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
    * `:on_lease_lost` - called with the reason for the lease loss, after the expiration manager
      has already disabled every configured factory to preserve uniqueness guarantees. Can be
      used to halt the entire node, for example.

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

  @moduledoc """
  Acquires and renews a machine ID lease through a pluggable `NoNoncense.MachineId.Strategy`,
  managing the configured `NoNoncense` factories together with `ExpirationManager`.

  Initial acquisition blocks startup. Once leased, the manager renews before the earlier of the
  configured renewal interval and the strategy-provided TTL. A confirmed loss or local expiry
  disables every configured factory, asynchronously releases the lost strategy lease, invokes
  `:on_lease_lost` with a reason, and schedules reacquisition. A successful reacquisition
  reinitializes the factories with the new machine ID.

  An ambiguous renewal failure is retried while the known-valid window remains open. On graceful
  shutdown, the manager makes a best-effort call to the strategy's `release/2` callback when it
  still holds a lease.

  `LeaseCache` is the authoritative local lease record, surviving a crash of this process so a
  restart can renew the prior lease instead of acquiring a new one. `ExpirationManager` owns the
  cache's expiry timer and disables factories independently of potentially blocking strategy
  callbacks performed here.

  ## Options

  #{@options_docs}
  """
  use GenServer

  alias NoNoncense.MachineId.{ExpirationManager, LeaseCache}
  alias NoNoncense.MachineId.LeaseManager.{Backoff, Bootstrap, Instances, Timers}
  alias NoNoncense.Telemetry
  require Logger

  @type opt ::
          {:name, GenServer.name()}
          | {:strategy, module()}
          | {:strategy_opts, keyword()}
          | {:lease_duration, pos_integer()}
          | {:renew_interval, pos_integer()}
          | {:acquire_timeout, pos_integer() | :infinity}
          | {:on_lease_lost, (term() -> any())}
          | {:instances, [NoNoncense.init_opt()]}
          | {:lease_cache, GenServer.name()}
          | {:expiration_manager, GenServer.name()}

  @default_state %{
    name: __MODULE__,
    strategy: nil,
    strategy_opts: [],
    lease_duration: 8 * 60 * 60 * 1000,
    renew_interval: 30 * 60 * 1000,
    acquire_timeout: 60 * 1000,
    instances: [],
    lease_cache: nil,
    expiration_manager: nil,
    on_lease_lost: nil,
    attempt: 1,
    timers: %{},
    generation: 0
  }

  @doc """
  Starts the lease manager, blocking until the initial lease is acquired (or `:acquire_timeout`
  elapses, in which case `start_link/1` fails).

  ## Options

  #{@options_docs}
  """
  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) do
    opts = Enum.into(opts, @default_state)
    # init/1 blocks while acquiring; the default 5s GenServer init timeout must not apply
    GenServer.start_link(__MODULE__, opts, name: opts.name, timeout: :infinity)
  end

  @doc "Returns the currently leased machine ID, or `nil` if no lease is currently held."
  @spec machine_id(GenServer.name()) :: non_neg_integer() | nil
  def machine_id(name \\ __MODULE__), do: GenServer.call(name, :machine_id)

  @doc "Signal to the lease manager that the lease was lost because of some external reason"
  @spec lease_lost(GenServer.name(), term()) :: :ok
  def lease_lost(name \\ __MODULE__, reason \\ :external),
    do: GenServer.call(name, {:lease_lost, reason})

  ##########
  # Server #
  ##########

  @impl true
  def init(state) do
    # ensures terminate/2 is called on supervisor-initiated shutdown (SIGTERM, app stop)
    Process.flag(:trap_exit, true)

    case Bootstrap.acquire_initial_id(state) do
      {:ok, lease} ->
        state = state |> re_init_instances(lease.machine_id) |> schedule_renew(lease)
        {:ok, state}

      {:error, reason} ->
        if state.on_lease_lost, do: state.on_lease_lost.(reason)
        {:stop, :lease_acquisition_failed}
    end
  end

  @impl true
  def handle_call(:machine_id, _from, state) do
    machine_id =
      case LeaseCache.get(state.lease_cache) do
        lease when is_map(lease) -> if LeaseCache.valid?(lease), do: lease.machine_id, else: nil
        nil -> nil
      end

    {:reply, machine_id, state}
  end

  def handle_call({:lease_lost, reason}, _from, state) do
    :ok = ExpirationManager.lose(state.expiration_manager, reason)
    {:reply, :ok, state}
  end

  def handle_call(msg, _from, state), do: unknown_message(:handle_call, msg, state)

  @impl true
  def handle_info({:lease_lost, lease, reason}, state) do
    case LeaseCache.get(state.lease_cache) do
      nil -> {:noreply, on_lost(state, lease, reason)}
      ^lease -> {:noreply, on_lost(state, lease, reason)}
      _replacement -> {:noreply, state}
    end
  end

  def handle_info({message, generation}, state)
      when message in [:renew, :reacquire] and generation != state.generation,
      do: {:noreply, state}

  def handle_info({:renew, _generation}, state), do: {:noreply, renew(state)}
  def handle_info({:reacquire, _generation}, state), do: {:noreply, reacquire(state)}
  def handle_info(msg, state), do: unknown_message(:handle_info, msg, state)

  @impl true
  def terminate(reason, state) when reason in [:normal, :shutdown] do
    lease = LeaseCache.get(state.lease_cache)
    Enum.each(state.instances, &Instances.disable/1)
    :ok = ExpirationManager.lose(state.expiration_manager, :shutdown)
    if lease, do: release(state, lease, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ###########
  # Private #
  ###########

  @doc false
  def options_docs(), do: @shared_options_docs

  defp renew(state) do
    case LeaseCache.get(state.lease_cache) do
      lease when is_map(lease) ->
        if LeaseCache.valid?(lease) do
          renew_lease(state, lease)
        else
          :ok = ExpirationManager.lose(state.expiration_manager, :expired)
          state
        end

      nil ->
        :ok = ExpirationManager.lose(state.expiration_manager, :expired)
        state
    end
  end

  defp renew_lease(state, lease) do
    fn -> state.strategy.renew(lease.lease, state.lease_duration, state.strategy_opts) end
    |> Telemetry.lease_operation(:renew, %{strategy: state.strategy, source: :scheduled})
    |> case do
      {:ok, renewed_lease, ttl_ms} when ttl_ms >= 30_000 ->
        case ExpirationManager.renew(state.expiration_manager, renewed_lease, ttl_ms) do
          {:ok, renewed_cache} ->
            Logger.debug("Lease of ID #{renewed_cache.machine_id} renewed for #{ttl_ms}ms.")
            schedule_renew(state, renewed_cache)

          :lost ->
            state
        end

      {:ok, _, _} ->
        :ok = ExpirationManager.lose(state.expiration_manager, :illegal_ttl)
        state

      {:error, :lost, reason} ->
        :ok = ExpirationManager.lose(state.expiration_manager, reason)
        state

      {:error, :retry, reason} ->
        retry(state, :renew, reason)
    end
  end

  defp reacquire(state) do
    fn -> state.strategy.acquire(state.lease_duration, state.strategy_opts) end
    |> Telemetry.lease_operation(:acquire, %{strategy: state.strategy, source: :reacquire})
    |> case do
      {:ok, machine_id, lease, ttl_ms} when ttl_ms >= 30_000 ->
        {:ok, cached_lease} =
          ExpirationManager.acquire(state.expiration_manager, machine_id, lease, ttl_ms)

        Logger.info("Lease reacquired; new ID is #{machine_id}, valid for #{ttl_ms}ms")
        state |> re_init_instances(cached_lease.machine_id) |> schedule_renew(cached_lease)

      {:ok, _, _, _} ->
        retry(state, :reacquire, :illegal_ttl)

      {:error, reason} ->
        retry(state, :reacquire, reason)
    end
  end

  defp on_lost(state, lease, reason) do
    Logger.critical("Lease of ID #{lease.machine_id} lost: #{inspect(reason)}")
    Telemetry.lease_lost(reason, max(0, lease.expires_at_mono - now_mono()))

    state = Timers.clear(state)

    Task.start(fn -> release(state, lease, :loss) end)

    state =
      if state.strategy.deterministic?(), do: state, else: Timers.schedule(state, :reacquire, 0)

    if state.on_lease_lost, do: state.on_lease_lost.(reason)
    %{state | attempt: 1}
  end

  defp retry(state, operation, reason) do
    delay = Backoff.delay(state.attempt, 1000, state.renew_interval)
    label = if operation == :renew, do: "Lease renewal", else: "Reacquisition"
    Logger.warning("#{label} failed (retry in #{delay}ms): #{inspect(reason)}")

    Telemetry.lease_retry(
      if(operation == :renew, do: :renew, else: :acquire),
      state.attempt,
      delay,
      reason
    )

    state |> Timers.schedule(operation, delay) |> Map.update!(:attempt, &(&1 + 1))
  end

  defp schedule_renew(state, lease) do
    remaining_ttl = max(0, lease.expires_at_mono - now_mono())
    delay = max(0, min(state.renew_interval, remaining_ttl) - 10_000)
    state |> Timers.clear() |> Timers.schedule(:renew, delay) |> Map.put(:attempt, 1)
  end

  defp re_init_instances(state, machine_id) do
    state.instances
    |> Enum.map(&Keyword.put(&1, :machine_id, machine_id))
    |> Enum.each(&Instances.re_init/1)

    state
  end

  defp release(state, lease, source) do
    fn -> state.strategy.release(lease.lease, state.strategy_opts) end
    |> Telemetry.lease_operation(:release, %{strategy: state.strategy, source: source})
  end

  defp now_mono(), do: :erlang.monotonic_time(:millisecond)

  defp unknown_message(callback, msg, state) do
    Logger.warning("Unknown #{callback} message received: #{inspect(msg)}")
    {:noreply, state}
  end
end
