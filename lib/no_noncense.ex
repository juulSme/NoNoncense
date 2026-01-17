defmodule NoNoncense do
  @moduledoc """
  Generate locally unique nonces (number-only-used-once) in distributed Elixir.

  Nonces are unique values that are generated once and never repeated within your system. They have many practical uses including:

  - **ID Generation**: Create unique identifiers for database records, API requests, or any other resource in distributed systems. If this is your use case, have a look at [Once](https://hexdocs.pm/once/Once.html).
  - **Cryptographic Operations**: Serve as initialization vectors (IVs) for encryption algorithms, ensuring security in block cipher modes
  - **Deduplication**: Identify and prevent duplicate operations or messages in distributed systems

  Locally unique means that the nonces are unique within your application/database/domain, as opposed to globally unique nonces that are unique across applications/databases/domains, like UUIDs.

  > #### Read the migration guide {: .warning}
  >
  > If you're upgrading from v0.x.x and you use encrypted nonces, please read the [Migration Guide](MIGRATION.md) carefully - there are breaking changes that require attention to preserve uniqueness guarantees.

  ## Usage

  Note that `NoNoncense` is not a GenServer. Instead it stores its initial state using `m::persistent_term` and its internal counter using `m::atomics`. Because `m::persistent_term` triggers a garbage collection cycle on writes, it is recommended to initialize your `NoNoncense` instance(s) at application start, when there is hardly any garbage to collect.

      # lib/my_app/application.ex
      # generate a machine ID, start conflict guard and initialize a NoNoncense instance
      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          machine_id = NoNoncense.MachineId.id!(node_list: [:"myapp@127.0.0.1"])
          # base_key is required for encrypted nonces
          :ok = NoNoncense.init(machine_id: machine_id, base_key: System.get_env("BASE_KEY"))

          children =
            [
              # optional but recommended
              {NoNoncense.MachineId.ConflictGuard, [machine_id: machine_id]}
            ]

          opts = [strategy: :one_for_one, name: MyApp.Supervisor]
          Supervisor.start_link(children, opts)
        end
      end

  Then you can generate nonces.

      # generate counter nonces
      iex> <<_::64>> = NoNoncense.nonce(64)
      iex> <<_::96>> = NoNoncense.nonce(96)
      iex> <<_::128>> = NoNoncense.nonce(128)

      # generate sortable nonces
      iex> <<_::64>> = NoNoncense.sortable_nonce(64)
      iex> <<_::96>> = NoNoncense.sortable_nonce(96)
      iex> <<_::128>> = NoNoncense.sortable_nonce(128)

      # generate encrypted nonces
      # be sure to read the NoNoncense docs before using 64/96-bit encrypted nonces
      iex> <<_::64>> = NoNoncense.encrypted_nonce(64)
      iex> <<_::96>> = NoNoncense.encrypted_nonce(96)
      iex> <<_::128>> = NoNoncense.encrypted_nonce(128)

  ## Anatomy of a nonce

  While there are different types of nonces, they share a common binary composition.

  * **42 bits:** Millisecond-precision timestamp (relative to the configured epoch, which is 2025-01-01 00:00 by default).
  * **9 bits:** Machine ID (supports up to 512 nodes).
  * **Remaining bits:** Per-machine counter (size depends on total nonce length).

  ## Nonce types

  Choose the type that best fits your security and performance requirements.

  | Type          | Features              | Generation rate                  | Info leak                       | Suitable for crypto |
  | :------------ | :-------------------- | :------------------------------- | :------------------------------ | :------------------ |
  | **Counter**   | Unique                | ⏩⏩⏩ Very high (burst capable) | 🟠 Medium (boot time, sequence) | ❌ No               |
  | **Sortable**  | Unique, time-sortable | ⏩⏩ High                        | ❌ High (create time, sequence) | ❌ No               |
  | **Encrypted** | Unique, unpredictable | ⏩⏩ High (scales with cores)    | ✅ None                         | ✅ Yes              |

  Nonces are guaranteed to be unique **if and only if**:
  - You use one instance and one nonce type. Only use separate instances for separate purposes (database IDs and encryption IVs, for example).
  - Machine IDs are unique for each node (`NoNoncense.MachineId` and `NoNoncense.MachineId.ConflictGuard` can help with that).
  - Nodes maintain a somewhat accurate clock (specifically, the UTC clock must progress between node restarts).
  - **Sortable nonces only:** the machine clock has to be accurate.
  - **Encrypted nonces only:** the cipher and key must not be changed.

  ### Counter nonces

  Counter nonces are basically a counter that is initialized with the machine (node) start time. An overflow of a nonce's counter bits will trigger a timestamp increase by 1ms, implying that the timestamp effectively functions as an extended counter. Because the timestamp can't exceed the actual time (that would break the uniqueness guarantee), new nonce generation throttles if the timestamp catches up to the actual time.

  That means that the maximum *sustained* rate is 8M/s per machine for 64-bit nonces (which have 13 counter bits). In practice it is unlikely that nonces are generated at such an extreme sustained rate, and the timestamp will lag behind the actual time. This creates "saved up seconds" that can be used to *burst* to even higher rates. For example, if the first nonce is generated 10 seconds after initialization, 10K milliseconds have been "saved up" to generate 80M nonces as quickly as hardware will allow. Benchmarking shows rates in the tens of millions per second are attainable this way.

  96/128 bits counter nonces have such large counters that they can be generated at a practically unlimited sustained rate of >= 2^45 nonces per ms per machine, meaning they will never catch the actual time, and the practical rate is only limited by hardware.

  ### Sortable nonces (Snowflake IDs)

  Sortable nonces have an accurate creation timestamp (as opposed to counter nonces). This makes them analogous to [Snowflake IDs](https://en.wikipedia.org/wiki/Snowflake_ID), apart from the slightly altered bit distribution of NoNoncense nonces (42 instead of 41 timestamp bits, 9 instead of 10 ID bits, no unused bit).

  This has some implications. Again, 96/128-bit sortable nonces can be generated as quickly as your hardware can go. However, the 64-bit variant can be generated at 8M/s per machine and can't ever burst beyond that (the "saved-up-seconds" mechanic of counter nonces does not apply here). This should of course be plenty for most applications.

  ### Encrypted nonces

  By encrypting a nonce, the timestamp, machine ID and sequence information leak can be prevented. However, we wish to encrypt in a way that **maintains the uniqueness guarantee** of the input counter nonce. We can achieve this by using a block cipher where the cipher's block size matches the nonce's bit-length.

  > #### Cipher recommendations {: .info}
  >
  > Use **AES** for 128-bit nonces. Use **Speck** for 64 and 96-bit nonces if possible. If you with to stick to OTP / non-NSA ciphers, use **Blowfish** on Linux and **3DES** elsewhere.
  >
  > |  | Size | Cipher   | Performance | Security | Future proof | Notes                                                       |
  > |:-| :--- | :------- | :---------- | :------- | :----------- | :---------------------------------------------------------- |
  > |🥇| 128  | AES      | ⏩⏩⏩⏩    | ✅✅✅   | ✅           | The "gold standard".                                        |
  > |  | 128  | Speck    | ⏩⏩⏩      | ✅✅     | ✅           | Recommended if no AES hardware acceleration, requires `SpeckEx`. |
  > |🥇| 96   | Speck    | ⏩⏩⏩      | ✅✅     | ✅           | Fully encrypted 96-bit nonces, requires `SpeckEx`.      |
  > |  | 96   | Blowfish | ⏩⏩        | ✅       | ❌           | Legacy, predictable tail, custom OpenSSL needed on Win/Mac. |
  > |  | 96   | 3DES     | ⏩          | ✅       | 🟠           | Not *yet* legacy, predictable tail, slow.             |
  > |🥇| 64   | Speck    | ⏩⏩⏩      | ✅✅     | ✅           | Requires `SpeckEx`.                                         |
  > |  | 64   | Blowfish | ⏩⏩⏩      | ✅       | ❌           | Legacy, custom OpenSSL needed on Win/Mac.                   |
  > |  | 64   | 3DES     | ⏩          | ✅       | 🟠           | Not *yet* legacy, slow.                               |

  > #### Don't change the key or cipher {: .warning}
  >
  > You must never change the cipher or key used to generate encrypted nonces; doing so breaks the uniqueness guarantee. The only way to change the key or the cipher is by regenerating / invalidating all previously generated encrypted nonces.

  > #### Don't use `encrypt/2` and `decrypt/2` for your own data {: .warning}
  >
  > The internal encryption primitives used by NoNoncense are designed solely to mask counters using raw block ciphers. Because they only operate on fixed-size blocks, lack padding or authentication, and use ciphers that are insecure for general-purpose applications, `encrypt/2` and `decrypt/2` are **not suitable for general-purpose encryption**.

  ## Nonce encryption deep dive

  Block ciphers essentially create a 1:1 (bijective) mapping of each plaintext block of data to an encrypted block. Most modern ciphers use 128-bit blocks, notably "gold standard" AES, making it the perfect choice for 128-bit nonces.

  The problem is that we can't use a 128-bit block cipher for 64/96-bit nonces, because we can't truncate the output. If we encrypt a 64-bit nonce with AES and then truncate the output back to 64 bits, collisions are possible. This makes sense in extremis: if we truncated to a single byte, the 2^64 unique inputs would result in only 256 unique outputs. So that's why we need ciphers with 64 and 96-bit block sizes, respectively. Unfortunately these are exceedingly rare because they are no longer secure for general-purpose usage.

  One such cipher is Speck, designed by the NSA in 2013 for lightweight encryption. It has both 64 and 96-bit variants. The optional dependency `SpeckEx`, backed by (precompiled) Rust crate `speck_cipher`, enables support for it. It is very fast; in line with hardware-accelerated AES. Be aware that although the primitive block cipher mode used by `NoNoncense` matches official test vectors, `SpeckEx` has not been reviewed or audited.

  If you only want to use OTP (OpenSSL) ciphers, we are limited to DES, 3DES, and BlowFish which all operate on 64-bit blocks. Both DES and Blowfish have been moved to the legacy ciphers list in OpenSSL 3.0, which means they are not available on all systems (notably Mac and Windows). Blowfish is the default because it offers the best performance by miles and is still available (for now) in Linux distributions, on which Elixir applications are likely to run. 3DES is a fallback option if that doesn't work for you and you don't want to use Speck. It is still part (for now) of the default ciphers in OpenSSL.

  For 96-bit nonces there are no block ciphers whatsoever to choose from in OTP. The best we can do is generate a 64-bit encrypted nonce and postfix 32 zero-bit. That way the nonce as a whole is unique, despite the predictable tail. You should determine for yourself if you can live with that. The only other option - and the main reason it exists in the first place - is using `SpeckEx`, because Speck has a 96-bit variant that can encrypt a full 96-bit counter nonce, without needing any padding.

  ## Crypto suitability

  NoNoncense encrypted nonces are **unique and unpredictable**, making them suitable for use as the input IV/nonce of a block or streaming cipher to encrypt your own data, like so:

      iex> data = "Hello world"
      iex> key = :crypto.strong_rand_bytes(32)
      iex> iv = NoNoncense.encrypted_nonce(128)
      iex> ciphertext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, data, true)

  Technically speaking, some block modes and ciphers only require IVs/nonces that are unique for a given key (but not necessarily unpredictable). Examples are CTR, GCM, CCM modes and streaming ciphers like ChaCha20. That means NoNoncense counter & sortable nonces **technically** meet the criteria, but because they leak information this is not a recommended practice.
  """
  alias NoNoncense.Crypto
  require Logger

  use __MODULE__.Constants

  @one_day_ms 24 * 60 * 60 * 1000

  @type nonce_size :: 64 | 96 | 128
  @type nonce :: <<_::64>> | <<_::96>> | <<_::128>>

  @init_opt_docs """
    * `:machine_id` (required) - machine ID of the node
    * `:name` - The name of the nonce factory (default: `NoNoncense`).
    * `:epoch` - Override the configured epoch for this factory instance. Defaults to the NoNoncense epoch (2025-01-01 00:00:00Z).
    * `:base_key` - A key of at least 256 bits (32 bytes) used to derive encryption keys for all nonce sizes.
    * `:key64` - Override the derived key for 64-bit nonces.
    * `:key96` - Override the derived key for 96-bit nonces.
    * `:key128` - Override the derived key for 128-bit nonces.
    * `:cipher64` - The cipher for 64-bit nonces (`:blowfish`, `:speck`, or `:des3`). Defaults to `:blowfish`.
    * `:cipher96` - The cipher for 96-bit nonces (`:blowfish`, `:speck`, or `:des3`). Defaults to `:blowfish`.
    * `:cipher128` - The cipher for 128-bit nonces (`:aes` or `:speck`). Defaults to `:aes`.

  The encryption-related options only affect `encrypted_nonce/2` nonces.
  """

  @typedoc @init_opt_docs
  @type init_opt ::
          {:epoch, non_neg_integer()}
          | {:name, atom()}
          | {:machine_id, non_neg_integer()}
          | {:base_key, binary()}
          | {:key64, binary()}
          | {:key96, binary()}
          | {:key128, binary()}
          | {:cipher64, :blowfish | :des3 | :speck}
          | {:cipher96, :blowfish | :des3 | :speck}
          | {:cipher128, :aes | :speck}

  @doc """
  Initialize a nonce factory. Multiple instances with different names, epochs and even machine IDs are supported.

  ## Options

  #{@init_opt_docs}

  ## Examples

      iex> NoNoncense.init(machine_id: 1)
      :ok

      iex> NoNoncense.init(machine_id: 1, name: :custom, epoch: 1609459200000)
      :ok
  """
  @spec init([init_opt()]) :: :ok
  def init(opts \\ []) do
    name = opts[:name] || __MODULE__
    epoch = opts[:epoch] || @no_noncense_epoch
    machine_id = Keyword.fetch!(opts, :machine_id)

    # check machine ID
    if machine_id < 0 or machine_id > @machine_id_limit,
      do: raise(ArgumentError, "machine ID out of range 0-#{@machine_id_limit}")

    # the offset of the monotonic clock from the epoch
    time_offset = System.time_offset(:millisecond) - epoch
    init_at = time_from_offset(time_offset)

    # verify timestamp does not overflow
    timestamp_overflow = Integer.pow(2, @ts_bits)
    if init_at >= timestamp_overflow, do: raise(RuntimeError, "timestamp overflow")
    days_until_overflow = div(timestamp_overflow - init_at, @one_day_ms)

    if days_until_overflow <= 365,
      do: Logger.warning("timestamp overflow in #{days_until_overflow} days")

    # initialize nonce counters
    counters_ref = :atomics.new(2, signed: false)
    # the counter will overflow to 0 on the first nonce generation
    :atomics.put(counters_ref, @counter_idx, Integer.pow(2, 64) - 1)
    :atomics.put(counters_ref, @sortable_counter_idx, init_at)

    # initialize encryption keys
    ciphers = Crypto.init(opts)

    # build and store the state
    state = {machine_id, init_at, time_offset, counters_ref, ciphers}
    :ok = :persistent_term.put(name, state)
  end

  @doc """
  Generate a new 64/96/128-bit counter-like nonce.

  ## Examples

      iex> nonce(64)
      <<101, 6, 25, 181, 192, 128, 32, 17>>

      iex> nonce(96)
      <<101, 6, 25, 181, 192, 128, 32, 0, 0, 0, 0, 18>>

      iex> nonce(128)
      <<101, 6, 25, 181, 192, 128, 32, 0, 0, 0, 0, 0, 0, 0, 0, 19>>
  """
  @spec nonce(atom(), nonce_size()) :: nonce()
  def nonce(name \\ __MODULE__, bit_size)
  def nonce(name, bit_size), do: :persistent_term.get(name) |> gen_ctr_nonce(bit_size)

  defp gen_ctr_nonce({machine_id, init_at, time_offset, counters_ref, _}, 64) do
    # we can generate 10B nonce/s for 60 years straight before the unsigned 64-bit int overflows
    # so we don't need to worry about the atomic counter itself overflowing
    atomic_count = :atomics.add_get(counters_ref, @counter_idx, 1)

    # but we do need to worry about the nonce's counter - only 13 bits for a 64-bit nonce - overflowing
    # we divide the 64-bit atomic counter space to derive the nonce's cycle count and counter
    <<cycle_n::@atomic_cycle_bits_64, count::@count_bits_64>> = <<atomic_count::64>>

    # the nonce timestamp is actually an init timestamp + cycle counter
    timestamp = init_at + cycle_n

    # with small counters in the nonce, we may need to wait for the monotonic clock to catch up to the nonce timestamp
    # with bigger nonces the counter is so big (>= 2^45) that it can't realistically overtake the timestamp
    wait_until(timestamp, time_offset)

    to_nonce(timestamp, machine_id, count, 64)
  end

  defp gen_ctr_nonce({machine_id, init_at, _time_offset, counters_ref, _}, 96) do
    atomic_count = :atomics.add_get(counters_ref, @counter_idx, 1)
    <<cycle_n::@atomic_cycle_bits_96, count::@count_bits_96>> = <<atomic_count::64>>
    to_nonce(init_at + cycle_n, machine_id, count, 96)
  end

  defp gen_ctr_nonce({machine_id, init_at, _time_offset, counters_ref, _}, 128) do
    atomic_count = :atomics.add_get(counters_ref, @counter_idx, 1)
    to_nonce(init_at, machine_id, atomic_count, 128)
  end

  @doc """
  Generate a new nonce and encrypt it, to create a unique but unpredictable nonce.

  The `base_type` argument can be used to specify if a `:counter` or `:sortable` nonce
  should be used as the plaintext nonce (default `:counter`).

  For more info, see [encrypted nonces](#module-encrypted-nonces).

  ## Examples

      iex> NoNoncense.init(machine_id: 1, base_key: :crypto.strong_rand_bytes(32))
      :ok
      iex> NoNoncense.encrypted_nonce(64)
      <<50, 231, 215, 98, 233, 96, 157, 205>>
      iex> NoNoncense.encrypted_nonce(96)
      <<6, 138, 218, 96, 131, 136, 51, 242, 0, 0, 0, 0>>
      iex> NoNoncense.encrypted_nonce(128)
      <<162, 10, 94, 4, 91, 56, 147, 198, 46, 87, 142, 197, 128, 41, 79, 209>>

      # Using sortable nonces as base
      iex> NoNoncense.encrypted_nonce(64, :sortable)
      <<177, 123, 45, 67, 89, 12, 234, 56>>
  """
  @spec encrypted_nonce(atom(), nonce_size(), :counter | :sortable) :: nonce()
  def encrypted_nonce(name \\ __MODULE__, bit_size, base_type \\ :counter)

  def encrypted_nonce(name, bit_size, base_type) when bit_size in [64, 128] do
    config = :persistent_term.get(name)
    cipher = get_cipher(config, bit_size)
    gen_base_nonce(config, base_type, bit_size) |> Crypto.crypt(cipher, true)
  end

  def encrypted_nonce(name, 96, base_type) do
    config = :persistent_term.get(name)
    {_, _, _, _, {_, cipher, _}} = config

    case cipher do
      {:speck, _} -> gen_base_nonce(config, base_type, 96) |> Crypto.crypt(cipher, true)
      _ -> (gen_base_nonce(config, base_type, 64) |> Crypto.crypt(cipher, true)) <> @pad_64_to_96
    end
  end

  @doc """
  Encrypt a nonce while preserving its uniqueness guarantee. Only use this function to encrypt NoNoncense nonces.

  Under the same key and cipher, this results in a one-to-one mapping of plaintext and ciphertext nonces.

  The same caveats described for `encrypted_nonce/3` also apply to `encrypt/2` and `decrypt/2`. For more info, see [encrypted nonces](#module-encrypted-nonces).

      iex> NoNoncense.init(machine_id: 1, base_key: :crypto.strong_rand_bytes(32))
      :ok
      iex> plaintext = NoNoncense.nonce(64)
      iex> ^plaintext = plaintext |> NoNoncense.encrypt() |> NoNoncense.decrypt()
  """
  @spec encrypt(atom, nonce()) :: nonce()
  def encrypt(name \\ __MODULE__, nonce), do: :persistent_term.get(name) |> crypt(nonce, true)

  @doc """
  Decrypt a nonce. Only use this function to decrypt NoNoncense nonces. See `encrypt/2`.
  """
  @spec decrypt(atom, nonce()) :: nonce()
  def decrypt(name \\ __MODULE__, nonce), do: :persistent_term.get(name) |> crypt(nonce, false)

  @doc """
  Generate a nonce that is sortable by generation time, like a Snowflake ID. The first 42 bits contain the timestamp.

  These nonces are *not* suitable for cryptographic purposes because they are predictable and leak their generation timestamp.

  ## Examples

      iex> NoNoncense.sortable_nonce(64)
      <<0, 15, 27, 213, 143, 128, 0, 0>>
      iex> NoNoncense.sortable_nonce(96)
      <<0, 15, 27, 215, 172, 0, 0, 0, 0, 0, 0, 0>>
      iex> NoNoncense.sortable_nonce(128)
      <<0, 15, 27, 217, 161, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
  """
  @spec sortable_nonce(atom(), nonce_size()) :: nonce()
  def sortable_nonce(name \\ __MODULE__, bit_size)
  def sortable_nonce(name, bit_size), do: :persistent_term.get(name) |> gen_srt_nonce(bit_size)

  defp gen_srt_nonce(cfg = {machine_id, _, time_offset, counters_ref, _}, bit_size)
       when bit_size in [64, 96, 128] do
    ts_counter = :atomics.add_get(counters_ref, @sortable_counter_idx, 1)
    # 2^22 * 1000 = 4B ops/s is not an attainable generation rate, we can assume no overflow
    <<current_ts::@ts_bits, new_count::@non_ts_bits_64>> = <<ts_counter::64>>

    now = time_from_offset(time_offset)

    # if timestamp has changed since last invocation...
    if now > current_ts do
      # ...reset the counter. Under load, this should be a minority of cases.
      <<new_ts_counter::64>> = <<now::@ts_bits, 0::@non_ts_bits_64>>

      :atomics.compare_exchange(counters_ref, @sortable_counter_idx, ts_counter, new_ts_counter)
      |> case do
        :ok -> to_nonce(now, machine_id, 0, bit_size)
        _ -> gen_srt_nonce(cfg, bit_size)
      end
    else
      # larger nonce sizes will not overflow their >= 2^45 bits counters
      if bit_size == 64 and new_count >= @max_count_64 do
        gen_srt_nonce(cfg, bit_size)
      else
        to_nonce(now, machine_id, new_count, bit_size)
      end
    end
  end

  @doc """
  Get the timestamp of the nonce as a `DateTime`, given the epoch of the instance.
  This should only be used for `sortable_nonce/2` nonces.

  ## Examples

      iex> NoNoncense.get_datetime(<<0, 15, 27, 213, 143, 128, 0, 0>>)
      ~U[2025-01-12 17:38:49.534Z]
  """
  @spec get_datetime(atom(), nonce()) :: DateTime.t()
  def get_datetime(name \\ __MODULE__, nonce) do
    {_, _init_at, time_offset, _, _} = :persistent_term.get(name)
    <<timestamp::@ts_bits, _::bits>> = nonce
    epoch = System.time_offset(:millisecond) - time_offset
    timestamp = timestamp + epoch
    DateTime.from_unix!(timestamp, :millisecond)
  end

  ###########
  # Private #
  ###########

  @compile {:inline, wait_until: 2}
  defp wait_until(timestamp, time_offset) do
    now = time_from_offset(time_offset)
    if timestamp > now, do: :timer.sleep(timestamp - now)
  end

  @compile {:inline, time_from_offset: 1}
  defp time_from_offset(time_offset), do: System.monotonic_time(:millisecond) + time_offset

  @compile {:inline, to_nonce: 4}
  defp to_nonce(timestamp, machine_id, count, _size = 64) do
    <<timestamp::@ts_bits, machine_id::@id_bits, count::@count_bits_64>>
  end

  defp to_nonce(timestamp, machine_id, count, 96) do
    <<timestamp::@ts_bits, machine_id::@id_bits, count::@count_bits_96>>
  end

  defp to_nonce(timestamp, machine_id, count, 128) do
    <<timestamp::@ts_bits, machine_id::@id_bits, 0::@padding_bits_128, count::64>>
  end

  @compile {:inline, get_cipher: 2}
  defp get_cipher({_, _, _, _, {cipher, _, _}}, 64), do: cipher
  defp get_cipher({_, _, _, _, {_, cipher, _}}, 96), do: cipher
  defp get_cipher({_, _, _, _, {_, _, cipher}}, 128), do: cipher

  @compile {:inline, gen_base_nonce: 3}
  defp gen_base_nonce(config, :counter, bit_size), do: gen_ctr_nonce(config, bit_size)
  defp gen_base_nonce(config, :sortable, bit_size), do: gen_srt_nonce(config, bit_size)

  defp crypt(config, nonce, encrypt?), do: bit_size(nonce) |> crypt(config, nonce, encrypt?)

  @compile {:inline, crypt: 4}
  defp crypt(bit_size, config, nonce, encrypt?) when bit_size in [64, 96, 128] do
    cipher = get_cipher(config, bit_size)
    Crypto.crypt(nonce, cipher, encrypt?)
  end
end
