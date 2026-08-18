defmodule NoNoncense.MachineId.Strategy.RedisLeaseTest do
  use ExUnit.Case, async: true
  use Mimic

  alias NoNoncense.MachineId.Strategy.RedisLease

  setup_all do
    {:ok, conn} = start_supervised({Redix, database: 15})
    {:ok, "OK"} = Redix.command(conn, ["FLUSHDB"])
    [conn: conn]
  end

  setup %{conn: conn} do
    key = Ecto.UUID.generate()
    %{conn: conn, opts: [with_connection: conn, key: key], key: key}
  end

  describe "acquire/2" do
    test "acquires ID 0 and stores its lease value", fixtures do
      assert {:ok, 0, {0, token}, 10_000} = RedisLease.acquire(10_000, fixtures.opts)
      assert is_binary(token)

      assert {:ok, ["0", ^token, "token.0." <> ^token, "0"]} =
               Redix.command(fixtures.conn, ["HGETALL", fixtures.key])

      assert {:ok, [ttl]} =
               Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "0"])

      assert ttl > 0
    end

    test "works with pool-friendly with_connection", fixtures do
      with_connection = fn fun -> fun.(fixtures.conn) end
      opts = fixtures.opts |> Keyword.put(:with_connection, with_connection)
      assert {:ok, 0, _, _} = RedisLease.acquire(10_000, opts)
    end

    test "returns an error when the connection wrapper exits", fixtures do
      with_connection = fn _fun -> exit(:pool_timeout) end
      opts = Keyword.put(fixtures.opts, :with_connection, with_connection)

      assert {:error, {:exit, :pool_timeout}} = RedisLease.acquire(10_000, opts)
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
      assert {:ok, ^token} = Redix.command(fixtures.conn, ["HGET", fixtures.key, "1"])
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

    test "retries a conditional conflict using a refreshed lease view" do
      parent = self()
      marker = "token.0." <> String.duplicate("a", 22)
      responses = Agent.start_link(fn -> [[], ["0", marker]] end)
      {:ok, response_agent} = responses
      attempts = Agent.start_link(fn -> 0 end)
      {:ok, attempt_agent} = attempts

      stub(Redix, :command, fn :conn, command ->
        send(parent, {:redis_command, command})

        case command do
          ["HKEYS", "test-key"] ->
            Agent.get_and_update(response_agent, fn [response | remaining] ->
              {response, remaining}
            end)
            |> then(&{:ok, &1})

          ["HSETEX", "test-key", "FNX", "PX", _ttl, "FIELDS", "2", id, _token, _marker, id] ->
            Agent.get_and_update(attempt_agent, fn attempt ->
              result = if attempt == 0, do: {:ok, 0}, else: {:ok, 1}
              {result, attempt + 1}
            end)
        end
      end)

      assert {:ok, 1, {1, _token}, 10_000} =
               RedisLease.acquire(10_000, with_connection: :conn, key: "test-key")

      assert_receive {:redis_command,
                      ["HSETEX", "test-key", "FNX", "PX", "10000", "FIELDS", "2", "0" | _]}

      assert_receive {:redis_command,
                      ["HSETEX", "test-key", "FNX", "PX", "10000", "FIELDS", "2", "1" | _]}
    end

    test "stops after three conditional conflicts" do
      parent = self()

      stub(Redix, :command, fn :conn, command ->
        send(parent, {:redis_command, command})

        case command do
          ["HKEYS", "test-key"] ->
            {:ok, []}

          ["HSETEX", "test-key", "FNX", "PX", _ttl, "FIELDS", "2", "0", _token, _marker, "0"] ->
            {:ok, 0}
        end
      end)

      assert {:error, :conflict} =
               RedisLease.acquire(10_000, with_connection: :conn, key: "test-key")

      assert_received {:redis_command, ["HSETEX" | _]}
      assert_received {:redis_command, ["HSETEX" | _]}
      assert_received {:redis_command, ["HSETEX" | _]}
      refute_received {:redis_command, ["HSETEX" | _]}
    end
  end

  describe "renew/3" do
    test "extends the TTL of both fields while the lease is still held", fixtures do
      assert {:ok, 0, lease, 10_000} = RedisLease.acquire(10_000, fixtures.opts)

      assert {:ok, [ttl_before]} =
               Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "0"])

      Process.sleep(50)
      assert {:ok, ^lease, 20_000} = RedisLease.renew(lease, 20_000, fixtures.opts)

      assert {:ok, [ttl_after]} =
               Redix.command(fixtures.conn, ["HPTTL", fixtures.key, "FIELDS", "1", "0"])

      assert ttl_after > ttl_before
    end

    test "fails when the lease already expired", fixtures do
      assert {:ok, 0, lease, _} = RedisLease.acquire(10_000, fixtures.opts)
      assert {:ok, marker} = marker_field(fixtures.conn, fixtures.key, 0)
      Redix.command(fixtures.conn, ["HDEL", fixtures.key, "0", marker])

      assert {:error, :lost, :expired} =
               RedisLease.renew(lease, 10_000, fixtures.opts)
    end

    test "fails without disturbing another node's lease for the same ID", fixtures do
      assert {:ok, 0, stale_lease, _} = RedisLease.acquire(10_000, fixtures.opts)
      assert {:ok, marker} = marker_field(fixtures.conn, fixtures.key, 0)
      Redix.command(fixtures.conn, ["HDEL", fixtures.key, "0", marker])
      assert {:ok, 0, current_lease, _} = RedisLease.acquire(10_000, fixtures.opts)

      assert {:error, :lost, :expired} =
               RedisLease.renew(stale_lease, 10_000, fixtures.opts)

      assert {:ok, ^current_lease, 10_000} =
               RedisLease.renew(current_lease, 10_000, fixtures.opts)
    end

    test "reports a connection wrapper exit as retryable", fixtures do
      with_connection = fn _fun -> exit(:pool_timeout) end
      opts = Keyword.put(fixtures.opts, :with_connection, with_connection)

      assert {:error, :retry, {:exit, :pool_timeout}} =
               RedisLease.renew({0, "token"}, 10_000, opts)
    end
  end

  describe "release/2" do
    test "deletes both fields when the lease is still held", fixtures do
      assert {:ok, 0, lease, _} = RedisLease.acquire(10_000, fixtures.opts)
      assert :ok = RedisLease.release(lease, fixtures.opts)
      assert {:ok, []} = Redix.command(fixtures.conn, ["HGETALL", fixtures.key])
    end

    test "does not delete another node's lease for the same ID", fixtures do
      assert {:ok, 0, stale_lease, _} = RedisLease.acquire(10_000, fixtures.opts)
      assert {:ok, marker} = marker_field(fixtures.conn, fixtures.key, 0)
      Redix.command(fixtures.conn, ["HDEL", fixtures.key, "0", marker])
      assert {:ok, 0, {0, current_token}, _} = RedisLease.acquire(10_000, fixtures.opts)

      assert :ok = RedisLease.release(stale_lease, fixtures.opts)

      assert {:ok, ^current_token} =
               Redix.command(fixtures.conn, ["HGET", fixtures.key, "0"])
    end

    test "remains best-effort when the connection wrapper exits", fixtures do
      with_connection = fn _fun -> exit(:pool_timeout) end
      opts = Keyword.put(fixtures.opts, :with_connection, with_connection)

      assert :ok = RedisLease.release({0, "token"}, opts)
    end
  end

  defp marker_field(conn, key, id) do
    with {:ok, fields} <- Redix.command(conn, ["HGETALL", key]) do
      id = to_string(id)
      marker = fields |> Enum.find(&match?(<<"token.", ^id::binary, ?., _::binary>>, &1))
      {:ok, marker}
    end
  end
end
