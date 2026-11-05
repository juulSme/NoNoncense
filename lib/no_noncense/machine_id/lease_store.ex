defmodule NoNoncense.MachineId.LeaseStore do
  @moduledoc """
  Holds the current machine ID lease and independently enforces its local expiry, so nonce
  factories are only enabled while a valid lease is held.

  The store knows nothing about how leases are acquired. `NoNoncense.MachineId.LeaseManager`
  talks to the strategy and records the outcome here; the store decides what that means for the
  factories and how long the lease may be trusted.

  ## Guarantees

    * **At most one lease**, made up of the machine ID, the strategy's opaque lease token and a
      local expiry.
    * **Factories follow the lease.** They are enabled when a lease is stored and disabled when it
      expires, is lost, or is discarded. Factories are also disabled when the store starts, since
      nothing is confirmed yet.
    * **Local expiry comes before the strategy's.** The lease is considered valid for its TTL
      minus a 10 second safety margin, counted from when the strategy call started. Generation
      stops before the machine ID can be handed to another node, and a slow strategy call cannot
      stretch the lease.
    * **Reads never return an expired lease.** `get/1` and `machine_id/1` return `nil` as soon as
      the local expiry has passed, even if the store has not yet processed the expiry itself.
    * **Independent of the manager.** The store is supervised ahead of the lease manager, so a
      manager restart finds the previous lease and can renew it instead of acquiring a new ID.
      Nothing here waits on strategy callbacks.

  ## Storing and renewing

  `put/5` stores a newly acquired lease and enables the factories with its machine ID. `renew/4`
  keeps the machine ID, replaces the token and expiry, and leaves the factories enabled. Both
  take the monotonic time at which the strategy call started, and both can refuse the lease:

    * `{:error, :illegal_ttl}` - the granted TTL is below 30 seconds.
    * `{:error, :expired}` - the call took long enough to use up the validity window.
    * `{:error, :lost}` - `renew/4` only: no lease is held, or it has already expired locally.

  A refused `put/5` changes nothing. A refused `renew/4` keeps the old lease, which then runs out
  on its own schedule. The caller still holds the refused lease with the strategy and is
  responsible for releasing it.

  ## Losing a lease

  A lease ends in one of three ways:

    * Its local expiry passes. The store disables the factories and notifies the manager with
      reason `:expired`.
    * `lose/2` is called, for example after the strategy confirms the lease is gone or the
      conflict guard detects a duplicate ID. The store disables the factories and notifies the
      manager with the given reason.
    * `discard/1` is called. This is the silent variant, used during bootstrap when the manager is
      deciding for itself what to do next. The factories are disabled but nobody is notified.

  The notification is `{:lease_lost, lease, reason}`, sent only if a lease was actually held, and
  only after the factories are disabled. It is best-effort: if the manager is not running it is
  dropped.
  """

  # Implementation notes:
  #
  #   * State is `%{lease, timer, lease_manager, instances}`. `lease` is the single source of
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

  alias NoNoncense.MachineId.Instances

  # Shortest TTL a strategy may grant; anything below would leave no room for the margin and retries
  @min_ttl_ms 30_000
  # Local expiry is this much earlier than the strategy's, so we stop generating before the ID is free
  @safety_margin_ms 10_000

  @type lease :: %{machine_id: 0..511, lease: term(), expires_at_mono: integer()}
  @type error :: :expired | :lost | :illegal_ttl

  @doc "Starts an empty lease store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc "Returns the stored lease while it is inside its local validity window, else `nil`."
  @spec get(GenServer.name()) :: lease() | nil
  def get(name \\ __MODULE__), do: GenServer.call(name, :get)

  @doc "Returns the currently leased machine ID, or `nil` if no valid lease is held."
  @spec machine_id(GenServer.name()) :: 0..511 | nil
  def machine_id(name \\ __MODULE__) do
    with %{machine_id: machine_id} <- get(name), do: machine_id
  end

  @doc "Stores a newly acquired lease, using its operation start time in monotonic milliseconds."
  @spec put(GenServer.name(), 0..511, term(), integer(), integer()) ::
          {:ok, lease()} | {:error, :expired | :illegal_ttl}
  def put(name, machine_id, lease, ttl_ms, started_at) do
    GenServer.call(name, {:put, machine_id, lease, ttl_ms, started_at})
  end

  @doc "Replaces an active lease using its operation start time in monotonic milliseconds."
  @spec renew(GenServer.name(), term(), integer(), integer()) ::
          {:ok, lease()} | {:error, error()}
  def renew(name, lease, ttl_ms, started_at) do
    GenServer.call(name, {:renew, lease, ttl_ms, started_at})
  end

  @doc "Reports the current lease as lost, disabling factories and notifying the lease manager."
  @spec lose(GenServer.name(), term()) :: :ok
  def lose(name \\ __MODULE__, reason), do: GenServer.call(name, {:clear, reason})

  @doc "Discards a lease during bootstrap without notifying the lease manager."
  @spec discard(GenServer.name()) :: :ok
  def discard(name \\ __MODULE__), do: GenServer.call(name, {:clear, nil})

  @doc "Returns whether a stored lease remains inside its local validity window."
  @spec valid?(lease() | nil) :: boolean()
  def valid?(lease), do: remaining_ms(lease) > 0

  @doc "Milliseconds left in the lease's local validity window, clamped to zero."
  @spec remaining_ms(lease() | nil) :: non_neg_integer()
  def remaining_ms(%{expires_at_mono: expires_at_mono}) do
    max(0, expires_at_mono - System.monotonic_time(:millisecond))
  end

  def remaining_ms(_), do: 0

  @doc "How long before the strategy-granted expiry the local validity window ends."
  @spec safety_margin_ms() :: pos_integer()
  def safety_margin_ms(), do: @safety_margin_ms

  @impl true
  def init(state) do
    state = Map.merge(%{lease: nil, timer: nil, lease_manager: nil, instances: []}, state)

    # makes supervisor shutdowns call terminate/2
    Process.flag(:trap_exit, true)

    # Factories may have survived a manager restart but cannot run until a lease is confirmed.
    Enum.each(state.instances, &Instances.disable/1)
    {:ok, state}
  end

  # State: `lease` is the single source of truth (nil when none is held); `timer` is the pending
  # local-expiry timer for that lease. Factories are enabled only while a lease is held.
  @impl true
  def handle_call(:get, _from, %{lease: lease} = state) do
    # The expiry timer may not have fired yet, so check the clock rather than trusting `lease`
    {:reply, if(valid?(lease), do: lease), state}
  end

  # Acquisition: the machine ID comes from the strategy. Factories are enabled before the timer
  # is armed, and a rejected lease leaves the previous state untouched.
  def handle_call({:put, machine_id, lease, ttl_ms, started_at}, _from, state) do
    case build(machine_id, lease, ttl_ms, started_at) do
      {:ok, stored} ->
        Enum.each(state.instances, &Instances.re_init(Keyword.put(&1, :machine_id, machine_id)))
        {:reply, {:ok, stored}, arm(state, stored)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:renew, _lease, _ttl_ms, _started_at}, _from, %{lease: nil} = state) do
    {:reply, {:error, :lost}, state}
  end

  # Renewal keeps the machine ID and only swaps the token and expiry, so factories stay enabled.
  # A rejected renewal keeps the old lease, which then runs out on its own timer.
  def handle_call({:renew, lease, ttl_ms, started_at}, _from, %{lease: current} = state) do
    if valid?(current) do
      case build(current.machine_id, lease, ttl_ms, started_at) do
        {:ok, stored} -> {:reply, {:ok, stored}, arm(state, stored)}
        {:error, _reason} = error -> {:reply, error, state}
      end
    else
      # Expired but the timer message hasn't been handled yet; handle it here and now
      {:reply, {:error, :lost}, clear(state, :expired)}
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

  # Rejects TTLs below the minimum before doing arithmetic on them.
  defp build(_machine_id, _lease, ttl_ms, _started_at)
       when not (is_integer(ttl_ms) and ttl_ms >= @min_ttl_ms) do
    {:error, :illegal_ttl}
  end

  # Expiry counts from when the strategy call started, not when it returned, so slow calls can't
  # stretch the lease. A call slow enough to use up the whole window is rejected as expired.
  defp build(machine_id, lease, ttl_ms, started_at) do
    stored = %{
      machine_id: machine_id,
      lease: lease,
      expires_at_mono: started_at + ttl_ms - @safety_margin_ms
    }

    if valid?(stored), do: {:ok, stored}, else: {:error, :expired}
  end

  # Makes `lease` current and restarts the expiry timer for it.
  defp arm(state, lease) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = :erlang.start_timer(remaining_ms(lease), self(), :expired)
    %{state | lease: lease, timer: timer}
  end

  # Drops the lease and disables factories. A `nil` reason is silent (bootstrap); otherwise the
  # manager is told, but only after factories are off and only if a lease was actually held.
  defp clear(state, reason) do
    if state.timer, do: Process.cancel_timer(state.timer)
    Enum.each(state.instances, &Instances.disable/1)

    if state.lease && reason do
      manager = if state.lease_manager, do: GenServer.whereis(state.lease_manager)
      if manager, do: send(manager, {:lease_lost, state.lease, reason})
    end

    %{state | lease: nil, timer: nil}
  end
end
