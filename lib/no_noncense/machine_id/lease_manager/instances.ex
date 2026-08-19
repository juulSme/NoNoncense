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
      state(machine_id: ^machine_id, enabled?: true) ->
        :ok

      state(machine_id: ^machine_id, enabled?: false) = state ->
        :persistent_term.put(name, state(state, enabled?: true))

      _ ->
        NoNoncense.init(opts)
    end
  end

  @doc "Initializes every configured factory unless it already has the current machine ID."
  @spec re_init_all([instance_opts()]) :: [:ok]
  def re_init_all(all_opts), do: for(opts <- all_opts, do: re_init(opts))

  @doc "Erases an instance so it can no longer generate nonces."
  @spec disable(instance_opts()) :: :ok
  def disable(opts) do
    name = Keyword.fetch!(opts, :name)

    case :persistent_term.get(name, nil) do
      nil -> :ok
      state -> :persistent_term.put(name, state(state, enabled?: false))
    end
  end

  @doc "Erases every configured factory."
  @spec disable_all([instance_opts()]) :: [:ok]
  def disable_all(all_opts), do: for(opts <- all_opts, do: disable(opts))
end
