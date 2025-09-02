import Config

config :logger, level: :info

config :nostrum,
  ffmpeg: nil

import_config "#{Mix.env()}.exs"
