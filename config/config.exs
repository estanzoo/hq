import Config

config :hq,
  herdr_socket: Path.expand("~/.config/herdr/herdr.sock"),
  root: Path.expand("~/.hq"),
  settle_ms: 400,
  pane_settle_ms: 300,
  start_children: true

config :logger, level: :info

if config_env() == :test do
  import_config "test.exs"
end
