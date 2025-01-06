defmodule NoNoncense.MachineId.ConflictGuardTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias NoNoncense.MachineId
  alias MachineId.ConflictGuard

  setup do
    test_pid = self()
    config = [machine_id: 0, on_conflict: fn -> send(test_pid, :shut_down!) end]
    [pid: start_link_supervised!({ConflictGuard, config})]
  end

  defp expect_to_receive(message) do
    receive do
      received -> received
    after
      200 -> "no message"
    end
    |> case do
      received -> assert received == message
    end
  end

  defp expect_log_message({res, msg}, expected_msg) do
    assert msg =~ expected_msg
    {res, msg}
  end

  describe "handle_info({:nodeup, node})" do
    test "calls the node's genserver with its own contact info and state", seeds do
      # start conflictguard and send it the message that the current node is up
      # this will of course be in conflict with itself
      with_log(fn ->
        send(seeds.pid, {:nodeup, Node.self()})
        expect_to_receive(:shut_down!)
      end)
      |> expect_log_message("I'm the newer node")
    end
  end

  describe "handle_cast/2" do
    test "does nothing if no ID conflict", seeds do
      with_log(fn ->
        GenServer.cast(seeds.pid, {:id_from, Node.self(), %{machine_id: 1, init_at: 0}})
        expect_to_receive("no message")
      end)
      |> expect_log_message("machine ID 1 joined")
    end

    test "does nothing if oldest node with ID conflict", seeds do
      with_log(fn ->
        now = System.system_time(:millisecond)
        # send a message from a newer machine, with a later init_at
        GenServer.cast(seeds.pid, {:id_from, Node.self(), %{machine_id: 0, init_at: now + 20000}})
        expect_to_receive("no message")
      end)
      |> expect_log_message("I was here first")
      |> expect_log_message("[critical]")
    end

    test "calls on_conflict callback", seeds do
      with_log(fn ->
        now = System.system_time(:millisecond)
        # send a message from an older machine, with an earlier init_at
        GenServer.cast(seeds.pid, {:id_from, Node.self(), %{machine_id: 0, init_at: now - 20000}})
        expect_to_receive(:shut_down!)
      end)
      |> expect_log_message("taking evasive action!")
      |> expect_log_message("[critical]")
    end
  end
end
