defmodule NoNoncense.MachineId.Strategy do
  @moduledoc """
  Behaviour for pluggable machine ID lease strategies, used by `NoNoncense.MachineId.LeaseManager`
  to coordinate unique machine ID assignment across nodes (e.g. through SQL or Redis).

  A strategy must hand back the same `machine_id` to a given node/identity across `acquire/2` and
  successive `renew/3` calls - callers rely on this to keep using the same ID for the lifetime of a lease.

  `lease_duration` is the duration (in ms) the caller would like the lease to be valid for; a
  strategy may grant a different duration (e.g. clamped to its own bounds) via the returned `ttl_ms`.

  Strategies must grant leases of at least 30 seconds. `LeaseManager` uses the returned `ttl_ms`
  to schedule both renewal and a local expiry deadline, with safety margins before the actual
  expiry. A shorter lease is treated as lost and its factories are disabled.

  `renew/3` distinguishes two failure modes so callers can tell confirmed loss from mere uncertainty:

    * `{:error, :lost, reason}` - the strategy positively confirms the lease is no longer held
      (e.g. another node holds it now, or the coordinator explicitly rejects the renewal).
    * `{:error, :retry, reason}` - an ambiguous/transient failure (timeout, connection error); the
      strategy cannot confirm whether the lease is still valid.
  """

  @type machine_id :: non_neg_integer()
  @type lease :: term()
  @type lease_duration :: pos_integer()
  @type ttl_ms :: pos_integer()
  @type opts :: keyword()

  @doc "Acquire a new lease, returning the assigned machine ID and its actual validity period."
  @callback acquire(lease_duration(), opts()) ::
              {:ok, machine_id(), lease(), ttl_ms()} | {:error, reason :: term()}

  @doc "Renew an existing lease, extending its validity period."
  @callback renew(lease(), lease_duration(), opts()) ::
              {:ok, lease(), ttl_ms()}
              | {:error, :lost, reason :: term()}
              | {:error, :retry, reason :: term()}

  @doc "Best-effort release of a lease, e.g. on graceful shutdown."
  @callback release(lease(), opts()) :: :ok

  @doc "Imports the strategy behaviour and default stateless `renew/3` and `release/2` callbacks."
  defmacro __using__(_opts \\ []) do
    quote location: :keep do
      @behaviour NoNoncense.MachineId.Strategy

      @impl true
      def renew(lease, lease_duration, _opts), do: {:ok, lease, lease_duration}
      defoverridable renew: 3

      @impl true
      def release(_lease, _opts), do: :ok
      defoverridable release: 2
    end
  end
end
