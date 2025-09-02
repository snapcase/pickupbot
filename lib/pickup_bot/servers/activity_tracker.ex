defmodule PickupBot.Servers.ActivityTracker do
  use GenServer

  require Logger

  # Client

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def track_msg(user_id) do
    GenServer.cast(__MODULE__, {:track, user_id})
  end

  def get_timestamps(user_ids) do
    GenServer.call(__MODULE__, {:get_timestamps, user_ids})
  end

  # Server (callbacks)

  def init(_arg) do
    {:ok, %{}}
  end

  def handle_cast({:track, user_id}, state) do
    now = DateTime.utc_now()

    {:noreply, Map.put(state, user_id, now)}
  end

  def handle_call({:get_timestamps, user_ids}, _from, state) do
    # Default to unix timestamp 0
    default_date = ~U[1970-01-01T00:00:00Z]

    timestamps =
      Enum.map(user_ids, fn user_id ->
        {user_id, Map.get(state, user_id, default_date)}
      end)

    {:reply, timestamps, state}
  end
end
