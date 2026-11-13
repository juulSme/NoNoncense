defmodule NoNoncense.MachineId.Strategy.RedisLeaseTest do
  use ExUnit.Case, async: true
  use Mimic
  @moduletag :integration

  alias NoNoncense.MachineId.Strategy.{RedisLease, Shared}

  setup_all do
    {:ok, conn} = start_supervised({Redix, database: 15})
    {:ok, "OK"} = Redix.command(conn, ["FLUSHDB"])
    [conn: conn]
  end

  setup %{conn: conn} do
    key = Ecto.UUID.generate()

    %{
      conn: conn,
      opts: [with_connection: conn, key: key, time_offset: System.time_offset(:millisecond)],
      key: key
    }
  end

  describe "acquire/2" do
    test "acquires ID 0 and stores its lease value", fixtures do
      assert {:ok, 0, {0, token}, 10_000} = RedisLease.acquire(10_000, fixtures.opts)
      assert is_binary(token)

      assert {:ok, fields} = Redix.command(fixtures.conn, ["HGETALL", fixtures.key])
      marker = "token.0.#{token}"

      assert %{"0" => "", ^marker => "", "exp.0" => expires_at} =
               fields |> Enum.chunk_every(2) |> Map.new(fn [key, value] -> {key, value} end)

      assert String.to_integer(expires_at) > System.system_time(:millisecond)

      assert {:ok, [ttl]} =
               Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "0"])

      assert ttl > 0
    end

    test "works with pool-friendly with_connection", fixtures do
      with_connection = fn fun -> fun.(fixtures.conn) end
      opts = fixtures.opts |> Keyword.put(:with_connection, with_connection)
      assert {:ok, 0, _, _} = RedisLease.acquire(10_000, opts)
    end

    test "skips a Redis-expired lease until the local clock passes its expiry", fixtures do
      expiry = Shared.now_unix(fixtures.opts) - 30_000
      assert {:ok, 1} = Redix.command(fixtures.conn, ["HSET", fixtures.key, "exp.0", expiry])
      opts = Keyword.put(fixtures.opts, :time_offset, :erlang.time_offset(:millisecond) - 60_000)

      assert {:ok, 1, _, 30_000} = RedisLease.acquire(30_000, opts)
      assert {:ok, 0, _, 30_000} = RedisLease.acquire(30_000, fixtures.opts)
    end

    test "skips a locally expired lease while its Redis fields are still live", fixtures do
      assert {:ok, 0, _, 30_000} = RedisLease.acquire(30_000, fixtures.opts)
      opts = Keyword.put(fixtures.opts, :time_offset, :erlang.time_offset(:millisecond) + 60_000)
      assert {:ok, 1, _, 30_000} = RedisLease.acquire(30_000, opts)
    end

    for {direction, skew} <- [ahead: 60_000, behind: -60_000] do
      @tag clock_skew: skew
      test "stores the local clock expiry when local time is #{direction}", fixtures do
        opts =
          Keyword.put(
            fixtures.opts,
            :time_offset,
            :erlang.time_offset(:millisecond) + fixtures.clock_skew
          )

        before = Shared.now_unix(opts)
        assert {:ok, _, lease, 30_000} = RedisLease.acquire(30_000, opts)
        after_ = Shared.now_unix(opts)
        expiry = lease_expiry(fixtures.conn, fixtures.key, lease)

        assert expiry >= before + 30_000
        assert expiry <= after_ + 30_000
      end
    end

    test "acquires the first unleased ID", fixtures do
      assert {:ok, 2} =
               Redix.command(fixtures.conn, [
                 "HSET",
                 fixtures.key,
                 "2",
                 "existing-2",
                 "0",
                 "existing-0"
               ])

      assert {:ok, 1, {1, token}, 10_000} = RedisLease.acquire(10_000, fixtures.opts)
      assert {:ok, "existing-0"} = Redix.command(fixtures.conn, ["HGET", fixtures.key, "0"])
      assert {:ok, ""} = Redix.command(fixtures.conn, ["HGET", fixtures.key, "1"])
      assert {:ok, "token.1." <> token} == marker_field(fixtures.conn, fixtures.key, 1)
      assert {:ok, "existing-2"} = Redix.command(fixtures.conn, ["HGET", fixtures.key, "2"])
    end

    test "acquires the first unleased ID when leased IDs span multiple digit lengths", fixtures do
      # IDs "0".."10" sort as "0","1","10","2",...,"9" as strings, unlike numerically
      fields = for id <- 0..10, do: [Integer.to_string(id), "existing-#{id}"]

      assert {:ok, 11} =
               Redix.command(fixtures.conn, ["HSET", fixtures.key | List.flatten(fields)])

      assert {:ok, 11, _lease, 10_000} = RedisLease.acquire(10_000, fixtures.opts)
    end

    test "returns an error when every ID is leased", fixtures do
      fields = for id <- 0..511, do: [Integer.to_string(id), "existing"]

      assert {:ok, 512} =
               Redix.command(fixtures.conn, ["HSET", fixtures.key | List.flatten(fields)])

      assert {:error, :exhausted} = RedisLease.acquire(10_000, fixtures.opts)
    end

    test "marker fields don't get mistaken for occupied IDs", fixtures do
      assert {:ok, 0, _lease, 10_000} = RedisLease.acquire(10_000, fixtures.opts)
      # if the marker ("token.0") were counted as a lease, this would skip past 1
      assert {:ok, 1, _lease, 10_000} = RedisLease.acquire(10_000, fixtures.opts)
    end

    test "ignores unexpected lease fields", fixtures do
      assert {:ok, 1} = Redix.command(fixtures.conn, ["HSET", fixtures.key, "not-an-id", "value"])
      assert {:ok, 0, _, _} = RedisLease.acquire(10_000, fixtures.opts)
    end

    test "only reuses a free ID after its local expiry", fixtures do
      future = System.system_time(:millisecond) + 60_000
      assert {:ok, 1} = Redix.command(fixtures.conn, ["HSET", fixtures.key, "exp.0", future])
      assert {:ok, 1, _, _} = RedisLease.acquire(10_000, fixtures.opts)

      assert {:ok, 0} = Redix.command(fixtures.conn, ["HSET", fixtures.key, "exp.0", "0"])
      assert {:ok, 0, _, _} = RedisLease.acquire(10_000, fixtures.opts)
    end

    test "tries the next free ID after a conditional conflict" do
      parent = self()

      stub(Redix, :command, fn :conn, command ->
        send(parent, {:redis_command, command})

        case command do
          ["HGETALL", "test-key"] ->
            {:ok, []}

          ["HSETEX", "test-key", "FNX", "PX", _ttl, "FIELDS", "2", id | _] ->
            {:ok, if(id == "0", do: 0, else: 1)}

          ["HSET", "test-key", "exp.1", _] ->
            {:ok, 1}
        end
      end)

      assert {:ok, 1, {1, _token}, 10_000} = RedisLease.acquire(10_000, mock_opts())

      assert_received {:redis_command,
                       ["HSETEX", "test-key", "FNX", "PX", "10000", _, "2", "0" | _]}

      assert_received {:redis_command,
                       ["HSETEX", "test-key", "FNX", "PX", "10000", _, "2", "1" | _]}
    end

    test "returns a conflict after every free ID is claimed concurrently" do
      parent = self()

      stub(Redix, :command, fn :conn, command ->
        send(parent, {:redis_command, command})

        case command do
          ["HGETALL", "test-key"] -> {:ok, []}
          ["HSETEX" | _] -> {:ok, 0}
        end
      end)

      assert {:error, :conflict} = RedisLease.acquire(10_000, mock_opts())

      for id <- 0..511 do
        id = Integer.to_string(id)

        assert_received {:redis_command,
                         ["HSETEX", "test-key", "FNX", "PX", "10000", _, "2", ^id | _]}
      end

      refute_received {:redis_command, ["HSETEX" | _]}
    end
  end

  describe "renew/3" do
    for {direction, skew} <- [ahead: 60_000, behind: -60_000] do
      @tag clock_skew: skew
      test "renews from the local clock and allows expiry shortening when local time is #{direction}",
           fixtures do
        assert {:ok, _, lease, 120_000} = RedisLease.acquire(120_000, fixtures.opts)
        previous_expiry = lease_expiry(fixtures.conn, fixtures.key, lease)

        opts =
          Keyword.put(
            fixtures.opts,
            :time_offset,
            :erlang.time_offset(:millisecond) + fixtures.clock_skew
          )

        before = Shared.now_unix(opts)
        assert {:ok, ^lease, 30_000} = RedisLease.renew(lease, 30_000, opts)
        after_ = Shared.now_unix(opts)
        expiry = lease_expiry(fixtures.conn, fixtures.key, lease)

        assert expiry >= before + 30_000
        assert expiry <= after_ + 30_000
        assert expiry < previous_expiry
      end
    end

    test "extends the TTL of both fields while the lease is still held", fixtures do
      assert {:ok, 0, lease, 10_000} = RedisLease.acquire(10_000, fixtures.opts)

      assert {:ok, [ttl_before]} =
               Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "0"])

      assert {:ok, ^lease, 20_000} = RedisLease.renew(lease, 20_000, fixtures.opts)

      assert {:ok, [ttl_after]} =
               Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "0"])

      assert ttl_after > ttl_before
    end

    test "fails when the lease already expired", fixtures do
      assert {:ok, 0, lease, _} = RedisLease.acquire(10_000, fixtures.opts)
      assert {:ok, marker} = marker_field(fixtures.conn, fixtures.key, 0)
      Redix.command(fixtures.conn, ["HDEL", fixtures.key, "0", marker])

      assert {:error, :lost, :not_owner} =
               RedisLease.renew(lease, 10_000, fixtures.opts)
    end

    test "fails without disturbing another node's lease for the same ID", fixtures do
      assert {:ok, 0, stale_lease, _} = RedisLease.acquire(10_000, fixtures.opts)
      expire_lease(fixtures.conn, fixtures.key, stale_lease)
      assert {:ok, 0, current_lease, _} = RedisLease.acquire(10_000, fixtures.opts)

      assert {:error, :lost, :not_owner} =
               RedisLease.renew(stale_lease, 10_000, fixtures.opts)

      assert {:ok, ^current_lease, 10_000} =
               RedisLease.renew(current_lease, 10_000, fixtures.opts)
    end
  end

  describe "release/2" do
    for {direction, skew} <- [ahead: 60_000, behind: -60_000] do
      @tag clock_skew: skew
      test "stores the local clock quarantine cutoff when local time is #{direction}",
           fixtures do
        assert {:ok, _, lease, 120_000} = RedisLease.acquire(120_000, fixtures.opts)
        previous_expiry = lease_expiry(fixtures.conn, fixtures.key, lease)

        opts =
          Keyword.put(
            fixtures.opts,
            :time_offset,
            :erlang.time_offset(:millisecond) + fixtures.clock_skew
          )

        before = Shared.now_unix(opts)
        assert :ok = RedisLease.release(lease, opts)
        after_ = Shared.now_unix(opts)
        expiry = lease_expiry(fixtures.conn, fixtures.key, lease)

        assert expiry >= before + 1_000
        assert expiry <= after_ + 1_000
        assert expiry < previous_expiry
      end
    end

    test "preserves the release cutoff after Redis expiry and rejects slower successors",
         fixtures do
      offset = :erlang.time_offset(:millisecond)
      owner_opts = Keyword.put(fixtures.opts, :time_offset, offset + 60_000)
      assert {:ok, 0, lease = {0, token}, 30_000} = RedisLease.acquire(30_000, owner_opts)
      assert :ok = RedisLease.release(lease, owner_opts)
      cutoff = lease_expiry(fixtures.conn, fixtures.key, lease)

      assert {:ok, [2, 2]} =
               Redix.command(fixtures.conn, [
                 "HPEXPIREAT",
                 fixtures.key,
                 "1",
                 "FIELDS",
                 "2",
                 "0",
                 "token.0.#{token}"
               ])

      assert lease_expiry(fixtures.conn, fixtures.key, lease) == cutoff
      slower_opts = Keyword.put(fixtures.opts, :time_offset, offset)
      assert {:ok, 1, _, 30_000} = RedisLease.acquire(30_000, slower_opts)

      successor_opts = Keyword.put(fixtures.opts, :time_offset, offset + 120_000)

      assert {:ok, 0, successor_lease = {0, successor_token}, 30_000} =
               RedisLease.acquire(30_000, successor_opts)

      refute successor_token == token
      successor_expiry = lease_expiry(fixtures.conn, fixtures.key, successor_lease)
      assert :ok = RedisLease.release(lease, owner_opts)
      assert lease_expiry(fixtures.conn, fixtures.key, successor_lease) == successor_expiry

      assert {:ok, ^successor_lease, 30_000} =
               RedisLease.renew(successor_lease, 30_000, successor_opts)
    end

    test "quarantines both fields for one second and skips the released ID", fixtures do
      assert {:ok, 0, lease = {0, token}, _} = RedisLease.acquire(10_000, fixtures.opts)
      assert :ok = RedisLease.release(lease, fixtures.opts)

      assert {:ok, [id_ttl, marker_ttl]} =
               Redix.command(fixtures.conn, [
                 "HPTTL",
                 fixtures.key,
                 "FIELDS",
                 "2",
                 "0",
                 "token.0.#{token}"
               ])

      assert id_ttl > 0 and id_ttl <= 1_000
      assert marker_ttl == id_ttl
      assert {:ok, 1, _lease, _ttl} = RedisLease.acquire(10_000, fixtures.opts)
    end

    test "allows reuse after quarantine expires with a new token", fixtures do
      assert {:ok, 0, lease = {0, token}, _} = RedisLease.acquire(10_000, fixtures.opts)
      assert :ok = RedisLease.release(lease, fixtures.opts)

      expire_lease(fixtures.conn, fixtures.key, lease)

      assert {:ok, 0, current_lease = {0, current_token}, _} =
               RedisLease.acquire(10_000, fixtures.opts)

      refute current_token == token
      assert :ok = RedisLease.release(lease, fixtures.opts)

      assert {:ok, ^current_lease, 10_000} =
               RedisLease.renew(current_lease, 10_000, fixtures.opts)
    end

    test "does not shorten another node's lease for the same ID", fixtures do
      assert {:ok, 0, stale_lease, _} = RedisLease.acquire(10_000, fixtures.opts)
      expire_lease(fixtures.conn, fixtures.key, stale_lease)
      assert {:ok, 0, {0, current_token}, _} = RedisLease.acquire(10_000, fixtures.opts)

      assert {:ok, before} = Redix.command(fixtures.conn, ["HGETALL", fixtures.key])
      assert :ok = RedisLease.release(stale_lease, fixtures.opts)
      assert {:ok, ^before} = Redix.command(fixtures.conn, ["HGETALL", fixtures.key])

      assert {:ok, ""} =
               Redix.command(fixtures.conn, ["HGET", fixtures.key, "token.0.#{current_token}"])

      assert {:ok, [ttl]} =
               Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "0"])

      assert ttl > 1_000
    end
  end

  describe "command failures" do
    test "acquire propagates an exp write error" do
      error = %Redix.Error{message: "ERR denied"}

      stub(Redix, :command, fn :conn, command ->
        case command do
          ["HGETALL", "test-key"] -> {:ok, []}
          ["HSETEX" | _] -> {:ok, 1}
          ["HSET" | _] -> {:error, error}
        end
      end)

      assert {:error, ^error} = RedisLease.acquire(10_000, mock_opts())
    end

    test "renew reports a conditional-write command error as retryable" do
      error = %Redix.Error{message: "ERR denied"}
      expect(Redix, :command, fn :conn, ["HSETEX" | _] -> {:error, error} end)

      assert {:error, :retry, ^error} = RedisLease.renew({0, "token"}, 10_000, mock_opts())
    end

    test "renew propagates an exp write connection error" do
      stub(Redix, :command, fn :conn, command ->
        case command do
          ["HSETEX" | _] -> {:ok, 1}
          ["HSET" | _] -> {:error, :closed}
        end
      end)

      assert {:error, :retry, :closed} = RedisLease.renew({0, "token"}, 10_000, mock_opts())
    end

    test "release ignores an exp write failure" do
      stub(Redix, :command, fn :conn, command ->
        case command do
          ["HSETEX" | _] -> {:ok, 1}
          ["HSET" | _] -> {:error, :closed}
        end
      end)

      assert :ok = RedisLease.release({0, "token"}, mock_opts())
    end
  end

  defp mock_opts do
    [with_connection: :conn, time_offset: System.time_offset(:millisecond), key: "test-key"]
  end

  defp lease_expiry(conn, key, {id, _token}) do
    assert {:ok, expiry} = Redix.command(conn, ["HGET", key, "exp.#{id}"])
    String.to_integer(expiry)
  end

  defp expire_lease(conn, key, {id, token}) do
    assert {:ok, [2, 2]} =
             Redix.command(conn, [
               "HPEXPIREAT",
               key,
               "1",
               "FIELDS",
               "2",
               to_string(id),
               "token.#{id}.#{token}"
             ])

    assert {:ok, 0} = Redix.command(conn, ["HSET", key, "exp.#{id}", "0"])
  end

  defp marker_field(conn, key, id) do
    with {:ok, fields} <- Redix.command(conn, ["HGETALL", key]) do
      id = to_string(id)
      marker = fields |> Enum.find(&match?(<<"token.", ^id::binary, ?., _::binary>>, &1))
      {:ok, marker}
    end
  end
end
