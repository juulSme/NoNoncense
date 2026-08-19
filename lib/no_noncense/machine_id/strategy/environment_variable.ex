defmodule NoNoncense.MachineId.Strategy.EnvironmentVariable do
  @moduledoc """
  Strategy to acquire the machine ID from the last digits in an environment variable value.
  Useful for using Kubernetes StatefulSets for determining the machine ID.

  A StatefulSet gives each pod a stable, zero-based ordinal in its name, such as
  `nonce-worker-0` and `nonce-worker-1`. Expose the pod name through the Downward API:

  ```yaml
  env:
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
  ```

  Then configure the strategy when starting `NoNoncense.MachineId`:

      children = [
        {NoNoncense.MachineId,
         strategy: NoNoncense.MachineId.Strategy.EnvironmentVariable,
         strategy_opts: [variable_name: "POD_NAME"],
         instances: [[base_key: System.fetch_env!("BASE_KEY")]]}
      ]

  The default `ConflictGuard` detects duplicate IDs among connected Erlang nodes.

  This strategy is suitable only when every nonce-generating pod has a globally unique numeric
  suffix. A single StatefulSet provides that property, but separate StatefulSets reuse their
  ordinals. Ensure the resulting IDs remain in the supported range of 0..511.

  > #### Be careful with other orchestrators {: .warning}
  >
  > Do not assume a task or allocation index from an orchestrator such as Nomad is an exclusive,
  > globally unique machine ID. During rolling deployments, an old and replacement allocation may
  > overlap, or a deployment may reuse an index. Use this strategy only when the orchestrator
  > guarantees unique IDs for all concurrently running instances; otherwise use a coordinating
  > lease strategy.
  """
  use NoNoncense.MachineId.Strategy

  @type opt :: {:variable_name, String.t()}

  @impl true
  def acquire(lease_duration, opts) do
    env_var = Keyword.fetch!(opts, :variable_name)

    with {_, {:ok, value}} <- {:env_var, System.fetch_env(env_var)},
         {_, [digits], _} <- {:extract, Regex.run(~r/\d+$/, value), value} do
      {id, ""} = Integer.parse(digits)
      {:ok, id, :static, lease_duration}
    else
      {:env_var, _} -> {:error, "env var #{env_var} not found"}
      {:extract, _, value} -> {:error, "could not parse #{env_var}=#{value}"}
    end
  end
end
