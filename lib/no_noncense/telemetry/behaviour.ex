defmodule NoNoncense.Telemetry.Behaviour do
  @moduledoc false

  # compile-time contract to prevent mismatches between dummy and real implementation

  @callback lease_operation(
              fun :: (-> term()),
              operation :: :acquire | :renew | :release,
              metadata :: map()
            ) :: term()
  @callback lease_retry(
              operation :: :acquire | :renew,
              attempt :: pos_integer(),
              delay_ms :: non_neg_integer(),
              reason :: term()
            ) :: :ok
  @callback lease_lost(reason :: term(), remaining_ttl_ms :: non_neg_integer()) :: :ok
  @callback peer_checked(outcome :: :conflict | :no_local_id | :match) :: :ok
  @callback conflict(resolution :: :local_node | :remote_node) :: :ok
end
