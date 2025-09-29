tasks = 4
# with a long-ago epoch, we force a worst-case scenario with bigger-number arithmetic
NoNoncense.init(machine_id: 0, epoch: DateTime.to_unix(~U[1900-01-01T10:00:00Z], :millisecond))

# artifially set back the clock, so that 64-bits nonces don't hit their time-based rate limit
{machine_id, init_at, time_offset, counters_ref} = :persistent_term.get(NoNoncense)
one_day = 24 * 60 * 60 * 1000
:persistent_term.put(NoNoncense, {machine_id, init_at - one_day, time_offset, counters_ref})

<<new_value::64>> = <<init_at - one_day::51, 0::13>>
:atomics.put(counters_ref, 1, new_value - 1)

key128 = :crypto.strong_rand_bytes(32)
key192 = :crypto.strong_rand_bytes(24)

%{
  "strong_rand_bytes(8) single" => [fn -> :crypto.strong_rand_bytes(8) end, tasks: 1],
  "strong_rand_bytes(8) multi" => [fn -> :crypto.strong_rand_bytes(8) end, tasks: tasks],
  "strong_rand_bytes(12) single" => [fn -> :crypto.strong_rand_bytes(12) end, tasks: 1],
  "strong_rand_bytes(12) multi" => [fn -> :crypto.strong_rand_bytes(12) end, tasks: tasks],
  "strong_rand_bytes(16) single" => [fn -> :crypto.strong_rand_bytes(16) end, tasks: 1],
  "strong_rand_bytes(16) multi" => [fn -> :crypto.strong_rand_bytes(16) end, tasks: tasks],
  "nonce(64) single" => [fn -> NoNoncense.nonce(64) end, tasks: 1],
  "nonce(64) multi" => [fn -> NoNoncense.nonce(64) end, tasks: tasks],
  "nonce(96) single" => [fn -> NoNoncense.nonce(96) end, tasks: 1],
  "nonce(96) multi" => [fn -> NoNoncense.nonce(96) end, tasks: tasks],
  "nonce(128) single" => [fn -> NoNoncense.nonce(128) end, tasks: 1],
  "nonce(128) multi" => [fn -> NoNoncense.nonce(128) end, tasks: tasks],
  "encrypted_nonce(64) single" => [fn -> NoNoncense.encrypted_nonce(64, key192) end, tasks: 1],
  "encrypted_nonce(64) multi" => [fn -> NoNoncense.encrypted_nonce(64, key192) end, tasks: tasks],
  "encrypted_nonce(96) single" => [fn -> NoNoncense.encrypted_nonce(96, key192) end, tasks: 1],
  "encrypted_nonce(96) multi" => [fn -> NoNoncense.encrypted_nonce(96, key192) end, tasks: tasks],
  "encrypted_nonce(128) single" => [fn -> NoNoncense.encrypted_nonce(128, key128) end, tasks: 1],
  "encrypted_nonce(128) multi" => [
    fn -> NoNoncense.encrypted_nonce(128, key128) end,
    tasks: tasks
  ],
  "sortable_nonce(64) single" => [fn -> NoNoncense.sortable_nonce(64) end, tasks: 1],
  "sortable_nonce(64) multi" => [fn -> NoNoncense.sortable_nonce(64) end, tasks: tasks],
  "sortable_nonce(96) single" => [fn -> NoNoncense.sortable_nonce(96) end, tasks: 1],
  "sortable_nonce(96) multi" => [fn -> NoNoncense.sortable_nonce(96) end, tasks: tasks],
  "sortable_nonce(128) single" => [fn -> NoNoncense.sortable_nonce(128) end, tasks: 1],
  "sortable_nonce(128) multi" => [fn -> NoNoncense.sortable_nonce(128) end, tasks: tasks]
}
|> Benchmark.bench_many()
|> Benchmark.format_results()
|> IO.puts()
