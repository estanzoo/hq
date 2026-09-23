defmodule Hq.Herdr.EventsTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    prev = Application.get_env(:hq, :herdr_socket)
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    on_exit(fn -> Application.put_env(:hq, :herdr_socket, prev) end)
    %{fake: fake}
  end

  test "subscribes and forwards pushed events to its owner", %{fake: fake} do
    subs = [%{"type" => "pane.agent_status_changed", "pane_id" => "w5:p1"}]
    {:ok, _pid} = Hq.Herdr.Events.start_link(owner: self(), subscriptions: subs)

    assert_receive {:hq_events, :connected}, 1_000

    FakeHerdr.push_event(fake, "pane_agent_status_changed", %{
      "pane_id" => "w5:p1",
      "agent_status" => "idle"
    })

    assert_receive {:hq_event, "pane_agent_status_changed", %{"agent_status" => "idle"}}, 1_000
  end

  # Herdr is inconsistent about the `event` field it pushes: measured against
  # the live server, `pane.agent_status_changed` arrives DOTTED (verbatim,
  # matching its subscription type), not snake_case. Reproduce exactly what
  # the real server sends and prove it still reaches the owner normalized —
  # this is the case the old, snake_case-only test above could not catch,
  # because the fake it drove happened to mirror the same wrong assumption
  # the production code made.
  test "normalizes a DOTTED pushed kind to snake_case, as the real server sends it", %{
    fake: fake
  } do
    subs = [%{"type" => "pane.agent_status_changed", "pane_id" => "wA:p4"}]
    {:ok, _pid} = Hq.Herdr.Events.start_link(owner: self(), subscriptions: subs)

    assert_receive {:hq_events, :connected}, 1_000

    FakeHerdr.push_event(fake, "pane.agent_status_changed", %{
      "agent" => "claude",
      "agent_status" => "working",
      "pane_id" => "wA:p4",
      "workspace_id" => "wA"
    })

    assert_receive {:hq_event, "pane_agent_status_changed",
                    %{"agent_status" => "working", "pane_id" => "wA:p4"}},
                   1_000
  end

  # A standalone "already-snake_case kind unchanged" test used to live here.
  # Deleted: `normalize_kind(kind), do: kind` alone still passed it (pushing
  # `pane_closed` makes normalization a no-op either way), and the inverse
  # mutation that did kill it (`String.replace(kind, "_", ".")`) also killed
  # three other tests, so it caught nothing uniquely. The dotted test above
  # and Hq.SessionTest's normalize_kind coverage already prove
  # `normalize_kind/1` is necessary; a test that cannot fail alone is worse
  # than no test.

  test "sends the subscriptions verbatim", %{fake: fake} do
    subs = [%{"type" => "pane.agent_status_changed", "pane_id" => "w5:p1"}]
    {:ok, _} = Hq.Herdr.Events.start_link(owner: self(), subscriptions: subs)
    assert_receive {:hq_events, :connected}, 1_000

    assert [%{"method" => "events.subscribe", "params" => %{"subscriptions" => ^subs}}] =
             FakeHerdr.calls(fake)
  end

  test "reconnects after the connection drops", %{fake: fake} do
    subs = [%{"type" => "pane.created"}]
    {:ok, _} = Hq.Herdr.Events.start_link(owner: self(), subscriptions: subs)
    assert_receive {:hq_events, :connected}, 1_000

    FakeHerdr.drop_subscribers(fake)
    assert_receive {:hq_events, :disconnected}, 1_000
    assert_receive {:hq_events, :connected}, 3_000

    FakeHerdr.push_event(fake, "pane_created", %{"pane_id" => "w9:p1"})
    assert_receive {:hq_event, "pane_created", %{"pane_id" => "w9:p1"}}, 1_000
  end

  test "does not leak a socket when subscribe fails after connecting" do
    # Hq.Herdr.Events.subscribe/1 connects, then sends events.subscribe and
    # waits for a "subscription_started" reply. If the connection is accepted
    # but then closed before that reply lands (server hiccup, wrong socket,
    # etc.), send_request or recv fails. The old with/else shape lost `sock`
    # in the else branch on exactly this path and never closed it. Drive
    # subscribe/1 directly (bypassing the GenServer's backoff, which would
    # make 50 iterations take minutes) against a server that accepts and
    # immediately closes, and confirm the client's own sockets don't pile up.
    {path, listen, acceptor} = accept_and_close_server()
    Application.put_env(:hq, :herdr_socket, path)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
      File.rm(path)
    end)

    before = length(Port.list())

    # 300 iterations, not 50: at 50 iterations a reintroduced leak (dropping
    # the `:gen_tcp.close(sock)` below) measured growth of exactly 50 against
    # a `< 50` bound -- a margin of exactly one port, so any single incidental
    # port closing elsewhere in the VM would let a real leak through. Measured
    # directly at 300 iterations: growth is 0 with the fix in place, and 300
    # (one leaked port per call) with the leak reintroduced -- so the bound
    # below has a wide margin instead of being one port from either outcome.
    iterations = 300

    for _ <- 1..iterations do
      assert {:error, _} = Hq.Herdr.Events.subscribe([%{"type" => "pane.created"}])
    end

    after_count = length(Port.list())
    growth = after_count - before

    # Without the fix: growth tracks the iteration count 1:1 (one leaked
    # client socket per call, on top of the server-side accepts). With the
    # fix: only the (already-closed) accepts contribute, so growth stays flat
    # regardless of iteration count. A leak of even one port per ten calls
    # would still clear this bound by a wide margin.
    assert growth < div(iterations, 10),
           "Port growth: #{growth} (before: #{before}, after: #{after_count}) - possible socket leak"
  end

  defp accept_and_close_server do
    path =
      Path.join(System.tmp_dir!(), "hq-events-closing-#{System.unique_integer([:positive])}.sock")

    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :line,
        reuseaddr: true
      ])

    acceptor = spawn_link(fn -> accept_and_close(listen) end)
    {path, listen, acceptor}
  end

  defp accept_and_close(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        accept_and_close(listen)

      {:error, _} ->
        :ok
    end
  end
end
