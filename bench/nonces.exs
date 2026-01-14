# with a long-ago epoch, we force a worst-case scenario with bigger-number arithmetic
NoNoncense.init(
  machine_id: 0,
  epoch: DateTime.to_unix(~U[1900-01-01T10:00:00Z], :millisecond),
  base_key: :crypto.strong_rand_bytes(32)
)

NoNoncense.init(
  name: :speck,
  machine_id: 0,
  epoch: DateTime.to_unix(~U[1900-01-01T10:00:00Z], :millisecond),
  base_key: :crypto.strong_rand_bytes(32),
  cipher64: :speck,
  cipher96: :speck
)

NoNoncense.init(
  name: :des3,
  machine_id: 0,
  epoch: DateTime.to_unix(~U[1900-01-01T10:00:00Z], :millisecond),
  base_key: :crypto.strong_rand_bytes(32),
  cipher64: :des3,
  cipher96: :des3
)

# artifially set back the clock, so that 64-bit nonces don't hit their time-based rate limit
{a, init_at, c, d, e} = :persistent_term.get(NoNoncense)
ten_days = 10 * 24 * 60 * 60 * 1000
:persistent_term.put(NoNoncense, {a, init_at - ten_days, c, d, e})

Process.sleep(1000)

%{
  "strong_rand_bytes(8)             1 task" => [
    fn -> :crypto.strong_rand_bytes(8) end,
    tasks: 1
  ],
  "strong_rand_bytes(8)             4 tasks" => [
    fn -> :crypto.strong_rand_bytes(8) end,
    tasks: 4
  ],
  "strong_rand_bytes(8)            16 tasks" => [
    fn -> :crypto.strong_rand_bytes(8) end,
    tasks: 16
  ],
  "strong_rand_bytes(12)            1 task" => [
    fn -> :crypto.strong_rand_bytes(12) end,
    tasks: 1
  ],
  "strong_rand_bytes(12)            4 tasks" => [
    fn -> :crypto.strong_rand_bytes(12) end,
    tasks: 4
  ],
  "strong_rand_bytes(12)           16 tasks" => [
    fn -> :crypto.strong_rand_bytes(12) end,
    tasks: 16
  ],
  "strong_rand_bytes(16)            1 task" => [
    fn -> :crypto.strong_rand_bytes(16) end,
    tasks: 1
  ],
  "strong_rand_bytes(16)            4 tasks" => [
    fn -> :crypto.strong_rand_bytes(16) end,
    tasks: 4
  ],
  "strong_rand_bytes(16)           16 tasks" => [
    fn -> :crypto.strong_rand_bytes(16) end,
    tasks: 16
  ],
  "nonce(64)                        1 task" => [
    fn -> NoNoncense.nonce(64) end,
    tasks: 1
  ],
  "nonce(64)                        4 tasks" => [
    fn -> NoNoncense.nonce(64) end,
    tasks: 4
  ],
  "nonce(64)                       16 tasks" => [
    fn -> NoNoncense.nonce(64) end,
    tasks: 16
  ],
  "nonce(96)                        1 task" => [
    fn -> NoNoncense.nonce(96) end,
    tasks: 1
  ],
  "nonce(96)                        4 tasks" => [
    fn -> NoNoncense.nonce(96) end,
    tasks: 4
  ],
  "nonce(96)                       16 tasks" => [
    fn -> NoNoncense.nonce(96) end,
    tasks: 16
  ],
  "nonce(128)                       1 task" => [
    fn -> NoNoncense.nonce(128) end,
    tasks: 1
  ],
  "nonce(128)                       4 tasks" => [
    fn -> NoNoncense.nonce(128) end,
    tasks: 4
  ],
  "nonce(128)                      16 tasks" => [
    fn -> NoNoncense.nonce(128) end,
    tasks: 16
  ],
  "encrypted_nonce(64) Blowfish     1 task" => [
    fn -> NoNoncense.encrypted_nonce(64) end,
    tasks: 1
  ],
  "encrypted_nonce(64) Blowfish     4 tasks" => [
    fn -> NoNoncense.encrypted_nonce(64) end,
    tasks: 4
  ],
  "encrypted_nonce(64) Blowfish    16 tasks" => [
    fn -> NoNoncense.encrypted_nonce(64) end,
    tasks: 16
  ],
  "encrypted_nonce(96) Blowfish     1 task" => [
    fn -> NoNoncense.encrypted_nonce(96) end,
    tasks: 1
  ],
  "encrypted_nonce(96) Blowfish     4 tasks" => [
    fn -> NoNoncense.encrypted_nonce(96) end,
    tasks: 4
  ],
  "encrypted_nonce(96) Blowfish    16 tasks" => [
    fn -> NoNoncense.encrypted_nonce(96) end,
    tasks: 16
  ],
  "encrypted_nonce(64) Speck        1 task" => [
    fn -> NoNoncense.encrypted_nonce(:speck, 64) end,
    tasks: 1
  ],
  "encrypted_nonce(64) Speck        4 tasks" => [
    fn -> NoNoncense.encrypted_nonce(:speck, 64) end,
    tasks: 4
  ],
  "encrypted_nonce(64) Speck       16 tasks" => [
    fn -> NoNoncense.encrypted_nonce(:speck, 64) end,
    tasks: 16
  ],
  "encrypted_nonce(96) Speck        1 task" => [
    fn -> NoNoncense.encrypted_nonce(:speck, 96) end,
    tasks: 1
  ],
  "encrypted_nonce(96) Speck        4 tasks" => [
    fn -> NoNoncense.encrypted_nonce(:speck, 96) end,
    tasks: 4
  ],
  "encrypted_nonce(96) Speck       16 tasks" => [
    fn -> NoNoncense.encrypted_nonce(:speck, 96) end,
    tasks: 16
  ],
  "encrypted_nonce(64) 3DES         1 task" => [
    fn -> NoNoncense.encrypted_nonce(:des3, 64) end,
    tasks: 1
  ],
  "encrypted_nonce(64) 3DES         4 tasks" => [
    fn -> NoNoncense.encrypted_nonce(:des3, 64) end,
    tasks: 4
  ],
  "encrypted_nonce(64) 3DES        16 tasks" => [
    fn -> NoNoncense.encrypted_nonce(:des3, 64) end,
    tasks: 16
  ],
  "encrypted_nonce(96) 3DES         1 task" => [
    fn -> NoNoncense.encrypted_nonce(:des3, 96) end,
    tasks: 1
  ],
  "encrypted_nonce(96) 3DES         4 tasks" => [
    fn -> NoNoncense.encrypted_nonce(:des3, 96) end,
    tasks: 4
  ],
  "encrypted_nonce(96) 3DES        16 tasks" => [
    fn -> NoNoncense.encrypted_nonce(:des3, 96) end,
    tasks: 16
  ],
  "encrypted_nonce(128) AES         1 task" => [
    fn -> NoNoncense.encrypted_nonce(128) end,
    tasks: 1
  ],
  "encrypted_nonce(128) AES         4 tasks" => [
    fn -> NoNoncense.encrypted_nonce(128) end,
    tasks: 4
  ],
  "encrypted_nonce(128) AES        16 tasks" => [
    fn -> NoNoncense.encrypted_nonce(128) end,
    tasks: 16
  ],
  "sortable_nonce(64)               1 task" => [
    fn -> NoNoncense.sortable_nonce(64) end,
    tasks: 1
  ],
  "sortable_nonce(64)               4 tasks" => [
    fn -> NoNoncense.sortable_nonce(64) end,
    tasks: 4
  ],
  "sortable_nonce(64)              16 tasks" => [
    fn -> NoNoncense.sortable_nonce(64) end,
    tasks: 16
  ],
  "sortable_nonce(96)               1 task" => [
    fn -> NoNoncense.sortable_nonce(96) end,
    tasks: 1
  ],
  "sortable_nonce(96)               4 tasks" => [
    fn -> NoNoncense.sortable_nonce(96) end,
    tasks: 4
  ],
  "sortable_nonce(96)              16 tasks" => [
    fn -> NoNoncense.sortable_nonce(96) end,
    tasks: 16
  ],
  "sortable_nonce(128)              1 task" => [
    fn -> NoNoncense.sortable_nonce(128) end,
    tasks: 1
  ],
  "sortable_nonce(128)              4 tasks" => [
    fn -> NoNoncense.sortable_nonce(128) end,
    tasks: 4
  ],
  "sortable_nonce(128)             16 tasks" => [
    fn -> NoNoncense.sortable_nonce(128) end,
    tasks: 16
  ]
}
|> Benchmark.bench_many()
|> Benchmark.format_results()
|> IO.puts()
