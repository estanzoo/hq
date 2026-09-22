defmodule Hq.Spawner do
  @moduledoc """
  Creates a supervised agent: pane or worktree, environment, then the agent.

  The order is ported from bdherd (see reference/bdherd.bash) and each step is
  load-bearing. In particular the credential unset must happen before
  `agent.start`: stale ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN exports in
  the shell profile make Claude Code open a credential dialog and sit there
  blocked forever.
  """
  require Logger

  @name_re ~r/^[a-z][a-z0-9_-]{0,31}$/
  @unset "unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN"

  # Herdr requires the target pane to be idle at its interactive prompt
  # before `agent.start` accepts it. prepare_env/3 just sent shell commands
  # into the pane (worktree-env.sh, then the credential unset); for a moment
  # after each Enter the shell is still running that command, so `agent.start`
  # can land while the pane is briefly busy and get rejected with
  # "agent_pane_busy" even though the pane will be ready an instant later.
  # bdherd, the shell script this was ported from, papered over this with a
  # blind `sleep 2` before starting the agent (reference/bdherd.bash:214-218)
  # — too slow when the pane settles quickly, too short under load. Retry
  # ONLY that specific error a bounded number of times instead, with a short
  # pause between attempts: 8 attempts is roughly a 10s worst-case budget
  # once Herdr's own response time under load is counted alongside our
  # sleeps, without ever blocking a pane that is already available.
  @pane_busy_attempts 8

  # Herdr's pane.split / worktree.create returns as soon as the pane exists,
  # not once its shell is usable: a fresh zsh still runs its own startup
  # (.zprofile's path_helper, etc.) for roughly half a second afterwards. In
  # that window `pane.process_info` reports more than one foreground
  # process, and Herdr rightly refuses `agent.start` against the pane —
  # empirically this is not a rare race, it is the first-spawn case every
  # time. The pane_busy retry below (ported from the previous fix, kept as a
  # backstop) treated this as a brief post-command busy window and retried
  # agent.start blindly; it did not touch the real cause because the pane
  # was never written to correctly in the first place — hq itself was
  # sending prepare_env's commands into a shell that had not reached its
  # prompt yet. Poll until the pane settles to exactly one foreground
  # process — the shell itself — before writing anything into it at all,
  # and again after prepare_env's commands (which briefly occupy the shell
  # the same way) and before agent.start. 150 attempts at the default 100ms
  # poll interval is a 15s worst-case budget; observed settle time against a
  # real server was ~0.46s.
  @pane_ready_attempts 150

  @spec spawn_agent(map()) :: {:ok, map()} | {:error, map()}
  def spawn_agent(%{"name" => name} = args) do
    cond do
      not Regex.match?(@name_re, name) ->
        {:error,
         %{
           "code" => "bad_name",
           "message" => "names must match [a-z][a-z0-9_-]{0,31}; got #{inspect(name)}"
         }}

      Hq.Session.alive?(name) ->
        {:error, %{"code" => "name_taken", "message" => name}}

      Map.get(args, "from") == name ->
        {:error,
         %{
           "code" => "self_spawn",
           "message" => "a session cannot be spawned_by itself: #{inspect(name)}"
         }}

      true ->
        do_spawn(name, args)
    end
  end

  def spawn_agent(_), do: {:error, %{"code" => "bad_request", "message" => "name is required"}}

  @spec preamble(String.t()) :: String.t()
  def preamble(name) do
    """
    [hq] You are `#{name}`, one of several Claude Code sessions coordinated by hq.

    You can message any other live session directly:
      hq send <name> "<message>"   queue a message; it is typed into their
                                   session the moment they go idle
      hq ls                        who is live, their status and mailbox depth
      hq inbox                     what is queued for you

    Mail from a peer arrives prefixed `[hq]`. Anything without that prefix is
    from your own operator. Peers are working in parallel, so tell them what you
    have decided rather than waiting to be asked.
    """
  end

  # -- Internals ------------------------------------------------------------

  defp do_spawn(name, args) do
    cwd = Map.get(args, "cwd")

    with {:ok, pane_id, target_dir} <- make_pane(name, args, cwd),
         :ok <- wait_for_shell(pane_id),
         :ok <- prepare_env(pane_id, cwd, target_dir),
         :ok <- wait_for_shell(pane_id),
         {:ok, _} <- start_agent(name, pane_id, args),
         {:ok, _pid} <- Hq.Roster.adopt(name, pane_id, cwd: cwd, spawned_by: args["from"]) do
      first_message(name, args)
      {:ok, %{"name" => name, "pane_id" => pane_id}}
    else
      # Every failure reachable here — a raw Herdr protocol error from
      # make_pane/prepare_env/start_agent, or a non-map reason from
      # Roster.adopt — is wrapped uniformly as spawn_failed rather than
      # passed through: an upstream error map happens to carry its own
      # "code" key (e.g. "agent_not_ready"), and forwarding it unchanged
      # would let it collide with hq's own error codes.
      {:error, reason} ->
        Logger.warning("hq: spawn of #{name} failed: #{inspect(reason)}")
        {:error, %{"code" => "spawn_failed", "message" => inspect(reason)}}
    end
  end

  # bdherd creates the worktree at a deterministic path under the source
  # checkout ($REPO/.worktree/$slug) and later runs the env script AGAINST
  # THAT PATH, not against $REPO. Mirror both halves here: compute (or take
  # the caller's) target path, ask Herdr to create the worktree there, and
  # hand that path — not `cwd` — back to the caller so prepare_env can point
  # the script at the right directory.
  defp make_pane(name, %{"worktree" => true} = args, cwd) do
    default_path = cwd && Path.join([cwd, ".worktree", name])
    path = Map.get(args, "path", default_path)

    params =
      %{
        "branch" => "agent/#{name}",
        "base" => Map.get(args, "base", "main"),
        "label" => name,
        "focus" => false
      }
      |> maybe_put("cwd", cwd)
      |> maybe_put("path", path)

    case Hq.Herdr.call("worktree.create", params) do
      {:ok, %{"root_pane" => %{"pane_id" => pane_id}} = result} ->
        {:ok, pane_id, worktree_path(result, path)}

      {:ok, other} ->
        {:error, {:no_pane_in_response, other}}

      error ->
        error
    end
  end

  defp make_pane(_name, _args, cwd) do
    params = %{"direction" => "right", "focus" => false} |> maybe_put("cwd", cwd)

    case Hq.Herdr.call("pane.split", params) do
      {:ok, %{"pane" => %{"pane_id" => pane_id}}} -> {:ok, pane_id, cwd}
      {:ok, other} -> {:error, {:no_pane_in_response, other}}
      error -> error
    end
  end

  # Herdr's `worktree_created` response carries the authoritative location at
  # `result.worktree.path` (`WorktreeInfo.path` is a required field per the
  # API schema) — prefer it over what we asked for, since Herdr may adjust
  # it. A spawn must not fail just because a response (or a test stub)
  # happens to omit it, so fall back to the path we requested.
  defp worktree_path(%{"worktree" => %{"path" => path}}, _requested) when is_binary(path),
    do: path

  defp worktree_path(_result, requested), do: requested

  # This monorepo derives per-checkout compose ports from the checkout directory
  # name; without this the new worktree's apps collide with every other
  # checkout's. Failure is not fatal — most repos have no such script.
  #
  # The script itself always lives in the SOURCE checkout (`cwd`), but it
  # must run AGAINST the directory the agent will actually work in
  # (`target_dir`): for a plain pane.split those are the same directory, but
  # for a worktree spawn they are not — running it against `cwd` instead of
  # the new worktree derives ports for the wrong checkout and defeats the
  # reason this step exists.
  defp prepare_env(pane_id, cwd, target_dir) do
    script = cwd && Path.join(cwd, "tools/worktree-env.sh")

    if script && File.exists?(script) do
      run(pane_id, "#{script} #{target_dir} >/dev/null 2>&1 || true")
    end

    run(pane_id, @unset)
  end

  # Polls pane.process_info until the pane's only foreground process is its
  # own shell, i.e. it has reached an interactive prompt and is safe to
  # write into or hand to agent.start. Bounded by @pane_ready_attempts *
  # pane_poll_ms; on exhaustion this returns an error (never raises, never
  # loops forever) so the caller can fail the spawn cleanly instead of
  # writing into — or starting an agent against — a shell that may never
  # settle.
  defp wait_for_shell(pane_id), do: wait_for_shell(pane_id, @pane_ready_attempts)

  defp wait_for_shell(pane_id, 0) do
    {:error,
     %{
       "code" => "pane_not_ready",
       "message" => "pane #{pane_id} never reached an idle shell prompt"
     }}
  end

  defp wait_for_shell(pane_id, attempts_left) do
    if pane_shell_ready?(pane_id) do
      :ok
    else
      Process.sleep(pane_poll_ms())
      wait_for_shell(pane_id, attempts_left - 1)
    end
  end

  # The repeated `pid` variable is intentional: a single Elixir pattern
  # requires every occurrence of the same variable to match the same value,
  # so this is true only when the pane's foreground process list holds
  # exactly one entry and that entry's pid is the shell's own pid — not two
  # separately-checked conditions but one structural match.
  defp pane_shell_ready?(pane_id) do
    match?(
      {:ok, %{"process_info" => %{"foreground_processes" => [%{"pid" => pid}], "shell_pid" => pid}}},
      Hq.Herdr.call("pane.process_info", %{"pane_id" => pane_id})
    )
  end

  defp pane_poll_ms, do: Application.get_env(:hq, :pane_poll_ms, 100)

  defp run(pane_id, text) do
    case Hq.Herdr.call("pane.send_input", %{
           "pane_id" => pane_id,
           "text" => text,
           "keys" => ["enter"]
         }) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp start_agent(name, pane_id, args) do
    params = %{
      "name" => name,
      "kind" => Map.get(args, "kind", "claude"),
      "pane_id" => pane_id
    }

    params =
      if Map.get(args, "permissive") do
        Map.put(params, "args", ["--dangerously-skip-permissions"])
      else
        params
      end

    start_agent_call(params, @pane_busy_attempts)
  end

  # Any error other than agent_pane_busy — a bad name, a missing pane, an
  # agent that failed to come up — is a genuine failure and must surface on
  # the first attempt, unretried and unchanged.
  defp start_agent_call(params, attempts_left) do
    case Hq.Herdr.call("agent.start", params, timeout: 60_000) do
      {:error, %{"code" => "agent_pane_busy"}} when attempts_left > 1 ->
        Process.sleep(pane_settle_ms())
        start_agent_call(params, attempts_left - 1)

      # Bounded retries exhausted: return the last agent_pane_busy error
      # rather than swallowing it, so the caller sees the real reason.
      result ->
        result
    end
  end

  defp pane_settle_ms, do: Application.get_env(:hq, :pane_settle_ms, 300)

  defp first_message(name, args) do
    from = Map.get(args, "from", "hq")
    Hq.Session.deliver(name, from, preamble(name))

    case Map.get(args, "task") do
      nil -> :ok
      "" -> :ok
      task -> Hq.Session.deliver(name, from, task)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
