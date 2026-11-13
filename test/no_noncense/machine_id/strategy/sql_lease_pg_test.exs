defmodule NoNoncense.MachineId.Strategy.SqlLeasePgTest do
  use TestNoNoncense.DataCase, repo: :pg
  use Mimic
  import ExUnit.CaptureLog
  @moduletag :integration

  alias NoNoncense.MachineId.Strategy.{Shared, SqlLease}
  alias SqlLease.NoNoncenseLease

  @opts [repo: PgRepo, time_offset: System.time_offset(:millisecond)]

  describe "acquire/2" do
    test "acquires the lowest available id" do
      assert {:ok, 0, {0, token}, 10_000} = SqlLease.acquire(10_000, @opts)
      assert is_binary(token)
    end

    test "skips a database-expired lease until the local clock passes its expiry" do
      from(l in NoNoncenseLease,
        where: l.id == 0,
        update: [set: [expires_at: datetime_add(fragment("CURRENT_TIMESTAMP(6)"), -30, "second")]]
      )
      |> PgRepo.update_all([])

      opts = Keyword.put(@opts, :time_offset, :erlang.time_offset(:millisecond) - 60_000)
      assert {:ok, 1, _, 30_000} = SqlLease.acquire(30_000, opts)
      assert {:ok, 0, _, 30_000} = SqlLease.acquire(30_000, @opts)
    end

    test "skips a locally expired lease until the database clock passes its expiry" do
      from(l in NoNoncenseLease,
        where: l.id == 0,
        update: [set: [expires_at: datetime_add(fragment("CURRENT_TIMESTAMP(6)"), 30, "second")]]
      )
      |> PgRepo.update_all([])

      opts = Keyword.put(@opts, :time_offset, :erlang.time_offset(:millisecond) + 60_000)
      assert {:ok, 1, _, 30_000} = SqlLease.acquire(30_000, opts)
    end

    for {direction, skew} <- [ahead: 60_000, behind: -60_000] do
      @tag clock_skew: skew
      test "uses the later clock for acquisition expiry when local time is #{direction}", %{
        clock_skew: skew
      } do
        opts = Keyword.put(@opts, :time_offset, :erlang.time_offset(:millisecond) + skew)
        before_clocks = clock_times(opts)
        assert {:ok, id, _, 30_000} = SqlLease.acquire(30_000, opts)
        after_clocks = clock_times(opts)

        assert_expiry_between(
          PgRepo.get(NoNoncenseLease, id).expires_at,
          before_clocks,
          after_clocks,
          30_000
        )
      end
    end

    test "skips ids that are still leased" do
      future = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

      from(l in NoNoncenseLease, where: l.id in [0, 1])
      |> PgRepo.update_all(set: [token: "x", expires_at: future])

      assert {:ok, 2, {2, _token}, 10_000} = SqlLease.acquire(10_000, @opts)
    end

    test "returns an error when every id is leased" do
      future = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)
      PgRepo.update_all(NoNoncenseLease, set: [token: "x", expires_at: future])

      assert {:error, :exhausted} = SqlLease.acquire(10_000, @opts)
    end

    test "sets token, a future expires_at and increments lock_version" do
      assert {:ok, id, {id, token}, 10_000} = SqlLease.acquire(10_000, @opts)

      lease = PgRepo.get(NoNoncenseLease, id)
      assert lease.token == token
      assert lease.lock_version == 1
      assert DateTime.compare(lease.expires_at, DateTime.utc_now()) == :gt
    end

    test "concurrent acquires receive distinct ids" do
      ids =
        1..20
        |> Task.async_stream(fn _ -> SqlLease.acquire(10_000, @opts) end, timeout: 10_000)
        |> Enum.map(fn {:ok, {:ok, id, _lease, _ttl}} -> id end)

      assert length(Enum.uniq(ids)) == 20
    end

    test "returns a conflict after every candidate is claimed concurrently" do
      parent = self()

      stub(PgRepo, :update_all, fn _query, _updates ->
        send(parent, :claim_attempt)
        {0, nil}
      end)

      assert {:error, :conflict} = SqlLease.acquire(10_000, @opts)

      for _ <- 1..512, do: assert_received(:claim_attempt)
      refute_received :claim_attempt
    end
  end

  describe "renew/3" do
    for {direction, skew} <- [ahead: 60_000, behind: -60_000] do
      @tag clock_skew: skew
      test "renews from the later clock and allows TTL shortening when local time is #{direction}",
           %{clock_skew: skew} do
        assert {:ok, id, lease, 120_000} = SqlLease.acquire(120_000, @opts)
        previous_expiry = PgRepo.get(NoNoncenseLease, id).expires_at
        opts = Keyword.put(@opts, :time_offset, :erlang.time_offset(:millisecond) + skew)
        before_clocks = clock_times(opts)

        assert {:ok, ^lease, 30_000} = SqlLease.renew(lease, 30_000, opts)
        after_clocks = clock_times(opts)
        renewed = PgRepo.get(NoNoncenseLease, id)

        assert_expiry_between(renewed.expires_at, before_clocks, after_clocks, 30_000)
        assert DateTime.compare(renewed.expires_at, previous_expiry) == :lt
        assert renewed.lock_version == 2
      end
    end

    test "extends expires_at and increments lock_version" do
      assert {:ok, id, lease, _ttl} = SqlLease.acquire(10_000, @opts)
      expires_before = PgRepo.get(NoNoncenseLease, id).expires_at

      assert {:ok, {^id, _token}, 20_000} = SqlLease.renew(lease, 20_000, @opts)

      updated = PgRepo.get(NoNoncenseLease, id)
      assert updated.lock_version == 2
      assert DateTime.compare(updated.expires_at, expires_before) == :gt
    end

    test "succeeds past the lease's own expires_at, as long as nobody else reclaimed it" do
      assert {:ok, id, lease, _ttl} = SqlLease.acquire(10_000, @opts)

      from(l in NoNoncenseLease, where: l.id == ^id)
      |> PgRepo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      assert {:ok, _lease, 10_000} = SqlLease.renew(lease, 10_000, @opts)
    end

    test "fails with :lost when the token doesn't match" do
      assert {:ok, id, {id, _token}, _ttl} = SqlLease.acquire(10_000, @opts)

      assert {:error, :lost, :not_owner} =
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
      |> PgRepo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      assert {:ok, ^id, current_lease, _ttl} = SqlLease.acquire(10_000, @opts)

      assert {:error, :lost, :not_owner} = SqlLease.renew(stale_lease, 10_000, @opts)
      assert {:ok, _renewed, _ttl} = SqlLease.renew(current_lease, 10_000, @opts)
    end
  end

  describe "release/2" do
    for {direction, skew} <- [ahead: 60_000, behind: -60_000] do
      @tag clock_skew: skew
      test "uses the later clock for release quarantine when local time is #{direction}", %{
        clock_skew: skew
      } do
        assert {:ok, id, lease, 120_000} = SqlLease.acquire(120_000, @opts)
        previous_expiry = PgRepo.get(NoNoncenseLease, id).expires_at
        opts = Keyword.put(@opts, :time_offset, :erlang.time_offset(:millisecond) + skew)
        before_clocks = clock_times(opts)

        assert :ok = SqlLease.release(lease, opts)
        after_clocks = clock_times(opts)
        released = PgRepo.get(NoNoncenseLease, id)

        assert_expiry_between(released.expires_at, before_clocks, after_clocks, 1_000)
        assert DateTime.compare(released.expires_at, previous_expiry) == :lt
        assert released.token == nil
        assert released.lock_version == 2
        assert {:error, :lost, :not_owner} = SqlLease.renew(lease, 30_000, opts)
        assert :ok = SqlLease.release(lease, opts)
        assert PgRepo.get(NoNoncenseLease, id) == released
      end
    end

    test "preserves both clock guards during a skewed-clock handoff" do
      offset = :erlang.time_offset(:millisecond)
      owner_opts = Keyword.put(@opts, :time_offset, offset + 60_000)
      assert {:ok, id, lease = {id, token}, 30_000} = SqlLease.acquire(30_000, owner_opts)
      assert :ok = SqlLease.release(lease, owner_opts)
      released = PgRepo.get(NoNoncenseLease, id)
      assert released.token == nil

      fast_opts = Keyword.put(@opts, :time_offset, offset + 120_000)
      assert DateTime.compare(Shared.now(fast_opts), released.expires_at) == :gt
      assert {:ok, 1, _, 30_000} = SqlLease.acquire(30_000, fast_opts)
      assert PgRepo.get(NoNoncenseLease, id) == released

      # Backdate the cutoff and successor clocks equally to simulate elapsed time without waiting.
      elapsed = 120_000
      cutoff = DateTime.add(released.expires_at, -elapsed, :millisecond)

      from(l in NoNoncenseLease, where: l.id == ^id)
      |> PgRepo.update_all(set: [expires_at: cutoff])

      slower_opts = Keyword.put(@opts, :time_offset, offset - elapsed)
      assert DateTime.compare(Shared.now(slower_opts), cutoff) == :lt
      assert {:ok, 2, _, 30_000} = SqlLease.acquire(30_000, slower_opts)
      assert PgRepo.get(NoNoncenseLease, id).expires_at == cutoff

      successor_opts = Keyword.put(@opts, :time_offset, offset + 120_000 - elapsed)

      assert {:ok, ^id, successor_lease = {^id, successor_token}, 30_000} =
               SqlLease.acquire(30_000, successor_opts)

      refute successor_token == token
      successor = PgRepo.get(NoNoncenseLease, id)
      assert :ok = SqlLease.release(lease, owner_opts)
      assert {:error, :lost, :not_owner} = SqlLease.renew(lease, 30_000, owner_opts)
      assert PgRepo.get(NoNoncenseLease, id) == successor

      assert {:ok, ^successor_lease, 30_000} =
               SqlLease.renew(successor_lease, 30_000, successor_opts)
    end

    test "quarantines the lease for one second according to both clocks and prevents renewal" do
      assert {:ok, id, lease, _ttl} = SqlLease.acquire(10_000, @opts)
      opts = Keyword.put(@opts, :time_offset, :erlang.time_offset(:millisecond))
      local_before = Shared.now(opts)

      db_before =
        PgRepo.one(
          from(l in NoNoncenseLease,
            where: l.id == ^id,
            select: type(fragment("CURRENT_TIMESTAMP(6)"), :utc_datetime_usec)
          )
        )

      assert :ok = SqlLease.release(lease, opts)

      {released, db_after} =
        PgRepo.one(
          from(l in NoNoncenseLease,
            where: l.id == ^id,
            select: {l, type(fragment("CURRENT_TIMESTAMP(6)"), :utc_datetime_usec)}
          )
        )

      local_after = Shared.now(opts)
      earliest_expiry = Enum.max([local_before, db_before], DateTime) |> DateTime.add(1, :second)
      latest_expiry = Enum.max([local_after, db_after], DateTime) |> DateTime.add(1, :second)

      assert released.token == nil
      assert released.lock_version == 2
      assert DateTime.compare(released.expires_at, earliest_expiry) != :lt
      assert DateTime.compare(released.expires_at, latest_expiry) != :gt
      assert {:error, :lost, :not_owner} = SqlLease.renew(lease, 10_000, @opts)
    end

    test "allows reuse after quarantine expires with a new token" do
      assert {:ok, id, lease = {id, token}, _ttl} = SqlLease.acquire(10_000, @opts)
      assert :ok = SqlLease.release(lease, @opts)

      from(l in NoNoncenseLease, where: l.id == ^id)
      |> PgRepo.update_all(set: [expires_at: ~U[1970-01-01 00:00:00.000000Z]])

      assert {:ok, ^id, current_lease = {^id, current_token}, _ttl} =
               SqlLease.acquire(10_000, @opts)

      refute current_token == token
      before = PgRepo.get(NoNoncenseLease, id)
      assert :ok = SqlLease.release(lease, @opts)
      assert PgRepo.get(NoNoncenseLease, id) == before
      assert {:ok, ^current_lease, 10_000} = SqlLease.renew(current_lease, 10_000, @opts)
    end

    test "does not disturb another node's lease acquired for the same id" do
      assert {:ok, id, stale_lease, _ttl} = SqlLease.acquire(10_000, @opts)

      from(l in NoNoncenseLease, where: l.id == ^id)
      |> PgRepo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      assert {:ok, ^id, current_lease, _ttl} = SqlLease.acquire(10_000, @opts)

      {_, _log} = with_log(fn -> assert :ok = SqlLease.release(stale_lease, @opts) end)
      assert {:ok, _renewed, _ttl} = SqlLease.renew(current_lease, 10_000, @opts)
    end
  end

  defp clock_times(opts) do
    db_now =
      PgRepo.one(
        from(l in NoNoncenseLease,
          limit: 1,
          select: type(fragment("CURRENT_TIMESTAMP(6)"), :utc_datetime_usec)
        )
      )

    [db_now, Shared.now(opts)]
  end

  defp assert_expiry_between(expiry, before_clocks, after_clocks, ttl) do
    earliest = Enum.max(before_clocks, DateTime) |> DateTime.add(ttl, :millisecond)
    latest = Enum.max(after_clocks, DateTime) |> DateTime.add(ttl, :millisecond)
    assert DateTime.compare(expiry, earliest) != :lt
    assert DateTime.compare(expiry, latest) != :gt
  end
end
