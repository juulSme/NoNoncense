import Ecto.Query
alias MyApp.{PgRepo, MysqlRepo}
alias NoNoncense.MachineId.Strategy.SqlLease.NoNoncenseLease

defmodule MyApp.IexTelemetry do
  require Logger
  def handle_event(_, _, metadata, _), do: metadata.commands |> inspect() |> Logger.debug()
end

:ok =
  :telemetry.attach_many(
    "redix-logger",
    [[:redix, :pipeline, :start]],
    &MyApp.IexTelemetry.handle_event/4,
    nil
  )

secret_key = :crypto.strong_rand_bytes(32)
shared_opts = [lease_duration: 60 * 60 * 1000, renew_interval: 30 * 60 * 1000]

{:ok, _supervisor} =
  Supervisor.start_link(
    [
      {Ecto.Migrator, repos: Application.fetch_env!(:no_noncense, :ecto_repos)},
      PgRepo,
      MysqlRepo,
      {Redix, database: 14, name: MyApp.Redix},
      {NoNoncense.MachineId,
       shared_opts ++
         [
           name: MyApp.RedisMachineId,
           strategy: NoNoncense.MachineId.Strategy.RedisLease,
           strategy_opts: [with_connection: MyApp.Redix],
           instances: [[base_key: secret_key, cipher64: :speck, cipher96: :speck]]
         ]},
      {NoNoncense.MachineId,
       shared_opts ++
         [
           name: MyApp.PgMachineId,
           strategy: NoNoncense.MachineId.Strategy.SqlLease,
           strategy_opts: [repo: PgRepo],
           instances: [[name: :sql, base_key: secret_key, cipher64: :speck, cipher96: :speck]]
         ]}
    ],
    strategy: :one_for_one
  )

defmodule MyApp.DevFuns do
  import Ecto.Query
  alias MyApp.PgRepo
  alias NoNoncense.MachineId.Strategy.SqlLease.NoNoncenseLease

  def expire_pg_leases do
    from(l in NoNoncenseLease) |> PgRepo.update_all(set: [expires_at: now_usec()])
  end

  def hijack_pg_leases do
    from(l in NoNoncenseLease, where: l.expires_at > ^now_usec())
    |> PgRepo.update_all(set: [token: :crypto.strong_rand_bytes(16)])
  end

  def list_pg_leases do
    from(l in NoNoncenseLease, where: l.expires_at > ^now_usec()) |> PgRepo.all()
  end

  def claim_pg_lease(id_or_ids) do
    from(l in NoNoncenseLease, where: l.id in ^to_ids_list(id_or_ids))
    |> PgRepo.update_all(
      set: [token: :crypto.strong_rand_bytes(16), expires_at: now_usec() |> DateTime.add(300)]
    )
  end

  def renew_pg_now() do
    GenServer.cast(MyApp.PgMachineId.LeaseManager, :renew)
  end

  def redix_cmd(cmd), do: Redix.command(MyApp.Redix, cmd)

  defp markers_ids do
    {:ok, keys} = redix_cmd(~w(HKEYS no_noncense_leases))
    Enum.split_with(keys, &match?("token." <> _, &1))
  end

  def list_redis_leases, do: markers_ids() |> elem(1)

  def invalidate_redis_leases, do: redix_cmd(~w(DEL no_noncense_leases))

  def renew_redis_now() do
    GenServer.cast(MyApp.RedisMachineId.LeaseManager, :renew)
  end

  def claim_redis_lease(id_or_ids) do
    ids = to_ids_list(id_or_ids) |> Enum.map(&Integer.to_string/1)
    field_n = to_string(length(ids) * 2)
    {:ok, pairs} = redix_cmd(~w(HGETALL no_noncense_leases))
    pairs = Enum.chunk_every(pairs, 2) |> Map.new(fn [k, v] -> {k, v} end)
    claimed = Map.take(pairs, ids)
    markers = Enum.map(claimed, fn {id, token} -> "token.#{id}.#{token}" end)
    if markers != [], do: redix_cmd(["HDEL", "no_noncense_leases" | markers])

    new_pairs =
      Enum.flat_map(ids, fn id ->
        token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
        ["#{id}", token, "token.#{id}.#{token}", "#{id}"]
      end)

    redix_cmd(["HSETEX", "no_noncense_leases", "PX", "300000", "FIELDS", field_n | new_pairs])
  end

  defp now_usec(), do: DateTime.utc_now(:microsecond)

  defp to_ids_list(id) when is_integer(id), do: [id]
  defp to_ids_list(list) when is_list(list), do: list
  defp to_ids_list(%Range{} = r), do: Enum.to_list(r)
end

import MyApp.DevFuns
