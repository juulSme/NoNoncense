defmodule NoNoncenseTest do
  alias NoNoncense.Crypto
  use ExUnit.Case, async: true
  use NoNoncense.Constants
  import ExUnit.CaptureLog
  import SpeckEx.Block

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

    @tag :blowfish
    test "defaults to OTP algorithms" do
      NoNoncense.init(name: @name, machine_id: 1, base_key: :crypto.strong_rand_bytes(32))

      %{cipher64: {cipher64, _, _}, cipher96: {cipher96, _, _}, cipher128: {cipher128, _, _}} =
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
      assert_raise ArgumentError, "alg aes is not supported for 64-bit nonces", fn ->
        NoNoncense.init(
          name: @name,
          machine_id: 1,
          base_key: :crypto.strong_rand_bytes(32),
          cipher64: :aes,
          cipher96: :des3
        )
      end

      assert_raise ArgumentError, "alg aes is not supported for 96-bit nonces", fn ->
        NoNoncense.init(
          name: @name,
          machine_id: 1,
          base_key: :crypto.strong_rand_bytes(32),
          cipher64: :des3,
          cipher96: :aes
        )
      end
    end

    test "defaults to derived keys" do
      base_key = :crypto.strong_rand_bytes(32)

      NoNoncense.init(
        name: @name,
        machine_id: 1,
        base_key: base_key,
        cipher64: :des3,
        cipher96: :des3
      )

      NoNoncense.encrypted_nonce(@name, 64)
      NoNoncense.encrypted_nonce(@name, 96)
      NoNoncense.encrypted_nonce(@name, 128)
    end

    test "uses key overrides" do
      base_key = :crypto.strong_rand_bytes(32)

      key64 = :crypto.strong_rand_bytes(24)
      key96 = :crypto.strong_rand_bytes(24)
      key128 = :crypto.strong_rand_bytes(32)

      NoNoncense.init(
        name: @name,
        machine_id: 1,
        base_key: base_key,
        cipher64: :des3,
        key64: key64,
        cipher96: :des3,
        key96: key96,
        key128: key128
      )

      <<b::51, c1::13>> = NoNoncense.nonce(@name, 64)
      enc_nonce_64 = NoNoncense.encrypted_nonce(@name, 64)
      enc_nonce_96 = NoNoncense.encrypted_nonce(@name, 96)
      enc_nonce_128 = NoNoncense.encrypted_nonce(@name, 128)

      assert enc_nonce_64 ==
               :crypto.crypto_one_time(
                 :des_ede3_cbc,
                 key64,
                 <<0::64>>,
                 <<b::51, c1 + 1::13>>,
                 true
               )

      assert enc_nonce_96 ==
               :crypto.crypto_one_time(
                 :des_ede3_cbc,
                 key96,
                 <<0::64>>,
                 <<b::51, c1 + 2::13>>,
                 true
               ) <>
                 <<0::32>>

      assert enc_nonce_128 ==
               :crypto.crypto_one_time(:aes_256_ecb, key128, <<b::51, 0::64, c1 + 3::13>>, true)
    end

    @tag :blowfish
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
    @tag :blowfish
    test "Blowfish crypto_one_time matches concurrent shared-init-ref crypto_update" do
      test_concurrent_shared_init_ref_enc(:blowfish_ecb, 16, 8)
    end

    test "AES 256 crypto_one_time matches concurrent shared-init-ref crypto_update" do
      test_concurrent_shared_init_ref_enc(:aes_256_ecb, 32, 16)
    end
  end

  defp test_concurrent_shared_init_ref_enc(alg, key_size, block_size) do
    to_blocklist = fn bin -> for <<block::binary-size(block_size) <- bin>>, do: block end

    key = :crypto.strong_rand_bytes(key_size)
    schedulers = :erlang.system_info(:schedulers_online)
    # block count aligned with scheduler count
    block_n = 100_000 |> div(schedulers) |> Kernel.*(schedulers)
    blocks = :crypto.strong_rand_bytes(block_size * block_n)

    crypto_one_time_res =
      :crypto.crypto_one_time(alg, key, blocks, true)
      |> to_blocklist.()
      |> Enum.sort()

    initialized = :crypto.crypto_init(alg, key, true)

    results =
      blocks
      |> to_blocklist.()
      |> Stream.chunk_every(div(block_n, schedulers))
      |> Enum.map(fn blocks ->
        Task.async(fn ->
          for b <- blocks, do: :crypto.crypto_update(initialized, b)
        end)
      end)
      |> Task.await_many()
      |> List.flatten()
      |> Enum.sort()

    assert crypto_one_time_res == results
  end

  describe "encrypted_nonce/2 with blowfish" do
    setup do
      base_key = :crypto.strong_rand_bytes(32)
      NoNoncense.init(machine_id: 0, name: @name, epoch: @epoch, base_key: base_key)
      [base_key: base_key]
    end

    @tag :blowfish
    test "generates new 64-bit nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 64)
      assert bit_size(nonce) == 64
      assert nonce != NoNoncense.encrypted_nonce(@name, 64)
    end

    @tag :blowfish
    test "generates new 96-bit nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 96)
      assert bit_size(nonce) == 96
      assert nonce != NoNoncense.encrypted_nonce(@name, 96)
    end

    @tag :blowfish
    test "actually uses blowfish", %{base_key: base_key} do
      {_, key64} = Crypto.maybe_gen_key(nil, base_key, :blowfish, 64)
      {_, key96} = Crypto.maybe_gen_key(nil, base_key, :blowfish, 96)

      <<b::51, c1::13>> = NoNoncense.nonce(@name, 64)
      enc_nonce_64 = NoNoncense.encrypted_nonce(@name, 64)
      enc_nonce_96 = NoNoncense.encrypted_nonce(@name, 96)

      assert enc_nonce_64 ==
               :crypto.crypto_one_time(:blowfish_ecb, key64, <<b::51, c1 + 1::13>>, true)

      assert enc_nonce_96 ==
               :crypto.crypto_one_time(:blowfish_ecb, key96, <<b::51, c1 + 2::13>>, true) <>
                 <<0::32>>
    end

    @tag timeout: :infinity
    @tag :very_slow
    @tag :blowfish
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

    test "generates new 64-bit nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 64)
      assert bit_size(nonce) == 64
      assert nonce != NoNoncense.encrypted_nonce(@name, 64)
    end

    test "generates new 96-bit nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 96)
      assert bit_size(nonce) == 96
      assert nonce != NoNoncense.encrypted_nonce(@name, 96)
      <<_head::64, tail::32>> = nonce
      assert tail != 0
    end

    test "generates new 128-bit nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 128)
      assert bit_size(nonce) == 128
      assert nonce != NoNoncense.encrypted_nonce(@name, 128)
    end

    test "nonces are actually speck-encrypted" do
      %{cipher64: {_, init64}, cipher96: {_, init96}, cipher128: {_, init128}} =
        get_state(@name)

      <<b::51, c1::13>> = NoNoncense.nonce(@name, 64)
      enc_nonce_64 = NoNoncense.encrypted_nonce(@name, 64)
      enc_nonce_96 = NoNoncense.encrypted_nonce(@name, 96)
      enc_nonce_128 = NoNoncense.encrypted_nonce(@name, 128)

      assert enc_nonce_64 == encrypt(<<b::51, c1 + 1::13>>, init64, :speck64_128)
      assert enc_nonce_96 == encrypt(<<b::51, 0::32, c1 + 2::13>>, init96, :speck96_144)
      assert enc_nonce_128 == encrypt(<<b::51, 0::64, c1 + 3::13>>, init128, :speck128_256)
    end
  end

  describe "encrypted_nonce/2 with 3des and aes" do
    setup do
      base_key = :crypto.strong_rand_bytes(32)

      NoNoncense.init(
        machine_id: 0,
        name: @name,
        epoch: @epoch,
        base_key: base_key,
        cipher64: :des3,
        cipher96: :des3
      )

      [base_key: base_key]
    end

    test "raises without key" do
      NoNoncense.init(machine_id: 0, name: :raise_test)

      for size <- [64, 96, 128] do
        assert_raise RuntimeError, "no key set at NoNoncense initialization", fn ->
          NoNoncense.encrypted_nonce(:raise_test, size)
        end
      end
    end

    test "generates new 64-bit nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 64)
      assert bit_size(nonce) == 64
      assert nonce != NoNoncense.encrypted_nonce(@name, 64)
    end

    test "generates new 96-bit nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 96)
      assert bit_size(nonce) == 96
      assert nonce != NoNoncense.encrypted_nonce(@name, 96)
    end

    test "generates new 128-bit nonces" do
      nonce = NoNoncense.encrypted_nonce(@name, 128)
      assert bit_size(nonce) == 128
      assert nonce != NoNoncense.encrypted_nonce(@name, 128)
    end

    test "are actually 3des/aes-encrypted", %{base_key: base_key} do
      %{cipher64: {_, key64}, cipher96: {_, key96}} = get_state(@name)
      {_, key128} = Crypto.maybe_gen_key(nil, base_key, :aes, 128)

      <<b::51, c1::13>> = NoNoncense.nonce(@name, 64)
      enc_nonce_64 = NoNoncense.encrypted_nonce(@name, 64)
      enc_nonce_96 = NoNoncense.encrypted_nonce(@name, 96)
      enc_nonce_128 = NoNoncense.encrypted_nonce(@name, 128)

      assert enc_nonce_64 ==
               :crypto.crypto_one_time(
                 :des_ede3_cbc,
                 key64,
                 <<0::64>>,
                 <<b::51, c1 + 1::13>>,
                 true
               )

      assert enc_nonce_96 ==
               :crypto.crypto_one_time(
                 :des_ede3_cbc,
                 key96,
                 <<0::64>>,
                 <<b::51, c1 + 2::13>>,
                 true
               ) <>
                 <<0::32>>

      assert enc_nonce_128 ==
               :crypto.crypto_one_time(:aes_256_ecb, key128, <<b::51, 0::64, c1 + 3::13>>, true)
    end
  end

  describe "encrypt/2 and decrypt/2" do
    setup do
      NoNoncense.init(
        machine_id: 0,
        name: @name,
        epoch: @epoch,
        base_key: :crypto.strong_rand_bytes(32),
        cipher64: :speck,
        cipher96: :speck
      )
    end

    test "encrypt and decrypt 64-bit nonces" do
      plaintext = NoNoncense.nonce(@name, 64)
      ciphertext = NoNoncense.encrypt(@name, plaintext)

      assert bit_size(ciphertext) == 64
      assert plaintext != ciphertext
      assert plaintext == NoNoncense.decrypt(@name, ciphertext)
    end

    test "encrypt and decrypt 96-bit nonces" do
      plaintext = NoNoncense.nonce(@name, 64) <> <<0::32>>
      ciphertext = NoNoncense.encrypt(@name, plaintext)

      assert bit_size(ciphertext) == 96
      assert plaintext != ciphertext
      assert plaintext == NoNoncense.decrypt(@name, ciphertext)
    end

    test "encrypt and decrypt 128-bit nonces" do
      plaintext = NoNoncense.nonce(@name, 128)
      ciphertext = NoNoncense.encrypt(@name, plaintext)

      assert bit_size(ciphertext) == 128
      assert plaintext != ciphertext
      assert plaintext == NoNoncense.decrypt(@name, ciphertext)
    end

    test "encrypting the same nonce twice produces the same ciphertext" do
      plaintext = NoNoncense.nonce(@name, 64)
      ciphertext1 = NoNoncense.encrypt(@name, plaintext)
      ciphertext2 = NoNoncense.encrypt(@name, plaintext)

      assert ciphertext1 == ciphertext2
    end

    test "different plaintext nonces produce different ciphertext" do
      plaintext1 = NoNoncense.nonce(@name, 64)
      plaintext2 = NoNoncense.nonce(@name, 64)
      ciphertext1 = NoNoncense.encrypt(@name, plaintext1)
      ciphertext2 = NoNoncense.encrypt(@name, plaintext2)

      assert plaintext1 != plaintext2
      assert ciphertext1 != ciphertext2
    end

    test "decrypt is the inverse of encrypt for 64 and 128-bit nonces" do
      for size <- [64, 128] do
        plaintext = NoNoncense.nonce(@name, size)
        ciphertext = NoNoncense.encrypt(@name, plaintext)
        assert plaintext == NoNoncense.decrypt(@name, ciphertext)
      end
    end
  end

  describe "encrypt/2 and decrypt/2 with 3DES" do
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

    test "rejects 96 bits nonces with non-zero tail" do
      assert_raise FunctionClauseError, fn -> NoNoncense.encrypt(@name, <<1::96>>) end
      assert_raise FunctionClauseError, fn -> NoNoncense.decrypt(@name, <<1::96>>) end
    end
  end

  describe "encrypt/2 and decrypt/2 with Speck cipher for 96-bit support" do
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

    test "encrypt and decrypt 96-bit nonces with Speck" do
      plaintext = NoNoncense.nonce(@name, 96)
      ciphertext = NoNoncense.encrypt(@name, plaintext)

      assert bit_size(ciphertext) == 96
      assert plaintext != ciphertext
      assert plaintext == NoNoncense.decrypt(@name, ciphertext)
    end

    test "decrypt is the inverse of encrypt for all sizes with Speck" do
      for size <- [64, 96, 128] do
        plaintext = NoNoncense.nonce(@name, size)
        ciphertext = NoNoncense.encrypt(@name, plaintext)
        assert plaintext == NoNoncense.decrypt(@name, ciphertext)
      end
    end
  end

  describe "decrypt/2 encrypted_nonce/3 nonces" do
    setup do
      NoNoncense.init(
        machine_id: 0,
        name: @name,
        epoch: @epoch,
        base_key: :crypto.strong_rand_bytes(32),
        cipher64: :speck,
        cipher96: :speck
      )
    end

    test "decrypt counter-based encrypted nonces" do
      encrypted_nonce = NoNoncense.encrypted_nonce(@name, 64, :counter)
      decrypted = NoNoncense.decrypt(@name, encrypted_nonce)

      assert bit_size(decrypted) == 64
      # Verify it's a valid nonce structure
      <<_ts::42, machine_id::9, _count::13>> = decrypted
      assert machine_id == 0
    end

    test "decrypt works for nonces with counter base" do
      for size <- [64, 96, 128] do
        encrypted_nonce = NoNoncense.encrypted_nonce(@name, size, :counter)
        decrypted = NoNoncense.decrypt(@name, encrypted_nonce)

        assert bit_size(decrypted) == size
        # Re-encrypting should produce the original encrypted nonce
        assert NoNoncense.encrypt(@name, decrypted) == encrypted_nonce
      end
    end

    test "decrypt works for nonces with sortable base" do
      for size <- [64, 96, 128] do
        encrypted_nonce = NoNoncense.encrypted_nonce(@name, size, :sortable)
        decrypted = NoNoncense.decrypt(@name, encrypted_nonce)

        assert bit_size(decrypted) == size
        # Re-encrypting should produce the original encrypted nonce
        assert NoNoncense.encrypt(@name, decrypted) == encrypted_nonce
      end
    end
  end

  describe "decrypt/2 encrypted_nonce/3 96-bit nonces with Speck" do
    setup do
      NoNoncense.init(
        machine_id: 0,
        name: @name,
        epoch: @epoch,
        base_key: :crypto.strong_rand_bytes(32),
        cipher64: :speck,
        cipher96: :speck
      )
    end

    test "decrypt 96-bit counter-based encrypted nonces with Speck" do
      encrypted_nonce = NoNoncense.encrypted_nonce(@name, 96, :counter)
      decrypted = NoNoncense.decrypt(@name, encrypted_nonce)

      assert bit_size(decrypted) == 96
      # Verify it's a valid nonce structure
      <<_ts::42, machine_id::9, _count::45>> = decrypted
      assert machine_id == 0
    end

    test "decrypt works for all nonce sizes with Speck cipher" do
      for size <- [64, 96, 128] do
        encrypted_nonce = NoNoncense.encrypted_nonce(@name, size, :counter)
        decrypted = NoNoncense.decrypt(@name, encrypted_nonce)

        assert bit_size(decrypted) == size
        # Re-encrypting should produce the original encrypted nonce
        assert NoNoncense.encrypt(@name, decrypted) == encrypted_nonce
      end
    end
  end
end
