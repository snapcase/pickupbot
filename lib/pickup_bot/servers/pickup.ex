defmodule PickupBot.Servers.Pickup do
  @moduledoc """
  GenServer for TDM pickup
  """
  use GenServer

  require Logger

  alias PickupBot.Servers.ActivityTracker

  @maxplayers 8

  # TODO: make these configurable
  @afk_interval 20
  # @channel 1_412_476_637_479_436_288
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
    {:ok, %{players: MapSet.new()}}
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
      end

      # Send message to announce player count change
      # Only announce if player count actually changed
      updated_state =
        if MapSet.size(new_players) != MapSet.size(state.players) do
          # Cancel any existing timer
          if state[:announce_timer] do
            Process.cancel_timer(state[:announce_timer])
          end

          # Schedule new announcement with 750ms delay
          timer_ref =
            Process.send_after(self(), {:announce_player_count, MapSet.size(new_players)}, 750)

          Map.put(state, :announce_timer, timer_ref)
        else
          state
        end

      {:reply, :ok, %{updated_state | players: new_players}}
    end
  end

  # TODO: players should be able to remove pending the AFK stage
  #       currently the afk check loop will just continue when the player count != @maxplayers
  def handle_call({:remove, player_id}, _from, state) do
    new_players = MapSet.delete(state.players, player_id)

    updated_state =
      if MapSet.size(new_players) != MapSet.size(state.players) do
        # Cancel any existing timer
        if state[:announce_timer] do
          Process.cancel_timer(state[:announce_timer])
        end

        # Schedule new announcement with 750ms delay
        timer_ref =
          Process.send_after(self(), {:announce_player_count, MapSet.size(new_players)}, 750)

        Map.put(state, :announce_timer, timer_ref)
      else
        state
      end

    {:reply, :ok, %{updated_state | players: new_players}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | players: MapSet.new()}}
  end

  def handle_info({:announce_player_count, player_count}, state) do
    Logger.info("Player count updated: #{player_count}/#{@maxplayers}")

    # TODO: Add logic to announce player count (e.g., send Discord message)

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
        remaining = 80 - attempt * @afk_interval

        remaining_humanized = humanize_seconds(remaining)
        afk_players = afk_players(state.players)

        Logger.info(
          "AFK check attempt #{attempt + 1}: Not all players present. Scheduling next check. Time remaining: #{remaining_humanized}. AFK players: #{inspect(afk_players)}"
        )

        Process.send_after(self(), {:start_afk_check, attempt + 1}, 20_000)
        {:noreply, state}
      else
        Logger.info("AFK check timed out after 80 seconds.")

        # Remove AFK players and reset if not enough players remain
        all_players = MapSet.to_list(state.players)
        afk_players = afk_players(state.players)
        active_players = all_players -- afk_players
        new_players = MapSet.new(active_players)

        Logger.info("Removing AFK players: #{inspect(afk_players)}")

        {:noreply, %{state | players: new_players}}
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

  defp afk_players(players) do
    players
    |> MapSet.to_list()
    |> ActivityTracker.get_timestamps()
    |> Enum.reject(&active_5m?/1)
    |> Enum.map(fn {player_id, _} -> player_id end)
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
end
