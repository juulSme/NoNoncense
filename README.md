# NoNoncense

Generate globally unique nonces (number-only-used-once) in distributed Elixir.

The nonces are guaranteed to be unique if:

- machine IDs are unique for each node (`NoNoncense.MachineId.ConflictGuard` can help there)
- individual machines maintain a somewhat accurate clock (specifically, the UTC clock has to have progressed between node restarts)

## Installation

The package is hosted on [hex.pm](https://hex.pm/packages/no_noncense) and can be installed by adding `:no_noncense` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:no_noncense, "~> 0.0.1"}
  ]
end
```

## Docs

Documentation can be found on [hexdocs.pm](https://hexdocs.pm/no_noncense/).

## Usage

Note that `NoNoncense` is not a GenServer. Instead, it stores its initial state using `m::persistent_term` and its internal counter using `m::atomics`. Because `m::persistent_term` triggers a garbage collection cycle on writes, it is recommended to initialize your `NoNoncense` instance(s) at application start, when there is hardly any garbage to collect.

```elixir
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
```

Then you can generate plain and encrypted nonces.

```elixir
# generate nonces
iex> <<_::64>> = NoNoncense.nonce(64)
iex> <<_::96>> = NoNoncense.nonce(96)
iex> <<_::128>> = NoNoncense.nonce(128)

# generate encrypted nonces
iex> <<_::64>> = NoNoncense.encrypted_nonce(64, :crypto.strong_rand_bytes(24))
iex> <<_::96>> = NoNoncense.encrypted_nonce(96, :crypto.strong_rand_bytes(24))
iex> <<_::128>> = NoNoncense.encrypted_nonce(128, :crypto.strong_rand_bytes(32))
```

## How it works

The first 42 bits are a millisecond-precision timestamp of the initialization time (allows for ~139 years of operation), relative to the NoNoncense epoch (2025-01-01 00:00:00 UTC) by default. The next 9 bits are the machine ID (allows for 512 machines). The remaining bits are a per-machine counter.

A counter overflow will trigger a timestamp increase by 1ms (the timestamp effectively functions as a cycle counter after initialization). The theoretical maximum sustained rate is 2^counter-bits nonces per millisecond per machine. For 64-bit nonces (with a 13-bit counter), that means 8192 nonces per millisecond per machine. Because the timestamp can't exceed the actual time (that would break the uniqueness guarantee), new nonce generation throttles if the nonce timestamp/counter catches up to the actual time. In practice, that will probably never happen, and nonces will be generated at a higher rate. For example, if the first nonce is generated 10 seconds after initialization, 10K milliseconds have been "saved up" to generate 80M 64-bit nonces at virtually unlimited rate. Benchmarking shows rates around 20M/s are attainable.

The design is inspired by Twitter's Snowflake IDs, although there are some differences, most notably in the timestamp which is _not_ a message timestamp. Unlike Snowflake IDs, nonces are meant to be opaque, and not used for sorting.

> #### Suitability of plain nonces for cryptography {: .warning}
>
> The plain nonces produced by `nonce/2` are technically suitable for cryptography as IVs for block cipher modes that permit use of a counter, like CTR, OFB, CCM, and GCM, and for streaming ciphers like ChaCha20. However, block cipher modes that require not just unique but also unpredictable IVs, like CBC and CFB, should use `encrypted_nonce/2` (or random IVs).
>
> A plain nonce's timestamp bits will leak the node initialization time, the machine ID, and the counter, and - with improbably high-rate 64-bit nonces - the nonce generation timestamp. If that is not acceptable, use `encrypted_nonce/2` instead of the plain nonce functions.

## Encrypted / obfuscated nonces

By encrypting a nonce, the timestamp, machine ID, and message ordering information leak can be prevented. However, we wish to encrypt in a way that **maintains the uniqueness guarantee** of the plain input nonce. So 2^64 unique inputs should generate 2^64 unique outputs, same for the other sizes.

IETF has some [wisdom to share](https://datatracker.ietf.org/doc/html/rfc8439#section-4) on the topic of nonce encryption (in the context of ChaCha20 / Poly1305 nonces):

> Counters and LFSRs are both acceptable ways of generating unique nonces, as is encrypting a counter using a block cipher with a 64-bit block size such as DES. Note that it is not acceptable to use a truncation of a counter encrypted with block ciphers with 128-bit or 256-bit blocks, because such a truncation may repeat after a short time.

There are some interesting things to unpick there. Why can't we use higher ciphers with a larger block size? As it turns out, block ciphers only generate unique outputs for inputs of at least their block size (128 bits for most modern ciphers, notably AES). For example, encrypting a 64-bit nonce with AES would produce a unique 128-bit ciphertext, but that ciphertext can't be reduced back to 64 bits without losing the uniqueness property. Sadly, this also holds for the streaming modes of these ciphers, which still use blocks internally to generate the keystream. That means, on the bright side:

> #### 128-bit encrypted nonces {: .tip}
>
> We have "perfect" AES256-encrypted 128-bit nonces, each one unique and indistinguishable from random nonces, with no information leakage.

However, for 64-bit nonces we are limited to block ciphers with 64-bit block sizes. There are only a few of those in OTP's `m::crypto` module, namely DES, 3DES, and BlowFish. DES is broken and can merely be considered obfuscation at this point, despite the IETF quote (from 2018). 3DES is less broken but that seems like a matter of time. BlowFish performs atrociously in the OTP implementation (~30 times worse than AES, dropping from ~1.8M ops/s to 60K ops/s) to the point where it can realistically form a bottleneck. To pick a poison, 3DES seems like the least worst.

For 96-bit nonces there are no block ciphers whatsoever to choose from. The best we can do while maintaining uniqueness is use a 64-bit cipher for the first 64 bits (hiding the timestamp) but leave the remaining 32 bits of the counter unencrypted and leaking info.

There is an alternative. Ciphers that use 96-bit IVs (ChaCha20, GCM-mode block cipher) pre- or postfix an all-zero block counter. That means we can use a 64-bit encrypted nonce with an all-zero 64-bit counter (for example, for ChaCha20, prefix 64 zero bits to a 64-bit nonce). That way, at least the _message_ counter part of the nonce is encrypted (and the block counter is not part of the nonce that is attached to the message).

> #### 64/96-bit encrypted nonces {: .error}
>
> If you really can't tolerate **any** information leakage through the nonce, you should not use encrypted nonces of 64 or 96 bits because they can't be encrypted securely. They should be considered as merely obfuscated.

Naturally, if you _can_ tolerate that information leaking, you might as well use plain unencrypted nonces.

## Benchmarks

```
On Debian Bookworm, AMD 9700X (8C 16T), 32GB, 990 Pro, generating 100M nonces

