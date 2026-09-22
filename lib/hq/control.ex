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
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :line,
        reuseaddr: true
      ])

    server = self()
    spawn_link(fn -> accept_loop(listen, server) end)
    Logger.info("hq: listening on #{path}")

    {:ok, %{listen: listen, path: path}}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    File.rm(state.path)
    :ok
  end

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
  end

  defp reply(sock, {:ok, result}),
    do: :gen_tcp.send(sock, [JSON.encode!(%{"ok" => true, "result" => result}), ?\n])

  defp reply(sock, {:error, error}),
    do: :gen_tcp.send(sock, [JSON.encode!(%{"ok" => false, "error" => error}), ?\n])
end
