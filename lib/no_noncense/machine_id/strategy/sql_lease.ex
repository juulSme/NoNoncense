if Code.ensure_loaded?(Ecto.Migration) do
  defmodule NoNoncense.MachineId.Strategy.SqlLease do
    @moduledoc """
    Strategy to acquire a machine ID lease from a SQL database (Postgres or MySQL), coordinating
    uniqueness across nodes through a single table.

    Each machine ID (`0..511`) is a row in the table; a node acquires the lowest available (i.e.
    already-expired) row and holds it by keeping its `expires_at` in the future with a random
    `token`, renewing it periodically.

    Requires a table with one pre-populated row per possible machine ID - see the migration below.

    Configure the strategy when starting `NoNoncense.MachineId` and add it after your Repo:

        children = [
          ...
          MyApp.Repo,
          {NoNoncense.MachineId,
           strategy: NoNoncense.MachineId.Strategy.SqlLease,
           strategy_opts: [repo: MyApp.Repo],
           instances: [[base_key: System.fetch_env!("BASE_KEY")]]}
        ]

    ## Options

      * `:repo` (required) - the `Ecto.Repo` to run queries against
      * `:table` - the table leases are stored in (default `"no_noncense_leases"`)

    ## Migration

    A convenience helper `migrate/1` has been added to this module to help you write a migration. The table name is overridable using option `:table_name`.

        defmodule MyApp.Repo.Migrations.NoNoncenseLeases do
          use Ecto.Migration

          def change, do: NoNoncense.MachineId.Strategy.SqlLease.migrate()
        end
    """

    # Implementation notes:
    #
    #   * `token` and `lock_version` serve different purposes and are deliberately not
    #     interchangeable. `claim/4` (called from `acquire/2`) uses `lock_version` as its
    #     optimistic-lock CAS guard when flipping an unclaimed/expired row to claimed, because at
    #     that point there is no existing token to check against (fresh/expired rows can have
    #     `token: nil`, and SQL's `=` never matches `NULL`). Once a row is claimed, `renew/3` and
    #     `release/2` instead match on `token` alone - it's the stable identity of *this specific*
    #     acquisition, since (unlike `lock_version`) it is never rotated by renew or release, only
    #     by a fresh `claim/4`.
    #   * Not matching on `lock_version` in `renew/3` is deliberate, not an oversight: `lock_version`
    #     is bumped (via `inc:`) on every successful renew, so if a renewal commits but its
    #     response is lost (ambiguous failure), a caller retrying with its last-known lease would
    #     find `lock_version` already stale and get a false `{:error, :lost, _}` even though nobody
    #     else took the lease. Matching on `token` only makes such retries idempotent instead.
    #   * `db_now/0` reads `CURRENT_TIMESTAMP`, which Postgres pins to transaction start (unlike
    #     MySQL, which re-evaluates it per statement). Callers that wrap `acquire/renew/release` in
    #     an explicit transaction on Postgres will see `db_now()` "frozen", so e.g. a row released
    #     via `db_now()` won't look expired to a later `acquire/2` call in that same transaction.
    #     Normal usage (separate calls, no explicit transaction) is unaffected.
    alias __MODULE__.NoNoncenseLease
    import Ecto.Query
    require Logger

    use NoNoncense.MachineId.Strategy

    @type opt :: {:table, String.t()} | {:repo, module()}
    @type migrate_opt :: {:table_name, String.t()}

    @default_table_name "no_noncense_leases"

    # we use the db clock to have a single clock determining eligibility
    defmacrop db_now(), do: quote(do: fragment("CURRENT_TIMESTAMP(6)"))

    defmacrop db_now_add(duration_ms) do
      quote do: datetime_add(db_now(), unquote(duration_ms), "millisecond")
    end

    @impl true
    def acquire(lease_duration, opts) do
      {repo, table} = process_opts(opts)

      fn ->
        from(l in {table, NoNoncenseLease},
          where: l.expires_at < db_now(),
          order_by: l.id,
          limit: 5
        )
        |> repo.all()
      end
      |> catch_connection_error()
      |> case do
        [] -> {:error, :exhausted}
        {:error, _} = err -> err
        available -> claim(available, repo, table, lease_duration)
      end
    end

    defp claim([], _, _, _), do: {:error, :conflict}

    defp claim([%{id: id, lock_version: lock_version} | rest], repo, table, lease_duration) do
      token = :crypto.strong_rand_bytes(16)

      from(l in {table, NoNoncenseLease},
        where: l.id == ^id and l.lock_version == ^lock_version,
        update: [
          set: [token: ^token, expires_at: db_now_add(^lease_duration)],
          inc: [lock_version: 1]
        ]
      )
      |> update_all(repo)
      |> case do
        :ok -> {:ok, id, {id, token}, lease_duration}
        {:error, :update_failed} -> claim(rest, repo, table, lease_duration)
        error -> error
      end
    end

    @impl true
    def renew({id, token}, lease_duration, opts) do
      {repo, table} = process_opts(opts)

      from(l in {table, NoNoncenseLease},
        where: l.id == ^id and l.token == ^token,
        update: [set: [expires_at: db_now_add(^lease_duration)], inc: [lock_version: 1]]
      )
      |> update_all(repo)
      |> case do
        :ok -> {:ok, {id, token}, lease_duration}
        {:error, :update_failed} -> {:error, :lost, :expired}
        {:error, msg} -> {:error, :retry, msg}
      end
    end

    @impl true
    def release(_lease = {id, token}, opts) do
      {repo, table} = process_opts(opts)

      from(l in {table, NoNoncenseLease},
        where: l.id == ^id and l.token == ^token,
        update: [set: [expires_at: db_now()], inc: [lock_version: 1]]
      )
      |> update_all(repo)

      :ok
    end

    @impl true
    def deterministic?(), do: false

    @doc """
    Convenience helper for creating the leases table in an Ecto migration.

    Creates table "#{@default_table_name}" (overridable) with `id`, `token`, `expires_at` and `lock_version` columns, and preseeds all 512 IDs.

    ## Options
      - `:table_name` override the name of the leases table. Must be passed to the strategy as well if overridden.
    """
    @spec migrate([migrate_opt]) :: term()
    def migrate(opts \\ []) do
      import Ecto.Migration

      table_name = opts[:table_name] || @default_table_name

      create table(table_name, primary_key: [name: :id, type: :smallint]) do
        add(:token, :binary, length: 16)
        add(:expires_at, :utc_datetime_usec, null: false)
        add(:lock_version, :integer, null: false, default: 0)
      end

      if direction() == :up do
        flush()
        epoch = ~U[1970-01-01 00:00:00.000000Z]
        rows = for id <- 0..511, do: %{id: id, lock_version: 0, expires_at: epoch}
        repo().insert_all(table_name, rows)
      end
    end

    ###########
    # Private #
    ###########

    defp process_opts(opts) do
      repo = Keyword.fetch!(opts, :repo)
      table = opts[:table] || @default_table_name
      {repo, table}
    end

    defp update_all(query, repo) do
      fn ->
        repo.update_all(query, [])
        |> case do
          {1, _} -> :ok
          {0, _} -> {:error, :update_failed}
        end
      end
      |> catch_connection_error()
    end

    defp catch_connection_error(fun) do
      try do
        fun.()
      rescue
        e in [DBConnection.ConnectionError] ->
          msg = "unexpected repo result: #{inspect(e)}"
          Logger.warning(msg)
          {:error, msg}
      end
    end
  end
end
