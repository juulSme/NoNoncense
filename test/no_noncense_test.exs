defmodule NoNoncenseTest do
  use ExUnit.Case, async: true
  use NoNoncense.Constants
  import ExUnit.CaptureLog

  @name :test_nonce_factory
  @epoch System.system_time(:millisecond)

  defp get_state(name) do
    {machine_id, init_at, time_offset, counters_ref, {cipher64, cipher96, cipher128}} =
      :persistent_term.get(name)

    %{
      machine_id: machine_id,
      init_at: init_at,
      time_offset: time_offset,
      counters_ref: counters_ref,
      cipher64: cipher64,
      cipher96: cipher96,
      cipher128: cipher128
    }
  end

  defp nonce_info(nonce, name) do
    %{init_at: init_at, time_offset: time_offset} = get_state(name)

    size = bit_size(nonce)
    count_size = size - @ts_bits - @id_bits
    cycle_size = Integer.pow(2, min(64, count_size))

    <<timestamp::@ts_bits, machine_id::@id_bits, count::size(count_size)>> = nonce

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
        System.system_time(:millisecond) - Integer.pow(2, @ts_bits) + 1 * 24 * 60 * 60 * 1000 +
          60_000

      {_, msg} =
        with_log(fn ->
          NoNoncense.init(machine_id: 0, name: @name, epoch: long_ago)
        end)

      assert msg =~ "[warning] timestamp overflow in 1 days"
    end

    test "raises on timestamp overflow" do
      long_ago = System.system_time(:millisecond) - Integer.pow(2, @ts_bits) - 1000

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

    test "works without crypto init" do
      NoNoncense.init(name: @name, machine_id: 1)
      assert %{cipher64: nil, cipher96: nil, cipher128: nil} = get_state(@name)
    end

    test "raises on too small base key" do
      assert_raise ArgumentError, "base_key size must be at least 256 bits", fn ->
        NoNoncense.init(machine_id: 1, base_key: "a")
      end
    end

    test "defaults to OTP algorithms" do
      NoNoncense.init(name: @name, machine_id: 1, base_key: :crypto.strong_rand_bytes(32))

      %{cipher64: {cipher64, _}, cipher96: {cipher96, _}, cipher128: {cipher128, _}} =
        get_state(@name)

      assert cipher64 == :blowfish
      assert cipher96 == :blowfish
      assert cipher128 == :aes
    end

    test "can override algorithms" do
      NoNoncense.init(
        name: @name,
        machine_id: 1,
        base_key: :crypto.strong_rand_bytes(32),
        cipher64: :des3,
        cipher96: :speck,
        cipher128: :speck
      )

      assert %{cipher64: {:des3, _}, cipher96: {:speck, _}, cipher128: {:speck, _}} =
               get_state(@name)
    end

    test "raises on unsupported alg" do
      assert_raise ArgumentError, "alg aes is not supported for 64-bits nonces", fn ->
        NoNoncense.init(
          name: @name,
          machine_id: 1,
          base_key: :crypto.strong_rand_bytes(32),
          cipher64: :aes
        )
      end
    end

    test "defaults to derived keys" do
      base_key = :crypto.strong_rand_bytes(32)

      NoNoncense.init(name: @name, machine_id: 1, base_key: base_key)

      NoNoncense.encrypted_nonce(@name, 64)
      NoNoncense.encrypted_nonce(@name, 96)
      NoNoncense.encrypted_nonce(@name, 128)
    end

    test "uses key overrides" do
      base_key = :crypto.strong_rand_bytes(32)

      key64 = :crypto.strong_rand_bytes(16)
      key96 = :crypto.strong_rand_bytes(16)
      key128 = :crypto.strong_rand_bytes(32)

      NoNoncense.init(
        name: @name,
        machine_id: 1,
        base_key: base_key,
        key64: key64,
        key96: key96,
        key128: key128
      )

      <<_::51, c1::13>> = NoNoncense.nonce(@name, 64)
      enc_nonce_64 = NoNoncense.encrypted_nonce(@name, 64)
      <<_::51, c2::13>> = :crypto.crypto_one_time(:blowfish_ecb, key64, enc_nonce_64, false)
      <<enc_nonce_96::binary-8, 0::32>> = NoNoncense.encrypted_nonce(@name, 96)
      <<_::51, c3::13>> = :crypto.crypto_one_time(:blowfish_ecb, key96, enc_nonce_96, false)
      enc_nonce_128 = NoNoncense.encrypted_nonce(@name, 128)
      <<_::115, c4::13>> = :crypto.crypto_one_time(:aes_256_ecb, key128, enc_nonce_128, false)
      assert c1 == c2 - 1
      assert c2 == c3 - 1
      assert c3 == c4 - 1
    end

    test "verifies key override lengths" do
      base_key = :crypto.strong_rand_bytes(32)

      right = [
        {64, :des3, 24},
        {64, :blowfish, 16},
        {64, :speck, 16},
        {96, :des3, 24},
        {96, :blowfish, 16},
        {96, :speck, 18},
        {128, :aes, 32},
        {128, :speck, 32}
      ]

      for {size, alg, key_size} <- right do
        NoNoncense.init([
          {:"cipher#{size}", alg},
          {:"key#{size}", :crypto.strong_rand_bytes(key_size)},
          name: @name,
          machine_id: 1,
          base_key: base_key
        ])

        assert_raise ArgumentError, fn ->
          NoNoncense.init([
            {:"cipher#{size}", alg},
            {:"key#{size}", :crypto.strong_rand_bytes(1)},
            name: @name,
            machine_id: 1,
            base_key: base_key
          ])
        end
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
      %{counters_ref: counter_ref} = get_state(@name)
      :atomics.put(counter_ref, 1, @max_count_64 - 2)

      nonce1 = NoNoncense.nonce(@name, 64)
      nonce1_info = nonce_info(nonce1, @name)

      nonce2 = NoNoncense.nonce(@name, 64)
      nonce2_info = nonce_info(nonce2, @name)

      assert nonce1_info.count == @max_count_64 - 1
      assert nonce2_info.count == 0

      assert nonce1_info.cycle == 0
      assert nonce2_info.cycle == 1

      assert nonce2_info.timestamp == nonce1_info.timestamp + 1
    end

    test "nonce's can't predate their timestamp" do
      state = get_state(@name)
      %{init_at: init_at, time_offset: time_offset, counters_ref: counter_ref} = state

      # jump to cycle #99, which should not generate nonces until 99ms have passed
      cycle_count = 99
      :atomics.put(counter_ref, 1, @max_count_64 * cycle_count - 5)
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
        nonce_n = info.total_count - cycle_count * @max_count_64

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
      %{counters_ref: counter_ref} = get_state(@name)
      cycle_size = Integer.pow(2, @count_bits_96)
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

  describe "get_datetime/2" do
    setup do
      NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch)
    end

    test "returns nonce timestamp" do
      pre_gen_dt = DateTime.utc_now()
      Process.sleep(10)
      nonce = NoNoncense.sortable_nonce(@name, 64)
      nonce_dt = NoNoncense.get_datetime(@name, nonce)
      assert :lt == DateTime.compare(pre_gen_dt, nonce_dt)
    end
  end

  describe "inialized ciphers" do
    test "Blowfish crypto_one_time matches crypto_update" do
      key = :crypto.strong_rand_bytes(32)
      blocks = for _ <- 1..10, do: :crypto.strong_rand_bytes(8)
      one_time_res = for b <- blocks, do: :crypto.crypto_one_time(:blowfish_ecb, key, b, true)
      initialized = :crypto.crypto_init(:blowfish_ecb, key, true)
      update_res = for b <- blocks, do: :crypto.crypto_update(initialized, b)
      assert one_time_res == update_res
    end

    test "AES 256 crypto_one_time matches crypto_update" do
      key = :crypto.strong_rand_bytes(32)
      blocks = for _ <- 1..10, do: :crypto.strong_rand_bytes(16)
      one_time_res = for b <- blocks, do: :crypto.crypto_one_time(:aes_256_ecb, key, b, true)
      initialized = :crypto.crypto_init(:aes_256_ecb, key, true)
      update_res = for b <- blocks, do: :crypto.crypto_update(initialized, b)
      assert one_time_res == update_res
    end
  end

  describe "encrypted_nonce/2 with blowfish" do
    setup do
      NoNoncense.init(
        machine_id: 0,
        name: @name,
        epoch: @epoch,
        base_key: :crypto.strong_rand_bytes(32)
      )
    end

    test "raises without key" do
      NoNoncense.init(machine_id: 0, name: :raise_test)

      for size <- [64, 96, 128] do
        assert_raise RuntimeError, "no key set at NoNoncense initialization", fn ->
          NoNoncense.encrypted_nonce(:raise_test, size)
        end
      end
    end

    test "generates new 64-bits nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 64)
      assert bit_size(nonce) == 64
      assert nonce != NoNoncense.encrypted_nonce(@name, 64)
    end

    test "generates new 96-bits nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 96)
      assert bit_size(nonce) == 96
      assert nonce != NoNoncense.encrypted_nonce(@name, 96)
    end

    test "generates new 128-bits nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 128)
      assert bit_size(nonce) == 128
      assert nonce != NoNoncense.encrypted_nonce(@name, 128)
    end

    @tag timeout: :infinity
    @tag :very_slow
    # requires redis / valkey
    test "find collision" do
      conns =
        for n <- 1..10 do
          start_supervised!(Supervisor.child_spec({Redix, database: 12}, id: {Redix, n}))
        end
        |> Stream.cycle()

      get_conn = fn -> Enum.take(conns, 1) |> List.first() end
      get_conn.() |> Redix.command(~w(flushdb))
      on_exit(:flush_redis, fn -> Redix.command(get_conn.(), ~w(flushdb)) end)

      max_nonce_2n = 29
      chunk_size_2n = 18
      chunk_size = Integer.pow(2, chunk_size_2n)
      chunks = Integer.pow(2, max_nonce_2n - chunk_size_2n)

      1..chunks
      |> Task.async_stream(
        fn chunk_n ->
          # for 1..
          nonces =
            1..chunk_size
            |> Enum.flat_map(fn _ ->
              [NoNoncense.encrypted_nonce(@name, 64), nil]
            end)

          start = System.monotonic_time(:millisecond)
          assert {:ok, 1} = Redix.command(get_conn.(), ~w(MSETNX) ++ nonces, timeout: :infinity)
          {chunk_n, System.monotonic_time(:millisecond) - start}
        end,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity
      )
      |> Stream.with_index()
      |> Enum.each(fn {{:ok, {n, time}}, i} ->
        IO.puts("#{i * chunk_size / 1_000_000}M nonces, chunk #{n} write took #{time}ms")
      end)
    end
  end

  describe "encrypted_nonce/2 with Speck" do
    setup do
      NoNoncense.init(
        machine_id: 0,
        name: @name,
        epoch: @epoch,
        base_key: :crypto.strong_rand_bytes(32),
        cipher64: :speck,
        cipher96: :speck,
        cipher128: :speck
      )
    end

    test "generates new 64-bits nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 64)
      assert bit_size(nonce) == 64
      assert nonce != NoNoncense.encrypted_nonce(@name, 64)
    end

    test "generates new 96-bits nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 96)
      assert bit_size(nonce) == 96
      assert nonce != NoNoncense.encrypted_nonce(@name, 96)
    end

    test "generates new 128-bits nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 128)
      assert bit_size(nonce) == 128
      assert nonce != NoNoncense.encrypted_nonce(@name, 128)
    end
  end

  describe "encrypted_nonce/2 with 3des" do
    setup do
      NoNoncense.init(
        machine_id: 0,
        name: @name,
        epoch: @epoch,
        base_key: :crypto.strong_rand_bytes(32),
        cipher64: :des3,
        cipher96: :des3
      )
    end

    test "generates new 64-bits nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 64)
      assert bit_size(nonce) == 64
      assert nonce != NoNoncense.encrypted_nonce(@name, 64)
    end

    test "generates new 96-bits nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 96)
      assert bit_size(nonce) == 96
      assert nonce != NoNoncense.encrypted_nonce(@name, 96)
    end
  end
end
