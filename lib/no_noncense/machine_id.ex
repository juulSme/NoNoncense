defmodule NoNoncense.MachineId do
  alias NoNoncense.MachineId.{ConflictGuard, LeaseStore, LeaseManager}

  @options_docs """
    * `:name` - registered name of this supervisor (default `#{inspect(__MODULE__)}`)
    * `:instances` (required) - list of per-instance option keywords, each accepting the same options as `NoNoncense.init/1` (`:base_key`, `:epoch`, etc.). Note that names must be unique for each factory, the default name is `NoNoncense`.
    * `:enable_conflict_guard?` - whether to start a `NoNoncense.MachineId.ConflictGuard` as a supervised child (default `true`)
  #{LeaseManager.options_docs()}
  """

  @moduledoc """
  Supervised machine ID lease management for `NoNoncense`.

  Every node generating nonces needs a unique machine ID (0–511). `NoNoncense.MachineId`
  acquires and holds that ID through a pluggable strategy, automatically renewing it in the
  background. Configured `NoNoncense` factories are enabled when a lease is accepted and disabled
  when it is lost.

  ## Usage

  Add it to your supervision tree in the appropriate place (in this case, after your Repo):

      children = [
        ...
        MyApp.Repo,
        {NoNoncense.MachineId,
         strategy: NoNoncense.MachineId.Strategy.SqlLease,
         strategy_opts: [repo: MyApp.Repo],
         instances: [[base_key: System.fetch_env!("BASE_KEY")]]}
      ]

  ## Strategies

  | Strategy | Infrastructure | Notes |
  |---|---|---|
  | [`HostIdentifiers`](./NoNoncense.MachineId.Strategy.HostIdentifiers.html) | None | Derives IDs from node names/IPs; requires identical config on all nodes; no coordination |
  | [`EnvironmentVariable`](./NoNoncense.MachineId.Strategy.EnvironmentVariable.html) | Kubernetes StatefulSet | Reads pod ordinal env var; no coordination |
  | [`SqlLease`](./NoNoncense.MachineId.Strategy.SqlLease.html) | PostgreSQL or MySQL | Dynamically coordinates across nodes; requires a migration (see module doc) |
  | [`RedisLease`](./NoNoncense.MachineId.Strategy.RedisLease.html) | Redis 8+ / Valkey 9+ | Dynamically coordinates across nodes; requires [`HSETEX`](https://valkey.io/commands/hsetex/) support |

  ## Conflict Guard

  A `NoNoncense.MachineId.ConflictGuard` is started by default. Set
  `enable_conflict_guard?: false` to disable it. The guard uses Erlang node networking to detect
  machine ID conflicts when nodes connect. It works with every strategy but is most useful with
  static strategies that have no central lease coordinator. On a conflict, the newer node loses its
  lease, which disables its factories and triggers `:on_lease_lost`. It requires distributed Erlang;
  without connected nodes, it has no peers to compare.

  ## Options

  #{@options_docs}

  ## Lease lifecycle

  Two supervised processes share the work. The lease manager talks to the strategy to acquire,
  renew, and release leases. The lease store holds the current lease and enforces its local expiry,
  so it keeps working even when a strategy callback blocks or the manager restarts.

  Startup blocks until a lease is acquired or `:acquire_timeout` is reached. Acquisition failures
  are retried with backoff; a strategy granting an invalid machine ID or a TTL below 30 seconds
  fails startup immediately.
  Factories are enabled only after a lease is accepted.

  The strategy may grant a TTL different from the requested `:lease_duration`. Local expiry is
  calculated from the start of the acquire or renew call, using the granted TTL less a 10-second
  safety margin. Renewal is scheduled one safety margin before the earlier of the configured
  `:renew_interval` and local expiry, or immediately if that time has already passed. A lease is
  rejected if its TTL is below 30 seconds or the call has exhausted its local validity window;
  release is attempted on a best-effort basis.

  Acquisition, renewal, and release run in isolated tasks bounded by `:callback_timeout`. During
  startup, the remaining `:acquire_timeout` also bounds these calls. A timed-out call may still
  have taken effect in the coordinator; see `NoNoncense.MachineId.Strategy` for the resulting
  requirements on strategy implementations.

  ## Lease loss and recovery

  A transient or ambiguous renewal failure is retried with backoff while the lease remains locally
  valid. A confirmed loss or local expiry disables the factories and triggers `:on_lease_lost` with
  the reason. Expiry is enforced independently of strategy callbacks, although timer latency can
  delay factory shutdown briefly after the local deadline. Notifications are best-effort if the
  lease manager is unavailable.

  Coordinating strategies retry acquisition after a loss; deterministic strategies do not, since
  they would return the same ID. A successful reacquisition reinitializes the factories. The
  `:on_lease_lost` callback can notify, halt the node, or take another application-specific action;
  it runs in the lease manager, so a blocking callback delays recovery.

  A lease can survive a lease manager crash and be renewed on restart. On graceful shutdown,
  factories are disabled and release of any still-valid lease is attempted on a best-effort basis.
  """
  use Supervisor

  @type lease_opt ::
          {:strategy, module()}
          | {:strategy_opts, keyword()}
          | {:lease_duration, pos_integer()}
          | {:renew_interval, pos_integer()}
          | {:acquire_timeout, pos_integer() | :infinity}
          | {:callback_timeout, pos_integer()}
          | {:on_lease_lost, (term() -> any())}

  @type opt ::
          lease_opt()
          | {:name, module()}
          | {:instances, [NoNoncense.init_opt()]}
          | {:enable_conflict_guard?, boolean()}

  @doc """
  Starts the machine ID supervisor, blocking until the initial lease is acquired.

  ## Options

  #{@options_docs}
  """
  @spec start_link([opt()]) :: Supervisor.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  # Sets opts[:name] as the id.
  def child_spec(opts), do: Supervisor.child_spec(super(opts), id: opts[:name] || __MODULE__)

  @impl true
  def init(opts) do
    name = opts[:name] || __MODULE__
    instances = Keyword.fetch!(opts, :instances)
    instances = Enum.map(instances, &Keyword.put_new(&1, :name, NoNoncense))

    # LeaseStore
    store_name = Module.concat(name, :LeaseStore)
    lm_name = Module.concat(name, :LeaseManager)
    store_opts = [name: store_name, lease_manager: lm_name, instances: instances]
    lease_store = {LeaseStore, store_opts}

    task_supervisor_name = Module.concat(name, :TaskSupervisor)
    task_supervisor = {Task.Supervisor, name: task_supervisor_name}

    # LeaseManager
    lm_opts =
      opts
      |> Keyword.drop([:enable_conflict_guard?, :instances])
      |> Keyword.merge(
        name: lm_name,
        lease_store: store_name,
        task_supervisor: task_supervisor_name
      )

    lease_manager = {LeaseManager, lm_opts}

    # ConflictGuard talks to the store, which never blocks on strategy callbacks
    enable_cg? = Keyword.get(opts, :enable_conflict_guard?, true)
    cg_name = Module.concat(name, :ConflictGuard)

    cg_opts = [
      name: cg_name,
      on_conflict: fn -> LeaseStore.lose(store_name, :conflict_guard) end,
      machine_id: fn -> LeaseStore.machine_id(store_name) end
    ]

    conflict_guard = if enable_cg?, do: {ConflictGuard, cg_opts}, else: nil

    # Supervisor
    [lease_store, task_supervisor, lease_manager, conflict_guard]
    |> Enum.reject(&is_nil/1)
    |> Supervisor.init(strategy: :rest_for_one)
  end
end
