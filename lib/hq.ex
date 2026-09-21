defmodule Hq do
  @moduledoc "Message bus for Claude Code sessions running in Herdr panes."

  @version Mix.Project.config()[:version]

  @spec version() :: String.t()
  def version, do: @version
end
