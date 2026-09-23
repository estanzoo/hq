import Config

# Mix starts the :hq application in the test env. If Hq.Application started
# the real tree, every test that starts its own Registry/SessionSup would die
# with :already_started, and tests would share one global Roster and Control
# socket. Each test starts exactly the processes it needs instead.
config :hq, start_children: false

# Safety net, not a feature: whatever test drives `Hq.Control.Handler`'s
# `stop` verb overrides these itself (a harmless stand-in it can assert on),
# but every OTHER test in this suite shares this same BEAM instance. Letting
# `:stop_fun` default to `&:init.stop/0` under `mix test` would mean any
# accidental "stop" request halts the entire test run's VM; letting
# `:signal_fun` default to a real `kill` would risk signalling a real
# process from a test that never meant to. Pinning both to no-ops here is
# what makes that impossible regardless of which test runs.
config :hq, stop_fun: fn -> :ok end, signal_fun: fn _pid -> :ok end

config :logger, level: :warning
