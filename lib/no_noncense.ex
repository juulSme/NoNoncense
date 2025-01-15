defmodule NoNoncense do
  @moduledoc """
  Generate locally unique nonces (number-only-used-once) in distributed Elixir.

  Locally unique means that the nonces are unique within your application/database/domain, as opposed to globally unique nonces that are unique across applications/databases/domains, like UUIDs.

  ## Nonce types

  Several types of nonces can be generated, although they share their basic composition. The first 42 bits are a millisecond-precision timestamp (allows for ~139 years of operation), relative to the NoNoncense epoch (2025-01-01 00:00:00 UTC) by default. The next 9 bits are the machine ID (allows for 512 machines). The remaining bits are a per-machine counter.

  ### Counter nonces

  - Features: unique.
  - Generation rate: very high.
  - Info leak: medium (machine init time, creation order).
  - Crypto: technically suitable for block ciphers in modes that require an IV that is unique but not necessarily unpredictable (like CTR, OFB, CCM, and GCM), and some streaming ciphers. Only when some info leak is acceptable.

  96/128 bits counter nonces can be generated at a practically unlimited rate of >= 2^45 nonces per ms per machien. With 64-bits nonces, an overflow of the 13 counter bits will trigger a timestamp increase by 1ms (the timestamp effectively functions as an extended counter after initialization). The maximum *sustained* rate is 8M/s per machine. Because the timestamp can't exceed the actual time (that would break the uniqueness guarantee), new nonce generation throttles if the nonce timestamp/counter catches up to the actual time. In practice, that will probably never happen, and nonces will be generated at a higher rate. For example, if the first nonce is generated 10 seconds after initialization, 10K milliseconds have been "saved up" to generate 80M 64-bit nonces as quickly as hardware will allow. Benchmarking shows rates in the tens of millions per second are attainable.

  ### Sortable nonces (Snowflake IDs)

  - Features: unique, time-sortable.
  - Generation rate: high.
  - Info leak: high (creation time, creation order).
  - Crypto: not recommended. They leak more info than counter nonces but are slower to generate.

  Sortable nonces have an accurate creation timestamp, instead of counter nonces' hybrid init time + counter construction. This makes them equivalent to [Snowflake IDs](https://en.wikipedia.org/wiki/Snowflake_ID), apart from the slightly altered bit distribution of NoNoncense nonces (42 instead of 41 timestamp bits, 9 instead of 10 ID bits, no unused bit).

  This has some implications. Again, 96/128-bits sortable nonces can be generated as quickly as your hardware can go. However, the 64-bits variant can be generated at 8M/s per machine and can't ever burst beyond that (the "saving up seconds" mechanic of counter nonces does not apply here). This should of course be plenty for most applications.

  ### Encrypted nonces

  - Features: unique, unpredictable.
  - Generation rate: medium (scales well with CPU cores).
  - Info leak: none.
  - Crypto: same as counter nonces, but no info leaks. Additionally, suitable for block cipher modes that require unpredictable IVs, like CBC and CFB.

  These nonces are encrypted in a way that preserves their uniqueness, but they are unpredictable and don't leak information. For more info, see [encrypted nonces](#module-encrypted-nonces).

  ## Usage

  Note that `NoNoncense` is not a GenServer. Instead it stores its initial state using `m::persistent_term` and its internal counter using `m::atomics`. Because `m::persistent_term` triggers a garbage collection cycle on writes, it is recommended to initialize your `NoNoncense` instance(s) at application start, when there is hardly any garbage to collect.

      # lib/my_app/application.ex
      # generate a machine ID, start conflict guard and initialize a NoNoncense instance
      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          machine_id = NoNoncense.MachineId.id!(node_list: [:"myapp@127.0.0.1"])
          :ok = NoNoncense.init(machine_id: machine_id)

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
      iex> <<_::64>> = NoNoncense.encrypted_nonce(64, :crypto.strong_rand_bytes(24))
      iex> <<_::96>> = NoNoncense.encrypted_nonce(96, :crypto.strong_rand_bytes(24))
      iex> <<_::128>> = NoNoncense.encrypted_nonce(128, :crypto.strong_rand_bytes(32))


  ## Uniqueness guarantees

  Nonces are guaranteed to be unique if:
  - Machine IDs are unique for each node (`NoNoncense.MachineId` and `NoNoncense.MachineId.ConflictGuard` can help there).
  - Individual machines maintain a somewhat accurate clock (specifically, the UTC clock has to have progressed between node restarts).
  - (Sortable nonces only) the machine clock has to be accurate.

  ## Encrypted nonces

  By encrypting a nonce, the timestamp, machine ID and message ordering information leak can be prevented. However, we wish to encrypt in a way that **maintains the uniqueness guarantee** of the input counter nonce. So 2^64 unique inputs should generate 2^64 unique outputs, same for the other sizes.

  IETF has some [wisdom to share](https://datatracker.ietf.org/doc/html/rfc8439#section-4) on the topic of nonce encryption (in the context of ChaCha20 / Poly1305 nonces):

  > Counters and LFSRs are both acceptable ways of generating unique nonces, as is encrypting a counter using a block cipher with a 64-bit block size such as DES. Note that it is not acceptable to use a truncation of a counter encrypted with block ciphers with 128-bit or 256-bit blocks, because such a truncation may repeat after a short time.

  There are some interesting things to unpick there. Why can't we use higher ciphers with a larger block size? As it turns out, block ciphers only generate unique outputs for inputs of at least their block size (128 bits for most modern ciphers, notably AES). For example, encrypting a 64-bit nonce with AES would produce a unique 128-bit ciphertext, but that ciphertext can't be reduced back to 64 bits without losing the uniqueness property. Sadly, this also holds for the streaming modes of these ciphers, which still use blocks internally to generate the keystream. That means we can just use AES256 ECB (we only encrypt one block) for 128-bit nonces.

  > #### 128-bit encrypted nonces {: .tip}
  >
  > We have AES256-encrypted 128-bit nonces that are unique and indistinguishable from random noise.

  However, for 64-bit nonces we are limited to block ciphers with 64-bit block sizes. There are only a few of those in OTP's `m::crypto` module, namely DES, 3DES, and BlowFish. DES is broken and can merely be considered obfuscation at this point, despite the IETF quote (from 2018). BlowFish performs atrociously in the OTP implementation (~30 times worse than AES, dropping from ~1.8M ops/s to 60K ops/s) to the point where it can realistically form a bottleneck. 3DES seems like the least worst option, and practical attacks on it are mainly aimed at block collisions (within a message) which doesn't apply here. Still, it's old.

  For 96-bit nonces there are no block ciphers whatsoever to choose from. All we can do is generate a 64-bits nonce and postfix 4 zero-bytes. That way the nonce is unique, and while the last 4 bytes are predictable, the nonce as a whole is not and no message ordering information leaks.

  > #### 64/96-bit encrypted nonces {: .info}
  >
  > We have 3DES-encrypted 64/96-bit nonces, which is probably good enough.
  """
  require Logger

  @nononce_epoch ~U[2025-01-01T00:00:00Z] |> DateTime.to_unix(:millisecond)
  @one_day_ms 24 * 60 * 60 * 1000
  @ts_bits 42
  @id_bits 9
  @non_ts_bits_64 64 - @ts_bits
  @machine_id_limit Integer.pow(2, @id_bits) - 1
  @count_bits_64 @non_ts_bits_64 - @id_bits
  @cycle_size_64 Integer.pow(2, min(64, @count_bits_64))
  @count_bits_96 96 - @ts_bits - @id_bits
  @cycle_size_96 Integer.pow(2, min(64, @count_bits_96))
  @padding_bits_128 128 - @ts_bits - @id_bits - 64

  @type nonce_size :: 64 | 96 | 128
  @type nonce :: <<_::64>> | <<_::96>> | <<_::128>>

  @type init_opts :: [epoch: non_neg_integer(), name: atom(), machine_id: non_neg_integer()]

  @doc """
  Initialize a nonce factory. Multiple instances with different names, epochs and even machine IDs are supported.

  ## Options

    * `:machine_id` - machine ID of the node
    * `:name` - The name of the nonce factory (default: module name).
    * `:epoch` - Override the configured epoch for this factory instance. Defaults to the NoNoncense epoch (2025-01-01 00:00:00Z).

  ## Examples

      iex> NoNoncense.init(machine_id: 1)
      :ok

      iex> NoNoncense.init(machine_id: 1, name: :custom, epoch: 1609459200000)
      :ok
  """
  @spec init(init_opts()) :: :ok
  def init(opts \\ []) do
    name = opts[:name] || __MODULE__
    epoch = opts[:epoch] || @nononce_epoch
    machine_id = Keyword.fetch!(opts, :machine_id)

    if machine_id < 0 or machine_id > @machine_id_limit,
      do: raise(ArgumentError, "machine ID out of range 0-#{@machine_id_limit}")

    # the offset of the monotonic clock from the epoch
    time_offset = System.time_offset(:millisecond) - epoch
    init_at = time_from_offset(time_offset)

    timestamp_overflow = Integer.pow(2, @ts_bits)
    if init_at > timestamp_overflow, do: raise(RuntimeError, "timestamp overflow")
    days_until_overflow = div(timestamp_overflow - init_at, @one_day_ms)

    if days_until_overflow <= 365,
      do: Logger.warning("timestamp overflow in #{days_until_overflow} days")

    counters_ref = :atomics.new(2, signed: false)
    # the counter will overflow to 0 on the first nonce generation
    :atomics.put(counters_ref, 1, Integer.pow(2, 64) - 1)
    :atomics.put(counters_ref, 2, init_at)

    state = {machine_id, init_at, time_offset, counters_ref}
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
    {machine_id, init_at, time_offset, counters_ref} = :persistent_term.get(name)

    # we can generate 10B nonce/s for 60 years straight before the unsigned 64-bits int overflows
    # so we don't need to worry about the atomic counter itself overflowing
    atomic_count = :atomics.add_get(counters_ref, 1, 1)

    # # but we do need to worry about the nonce's counter - which may be only 13 bits for a 64-bit nonce - overflowing
    cycle_n = div(atomic_count, @cycle_size_64)
    count = atomic_count - cycle_n * @cycle_size_64

    # the nonce timestamp is actually an init timestamp + cycle counter
    timestamp = init_at + cycle_n

    # with small counters in the nonce, we may need to wait for the monotonic clock to catch up to the nonce timestamp
    # with bigger nonces the counter is so big (>= 2^45) that it can't realistically overtake the timestamp
    wait_until(timestamp, time_offset)

    to_nonce(timestamp, machine_id, count, 64)
  end

  def nonce(name, 96) do
    {machine_id, init_at, _, counters_ref} = :persistent_term.get(name)

    atomic_count = :atomics.add_get(counters_ref, 1, 1)

    cycle_n = div(atomic_count, @cycle_size_96)
    count = atomic_count - cycle_n * @cycle_size_96

    to_nonce(init_at + cycle_n, machine_id, count, 96)
  end

  def nonce(name, 128) do
    {machine_id, init_at, _, counters_ref} = :persistent_term.get(name)

    atomic_count = :atomics.add_get(counters_ref, 1, 1)

    to_nonce(init_at, machine_id, atomic_count, 128)
  end

  @doc """
  Generate a new nonce and encrypt it. This creates an unpredictable but still unique nonce.

      iex> key = :crypto.strong_rand_bytes 24
      <<76, 201, 87, 221, 39, 41, 231, 66, 80, 199, 18, 164, 248, 5, 92, 42, 246, 73,
        151, 198, 51, 190, 81, 82>>
      iex> NoNoncense.encrypted_nonce(64, key)
      <<50, 231, 215, 98, 233, 96, 157, 205>>
      iex> NoNoncense.encrypted_nonce(96, key)
      <<6, 138, 218, 96, 131, 136, 51, 242, 0, 0, 0, 0>>
      iex> key = :crypto.strong_rand_bytes 32
      <<175, 189, 46, 130, 235, 88, 83, 220, 44, 179, 255, 75, 255, 212, 9, 148, 53,
        211, 157, 137, 52, 48, 247, 155, 222, 130, 70, 227, 57, 89, 137, 171>>
      iex> NoNoncense.encrypted_nonce(128, key)
      <<162, 10, 94, 4, 91, 56, 147, 198, 46, 87, 142, 197, 128, 41, 79, 209>>
  """
  @spec encrypted_nonce(atom(), nonce_size(), binary()) :: nonce()
  def encrypted_nonce(name \\ __MODULE__, bit_size, key)

  def encrypted_nonce(name, 64, key = <<_::192>>) do
    nonce = nonce(name, 64)
    # CBC with all-zero IV = ECB can safely be used here because we only encrypt one block
    :crypto.crypto_one_time(:des_ede3_cbc, key, <<0::64>>, nonce, true)
  end

  def encrypted_nonce(name, 96, key = <<_::192>>) do
    <<encrypted_nonce(name, 64, key)::bits, 0::32>>
  end

  def encrypted_nonce(name, 128, key = <<_::256>>) do
    nonce = nonce(name, 128)
    # ECB can safely be used here because we only encrypt one block
    :crypto.crypto_one_time(:aes_256_ecb, key, nonce, true)
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
    {machine_id, _init_at, time_offset, counters_ref} = :persistent_term.get(name)

    ts_counter = :atomics.add_get(counters_ref, 2, 1)
    # 2^22 * 1000 = 4B ops/s is not an attainable generation rate, we can assume no overflow
    <<current_ts::@ts_bits, new_count::@non_ts_bits_64>> = <<ts_counter::64>>

    now = time_from_offset(time_offset)

    # if timestamp has changed since last invocation...
    if now > current_ts do
      # ...reset the counter. Under load, this should be a minority of cases.
      <<new_ts_counter::64>> = <<now::@ts_bits, 0::@non_ts_bits_64>>
      write_result = :atomics.compare_exchange(counters_ref, 2, ts_counter, new_ts_counter)

      case write_result do
        :ok -> to_nonce(now, machine_id, 0, bit_size)
        _ -> sortable_nonce(name, bit_size)
      end
    else
      # larger nonce sizes will not overflow their >= 2^45 bits counters
      if bit_size == 64 and new_count >= @cycle_size_64 do
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
    {_, _init_at, time_offset, _} = :persistent_term.get(name)
    <<timestamp::@ts_bits, _::bits>> = nonce
    epoch = System.time_offset(:millisecond) - time_offset
    timestamp = timestamp + epoch
    DateTime.from_unix!(timestamp, :millisecond)
  end

  ###########
  # Private #
  ###########

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
end
