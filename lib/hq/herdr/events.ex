defmodule Hq.Herdr.Events do
  @moduledoc """
  One long-lived connection carrying a Herdr event subscription.

  Once `events.subscribe` succeeds, Herdr serves only events on that socket, so
  a subscription cannot share the request connection and each subscription set
  needs a socket of its own. That is why a Session owns one of these rather
  than there being a single shared event process.
  """
  use GenServer
  require Logger

  @backoff_ms [250, 500, 1_000, 2_000, 5_000]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      owner: Keyword.fetch!(opts, :owner),
      subscriptions: Keyword.fetch!(opts, :subscriptions),
      sock: nil,
      attempt: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case subscribe(state.subscriptions) do
      {:ok, sock} ->
        send(state.owner, {:hq_events, :connected})
        {:noreply, %{state | sock: sock, attempt: 0}}

      {:error, reason} ->
        Logger.warning("hq: events.subscribe failed: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, backoff(state.attempt))
        {:noreply, %{state | sock: nil, attempt: state.attempt + 1}}
    end
  end

  @impl true
  def handle_info({:tcp, sock, line}, %{sock: sock} = state) do
    case JSON.decode(line) do
      {:ok, %{"event" => kind, "data" => data}} ->
        send(state.owner, {:hq_event, normalize_kind(kind), data})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, sock}, %{sock: sock} = state) do
    send(state.owner, {:hq_events, :disconnected})
    Process.send_after(self(), :reconnect, backoff(state.attempt))
    {:noreply, %{state | sock: nil, attempt: state.attempt + 1}}
  end

  def handle_info({:tcp_error, sock, _}, %{sock: sock} = state) do
    handle_info({:tcp_closed, sock}, state)
  end

  def handle_info(:reconnect, state), do: {:noreply, state, {:continue, :connect}}
  def handle_info(_other, state), do: {:noreply, state}

  # Exposed (not private) so the socket-leak regression test can drive the
  # connect/subscribe path directly, many times, without waiting out the
  # GenServer's backoff schedule between retries. Not part of the public API.
  @doc false
  def subscribe(subscriptions) do
    case Hq.Herdr.connect(5_000) do
      {:ok, sock} ->
        case do_subscribe(sock, subscriptions) do
          :ok ->
            # Success: the caller now owns `sock` and must keep it open, so
            # there is no close here on this path.
            :ok = :inet.setopts(sock, active: true)
            {:ok, sock}

          {:error, reason} ->
            # Every failure branch below reaches here with `sock` still open
            # and still ours to close — close it before returning the error.
            :gen_tcp.close(sock)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Pure protocol logic: never touches the socket's lifecycle, only what is
  # written to and read from it. subscribe/1 above owns close-on-failure.
  defp do_subscribe(sock, subscriptions) do
    with :ok <-
           Hq.Herdr.send_request(sock, "events.subscribe", %{"subscriptions" => subscriptions}),
         {:ok, line} <- :gen_tcp.recv(sock, 0, 5_000),
         {:ok, %{"result" => %{"type" => "subscription_started"}}} <- JSON.decode(line) do
      :ok
    else
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp backoff(attempt), do: Enum.at(@backoff_ms, attempt, List.last(@backoff_ms))

  # Herdr is inconsistent about the `event` field it pushes: measured against
  # the live server (0.9.1, protocol 22), `pane.agent_status_changed` arrives
  # DOTTED (matching its subscription type verbatim), while `pane.closed`
  # arrives snake_case (`pane_closed`) — the two are not the same shape even
  # though both are pushed on subscriptions requested the same way. A local
  # test double that just mirrors whatever spelling the test hands it can't
  # catch this; it has to be checked against the real server, which is how
  # this was found. Normalizing once, here, at the boundary, means every
  # consumer (Session, Roster, …) matches a single canonical spelling and
  # stays correct regardless of which form Herdr happens to use for a given
  # event kind today or after some future Herdr release.
  defp normalize_kind(kind), do: String.replace(kind, ".", "_")
end
