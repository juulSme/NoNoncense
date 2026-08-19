defmodule NoNoncense.MachineId.LeaseManager.Timers do
  @moduledoc false

  @doc "Schedules `msg` after `after_ms`, tagged with the state's current generation."
  @spec schedule(map(), atom(), non_neg_integer()) :: map()
  def schedule(state = %{timers: timers, generation: gen}, msg, after_ms) do
    ref = Process.send_after(self(), {msg, gen}, after_ms)
    %{state | timers: Map.put(timers, msg, ref)}
  end

  @doc "Cancels all pending timers and advances the generation, invalidating any in-flight messages."
  @spec clear(map()) :: map()
  def clear(state) do
    Enum.each(state.timers, fn {_msg, ref} -> Process.cancel_timer(ref) end)
    %{state | timers: %{}, generation: state.generation + 1}
  end
end
