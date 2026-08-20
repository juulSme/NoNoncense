if Code.ensure_loaded?(:telemetry) do
  defmodule NoNoncense.Telemetry do
    @moduledoc """
    Events emitted while managing machine IDs. Nonce generation is never instrumented.

    The module emits no events when the optional `:telemetry` dependency is unavailable.

    ## Lease operation spans

    Lease acquisition, renewal, and release emit a span, where `operation` is `:acquire`,
    `:renew`, or `:release`.

      * Start: `[:no_noncense, :machine_id, :lease, operation, :start]`
      * Stop: `[:no_noncense, :machine_id, :lease, operation, :stop]`

    Start measurements:

      * `:system_time` - system time in native time units when the operation began.
      * `:monotonic_time` - monotonic time in native time units when the operation began.

    Stop measurements:

      * `:duration` - elapsed monotonic time in native time units.
      * `:ttl_ms` - granted lease duration in milliseconds; present only for successful acquire
        and renew operations.

    Both events include these metadata fields:

      * `:strategy` - the lease strategy module.
      * `source: :initial | :reacquire | :cache | :scheduled | :loss | :shutdown` - the operation's
        lifecycle path.

    Stop events also include `result: :ok | :error | :retry | :lost`. `:retry` and `:lost`
    distinguish strategy-confirmed transient failures from confirmed lease loss.

    ## Lease state events

    ### Retry scheduled

    `[:no_noncense, :machine_id, :lease, :retry]` reports that a failed acquisition or renewal
    will be retried.

    Measurements:

      * `:attempt` - the retry attempt number.
      * `:delay_ms` - the delay before retrying, in milliseconds.

    Metadata:

      * `operation: :acquire | :renew`.
      * `:reason` - the strategy's atom reason, or `:other` when the reason is not an atom.

    ### Lease lost

    `[:no_noncense, :machine_id, :lease, :lost]` reports local expiry or a confirmed loss of the
    lease.

    Measurements:

      * `:remaining_ttl_ms` - milliseconds remaining in the locally tracked lease lifetime,
        clamped to zero.

    Metadata:

      * `:reason` - the loss reason as an atom, or `:other` when the reason is not an atom.

    ## Conflict guard events

    ### Peer checked

    `[:no_noncense, :machine_id, :conflict_guard, :peer_checked]` reports the result of comparing
    this node's machine ID with a peer. It has no measurements.

    Metadata:

      * `outcome: :conflict | :no_local_id | :match`.

    ### Conflict detected

    `[:no_noncense, :machine_id, :conflict_guard, :conflict]` reports a duplicate machine ID. It
    has no measurements.

    Metadata:

      * `resolution: :local_node | :remote_node` - whether this node or the peer resolves the
        conflict.
    """
    @behaviour NoNoncense.Telemetry.Behaviour

    @impl true
    def lease_operation(fun, operation, metadata) do
      :telemetry.span(
        [:no_noncense, :machine_id, :lease, operation],
        metadata,
        fn ->
          result = fun.()
          {result, ttl_measurement(result), Map.put(metadata, :result, result_type(result))}
        end
      )
    end

    @impl true
    def lease_retry(operation, attempt, delay_ms, reason) do
      :telemetry.execute(
        [:no_noncense, :machine_id, :lease, :retry],
        %{attempt: attempt, delay_ms: delay_ms},
        %{operation: operation, reason: reason_category(reason)}
      )
    end

    @impl true
    def lease_lost(reason, remaining_ttl_ms) do
      :telemetry.execute(
        [:no_noncense, :machine_id, :lease, :lost],
        %{remaining_ttl_ms: remaining_ttl_ms},
        %{reason: reason_category(reason)}
      )
    end

    @impl true
    def peer_checked(outcome) do
      :telemetry.execute(
        [:no_noncense, :machine_id, :conflict_guard, :peer_checked],
        %{},
        %{outcome: outcome}
      )
    end

    @impl true
    def conflict(resolution) do
      :telemetry.execute(
        [:no_noncense, :machine_id, :conflict_guard, :conflict],
        %{},
        %{resolution: resolution}
      )
    end

    defp ttl_measurement({:ok, _, _, ttl_ms}) when is_integer(ttl_ms), do: %{ttl_ms: ttl_ms}
    defp ttl_measurement({:ok, _, ttl_ms}) when is_integer(ttl_ms), do: %{ttl_ms: ttl_ms}
    defp ttl_measurement(_), do: %{}

    defp result_type({:ok, _}), do: :ok
    defp result_type({:ok, _, _}), do: :ok
    defp result_type({:ok, _, _, _}), do: :ok
    defp result_type(:ok), do: :ok
    defp result_type({:error, :retry, _}), do: :retry
    defp result_type({:error, :lost, _}), do: :lost
    defp result_type({:error, _}), do: :error
    defp result_type(_), do: :error

    defp reason_category(atom) when is_atom(atom), do: atom
    defp reason_category(_), do: :other
  end
else
  defmodule NoNoncense.Telemetry do
    @moduledoc """
    No-op telemetry implementation used when the optional `:telemetry` dependency is unavailable.
    """
    @behaviour NoNoncense.Telemetry.Behaviour

    @impl true
    def lease_operation(fun, _, _), do: fun.()
    @impl true
    def lease_retry(_, _, _, _), do: :ok
    @impl true
    def lease_lost(_, _), do: :ok
    @impl true
    def peer_checked(_), do: :ok
    @impl true
    def conflict(_), do: :ok
  end
end
