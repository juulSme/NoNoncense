defmodule NoNoncense.BitwiseTest do
  use ExUnit.Case, async: true
  use NoNoncense.Constants

  import Bitwise

  test "extracts 64-bit counter timestamp and count like binary matching" do
    for <<atomic_count::64>> <- [
          <<0::@non_count_bits_64, 0::@count_bits_64>>,
          <<0::@non_count_bits_64, @count_mask_64::@count_bits_64>>,
          <<1::@non_count_bits_64, 0::@count_bits_64>>,
          <<Integer.pow(2, @non_count_bits_64) - 1::@non_count_bits_64,
            @count_mask_64::@count_bits_64>>
        ] do
      <<timestamp::@non_count_bits_64, count::@count_bits_64>> = <<atomic_count::64>>

      assert {atomic_count >>> @count_bits_64, atomic_count &&& @count_mask_64} ==
               {timestamp, count}
    end
  end

  test "extracts 96-bit counter cycle and count like binary matching" do
    for <<atomic_count::64>> <- [
          <<0::@atomic_cycle_bits_96, 0::@count_bits_96>>,
          <<0::@atomic_cycle_bits_96, @count_mask_96::@count_bits_96>>,
          <<1::@atomic_cycle_bits_96, 0::@count_bits_96>>,
          <<Integer.pow(2, @atomic_cycle_bits_96) - 1::@atomic_cycle_bits_96,
            @count_mask_96::@count_bits_96>>
        ] do
      <<cycle_n::@atomic_cycle_bits_96, count::@count_bits_96>> = <<atomic_count::64>>

      assert {atomic_count >>> @count_bits_96, atomic_count &&& @count_mask_96} ==
               {cycle_n, count}
    end
  end

  test "extracts sortable timestamp and count like binary matching" do
    for <<ts_counter::64>> <- [
          <<0::@ts_bits, 0::@non_ts_bits_64>>,
          <<0::@ts_bits, @non_ts_mask_64::@non_ts_bits_64>>,
          <<1::@ts_bits, 0::@non_ts_bits_64>>,
          <<Integer.pow(2, @ts_bits) - 1::@ts_bits, @non_ts_mask_64::@non_ts_bits_64>>
        ] do
      <<timestamp::@ts_bits, count::@non_ts_bits_64>> = <<ts_counter::64>>

      assert {ts_counter >>> @non_ts_bits_64, ts_counter &&& @non_ts_mask_64} ==
               {timestamp, count}
    end
  end

  test "packs sortable timestamps like binary matching" do
    for timestamp <- [0, 1, Integer.pow(2, @ts_bits) - 1] do
      <<expected::64>> = <<timestamp::@ts_bits, 0::@non_ts_bits_64>>

      assert timestamp <<< @non_ts_bits_64 == expected
    end
  end
end
