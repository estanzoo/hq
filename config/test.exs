import Config

# Mix starts the :hq application in the test env. If Hq.Application started
# the real tree, every test that starts its own Registry/SessionSup would die
# with :already_started, and tests would share one global Roster and Control
# socket. Each test starts exactly the processes it needs instead.
config :hq, start_children: false

config :logger, level: :warning
