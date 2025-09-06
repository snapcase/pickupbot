defmodule PickupBot.Servers.MessageServer do
  @moduledoc """
  The purpose of this server is to act as an outgoing message handler for the bot.
  Primary function is to clean up old messages from the MapVote server.
  """
  use GenServer

  alias Nostrum.Api.Message

  require Logger

  # Client

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def create(channel_id, content) do
    GenServer.call(__MODULE__, {:create, channel_id, content})
  end

  def delete(channel_id, msg_id) do
    GenServer.cast(__MODULE__, {:delete, channel_id, msg_id})
  end

  # Server (callbacks)

  @impl true
  def init(_args) do
    Logger.info("Starting MessageServer")
    {:ok, %{messages: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:create, channel_id, content}, {from_pid, _ref}, state) do
    Logger.info("Sending message to channel #{channel_id}")

    # Monitor the calling process if not already monitored
    monitors = state.monitors
    messages = state.messages

    {monitors, _monitor_ref} =
      case Map.has_key?(monitors, from_pid) do
        true ->
          Logger.debug("Already monitoring #{inspect(from_pid)}")
          {monitors, monitors[from_pid]}

        false ->
          Logger.debug("Starting monitoring for #{inspect(from_pid)}")

          ref = Process.monitor(from_pid)
          {Map.put(monitors, from_pid, ref), ref}
      end

    Logger.info("sending discord message on behalf of #{inspect(from_pid)}")

    case Message.create(channel_id, content) do
      {:ok, msg} ->
        user_msgs = Map.get(messages, from_pid, [])
        new_messages = Map.put(messages, from_pid, [msg | user_msgs])
        {:reply, {:ok, msg}, %{state | messages: new_messages, monitors: monitors}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:delete, channel_id, msg_id}, state) do
    Logger.info("Deleting message with id: #{msg_id} from channel: #{channel_id}")

    Message.delete(channel_id, msg_id)

    # Find and remove the message from the state
    messages =
      Map.update(state.messages, self(), [], fn msgs ->
        Enum.reject(msgs, fn msg -> msg.id == msg_id and msg.channel_id == channel_id end)
      end)

    {:noreply, %{state | messages: messages}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Find and print message IDs for the shutting down server
    messages = Map.get(state.messages, pid, [])

    Enum.each(messages, fn msg ->
      Logger.info("Cleaning up message with id: #{msg.id}")
      Message.delete(msg.channel_id, msg.id)
    end)

    # Remove monitoring reference and messages for this pid
    new_monitors = Map.delete(state.monitors, pid)
    new_messages = Map.delete(state.messages, pid)

    {:noreply, %{state | monitors: new_monitors, messages: new_messages}}
  end
end
