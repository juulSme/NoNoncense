if Code.ensure_loaded?(Redix) do
  defmodule NoNoncense.MachineId.Strategy.RedisLease do
    @moduledoc """
    Strategy to acquire a machine ID lease from Redis, coordinating uniqueness across nodes
    through a single Redis hash.

    Each machine ID (`0..511`) is a field in the hash; a node prefers the lowest free ID and
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
          with_connection: fn fun ->
            conn = :poolboy.checkout(MyApp.RedixPool)

            try do
              fun.(conn)
            after
              :poolboy.checkin(MyApp.RedixPool, conn)
            end
          end
          ```
          (or use the simpler poolboy transaction syntax)
          ```
          with_connection: &:poolboy.transaction(MyApp.RedixPool, &1)
          ```

      * `:key` - the Redis hash key to store leases under (default `"no_noncense_leases"`)
    """

    # Implementation notes: each lease writes *two* fields to the hash via a single `HSETEX`:
    #
    #   * the ID field itself, e.g. `"3" => token` - this is what `acquire/2` scans to find a
    #     free ID, and what other nodes see as "ID 3 is taken".
    #   * a marker field, e.g. `"token.3.<22-char token>" => "3"` - a field whose key embeds both
    #     the ID and the token.
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
    alias NoNoncense.MachineId.Strategy.Shared

    @type with_connection :: ((Redix.connection() -> any()) -> any()) | Redix.connection()
    @type opt :: {:with_connection, with_connection()} | {:key, binary()}

    @default_key "no_noncense_leases"
    @all_ids Enum.to_list(0..511)
    @with_connection_err_msg "with_connection must be a fun/1 or a Redix connection"

    @impl true
    def acquire(lease_duration, opts) do
      {with_conn, key} = process_opts(opts)
      with_conn.(&_acquire(&1, key, lease_duration))
    end

    defp _acquire(conn, key, lease_duration) do
      with {:ok, keys} <- Redix.command(conn, ["HKEYS", key]),
           available_ids = [_ | _] <- keys |> leased_ids() |> available_ids() do
        token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
        available_ids |> Shared.shuffle_after_3() |> claim(conn, key, token, lease_duration)
      else
        [] -> {:error, :exhausted}
        error -> error
      end
    end

    defp claim([], _, _, _, _), do: {:error, :conflict}

    defp claim([id | tail], conn, key, token, lease_duration) do
      with cmd = set_hash_fields_cmd(key, id, token, lease_duration, :if_none_exist),
           {:ok, 1} <- Redix.command(conn, cmd) do
        {:ok, id, {id, token}, lease_duration}
      else
        {:ok, 0} -> claim(tail, conn, key, token, lease_duration)
        error -> error
      end
    end

    @impl true
    def renew(lease = {id, token}, lease_duration, opts) do
      {with_conn, key} = process_opts(opts)

      exec(with_conn, set_hash_fields_cmd(key, id, token, lease_duration, :if_all_exist))
      |> case do
        {:ok, 1} -> {:ok, lease, lease_duration}
        {:ok, 0} -> {:error, :lost, :not_owner}
        {:error, reason} -> {:error, :retry, reason}
        _ -> {:error, :retry, "unknown"}
      end
    end

    @impl true
    def release(_lease = {id, token}, opts) do
      {with_conn, key} = process_opts(opts)
      # we quarantine the ID for 1 second
      # this prevents another node with a skewed clock from generating the same IDs
      exec(with_conn, set_hash_fields_cmd(key, id, token, 1_000, :if_all_exist))
      :ok
    end

    @impl true
    def deterministic?(), do: false

    ###########
    # Private #
    ###########

    defp process_opts(opts) do
      with_conn = Keyword.fetch!(opts, :with_connection) |> process_with_conn()
      key = opts[:key] || @default_key
      {with_conn, key}
    end

    defp process_with_conn(with_conn) when is_function(with_conn, 1), do: with_conn
    defp process_with_conn(conn) when is_atom(conn) or is_pid(conn), do: & &1.(conn)
    defp process_with_conn(c = {atom, node}) when is_atom(atom) and is_atom(node), do: & &1.(c)
    defp process_with_conn(_), do: raise(ArgumentError, @with_connection_err_msg)

    defp exec(with_conn, command), do: with_conn.(fn conn -> Redix.command(conn, command) end)

    defp leased_ids(keys), do: keys |> Enum.flat_map(&key_to_id/1) |> :ordsets.from_list()

    defp key_to_id(binary) do
      if id?(binary), do: int_or_ignore(binary), else: []
    end

    defp id?(binary), do: not marker?(binary)

    defp marker?(binary), do: match?("token." <> _, binary)

    defp int_or_ignore(binary) do
      try do: [String.to_integer(binary)], rescue: (_ -> [])
    end

    defp available_ids(leased_ids), do: :ordsets.subtract(@all_ids, leased_ids)

    defp set_hash_fields_cmd(key, id, token, ttl, condition) do
      ttl = Integer.to_string(ttl)
      id = Integer.to_string(id)
      marker_key = "token.#{id}.#{token}"
      condition = to_condition_code(condition)

      ["HSETEX", key, condition, "PX", ttl, "FIELDS", "2", id, token, marker_key, id]
    end

    defp to_condition_code(:if_all_exist), do: "FXX"
    defp to_condition_code(:if_none_exist), do: "FNX"
  end
end
