# NoNoncense

Generate locally unique nonces (number-only-used-once) in distributed Elixir.

Nonces come in multiple varians:

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

Then you can generate plain and encrypted nonces.

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

nonce(128) single:             54_981_091 ops/s
nonce(96) single:              44_348_625 ops/s
nonce(128) multi:              37_745_241 ops/s
nonce(64) multi:               37_617_656 ops/s
nonce(96) multi:               37_552_652 ops/s
sortable_nonce(96) multi:      35_124_078 ops/s
sortable_nonce(128) multi:     34_819_544 ops/s
nonce(64) single:              25_847_171 ops/s
sortable_nonce(128) single:    21_776_095 ops/s
sortable_nonce(96) single:     21_016_157 ops/s
encrypted_nonce(128) multi:    13_485_052 ops/s
encrypted_nonce(64) multi:     11_049_795 ops/s
encrypted_nonce(96) multi:     10_438_713 ops/s
sortable_nonce(64) multi:       8_192_779 ops/s
sortable_nonce(64) single:      8_191_835 ops/s
strong_rand_bytes(8) multi:     4_859_998 ops/s
strong_rand_bytes(12) multi:    4_856_265 ops/s
strong_rand_bytes(16) multi:    4_807_786 ops/s
strong_rand_bytes(8) single:    2_731_625 ops/s
strong_rand_bytes(12) single:   2_723_526 ops/s
strong_rand_bytes(16) single:   2_723_058 ops/s
encrypted_nonce(128) single:    2_446_565 ops/s
encrypted_nonce(64) single:     1_209_200 ops/s
encrypted_nonce(96) single:     1_118_734 ops/s
```

Some things of note:

- NoNoncense nonces generate much faster than random binaries.
- All methods are quick enough to handle very high peak loads.
- The plain nonce generation rate is hardly influenced by multithreading and seems to hit a bottleneck of some kind, probably to do with `:persistent_term` or `:atomics`. Still, it hits a really high rate.
- Encrypting the nonce exacts a very hefty penalty, but parallellization scales well to alleviate the issue.
- Triple DES sucks.
