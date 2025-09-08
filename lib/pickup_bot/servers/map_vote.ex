defmodule PickupBot.Servers.MapVote do
  @moduledoc """
  Temporary server to deal with interaction messages from Discord.
  The server will join the Nostrum ConsumerGroup to listen for events.
  """
  use GenServer, restart: :transient

  # alias Nostrum.Api.Message
  alias PickupBot.Servers.MessageServer

  require Logger

  # Hardcoded list of maps for now
  @maps [
    "cpm21",
    "cpm4a",
    "cpm18r",
    "ospdm5a",
    "avrdm1b",
    "cpm27",
    "cpm26"
  ]

  # Client

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def vote(player_id, map) do
    GenServer.cast(__MODULE__, {:vote, player_id, map})
  end

  # Server (callbacks)

  @impl true
  def init(args) do
    Logger.info("Starting MapVote server")

    # Pick 3 random maps
    maps = Enum.take_random(@maps, 3)

    # Merge map votes into the state
    # Keep track of msg count in case we need to "bump" the map vote
    state =
      Map.merge(args, %{
        votes: maps |> Enum.map(&{&1, []}) |> Enum.into(%{}),
        vote_actions: %{},
        msg_count: 0,
        msg: nil
      })

    {:ok, state, {:continue, :create_vote}}
  end

  @impl true
  def handle_continue(:create_vote, state) do
    # Join the Consumer for the duration of this gen_server
    Nostrum.ConsumerGroup.join()

    {:ok, msg} = MessageServer.create(state.channel_id, create_map_vote_msg(state, 0))

    Process.send_after(self(), {:start_map_vote, 0}, 5_000)

    {:noreply, %{state | channel_id: msg.channel_id, msg: msg}}
  end

  def handle_info({:start_map_vote, attempt}, state) do
    if attempt < 8 do
      Logger.info("Map Vote Rotation: #{attempt + 1}")

      # Update the message with the current map vote state
      # TODO: recreate the message further down if there's people chatting
      MessageServer.edit(state.msg, create_map_vote_msg(state, attempt + 1))

      Process.send_after(self(), {:start_map_vote, attempt + 1}, 5_000)
      {:noreply, state}
    else
      Logger.info("Map Vote Rotation complete")

      GenServer.call(state.pickup_pid, {:map, top_voted_map(state)})
      Process.send_after(self(), :shutdown, 500)

      {:noreply, state}
    end
  end

  def handle_info(:shutdown, state) do
    Logger.info("Shutting down MapVote server")

    Nostrum.ConsumerGroup.leave()

    {:stop, :normal, state}
  end

  #
  # Nostrum Consumer handlers
  #

  @impl true
  def handle_info({:event, {:MESSAGE_CREATE, msg, _ws_state}}, state)
      when msg.channel_id == state.channel_id do
    Logger.info("received MESSAGE_CREATE event")

    {:noreply, Map.update(state, :msg_count, 1, &(&1 + 1))}
  end

  def handle_info({:event, {:INTERACTION_CREATE, interaction, _ws_state}}, state)
      when interaction.channel_id == state.channel_id do
    Logger.info("received INTERACTION_CREATE event")

    user_id = interaction.user.id

    if eligible_to_vote?(user_id, state) do
      map = String.replace_prefix(interaction.data.custom_id, "btn_map_", "")

      # Get user's actions for this map
      user_actions = Map.get(state.vote_actions, user_id, %{})
      action = Map.get(user_actions, map, nil)

      new_state =
        if action == :voted do
          # Already voted, allow one unvote
          Logger.info("User #{user_id} unvoted map #{map}")

          Nostrum.Api.Interaction.create_response(interaction.id, interaction.token, %{type: 6})

          votes = Map.update(state.votes, map, [], fn voters -> List.delete(voters, user_id) end)

          vote_actions =
            Map.put(state.vote_actions, user_id, Map.put(user_actions, map, :unvoted))

          %{state | votes: votes, vote_actions: vote_actions}
        else
          if action == :unvoted do
            # Already unvoted, ignore further actions
            Logger.info("User #{user_id} already unvoted map #{map}, ignoring.")

            Nostrum.Api.Interaction.create_response(interaction.id, interaction.token, %{type: 6})

            state
          else
            # First vote
            Logger.info("User #{user_id} voted map #{map}")

            Nostrum.Api.Interaction.create_response(interaction.id, interaction.token, %{type: 6})

            votes =
              Map.update(state.votes, map, [user_id], fn voters ->
                [user_id | voters]
              end)

            vote_actions =
              Map.put(state.vote_actions, user_id, Map.put(user_actions, map, :voted))

            %{state | votes: votes, vote_actions: vote_actions}
          end
        end

      {:noreply, new_state}
    else
      Logger.info("User #{interaction.user.id} is not a player, ignoring interaction.")
      Nostrum.Api.Interaction.create_response(interaction.id, interaction.token, %{type: 6})
      {:noreply, state}
    end
  end

  def handle_info({:event, _event}, state) do
    {:noreply, state}
  end

  #
  # Private functions
  #

  defp create_map_vote_msg(state, attempt) do
    map_votes = map_votes_with_percent(state)
    time_left = max(0, 45 - attempt * 5)

    content = ~s"""
    Pickup is about to start - map voting for pickup **tdm** started - #{time_left} seconds left
    Please vote: #{mention_players(state.players)}

    __**Voting results**__

    #{Enum.join(map_votes, "\n")}

    Please vote using the buttons, you can vote for multiple maps.
    **You can only vote and unvote once per map.**

    ⏱️ **Vote results update every 5 seconds - no need to spam buttons!**
    """

    %{
      components: [
        %{
          components: create_map_vote_buttons(state),
          type: 1
        }
      ],
      content: content
    }
  end

  defp eligible_to_vote?(user_id, state) do
    user_id in state.players
  end

  defp mention_players(players) do
    players
    |> Enum.map(&"<@#{&1}>")
    |> Enum.join(", ")
  end

  defp create_map_vote_buttons(state) do
    state.votes
    |> Map.keys()
    |> Enum.map(&%{type: 2, style: 3, label: &1, custom_id: "btn_map_#{&1}"})
  end

  defp map_votes_with_percent(state) do
    total_votes =
      state.votes
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    state.votes
    |> Map.keys()
    |> Enum.map(fn map ->
      votes = Map.get(state.votes, map, [])

      percent =
        if total_votes > 0 do
          round(length(votes) * 100 / total_votes)
        else
          0
        end

      "#{progress_bar(percent)} #{percent}% - #{map}"
    end)
  end

  defp progress_bar(percent)
       when is_integer(percent) and percent >= 0 and percent <= 100 do
    total_blocks = 24
    filled_blocks = div(percent * total_blocks, 100)
    empty_blocks = total_blocks - filled_blocks

    filled = String.duplicate("⣿", filled_blocks)
    empty = String.duplicate("⣀", empty_blocks)

    filled <> empty
  end

  defp top_voted_map(state) do
    state.votes
    |> Enum.max_by(fn {_map, votes} -> length(votes) end, fn -> {nil, []} end)
    |> elem(0)
  end
end
