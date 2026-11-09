defmodule NoNoncense.MachineId.LeaseManagerTest do
  use ExUnit.Case, async: true
  use Mimic
  import ExUnit.CaptureLog

  alias NoNoncense.MachineId.{LeaseStore, LeaseManager}

  defmodule FakeStrategy do
    @behaviour NoNoncense.MachineId.Strategy

    def start_agent(acquire, renew) do
      spec = {Agent, fn -> %{acquire: acquire, renew: renew} end}
      ExUnit.Callbacks.start_supervised(Supervisor.child_spec(spec, id: make_ref()))
    end

    @impl true
    def acquire(_lease_duration, opts) do
      result = opts[:agent] |> pop(:acquire) |> resolve(:acquire, opts)
      if pid = opts[:notify], do: send(pid, {:acquire, result})
      result
    end

    @impl true
    def renew(_lease, _lease_duration, opts) do
      result = opts[:agent] |> pop(:renew) |> resolve(:renew, opts)
      if pid = opts[:notify], do: send(pid, {:renew, result})
      result
    end

    @impl true
    def release(lease, opts) do
      if pid = opts[:notify], do: send(pid, {:release, lease})

      if pid = opts[:block_release] do
        send(pid, {:release_blocked, lease, self()})

        receive do
          {:resume_release, ^lease} -> :ok
        end
      end

      case opts[:release_failure] do
        {^lease, failure} -> resolve(failure, :release, opts)
        _ -> :ok
      end
    end

    @impl true
    def deterministic?(), do: false

    defp resolve(:block, operation, opts) do
      send(opts[:notify], {:blocked, operation, self()})

      receive do
        {:resume, result} -> result
      end
    end

    defp resolve({:late_write, result}, :acquire, opts) do
      notify = opts[:notify]

      backend =
        spawn(fn ->
          receive do
            :commit -> send(notify, {:committed, result})
          end
        end)

      send(notify, {:backend, backend})

      receive do
        :backend_response -> result
      end
    end

    defp resolve(failure, operation, opts) when failure in [:crash, :raise, :throw] do
      if pid = opts[:notify], do: send(pid, {:strategy_failure, operation, failure, self()})

      case failure do
        :crash -> exit(:strategy_crashed)
        :raise -> raise "strategy raised"
        :throw -> throw(:strategy_threw)
      end
    end

    defp resolve(result, _operation, _opts), do: result

    defp pop(agent, key) do
      Agent.get_and_update(agent, fn state ->
        case Map.fetch!(state, key) do
          [last] -> {last, state}
          [next | rest] -> {next, Map.put(state, key, rest)}
        end
      end)
    end
  end

  defmodule FailingSqlRepo do
    def update_all(_query, _updates) do
      raise(DBConnection.ConnectionError, message: "connection closed")
    end
  end

  defmodule FailingSqlRenewalStrategy do
    use NoNoncense.MachineId.Strategy

    @impl true
    def acquire(_lease_duration, _opts), do: {:ok, 3, {3, "token"}, 100_000}

    @impl true
    defdelegate renew(lease, lease_duration, opts),
      to: NoNoncense.MachineId.Strategy.SqlLease
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp store_name(name), do: :"#{name}_cache"

  defp start_dependencies!(name, opts) do
    store = Keyword.get(opts, :lease_store, store_name(name))

    if is_nil(Process.whereis(store)) do
      start_supervised!(
        {LeaseStore,
         name: store, lease_manager: name, instances: Keyword.get(opts, :instances, [])}
      )
    end

    task_supervisor = start_supervised!({Task.Supervisor, []})
    [lease_store: store, task_supervisor: task_supervisor]
  end

  defp start_lease_manager!(opts) do
    test_pid = self()
    name = Keyword.get(opts, :name, unique_name("lm"))
    restart = Keyword.get(opts, :restart, :temporary)

    dependencies = start_dependencies!(name, opts)

    opts =
      opts
      |> Keyword.delete(:restart)
      |> Keyword.put_new(:name, name)
      |> Keyword.put_new(:lease_duration, 100_000)
      |> Keyword.put_new(:renew_interval, 100_000)
      |> Keyword.put_new(:on_lease_lost, fn reason -> send(test_pid, {:lease_lost, reason}) end)
      |> Keyword.merge(dependencies)

    start_supervised!(Supervisor.child_spec({LeaseManager, opts}, restart: restart))
    name
  end

  # For managers expected to fail during init; unwraps the child spec ExUnit adds to the reason
  defp start_failing_manager(opts, dependencies) do
    with_log(fn ->
      {:error, {reason, _child_spec}} = start_supervised({LeaseManager, opts ++ dependencies})
      {:error, reason}
    end)
  end

  defp renew(name) do
    {:renew, ref} = :sys.get_state(name).timer
    send(name, {:timeout, ref, :renew})
  end

  defp await_strategy_tasks(name) do
    task_supervisor = :sys.get_state(name).task_supervisor

    for worker <- Task.Supervisor.children(task_supervisor) do
      worker_ref = Process.monitor(worker)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    end
  end

  describe "strategy failure isolation" do
    for failure <- [:crash, :raise, :throw] do
      test "retries startup acquisition after a strategy #{failure}" do
        failure = unquote(failure)
        {:ok, agent} = FakeStrategy.start_agent([failure, {:ok, 7, :lease, 100_000}], [])

        capture_log(fn ->
          name =
            start_lease_manager!(
              strategy: FakeStrategy,
              strategy_opts: [agent: agent, notify: self()],
              attempt: 0
            )

          assert_receive {:strategy_failure, :acquire, ^failure, worker}
          refute Process.alive?(worker)
          assert %{strategy_lease: :lease, machine_id: 7} = LeaseStore.get(store_name(name))
          assert %{timer: {:renew, _ref}, attempt: 1} = :sys.get_state(name)
          refute_received {:lease_lost, _reason}
        end)
      end

      test "preserves the lease and recovers after a renewal strategy #{failure}" do
        failure = unquote(failure)
        instance = unique_name("nonce")

        {:ok, agent} =
          FakeStrategy.start_agent([{:ok, 7, :original, 100_000}], [
            failure,
            {:ok, :renewed, 100_000}
          ])

        name =
          start_lease_manager!(
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: self()],
            instances: [[name: instance]]
          )

        manager = Process.whereis(name)
        lease = LeaseStore.get(store_name(name))

        capture_log(fn ->
          renew(name)
          assert_receive {:strategy_failure, :renew, ^failure, worker}
          assert %{timer: {:renew, _ref}, attempt: 2} = :sys.get_state(name)
          refute Process.alive?(worker)
          assert Process.whereis(name) == manager
          assert LeaseStore.get(store_name(name)) == lease
          assert <<_::64>> = NoNoncense.nonce(instance, 64)
          refute_received {:lease_lost, _reason}

          renew(name)
          assert %{timer: {:renew, _ref}, attempt: 1} = :sys.get_state(name)
          assert %{strategy_lease: :renewed} = LeaseStore.get(store_name(name))
          assert Process.whereis(name) == manager
        end)
      end

      test "retries reacquisition after a strategy #{failure}" do
        failure = unquote(failure)
        instance = unique_name("nonce")

        {:ok, agent} =
          FakeStrategy.start_agent(
            [{:ok, 7, :original, 100_000}, failure, {:ok, 8, :replacement, 100_000}],
            []
          )

        name =
          start_lease_manager!(
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: self()],
            instances: [[name: instance]]
          )

        manager = Process.whereis(name)

        capture_log(fn ->
          assert :ok = LeaseStore.lose(store_name(name), :external)
          assert_receive {:strategy_failure, :acquire, ^failure, worker}
          assert %{timer: {:acquire, ref}, attempt: 2} = :sys.get_state(name)
          refute Process.alive?(worker)
          assert Process.whereis(name) == manager
          assert LeaseStore.get(store_name(name)) == nil
          assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end

          send(name, {:timeout, ref, :acquire})
          assert %{timer: {:renew, _ref}, attempt: 1} = :sys.get_state(name)
          assert %{strategy_lease: :replacement, machine_id: 8} = LeaseStore.get(store_name(name))
          assert <<_::64>> = NoNoncense.nonce(instance, 64)
          assert Process.whereis(name) == manager
          assert_receive {:lease_lost, :external}
          refute_received {:lease_lost, _reason}
        end)
      end

      test "reacquires despite a background release strategy #{failure}" do
        failure = unquote(failure)
        instance = unique_name("nonce")

        {:ok, agent} =
          FakeStrategy.start_agent(
            [{:ok, 7, :original, 100_000}, {:ok, 8, :replacement, 100_000}],
            []
          )

        name =
          start_lease_manager!(
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: self(), release_failure: {:original, failure}],
            instances: [[name: instance]]
          )

        manager = Process.whereis(name)

        capture_log(fn ->
          assert :ok = LeaseStore.lose(store_name(name), :external)
          assert_receive {:strategy_failure, :release, ^failure, worker}
          worker_ref = Process.monitor(worker)
          assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
          assert_receive {:acquire, {:ok, 8, :replacement, 100_000}}
          assert %{timer: {:renew, _ref}, attempt: 1} = :sys.get_state(name)
          assert Process.whereis(name) == manager
          assert %{strategy_lease: :replacement, machine_id: 8} = LeaseStore.get(store_name(name))
          assert <<_::64>> = NoNoncense.nonce(instance, 64)
          assert_receive {:lease_lost, :external}
          refute_received {:lease_lost, _reason}
        end)
      end

      test "shuts down gracefully despite a release strategy #{failure}" do
        failure = unquote(failure)
        instance = unique_name("nonce")
        {:ok, agent} = FakeStrategy.start_agent([{:ok, 7, :original, 100_000}], [])

        name =
          start_lease_manager!(
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: self(), release_failure: {:original, failure}],
            instances: [[name: instance]]
          )

        manager = Process.whereis(name)
        manager_ref = Process.monitor(manager)

        capture_log(fn ->
          assert :ok = GenServer.stop(name, :normal)
          assert_receive {:strategy_failure, :release, ^failure, worker}
          refute Process.alive?(worker)
          assert_receive {:DOWN, ^manager_ref, :process, ^manager, :normal}
          assert LeaseStore.get(store_name(name)) == nil
          assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
          refute_received {:lease_lost, _reason}
        end)
      end
    end
  end

  describe "manager boundaries" do
    test "rejects non-positive and non-integer callback timeouts" do
      dependencies = start_dependencies!(unique_name("lm"), [])

      for timeout <- [0, -1, nil, :infinity, "5000", 1.5] do
        assert_raise ArgumentError, ":callback_timeout must be a positive integer", fn ->
          LeaseManager.start_link(
            [strategy: FakeStrategy, callback_timeout: timeout] ++ dependencies
          )
        end
      end
    end

    test "ignores stale renewal and acquisition timers without calling the strategy" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 7, :lease, 100_000}], [{:ok, :lease, 100_000}])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()]
        )

      assert_receive {:acquire, {:ok, 7, :lease, 100_000}}
      {:renew, old_ref} = :sys.get_state(name).timer
      renew(name)
      current = :sys.get_state(name)
      assert_receive {:renew, {:ok, :lease, 100_000}}
      refute current.timer == {:renew, old_ref}

      for kind <- [:renew, :acquire] do
        send(name, {:timeout, old_ref, kind})
        assert :sys.get_state(name) == current
      end

      refute_received {:acquire, _result}
      refute_received {:renew, _result}
    end

    test "logs unexpected messages without changing the lease or schedule" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 7, :lease, 100_000}], [])
      name = start_lease_manager!(strategy: FakeStrategy, strategy_opts: [agent: agent])
      current = :sys.get_state(name)
      lease = LeaseStore.get(store_name(name))

      log =
        capture_log(fn ->
          send(name, :unexpected)
          assert :sys.get_state(name) == current
        end)

      assert log =~ "Unknown handle_info message received: :unexpected"
      assert LeaseStore.get(store_name(name)) == lease
    end

    test "does not renew a locally expired lease before its expiry timer is handled" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 7, :lease, 100_000}], [:crash])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()]
        )

      now = System.monotonic_time(:millisecond)
      :sys.replace_state(store_name(name), &put_in(&1.local_lease.expires_at_mono, now))
      renew(name)

      assert %{timer: nil, attempt: 1} = :sys.get_state(name)
      assert LeaseStore.get(store_name(name)) == nil
      refute_received {:strategy_failure, :renew, _failure, _worker}
      refute_received {:lease_lost, _reason}
    end

    test "resumes the stored lease after an abnormal manager exit without resetting factories" do
      instance = unique_name("nonce")

      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 7, :lease, 100_000}], [{:ok, :lease, 100_000}])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()],
          instances: [[name: instance]],
          restart: :permanent
        )

      assert_receive {:acquire, {:ok, 7, :lease, 100_000}}
      manager = Process.whereis(name)
      manager_ref = Process.monitor(manager)
      config = :persistent_term.get(instance)

      capture_log(fn ->
        assert :ok = GenServer.stop(name, :simulated_failure)
        assert_receive {:DOWN, ^manager_ref, :process, ^manager, :simulated_failure}
        assert_receive {:renew, {:ok, :lease, 100_000}}
        assert %{timer: {:renew, _ref}} = :sys.get_state(name)
        refute Process.whereis(name) == manager
        assert %{strategy_lease: :lease, machine_id: 7} = LeaseStore.get(store_name(name))
        assert :persistent_term.get(instance) == config
        assert <<_::64>> = NoNoncense.nonce(instance, 64)
        refute_received {:acquire, _result}
        refute_received {:release, _lease}
        refute_received {:lease_lost, _reason}
      end)
    end
  end

  describe "initial acquisition" do
    test "retries acquisition with an infinite startup deadline" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:error, :unavailable}, {:ok, 7, :lease, 100_000}], [])

      capture_log(fn ->
        name =
          start_lease_manager!(
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: self()],
            acquire_timeout: :infinity,
            attempt: 0
          )

        assert_receive {:acquire, {:error, :unavailable}}
        assert_receive {:acquire, {:ok, 7, :lease, 100_000}}
        assert %{strategy_lease: :lease, machine_id: 7} = LeaseStore.get(store_name(name))
        assert %{timer: {:renew, _ref}} = :sys.get_state(name)
      end)
    end

    test "releases an expired startup grant and acquires a replacement" do
      name = unique_name("lm")
      instance = unique_name("nonce")
      dependencies = start_dependencies!(name, instances: [[name: instance]])
      store = dependencies[:lease_store]

      {:ok, agent} =
        FakeStrategy.start_agent(
          [{:ok, 7, :expired, 30_000}, {:ok, 8, :replacement, 30_000}],
          []
        )

      expired_now = System.monotonic_time(:millisecond) + 100_000
      stub(System, :monotonic_time, &:erlang.monotonic_time/1)
      expect(System, :monotonic_time, fn :millisecond -> expired_now end)
      allow(System, self(), Process.whereis(store))

      capture_log(fn ->
        start_supervised!(
          {LeaseManager,
           [
             name: name,
             strategy: FakeStrategy,
             strategy_opts: [agent: agent, notify: self()],
             acquire_timeout: 1_000
           ] ++ dependencies}
        )

        assert_receive {:release, :expired}
        assert_receive {:acquire, {:ok, 8, :replacement, 30_000}}
        assert %{strategy_lease: :replacement, machine_id: 8} = LeaseStore.get(store)
        assert %{timer: {:renew, _ref}} = :sys.get_state(name)
        assert <<_::64>> = NoNoncense.nonce(instance, 64)
      end)
    end

    test "requires a strategy, lease store and task supervisor" do
      assert_raise ArgumentError, ":strategy must be provided", fn ->
        LeaseManager.start_link(lease_store: unique_name("store"))
      end

      assert_raise ArgumentError, ":lease_store must be provided", fn ->
        LeaseManager.start_link(strategy: FakeStrategy)
      end

      assert_raise ArgumentError, ":task_supervisor must be provided", fn ->
        LeaseManager.start_link(strategy: FakeStrategy, lease_store: unique_name("store"))
      end
    end

    test "retries synchronously until it acquires a lease" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:error, :down}, {:ok, 7, :lease, 100_000}], [
          {:ok, :lease, 100_000}
        ])

      {name, _log} =
        with_log(fn ->
          start_lease_manager!(strategy: FakeStrategy, strategy_opts: [agent: agent])
        end)

      assert LeaseStore.machine_id(store_name(name)) == 7
    end

    test "fails startup when acquisition does not succeed before the timeout" do
      {:ok, agent} = FakeStrategy.start_agent([{:error, :down}], [{:ok, :lease, 100_000}])
      name = unique_name("lm")
      dependencies = start_dependencies!(name, [])

      {result, _log} =
        start_failing_manager(
          [
            name: name,
            strategy: FakeStrategy,
            strategy_opts: [agent: agent],
            acquire_timeout: 30
          ],
          dependencies
        )

      assert {:error, :lease_acquisition_failed} = result
    end

    test "disables factories when acquisition fails without a stored lease" do
      {:ok, agent} = FakeStrategy.start_agent([], [])
      instance = unique_name("nonce")
      name = unique_name("lm")
      dependencies = start_dependencies!(name, instances: [[name: instance]])
      NoNoncense.init(machine_id: 7, name: instance)

      {result, _log} =
        start_failing_manager(
          [
            name: name,
            strategy: FakeStrategy,
            strategy_opts: [agent: agent],
            acquire_timeout: 0,
            instances: [[name: instance]]
          ],
          dependencies
        )

      assert {:error, :lease_acquisition_failed} = result
      assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
    end

    test "does not retry acquisition after the deadline" do
      {:ok, agent} = FakeStrategy.start_agent([{:error, :down}], [{:ok, :lease, 100_000}])
      name = unique_name("lm")
      dependencies = start_dependencies!(name, [])

      {result, _log} =
        start_failing_manager(
          [
            name: name,
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: self()],
            acquire_timeout: 50
          ],
          dependencies
        )

      assert {:error, :lease_acquisition_failed} = result
      assert_receive {:acquire, {:error, :down}}
      refute_received {:acquire, _}
    end

    test "bounds a blocked acquisition by the overall startup deadline" do
      {:ok, agent} = FakeStrategy.start_agent([:block], [])
      name = unique_name("lm")
      dependencies = start_dependencies!(name, [])
      started_at = System.monotonic_time(:millisecond)

      {result, _log} =
        start_failing_manager(
          [
            name: name,
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: self()],
            acquire_timeout: 60,
            callback_timeout: 1_000
          ],
          dependencies
        )

      assert {:error, :lease_acquisition_failed} = result
      assert System.monotonic_time(:millisecond) - started_at < 500
      assert_received {:blocked, :acquire, worker}
      refute Process.alive?(worker)
    end

    test "ignores a backend write that completes after acquisition times out" do
      {:ok, agent} =
        FakeStrategy.start_agent(
          [{:late_write, {:ok, 3, :abandoned, 100_000}}, {:ok, 4, :current, 100_000}],
          []
        )

      {name, _log} =
        with_log(fn ->
          start_lease_manager!(
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: self()],
            callback_timeout: 40,
            acquire_timeout: 1_000
          )
        end)

      assert_received {:backend, backend}
      send(backend, :commit)
      assert_receive {:committed, {:ok, 3, :abandoned, 100_000}}
      assert LeaseStore.machine_id(store_name(name)) == 4
      assert %{strategy_lease: :current} = LeaseStore.get(store_name(name))
    end

    test "falls back to acquisition when cached renewal times out" do
      store = unique_name("store")
      start_supervised!({LeaseStore, name: store})
      LeaseStore.put(store, 12, :stored, 100_000, System.monotonic_time(:millisecond))
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 4, :replacement, 100_000}], [:block])

      start_lease_manager!(
        strategy: FakeStrategy,
        strategy_opts: [agent: agent, notify: self()],
        lease_store: store,
        callback_timeout: 40
      )

      assert_received {:blocked, :renew, worker}
      refute Process.alive?(worker)
      assert LeaseStore.machine_id(store) == 4
    end

    test "treats a granted TTL below the minimum as an immediate loss" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :lease1, 29_999}], [])
      test_pid = self()
      name = unique_name("lm")
      dependencies = start_dependencies!(name, [])

      {result, _log} =
        start_failing_manager(
          [
            name: name,
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, notify: test_pid],
            on_lease_lost: fn reason -> send(test_pid, {:lease_lost, reason}) end
          ],
          dependencies
        )

      assert {:error, :lease_acquisition_failed} = result
      assert_receive {:lease_lost, :illegal_ttl}
      assert_receive {:release, :lease1}
    end

    test "releases a rejected renewed token during startup" do
      store = unique_name("store")
      name = unique_name("lm")
      start_supervised!({LeaseStore, name: store})
      LeaseStore.put(store, 12, :stored, 100_000, System.monotonic_time(:millisecond))
      dependencies = start_dependencies!(name, lease_store: store)
      {:ok, agent} = FakeStrategy.start_agent([], [{:ok, :rotated, 29_999}])

      {result, _log} =
        start_failing_manager(
          [name: name, strategy: FakeStrategy, strategy_opts: [agent: agent, notify: self()]],
          dependencies
        )

      assert {:error, :lease_acquisition_failed} = result
      assert_receive {:release, :rotated}
      assert LeaseStore.get(store) == nil
    end

    test "disables cached factories before releasing a rejected startup renewal" do
      instance = unique_name("nonce")
      name = unique_name("lm")
      dependencies = start_dependencies!(name, instances: [[name: instance]])
      store = dependencies[:lease_store]
      LeaseStore.put(store, 12, :stored, 100_000, System.monotonic_time(:millisecond))
      {:ok, agent} = FakeStrategy.start_agent([], [{:ok, :rotated, 29_999}])
      test_pid = self()

      start_supervised!(
        {Task,
         fn ->
           Process.flag(:trap_exit, true)

           result =
             LeaseManager.start_link(
               [
                 name: name,
                 strategy: FakeStrategy,
                 strategy_opts: [agent: agent, block_release: test_pid]
               ] ++ dependencies
             )

           send(test_pid, {:startup_result, result})
         end}
      )

      assert_receive {:release_blocked, :rotated, worker}
      assert LeaseStore.get(store) == nil
      assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
      refute_receive {:startup_result, _}, 20
      send(worker, {:resume_release, :rotated})
      assert_receive {:startup_result, {:error, :lease_acquisition_failed}}
    end

    test "waits for rejected startup lease release before failing" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :rejected, 29_999}], [])
      name = unique_name("lm")
      dependencies = start_dependencies!(name, [])
      test_pid = self()

      task =
        Task.async(fn ->
          Process.flag(:trap_exit, true)

          LeaseManager.start_link(
            [
              name: name,
              strategy: FakeStrategy,
              strategy_opts: [agent: agent, block_release: test_pid]
            ] ++ dependencies
          )
        end)

      assert_receive {:release_blocked, :rejected, worker}
      assert Task.yield(task, 20) == nil
      send(worker, {:resume_release, :rejected})
      assert {:error, :lease_acquisition_failed} = Task.await(task)
    end

    test "hands a rejected startup lease release to the background once the deadline is reached" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :rejected, 29_999}], [])
      name = unique_name("lm")
      dependencies = start_dependencies!(name, [])
      started_at = System.monotonic_time(:millisecond)

      {result, _log} =
        start_failing_manager(
          [
            name: name,
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, block_release: self()],
            acquire_timeout: 60,
            callback_timeout: 1_000
          ],
          dependencies
        )

      assert {:error, :lease_acquisition_failed} = result
      assert System.monotonic_time(:millisecond) - started_at < 500
      assert_received {:release_blocked, :rejected, worker}
      refute Process.alive?(worker)
      assert_receive {:release_blocked, :rejected, async_worker}
      assert async_worker != worker
      send(async_worker, {:resume_release, :rejected})
    end

    test "hands a rejected cached renewal release to the background once the deadline is reached" do
      {:ok, agent} = FakeStrategy.start_agent([], [{:ok, :rotated, 29_999}])
      name = unique_name("lm")
      dependencies = start_dependencies!(name, [])

      LeaseStore.put(
        dependencies[:lease_store],
        12,
        :stored,
        100_000,
        System.monotonic_time(:millisecond)
      )

      started_at = System.monotonic_time(:millisecond)

      {result, _log} =
        start_failing_manager(
          [
            name: name,
            strategy: FakeStrategy,
            strategy_opts: [agent: agent, block_release: self()],
            acquire_timeout: 60,
            callback_timeout: 1_000
          ],
          dependencies
        )

      assert {:error, :lease_acquisition_failed} = result
      assert System.monotonic_time(:millisecond) - started_at < 500
      assert_received {:release_blocked, :rotated, worker}
      refute Process.alive?(worker)
      assert_receive {:release_blocked, :rotated, async_worker}
      assert async_worker != worker
      send(async_worker, {:resume_release, :rotated})
      assert LeaseStore.get(dependencies[:lease_store]) == nil
    end

    test "renews a stored lease before attempting a new acquisition" do
      store_name = unique_name("store")
      start_supervised!({LeaseStore, name: store_name})
      LeaseStore.put(store_name, 12, :stored, 100_000, System.monotonic_time(:millisecond))

      {:ok, agent} =
        FakeStrategy.start_agent([{:error, :should_not_acquire}], [{:ok, :stored, 100_000}])

      start_lease_manager!(
        strategy: FakeStrategy,
        strategy_opts: [agent: agent],
        lease_store: store_name
      )

      assert LeaseStore.machine_id(store_name) == 12
    end

    test "acquires a fresh lease when the previous lease was lost while the manager was absent" do
      store = unique_name("store")
      name = unique_name("lm")
      instance = unique_name("nonce")

      start_supervised!(
        {LeaseStore, name: store, lease_manager: name, instances: [[name: instance]]}
      )

      LeaseStore.put(store, 12, :previous, 100_000, System.monotonic_time(:millisecond))
      assert :ok = LeaseStore.lose(store, :expired)
      assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end

      {:ok, agent} = FakeStrategy.start_agent([{:ok, 4, :replacement, 100_000}], [])

      capture_log(fn ->
        start_lease_manager!(
          name: name,
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()],
          lease_store: store,
          instances: [[name: instance]]
        )
      end)

      assert_receive {:acquire, {:ok, 4, :replacement, 100_000}}
      assert LeaseStore.machine_id(store) == 4
      assert <<_::64>> = NoNoncense.nonce(instance, 64)
      await_strategy_tasks(name)
      refute_received {:lease_lost, :expired}
      refute_received {:release, :previous}
    end

    defmodule RaceStrategy do
      @moduledoc "Forces the lease store to expire the store mid-renew, simulating a race."
      @behaviour NoNoncense.MachineId.Strategy

      @impl true
      def acquire(_lease_duration, _opts), do: {:ok, 4, :replacement, 100_000}

      @impl true
      def renew(_lease, _lease_duration, opts) do
        send(opts[:lease_store], {:timeout, opts[:timer], :expired})
        # block until the expired message above has been processed
        :sys.get_state(opts[:lease_store])
        {:ok, :renewed, 100_000}
      end

      @impl true
      def release(lease, opts) do
        if opts[:notify], do: send(opts[:notify], {:release, lease})
        :ok
      end

      @impl true
      def deterministic?(), do: false
    end

    test "falls back to a fresh acquisition when the store expires mid-renew" do
      store_name = unique_name("store")
      name = unique_name("lm")
      test_pid = self()
      start_supervised!({LeaseStore, name: store_name, lease_manager: name})
      task_supervisor = start_supervised!({Task.Supervisor, []})
      LeaseStore.put(store_name, 12, :stored, 30_000, System.monotonic_time(:millisecond))

      %{timer: timer} = :sys.get_state(store_name)

      {result, _log} =
        with_log(fn ->
          start_supervised(
            {LeaseManager,
             name: name,
             strategy: RaceStrategy,
             strategy_opts: [lease_store: store_name, timer: timer, notify: test_pid],
             lease_store: store_name,
             task_supervisor: task_supervisor,
             on_lease_lost: fn reason -> send(test_pid, {:lease_lost, reason}) end,
             instances: []}
          )
        end)

      assert {:ok, _pid} = result
      assert LeaseStore.machine_id(store_name) == 4
      assert_receive {:release, :renewed}
      assert %{timer: {:renew, _ref}} = :sys.get_state(name)
      refute_received {:lease_lost, :expired}
    end

    test "does not report an old stored lease as lost after acquiring a replacement" do
      store_name = unique_name("store")
      start_supervised!({LeaseStore, name: store_name})
      LeaseStore.put(store_name, 12, :stored, 100_000, System.monotonic_time(:millisecond))

      {:ok, agent} =
        FakeStrategy.start_agent(
          [{:ok, 4, :replacement, 100_000}],
          [{:error, :retry, :unavailable}]
        )

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()],
          lease_store: store_name
        )

      assert LeaseStore.machine_id(store_name) == 4
      assert_receive {:release, :stored}
      assert %{timer: {:renew, _ref}} = :sys.get_state(name)
      refute_received {:lease_lost, _}
    end

    test "disables factories when a stored lease cannot be renewed" do
      store_name = unique_name("store")
      instance = unique_name("nonce")
      test_pid = self()
      name = unique_name("lm")

      start_supervised!(
        {LeaseStore, name: store_name, lease_manager: name, instances: [[name: instance]]}
      )

      LeaseStore.put(store_name, 12, :stored, 100_000, System.monotonic_time(:millisecond))
      NoNoncense.init(machine_id: 12, name: instance)

      {:ok, agent} =
        FakeStrategy.start_agent([{:error, :down}], [{:error, :retry, :unavailable}])

      dependencies =
        start_dependencies!(name, lease_store: store_name, instances: [[name: instance]])

      {result, _log} =
        start_failing_manager(
          [
            name: name,
            strategy: FakeStrategy,
            strategy_opts: [agent: agent],
            lease_store: store_name,
            instances: [[name: instance]],
            acquire_timeout: 0,
            on_lease_lost: fn reason -> send(test_pid, {:lease_lost, reason}) end
          ],
          dependencies
        )

      assert {:error, :lease_acquisition_failed} = result
      assert_receive {:lease_lost, :timeout}
      assert LeaseStore.get(store_name) == nil
      assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
    end
  end

  describe "renewal and loss" do
    test "retries a SQL connection exception without losing the confirmed lease" do
      name =
        start_lease_manager!(
          strategy: FailingSqlRenewalStrategy,
          strategy_opts: [repo: FailingSqlRepo]
        )

      lease = LeaseStore.get(store_name(name))

      log =
        capture_log(fn ->
          renew(name)
          :sys.get_state(name)
        end)

      assert log =~ "Lease renewal failed"
      assert LeaseStore.get(store_name(name)) == lease
      assert LeaseStore.machine_id(store_name(name)) == 3
      assert %{timer: {:renew, _ref}} = :sys.get_state(name)
    end

    test "leaves the task supervisor running when the manager dies" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :lease, 100_000}], [:block])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()]
        )

      supervisor = :sys.get_state(name).task_supervisor
      renew(name)
      assert_receive {:blocked, :renew, worker}
      manager_ref = Process.monitor(Process.whereis(name))
      Process.exit(Process.whereis(name), :kill)
      assert_receive {:DOWN, ^manager_ref, :process, _, :killed}
      assert Process.alive?(supervisor)
      send(worker, {:resume, {:ok, :lease, 100_000}})
    end

    test "retries a timed-out renewal without extending the confirmed lease" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :lease, 100_000}], [:block])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()],
          callback_timeout: 40
        )

      lease = LeaseStore.get(store_name(name))

      log =
        capture_log(fn ->
          renew(name)
          assert_receive {:blocked, :renew, worker}
          :sys.get_state(name)
          refute Process.alive?(worker)
        end)

      assert log =~ "Lease renewal failed"
      assert LeaseStore.get(store_name(name)) == lease
      assert LeaseStore.machine_id(store_name(name)) == 3
      assert %{timer: {:renew, _ref}} = :sys.get_state(name)
    end

    test "renews from a timer message" do
      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 3, :lease1, 100_000}], [{:ok, :lease2, 100_000}])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()]
        )

      renew(name)

      assert_receive {:renew, {:ok, :lease2, 100_000}}
      assert LeaseStore.machine_id(store_name(name)) == 3
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
      assert LeaseStore.machine_id(store_name(name)) == 3
      assert <<_::64>> = NoNoncense.nonce(instance, 64)
      refute_received {:lease_lost, _}
    end

    test "releases a rejected renewed token after disabling factories" do
      instance = unique_name("nonce")

      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 3, :original, 100_000}], [{:ok, :rotated, 29_999}])

      name =
        start_lease_manager!(
          strategy: __MODULE__.DeterministicFakeStrategy,
          strategy_opts: [agent: agent, notify: self()],
          instances: [[name: instance]]
        )

      capture_log(fn ->
        renew(name)
        assert_receive {:lease_lost, :illegal_ttl}
        assert_receive {:release, :rotated}
      end)

      assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
      assert LeaseStore.machine_id(store_name(name)) == nil
    end

    test "releases a rejected reacquisition before retrying" do
      {:ok, agent} =
        FakeStrategy.start_agent(
          [{:ok, 3, :original, 100_000}, {:ok, 4, :rejected, 29_999}],
          []
        )

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self()]
        )

      capture_log(fn ->
        assert :ok = LeaseStore.lose(store_name(name), :external)
        assert_receive {:acquire, {:ok, 4, :rejected, 29_999}}
        assert_receive {:release, :rejected}
      end)

      assert LeaseStore.machine_id(store_name(name)) == nil
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
      assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
      send(name, :resume_reacquisition)
      assert_receive {:acquire, {:ok, 4, :lease2, 100_000}}
      # the manager has stored the lease once it has handled the timer message
      :sys.get_state(name)
      assert LeaseStore.machine_id(store_name(name)) == 4
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

      assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
      assert %{timer: nil} = :sys.get_state(name)
      refute_received {:acquire, _}
    end

    test "handles externally signalled loss through the same lifecycle" do
      instance = unique_name("nonce")
      test_pid = self()

      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 3, :lease1, 100_000}], [{:ok, :lease1, 100_000}])

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

      log =
        capture_log(fn ->
          task = Task.async(fn -> LeaseStore.lose(store_name(name), :external) end)
          assert_receive {:lease_lost, :external}
          assert_receive {:release, :lease1}
          assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
          send(name, :resume_reacquisition)
          assert :ok = Task.await(task)
        end)

      assert log =~ "Lease of ID 3 lost: :external"
    end

    test "reacquires without waiting for a blocked release" do
      {:ok, agent} =
        FakeStrategy.start_agent(
          [{:ok, 3, :lease1, 100_000}, {:ok, 4, :lease2, 100_000}],
          [{:ok, :lease1, 100_000}]
        )

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, notify: self(), block_release: self()]
        )

      assert_receive {:acquire, {:ok, 3, :lease1, 100_000}}

      capture_log(fn ->
        assert :ok = LeaseStore.lose(store_name(name), :external)
        assert_receive {:release_blocked, :lease1, release_pid}
        assert_receive {:acquire, {:ok, 4, :lease2, 100_000}}
        :sys.get_state(name)
        assert LeaseStore.machine_id(store_name(name)) == 4
        supervisor = :sys.get_state(name).task_supervisor
        children = Task.Supervisor.children(supervisor)
        assert release_pid in children
        assert length(children) == 2
        send(release_pid, {:resume_release, :lease1})

        stop_task = Task.async(fn -> GenServer.stop(name, :normal) end)
        assert_receive {:release_blocked, :lease2, replacement_release_pid}
        send(replacement_release_pid, {:resume_release, :lease2})
        assert :ok = Task.await(stop_task)
      end)
    end
  end

  describe "renewal scheduling" do
    # renew fires 10s before the earlier of the TTL and renew_interval margins, expired fires
    # 10s before actual TTL expiry - leaving a 10s gap for retries between the two
    defp scheduled_delays(name) do
      %{timer: {:renew, renew_timer}} = :sys.get_state(name)
      %{timer: expiration_timer} = :sys.get_state(store_name(name))
      {Process.read_timer(renew_timer), Process.read_timer(expiration_timer)}
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
    test "bounds a blocked best-effort release" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :lease, 100_000}], [])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, block_release: self()],
          callback_timeout: 40,
          restart: :temporary
        )

      task = Task.async(fn -> GenServer.stop(name, :normal) end)
      assert_receive {:release_blocked, :lease, worker}
      assert :ok = Task.await(task, 500)
      refute Process.alive?(worker)
    end

    test "disables factories before releasing a currently held lease" do
      instance = unique_name("nonce")

      {:ok, agent} =
        FakeStrategy.start_agent([{:ok, 3, :lease1, 100_000}], [{:ok, :lease1, 100_000}])

      start_lease_manager!(
        strategy: FakeStrategy,
        strategy_opts: [agent: agent, notify: self()],
        instances: [[name: instance]]
      )

      assert <<_::64>> = NoNoncense.nonce(instance, 64)

      stop_supervised!(LeaseManager)

      assert_receive {:release, :lease1}
      assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
    end

    test "waits for release to finish before stopping" do
      {:ok, agent} = FakeStrategy.start_agent([{:ok, 3, :lease1, 100_000}], [])

      name =
        start_lease_manager!(
          strategy: FakeStrategy,
          strategy_opts: [agent: agent, block_release: self()],
          restart: :temporary
        )

      task = Task.async(fn -> GenServer.stop(name, :normal) end)
      assert_receive {:release_blocked, :lease1, release_pid}
      assert Task.yield(task, 20) == nil
      send(release_pid, {:resume_release, :lease1})
      assert :ok = Task.await(task)
    end
  end
end
