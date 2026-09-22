defmodule Hq.CLI do
  @moduledoc """
  escript entry point and control-socket client.

  The user never starts the daemon: any verb autostarts it if the control
  socket is not answering. Several agents can call hq at the same instant, so
  the start is guarded by an O_EXCL lockfile; without it a burst of concurrent
  `hq send` calls would race to spawn competing daemons.
  """

  @lock_stale_ms 30_000

  def main(argv) do
    case argv do
      [] -> usage(0)
      ["-h" | _] -> usage(0)
      ["--help" | _] -> usage(0)
      ["daemon" | _] -> run_daemon()
      _ -> run_verb(argv)
    end
  end

  # -- argv -----------------------------------------------------------------

  @spec parse([String.t()]) :: {String.t(), map()}
  def parse(["send", to, body]), do: {"send", %{"to" => to, "body" => body}}
  def parse(["ls"]), do: {"ls", %{}}
  def parse(["inbox"]), do: {"inbox", %{}}
  def parse(["register", name]), do: {"register", %{"name" => name}}
  def parse(["release", name]), do: {"release", %{"name" => name}}

  def parse(["spawn", name | rest]) do
    {flags, _, _} =
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
             {:ok, line} <- :gen_tcp.recv(sock, 0, 60_000) do
          case JSON.decode(line) do
            {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
            {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
            _ -> {:error, %{"code" => "bad_response", "message" => line}}
          end
        else
          {:error, reason} -> {:error, %{"code" => "no_daemon", "message" => inspect(reason)}}
        end
      after
        :gen_tcp.close(sock)
      end
    else
      {:error, %{"code" => _} = err} -> {:error, err}
      {:error, reason} -> {:error, %{"code" => "no_daemon", "message" => inspect(reason)}}
    end
  end

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
      [:binary, active: false, packet: :line],
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

  # -- verbs ----------------------------------------------------------------

  defp run_daemon do
    {:ok, _} = Application.ensure_all_started(:hq)
    Process.sleep(:infinity)
  end

  defp run_verb(argv) do
    {verb, args} = parse(argv)
    args = decorate(args)

    case request(verb, args) do
      {:ok, result} ->
        IO.puts(render(verb, result))
        System.halt(0)

      {:error, error} ->
        IO.puts(:stderr, "hq: #{error["message"] || error["code"]}")

        case error["live"] do
          [_ | _] = live -> IO.puts(:stderr, "     live: #{Enum.join(live, ", ")}")
          _ -> :ok
        end

        System.halt(1)
    end
  end

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
      :io_lib.format("~-20s ~-8s mail:~-3s ~s", [
        s["name"],
        s["status"],
        mailbox_label(s["mailbox"]),
        s["cwd"] || ""
      ])
      |> to_string()
      |> String.trim_trailing()
    end)
  end

  def render("inbox", %{"pending" => []}), do: "inbox empty"

  def render("inbox", %{"pending" => pending}) do
    Enum.map_join(pending, "\n", &"#{&1["from"]}: #{&1["body"]}")
  end

  def render(_verb, result), do: JSON.encode!(result)

  # A busy session comes back from `Hq.SessionSup.list/0` with
  # `"mailbox" => nil` (its Session process is occupied delivering a
  # message, so its depth cannot be read without blocking `ls` itself). The
  # brief's renderer used `~B` (integer) unconditionally, which would raise
  # `ArgumentError` from `:io_lib.format/2` the first time `hq ls` ran while
  # any session was busy.
  defp mailbox_label(nil), do: "?"
  defp mailbox_label(n) when is_integer(n), do: Integer.to_string(n)

  defp usage(code) do
    IO.puts("""
    hq — message bus for Claude Code sessions in Herdr panes

      hq register <name>              name this pane and start supervising it
      hq spawn <name> [flags]         create a supervised agent
          --worktree --base <ref> --cwd <path> --kind <kind>
          --task "<text>" --permissive
      hq send <name> "<message>"      queue a message; delivered when idle
      hq ls                           live sessions, status, mailbox depth
      hq inbox                        what is queued for this pane
      hq release <name>               stop supervising (does not kill the agent)
      hq daemon                       run the daemon in the foreground
    """)

    System.halt(code)
  end
end
