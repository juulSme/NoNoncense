defmodule NoNoncense.MachineId.LeaseStore do
  @moduledoc false

  # Implementation notes:
  #
  #   * State is `%{local_lease, timer, lease_manager, instances}`. `lease` is the single source of
  #     truth (nil when none is held), `timer` is the pending expiry timer for that lease,
  #     `lease_manager` is the name notifications are sent to, and `instances` are the factories
  #     to enable and disable.
  #
  #   * The expiry timer is an `:erlang.start_timer/3` reference, delivered as
  #     `{:timeout, ref, :expired}`. Cancelling a timer does not remove a message that was already
  #     delivered, so a timeout is acted on only if its ref is the current `timer`. This keeps an
  #     old timer from expiring a renewed lease.
  #
  #   * The timer can lag behind the clock, so validity is always computed from `expires_at_mono`
  #     rather than from the presence of a lease. `:get` filters on it, and `:renew` checks it and
  #     clears synchronously, instead of waiting for the timeout message.
  #
  #   * Ordering matters. `put` enables the factories before arming the timer. `clear` cancels the
  #     timer, disables the factories, and only then notifies the manager, so by the time the
  #     manager hears about a loss nothing can generate any more.
  #
  #   * `expires_at_mono = started_at + ttl - margin`. `build/4` rejects the TTL first, because
  #     the arithmetic is meaningless for a non-integer, and then rejects a window that has
  #     already closed.
  #
  #   * The manager is looked up with `GenServer.whereis/1` at notification time instead of
  #     being monitored, so a missing manager is simply skipped.
  #
  #   * There is a small gap between a lease becoming locally invalid and the timer firing, during
  #     which reads already return `nil` but the factories are still enabled. It is bounded by
  #     timer latency.
  #
  #   * Because an expired-but-uncleared lease reads as absent, the manager's graceful shutdown
  #     skips the best-effort `release` in that gap. The strategy's own TTL, which outlasts the
  #     local one by the safety margin, covers it.
  use GenServer
  use NoNoncense.Constants

  alias NoNoncense.MachineId.Instances

  @typedoc """
  The local lease is a wrapper around a strategy's returned lease, with the machine ID and expiration timestamp added.
  """
  @type local_lease :: %{machine_id: 0..511, strategy_lease: term(), expires_at_mono: integer()}
  @type error :: :expired | :lost | :illegal_ttl | :illegal_machine_id

  ##########
  # Client #
  ##########

  @doc "Starts an empty lease store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc "Returns the stored lease while it is inside its local validity window, else `nil`."
  @spec get(GenServer.name()) :: local_lease() | nil
  def get(name \\ __MODULE__), do: GenServer.call(name, :get)

  @doc "Returns the currently leased machine ID, or `nil` if no valid lease is held."
  @spec machine_id(GenServer.name()) :: 0..511 | nil
  def machine_id(name \\ __MODULE__) do
    with %{machine_id: machine_id} <- get(name), do: machine_id
  end

  @doc "Stores a newly acquired lease, using its operation start time in monotonic milliseconds."
  @spec put(GenServer.name(), 0..511, term(), integer(), integer()) ::
          {:ok, local_lease()} | {:error, :expired | :illegal_ttl | :illegal_machine_id}
  def put(name, machine_id, strategy_lease, ttl_ms, started_at) do
    GenServer.call(name, {:put, machine_id, strategy_lease, ttl_ms, started_at})
  end

  @doc "Replaces an active lease using its operation start time in monotonic milliseconds."
  @spec renew(GenServer.name(), term(), integer(), integer()) ::
          {:ok, local_lease()} | {:error, error()}
  def renew(name, strategy_lease, ttl_ms, started_at) do
    GenServer.call(name, {:renew, strategy_lease, ttl_ms, started_at})
  end

  @doc "Reports the current lease as lost, disabling factories and notifying the lease manager."
  @spec lose(GenServer.name(), term()) :: :ok
  def lose(name \\ __MODULE__, reason), do: GenServer.call(name, {:clear, reason})

  @doc "Discards a lease during bootstrap without notifying the lease manager."
  @spec discard(GenServer.name()) :: :ok
  def discard(name \\ __MODULE__), do: GenServer.call(name, {:clear, nil})

  ########
  # Util #
  ########

  @doc "Returns whether a stored lease remains inside its local validity window."
  @spec valid?(local_lease() | nil) :: boolean()
  def valid?(local_lease), do: remaining_ms(local_lease) > 0

  @doc "Milliseconds left in the lease's local validity window, clamped to zero."
  @spec remaining_ms(local_lease() | nil) :: non_neg_integer()
  def remaining_ms(_local_lease = %{expires_at_mono: expires_at_mono}) do
    max(0, expires_at_mono - System.monotonic_time(:millisecond))
  end

  def remaining_ms(_), do: 0

  ##########
  # Server #
  ##########

  @impl true
  def init(state) do
    state = Map.merge(%{local_lease: nil, timer: nil, lease_manager: nil, instances: []}, state)

    # makes supervisor shutdowns call terminate/2
    Process.flag(:trap_exit, true)

    # Factories may have survived a manager restart but cannot run until a lease is confirmed.
    Enum.each(state.instances, &Instances.disable/1)
    {:ok, state}
  end

  # State: `local_lease` is the single source of truth (nil when none is held); `timer` is the pending
  # local-expiry timer for that lease. Factories are enabled only while a lease is held.
  @impl true
  def handle_call(:get, _from, %{local_lease: local_lease} = state) do
    # The expiry timer may not have fired yet, so check the clock rather than trusting `local_lease`
    {:reply, if(valid?(local_lease), do: local_lease), state}
  end

  def handle_call({:put, machine_id, strategy_lease, ttl_ms, started_at}, _from, state) do
    with :ok <- verify_lease(machine_id, ttl_ms),
         {:ok, new_local} <- build_local_lease(machine_id, strategy_lease, ttl_ms, started_at),
         # enable factories before arming the timer
         Enum.each(state.instances, &Instances.re_init(Keyword.put(&1, :machine_id, machine_id))),
         # verify that initialization did not take too long
         true <- valid?(new_local) do
      {:reply, {:ok, new_local}, arm(state, new_local)}
    else
      {:error, _reason} = error -> {:reply, error, state}
      false -> {:reply, {:error, :expired}, clear(state, :expired)}
    end
  end

  def handle_call({:renew, _lease, _ttl_ms, _started_at}, _from, %{local_lease: nil} = state) do
    {:reply, {:error, :lost}, state}
  end

  # Renewal keeps the machine ID and only swaps the token and expiry, so factories stay enabled.
  # A rejected renewal leaves the old lease in place until the caller clears it or its timer fires.
  def handle_call({:renew, strategy_lease, ttl_ms, started_at}, _from, state) do
    with true <- valid?(state.local_lease),
         machine_id = state.local_lease.machine_id,
         :ok <- verify_lease(machine_id, ttl_ms),
         {:ok, new_local} <- build_local_lease(machine_id, strategy_lease, ttl_ms, started_at) do
      {:reply, {:ok, new_local}, arm(state, new_local)}
    else
      # Expired but the timer message hasn't been handled yet; handle it here and now
      false -> {:reply, {:error, :lost}, clear(state, :expired)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:clear, reason}, _from, state), do: {:reply, :ok, clear(state, reason)}

  @impl true
  def handle_info({:timeout, timer, :expired}, %{timer: timer} = state) do
    {:noreply, clear(state, :expired)}
  end

  # A cancelled timer can still have delivered its message; only the current timer may expire the lease
  def handle_info({:timeout, _stale_timer, :expired}, state), do: {:noreply, state}

  # Without the store there is no expiry timer, so factories must not outlive it
  @impl true
  def terminate(_reason, state) do
    clear(state, nil)
    :ok
  end

  ###########
  # Private #
  ###########

  defp verify_lease(machine_id, ttl_ms)
  defp verify_lease(id, _) when id not in 0..@machine_id_limit, do: {:error, :illegal_machine_id}
  defp verify_lease(_, ttl_ms) when not is_integer(ttl_ms), do: {:error, :illegal_ttl}
  defp verify_lease(_, ttl_ms) when ttl_ms < @min_lease_ttl, do: {:error, :illegal_ttl}
  defp verify_lease(_, _), do: :ok

  # Expiry counts from when the strategy call started, not when it returned, so slow calls can't
  # stretch the lease. A call slow enough to use up the whole window is rejected as expired.
  defp build_local_lease(machine_id, strategy_lease, ttl_ms, started_at) do
    exp = started_at + ttl_ms - @lease_safety_margin
    new_local = %{machine_id: machine_id, strategy_lease: strategy_lease, expires_at_mono: exp}
    if valid?(new_local), do: {:ok, new_local}, else: {:error, :expired}
  end

  # Makes `lease` current and restarts the expiry timer for it.
  defp arm(state, local_lease) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = :erlang.start_timer(remaining_ms(local_lease), self(), :expired)
    %{state | local_lease: local_lease, timer: timer}
  end

  # Drops the lease and disables factories. A `nil` reason is silent (bootstrap); otherwise the
  # manager is told, but only after factories are off and only if a lease was actually held.
  defp clear(state, reason) do
    if state.timer, do: Process.cancel_timer(state.timer)
    Enum.each(state.instances, &Instances.disable/1)

    if state.local_lease && reason do
      manager = if state.lease_manager, do: GenServer.whereis(state.lease_manager)
      if manager, do: send(manager, {:lease_lost, state.local_lease, reason})
    end

    %{state | local_lease: nil, timer: nil}
  end
end
