defmodule NoNoncense.MachineId.ConflictGuard do
  @moduledoc """
  Checks machine IDs with newly connected Erlang nodes and calls `:on_conflict` when this guard
  is the newer of two guards with the same ID.

  ## When to use

  The guard is most useful with static strategies such as
  `NoNoncense.MachineId.Strategy.HostIdentifiers` and
  `NoNoncense.MachineId.Strategy.EnvironmentVariable`, which do not coordinate IDs externally.

  > #### Requires distributed Erlang {: .warning}
  >
  > `ConflictGuard` only works when nodes are connected to each other via distributed Erlang
  > (i.e. started with `--name` / `--sname` and a shared cookie). Without it, the conflict
  > checks never run. Guards on peer nodes must use the same registered name. Checks occur on
  > connection, not continuously or when a machine ID changes.

  ## Usage

  `NoNoncense.MachineId` starts `ConflictGuard` by default. A conflict marks the local lease as
  lost, disabling factories and triggering the configured `:on_lease_lost` callback:

      {NoNoncense.MachineId,
       strategy: NoNoncense.MachineId.Strategy.HostIdentifiers,
       strategy_opts: [node_list: [:"myapp@10.0.0.1", :"myapp@10.0.0.2"]],
       on_lease_lost: fn reason -> Logger.critical(inspect(reason)) end,
       instances: [[base_key: System.fetch_env!("BASE_KEY")]]}

  Pass `enable_conflict_guard?: false` to disable it.

  To run it on its own, supply `:machine_id` as an integer or zero-arity function. The
  `:on_conflict` callback defaults to halting the node via `:erlang.halt(111)`:

      {NoNoncense.MachineId.ConflictGuard,
       machine_id: fn -> NoNoncense.MachineId.Strategy.HostIdentifiers.id!(node_list: nodes) end,
       on_conflict: fn -> System.stop(1) end}

  Guard start times use the system clock; equal timestamps cause both guards to act.
  """
  use GenServer
  alias NoNoncense.Telemetry
  require Logger

  @type opt ::
          {:name, GenServer.name()}
          | {:on_conflict, (-> any())}
          | {:machine_id, integer() | (-> integer())}

  @doc "Starts the conflict guard."
  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    on_conflict = opts[:on_conflict] || fn -> :erlang.halt(111) end

    machine_id =
      case opts[:machine_id] do
        id when is_integer(id) -> fn -> id end
        fun when is_function(fun, 0) -> fun
        _ -> raise ArgumentError, "machine ID is required as a literal or getter/0"
      end

    init_at = System.system_time(:microsecond)
    state = %{machine_id: machine_id, name: name, init_at: init_at, on_conflict: on_conflict}
    GenServer.start_link(__MODULE__, state, name: name)
  end

  ##########
  # Server #
  ##########

  @impl true
  def init(state) do
    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    :net_kernel.monitor_nodes(true, [])
    {:noreply, state}
  end

  def handle_continue(msg, state), do: unknown_message(:handle_continue, msg, state)

  @impl true
  def handle_info({:nodeup, node}, state) do
    GenServer.cast(
      {state.name, node},
      {:id_from, Node.self(), %{state | machine_id: state.machine_id.()}}
    )

    {:noreply, state}
  end

  def handle_info({:nodedown, _}, state), do: {:noreply, state}

  def handle_info(msg, state), do: unknown_message(:handle_info, msg, state)

  @impl true
  def handle_cast({:id_from, node, %{machine_id: others_id, init_at: others_init_at}}, state) do
    machine_id = state.machine_id.()

    cond do
      is_nil(machine_id) ->
        Logger.debug("Node #{node} joined but this node has no machine ID to compare with")
        Telemetry.peer_checked(:no_local_id)

      machine_id != others_id ->
        Logger.debug("Node #{node} with machine ID #{others_id} joined")
        Telemetry.peer_checked(:match)

      state.init_at >= others_init_at ->
        Logger.critical("Node #{node} has a conflicting ID; this node will resolve the conflict")
        Telemetry.peer_checked(:conflict)
        Telemetry.conflict(:local_node)
        state.on_conflict.()

      true ->
        Logger.critical("Node #{node} has a conflicting ID; it will resolve the conflict")
        Telemetry.peer_checked(:conflict)
        Telemetry.conflict(:remote_node)
    end

    {:noreply, state}
  end

  def handle_cast(msg, state), do: unknown_message(:handle_cast, msg, state)

  defp unknown_message(callback, msg, state) do
    Logger.warning("Unknown #{callback} message received: #{inspect(msg)}")
    {:noreply, state}
  end
end
