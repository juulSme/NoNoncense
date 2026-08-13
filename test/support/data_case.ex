defmodule TestNoNoncense.DataCase do
  use ExUnit.CaseTemplate

  # `use TestNoNoncense.DataCase, repo: :pg | :mysql` limits setup to a single repo/sandbox
  using(opts) do
    quote bind_quoted: [opts: opts] do
      @moduletag :db
      @moduletag repo: opts[:repo]

      alias MyApp.{PgRepo, MysqlRepo}

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import TestNoNoncense.DataCase
    end
  end

  setup tags do
    repos =
      case tags[:repo] do
        :pg -> [MyApp.PgRepo]
        :mysql -> [MyApp.MysqlRepo]
        _ -> [MyApp.PgRepo, MyApp.MysqlRepo]
      end

    for repo <- repos do
      :ok =
        if isolation_level = tags[:isolation] do
          Ecto.Adapters.SQL.Sandbox.checkout(repo, isolation: isolation_level)
        else
          Ecto.Adapters.SQL.Sandbox.checkout(repo)
        end

      unless tags[:async] do
        Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      end
    end

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  @spec errors_on({:error, Ecto.Changeset.t()} | Ecto.Changeset.t()) :: %{
          optional(atom) => [binary]
        }
  def errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  def errors_on({_, %Ecto.Changeset{} = changeset}), do: errors_on(changeset)
  def errors_on(other), do: other
end
