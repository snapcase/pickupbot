defmodule PickupBotTest do
  use ExUnit.Case
  doctest PickupBot

  test "greets the world" do
    assert PickupBot.hello() == :world
  end
end
