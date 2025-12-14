# NoNoncense

Generate locally unique nonces (number-only-used-once) in distributed Elixir.

Nonces are unique values that are generated once and never repeated within your system. They have many practical uses including:

- **ID Generation**: Create unique identifiers for database records, API requests, or any other resource in distributed systems
- **Cryptographic Operations**: Serve as initialization vectors (IVs) for encryption algorithms, ensuring security in block cipher modes
- **Deduplication**: Identify and prevent duplicate operations or messages in distributed systems

Nonces come in multiple variants:

- counter nonces that are unique but predictable and can be generated incredibly quickly
- sortable nonces ([Snowflake IDs](https://en.wikipedia.org/wiki/Snowflake_ID)) that have an accurate creation timestamp in their first bits
- encrypted nonces that are unique but unpredictable

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
    # grab your node_list from your application environment
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
iex> <<_::64>> = NoNoncense.encrypted_nonce(64, :crypto.strong_rand_bytes(24))
iex> <<_::96>> = NoNoncense.encrypted_nonce(96, :crypto.strong_rand_bytes(24))
iex> <<_::128>> = NoNoncense.encrypted_nonce(128, :crypto.strong_rand_bytes(32))
```

## Benchmarks

```
On Debian Bookworm, AMD 9700X (8C 16T), 32GB, 990 Pro.

nonce(128)                4 tasks      71_480_221 ops/s
nonce(96)                 4 tasks      71_026_121 ops/s
nonce(64)                 4 tasks      65_193_581 ops/s
sortable_nonce(128)       4 tasks      64_257_168 ops/s
sortable_nonce(96)        4 tasks      62_381_363 ops/s
nonce(128)                1 task       59_963_750 ops/s
nonce(96)                 1 task       45_250_223 ops/s
nonce(128)               16 tasks      38_430_576 ops/s <- contention?
nonce(96)                16 tasks      38_009_613 ops/s <- contention?
nonce(64)                16 tasks      37_882_988 ops/s <- contention?
sortable_nonce(96)       16 tasks      35_498_696 ops/s <- contention?
sortable_nonce(128)      16 tasks      35_017_229 ops/s <- contention?
nonce(64)                 1 task       24_068_163 ops/s
sortable_nonce(128)       1 task       22_222_475 ops/s
sortable_nonce(96)        1 task       20_848_971 ops/s
encrypted_nonce(128)     16 tasks      16_528_379 ops/s
encrypted_nonce(64)      16 tasks       9_833_709 ops/s
encrypted_nonce(96)      16 tasks       9_347_739 ops/s
encrypted_nonce(128)      4 tasks       8_390_814 ops/s
sortable_nonce(64)       16 tasks       8_192_220 ops/s <- throttled
sortable_nonce(64)        1 task        8_191_842 ops/s <- throttled
sortable_nonce(64)        4 tasks       8_192_027 ops/s <- throttled
strong_rand_bytes(16)     4 tasks       7_118_412 ops/s
strong_rand_bytes(8)      4 tasks       7_109_144 ops/s
strong_rand_bytes(12)     4 tasks       7_037_436 ops/s
encrypted_nonce(64)       4 tasks       4_394_582 ops/s
encrypted_nonce(96)       4 tasks       4_053_274 ops/s
strong_rand_bytes(8)      1 task        2_725_915 ops/s
strong_rand_bytes(16)     1 task        2_705_110 ops/s
strong_rand_bytes(12)     1 task        2_666_742 ops/s
encrypted_nonce(128)      1 task        2_388_358 ops/s
encrypted_nonce(64)       1 task        1_216_054 ops/s
encrypted_nonce(96)       1 task        1_127_631 ops/s
```

Some things of note:

- NoNoncense nonces generate much faster than random binaries (and guarantee uniqueness).
- The plain (counter) nonce generation rate is extremely high, even with a single thread. Multithreading improves performance mainly for 64-bits nonces.
- Increasing the thread count starts to reduce plaintext nonce performance at some point (it's better to scale the number of nodes). Generation rates seem to hit a bottleneck of some kind, probably to do with `:atomics` contention.
- Encrypting the nonce exacts a very hefty performance penalty, but parallellization scales well to alleviate the issue. Although to hit rates of 16M ops/s, the machine can't do anything other than generate nonces, which is probably not ideal. For scenarios where a less ridiculous generation rate is required (almost all real-world scenarios), this will not be an issue.
- 3DES (64/96-bits encrypted nonces) scales much worse than AES (128-bits encrypted nonces).
