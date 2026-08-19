import Config

config :logger, level: :warning

config :no_noncense, MyApp.MysqlRepo,
  database: "no_noncense_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  log: false

config :no_noncense, MyApp.PgRepo,
  database: "no_noncense_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  log: false
