defmodule Hq.SessionSup do
  @moduledoc """
  Supervises the live Sessions.

  Restart is `:transient`, so a crashed Session comes back and re-reads its
  state from Herdr and its mailbox file, while a deliberate stop stays stopped.
  An agent is an OS process owned by Herdr, so restarting a Session here never
  disturbs the agent it supervises.
  """
  use DynamicSupervisor

  def start_link(init_arg \\ :ok) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    spec = %{
      id: Keyword.fetch!(opts, :name),
      start: {Hq.Session, :start_link, [opts]},
      restart: :transient
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(name) do
    case Registry.lookup(Hq.Registry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  @spec list() :: [map()]
  def list do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        try do
          [GenServer.call(pid, :info, 2_000)]
        catch
          :exit, _ -> busy_entry(pid)
        end

      _ ->
        []
    end)
  end

  # A Session can legitimately be busy for up to 10s while it delivers a
  # message: the `agent.prompt` call it makes is bounded at 10s and runs on
  # the Session process itself, so a plain :info call can time out against a
  # perfectly healthy session. Dropping that session from the result here
  # would make it silently vanish from `hq ls`, indistinguishable from a
  # dead one. List it instead as "busy", recovering its name from the
  # Registry (which maps back from pid without touching the occupied
  # process) and leaving the fields we can't know without a reply as nil.
  # If the Registry entry is already gone too, the session has actually
  # exited between `which_children` and here — drop it, same as before.
  defp busy_entry(pid) do
    case Registry.keys(Hq.Registry, pid) do
      [name | _] ->
        [
          %{
            "name" => name,
            "pane_id" => nil,
            "cwd" => nil,
            "status" => "busy",
            "spawned_by" => nil,
            "mailbox" => nil
          }
        ]

      [] ->
        []
    end
  end
end
