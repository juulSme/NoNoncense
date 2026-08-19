defmodule NoNoncense.MachineId.LeaseManager.StateChange do
  @moduledoc false
  alias NoNoncense.MachineId.LeaseCache
  alias NoNoncense.MachineId.LeaseManager.{Timers, Instances}
  alias NoNoncense.Telemetry
  require Logger

  @doc """
  Records a renewed lease, schedules its renewal and local expiry, caches it, and initializes
  configured factories with its machine ID.
  """
  @spec on_renewed(map(), term(), pos_integer()) :: map()
  def on_renewed(state, lease, ttl_ms) when ttl_ms >= 30_000 do
    safe_ttl_ms = apply_margin(ttl_ms, 10_000)

    %{state | lease: lease, expires_at_mono: now_mono() + ttl_ms, leased?: true, attempt: 1}
    |> Timers.clear()
    |> Timers.schedule(:renew, min(state.renew_interval, safe_ttl_ms) |> apply_margin(10_000))
    |> Timers.schedule(:expired, safe_ttl_ms)
    |> put_cache()
    |> update_instances()
  end

  def on_renewed(state, _, _), do: on_lost(state, :illegal_ttl)

  @doc """
  Disables configured factories, clears the current lease, notifies the callback, and schedules
  immediate reacquisition.
  """
  @spec on_lost(map(), term()) :: map()
  def on_lost(state, reason) do
    Logger.critical("Lease of ID #{state.machine_id} lost: #{inspect(reason)}")
    Telemetry.lease_lost(reason, max(0, state.expires_at_mono - now_mono()))

    state
    |> cleanup()
    |> then(fn state ->
      if state.strategy.deterministic?(), do: state, else: Timers.schedule(state, :reacquire, 0)
    end)
    |> tap(fn state -> if state.on_lease_lost, do: state.on_lease_lost.(reason) end)
  end

  @doc """
  Cleanup the state (lease, cache, timers and instances) without triggering on_lease_lost.
  """
  @spec cleanup(map()) :: map()
  def cleanup(state) do
    state |> clear_lease() |> put_cache() |> update_instances() |> Timers.clear()
  end

  defp clear_lease(state), do: %{state | leased?: false, machine_id: nil, lease: nil, attempt: 1}

  defp put_cache(%{lease_cache: cache} = state) do
    if cache, do: LeaseCache.put(cache, Map.take(state, [:machine_id, :lease, :leased?]))
    state
  end

  defp update_instances(state) do
    if state.leased? do
      state.instances
      |> Enum.map(&Keyword.put(&1, :machine_id, state.machine_id))
      |> Instances.re_init_all()
    else
      Instances.disable_all(state.instances)
    end

    state
  end

  defp apply_margin(ttl_ms, margin), do: max(0, ttl_ms - margin)

  defp now_mono(), do: :erlang.monotonic_time(:millisecond)
end
