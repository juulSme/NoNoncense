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

  defp renew_if_leased(state = %{machine_id: machine_id}) when state.leased? do
    fn -> state.strategy.renew(state.lease, state.lease_duration, state.strategy_opts) end
    |> Telemetry.lease_operation(:renew, %{strategy: state.strategy, source: :cache})
    |> case do
      {:ok, lease, ttl_ms} ->
        Logger.debug("Lease of ID #{machine_id} renewed for #{ttl_ms}ms.")
        StateChange.on_renewed(state, lease, ttl_ms)

      {:error, status, reason} ->
        Logger.debug("Failed to renew lease of ID #{machine_id}: #{inspect({status, reason})}")
        StateChange.cleanup(state)
    end
  end

  defp renew_if_leased(state), do: state

  defp acquire_unless_leased(state) when not state.leased? do
    acquire_timeout = state.acquire_timeout
    deadline = if acquire_timeout == :infinity, do: :infinity, else: now_mono() + acquire_timeout

    case acquire_until(state, deadline) do
      {:ok, machine_id, lease, ttl_ms} ->
        Logger.info("Lease of ID #{machine_id} acquired for #{ttl_ms}ms.")
        StateChange.on_renewed(%{state | machine_id: machine_id}, lease, ttl_ms)

      {:error, reason} ->
        StateChange.on_lost(state, reason)
    end
  end

  defp acquire_unless_leased(state), do: state

  defp acquire_until(state, deadline) do
    if deadline_expired?(deadline) do
      Logger.critical("Acquisition failed, deadline exceeded.")
      {:error, :timeout}
    else
      fn -> state.strategy.acquire(state.lease_duration, state.strategy_opts) end
      |> Telemetry.lease_operation(:acquire, %{strategy: state.strategy, source: :initial})
      |> case do
        {:ok, _, _, _} = ok ->
          ok

        {:error, reason} ->
          Logger.warning("Acquisition failed: #{inspect(reason)}")
          delay_limit = cap_at_deadline(state.acquire_timeout, deadline)
          delay = Backoff.delay(state.attempt, 100, delay_limit)

          if delay > 0 do
            Telemetry.lease_retry(:acquire, state.attempt, delay, reason)
            Process.sleep(delay)
          end

          acquire_until(%{state | attempt: state.attempt + 1}, deadline)
      end
    end
  end

  defp deadline_expired?(:infinity), do: false
  defp deadline_expired?(deadline), do: now_mono() >= deadline

  defp cap_at_deadline(ttl, :infinity), do: ttl
  defp cap_at_deadline(ttl, deadline), do: min(ttl, max(0, _deadline_ttl = deadline - now_mono()))

  defp now_mono(), do: :erlang.monotonic_time(:millisecond)
end
