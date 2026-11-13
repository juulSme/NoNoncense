defmodule NoNoncense.MachineId.Strategy.Shared do
  @moduledoc false

  @doc """
  Keep the first three elements in order, and shuffle the rest.
  Used to attempt in-order acquisition of IDs, but with reduced raciness in high-contention situations.
  Passes through lists of 3 or less elements.

  ## Examples

      iex> Shared.shuffle_after_3([])
      []

      iex> Shared.shuffle_after_3([1, 2, 3])
      [1, 2, 3]

      iex> Shared.shuffle_after_3([1, 2, 3, 4])
      [1, 2, 3, 4]

      iex> [1, 2, 3 | sorted_tail] = all = Enum.to_list(1..1000)
      iex> [1, 2, 3 | tail] = Shared.shuffle_after_3(all)
      iex> sorted_tail == tail
      false
      iex> sorted_tail == Enum.sort(tail)
      true
  """
  def shuffle_after_3(list)
  def shuffle_after_3([a, b, c | tail]), do: [a, b, c | Enum.shuffle(tail)]
  def shuffle_after_3(short_list), do: short_list

  def now(opts), do: now_unix(opts) |> DateTime.from_unix!(:millisecond)
  def now_unix(opts), do: :erlang.monotonic_time(:millisecond) + time_offset(opts)
  def time_offset(opts), do: Keyword.fetch!(opts, :time_offset)
end
