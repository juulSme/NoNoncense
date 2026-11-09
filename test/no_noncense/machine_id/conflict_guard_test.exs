defmodule NoNoncense.MachineId.ConflictGuardTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias NoNoncense.MachineId.ConflictGuard

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  setup do
    test_pid = self()

    pid =
      start_supervised!(
        {ConflictGuard, machine_id: 0, on_conflict: fn -> send(test_pid, :conflict) end}
      )

    [pid: pid]
  end

  test "ignores peers with a different machine ID", %{pid: pid} do
    GenServer.cast(pid, {:id_from, :peer, %{machine_id: 1, init_at: 0}})

    :sys.get_state(pid)
    refute_received :conflict
  end

  test "does not act when an older node detects the conflict", %{pid: pid} do
    init_at = :sys.get_state(pid).init_at

    log =
      capture_log(fn ->
        GenServer.cast(pid, {:id_from, :peer, %{machine_id: 0, init_at: init_at + 1}})
        :sys.get_state(pid)
        refute_received :conflict
      end)

    assert log =~ "it will resolve the conflict"
  end

  test "calls on_conflict when this node is newer than its conflicting peer", %{pid: pid} do
    init_at = :sys.get_state(pid).init_at

    log =
      capture_log(fn ->
        GenServer.cast(pid, {:id_from, :peer, %{machine_id: 0, init_at: init_at - 1}})
        assert_receive :conflict
      end)

    assert log =~ "this node will resolve the conflict"
  end

  test "does not act while the machine ID getter returns nil" do
    test_pid = self()

    guard =
      Supervisor.child_spec(
        {ConflictGuard,
         name: unique_name("conflict_guard"),
         machine_id: fn -> nil end,
         on_conflict: fn -> send(test_pid, :conflict) end},
        id: unique_name("nil_id_guard")
      )

    pid = start_supervised!(guard)

    GenServer.cast(pid, {:id_from, :peer, %{machine_id: 0, init_at: 0}})

    :sys.get_state(pid)
    refute_received :conflict
  end

  test "broadcasts only the resolved machine ID and start timestamp", %{pid: pid} do
    recipient = unique_name("peer_guard")
    Process.register(self(), recipient)
    state = :sys.replace_state(pid, &%{&1 | name: recipient})
    node = Node.self()

    send(pid, {:nodeup, node})

    assert_receive {:"$gen_cast", {:id_from, ^node, payload}}
    assert payload == %{machine_id: 0, init_at: state.init_at}
  end

  test "broadcasts the resolved machine ID from a getter" do
    test_pid = self()
    name = unique_name("conflict_guard")

    guard =
      Supervisor.child_spec(
        {ConflictGuard,
         name: name, machine_id: fn -> 0 end, on_conflict: fn -> send(test_pid, :conflict) end},
        id: unique_name("getter_guard")
      )

    pid = start_supervised!(guard)

    log =
      capture_log(fn ->
        send(pid, {:nodeup, Node.self()})
        assert_receive :conflict
      end)

    assert log =~ "this node will resolve the conflict"
  end
end
