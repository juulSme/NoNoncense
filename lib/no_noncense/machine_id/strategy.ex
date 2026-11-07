defmodule NoNoncense.MachineId.Strategy do
  @moduledoc """
  Behaviour for pluggable machine ID strategies used by `NoNoncense.MachineId`.

  A strategy derives a deterministic machine ID from the node's environment or leases an ID
  (`0..511`) from an external coordinator.

  ## Static vs. dynamic strategies

  `use NoNoncense.MachineId.Strategy` provides defaults for static strategies:

    * `renew/3` succeeds immediately with the requested `lease_duration`.
    * `release/2` is a no-op.
    * `deterministic?/0` returns `true`, preventing reacquisition after a lease loss.

  Coordinating strategies must implement all four callbacks and return `false` from
  `deterministic?/0`. This callback runs in the manager and should return promptly.

  ## Lease contract

  `acquire/2` returns `{:ok, machine_id, lease, ttl_ms}`, where `lease` is an opaque term passed
  to `renew/3` and `release/2`. For coordinating strategies, it must identify the specific
  acquisition (for example, `{machine_id, random_token}`). Renew and release must only act while
  that acquisition still owns the ID; releasing a stale lease must be a no-op.

  The granted `ttl_ms` may differ from the requested `lease_duration`, but must be at least
  `30_000` ms. The backend lease must remain valid for at least that long from the start of the
  acquire or renew callback.

  Return `{:error, :lost, reason}` from `renew/3` when ownership is definitely lost, or
  `{:error, :retry, reason}` for a transient or ambiguous failure. Calls can time out after
  committing in the backend, so configure backend timeouts and tolerate retries. In particular,
  keep the previous lease token valid across renewals, and make release idempotent: it may run
  more than once or after a replacement is acquired.

  See `NoNoncense.MachineId` for timeout, renewal, and local expiry behavior.
  """

  @doc "Acquire a new lease, returning the assigned machine ID (`0..511`), an opaque lease term, and the granted TTL in milliseconds."
  @callback acquire(lease_duration :: pos_integer(), strategy_opts :: keyword()) ::
              {:ok, machine_id :: 0..511, lease :: term(), ttl_ms :: pos_integer()}
              | {:error, reason :: term()}

  @doc "Renew an existing lease for the same machine ID, returning the updated lease term and granted TTL in milliseconds."
  @callback renew(lease :: term(), lease_duration :: pos_integer(), strategy_opts :: keyword()) ::
              {:ok, lease :: term(), ttl_ms :: pos_integer()}
              | {:error, :lost, reason :: term()}
              | {:error, :retry, reason :: term()}

  @doc """
  Best-effort release of a lease, e.g. on graceful shutdown or after lease loss.

  This callback can run asynchronously after the lease manager has already begun acquiring a
  replacement. It must therefore be idempotent and only release when `lease` still identifies the
  same acquisition; a stale lease must be a no-op.
  """
  @callback release(lease :: term(), strategy_opts :: keyword()) :: :ok

  @doc """
  Returns `true` if `acquire/2` always yields the same machine ID for this node, making
  reacquisition after a conflict pointless.

  Dynamic coordinating strategies (such as `SqlLease` and `RedisLease`) must return `false` so
  `NoNoncense.MachineId` attempts reacquisition after a lease loss.
  """
  @callback deterministic? :: boolean()

  @doc "Imports the strategy behaviour with default implementations of `renew/3`, `release/2`, and `deterministic?/0` for static strategies."
  defmacro __using__(_opts \\ []) do
    quote location: :keep do
      @behaviour NoNoncense.MachineId.Strategy

      @impl true
      def renew(lease, lease_duration, _opts), do: {:ok, lease, lease_duration}
      defoverridable renew: 3

      @impl true
      def release(_lease, _opts), do: :ok
      defoverridable release: 2

      @impl true
      def deterministic?(), do: true
      defoverridable deterministic?: 0
    end
  end
end
