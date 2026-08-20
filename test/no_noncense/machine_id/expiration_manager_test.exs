defmodule NoNoncense.MachineId.ExpirationManagerTest do
  use ExUnit.Case, async: true

  alias NoNoncense.MachineId.{ExpirationManager, LeaseCache}

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp start_expiration_manager!(instance) do
    cache = unique_name("cache")
    manager = unique_name("expiration_manager")
    start_supervised!({LeaseCache, name: cache})

    start_supervised!(
      {ExpirationManager,
       name: manager, lease_cache: cache, lease_manager: self(), instances: [[name: instance]]}
    )

    %{cache: cache, manager: manager}
  end

  test "expiry clears the cache and disables factories before notifying the lease manager" do
    instance = unique_name("nonce")
    NoNoncense.init(machine_id: 7, name: instance)
    %{cache: cache, manager: manager} = start_expiration_manager!(instance)

    {:ok, lease} = ExpirationManager.acquire(manager, 7, :lease, 30_000)
    %{generation: generation} = :sys.get_state(manager)
    send(manager, {:expired, generation})

    assert_receive {:lease_lost, ^lease, :expired}
    assert LeaseCache.get(cache) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
  end

  test "an old timer cannot expire a renewed lease" do
    instance = unique_name("nonce")
    NoNoncense.init(machine_id: 7, name: instance)
    %{cache: cache, manager: manager} = start_expiration_manager!(instance)

    {:ok, _} = ExpirationManager.acquire(manager, 7, :lease1, 30_000)
    %{generation: old_generation} = :sys.get_state(manager)
    {:ok, renewed_lease} = ExpirationManager.renew(manager, :lease2, 30_000)
    %{generation: new_generation} = :sys.get_state(manager)

    send(manager, {:expired, old_generation})
    refute_receive {:lease_lost, _, :expired}, 20
    assert LeaseCache.get(cache) == renewed_lease
    assert <<_::64>> = NoNoncense.nonce(instance, 64)

    send(manager, {:expired, new_generation})
    assert_receive {:lease_lost, ^renewed_lease, :expired}
    assert :lost = ExpirationManager.renew(manager, :late_lease, 30_000)
  end

  test "silently clears an expired cached lease when its lease manager is not running" do
    instance = unique_name("nonce")
    cache = unique_name("cache")
    manager = unique_name("expiration_manager")
    missing_lease_manager = unique_name("lease_manager")
    NoNoncense.init(machine_id: 7, name: instance)
    start_supervised!({LeaseCache, name: cache})
    LeaseCache.put(cache, 7, :expired_lease, 10_000)

    start_supervised!(
      {ExpirationManager,
       name: manager,
       lease_cache: cache,
       lease_manager: missing_lease_manager,
       instances: [[name: instance]]}
    )

    assert LeaseCache.get(cache) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
  end

  test "stays alive when the lease manager is absent as an active lease expires" do
    instance = unique_name("nonce")
    NoNoncense.init(machine_id: 7, name: instance)
    %{cache: cache, manager: manager} = start_expiration_manager!(instance)

    missing_lease_manager = unique_name("lease_manager")
    :sys.replace_state(manager, &Map.put(&1, :lease_manager, missing_lease_manager))

    {:ok, lease} = ExpirationManager.acquire(manager, 7, :lease, 30_000)
    %{generation: generation} = :sys.get_state(manager)
    send(manager, {:expired, generation})
    :sys.get_state(manager)

    assert Process.alive?(Process.whereis(manager))
    assert LeaseCache.get(cache) == nil
    assert_raise NoNoncense.Errors.DisabledError, fn -> NoNoncense.nonce(instance, 64) end
    assert lease.machine_id == 7
  end
end
