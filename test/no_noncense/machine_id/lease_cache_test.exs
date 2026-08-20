defmodule NoNoncense.MachineId.LeaseCacheTest do
  use ExUnit.Case, async: true

  alias NoNoncense.MachineId.LeaseCache

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp start_cache! do
    name = unique_name("lease_cache")
    pid = start_supervised!({LeaseCache, name: name})
    %{name: name, pid: pid}
  end

  test "starts empty and clearing an empty cache is harmless" do
    %{name: name, pid: pid} = start_cache!()

    assert LeaseCache.get(name) == nil
    assert LeaseCache.clear(name) == nil
    assert LeaseCache.get(name) == nil
    assert Process.alive?(pid)
  end

  test "stores a lease with a local safety margin" do
    %{name: name, pid: pid} = start_cache!()
    before = :erlang.monotonic_time(:millisecond)

    lease = LeaseCache.put(name, 7, :token, 30_000)

    assert lease.machine_id == 7
    assert lease.lease == :token
    assert_in_delta lease.expires_at_mono, before + 20_000, 10
    assert LeaseCache.get(name) == lease
    assert LeaseCache.valid?(lease)
    assert Process.alive?(pid)
  end

  test "renewing retains the machine ID and replaces the lease" do
    %{name: name, pid: pid} = start_cache!()
    LeaseCache.put(name, 7, :old_token, 30_000)

    assert {:ok, renewed} = LeaseCache.renew(name, :new_token, 30_000)
    assert renewed.machine_id == 7
    assert renewed.lease == :new_token
    assert LeaseCache.get(name) == renewed
    assert Process.alive?(pid)
  end

  test "renewing without an active lease reports loss without crashing" do
    %{name: name, pid: pid} = start_cache!()

    assert LeaseCache.renew(name, :token, 30_000) == :lost
    assert LeaseCache.get(name) == nil
    assert Process.alive?(pid)
  end

  test "renew survives malformed cache states" do
    %{name: name, pid: pid} = start_cache!()

    for state <- [%{}, :invalid, 42, [], {:machine_id, 7}] do
      :sys.replace_state(name, fn _ -> state end)

      assert LeaseCache.renew(name, :token, 30_000) == :lost
      assert LeaseCache.get(name) == nil
      assert Process.alive?(pid)
    end
  end

  test "renew safely repairs a partial lease map" do
    %{name: name, pid: pid} = start_cache!()
    :sys.replace_state(name, fn _ -> %{machine_id: 7} end)

    assert {:ok, lease} = LeaseCache.renew(name, :token, 30_000)
    assert lease.machine_id == 7
    assert lease.lease == :token
    assert LeaseCache.get(name) == lease
    assert Process.alive?(pid)
  end

  test "clearing returns the active lease and prevents further renewal" do
    %{name: name, pid: pid} = start_cache!()
    lease = LeaseCache.put(name, 7, :token, 30_000)

    assert LeaseCache.clear(name) == lease
    assert LeaseCache.get(name) == nil
    assert LeaseCache.renew(name, :replacement, 30_000) == :lost
    assert Process.alive?(pid)
  end

  test "clear survives malformed cache states" do
    %{name: name, pid: pid} = start_cache!()

    for state <- [%{}, :invalid, 42, [], {:machine_id, 7}] do
      :sys.replace_state(name, fn _ -> state end)

      assert LeaseCache.clear(name) == state
      assert LeaseCache.get(name) == nil
      assert Process.alive?(pid)
    end
  end

  test "treats a lease at or past its local expiry boundary as invalid" do
    now = :erlang.monotonic_time(:millisecond)

    refute LeaseCache.valid?(nil)
    refute LeaseCache.valid?(%{expires_at_mono: now})
    refute LeaseCache.valid?(%{expires_at_mono: now - 1})
    assert LeaseCache.valid?(%{expires_at_mono: now + 1_000})
  end
end
