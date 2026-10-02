defmodule Hq.Runs do
  @moduledoc """
  The durable record of who spawned what: one entry per worker,
  `%{"parent", "name", "pane_id", "worktree"}`.

  `hq cleanup` needs to know which panes and worktrees belong to the
  orchestrator asking. A live session's `spawned_by` answers that only while
  the worker is still supervised; once its agent exits and `Hq.Roster` reaps
  it, the worktree it leaves behind is no longer attributable to anyone. This
  record outlives the session — and the daemon — so a cleanup at the end of a
  feature still finds every worktree its orchestrator created.

  Written by `Hq.Control.Handler` after a successful `spawn` (never by
  `Hq.Spawner` itself), and pruned by `Hq.Cleanup` for each worker it fully
  cleans up. Keyed by worker name: a re-spawn of a reused name replaces the
  old entry, because the name now belongs to the new run.
  """

  @lock {__MODULE__, :write}

  @spec record(map()) :: :ok
  def record(%{"parent" => parent, "name" => name} = entry)
      when is_binary(parent) and is_binary(name) do
    locked(fn ->
      others = Enum.reject(all(), &(&1["name"] == name))
      write(others ++ [Map.take(entry, ["parent", "name", "pane_id", "worktree"])])
    end)
  end

  @spec all() :: [map()]
  def all do
    case File.read(path()) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, entries} when is_list(entries) -> Enum.filter(entries, &is_map/1)
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  @spec for_parent(String.t()) :: [map()]
  def for_parent(parent), do: Enum.filter(all(), &(&1["parent"] == parent))

  # Drops only entries that still name `parent`: a worker name re-spawned by a
  # different orchestrator in the meantime belongs to that run now.
  @spec drop(String.t(), [String.t()]) :: :ok
  def drop(_parent, []), do: :ok

  def drop(parent, names) do
    locked(fn ->
      write(Enum.reject(all(), &(&1["parent"] == parent and &1["name"] in names)))
    end)
  end

  @spec path() :: String.t()
  def path, do: Path.join(Hq.Mailbox.root(), "runs.json")

  # Each control request is served by its own process, so two spawns that
  # finish at the same instant would otherwise race their read-modify-write
  # and one record would be lost.
  defp locked(fun) do
    :global.trans({@lock, self()}, fun)
    :ok
  end

  # Write-temp-then-rename, as `Hq.Mailbox` does: a crash mid-write leaves the
  # previous file intact rather than a truncated one.
  defp write(entries) do
    path = path()
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(entries))
    File.rename!(tmp, path)
  end
end
