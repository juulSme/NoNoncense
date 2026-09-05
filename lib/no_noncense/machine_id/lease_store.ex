defmodule NoNoncense.MachineId.LeaseStore do
  @moduledoc """
  Stores the current machine ID lease and independently enforces its local expiry.

  A restarted LeaseManager can renew the stored lease rather than acquiring another scarce machine
  ID. The store also disables factories and notifies the lease manager when the lease is lost,
  without waiting for potentially blocking strategy calls.
  """
  use GenServer

  alias NoNoncense.MachineId.LeaseManager.Instances

  @retry_delay 10
  @max_notification_retries 10
  @min_ttl_ms 30_000

  @type lease :: %{machine_id: 0..511, lease: term(), expires_at_mono: integer()}

  @doc "Starts an empty lease store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc "Returns the stored lease, or `nil` when no lease is active."
  @spec get(GenServer.name()) :: lease() | nil
  def get(name \\ __MODULE__), do: GenServer.call(name, :get)

  @doc "Stores a newly acquired lease."
  @spec put(GenServer.name(), 0..511, term(), pos_integer()) :: lease()
  def put(name \\ __MODULE__, machine_id, lease, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms >= @min_ttl_ms do
    GenServer.call(name, {:put, machine_id, lease, ttl_ms})
  end

  @doc "Replaces an active lease while retaining its machine ID."
  @spec renew(GenServer.name(), term(), pos_integer()) :: {:ok, lease()} | :lost
  def renew(name \\ __MODULE__, lease, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms >= @min_ttl_ms,
    do: GenServer.call(name, {:renew, lease, ttl_ms})

  @doc "Reports the current lease as lost, disabling factories and notifying the lease manager."
  @spec lose(GenServer.name(), term()) :: :ok
  def lose(name \\ __MODULE__, reason), do: GenServer.call(name, {:lose, reason})

  @doc "Discards a lease during bootstrap without notifying the lease manager."
  @spec discard(GenServer.name()) :: :ok
  def discard(name \\ __MODULE__), do: GenServer.call(name, :discard)

  @doc "Returns whether a stored lease remains inside its local validity window."
  @spec valid?(lease() | nil) :: boolean()
  def valid?(%{expires_at_mono: expires_at_mono}), do: now_mono() < expires_at_mono
  def valid?(_), do: false

  @impl true
  def init(state) do
    state =
      Map.merge(
        %{lease: nil, timer: nil, generation: 0, lease_manager: nil, instances: []},
        state
      )

    # Factories may have survived a manager restart but cannot run until a lease is confirmed.
    Enum.each(state.instances, &Instances.disable/1)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.lease, state}

  def handle_call({:put, machine_id, lease, ttl_ms}, _from, state) do
    stored_lease = new_lease(machine_id, lease, ttl_ms)
    {:reply, stored_lease, arm(state, stored_lease)}
  end

  def handle_call({:renew, lease, ttl_ms}, _from, %{lease: %{machine_id: machine_id}} = state) do
    stored_lease = new_lease(machine_id, lease, ttl_ms)
    {:reply, {:ok, stored_lease}, arm(state, stored_lease)}
  end

  def handle_call({:renew, _lease, _ttl_ms}, _from, state), do: {:reply, :lost, state}

  def handle_call({:lose, reason}, _from, state), do: {:reply, :ok, cleanup(state, reason)}
  def handle_call(:discard, _from, state), do: {:reply, :ok, cleanup(state, false)}

  @impl true
  def handle_info({:expired, generation}, %{generation: generation} = state),
    do: {:noreply, cleanup(state, :expired)}

  def handle_info({:expired, _generation}, state), do: {:noreply, state}

  def handle_info({:notify_lease_lost, lease, reason, retries}, state) do
    notify_lease_manager(state.lease_manager, lease, reason, retries)
    {:noreply, state}
  end

  defp arm(state, lease) do
    {_old_lease, state} = clear_lease(state)
    generation = state.generation + 1
    delay = max(0, lease.expires_at_mono - now_mono())
    timer = Process.send_after(self(), {:expired, generation}, delay)
    %{state | lease: lease, timer: timer, generation: generation}
  end

  defp cleanup(state, reason) do
    {lease, state} = clear_lease(state)
    Enum.each(state.instances, &Instances.disable/1)

    if lease && reason && state.lease_manager,
      do: notify_lease_manager(state.lease_manager, lease, reason, 0)

    state
  end

  defp clear_lease(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {state.lease, %{state | lease: nil, timer: nil}}
  end

  defp notify_lease_manager(lease_manager, lease, reason, retries) do
    manager = GenServer.whereis(lease_manager)
    retry? = retries < @max_notification_retries
    retry_msg = {:notify_lease_lost, lease, reason, retries + 1}

    cond do
      is_pid(manager) -> send(manager, {:lease_lost, lease, reason})
      retry? -> Process.send_after(self(), retry_msg, @retry_delay)
      true -> :ok
    end
  end

  defp new_lease(machine_id, lease, ttl_ms) do
    %{machine_id: machine_id, lease: lease, expires_at_mono: now_mono() + ttl_ms - 10_000}
  end

  defp now_mono(), do: :erlang.monotonic_time(:millisecond)
end
