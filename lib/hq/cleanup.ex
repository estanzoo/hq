defmodule Hq.Cleanup do
  @moduledoc """
  `hq cleanup`: at the end of a feature, close the calling orchestrator's
  worker panes and remove their worktrees.

  This is the one destructive verb hq has, so it is built to keep whenever it
  is in doubt:

    * **Dry run by default.** Without `"yes" => true` nothing is closed or
      removed; the result is the plan.
    * **Only the caller's own workers** — the union of `Hq.Runs` (the durable
      spawn record) and live sessions whose `spawned_by` is the caller.
      Name-matched legacy worktrees (`.worktree/<caller>-*`) are considered
      only with `"include_unrecorded" => true`, and are marked as such.
    * **Never the caller's own pane**, never a pane whose agent is not idle,
      and never a close Herdr says needs worktree-group confirmation — hq
      never forces one.
    * **Worktrees go only through plain `git worktree remove`** (never
      `--force`), and only when the worktree is linked (not the primary
      checkout), is not the caller's own, is clean, is not in `--keep`, is not
      in use by anyone outside the caller's workers, and its branch is NOT on
      `origin`. Workers never push, so a branch on `origin` is the one the
      user pushed for review: the PR's worktree.
    * **Branches are never deleted.** Removing a clean worktree loses nothing;
      every commit stays on its branch.
    * **Herdr unreachable means nothing happens.** Panes cannot be judged
      without `agent.list`, exactly as `Hq.Roster.reconcile/0` refuses to
      reap on a Herdr failure.
  """

  # Anything else -- working, blocked, and also `unknown`, which is Herdr
  # failing to classify the agent, not the agent being finished -- keeps the
  # pane and its worktree.
  @closable_statuses ~w(idle done)

  @ls_remote_timeout_ms 20_000
  @git_env [{"GIT_TERMINAL_PROMPT", "0"}]

  @group_confirmation "close needs worktree-group confirmation"
  @primary_reason "the repository's primary checkout"
  @own_reason "orchestrator's own worktree"

  @spec run(map()) :: {:ok, map()} | {:error, map()}
  def run(args) do
    opts = %{
      yes: args["yes"] == true,
      keep: args |> Map.get("keep", []) |> List.wrap() |> Enum.filter(&is_binary/1),
      include_unrecorded: args["include_unrecorded"] == true
    }

    with {:ok, caller} <- caller(args),
         {:ok, git} <- find_git(),
         {:ok, repo} <- locate_repo(git, args["cwd"]),
         {:ok, agents} <- herdr_agents() do
      plan = plan(caller, git, repo, agents, opts)
      plan = if opts.yes, do: execute(plan, git, repo, caller), else: plan
      {:ok, result(plan, caller, repo, opts)}
    end
  end

  # -- preconditions --------------------------------------------------------

  # `Hq.Control.Handler.resolve_from/1` has already turned the caller's pane
  # id into its session name, falling back to "operator" for a pane hq does
  # not supervise. "operator" is every unregistered pane at once, so cleaning
  # up "its" workers would reach into runs nobody here owns.
  defp caller(%{"pane_id" => pane_id, "from" => name})
       when is_binary(pane_id) and is_binary(name) and name != "operator" do
    info =
      try do
        if Hq.Session.alive?(name), do: Hq.Session.info(name), else: nil
      catch
        :exit, _ -> nil
      end

    case info do
      %{"pane_id" => ^pane_id} ->
        {:ok, %{name: name, pane_id: pane_id}}

      _ ->
        not_registered(pane_id)
    end
  end

  defp caller(%{"pane_id" => pane_id}) when is_binary(pane_id), do: not_registered(pane_id)

  defp caller(_args) do
    {:error,
     %{
       "code" => "no_pane",
       "message" => "hq cleanup must be run from the orchestrator's own Herdr pane"
     }}
  end

  defp not_registered(pane_id) do
    {:error,
     %{
       "code" => "not_registered",
       "message" =>
         "pane #{pane_id} is not registered with hq, so it has no workers to clean up.\n" <>
           "     Run `hq cleanup` from the orchestrator that spawned them."
     }}
  end

  defp find_git do
    case System.find_executable("git") do
      nil ->
        {:error,
         %{"code" => "git_missing", "message" => "git is not on the daemon's PATH; nothing done"}}

      git ->
        {:ok, git}
    end
  end

  defp locate_repo(git, cwd) when is_binary(cwd) do
    with true <- File.dir?(cwd) || {:error, "#{cwd} is not a directory"},
         {:ok, common} <- git_out(git, ["-C", cwd, "rev-parse", "--git-common-dir"]),
         {:ok, listing} <- git_out(git, ["-C", cwd, "worktree", "list", "--porcelain", "-z"]),
         [primary | _] = worktrees <- parse_worktrees(listing) do
      toplevel =
        case git_out(git, ["-C", cwd, "rev-parse", "--show-toplevel"]) do
          {:ok, top} -> canonical(String.trim(top))
          _ -> nil
        end

      {:ok,
       %{
         cwd: cwd,
         common_dir: canonical(Path.expand(String.trim(common), cwd)),
         primary: primary.path,
         toplevel: toplevel,
         worktrees: worktrees
       }}
    else
      [] -> bad_repo(cwd, "git listed no worktrees")
      {:error, reason} -> bad_repo(cwd, reason)
    end
  end

  defp locate_repo(_git, _cwd), do: bad_repo(nil, "the request carried no working directory")

  defp bad_repo(cwd, reason) do
    {:error,
     %{
       "code" => "not_a_repo",
       "message" => "could not locate a git repository from #{inspect(cwd)}: #{reason}"
     }}
  end

  defp herdr_agents do
    case Hq.Herdr.call("agent.list", %{}) do
      {:ok, %{"agents" => agents}} when is_list(agents) ->
        {:ok, Enum.filter(agents, &is_map/1)}

      other ->
        reason =
          case other do
            {:error, r} -> r
            {:ok, r} -> {:unexpected_response, r}
          end

        {:error,
         %{
           "code" => "herdr_unreachable",
           "message" =>
             "Herdr could not be reached (#{inspect(reason)}), so no pane can be judged safe " <>
               "to close.\n     Nothing was closed and nothing was removed. Run `hq cleanup` " <>
               "again once Herdr answers."
         }}
    end
  end

  # -- plan -----------------------------------------------------------------

  defp plan(caller, git, repo, agents, opts) do
    sessions = Hq.SessionSup.list()
    {workers, notes} = workers(caller, sessions)
    keep = keep_matcher(opts.keep, repo.cwd)

    panes =
      workers
      |> Enum.map(&pane_item(&1, agents, caller, sessions, keep))
      |> Enum.reject(&is_nil/1)

    worker_paths =
      workers
      |> Enum.filter(&is_binary(&1["worktree"]))
      |> Enum.group_by(&canonical(&1["worktree"]), & &1["name"])

    unrecorded =
      if opts.include_unrecorded,
        do: unrecorded_worktrees(caller, repo, sessions, Map.keys(worker_paths)),
        else: []

    closing_panes = for p <- panes, p["action"] == "close", do: p["pane_id"]

    ctx = %{
      git: git,
      repo: repo,
      caller: caller,
      sessions: sessions,
      agents: agents,
      panes: panes,
      closing_panes: closing_panes,
      keep: keep
    }

    candidates =
      Enum.map(worker_paths, fn {path, names} -> {path, names, nil} end) ++
        Enum.map(unrecorded, fn {path, reason} -> {path, [], reason} end)

    remote = remote_branches(git, repo, candidates)

    worktrees =
      candidates
      |> Enum.map(fn {path, names, name_reason} ->
        worktree_item(path, names, name_reason, remote, ctx)
      end)
      |> Enum.sort_by(& &1["path"])

    notes =
      notes ++
        remote_notes(remote) ++
        unmatched_keep_notes(opts.keep, workers, worktrees, repo.cwd)

    %{workers: workers, panes: panes, worktrees: worktrees, notes: notes, remote: remote}
  end

  # The caller's workers: every recorded spawn of theirs, plus every live
  # session whose spawned_by names them. A recorded name now held by a live
  # session that is NOT the caller's (the name was reused by another run, or
  # the session is too busy to say whose it is) is left alone.
  defp workers(caller, sessions) do
    live = Map.new(sessions, &{&1["name"], &1})

    live_workers =
      for s <- sessions, s["spawned_by"] == caller.name, s["name"] != caller.name do
        %{"name" => s["name"], "pane_id" => s["pane_id"], "worktree" => s["cwd"]}
      end

    {recorded, notes} =
      Hq.Runs.for_parent(caller.name)
      |> Enum.reject(&(&1["name"] == caller.name))
      |> Enum.reduce({[], []}, fn r, {acc, notes} ->
        case Map.get(live, r["name"]) do
          nil ->
            {[r | acc], notes}

          %{"spawned_by" => parent} when parent == caller.name ->
            {[r | acc], notes}

          %{"status" => "busy"} ->
            {acc,
             notes ++
               [
                 "#{r["name"]}: left alone -- its session is busy, so hq " <>
                   "could not confirm it is still yours"
               ]}

          %{"spawned_by" => other} ->
            {acc,
             notes ++
               [
                 "#{r["name"]}: left alone -- that name now belongs to " <>
                   "#{other || "a registered session"}"
               ]}
        end
      end)

    merged =
      Enum.reduce(Enum.reverse(recorded), %{}, fn r, acc ->
        Map.put(acc, r["name"], %{
          "name" => r["name"],
          "pane_id" => r["pane_id"],
          "worktree" => r["worktree"]
        })
      end)

    merged =
      Enum.reduce(live_workers, merged, fn w, acc ->
        Map.update(acc, w["name"], w, fn rec ->
          %{
            rec
            | "pane_id" => w["pane_id"] || rec["pane_id"],
              "worktree" => rec["worktree"] || w["worktree"]
          }
        end)
      end)

    {merged |> Map.values() |> Enum.sort_by(& &1["name"]), notes}
  end

  # nil when the worker has no live pane left (nothing to close).
  defp pane_item(worker, agents, caller, sessions, keep) do
    name = worker["name"]
    by_name = Enum.find(agents, &(&1["name"] == name))
    recorded_pane = worker["pane_id"]

    cond do
      by_name ->
        pane_id = by_name["pane_id"]
        status = by_name["agent_status"]
        holder = Enum.find(sessions, &(&1["pane_id"] == pane_id and &1["name"] != name))

        reason =
          cond do
            pane_id == caller.pane_id -> "orchestrator's own pane"
            holder && holder["name"] != caller.name -> "in use by #{holder["name"]}"
            status not in @closable_statuses -> "agent is #{status || "of unknown status"}"
            keep.(name, worker["worktree"]) -> "--keep"
            true -> nil
          end

        pane_entry(name, pane_id, reason)

      recorded_pane && Enum.find(agents, &(&1["pane_id"] == recorded_pane)) ->
        other = Enum.find(agents, &(&1["pane_id"] == recorded_pane))
        pane_entry(name, recorded_pane, "pane now hosts #{other["name"] || "another agent"}")

      true ->
        nil
    end
  end

  defp pane_entry(name, pane_id, nil),
    do: %{"name" => name, "pane_id" => pane_id, "action" => "close", "reason" => nil}

  defp pane_entry(name, pane_id, reason),
    do: %{"name" => name, "pane_id" => pane_id, "action" => "kept", "reason" => reason}

  defp worktree_item(path, names, name_reason, remote, ctx) do
    entry = Enum.find(ctx.repo.worktrees, &(&1.path == path))

    base = %{
      "path" => path,
      "branch" => entry && entry.branch,
      "workers" => names,
      "name_only" => names == [],
      "match" => name_reason
    }

    cond do
      entry == nil and not File.dir?(path) ->
        Map.merge(base, %{"action" => "gone", "reasons" => []})

      entry != nil and entry.prunable and not File.dir?(path) ->
        Map.merge(base, %{"action" => "gone", "reasons" => []})

      true ->
        reasons = worktree_reasons(path, entry, names, name_reason, remote, ctx)
        action = if reasons == [], do: "remove", else: "kept"
        Map.merge(base, %{"action" => action, "reasons" => reasons})
    end
  end

  # Every reason that applies, not just the first: a worktree kept for being
  # dirty AND pushed should say both, so nobody "fixes" one and is surprised.
  defp worktree_reasons(path, entry, names, name_reason, remote, ctx) do
    %{repo: repo, git: git} = ctx

    structural =
      cond do
        entry == nil -> ["not a worktree of #{repo.primary}"]
        entry.path == repo.primary or entry.bare -> [@primary_reason]
        true -> []
      end

    own =
      if repo.toplevel && within?(repo.toplevel, path),
        do: [@own_reason],
        else: []

    keep =
      if Enum.any?(names, &ctx.keep.(&1, path)) or ctx.keep.(nil, path),
        do: ["--keep"],
        else: []

    from_panes =
      for p <- ctx.panes, p["name"] in names, p["action"] == "kept", uniq: true, do: p["reason"]

    in_use = in_use_reasons(path, names, ctx)

    git_reasons =
      if entry == nil do
        []
      else
        locked = if entry.locked, do: ["locked"], else: []

        detached =
          if entry.branch == nil and not entry.bare,
            do: ["detached HEAD (its commits may be on no branch)"],
            else: []

        dirty =
          case worktree_status(git, path) do
            :clean -> []
            :dirty -> ["dirty"]
            {:error, why} -> ["could not read its git status (#{why})"]
          end

        locked ++ detached ++ dirty ++ pushed_reasons(git, repo, entry.branch, remote)
      end

    Enum.uniq(
      List.wrap(name_reason) ++ structural ++ own ++ keep ++ from_panes ++ in_use ++ git_reasons
    )
  end

  # Anyone other than this worktree's own workers whose working directory is
  # inside it: another hq session (the caller included), or any Herdr pane
  # that is not a caller's worker pane about to be closed. This worktree's own
  # workers are judged by their pane's reason instead.
  defp in_use_reasons(path, names, ctx) do
    hq_users =
      for s <- ctx.sessions,
          s["name"] not in names,
          is_binary(s["cwd"]),
          within?(canonical(s["cwd"]), path),
          do: s["name"]

    herdr_users =
      for a <- ctx.agents,
          a["pane_id"] not in ctx.closing_panes,
          a["name"] not in names,
          cwd = a["foreground_cwd"] || a["cwd"],
          is_binary(cwd),
          within?(canonical(cwd), path),
          do: a["name"] || "pane #{a["pane_id"]}"

    (hq_users ++ herdr_users) |> Enum.uniq() |> Enum.map(&"in use by #{&1}")
  end

  defp pushed_reasons(_git, _repo, nil, _remote), do: []

  defp pushed_reasons(_git, _repo, branch, {:reachable, on_origin}) do
    if MapSet.member?(on_origin, branch), do: ["PR branch pushed to origin"], else: []
  end

  defp pushed_reasons(git, repo, branch, {:unreachable, _why}) do
    if local_push_evidence?(git, repo, branch),
      do: ["PR branch pushed to origin (judged from local refs: origin was unreachable)"],
      else: []
  end

  defp pushed_reasons(_git, _repo, _branch, :none), do: []

  # `.worktree/<caller>-<suffix>` worktrees no record or live session ties to
  # the caller. Returned as {path, reason-or-nil}; a non-nil reason keeps it.
  defp unrecorded_worktrees(caller, repo, sessions, known_paths) do
    prefix = caller.name <> "-"
    orchestrators = other_orchestrators(caller, sessions)
    records = Hq.Runs.all()

    for e <- repo.worktrees,
        e.path != repo.primary,
        e.path not in known_paths,
        Path.basename(Path.dirname(e.path)) == ".worktree",
        base = Path.basename(e.path),
        String.starts_with?(base, prefix) do
      reason =
        cond do
          base in orchestrators ->
            "named after orchestrator #{base}"

          o = Enum.find(orchestrators, &String.starts_with?(base, &1 <> "-")) ->
            "matches orchestrator #{o}'s naming"

          r = Enum.find(records, &(&1["name"] == base and &1["parent"] != caller.name)) ->
            "recorded as #{r["parent"]}'s worker"

          true ->
            nil
        end

      {e.path, reason}
    end
  end

  # Every orchestrator hq knows of other than the caller: anything that has
  # spawned a worker (live or recorded) and any registered session.
  defp other_orchestrators(caller, sessions) do
    parents =
      Enum.map(Hq.Runs.all(), & &1["parent"]) ++
        Enum.map(sessions, & &1["spawned_by"]) ++
        Enum.map(Hq.Roster.remembered(), & &1["spawned_by"])

    registered =
      for s <- sessions ++ Hq.Roster.remembered(),
          s["spawned_by"] == nil,
          s["status"] != "busy",
          do: s["name"]

    (parents ++ registered)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 in [caller.name, "operator"]))
    |> Enum.uniq()
  end

  # --keep <worker-or-dir>: a worker name, a worktree's directory name, or a
  # path (absolute, or relative to the caller's cwd). Over-matching here only
  # ever keeps more.
  defp keep_matcher([], _cwd), do: fn _name, _path -> false end

  defp keep_matcher(values, cwd) do
    paths = Enum.map(values, &canonical(Path.expand(&1, cwd)))

    fn name, path ->
      (name != nil and name in values) or
        (is_binary(path) and
           (Path.basename(canonical(path)) in values or canonical(path) in paths))
    end
  end

  defp unmatched_keep_notes(values, workers, worktrees, cwd) do
    for v <- values,
        single = keep_matcher([v], cwd),
        not Enum.any?(workers, &single.(&1["name"], &1["worktree"])),
        not Enum.any?(worktrees, &single.(nil, &1["path"])),
        do: "--keep #{v} matched nothing"
  end

  # -- origin ---------------------------------------------------------------

  # One `git ls-remote --heads origin <refs...>` for every candidate branch:
  # authoritative, and a single network round trip for a whole cleanup.
  defp remote_branches(git, repo, candidates) do
    branches =
      for {path, _, _} <- candidates,
          e = Enum.find(repo.worktrees, &(&1.path == path)),
          e && e.branch,
          uniq: true,
          do: e.branch

    if branches == [] do
      :none
    else
      args = [
        "-C",
        repo.cwd,
        "ls-remote",
        "--heads",
        "origin" | Enum.map(branches, &"refs/heads/#{&1}")
      ]

      task =
        Task.async(fn -> System.cmd(git, args, stderr_to_stdout: true, env: @git_env) end)

      case Task.yield(task, ls_remote_timeout()) || Task.shutdown(task, :brutal_kill) do
        {:ok, {out, 0}} ->
          heads =
            for line <- String.split(out, "\n"),
                [_, ref] <- [Regex.run(~r/^[0-9a-f]{40,64}\trefs\/heads\/(.+)$/, line)],
                into: MapSet.new(),
                do: ref

          {:reachable, heads}

        {:ok, {out, code}} ->
          {:unreachable, "git ls-remote exited #{code}: #{first_line(out)}"}

        _ ->
          {:unreachable, "git ls-remote timed out after #{ls_remote_timeout()}ms"}
      end
    end
  end

  defp ls_remote_timeout,
    do: Application.get_env(:hq, :ls_remote_timeout_ms, @ls_remote_timeout_ms)

  defp local_push_evidence?(git, repo, branch) do
    upstream? =
      match?(
        {:ok, remote} when remote != "",
        git_out(git, ["-C", repo.cwd, "config", "--get", "branch.#{branch}.remote"])
      )

    tracking? =
      match?(
        {:ok, _},
        git_out(git, [
          "-C",
          repo.cwd,
          "rev-parse",
          "--verify",
          "--quiet",
          "refs/remotes/origin/#{branch}"
        ])
      )

    upstream? or tracking?
  end

  defp remote_notes({:unreachable, why}) do
    [
      "origin was unreachable (#{why}). \"Pushed to origin\" was judged from local refs " <>
        "only: a configured upstream or a refs/remotes/origin/<branch> ref."
    ]
  end

  defp remote_notes(_), do: []

  # -- execute --------------------------------------------------------------

  defp execute(plan, git, repo, caller) do
    {panes, aborted} = close_panes(plan.panes)

    kept_pane_reasons =
      for p <- panes, p["action"] == "kept", into: %{}, do: {p["name"], p["reason"]}

    worktrees =
      Enum.map(plan.worktrees, fn wt ->
        late = for n <- wt["workers"], r = kept_pane_reasons[n], uniq: true, do: r

        cond do
          wt["action"] != "remove" ->
            wt

          aborted ->
            kept(wt, ["Herdr became unreachable mid-cleanup (#{aborted}); nothing removed"])

          late != [] ->
            kept(wt, late)

          # Re-read right before removing: the plan's status is a moment old.
          worktree_status(git, wt["path"]) != :clean ->
            kept(wt, ["dirty"])

          true ->
            remove_worktree(git, repo, wt)
        end
      end)

    prune =
      case git_out(git, ["-C", repo.cwd, "worktree", "prune"]) do
        {:ok, _} -> :ok
        {:error, why} -> {:error, why}
      end

    cleaned = cleaned_workers(plan.workers, panes, worktrees)
    Hq.Runs.drop(caller.name, cleaned)

    notes =
      case prune do
        :ok -> plan.notes
        {:error, why} -> plan.notes ++ ["git worktree prune failed: #{why}"]
      end

    %{plan | panes: panes, worktrees: worktrees, notes: notes}
  end

  defp close_panes(panes) do
    {closed, aborted} =
      Enum.reduce(panes, {[], nil}, fn
        %{"action" => "close"} = p, {acc, nil} ->
          case Hq.Herdr.call("pane.close", %{"pane_id" => p["pane_id"]}) do
            {:ok, _} ->
              {[%{p | "action" => "closed"} | acc], nil}

            {:error, %{"code" => "confirmation_required"}} ->
              {[%{p | "action" => "kept", "reason" => @group_confirmation} | acc], nil}

            {:error, %{"code" => code} = err} ->
              reason = "pane close failed: #{err["message"] || code}"
              {[%{p | "action" => "kept", "reason" => reason} | acc], nil}

            {:error, transport} ->
              why = inspect(transport)
              {[%{p | "action" => "kept", "reason" => "Herdr unreachable (#{why})"} | acc], why}
          end

        %{"action" => "close"} = p, {acc, aborted} ->
          reason = "not attempted: Herdr became unreachable (#{aborted})"
          {[%{p | "action" => "kept", "reason" => reason} | acc], aborted}

        p, {acc, aborted} ->
          {[p | acc], aborted}
      end)

    {Enum.reverse(closed), aborted}
  end

  # Plain `git worktree remove` -- never --force, so git itself refuses a
  # dirty or locked worktree even if every check above were wrong.
  defp remove_worktree(git, repo, wt) do
    case System.cmd(git, ["-C", repo.cwd, "worktree", "remove", wt["path"]],
           stderr_to_stdout: true,
           env: @git_env
         ) do
      {_, 0} -> Map.merge(wt, %{"action" => "removed", "reasons" => []})
      {out, _} -> kept(wt, ["git refused: #{first_line(out)}"])
    end
  end

  defp kept(wt, reasons), do: Map.merge(wt, %{"action" => "kept", "reasons" => reasons})

  # A worker is done with once its pane is closed (or already gone) and every
  # worktree it used is removed (or already gone). Anything kept stays in the
  # record so the next cleanup still finds it.
  defp cleaned_workers(workers, panes, worktrees) do
    for w <- workers,
        pane_done?(Enum.find(panes, &(&1["name"] == w["name"]))),
        Enum.all?(worktrees, &(w["name"] not in &1["workers"] or worktree_done?(&1))),
        do: w["name"]
  end

  # The primary checkout and the orchestrator's own worktree are never
  # cleanup's to remove, so a worker that only ever ran there is finished
  # once its pane is; keeping its record would list it again every time.
  defp worktree_done?(wt) do
    wt["action"] in ["removed", "gone"] or
      Enum.any?(wt["reasons"], &(&1 in [@primary_reason, @own_reason]))
  end

  defp pane_done?(nil), do: true
  defp pane_done?(pane), do: pane["action"] == "closed"

  # -- result + rendering ---------------------------------------------------

  defp result(plan, caller, repo, opts) do
    %{
      "dry_run" => not opts.yes,
      "caller" => caller.name,
      "caller_pane" => caller.pane_id,
      "repo" => repo.primary,
      "panes" => plan.panes,
      "worktrees" => plan.worktrees,
      "notes" => plan.notes,
      "command" => yes_command(opts)
    }
  end

  defp yes_command(opts) do
    flags =
      ["--yes"] ++
        if(opts.include_unrecorded, do: ["--include-unrecorded"], else: []) ++
        Enum.flat_map(opts.keep, &["--keep", shell_quote(&1)])

    Enum.join(["hq", "cleanup" | flags], " ")
  end

  defp shell_quote(s) do
    if Regex.match?(~r/^[A-Za-z0-9_.\/:@%+=,-]+$/, s),
      do: s,
      else: "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  @doc "Renders a cleanup result for the terminal."
  @spec render(map()) :: String.t()
  def render(r) do
    dry? = r["dry_run"]
    repo = r["repo"]
    panes = r["panes"] || []
    worktrees = Enum.reject(r["worktrees"] || [], &(&1["action"] == "gone"))

    {close_word, remove_word} =
      if dry?, do: {"will close", "will remove"}, else: {"closed", "removed"}

    {close_action, remove_action} = if dry?, do: {"close", "remove"}, else: {"closed", "removed"}

    to_close = Enum.filter(panes, &(&1["action"] == close_action))
    to_remove = Enum.filter(worktrees, &(&1["action"] == remove_action))
    kept_panes = Enum.filter(panes, &(&1["action"] == "kept"))
    kept_worktrees = Enum.filter(worktrees, &(&1["action"] == "kept"))

    header =
      if dry?,
        do: "hq cleanup -- DRY RUN for `#{r["caller"]}` in #{repo}. Nothing has been changed.",
        else: "hq cleanup for `#{r["caller"]}` in #{repo}."

    own = %{
      "name" => r["caller"],
      "pane_id" => r["caller_pane"],
      "reason" => "orchestrator's own pane"
    }

    kept_lines =
      Enum.map([own | kept_panes], fn p ->
        "  pane      #{pad(p["name"], 22)} #{pad(p["pane_id"], 8)} #{p["reason"]}"
      end) ++
        Enum.map(kept_worktrees, fn wt ->
          "  worktree  #{pad(rel(wt["path"], repo), 30)} #{pad(wt["branch"] || "-", 24)} " <>
            name_only_tag(wt) <> Enum.join(wt["reasons"], "; ")
        end)

    sections = [
      header,
      "",
      section(
        "#{close_word} (#{count(to_close, "pane")})",
        Enum.map(to_close, fn p ->
          "  #{pad(p["name"], 22)} #{p["pane_id"]}"
        end)
      ),
      section(
        "#{remove_word} (#{count(to_remove, "worktree")})",
        Enum.map(to_remove, fn wt ->
          "  #{pad(rel(wt["path"], repo), 30)} #{pad(wt["branch"] || "-", 24)} " <>
            String.trim_trailing(name_only_tag(wt))
        end)
      ),
      section("kept (#{length(kept_lines)})", kept_lines),
      "branches: none deleted. Removing a clean worktree loses nothing -- every commit " <>
        "stays on its branch."
    ]

    notes =
      case r["notes"] || [] do
        [] -> []
        notes -> ["", "notes:" | Enum.map(notes, &"  - #{&1}")]
      end

    tail =
      if dry?,
        do: ["", "To run this plan:", "  #{r["command"]}"],
        else: []

    (sections ++ notes ++ tail)
    |> Enum.join("\n")
    |> String.replace(~r/[ \t]+\n/, "\n")
  end

  defp section(title, []), do: "#{title}: nothing\n"
  defp section(title, lines), do: Enum.join(["#{title}:" | lines], "\n") <> "\n"

  defp count(list, noun), do: "#{length(list)} #{noun}#{if length(list) == 1, do: "", else: "s"}"

  defp name_only_tag(%{"name_only" => true}), do: "[matched by name only] "
  defp name_only_tag(_), do: ""

  defp pad(nil, n), do: String.pad_trailing("-", n)
  defp pad(s, n), do: String.pad_trailing(to_string(s), n)

  defp rel(path, repo) do
    if is_binary(repo) and String.starts_with?(path, repo <> "/"),
      do: Path.relative_to(path, repo),
      else: path
  end

  # -- git ------------------------------------------------------------------

  defp git_out(git, args) do
    case System.cmd(git, args, stderr_to_stdout: true, env: @git_env) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, "git #{Enum.join(args, " ")} exited #{code}: #{first_line(out)}"}
    end
  end

  defp worktree_status(git, path) do
    case System.cmd(git, ["-C", path, "status", "--porcelain"],
           stderr_to_stdout: true,
           env: @git_env
         ) do
      {"", 0} -> :clean
      {out, 0} -> if String.trim(out) == "", do: :clean, else: :dirty
      {out, _} -> {:error, first_line(out)}
    end
  end

  # `git worktree list --porcelain -z`: NUL-terminated lines, records
  # separated by an empty line. The first record is always the primary.
  defp parse_worktrees(listing) do
    listing
    |> String.split("\0")
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.reject(&(&1 == [] or hd(&1) == ""))
    |> Enum.map(&parse_worktree/1)
    |> Enum.reject(&is_nil(&1.path))
  end

  defp parse_worktree(lines) do
    Enum.reduce(
      lines,
      %{path: nil, branch: nil, bare: false, locked: false, prunable: false},
      fn
        "worktree " <> path, acc -> %{acc | path: canonical(path)}
        "branch refs/heads/" <> branch, acc -> %{acc | branch: branch}
        "bare", acc -> %{acc | bare: true}
        "locked" <> _, acc -> %{acc | locked: true}
        "prunable" <> _, acc -> %{acc | prunable: true}
        _, acc -> acc
      end
    )
  end

  defp first_line(out), do: out |> String.trim() |> String.split("\n") |> hd()

  # -- paths ----------------------------------------------------------------

  defp within?(inner, outer), do: inner == outer or String.starts_with?(inner, outer <> "/")

  # Symlinks resolved component by component: git reports worktree paths with
  # symlinks resolved (/tmp is /private/tmp on macOS), while a session's cwd is
  # whatever it was given. Comparing un-resolved paths would miss a match --
  # which, for an "in use" or "own worktree" check, would mean removing
  # something that should have been kept.
  @doc false
  @spec canonical(String.t()) :: String.t()
  def canonical(path), do: canonical(Path.expand(path), 0)

  defp canonical(path, depth) when depth > 32, do: path

  defp canonical(path, depth) do
    [root | parts] = Path.split(path)
    walk(root, parts, depth)
  end

  defp walk(acc, [], _depth), do: acc

  defp walk(acc, [part | rest], depth) do
    next = Path.join(acc, part)

    case :file.read_link(next) do
      {:ok, target} ->
        resolved = Path.expand(to_string(target), acc)
        canonical(Path.join([resolved | rest]), depth + 1)

      {:error, _} ->
        walk(next, rest, depth)
    end
  end
end
