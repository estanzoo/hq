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

  # `dispatch/1` catches exceptions but exits are different: a Session that
  # dies between the handler's `alive?` check and its `GenServer.call` raises
  # `:exit`, not something `rescue` sees. Reaching that window via a real
  # Session death is racy (Registry cleanup is async), so instead this
  # registers a plain, non-GenServer process under the target name and has it
  # crash the instant it receives the call message the `send` verb sends it —
  # deterministic, no timing dependency: the process is confirmed registered
  # before the request is ever issued, and it only crashes in direct response
  # to that request's own GenServer.call.
  test "a verb whose target dies mid-call still returns a well-formed error envelope" do
    test_pid = self()

    zombie =
      spawn(fn ->
        {:ok, _} = Registry.register(Hq.Registry, "zombie", nil)
        send(test_pid, :registered)

        receive do
          _ -> raise "simulated crash mid-call"
        end
      end)

    assert_receive :registered, 1_000
    assert Hq.Session.alive?("zombie")

    ref = Process.monitor(zombie)

    assert %{"ok" => false, "error" => %{"code" => "internal"}} =
             request("send", %{"to" => "zombie", "from" => "worker-a", "body" => "hi"})

    assert_receive {:DOWN, ^ref, :process, ^zombie, _reason}, 1_000
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

    # `stop_session` (DynamicSupervisor.terminate_child) confirms the process
    # exited but does not wait for Registry's own, independent monitor to
    # process that death and remove the entry — the same race
    # `d646036` diagnosed and fixed for the identical stop_session -> alive?
    # shape elsewhere in this repo. Poll instead of reading `alive?` once.
    assert eventually(fn -> not Hq.Session.alive?("worker-a") end)
  end

  # Minor fix: `hq release ghost` used to report success (`:ok = Hq.Roster.forget(name)`
  # runs unconditionally, and forgetting a name hq never supervised is a
  # harmless no-op that still returns `:ok`) instead of telling the caller
  # the target never existed.
  test "release of a name hq never supervised is an error, not silent success" do
    assert %{"ok" => false, "error" => %{"code" => "unknown_target"}} =
             request("release", %{"name" => "ghost"})
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

  # `register` on a taken name used to return `%{"code" => "name_taken",
  # "message" => name}` -- the CLI renders `error["message"]` verbatim, so a
  # second orchestrator saw exactly `hq: orchestrator`, naming neither the
  # conflict nor the remedy. It must now name the conflict, the pane already
  # holding the name, and the fix -- asserted on content, not just the code,
  # so a regression back to the bare name cannot hide behind the code check
  # alone.
  test "register on a taken name explains the conflict, who holds it, and the remedy" do
    {:ok, _} = Hq.Roster.adopt("orchestrator", "w1:p1")

    assert %{"ok" => false, "error" => %{"code" => "name_taken", "message" => message}} =
             request("register", %{"name" => "orchestrator", "pane_id" => "w2:p1"})

    assert message =~ "`orchestrator` is already registered"
    assert message =~ "w1:p1"
    assert message =~ "Pick a different name"
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

  # This is the whole point of the ownership fix: a stray second daemon
  # (e.g. a stray `mix run` in this repo, or a plain double-start) must not
  # be able to steal the socket out from under a live one. The old
  # `init/1` called `File.rm(path)` unconditionally, so a second
  # `Hq.Control` here used to win the bind and leave the FIRST one orphaned,
  # bound to a now-unlinked inode -- reachable to nothing. Asserting the
  # original still answers a request afterward is what catches that
  # regression; asserting only that the second start failed would not.
  test "a second Hq.Control in the same root refuses to start while the first is live" do
    # `GenServer.start_link` links the caller to the child it spawns. When
    # `init/1` returns `{:stop, reason}` (reason not `:normal`), that link
    # delivers an EXIT signal to this test process too -- trap it, or this
    # process (not being a supervisor) dies from the very signal we're
    # asserting on instead of getting the `{:error, reason}` return.
    Process.flag(:trap_exit, true)

    assert {:error, {:socket_in_use, _pid}} = GenServer.start_link(Hq.Control, :ok)

    assert %{"ok" => true, "result" => %{"pong" => true}} = request("ping", %{})
  end

  test "a stale socket file with nothing listening is reclaimed and the daemon starts normally" do
    # `setup` already bound a real Hq.Control on this root; stop it via
    # supervised shutdown (see the test above for why that matters) so its
    # terminate/2 runs and removes both files, then leave a plain file (not
    # a bound socket) behind at the same path -- nothing can ever answer a
    # connect to it, which is exactly the "stale" case `init/1` must reclaim
    # rather than refuse.
    path = Hq.Control.socket_path()
    assert :ok = stop_supervised(Hq.Control)
    refute File.exists?(path)

    File.write!(path, "stale, not a socket")
    assert File.exists?(path)

    start_supervised!(Hq.Control)

    assert %{"ok" => true, "result" => %{"pong" => true}} = request("ping", %{})
    assert File.read!(Hq.Control.pid_path()) == System.pid()
  end

  test "terminate/2 removes the socket and pid file when it owns them" do
    socket_path = Hq.Control.socket_path()
    pid_path = Hq.Control.pid_path()
    assert File.exists?(socket_path)
    assert File.read!(pid_path) == System.pid()

    pid = Process.whereis(Hq.Control)
    ref = Process.monitor(pid)
    assert :ok = stop_supervised(Hq.Control)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    refute File.exists?(socket_path)
    refute File.exists?(pid_path)
  end

  # The other half of the ownership fix: once a DIFFERENT daemon's pid is
  # recorded at this path (because it reclaimed a stale socket after this
  # one died without ever getting to run terminate/2 -- see the moduledoc
  # history), this process must recognize it no longer owns the path and
  # leave both files alone. The old `terminate/2` called `File.rm`
  # unconditionally and would have deleted the files out from under the new
  # owner, which is precisely how a third daemon got started in production.
  test "terminate/2 leaves the socket and pid file alone when the pid file names a different pid" do
    socket_path = Hq.Control.socket_path()
    pid_path = Hq.Control.pid_path()
    assert File.exists?(socket_path)

    # Simulate a second daemon having reclaimed this path after this one
    # went stale, without ever going through this process's own bind path.
    File.write!(pid_path, "999999")

    pid = Process.whereis(Hq.Control)
    ref = Process.monitor(pid)
    assert :ok = stop_supervised(Hq.Control)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    assert File.exists?(socket_path)
    assert File.read!(pid_path) == "999999"
  end

  defp eventually(fun, tries \\ 50) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end
end
