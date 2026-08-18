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
  alias NoNoncense.MachineId.LeaseManager
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

    %{name: opts[:name], lease_manager: Module.concat(name, :LeaseManager)}
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

  describe "acquisition against a real backend" do
    test "two competing nodes get distinct machine IDs and both generate nonces", fixtures do
      db_a = unique_name("db")
      db_b = unique_name("db")

      %{lease_manager: lm_a} =
        start_machine_id!([instances: [[name: db_a]]], fixtures.conn, fixtures.key)

      %{lease_manager: lm_b} =
        start_machine_id!([instances: [[name: db_b]]], fixtures.conn, fixtures.key)

      id_a = LeaseManager.machine_id(lm_a)
      id_b = LeaseManager.machine_id(lm_b)

      assert id_a != id_b
      assert <<_::64>> = NoNoncense.nonce(db_a, 64)
      assert <<_::64>> = NoNoncense.nonce(db_b, 64)
    end
  end

  describe "renewal against a real backend" do
    test "a :renew tick refreshes the lease TTL in Redis", fixtures do
      db_name = unique_name("db")

      %{lease_manager: lm} =
        start_machine_id!([instances: [[name: db_name]]], fixtures.conn, fixtures.key)

      id = LeaseManager.machine_id(lm)

      # let the TTL decay a bit in real time so a refreshed TTL is measurably higher
      Process.sleep(100)

      {:ok, [ttl_before]} =
        Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "#{id}"])

      generation = :sys.get_state(lm).generation
      renew(lm)

      assert_eventually(fn -> assert :sys.get_state(lm).generation > generation end)

      {:ok, [ttl_after]} =
        Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "#{id}"])

      assert ttl_after > ttl_before
    end
  end

  describe "lease loss against a real backend" do
    test "lease loss invokes the callback and automatically restores factories after reacquisition",
         fixtures do
      db_name = unique_name("db")

      %{lease_manager: lm} =
        start_machine_id!(
          [instances: [[name: db_name]]],
          fixtures.conn,
          fixtures.key
        )

      id = LeaseManager.machine_id(lm)
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

      %{name: sup_name, lease_manager: lm} =
        start_machine_id!([instances: [[name: db_name]]], fixtures.conn, fixtures.key)

      id = LeaseManager.machine_id(lm)

      stop_supervised!(sup_name)

      assert {:ok, nil} = Redix.command(fixtures.conn, ["HGET", fixtures.key, "#{id}"])
    end
  end
end
