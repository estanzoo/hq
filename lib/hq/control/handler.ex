defmodule Hq.Control.Handler do
  @moduledoc """
  Dispatches control-socket verbs.

  Pure request-in, response-out so the verbs can be tested without a socket.
  """

  @name_re ~r/^[a-z][a-z0-9_-]{0,31}$/

  @spec handle(map()) :: {:ok, map()} | {:error, map()}
  def handle(%{"verb" => "ping"}), do: {:ok, %{"pong" => true, "version" => Hq.version()}}

  def handle(%{"verb" => "ls"}), do: {:ok, %{"sessions" => Hq.SessionSup.list()}}

  def handle(%{"verb" => "send", "args" => %{"to" => to, "from" => from, "body" => body}}) do
    if Hq.Session.alive?(to) do
      :ok = Hq.Session.deliver(to, from, body)
      {:ok, %{"queued" => true, "to" => to}}
    else
      {:error,
       %{
         "code" => "unknown_target",
         "message" => "no live session named #{to}",
         "live" => live_names()
       }}
    end
  end

  def handle(%{"verb" => "inbox", "args" => %{"name" => name}}) do
    if Hq.Session.alive?(name) do
      {:ok, %{"pending" => Hq.Session.pending(name)}}
    else
      {:error, %{"code" => "unknown_target", "message" => name, "live" => live_names()}}
    end
  end

  def handle(%{"verb" => "release", "args" => %{"name" => name}}) do
    :ok = Hq.Roster.forget(name)
    {:ok, %{"released" => name}}
  end

  def handle(%{"verb" => "register", "args" => %{"name" => name, "pane_id" => pane_id}}) do
    cond do
      not Regex.match?(@name_re, name) ->
        {:error,
         %{
           "code" => "bad_name",
           "message" => "names must match [a-z][a-z0-9_-]{0,31}; got #{inspect(name)}"
         }}

      Hq.Session.alive?(name) ->
        {:error, %{"code" => "name_taken", "message" => name}}

      true ->
        with {:ok, _} <- Hq.Herdr.call("agent.rename", %{"target" => pane_id, "name" => name}),
             {:ok, _} <- Hq.Roster.adopt(name, pane_id) do
          {:ok, %{"name" => name, "pane_id" => pane_id}}
        else
          {:error, reason} ->
            {:error, %{"code" => "register_failed", "message" => inspect(reason)}}
        end
    end
  end

  def handle(%{"verb" => "spawn", "args" => args}), do: Hq.Spawner.spawn_agent(args)

  def handle(%{"verb" => verb}) do
    {:error, %{"code" => "unknown_verb", "message" => to_string(verb)}}
  end

  defp live_names, do: Hq.SessionSup.list() |> Enum.map(& &1["name"]) |> Enum.sort()
end
