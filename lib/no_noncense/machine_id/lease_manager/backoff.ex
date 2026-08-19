defmodule NoNoncense.MachineId.LeaseManager.Backoff do
  @moduledoc false

  @one_day 24 * 60 * 60 * 1000

  @doc "Exponential backoff (with jitter) for `attempt`, in ms, capped at `limit` OR 24 hours. Attempt `0` means no delay."
  @spec delay(non_neg_integer(), pos_integer(), pos_integer() | :infinity) :: non_neg_integer()
  def delay(attempt, base, limit)
  def delay(0, _base, _limit), do: 0

  def delay(attempt, base, limit) do
    # exponential backoff: 1,2,4,8 x base ms delay + jitter to prevent thundering herd
    floor(base * 2 ** (attempt - 1) + :rand.uniform(base)) |> min(limit) |> min(@one_day)
  end
end
