defmodule PickupBot.Consumer do
  @behaviour Nostrum.Consumer

  require Logger

  alias PickupBot.Servers.Pickup

  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    PickupBot.Servers.ActivityTracker.track_msg(msg.author.id)

    case msg.content do
      "++" ->
        Pickup.add(msg.author.id)

      "--" ->
        Pickup.remove(msg.author.id)

      _ ->
        :ignore
    end
  end

  def handle_event(_), do: :ok
end
