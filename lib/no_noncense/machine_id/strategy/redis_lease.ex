if Code.ensure_loaded?(Redix) do
  defmodule NoNoncense.MachineId.Strategy.RedisLease do
    @moduledoc """
    Strategy to acquire a machine ID lease from Redis, coordinating uniqueness across nodes
    through a single Redis hash.

    Each machine ID (`0..511`) is a field in the hash; a node acquires the lowest free ID and
    holds it by keeping that field's value (a random token) alive with a TTL, renewing it
    periodically.
    Requires Redis 8+ or Valkey 9+ for `HSETEX`'s conditional (`FNX`/`FXX`) and per-field TTL support.

    Configure the strategy when starting `NoNoncense.MachineId`, after your Redix instance or pool:

        children = [
          ...
          MyApp.Redix,
          {NoNoncense.MachineId,
           strategy: NoNoncense.MachineId.Strategy.RedisLease,
           strategy_opts: [with_connection: MyApp.Redix],
           instances: [[base_key: System.fetch_env!("BASE_KEY")]]}
        ]

    ## Options

      * `:with_connection` (required) supports two forms:
        1. Pass the simple connection name or pid directly:
          ```
          with_connection: MyApp.Redix
          ```
        2. To support connection pools, pass a function that calls its argument function with a connection:
          ```
          with_connection: fn fun -> :poolboy.transaction(MyApp.RedixPool, fun) end
          ```

      * `:key` - the Redis hash key to store leases under (default `"no_noncense_leases"`)
    """

    # Implementation notes: each lease writes *two* fields to the hash via a single `HSETEX`:
    #
    #   * the ID field itself, e.g. `"3" => token` - this is what `acquire/2` scans to find a
    #     free ID, and what other nodes see as "ID 3 is taken".
    #   * a marker field, e.g. `"<22-char token>.3" => ""` - a field whose key embeds both the
    #     token and the ID it belongs to.
    #
    # Both fields always share the same TTL and are written/refreshed/deleted together, so the
    # marker field exists for exactly as long as this specific (id, token) pair still owns the
    # lease.
    # That gives `renew/3` and `release/2` a way to make their `HSETEX ... FXX` calls
    # conditional on *still holding this exact lease*, not just on "some lease for this ID
    # exists": FXX only succeeds if all given fields already exist, so if another node acquired
    # ID 3 in between (new token, new marker field, old marker field gone since it expired/was
    # deleted), our marker field is missing and the FXX call fails with 0 fields set - reported
    # as `{:error, :lost, _}` - instead of silently refreshing or deleting somebody else's lease.

    use NoNoncense.MachineId.Strategy

    @type with_connection :: ((Redix.connection() -> any()) -> any()) | Redix.connection()
    @type opt :: {:with_connection, with_connection()} | {:key, binary()}
    @type opts :: [opt()]

    @default_key "no_noncense_leases"
    @all_ids Enum.to_list(0..511)

    @doc "Claims the lowest available machine ID in the configured Redis hash."
    @impl true
    def acquire(lease_duration, opts) do
      {with_conn, key} = process_opts(opts)
      with_conn.(&_acquire(&1, key, lease_duration, 3))
    end

    defp _acquire(_, _, _, 0), do: {:error, :conflict}

    defp _acquire(conn, key, lease_duration, attempt) do
      with {:ok, keys} <- Redix.command(conn, ["HKEYS", key]),
           leased_ids = leased_ids(keys),
           [id | _] <- available_ids(leased_ids),
           token = random_string(),
           cmd = set_hash_fields_cmd(key, id, token, lease_duration, :if_none_exist),
           {_, {:ok, 1}} <- {:acquire, Redix.command(conn, cmd)} do
        {:ok, id, {id, token}, lease_duration}
      else
        {:acquire, _} -> _acquire(conn, key, lease_duration, attempt - 1)
        [] -> {:error, :exhausted}
        e -> {:error, "unknown: #{inspect(e)}"}
      end
    end

    @doc "Extends a lease only when its machine ID and ownership token are still present."
    @impl true
    def renew(lease = {id, token}, lease_duration, opts) do
      {with_conn, key} = process_opts(opts)
      cmd = set_hash_fields_cmd(key, id, token, lease_duration, :if_all_exist)

      with_conn.(&Redix.command(&1, cmd))
      |> case do
        {:ok, 1} -> {:ok, lease, lease_duration}
        {:ok, 0} -> {:error, :lost, :expired}
        _ -> {:error, :retry, "unknown"}
      end
    end

    @doc "Best-effort deletes a lease only when its ownership token still matches."
    @impl true
    def release(_lease = {id, token}, opts) do
      {with_conn, key} = process_opts(opts)
      cmd = set_hash_fields_cmd(key, id, token, 0, :if_all_exist)
      with_conn.(&Redix.command(&1, cmd))
      :ok
    end

    ###########
    # Private #
    ###########

    defp process_opts(opts) do
      with_conn = Keyword.fetch!(opts, :with_connection)

      with_conn =
        case with_conn do
          fun when is_function(fun, 1) -> fun
          conn when is_atom(conn) or is_pid(conn) -> & &1.(conn)
          conn = {atom, node} when is_atom(atom) and is_atom(node) -> & &1.(conn)
          _ -> raise ArgumentError, "with_connection must be a fun/1 or a Redix connection"
        end

      key = opts[:key] || @default_key
      {with_conn, key}
    end

    defp leased_ids(keys) do
      keys |> Stream.reject(&marker?/1) |> Enum.flat_map(&int_or_ignore/1) |> :ordsets.from_list()
    end

    defp marker?(<<"token.", _::binary>>), do: true
    defp marker?(_), do: false

    defp int_or_ignore(binary) do
      try do: [String.to_integer(binary)], rescue: (_ -> [])
    end

    defp available_ids(leased_ids), do: :ordsets.subtract(@all_ids, leased_ids)

    defp set_hash_fields_cmd(key, id, token, ttl, condition) do
      ttl = Integer.to_string(ttl)
      id = Integer.to_string(id)
      marker_key = "token.#{id}.#{token}"
      condition = if condition == :if_all_exist, do: "FXX", else: "FNX"

      ["HSETEX", key, condition, "PX", ttl, "FIELDS", "2", id, token, marker_key, id]
    end

    # results in binaries of length 22
    defp random_string(), do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
