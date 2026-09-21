defmodule Hq.HerdrTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    prev = Application.get_env(:hq, :herdr_socket)
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    on_exit(fn -> Application.put_env(:hq, :herdr_socket, prev) end)
    %{fake: fake}
  end

  test "returns the result of a successful call", %{fake: fake} do
    FakeHerdr.stub(fake, "agent.list", %{"type" => "agent_list", "agents" => [%{"name" => "a"}]})

    assert {:ok, %{"agents" => [%{"name" => "a"}]}} = Hq.Herdr.call("agent.list", %{})
  end

  test "sends a STRING id — an integer id is rejected by the real server", %{fake: fake} do
    FakeHerdr.stub(fake, "ping", %{"type" => "pong"})
    Hq.Herdr.call("ping", %{})

    # The double records params; assert framing separately by connecting raw.
    {:ok, sock} = Hq.Herdr.connect(1_000)
    :ok = Hq.Herdr.send_request(sock, "ping", %{})
    {:ok, line} = :gen_tcp.recv(sock, 0, 1_000)
    assert %{"id" => id} = JSON.decode!(line)
    assert is_binary(id)
  end

  test "surfaces a server error as {:error, map}", %{fake: fake} do
    FakeHerdr.stub_error(fake, "agent.get", %{"code" => "not_found", "message" => "ghost"})

    assert {:error, %{"code" => "not_found"}} = Hq.Herdr.call("agent.get", %{"target" => "ghost"})
  end

  test "each call uses a fresh connection" do
    # Two sequential calls must both succeed. If call/2 ever reused a socket the
    # second would time out, because the server answers one request per socket.
    {:ok, fake} = FakeHerdr.start_link()
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    FakeHerdr.stub(fake, "ping", %{"type" => "pong"})

    assert {:ok, _} = Hq.Herdr.call("ping", %{})
    assert {:ok, _} = Hq.Herdr.call("ping", %{})
    assert length(FakeHerdr.calls(fake)) == 2
  end

  test "returns an error when the socket does not exist" do
    Application.put_env(
      :hq,
      :herdr_socket,
      "/tmp/hq-nope-#{System.unique_integer([:positive])}.sock"
    )

    assert {:error, _} = Hq.Herdr.call("ping", %{})
  end
end
