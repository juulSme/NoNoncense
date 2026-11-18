defmodule NoNoncense.MachineId.Strategy.Shared do
  @moduledoc false

  @doc """
  Keep the first three elements in order, and shuffle the rest lazily.
  Returns a stream of elements; the shuffling happens when the fourth element is accessed.
  Used to attempt in-order acquisition of IDs, but with reduced raciness in high-contention situations.
  Passes through lists of 3 or less elements.

  ## Examples

      iex> Shared.lazy_shuffle_after_3([])
      []

      iex> Shared.lazy_shuffle_after_3([1, 2, 3]) |> Enum.to_list()
      [1, 2, 3]

      iex> Shared.lazy_shuffle_after_3([1, 2, 3, 4]) |> Enum.to_list()
      [1, 2, 3, 4]

      iex> [1, 2, 3 | sorted_tail] = all = Enum.to_list(1..1000)
      iex> [1, 2, 3 | tail] = Shared.lazy_shuffle_after_3(all) |> Enum.to_list()
      iex> sorted_tail == tail
      false
      iex> sorted_tail == Enum.sort(tail)
      true
  """
  @spec lazy_shuffle_after_3(list) :: Enumerable.t()
  def lazy_shuffle_after_3(list)

  # there must be >=2 elements to shuffle, so the list must have >=5 elements
  def lazy_shuffle_after_3([a, b, c | [_d, _e | _] = tail]) do
    lazy_shuffled = Stream.flat_map([:trigger], fn _ -> shuffle_list(tail) end)
    Stream.concat([a, b, c], lazy_shuffled)
  end

  def lazy_shuffle_after_3(short_list), do: short_list

  if function_exported?(:rand, :shuffle, 1) do
    defp shuffle_list(list), do: :rand.shuffle(list)
  else
    defp shuffle_list(list), do: Enum.shuffle(list)
  end

  def now(opts), do: now_unix(opts) |> DateTime.from_unix!(:millisecond)
  def now_unix(opts), do: :erlang.monotonic_time(:millisecond) + time_offset(opts)
  def time_offset(opts), do: Keyword.fetch!(opts, :time_offset)
end
