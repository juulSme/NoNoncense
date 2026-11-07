defmodule NoNoncense.MachineId.Instances do
  @moduledoc false
  import Bitwise
  import NoNoncense.State
  use NoNoncense.Constants

  @type instance_opts :: [NoNoncense.init_opt()]

  @doc """
  Initializes an instance unless it is already enabled with the leased machine ID.

  A disabled instance is initialized afresh instead of re-enabled: its counters would continue
  from timestamps that another node holding the same ID may have used in the meantime.
  """
  @spec re_init(instance_opts()) :: :ok
  def re_init(opts) do
    name = Keyword.fetch!(opts, :name)
    machine_id = Keyword.fetch!(opts, :machine_id)

    case :persistent_term.get(name, nil) do
      # same id, already enabled
      state(machine_id: ^machine_id, enabled?: true) ->
        :ok

      # uninitialized
      nil ->
        NoNoncense.init(opts)

      # any other previously initialized state
      state(init_at: init_at, mono_epoch_offset: me_offset, counters_ref: counters) ->
        # Wait past any timestamp already used or reserved by the previous state, so same-ms
        # reacquisition (including A -> B -> A transitions or 64-bit counter lookahead) cannot
        # repeat nonces.
        max_used_ts(init_at, counters) |> wait_past(me_offset)
        NoNoncense.init(opts)
    end
  end

  defp max_used_ts(init_at, counters) do
    counter64_ts = :atomics.get(counters, @counter64_idx) >>> @count_bits_64
    sortable_ts = :atomics.get(counters, @sortable_counter_idx) >>> @non_ts_bits_64
    # add_get ensures 64-bit wraparound
    cycle_96_128 = :atomics.add_get(counters, @counter96_128_idx, 1) >>> @count_bits_96
    Enum.max([init_at + cycle_96_128, counter64_ts, sortable_ts])
  end

  defp wait_past(used_ts, mono_epoch_offset) do
    epoch_now = :erlang.monotonic_time(:millisecond) + mono_epoch_offset
    if epoch_now <= used_ts, do: :timer.sleep(used_ts - epoch_now + 1)
  end

  @doc "Disables an instance so it can no longer generate nonces."
  @spec disable(instance_opts()) :: :ok
  def disable(opts) do
    name = Keyword.fetch!(opts, :name)

    case :persistent_term.get(name, nil) do
      nil -> :ok
      state(enabled?: false) -> :ok
      state -> :persistent_term.put(name, state(state, enabled?: false))
    end
  end
end
