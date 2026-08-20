defmodule NoNoncense.MachineId.ExpirationManager do
  @moduledoc """
  Tracks the local expiry of the currently held lease, independently of `LeaseManager`.

  `LeaseManager` can block for a while on strategy calls (a lease coordinator being slow or
  unreachable, for example). Since a stale lease would compromise machine ID uniqueness, expiry
  handling can't wait for `LeaseManager` to become available again. `ExpirationManager` is the
  single source of truth for whether the current lease is still valid instead: it writes every
  acquired or renewed lease to `LeaseCache`, arms a timer for its local expiry, and disables the
  configured `NoNoncense` factories (notifying `LeaseManager` asynchronously) the moment that
  timer fires or the lease is otherwise reported lost - all independently of `LeaseManager`.
  """
  use GenServer

  alias NoNoncense.MachineId.LeaseCache
  alias NoNoncense.MachineId.LeaseManager.Instances

  @type opt ::
          {:name, GenServer.name()}
          | {:lease_cache, GenServer.name()}
          | {:lease_manager, GenServer.name()}
          | {:instances, [Instances.instance_opts()]}

  @doc """
  Starts the expiration manager, resuming a still-valid cached lease's expiry timer if one
  exists, or clearing it (and disabling the configured factories) if it has already expired.
  """
  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc "Records a newly acquired lease in the cache and arms its local expiry timer."
  @spec acquire(GenServer.name(), 0..511, term(), pos_integer()) :: {:ok, LeaseCache.lease()}
  def acquire(name \\ __MODULE__, machine_id, lease, ttl_ms),
    do: GenServer.call(name, {:acquire, machine_id, lease, ttl_ms})

  @doc """
  Replaces the currently cached lease and re-arms its expiry timer.

  Returns `:lost` instead if the cache was cleared out from under the caller, e.g. because the
  local expiry timer fired while a renewal was in flight.
  """
  @spec renew(GenServer.name(), term(), pos_integer()) :: {:ok, LeaseCache.lease()} | :lost
  def renew(name \\ __MODULE__, lease, ttl_ms), do: GenServer.call(name, {:renew, lease, ttl_ms})

  @doc """
  Reports the current lease as lost: disables every configured factory, clears the cache, and
  notifies the lease manager with `reason` (unless there was no active lease to lose).
  """
  @spec lose(GenServer.name(), term()) :: :ok
  def lose(name \\ __MODULE__, reason), do: GenServer.call(name, {:lose, reason})

  @doc """
  Clears a cached lease that turned out unusable during bootstrap, without reporting it lost.
  """
  @spec discard(GenServer.name()) :: :ok
  def discard(name \\ __MODULE__), do: GenServer.call(name, :discard)

  ##########
  # Server #
  ##########

  @impl true
  def init(state) do
    state = Map.merge(%{timer: nil, generation: 0}, state)

    case LeaseCache.get(state.lease_cache) do
      lease when is_map(lease) ->
        if LeaseCache.valid?(lease),
          do: {:ok, arm(state, lease.expires_at_mono)},
          else: {:ok, cleanup(state, false)}

      nil ->
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:acquire, machine_id, lease, ttl_ms}, _from, state) do
    cached_lease = LeaseCache.put(state.lease_cache, machine_id, lease, ttl_ms)
    {:reply, {:ok, cached_lease}, arm(state, cached_lease.expires_at_mono)}
  end

  def handle_call({:renew, lease, ttl_ms}, _from, state) do
    case LeaseCache.renew(state.lease_cache, lease, ttl_ms) do
      {:ok, cached_lease} ->
        {:reply, {:ok, cached_lease}, arm(state, cached_lease.expires_at_mono)}

      :lost ->
        {:reply, :lost, state}
    end
  end

  def handle_call({:lose, reason}, _from, state), do: {:reply, :ok, cleanup(state, reason)}

  def handle_call(:discard, _from, state), do: {:reply, :ok, cleanup(state, false)}

  @impl true
  def handle_info({:expired, generation}, %{generation: generation} = state),
    do: {:noreply, cleanup(state, :expired)}

  def handle_info({:expired, _generation}, state), do: {:noreply, state}

  def handle_info({:notify_lease_lost, lease, reason}, state) do
    notify_lease_manager(state.lease_manager, lease, reason)
    {:noreply, state}
  end

  ###########
  # Private #
  ###########

  defp arm(state, expires_at_mono) do
    state = cancel_timer(state)
    generation = state.generation + 1
    delay = max(0, expires_at_mono - now_mono())
    timer = Process.send_after(self(), {:expired, generation}, delay)
    %{state | timer: timer, generation: generation}
  end

  defp cleanup(state, reason) do
    state = cancel_timer(state)

    case LeaseCache.clear(state.lease_cache) do
      nil ->
        state

      lease ->
        Enum.each(state.instances, &Instances.disable/1)
        if reason, do: notify_lease_manager(state.lease_manager, lease, reason)
        state
    end
  end

  defp notify_lease_manager(lease_manager, lease, reason) do
    case GenServer.whereis(lease_manager) do
      nil -> Process.send_after(self(), {:notify_lease_lost, lease, reason}, 10)
      pid -> send(pid, {:lease_lost, lease, reason})
    end
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp now_mono(), do: :erlang.monotonic_time(:millisecond)
end
