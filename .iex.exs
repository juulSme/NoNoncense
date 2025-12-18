alias NoNoncense.MachineId
alias MachineId.ConflictGuard

NoNoncense.init(
  machine_id: 0,
  base_key: :crypto.strong_rand_bytes(32),
  cipher64: :speck,
  cipher96: :speck
)

NoNoncense.init(name: :default, machine_id: 0, base_key: :crypto.strong_rand_bytes(32))
