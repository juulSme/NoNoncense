# NoNoncense

Generate locally unique nonces (number-only-used-once) in distributed Elixir.

Nonces are unique values that are generated once and never repeated within your system. They have many practical uses including:

- **ID Generation**: Create unique identifiers for database records, API requests, or any other resource in distributed systems. If this is your use case, have a look at [Once](https://github.com/juulSme/Once).
- **Cryptographic Operations**: Serve as initialization vectors (IVs) for encryption algorithms, ensuring security in block cipher modes
- **Deduplication**: Identify and prevent duplicate operations or messages in distributed systems

Nonces come in multiple variants:

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
    {:no_noncense, "~> 2.0"}
  ]
end
```

## Docs

Documentation can be found on [hexdocs.pm](https://hexdocs.pm/no_noncense/).

## Usage

Add `NoNoncense.MachineId` to your supervision tree. It acquires and renews a unique machine ID through a pluggable strategy and initializes your `NoNoncense` instances automatically. Startup blocks until the initial lease is acquired.

For example, with [`SqlLease`](https://hexdocs.pm/no_noncense/NoNoncense.MachineId.Strategy.SqlLease.html) (after running its migration):

```elixir
children = [
  MyApp.Repo,
  {NoNoncense.MachineId,
   strategy: NoNoncense.MachineId.Strategy.SqlLease,
   strategy_opts: [repo: MyApp.Repo],
   instances: [[base_key: System.fetch_env!("BASE_KEY")]]}
]
Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

See each strategy's module documentation for all configuration options.

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

### Telemetry

When the optional `:telemetry` dependency is available, NoNoncense emits events for machine ID
lease acquisition, renewal, retries, loss, release, and conflict detection. Nonce generation is
not instrumented. See [`NoNoncense.Telemetry`](https://hexdocs.pm/no_noncense/NoNoncense.Telemetry.html)
for the event names, measurements, and metadata.

## Benchmarks

```
On Debian Bookworm, AMD 9700X (8C 16T), 32GB, 990 Pro.

nonce(128)                       1 task     65_238_805 ops/s
nonce(96)                        1 task     50_140_765 ops/s
nonce(64)                        1 task     24_389_379 ops/s
sortable_nonce(128)              1 task     21_627_212 ops/s
sortable_nonce(96)               1 task     20_838_522 ops/s
encrypted_nonce(128) AES         1 task      8_918_276 ops/s
sortable_nonce(64)               1 task      8_191_866 ops/s <- throttled
encrypted_nonce(96) Speck        1 task      7_117_386 ops/s
encrypted_nonce(64) Speck        1 task      6_859_774 ops/s
encrypted_nonce(64) Blowfish     1 task      5_714_196 ops/s
encrypted_nonce(96) Blowfish     1 task      4_603_991 ops/s
strong_rand_bytes(16)            1 task      2_830_500 ops/s
encrypted_nonce(64) 3DES         1 task      1_194_550 ops/s
encrypted_nonce(96) 3DES         1 task      1_130_135 ops/s

nonce(128)                       4 tasks    67_479_380 ops/s
nonce(96)                        4 tasks    64_420_798 ops/s
sortable_nonce(128)              4 tasks    60_862_312 ops/s
nonce(64)                        4 tasks    60_386_514 ops/s
sortable_nonce(96)               4 tasks    60_149_950 ops/s
encrypted_nonce(128) AES         4 tasks    28_425_854 ops/s
encrypted_nonce(96) Speck        4 tasks    20_922_439 ops/s
encrypted_nonce(64) Speck        4 tasks    19_996_064 ops/s
encrypted_nonce(64) Blowfish     4 tasks    19_426_322 ops/s
encrypted_nonce(96) Blowfish     4 tasks    14_555_706 ops/s
sortable_nonce(64)               4 tasks     8_192_138 ops/s <- throttled
strong_rand_bytes(16)            4 tasks     7_408_921 ops/s
encrypted_nonce(64) 3DES         4 tasks     4_263_336 ops/s
encrypted_nonce(96) 3DES         4 tasks     4_058_711 ops/s

nonce(128)                      16 tasks    66_651_927 ops/s
encrypted_nonce(128) AES        16 tasks    57_043_233 ops/s
sortable_nonce(96)              16 tasks    55_579_818 ops/s
encrypted_nonce(64) Blowfish    16 tasks    45_025_885 ops/s
encrypted_nonce(64) Speck       16 tasks    28_533_885 ops/s
encrypted_nonce(64) 3DES        16 tasks    10_016_360 ops/s
```

Some things of note:

- NoNoncense nonces generate much faster than random binaries (and guarantee uniqueness).
- The plain (counter) nonce generation rate is extremely high, even with a single thread. Multithreading improves performance mainly for 64-bit nonces and encrypted nonces.
- Plaintext nonce generation rates don't scale beyond 4 cores, increasing the node count would be better.
- Nonce encryption exacts a performance penalty, but it is manageable and scales well with cores.
- 3DES performs atrociously compared to other cipher options.

## Compatibility

Elixir 1.18+ and OTP 27+ are fully supported and tested in CI.

Elixir 1.16–1.17 (with OTP 25+) are supported on a best-effort basis and tested in CI. Issues will be considered but may not be fixed if they require significant workarounds.

Older versions are not supported.
