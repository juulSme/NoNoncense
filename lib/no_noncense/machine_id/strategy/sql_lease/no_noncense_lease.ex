if Code.ensure_loaded?(Ecto) do
  defmodule NoNoncense.MachineId.Strategy.SqlLease.NoNoncenseLease do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "no_noncense_leases" do
      field(:id, :integer, primary_key: true)
      field(:token, :binary)
      field(:expires_at, :utc_datetime_usec)
      field(:lock_version, :integer)
    end
  end
end
