defmodule Hq.NotifyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

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

  test "tell logs when the parent is not live, instead of silently dropping" do
    log =
      capture_info_log(fn ->
        assert :ok = Hq.Notify.tell("ghost", "nobody hears this")
      end)

    assert log =~ "nobody hears this"
  end

  test "tell logs when there is no parent, instead of silently dropping" do
    log =
      capture_info_log(fn ->
        assert :ok = Hq.Notify.tell(nil, "orphan")
      end)

    assert log =~ "orphan"
  end

  test "tell logs instead of deadlocking when spawned_by resolves to the calling process" do
    # Register the test process itself under the name "loopy" — exactly what
    # a self-referential spawned_by ("from" == the session's own name) does
    # for a real Session, whose handle_info calls tell/2 synchronously from
    # inside its own process. If tell/2 ever again tried Session.deliver/3
    # here, this test would hang for @call_timeout (30s) and then crash;
    # asserting :ok comes back immediately is what proves the guard fired
    # instead of the deadlock path being taken.
    {:ok, _owner} = Registry.register(Hq.Registry, "loopy", nil)

    log =
      capture_info_log(fn ->
        assert :ok = Hq.Notify.tell("loopy", "would deadlock")
      end)

    assert log =~ "would deadlock"
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

  test "a disconnected reconnect that observes idle clears the latch, so the next " <>
         "blocked episode notifies again",
       %{fake: fake} do
    FakeHerdr.stub(fake, "agent.prompt", %{"type" => "agent_prompt", "submitted" => true})

    {:ok, _} = Hq.Roster.adopt("boss", "w1:p1")
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1", spawned_by: "boss")
    Hq.Session.deliver("worker-b", "worker-a", "held")

    FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
      "pane_id" => "w6:p1",
      "agent_status" => "blocked"
    })

    assert eventually(fn ->
             blocked_notices("worker-b") == 1
           end)

    # Simulate a disconnected blocked -> idle: the agent recovered while
    # Herdr was disconnected, so no `pane_agent_status_changed` event was
    # ever delivered for it — only the reconnect's own refresh (`agent.get`)
    # ever learns the new status.
    FakeHerdr.stub(fake, "agent.get", %{
      "type" => "agent_get",
      "agent" => %{"agent_status" => "idle"}
    })

    worker_b = GenServer.whereis(Hq.Session.via("worker-b"))
    send(worker_b, {:hq_events, :connected})

    assert eventually(fn -> Hq.Session.info("worker-b")["status"] == "idle" end)

    # A second, genuine blocked episode must notify again. If the reconnect
    # above left the latch set (the bug this test guards against), this
    # notice would never arrive and the assertion below would time out.
    FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
      "pane_id" => "w6:p1",
      "agent_status" => "blocked"
    })

    assert eventually(fn -> blocked_notices("worker-b") == 2 end)
  end

  defp blocked_notices(name) do
    Hq.Session.pending("boss") |> Enum.filter(&(&1["body"] =~ "#{name} is blocked")) |> length()
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

  # The test env pins `config :logger, level: :warning` (see config/test.exs)
  # so noisy `mix test` output stays quiet — but that primary level is
  # checked before a message ever reaches a handler, so plain `capture_log/2`
  # with a `:level` option can't retroactively rescue an `:info` call; per
  # its own docs, that option never overrides `Logger.level/0`. Bumping the
  # global level for the duration (confirmed empirically against this
  # project's Elixir/OTP versions — the documented per-call `:level` option
  # and `Logger.put_process_level/2` were both tried first and neither let
  # an `:info` message through here) is what actually works.
  defp capture_info_log(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: level)
    end
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
