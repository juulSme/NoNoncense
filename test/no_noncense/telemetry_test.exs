defmodule NoNoncense.TelemetryTest do
  use ExUnit.Case, async: true

  alias NoNoncense.Telemetry

  setup do
    handler_id = {__MODULE__, System.unique_integer([:positive, :monotonic])}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:no_noncense, :machine_id, :lease, :renew, :start],
          [:no_noncense, :machine_id, :lease, :renew, :stop],
          [:no_noncense, :machine_id, :lease, :retry],
          [:no_noncense, :machine_id, :lease, :lost],
          [:no_noncense, :machine_id, :conflict_guard, :conflict]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "emits lease operation spans with a classified result and TTL" do
    assert {:ok, :lease, 60_000} =
             fn -> {:ok, :lease, 60_000} end
             |> Telemetry.lease_operation(:renew, %{strategy: FakeStrategy, source: :scheduled})

    assert_receive {:telemetry, [:no_noncense, :machine_id, :lease, :renew, :start], %{},
                    %{strategy: FakeStrategy, source: :scheduled}}

    assert_receive {:telemetry, [:no_noncense, :machine_id, :lease, :renew, :stop],
                    %{duration: duration, ttl_ms: 60_000},
                    %{strategy: FakeStrategy, source: :scheduled, result: :ok}}

    assert is_integer(duration)
  end

  test "emits normalized retry, loss, and conflict events" do
    Telemetry.lease_retry(:renew, 2, 500, :unavailable)
    Telemetry.lease_lost(:expired, 0)
    Telemetry.conflict(:local_node)

    assert_receive {:telemetry, [:no_noncense, :machine_id, :lease, :retry],
                    %{attempt: 2, delay_ms: 500}, %{operation: :renew, reason: :unavailable}}

    assert_receive {:telemetry, [:no_noncense, :machine_id, :lease, :lost],
                    %{remaining_ttl_ms: 0}, %{reason: :expired}}

    assert_receive {:telemetry, [:no_noncense, :machine_id, :conflict_guard, :conflict], %{},
                    %{resolution: :local_node}}
  end
end
