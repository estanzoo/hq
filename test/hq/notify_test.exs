defmodule Hq.NotifyTest do
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

    %{fake: fake}
  end

  test "tell queues mail to a live parent" do
    {:ok, _} = Hq.Roster.adopt("boss", "w1:p1")

    :ok = Hq.Notify.tell("boss", "worker-b is blocked")

    assert [%{"from" => "hq", "body" => "worker-b is blocked"}] = Hq.Session.pending("boss")
  end

  test "tell is a no-op when the parent is not live" do
    assert :ok = Hq.Notify.tell("ghost", "nobody hears this")
  end

  test "tell is a no-op when there is no parent" do
    assert :ok = Hq.Notify.tell(nil, "orphan")
  end

  test "a session entering blocked notifies its parent", %{fake: fake} do
    {:ok, _} = Hq.Roster.adopt("boss", "w1:p1")
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1", spawned_by: "boss")

    Hq.Session.deliver("worker-b", "worker-a", "held")

    FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
      "pane_id" => "w6:p1",
      "agent_status" => "blocked"
    })

    assert eventually(fn ->
             Hq.Session.pending("boss") |> Enum.any?(&(&1["body"] =~ "worker-b is blocked"))
           end)

    assert Hq.Session.pending("boss")
           |> Enum.any?(&(&1["body"] =~ "1 message held"))
  end

  test "blocked notifies once, not on every repeated blocked event", %{fake: fake} do
    {:ok, _} = Hq.Roster.adopt("boss", "w1:p1")
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1", spawned_by: "boss")
    Hq.Session.deliver("worker-b", "worker-a", "held")

    for _ <- 1..4 do
      FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
        "pane_id" => "w6:p1",
        "agent_status" => "blocked"
      })
    end

    assert eventually(fn -> Hq.Session.pending("boss") != [] end)
    Process.sleep(60)

    notices = Hq.Session.pending("boss") |> Enum.filter(&(&1["body"] =~ "blocked"))
    assert length(notices) == 1
  end

  test "reaping a session with pending mail tells its parent", %{fake: fake} do
    start_supervised!(Hq.Roster)
    {:ok, _} = Hq.Roster.adopt("boss", "w1:p1")
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1", spawned_by: "boss")
    Hq.Session.deliver("worker-b", "worker-a", "never delivered")

    FakeHerdr.push_event(fake, "pane_exited", %{"pane_id" => "w6:p1"})

    assert eventually(fn ->
             Hq.Session.pending("boss")
             |> Enum.any?(&(&1["body"] =~ "worker-b exited with 1 undelivered"))
           end)
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
