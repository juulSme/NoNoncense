defmodule NoNoncense.MachineId.Strategy.HostIdentifiers do
  @moduledoc """
  Strategy to assign machine IDs based on the current node's network identifiers (hostname,
  FQDN, IP addresses, or OTP node name), matched against a fixed list of all possible nodes.

  Each entry in `node_list` receives a stable zero-based index as its machine ID. No external
  coordinator is required — IDs are determined locally — but every node must be configured with
  the same list. The list is treated as a set: insertion order does not affect which ID is
  assigned.

  Configure the strategy when starting `NoNoncense.MachineId`:

      children = [
        {NoNoncense.MachineId,
         strategy: NoNoncense.MachineId.Strategy.HostIdentifiers,
         strategy_opts: [node_list: [:"myapp@10.0.0.1", :"myapp@10.0.0.2"]],
         on_lease_lost: fn _reason -> :erlang.halt(111) end,
         instances: [[base_key: System.fetch_env!("BASE_KEY")]]}
      ]

  The default `ConflictGuard` detects duplicate IDs among connected Erlang nodes. Halting on
  lease loss prevents this deterministic strategy from reacquiring the same conflicting ID.

  ## Options

    * `:node_list` (required) - identifiers (IP addresses, OTP node names, hostnames, or FQDNs)
      for every node in the cluster; must be identical on every node and must not contain
      identifiers shared across nodes (e.g. do not include `:"nonode@nohost"`)

  > #### Use the same node list everywhere {: .warning}
  >
  > Your `node_list` must be the same for every node or the generated machine IDs will not be unique.
  """
  use NoNoncense.MachineId.Strategy
  @defaults %{machine_id: nil, node_list: []}

  @type host_identifiers :: [binary() | atom()]
  @type opt :: {:node_list, host_identifiers()}
  @type opts :: [opt()]

  @doc "Matches this node's identifiers against `:node_list` and returns its stable list index."
  @impl true
  def acquire(lease_duration, opts) do
    Enum.into(opts, @defaults)
    |> gen_machine_id()
    |> case do
      {:ok, id} -> {:ok, id, :static, lease_duration}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Determine the current node's machine ID.

  ## Examples / doctests

      # provide a list of possible node identifiers
      iex> node_list = [:a, :b, :nonode@nohost, "1.1.1.1"]
      iex> id!(node_list: node_list)
      2

      # raises when the machine ID could not be determined from the node list
      iex> node_list = ["1.1.1.1"]
      iex> id!(node_list: node_list)
      ** (RuntimeError) machine ID could not be determined
  """
  @spec id!(opts()) :: non_neg_integer()
  def id!(opts \\ []) do
    case Enum.into(opts, @defaults) |> gen_machine_id() do
      {:ok, id} -> id
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Get a list of all identifiers of the current node. You can use one or more of these values to populate your node list.

  ## Examples / doctests

      iex> host_identifiers()
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

  defp gen_machine_id(config) do
    node_list = config.node_list |> :ordsets.from_list()
    host_identifiers = host_identifiers()

    case :ordsets.intersection(host_identifiers, node_list) do
      [matching_node | _] ->
        id = Enum.find_index(node_list, &(&1 == matching_node))
        {:ok, id}

      _ ->
        {:error, "machine ID could not be determined"}
    end
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
