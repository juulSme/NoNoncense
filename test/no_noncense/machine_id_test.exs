defmodule NoNoncense.MachineIdTest do
  use ExUnit.Case, async: true
  alias NoNoncense.MachineId

  describe "id!/1" do
    test "the ordering of your node list has no influence" do
      node_list = [:a, "1.1.1.1", :b, :nonode@nohost]
      assert 2 == MachineId.id!(node_list: node_list)
    end
  end

  doctest MachineId, except: [host_identifiers: 0]
end
