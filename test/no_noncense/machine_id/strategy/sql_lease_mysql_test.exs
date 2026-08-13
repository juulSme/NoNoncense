defmodule NoNoncense.MachineId.Strategy.SqlLeaseMysqlTest do
  use TestNoNoncense.DataCase, repo: :mysql
  use Mimic
  import ExUnit.CaptureLog

  alias NoNoncense.MachineId.Strategy.SqlLease
  alias SqlLease.NoNoncenseLease

  @opts [repo: MysqlRepo]

  describe "acquire/2" do
    test "acquires the lowest available id" do
      assert {:ok, 0, {0, token}, 10_000} = SqlLease.acquire(10_000, @opts)
      assert is_binary(token)
    end

    test "skips ids that are still leased" do
      future = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

      from(l in NoNoncenseLease, where: l.id in [0, 1])
      |> MysqlRepo.update_all(set: [token: "x", expires_at: future])

      assert {:ok, 2, {2, _token}, 10_000} = SqlLease.acquire(10_000, @opts)
    end

    test "returns an error when every id is leased" do
      future = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)
      MysqlRepo.update_all(NoNoncenseLease, set: [token: "x", expires_at: future])

      assert {:error, :exhausted} = SqlLease.acquire(10_000, @opts)
    end

    test "sets token, a future expires_at and increments lock_version" do
      assert {:ok, id, {id, token}, 10_000} = SqlLease.acquire(10_000, @opts)

      lease = MysqlRepo.get(NoNoncenseLease, id)
      assert lease.token == token
      assert lease.lock_version == 1
      assert DateTime.compare(lease.expires_at, DateTime.utc_now()) == :gt
    end
  end

  describe "renew/3" do
    test "extends expires_at and increments lock_version" do
      assert {:ok, id, lease, _ttl} = SqlLease.acquire(10_000, @opts)
      expires_before = MysqlRepo.get(NoNoncenseLease, id).expires_at

      assert {:ok, {^id, _token}, 20_000} = SqlLease.renew(lease, 20_000, @opts)

      updated = MysqlRepo.get(NoNoncenseLease, id)
      assert updated.lock_version == 2
      assert DateTime.compare(updated.expires_at, expires_before) == :gt
    end

    test "succeeds past the lease's own expires_at, as long as nobody else reclaimed it" do
      assert {:ok, id, lease, _ttl} = SqlLease.acquire(10_000, @opts)

      from(l in NoNoncenseLease, where: l.id == ^id)
      |> MysqlRepo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      assert {:ok, _lease, 10_000} = SqlLease.renew(lease, 10_000, @opts)
    end

    test "fails with :lost when the token doesn't match" do
      assert {:ok, id, {id, _token}, _ttl} = SqlLease.acquire(10_000, @opts)

      assert {:error, :lost, :expired} =
               SqlLease.renew({id, "wrong-token"}, 10_000, @opts)
    end

    test "tolerates retrying with the same (unrotated) token, e.g. after a lost ack" do
      assert {:ok, _id, lease, _ttl} = SqlLease.acquire(10_000, @opts)

      # the token doesn't change on renew, so replaying the same lease value must keep working -
      # this matters when a renewal commits but its response is lost (ambiguous failure)
      assert {:ok, ^lease, 10_000} = SqlLease.renew(lease, 10_000, @opts)
      assert {:ok, ^lease, 10_000} = SqlLease.renew(lease, 10_000, @opts)
    end

    test "fails with :lost, without disturbing the new holder, once another node reclaimed the id" do
      assert {:ok, id, stale_lease, _ttl} = SqlLease.acquire(10_000, @opts)

      from(l in NoNoncenseLease, where: l.id == ^id)
      |> MysqlRepo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      assert {:ok, ^id, current_lease, _ttl} = SqlLease.acquire(10_000, @opts)

      assert {:error, :lost, :expired} = SqlLease.renew(stale_lease, 10_000, @opts)
      assert {:ok, _renewed, _ttl} = SqlLease.renew(current_lease, 10_000, @opts)
    end

    test "returns {:error, :retry, _} instead of raising when the repo errors unexpectedly" do
      assert {:ok, _id, lease, _ttl} = SqlLease.acquire(10_000, @opts)

      stub(MysqlRepo, :update_all, fn _query, _opts ->
        raise DBConnection.ConnectionError, message: "connection closed"
      end)

      {result, _log} = with_log(fn -> SqlLease.renew(lease, 10_000, @opts) end)
      assert {:error, :retry, _reason} = result
    end
  end

  describe "release/2" do
    test "immediately expires the lease so it becomes available again" do
      assert {:ok, id, lease, _ttl} = SqlLease.acquire(10_000, @opts)
      assert :ok = SqlLease.release(lease, @opts)

      released = MysqlRepo.get(NoNoncenseLease, id)
      assert DateTime.compare(released.expires_at, DateTime.utc_now()) != :gt
      assert {:ok, ^id, _new_lease, _ttl} = SqlLease.acquire(10_000, @opts)
    end

    test "does not disturb another node's lease acquired for the same id" do
      assert {:ok, id, stale_lease, _ttl} = SqlLease.acquire(10_000, @opts)

      from(l in NoNoncenseLease, where: l.id == ^id)
      |> MysqlRepo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      assert {:ok, ^id, current_lease, _ttl} = SqlLease.acquire(10_000, @opts)

      {_, _log} = with_log(fn -> assert :ok = SqlLease.release(stale_lease, @opts) end)
      assert {:ok, _renewed, _ttl} = SqlLease.renew(current_lease, 10_000, @opts)
    end

    test "returns :ok even if the underlying update fails unexpectedly" do
      assert {:ok, _id, lease, _ttl} = SqlLease.acquire(10_000, @opts)

      stub(MysqlRepo, :update_all, fn _query, _opts ->
        raise DBConnection.ConnectionError, message: "connection closed"
      end)

      {_, _log} = with_log(fn -> assert :ok = SqlLease.release(lease, @opts) end)
    end
  end
end
