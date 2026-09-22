defmodule Hq.Session do
  @moduledoc """
  Supervises one Claude Code agent: its status, its mailbox, and delivery.

  Delivery types into an *idle* agent's I/O, which means an arriving message is
  also the agent's wakeup. That is the whole loop — nothing polls, and no timer
  drives it. Only `pane.agent_status_changed` events pushed by Herdr do.
  """
  use GenServer
  require Logger

  @ready ~w(idle done)

  # A settle-triggered flush can occupy the Session process for up to the
  # bounded `agent.prompt` call in `flush/1` (10s). This gives a queued
  # caller room to wait out that worst case instead of crashing on the 5s
  # GenServer.call default.
  @call_timeout 30_000

  defstruct [
    :name,
    :pane_id,
    :cwd,
    :spawned_by,
    :events,
    :mailbox,
    status: "unknown",
    settling: false,
    notified_blocked: false
  ]

  # -- API ------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :name)))
  end

  @spec via(String.t()) :: GenServer.name()
  def via(name), do: {:via, Registry, {Hq.Registry, name}}

  @spec deliver(String.t(), String.t(), String.t()) :: :ok
  def deliver(name, from, body),
    do: GenServer.call(via(name), {:deliver, from, body}, @call_timeout)

  @spec info(String.t()) :: map()
  def info(name), do: GenServer.call(via(name), :info, @call_timeout)

  @spec pending(String.t()) :: [map()]
  def pending(name), do: GenServer.call(via(name), :pending, @call_timeout)

  @spec alive?(String.t()) :: boolean()
  def alive?(name), do: Registry.lookup(Hq.Registry, name) != []

  # -- Server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    pane_id = Keyword.fetch!(opts, :pane_id)

    {:ok, events} =
      Hq.Herdr.Events.start_link(
        owner: self(),
        subscriptions: [%{"type" => "pane.agent_status_changed", "pane_id" => pane_id}]
      )

    state = %__MODULE__{
      name: name,
      pane_id: pane_id,
      cwd: Keyword.get(opts, :cwd),
      spawned_by: Keyword.get(opts, :spawned_by),
      events: events,
      mailbox: Hq.Mailbox.load(name)
    }

    {:ok, state, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state) do
    {:noreply, state |> refresh_status() |> maybe_flush()}
  end

  @impl true
  def handle_call({:deliver, from, body}, _from, state) do
    mailbox = Hq.Mailbox.enqueue(state.mailbox, from, body)
    {:reply, :ok, maybe_flush(%{state | mailbox: mailbox})}
  end

  def handle_call(:info, _from, state) do
    info = %{
      "name" => state.name,
      "pane_id" => state.pane_id,
      "cwd" => state.cwd,
      "status" => state.status,
      "spawned_by" => state.spawned_by,
      "mailbox" => Hq.Mailbox.depth(state.mailbox)
    }

    {:reply, info, state}
  end

  def handle_call(:pending, _from, state), do: {:reply, state.mailbox.pending, state}

  # Match this Session's own pane. The subscription is per-pane, but pinning it
  # here means a Session can never act on another pane's transitions.
  @impl true
  def handle_info(
        {:hq_event, "pane_agent_status_changed",
         %{"pane_id" => pane_id, "agent_status" => status}},
        %{pane_id: pane_id} = state
      ) do
    {:noreply, state |> put_status(status) |> maybe_flush()}
  end

  # A reconnect can have missed transitions, so re-read rather than assume.
  def handle_info({:hq_events, :connected}, state) do
    {:noreply, state |> refresh_status() |> maybe_flush()}
  end

  def handle_info({:hq_events, :disconnected}, state), do: {:noreply, state}

  def handle_info(:settled, state) do
    state = %{state | settling: false} |> refresh_status()
    {:noreply, flush(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Internals ------------------------------------------------------------

  # Status flaps: an agent can report idle between two phases of one turn.
  # Waiting out a short window and then re-reading the authoritative status
  # keeps hq from typing into a session that is about to resume. The window
  # also batches a burst of messages into a single prompt, so three arrivals
  # start one turn instead of three.
  defp maybe_flush(%{settling: true} = state), do: state

  defp maybe_flush(state) do
    if ready?(state) do
      Process.send_after(self(), :settled, settle_ms())
      %{state | settling: true}
    else
      state
    end
  end

  defp settle_ms, do: Application.get_env(:hq, :settle_ms, 400)

  # hq never answers an approval dialog — a worker asking to do something
  # unexpected is a human decision. It does make sure someone is told, once,
  # rather than the mail sitting there silently.
  defp put_status(state, "blocked") do
    unless state.notified_blocked do
      held = Hq.Mailbox.depth(state.mailbox)

      Hq.Notify.tell(
        state.spawned_by,
        "#{state.name} is blocked on a dialog, #{held} " <>
          "message#{if held == 1, do: "", else: "s"} held. " <>
          "Inspect it with: herdr agent read #{state.name} --source detection"
      )
    end

    %{state | status: "blocked", notified_blocked: true}
  end

  defp put_status(state, status), do: %{state | status: status, notified_blocked: false}

  defp flush(state) do
    if ready?(state) do
      msgs = Hq.Mailbox.peek(state.mailbox)
      text = Hq.Envelope.render(msgs)

      # No `wait`: the Session learns the outcome from status events instead of
      # blocking its own mailbox on the call. Bounded well under the 30s
      # Herdr client default: a prompt is a local unix-socket write, so 10s
      # is already far beyond any healthy case, and it caps how long this
      # process can be occupied against a concurrent caller's patience above.
      case Hq.Herdr.call("agent.prompt", %{"target" => state.name, "text" => text},
             timeout: 10_000
           ) do
        {:ok, _} ->
          # Only drain (and persist the truncation) once delivery has actually
          # succeeded — draining first would durably erase mail the agent
          # never received.
          {_delivered, mailbox} = Hq.Mailbox.drain(state.mailbox)
          %{state | mailbox: mailbox}

        {:error, reason} ->
          Logger.warning("hq: delivery to #{state.name} failed: #{inspect(reason)}")
          # Nothing drained, nothing persisted — retried on the next ready transition.
          state
      end
    else
      state
    end
  end

  defp ready?(state), do: state.status in @ready and Hq.Mailbox.depth(state.mailbox) > 0

  # A refresh is a re-read of existing state, not a transition, so it must
  # never notify — that stays put_status/2's job. But it must not leave a
  # stale latch behind either: observing anything other than "blocked" here
  # means whatever blocked episode set notified_blocked (if any) is over, so
  # the next genuine blocked transition should notify again. Observing
  # "blocked" leaves the latch exactly as it was — set if we were already
  # blocked and known, unset if this is the first time we're learning of it
  # (in which case the *next* put_status/2 call, if any, decides).
  defp refresh_status(state) do
    case Hq.Herdr.call("agent.get", %{"target" => state.name}) do
      {:ok, %{"agent" => %{"agent_status" => "blocked"}}} ->
        %{state | status: "blocked"}

      {:ok, %{"agent" => %{"agent_status" => status}}} ->
        %{state | status: status, notified_blocked: false}

      _ ->
        state
    end
  end
end
