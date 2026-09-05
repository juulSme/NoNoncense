defmodule NoNoncense.MachineId.LeaseStoreTest do
  use ExUnit.Case, async: true

  alias NoNoncense.MachineId.LeaseStore

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp start_store!(opts \\ []) do
    name = Keyword.get(opts, :name, unique_name("lease_store"))
    pid = start_supervised!({LeaseStore, Keyword.put(opts, :name, name)})
    %{name: name, pid: pid}
  end

  test "starts empty" do
    %{name: name, pid: pid} = start_store!()

    assert LeaseStore.get(name) == nil
    assert Process.alive?(pid)
  end

  test "stores a lease with a local safety margin" do
    %{name: name, pid: pid} = start_store!()
    before = :erlang.monotonic_time(:millisecond)

    lease = LeaseStore.put(name, 7, :token, 30_000)

    assert lease.machine_id == 7
    assert lease.lease == :token
    assert_in_delta lease.expires_at_mono, before + 20_000, 10
    assert LeaseStore.get(name) == lease
    assert LeaseStore.valid?(lease)
    assert Process.alive?(pid)
  end

  test "renewing retains the machine ID and replaces the lease" do
    %{name: name, pid: pid} = start_store!()
    LeaseStore.put(name, 7, :old_token, 30_000)

    assert {:ok, renewed} = LeaseStore.renew(name, :new_token, 30_000)
    assert renewed.machine_id == 7
    assert renewed.lease == :new_token
    assert LeaseStore.get(name) == renewed
    assert Process.alive?(pid)
  end

  test "renewing without an active lease reports loss without crashing" do
    %{name: name, pid: pid} = start_store!()

    assert LeaseStore.renew(name, :token, 30_000) == :lost
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

    lease = LeaseStore.put(name, 7, :lease, 30_000)
    NoNoncense.init(machine_id: 7, name: instance)
    %{generation: generation} = :sys.get_state(name)

    assert LeaseStore.lose(name, :external) == :ok
    assert_receive {:lease_lost, ^lease, :external}
    assert LeaseStore.get(name) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end

    send(name, {:expired, generation})
    refute_receive {:lease_lost, _, _}, 20
  end

  test "discarding a stored lease disables factories without notifying the lease manager" do
    instance = unique_name("nonce")
    %{name: name} = start_store!(lease_manager: self(), instances: [[name: instance]])

    LeaseStore.put(name, 7, :lease, 30_000)
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

  test "expiry removes the stored lease and disables factories before notifying the lease manager" do
    instance = unique_name("nonce")
    %{name: name} = start_store!(lease_manager: self(), instances: [[name: instance]])

    lease = LeaseStore.put(name, 7, :lease, 30_000)
    NoNoncense.init(machine_id: 7, name: instance)
    %{generation: generation} = :sys.get_state(name)
    send(name, {:expired, generation})

    assert_receive {:lease_lost, ^lease, :expired}
    assert LeaseStore.get(name) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
  end

  test "an old timer cannot expire a renewed lease" do
    instance = unique_name("nonce")
    %{name: name} = start_store!(lease_manager: self(), instances: [[name: instance]])

    LeaseStore.put(name, 7, :lease1, 30_000)
    NoNoncense.init(machine_id: 7, name: instance)
    %{generation: old_generation} = :sys.get_state(name)
    {:ok, renewed_lease} = LeaseStore.renew(name, :lease2, 30_000)
    %{generation: new_generation} = :sys.get_state(name)

    send(name, {:expired, old_generation})
    refute_receive {:lease_lost, _, :expired}, 20
    assert LeaseStore.get(name) == renewed_lease
    assert <<_::64>> = NoNoncense.nonce(instance, 64)

    send(name, {:expired, new_generation})
    assert_receive {:lease_lost, ^renewed_lease, :expired}
    assert LeaseStore.renew(name, :late_lease, 30_000) == :lost
  end

  test "stays alive when the lease manager is absent as an active lease expires" do
    instance = unique_name("nonce")
    missing_lease_manager = unique_name("lease_manager")

    %{name: name, pid: pid} =
      start_store!(lease_manager: missing_lease_manager, instances: [[name: instance]])

    lease = LeaseStore.put(name, 7, :lease, 30_000)
    NoNoncense.init(machine_id: 7, name: instance)
    %{generation: generation} = :sys.get_state(name)
    send(name, {:expired, generation})
    :sys.get_state(name)

    assert Process.alive?(pid)
    assert LeaseStore.get(name) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
    assert lease.machine_id == 7
  end

  test "retries loss notification until the lease manager registers" do
    lease_manager = unique_name("lease_manager")
    %{name: name} = start_store!(lease_manager: lease_manager)
    lease = LeaseStore.put(name, 7, :lease, 30_000)
    %{generation: generation} = :sys.get_state(name)

    send(name, {:expired, generation})
    assert Process.register(self(), lease_manager)

    assert_receive {:lease_lost, ^lease, :expired}
    refute_receive {:lease_lost, _, _}, 20
  end

  test "disables configured factories when no stored lease exists at startup" do
    instance = unique_name("nonce")
    NoNoncense.init(machine_id: 7, name: instance)

    start_store!(instances: [[name: instance]])

    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
  end
end
