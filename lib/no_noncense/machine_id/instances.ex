defmodule NoNoncense.MachineId.Instances do
  @moduledoc false
  import NoNoncense.State

  @type instance_opts :: [NoNoncense.init_opt()]

  @doc """
  Initializes an instance unless it is already enabled with the leased machine ID.

  A disabled instance is initialized afresh instead of re-enabled: its counters would continue
  from timestamps that another node holding the same ID may have used in the meantime.
  """
  @spec re_init(instance_opts()) :: :ok
  def re_init(opts) do
    name = Keyword.fetch!(opts, :name)
    machine_id = Keyword.fetch!(opts, :machine_id)

    case :persistent_term.get(name, nil) do
      state(machine_id: ^machine_id, enabled?: true) -> :ok
      _ -> NoNoncense.init(opts)
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
