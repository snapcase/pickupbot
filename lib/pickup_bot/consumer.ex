defmodule PickupBot.Consumer do
  @behaviour Nostrum.Consumer

  require Logger

  alias Nostrum.Api.Message

  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    case msg.content do
      "ping!" ->
        Message.create(msg.channel_id, "I copy and pasted this code")

      _ ->
        :ignore
    end
  end

  def handle_event(_), do: :ok
end
