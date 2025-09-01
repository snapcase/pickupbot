defmodule PickupBot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    bot_options = %{
      consumer: PickupBot.Consumer,
      intents: [
        :guild_voice_states,
        :guilds,
        :guild_members,
        :guild_presences,
        :guild_messages,
        :guild_message_reactions,
        :message_content
      ],
      wrapped_token: fn -> System.get_env("BOT_TOKEN") end
    }

    children = [
      {Nostrum.Bot, bot_options}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PickupBot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
