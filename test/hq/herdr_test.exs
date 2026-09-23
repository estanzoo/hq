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

  test "sends a STRING id — an integer id is rejected by the real server" do
    # Assert on the REQUEST framing hq itself writes, not the reply: FakeHerdr
    # always answers a bad id with `%{"id" => "", ...}` (see
    # invalid_id_message/1 in test/support/fake_herdr.ex), and "" is itself a
    # binary, so asserting `is_binary` on the REPLY's id would hold even if
    # `new_id/0` regressed to an integer. Stand up a raw listener instead of
    # going through FakeHerdr, so we decode exactly the line the client wrote.
    path = Path.join(System.tmp_dir!(), "hq-raw-id-#{System.unique_integer([:positive])}.sock")
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :line,
        reuseaddr: true
      ])

    on_exit(fn ->
      :gen_tcp.close(listen)
      File.rm(path)
    end)

    Application.put_env(:hq, :herdr_socket, path)

    {:ok, client} = Hq.Herdr.connect(1_000)
    :ok = Hq.Herdr.send_request(client, "ping", %{})

    {:ok, server} = :gen_tcp.accept(listen, 1_000)
    {:ok, line} = :gen_tcp.recv(server, 0, 1_000)
    :gen_tcp.close(client)
    :gen_tcp.close(server)

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

  # I1: `Hq.Herdr.connect/1` omitted `buffer:`, so a `packet: :line` frame
  # past ~9216 bytes truncated — in either direction, since a call both
  # sends params and reads a result over the same framing. Round-trips a
  # large value both ways in one call: a >9KB `text` param out, and a >9KB
  # result field back.
  test "a body well over 9 KB round-trips through Hq.Herdr.call without truncating", %{
    fake: fake
  } do
    big = String.duplicate("z", 12_000)
    FakeHerdr.stub(fake, "agent.prompt", %{"type" => "agent_prompt", "echo" => big})

    assert {:ok, %{"echo" => echoed}} =
             Hq.Herdr.call("agent.prompt", %{"target" => "worker-a", "text" => big})

    assert echoed == big

    [call] = FakeHerdr.calls(fake) |> Enum.filter(&(&1["method"] == "agent.prompt"))
    assert call["params"]["text"] == big
  end

  test "returns an error when the socket does not exist" do
    Application.put_env(
      :hq,
      :herdr_socket,
      "/tmp/hq-nope-#{System.unique_integer([:positive])}.sock"
    )

    assert {:error, _} = Hq.Herdr.call("ping", %{})
  end

  test "does not leak a socket when recv times out" do
    # Critical: socket must close even when recv fails. Use a silent server that
    # accepts connections but never replies. This forces recv to timeout/fail,
    # exercising the error path where the old code (with/else) would leak.
    {path, listen, acceptor} = silent_server()

    Application.put_env(:hq, :herdr_socket, path)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
      File.rm(path)
    end)

    # Count ports before the batch. Include some slack for system activity.
    before = length(Port.list())

    # 50 calls with 50ms timeout. Each will connect, send, then timeout on recv.
    # Server accepts and holds, so we get N accepted sockets on the server side.
    # Leak test: client sockets should all close in the after block.
    for _ <- 1..50, do: Hq.Herdr.call("ping", %{}, timeout: 50)

    after_count = length(Port.list())
    growth = after_count - before

    # Without the fix: ~100 ports grow (50 client leaks + 50 server accepts)
    # With the fix: ~50 ports grow (only 50 server accepts, all clients close)
    # Assert the fixed version keeps growth low.
    assert growth < 60,
           "Port growth: #{growth} (before: #{before}, after: #{after_count}) - possible socket leak"
  end

  defp silent_server do
    path = Path.join(System.tmp_dir!(), "hq-silent-#{System.unique_integer([:positive])}.sock")
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :line,
        reuseaddr: true
      ])

    # Accept connections and hold without replying
    acceptor = spawn_link(fn -> accept_and_hold(listen, []) end)
    {path, listen, acceptor}
  end

  defp accept_and_hold(listen, socks) do
    case :gen_tcp.accept(listen) do
      {:ok, s} -> accept_and_hold(listen, [s | socks])
      {:error, _} -> :ok
    end
  end
end
