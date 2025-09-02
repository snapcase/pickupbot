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
  # @maps [
  #   "cpm21",
  #   "cpm4a",
  #   "cpm18r",
  #   "ospdm5a",
  #   "avrdm1b",
  #   "cpm27",
  #   "cpm26"
  # ]

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

  def reset, do: GenServer.call(__MODULE__, :reset)

  # Server (callbacks)

  def init(_arg) do
    {:ok,
     %{
       players: MapSet.new(),
       announce_timer: nil,
       afk_timer: nil
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
                750
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
    new_players = MapSet.delete(state.players, player_id)

    updated_state =
      if MapSet.size(new_players) != MapSet.size(state.players) do
        # Cancel any existing timer
        cancel_timer([state.announce_timer, state.afk_timer])

        # Schedule new announcement with 750ms delay
        timer_ref =
          Process.send_after(
            self(),
            {:announce_player_count, MapSet.size(new_players), :down},
            750
          )

        Map.put(state, :announce_timer, timer_ref)
      else
        state
      end

    {:reply, :ok, %{updated_state | players: new_players}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | players: MapSet.new()}}
  end

  def handle_info({:announce_player_count, player_count, direction}, state) do
    # TODO: These are hardcoded to emojis on the dev bot, won't work elsewhere.
    emoji =
      case direction do
        :up -> "<:up:1412542359807332412>"
        :down -> "<:down:1412542407748227183>"
      end

    Logger.info("Player count updated: #{player_count}/#{@maxplayers}")

    Message.create(@channel, "**TDM** [ **#{player_count}** / **#{@maxplayers}**#{emoji}]")

    {:noreply, state}
  end

  def handle_info({:start_afk_check, attempt}, state) do
    if all_present?(state.players) do
      Logger.info("All players are present. AFK check complete.")

      Process.send_after(self(), {:start_map_vote, MapSet.to_list(state.players)}, 0)

      {:noreply, state}
    else
      # 4 attempts * 20 seconds = 80 seconds
      if attempt < 4 do
        remaining = 80 - attempt * 20

        remaining_humanized = humanize_seconds(remaining)
        {_active_players, afk_players} = split_active_afk(state.players)

        Logger.info(
          "AFK check attempt #{attempt + 1}: Not all players present. Scheduling next check. Time remaining: #{remaining_humanized}. AFK players: #{inspect(afk_players)}"
        )

        timer_ref = Process.send_after(self(), {:start_afk_check, attempt + 1}, 20_000)
        {:noreply, %{state | afk_timer: timer_ref}}
      else
        Logger.info("AFK check timed out after 80 seconds.")

        # Remove AFK players and reset if not enough players remain
        {active_players, afk_players} = split_active_afk(state.players)
        new_players = MapSet.new(active_players)

        Logger.info("Removing AFK players: #{inspect(afk_players)}")

        timer_ref =
          Process.send_after(
            self(),
            {:announce_player_count, MapSet.size(new_players), :down},
            750
          )

        {:noreply, %{state | players: new_players, announce_timer: timer_ref}}
      end
    end
  end

  def handle_info({:start_map_vote, _players}, state) do
    Logger.info("Reached a state of all players ready, initiating map vote!")

    # we will keep the player state until this completes
    # once it's done we can reset the state so that a new pickup can start

    {:noreply, state}
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
