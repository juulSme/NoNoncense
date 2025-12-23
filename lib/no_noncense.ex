defmodule NoNoncense do
  @moduledoc """
  Generate locally unique nonces (number-only-used-once) in distributed Elixir.

  Locally unique means that the nonces are unique within your application/database/domain, as opposed to globally unique nonces that are unique across applications/databases/domains, like UUIDs.

  > #### Read the migration guide {: .warning}
  >
  > If you're upgrading from v0.x.x and you use encrypted nonces, please read the [Migration Guide](MIGRATION.md) carefully - there are breaking changes that require attention to preserve uniqueness guarantees.

  ## Nonce types

  Several types of nonces can be generated, although they share their basic composition. The first 42 bits are a millisecond-precision timestamp (allows for ~139 years of operation), relative to the NoNoncense epoch (2025-01-01 00:00:00 UTC) by default. The next 9 bits are the machine ID (allows for 512 machines). The remaining bits are a per-machine counter.

  ### Counter nonces

  - Features: unique.
  - Generation rate: very high.
  - Info leak: medium (machine init time, creation order).
  - Crypto: technically suitable for block ciphers in modes that require a nonce that is unique but not necessarily unpredictable (like CTR, OFB, CCM, and GCM), and some streaming ciphers. Only when some info leak is acceptable.

  Counter nonces are basically a counter that is initialized with the machine (node) start time. An overflow of a nonce's counter bits will trigger a timestamp increase by 1ms, implying that the timestamp effectively functions as an extended counter. Because the timestamp can't exceed the actual time (that would break the uniqueness guarantee), new nonce generation throttles if the timestamp catches up to the actual time.

  That means that the maximum *sustained* rate is 8M/s per machine for 64-bits nonces (which have 13 counter bits). In practice it is unlikely that nonces are generated at such an extreme sustained rate, and the timestamp will lag behind the actual time. This creates "saved up seconds" that can be used to *burst* to even higher rates. For example, if the first nonce is generated 10 seconds after initialization, 10K milliseconds have been "saved up" to generate 80M nonces as quickly as hardware will allow. Benchmarking shows rates in the tens of millions per second are attainable this way.

  96/128 bits counter nonces have such large counters that they can be generated at a practically unlimited sustained rate of >= 2^45 nonces per ms per machine, meaning they will never catch the actual time, and the practical rate is only limited by hardware.

  ### Sortable nonces (Snowflake IDs)

  - Features: unique, time-sortable.
  - Generation rate: high.
  - Info leak: high (creation time, creation order).
  - Crypto: not recommended. They leak more info than counter nonces but are slightly slower to generate.

  Sortable nonces have an accurate creation timestamp (as opposed to counter nonces). This makes them equivalent to [Snowflake IDs](https://en.wikipedia.org/wiki/Snowflake_ID), apart from the slightly altered bit distribution of NoNoncense nonces (42 instead of 41 timestamp bits, 9 instead of 10 ID bits, no unused bit).

  This has some implications. Again, 96/128-bits sortable nonces can be generated as quickly as your hardware can go. However, the 64-bits variant can be generated at 8M/s per machine and can't ever burst beyond that (the "saved-up-seconds" mechanic of counter nonces does not apply here). This should of course be plenty for most applications.

  ### Encrypted nonces

  - Features: unique, unpredictable.
  - Generation rate: medium (scales well with CPU cores).
  - Info leak: none.
  - Crypto: same as counter nonces, but no info leaks. Additionally, suitable for block cipher modes that require unpredictable IVs, like CBC and CFB.

  These nonces are encrypted in a way that preserves their uniqueness, but they are unpredictable and don't leak information. For more info, see [nonce encryption](#module-nonce-encryption).

  > #### Don't change the key or cipher {: .warning}
  >
  > Once you are using a cipher and a key, you **must never** change them. Doing so breaks the uniqueness guarantees of all encrypted nonces of the affected NoNoncense instance. The only way to change the key or the cipher is by regenerating / invalidating all previously generated encrypted nonces.

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
      # be sure to read the NoNoncense docs before using 64/96 bits encrypted nonces
      iex> <<_::64>> = NoNoncense.encrypted_nonce(64)
      iex> <<_::96>> = NoNoncense.encrypted_nonce(96)
      iex> <<_::128>> = NoNoncense.encrypted_nonce(128)


  ## Uniqueness guarantees

  Nonces are guaranteed to be unique if:
  - Machine IDs are unique for each node (`NoNoncense.MachineId` and `NoNoncense.MachineId.ConflictGuard` can help there).
  - Individual machines maintain a somewhat accurate clock (specifically, the UTC clock has to have progressed between node restarts).
  - (Sortable nonces only) the machine clock has to be accurate.

  ## Nonce encryption

  By encrypting a nonce, the timestamp, machine ID and message ordering information leak can be prevented. However, we wish to encrypt in a way that **maintains the uniqueness guarantee** of the input counter nonce. So 2^64 unique inputs should generate 2^64 unique outputs, same for the other sizes.

  IETF has some [wisdom to share](https://datatracker.ietf.org/doc/html/rfc8439#section-4) on the topic of nonce encryption (in the context of ChaCha20 / Poly1305 nonces):

  > Counters and LFSRs are both acceptable ways of generating unique nonces, as is encrypting a counter using a block cipher with a 64-bit block size such as DES. Note that it is not acceptable to use a truncation of a counter encrypted with block ciphers with 128-bit or 256-bit blocks, because such a truncation may repeat after a short time.

  There are some interesting things to unpick there. Why can't we use higher ciphers with a larger block size? As it turns out, block ciphers only generate unique outputs for inputs of at least their block size (128 bits for most modern ciphers, notably AES). For example, encrypting a 64-bit nonce with AES would produce a unique 128-bit ciphertext, but that ciphertext can't be reduced back to 64 bits without losing the uniqueness property. Sadly, this also holds for the streaming modes of these ciphers, which still use blocks internally to generate the keystream. That means we can just use AES256 ECB (we only encrypt unique blocks) for 128-bit nonces.

  > #### 128-bit encrypted nonces {: .tip}
  >
  > We have AES256-encrypted 128-bit nonces that are unique and indistinguishable from random noise.

  For 64/96 bits nonces we need a block cipher that operates on matching block sizes, which are exceedingly rare. One such cipher is Speck, designed by the NSA in 2013 for lightweight encryption. The optional dependency `SpeckEx`, backed by (precompiled) Rust crate `speck_cipher`, enables support for it. It is very fast; in line with hardware-accelerated AES. Be aware that SpeckEx should be considered experimental right now; it has not been reviewed or audited; although the primitive block cipher mode used by `NoNoncense` matches official test vectors.

  If you only want to use OTP ciphers, we are limited to DES, 3DES, and BlowFish. DES is broken and can merely be considered obfuscation at this point, despite the IETF quote (from 2018). 3DES is slow (it is still offered for backwards compatibility). Blowfish performs well after initial key expansion, and is secure since we don't have to worry about the birthday attack (all of our input blocks are unique, so all of our output blocks are unique, so there will be no collisions).

  For 96-bit nonces there are no block ciphers whatsoever to choose from in OTP. All we can do is generate a 64-bits encrypted nonce and postfix 32 zero-bits. That way the whole nonce is unique, despite the predictable tail. You should determine for yourself if you can live with that. The only other option, and the main reason it was added, is using `SpeckEx`, because Speck has a 96-bits variant that can encrypt a full 96-bits counter nonce, without needing any padding.

  > #### 64/96-bit encrypted nonces {: .info}
  >
  > We have either Speck, Blowfish or 3DES encrypted nonces. Speck offers the best security and performance, but is experimental right now. Of the OTP ciphers, the default Blowfish is fast and secure. For 96-bits nonces, using OTP's Blowfish or 3DES results in a padded 64-bits encrypted nonce, which may or may not be good enough for your use case. If it is not, your only option is using Speck.
  """
  alias NoNoncense.Crypto
  require Logger

  use __MODULE__.Constants

  @one_day_ms 24 * 60 * 60 * 1000

  @type nonce_size :: 64 | 96 | 128
  @type nonce :: <<_::64>> | <<_::96>> | <<_::128>>

  @type init_opts :: [epoch: non_neg_integer(), name: atom(), machine_id: non_neg_integer()]

  @doc """
  Initialize a nonce factory. Multiple instances with different names, epochs and even machine IDs are supported.

  ## Options

    * `:machine_id` (required) - machine ID of the node
    * `:name` - The name of the nonce factory (default: module name).
    * `:epoch` - Override the configured epoch for this factory instance. Defaults to the NoNoncense epoch (2025-01-01 00:00:00Z).
    * `:base_key` - A 256-bit (32 bytes) key used to derive encryption keys for all nonce sizes.
    * `:key64` - Override the derived key for 64-bit nonces.
    * `:key96` - Override the derived key for 96-bit nonces.
    * `:key128` - Override the derived key for 128-bit nonces.
    * `:cipher64` - The cipher for 64-bit nonces (`:blowfish`, `:speck`, or `:des3`). Defaults to `:blowfish`.
    * `:cipher96` - The cipher for 96-bit nonces (`:blowfish`, `:speck`, or `:des3`). Defaults to `:blowfish`.
    * `:cipher128` - The cipher for 128-bit nonces (`:aes` or `:speck`). Defaults to `:aes`.

  The encryption-related options only affect `encrypted_nonce/2` nonces.

  ## Examples

      iex> NoNoncense.init(machine_id: 1)
      :ok

      iex> NoNoncense.init(machine_id: 1, name: :custom, epoch: 1609459200000)
      :ok
  """
  @spec init(init_opts()) :: :ok
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
  Generate a new 64/96/128-bits counter-like nonce.

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

  def nonce(name, 64) do
    {machine_id, init_at, time_offset, counters_ref, _} = :persistent_term.get(name)
    gen_ctr_nonce_64(machine_id, init_at, time_offset, counters_ref)
  end

  def nonce(name, 96) do
    {machine_id, init_at, time_offset, counters_ref, _} = :persistent_term.get(name)
    gen_ctr_nonce_96(machine_id, init_at, time_offset, counters_ref)
  end

  def nonce(name, 128) do
    {machine_id, init_at, time_offset, counters_ref, _} = :persistent_term.get(name)
    gen_ctr_nonce_128(machine_id, init_at, time_offset, counters_ref)
  end

  @compile {:inline, gen_ctr_nonce_64: 4, gen_ctr_nonce_96: 4, gen_ctr_nonce_128: 4}
  defp gen_ctr_nonce_64(machine_id, init_at, time_offset, counters_ref) do
    # we can generate 10B nonce/s for 60 years straight before the unsigned 64-bits int overflows
    # so we don't need to worry about the atomic counter itself overflowing
    atomic_count = :atomics.add_get(counters_ref, @counter_idx, 1)

    # but we do need to worry about the nonce's counter - which may be only 13 bits for a 64-bit nonce - overflowing
    # we divide the 64-bit atomic counter space to derive the nonce's cycle count and counter
    <<cycle_n::@atomic_cycle_bits_64, count::@count_bits_64>> = <<atomic_count::64>>

    # the nonce timestamp is actually an init timestamp + cycle counter
    timestamp = init_at + cycle_n

    # with small counters in the nonce, we may need to wait for the monotonic clock to catch up to the nonce timestamp
    # with bigger nonces the counter is so big (>= 2^45) that it can't realistically overtake the timestamp
    wait_until(timestamp, time_offset)

    to_nonce(timestamp, machine_id, count, 64)
  end

  defp gen_ctr_nonce_96(machine_id, init_at, _time_offset, counters_ref) do
    atomic_count = :atomics.add_get(counters_ref, @counter_idx, 1)
    <<cycle_n::@atomic_cycle_bits_96, count::@count_bits_96>> = <<atomic_count::64>>
    to_nonce(init_at + cycle_n, machine_id, count, 96)
  end

  defp gen_ctr_nonce_128(machine_id, init_at, _time_offset, counters_ref) do
    atomic_count = :atomics.add_get(counters_ref, @counter_idx, 1)
    to_nonce(init_at, machine_id, atomic_count, 128)
  end

  @doc """
  Generate a new counter nonce and encrypt it. This creates an unpredictable but still unique nonce.

  For more info, see [nonce encryption](#module-nonce-encryption).

      iex> NoNoncense.init(machine_id: 1, base_key: :crypto.strong_rand_bytes(32))
      :ok
      iex> NoNoncense.encrypted_nonce(64)
      <<50, 231, 215, 98, 233, 96, 157, 205>>
      iex> NoNoncense.encrypted_nonce(96)
      <<6, 138, 218, 96, 131, 136, 51, 242, 0, 0, 0, 0>>
      iex> NoNoncense.encrypted_nonce(128)
      <<162, 10, 94, 4, 91, 56, 147, 198, 46, 87, 142, 197, 128, 41, 79, 209>>
  """
  @spec encrypted_nonce(atom(), nonce_size()) :: nonce()
  def encrypted_nonce(name \\ __MODULE__, bit_size)

  def encrypted_nonce(name, 64) do
    {machine_id, init_at, time_offset, counters_ref, {cipher64, _, _}} =
      :persistent_term.get(name)

    nonce = gen_ctr_nonce_64(machine_id, init_at, time_offset, counters_ref)

    case cipher64 do
      {:speck, cipher64} -> Crypto.speck_enc(nonce, cipher64, :speck64_128)
      {:blowfish, cipher64} -> :crypto.crypto_update(cipher64, nonce)
      {:des3, key} -> des_encrypt(nonce, key)
      nil -> raise RuntimeError, "no key set at NoNoncense initialization"
    end
  end

  @pad_64_to_96 <<0::32>>

  def encrypted_nonce(name, 96) do
    {machine_id, init_at, time_offset, counters_ref, {_, cipher96, _}} =
      :persistent_term.get(name)

    case cipher96 do
      {:speck, cipher96} ->
        gen_ctr_nonce_96(machine_id, init_at, time_offset, counters_ref)
        |> Crypto.speck_enc(cipher96, :speck96_144)

      {other, cipher_or_key} ->
        nonce = gen_ctr_nonce_64(machine_id, init_at, time_offset, counters_ref)

        case other do
          :blowfish -> :crypto.crypto_update(cipher_or_key, nonce) <> @pad_64_to_96
          :des3 -> des_encrypt(nonce, cipher_or_key) <> @pad_64_to_96
        end

      nil ->
        raise RuntimeError, "no key set at NoNoncense initialization"
    end
  end

  def encrypted_nonce(name, 128) do
    {machine_id, init_at, time_offset, counters_ref, {_, _, cipher128}} =
      :persistent_term.get(name)

    nonce = gen_ctr_nonce_128(machine_id, init_at, time_offset, counters_ref)

    case cipher128 do
      {:aes, cipher128} -> :crypto.crypto_update(cipher128, nonce)
      {:speck, cipher128} -> Crypto.speck_enc(nonce, cipher128, :speck128_256)
      nil -> raise RuntimeError, "no key set at NoNoncense initialization"
    end
  end

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

      # the generation time can be extracted
      iex> <<ts::42, _::22>> = <<0, 15, 27, 213, 143, 128, 0, 0>>
      iex> epoch = ~U[2025-01-01T00:00:00Z] |> DateTime.to_unix(:millisecond)
      iex> DateTime.from_unix!(ts + epoch, :millisecond)
      ~U[2025-01-12 17:38:49.534Z]
  """
  @spec sortable_nonce(atom(), nonce_size()) :: nonce()
  def sortable_nonce(name \\ __MODULE__, bit_size) when bit_size in [64, 96, 128] do
    {machine_id, _init_at, time_offset, counters_ref, _} = :persistent_term.get(name)

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
        _ -> sortable_nonce(name, bit_size)
      end
    else
      # larger nonce sizes will not overflow their >= 2^45 bits counters
      if bit_size == 64 and new_count >= @max_count_64 do
        sortable_nonce(name, bit_size)
      else
        to_nonce(now, machine_id, new_count, bit_size)
      end
    end
  end

  @doc """
  Get the timestamp of the nonce as a `DateTime`, given the epoch of the instance.
  This should only be used for `sortable_nonce/2` nonces.
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

  @compile {:inline, wait_until: 2, time_from_offset: 1, to_nonce: 4}

  defp wait_until(timestamp, time_offset) do
    now = time_from_offset(time_offset)
    if timestamp > now, do: :timer.sleep(timestamp - now)
  end

  defp time_from_offset(time_offset), do: System.monotonic_time(:millisecond) + time_offset

  defp to_nonce(timestamp, machine_id, count, size)

  defp to_nonce(timestamp, machine_id, count, 64) do
    <<timestamp::@ts_bits, machine_id::@id_bits, count::@count_bits_64>>
  end

  defp to_nonce(timestamp, machine_id, count, 96) do
    <<timestamp::@ts_bits, machine_id::@id_bits, count::@count_bits_96>>
  end

  defp to_nonce(timestamp, machine_id, count, 128) do
    <<timestamp::@ts_bits, machine_id::@id_bits, 0::@padding_bits_128, count::64>>
  end

  @des_iv <<0::64>>

  @compile {:inline, des_encrypt: 2}
  defp des_encrypt(nonce, key) do
    :crypto.crypto_one_time(:des_ede3_cbc, key, @des_iv, nonce, true)
  end
end
