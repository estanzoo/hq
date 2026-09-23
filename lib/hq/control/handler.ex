defmodule Hq.Control.Handler do
  @moduledoc """
  Dispatches control-socket verbs.

  Pure request-in, response-out so the verbs can be tested without a socket.
  """

  @name_re ~r/^[a-z][a-z0-9_-]{0,31}$/

  # `decorate/1` on the CLI side stamps every request's `"from"` with
  # `$HERDR_PANE_ID` (e.g. "w1:p1") — the caller's own identity is only known
  # by which pane it runs in, not by any session name. Every downstream
  # consumer (Hq.Spawner's spawned_by, Hq.Session's mailbox `from`,
  # Hq.Notify's parent lookup) expects a session NAME, keyed the same way
  # `inbox`'s pane_id branch already resolves its caller. Resolving here,
  # once, before any verb handler runs, is what makes that pane id usable
  # everywhere else instead of silently never matching anything.
  @spec handle(map()) :: {:ok, map()} | {:error, map()}
  def handle(%{"args" => args} = req) when is_map(args) do
    do_handle(%{req | "args" => resolve_from(args)})
  end

  def handle(req), do: do_handle(req)

  defp do_handle(%{"verb" => "ping"}), do: {:ok, %{"pong" => true, "version" => Hq.version()}}

  defp do_handle(%{"verb" => "ls"}), do: {:ok, %{"sessions" => Hq.SessionSup.list()}}

  defp do_handle(%{"verb" => "send", "args" => %{"to" => to, "from" => from, "body" => body}}) do
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

  # This clause must stay ahead of the `pane_id` one below: `decorate/1`
  # stamps EVERY request's args with `"pane_id"` (the caller's own pane)
  # regardless of whether the caller also gave an explicit target name, so
  # `hq inbox worker-a` arrives with both `"name" => "worker-a"` AND
  # `"pane_id" => <the caller's own pane>` present at once. An explicit name
  # names the request's TARGET and must win over the ambient `"pane_id"`, or
  # `hq inbox <name>` would silently return the CALLER's own inbox instead —
  # exactly the bug this ordering exists to prevent.
  defp do_handle(%{"verb" => "inbox", "args" => %{"name" => name}}) do
    if Hq.Session.alive?(name) do
      {:ok, %{"pending" => Hq.Session.pending(name)}}
    else
      {:error, %{"code" => "unknown_target", "message" => name, "live" => live_names()}}
    end
  end

  defp do_handle(%{"verb" => "inbox", "args" => %{"pane_id" => pane_id}}) do
    case Enum.find(Hq.SessionSup.list(), &(&1["pane_id"] == pane_id)) do
      nil ->
        {:error, %{"code" => "not_registered", "message" => "this pane is not supervised by hq"}}

      %{"name" => name} ->
        {:ok, %{"pending" => Hq.Session.pending(name)}}
    end
  end

  defp do_handle(%{"verb" => "release", "args" => %{"name" => name}}) do
    known? = Hq.Session.alive?(name) or Enum.any?(Hq.Roster.remembered(), &(&1["name"] == name))

    if known? do
      :ok = Hq.Roster.forget(name)
      {:ok, %{"released" => name}}
    else
      {:error, %{"code" => "unknown_target", "message" => name, "live" => live_names()}}
    end
  end

  defp do_handle(%{"verb" => "register", "args" => %{"name" => name, "pane_id" => pane_id}}) do
    cond do
      not Regex.match?(@name_re, name) ->
        {:error,
         %{
           "code" => "bad_name",
           "message" => "names must match [a-z][a-z0-9_-]{0,31}; got #{inspect(name)}"
         }}

      Hq.Session.alive?(name) ->
        {:error, %{"code" => "name_taken", "message" => name_taken_message(name)}}

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

  defp do_handle(%{"verb" => "spawn", "args" => args}), do: Hq.Spawner.spawn_agent(args)

  # `hq stop`'s primary, signal-free path -- see the module doc on
  # `Hq.Control` for why `pkill -f 'hq daemon'` (the old advice) is
  # dangerous: it matches every process's full command line, not just the
  # daemon's. This verb lets the CLI ask the daemon it can actually reach
  # (over its own control socket) to shut itself down, no signal involved.
  #
  # The reply MUST reach the caller before the daemon goes down, or the CLI
  # sees a closed socket instead of a confirmation -- indistinguishable from
  # the daemon having simply crashed. `Hq.Control.serve/1` calls
  # `reply(sock, dispatch(req))`: whatever this function returns becomes the
  # bytes written to the socket, and that write happens strictly AFTER this
  # function returns. So the actual shutdown trigger runs in a SEPARATE,
  # freshly spawned process, after a short delay -- never inline, in the
  # process that still has to write the reply. Calling `stop_fun` directly
  # here, in this process, would race full application shutdown against that
  # very `:gen_tcp.send`: if shutdown reached this process first, the reply
  # would never go out.
  #
  # `:init.stop/0` (never `System.halt/1`) is what actually runs -- it drives
  # ordinary application shutdown, so `Hq.Control.terminate/2` executes and
  # cleans up the socket and `daemon.pid` exactly as it does on any other
  # controlled stop. `System.halt/1` skips every `terminate/2` callback and
  # would leave both files behind.
  #
  # Both the delay and the trigger itself are configurable via
  # `Application.get_env(:hq, :stop_delay_ms | :stop_fun, ...)` purely so
  # tests can swap in a harmless stand-in instead of tearing down the whole
  # test VM -- config/test.exs pins a no-op default as a safety net.
  @stop_delay_ms 100

  defp do_handle(%{"verb" => "stop"}) do
    pid = System.pid()
    delay = Application.get_env(:hq, :stop_delay_ms, @stop_delay_ms)
    stop_fun = Application.get_env(:hq, :stop_fun, &:init.stop/0)

    spawn(fn ->
      Process.sleep(delay)
      stop_fun.()
    end)

    {:ok, %{"pid" => pid, "stopping" => true}}
  end

  defp do_handle(%{"verb" => verb}) do
    {:error, %{"code" => "unknown_verb", "message" => to_string(verb)}}
  end

  defp live_names, do: Hq.SessionSup.list() |> Enum.map(& &1["name"]) |> Enum.sort()

  # `register` on a taken name used to return `%{"code" => "name_taken",
  # "message" => name}` -- the CLI renders `error["message"]` verbatim, so a
  # second orchestrator trying to register the same name as a first saw
  # exactly `hq: orchestrator`, naming neither the conflict nor the remedy.
  # It has no way to tell "orchestrator" is taken from that alone, so it
  # proceeds unregistered while its own workers keep addressing a name that
  # routes to someone else's session. Name the conflict, the pane holding it
  # (when that's cheap -- one more GenServer.call against a session we just
  # confirmed alive), and the fix: pick a different name.
  defp name_taken_message(name) do
    "`#{name}` is already registered#{held_by(name)}.\n" <>
      "     hq names are global to this machine, not per-orchestrator -- two " <>
      "orchestrators running at once must not share one.\n" <>
      "     Pick a different name and register again."
  end

  defp held_by(name) do
    case Hq.Session.info(name)["pane_id"] do
      pane_id when is_binary(pane_id) -> " (held by pane #{pane_id})"
      _ -> ""
    end
  end

  # A session name (`@name_re`) never contains `:`; a Herdr pane id always
  # does (e.g. "w1:p1"), so the two are never ambiguous. Anything already
  # name-shaped — including the "operator" fallback `decorate/1` uses outside
  # a Herdr pane, and every hand-written "from" a test supplies directly — is
  # left untouched. A pane id that maps to one of hq's own supervised
  # sessions (the same pane_id -> name lookup `inbox` uses above) is resolved
  # to that session's name; a pane id with no supervised session falls back
  # to "operator" rather than ever reaching Hq.Spawner/Hq.Session/Hq.Notify as
  # a raw, un-lookupable pane id.
  defp resolve_from(%{"from" => from} = args) when is_binary(from) do
    if Regex.match?(@name_re, from) do
      args
    else
      case Enum.find(Hq.SessionSup.list(), &(&1["pane_id"] == from)) do
        %{"name" => name} -> Map.put(args, "from", name)
        nil -> Map.put(args, "from", "operator")
      end
    end
  end

  defp resolve_from(args), do: args
end
