defmodule NoNoncense.MachineId.LeaseManager.BackoffTest do
  use ExUnit.Case, async: true

  alias NoNoncense.MachineId.LeaseManager.Backoff

  @one_day_ms 24 * 60 * 60 * 1000

  test "returns no delay for attempt zero" do
    assert Backoff.delay(0, 1_000, :infinity) == 0
  end

  test "caps the delay at the configured limit" do
    assert Backoff.delay(2, 1_000, 2_000) == 2_000
  end

  test "accepts an infinite configured limit and caps it at one day" do
    assert Backoff.delay(20, 1_000, :infinity) == @one_day_ms
  end
end
