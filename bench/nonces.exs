NoNoncense.init(machine_id: 0)
IO.puts("Sleeping for 10 seconds to allow some timestamp space to build")
Process.sleep(10000)
key192 = :crypto.strong_rand_bytes(24)
key256 = :crypto.strong_rand_bytes(32)

Benchee.run(
  %{
    "random 64" => fn -> :crypto.strong_rand_bytes(8) end,
    "random 96" => fn -> :crypto.strong_rand_bytes(12) end,
    "random 128" => fn -> :crypto.strong_rand_bytes(16) end,
    "encrypted_nonce(64)" => fn -> NoNoncense.encrypted_nonce(64, key192) end,
    "encrypted_nonce(96)" => fn -> NoNoncense.encrypted_nonce(96, key192) end,
    "encrypted_nonce(128)" => fn -> NoNoncense.encrypted_nonce(128, key256) end,
    "nonce(64)" => fn -> NoNoncense.nonce(64) end,
    "nonce(96)" => fn -> NoNoncense.nonce(96) end,
    "nonce(128)" => fn -> NoNoncense.nonce(128) end
  },
  time: 1,
  parallel: 1
)
