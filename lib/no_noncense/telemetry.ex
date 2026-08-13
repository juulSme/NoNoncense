if Code.ensure_loaded?(:telemetry) do
  defmodule NoNoncense.Telemetry do
    @moduledoc """
    Telemetry events emitted by NoNoncense machine ID management.

    This module is active only when the optional `:telemetry` dependency is available. It emits
    events for lease management and conflict detection; nonce generation is never instrumented.

    ## Lease operations

    Lease strategy calls emit span events for each `operation` in `:acquire`, `:renew`, and
    `:release`:

      `[:no_noncense, :machine_id, :lease, operation, :start]`

      `[:no_noncense, :machine_id, :lease, operation, :stop]`

    The `:start` event has no measurements. The `:stop` event includes `:duration` in native time
    units and, for successful acquire and renew operations, `:ttl_ms`. Both events include
    `:strategy` and `:source` metadata. The `:stop` event additionally includes `:result`, one of
    `:ok`, `:error`, `:retry`, or `:lost`.

    `:source` identifies the lifecycle path: `:initial`, `:reacquire`, `:cache`, `:scheduled`, or
    `:shutdown`.

    ## Lease state changes

    Retry scheduling emits:

      `[:no_noncense, :machine_id, :lease, :retry]`

    with `:attempt` and `:delay_ms` measurements and `:operation` and `:reason` metadata.

    A confirmed local lease loss or expiry emits:

      `[:no_noncense, :machine_id, :lease, :lost]`

    with a `:remaining_ttl_ms` measurement and a normalized `:reason` metadata value.

    ## Conflict guard

    Each peer comparison emits:

      `[:no_noncense, :machine_id, :conflict_guard, :peer_checked]`

    with `:outcome` metadata of `:different`, `:local_id_unavailable`, or `:match`.

    A duplicate machine ID emits:

      `[:no_noncense, :machine_id, :conflict_guard, :conflict]`

    with `:resolution` metadata of `:local_node` when this node resolves the conflict, or
    `:remote_node` when the peer does.
    """

    @doc false
    @spec lease_operation((-> term()), :acquire | :renew | :release, map()) :: term()
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

    @doc false
    @spec lease_retry(:acquire | :renew, pos_integer(), non_neg_integer(), term()) :: :ok
    def lease_retry(operation, attempt, delay_ms, reason) do
      :telemetry.execute(
        [:no_noncense, :machine_id, :lease, :retry],
        %{attempt: attempt, delay_ms: delay_ms},
        %{operation: operation, reason: reason_category(reason)}
      )
    end

    @doc false
    @spec lease_lost(term(), non_neg_integer()) :: :ok
    def lease_lost(reason, remaining_ttl_ms) do
      :telemetry.execute(
        [:no_noncense, :machine_id, :lease, :lost],
        %{remaining_ttl_ms: remaining_ttl_ms},
        %{reason: reason_category(reason)}
      )
    end

    @doc false
    @spec peer_checked(:different | :local_id_unavailable | :match) :: :ok
    def peer_checked(outcome) do
      :telemetry.execute(
        [:no_noncense, :machine_id, :conflict_guard, :peer_checked],
        %{},
        %{outcome: outcome}
      )
    end

    @doc false
    @spec conflict(:local_node | :remote_node) :: :ok
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
    defp reason_category(_), do: :strategy
  end
else
  defmodule NoNoncense.Telemetry do
    @moduledoc """
    Telemetry must be loaded for this module to do useful work.
    """

    @doc false
    def lease_operation(fun, _, _), do: fun.()
    @doc false
    def lease_retry(_, _, _, _), do: :ok
    @doc false
    def lease_lost(_, _, _), do: :ok
    @doc false
    def peer_checked(_), do: :ok
    @doc false
    def conflict(_), do: :ok
  end
end
