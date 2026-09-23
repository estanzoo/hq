defmodule Hq.Envelope do
  @moduledoc """
  Renders queued messages into the text typed into a session's I/O.

  The `[hq]` prefix is load-bearing: a receiving agent must be able to tell peer
  mail from its own operator's instructions at a glance.
  """

  @spec render([map()]) :: String.t()
  def render([%{"from" => from, "body" => body}]) do
    "[hq] message from #{from}:\n#{body}"
  end

  def render(msgs) do
    blocks =
      Enum.map_join(msgs, "\n\n", fn %{"from" => from, "body" => body} ->
        "from #{from}:\n#{body}"
      end)

    "[hq] #{length(msgs)} messages\n\n" <> blocks
  end
end
