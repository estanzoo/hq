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

  defstruct [
    :name,
    :pane_id,
    :cwd,
    :spawned_by,
    :events,
    :mailbox,
    status: "unknown",
    settling: false
  ]

  # -- API ------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :name)))
  end

  @spec via(String.t()) :: GenServer.name()
  def via(name), do: {:via, Registry, {Hq.Registry, name}}

  @spec deliver(String.t(), String.t(), String.t()) :: :ok
  def deliver(name, from, body), do: GenServer.call(via(name), {:deliver, from, body})

  @spec info(String.t()) :: map()
  def info(name), do: GenServer.call(via(name), :info)

  @spec pending(String.t()) :: [map()]
  def pending(name), do: GenServer.call(via(name), :pending)

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
    {:noreply, maybe_flush(%{state | status: status})}
  end

  # A reconnect can have missed transitions, so re-read rather than assume.
  def handle_info({:hq_events, :connected}, state) do
    {:noreply, state |> refresh_status() |> maybe_flush()}
  end

  def handle_info({:hq_events, :disconnected}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # -- Internals ------------------------------------------------------------

  defp maybe_flush(state), do: flush(state)

  defp flush(state) do
    if ready?(state) do
      {msgs, mailbox} = Hq.Mailbox.drain(state.mailbox)
      text = Hq.Envelope.render(msgs)

      # No `wait`: the Session learns the outcome from status events instead of
      # blocking its own mailbox on the call.
      case Hq.Herdr.call("agent.prompt", %{"target" => state.name, "text" => text}) do
        {:ok, _} ->
          %{state | mailbox: mailbox}

        {:error, reason} ->
          Logger.warning("hq: delivery to #{state.name} failed: #{inspect(reason)}")
          # Mailbox untouched — retried on the next ready transition.
          state
      end
    else
      state
    end
  end

  defp ready?(state), do: state.status in @ready and Hq.Mailbox.depth(state.mailbox) > 0

  defp refresh_status(state) do
    case Hq.Herdr.call("agent.get", %{"target" => state.name}) do
      {:ok, %{"agent" => %{"agent_status" => status}}} -> %{state | status: status}
      _ -> state
    end
  end
end
