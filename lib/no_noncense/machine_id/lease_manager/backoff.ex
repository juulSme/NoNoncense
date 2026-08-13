defmodule NoNoncense.MachineId.LeaseManager.Backoff do
  @moduledoc false

  @doc "Exponential backoff (with jitter) for `attempt`, in ms, capped at `limit`. Attempt `0` means no delay."
  @spec delay(non_neg_integer(), pos_integer(), pos_integer()) :: non_neg_integer()
  def delay(attempt, base, limit)
  def delay(0, _base, _limit), do: 0

  def delay(attempt, base, limit) do
    # exponential backoff: 1,2,4,8 x base ms delay + jitter to prevent thundering herd
    min(limit, floor(base * 2 ** (attempt - 1) + :rand.uniform(base)))
  end
end
