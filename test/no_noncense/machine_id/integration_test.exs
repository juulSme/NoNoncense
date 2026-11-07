defmodule NoNoncense.MachineId.IntegrationTest do
  @moduledoc """
  Full-stack tests wiring `NoNoncense.MachineId` up to a real `RedisLease`/Redis backend, as
  opposed to the FakeStrategy-based unit tests elsewhere, which prove the individual pieces
  (LeaseManager retry/backoff, factory lifecycle, strategy commands) work in isolation but not
  that they cooperate correctly against a real coordinator.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  @moduletag :integration

  alias NoNoncense.MachineId
  alias NoNoncense.MachineId.LeaseStore
  alias NoNoncense.MachineId.Strategy.RedisLease

  setup_all do
    {:ok, conn} = start_supervised({Redix, database: 15})
    {:ok, "OK"} = Redix.command(conn, ["FLUSHDB"])
    [conn: conn]
  end

  setup %{conn: conn} do
    %{conn: conn, key: Ecto.UUID.generate()}
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp start_machine_id!(opts, conn, key) do
    test_pid = self()
    name = unique_name("sup")

    opts =
      opts
      |> Keyword.put_new(:name, name)
      |> Keyword.put_new(:strategy, RedisLease)
      |> Keyword.put_new(:strategy_opts, with_connection: conn, key: key)
      |> Keyword.put_new(:lease_duration, 40_000)
      |> Keyword.put_new(:renew_interval, 40_000)
      |> Keyword.put_new(:enable_conflict_guard?, false)
      |> Keyword.put_new(:on_lease_lost, fn reason -> send(test_pid, {:lease_lost, reason}) end)

    start_supervised!(Supervisor.child_spec({MachineId, opts}, id: opts[:name]))

    %{
      name: opts[:name],
      lease_manager: Module.concat(name, :LeaseManager),
      lease_store: Module.concat(name, :LeaseStore)
    }
  end

  defp renew(lease_manager) do
    {:renew, ref} = :sys.get_state(lease_manager).timer
    send(lease_manager, {:timeout, ref, :renew})
  end

  defp assert_eventually(assertion, attempts \\ 20)
  defp assert_eventually(assertion, 0), do: assertion.()

  defp assert_eventually(assertion, attempts) do
    assertion.()
  rescue
    _error in [ExUnit.AssertionError, NoNoncense.Errors.DisabledError] ->
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
  end

  describe "acquisition against a real backend" do
    test "two competing nodes get distinct machine IDs and both generate nonces", fixtures do
      db_a = unique_name("db")
      db_b = unique_name("db")

      %{lease_store: store_a} =
        start_machine_id!([instances: [[name: db_a]]], fixtures.conn, fixtures.key)

      %{lease_store: store_b} =
        start_machine_id!([instances: [[name: db_b]]], fixtures.conn, fixtures.key)

      id_a = LeaseStore.machine_id(store_a)
      id_b = LeaseStore.machine_id(store_b)

      assert id_a != id_b
      assert <<_::64>> = NoNoncense.nonce(db_a, 64)
      assert <<_::64>> = NoNoncense.nonce(db_b, 64)
    end
  end

  describe "renewal against a real backend" do
    test "retries when the connection wrapper exits", fixtures do
      attempts = start_supervised!({Agent, fn -> 0 end})

      with_connection = fn fun ->
        attempt = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)
        if attempt == 1, do: exit(:pool_timeout), else: fun.(fixtures.conn)
      end

      %{lease_manager: lm, lease_store: store} =
        start_machine_id!(
          [instances: [], strategy_opts: [with_connection: with_connection, key: fixtures.key]],
          fixtures.conn,
          fixtures.key
        )

      log =
        capture_log(fn ->
          renew(lm)
          :sys.get_state(lm)
        end)

      assert log =~ "Lease renewal failed"
      assert LeaseStore.machine_id(store) == 0
      assert {:renew, _ref} = :sys.get_state(lm).timer
    end

    test "a :renew tick refreshes the lease TTL in Redis", fixtures do
      db_name = unique_name("db")

      %{lease_manager: lm, lease_store: store} =
        start_machine_id!([instances: [[name: db_name]]], fixtures.conn, fixtures.key)

      %{lease: {id, token}} = LeaseStore.get(store)

      assert {:ok, [1, 1]} =
               Redix.command(fixtures.conn, [
                 "HPEXPIRE",
                 fixtures.key,
                 "20000",
                 "FIELDS",
                 "2",
                 "#{id}",
                 "token.#{id}.#{token}"
               ])

      {:ok, [ttl_before]} =
        Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "#{id}"])

      {:renew, old_ref} = :sys.get_state(lm).timer
      renew(lm)

      assert_eventually(fn -> refute :sys.get_state(lm).timer == {:renew, old_ref} end)

      {:ok, [ttl_after]} =
        Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "#{id}"])

      assert ttl_after > ttl_before
    end
  end

  describe "lease loss against a real backend" do
    test "lease loss invokes the callback and automatically restores factories after reacquisition",
         fixtures do
      db_name = unique_name("db")

      %{lease_manager: lm, lease_store: store} =
        start_machine_id!(
          [instances: [[name: db_name]]],
          fixtures.conn,
          fixtures.key
        )

      id = LeaseStore.machine_id(store)
      assert <<_::64>> = NoNoncense.nonce(db_name, 64)

      # simulate another node ripping the lease out from under the running one
      {:ok, _} = Redix.command(fixtures.conn, ["HDEL", fixtures.key, "#{id}"])

      {_, _log} =
        with_log(fn ->
          renew(lm)
          assert_receive {:lease_lost, :expired}, 200
        end)

      assert_eventually(fn -> assert <<_::64>> = NoNoncense.nonce(db_name, 64) end)
    end
  end

  describe "lease release against a real backend" do
    test "stopping the supervisor releases the id back to Redis", fixtures do
      db_name = unique_name("db")

      %{name: sup_name, lease_store: store} =
        start_machine_id!([instances: [[name: db_name]]], fixtures.conn, fixtures.key)

      id = LeaseStore.machine_id(store)

      stop_supervised!(sup_name)

      assert {:ok, nil} = Redix.command(fixtures.conn, ["HGET", fixtures.key, "#{id}"])
    end
  end
end
