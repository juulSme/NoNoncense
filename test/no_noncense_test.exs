defmodule NoNoncenseTest do
  use ExUnit.Case
  doctest NoNoncense

  test "greets the world" do
    assert NoNoncense.hello() == :world
  end
end
