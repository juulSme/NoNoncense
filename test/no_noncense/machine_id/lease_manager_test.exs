defmodule NoNoncense.MachineId.LeaseManagerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias NoNoncense.MachineId.{LeaseCache, LeaseManager}

  defmodule FakeStrategy do
    @behaviour NoNoncense.MachineId.Strategy

    def start_agent(acquire, renew),
      do: Agent.start_link(fn -> %{acquire: acquire, renew: renew} end)

    @impl true
    def acquire(_lease_duration, opts) do
      result = pop(opts[:agent], :acquire)
      if pid = opts[:notify], do: send(pid, {:acquire, result})
      result
    end

    @impl true
    def renew(_lease, _lease_duration, opts) do
      result = pop(opts[:agent], :renew)
      if pid = opts[:notify], do: send(pid, {:renew, result})
      result
    end

    @impl true
    def release(lease, opts) do
      if pid = opts[:notify], do: send(pid, {:release, lease})
      :ok
    end

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

  defp start_lease_manager!(opts) do
    test_pid = self()
    name = Keyword.get(opts, :name, unique_name("lm"))

    opts =
      opts
      |> Keyword.put_new(:name, name)
      |> Keyword.put_new(:lease_duration, 100_000)
      |> Keyword.put_new(:renew_interval, 100_000)
      |> Keyword.put_new(:on_lease_lost, fn reason -> send(test_pid, {:lease_lost, reason}) end)

    start_supervised!({LeaseManager, opts})
    name
  end

  defp renew(name) do
    state = :sys.get_state(name)
    send(name, {:renew, state.generation})
  end

  describe "initial acquisition" do
    test "retries synchronously until it acquires a lease" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:error, :down}, {:ok, 7, :lease, 100_000}], [
          {:ok, :lease, 100_000}
        ])

      {name, _log} =
        with_log(fn ->
          start_lease_manager!(strategy: FakeStrategy, strategy_opts: [agent: agent])
        end)

      assert LeaseManager.machine_id(name) == 7
    end

    test "fails startup when acquisition does not succeed before the timeout" do
      {:ok, agent} = FakeStrategy.start_agent([{:error, :down}], [{:ok, :lease, 100_000}])
      Process.flag(:trap_exit, true)

      {result, _log} =
        with_log(fn ->
          LeaseManager.start_link(
            name: unique_name("lm"),
            strategy: FakeStrategy,
            strategy_opts: [agent: agent],
            acquire_timeout: 30
          )
        end)

      assert {:error, :lease_acquisition_failed} = result
    end

    test "does not retry acquisition after the deadline" do
      {:ok, agent} = FakeStrategy.start_agent([{:error, :down}], [{:ok, :lease, 100_000}])
      Process.flag(:trap_exit, true)

      {result, _log} =
        with_log(fn ->
          LeaseManager.start_link(
            name: unique_name("lm"),
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: self()],
            acquire_timeout: 50
          )
        end)

      assert {:error, :lease_acquisition_failed} = result
      assert_receive {:acquire, {:error, :down}}
      refute_receive {:acquire, _}, 20
    end

    test "treats a granted TTL below the minimum as an immediate loss" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :lease1, 29_999}], [])
      test_pid = self()
      Process.flag(:trap_exit, true)

      {result, _log} =
        with_log(fn ->
          LeaseManager.start_link(
            name: unique_name("lm"),
            strategy: FakeStrategy,
            strategy_opts: [agent: agent],
            on_lease_lost: fn reason -> send(test_pid, {:lease_lost, reason}) end
          )
        end)

      assert {:error, :lease_acquisition_failed} = result
      assert_receive {:lease_lost, :illegal_ttl}
    end

    test "renews a cached lease before attempting a new acquisition" do
      cache_name = unique_name("cache")
      start_supervised!({LeaseCache, name: cache_name})
      LeaseCache.put(cache_name, %{machine_id: 12, lease: :cached, leased?: true})

      {:ok, agent} =
        FakeStrategy.start_agent([{:error, :should_not_acquire}], [{:ok, :cached, 100_000}])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent],
          lease_cache: cache_name
        )

      assert LeaseManager.machine_id(name) == 12
    end

    test "disables factories when a cached lease cannot be renewed" do
      cache_name = unique_name("cache")
      instance = unique_name("nonce")
      test_pid = self()
      start_supervised!({LeaseCache, name: cache_name})
      LeaseCache.put(cache_name, %{machine_id: 12, lease: :cached, leased?: true})
      NoNoncense.init(machine_id: 12, name: instance)

      {:ok, agent} =
        FakeStrategy.start_agent([{:error, :down}], [{:error, :retry, :unavailable}])

      Process.flag(:trap_exit, true)

      {result, _log} =
        with_log(fn ->
          LeaseManager.start_link(
            name: unique_name("lm"),
            strategy: FakeStrategy,
            strategy_opts: [agent: agent],
            lease_cache: cache_name,
            instances: [[name: instance]],
            acquire_timeout: 0,
            on_lease_lost: fn reason -> send(test_pid, {:lease_lost, reason}) end
          )
        end)

      assert {:error, :lease_acquisition_failed} = result
      assert_receive {:lease_lost, :timeout}
      assert LeaseCache.get(cache_name) == %{machine_id: nil, lease: nil, leased?: false}
      assert_raise ArgumentError, fn -> NoNoncense.nonce(instance, 64) end
    end
  end

  describe "renewal and loss" do
    test "renews from a generation-tagged timer message" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 3, :lease1, 100_000}], [{:ok, :lease2, 100_000}])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()]
        )

      renew(name)

      assert_receive {:renew, {:ok, :lease2, 100_000}}
      assert LeaseManager.machine_id(name) == 3
    end

    test "keeps factories available after an ambiguous renewal failure" do
      instance = unique_name("nonce")

      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 3, :lease1, 100_000}], [{:error, :retry, :hiccup}])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()],
          instances: [[name: instance]]
        )

      log =
        capture_log(fn ->
          renew(name)
          assert_receive {:renew, {:error, :retry, :hiccup}}
          :sys.get_state(name)
        end)

      assert log =~ "Lease renewal failed"
      assert LeaseManager.machine_id(name) == 3
      assert <<_::64>> = NoNoncense.nonce(instance, 64)
      refute_receive {:lease_lost, _}, 20
    end

    test "disables factories, calls back, and reacquires after confirmed loss" do
      instance = unique_name("nonce")
      test_pid = self()

      {:ok, agent} =
        FakeStrategy.start_agent(
          [{:ok, 3, :lease1, 100_000}, {:ok, 4, :lease2, 100_000}],
          [{:error, :lost, :stolen}]
        )

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()],
          on_lease_lost: fn reason ->
            send(test_pid, {:lease_lost, reason})
            receive do: (:resume_reacquisition -> :ok)
          end,
          instances: [[name: instance]]
        )

      assert_receive {:acquire, {:ok, 3, :lease1, 100_000}}
      assert <<_::64>> = NoNoncense.nonce(instance, 64)

      log =
        capture_log(fn ->
          renew(name)
          assert_receive {:renew, {:error, :lost, :stolen}}
          assert_receive {:lease_lost, :stolen}
        end)

      assert log =~ "Lease of ID 3 lost: :stolen"
      assert_raise ArgumentError, fn -> NoNoncense.nonce(instance, 64) end
      send(name, :resume_reacquisition)
      assert_receive {:acquire, {:ok, 4, :lease2, 100_000}}
      assert LeaseManager.machine_id(name) == 4
      assert <<_::64>> = NoNoncense.nonce(instance, 64)
    end

    defmodule DeterministicFakeStrategy do
      @behaviour NoNoncense.MachineId.Strategy

      defdelegate start_agent(acquire, renew), to: FakeStrategy
      @impl true
      defdelegate acquire(lease_duration, opts), to: FakeStrategy
      @impl true
      defdelegate renew(lease, lease_duration, opts), to: FakeStrategy
      @impl true
      defdelegate release(lease, opts), to: FakeStrategy
      @impl true
      def deterministic?(), do: true
    end

    test "does not reacquire after confirmed loss for a deterministic strategy" do
      instance = unique_name("nonce")

      {:ok, agent} =
        DeterministicFakeStrategy.start_agent(
          [{:ok, 3, :lease1, 100_000}],
          [{:error, :lost, :conflict}]
        )

      name =
        start_lease_manager!(
          strategy: DeterministicFakeStrategy,
          strategy_opts: [agent: agent, notify: self()],
          instances: [[name: instance]]
        )

      assert_receive {:acquire, {:ok, 3, :lease1, 100_000}}
      assert <<_::64>> = NoNoncense.nonce(instance, 64)

      capture_log(fn ->
        renew(name)
        assert_receive {:renew, {:error, :lost, :conflict}}
        assert_receive {:lease_lost, :conflict}
      end)

      assert_raise ArgumentError, fn -> NoNoncense.nonce(instance, 64) end
      refute_receive {:acquire, _}, 20
      assert %{leased?: false, timers: timers} = :sys.get_state(name)
      refute Map.has_key?(timers, :reacquire)
    end

    test "handles externally signalled loss through the same lifecycle" do
      instance = unique_name("nonce")
      test_pid = self()

      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 3, :lease1, 100_000}], [{:ok, :lease1, 100_000}])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent],
          on_lease_lost: fn reason ->
            send(test_pid, {:lease_lost, reason})
            receive do: (:resume_reacquisition -> :ok)
          end,
          instances: [[name: instance]]
        )

      log =
        capture_log(fn ->
          task = Task.async(fn -> LeaseManager.lease_lost(name) end)
          assert_receive {:lease_lost, :external}
          assert_raise ArgumentError, fn -> NoNoncense.nonce(instance, 64) end
          send(name, :resume_reacquisition)
          assert :ok = Task.await(task)
        end)

      assert log =~ "Lease of ID 3 lost: :external"
    end
  end

  describe "renewal scheduling" do
    # renew fires 10s before the earlier of the TTL and renew_interval margins, expired fires
    # 10s before actual TTL expiry - leaving a 10s gap for retries between the two
    defp scheduled_delays(name) do
      %{timers: timers} = :sys.get_state(name)
      {Process.read_timer(timers[:renew]), Process.read_timer(timers[:expired])}
    end

    test "renew and expired are scheduled off the granted TTL when it is the limiting factor" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :lease1, 40_000}], [])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent],
          renew_interval: 100_000
        )

      {renew_delay, expired_delay} = scheduled_delays(name)

      assert_in_delta renew_delay, 20_000, 1_000
      assert_in_delta expired_delay, 30_000, 1_000
    end

    test "renew is scheduled off renew_interval, with margin, when it is the limiting factor" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :lease1, 100_000}], [])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent],
          renew_interval: 20_000
        )

      {renew_delay, expired_delay} = scheduled_delays(name)

      assert_in_delta renew_delay, 10_000, 1_000
      assert_in_delta expired_delay, 90_000, 1_000
    end
  end

  describe "shutdown" do
    test "releases a currently held lease" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 3, :lease1, 100_000}], [{:ok, :lease1, 100_000}])

      start_lease_manager!(strategy: FakeStrategy, strategy_opts: [agent: agent, notify: self()])

      stop_supervised!(LeaseManager)

      assert_receive {:release, :lease1}
    end
  end
end
