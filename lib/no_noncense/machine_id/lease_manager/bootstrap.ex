defmodule NoNoncense.MachineId.LeaseManager.Bootstrap do
  @moduledoc false

  alias NoNoncense.MachineId.{ExpirationManager, LeaseCache}
  alias NoNoncense.MachineId.LeaseManager.Backoff
  alias NoNoncense.Telemetry
  require Logger

  @doc """
  Acquires a machine ID during LeaseManager startup.

  - try to fetch a cached lease
  - renew it if still locally valid (single attempt), falling back to a fresh acquisition on
    failure, an illegal TTL, or a race where the expiration manager clears the cache mid-renew
  - acquire a new lease otherwise

  This runs synchronously, so the manager does not start until it has a valid lease.
  """
  @spec acquire_initial_id(map()) :: {:ok, LeaseCache.lease()} | {:error, term()}
  def acquire_initial_id(state) do
    case LeaseCache.get(state.lease_cache) do
      lease when is_map(lease) -> renew_cached(state, lease)
      nil -> acquire_new(state)
    end
  end

  defp renew_cached(state, lease) do
    if LeaseCache.valid?(lease) do
      fn -> state.strategy.renew(lease.lease, state.lease_duration, state.strategy_opts) end
      |> Telemetry.lease_operation(:renew, %{strategy: state.strategy, source: :cache})
      |> case do
        {:ok, renewed_lease, ttl_ms} when ttl_ms >= 30_000 ->
          case ExpirationManager.renew(state.expiration_manager, renewed_lease, ttl_ms) do
            {:ok, cached_lease} -> {:ok, cached_lease}
            # cache was cleared by the expiration manager's own timer while renewing
            :lost -> acquire_new(state)
          end

        {:ok, _, _} ->
          ExpirationManager.discard(state.expiration_manager)
          {:error, :illegal_ttl}

        {:error, _status, reason} ->
          Logger.debug("Failed to renew lease of ID #{lease.machine_id}: #{inspect(reason)}")
          ExpirationManager.discard(state.expiration_manager)
          acquire_new(state)
      end
    else
      ExpirationManager.discard(state.expiration_manager)
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
          ExpirationManager.acquire(state.expiration_manager, machine_id, lease, ttl_ms)

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
