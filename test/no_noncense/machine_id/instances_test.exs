defmodule NoNoncense.MachineId.InstancesTest do
  use ExUnit.Case, async: true
  import NoNoncense.State

  alias NoNoncense.MachineId.Instances

  defp unique_name(), do: :"instance_#{System.unique_integer([:positive])}"

  test "keeps an enabled instance that already has the machine ID" do
    name = unique_name()
    :ok = NoNoncense.init(name: name, machine_id: 3)
    before = :persistent_term.get(name)

    assert :ok = Instances.re_init(name: name, machine_id: 3)
    assert :persistent_term.get(name) == before
  end

  test "initializes a disabled instance afresh, even with the same machine ID" do
    name = unique_name()
    :ok = NoNoncense.init(name: name, machine_id: 3)
    state(counters_ref: old_counters) = :persistent_term.get(name)
    Instances.disable(name: name)

    assert :ok = Instances.re_init(name: name, machine_id: 3)
    state(counters_ref: counters, enabled?: enabled?) = :persistent_term.get(name)
    assert enabled?
    refute counters == old_counters
  end

  test "initializes an instance afresh when the machine ID changes" do
    name = unique_name()
    :ok = NoNoncense.init(name: name, machine_id: 3)
    state(counters_ref: old_counters) = :persistent_term.get(name)

    assert :ok = Instances.re_init(name: name, machine_id: 4)
    state(machine_id: 4, counters_ref: counters) = :persistent_term.get(name)
    refute counters == old_counters
  end

  test "reinitializes a disabled instance strictly after the previous init_at" do
    name = unique_name()
    :ok = NoNoncense.init(name: name, machine_id: 3)
    state(init_at: old_init_at) = :persistent_term.get(name)
    Instances.disable(name: name)

    assert :ok = Instances.re_init(name: name, machine_id: 3)
    state(init_at: init_at) = :persistent_term.get(name)
    assert init_at > old_init_at
  end
end
