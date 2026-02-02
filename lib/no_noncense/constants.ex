defmodule NoNoncense.Constants do
  @moduledoc false

  defmacro __using__(_opts \\ []) do
    quote do
      @no_noncense_epoch ~U[2025-01-01T00:00:00Z] |> DateTime.to_unix(:millisecond)

      # no of timestamp bits
      @ts_bits 42
      # no of id bits
      @id_bits 9
      # max value of machine id
      @machine_id_limit Integer.pow(2, @id_bits) - 1
      # no of non-timestamp bits in a 64-bit nonce
      @non_ts_bits_64 64 - @ts_bits
      # no of counter bits in a 64-bit nonce
      @count_bits_64 64 - @ts_bits - @id_bits
      # no of counter bits in a 96-bit nonce
      @count_bits_96 96 - @ts_bits - @id_bits
      # max value of 64-bit nonce counter
      @max_count_64 Integer.pow(2, @count_bits_64)
      # no of cycle counter bits in the :atomics counter of a 64-bit nonce
      @atomic_cycle_bits_64 64 - @count_bits_64
      # no of cycle counter bits in the :atomics counter of a 96-bit nonce
      @atomic_cycle_bits_96 64 - @count_bits_96
      # no of padding bits in a 128-bit nonce
      @padding_bits_128 128 - @ts_bits - @id_bits - 64
      # maximum timestamp value
      @max_ts Integer.pow(2, @ts_bits)

      # atomics indexes
      @counter_idx 1
      @sortable_counter_idx 2

      # padding to extend a 64-bits encrypted nonce to 96 bits
      @zero32 <<0::32>>
    end
  end
end
