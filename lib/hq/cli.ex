defmodule Hq.CLI do
  @moduledoc """
  escript entry point and control-socket client.

  The user never starts the daemon: any verb autostarts it if the control
  socket is not answering. Several agents can call hq at the same instant, so
  the start is guarded by an O_EXCL lockfile; without it a burst of concurrent
  `hq send` calls would race to spawn competing daemons.
  """

  @lock_stale_ms 30_000

  # I4: `hq spawn`'s single control-socket request is answered only once the
  # ENTIRE server-side spawn flow finishes (Hq.Spawner runs synchronously
  # inside Hq.Control.Handler). Its worst-case budget is two
  # `wait_for_shell` polls (150 attempts * 100ms default = 15s each, so 30s)
  # plus up to 8 `agent.start` attempts at a 60s Herdr timeout each (480s) —
  # 510s total. The old 60s recv here was shorter than even ONE of those
  # `agent.start` attempts, so a spawn that took its time (not a stuck one)
  # printed `hq: no_daemon` — implying the daemon had died — while it was
  # simply still working and would likely finish moments later. This must
  # clear the full 510s budget with room to spare.
  @request_timeout_ms 600_000

  def main(argv) do
    case argv do
      [] -> usage(0)
      ["-h" | _] -> usage(0)
      ["--help" | _] -> usage(0)
      ["daemon" | _] -> run_daemon()
      ["stop" | _] -> run_stop()
      ["restart" | _] -> run_restart()
      _ -> run_verb(argv)
    end
  end

  # -- argv -----------------------------------------------------------------

  @spec parse([String.t()]) :: {String.t(), map()} | {:error, String.t()}
  def parse(["send", to, body]), do: {"send", %{"to" => to, "body" => body}}

  # I2: a wrong-arity call to a KNOWN verb used to fall straight through to
  # the catch-all below, which discards every argument and sends the daemon
  # a bare `{"verb" => "send", "args" => %{}}` — no handler clause matches
  # that (the real `send` clause requires "to"/"from"/"body"), so it lands on
  # the generic `unknown_verb` catch-all and prints `hq: send`, naming
  # neither the real mistake (missing/unquoted args) nor the fix. The
  # likeliest slip — `hq send worker-a schema is frozen` with the message
  # left unquoted — parses as 4 extra args, not 2; this catches that shape
  # too, not just the missing-body case.
  def parse(["send" | rest]) do
    {:error,
     "send: expected `hq send <name> \"<message>\"` (quote a message with spaces); " <>
       "got #{length(rest)} argument(s)"}
  end

  def parse(["ls"]), do: {"ls", %{}}
  def parse(["inbox"]), do: {"inbox", %{}}

  # I3: `hq inbox worker-a` used to silently return the CALLER's own inbox
  # instead of erroring or resolving worker-a's — the extra argument was
  # simply discarded by the `[verb | _]` catch-all before this clause
  # existed. See the handler-side ordering fix (`Hq.Control.Handler`'s
  # "name" clause) for why the daemon now honors this rather than letting the
  # ambient `pane_id` `decorate/1` always attaches win instead.
  def parse(["inbox", name]), do: {"inbox", %{"name" => name}}

  def parse(["inbox" | rest]) do
    {:error, "inbox: expected `hq inbox` or `hq inbox <name>`; got #{length(rest)} argument(s)"}
  end

  def parse(["register", name]), do: {"register", %{"name" => name}}

  def parse(["register" | rest]) do
    {:error, "register: expected `hq register <name>`; got #{length(rest)} argument(s)"}
  end

  def parse(["release", name]), do: {"release", %{"name" => name}}

  def parse(["release" | rest]) do
    {:error, "release: expected `hq release <name>`; got #{length(rest)} argument(s)"}
  end

  def parse(["spawn", name | rest]) do
    {flags, _, invalid} =
      OptionParser.parse(rest,
        strict: [
          worktree: :boolean,
          permissive: :boolean,
          cwd: :string,
          base: :string,
          kind: :string,
          task: :string
        ]
      )

    case invalid do
      [] ->
        args = %{
          "name" => name,
          "worktree" => Keyword.get(flags, :worktree, false),
          "permissive" => Keyword.get(flags, :permissive, false)
        }

        args =
          Enum.reduce([:cwd, :base, :kind, :task], args, fn key, acc ->
            case Keyword.get(flags, key) do
              nil -> acc
              value -> Map.put(acc, to_string(key), value)
            end
          end)

        {"spawn", args}

      [_ | _] ->
        # I3: `--worktre` (a typo of `--worktree`) used to be silently
        # dropped -- OptionParser's third return element (the invalid-flag
        # list) was discarded via `{flags, _, _}` -- so the spawn proceeded
        # anyway as a plain pane, "succeeding" at the wrong thing instead of
        # failing loudly on the typo.
        bad = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)
        {:error, "spawn: unknown flag(s): #{bad}"}
    end
  end

  # `hq cleanup` is destructive, so its parse is strict: an unknown flag (a
  # typo of `--yes`, say) or a stray positional argument is an error rather
  # than silently dropped -- and a dropped `--keep` would remove something
  # the user asked to protect. The CLI's own working directory travels with
  # the request because the daemon's cwd is wherever it happened to start;
  # the repository is located from the caller's, never the daemon's.
  def parse(["cleanup" | rest]) do
    case OptionParser.parse(rest,
           strict: [yes: :boolean, keep: :keep, include_unrecorded: :boolean]
         ) do
      {flags, [], []} ->
        {"cleanup",
         %{
           "yes" => Keyword.get(flags, :yes, false),
           "include_unrecorded" => Keyword.get(flags, :include_unrecorded, false),
           "keep" => Keyword.get_values(flags, :keep),
           "cwd" => File.cwd!()
         }}

      {_, extra, []} ->
        {:error,
         "cleanup: unexpected argument(s): #{Enum.join(extra, " ")}; " <>
           "expected `hq cleanup [--yes] [--keep <worker-or-dir>]... [--include-unrecorded]`"}

      {_, _, invalid} ->
        bad = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)
        {:error, "cleanup: unknown flag(s): #{bad}"}
    end
  end

  def parse([verb | _]), do: {verb, %{}}

  # -- control socket -------------------------------------------------------

  @spec request(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def request(verb, args) do
    with :ok <- ensure_daemon(),
         {:ok, sock} <- connect() do
      # `with/else` does not expose a binding made earlier in the `with` (here,
      # `sock`) to its `else` clause, so a bare `with` covering send/recv too
      # would leak the socket on a send failure or a recv timeout -- exactly
      # the fd-leak shape `Hq.Control.serve/1` already had to fix once with
      # `try/after` (see its comments). Scoping `sock`'s lifetime to this
      # `try/after`, nested inside the outer `with` (which only covers
      # `ensure_daemon/0` and `connect/0`, neither of which ever has a socket
      # open when it fails), closes it on every exit from here on.
      try do
        with :ok <-
               :gen_tcp.send(sock, [JSON.encode!(%{"verb" => verb, "args" => args}), ?\n]),
             {:ok, line} <- :gen_tcp.recv(sock, 0, request_timeout_ms()) do
          case JSON.decode(line) do
            {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
            {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
            _ -> {:error, %{"code" => "bad_response", "message" => line}}
          end
        else
          # A `recv` timeout means the connection is (or was, until just now)
          # alive and the daemon simply hasn't answered yet -- the opposite
          # situation from every other failure this `with` can hit (a refused
          # or reset connection, both genuinely "no daemon there"). Reporting
          # it as `no_daemon` told the caller the daemon had died when it was
          # actually still working; keep the two apart.
          {:error, :timeout} ->
            {:error,
             %{
               "code" => "timeout",
               "message" =>
                 "the daemon did not respond within #{request_timeout_ms()}ms; a spawn " <>
                   "can legitimately take several minutes -- check `hq ls` before " <>
                   "assuming it failed"
             }}

          {:error, reason} ->
            {:error, %{"code" => "no_daemon", "message" => inspect(reason)}}
        end
      after
        :gen_tcp.close(sock)
      end
    else
      {:error, %{"code" => _} = err} -> {:error, err}
      {:error, reason} -> {:error, %{"code" => "no_daemon", "message" => inspect(reason)}}
    end
  end

  defp request_timeout_ms, do: Application.get_env(:hq, :request_timeout_ms, @request_timeout_ms)

  @spec ensure_daemon() :: :ok | {:error, term()}
  def ensure_daemon do
    case connect() do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} ->
        with_lock(fn ->
          # Re-check inside the lock: another caller may have just started it.
          case connect() do
            {:ok, sock} ->
              :gen_tcp.close(sock)
              :ok

            {:error, _} ->
              start_daemon()
              await_socket(100)
          end
        end)
    end
  end

  defp connect do
    :gen_tcp.connect(
      {:local, Hq.Control.socket_path()},
      0,
      # See Hq.Control's listen socket for why `buffer` is set: without it a
      # response line past ~9216 bytes (e.g. a large `hq inbox`) truncates
      # here, `JSON.decode` fails, and the caller sees a confusing
      # "bad_response" with mangled JSON on stderr instead of its answer.
      [:binary, active: false, packet: :line, buffer: 1_000_000],
      2_000
    )
  end

  defp with_lock(fun) do
    path = Path.join(Hq.Mailbox.root(), "daemon.lock")
    File.mkdir_p!(Path.dirname(path))
    clear_stale_lock(path)

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          fun.()
        after
          File.close(io)
          File.rm(path)
        end

      {:error, :eexist} ->
        # Another process is starting the daemon; wait for its socket.
        await_socket(150)
    end
  end

  defp clear_stale_lock(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        age_ms = (System.os_time(:second) - mtime) * 1_000
        if age_ms > @lock_stale_ms, do: File.rm(path)

      _ ->
        :ok
    end
  end

  defp start_daemon do
    exe = System.find_executable("hq") || :escript.script_name() |> to_string()
    log = Path.join(Hq.Mailbox.root(), "hq.log")

    System.cmd("/bin/sh", ["-c", "nohup #{exe} daemon >> #{log} 2>&1 &"], stderr_to_stdout: true)

    :ok
  end

  defp await_socket(0), do: {:error, :daemon_did_not_start}

  defp await_socket(tries) do
    case connect() do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} ->
        Process.sleep(50)
        await_socket(tries - 1)
    end
  end

  # -- stop / restart --------------------------------------------------------
  #
  # This exists so nobody ever has to reach for `pkill -f 'hq daemon'` again.
  # `pkill -f` matches a pattern against every process's FULL COMMAND LINE on
  # the whole machine, not just the daemon's -- the exact form of that advice
  # once took down a live machine (terminal shells, editor helpers and
  # Electron processes whose arguments happened to contain the string all
  # died alongside the daemon). Nothing below ever searches the process
  # table by pattern: the primary path asks the daemon to stop itself over
  # the socket it already answers on, and the signal fallback only ever acts
  # on a pid it has independently verified is genuinely hq's.

  @socket_gone_tries 100
  @socket_gone_poll_ms 20

  @spec stop_daemon() ::
          {:stopped, String.t(), :socket | :socket_unconfirmed | :signal}
          | {:no_daemon, String.t()}
          | {:refused, String.t()}
  def stop_daemon do
    # A raw request, not `request/2`: `request/2` calls `ensure_daemon/0`
    # first, which AUTOSTARTS a daemon when none answers -- exactly wrong for
    # `hq stop`, which must never bring up a daemon just to immediately stop
    # it. Failing to connect here means either nothing is listening, or
    # something is there but not answering; either way the signal fallback
    # (which does its own from-scratch liveness check) is what decides next,
    # not an autostart.
    case raw_request("stop", %{}) do
      {:ok, %{"pid" => pid}} ->
        case wait_for_socket_gone() do
          :ok -> {:stopped, pid, :socket}
          :timeout -> {:stopped, pid, :socket_unconfirmed}
        end

      {:error, _reason} ->
        case attempt_signal_stop() do
          {:ok, pid} -> {:stopped, pid, :signal}
          {:no_daemon, _} = result -> result
          {:refused, _} = result -> result
        end
    end
  end

  # `starter` defaults to the real `ensure_daemon/0` and exists only so a
  # test can substitute a fake that writes a distinguishable pid to
  # `Hq.Control.pid_path/0` without shelling out to a real second `hq`
  # process -- `restart_daemon/1`'s own job (stop, then read whatever pid
  # ends up on disk) is exercised for real either way.
  @spec restart_daemon((-> :ok | {:error, term()})) ::
          {:restarted, String.t() | nil, String.t() | nil}
          | {:restart_failed, String.t() | nil, term()}
          | {:refused, String.t()}
  def restart_daemon(starter \\ &ensure_daemon/0) do
    case stop_daemon() do
      {:refused, _message} = refused ->
        refused

      stop_result ->
        old_pid =
          case stop_result do
            {:stopped, pid, _via} -> pid
            _ -> nil
          end

        case starter.() do
          :ok -> {:restarted, old_pid, read_daemon_pid()}
          {:error, reason} -> {:restart_failed, old_pid, reason}
        end
    end
  end

  # Verifies a pid actually belongs to hq before anything is ever signalled.
  # Public so a test can drive it directly against a real (but disposable,
  # test-owned) process rather than only indirectly through `stop_daemon/0`.
  @spec verify_hq_daemon(String.t()) ::
          {:ok, String.t()} | {:error, :not_running} | {:error, :not_hq, String.t()}
  def verify_hq_daemon(pid) do
    case os_process_command(pid) do
      nil ->
        {:error, :not_running}

      command ->
        if hq_daemon_command?(command), do: {:ok, command}, else: {:error, :not_hq, command}
    end
  end

  # The signal fallback: only reached once the control socket has already
  # failed to answer `stop`. Reads the pid `Hq.Control`'s own `init/1` wrote
  # (see `pid_path/0`'s moduledoc), then refuses outright unless that exact
  # pid's own command line checks out -- a stale pid file whose number has
  # since been reused by an unrelated process must never be signalled, and
  # neither must an absent or already-dead one (both just mean no daemon is
  # running, not an error).
  @spec attempt_signal_stop() ::
          {:ok, String.t()} | {:no_daemon, String.t()} | {:refused, String.t()}
  defp attempt_signal_stop do
    pid_path = Hq.Control.pid_path()

    case File.read(pid_path) do
      {:error, _} ->
        {:no_daemon, "no daemon is running"}

      {:ok, contents} ->
        pid = String.trim(contents)

        case verify_hq_daemon(pid) do
          {:error, :not_running} ->
            {:no_daemon, "no daemon is running (stale pid file for pid #{pid} at #{pid_path})"}

          {:error, :not_hq, command} ->
            {:refused,
             "pid #{pid} (from #{pid_path}) does not look like an hq daemon " <>
               "(command: #{inspect(command)}) -- refusing to signal it. If this pid is " <>
               "something else entirely, remove #{pid_path} by hand; do not signal it " <>
               "yourself by pid or pattern."}

          {:ok, _command} ->
            signal_fun().(pid)
            {:ok, pid}
        end
    end
  end

  @spec os_process_command(String.t()) :: String.t() | nil
  defp os_process_command(pid) do
    case System.cmd("ps", ["-p", pid, "-o", "command="], stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          command -> command
        end

      _ ->
        nil
    end
  end

  # Both conditions must hold: the command line must name "daemon" (the one
  # argument every real `hq daemon` process runs with) AND look like hq
  # itself, either by containing the exact executable this CLI would itself
  # resolve to, or by having "hq" as a bare path component / leading word --
  # loose enough to survive PATH differing slightly between when the daemon
  # was started and when it is being stopped, without matching some
  # unrelated process that merely mentions "daemon" somewhere in its args.
  @spec hq_daemon_command?(String.t()) :: boolean()
  defp hq_daemon_command?(command) do
    String.contains?(command, "daemon") and
      (String.contains?(command, hq_executable()) or
         Regex.match?(~r{(^|/)hq(\s|$)}, command))
  end

  defp hq_executable do
    System.find_executable("hq") ||
      try do
        :escript.script_name() |> to_string()
      rescue
        _ -> "hq"
      end
  end

  defp signal_fun, do: Application.get_env(:hq, :signal_fun, &default_signal/1)

  defp default_signal(pid), do: System.cmd("kill", [pid], stderr_to_stdout: true)

  defp read_daemon_pid do
    case File.read(Hq.Control.pid_path()) do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp wait_for_socket_gone(tries \\ @socket_gone_tries) do
    cond do
      tries <= 0 ->
        :timeout

      not File.exists?(Hq.Control.socket_path()) ->
        :ok

      true ->
        Process.sleep(@socket_gone_poll_ms)
        wait_for_socket_gone(tries - 1)
    end
  end

  # A raw request bypassing `request/2`'s `ensure_daemon/0` autostart -- see
  # `stop_daemon/0` for why that matters here. Otherwise identical to
  # `request/2`'s own send/recv/decode, including its socket handling.
  defp raw_request(verb, args) do
    case connect() do
      {:ok, sock} ->
        try do
          with :ok <-
                 :gen_tcp.send(sock, [JSON.encode!(%{"verb" => verb, "args" => args}), ?\n]),
               {:ok, line} <- :gen_tcp.recv(sock, 0, request_timeout_ms()) do
            case JSON.decode(line) do
              {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
              {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
              _ -> {:error, %{"code" => "bad_response", "message" => line}}
            end
          else
            {:error, reason} -> {:error, reason}
          end
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_stop do
    case stop_daemon() do
      {:stopped, pid, :socket} ->
        IO.puts("hq: stopped daemon (pid #{pid}); socket removed")
        System.halt(0)

      {:stopped, pid, :socket_unconfirmed} ->
        IO.puts(
          "hq: daemon (pid #{pid}) acknowledged the stop request, but its socket is " <>
            "still present; it may just need another moment to finish shutting down"
        )

        System.halt(0)

      {:stopped, pid, :signal} ->
        IO.puts("hq: control socket was not answering; sent a stop signal to pid #{pid}")
        System.halt(0)

      {:no_daemon, message} ->
        IO.puts("hq: #{message}")
        System.halt(0)

      {:refused, message} ->
        IO.puts(:stderr, "hq: #{message}")
        System.halt(1)
    end
  end

  defp run_restart do
    case restart_daemon() do
      {:restarted, old_pid, new_pid} ->
        IO.puts("hq: restarted (old pid #{old_pid || "none"}, new pid #{new_pid || "unknown"})")
        System.halt(0)

      {:restart_failed, old_pid, reason} ->
        IO.puts(
          :stderr,
          "hq: stopped old daemon (pid #{old_pid || "none"}) but failed to start a new " <>
            "one: #{inspect(reason)}"
        )

        System.halt(1)

      {:refused, message} ->
        IO.puts(:stderr, "hq: #{message}")
        System.halt(1)
    end
  end

  # -- verbs ----------------------------------------------------------------

  defp run_daemon do
    case Application.ensure_all_started(:hq) do
      {:ok, _} ->
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts(:stderr, "hq: #{daemon_start_error(reason)}")
        System.halt(1)
    end
  end

  # `ensure_daemon/0` already probes the socket before ever spawning `hq
  # daemon`, so in practice this path is belt-and-braces -- but when
  # `Hq.Control.init/1` stops with `{:socket_in_use, pid}` (see its
  # moduledoc), the bare `{:ok, _} = Application.ensure_all_started(:hq)`
  # this replaced would raise a `MatchError` and dump a raw supervisor crash
  # report instead of telling the user what actually happened.
  # `Application.ensure_all_started/1` wraps a failed child's init deep
  # inside OTP's own supervisor-shutdown shape (roughly `{:hq, {:shutdown,
  # {:failed_to_start_child, Hq.Control, reason}}}`) -- searching for the
  # `{:socket_in_use, pid}` tuple rather than pattern-matching that exact
  # wrapper keeps this working even if a future OTP or supervisor-option
  # change alters how deep the wrapping goes. Public so a test can assert the
  # exact wording a user sees by feeding it a synthetic reason, without
  # calling `Application.ensure_all_started/1` for real -- an application's
  # start callback runs at most once per node per start, so exercising the
  # failure twice in one test run (once for `mix test` itself, once for the
  # test) is not reliably repeatable.
  @spec daemon_start_error(term()) :: String.t()
  def daemon_start_error(reason) do
    case find_socket_in_use(reason) do
      {:ok, pid} ->
        "a daemon is already running" <>
          if(pid, do: " (pid #{pid})", else: "") <>
          " -- serving #{Hq.Control.socket_path()}"

      :error ->
        "failed to start: #{inspect(reason)}"
    end
  end

  defp find_socket_in_use({:socket_in_use, pid}), do: {:ok, pid}

  defp find_socket_in_use(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> find_socket_in_use()

  defp find_socket_in_use(term) when is_list(term) do
    Enum.find_value(term, :error, fn el ->
      case find_socket_in_use(el) do
        {:ok, _} = found -> found
        :error -> nil
      end
    end)
  end

  defp find_socket_in_use(_), do: :error

  defp run_verb(argv) do
    case parse(argv) do
      {:error, message} ->
        IO.puts(:stderr, "hq: #{message}")
        System.halt(1)

      {verb, args} ->
        args = decorate(args)

        with :ok <- require_pane(verb),
             {:ok, result} <- request(verb, args) do
          IO.puts(render(verb, result))
          System.halt(0)
        else
          {:error, error} ->
            IO.puts(:stderr, "hq: #{error["message"] || error["code"]}")

            case error["live"] do
              [_ | _] = live -> IO.puts(:stderr, "     live: #{Enum.join(live, ", ")}")
              _ -> :ok
            end

            System.halt(1)
        end
    end
  end

  # `register` and `inbox` both resolve the caller's own session from
  # `$HERDR_PANE_ID` (see `put_self_name/1` above) rather than an explicit
  # name argument. Outside a Herdr pane that variable is unset, `decorate/1`
  # never attaches `pane_id`, no handler clause matches either verb, and the
  # request used to reach the daemon anyway and come back as a bare
  # `unknown_verb` naming the verb itself (e.g. `hq: register`) -- telling
  # the caller neither the real cause nor the remedy. Catching this
  # client-side, before `request/2` ever opens a socket, means the daemon is
  # never contacted for a request that cannot succeed, and the message
  # actually explains what to do. Public (like `decorate/1`) so a test can
  # assert on the `{:error, map()}` directly without going through
  # `System.halt/1`.
  @spec require_pane(String.t()) :: :ok | {:error, map()}
  def require_pane(verb) when verb in ["register", "inbox", "cleanup"] do
    case System.get_env("HERDR_PANE_ID") do
      nil ->
        {:error,
         %{
           "code" => "no_pane",
           "message" =>
             "not running inside a Herdr pane ($HERDR_PANE_ID is unset)\n" <>
               "     `hq register`, `hq inbox` and `hq cleanup` identify your session by " <>
               "its pane.\n" <>
               "     Start this session inside Herdr, or pass an explicit target."
         }}

      _pane ->
        :ok
    end
  end

  def require_pane(_verb), do: :ok

  # The args-decoration pipeline `run_verb/1` applies before every request:
  # the caller's own identity comes from the pane it is running in. Public
  # (rather than private, like the rest of this section) so tests can drive
  # `parse/1 -> decorate/1 -> request/2` exactly as `run_verb/1` does without
  # going through `main/1`, which calls `System.halt/1` and would kill the
  # test VM.
  @spec decorate(map()) :: map()
  def decorate(args), do: args |> put_self("from") |> put_self_name()

  defp put_self(args, key) do
    case System.get_env("HERDR_PANE_ID") do
      nil -> Map.put_new(args, key, "operator")
      pane -> Map.put_new(args, key, pane)
    end
  end

  # `hq register <name>` parses to `%{"name" => name}` and `hq inbox` parses
  # to `%{}` — both need `pane_id` attached from the environment regardless
  # of whether `"name"` is already present. An earlier version of this
  # function had a first clause that matched on `%{"name" => _}` and
  # returned the args untouched, so `hq register <name>` never got a
  # `pane_id` at all: the handler's `register` clause requires both `"name"`
  # and `"pane_id"`, the request fell through to the catch-all, and `hq
  # register` — the entry point to the whole system — always came back
  # `unknown_verb`. See `Hq.CLITest` for the end-to-end regression test.
  defp put_self_name(args) do
    case System.get_env("HERDR_PANE_ID") do
      nil -> args
      pane -> Map.put(args, "pane_id", pane)
    end
  end

  # Public (see `decorate/1` above for why): `run_verb/1` is the only caller
  # in production, but it is on the far side of `System.halt/1`, so tests
  # reach the rendering logic straight through this function instead.
  @spec render(String.t(), map()) :: String.t()
  def render("ls", %{"sessions" => []}), do: "no live sessions"

  def render("ls", %{"sessions" => sessions}) do
    Enum.map_join(sessions, "\n", fn s ->
      :io_lib.format("~-20s ~-8s mail:~-3s ~-14s ~s", [
        s["name"],
        s["status"],
        mailbox_label(s["mailbox"]),
        parent_label(s["spawned_by"]),
        elide_cwd(s["cwd"])
      ])
      |> to_string()
      |> String.trim_trailing()
    end)
  end

  def render("inbox", %{"pending" => []}), do: "inbox empty"

  def render("inbox", %{"pending" => pending}) do
    Enum.map_join(pending, "\n", &"#{&1["from"]}: #{&1["body"]}")
  end

  def render("cleanup", result), do: Hq.Cleanup.render(result)

  def render(_verb, result), do: JSON.encode!(result)

  # A busy session comes back from `Hq.SessionSup.list/0` with
  # `"mailbox" => nil` (its Session process is occupied delivering a
  # message, so its depth cannot be read without blocking `ls` itself). The
  # brief's renderer used `~B` (integer) unconditionally, which would raise
  # `ArgumentError` from `:io_lib.format/2` the first time `hq ls` ran while
  # any session was busy.
  defp mailbox_label(nil), do: "?"
  defp mailbox_label(n) when is_integer(n), do: Integer.to_string(n)

  # A session `hq register`ed directly (not spawned by another session) has
  # no `spawned_by`. Rendering `nil` (via plain string interpolation, e.g.
  # `"#{nil}"`) would print the literal word "nil" in the parent column,
  # indistinguishable from a session actually named that; render blank/"-"
  # instead so an unparented session is unambiguous at a glance.
  defp parent_label(nil), do: "-"
  defp parent_label(parent), do: parent

  # `cwd` is the one field here with no natural bound (a deep worktree path
  # can run well past a terminal's width and wrap the whole `hq ls` table).
  # Every other column is fixed-width; keep this one readable by eliding the
  # middle of a long path rather than letting it push (or wrap) everything
  # after it.
  @cwd_width 40

  defp elide_cwd(nil), do: ""

  defp elide_cwd(cwd) do
    if String.length(cwd) <= @cwd_width do
      cwd
    else
      keep = div(@cwd_width - 1, 2)
      String.slice(cwd, 0, keep) <> "…" <> String.slice(cwd, -keep, keep)
    end
  end

  defp usage(code) do
    IO.puts("""
    hq — message bus for Claude Code sessions in Herdr panes

      hq register <name>              name this pane and start supervising it
      hq spawn <name> [flags]         create a supervised agent
          --worktree --base <ref> --cwd <path> --kind <kind>
          --task "<text>" --permissive
      hq send <name> "<message>"      queue a message; delivered when idle
      hq ls                           live sessions, status, mailbox depth, parent
      hq inbox                        what is queued for this pane
      hq release <name>               stop supervising (does not kill the agent)
      hq cleanup [flags]              end of a feature: close this orchestrator's
                                      worker panes and remove their worktrees.
                                      DRY RUN unless --yes; prints the plan.
          --yes                       carry the plan out
          --keep <worker-or-dir>      protect something extra (repeatable)
          --include-unrecorded        also consider .worktree/<you>-* worktrees
                                      matched by name only (legacy runs)
                                      Never closes your own pane, never deletes
                                      a branch, keeps any worktree whose branch
                                      is on origin (the PR), and keeps dirty ones.
      hq stop                         stop the daemon (safe; never pkill/killall)
      hq restart                      stop the daemon, then start a fresh one
      hq daemon                       run the daemon in the foreground

    After ./install.sh rebuilds hq, a daemon already running keeps serving the
    OLD build until you `hq restart` -- it does not reload itself.
    """)

    System.halt(code)
  end
end
