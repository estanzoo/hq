# Claude Code sets CLAUDECODE=1 in every command it runs, so `mix test` run by
# an agent would otherwise see a different `hq spawn` caller than `mix test`
# run by a person. Tests that need it set it themselves.
System.delete_env("CLAUDECODE")

ExUnit.start()
