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
    # outlives the ownership fields. Reuse requires the ID fields to have expired in Redis and the
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
           available_ids = [_ | _] <- leased_ids |> available_ids(exps, now) do
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
          "exp." <> _ -> {markers, Map.put(exps, k, int_or_nil(v) || 0), ids}
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
      with hash_fields_cmd = set_hash_fields_cmd(key, id, token, ttl, condition),
           {:ok, 1} <- Redix.command(conn, hash_fields_cmd),
           # only written once the conditional write succeeded, so a failed claim can't touch
           # the current holder's cutoff
           exp_cmd = ["HSET", key, "exp.#{id}", to_string(local_expiry)],
           {:ok, res} when res in [0, 1] <- Redix.command(conn, exp_cmd) do
        :ok
      else
        {:ok, 0} -> {:error, :condition_not_met}
        {:ok, result} -> {:error, result}
        {:error, _reason} = error -> error
      end
    end

    defp set_hash_fields_cmd(key, id, token, ttl, condition) do
      ttl = Integer.to_string(ttl)
      id = Integer.to_string(id)
      marker_key = "token.#{id}.#{token}"
      condition = to_cond_code(condition)

      ["HSETEX", key, condition, "PX", ttl, "FIELDS", "2", id, "", marker_key, ""]
    end

    defp to_cond_code(:if_all_exist), do: "FXX"
    defp to_cond_code(:if_none_exist), do: "FNX"
  end
end
