defmodule MyApp.PgRepo do
  use Ecto.Repo, otp_app: :no_noncense, adapter: Ecto.Adapters.Postgres
end
