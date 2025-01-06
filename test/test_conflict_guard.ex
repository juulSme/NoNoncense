children = [
  {NoNoncense.MachineId.ConflictGuard, [machine_id: 0]}
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

Process.sleep(10000)
