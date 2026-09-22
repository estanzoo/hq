defmodule Hq.ControlTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    root = Path.join(System.tmp_dir!(), "hq-test-#{System.unique_integer([:positive])}")
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    Application.put_env(:hq, :root, root)
    Application.put_env(:hq, :settle_ms, 10)
    on_exit(fn -> File.rm_rf(root) end)

    FakeHerdr.stub(fake, "agent.get", %{
      "type" => "agent_get",
      "agent" => %{"agent_status" => "working"}
    })

    FakeHerdr.stub(fake, "agent.list", %{"type" => "agent_list", "agents" => []})
    FakeHerdr.stub(fake, "agent.rename", %{"type" => "agent_rename"})

    start_supervised!({Registry, keys: :unique, name: Hq.Registry})
    start_supervised!(Hq.SessionSup)
    start_supervised!(Hq.Control)

    %{fake: fake}
  end

  defp request(verb, args) do
    {:ok, sock} =
      :gen_tcp.connect({:local, Hq.Control.socket_path()}, 0, [
        :binary,
        active: false,
        packet: :line
      ])

    :ok = :gen_tcp.send(sock, [JSON.encode!(%{"verb" => verb, "args" => args}), ?\n])
    {:ok, line} = :gen_tcp.recv(sock, 0, 2_000)
    :gen_tcp.close(sock)
    JSON.decode!(line)
  end

  test "ping answers" do
    assert %{"ok" => true, "result" => %{"pong" => true}} = request("ping", %{})
  end

  test "ls is empty with no sessions" do
    assert %{"ok" => true, "result" => %{"sessions" => []}} = request("ls", %{})
  end

  test "ls reports a live session" do
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")

    assert %{"ok" => true, "result" => %{"sessions" => [%{"name" => "worker-a"}]}} =
             request("ls", %{})
  end

  test "send queues to the target" do
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1")

    assert %{"ok" => true} =
             request("send", %{"to" => "worker-b", "from" => "worker-a", "body" => "hi"})

    assert Hq.Session.info("worker-b")["mailbox"] == 1
  end

  test "send to an unknown target fails and lists who IS live" do
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")

    assert %{"ok" => false, "error" => %{"code" => "unknown_target", "live" => ["worker-a"]}} =
             request("send", %{"to" => "ghost", "from" => "worker-a", "body" => "hi"})
  end

  test "inbox reports pending messages for a name" do
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1")
    Hq.Session.deliver("worker-b", "worker-a", "pending")

    assert %{"ok" => true, "result" => %{"pending" => [%{"body" => "pending"}]}} =
             request("inbox", %{"name" => "worker-b"})
  end

  test "release stops supervising" do
    {:ok, _} = Hq.Roster.adopt("worker-a", "w5:p1")

    assert %{"ok" => true} = request("release", %{"name" => "worker-a"})
    refute Hq.Session.alive?("worker-a")
  end

  test "register names a pane and supervises it", %{fake: fake} do
    assert %{"ok" => true, "result" => %{"name" => "boss"}} =
             request("register", %{"name" => "boss", "pane_id" => "w1:p1"})

    assert Hq.Session.alive?("boss")

    rename =
      FakeHerdr.calls(fake) |> Enum.find(&(&1["method"] == "agent.rename"))

    assert rename["params"] == %{"target" => "w1:p1", "name" => "boss"}
  end

  test "register rejects a name Herdr will not accept" do
    assert %{"ok" => false, "error" => %{"code" => "bad_name"}} =
             request("register", %{"name" => "Worker A", "pane_id" => "w1:p1"})
  end

  test "an unknown verb is an error, not a hang" do
    assert %{"ok" => false, "error" => %{"code" => "unknown_verb"}} = request("frobnicate", %{})
  end

  # A prior task in this repo shipped a `terminate/2` that never ran because
  # the GenServer was linked to a supervisor (ExUnit's own, via
  # start_supervised!, mirroring the real app's supervision tree) and did not
  # trap exits — Supervisor.terminate_child sends a plain exit signal, which
  # kills a non-trapping GenServer before terminate/2 gets a chance to run.
  # That leaked 25 socket files into $TMPDIR before anyone noticed. Stopping
  # Hq.Control the same way the supervisor would (not via GenServer.stop,
  # which always calls terminate/2 regardless of trap_exit and so would not
  # catch a regression here) is the only way this test actually proves the
  # fix.
  test "the control socket file is removed once the process stops via supervised shutdown" do
    path = Hq.Control.socket_path()
    assert File.exists?(path)

    pid = Process.whereis(Hq.Control)
    ref = Process.monitor(pid)

    assert :ok = stop_supervised(Hq.Control)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    refute File.exists?(path)
  end
end
