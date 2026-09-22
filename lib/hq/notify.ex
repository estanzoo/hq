defmodule Hq.Notify do
  @moduledoc """
  Tells a session's parent about something it cannot see.

  A notice is ordinary `[hq]` mail, not a special channel: there is no
  orchestrator identity in the system, only participants. A session with no
  live parent logs instead, so a notice is never silently dropped.

  A session whose `spawned_by` names itself is the same guarantee under a
  different failure mode: delivering to it would be a `GenServer.call` from a
  process to itself, made from inside that same process's own callback (a
  blocked/exit transition calling `tell/2` synchronously). That deadlocks
  until the call timeout kills it. The guard lives here rather than only at
  the one place that constructs `spawned_by` today, so every caller —
  present and future — is covered.
  """
  require Logger

  @spec tell(String.t() | nil, String.t()) :: :ok
  def tell(nil, body) do
    Logger.info("hq: #{body}")
    :ok
  end

  def tell(parent, body) do
    case GenServer.whereis(Hq.Session.via(parent)) do
      nil ->
        Logger.info("hq: #{body}")

      pid when pid == self() ->
        Logger.info(
          "hq: #{parent} is its own spawned_by; not delivering to self to avoid " <>
            "deadlocking: #{body}"
        )

      _pid ->
        Hq.Session.deliver(parent, "hq", body)
    end

    :ok
  end
end
