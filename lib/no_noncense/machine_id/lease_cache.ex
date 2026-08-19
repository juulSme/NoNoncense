defmodule NoNoncense.MachineId.LeaseCache do
  @moduledoc """
  In-memory cache of a machine ID and its lease.

  The purpose of the cache is to allow the lease to resume if the LeaseManager crashes for whatever reason, for example if a lease strategy does not properly catch all errors.
  In that case, the lease manager will be restarted, can fetch the existing lease from the cache and attempt to renew it.
  This way, the lease manager does not have to request a new lease, protecting against ID exhaustion, of which there are only 512 after all.

  Since this is an in-memory cache, it will not protect against node crashes or, notably, external forced kills by the kernel or the scheduler (for example in OOM scenarios).
  """
  use Agent

  @doc "Starts an empty in-memory lease cache."
  @spec start_link(name: GenServer.name()) :: Agent.on_start()
  def start_link(opts), do: Agent.start_link(fn -> nil end, name: opts[:name] || __MODULE__)

  @doc "Replaces the cached lease state."
  @spec put(GenServer.name(), term()) :: :ok
  def put(name \\ __MODULE__, term), do: Agent.update(name, fn _ -> term end)

  @doc "Returns the cached lease state, or `nil` when no lease has been cached."
  @spec get(GenServer.name()) :: term()
  def get(name \\ __MODULE__), do: Agent.get(name, & &1)
end
