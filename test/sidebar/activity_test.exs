defmodule Hq.Sidebar.ActivityTest do
  # Runs sidebar/activity.sh as Claude Code hooks would, with a fake `herdr` on
  # PATH that records each call. The script's own timings are cut to about a
  # second, so the background loop's work shows within a test.
  use ExUnit.Case, async: true

  @script Path.expand("../../sidebar/activity.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "hq-activity-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    # The fake answers `pane get` with the status in $root/status (default
    # working) and the agent in $root/agent (default claude; "none" leaves the
    # agent out), and appends every other call to $root/calls.
    # FAKE_HERDR_SLOW makes each call take that many seconds.
    File.write!(Path.join(bin, "herdr"), """
    #!/bin/bash
    sleep "${FAKE_HERDR_SLOW:-0}"
    if [ "$1 $2" = "pane get" ]; then
      status=$(cat #{root}/status 2>/dev/null || echo working)
      agent=$(cat #{root}/agent 2>/dev/null || echo claude)
      if [ "$agent" = none ]; then
        printf '{"result":{"pane":{"agent_status":"%s"}}}\\n' "$status"
      else
        printf '{"result":{"pane":{"agent_status":"%s","agent":"%s"}}}\\n' "$status" "$agent"
      fi
    else
      echo "$*" >> #{root}/calls
    fi
    """)

    File.chmod!(Path.join(bin, "herdr"), 0o755)

    env = %{
      "PATH" => bin <> ":" <> System.get_env("PATH"),
      "HERDR_PANE_ID" => "w1:p1",
      "HQ_ACTIVITY_DIR" => Path.join(root, "state"),
      "HQ_ACTIVITY_TICK" => "0.2",
      "HQ_ACTIVITY_SCRIPT_AFTER" => "1",
      "HQ_ACTIVITY_STALE_AFTER" => "3600",
      "HQ_ACTIVITY_CHECK_EVERY" => "0"
    }

    state = Path.join([root, "state", "w1_p1"])

    on_exit(fn ->
      # Ending the session ends its loop; kill it too in case a test failed
      # before that.
      case File.read(Path.join([state, "loop", "pid"])) do
        {:ok, pid} -> System.cmd("kill", [String.trim(pid)], stderr_to_stdout: true)
        _ -> :ok
      end

      File.rm_rf!(root)
    end)

    %{root: root, env: env, state: state}
  end

  defp hook(env, event, extra \\ %{}) do
    json = JSON.encode!(Map.merge(%{"hook_event_name" => event, "session_id" => "s1"}, extra))

    System.cmd("bash", ["-c", ~s(printf '%s' "$HOOK_JSON" | "$HOOK_SCRIPT")],
      env: Map.merge(env, %{"HOOK_JSON" => json, "HOOK_SCRIPT" => @script}),
      stderr_to_stdout: true
    )
  end

  defp bash_tool(env, event, id, extra \\ %{}),
    do: hook(env, event, Map.merge(%{"tool_name" => "Bash", "tool_use_id" => id}, extra))

  # The hooks of one Bash call with run_in_background, which Claude Code
  # answers at once with the shell's task id.
  defp background_shell(env, id, task) do
    bash_tool(env, "PreToolUse", id, %{"tool_input" => %{"run_in_background" => true}})

    bash_tool(env, "PostToolUse", id, %{
      "tool_input" => %{"run_in_background" => true},
      "tool_response" => %{"stdout" => "", "backgroundTaskId" => task}
    })
  end

  defp stop(env, running_shells \\ []) do
    tasks = for id <- running_shells, do: %{"id" => id, "type" => "shell", "status" => "running"}
    hook(env, "Stop", %{"background_tasks" => tasks})
  end

  defp calls(root) do
    case File.read(Path.join(root, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  defp tokens(root) do
    for c <- calls(root) do
      case Regex.run(~r/--token activity=(.*)$/, c) do
        [_, text] -> text
        nil -> if c =~ "--clear-token activity", do: :cleared, else: c
      end
    end
  end

  defp files(state, pattern), do: state |> Path.join(pattern) |> Path.wildcard()

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition not met in time")
      else
        Process.sleep(100)
        do_eventually(fun, deadline)
      end
    end
  end

  test "outside a Herdr pane a hook does nothing", %{root: root, env: env} do
    assert {"", 0} = hook(Map.put(env, "HERDR_PANE_ID", ""), "UserPromptSubmit")
    Process.sleep(500)
    refute File.exists?(Path.join(root, "state"))
    assert calls(root) == []
  end

  test "a hook prints nothing, because UserPromptSubmit output becomes context", %{env: env} do
    assert {"", 0} = hook(env, "UserPromptSubmit")
    assert {"", 0} = bash_tool(env, "PreToolUse", "t1")
    assert {"", 0} = bash_tool(env, "PostToolUse", "t1")
    assert {"", 0} = hook(env, "PostToolBatch", %{"tool_calls" => [%{"tool_use_id" => "t1"}]})
    assert {"", 0} = stop(env)
    assert {"", 0} = hook(env, "SessionEnd")
  end

  test "a turn shows coding time, and Stop clears it and ends the loop",
       %{root: root, env: env, state: state} do
    hook(env, "UserPromptSubmit")
    eventually(fn -> tokens(root) == ["📝 <1m"] end)

    stop(env)
    eventually(fn -> tokens(root) == ["📝 <1m", :cleared] end)
    eventually(fn -> not File.exists?(Path.join(state, "loop")) end)
  end

  test "a long Bash command shows script wait, then coding time again", %{root: root, env: env} do
    hook(env, "UserPromptSubmit")
    bash_tool(env, "PreToolUse", "t1")
    eventually(fn -> "⏳ <1m" in tokens(root) end)

    bash_tool(env, "PostToolUse", "t1")
    eventually(fn -> List.last(tokens(root)) == "📝 <1m" end)
    assert tokens(root) == ["📝 <1m", "⏳ <1m", "📝 <1m"]

    stop(env)
    eventually(fn -> List.last(tokens(root)) == :cleared end)
  end

  test "a failed or interrupted Bash command ends its script wait too", %{root: root, env: env} do
    hook(env, "UserPromptSubmit")
    bash_tool(env, "PreToolUse", "t1")
    eventually(fn -> "⏳ <1m" in tokens(root) end)

    bash_tool(env, "PostToolUseFailure", "t1")
    eventually(fn -> List.last(tokens(root)) == "📝 <1m" end)
    stop(env)
  end

  test "a Bash call that never ran ends with its batch", %{root: root, env: env, state: state} do
    # A call refused before it starts gets a PreToolUse but no PostToolUse.
    hook(env, "UserPromptSubmit")
    bash_tool(env, "PreToolUse", "t1")
    eventually(fn -> "⏳ <1m" in tokens(root) end)

    hook(env, "PostToolBatch", %{
      "tool_calls" => [%{"tool_name" => "Bash", "tool_use_id" => "t1"}]
    })

    eventually(fn -> List.last(tokens(root)) == "📝 <1m" end)
    assert files(state, "script-*") == []
    stop(env)
  end

  test "a short Bash command never shows script wait", %{root: root, env: env} do
    env = Map.put(env, "HQ_ACTIVITY_SCRIPT_AFTER", "3")
    hook(env, "UserPromptSubmit")
    eventually(fn -> tokens(root) == ["📝 <1m"] end)
    bash_tool(env, "PreToolUse", "t1")
    Process.sleep(500)
    bash_tool(env, "PostToolUse", "t1")
    Process.sleep(3_500)

    assert tokens(root) == ["📝 <1m"]
    stop(env)
  end

  test "a tool other than Bash is not a script wait", %{root: root, env: env, state: state} do
    hook(env, "UserPromptSubmit")
    eventually(fn -> tokens(root) == ["📝 <1m"] end)
    hook(env, "PreToolUse", %{"tool_name" => "Read", "tool_use_id" => "t1"})
    Process.sleep(1_500)

    assert files(state, "script-*") == []
    assert tokens(root) == ["📝 <1m"]
    stop(env)
  end

  test "a running turn keeps its start time, and long times show hours",
       %{root: root, env: env, state: state} do
    File.mkdir_p!(state)
    File.write!(Path.join(state, "turn-s1"), "#{System.os_time(:second) - 3_900}\n")

    hook(env, "UserPromptSubmit")
    eventually(fn -> tokens(root) == ["📝 1h05m"] end)
    stop(env)
  end

  test "a session started inside the pane does not end the turn around it",
       %{root: root, env: env} do
    hook(env, "UserPromptSubmit")
    eventually(fn -> tokens(root) == ["📝 <1m"] end)

    nested = %{"session_id" => "s2"}
    hook(env, "UserPromptSubmit", nested)
    hook(env, "Stop", nested)
    hook(env, "SessionEnd", nested)
    Process.sleep(1_000)
    assert tokens(root) == ["📝 <1m"]

    stop(env)
    eventually(fn -> List.last(tokens(root)) == :cleared end)
  end

  test "a background shell shows script wait while the session waits for it",
       %{root: root, env: env, state: state} do
    hook(env, "UserPromptSubmit")
    background_shell(env, "t1", "b1")
    assert files(state, "script-*") == []
    assert [_] = files(state, "bg-s1-b1")

    # The turn ends while the shell runs: the session now waits for it.
    stop(env, ["b1"])
    eventually(fn -> List.last(tokens(root)) == "⏳ <1m" end)

    # The shell ends: Claude Code wakes the session with a new prompt.
    hook(env, "UserPromptSubmit")
    eventually(fn -> List.last(tokens(root)) == "📝 <1m" end)

    stop(env)
    eventually(fn -> List.last(tokens(root)) == :cleared end)
    assert tokens(root) == ["📝 <1m", "⏳ <1m", "📝 <1m", :cleared]
    assert files(state, "bg-*") == []
  end

  test "a background shell ends with its session", %{root: root, env: env, state: state} do
    hook(env, "UserPromptSubmit")
    background_shell(env, "t1", "b1")
    stop(env, ["b1"])
    eventually(fn -> List.last(tokens(root)) == "⏳ <1m" end)

    hook(env, "SessionEnd")
    eventually(fn -> List.last(tokens(root)) == :cleared end)
    assert files(state, "bg-*") == []
  end

  test "a turn that Herdr reports idle twice ends, but a background shell stays",
       %{root: root, env: env, state: state} do
    env = Map.put(env, "HQ_ACTIVITY_STALE_AFTER", "0")
    File.write!(Path.join(root, "status"), "idle")

    hook(env, "UserPromptSubmit")
    background_shell(env, "t1", "b1")
    eventually(fn -> files(state, "turn-*") == [] end)
    eventually(fn -> List.last(tokens(root)) == "⏳ <1m" end)

    Process.sleep(1_000)
    assert [_] = files(state, "bg-s1-b1")
    stop(env)
  end

  test "all records end when the pane has no agent any more", %{
    root: root,
    env: env,
    state: state
  } do
    hook(env, "UserPromptSubmit")
    background_shell(env, "t1", "b1")
    stop(env, ["b1"])
    eventually(fn -> List.last(tokens(root)) == "⏳ <1m" end)

    File.write!(Path.join(root, "agent"), "none")
    eventually(fn -> List.last(tokens(root)) == :cleared end)
    assert files(state, "bg-*") == []
  end

  test "a turn that Herdr reports working is kept", %{root: root, env: env} do
    env = Map.put(env, "HQ_ACTIVITY_STALE_AFTER", "0")

    hook(env, "UserPromptSubmit")
    eventually(fn -> tokens(root) == ["📝 <1m"] end)
    # Several checks against Herdr run in this time; none may end the turn.
    Process.sleep(1_500)
    assert tokens(root) == ["📝 <1m"]
    stop(env)
  end

  test "a hook does not wait for a slow Herdr", %{env: env} do
    # Each fake Herdr call takes 3 s; a hook that waited for one would take longer.
    env = Map.put(env, "FAKE_HERDR_SLOW", "3")
    {micros, _} = :timer.tc(fn -> hook(env, "UserPromptSubmit") end)
    assert micros < 2_000_000
    stop(env)
  end

  test "hooks from one turn start only one loop", %{env: env, state: state} do
    hook(env, "UserPromptSubmit")
    pid = File.read!(Path.join([state, "loop", "pid"]))
    for id <- ~w(t1 t2 t3), do: bash_tool(env, "PreToolUse", id)

    assert File.read!(Path.join([state, "loop", "pid"])) == pid
    for id <- ~w(t1 t2 t3), do: bash_tool(env, "PostToolUse", id)
    stop(env)
  end
end
