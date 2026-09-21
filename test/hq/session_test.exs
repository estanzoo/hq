defmodule Hq.SessionTest do
  use ExUnit.Case, async: false

  @pane "w5:p1"

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    root = Path.join(System.tmp_dir!(), "hq-test-#{System.unique_integer([:positive])}")

    prev_sock = Application.get_env(:hq, :herdr_socket)
    prev_root = Application.get_env(:hq, :root)
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    Application.put_env(:hq, :root, root)
    Application.put_env(:hq, :settle_ms, 10)

    on_exit(fn ->
      Application.put_env(:hq, :herdr_socket, prev_sock)
      Application.put_env(:hq, :root, prev_root)
      File.rm_rf(root)
    end)

    start_supervised!({Registry, keys: :unique, name: Hq.Registry})

    FakeHerdr.stub(fake, "agent.prompt", %{"type" => "agent_prompt", "submitted" => true})
    %{fake: fake}
  end

  defp stub_status(fake, status) do
    FakeHerdr.stub(fake, "agent.get", %{
      "type" => "agent_get",
      "agent" => %{"name" => "worker-b", "pane_id" => @pane, "agent_status" => status}
    })
  end

  defp start_session(status_at_boot) do
    {:ok, pid} = Hq.Session.start_link(name: "worker-b", pane_id: @pane, spawned_by: "boss")
    _ = status_at_boot
    pid
  end

  defp prompts(fake) do
    FakeHerdr.calls(fake) |> Enum.filter(&(&1["method"] == "agent.prompt"))
  end

  test "delivers when the agent is already idle", %{fake: fake} do
    stub_status(fake, "idle")
    start_session("idle")

    Hq.Session.deliver("worker-b", "worker-a", "schema frozen")

    assert eventually(fn -> length(prompts(fake)) == 1 end)
    [%{"params" => params}] = prompts(fake)
    assert params["target"] == "worker-b"
    assert params["text"] == "[hq] message from worker-a:\nschema frozen"
    refute Map.has_key?(params, "wait")
  end

  for status <- ~w(working blocked unknown) do
    test "holds mail while the agent is #{status}", %{fake: fake} do
      stub_status(fake, unquote(status))
      start_session(unquote(status))

      Hq.Session.deliver("worker-b", "worker-a", "held")
      Process.sleep(80)

      assert prompts(fake) == []
      assert Hq.Session.info("worker-b")["mailbox"] == 1
    end
  end

  test "delivers held mail when the agent goes idle", %{fake: fake} do
    stub_status(fake, "working")
    start_session("working")

    Hq.Session.deliver("worker-b", "worker-a", "held then sent")
    Process.sleep(50)
    assert prompts(fake) == []

    stub_status(fake, "idle")

    FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
      "pane_id" => @pane,
      "agent_status" => "idle"
    })

    assert eventually(fn -> length(prompts(fake)) == 1 end)
  end

  test "`done` counts as ready, same as idle", %{fake: fake} do
    stub_status(fake, "done")
    start_session("done")

    Hq.Session.deliver("worker-b", "worker-a", "on done")

    assert eventually(fn -> length(prompts(fake)) == 1 end)
  end

  test "reports its state", %{fake: fake} do
    stub_status(fake, "working")
    start_session("working")

    Hq.Session.deliver("worker-b", "worker-a", "x")
    info = Hq.Session.info("worker-b")

    assert info["name"] == "worker-b"
    assert info["pane_id"] == @pane
    assert info["status"] == "working"
    assert info["mailbox"] == 1
    assert info["spawned_by"] == "boss"
  end

  test "keeps mail when delivery fails, and retries on the next ready transition", %{fake: fake} do
    stub_status(fake, "idle")

    FakeHerdr.stub_error(fake, "agent.prompt", %{"code" => "agent_blocked", "message" => "dialog"})

    start_session("idle")

    Hq.Session.deliver("worker-b", "worker-a", "retry me")
    Process.sleep(80)

    assert Hq.Session.info("worker-b")["mailbox"] == 1

    # Prove durability, not just in-memory state: reload the mailbox
    # independently from disk. A failed delivery must never have drained
    # (and thus truncated) the persisted file.
    reloaded = Hq.Mailbox.load("worker-b")
    assert Hq.Mailbox.depth(reloaded) == 1
    assert [%{"body" => "retry me", "from" => "worker-a"}] = reloaded.pending

    FakeHerdr.stub(fake, "agent.prompt", %{"type" => "agent_prompt", "submitted" => true})

    FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
      "pane_id" => @pane,
      "agent_status" => "idle"
    })

    assert eventually(fn -> Hq.Session.info("worker-b")["mailbox"] == 0 end)
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

  test "coalesces a burst into ONE prompt, not one per message", %{fake: fake} do
    stub_status(fake, "working")
    start_session("working")

    Hq.Session.deliver("worker-b", "worker-a", "one")
    Hq.Session.deliver("worker-b", "worker-c", "two")
    Hq.Session.deliver("worker-b", "worker-a", "three")

    stub_status(fake, "idle")

    FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
      "pane_id" => @pane,
      "agent_status" => "idle"
    })

    assert eventually(fn -> length(prompts(fake)) == 1 end)
    Process.sleep(60)
    assert length(prompts(fake)) == 1

    [%{"params" => %{"text" => text}}] = prompts(fake)
    assert text =~ "[hq] 3 messages"
    assert text =~ "from worker-a:\none"
    assert text =~ "from worker-c:\ntwo"
  end

  test "a status flap does not cause a double delivery", %{fake: fake} do
    stub_status(fake, "working")
    start_session("working")

    Hq.Session.deliver("worker-b", "worker-a", "once only")
    stub_status(fake, "idle")

    for _ <- 1..5 do
      FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
        "pane_id" => @pane,
        "agent_status" => "idle"
      })
    end

    assert eventually(fn -> length(prompts(fake)) == 1 end)
    Process.sleep(60)
    assert length(prompts(fake)) == 1
  end

  test "re-reads status after settling and does NOT deliver if the agent resumed", %{fake: fake} do
    stub_status(fake, "working")
    start_session("working")

    Hq.Session.deliver("worker-b", "worker-a", "should stay held")

    # Announce idle, but the authoritative read still says working — the flap
    # case this window exists to catch.
    FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
      "pane_id" => @pane,
      "agent_status" => "idle"
    })

    Process.sleep(120)

    assert prompts(fake) == []
    assert Hq.Session.info("worker-b")["mailbox"] == 1
  end
end
