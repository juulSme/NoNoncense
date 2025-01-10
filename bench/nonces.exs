defmodule Benchmark do
  def bench(fun, tasks \\ System.schedulers_online(), count \\ 10_000_000) do
    fn _ -> fun.() end |> do_bench(tasks, count)
  end

  defp do_bench(fun, 1, count) do
    start = System.monotonic_time(:nanosecond)
    1..count |> Stream.each(fun) |> Stream.run()
    stop = System.monotonic_time(:nanosecond)
    calc_rate(count, start, stop)
  end

  defp do_bench(fun, tasks, count) do
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

  def bench_many(pairs) do
    Enum.map(pairs, fn {name, bench_args} ->
      IO.write("Running #{name}... ")
      {name, apply(__MODULE__, :bench, bench_args)} |> tap(fn _ -> IO.puts("done.") end)
    end)
    |> tap(fn _ -> IO.puts("") end)
  end

  def format_results(results) do
    name_length = Enum.reduce(results, 0, fn {name, _}, acc -> max(acc, String.length(name)) end)
    res_length = Enum.reduce(results, 0, fn {_, res}, acc -> max(acc, String.length(res)) end)

    results
    |> Enum.map(fn {name, result} ->
      {String.pad_trailing(name <> ":", name_length + 1), String.pad_leading(result, res_length)}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.map(fn {name, result} -> "#{name} #{result}" end)
    |> Enum.join("\n")
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
  end
end

NoNoncense.init(machine_id: 0)
key128 = :crypto.strong_rand_bytes(32)
key192 = :crypto.strong_rand_bytes(24)

IO.puts("Sleeping for 10 seconds to allow some timestamp space to build")
Process.sleep(10000)

m10 = 10_000_000
m100 = 100_000_000
tasks = System.schedulers_online()

%{
  "rand64" => [fn -> :crypto.strong_rand_bytes(8) end, 1, m10],
  "rand64_m" => [fn -> :crypto.strong_rand_bytes(8) end, tasks, m10],
  "rand96" => [fn -> :crypto.strong_rand_bytes(12) end, 1, m10],
  "rand96_m" => [fn -> :crypto.strong_rand_bytes(12) end, tasks, m10],
  "rand128" => [fn -> :crypto.strong_rand_bytes(16) end, 1, m10],
  "rand128_m" => [fn -> :crypto.strong_rand_bytes(16) end, tasks, m10],
  "nonce64" => [fn -> NoNoncense.nonce(64) end, 1, m100],
  "nonce64_m" => [fn -> NoNoncense.nonce(64) end, tasks, m100],
  "nonce96" => [fn -> NoNoncense.nonce(96) end, 1, m100],
  "nonce96_m" => [fn -> NoNoncense.nonce(96) end, tasks, m100],
  "nonce128" => [fn -> NoNoncense.nonce(128) end, 1, m100],
  "nonce128_m" => [fn -> NoNoncense.nonce(128) end, tasks, m100],
  "enc_nonce64" => [fn -> NoNoncense.encrypted_nonce(64, key192) end, 1, m10],
  "enc_nonce64_m" => [fn -> NoNoncense.encrypted_nonce(64, key192) end, tasks, m10],
  "enc_nonce96" => [fn -> NoNoncense.encrypted_nonce(96, key192) end, 1, m10],
  "enc_nonce96_m" => [fn -> NoNoncense.encrypted_nonce(96, key192) end, tasks, m10],
  "enc_nonce128" => [fn -> NoNoncense.encrypted_nonce(128, key128) end, 1, m10],
  "enc_nonce128_m" => [fn -> NoNoncense.encrypted_nonce(128, key128) end, tasks, m10],
  "sortable_nonce64" => [fn -> NoNoncense.sortable_nonce(64) end, 1, m100],
  "sortable_nonce64_m" => [fn -> NoNoncense.sortable_nonce(64) end, tasks, m100],
  "sortable_nonce96" => [fn -> NoNoncense.sortable_nonce(96) end, 1, m100],
  "sortable_nonce96_m" => [fn -> NoNoncense.sortable_nonce(96) end, tasks, m100],
  "sortable_nonce128" => [fn -> NoNoncense.sortable_nonce(128) end, 1, m100],
  "sortable_nonce128_m" => [fn -> NoNoncense.sortable_nonce(128) end, tasks, m100]
}
|> Benchmark.bench_many()
|> Benchmark.format_results()
|> IO.puts()
