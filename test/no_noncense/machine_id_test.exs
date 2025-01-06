defmodule NoNoncense.MachineIdTest do
  use ExUnit.Case, async: true
  alias NoNoncense.MachineId

  describe "id!/1" do
    test "the ordering of your node list has no influence" do
      node_list = ["127.0.0.1", "8.8.8.8", "1.1.1.1"]
      assert 1 == MachineId.id!(node_list: node_list)
    end
  end

  doctest MachineId, except: [host_identifiers: 0]
end
