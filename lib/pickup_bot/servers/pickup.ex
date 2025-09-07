defmodule PickupBot.Servers.Pickup do
  @moduledoc """
  GenServer for TDM pickup
  """
  use GenServer

  require Logger

  alias PickupBot.Servers.ActivityTracker
  alias Nostrum.Api.Message

  @maxplayers 8

  @channel 1_412_476_637_479_436_288

  # Client

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def add(player_id) do
    GenServer.call(__MODULE__, {:add, player_id})
  end

  def remove(player_id) do
    GenServer.call(__MODULE__, {:remove, player_id})
  end

  def map(name) do
    GenServer.call(__MODULE__, {:map, name})
  end

  def reset, do: GenServer.call(__MODULE__, :reset)
  def test, do: for(i <- 1..7, do: PickupBot.Servers.Pickup.add(i))

  # Server (callbacks)

  def init(_arg) do
    {:ok,
     %{
       players: MapSet.new(),
       announce_timer: nil,
       afk_timer: nil,
       paused: false,
       map: nil
     }}
  end

  def handle_call({:add, player_id}, _from, state) do
    # Ignore new signups if we're in a pending state
    if MapSet.size(state.players) >= @maxplayers do
      {:reply, :ok, state}
    else
      new_players = MapSet.put(state.players, player_id)

      if MapSet.size(new_players) == @maxplayers do
        Logger.info("Pickup ready! Players: #{inspect(MapSet.to_list(new_players))}")

        # Send message to initiate AFK handler
        Process.send_after(self(), {:start_afk_check, 0}, 0)

        # Do NOT announce player count when reaching maxplayers
        cancel_timer(state.announce_timer)

        {:reply, :ok, %{state | players: new_players}}
      else
        # Only announce if player count actually changed and not at maxplayers
        updated_state =
          if MapSet.size(new_players) != MapSet.size(state.players) do
            cancel_timer(state.announce_timer)

            timer_ref =
              Process.send_after(
                self(),
                {:announce_player_count, MapSet.size(new_players), :up},
                500
              )

            Map.put(state, :announce_timer, timer_ref)
          else
            state
          end

        {:reply, :ok, %{updated_state | players: new_players}}
      end
    end
  end

  def handle_call({:remove, player_id}, _from, state) do
    if state.paused do
      Logger.info("Ignoring removal of player #{player_id} while paused.")

      {:reply, :ok, state}
    else
      new_players = MapSet.delete(state.players, player_id)

      updated_state =
        if MapSet.size(new_players) != MapSet.size(state.players) do
          # Cancel any existing timer
          cancel_timer([state.announce_timer, state.afk_timer])

          # Schedule new announcement with 500ms delay
          timer_ref =
            Process.send_after(
              self(),
              {:announce_player_count, MapSet.size(new_players), :down},
              500
            )

          Map.put(state, :announce_timer, timer_ref)
        else
          state
        end

      {:reply, :ok, %{updated_state | players: new_players}}
    end
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | players: MapSet.new()}}
  end

  def handle_call({:map, name}, _from, state) do
    Logger.info("received map from map_vote server")

    {:reply, :ok, %{state | map: name}}
  end

  def handle_info({:announce_player_count, player_count, direction}, state) do
    # TODO: These are hardcoded to emojis on the dev bot, won't work elsewhere.
    emoji =
      case direction do
        :up -> "<:up:1412542359807332412>"
        :down -> "<:down:1412542407748227183>"
      end

    Logger.info("Player count updated: #{player_count}/#{@maxplayers}")

    Message.create(@channel, "**tdm** [ **#{player_count}** / **#{@maxplayers}**#{emoji}]")

    {:noreply, state}
  end

  def handle_info({:start_afk_check, attempt}, state) do
    if all_present?(state.players) do
      Logger.info("All players are present. AFK check complete.")

      # Spawn a dynamic map_vote GenServer and transfer control
      {:ok, map_vote_pid} =
        DynamicSupervisor.start_child(
          PickupBot.DynamicSupervisor,
          {PickupBot.Servers.MapVote,
           %{
             players: MapSet.to_list(state.players),
             pickup_pid: self(),
             channel_id: @channel
           }}
        )

      # Monitor the map_vote process, when it exits the game may start.
      Process.monitor(map_vote_pid)

      Logger.info("Started map vote process: #{inspect(map_vote_pid)}")

      # Pause any further processing of messages until MapVote completes
      {:noreply, Map.put(state, :paused, true)}
    else
      # 4 attempts * 20 seconds = 80 seconds
      if attempt < 4 do
        remaining = 80 - attempt * 20

        remaining_humanized = humanize_seconds(remaining)

        {active_players, afk_players} = split_active_afk(state.players)

        Logger.info(
          "AFK check attempt #{attempt + 1}: Not all players present. Scheduling next check. Time remaining: #{remaining_humanized}. AFK players: #{inspect(afk_players)}"
        )

        ready_players =
          active_players
          |> Enum.map(&"`#{find_username(&1)}`")
          |> Enum.join(", ")

        not_ready_players =
          afk_players
          |> Enum.map(&"<@#{&1}>")
          |> Enum.join(", ")

        msg = ~s"""
        **tdm** is about to start
        Ready players: #{ready_players}
        Please send a message to ready up: #{not_ready_players}
        **#{remaining_humanized}** left until the pickup gets aborted.
        """

        Message.create(@channel, msg)

        timer_ref = Process.send_after(self(), {:start_afk_check, attempt + 1}, 20_000)
        {:noreply, %{state | afk_timer: timer_ref}}
      else
        Logger.info("AFK check timed out after 80 seconds.")

        # Remove AFK players and reset if not enough players remain
        {active_players, afk_players} = split_active_afk(state.players)
        new_players = MapSet.new(active_players)

        Logger.info("Removing AFK players: #{inspect(afk_players)}")

        Message.create(@channel, "**tdm** aborted because players are missing.")

        timer_ref =
          Process.send_after(
            self(),
            {:announce_player_count, MapSet.size(new_players), :down},
            500
          )

        {:noreply, %{state | players: new_players, announce_timer: timer_ref}}
      end
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.info("MapVote process exited with reason: #{reason}, resuming normal operation.")

    # TODO: temporary random output for team assignment
    {team_red, team_blue} =
      state.players
      |> MapSet.to_list()
      |> Enum.shuffle()
      |> Enum.split(4)

    msg = ~s"""
    **tdm** pickup started

    Team Red
    #{Enum.map_join(team_red, ", ", &"<@#{&1}>")}
    Team Blue
    #{Enum.map_join(team_blue, ", ", &"<@#{&1}>")}

    Map: **#{state.map}**
    IP: **de.snapcase.net:27963** Password: **pickup**
    """

    Message.create(@channel, msg)

    # Reset state to allow new signups
    {:noreply, %{state | paused: false, players: MapSet.new()}}
  end

  defp find_username(id) do
    case Nostrum.Cache.UserCache.get(id) do
      {:ok, user} ->
        user.username

      {:error, :user_not_found} ->
        "Unknown User"
    end
  end

  defp all_present?(players) do
    players = ActivityTracker.get_timestamps(players)

    Enum.all?(players, &active_5m?/1)
  end

  defp active_5m?({_player_id, timestamp}) do
    DateTime.diff(DateTime.utc_now(), timestamp, :second) < 300
  end

  defp humanize_seconds(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)

    cond do
      minutes > 0 and secs > 0 -> "#{minutes} minute and #{secs} seconds"
      minutes > 0 -> "#{minutes} minute"
      true -> "#{secs} seconds"
    end
  end

  defp cancel_timer(timer_ref) when is_list(timer_ref) do
    Enum.each(timer_ref, &cancel_timer/1)
  end

  defp cancel_timer(timer_ref) do
    if timer_ref, do: Process.cancel_timer(timer_ref)
  end

  defp split_active_afk(players) do
    timestamps =
      players
      |> MapSet.to_list()
      |> PickupBot.Servers.ActivityTracker.get_timestamps()

    {active, afk} = Enum.split_with(timestamps, &active_5m?/1)

    {
      Enum.map(active, fn {player_id, _} -> player_id end),
      Enum.map(afk, fn {player_id, _} -> player_id end)
    }
  end
end
