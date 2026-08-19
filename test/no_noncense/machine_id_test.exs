defmodule NoNoncense.MachineIdTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias NoNoncense.MachineId.LeaseManager

  defmodule FakeStrategy do
    @behaviour NoNoncense.MachineId.Strategy

    def start_agent(acquire, renew),
      do: Agent.start_link(fn -> %{acquire: acquire, renew: renew} end)

    @impl true
    def acquire(_lease_duration, opts), do: pop(opts[:agent], :acquire)

    @impl true
    def renew(_lease, _lease_duration, opts), do: pop(opts[:agent], :renew)

    @impl true
    def release(_, _), do: :ok

    @impl true
    def deterministic?(), do: false

    defp pop(agent, key) do
      Agent.get_and_update(agent, fn state ->
        case Map.fetch!(state, key) do
          [last] -> {last, state}
          [next | rest] -> {next, Map.put(state, key, rest)}
        end
      end)
    end
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp start_machine_id!(opts) do
    test_pid = self()
    name = Keyword.get(opts, :name, unique_name("sup"))

    opts =
      opts
      |> Keyword.put_new(:name, name)
      |> Keyword.put_new(:lease_duration, 100_000)
      |> Keyword.put_new(:renew_interval, 100_000)
      |> Keyword.put_new(:on_lease_lost, fn reason -> send(test_pid, {:lease_lost, reason}) end)

    start_supervised!({NoNoncense.MachineId, opts})
    %{name: name, lease_manager: Module.concat(name, :LeaseManager)}
  end

  defp renew(lease_manager) do
    state = :sys.get_state(lease_manager)
    send(lease_manager, {:renew, state.generation})
  end

  defp assert_eventually(assertion, attempts \\ 20)
  defp assert_eventually(assertion, 0), do: assertion.()

  defp assert_eventually(assertion, attempts) do
    assertion.()
  rescue
    _error in [ExUnit.AssertionError, ArgumentError] ->
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
  end

  describe "initial acquisition" do
    test "blocks until it acquires a lease, then initializes factories" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:error, :down}, {:ok, 7, :lease, 100_000}], [
          {:ok, :lease, 100_000}
        ])

      instance = unique_name("nonce")

      {machine_id, _log} =
        with_log(fn ->
          start_machine_id!(
            strategy: FakeStrategy,
            strategy_opts: [agent: agent],
            enable_conflict_guard?: false,
            instances: [[name: instance]]
          )
        end)

      assert LeaseManager.machine_id(machine_id.lease_manager) == 7
      assert <<_::64>> = NoNoncense.nonce(instance, 64)
    end

    test "fails startup when no lease can be acquired before the timeout" do
      {:ok, agent} = FakeStrategy.start_agent([{:error, :down}], [{:ok, :lease, 100_000}])
      Process.flag(:trap_exit, true)

      {result, _log} =
        with_log(fn ->
          NoNoncense.MachineId.start_link(
            name: unique_name("sup"),
            strategy: FakeStrategy,
            strategy_opts: [agent: agent],
            acquire_timeout: 30,
            enable_conflict_guard?: false,
            instances: [[name: unique_name("nonce")]]
          )
        end)

      assert {:error, _reason} = result
    end

    test "initializes every configured factory with the leased machine ID" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 9, :lease, 100_000}], [{:ok, :lease, 100_000}])

      db_name = unique_name("db")
      iv_name = unique_name("iv")

      machine_id =
        start_machine_id!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent],
          enable_conflict_guard?: false,
          instances: [[name: db_name], [name: iv_name]]
        )

      assert LeaseManager.machine_id(machine_id.lease_manager) == 9
      assert <<_::64>> = NoNoncense.nonce(db_name, 64)
      assert <<_::64>> = NoNoncense.nonce(iv_name, 64)
    end
  end

  describe "conflict guard" do
    test "starts ConflictGuard by default" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 2, :lease, 100_000}], [{:ok, :lease, 100_000}])

      %{name: name} =
        start_machine_id!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent],
          instances: [[name: unique_name("nonce")]]
        )

      assert Process.whereis(Module.concat(name, :ConflictGuard))
    end
  end

  describe "lease loss" do
    test "disables factories, invokes the reason callback, and restores factories after reacquisition" do
      {:ok, agent} =
        FakeStrategy.start_agent(
          [{:ok, 3, :lease1, 100_000}, {:ok, 4, :lease2, 100_000}],
          [{:error, :lost, :stolen}]
        )

      instance = unique_name("nonce")
      test_pid = self()

      machine_id =
        start_machine_id!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent],
          enable_conflict_guard?: false,
          on_lease_lost: fn reason ->
            send(test_pid, {:lease_lost, reason})
            receive do: (:resume_reacquisition -> :ok)
          end,
          instances: [[name: instance]]
        )

      assert <<_::64>> = NoNoncense.nonce(instance, 64)

      log =
        capture_log(fn ->
          renew(machine_id.lease_manager)
          assert_receive {:lease_lost, :stolen}
        end)

      assert log =~ "Lease of ID 3 lost: :stolen"
      assert_raise ArgumentError, fn -> NoNoncense.nonce(instance, 64) end
      send(machine_id.lease_manager, :resume_reacquisition)

      assert_eventually(fn ->
        assert LeaseManager.machine_id(machine_id.lease_manager) == 4
        assert <<_::64>> = NoNoncense.nonce(instance, 64)
      end)
    end
  end
end
