defmodule FakeHerdrTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    %{fake: fake, path: FakeHerdr.path(fake)}
  end

  defp connect(path) do
    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])

    sock
  end

  defp request(sock, method, params) do
    line = JSON.encode!(%{"id" => "t1", "method" => method, "params" => params})
    :ok = :gen_tcp.send(sock, [line, ?\n])
  end

  defp request_with_id(sock, id, method, params) do
    line = JSON.encode!(%{"id" => id, "method" => method, "params" => params})
    :ok = :gen_tcp.send(sock, [line, ?\n])
  end

  test "answers a stubbed request and records the call", %{fake: fake, path: path} do
    FakeHerdr.stub(fake, "agent.list", %{"type" => "agent_list", "agents" => []})

    sock = connect(path)
    request(sock, "agent.list", %{})
    {:ok, line} = :gen_tcp.recv(sock, 0, 1_000)

    assert %{"id" => "t1", "result" => %{"type" => "agent_list"}} = JSON.decode!(line)
    assert [%{"method" => "agent.list", "params" => %{}}] = FakeHerdr.calls(fake)
  end

  test "closes the connection after one reply", %{fake: fake, path: path} do
    FakeHerdr.stub(fake, "ping", %{"type" => "pong"})

    sock = connect(path)
    request(sock, "ping", %{})
    {:ok, _} = :gen_tcp.recv(sock, 0, 1_000)

    assert {:error, :closed} = :gen_tcp.recv(sock, 0, 1_000)
  end

  test "holds a subscription open and pushes events", %{fake: fake, path: path} do
    sock = connect(path)
    request(sock, "events.subscribe", %{"subscriptions" => [%{"type" => "pane.created"}]})

    {:ok, line} = :gen_tcp.recv(sock, 0, 1_000)
    assert %{"result" => %{"type" => "subscription_started"}} = JSON.decode!(line)
    assert FakeHerdr.subscriber_count(fake) == 1

    FakeHerdr.push_event(fake, "pane_created", %{"pane_id" => "w9:p1"})
    {:ok, ev} = :gen_tcp.recv(sock, 0, 1_000)

    assert %{"event" => "pane_created", "data" => %{"pane_id" => "w9:p1"}} = JSON.decode!(ev)
  end

  test "returns a stubbed error", %{fake: fake, path: path} do
    FakeHerdr.stub_error(fake, "agent.get", %{"code" => "not_found", "message" => "nope"})

    sock = connect(path)
    request(sock, "agent.get", %{"target" => "ghost"})
    {:ok, line} = :gen_tcp.recv(sock, 0, 1_000)

    assert %{"error" => %{"code" => "not_found"}} = JSON.decode!(line)
  end

  test "unstubbed methods return an error rather than hanging", %{path: path} do
    sock = connect(path)
    request(sock, "agent.wat", %{})
    {:ok, line} = :gen_tcp.recv(sock, 0, 1_000)

    assert %{"error" => %{"code" => "unstubbed"}} = JSON.decode!(line)
  end

  test "rejects a non-string id with invalid_request, mirroring the real server",
       %{fake: fake, path: path} do
    FakeHerdr.stub(fake, "ping", %{"type" => "pong"})

    sock = connect(path)
    request_with_id(sock, 1, "ping", %{})
    {:ok, line} = :gen_tcp.recv(sock, 0, 1_000)

    assert %{"id" => "", "error" => %{"code" => "invalid_request"}} = JSON.decode!(line)
    # Rejected before dispatch: never recorded as a call against the stub.
    assert FakeHerdr.calls(fake) == []
  end

  test "removes the socket file when its starting process exits normally" do
    test_pid = self()

    # GenServer.stop/1 already ran terminate/2 before the trap_exit fix, so
    # it proves nothing about the parent-exit path that was actually
    # leaking. Exercise that path directly: start FakeHerdr from a process
    # other than this test, let that process exit normally, and confirm
    # FakeHerdr (its real start_link parent) cleaned up in response.
    {starter, ref} =
      spawn_monitor(fn ->
        {:ok, fake} = FakeHerdr.start_link()
        send(test_pid, {:started, FakeHerdr.path(fake)})
      end)

    path =
      receive do
        {:started, path} -> path
      after
        1_000 -> flunk("starter process did not report its path")
      end

    assert_receive {:DOWN, ^ref, :process, ^starter, :normal}

    # terminate/2 runs on FakeHerdr's own schedule after the parent-EXIT
    # message is delivered, so poll briefly instead of asserting instantly.
    assert wait_until(fn -> not File.exists?(path) end)
  end

  test "an abnormal EXIT from a linked process brings the double down loudly", %{fake: fake} do
    # This test process is fake's start_link parent (linked in setup), so
    # fake dying with a non-normal reason would otherwise propagate that
    # same EXIT signal here and kill this test process before the
    # assertion runs. Trap it so we can observe the crash instead.
    Process.flag(:trap_exit, true)
    ref = Process.monitor(fake)

    ExUnit.CaptureLog.capture_log(fn ->
      # The accept-loop process is linked but is not FakeHerdr's start_link
      # parent, so its EXIT goes through handle_info, not straight to
      # terminate/2. We can't reach that pid from here, so send the same
      # shaped message FakeHerdr would receive from it crashing abnormally.
      send(fake, {:EXIT, self(), :boom})
      assert_receive {:DOWN, ^ref, :process, ^fake, :boom}
    end)
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries <= 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end
