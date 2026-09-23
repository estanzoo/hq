defmodule Hq.EnvelopeTest do
  use ExUnit.Case, async: true

  defp msg(from, body), do: %{"from" => from, "body" => body, "at" => "2026-09-21T00:00:00Z"}

  test "renders a single message with its sender" do
    text = Hq.Envelope.render([msg("worker-a", "schema frozen")])

    assert text == "[hq] message from worker-a:\nschema frozen"
  end

  test "renders several messages as one block with a count" do
    text = Hq.Envelope.render([msg("worker-a", "one"), msg("worker-b", "two")])

    assert text == """
           [hq] 2 messages

           from worker-a:
           one

           from worker-b:
           two\
           """
  end
end
