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
      state(machine_id: ^machine_id) -> :ok
      _ -> NoNoncense.init(opts)
    end
  end

  @doc "Initializes every configured factory unless it already has the current machine ID."
  @spec re_init_all([instance_opts()]) :: [:ok]
  def re_init_all(all_opts), do: for(opts <- all_opts, do: re_init(opts))

  @doc "Erases an instance so it can no longer generate nonces."
  @spec destroy(instance_opts()) :: boolean()
  def destroy(opts) do
    Keyword.fetch!(opts, :name) |> :persistent_term.erase()
  end

  @doc "Erases every configured factory."
  @spec destroy_all([instance_opts()]) :: [boolean()]
  def destroy_all(all_opts), do: for(opts <- all_opts, do: destroy(opts))
end
