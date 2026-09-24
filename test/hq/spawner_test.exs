defmodule Hq.SpawnerTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    root = Path.join(System.tmp_dir!(), "hq-test-#{System.unique_integer([:positive])}")
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    Application.put_env(:hq, :root, root)
    Application.put_env(:hq, :settle_ms, 10)
    Application.put_env(:hq, :pane_settle_ms, 1)
    Application.put_env(:hq, :pane_poll_ms, 1)
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

    # A freshly split (or created) pane's shell is, by default in these
    # tests, already past its own startup: exactly one foreground process,
    # and it is the shell itself. Tests that care about the busy window
    # override this stub explicitly.
    FakeHerdr.stub(fake, "pane.process_info", ready_process_info(999))

    %{fake: fake}
  end

  defp ready_process_info(shell_pid) do
    %{
      "process_info" => %{
        "foreground_processes" => [%{"name" => "zsh", "pid" => shell_pid}],
        "shell_pid" => shell_pid
      }
    }
  end

  defp busy_process_info(shell_pid) do
    %{
      "process_info" => %{
        "foreground_processes" => [
          %{"name" => "path_helper", "pid" => shell_pid + 3},
          %{"name" => "zsh", "pid" => shell_pid}
        ],
        "shell_pid" => shell_pid
      }
    }
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

  # -- --cwd pointed at an existing worktree (no --worktree) -----------------
  #
  # skills/hq/SKILL.md's "Ordered tasks sharing a branch" workflow spawns the
  # first task with --worktree (its own new workspace) and later tasks with
  # --cwd <that worktree path> (no --worktree). Those later spawns used to
  # always pane.split in the CALLER's workspace; they must now land in the
  # worktree's own workspace instead, matching the first task.

  defp worktree_list_stub(fake, worktrees) do
    FakeHerdr.stub(fake, "worktree.list", %{
      "type" => "worktree_list",
      "source" => %{
        "repo_key" => "/tmp/repo/.git",
        "repo_name" => "repo",
        "repo_root" => "/tmp/repo",
        "source_checkout_path" => "/tmp/repo"
      },
      "worktrees" => worktrees
    })
  end

  defp worktree_entry(path, opts \\ []) do
    %{
      "path" => path,
      "is_bare" => false,
      "is_detached" => false,
      "is_prunable" => false,
      "is_linked_worktree" => Keyword.get(opts, :linked, true),
      "label" => "repo"
    }
    |> then(fn entry ->
      case Keyword.get(opts, :open_workspace_id) do
        nil -> entry
        id -> Map.put(entry, "open_workspace_id", id)
      end
    end)
  end

  defp unique_worktree_path do
    Path.join(System.tmp_dir!(), "hq-worktree-#{System.unique_integer([:positive])}")
  end

  test "an OPEN worktree workspace: splits with that workspace's workspace_id", %{fake: fake} do
    worktree_path = unique_worktree_path()

    worktree_list_stub(fake, [
      worktree_entry("/tmp/repo", linked: false, open_workspace_id: "w-primary"),
      worktree_entry(worktree_path, open_workspace_id: "w-linked")
    ])

    assert {:ok, %{"pane_id" => "w1:p2"}} =
             Hq.Spawner.spawn_agent(%{
               "name" => "worker-a",
               "from" => "boss",
               "cwd" => worktree_path
             })

    assert call(fake, "pane.split")["params"]["workspace_id"] == "w-linked"
    refute "worktree.open" in methods(fake)
    assert Hq.Session.alive?("worker-a")
  end

  test "a CLOSED worktree workspace: opens it and lands the agent in its root pane",
       %{fake: fake} do
    worktree_path = unique_worktree_path()

    worktree_list_stub(fake, [worktree_entry(worktree_path)])

    FakeHerdr.stub(fake, "worktree.open", %{
      "type" => "worktree_opened",
      "already_open" => false,
      "workspace" => %{
        "workspace_id" => "w-opened",
        "number" => 3,
        "label" => "repo",
        "focused" => false,
        "pane_count" => 1,
        "tab_count" => 1,
        "active_tab_id" => "t1",
        "agent_status" => "idle"
      },
      "tab" => %{"tab_id" => "t1"},
      "root_pane" => %{
        "pane_id" => "w-opened:p1",
        "terminal_id" => "term1",
        "workspace_id" => "w-opened",
        "tab_id" => "t1",
        "focused" => true,
        "agent_status" => "idle",
        "revision" => 1
      },
      "worktree" => worktree_entry(worktree_path, open_workspace_id: "w-opened")
    })

    assert {:ok, %{"pane_id" => "w-opened:p1"}} =
             Hq.Spawner.spawn_agent(%{
               "name" => "worker-a",
               "from" => "boss",
               "cwd" => worktree_path
             })

    assert call(fake, "worktree.open")["params"]["path"] == worktree_path
    refute "pane.split" in methods(fake)
    assert Hq.Session.alive?("worker-a")
  end

  test "a --cwd that is not a worktree behaves exactly as before", %{fake: fake} do
    worktree_list_stub(fake, [worktree_entry("/tmp/repo", linked: false)])

    assert {:ok, %{"name" => "worker-a", "pane_id" => "w1:p2"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    assert "worktree.list" in methods(fake)
    refute "worktree.open" in methods(fake)
    refute call(fake, "pane.split")["params"]["workspace_id"]
  end

  test "does not route through the primary checkout's own workspace_id", %{fake: fake} do
    worktree_list_stub(fake, [
      worktree_entry("/tmp/x", linked: false, open_workspace_id: "w-primary")
    ])

    assert {:ok, %{"pane_id" => "w1:p2"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    refute call(fake, "pane.split")["params"]["workspace_id"]
  end

  test "a failing worktree.list falls back to a plain split and the spawn still succeeds",
       %{fake: fake} do
    FakeHerdr.stub_error(fake, "worktree.list", %{"code" => "internal_error", "message" => "boom"})

    assert {:ok, %{"name" => "worker-a", "pane_id" => "w1:p2"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    assert Hq.Session.alive?("worker-a")
    refute call(fake, "pane.split")["params"]["workspace_id"]
  end

  test "a failing worktree.open falls back to a plain split and the spawn still succeeds",
       %{fake: fake} do
    worktree_path = unique_worktree_path()

    worktree_list_stub(fake, [worktree_entry(worktree_path)])
    FakeHerdr.stub_error(fake, "worktree.open", %{"code" => "worktree_busy", "message" => "boom"})

    assert {:ok, %{"pane_id" => "w1:p2"}} =
             Hq.Spawner.spawn_agent(%{
               "name" => "worker-a",
               "from" => "boss",
               "cwd" => worktree_path
             })

    assert call(fake, "pane.split")["params"]["cwd"] == worktree_path
    refute call(fake, "pane.split")["params"]["workspace_id"]
  end

  test "matches a worktree path even when cwd carries a cosmetic difference", %{fake: fake} do
    worktree_path = unique_worktree_path()

    worktree_list_stub(fake, [worktree_entry(worktree_path, open_workspace_id: "w-linked")])

    assert {:ok, %{"pane_id" => "w1:p2"}} =
             Hq.Spawner.spawn_agent(%{
               "name" => "worker-a",
               "from" => "boss",
               "cwd" => worktree_path <> "/"
             })

    assert call(fake, "pane.split")["params"]["workspace_id"] == "w-linked"
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

  # Minor fix: Hq.Roster.adopt was passed `cwd: cwd` (the SOURCE checkout)
  # instead of `cwd: target_dir` (the directory the agent actually runs in) —
  # identical for a plain pane.split, but wrong for a worktree spawn, where
  # `hq ls` would show the source checkout instead of the worktree.
  test "adopts the session with the worktree's own directory, not the source checkout" do
    assert {:ok, %{"pane_id" => "w7:p1"}} =
             Hq.Spawner.spawn_agent(%{
               "name" => "worker-a",
               "from" => "boss",
               "cwd" => "/tmp/x",
               "worktree" => true,
               "base" => "main"
             })

    expected = Path.join(["/tmp/x", ".worktree", "worker-a"])
    assert Hq.Session.info("worker-a")["cwd"] == expected
    refute Hq.Session.info("worker-a")["cwd"] == "/tmp/x"
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

  # I5: `preamble/1` used to say only "you can message any other live
  # session" -- a worker learned who its parent was solely from free-text an
  # orchestrator happened to write into `--task`. Drive this through a real
  # spawn (not a hand-written preamble string) so a regression that stops
  # wiring `args["from"]` through to the preamble cannot hide behind a test
  # that constructs the expected text itself.
  test "preamble names the actual resolved parent, not just a peer notice" do
    Hq.Spawner.spawn_agent(%{
      "name" => "worker-a",
      "from" => "boss",
      "cwd" => "/tmp/x"
    })

    pending = Hq.Session.pending("worker-a")
    body = pending |> Enum.map(& &1["body"]) |> Enum.join("\n")

    assert body =~ "You were spawned by `boss`"
    assert body =~ "hq send boss"
  end

  # "operator" is `Hq.Control.Handler.resolve_from/1`'s fallback when the
  # spawning pane has no supervised hq session of its own -- there is no
  # session actually named "operator" to `hq send`, so telling a worker to
  # message it would just produce an unknown_target error the worker cannot
  # recover from on its own.
  test "preamble tells a directly-spawned worker the operator is not an addressable session" do
    Hq.Spawner.spawn_agent(%{
      "name" => "worker-a",
      "from" => "operator",
      "cwd" => "/tmp/x"
    })

    pending = Hq.Session.pending("worker-a")
    body = pending |> Enum.map(& &1["body"]) |> Enum.join("\n")

    assert body =~ "not an addressable hq session"
    refute body =~ "hq send operator"
  end

  test "rejects a name Herdr will not accept" do
    assert {:error, %{"code" => "bad_name"}} =
             Hq.Spawner.spawn_agent(%{"name" => "Worker A", "from" => "boss"})
  end

  test "rejects a self-referential spawned_by" do
    assert {:error, %{"code" => "self_spawn"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "worker-a"})

    refute Hq.Session.alive?("worker-a")
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

  # Immediately after prepare_env/3 sends the credential-unset command, the
  # pane is briefly still "running" that command in Herdr's eyes, so
  # agent.start can be rejected with agent_pane_busy even though the pane is
  # about to be ready. This must be retried transparently.
  test "retries agent.start when the pane is briefly busy, then succeeds", %{fake: fake} do
    FakeHerdr.stub_sequence(fake, "agent.start", [
      {:error, %{"code" => "agent_pane_busy", "message" => "not an available shell"}},
      {:ok, %{"type" => "agent_start", "agent" => %{"name" => "worker-a"}}}
    ])

    assert {:ok, %{"name" => "worker-a", "pane_id" => "w1:p2"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    assert Hq.Session.alive?("worker-a")

    starts = FakeHerdr.calls(fake) |> Enum.filter(&(&1["method"] == "agent.start"))
    assert length(starts) == 2
  end

  # A non-busy failure (bad name, missing pane, agent never came up, ...) is
  # a genuine error, not a transient one. It must fail on the FIRST attempt —
  # asserting the call count here means an implementation that blindly
  # retries every agent.start error, not just agent_pane_busy, fails this
  # test.
  test "does not retry a non-busy agent.start error", %{fake: fake} do
    FakeHerdr.stub_error(fake, "agent.start", %{"code" => "agent_not_ready", "message" => "nope"})

    assert {:error, %{"code" => "spawn_failed"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    starts = FakeHerdr.calls(fake) |> Enum.filter(&(&1["method"] == "agent.start"))
    assert length(starts) == 1
  end

  # The retry loop must be bounded, not infinite: if the pane never settles,
  # give up and surface the real agent_pane_busy error rather than hanging
  # or swallowing it into something unrecognizable.
  test "gives up after exhausting bounded retries and surfaces the busy error", %{fake: fake} do
    FakeHerdr.stub_error(fake, "agent.start", %{
      "code" => "agent_pane_busy",
      "message" => "not an available shell"
    })

    assert {:error, %{"code" => "spawn_failed", "message" => message}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    assert message =~ "agent_pane_busy"
    refute Hq.Session.alive?("worker-a")

    starts = FakeHerdr.calls(fake) |> Enum.filter(&(&1["method"] == "agent.start"))
    assert length(starts) <= 10
    assert length(starts) > 1
  end

  # Immediately after pane.split/worktree.create, the shell is still running
  # its own startup (.zprofile's path_helper, etc.) and reports more than one
  # foreground process. hq must poll pane.process_info until the pane
  # settles to just the shell before writing anything into it, rather than
  # racing the shell's own prompt.
  test "waits out a pane reported busy before it settles, then proceeds", %{fake: fake} do
    FakeHerdr.stub_sequence(fake, "pane.process_info", [
      {:ok, busy_process_info(999)},
      {:ok, ready_process_info(999)}
    ])

    assert {:ok, %{"name" => "worker-a", "pane_id" => "w1:p2"}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    assert Hq.Session.alive?("worker-a")

    # A raw call-count assertion here (`>= 2`) does not kill a mutated
    # `wait_for_shell/2` that checks once and proceeds regardless: `do_spawn`
    # calls `wait_for_shell` at TWO call sites (before prepare_env and again
    # before start_agent), so two `pane.process_info` calls happen even with
    # zero retries. State the actual property instead: the pane must be
    # confirmed READY -- not merely checked once -- before anything is typed
    # into it. The stub above answers busy, then ready, so a genuine retry
    # means the check immediately preceding the first `pane.send_input` is
    # NOT the lone busy reply; with zero retries, prepare_env's send_input
    # follows directly on the heels of that single busy check.
    calls = FakeHerdr.calls(fake)
    send_input_index = Enum.find_index(calls, &(&1["method"] == "pane.send_input"))
    assert send_input_index, "expected at least one pane.send_input call"

    checks_before_write =
      calls |> Enum.take(send_input_index) |> Enum.count(&(&1["method"] == "pane.process_info"))

    assert checks_before_write >= 2,
           "expected the busy reply to be retried (>=2 process_info checks) before the first " <>
             "send_input, got #{checks_before_write}"

    starts = FakeHerdr.calls(fake) |> Enum.filter(&(&1["method"] == "agent.start"))
    assert length(starts) == 1
  end

  # If the pane never settles, give up rather than writing into (or starting
  # an agent against) a shell that may never be ready. This must be bounded,
  # not an infinite poll, and must never reach agent.start.
  test "gives up when the pane never becomes ready, and never calls agent.start", %{fake: fake} do
    FakeHerdr.stub(fake, "pane.process_info", busy_process_info(999))

    assert {:error, %{"code" => "spawn_failed", "message" => message}} =
             Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    assert message =~ "pane_not_ready"
    assert message =~ "w1:p2"
    refute Hq.Session.alive?("worker-a")

    starts = FakeHerdr.calls(fake) |> Enum.filter(&(&1["method"] == "agent.start"))
    assert starts == []
  end

  test "checks the pane is ready before writing anything into it", %{fake: fake} do
    Hq.Spawner.spawn_agent(%{"name" => "worker-a", "from" => "boss", "cwd" => "/tmp/x"})

    ms = methods(fake)
    first_check = Enum.find_index(ms, &(&1 == "pane.process_info"))
    first_input = Enum.find_index(ms, &(&1 == "pane.send_input"))

    assert first_check < first_input,
           "the pane's readiness must be checked before any input is written into it"
  end
end
