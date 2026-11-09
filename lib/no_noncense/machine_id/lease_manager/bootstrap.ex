defmodule NoNoncense.MachineId.LeaseManager.Bootstrap do
  @moduledoc false

  alias NoNoncense.MachineId.LeaseStore
  alias NoNoncense.MachineId.LeaseManager.{Backoff, StrategyCall}
  alias NoNoncense.Telemetry
  require Logger

  @doc """
  Acquires a machine ID during LeaseManager startup.

  - renew the stored lease if it is still locally valid (single attempt)
  - otherwise, or if renewal fails, acquire a new lease, retrying until the deadline
  - an illegal TTL fails startup instead of retrying

  `:acquire_timeout` bounds all of it, including the strategy calls themselves.
  This runs synchronously, so the manager does not start until it has a valid lease.
  """
  @spec acquire_initial_id(map()) :: {:ok, LeaseStore.local_lease()} | {:error, term()}
  def acquire_initial_id(state) do
    # An absolute monotonic time, so every step below can ask how much time is left
    deadline = state.acquire_timeout
    deadline = if deadline == :infinity, do: deadline, else: deadline + now_mono()

    case renew_stored(state, deadline) do
      {:ok, local_lease} -> {:ok, local_lease}
      # The strategy grants TTLs we cannot use; retrying would get the same answer
      {:error, :rejected, :illegal_ttl} -> {:error, :illegal_ttl}
      _ -> acquire_new_until(state, deadline)
    end
  end

  # Tries once to carry on with the lease a previous manager left in the store. Any other outcome,
  # including having no usable stored lease, discards the store, so factories are disabled and
  # nothing stale remains while a replacement is acquired. It must be `discard`, not `lose`: the
  # manager is already registered, and a loss notification would start its loss handling.
  defp renew_stored(state, deadline) do
    case LeaseStore.get(state.lease_store) do
      %{} = local_lease -> attempt_renew(state, local_lease, deadline)
      nil -> LeaseStore.discard(state.lease_store) && nil
    end
  end

  defp attempt_renew(state, local_lease, deadline) do
    case StrategyCall.renew(state, local_lease.strategy_lease, :store, deadline: deadline) do
      {:ok, renewed = %{machine_id: machine_id}} = ok ->
        Logger.info("Lease of ID #{machine_id} resumed from store, #{valid_for(renewed)}.")
        ok

      failure ->
        Logger.debug("Failed to renew stored ID #{local_lease.machine_id}: #{inspect(failure)}")
        LeaseStore.discard(state.lease_store)
        StrategyCall.release_async(state, local_lease.strategy_lease)
        failure
    end
  end

  # Acquires a fresh lease, looping until it succeeds, fails for good, or the deadline passes.
  defp acquire_new_until(state, deadline) do
    with {_, false} <- {:deadline_expired?, deadline_expired?(deadline)},
         {:ok, lease} <- StrategyCall.acquire(state, :initial, deadline: deadline) do
      Logger.info("Lease of ID #{lease.machine_id} acquired, #{valid_for(lease)}.")
      {:ok, lease}
    else
      {:deadline_expired?, true} ->
        Logger.critical("Acquisition failed, deadline exceeded.")
        {:error, :timeout}

      {:error, :rejected, :illegal_ttl} ->
        {:error, :illegal_ttl}

      # The strategy answered but the call used up the validity window. StrategyCall has already
      # released that lease, so try again straight away; the deadline bounds the loop.
      {:error, :rejected, _reason} ->
        acquire_new_until(state, deadline)

      # The strategy failed, timed out or crashed: back off, then try again.
      {:error, :retry, reason} ->
        Logger.warning("Acquisition failed: #{inspect(reason)}")
        delay = Backoff.delay(state.attempt, 100, time_left(deadline))

        # A zero delay means the deadline has been reached, so the next pass gives up
        if delay > 0 do
          Telemetry.lease_retry(:acquire, state.attempt, delay, reason)
          Process.sleep(delay)
        end

        acquire_new_until(%{state | attempt: state.attempt + 1}, deadline)
    end
  end

  defp deadline_expired?(:infinity), do: false
  defp deadline_expired?(deadline), do: now_mono() >= deadline

  # Milliseconds until the deadline, which is also the longest a retry may sleep
  defp time_left(:infinity), do: :infinity
  defp time_left(deadline), do: max(0, deadline - now_mono())

  defp valid_for(lease), do: "valid for #{LeaseStore.remaining_ms(lease)}ms locally"
  defp now_mono(), do: System.monotonic_time(:millisecond)
end
