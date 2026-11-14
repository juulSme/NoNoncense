if Code.ensure_loaded?(Redix) do
  defmodule NoNoncense.MachineId.Strategy.RedisLease do
    @moduledoc """
    Strategy to acquire a machine ID lease from Redis, coordinating uniqueness across nodes
    through a single Redis hash.

    A node prefers the lowest eligible machine ID (`0..511`) and holds it through a
    token-protected lease with a TTL, renewing it periodically.
    The strategy protects ID reuse between nodes against clock skew by recording the lease holder's local expiry and requiring the successor's local clock to pass that cutoff.
    Requires Redis 8+ or Valkey 9+ for `HSETEX`'s conditional (`FNX`/`FXX`) and per-field TTL support. Uses MULTI/EXEC, but no Lua scripts or server functions.

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

    # Implementation notes: each lease writes two TTL'd fields to the hash via a single `HSETEX`:
    #
    #   * the ID field itself, e.g. `"3" => ""` - this is what `acquire/2` scans to find a
    #     free ID, and what other nodes see as "ID 3 is taken".
    #   * a marker field, e.g. `"token.3.<22-char token>" => ""` - a field whose key embeds both
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
    #
    # Clock-skew invariant: a successor's nonce timestamps must exceed any the previous holder
    # could have used. acquire/renew store local time + TTL in a persistent `exp.<id>` field that
    # outlives the ownership fields. The lease write and the `exp.<id>` write run in one
    # MULTI/EXEC, so an expired holder can't overwrite its successor's cutoff. The `exp` write is
    # an `HSETEX FXX KEEPTTL` that includes the marker field, so it only applies if the
    # conditional lease write succeeded; the preceding `HSETNX` just ensures `exp.<id>` exists
    # for FXX. Reuse requires the ID fields to have expired in Redis and the
    # successor's local clock to have passed `exp.<id>`. The local clock uses the fixed offset
    # shared with nonce generation. Release runs after factories are disabled and replaces the
    # cutoff with local time + the quarantine duration.

    use NoNoncense.MachineId.Strategy
    alias NoNoncense.MachineId.Strategy.Shared

    @type with_connection :: ((Redix.connection() -> any()) -> any()) | Redix.connection()
    @type opt :: {:with_connection, with_connection()} | {:key, binary()}

    @default_key "no_noncense_leases"
    @all_ids Enum.to_list(0..511)
    @with_connection_err_msg "with_connection must be a fun/1 or a Redix connection"

    @impl true
    def acquire(ttl, opts) do
      now = Shared.now_unix(opts)
      {with_conn, key} = process_opts(opts)
      with_conn.(&_acquire(&1, key, ttl, now))
    end

    defp _acquire(conn, key, ttl, now) do
      with {:ok, pairs} <- Redix.command(conn, ["HGETALL", key]),
           {_markers, exps, leased_ids} = group_pairs(pairs),
           available_ids = [_ | _] <- available_ids(leased_ids, exps, now) do
        token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
        available_ids |> Shared.shuffle_after_3() |> claim(conn, key, token, ttl, now + ttl)
      else
        [] -> {:error, :exhausted}
        error -> error
      end
    end

    defp claim([], _, _, _, _, _), do: {:error, :conflict}

    defp claim([id | tail], conn, key, token, ttl, local_expiry) do
      case update_lease(conn, key, {id, token}, ttl, :if_none_exist, local_expiry) do
        :ok -> {:ok, id, {id, token}, ttl}
        {:error, :condition_not_met} -> claim(tail, conn, key, token, ttl, local_expiry)
        {:error, _reason} = error -> error
      end
    end

    @impl true
    def renew(lease, ttl, opts) do
      local_expiry = Shared.now_unix(opts) + ttl
      {with_conn, key} = process_opts(opts)

      with_conn.(fn conn ->
        case update_lease(conn, key, lease, ttl, :if_all_exist, local_expiry) do
          :ok -> {:ok, lease, ttl}
          {:error, :condition_not_met} -> {:error, :lost, :not_owner}
          {:error, reason} -> {:error, :retry, reason}
        end
      end)
    end

    @impl true
    def release(lease, opts) do
      local_expiry = Shared.now_unix(opts) + 1_000
      {with_conn, key} = process_opts(opts)
      with_conn.(&update_lease(&1, key, lease, 1_000, :if_all_exist, local_expiry))
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

    @doc false
    def group_pairs(pairs) do
      pairs
      |> Enum.chunk_every(2)
      |> Enum.reduce({[], %{}, []}, fn [k, v], {markers, exps, ids} ->
        case k do
          "token." <> _ -> {[k | markers], exps, ids}
          "exp." <> _ -> {markers, Map.put(exps, k, int_or_nil(v)), ids}
          _ -> {markers, exps, int_or_nil(k) |> :ordsets.add_element(ids)}
        end
      end)
      |> then(fn {markers, exps, ids} -> {markers, exps, :ordsets.del_element(nil, ids)} end)
    end

    defp int_or_nil(binary) do
      try do: String.to_integer(binary), rescue: (_ -> nil)
    end

    defp available_ids(leased_ids, exps, now) do
      :ordsets.subtract(@all_ids, leased_ids)
      |> Enum.filter(fn id -> (Map.get(exps, "exp.#{id}") || 0) < now end)
    end

    defp update_lease(conn, key, {id, token}, ttl, condition, local_expiry) do
      id = Integer.to_string(id)
      ttl = Integer.to_string(ttl)
      local_expiry = Integer.to_string(local_expiry)
      marker_fld = "token.#{id}.#{token}"
      exp_fld = "exp.#{id}"
      condition = to_cond_code(condition)

      Redix.transaction_pipeline(conn, [
        # create/update id and marker fields if the condition is met, with specified ttl
        ["HSETEX", key, condition, "PX", ttl, "FIELDS", "2", id, "", marker_fld, ""],
        # create exp_fld if it does not exist
        ["HSETNX", key, exp_fld, "0"],
        # if we own the lease, write local expiry to exp_fld, with unchanged ttl
        # we own the lease if the marker field exists after the first command
        ["HSETEX", key, "FXX", "KEEPTTL", "FIELDS", "2", marker_fld, "", exp_fld, local_expiry]
      ])
      |> case do
        {:ok, [1, hsetnx_res, 1]} when hsetnx_res in [0, 1] -> :ok
        {:ok, [0, _, _]} -> {:error, :condition_not_met}
        {:ok, result} -> {:error, result}
        {:error, _reason} = error -> error
      end
    end

    defp to_cond_code(:if_all_exist), do: "FXX"
    defp to_cond_code(:if_none_exist), do: "FNX"
  end
end
