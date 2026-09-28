defmodule Hq.RosterTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    root = Path.join(System.tmp_dir!(), "hq-test-#{System.unique_integer([:positive])}")
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    Application.put_env(:hq, :root, root)
    Application.put_env(:hq, :settle_ms, 10)
    on_exit(fn -> File.rm_rf(root) end)

    FakeHerdr.stub(fake, "agent.get", %{
      "type" => "agent_get",
      "agent" => %{"agent_status" => "working"}
    })

    FakeHerdr.stub(fake, "agent.list", %{"type" => "agent_list", "agents" => []})

    start_supervised!({Registry, keys: :unique, name: Hq.Registry})
    start_supervised!(Hq.SessionSup)

    %{fake: fake, root: root}
  end

  test "adopting starts a session and remembers it" do
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1", cwd: "/tmp/a", spawned_by: "boss")

    assert Hq.Session.alive?("worker-a")

    assert [%{"name" => "worker-a", "pane_id" => "w5:p1", "spawned_by" => "boss"}] =
             Hq.Roster.remembered()
  end

  test "does NOT adopt agents it merely observes", %{fake: fake} do
    FakeHerdr.stub(fake, "agent.list", %{
      "type" => "agent_list",
      "agents" => [
        %{"name" => "someones-repl", "pane_id" => "w9:p1", "agent_status" => "idle"}
      ]
    })

    start_supervised!(Hq.Roster)
    Process.sleep(100)

    refute Hq.Session.alive?("someones-repl")
    assert Hq.Roster.remembered() == []
  end

  test "re-adopts remembered sessions on boot", %{fake: fake} do
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")
    :ok = Hq.SessionSup.stop_session("worker-a")
    assert eventually(fn -> not Hq.Session.alive?("worker-a") end)

    FakeHerdr.stub(fake, "agent.list", %{
      "type" => "agent_list",
      "agents" => [%{"name" => "worker-a", "pane_id" => "w5:p1", "agent_status" => "idle"}]
    })

    start_supervised!(Hq.Roster)

    assert eventually(fn -> Hq.Session.alive?("worker-a") end)
  end

  test "does not re-adopt a remembered session whose agent is gone", %{fake: fake} do
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")
    :ok = Hq.SessionSup.stop_session("worker-a")

    FakeHerdr.stub(fake, "agent.list", %{"type" => "agent_list", "agents" => []})
    start_supervised!(Hq.Roster)
    Process.sleep(100)

    refute Hq.Session.alive?("worker-a")
    assert Hq.Roster.remembered() == []
  end

  test "reaps a session when its pane exits", %{fake: fake} do
    start_supervised!(Hq.Roster)
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")
    assert Hq.Session.alive?("worker-a")

    FakeHerdr.push_event(fake, "pane_exited", %{"pane_id" => "w5:p1"})

    assert eventually(fn -> not Hq.Session.alive?("worker-a") end)
    assert eventually(fn -> Hq.Roster.remembered() == [] end)
  end

  # Bug 2: the Claude process in a pane exits, but the pane itself (the
  # user's shell) stays open, so neither pane.exited nor pane.closed ever
  # fires -- the ghost that bit the user as "ev-limit". Herdr signals this
  # with `pane.agent_detected` on that pane (no pane_id filter is possible on
  # the subscription itself, so Roster hears every pane's detection changes
  # and re-verifies via `agent.list` rather than trusting the event body --
  # see the handler comment in lib/hq/roster.ex). Once the agent is gone,
  # `agent.list` stops reporting its name at all.
  test "reaps a session whose agent departs even though its pane stays open", %{fake: fake} do
    FakeHerdr.stub(fake, "agent.list", %{
      "type" => "agent_list",
      "agents" => [%{"name" => "worker-a", "pane_id" => "w5:p1", "agent_status" => "idle"}]
    })

    # Adopt BEFORE starting Roster: start_supervised!/1 kicks off an async
    # boot-time reconcile (handle_continue) that runs concurrently with
    # whatever the test does next, since `adopt/3` itself is a plain
    # function, not routed through the Roster process. Adopting first means
    # `remembered()` is already settled by the time that boot reconcile
    # (whenever it actually runs) reads it, so there is nothing left to race.
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")
    start_supervised!(Hq.Roster)
    settle()
    assert Hq.Session.alive?("worker-a")

    FakeHerdr.stub(fake, "agent.list", %{"type" => "agent_list", "agents" => []})

    FakeHerdr.push_event(fake, "pane_agent_detected", %{
      "pane_id" => "w5:p1",
      "workspace_id" => "w5",
      "agent" => nil,
      "released" => true
    })

    assert eventually(fn -> not Hq.Session.alive?("worker-a") end)
    assert eventually(fn -> Hq.Roster.remembered() == [] end)
  end

  # The false-reap guard: `agent_status: "unknown"` means Herdr merely
  # couldn't classify the agent confidently, not that it is gone. Presence in
  # `agent.list` (not the status value) is the only thing `reconcile/0` acts
  # on, so a live agent reporting "unknown" must survive a reconcile sweep
  # untouched.
  test "an agent reporting status unknown is not reaped", %{fake: fake} do
    FakeHerdr.stub(fake, "agent.list", %{
      "type" => "agent_list",
      "agents" => [%{"name" => "worker-a", "pane_id" => "w5:p1", "agent_status" => "unknown"}]
    })

    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")
    start_supervised!(Hq.Roster)

    FakeHerdr.push_event(fake, "pane_agent_detected", %{
      "pane_id" => "w5:p1",
      "workspace_id" => "w5",
      "agent" => "worker-a",
      "released" => false
    })

    Process.sleep(150)

    assert Hq.Session.alive?("worker-a")
    assert Hq.Roster.remembered() |> Enum.map(& &1["name"]) == ["worker-a"]
  end

  # Bug 3: closing a whole workspace or worktree group takes every pane in it
  # with it in one shot, without emitting a per-pane pane.closed for any of
  # them. `workspace.closed` is the only signal left, and it names the
  # workspace, not the panes -- so this must re-verify every remembered
  # session against Herdr (`agent.list`) rather than try to map the
  # workspace back to specific panes (pane ids are documented opaque, and a
  # closed workspace's panes can't be queried anymore anyway).
  test "workspace.closed reaps the sessions whose panes are gone and keeps the ones that survive",
       %{fake: fake} do
    FakeHerdr.stub(fake, "agent.list", %{
      "type" => "agent_list",
      "agents" => [
        %{"name" => "worker-a", "pane_id" => "w5:p1", "agent_status" => "idle"},
        %{"name" => "worker-b", "pane_id" => "w6:p1", "agent_status" => "idle"}
      ]
    })

    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1")
    start_supervised!(Hq.Roster)
    settle()

    # The workspace holding worker-a's pane closes; worker-b's is untouched.
    FakeHerdr.stub(fake, "agent.list", %{
      "type" => "agent_list",
      "agents" => [%{"name" => "worker-b", "pane_id" => "w6:p1", "agent_status" => "idle"}]
    })

    FakeHerdr.push_event(fake, "workspace_closed", %{"workspace_id" => "w5"})

    assert eventually(fn -> not Hq.Session.alive?("worker-a") end)
    assert Hq.Session.alive?("worker-b")

    # `forget/1` (by design -- see its moduledoc) stops the session BEFORE
    # rewriting sessions.json, so `Hq.Session.alive?` can flip to false a
    # moment before the file write lands. Poll this one too, exactly like
    # the existing "reaps a session when its pane exits" test above does,
    # rather than reading `remembered()` once immediately after the
    # liveness check.
    assert eventually(fn ->
             Hq.Roster.remembered() |> Enum.map(& &1["name"]) == ["worker-b"]
           end)
  end

  # Any new reaping path must honour the same rule as the boot-time sweep: a
  # Herdr outage is never proof the agents are gone. This drives that through
  # an event-triggered reconcile (workspace.closed), not just boot, since
  # C1's original guard lived only in the boot path before this task.
  test "a Herdr failure during an event-triggered reconcile reaps nothing", %{fake: fake} do
    FakeHerdr.stub(fake, "agent.list", %{
      "type" => "agent_list",
      "agents" => [%{"name" => "worker-a", "pane_id" => "w5:p1", "agent_status" => "idle"}]
    })

    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")
    start_supervised!(Hq.Roster)
    settle()
    assert Hq.Session.alive?("worker-a")

    FakeHerdr.stub_error(fake, "agent.list", %{
      "code" => "connection_refused",
      "message" => "herdr is down"
    })

    FakeHerdr.push_event(fake, "workspace_closed", %{"workspace_id" => "w9"})

    Process.sleep(150)

    assert Hq.Session.alive?("worker-a")
    assert Hq.Roster.remembered() |> Enum.map(& &1["name"]) == ["worker-a"]
  end

  # C1: a Herdr outage at boot must never be read as "no live agents". The old
  # `live_panes/0` collapsed every `Hq.Herdr.call` failure (connection
  # refused, timeout, malformed JSON) into `%{}`, indistinguishable from
  # "Herdr answered and has nothing". `handle_continue(:readopt)` then took
  # `Map.get(live, name) == nil` as proof each remembered agent was gone and
  # called `forget/1` on all of them, rewriting sessions.json to `[]` — wiping
  # durable state that no orchestrator running remotely could ever re-adopt.
  test "surviving Herdr being unreachable at boot: both remembered sessions survive", %{
    fake: fake
  } do
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1")
    :ok = Hq.SessionSup.stop_session("worker-a")
    :ok = Hq.SessionSup.stop_session("worker-b")

    FakeHerdr.stub_error(fake, "agent.list", %{
      "code" => "connection_refused",
      "message" => "herdr is down"
    })

    start_supervised!(Hq.Roster)
    Process.sleep(150)

    names = Hq.Roster.remembered() |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["worker-a", "worker-b"]
  end

  test "forget stops and un-remembers" do
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")
    :ok = Hq.Roster.forget("worker-a")

    refute Hq.Session.alive?("worker-a")
    assert Hq.Roster.remembered() == []
  end

  # Blocks until Hq.Roster has finished processing everything already queued
  # to it, including its own boot-time `{:continue, :reconcile}` (which runs
  # asynchronously relative to `start_supervised!/1`'s caller, since that
  # continue is scheduled the instant `init/1` returns, not awaited by it).
  # `:sys.get_state/1` only replies once the process is between callbacks, so
  # calling it right after `start_supervised!(Hq.Roster)` guarantees the boot
  # reconcile has fully settled -- including its own `agent.list` round trip
  # -- against whatever stub was in place at that point, before a test goes on
  # to change the stub and push an event. Without this, a slow boot reconcile
  # can race past a later stub change and perform the very reap a test means
  # to attribute to the event it pushes, making the two paths indistinguishable.
  defp settle, do: :sys.get_state(Hq.Roster)

  defp eventually(fun, tries \\ 50) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end
end
