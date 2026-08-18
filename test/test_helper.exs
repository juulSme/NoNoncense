Mimic.copy(Redix)
Mimic.copy(MyApp.PgRepo)
Mimic.copy(MyApp.MysqlRepo)

ExUnit.start(exclude: [:very_slow])

unless System.get_env("NO_NONCENSE_UNIT_TESTS") == "true" do
  {:ok, _} = Supervisor.start_link([MyApp.PgRepo, MyApp.MysqlRepo], strategy: :one_for_one)
  Ecto.Adapters.SQL.Sandbox.mode(MyApp.PgRepo, :manual)
  Ecto.Adapters.SQL.Sandbox.mode(MyApp.MysqlRepo, :manual)
end
