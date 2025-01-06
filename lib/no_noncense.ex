defmodule NoNoncense do
  @ts_bits 42
  @ts_duration Integer.pow(2, @ts_bits) |> div(365 * 24 * 60 * 60 * 1000)
  @id_bits 9
  @machine_id_limit Integer.pow(2, @id_bits) - 1
  @count_bits_64 64 - @ts_bits - @id_bits
  @cycle_size_64 Integer.pow(2, min(64, @count_bits_64))
  @count_bits_96 96 - @ts_bits - @id_bits
  @cycle_size_96 Integer.pow(2, min(64, @count_bits_96))
  @padding_bits_128 128 - @ts_bits - @id_bits - 64

  @moduledoc """
  Factory to generate nonces (number-only-used-once). These nonces are guaranteed to be unique if:
  - machine IDs are unique for each node (this is enforced by `NoNoncense.MachineId.ConflictGuard`)
  - individual machines maintain a somewhat accurate clock (specifically, the UTC clock has to have progressed between node restarts)

  First #{@ts_bits} bits is a millisecond-precision timestamp of the initialization time (allows for ~#{@ts_duration} years of operation), relative to the NoNoncense epoch (2025-01-01 00:00:00 UTC) by default. Next #{@id_bits} bits is machine ID (allows for #{@machine_id_limit + 1} machines). The remaining bits are a per-machine counter.

  A counter overflow will trigger a timestamp increase by 1ms (the timestamp functions as a cycle counter after initialization). The theoretical maximum sustained rate is 2^counter-bits nonces per millisecond per machine. For 64-bits nonces (with a #{@count_bits_64}-bit counter), that means #{@cycle_size_64} nonces per millisecond per machine. However, even for small nonces, even higher rates are possible if the "timestamp-counter" lags behind the actual time. Benchmarking shows such rates are actually attainable in practice.

  > #### Suitability of plain nonces for encryption {: .warning}
  >
  > The plain nonces produced by `nonce/2` are suitable for cryptography as IVs for block cipher modes that permit use of a counter, like CTR, OFB and GCM, and for streaming ciphers like ChaCha20. However, block cipher modes that require not just unique but also unpredictable IVs, like CBC and CFB, should use `encrypted_nonce/2` (or random IVs).
  >
  > A plain nonce's timestamp bits will leak the node initialization time, the machine ID and the counter, and - with unprobably high-rate 64-bits nonces - the nonce generation timestamp. If that is not acceptable, use `encrypted_nonce/2` instead of the plain nonce functions.

  Inspired by Twitter's Snowflake IDs.

  ## Encrypted / obfuscated nonces

  By encrypting a nonce the timestamp, machine ID and message ordering information leak can be prevented. However, we wish to encrypt in a way that **maintains the uniqueness guarantee** of the plain input nonce. So 2^64 unique inputs should generate 2^64 unique outputs, same for the other sizes.

  Block ciphers only generate unique outputs for inputs of at least their block size (128 bits for most modern ciphers, notably AES). For example, encrypting a 64-bits nonce with AES would produce a unique 128-bits ciphertext, but that ciphertext can't be reduced back to 64-bits without losing the uniqueness property. Sadly, this also holds for the streaming modes of these ciphers, which still use blocks internally to generate the keystream. That means, on the bright side:

  > #### 128-bits encrypted nonces {: .tip}
  >
  > We have "perfect" AES-encrypted 128-bits nonces, each one unique and indistinguishable from random nonces, with no information leakage.

  However, for 64-bits nonces we are limited to block ciphers with 64-bits block sizes. There are only a few of those in OTP's `:crypto` module, namely DES, 3DES and BlowFish. DES is broken and can merely be considered obfuscation at this point. 3DES is less broken but that seems like a matter of time. BlowFish performs atrociously in the OTP implementation (~30 times worse than AES, dropping from ~1.8M ops/s to 60K ops/s) to the point where it can form a bottleneck. To pick a poison, 3DES seems like the least worst.

  For 96-bits nonces there are no block ciphers whatsoever to choose from. The best we can do while maintaining uniqueness is use a 64-bits cipher for the first 64-bits (hiding the timestamp) but leave the remaining 32 bits of the counter unencrypted and leaking info.

  Ciphers that use 96-bits IVs (ChaCha20, GCM-mode block cipher) pre- or postfix an all-zero block counter. That provides an alternative where we use a 64-bits encrypted nonce with an all-zero 64-bits counter (for example, for ChaCha20, prefix 64 zero bits to a 64-bits nonce). That way, the *message* counter part of the nonce is at least encrypted.

  > #### 64/96-bits encrypted nonces {: .error}
  >
  > If you really can't tolerate **any** information leakage trough the nonce, you should not use encrypted nonces of 64 or 96 bits because they can't be encrypted securely. They should be considered as merely obfuscated.

  Naturally, if you *can* tolerate that information leaking, you might as well use plain unencrypted nonces.

  Finally, some [IETF wisdom](https://datatracker.ietf.org/doc/html/rfc8439#section-4) on this topic with regards to ChaCha20/Poly1305 nonces:
  > Counters and LFSRs are both acceptable ways of generating unique nonces, as is encrypting a counter using a block cipher with a 64-bit block size such as DES. Note that it is not acceptable to use a truncation of a counter encrypted with block ciphers with 128-bit or 256-bit blocks, because such a truncation may repeat after a short time.
  """
  require Logger

  @epoch ~U[2025-01-01T00:00:00Z] |> DateTime.to_unix(:millisecond)

  @type nonce_size :: 64 | 96 | 128
  @type nonce :: <<_::64>> | <<_::96>> | <<_::128>>

  @type init_opts :: [epoch: non_neg_integer(), name: atom()]

  @doc """
  Initializes the nonce factory with the given options.

  ## Options

    * `:machine_id` - machine ID of the node
    * `:name` - The name of the nonce factory (default: module name).
    * `:epoch` - Override the configured epoch for this factory instance. Defaults to the NoNoncense epoch (2025-01-01 00:00:00Z).

  ## Examples

      iex> NoNoncense.init()
      :ok

      iex> NoNoncense.init(name: :custom, epoch: 1609459200000)
      :ok
  """
  @spec init(init_opts()) :: :ok
  def init(opts \\ []) do
    name = opts[:name] || __MODULE__
    epoch = opts[:epoch] || @epoch
    machine_id = Keyword.fetch!(opts, :machine_id)

    if machine_id < 0 or machine_id > @machine_id_limit,
      do: raise("machine ID out of range 0-#{@machine_id_limit}")

    # the offset of the monotonic clock from the epoch
    time_offset = System.time_offset(:millisecond) - epoch
    init_at = time_from_offset(time_offset)

    timestamp_overflow = Integer.pow(2, @ts_bits)
    if init_at > timestamp_overflow, do: raise("timestamp overlow")
    days_until_overflow = div(timestamp_overflow - init_at, 24 * 60 * 60 * 1000)

    if days_until_overflow <= 365,
      do: Logger.warning("timestamp overflow in #{days_until_overflow} days")

    counter_ref = :atomics.new(1, signed: false)
    # the counter will overflow to 0 on the first nonce generation
    :atomics.put(counter_ref, 1, Integer.pow(2, 64) - 1)

    state = {machine_id, init_at, time_offset, counter_ref}
    :ok = :persistent_term.put(name, state)
  end

  @doc """
  Generate a new 64/96/128-bits nonce.

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
    {machine_id, init_at, time_offset, counter_ref} = :persistent_term.get(name)

    # we can generate 10B nonce/s for 60 years straight before the unsigned 64-bits int overflows
    # so we don't need to worry about the atomic counter itself overflowing
    atomic_count = :atomics.add_get(counter_ref, 1, 1)

    # # but we do need to worry about the nonce's counter - which may be only 13 bits for a 64-bit nonce - overflowing
    cycle_n = div(atomic_count, @cycle_size_64)
    count = atomic_count - cycle_n * @cycle_size_64

    # the nonce timestamp is actually an init timestamp + cycle counter
    timestamp = init_at + cycle_n

    # with small counters in the nonce, we may need to wait for the monotonic clock to catch up to the nonce timestamp
    # with 96-bits nonces, the counter is 45 bits, meaning we can generate 2^45 IVs per ms before the counter overflows
    wait_until(timestamp, time_offset)

    <<timestamp::@ts_bits, machine_id::@id_bits, count::@count_bits_64>>
  end

  def nonce(name, 96) do
    {machine_id, init_at, _, counter_ref} = :persistent_term.get(name)

    atomic_count = :atomics.add_get(counter_ref, 1, 1)

    cycle_n = div(atomic_count, @cycle_size_96)
    count = atomic_count - cycle_n * @cycle_size_96

    timestamp = init_at + cycle_n

    <<timestamp::@ts_bits, machine_id::@id_bits, count::@count_bits_96>>
  end

  def nonce(name, 128) do
    {machine_id, init_at, _, counter_ref} = :persistent_term.get(name)

    atomic_count = :atomics.add_get(counter_ref, 1, 1)

    <<init_at::@ts_bits, machine_id::@id_bits, 0::@padding_bits_128, atomic_count::64>>
  end

  @doc """
  Generate a new nonce and encrypt it. This creates an unpredictable but still unique nonce.

  > #### 64/96 bits caveats {: .warning}
  >
  > Be sure to read the docs of `NoNoncense` for important caveats before deciding to use 64/96-bits encypted nonces.
  """
  @spec encrypted_nonce(atom(), binary(), nonce_size()) :: nonce()
  def encrypted_nonce(name \\ __MODULE__, key, size)

  def encrypted_nonce(name, key, 64) do
    nonce = nonce(name, 64)
    # CBC with all-zero IV = ECB can safely be used here because we only encrypt one block
    :crypto.crypto_one_time(:des_ede3_cbc, key, <<0::64>>, nonce, true)
  end

  # this is *not* unpredictable, because of the counter use
  def encrypted_nonce(name, key, 96) do
    <<part0::bits-64, part1::bits-32>> = nonce(name, 96)
    part0_enc = :crypto.crypto_one_time(:des_ede3_cbc, key, <<0::64>>, part0, true)
    <<part0_enc::bits-64, part1::bits-32>>
  end

  def encrypted_nonce(name, key, 128) do
    nonce = nonce(name, 128)
    # ECB can safely be used here because we only encrypt one block
    :crypto.crypto_one_time(:aes_256_ecb, key, nonce, true)
  end

  ###########
  # Private #
  ###########

  defp wait_until(timestamp, time_offset) do
    now = time_from_offset(time_offset)
    if timestamp > now, do: :timer.sleep(timestamp - now)
  end

  defp time_from_offset(time_offset), do: System.monotonic_time(:millisecond) + time_offset
end
