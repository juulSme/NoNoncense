# Migration Guide

## Upgrading to v2.0.0

Version 2.0.0 introduces a supervised machine ID API. `NoNoncense.MachineId` no longer
calculates a static ID with `id!/1`; it is now a supervisor that acquires a machine ID and
initializes one or more `NoNoncense` instances.

### Replace manual machine ID initialization

Before v2, applications typically calculated a machine ID during startup and passed it to
`NoNoncense.init/1` themselves:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    machine_id = NoNoncense.MachineId.id!(node_list: [:"myapp@127.0.0.1"])
    :ok = NoNoncense.init(machine_id: machine_id, base_key: System.fetch_env!("BASE_KEY"))

    Supervisor.start_link([], strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

In v2, add `NoNoncense.MachineId` to your supervision tree. It blocks application startup
until it has acquired an ID, then initializes the nonce factories in `:instances`:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {NoNoncense.MachineId,
       strategy: NoNoncense.MachineId.Strategy.SqlLease,
       strategy_opts: [repo: MyApp.Repo],
       instances: [[base_key: System.fetch_env!("BASE_KEY")]]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

See the `NoNoncense.MachineId` module documentation for the available machine ID strategies
and their configuration options.

If you prefer to keep the old host-identifiers based behavior,
you can use `NoNoncense.MachineId.Strategy.HostIdentifiers` and pass your node list to its opts.

> #### Bring down all nodes when switching strategies {: .warning}
>
> When switching strategies, a rolling restart can temporarily run old nodes that are unmanaged by the new strategy.
> During that window, machine ID conflicts are possible. Stop all nodes before deploying the new strategy.

## Upgrading to v1.0.0

Version 1.0.0 introduces breaking changes to the encrypted nonce API. This guide will help you migrate your application safely.

### Overview of Changes

1. Encryption keys moved from `encrypted_nonce/2` to `NoNoncense.init/1`
2. Default encryption algorithm changed from 3DES to Blowfish (64/96-bit nonces)
3. New `encrypted_nonce/2` signature: `encrypted_nonce(name \\ __MODULE__, bit_size)`

> #### Critical: Preserving Uniqueness Guarantees {: .warning}
>
> If you are using 0.x.x encrypted nonces in production, you **MUST**:
>
> - pass your old encryption key(s) to `NoNoncense.init/1` using the `:key64`, `:key96` and `:key128` opts
> - (when using encrypted 64 and/or 96-bit nonces) pass algorithm `:des3` to `NoNoncense.init/1` using the `:cipher64` and `:cipher96` opts
>
> If you don't, you will **break the uniqueness guarantee** of your nonces, potentially causing collisions in your database or application.

#### Before (v0.x)

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    machine_id = NoNoncense.MachineId.id!(node_list: [:"myapp@127.0.0.1"])
    :ok = NoNoncense.init(machine_id: machine_id)

    # ... supervisor setup
  end
end

# Elsewhere in your code:
key64 = :crypto.strong_rand_bytes(24)  # 3DES key
nonce = NoNoncense.encrypted_nonce(64, key64)
```

#### After (v1.0) - preserving 3DES

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    machine_id = NoNoncense.MachineId.id!(node_list: [:"myapp@127.0.0.1"])

    :ok = NoNoncense.init(
      machine_id: machine_id,
      key64: System.fetch_env!("NONCE_KEY_64"), # Your existing 192-bit 3DES key,
      key96: System.fetch_env!("NONCE_KEY_96"), # Your existing 192-bit 3DES key,
      cipher64: :des3,                          # MUST specify to prevent default change
      cipher96: :des3                           # MUST specify to prevent default change
    )

    # ... supervisor setup
  end
end

# Elsewhere in your code:
nonce = NoNoncense.encrypted_nonce(64)  # Key comes from init
```
