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
         :ok <- prepare_env(pane_id, cwd, target_dir),
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

    Hq.Herdr.call("agent.start", params, timeout: 60_000)
  end

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
