defmodule NoNoncenseTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  @name :test_nonce_factory
  @epoch System.system_time(:millisecond)

  defp nonce_info(nonce, name) do
    {_, init_at, time_offset, _} = :persistent_term.get(name)

    size = bit_size(nonce)
    count_size = size - 42 - 9
    cycle_size = Integer.pow(2, min(64, count_size))

    <<timestamp::42, machine_id::9, count::size(count_size)>> = nonce

    cycle = timestamp - init_at
    total_count = cycle * cycle_size + count
    epoch = System.time_offset(:millisecond) - time_offset
    timestamp = timestamp + epoch
    datetime = DateTime.from_unix!(timestamp, :millisecond)

    %{
      timestamp: timestamp,
      machine_id: machine_id,
      count: count,
      datetime: datetime,
      cycle: cycle,
      total_count: total_count,
      cycle_size: cycle_size
    }
  end

  defp concurrent_gen(tasks, nonces_per_task, fun) do
    1..tasks
    |> Enum.map(fn _ ->
      Task.async(fn ->
        for _ <- 1..nonces_per_task, into: MapSet.new(), do: fun.()
      end)
    end)
    |> Task.await_many(20000)
    |> Enum.reduce(&MapSet.union/2)
  end

  describe "init/0" do
    test "initializes the nonce factory with default options" do
      assert NoNoncense.init(machine_id: 0, name: @name) == :ok
    end

    test "initializes the nonce factory with custom options" do
      assert NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch) == :ok
    end

    test "warns on imminent timestamp overflow" do
      long_ago =
        System.system_time(:millisecond) - Integer.pow(2, 42) + 1 * 24 * 60 * 60 * 1000 + 60_000

      {_, msg} =
        with_log(fn ->
          NoNoncense.init(machine_id: 0, name: @name, epoch: long_ago)
        end)

      assert msg =~ "[warning] timestamp overflow in 1 days"
    end

    test "raises on timestamp overflow" do
      long_ago = System.system_time(:millisecond) - Integer.pow(2, 42) - 1000

      assert_raise RuntimeError, "timestamp overflow", fn ->
        NoNoncense.init(machine_id: 0, name: @name, epoch: long_ago)
      end
    end

    test "raises on machine ID out of range" do
      assert_raise ArgumentError, "machine ID out of range 0-511", fn ->
        NoNoncense.init(machine_id: 512)
      end

      assert_raise ArgumentError, "machine ID out of range 0-511", fn ->
        NoNoncense.init(machine_id: -1)
      end
    end
  end

  describe "nonce(64)" do
    setup do
      NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch)
    end

    test "generates a new nonce" do
      nonce = NoNoncense.nonce(@name, 64)
      assert bit_size(nonce) == 64
      assert nonce != NoNoncense.nonce(@name, 64)
    end

    test "raises an error if the nonce factory has not been initialized" do
      assert_raise ArgumentError, fn -> NoNoncense.nonce(:not_initialized, 64) end
    end

    test "count wraps and timestamp increases on cycle limit wrap" do
      %{cycle_size: cycle_size} = NoNoncense.nonce(@name, 64) |> nonce_info(@name)
      state = :persistent_term.get(@name)
      {_, _, _, counter_ref} = state
      :atomics.put(counter_ref, 1, cycle_size - 2)

      nonce1 = NoNoncense.nonce(@name, 64)
      nonce1_info = nonce_info(nonce1, @name)

      nonce2 = NoNoncense.nonce(@name, 64)
      nonce2_info = nonce_info(nonce2, @name)

      assert nonce1_info.count == cycle_size - 1
      assert nonce2_info.count == 0

      assert nonce1_info.cycle == 0
      assert nonce2_info.cycle == 1

      assert nonce2_info.timestamp == nonce1_info.timestamp + 1
    end

    test "nonce's can't predate their timestamp" do
      %{cycle_size: cycle_size} = NoNoncense.nonce(@name, 64) |> nonce_info(@name)
      state = :persistent_term.get(@name)
      {_machine_id, init_at, time_offset, counter_ref} = state

      # jump to cycle #99, which should not generate nonces until 99ms have passed
      cycle_count = 99
      :atomics.put(counter_ref, 1, cycle_size * cycle_count - 5)
      not_before = init_at + cycle_count

      1..10
      |> Enum.map(fn _ ->
        Task.async(fn ->
          pre = System.monotonic_time(:millisecond) + time_offset

          assert abs(not_before - pre) < 110

          assert pre < not_before,
                 "it should be earlier than when the first nonces of this cycle may be created"

          nonce = NoNoncense.nonce(@name, 64)
          post = System.monotonic_time(:millisecond) + time_offset
          info = nonce_info(nonce, @name)

          %{post: post, info: info}
        end)
      end)
      |> Task.await_many()
      |> Enum.sort_by(& &1.info.total_count)
      |> Enum.each(fn %{post: post, info: info} ->
        nonce_n = info.total_count - cycle_count * cycle_size

        if info.cycle == cycle_count do
          assert post >= not_before,
                 "nonce #{nonce_n} was generated at #{post} before it should have been at #{not_before}"
        end
      end)
    end

    test "creates unique nonces with concurrent requests" do
      tasks = 10
      nonces_per_task = 100_000

      concurrent_gen(tasks, nonces_per_task, fn -> NoNoncense.nonce(@name, 64) end)
      |> Enum.count()
      |> then(fn count -> assert count == tasks * nonces_per_task end)
    end
  end

  describe "nonce(96)" do
    setup do
      NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch)
    end

    test "generates a new nonce" do
      nonce = NoNoncense.nonce(@name, 96)
      assert bit_size(nonce) == 96
      assert nonce != NoNoncense.nonce(@name, 96)
    end

    test "count wraps and timestamp increases on cycle limit wrap" do
      %{cycle_size: cycle_size} = NoNoncense.nonce(@name, 96) |> nonce_info(@name)
      state = :persistent_term.get(@name)
      {_, _, _, counter_ref} = state
      :atomics.put(counter_ref, 1, cycle_size - 2)

      nonce1 = NoNoncense.nonce(@name, 96)
      nonce1_info = nonce_info(nonce1, @name)

      nonce2 = NoNoncense.nonce(@name, 96)
      nonce2_info = nonce_info(nonce2, @name)

      assert nonce1_info.count == cycle_size - 1
      assert nonce2_info.count == 0

      assert nonce1_info.cycle == 0
      assert nonce2_info.cycle == 1

      assert nonce2_info.timestamp == nonce1_info.timestamp + 1
    end

    test "creates unique nonces with concurrent requests" do
      tasks = 10
      nonces_per_task = 100_000

      concurrent_gen(tasks, nonces_per_task, fn -> NoNoncense.nonce(@name, 96) end)
      |> Enum.count()
      |> then(fn count -> assert count == tasks * nonces_per_task end)
    end
  end

  describe "nonce(128)" do
    setup do
      NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch)
    end

    test "generates a new nonce" do
      nonce = NoNoncense.nonce(@name, 128)
      assert bit_size(nonce) == 128
      assert nonce != NoNoncense.nonce(@name, 128)
    end

    test "creates unique nonces with concurrent requests" do
      tasks = 10
      nonces_per_task = 100_000

      concurrent_gen(tasks, nonces_per_task, fn -> NoNoncense.nonce(@name, 128) end)
      |> Enum.count()
      |> then(fn count -> assert count == tasks * nonces_per_task end)
    end
  end

  describe "sortable_nonce(64)" do
    setup do
      NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch)
    end

    test "generates a new nonce" do
      nonce = NoNoncense.sortable_nonce(@name, 64)
      assert bit_size(nonce) == 64
      assert nonce != NoNoncense.sortable_nonce(@name, 64)
    end

    test "creates unique nonces with concurrent requests" do
      tasks = 10
      nonces_per_task = 100_000

      concurrent_gen(tasks, nonces_per_task, fn -> NoNoncense.sortable_nonce(@name, 64) end)
      |> Enum.count()
      |> then(fn count -> assert count == tasks * nonces_per_task end)
    end
  end

  describe "sortable_nonce(96)" do
    setup do
      NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch)
    end

    test "generates a new nonce" do
      nonce = NoNoncense.sortable_nonce(@name, 96)
      assert bit_size(nonce) == 96
      assert nonce != NoNoncense.sortable_nonce(@name, 96)
    end

    test "creates unique nonces with concurrent requests" do
      tasks = 10
      nonces_per_task = 100_000

      concurrent_gen(tasks, nonces_per_task, fn -> NoNoncense.sortable_nonce(@name, 96) end)
      |> Enum.count()
      |> then(fn count -> assert count == tasks * nonces_per_task end)
    end
  end

  describe "sortable_nonce(128)" do
    setup do
      NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch)
    end

    test "generates a new nonce" do
      nonce = NoNoncense.sortable_nonce(@name, 128)
      assert bit_size(nonce) == 128
      assert nonce != NoNoncense.sortable_nonce(@name, 128)
    end

    test "creates unique nonces with concurrent requests" do
      tasks = 10
      nonces_per_task = 100_000

      concurrent_gen(tasks, nonces_per_task, fn -> NoNoncense.sortable_nonce(@name, 128) end)
      |> Enum.count()
      |> then(fn count -> assert count == tasks * nonces_per_task end)
    end
  end

  describe "encrypted_nonce/2" do
    setup do
      NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch)
    end

    test "generates new 64-bits nonces" do
      key = :crypto.strong_rand_bytes(24)
      nonce = NoNoncense.encrypted_nonce(@name, 64, key)
      assert bit_size(nonce) == 64
      assert nonce != NoNoncense.encrypted_nonce(@name, 64, key)
    end

    test "generates new 96-bits nonces" do
      key = :crypto.strong_rand_bytes(24)
      nonce = NoNoncense.encrypted_nonce(@name, 96, key)
      assert bit_size(nonce) == 96
      assert nonce != NoNoncense.encrypted_nonce(@name, 96, key)
    end

    test "generates new 128-bits nonces" do
      key = :crypto.strong_rand_bytes(32)
      nonce = NoNoncense.encrypted_nonce(@name, 128, key)
      assert bit_size(nonce) == 128
      assert nonce != NoNoncense.encrypted_nonce(@name, 128, key)
    end

    # @tag timeout: :infinity
    # test "find collision" do
    #   # 2^31 64 bits nonces take 16GB memory after which we terminate
    #   1..Integer.pow(2, 31)
    #   |> Stream.map(fn _ -> NoNoncense.encrypted_nonce(@name, 64) end)
    #   |> Enum.reduce_while({MapSet.new(), 0}, fn nonce, {nonces, count} ->
    #     if rem(count, 1_000_000) == 0, do: IO.puts("#{div(count, 1_000_000)}M nonces")

    #     if MapSet.member?(nonces, nonce) do
    #       {:halt, "nonce #{nonce} present in nonces"}
    #     else
    #       {:cont, {MapSet.put(nonces, nonce), count + 1}}
    #     end
    #   end)
    # end
  end
end
