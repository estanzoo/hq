defmodule Hq.Roster do
  @moduledoc """
  Tracks which sessions hq supervises, and reaps them when their agent is gone.

  hq supervises only sessions it spawned or that explicitly registered. It does
  not adopt every agent it can see: adoption makes a session addressable, and
  typing a peer's message into a session the user is working in interactively
  would be intrusive. The global event subscription here is for reaping, not
  for recruiting.

  A session hq still supervises whose agent is actually gone is a "ghost" --
  hq will route mail to it, spawned workers will be told to report to it, and
  none of that will ever be delivered. A ghost is created three ways, and
  `reconcile/0` is the one place all three are cleaned up:

    * the daemon reboots with sessions.json referring to agents that came or
      went while it was down (the original boot-time case);
    * an agent process exits but its pane stays open (the user's shell is
      still there), so no `pane.exited`/`pane.closed` ever fires;
    * a whole workspace or worktree group closes at once, which does not
      emit a `pane.closed` per pane inside it.

  `reconcile/0` treats all three the same way: ask Herdr who is actually
  live (`agent.list`), and believe that over whatever hq last remembered.
  """
  use GenServer
  require Logger

  def start_link(_ \\ :ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # A pane hosts exactly one agent. If some OTHER remembered session still
  # claims this pane_id, its pane has been reassigned to whoever we are
  # about to adopt -- that other session is dead: the agent it thought it
  # supervised no longer owns this pane. This is how a stale registration
  # survives a pane being reused (e.g. `ev-limit` exits, its pane sits open,
  # the user starts a fresh orchestrator in it and runs `hq register
  # sw-desktop`): without this, both entries claim the same pane_id and
  # whichever `Hq.Control.Handler.resolve_from/1` (or `Hq.SessionSup.list/0`)
  # happens to find first wins, silently misrouting mail and spawned-worker
  # reports to the dead one. Forgetting it here, before the new entry is
  # remembered, means at most one entry ever claims a given pane_id.
  @spec adopt(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def adopt(name, pane_id, opts \\ []) do
    evict_other_claimants(name, pane_id)

    entry = %{
      "name" => name,
      "pane_id" => pane_id,
      "cwd" => Keyword.get(opts, :cwd),
      "spawned_by" => Keyword.get(opts, :spawned_by)
    }

    case Hq.SessionSup.start_session(
           name: name,
           pane_id: pane_id,
           cwd: entry["cwd"],
           spawned_by: entry["spawned_by"]
         ) do
      {:ok, pid} ->
        remember(entry)
        {:ok, pid}

      error ->
        error
    end
  end

  @spec forget(String.t()) :: :ok
  def forget(name) do
    Hq.SessionSup.stop_session(name)
    write(Enum.reject(remembered(), &(&1["name"] == name)))
    :ok
  end

  @spec remembered() :: [map()]
  def remembered do
    case File.read(store_path()) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, entries} when is_list(entries) -> entries
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  # -- Server ---------------------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, events} =
      Hq.Herdr.Events.start_link(
        owner: self(),
        subscriptions: [
          %{"type" => "pane.exited"},
          %{"type" => "pane.closed"},
          # Broad (no pane_id filter -- unlike Hq.Session's own per-pane
          # subscription to this same event, `pane.agent_status_changed`'s
          # subscription REQUIRES a pane_id, so it cannot be used here to
          # watch every pane at once). `pane.agent_detected` carries no such
          # requirement and is Herdr's signal that a pane's agent identity
          # changed -- including an agent departing a pane that stays open,
          # which is exactly the case `pane.exited`/`pane.closed` miss (see
          # the moduledoc). Its payload is only ever used as a trigger here:
          # `reconcile/0` re-verifies against `agent.list` rather than
          # trusting the pushed event body, which is both simpler (one
          # source of truth) and safer (immune to whatever that payload
          # does or doesn't mean in a given Herdr release).
          %{"type" => "pane.agent_detected"},
          # Closing a whole workspace or worktree group does not emit a
          # `pane.closed` for each pane inside it (see the moduledoc), so
          # every session in it would otherwise linger as a ghost forever.
          %{"type" => "workspace.closed"}
        ]
      )

    {:ok, %{events: events}, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    reconcile()
    {:noreply, state}
  end

  # pane.exited/pane.closed carry the one piece of information that matters
  # directly in the event itself -- the exact pane_id that just went away --
  # so this stays a precise, local match against `remembered()` with no extra
  # Herdr round trip, exactly as before. That precision is also why this does
  # NOT go through `reconcile/0`: reconcile treats a REMEMBERED entry's
  # absence from a fresh `agent.list` as proof of death, which only holds if
  # that listing reflects every other still-live session too. A test (or a
  # momentarily incomplete `agent.list`) that only accounts for the session
  # whose pane just closed would otherwise cost every OTHER remembered
  # session its life in the same sweep -- exactly the false-reap risk this
  # whole family of bugs is about avoiding.
  @impl true
  def handle_info({:hq_event, kind, %{"pane_id" => pane_id}}, state)
      when kind in ["pane_exited", "pane_closed"] do
    for entry <- remembered(), entry["pane_id"] == pane_id do
      reap(entry, "pane #{pane_id} is gone")
    end

    {:noreply, state}
  end

  # Neither of these carries a single authoritative pane_id the way
  # pane.exited/pane.closed do -- an agent departing a pane that stays open
  # is signalled only by a detection change on that pane (see the
  # subscription comment above), and a workspace closing takes an unknown
  # number of panes with it at once, several of which may not even belong to
  # sessions hq supervises. Re-verify EVERY remembered session against
  # Herdr's own live listing rather than trying to interpret either event's
  # payload — re-verifying is more robust than trying to map either one back
  # to specific panes, and it's the same question boot-time re-adoption
  # already asks, hence the shared function. Presence in `agent.list` is
  # also what keeps this safe against a false reap: it doesn't care what
  # STATUS the agent is in (idle, working, even "unknown" — Herdr merely
  # failing to classify it confidently is not the same as it being gone),
  # only whether Herdr still knows it by name. And because a session is only
  # ever remembered (see `adopt/3`) AFTER Herdr has already confirmed that
  # name — `agent.rename` for register, `agent.start` for spawn, both called
  # before `Hq.Roster.adopt/3` — there is no window right after spawn/register
  # where a freshly adopted session could be live locally but still invisible
  # to `agent.list`.
  def handle_info({:hq_event, kind, _data}, state)
      when kind in ["pane_agent_detected", "workspace_closed"] do
    reconcile()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Internals ------------------------------------------------------------

  @spec reconcile() :: :ok
  defp reconcile do
    case live_panes() do
      {:ok, live} ->
        for entry <- remembered(), do: reconcile_entry(entry, live)
        :ok

      {:error, reason} ->
        # A failure here (connection refused, timeout, malformed JSON, ...) is
        # indistinguishable from "Herdr is fine and just has no agents" unless
        # we keep the two apart explicitly. Reading it as the latter — as this
        # used to — takes every remembered session's absence from `live` as
        # proof its agent is gone and reaps all of them, permanently wiping
        # sessions.json on nothing more than a single unlucky boot (or event)
        # against a restarting Herdr. Skip the sweep entirely instead: a
        # session that is genuinely gone is still reaped on the next
        # reconcile once Herdr answers again.
        Logger.warning(
          "hq: skipping reconcile — Herdr is unreachable (#{inspect(reason)}); " <>
            "sessions.json left untouched"
        )

        :ok
    end
  end

  defp reconcile_entry(entry, live) do
    name = entry["name"]

    cond do
      Map.get(live, name) == nil ->
        reap(entry, "its agent is gone")

      Hq.Session.alive?(name) ->
        :ok

      true ->
        # Herdr confirms the agent is live but this process has no Session
        # for it (a fresh boot, or a reconcile that raced a crash) — adopt
        # it at the pane `agent.list` reports now, not whatever pane was
        # last remembered, in case the agent moved.
        adopt(name, Map.fetch!(live, name), cwd: entry["cwd"], spawned_by: entry["spawned_by"])
    end
  end

  defp reap(entry, reason) do
    name = entry["name"]
    undelivered = Hq.Mailbox.load(name) |> Hq.Mailbox.depth()

    if undelivered > 0 do
      Hq.Notify.tell(
        entry["spawned_by"],
        "#{name} exited with #{undelivered} undelivered message(s). " <>
          "They are in #{Hq.Mailbox.path_for(name)}."
      )
    end

    Logger.info("hq: reaping #{name} — #{reason}")
    forget(name)
  end

  defp evict_other_claimants(name, pane_id) do
    for entry <- remembered(), entry["pane_id"] == pane_id, entry["name"] != name do
      Logger.info(
        "hq: evicting #{entry["name"]} from #{pane_id} — #{name} is registering there instead"
      )

      forget(entry["name"])
    end

    :ok
  end

  # {:ok, %{name => pane_id}} for every live NAMED agent, or {:error, reason}
  # when Herdr could not be reached or answered something unexpected. `name`
  # is absent on unnamed agents, so it must never be assumed present. The
  # caller (reconcile/0) depends on failure and emptiness staying
  # distinguishable — collapsing both into the same `%{}` is exactly the bug
  # this shape exists to prevent (see the moduledoc).
  @spec live_panes() :: {:ok, map()} | {:error, term()}
  defp live_panes do
    case Hq.Herdr.call("agent.list", %{}) do
      {:ok, %{"agents" => agents}} ->
        map =
          for %{"pane_id" => pane_id} = a <- agents,
              name = Map.get(a, "name"),
              is_binary(name),
              into: %{},
              do: {name, pane_id}

        {:ok, map}

      {:error, reason} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}
    end
  end

  defp remember(entry) do
    others = Enum.reject(remembered(), &(&1["name"] == entry["name"]))
    write(others ++ [entry])
  end

  defp write(entries) do
    path = store_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(entries))
  end

  defp store_path, do: Path.join(Hq.Mailbox.root(), "sessions.json")
end
