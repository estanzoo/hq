defmodule Hq.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: Hq.Supervisor)
  end

  # Under MIX_ENV=test the tree stays empty: each test starts exactly the
  # processes it needs, so they do not collide on Hq.Registry or share one
  # global Roster and control socket.
  defp children do
    if Application.get_env(:hq, :start_children, true) do
      [
        {Registry, keys: :unique, name: Hq.Registry},
        Hq.SessionSup,
        Hq.Roster,
        Hq.Control
      ]
    else
      []
    end
  end
end
