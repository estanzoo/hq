defmodule Hq.Notify do
  @moduledoc """
  Tells a session's parent about something it cannot see.

  A notice is ordinary `[hq]` mail, not a special channel: there is no
  orchestrator identity in the system, only participants. A session with no
  live parent logs instead, so a notice is never silently dropped.
  """
  require Logger

  @spec tell(String.t() | nil, String.t()) :: :ok
  def tell(nil, body) do
    Logger.info("hq: #{body}")
    :ok
  end

  def tell(parent, body) do
    if Hq.Session.alive?(parent) do
      Hq.Session.deliver(parent, "hq", body)
    else
      Logger.info("hq: #{body}")
    end

    :ok
  end
end
