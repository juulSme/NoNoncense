NoNoncense.init(machine_id: 0)

# artifially set back the clock, so that 64-bits nonces don't hit their time-based rate limit
{machine_id, init_at, time_offset, counters_ref} = :persistent_term.get(NoNoncense)
one_day = 24 * 60 * 60 * 1000
:persistent_term.put(NoNoncense, {machine_id, init_at - one_day, time_offset, counters_ref})

key128 = :crypto.strong_rand_bytes(32)
key192 = :crypto.strong_rand_bytes(24)

%{
  "rand64" => [fn -> :crypto.strong_rand_bytes(8) end, tasks: 1],
  "rand64_m" => [fn -> :crypto.strong_rand_bytes(8) end],
  "rand96" => [fn -> :crypto.strong_rand_bytes(12) end, tasks: 1],
  "rand96_m" => [fn -> :crypto.strong_rand_bytes(12) end],
  "rand128" => [fn -> :crypto.strong_rand_bytes(16) end, tasks: 1],
  "rand128_m" => [fn -> :crypto.strong_rand_bytes(16) end],
  "nonce64" => [fn -> NoNoncense.nonce(64) end, tasks: 1],
  "nonce64_m" => [fn -> NoNoncense.nonce(64) end],
  "nonce96" => [fn -> NoNoncense.nonce(96) end, tasks: 1],
  "nonce96_m" => [fn -> NoNoncense.nonce(96) end],
  "nonce128" => [fn -> NoNoncense.nonce(128) end, tasks: 1],
  "nonce128_m" => [fn -> NoNoncense.nonce(128) end],
  "enc_nonce64" => [fn -> NoNoncense.encrypted_nonce(64, key192) end, tasks: 1],
  "enc_nonce64_m" => [fn -> NoNoncense.encrypted_nonce(64, key192) end],
  "enc_nonce96" => [fn -> NoNoncense.encrypted_nonce(96, key192) end, tasks: 1],
  "enc_nonce96_m" => [fn -> NoNoncense.encrypted_nonce(96, key192) end],
  "enc_nonce128" => [fn -> NoNoncense.encrypted_nonce(128, key128) end, tasks: 1],
  "enc_nonce128_m" => [fn -> NoNoncense.encrypted_nonce(128, key128) end],
  "sortable_nonce64" => [fn -> NoNoncense.sortable_nonce(64) end, tasks: 1],
  "sortable_nonce64_m" => [fn -> NoNoncense.sortable_nonce(64) end],
  "sortable_nonce96" => [fn -> NoNoncense.sortable_nonce(96) end, tasks: 1],
  "sortable_nonce96_m" => [fn -> NoNoncense.sortable_nonce(96) end],
  "sortable_nonce128" => [fn -> NoNoncense.sortable_nonce(128) end, tasks: 1],
  "sortable_nonce128_m" => [fn -> NoNoncense.sortable_nonce(128) end]
}
|> Benchmark.bench_many()
|> Benchmark.format_results()
|> IO.puts()
