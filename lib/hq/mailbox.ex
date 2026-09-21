defmodule Hq.Mailbox do
  @moduledoc """
  Durable per-session FIFO queue.

  The file is the queue and memory is the cache. Without this, a daemon restart
  would drop every queued message with no trace — a silent-loss failure mode
  that is much worse than the cost of writing a few lines of JSON.
  """

  defstruct [:name, :path, pending: []]

  @type t :: %__MODULE__{name: String.t(), path: String.t(), pending: [map()]}

  @spec load(String.t()) :: t()
  def load(name) do
    path = path_for(name)

    pending =
      case File.read(path) do
        {:ok, body} ->
          body
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case JSON.decode(line) do
              {:ok, msg} -> [msg]
              _ -> []
            end
          end)

        {:error, _} ->
          []
      end

    %__MODULE__{name: name, path: path, pending: pending}
  end

  @spec enqueue(t(), String.t(), String.t()) :: t()
  def enqueue(%__MODULE__{} = mb, from, body) do
    msg = %{
      "from" => from,
      "body" => body,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Appending keeps FIFO obvious; queues here are a handful of messages at most.
    persist(%{mb | pending: mb.pending ++ [msg]})
  end

  @spec drain(t()) :: {[map()], t()}
  def drain(%__MODULE__{pending: []} = mb), do: {[], mb}

  def drain(%__MODULE__{pending: pending} = mb) do
    {pending, persist(%{mb | pending: []})}
  end

  @spec depth(t()) :: non_neg_integer()
  def depth(%__MODULE__{pending: pending}), do: length(pending)

  @spec path_for(String.t()) :: String.t()
  def path_for(name), do: Path.join([root(), "mailbox", "#{name}.ndjson"])

  @spec root() :: String.t()
  def root, do: Application.get_env(:hq, :root) || Path.expand("~/.hq")

  defp persist(%__MODULE__{path: path, pending: pending} = mb) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map(pending, &[JSON.encode!(&1), ?\n]))
    mb
  end
end
