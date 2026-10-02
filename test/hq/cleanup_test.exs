defmodule Hq.CleanupTest do
  # Every test gets its own temp root, its own real git repository (with a
  # bare repository as `origin`) and real worktrees, so `git worktree remove`
  # is exercised for real. Herdr is FakeHerdr.
  use ExUnit.Case, async: false

  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "t"},
    {"GIT_AUTHOR_EMAIL", "t@example.com"},
    {"GIT_COMMITTER_NAME", "t"},
    {"GIT_COMMITTER_EMAIL", "t@example.com"}
  ]

  @caller_pane "w1:p1"

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    root = Path.join(System.tmp_dir!(), "hq-test-#{System.unique_integer([:positive])}")
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    Application.put_env(:hq, :root, root)
    Application.put_env(:hq, :settle_ms, 10)
    Application.put_env(:hq, :pane_settle_ms, 1)
    Application.put_env(:hq, :pane_poll_ms, 1)
    on_exit(fn -> File.rm_rf(root) end)

    FakeHerdr.stub(fake, "agent.get", %{
      "type" => "agent_get",
      "agent" => %{"agent_status" => "working"}
    })

    FakeHerdr.stub(fake, "agent.list", %{"type" => "agent_list", "agents" => []})
    FakeHerdr.stub(fake, "agent.prompt", %{"type" => "agent_prompt"})
    FakeHerdr.stub(fake, "agent.rename", %{"type" => "agent_rename"})
    FakeHerdr.stub(fake, "pane.close", %{"type" => "pane_closed"})

    start_supervised!({Registry, keys: :unique, name: Hq.Registry})
    start_supervised!(Hq.SessionSup)
    start_supervised!(Hq.Control)

    # `repo` is deliberately the un-canonical path (on macOS the temp dir
    # sits behind the /var -> /private/var symlink): sessions and the CLI
    # report whatever path they were given, git reports resolved ones.
    repo = Path.join(root, "repo")
    origin = Path.join(root, "origin.git")
    File.mkdir_p!(repo)
    git!(root, ["init", "-q", "--bare", "-b", "main", origin])
    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README"), "hello\n")
    File.write!(Path.join(repo, ".gitignore"), ".worktree/\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])
    git!(repo, ["remote", "add", "origin", origin])
    git!(repo, ["push", "-q", "origin", "main"])

    {:ok, _} = Hq.Roster.adopt("boss", @caller_pane)

    %{fake: fake, root: root, repo: repo, origin: origin}
  end

  # -- helpers ----------------------------------------------------------------

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], env: @git_env, stderr_to_stdout: true)
    out
  end

  # A real linked worktree at <repo>/.worktree/<name> on its own branch, with
  # one commit of its own so a lost branch would mean lost work.
  defp worktree!(repo, name, branch \\ nil) do
    branch = branch || "agent/#{name}"
    path = Path.join([repo, ".worktree", name])
    git!(repo, ["worktree", "add", "-q", "-b", branch, path, "main"])
    File.write!(Path.join(path, "#{name}.txt"), "work of #{name}\n")
    git!(path, ["add", "."])
    git!(path, ["commit", "-q", "-m", "work of #{name}"])
    path
  end

  defp worker!(name, pane_id, path, parent \\ "boss") do
    {:ok, _} = Hq.Roster.adopt(name, pane_id, cwd: path, spawned_by: parent)

    :ok =
      Hq.Runs.record(%{
        "parent" => parent,
        "name" => name,
        "pane_id" => pane_id,
        "worktree" => path
      })
  end

  defp agents!(fake, agents) do
    FakeHerdr.stub(fake, "agent.list", %{
      "type" => "agent_list",
      "agents" =>
        Enum.map(agents, fn {name, pane_id, status} ->
          %{"name" => name, "pane_id" => pane_id, "agent_status" => status}
        end)
    })
  end

  defp cleanup(repo, extra \\ %{}) do
    Hq.Control.Handler.handle(%{
      "verb" => "cleanup",
      "args" =>
        Map.merge(
          %{"from" => @caller_pane, "pane_id" => @caller_pane, "cwd" => repo},
          extra
        )
    })
  end

  defp closes(fake) do
    for %{"method" => "pane.close", "params" => params} <- FakeHerdr.calls(fake), do: params
  end

  defp branches(repo) do
    git!(repo, ["branch", "--list", "--format=%(refname:short)"]) |> String.split()
  end

  defp worktree_paths(repo) do
    for "worktree " <> path <- String.split(git!(repo, ["worktree", "list", "--porcelain"]), "\n"),
        do: path
  end

  defp item(result, path) do
    canon = Hq.Cleanup.canonical(path)
    Enum.find(result["worktrees"], &(&1["path"] == canon))
  end

  defp pane(result, name), do: Enum.find(result["panes"], &(&1["name"] == name))

  # -- dry run ----------------------------------------------------------------

  test "dry run is the default and changes nothing", %{fake: fake, repo: repo} do
    wt = worktree!(repo, "boss-1")
    worker!("boss-1", "w2:p1", wt)
    agents!(fake, [{"boss", @caller_pane, "idle"}, {"boss-1", "w2:p1", "idle"}])
    before_list = worktree_paths(repo)
    before_runs = File.read!(Hq.Runs.path())

    assert {:ok, result} = cleanup(repo)

    assert result["dry_run"] == true
    assert pane(result, "boss-1")["action"] == "close"
    assert item(result, wt)["action"] == "remove"

    assert closes(fake) == []
    assert File.dir?(wt)
    assert worktree_paths(repo) == before_list
    assert File.read!(Hq.Runs.path()) == before_runs
    assert Hq.Session.alive?("boss-1")

    text = Hq.Cleanup.render(result)
    assert text =~ "DRY RUN"
    assert text =~ "will close (1 pane)"
    assert text =~ "will remove (1 worktree)"
    assert text =~ "branches: none deleted"
    assert String.ends_with?(text, "hq cleanup --yes")
  end

  # -- --yes --------------------------------------------------------------------

  test "--yes closes the caller's workers' panes, removes their clean worktrees, and keeps every branch",
       %{fake: fake, repo: repo} do
    wt1 = worktree!(repo, "boss-1")
    wt2 = worktree!(repo, "boss-2")
    worker!("boss-1", "w2:p1", wt1)
    worker!("boss-2", "w3:p1", wt2)

    agents!(fake, [
      {"boss", @caller_pane, "idle"},
      {"boss-1", "w2:p1", "idle"},
      {"boss-2", "w3:p1", "done"}
    ])

    assert {:ok, result} = cleanup(repo, %{"yes" => true})

    assert result["dry_run"] == false
    assert Enum.sort(closes(fake)) == [%{"pane_id" => "w2:p1"}, %{"pane_id" => "w3:p1"}]
    assert item(result, wt1)["action"] == "removed"
    assert item(result, wt2)["action"] == "removed"
    refute File.exists?(wt1)
    refute File.exists?(wt2)
    assert Enum.sort(worktree_paths(repo)) == [Hq.Cleanup.canonical(repo)]

    # Branches are never deleted: every commit is still reachable.
    assert Enum.sort(branches(repo)) == ["agent/boss-1", "agent/boss-2", "main"]
    assert git!(repo, ["show", "agent/boss-1:boss-1.txt"]) == "work of boss-1\n"

    # Fully cleaned workers leave the run record.
    assert Hq.Runs.for_parent("boss") == []

    text = Hq.Cleanup.render(result)
    assert text =~ "closed (2 panes)"
    assert text =~ "removed (2 worktrees)"
    refute text =~ "To run this plan"
  end

  test "the PR worktree -- its branch is on origin -- is kept", %{fake: fake, repo: repo} do
    wt_pr = worktree!(repo, "boss-3", "feat/the-pr")
    wt_plain = worktree!(repo, "boss-1")
    git!(wt_pr, ["push", "-q", "origin", "feat/the-pr"])
    worker!("boss-3", "w4:p1", wt_pr)
    worker!("boss-1", "w2:p1", wt_plain)

    agents!(fake, [
      {"boss", @caller_pane, "idle"},
      {"boss-1", "w2:p1", "idle"},
      {"boss-3", "w4:p1", "idle"}
    ])

    assert {:ok, dry} = cleanup(repo)
    assert item(dry, wt_pr)["action"] == "kept"
    assert "PR branch pushed to origin" in item(dry, wt_pr)["reasons"]

    assert {:ok, result} = cleanup(repo, %{"yes" => true})

    assert item(result, wt_pr)["action"] == "kept"
    assert "PR branch pushed to origin" in item(result, wt_pr)["reasons"]
    assert File.dir?(wt_pr)
    assert Hq.Cleanup.canonical(wt_pr) in worktree_paths(repo)
    # ...while the run still did its job on the unpushed one.
    refute File.exists?(wt_plain)
    assert Hq.Cleanup.render(result) =~ "PR branch pushed to origin"
  end

  test "origin unreachable: falls back to local evidence and says so", %{fake: fake, repo: repo} do
    wt_tracked = worktree!(repo, "boss-3")
    wt_plain = worktree!(repo, "boss-1")
    git!(repo, ["update-ref", "refs/remotes/origin/agent/boss-3", "agent/boss-3"])
    git!(repo, ["remote", "set-url", "origin", "/nonexistent/hq-cleanup-test/origin.git"])
    worker!("boss-3", "w4:p1", wt_tracked)
    worker!("boss-1", "w2:p1", wt_plain)

    agents!(fake, [
      {"boss", @caller_pane, "idle"},
      {"boss-1", "w2:p1", "idle"},
      {"boss-3", "w4:p1", "idle"}
    ])

    assert {:ok, result} = cleanup(repo, %{"yes" => true})

    assert [reason] = item(result, wt_tracked)["reasons"]
    assert reason =~ "PR branch pushed to origin"
    assert reason =~ "origin was unreachable"
    assert File.dir?(wt_tracked)
    refute File.exists?(wt_plain)
    assert Enum.any?(result["notes"], &(&1 =~ "origin was unreachable"))
  end

  test "the orchestrator's own pane is never closed, even when Herdr names a worker there",
       %{fake: fake, repo: repo} do
    wt1 = worktree!(repo, "boss-1")
    wt9 = worktree!(repo, "boss-9")
    worker!("boss-1", "w2:p1", wt1)

    # boss-9's record claims the caller's own pane, and Herdr's listing
    # agrees: drift of exactly the kind that must never cost the caller its
    # own pane.
    :ok =
      Hq.Runs.record(%{
        "parent" => "boss",
        "name" => "boss-9",
        "pane_id" => @caller_pane,
        "worktree" => wt9
      })

    agents!(fake, [{"boss-9", @caller_pane, "idle"}, {"boss-1", "w2:p1", "idle"}])

    assert {:ok, result} = cleanup(repo, %{"yes" => true})

    assert closes(fake) == [%{"pane_id" => "w2:p1"}]
    refute %{"pane_id" => @caller_pane} in closes(fake)
    assert pane(result, "boss-9")["action"] == "kept"
    assert pane(result, "boss-9")["reason"] == "orchestrator's own pane"
    assert Hq.Session.alive?("boss")
    assert File.dir?(wt9)
    assert Hq.Cleanup.render(result) =~ "orchestrator's own pane"
  end

  test "the orchestrator's own worktree and the primary checkout are kept, even when unpushed and clean",
       %{fake: fake, repo: repo} do
    own = worktree!(repo, "boss")
    worker!("boss-1", "w2:p1", own)
    worker!("boss-2", "w3:p1", repo)

    agents!(fake, [
      {"boss", @caller_pane, "idle"},
      {"boss-1", "w2:p1", "idle"},
      {"boss-2", "w3:p1", "idle"}
    ])

    # The orchestrator runs from inside its own (feature) worktree.
    assert {:ok, result} = cleanup(Path.join(own, "."), %{"yes" => true})

    assert "orchestrator's own worktree" in item(result, own)["reasons"]
    assert "the repository's primary checkout" in item(result, repo)["reasons"]
    assert File.dir?(own)
    assert File.dir?(Path.join(repo, ".git"))
    assert Enum.sort(closes(fake)) == [%{"pane_id" => "w2:p1"}, %{"pane_id" => "w3:p1"}]
    # Nothing left for a later cleanup to do with either, so both leave the record.
    assert Hq.Runs.for_parent("boss") == []
  end

  test "a dirty worktree is kept", %{fake: fake, repo: repo} do
    wt = worktree!(repo, "boss-1")
    File.write!(Path.join(wt, "boss-1.txt"), "uncommitted edit\n")
    File.write!(Path.join(wt, "scratch.txt"), "untracked\n")
    worker!("boss-1", "w2:p1", wt)
    agents!(fake, [{"boss", @caller_pane, "idle"}, {"boss-1", "w2:p1", "idle"}])

    assert {:ok, dry} = cleanup(repo)
    assert item(dry, wt)["action"] == "kept"
    assert item(dry, wt)["reasons"] == ["dirty"]

    assert {:ok, result} = cleanup(repo, %{"yes" => true})

    assert item(result, wt)["action"] == "kept"
    assert item(result, wt)["reasons"] == ["dirty"]
    assert File.read!(Path.join(wt, "boss-1.txt")) == "uncommitted edit\n"
    assert File.read!(Path.join(wt, "scratch.txt")) == "untracked\n"
    assert Hq.Cleanup.render(result) =~ "dirty"
    # Kept means still recorded, so the next cleanup still finds it.
    assert [%{"name" => "boss-1"}] = Hq.Runs.for_parent("boss")
  end

  test "a working worker keeps both its pane and its worktree", %{fake: fake, repo: repo} do
    wt = worktree!(repo, "boss-1")
    worker!("boss-1", "w2:p1", wt)
    agents!(fake, [{"boss", @caller_pane, "idle"}, {"boss-1", "w2:p1", "working"}])

    assert {:ok, result} = cleanup(repo, %{"yes" => true})

    assert closes(fake) == []

    assert pane(result, "boss-1") |> Map.take(["action", "reason"]) ==
             %{"action" => "kept", "reason" => "agent is working"}

    assert item(result, wt)["action"] == "kept"
    assert "agent is working" in item(result, wt)["reasons"]
    assert File.dir?(wt)
  end

  test "another orchestrator's workers are untouched", %{fake: fake, repo: repo} do
    wt_mine = worktree!(repo, "boss-1")
    wt_theirs = worktree!(repo, "other-1")
    wt_theirs_done = worktree!(repo, "other-2")
    {:ok, _} = Hq.Roster.adopt("other", "w5:p1")
    worker!("boss-1", "w2:p1", wt_mine)
    worker!("other-1", "w6:p1", wt_theirs, "other")

    # other-2 has finished and been reaped: only the record still ties it to
    # `other`, so no live-session check can save it -- the parent must.
    :ok =
      Hq.Runs.record(%{
        "parent" => "other",
        "name" => "other-2",
        "pane_id" => "w9:p1",
        "worktree" => wt_theirs_done
      })

    agents!(fake, [
      {"boss", @caller_pane, "idle"},
      {"other", "w5:p1", "idle"},
      {"boss-1", "w2:p1", "idle"},
      {"other-1", "w6:p1", "idle"}
    ])

    assert {:ok, result} = cleanup(repo, %{"yes" => true})

    assert closes(fake) == [%{"pane_id" => "w2:p1"}]
    assert pane(result, "other-1") == nil
    assert item(result, wt_theirs) == nil
    assert item(result, wt_theirs_done) == nil
    assert File.dir?(wt_theirs)
    assert File.dir?(wt_theirs_done)
    refute File.exists?(wt_mine)
    assert Hq.Session.alive?("other-1")
    assert [%{"name" => "other-1"}, %{"name" => "other-2"}] = Hq.Runs.for_parent("other")
  end

  test "a recorded name since reused by another run is left alone", %{fake: fake, repo: repo} do
    wt = worktree!(repo, "boss-1")
    :ok = Hq.Runs.record(%{"parent" => "boss", "name" => "boss-1", "pane_id" => "w2:p1"})
    {:ok, _} = Hq.Roster.adopt("boss-1", "w2:p1", cwd: wt, spawned_by: "other")
    agents!(fake, [{"boss", @caller_pane, "idle"}, {"boss-1", "w2:p1", "idle"}])

    assert {:ok, result} = cleanup(repo, %{"yes" => true})

    assert closes(fake) == []
    assert File.dir?(wt)
    assert Enum.any?(result["notes"], &(&1 =~ "boss-1: left alone"))
  end

  # -- unrecorded (legacy) worktrees -----------------------------------------------

  test "a name-only legacy worktree is ignored without --include-unrecorded and included with it",
       %{fake: fake, repo: repo} do
    legacy = worktree!(repo, "boss-old")
    # `boss-v2` is another orchestrator whose name merely starts with ours.
    {:ok, _} = Hq.Roster.adopt("boss-v2", "w7:p1")
    named_after = worktree!(repo, "boss-v2")
    its_worker = worktree!(repo, "boss-v2-1")
    in_use = worktree!(repo, "boss-busy")
    {:ok, _} = Hq.Roster.adopt("someone", "w8:p1", cwd: in_use)
    agents!(fake, [{"boss", @caller_pane, "idle"}, {"boss-v2", "w7:p1", "idle"}])

    assert {:ok, without} = cleanup(repo, %{"yes" => true})
    assert without["worktrees"] == []
    assert File.dir?(legacy)

    assert {:ok, dry} = cleanup(repo, %{"include_unrecorded" => true})
    assert item(dry, legacy)["name_only"] == true
    assert item(dry, legacy)["action"] == "remove"
    text = Hq.Cleanup.render(dry)
    assert text =~ "[matched by name only]"
    assert text =~ "hq cleanup --yes --include-unrecorded"

    assert {:ok, result} = cleanup(repo, %{"yes" => true, "include_unrecorded" => true})

    refute File.exists?(legacy)
    assert item(result, named_after)["reasons"] == ["named after orchestrator boss-v2"]
    assert item(result, its_worker)["reasons"] == ["matches orchestrator boss-v2's naming"]
    assert item(result, in_use)["reasons"] == ["in use by someone"]
    assert File.dir?(named_after)
    assert File.dir?(its_worker)
    assert File.dir?(in_use)
    assert "agent/boss-old" in branches(repo)
  end

  # -- --keep, confirmation, Herdr failure ------------------------------------------

  test "--keep protects a worker by name and a worktree by path", %{fake: fake, repo: repo} do
    wt1 = worktree!(repo, "boss-1")
    wt2 = worktree!(repo, "boss-2")
    wt3 = worktree!(repo, "boss-3")
    worker!("boss-1", "w2:p1", wt1)
    worker!("boss-2", "w3:p1", wt2)
    worker!("boss-3", "w4:p1", wt3)

    agents!(fake, [
      {"boss", @caller_pane, "idle"},
      {"boss-1", "w2:p1", "idle"},
      {"boss-2", "w3:p1", "idle"},
      {"boss-3", "w4:p1", "idle"}
    ])

    assert {:ok, result} =
             cleanup(repo, %{"yes" => true, "keep" => ["boss-1", ".worktree/boss-2"]})

    assert closes(fake) == [%{"pane_id" => "w4:p1"}]
    assert pane(result, "boss-1")["reason"] == "--keep"
    assert item(result, wt1)["reasons"] == ["--keep"]
    assert item(result, wt2)["reasons"] == ["--keep"]
    assert File.dir?(wt1)
    assert File.dir?(wt2)
    refute File.exists?(wt3)
  end

  test "confirmation_required is skipped and reported, never forced", %{fake: fake, repo: repo} do
    wt = worktree!(repo, "boss-1")
    worker!("boss-1", "w2:p1", wt)
    agents!(fake, [{"boss", @caller_pane, "idle"}, {"boss-1", "w2:p1", "idle"}])

    FakeHerdr.stub_error(fake, "pane.close", %{
      "code" => "confirmation_required",
      "message" => "closing this pane closes the worktree group"
    })

    assert {:ok, result} = cleanup(repo, %{"yes" => true})

    # Exactly one attempt, with nothing but the pane id: no group/force flag.
    assert closes(fake) == [%{"pane_id" => "w2:p1"}]
    assert pane(result, "boss-1")["reason"] == "close needs worktree-group confirmation"
    assert item(result, wt)["reasons"] == ["close needs worktree-group confirmation"]
    assert File.dir?(wt)
    assert Hq.Cleanup.render(result) =~ "close needs worktree-group confirmation"
  end

  test "Herdr unreachable: nothing is closed and nothing is removed", %{fake: fake, repo: repo} do
    wt = worktree!(repo, "boss-1")
    worker!("boss-1", "w2:p1", wt)
    Application.put_env(:hq, :herdr_socket, "/nonexistent/hq-cleanup-test/herdr.sock")

    assert {:error, %{"code" => "herdr_unreachable", "message" => message}} =
             cleanup(repo, %{"yes" => true})

    assert message =~ "Nothing was closed and nothing was removed"
    assert closes(fake) == []
    assert File.dir?(wt)
    assert [%{"name" => "boss-1"}] = Hq.Runs.for_parent("boss")
  end

  test "an unregistered pane cannot clean up", %{repo: repo} do
    assert {:error, %{"code" => "not_registered"}} =
             Hq.Control.Handler.handle(%{
               "verb" => "cleanup",
               "args" => %{"from" => "w99:p1", "pane_id" => "w99:p1", "cwd" => repo}
             })
  end

  # -- the record -------------------------------------------------------------------

  test "a successful spawn is recorded, and the record survives a daemon restart",
       %{fake: fake, repo: repo} do
    wt = worktree!(repo, "boss-1")

    FakeHerdr.stub(fake, "worktree.create", %{
      "type" => "worktree_create",
      "root_pane" => %{"pane_id" => "w2:p1"},
      "worktree" => %{"path" => wt}
    })

    FakeHerdr.stub(fake, "pane.send_input", %{"type" => "pane_send_input"})
    FakeHerdr.stub(fake, "agent.start", %{"type" => "agent_start"})

    FakeHerdr.stub(fake, "pane.process_info", %{
      "process_info" => %{"foreground_processes" => [%{"pid" => 9}], "shell_pid" => 9}
    })

    assert {:ok, %{"name" => "boss-1"}} =
             Hq.Control.Handler.handle(%{
               "verb" => "spawn",
               "args" => %{
                 "name" => "boss-1",
                 "worktree" => true,
                 "from" => @caller_pane,
                 "pane_id" => @caller_pane
               }
             })

    assert [%{"parent" => "boss", "name" => "boss-1", "pane_id" => "w2:p1", "worktree" => ^wt}] =
             Hq.Runs.all()

    # Restart: every process goes; only files on disk survive. The worker's
    # agent is gone too, so on boot the Roster reaps it -- after which only
    # the run record still ties its worktree to boss.
    :ok = stop_supervised(Hq.Control)
    :ok = stop_supervised(Hq.SessionSup)
    :ok = stop_supervised(Hq.Registry)
    start_supervised!({Registry, keys: :unique, name: Hq.Registry})
    start_supervised!(Hq.SessionSup)
    agents!(fake, [{"boss", @caller_pane, "idle"}])
    start_supervised!(Hq.Roster)
    assert eventually(fn -> Hq.Session.alive?("boss") end)
    assert eventually(fn -> not Enum.any?(Hq.Roster.remembered(), &(&1["name"] == "boss-1")) end)

    assert [%{"name" => "boss-1", "worktree" => ^wt}] = Hq.Runs.for_parent("boss")

    assert {:ok, result} = cleanup(repo, %{"yes" => true})
    assert item(result, wt)["action"] == "removed"
    refute File.exists?(wt)
    assert "agent/boss-1" in branches(repo)
    assert Hq.Runs.all() == []
  end

  test "a spawn from an unregistered pane is not recorded", %{fake: fake} do
    FakeHerdr.stub(fake, "tab.create", %{
      "type" => "tab_created",
      "root_pane" => %{"pane_id" => "w2:p1"}
    })

    FakeHerdr.stub(fake, "pane.send_input", %{"type" => "pane_send_input"})
    FakeHerdr.stub(fake, "agent.start", %{"type" => "agent_start"})

    FakeHerdr.stub(fake, "pane.process_info", %{
      "process_info" => %{"foreground_processes" => [%{"pid" => 9}], "shell_pid" => 9}
    })

    assert {:ok, _} =
             Hq.Control.Handler.handle(%{
               "verb" => "spawn",
               "args" => %{"name" => "stray-1", "from" => "w99:p1", "worktree" => false}
             })

    assert Hq.Runs.all() == []
  end

  # -- the real CLI pipeline ----------------------------------------------------------

  test "parse -> decorate -> request -> handler resolves the caller from $HERDR_PANE_ID",
       %{fake: fake, repo: repo} do
    wt = worktree!(repo, "boss-1")
    worker!("boss-1", "w2:p1", wt)
    agents!(fake, [{"boss", @caller_pane, "idle"}, {"boss-1", "w2:p1", "idle"}])

    System.put_env("HERDR_PANE_ID", @caller_pane)
    on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

    {verb, args} = File.cd!(repo, fn -> Hq.CLI.parse(["cleanup"]) end)
    args = Hq.CLI.decorate(args)
    assert args["from"] == @caller_pane, "the caller is only known by its pane here"
    assert :ok = Hq.CLI.require_pane(verb)

    assert {:ok, dry} = Hq.CLI.request(verb, args)
    assert dry["caller"] == "boss"
    assert File.dir?(wt)
    assert closes(fake) == []

    {verb, args} = File.cd!(repo, fn -> Hq.CLI.parse(["cleanup", "--yes"]) end)
    assert {:ok, done} = Hq.CLI.request(verb, Hq.CLI.decorate(args))
    assert done["caller"] == "boss"
    assert closes(fake) == [%{"pane_id" => "w2:p1"}]
    refute File.exists?(wt)
    assert Hq.CLI.render("cleanup", done) =~ "removed (1 worktree)"
  end

  describe "CLI parsing" do
    test "flags" do
      assert {"cleanup", args} =
               Hq.CLI.parse([
                 "cleanup",
                 "--yes",
                 "--keep",
                 "a",
                 "--keep",
                 "b c",
                 "--include-unrecorded"
               ])

      assert args["yes"] == true
      assert args["include_unrecorded"] == true
      assert args["keep"] == ["a", "b c"]
      assert args["cwd"] == File.cwd!()
    end

    test "dry run unless --yes" do
      assert {"cleanup", %{"yes" => false, "keep" => [], "include_unrecorded" => false}} =
               Hq.CLI.parse(["cleanup"])
    end

    test "a typo'd flag or stray argument is an error, not silently dropped" do
      assert {:error, message} = Hq.CLI.parse(["cleanup", "--yse"])
      assert message =~ "--yse"
      assert {:error, _} = Hq.CLI.parse(["cleanup", "boss-1"])
    end

    test "requires $HERDR_PANE_ID" do
      System.delete_env("HERDR_PANE_ID")
      assert {:error, %{"code" => "no_pane", "message" => msg}} = Hq.CLI.require_pane("cleanup")
      assert msg =~ "hq cleanup"
    end

    test "the dry-run command to run quotes --keep values" do
      text =
        Hq.Cleanup.render(%{
          "dry_run" => true,
          "caller" => "boss",
          "caller_pane" => "w1:p1",
          "repo" => "/r",
          "panes" => [],
          "worktrees" => [],
          "notes" => [],
          "command" => "hq cleanup --yes --keep 'b c'"
        })

      assert String.ends_with?(text, "hq cleanup --yes --keep 'b c'")
    end
  end

  defp eventually(fun, tries \\ 100) do
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
