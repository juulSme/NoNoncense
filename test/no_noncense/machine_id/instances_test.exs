defmodule NoNoncense.MachineId.InstancesTest do
  use ExUnit.Case, async: true
  import Bitwise
  import NoNoncense.State
  use NoNoncense.Constants

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

  test "waits past reserved 64-bit counter timestamps" do
    name = unique_name()
    :ok = NoNoncense.init(name: name, machine_id: 3)
    state(init_at: old_init_at, counters_ref: counters) = :persistent_term.get(name)

    # a burst of 64-bit nonces that reserved timestamps 5ms into the future
    reserved_ts = old_init_at + 5
    :atomics.put(counters, @counter64_idx, (reserved_ts <<< @count_bits_64) + 42)
    Instances.disable(name: name)

    assert :ok = Instances.re_init(name: name, machine_id: 3)
    state(init_at: init_at) = :persistent_term.get(name)
    assert init_at > reserved_ts
  end

  test "waits past the last sortable counter timestamp" do
    name = unique_name()
    :ok = NoNoncense.init(name: name, machine_id: 3)
    state(init_at: old_init_at, counters_ref: counters) = :persistent_term.get(name)

    reserved_ts = old_init_at + 5
    :atomics.put(counters, @sortable_counter_idx, (reserved_ts <<< @non_ts_bits_64) + 42)
    Instances.disable(name: name)

    assert :ok = Instances.re_init(name: name, machine_id: 3)
    state(init_at: init_at) = :persistent_term.get(name)
    assert init_at > reserved_ts
  end

  test "waits past timestamps used by an intermediate machine ID (A -> B -> A)" do
    name = unique_name()
    :ok = NoNoncense.init(name: name, machine_id: 3)

    assert :ok = Instances.re_init(name: name, machine_id: 4)
    state(init_at: b_init_at, counters_ref: b_counters) = :persistent_term.get(name)

    reserved_ts = b_init_at + 5
    :atomics.put(b_counters, @sortable_counter_idx, (reserved_ts <<< @non_ts_bits_64) + 42)

    assert :ok = Instances.re_init(name: name, machine_id: 3)
    state(machine_id: 3, init_at: init_at) = :persistent_term.get(name)
    assert init_at > reserved_ts
  end
end
