defmodule FakeHerdr do
  @moduledoc """
  A real unix-socket server speaking Herdr's wire protocol.

  Mirrors the two protocol properties that constrain the client: exactly one
  request is answered per connection, and a connection that subscribes to
  events thereafter carries only events. A client that violates either will
  hang here, which is the point.
  """
  use GenServer

  defstruct [:path, :listen, calls: [], replies: %{}, subscribers: []]

  # -- API ------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def path(pid), do: GenServer.call(pid, :path)
  def stub(pid, method, result), do: GenServer.call(pid, {:stub, method, {:result, result}})
  def stub_error(pid, method, error), do: GenServer.call(pid, {:stub, method, {:error, error}})
  def calls(pid), do: GenServer.call(pid, :calls)
  def subscriber_count(pid), do: GenServer.call(pid, :subscriber_count)
  def push_event(pid, kind, data), do: GenServer.call(pid, {:push_event, kind, data})
  def drop_subscribers(pid), do: GenServer.call(pid, :drop_subscribers)

  # -- Server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs (closing the listen socket and removing
    # the .sock file) when our parent (the linked test process) exits, and so
    # the linked accept-loop's exit arrives as a handle_info message instead
    # of taking us down with it. See handle_info/2 below.
    Process.flag(:trap_exit, true)

    path = Keyword.get_lazy(opts, :path, &tmp_path/0)
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

    {:ok, %__MODULE__{path: path, listen: listen}}
  end

  @impl true
  def handle_call(:path, _from, st), do: {:reply, st.path, st}
  def handle_call(:calls, _from, st), do: {:reply, Enum.reverse(st.calls), st}
  def handle_call(:subscriber_count, _from, st), do: {:reply, length(st.subscribers), st}

  def handle_call({:stub, method, reply}, _from, st) do
    {:reply, :ok, %{st | replies: Map.put(st.replies, method, reply)}}
  end

  def handle_call({:push_event, kind, data}, _from, st) do
    line = [JSON.encode!(%{"event" => kind, "data" => data}), ?\n]
    Enum.each(st.subscribers, &:gen_tcp.send(&1, line))
    {:reply, :ok, st}
  end

  def handle_call(:drop_subscribers, _from, st) do
    Enum.each(st.subscribers, &:gen_tcp.close/1)
    {:reply, :ok, %{st | subscribers: []}}
  end

  @impl true
  def handle_cast({:request, req, sock}, st) do
    %{"id" => id, "method" => method} = req

    if is_binary(id) do
      params = Map.get(req, "params", %{})
      st = %{st | calls: [%{"method" => method, "params" => params} | st.calls]}
      dispatch(id, method, sock, st)
    else
      # The real Herdr server rejects a non-string id before it ever reaches
      # method dispatch, and replies with an empty string id. Mirror that:
      # the request is never recorded as a call.
      resp = %{
        "id" => "",
        "error" => %{"code" => "invalid_request", "message" => invalid_id_message(id)}
      }

      send_line(sock, resp)
      :gen_tcp.close(sock)
      {:noreply, st}
    end
  end

  # The parent's own EXIT never reaches here: OTP's gen_server loop routes
  # an EXIT from the process that called start_link straight to terminate/2
  # before we ever see it. In practice this clause only sees the linked
  # accept-loop process, so only benign reasons are swallowed; anything else
  # (e.g. a crashed match in accept_loop) stops the double loudly instead of
  # leaving it to hang every later connect with no attribution.
  @impl true
  def handle_info({:EXIT, _pid, reason}, st) when reason in [:normal, :shutdown] do
    {:noreply, st}
  end

  def handle_info({:EXIT, _pid, {:shutdown, _}}, st), do: {:noreply, st}
  def handle_info({:EXIT, _pid, reason}, st), do: {:stop, reason, st}

  @impl true
  def terminate(_reason, st) do
    :gen_tcp.close(st.listen)
    File.rm(st.path)
    :ok
  end

  # -- Internals ------------------------------------------------------------

  defp dispatch(id, method, sock, st) do
    case method do
      "events.subscribe" ->
        send_line(sock, %{"id" => id, "result" => %{"type" => "subscription_started"}})
        {:noreply, %{st | subscribers: [sock | st.subscribers]}}

      _ ->
        resp =
          case Map.get(st.replies, method) do
            {:result, result} -> %{"id" => id, "result" => result}
            {:error, error} -> %{"id" => id, "error" => error}
            nil -> %{"id" => id, "error" => %{"code" => "unstubbed", "message" => method}}
          end

        send_line(sock, resp)
        :gen_tcp.close(sock)
        {:noreply, st}
    end
  end

  # Only the integer case is verified against the live server's exact
  # message text; other non-string types get a reasonable but unverified
  # fallback since they aren't the shape a real client bug would produce.
  defp invalid_id_message(id) when is_integer(id) do
    "invalid request: invalid type: integer `#{id}`, expected a string"
  end

  defp invalid_id_message(id) do
    "invalid request: invalid type: #{inspect(id)}, expected a string"
  end

  defp send_line(sock, map), do: :gen_tcp.send(sock, [JSON.encode!(map), ?\n])

  defp accept_loop(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        pid = spawn(fn -> handle_conn(sock, server) end)
        :ok = :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept_loop(listen, server)

      {:error, _} ->
        :ok
    end
  end

  defp handle_conn(sock, server) do
    receive do
      :go -> :ok
    after
      1_000 -> :ok
    end

    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, line} ->
        # Hand ownership to the server so a subscription outlives this process.
        :ok = :gen_tcp.controlling_process(sock, server)
        GenServer.cast(server, {:request, JSON.decode!(line), sock})

      _ ->
        :gen_tcp.close(sock)
    end
  end

  defp tmp_path do
    rand = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    Path.join(System.tmp_dir!(), "fake-herdr-#{rand}.sock")
  end
end
