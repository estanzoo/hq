defmodule Hq.MixProject do
  use Mix.Project

  def project do
    [
      app: :hq,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # `:app` is `nil`: `escript.build` otherwise starts the current app
      # (the whole :hq supervision tree — Registry, SessionSup, Roster,
      # Control) before `Hq.CLI.main/1` ever runs, for every invocation of
      # the escript, not just `hq daemon`. That would mean `hq --help` or
      # `hq ls` locally starts its own Hq.Control, which deletes and rebinds
      # the real daemon's control.sock out from under it — the one thing the
      # O_EXCL-guarded autostart in `Hq.CLI.ensure_daemon/0` exists to
      # prevent. Only `hq daemon` (`run_daemon/0`) starts the application,
      # explicitly, via `Application.ensure_all_started/1`; every other verb
      # stays a plain client of the control socket.
      escript: [main_module: Hq.CLI, name: "hq", app: nil],
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Hq.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
