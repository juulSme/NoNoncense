defmodule NoNoncense.MachineId.LeaseManager do
  @shared_options_docs """
    * `:strategy` (required) - a module implementing the `NoNoncense.MachineId.Strategy` behaviour
    * `:strategy_opts` - passed as-is to the strategy's callbacks (default `[]`)
    * `:lease_duration` - the duration, in ms, to request from the strategy on every
      `acquire`/`renew` call (the strategy may grant a different actual duration; default 8 hours)
    * `:renew_interval` - how often to renew, in ms; should be comfortably shorter than the
      lease's actual TTL to allow for retries (default 30 minutes)
    * `:acquire_timeout` - max total time, in ms, to keep retrying acquisition at boot before giving up
      and failing `start_link/1` (default `60_000`; pass `:infinity` to retry forever)
    * `:callback_timeout` - maximum time, in ms, to wait for an acquire, renew, or release callback
      (default `5_000`)
    * `:on_lease_lost` - called with the reason for the lease loss, after every configured factory
      has been disabled to preserve uniqueness guarantees. Can be used to halt the entire node, for
      example. Notifications are best-effort if the lease manager is unavailable.

  ### Lease duration and renew interval

  The defaults leave a wide recovery window for a temporary connection loss to your coordinator
  (e.g. your database), while still renewing well ahead of the lease's expiration. If you
  override these, keep that balance intact - most practical uses of nonce generation, such as
  ID generation, will grind to a halt if generation stops, so favor conservative, generous
  durations over aggressive, short ones. Machine IDs are meant to stay static for the lifetime
  of the node, so there's little to be gained from renewing more aggressively.
  """
  @options_docs """
    * `:name` - registered name (default `#{inspect(__MODULE__)}`)
  #{@shared_options_docs}
  """

  @moduledoc false

  # Implementation notes:
  #
  #   * The manager is a small state machine driven by a single timer. While a lease is held the
  #     timer is `{:renew, ref}`. After a loss it is `{:acquire, ref}`, which also paces retries.
  #     After a loss with a deterministic strategy there is no timer at all, since reacquiring
  #     would only return the same ID.
  #
  #   * Only the store decides that a lease is gone. The manager never clears it itself: it asks
  #     the store to `lose` the lease and handles the `{:lease_lost, lease, reason}` message the
  #     store sends once the factories are off. All loss handling runs from that one message,
  #     whatever the cause: local expiry, a confirmed loss from the strategy, the conflict guard,
  #     or a call to `LeaseStore.lose/2` from anywhere else.
  #
  #   * Strategy calls go through `StrategyCall` and block this process for at most
  #     `:callback_timeout`. The store keeps enforcing expiry meanwhile, so a stuck strategy
  #     cannot keep factories enabled past the lease.
  #
  #   * Renewal is scheduled one safety margin ahead of the earlier of `:renew_interval` and the
  #     local expiry. A failed renewal keeps the lease and retries with backoff; if the retries
  #     outlast the lease, the store's expiry takes over.
  #
  #   * Only a graceful stop (`:normal` or `:shutdown`) releases the lease. After a crash the lease
  #     stays in the store, so the restarted manager renews it instead of acquiring a new ID.
  #
  #   * `:on_lease_lost` runs inside this process, after reacquisition is scheduled. A callback
  #     that blocks therefore delays everything else the manager does.
  use GenServer
  use NoNoncense.Constants

  alias NoNoncense.MachineId.LeaseStore
  alias NoNoncense.MachineId.LeaseManager.{Backoff, Bootstrap, StrategyCall}
  alias NoNoncense.Telemetry
  require Logger

  @type opt ::
          NoNoncense.MachineId.lease_opt()
          | {:name, GenServer.name()}
          | {:lease_store, GenServer.name()}
          | {:task_supervisor, GenServer.server()}

  @default_state %{
    name: __MODULE__,
    strategy: nil,
    strategy_opts: [],
    lease_duration: 8 * 60 * 60 * 1000,
    renew_interval: 30 * 60 * 1000,
    acquire_timeout: 60 * 1000,
    callback_timeout: 5_000,
    task_supervisor: nil,
    lease_store: nil,
    on_lease_lost: nil,
    # Failures in a row during the current outage; sets the backoff, reset on success or loss
    attempt: 1,
    # {:renew | :acquire, ref} of the single pending timer
    timer: nil
  }

  @doc """
  Starts the lease manager, blocking until the initial lease is acquired (or `:acquire_timeout`
  elapses, in which case `start_link/1` fails).

  ## Options

  #{@options_docs}
  """
  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) do
    for key <- [:strategy, :lease_store, :task_supervisor], !opts[key] do
      raise(ArgumentError, ":#{key} must be provided")
    end

    callback_timeout = Keyword.get(opts, :callback_timeout, 5_000)

    unless is_integer(callback_timeout) and callback_timeout > 0 do
      raise ArgumentError, ":callback_timeout must be a positive integer"
    end

    opts = Enum.into(opts, @default_state)
    # init/1 blocks while acquiring; the default 5s GenServer init timeout must not apply
    GenServer.start_link(__MODULE__, opts, name: opts.name, timeout: :infinity)
  end

  @doc false
  def options_docs(), do: @shared_options_docs

  ##########
  # Server #
  ##########

  @impl true
  def init(state) do
    # ensures terminate/2 is called on supervisor-initiated shutdown (SIGTERM, app stop)
    Process.flag(:trap_exit, true)

    # Blocks until a lease is held, so nothing starts after this manager without a machine ID
    case Bootstrap.acquire_initial_id(state) do
      {:ok, lease} ->
        state = schedule_renew(state, lease)
        {:ok, state}

      {:error, reason} ->
        # Bootstrap has already discarded the store, which disables the factories
        if state.on_lease_lost, do: state.on_lease_lost.(reason)
        {:stop, :lease_acquisition_failed}
    end
  end

  # The store's notification that the lease is gone.
  @impl true
  def handle_info({:lease_lost, lease, reason}, state) do
    # a replacement lease in the store means this notification is stale
    if LeaseStore.get(state.lease_store) in [nil, lease] do
      {:noreply, on_lost(state, lease, reason)}
    else
      {:noreply, state}
    end
  end

  # A timer message counts only if it is the pending timer. The timer is cleared first so the
  # handler is free to set the next one.
  def handle_info({:timeout, ref, :renew}, %{timer: {:renew, ref}} = state) do
    {:noreply, renew(%{state | timer: nil})}
  end

  def handle_info({:timeout, ref, :acquire}, %{timer: {:acquire, ref}} = state) do
    {:noreply, reacquire(%{state | timer: nil})}
  end

  # A cancelled timer may already have delivered its message
  def handle_info({:timeout, _stale_ref, kind}, state) when kind in [:renew, :acquire] do
    {:noreply, state}
  end

  def handle_info(msg, state), do: unknown_message(:handle_info, msg, state)

  # Graceful stops hand the lease back. Discarding first turns the factories off and is silent,
  # so we are not notified of our own shutdown. Any other exit leaves the lease in the store.
  @impl true
  def terminate(reason, state) when reason in [:normal, :shutdown] do
    local_lease = LeaseStore.get(state.lease_store)
    :ok = LeaseStore.discard(state.lease_store)
    if local_lease, do: StrategyCall.release(state, local_lease.strategy_lease, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ###########
  # Private #
  ###########

  # The renew timer fired. Each outcome either schedules the next renewal, schedules a retry, or
  # leaves the store to drive recovery through its loss notification.
  defp renew(state) do
    with local_lease when not is_nil(local_lease) <- LeaseStore.get(state.lease_store),
         {:ok, renewed_lease} <- StrategyCall.renew(state, local_lease.strategy_lease, :scheduled) do
      Logger.debug("Lease of ID #{renewed_lease.machine_id} renewed.")
      schedule_renew(state, renewed_lease)
    else
      # The store has dropped the lease or is about to expire it, and notifies us either way
      nil -> state
      # Ambiguous failure: the lease is still valid locally, so keep it and try again
      {:error, :retry, reason} -> retry(state, :renew, reason)
      # Only the strategy knows; the store's notification triggers on_lost/3
      {:error, :lost, reason} -> tap(state, &LeaseStore.lose(&1.lease_store, reason))
      # StrategyCall has already reported the loss to the store
      {:error, :rejected, _reason} -> state
    end
  end

  # The acquire timer fired after a loss. A success re-enables the factories (the store does that)
  # and goes back to renewing; anything else backs off and tries again.
  defp reacquire(state) do
    case StrategyCall.acquire(state, :reacquire) do
      {:ok, lease} ->
        Logger.info("Lease reacquired; new ID is #{lease.machine_id}")
        schedule_renew(state, lease)

      {:error, _kind, reason} ->
        retry(state, :acquire, reason)
    end
  end

  # Runs once per lost lease, when the store reports it. The factories are already off by now.
  defp on_lost(state, local_lease, reason) do
    Logger.critical("Lease of ID #{local_lease.machine_id} lost: #{inspect(reason)}")
    Telemetry.lease_lost(reason, LeaseStore.remaining_ms(local_lease))

    # The old token is released in the background so reacquisition does not wait for it
    StrategyCall.release_async(state, local_lease.strategy_lease)
    state = cancel_timer(state)
    # A deterministic strategy would hand back the same ID, so there is nothing to reacquire
    state = if state.strategy.deterministic?(), do: state, else: set_timer(state, :acquire, 0)

    if state.on_lease_lost, do: state.on_lease_lost.(reason)
    %{state | attempt: 1}
  end

  # Schedules another attempt of `kind` (`:renew` or `:acquire`) after a backoff that grows with
  # `attempt` and never exceeds `:renew_interval`.
  defp retry(state, kind, reason) do
    delay = Backoff.delay(state.attempt, 1000, state.renew_interval)
    label = if kind == :renew, do: "Lease renewal", else: "Reacquisition"
    Logger.warning("#{label} failed (retry in #{delay}ms): #{inspect(reason)}")
    Telemetry.lease_retry(kind, state.attempt, delay, reason)

    state |> set_timer(kind, delay) |> Map.update!(:attempt, &(&1 + 1))
  end

  # The delay is measured from now: `remaining_ms` already excludes the safety margin, and
  # subtracting it again leaves one margin of retry room before the local expiry.
  defp schedule_renew(state, lease) do
    until_expiry = min(state.renew_interval, LeaseStore.remaining_ms(lease))
    delay = max(0, until_expiry - @lease_safety_margin)
    state |> set_timer(:renew, delay) |> Map.put(:attempt, 1)
  end

  # At most one timer is pending; setting a new one cancels the old.
  defp set_timer(state, kind, delay) do
    state = cancel_timer(state)
    %{state | timer: {kind, :erlang.start_timer(delay, self(), kind)}}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: {_kind, ref}} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp unknown_message(callback, msg, state) do
    Logger.warning("Unknown #{callback} message received: #{inspect(msg)}")
    {:noreply, state}
  end
end
