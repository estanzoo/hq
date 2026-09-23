defmodule Hq.Control do
  @moduledoc """
  Listener for the hq control socket.

  One request per connection, mirroring Herdr's own shape so there is one
  protocol convention in the system rather than two.
  """
  use GenServer
  require Logger

  def start_link(_ \\ :ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec socket_path() :: String.t()
  def socket_path, do: Path.join(Hq.Mailbox.root(), "control.sock")

  # Per-root (derived from `Hq.Mailbox.root()` exactly like `socket_path/0`),
  # never a fixed global path -- `Hq.Control` starts and stops many times
  # across the test suite, each test pointed at its own root via
  # `Application.put_env(:hq, :root, ...)`, and a shared pid file would let
  # one test's daemon see another test's pid and draw the wrong ownership
  # conclusion.
  @spec pid_path() :: String.t()
  def pid_path, do: Path.join(Hq.Mailbox.root(), "daemon.pid")

  @impl true
  def init(:ok) do
    # Trap exits so terminate/2 reliably runs (removing the .sock file) both
    # when a supervisor shuts this process down (Supervisor.terminate_child
    # sends a plain exit signal, which kills a non-trapping GenServer before
    # terminate/2 ever gets a chance to run) and when the linked accept-loop
    # exits. A prior task in this repo shipped a terminate/2 that never ran
    # for exactly this reason and leaked 25 socket files into $TMPDIR before
    # anyone noticed. See handle_info/2 below.
    Process.flag(:trap_exit, true)

    path = socket_path()
    pid_path = pid_path()
    File.mkdir_p!(Path.dirname(path))

    # Unconditionally deleting the socket file here (the old behaviour) is
    # exactly what let a stray `mix run` in this repo delete and rebind the
    # live daemon's socket out from under it: `init/1` never checked whether
    # anything actually still owned that path. A connect probe is the most
    # direct test of "is a daemon live here" -- if something answers, this
    # path is spoken for and we must not touch it. Only a socket nothing
    # answers on is safe to reclaim.
    if live_daemon?(path) do
      owner = read_pid(pid_path)

      Logger.error(
        "hq: a daemon is already running#{owner_suffix(owner)}, refusing to take over #{path}"
      )

      {:stop, {:socket_in_use, owner}}
    else
      # Stale: either no file, or a file with nothing listening behind it
      # (e.g. left behind by a daemon that crashed before terminate/2 ran).
      # Safe to reclaim.
      File.rm(path)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:ifaddr, {:local, path}},
          active: false,
          packet: :line,
          reuseaddr: true,
          # Default driver buffer truncates a `packet: :line` frame past ~9216
          # bytes — measured against this exact socket: 9044B arrives whole,
          # 12044B truncates, and the server then can't decode the (now
          # incomplete) JSON line and answers "unparseable". Agents paste diffs
          # and logs well past that; the real Herdr server accepts up to 60KB,
          # so this ceiling was ours alone. Accepted sockets inherit a listen
          # socket's options, so this one change covers every connection.
          buffer: 1_000_000
        ])

      my_pid = System.pid()
      File.write!(pid_path, my_pid)

      server = self()
      spawn_link(fn -> accept_loop(listen, server) end)
      Logger.info("hq: listening on #{path}")

      {:ok, %{listen: listen, path: path, pid_path: pid_path, pid: my_pid}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)

    # Only remove the socket (and pid) file if the pid file still names us.
    # By the time `terminate/2` runs, ownership may have already changed
    # hands: an orphaned daemon (see moduledoc history) can be killed well
    # after a second daemon has reclaimed the same path, and deleting the
    # file unconditionally here is exactly what let that second daemon's
    # own socket vanish out from under it, handing the path to a THIRD
    # daemon. Leaving both files alone when we are no longer the owner is
    # what stops that cascade.
    if owner?(state) do
      File.rm(state.path)
      File.rm(state.pid_path)
    end

    :ok
  end

  @spec live_daemon?(String.t()) :: boolean()
  defp live_daemon?(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 500) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp read_pid(pid_path) do
    case File.read(pid_path) do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp owner?(%{pid_path: pid_path, pid: pid}) do
    read_pid(pid_path) == pid
  end

  defp owner_suffix(nil), do: ""
  defp owner_suffix(pid), do: " (pid #{pid})"

  # The parent's own EXIT never reaches here: OTP's gen_server loop routes an
  # EXIT from the process that called start_link (our supervisor) straight to
  # terminate/2 before we ever see it. In practice this clause only sees the
  # linked accept-loop process, so only benign reasons are swallowed; anything
  # else (e.g. a crash inside accept_loop) stops this process loudly instead
  # of leaving the listener silently dead with no attribution.
  @impl true
  def handle_info({:EXIT, _pid, reason}, state) when reason in [:normal, :shutdown] do
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, {:shutdown, _}}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  defp accept_loop(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        pid = spawn(fn -> serve(sock) end)
        :ok = :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept_loop(listen, server)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock) do
    receive do
      :go -> :ok
    after
      1_000 -> :ok
    end

    # try/after (not with/else) closes the socket on every exit from this
    # function, including a parse failure and an exception raised while
    # building or sending the reply — with/else does not extend that
    # guarantee, since a binding made inside a `with` clause is not visible
    # to its `else`, and this repo has already leaked file descriptors twice
    # from exactly that gap.
    try do
      case :gen_tcp.recv(sock, 0, 10_000) do
        {:ok, line} ->
          case JSON.decode(line) do
            {:ok, req} -> reply(sock, dispatch(req))
            _ -> reply(sock, {:error, %{"code" => "bad_request", "message" => "unparseable"}})
          end

        {:error, _} ->
          :ok
      end
    after
      :gen_tcp.close(sock)
    end
  end

  defp dispatch(req) do
    Hq.Control.Handler.handle(Map.put_new(req, "args", %{}))
  rescue
    e -> {:error, %{"code" => "internal", "message" => Exception.message(e)}}
  catch
    # `rescue` only catches raised exceptions, not exits. `send`/`inbox`/
    # `release` all check `Hq.Session.alive?/1` (a Registry read) and then
    # `GenServer.call` through the same `:via` tuple — if the Session dies in
    # that window the call exits `:noproc` instead of raising, and without
    # this clause the connection would just drop with no envelope at all,
    # violating the "every request gets an ok/error envelope" contract.
    :exit, reason -> {:error, %{"code" => "internal", "message" => inspect(reason)}}
  end

  defp reply(sock, {:ok, result}),
    do: :gen_tcp.send(sock, [JSON.encode!(%{"ok" => true, "result" => result}), ?\n])

  defp reply(sock, {:error, error}),
    do: :gen_tcp.send(sock, [JSON.encode!(%{"ok" => false, "error" => error}), ?\n])
end
