defmodule Hq.SpawnerTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    root = Path.join(System.tmp_dir!(), "hq-test-#{System.unique_integer([:positive])}")
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    Application.put_env(:hq, :root, root)
    Application.put_env(:hq, :settle_ms, 10)
    on_exit(fn -> File.rm_rf(root) end)

    start_supervised!({Registry, keys: :unique, name: Hq.Registry})
    start_supervised!(Hq.SessionSup)

    # NOTE: "working", not "idle". With "idle" and a 10ms settle window, the
    # Session spawned below can flush and drain its mailbox before the
    # "queues the preamble..." test below reads it back, making that
    # assertion flaky. "working" keeps mail queued deterministically; no
    # other test in this file depends on the status being idle.
    FakeHerdr.stub(fake, "agent.get", %{
      "type" => "agent_get",
      "agent" => %{"agent_status" => "working"}
    })

    FakeHerdr.stub(fake, "agent.list", %{"type" => "agent_list", "agents" => []})
    FakeHerdr.stub(fake, "agent.prompt", %{"type" => "agent_prompt"})
    FakeHerdr.stub(fake, "pane.send_input", %{"type" => "pane_send_input"})

    FakeHerdr.stub(fake, "agent.start", %{
      "type" => "agent_start",
      "agent" => %{"name" => "worker-a"}
    })

    FakeHerdr.stub(fake, "pane.split", %{
      "type" => "pane_split",
      "pane" => %{"pane_id" => "w1:p2"}
    })

    FakeHerdr.stub(fake, "worktree.create", %{
      "type" => "worktree_create",
      "root_pane" => %{"pane_id" => "w7:p1"}
    })

    %{fake: fake}
  end

  defp methods(fake), do: FakeHerdr.calls(fake) |> Enum.map(& &1["method"])
  defp call(fake, m), do: FakeHerdr.calls(fake) |> Enum.find(&(&1["method"] == m))

  test "splits a pane when no worktree is asked for", %{fake: fake} do
    assert {:ok, %{"name" => "worker-a", "pane_id" => "w1:p2"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    assert "pane.split" in methods(fake)
    refute "worktree.create" in methods(fake)
    assert Hq.Session.alive?("worker-a")
  end

  test "creates a worktree when asked", %{fake: fake} do
    assert {:ok, %{"pane_id" => "w7:p1"}} =
             Hq.Spawner.spawn_agent(%{
               "name" => "worker-a",
               "from" => "boss",
               "cwd" => "/tmp/x",
               "worktree" => true,
               "base" => "main"
             })

    wt = call(fake, "worktree.create")
    assert wt["params"]["branch"] == "agent/worker-a"
    assert wt["params"]["base"] == "main"
  end

  # bdherd runs `tools/worktree-env.sh` against the NEWLY CREATED WORKTREE's
  # path, not the source checkout it was ported from ($REPO/.worktree/$slug,
  # not $REPO — see reference/bdherd.bash:203-206). A prior version of this
  # module collapsed both to `cwd`, deriving compose ports for the base
  # checkout instead of the worktree just created — silently defeating the
  # entire reason this step exists. Every other test in this file passes
  # `cwd` as a bare "/tmp/x" with no `tools/worktree-env.sh` under it, so
  # `File.exists?` is always false and the script branch never runs; this is
  # the only test that actually exercises it.
  test "runs worktree-env.sh against the new worktree's path, not the source checkout",
       %{fake: fake} do
    checkout = Path.join(System.tmp_dir!(), "hq-checkout-#{System.unique_integer([:positive])}")
    script = Path.join(checkout, "tools/worktree-env.sh")
    File.mkdir_p!(Path.dirname(script))
    File.write!(script, "#!/bin/sh\nexit 0\n")
    File.chmod!(script, 0o755)
    on_exit(fn -> File.rm_rf(checkout) end)

    assert {:ok, _} =
             Hq.Spawner.spawn_agent(%{
               "name" => "worker-a",
               "from" => "boss",
               "cwd" => checkout,
               "worktree" => true,
               "base" => "main"
             })

    expected_worktree_path = Path.join([checkout, ".worktree", "worker-a"])

    # We also asked Herdr to create the worktree there in the first place.
    assert call(fake, "worktree.create")["params"]["path"] == expected_worktree_path

    script_calls =
      FakeHerdr.calls(fake)
      |> Enum.filter(&(&1["method"] == "pane.send_input"))
      |> Enum.map(& &1["params"]["text"])
      |> Enum.filter(&String.contains?(&1, "worktree-env.sh"))

    assert [text] = script_calls
    assert text == "#{script} #{expected_worktree_path} >/dev/null 2>&1 || true"
  end

  test "clears stale credential env BEFORE starting the agent", %{fake: fake} do
    Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    ms = methods(fake)
    unset_at = Enum.find_index(ms, &(&1 == "pane.send_input"))
    start_at = Enum.find_index(ms, &(&1 == "agent.start"))

    assert unset_at < start_at,
           "credentials must be cleared before the agent starts, or Claude Code opens a blocked dialog"

    assert call(fake, "pane.send_input")["params"]["text"] =~
             "unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN"
  end

  test "starts the agent with the right name, kind and pane", %{fake: fake} do
    Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    params = call(fake, "agent.start")["params"]
    assert params["name"] == "worker-a"
    assert params["kind"] == "claude"
    assert params["pane_id"] == "w1:p2"
    refute params["args"]
  end

  test "passes --dangerously-skip-permissions only when permissive", %{fake: fake} do
    Hq.Spawner.spawn_agent(%{
      "name" => "worker-a",
      "from" => "boss",
      "cwd" => "/tmp/x",
      "permissive" => true
    })

    assert call(fake, "agent.start")["params"]["args"] == ["--dangerously-skip-permissions"]
  end

  test "queues the preamble and the task as the first message" do
    Hq.Spawner.spawn_agent(%{
      "name" => "worker-a",
      "from" => "boss",
      "cwd" => "/tmp/x",
      "task" => "implement the parser"
    })

    pending = Hq.Session.pending("worker-a")
    body = pending |> Enum.map(& &1["body"]) |> Enum.join("\n")

    assert body =~ "You are `worker-a`"
    assert body =~ "hq send"
    assert body =~ "implement the parser"
  end

  test "rejects a name Herdr will not accept" do
    assert {:error, %{"code" => "bad_name"}} =
             Hq.Spawner.spawn_agent(%{"name" => "Worker A", "from" => "boss"})
  end

  test "rejects a name already in use" do
    assert {:ok, _} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    assert {:error, %{"code" => "name_taken"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})
  end

  test "reports a spawn failure instead of leaving a half-built session", %{fake: fake} do
    FakeHerdr.stub_error(fake, "agent.start", %{"code" => "agent_not_ready", "message" => "nope"})

    assert {:error, %{"code" => "spawn_failed"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    refute Hq.Session.alive?("worker-a")
  end
end
