defmodule NoNoncense.State do
  @moduledoc false
  require Record

  @doc """
  The internal state of a NoNoncense instance as initialized by `NoNoncense.init/1`.
  """
  Record.defrecord(:state, [
    :machine_id,
    :init_at,
    :mono_epoch_offset,
    :counters_ref,
    :cipher64,
    :cipher96,
    :cipher128,
    :enc64,
    :enc96,
    :enc128,
    :dec64,
    :dec96,
    :dec128
  ])
end
