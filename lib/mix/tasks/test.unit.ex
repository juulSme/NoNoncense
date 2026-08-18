defmodule Mix.Tasks.Test.Unit do
  use Mix.Task

  @shortdoc "Runs unit tests without external services"

  @impl Mix.Task
  def run(args) do
    System.put_env("NO_NONCENSE_UNIT_TESTS", "true")
    Mix.Tasks.Test.run(["--exclude", "integration" | args])
  end
end
