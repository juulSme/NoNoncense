defmodule NoNoncense.MachineId.LeaseStoreTest do
  use ExUnit.Case, async: true

  alias NoNoncense.MachineId.LeaseStore

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp put(name, machine_id, lease, ttl_ms) do
    LeaseStore.put(name, machine_id, lease, ttl_ms, System.monotonic_time(:millisecond))
  end

  defp renew(name, lease, ttl_ms) do
    LeaseStore.renew(name, lease, ttl_ms, System.monotonic_time(:millisecond))
  end

  defp expire(name) do
    %{timer: timer} = :sys.get_state(name)
    send(name, {:timeout, timer, :expired})
  end

  defp start_store!(opts \\ []) do
    name = Keyword.get(opts, :name, unique_name("lease_store"))
    pid = start_supervised!({LeaseStore, Keyword.put(opts, :name, name)})
    %{name: name, pid: pid}
  end

  test "starts empty" do
    %{name: name, pid: pid} = start_store!()

    assert LeaseStore.get(name) == nil
    assert LeaseStore.machine_id(name) == nil
    assert Process.alive?(pid)
  end

  test "stores a lease with a local safety margin" do
    %{name: name, pid: pid} = start_store!()
    before = :erlang.monotonic_time(:millisecond)

    assert {:ok, lease} = put(name, 7, :token, 30_000)

    assert lease.machine_id == 7
    assert lease.lease == :token
    assert_in_delta lease.expires_at_mono, before + 20_000, 10
    assert LeaseStore.get(name) == lease
    assert LeaseStore.machine_id(name) == 7
    assert LeaseStore.valid?(lease)
    assert Process.alive?(pid)
  end

  test "activates factories when accepting a lease and disables them on expiry" do
    instance = unique_name("nonce")
    %{name: name} = start_store!(lease_manager: self(), instances: [[name: instance]])

    assert {:ok, lease} = put(name, 7, :token, 30_000)
    assert <<_::64>> = NoNoncense.nonce(instance, 64)

    expire(name)
    assert_receive {:lease_lost, ^lease, :expired}
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
  end

  test "rejects TTLs below the minimum" do
    %{name: name} = start_store!()

    for ttl_ms <- [-1, 0, 29_999, nil] do
      assert {:error, :illegal_ttl} = put(name, 7, :token, ttl_ms)
    end

    assert LeaseStore.get(name) == nil

    assert {:ok, lease} = put(name, 7, :token, 30_000)

    for ttl_ms <- [-1, 0, 29_999] do
      assert {:error, :illegal_ttl} = renew(name, :token, ttl_ms)
    end

    assert LeaseStore.get(name) == lease
  end

  test "renewing retains the machine ID and replaces the lease" do
    %{name: name, pid: pid} = start_store!()
    put(name, 7, :old_token, 30_000)

    assert {:ok, renewed} = renew(name, :new_token, 30_000)
    assert renewed.machine_id == 7
    assert renewed.lease == :new_token
    assert LeaseStore.get(name) == renewed
    assert Process.alive?(pid)
  end

  test "uses the callback start time for acquisition and renewal expiry" do
    %{name: name} = start_store!()
    started_at = :erlang.monotonic_time(:millisecond) - 5_000

    assert {:ok, lease} = LeaseStore.put(name, 7, :token, 30_000, started_at)
    assert lease.expires_at_mono == started_at + 20_000
    assert {:ok, renewed} = LeaseStore.renew(name, :token, 30_000, started_at)
    assert renewed.expires_at_mono == started_at + 20_000
  end

  test "does not store an acquisition or renewal that is already locally expired" do
    %{name: name} = start_store!()
    started_at = :erlang.monotonic_time(:millisecond) - 20_000

    assert {:error, :expired} = LeaseStore.put(name, 7, :old, 30_000, started_at)
    assert LeaseStore.get(name) == nil

    assert {:ok, lease} = put(name, 7, :current, 30_000)
    assert {:error, :expired} = LeaseStore.renew(name, :late, 30_000, started_at)
    assert LeaseStore.get(name) == lease
  end

  test "does not revive a lease past its expiry even if its timer has not run" do
    %{name: name} = start_store!(lease_manager: self())
    put(name, 7, :token, 30_000)
    now = :erlang.monotonic_time(:millisecond)

    :sys.replace_state(name, fn state -> put_in(state.lease.expires_at_mono, now) end)
    assert renew(name, :token, 30_000) == {:error, :lost}
    assert_receive {:lease_lost, _, :expired}
    assert LeaseStore.get(name) == nil
  end

  test "renewing without an active lease reports loss without crashing" do
    %{name: name, pid: pid} = start_store!()

    assert renew(name, :token, 30_000) == {:error, :lost}
    assert LeaseStore.get(name) == nil
    assert Process.alive?(pid)
  end

  test "losing an empty store is harmless" do
    %{name: name, pid: pid} = start_store!()

    assert LeaseStore.lose(name, :external) == :ok
    assert LeaseStore.get(name) == nil
    assert Process.alive?(pid)
  end

  test "losing a stored lease disables factories and notifies the lease manager once" do
    instance = unique_name("nonce")
    %{name: name} = start_store!(lease_manager: self(), instances: [[name: instance]])

    assert {:ok, lease} = put(name, 7, :lease, 30_000)
    NoNoncense.init(machine_id: 7, name: instance)
    %{timer: timer} = :sys.get_state(name)

    assert LeaseStore.lose(name, :external) == :ok
    assert_receive {:lease_lost, ^lease, :external}
    assert LeaseStore.get(name) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end

    send(name, {:timeout, timer, :expired})
    refute_receive {:lease_lost, _, _}, 20
  end

  test "discarding a stored lease disables factories without notifying the lease manager" do
    instance = unique_name("nonce")
    %{name: name} = start_store!(lease_manager: self(), instances: [[name: instance]])

    put(name, 7, :lease, 30_000)
    NoNoncense.init(machine_id: 7, name: instance)

    assert LeaseStore.discard(name) == :ok
    assert LeaseStore.get(name) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
    refute_receive {:lease_lost, _, _}, 20
  end

  test "treats a lease at or past its local expiry boundary as invalid" do
    now = :erlang.monotonic_time(:millisecond)

    refute LeaseStore.valid?(nil)
    refute LeaseStore.valid?(:invalid)
    refute LeaseStore.valid?(%{})
    refute LeaseStore.valid?(%{expires_at_mono: now})
    refute LeaseStore.valid?(%{expires_at_mono: now - 1})
    assert LeaseStore.valid?(%{expires_at_mono: now + 1_000})
  end

  test "does not report an expired lease through get or machine_id" do
    %{name: name} = start_store!()
    put(name, 7, :token, 30_000)
    now = :erlang.monotonic_time(:millisecond)

    :sys.replace_state(name, fn state -> put_in(state.lease.expires_at_mono, now) end)
    assert LeaseStore.get(name) == nil
    assert LeaseStore.machine_id(name) == nil
  end

  test "expiry removes the stored lease and disables factories before notifying the lease manager" do
    instance = unique_name("nonce")
    %{name: name} = start_store!(lease_manager: self(), instances: [[name: instance]])

    assert {:ok, lease} = put(name, 7, :lease, 30_000)
    NoNoncense.init(machine_id: 7, name: instance)
    expire(name)

    assert_receive {:lease_lost, ^lease, :expired}
    assert LeaseStore.get(name) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
  end

  test "an old timer cannot expire a renewed lease" do
    instance = unique_name("nonce")
    %{name: name} = start_store!(lease_manager: self(), instances: [[name: instance]])

    put(name, 7, :lease1, 30_000)
    NoNoncense.init(machine_id: 7, name: instance)
    %{timer: old_timer} = :sys.get_state(name)
    {:ok, renewed_lease} = renew(name, :lease2, 30_000)

    send(name, {:timeout, old_timer, :expired})
    refute_receive {:lease_lost, _, :expired}, 20
    assert LeaseStore.get(name) == renewed_lease
    assert <<_::64>> = NoNoncense.nonce(instance, 64)

    expire(name)
    assert_receive {:lease_lost, ^renewed_lease, :expired}
    assert renew(name, :late_lease, 30_000) == {:error, :lost}
  end

  test "stays alive when the lease manager is absent as an active lease expires" do
    instance = unique_name("nonce")
    missing_lease_manager = unique_name("lease_manager")

    %{name: name, pid: pid} =
      start_store!(lease_manager: missing_lease_manager, instances: [[name: instance]])

    assert {:ok, lease} = put(name, 7, :lease, 30_000)
    NoNoncense.init(machine_id: 7, name: instance)
    expire(name)
    :sys.get_state(name)

    assert Process.alive?(pid)
    assert LeaseStore.get(name) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
    assert lease.machine_id == 7
  end

  test "disables configured factories when no stored lease exists at startup" do
    instance = unique_name("nonce")
    NoNoncense.init(machine_id: 7, name: instance)

    start_store!(instances: [[name: instance]])

    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
  end
end
