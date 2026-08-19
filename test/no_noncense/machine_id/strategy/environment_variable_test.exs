defmodule NoNoncense.MachineId.Strategy.EnvironmentVariableTest do
  use ExUnit.Case, async: false

  alias NoNoncense.MachineId.Strategy.EnvironmentVariable

  @environment_variable "NO_NONCENSE_TEST_MACHINE_ID"

  setup do
    previous = System.get_env(@environment_variable)

    on_exit(fn ->
      if previous,
        do: System.put_env(@environment_variable, previous),
        else: System.delete_env(@environment_variable)
    end)
  end

  test "acquires the numeric suffix as the machine ID" do
    System.put_env(@environment_variable, "nonce-worker-123")

    assert {:ok, 123, :static, 60_000} =
             EnvironmentVariable.acquire(60_000, variable_name: @environment_variable)
  end

  test "returns an error when the environment variable is missing" do
    System.delete_env(@environment_variable)

    assert {:error, "env var NO_NONCENSE_TEST_MACHINE_ID not found"} =
             EnvironmentVariable.acquire(60_000, variable_name: @environment_variable)
  end

  test "returns an error when the environment variable has no numeric suffix" do
    System.put_env(@environment_variable, "nonce-worker")

    assert {:error, "could not parse NO_NONCENSE_TEST_MACHINE_ID=nonce-worker"} =
             EnvironmentVariable.acquire(60_000, variable_name: @environment_variable)
  end

  test "renews and releases its stateless lease" do
    assert {:ok, :lease, 60_000} = EnvironmentVariable.renew(:lease, 60_000, [])
    assert :ok = EnvironmentVariable.release(:lease, [])
  end
end
