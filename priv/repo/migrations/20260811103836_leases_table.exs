defmodule MyApp.Repo.Migrations.LeasesTable do
  use Ecto.Migration

  def change, do: NoNoncense.MachineId.Strategy.SqlLease.migrate()
end
