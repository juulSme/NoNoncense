defmodule NoNoncense.MachineId.ConflictGuard do
  @moduledoc """
  Guards against machine ID conflicts between nodes. If a new node joins the cluster with the same ID, it is sent the machine IDs of all existing nodes, will become aware of the ID conflict and will call the `on_conflict` callback that can take action to prevent bad stuff from happening (for example, that the uniqueness guarantee of `NoNoncense` will no longer hold).

  By default, the `on_conflict` callback emergeny shuts down the entire node using `:erlang.halt/1` with status code 111.

  Of course, all of this only works if the nodes are actually connected to one another.
  """
  use GenServer
  require Logger

  @type opts :: [name: module(), on_conflict: (-> any()), machine_id: non_neg_integer()]

  @doc """
  Let's get this puppy going!
  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    on_conflict = opts[:on_conflict] || fn -> :erlang.halt(111) end
    machine_id = Keyword.fetch!(opts, :machine_id)
    init_at = System.system_time(:millisecond)
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
    GenServer.cast({state.name, node}, {:id_from, Node.self(), state})
    {:noreply, state}
  end

  def handle_info({:nodedown, _}, state), do: {:noreply, state}

  def handle_info(msg, state), do: unknown_message(:handle_info, msg, state)

  @impl true
  def handle_cast({:id_from, node, %{machine_id: others_id, init_at: others_init_at}}, state) do
    if state.machine_id == others_id do
      msg = "Node #{node} has the same machine ID (#{others_id}) as me (#{Node.self()})."

      if state.init_at >= others_init_at do
        Logger.critical("#{msg} I'm the newer node, taking evasive action!")
        state.on_conflict.()
      else
        Logger.critical("#{msg} I was here first, let the other guy fix it.")
      end
    else
      Logger.debug("Node #{node} with machine ID #{others_id} joined.")
    end

    {:noreply, state}
  end

  def handle_cast(msg, state), do: unknown_message(:handle_cast, msg, state)

  defp unknown_message(callback, msg, state) do
    Logger.warning("Unknown #{callback} message received: #{inspect(msg)}")
    {:noreply, state}
  end
end
