defmodule NoNoncense.MachineId.LeaseManager.Bootstrap do
  @moduledoc false

  alias NoNoncense.MachineId.LeaseCache
  alias NoNoncense.MachineId.LeaseManager.{Backoff, StateChange}
  alias NoNoncense.Telemetry
  require Logger

  @doc """
  Acquires a machine ID during LeaseManager startup.

  - try to fetch a cached ID and lease
  - renew the cached lease if it exists (single attempt)
  - acquire a new lease otherwise

  This runs synchronously, so the manager does not start until it has a valid lease.
  """
  @spec acquire_initial_id(map()) :: map()
  def acquire_initial_id(state) do
    state |> fetch_cached() |> renew_if_leased() |> acquire_unless_leased()
  end

  defp fetch_cached(state = %{lease_cache: nil}), do: state

  defp fetch_cached(%{lease_cache: cache} = state),
    do: Map.merge(state, LeaseCache.get(cache) || %{})

  defp renew_if_leased(state) when state.leased? do
    fn -> state.strategy.renew(state.lease, state.lease_duration, state.strategy_opts) end
    |> Telemetry.lease_operation(:renew, %{strategy: state.strategy, source: :cache})
    |> case do
      {:ok, lease, ttl_ms} ->
        Logger.debug("Lease of ID #{state.machine_id} renewed for #{div(ttl_ms, 1000)}s.")
        StateChange.on_renewed(state, lease, ttl_ms)

      _ ->
        Logger.debug("Could not renew cached ID #{state.machine_id} lease.")
        StateChange.clear_lease(state)
    end
  end

  defp renew_if_leased(state), do: state

  defp acquire_unless_leased(state) when not state.leased? do
    acquire_timeout = state.acquire_timeout
    deadline = if acquire_timeout == :infinity, do: :infinity, else: now_mono() + acquire_timeout

    case acquire_until(state, deadline) do
      {:ok, machine_id, lease, ttl_ms} ->
        Logger.info("Lease of ID #{machine_id} acquired for #{div(ttl_ms, 1000)}s.")
        StateChange.on_renewed(%{state | machine_id: machine_id}, lease, ttl_ms)

      {:error, reason} ->
        StateChange.on_lost(state, reason)
    end
  end

  defp acquire_unless_leased(state), do: state

  defp acquire_until(state, deadline) do
    fn -> state.strategy.acquire(state.lease_duration, state.strategy_opts) end
    |> Telemetry.lease_operation(:acquire, %{strategy: state.strategy, source: :initial})
    |> case do
      {:ok, _, _, _} = ok ->
        ok

      {:error, reason} ->
        if deadline != :infinity and now_mono() >= deadline do
          Logger.critical("Acquisition failed, deadline exceeded: #{inspect(reason)}")
          {:error, reason}
        else
          delay = Backoff.delay(state.attempt, 100, state.acquire_timeout)
          Logger.warning("Acquisition failed (retry in #{div(delay, 1000)}s): #{inspect(reason)}")
          Telemetry.lease_retry(:acquire, state.attempt, delay, reason)

          Process.sleep(delay)
          acquire_until(%{state | attempt: state.attempt + 1}, deadline)
        end
    end
  end

  defp now_mono(), do: :erlang.monotonic_time(:millisecond)
end
