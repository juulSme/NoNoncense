defmodule NoNoncense.MachineId do
  alias NoNoncense.MachineId.{ConflictGuard, ExpirationManager, LeaseCache, LeaseManager}

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
  background. `LeaseManager` directly initializes the configured `NoNoncense` factories after
  acquiring a lease, disables them when that lease is lost, and initializes them again after a
  successful reacquisition.

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

  Startup blocks until the initial lease is acquired. Once started, the lease renews
  automatically. If a lease is confirmed lost or reaches its local expiry deadline, the factories
  are disabled, `:on_lease_lost` is called with the reason, and the manager keeps trying to
  acquire a lease. The callback may notify, halt the node, or take any other application-specific
  action.

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
  machine ID conflicts. It works with every strategy but is most useful with strategies that don't
  have a central lease coordinator. It requires distributed Erlang; without connected nodes, it
  has no peers to compare.

  ## Options

  #{@options_docs}
  """
  use Supervisor

  @type opt ::
          {:name, module()}
          | {:strategy, module()}
          | {:strategy_opts, keyword()}
          | {:lease_duration, pos_integer()}
          | {:renew_interval, pos_integer()}
          | {:acquire_timeout, pos_integer() | :infinity}
          | {:on_lease_lost, (term() -> any())}
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

  @impl true
  def init(opts) do
    name = opts[:name] || __MODULE__
    instances = Keyword.fetch!(opts, :instances)
    instances = Enum.map(instances, &Keyword.put_new(&1, :name, NoNoncense))

    # LeaseCache
    cache_name = Module.concat(name, :LeaseCache)
    cache_opts = [name: cache_name]
    lease_cache = {LeaseCache, cache_opts}

    # ExpirationManager
    expiration_manager_name = Module.concat(name, :ExpirationManager)

    expiration_manager =
      {ExpirationManager,
       [
         name: expiration_manager_name,
         lease_cache: cache_name,
         lease_manager: Module.concat(name, :LeaseManager),
         instances: instances
       ]}

    # LeaseManager
    lm_name = Module.concat(name, :LeaseManager)

    lm_opts =
      opts
      |> Keyword.drop([:enable_conflict_guard?])
      |> Keyword.merge(
        name: lm_name,
        instances: instances,
        lease_cache: cache_name,
        expiration_manager: expiration_manager_name
      )

    lease_manager = {LeaseManager, lm_opts}

    # ConflictGuard
    enable_cg? = Keyword.get(opts, :enable_conflict_guard?, true)
    cg_name = Module.concat(name, :ConflictGuard)
    # ConflictGuard should not crash if LeaseManager is down
    get_machine_id = safe_caller(fn -> LeaseManager.machine_id(lm_name) end, nil)
    on_conflict = safe_caller(fn -> LeaseManager.lease_lost(lm_name, :conflict_guard) end, :ok)
    cg_opts = [name: cg_name, on_conflict: on_conflict, machine_id: get_machine_id]
    conflict_guard = if enable_cg?, do: {ConflictGuard, cg_opts}, else: nil

    # Supervisor
    [lease_cache, expiration_manager, lease_manager, conflict_guard]
    |> Enum.reject(&is_nil/1)
    |> Supervisor.init(strategy: :rest_for_one)
  end

  # create a function that can call a genserver that is down without crashing
  defp safe_caller(fun, result_if_down) do
    fn ->
      try do
        fun.()
      catch
        :exit, {:noproc, _} -> result_if_down
      end
    end
  end
end
