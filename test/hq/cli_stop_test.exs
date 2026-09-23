defmodule Hq.CLIStopTest do
  use ExUnit.Case, async: false

  @moduledoc """
  `hq stop` / `hq restart` — the safe replacement for `pkill -f 'hq daemon'`.

  `pkill -f` matches a pattern against every process's FULL COMMAND LINE on
  the whole machine; the advice to use it once took down a live machine
  (terminal shells, editor helpers, and Electron processes that merely
  happened to mention the string all died alongside the daemon). These tests
  exist to prove the replacement never repeats that mistake: the signal
  fallback below only ever acts on a pid it has independently verified,
  never on a pattern match, and every scenario where it can't be sure
  refuses outright rather than guessing.

  No test here ever touches `~/.hq` or signals a process it did not itself
  spawn: every test gets its own temp `root`, and the one test that does
  send a real signal sends it only to a disposable decoy process this file
  creates and owns.
  """

  setup do
    root = Path.join(System.tmp_dir!(), "hq-cli-stop-test-#{System.unique_integer([:positive])}")
    Application.put_env(:hq, :root, root)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      # Every test that overrides these restores config/test.exs's own
      # no-op defaults, but belt-and-braces: no test here should ever leave
      # a real `kill` or `:init.stop/0` wired in for whatever runs next.
      Application.put_env(:hq, :stop_fun, fn -> :ok end)
      Application.put_env(:hq, :signal_fun, fn _pid -> :ok end)
    end)

    %{root: root}
  end

  # -- "no daemon running" / pid file missing ----------------------------------
  #
  # Doubles as the "pid file is missing" refusal case: with no control
  # socket answering AND no pid file on disk, the signal fallback must
  # conclude "no daemon is running" — a plain, non-error report — rather
  # than inventing a pid to signal.
  test "stop_daemon reports no daemon running when nothing is listening and no pid file exists" do
    test_pid = self()
    Application.put_env(:hq, :signal_fun, fn pid -> send(test_pid, {:signaled, pid}) end)

    refute File.exists?(Hq.Control.pid_path())

    assert {:no_daemon, "no daemon is running"} = Hq.CLI.stop_daemon()
    refute_received {:signaled, _}
  end

  # -- signal fallback: pid recorded but that process is not running ----------
  test "stop_daemon refuses to signal, and reports no daemon running, when the recorded pid is not running" do
    test_pid = self()
    Application.put_env(:hq, :signal_fun, fn pid -> send(test_pid, {:signaled, pid}) end)

    # `System.cmd/3` runs synchronously and waits for the child to exit
    # before returning, so by the time this line completes, the pid it
    # printed via `$$` is guaranteed to already be dead — no timing race,
    # and pids are not recycled fast enough on this OS for this to flake.
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    dead_pid = String.trim(output)

    File.write!(Hq.Control.pid_path(), dead_pid)

    assert {:no_daemon, message} = Hq.CLI.stop_daemon()
    assert message =~ "no daemon is running"
    assert message =~ dead_pid
    refute_received {:signaled, _}
  end

  # -- signal fallback: pid is running, but as something else entirely --------
  #
  # This is the exact failure mode the task brief calls out by name: "a
  # stale pid file whose number has been reused by an unrelated process must
  # never be signalled." A real, currently-running process is spawned here
  # (this test's own shell, doing nothing hq-related) so the check is
  # exercised against genuine `ps` output, not a fake.
  test "stop_daemon refuses to signal a pid whose command line does not look like hq" do
    test_pid = self()
    Application.put_env(:hq, :signal_fun, fn pid -> send(test_pid, {:signaled, pid}) end)

    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["30"]])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    pid = Integer.to_string(os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", pid], stderr_to_stdout: true) end)

    # Give the OS a moment to make sure `ps` sees the freshly spawned process.
    Process.sleep(50)

    File.write!(Hq.Control.pid_path(), pid)

    assert {:refused, message} = Hq.CLI.stop_daemon()
    assert message =~ pid
    assert message =~ "does not look like an hq daemon"
    refute_received {:signaled, _}

    Port.close(port)
  end

  # -- restart: stops a verified old daemon, starts a fresh one, reports both -
  test "restart_daemon signals a verified old daemon, starts a fresh one, and reports both pids" do
    {port, old_pid} = spawn_decoy_hq_daemon()
    Process.sleep(50)

    File.write!(Hq.Control.pid_path(), old_pid)

    Application.put_env(:hq, :signal_fun, fn pid -> System.cmd("kill", [pid]) end)

    on_exit(fn ->
      System.cmd("kill", ["-9", old_pid], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    fake_starter = fn ->
      File.write!(Hq.Control.pid_path(), "99999")
      :ok
    end

    assert {:restarted, ^old_pid, "99999"} = Hq.CLI.restart_daemon(fake_starter)
    assert old_pid != "99999"

    # The decoy really was signalled (not merely "verified and ignored") --
    # give the TERM a moment to land, then confirm it's gone.
    assert eventually(fn -> not process_running?(old_pid) end)
  end

  test "restart_daemon reports a nil old pid when no daemon was running to begin with" do
    refute File.exists?(Hq.Control.pid_path())

    fake_starter = fn ->
      File.write!(Hq.Control.pid_path(), "12345")
      :ok
    end

    assert {:restarted, nil, "12345"} = Hq.CLI.restart_daemon(fake_starter)
  end

  test "restart_daemon reports restart_failed, still naming the old pid, when the starter fails" do
    {port, old_pid} = spawn_decoy_hq_daemon()
    Process.sleep(50)
    File.write!(Hq.Control.pid_path(), old_pid)
    Application.put_env(:hq, :signal_fun, fn pid -> System.cmd("kill", [pid]) end)

    on_exit(fn ->
      System.cmd("kill", ["-9", old_pid], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    failing_starter = fn -> {:error, :boom} end

    assert {:restart_failed, ^old_pid, :boom} = Hq.CLI.restart_daemon(failing_starter)
  end

  # -- helpers ------------------------------------------------------------------

  # A throwaway script literally named "hq", invoked with "daemon" as its
  # argument, so its `ps -o command=` output genuinely looks like a real hq
  # daemon (confirmed against this OS's actual `ps` output: the shebang
  # interpreter becomes argv0, e.g. `/bin/sh /tmp/.../hq daemon`) without
  # this test file having to duplicate or fake `Hq.CLI`'s own verification
  # logic. This is the ONLY thing in this file that spawns a process meant
  # to pass the "looks like hq" check, and this test owns and kills it.
  defp spawn_decoy_hq_daemon do
    dir = Path.join(System.tmp_dir!(), "hq-decoy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script_path = Path.join(dir, "hq")
    File.write!(script_path, "#!/bin/sh\nsleep 30\n")
    File.chmod!(script_path, 0o755)

    port = Port.open({:spawn_executable, script_path}, [:binary, args: ["daemon"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, Integer.to_string(os_pid)}
  end

  defp process_running?(pid) do
    case System.cmd("ps", ["-p", pid, "-o", "pid="], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
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
