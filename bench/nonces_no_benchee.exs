defmodule NoncesNoBenchee do
  def bench(fun, tasks \\ System.schedulers_online(), count \\ 10_000_000)

  def bench(fun, 1, count) do
    start = System.monotonic_time(:microsecond)
    1..count |> Stream.each(fun) |> Stream.run()
    stop = System.monotonic_time(:microsecond)
    calc_rate(count, start, stop)
  end

  def bench(fun, tasks, count) do
    per_task = div(count, tasks)
    start = System.monotonic_time(:microsecond)

    1..tasks
    |> Enum.map(fn _ ->
      Task.async(fn ->
        1..per_task |> Stream.each(fun) |> Stream.run()
      end)
    end)
    |> Task.await_many(60000)

    stop = System.monotonic_time(:microsecond)
    calc_rate(count, start, stop)
  end

  defp calc_rate(count, start, stop) do
    duration = stop - start
    rate = floor(count / duration * 1_000_000)
    "#{rate} ops/s"
  end
end

NoNoncense.init(machine_id: 0)
key128 = :crypto.strong_rand_bytes(32)
IO.puts("Sleeping for 10 seconds to allow some timestamp space to build")
Process.sleep(10000)

key192 = :crypto.strong_rand_bytes(24)

NoncesNoBenchee.bench(fn _ -> NoNoncense.nonce(64) end, 1)
|> IO.inspect(label: "nonce(64) single")

NoncesNoBenchee.bench(fn _ -> NoNoncense.nonce(64) end) |> IO.inspect(label: "nonce(64)")

NoncesNoBenchee.bench(fn _ -> NoNoncense.encrypted_nonce(64, key192) end, 1)
|> IO.inspect(label: "encrypted_nonce(64) single")

NoncesNoBenchee.bench(fn _ -> NoNoncense.encrypted_nonce(64, key192) end)
|> IO.inspect(label: "encrypted_nonce(64)")

NoncesNoBenchee.bench(fn _ -> NoNoncense.nonce(128) end, 1)
|> IO.inspect(label: "nonce(128) single")

NoncesNoBenchee.bench(fn _ -> NoNoncense.nonce(128) end) |> IO.inspect(label: "nonce(128)")

NoncesNoBenchee.bench(fn _ -> NoNoncense.encrypted_nonce(128, key128) end, 1)
|> IO.inspect(label: "encrypted_nonce(128) single")

NoncesNoBenchee.bench(fn _ -> NoNoncense.encrypted_nonce(128, key128) end)
|> IO.inspect(label: "encrypted_nonce(128)")
