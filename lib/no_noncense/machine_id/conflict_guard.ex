defmodule NoNoncense.MachineId.ConflictGuard do
  @moduledoc """
  Guards against machine ID conflicts between nodes by broadcasting each node's machine ID to
  newly connected peers and calling `on_conflict` whenever a duplicate is detected.

  ## When to use

  `ConflictGuard` is useful when running `NoNoncense` with strategies that do not provide
  server-side uniqueness guarantees, such as `NoNoncense.MachineId.Strategy.HostIdentifiers` or
  `NoNoncense.MachineId.Strategy.EnvironmentVariable`. It adds a runtime cross-check that a
  split-brain or misconfiguration hasn't caused two nodes to end up with the same ID.

  For lease-based strategies (`SqlLease`, `RedisLease`), the external coordinator already
  prevents duplicate IDs, so `ConflictGuard` provides little additional value — though it
  won't hurt to enable it.

  > #### Requires distributed Erlang {: .warning}
  >
  > `ConflictGuard` only works when nodes are connected to each other via distributed Erlang
  > (i.e. started with `--name` / `--sname` and a shared cookie). Without it, the conflict
  > checks never run.

  ## Default action

  When a conflict is detected, the newer node calls `on_conflict`, which defaults to halting
  the node immediately via `:erlang.halt(111)`.

  ## Usage

  `NoNoncense.MachineId` starts `ConflictGuard` by default. Pass
  `enable_conflict_guard?: false` to disable it. When enabled through `NoNoncense.MachineId`,
  the supervisor derives the guard's name and resolves the machine ID through its lease manager.
  A conflict signals the lease manager that its lease was lost:

      {NoNoncense.MachineId,
       strategy: NoNoncense.MachineId.Strategy.HostIdentifiers,
       instances: [[base_key: System.fetch_env!("BASE_KEY")]]}

  When started manually, supply `:machine_id` to resolve the ID,
  and `:on_conflict` to override the default halt behaviour.
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
