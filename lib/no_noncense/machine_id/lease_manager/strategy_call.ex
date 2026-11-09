defmodule NoNoncense.MachineId.LeaseManager.StrategyCall do
  @moduledoc false

  # This is the only module that calls a strategy. Each call:
  #
  #   * runs in a task under the task supervisor, so a slow, blocked or crashing strategy cannot
  #     take the caller down, and is cut off after `:callback_timeout` or, when given, the
  #     caller's deadline, whichever comes first;
  #   * is wrapped in a telemetry span;
  #   * for acquire and renew, is recorded in the `LeaseStore`, which decides whether the granted
  #     lease is acceptable.
  #
  # `acquire/3` and `renew/4` return `{:ok, lease}` or `{:error, kind, reason}`:
  #
  #   * `:retry` - the strategy failed, crashed, timed out or was never called because the
  #     deadline had passed. The outcome is ambiguous (a timed-out call may still have committed)
  #     and nothing changed locally.
  #   * `:lost` - the strategy confirmed the lease is gone. Renew only; the caller must tell the
  #     store, which does not know.
  #   * `:rejected` - the strategy granted a lease but the store refused it. The lease has been, or
  #     is being, released, so the caller has nothing left to clean up.
  #
  # `started_at` is taken before the strategy call and handed to the store, so a lease's local
  # expiry counts from when the call began.

  alias NoNoncense.MachineId.LeaseStore
  alias NoNoncense.Telemetry

  # Sources that run before the manager has a lease; failures there are handled by Bootstrap
  @startup_sources [:initial, :store]

  @type result ::
          {:ok, LeaseStore.local_lease()}
          | {:error, :retry | :lost | :rejected, term()}

  @doc """
  Acquires a lease and records it in the store.
  LeaseStore.local_lease
  A lease the strategy granted but the store refused is released and reported as `:rejected`.
  """
  @spec acquire(map(), atom(), keyword()) :: result()
  def acquire(state, source, opts \\ []) do
    fn -> state.strategy.acquire(state.lease_duration, state.strategy_opts) end
    |> run(state, :acquire, source, opts[:deadline])
    |> case do
      {{:ok, machine_id, lease, ttl_ms}, started_at} ->
        state.lease_store
        |> LeaseStore.put(machine_id, lease, ttl_ms, started_at)
        |> accept(state, lease, source, opts[:deadline])

      {{:error, reason}, _started_at} ->
        {:error, :retry, reason}
    end
  end

  @doc """
  Renews a lease and records it in the store.

  A lease the strategy granted but the store refused is released and reported as `:rejected`.
  """
  @spec renew(map(), term(), atom(), keyword()) :: result()
  def renew(state, lease, source, opts \\ []) do
    fn -> state.strategy.renew(lease, state.lease_duration, state.strategy_opts) end
    |> run(state, :renew, source, opts[:deadline])
    |> case do
      {{:ok, renewed_lease, ttl_ms}, started_at} ->
        state.lease_store
        |> LeaseStore.renew(renewed_lease, ttl_ms, started_at)
        |> accept(state, renewed_lease, source, opts[:deadline])

      {{:error, _kind, _reason} = error, _started_at} ->
        error
    end
  end

  @doc "Best-effort release of a lease. Failures are ignored, so it always returns `:ok`."
  def release(state, lease, source) do
    release_within(state, lease, source, nil)
    :ok
  end

  @doc "Releases a lease in the background so the caller is not held up by a slow strategy."
  def release_async(state, lease) do
    Task.Supervisor.start_child(state.task_supervisor, fn -> release(state, lease, :loss) end)
  end

  # Passes through what the store accepted. A refusal means the strategy is still holding a lease
  # we cannot use, so release it and report why.
  defp accept({:ok, local_lease}, _state, _lease, _source, _deadline), do: {:ok, local_lease}

  defp accept({:error, reason}, state, lease, source, deadline) do
    reject(state, lease, reason, source, deadline)
    {:error, :rejected, reason}
  end

  # Bootstrap retries right away and wants the ID free, so wait for the release, but only as long
  # as the deadline allows. If it did not complete, finish it in the background; release is
  # idempotent, so repeating a call that may have taken effect is safe.
  defp reject(state, lease, _reason, source, deadline) when source in @startup_sources do
    :ok = LeaseStore.discard(state.lease_store)

    with {:error, _reason} <- release_within(state, lease, :loss, deadline) do
      release_async(state, lease)
    end
  end

  # Factories must be disabled before the ID is released for others to take
  defp reject(state, lease, reason, _source, _deadline) do
    :ok = LeaseStore.lose(state.lease_store, reason)
    release_async(state, lease)
  end

  # One release attempt that gives up at `deadline`. Returns `:ok` or `{:error, reason}`, where a
  # call that never started, timed out or crashed is an error.
  defp release_within(state, lease, source, deadline) do
    {result, _started_at} =
      fn -> state.strategy.release(lease, state.strategy_opts) end
      |> run(state, :release, source, deadline)

    result
  end

  # Runs `fun` as a strategy call and returns `{result, started_at}`. The result keeps the
  # strategy's own shape, which is what telemetry classifies; `acquire/3` and `renew/4` normalize
  # it afterwards.
  defp run(fun, state, operation, source, deadline) do
    started_at = System.monotonic_time(:millisecond)
    timeout = timeout(state.callback_timeout, deadline)

    result =
      if timeout == 0 do
        # The deadline has passed, so the call is never started and gets no telemetry span
        failure(operation, :timeout)
      else
        fn -> await(state, operation, fun, timeout) end
        |> Telemetry.lease_operation(operation, %{strategy: state.strategy, source: source})
      end

    {result, started_at}
  end

  # The task is not linked, so a crash in the strategy arrives as `{:exit, reason}` instead of
  # killing the caller. On timeout the task is killed, but its call may already have taken effect.
  defp await(state, operation, fun, timeout) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> failure(operation, {:strategy_exit, reason})
      nil -> failure(operation, :timeout)
    end
  end

  # Shaped like the strategy's own error returns, because telemetry classifies this value:
  # renew failures are `{:error, :retry, reason}`, the others `{:error, reason}`.
  defp failure(:renew, reason), do: {:error, :retry, reason}
  defp failure(_operation, reason), do: {:error, reason}

  # The time allowed for one call. Zero means the deadline has already passed.
  defp timeout(callback_timeout, deadline) when deadline in [nil, :infinity], do: callback_timeout

  defp timeout(callback_timeout, deadline) do
    min(callback_timeout, max(0, deadline - System.monotonic_time(:millisecond)))
  end
end
