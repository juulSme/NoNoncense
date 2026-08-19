import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module, :function]

config :no_noncense, ecto_repos: [MyApp.MysqlRepo, MyApp.PgRepo]

config :no_noncense, MyApp.MysqlRepo,
  host: "localhost",
  port: 3306,
  username: "root",
  password: "supersecret",
  database: "no_noncense",
  pool: Ecto.Adapters.SQL.Sandbox,
  priv: "priv/repo"

config :no_noncense, MyApp.PgRepo,
  host: "localhost",
  port: 5432,
  username: "postgres",
  password: "supersecret",
  database: "no_noncense",
  pool: Ecto.Adapters.SQL.Sandbox,
  priv: "priv/repo"

import_config("#{Mix.env()}.exs")
