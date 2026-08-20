defmodule NoNoncense.MachineId.LeaseManager.Instances do
  @moduledoc false
  import NoNoncense.State

  @type instance_opts :: [NoNoncense.init_opt()]

  @doc """
  Initializes an instance unless its stored machine ID already matches the current lease.
  """
  @spec re_init(instance_opts()) :: :ok
  def re_init(opts) do
    name = Keyword.fetch!(opts, :name)
    machine_id = Keyword.fetch!(opts, :machine_id)

    case :persistent_term.get(name, nil) do
      state(machine_id: ^machine_id, enabled?: true) -> :ok
      nil -> NoNoncense.init(opts)
      state -> :persistent_term.put(name, state(state, enabled?: true, machine_id: machine_id))
    end
  end

  @doc "Erases an instance so it can no longer generate nonces."
  @spec disable(instance_opts()) :: :ok
  def disable(opts) do
    name = Keyword.fetch!(opts, :name)

    case :persistent_term.get(name, nil) do
      nil -> :ok
      state(enabled?: false) -> :ok
      state -> :persistent_term.put(name, state(state, enabled?: false))
    end
  end
end
