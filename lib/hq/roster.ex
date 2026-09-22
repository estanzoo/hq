defmodule Hq.Roster do
  @moduledoc """
  Tracks which sessions hq supervises, and reaps them when their panes die.

  hq supervises only sessions it spawned or that explicitly registered. It does
  not adopt every agent it can see: adoption makes a session addressable, and
  typing a peer's message into a session the user is working in interactively
  would be intrusive. The global event subscription here is for reaping, not
  for recruiting.
  """
  use GenServer
  require Logger

  def start_link(_ \\ :ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec adopt(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def adopt(name, pane_id, opts \\ []) do
    entry = %{
      "name" => name,
      "pane_id" => pane_id,
      "cwd" => Keyword.get(opts, :cwd),
      "spawned_by" => Keyword.get(opts, :spawned_by)
    }

    case Hq.SessionSup.start_session(
           name: name,
           pane_id: pane_id,
           cwd: entry["cwd"],
           spawned_by: entry["spawned_by"]
         ) do
      {:ok, pid} ->
        remember(entry)
        {:ok, pid}

      error ->
        error
    end
  end

  @spec forget(String.t()) :: :ok
  def forget(name) do
    Hq.SessionSup.stop_session(name)
    write(Enum.reject(remembered(), &(&1["name"] == name)))
    :ok
  end

  @spec remembered() :: [map()]
  def remembered do
    case File.read(store_path()) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, entries} when is_list(entries) -> entries
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  # -- Server ---------------------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, events} =
      Hq.Herdr.Events.start_link(
        owner: self(),
        subscriptions: [%{"type" => "pane.exited"}, %{"type" => "pane.closed"}]
      )

    {:ok, %{events: events}, {:continue, :readopt}}
  end

  @impl true
  def handle_continue(:readopt, state) do
    live = live_panes()

    for entry <- remembered() do
      cond do
        Hq.Session.alive?(entry["name"]) ->
          :ok

        Map.get(live, entry["name"]) == nil ->
          Logger.info("hq: forgetting #{entry["name"]} — its agent is gone")
          forget(entry["name"])

        true ->
          adopt(entry["name"], Map.fetch!(live, entry["name"]),
            cwd: entry["cwd"],
            spawned_by: entry["spawned_by"]
          )
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:hq_event, kind, %{"pane_id" => pane_id}}, state)
      when kind in ["pane_exited", "pane_closed"] do
    for entry <- remembered(), entry["pane_id"] == pane_id do
      Logger.info("hq: reaping #{entry["name"]} — pane #{pane_id} is gone")
      forget(entry["name"])
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Internals ------------------------------------------------------------

  # %{name => pane_id} for every live NAMED agent. `name` is absent on unnamed
  # agents, so it must never be assumed present.
  defp live_panes do
    case Hq.Herdr.call("agent.list", %{}) do
      {:ok, %{"agents" => agents}} ->
        for %{"pane_id" => pane_id} = a <- agents,
            name = Map.get(a, "name"),
            is_binary(name),
            into: %{},
            do: {name, pane_id}

      _ ->
        %{}
    end
  end

  defp remember(entry) do
    others = Enum.reject(remembered(), &(&1["name"] == entry["name"]))
    write(others ++ [entry])
  end

  defp write(entries) do
    path = store_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(entries))
  end

  defp store_path, do: Path.join(Hq.Mailbox.root(), "sessions.json")
end
