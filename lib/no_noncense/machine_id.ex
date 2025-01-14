defmodule NoNoncense.MachineId do
  @moduledoc """
  Determine unique machine IDs for nodes, which can be used to guarantee uniqueness in a distributed system.

  To determine the unique node ID, you must provide a list of possible node identifiers. The possible identifiers are IP addresses, OTP node identifiers, hostnames and fully-qualified domain names. You should only provide possible identifiers that can't conflict with one another. So if you don't explicitly set OTP node names you should not add the default `:"nonode@nohost"` to your identifier list.

  > #### Use the same node list everywhere {: .warning}
  >
  > Your `node_list` must be the same for every node or the generated machine IDs will not be unique.

  You can configure the options in your application environment and just pass them into `id/1`.

  After https://github.com/blitzstudios/snowflake
  """
  @defaults %{machine_id: nil, node_list: [], max_nodes: 512}

  @type host_identifiers :: [binary() | atom()]
  @type id_opts :: [
          machine_id: non_neg_integer() | nil,
          node_list: host_identifiers(),
          max_nodes: pos_integer()
        ]

  @doc """
  Determine the current node's machine ID.

  ## Examples / doctests

      # provide a list of possible node identifiers
      iex> node_list = ["1.1.1.1", "127.0.0.1", "8.8.8.8", "0.0.0.0"]
      iex> MachineId.id!(node_list: node_list)
      2

      # a statically configured ID will override the node list
      iex> node_list = ["1.1.1.1", "127.0.0.1", "8.8.8.8", "0.0.0.0"]
      iex> MachineId.id!(machine_id: 1, node_list: node_list)
      1

      # the node ID must be within the provided range (default 0-1023)
      iex> node_list = ["1.1.1.1", "127.0.0.1", "8.8.8.8", "0.0.0.0"]
      iex> MachineId.id!(max_nodes: 2, node_list: node_list)
      ** (RuntimeError) Node ID 2 out of range 0-1

      # raises when the machine ID could not be determined from the node list
      iex> node_list = ["1.1.1.1"]
      iex> MachineId.id!(node_list: node_list)
      ** (RuntimeError) machine ID could not be determined
  """
  @spec id!(id_opts()) :: non_neg_integer()
  def id!(opts \\ []), do: Enum.into(opts, @defaults) |> gen_machine_id()

  @doc """
  Get a list of all identifiers of the current node. You can use one or more of these values to populate your node list.

  ## Examples / doctests

      iex> MachineId.host_identifiers()
      [:nonode@nohost, "host.mydomain.com", "10.11.12.13", "myhost", "fe80::1234::abcd"]
  """
  @spec host_identifiers() :: host_identifiers()
  def host_identifiers() do
    ([hostname(), fqdn(), Node.self()] ++ ip_addrs())
    |> Enum.reject(&is_nil/1)
    |> :ordsets.from_list()
  end

  ###########
  # Private #
  ###########

  defp gen_machine_id(config = %{machine_id: nil}) do
    node_list = config.node_list |> :ordsets.from_list()
    host_identifiers = host_identifiers()

    case :ordsets.intersection(host_identifiers, node_list) do
      [matching_node | _] ->
        id = Enum.find_index(node_list, &(&1 == matching_node))
        gen_machine_id(%{config | machine_id: id})

      _ ->
        raise RuntimeError, "machine ID could not be determined"
    end
  end

  defp gen_machine_id(c = %{machine_id: id}) when id >= 0 and id < c.max_nodes - 1, do: id

  defp gen_machine_id(c) do
    raise(RuntimeError, "Node ID #{c.machine_id} out of range 0-#{c.max_nodes - 1}")
  end

  defp ip_addrs() do
    {:ok, ifaddrs} = :inet.getifaddrs()

    ifaddrs
    |> Stream.map(fn {_name, props} -> props[:addr] end)
    |> Stream.reject(&is_nil/1)
    |> Enum.map(fn addr -> addr |> :inet.ntoa() |> to_string() end)
  end

  defp hostname() do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp fqdn() do
    case :inet.get_rc()[:domain] do
      nil -> nil
      domain -> hostname() <> "." <> to_string(domain)
    end
  end
end
