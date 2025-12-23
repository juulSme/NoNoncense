# NoNoncense

Generate locally unique nonces (number-only-used-once) in distributed Elixir.

Nonces are unique values that are generated once and never repeated within your system. They have many practical uses including:

- **ID Generation**: Create unique identifiers for database records, API requests, or any other resource in distributed systems
- **Cryptographic Operations**: Serve as initialization vectors (IVs) for encryption algorithms, ensuring security in block cipher modes
- **Deduplication**: Identify and prevent duplicate operations or messages in distributed systems

Generate locally unique nonces (number-only-used-once) in distributed Elixir. Nonces come in multiple variants:

- counter nonces that are unique but predictable and can be generated incredibly quickly
- sortable nonces ([Snowflake IDs](https://en.wikipedia.org/wiki/Snowflake_ID)) that have an accurate creation timestamp in their first bits
- encrypted nonces that are unique but unpredictable

> #### Read the migration guide
>
> If you're upgrading from v0.x.x and you use encrypted nonces, please read the [Migration Guide](MIGRATION.md) carefully - there are breaking changes that require attention to preserve uniqueness guarantees.

## Installation

The package is hosted on [hex.pm](https://hex.pm/packages/no_noncense) and can be installed by adding `:no_noncense` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:no_noncense, "~> 1.0"}
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
    # grab your node_list from your application environment
    machine_id = NoNoncense.MachineId.id!(node_list: [:"myapp@127.0.0.1"])
    # base_key is required for encrypted nonces
    :ok = NoNoncense.init(machine_id: machine_id, base_key: :crypto.strong_rand_bytes(32))

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

Then you can generate nonces.

```elixir
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
```

## Benchmarks

```
On Debian Bookworm, AMD 9700X (8C 16T), 32GB, 990 Pro.

nonce(128)                       4 tasks    67_479_380 ops/s
nonce(128)                      16 tasks    66_651_927 ops/s
nonce(96)                       16 tasks    65_672_432 ops/s
nonce(64)                       16 tasks    65_424_996 ops/s
nonce(128)                       1 task     65_238_805 ops/s
nonce(96)                        4 tasks    64_420_798 ops/s
sortable_nonce(128)              4 tasks    60_862_312 ops/s
nonce(64)                        4 tasks    60_386_514 ops/s
sortable_nonce(96)               4 tasks    60_149_950 ops/s
encrypted_nonce(128) AES        16 tasks    57_043_233 ops/s
sortable_nonce(96)              16 tasks    55_579_818 ops/s
sortable_nonce(128)             16 tasks    54_993_955 ops/s
nonce(96)                        1 task     50_140_765 ops/s
encrypted_nonce(64) Blowfish    16 tasks    45_025_885 ops/s
encrypted_nonce(96) Speck       16 tasks    37_038_782 ops/s
encrypted_nonce(96) Blowfish    16 tasks    34_539_194 ops/s
encrypted_nonce(64) Speck       16 tasks    28_533_885 ops/s
encrypted_nonce(128) AES         4 tasks    28_425_854 ops/s
nonce(64)                        1 task     24_389_379 ops/s
sortable_nonce(128)              1 task     21_627_212 ops/s
encrypted_nonce(96) Speck        4 tasks    20_922_439 ops/s
sortable_nonce(96)               1 task     20_838_522 ops/s
encrypted_nonce(64) Speck        4 tasks    19_996_064 ops/s
encrypted_nonce(64) Blowfish     4 tasks    19_426_322 ops/s
encrypted_nonce(96) Blowfish     4 tasks    14_555_706 ops/s
encrypted_nonce(64) 3DES        16 tasks    10_016_360 ops/s
encrypted_nonce(96) 3DES        16 tasks     9_535_425 ops/s
encrypted_nonce(128) AES         1 task      8_918_276 ops/s
sortable_nonce(64)               4 tasks     8_192_138 ops/s <- throttled
sortable_nonce(64)               1 task      8_191_866 ops/s <- throttled
sortable_nonce(64)              16 tasks     7_973_708 ops/s <- throttled
strong_rand_bytes(8)             4 tasks     7_452_613 ops/s
strong_rand_bytes(16)            4 tasks     7_408_921 ops/s
strong_rand_bytes(12)            4 tasks     7_396_600 ops/s
encrypted_nonce(96) Speck        1 task      7_117_386 ops/s
encrypted_nonce(64) Speck        1 task      6_859_774 ops/s
encrypted_nonce(64) Blowfish     1 task      5_714_196 ops/s
strong_rand_bytes(12)           16 tasks     4_776_713 ops/s
strong_rand_bytes(8)            16 tasks     4_770_078 ops/s
strong_rand_bytes(16)           16 tasks     4_762_500 ops/s
encrypted_nonce(96) Blowfish     1 task      4_603_991 ops/s
encrypted_nonce(64) 3DES         4 tasks     4_263_336 ops/s
encrypted_nonce(96) 3DES         4 tasks     4_058_711 ops/s
strong_rand_bytes(16)            1 task      2_830_500 ops/s
strong_rand_bytes(8)             1 task      2_780_367 ops/s
strong_rand_bytes(12)            1 task      2_745_915 ops/s
encrypted_nonce(64) 3DES         1 task      1_194_550 ops/s
encrypted_nonce(96) 3DES         1 task      1_130_135 ops/s
```

Some things of note:

- NoNoncense nonces generate much faster than random binaries (and guarantee uniqueness).
- The plain (counter) nonce generation rate is extremely high, even with a single thread. Multithreading improves performance mainly for 64-bits nonces.
- Increasing the thread count starts to reduce plaintext nonce performance at some point (it's better to scale the number of nodes). Generation rates seem to hit a bottleneck of some kind, probably to do with `:atomics` contention. 4 tasks seem to be optimal with plaintext nonces on this platform.
- Nonce encryption exacts a performance penalty, but it is manageable and scales well with cores. AES performs exceedingly well and there's really no reason to use anything else for 128-bits nonces except on platforms without hardware acceleration. For 64/96-bits nonces, Blowfish is a good default that is available in OTP. For 96-bits nonces, Speck offers best security and performance. See the [NoNoncense](https://hexdocs.pm/no_noncense/NoNoncense.html#module-nonce-encryption) docs for more info.
- 3DES performs atrociously in comparison
