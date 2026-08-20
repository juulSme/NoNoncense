defmodule NoNoncense.MachineId.LeaseCache do
  @moduledoc """
  In-memory cache of the currently held machine ID lease.

  It lets a restarted LeaseManager renew its prior lease rather than acquiring another scarce
  machine ID. The cache is local only; an ExpirationManager owns all writes during normal lease
  operation and clears it before factories are disabled.
  """
  use Agent

  @type lease :: %{machine_id: 0..511, lease: term(), expires_at_mono: integer()}

  @doc "Starts an empty in-memory lease cache."
  @spec start_link(name: GenServer.name()) :: Agent.on_start()
  def start_link(opts), do: Agent.start_link(fn -> nil end, name: opts[:name] || __MODULE__)

  @doc "Returns the cached lease, or `nil` when no lease is active."
  @spec get(GenServer.name()) :: lease() | nil
  def get(name \\ __MODULE__), do: Agent.get(name, & &1)

  @doc "Stores a newly acquired lease."
  @spec put(GenServer.name(), 0..511, term(), pos_integer()) :: lease()
  def put(name \\ __MODULE__, machine_id, lease, ttl_ms) when is_integer(ttl_ms) do
    new_lease(machine_id, lease, ttl_ms) |> tap(&Agent.update(name, fn _ -> &1 end))
  end

  @doc "Replaces an active lease while retaining its machine ID."
  @spec renew(GenServer.name(), term(), pos_integer()) :: {:ok, lease()} | :lost
  def renew(name \\ __MODULE__, lease, ttl_ms) when is_integer(ttl_ms) do
    Agent.get_and_update(name, fn
      %{machine_id: machine_id} -> new_lease(machine_id, lease, ttl_ms) |> then(&{{:ok, &1}, &1})
      _ -> {:lost, nil}
    end)
  end

  @doc "Clears and returns the active lease, if any."
  @spec clear(GenServer.name()) :: lease() | nil
  def clear(name \\ __MODULE__) do
    Agent.get_and_update(name, fn lease -> {lease, nil} end)
  end

  @doc "Returns whether a cached lease remains inside its local validity window."
  @spec valid?(lease() | nil) :: boolean()
  def valid?(%{expires_at_mono: expires_at_mono}), do: now_mono() < expires_at_mono
  def valid?(nil), do: false

  defp new_lease(machine_id, lease, ttl_ms) do
    %{machine_id: machine_id, lease: lease, expires_at_mono: now_mono() + ttl_ms - 10_000}
  end

  defp now_mono(), do: :erlang.monotonic_time(:millisecond)
end
