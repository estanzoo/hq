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
