defmodule MyApp.MysqlRepo do
  use Ecto.Repo, otp_app: :no_noncense, adapter: Ecto.Adapters.MyXQL
end
