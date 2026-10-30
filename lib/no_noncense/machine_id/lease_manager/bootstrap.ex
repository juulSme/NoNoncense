defmodule NoNoncense.MachineId.LeaseManager.Bootstrap do
  @moduledoc false

  alias NoNoncense.MachineId.LeaseStore
  alias NoNoncense.MachineId.LeaseManager.Backoff
  alias NoNoncense.Telemetry
  require Logger

  @doc """
  Acquires a machine ID during LeaseManager startup.

  - try to fetch a stored lease
  - renew it if still locally valid (single attempt), falling back to a fresh acquisition on
    failure, an illegal TTL, or a race where the store expires mid-renew
  - acquire a new lease otherwise

  This runs synchronously, so the manager does not start until it has a valid lease.
  """
  @spec acquire_initial_id(map()) :: {:ok, LeaseStore.lease()} | {:error, term()}
  def acquire_initial_id(state) do
    with %{} = lease <- LeaseStore.get(state.lease_store),
         true <- LeaseStore.valid?(lease) do
      renew_cached(state, lease)
    else
      _ ->
        LeaseStore.discard(state.lease_store)
        acquire_new(state)
    end
  end

  defp renew_cached(state, lease) do
    op = fn -> state.strategy.renew(lease.lease, state.lease_duration, state.strategy_opts) end

    with {:ok, renewed_lease, ttl_ms} when ttl_ms >= 30_000 <-
           Telemetry.lease_operation(op, :renew, %{strategy: state.strategy, source: :store}),
         {:ok, stored_lease} <- LeaseStore.renew(state.lease_store, renewed_lease, ttl_ms) do
      {:ok, stored_lease}
    else
      {:ok, _, _} ->
        LeaseStore.discard(state.lease_store)
        {:error, :illegal_ttl}

      :lost ->
        acquire_new(state)

      {:error, _status, reason} ->
        Logger.debug("Failed to renew lease of ID #{lease.machine_id}: #{inspect(reason)}")
        LeaseStore.discard(state.lease_store)
        acquire_new(state)
    end
  end

  defp acquire_new(state) do
    acquire_timeout = state.acquire_timeout
    deadline = if acquire_timeout == :infinity, do: :infinity, else: now_mono() + acquire_timeout
    acquire_new_until(state, deadline)
  end

  defp acquire_new_until(state, deadline) do
    if deadline_expired?(deadline) do
      Logger.critical("Acquisition failed, deadline exceeded.")
      {:error, :timeout}
    else
      fn -> state.strategy.acquire(state.lease_duration, state.strategy_opts) end
      |> Telemetry.lease_operation(:acquire, %{strategy: state.strategy, source: :initial})
      |> case do
        {:ok, machine_id, lease, ttl_ms} when ttl_ms >= 30_000 ->
          {:ok, LeaseStore.put(state.lease_store, machine_id, lease, ttl_ms)}

        {:ok, _, _, _} ->
          {:error, :illegal_ttl}

        {:error, reason} ->
          Logger.warning("Acquisition failed: #{inspect(reason)}")
          delay_limit = cap_at_deadline(state.acquire_timeout, deadline)
          delay = Backoff.delay(state.attempt, 100, delay_limit)

          if delay > 0 do
            Telemetry.lease_retry(:acquire, state.attempt, delay, reason)
            Process.sleep(delay)
          end

          acquire_new_until(%{state | attempt: state.attempt + 1}, deadline)
      end
    end
  end

  defp deadline_expired?(:infinity), do: false
  defp deadline_expired?(deadline), do: now_mono() >= deadline

  defp cap_at_deadline(ttl, :infinity), do: ttl
  defp cap_at_deadline(ttl, deadline), do: min(ttl, max(0, _deadline_ttl = deadline - now_mono()))

  defp now_mono(), do: :erlang.monotonic_time(:millisecond)
end
