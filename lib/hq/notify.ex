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

  The self-guard above only catches a session naming itself. Two DIFFERENT
  sessions that name each other as parent hit the same deadlock shape from
  the other side: A's `handle_info` calls `tell/2` synchronously to notify B,
  which is a `GenServer.call` that blocks A's own mailbox loop until B
  replies; if B is, at the same moment, inside its own `handle_info` making
  the identical blocking call back to A, neither process's mailbox loop is
  free to answer the other's call, and both hang until `@call_timeout` (30s)
  kills them. Delivery from inside a Session's own callback is therefore done
  from a short-lived, unlinked `Task` instead of inline: the callback returns
  immediately either way, so a Session's mailbox loop is never the thing the
  other Session is waiting on. A caller that is not itself a Session (a test,
  `Hq.Roster` reaping a pane) has no such risk and keeps the original
  synchronous delivery, so a genuine delivery failure there still surfaces to
  the caller rather than being silently backgrounded.
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
        deliver(parent, body)
    end

    :ok
  end

  # `Registry.keys/2` on the CURRENT process tells us whether `self()` is
  # itself a supervised Session (registered under its own name in
  # `Hq.Registry`) — true only when `tell/2` was reached from inside a
  # Session's own `handle_info`, which is precisely the case that can
  # deadlock against a peer doing the same thing back. Everyone else (a test
  # process, `Hq.Roster`) delivers inline as before.
  defp deliver(parent, body) do
    if Registry.keys(Hq.Registry, self()) == [] do
      Hq.Session.deliver(parent, "hq", body)
    else
      Task.start(fn -> Hq.Session.deliver(parent, "hq", body) end)
      :ok
    end
  end
end
