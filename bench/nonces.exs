NoNoncense.init(machine_id: 0)

# artifially set back the clock, so that 64-bits nonces don't hit their time-based rate limit
{machine_id, init_at, time_offset, counters_ref} = :persistent_term.get(NoNoncense)
one_day = 24 * 60 * 60 * 1000
:persistent_term.put(NoNoncense, {machine_id, init_at - one_day, time_offset, counters_ref})

key128 = :crypto.strong_rand_bytes(32)
key192 = :crypto.strong_rand_bytes(24)

%{
  "strong_rand_bytes(8) single" => [fn -> :crypto.strong_rand_bytes(8) end, tasks: 1],
  "strong_rand_bytes(8) multi" => [fn -> :crypto.strong_rand_bytes(8) end],
  "strong_rand_bytes(12) single" => [fn -> :crypto.strong_rand_bytes(12) end, tasks: 1],
  "strong_rand_bytes(12) multi" => [fn -> :crypto.strong_rand_bytes(12) end],
  "strong_rand_bytes(16) single" => [fn -> :crypto.strong_rand_bytes(16) end, tasks: 1],
  "strong_rand_bytes(16) multi" => [fn -> :crypto.strong_rand_bytes(16) end],
  "nonce(64) single" => [fn -> NoNoncense.nonce(64) end, tasks: 1],
  "nonce(64) multi" => [fn -> NoNoncense.nonce(64) end],
  "nonce(96) single" => [fn -> NoNoncense.nonce(96) end, tasks: 1],
  "nonce(96) multi" => [fn -> NoNoncense.nonce(96) end],
  "nonce(128) single" => [fn -> NoNoncense.nonce(128) end, tasks: 1],
  "nonce(128) multi" => [fn -> NoNoncense.nonce(128) end],
  "encrypted_nonce(64) single" => [fn -> NoNoncense.encrypted_nonce(64, key192) end, tasks: 1],
  "encrypted_nonce(64) multi" => [fn -> NoNoncense.encrypted_nonce(64, key192) end],
  "encrypted_nonce(96) single" => [fn -> NoNoncense.encrypted_nonce(96, key192) end, tasks: 1],
  "encrypted_nonce(96) multi" => [fn -> NoNoncense.encrypted_nonce(96, key192) end],
  "encrypted_nonce(128) single" => [fn -> NoNoncense.encrypted_nonce(128, key128) end, tasks: 1],
  "encrypted_nonce(128) multi" => [fn -> NoNoncense.encrypted_nonce(128, key128) end],
  "sortable_nonce(64) single" => [fn -> NoNoncense.sortable_nonce(64) end, tasks: 1],
  "sortable_nonce(64) multi" => [fn -> NoNoncense.sortable_nonce(64) end],
  "sortable_nonce(96) single" => [fn -> NoNoncense.sortable_nonce(96) end, tasks: 1],
  "sortable_nonce(96) multi" => [fn -> NoNoncense.sortable_nonce(96) end],
  "sortable_nonce(128) single" => [fn -> NoNoncense.sortable_nonce(128) end, tasks: 1],
  "sortable_nonce(128) multi" => [fn -> NoNoncense.sortable_nonce(128) end]
}
|> Benchmark.bench_many()
|> Benchmark.format_results()
|> IO.puts()