NoNonce.nonce(64) single                   22_306_381 ops/s
NoNonce.nonce(96) single                   40_686_097 ops/s
NoNonce.nonce(128) single                  41_549_756 ops/s
NoNonce.encrypted_nonce(64) single          1_205_063 ops/s
NoNonce.encrypted_nonce(96) single          1_140_176 ops/s
NoNonce.encrypted_nonce(128) single         2_421_775 ops/s
:crypto.strong_rand_bytes(8) single         2_650_561 ops/s
:crypto.strong_rand_bytes(12) single        2_660_745 ops/s
:crypto.strong_rand_bytes(126) single       2_654_720 ops/s
NoNonce.nonce(64) multi                    39_031_122 ops/s
NoNonce.nonce(96) multi                    38_306_529 ops/s
NoNonce.nonce(128) multi                   39_012_560 ops/s
NoNonce.encrypted_nonce(64) multi          10_033_706 ops/s
NoNonce.encrypted_nonce(96) multi           9_584_873 ops/s
NoNonce.encrypted_nonce(128) multi         13_515_584 ops/s
:crypto.strong_rand_bytes(8) multi          4_751_390 ops/s
:crypto.strong_rand_bytes(12) multi         4_766_312 ops/s
:crypto.strong_rand_bytes(126) multi        4_749_853 ops/s
```

Some things of note:

- NoNoncense wins! :p
- All methods are quick enough to handle very high peak loads.
- The plain nonce generation rate is hardly influenced by multithreading and seems to hit a bottleneck of some kind, probably to do with `:persistent_term` or `:atomics`. Still, it hits a really high rate and is almost as quick as calling a plain getter.
- Encrypting the nonce exacts a very hefty penalty, but parallellization scales well to alleviate the issue.
- Triple DES sucks.
