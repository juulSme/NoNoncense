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
    * `:on_lease_lost` - called with the reason for the lease loss. Can be used to halt the entire node, for example. Note that on lease loss, all NoNoncense factories are always disabled to preserve uniqueness guarantees.

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
  directly managing the configured `NoNoncense` factories.

  Initial acquisition blocks startup. Once leased, the manager renews before the earlier of the
  configured renewal interval and the strategy-provided TTL. A confirmed loss or local expiry
  disables every configured factory, invokes `:on_lease_lost` with a reason, and schedules
  reacquisition. A successful reacquisition reinitializes the factories with the new machine ID.

  An ambiguous renewal failure is retried while the known-valid window remains open. On graceful
  shutdown, the manager makes a best-effort call to the strategy's `release/2` callback when it
  still holds a lease.

  ## Options

  #{@options_docs}
  """
  use GenServer
  use NoNoncense.Constants
  alias NoNoncense.MachineId.LeaseManager.{Backoff, Bootstrap, Timers, StateChange}
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

  @type opts :: [opt()]

  @default_state %{
    name: __MODULE__,
    strategy: nil,
    strategy_opts: [],
    lease_duration: 8 * 60 * 60 * 1000,
    renew_interval: 30 * 60 * 1000,
    acquire_timeout: 60 * 1000,
    instances: [],
    lease_cache: nil,
    on_lease_lost: nil,
    # internal
    machine_id: nil,
    lease: nil,
    expires_at_mono: 0,
    leased?: false,
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
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Enum.into(opts, @default_state)
    # init/1 blocks while acquiring; the default 5s GenServer init timeout must not apply
    GenServer.start_link(__MODULE__, opts, name: opts.name, timeout: :infinity)
  end

  @doc "Returns the currently leased machine ID."
  @spec machine_id(GenServer.name()) :: non_neg_integer()
  def machine_id(name \\ __MODULE__), do: GenServer.call(name, :machine_id)

  @doc "Signal to the lease manager that the lease was lost because of some external reason"
  @spec lease_lost(GenServer.name()) :: :ok
  def lease_lost(name \\ __MODULE__), do: GenServer.call(name, :lease_lost)

  ##########
  # Server #
  ##########

  @impl true
  def init(state) do
    # ensures terminate/2 is called on supervisor-initiated shutdown (SIGTERM, app stop)
    Process.flag(:trap_exit, true)

    case Bootstrap.acquire_initial_id(state) do
      state when state.leased? -> {:ok, state}
      _ -> {:stop, :lease_acquisition_failed}
    end
  end

  @impl true
  def handle_call(:machine_id, _from, state), do: {:reply, state.machine_id, state}

  def handle_call(:lease_lost, _from, state) do
    {:reply, :ok, StateChange.on_lost(state, :external)}
  end

  def handle_call(msg, _from, state), do: unknown_message(:handle_call, msg, state)

  @impl true
  def handle_info({msg, gen}, state)
      when msg in [:renew, :expired, :reacquire] and gen != state.generation do
    Logger.debug("Stale message received: #{msg}")
    {:noreply, state}
  end

  def handle_info({:renew, _}, state) when state.leased? do
    fn -> state.strategy.renew(state.lease, state.lease_duration, state.strategy_opts) end
    |> Telemetry.lease_operation(:renew, %{strategy: state.strategy, source: :scheduled})
    |> case do
      {:ok, lease, ttl_ms} ->
        Logger.debug("Lease of ID #{state.machine_id} renewed for #{div(ttl_ms, 1000)}s.")
        {:noreply, StateChange.on_renewed(state, lease, ttl_ms)}

      {:error, :lost, reason} ->
        {:noreply, StateChange.on_lost(state, reason)}

      {:error, :retry, reason} ->
        delay = Backoff.delay(state.attempt, 1000, state.renew_interval)

        Logger.warning("Lease renewal failed (retry in #{div(delay, 1000)}s): #{inspect(reason)}")
        Telemetry.lease_retry(:renew, state.attempt, delay, reason)

        state
        |> Timers.schedule(:renew, delay)
        |> then(fn state -> {:noreply, %{state | attempt: state.attempt + 1}} end)
    end
  end

  def handle_info({:renew, _}, state) do
    Logger.warning("Lease of ID #{state.machine_id} can't be renewed because it was lost.")
    {:noreply, state}
  end

  def handle_info({:expired, _}, state), do: {:noreply, StateChange.on_lost(state, :expired)}

  def handle_info({:reacquire, _}, state) do
    fn -> state.strategy.acquire(state.lease_duration, state.strategy_opts) end
    |> Telemetry.lease_operation(:acquire, %{strategy: state.strategy, source: :reacquire})
    |> case do
      {:ok, machine_id, lease, ttl_ms} ->
        {:noreply, StateChange.on_renewed(%{state | machine_id: machine_id}, lease, ttl_ms)}

      {:error, reason} ->
        delay = Backoff.delay(state.attempt, 1000, state.renew_interval)
        Logger.warning("Reacquisition failed (retry in #{div(delay, 1000)}s): #{inspect(reason)}")
        Telemetry.lease_retry(:acquire, state.attempt, delay, reason)

        state
        |> Timers.schedule(:reacquire, delay)
        |> then(fn state -> {:noreply, %{state | attempt: state.attempt + 1}} end)
    end
  end

  def handle_info(msg, state), do: unknown_message(:handle_info, msg, state)

  @impl true
  def terminate(_reason, state) do
    if state.leased? do
      fn -> state.strategy.release(state.lease, state.strategy_opts) end
      |> Telemetry.lease_operation(:release, %{strategy: state.strategy, source: :shutdown})
    end

    Logger.info("Lease released.")
    :ok
  end

  ###########
  # Private #
  ###########

  @doc false
  def options_docs(), do: @shared_options_docs

  defp unknown_message(callback, msg, state) do
    Logger.warning("Unknown #{callback} message received: #{inspect(msg)}")
    {:noreply, state}
  end
end
