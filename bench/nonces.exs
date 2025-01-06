defmodule Benchmark do
  def bench(fun, tasks \\ System.schedulers_online(), count \\ 10_000_000)

  def bench(fun, 1, count) do
    start = System.monotonic_time(:nanosecond)
    1..count |> Stream.each(fun) |> Stream.run()
    stop = System.monotonic_time(:nanosecond)
    calc_rate(count, start, stop)
  end

  def bench(fun, tasks, count) do
    per_task = div(count, tasks)
    start = System.monotonic_time(:nanosecond)

    1..tasks
    |> Enum.map(fn _ ->
      Task.async(fn ->
        1..per_task |> Stream.each(fun) |> Stream.run()
      end)
    end)
    |> Task.await_many(:infinity)

    stop = System.monotonic_time(:nanosecond)
    calc_rate(count, start, stop)
  end

  defp calc_rate(count, start, stop) do
    duration = stop - start

    floor(count / duration * 1_000_000_000)
    |> to_string()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.intersperse(~c"_")
    |> List.flatten()
    |> Enum.reverse()
    |> List.to_string()
    |> String.pad_leading(15)
  end
end

NoNoncense.init(machine_id: 0)
key128 = :crypto.strong_rand_bytes(32)
key192 = :crypto.strong_rand_bytes(24)

IO.puts("Sleeping for 10 seconds to allow some timestamp space to build")
Process.sleep(10000)

rand64 = Benchmark.bench(fn _ -> :crypto.strong_rand_bytes(8) end, 1)
rand64_m = Benchmark.bench(fn _ -> :crypto.strong_rand_bytes(8) end)
rand96 = Benchmark.bench(fn _ -> :crypto.strong_rand_bytes(12) end, 1)
rand96_m = Benchmark.bench(fn _ -> :crypto.strong_rand_bytes(12) end)
rand128 = Benchmark.bench(fn _ -> :crypto.strong_rand_bytes(16) end, 1)
rand128_m = Benchmark.bench(fn _ -> :crypto.strong_rand_bytes(16) end)
nonce64 = Benchmark.bench(fn _ -> NoNoncense.nonce(64) end, 1)
nonce64_m = Benchmark.bench(fn _ -> NoNoncense.nonce(64) end)
enc_nonce64 = Benchmark.bench(fn _ -> NoNoncense.encrypted_nonce(64, key192) end, 1)
enc_nonce64_m = Benchmark.bench(fn _ -> NoNoncense.encrypted_nonce(64, key192) end)
nonce96 = Benchmark.bench(fn _ -> NoNoncense.nonce(96) end, 1)
nonce96_m = Benchmark.bench(fn _ -> NoNoncense.nonce(96) end)
enc_nonce96 = Benchmark.bench(fn _ -> NoNoncense.encrypted_nonce(96, key192) end, 1)
enc_nonce96_m = Benchmark.bench(fn _ -> NoNoncense.encrypted_nonce(96, key192) end)
nonce128 = Benchmark.bench(fn _ -> NoNoncense.nonce(128) end, 1)
nonce128_m = Benchmark.bench(fn _ -> NoNoncense.nonce(128) end)
enc_nonce128 = Benchmark.bench(fn _ -> NoNoncense.encrypted_nonce(128, key128) end, 1)
enc_nonce128_m = Benchmark.bench(fn _ -> NoNoncense.encrypted_nonce(128, key128) end)

"""
NoNonce.nonce(64) single              #{nonce64} ops/s
NoNonce.nonce(96) single              #{nonce96} ops/s
NoNonce.nonce(128) single             #{nonce128} ops/s
NoNonce.encrypted_nonce(64) single    #{enc_nonce64} ops/s
NoNonce.encrypted_nonce(96) single    #{enc_nonce96} ops/s
NoNonce.encrypted_nonce(128) single   #{enc_nonce128} ops/s
:crypto.strong_rand_bytes(8) single   #{rand64} ops/s
:crypto.strong_rand_bytes(12) single  #{rand96} ops/s
:crypto.strong_rand_bytes(126) single #{rand128} ops/s
NoNonce.nonce(64) multi               #{nonce64_m} ops/s
NoNonce.nonce(96) multi               #{nonce96_m} ops/s
NoNonce.nonce(128) multi              #{nonce128_m} ops/s
NoNonce.encrypted_nonce(64) multi     #{enc_nonce64_m} ops/s
NoNonce.encrypted_nonce(96) multi     #{enc_nonce96_m} ops/s
NoNonce.encrypted_nonce(128) multi    #{enc_nonce128_m} ops/s
:crypto.strong_rand_bytes(8) multi    #{rand64_m} ops/s
:crypto.strong_rand_bytes(12) multi   #{rand96_m} ops/s
:crypto.strong_rand_bytes(126) multi  #{rand128_m} ops/s
"""
|> IO.puts()
