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
end
