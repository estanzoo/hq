defmodule Hq.CLITest do
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

    %{fake: fake, root: root}
  end

  test "parses `send` into a control request" do
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1")

    assert {:ok, %{"queued" => true}} =
             Hq.CLI.request("send", %{"to" => "worker-b", "from" => "worker-a", "body" => "hi"})
  end

  test "argv parsing builds the right send request" do
    assert {"send", %{"to" => "worker-b", "body" => "hello there"}} =
             Hq.CLI.parse(["send", "worker-b", "hello there"])
  end

  test "argv parsing handles spawn flags" do
    {verb, args} =
      Hq.CLI.parse(["spawn", "worker-a", "--worktree", "--permissive", "--task", "do it"])

    assert verb == "spawn"
    assert args["name"] == "worker-a"
    assert args["worktree"] == true
    assert args["permissive"] == true
    assert args["task"] == "do it"
  end

  test "argv parsing defaults spawn flags to false" do
    {_verb, args} = Hq.CLI.parse(["spawn", "worker-a"])

    assert args["worktree"] == false
    assert args["permissive"] == false
  end

  test "an error response surfaces as {:error, map}" do
    assert {:error, %{"code" => "unknown_target"}} =
             Hq.CLI.request("send", %{"to" => "ghost", "from" => "x", "body" => "y"})
  end

  test "concurrent ensure_daemon calls start exactly one daemon" do
    # The control socket is already up, so ensure_daemon must be a no-op for
    # every caller rather than racing to start a second one.
    results =
      1..10
      |> Task.async_stream(fn _ -> Hq.CLI.ensure_daemon() end, max_concurrency: 10)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &(&1 == :ok))
  end

  # -- register: the entry point to the whole system -------------------------
  #
  # The brief's original `put_self_name/1` had a first clause,
  # `put_self_name(%{"name" => _} = args), do: args`, that matched
  # `%{"name" => name}` (exactly what `hq register <name>` parses into) and
  # returned it untouched -- `pane_id` never got attached. The handler's
  # `register` clause requires both `"name"` and `"pane_id"`, so the request
  # fell through to the catch-all and came back `unknown_verb`. This test
  # drives the real pipeline (parse -> decorate -> request -> handler) end to
  # end, so a regression here cannot hide behind a unit test of `parse/1`
  # alone. See the task report for the red run against the original code.
  test "hq register drives parse -> decorate -> request -> handler and actually registers", %{
    fake: fake
  } do
    System.put_env("HERDR_PANE_ID", "w1:p1")
    on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

    {verb, args} = Hq.CLI.parse(["register", "boss"])
    args = Hq.CLI.decorate(args)

    assert args["pane_id"] == "w1:p1"

    assert {:ok, %{"name" => "boss", "pane_id" => "w1:p1"}} = Hq.CLI.request(verb, args)
    assert Hq.Session.alive?("boss")

    rename = FakeHerdr.calls(fake) |> Enum.find(&(&1["method"] == "agent.rename"))
    assert rename["params"] == %{"target" => "w1:p1", "name" => "boss"}
  end

  test "hq inbox resolves the calling pane to its session" do
    System.put_env("HERDR_PANE_ID", "w2:p1")
    on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

    {:ok, _} = Hq.Roster.adopt("worker-c", "w2:p1")
    Hq.Session.deliver("worker-c", "worker-a", "hi from the pane test")

    {verb, args} = Hq.CLI.parse(["inbox"])
    args = Hq.CLI.decorate(args)

    assert {:ok, %{"pending" => [%{"body" => "hi from the pane test"}]}} =
             Hq.CLI.request(verb, args)
  end

  # -- socket lifecycle --------------------------------------------------------
  #
  # `with/else` does not expose bindings made earlier in the `with` to its
  # `else` clause. `request/2`'s `with` opens `sock` via `connect()` and then
  # calls `:gen_tcp.send/2` and `:gen_tcp.recv/3` on it; if either of those
  # later steps fails, control goes to `else`, which never sees `sock` and so
  # can never close it -- exactly the fd-leak shape this codebase has already
  # shipped twice (see `Hq.Control.serve/1`, which uses `try/after` for
  # precisely this reason). This test stands up a server that accepts the
  # connection (so `connect()` succeeds and a socket really is opened) and
  # then closes it immediately without reading or replying, forcing
  # `request/2` down its `send`/`recv`-failure path on every iteration.
  test "request/2 does not leak its socket when the peer closes the connection early", %{
    root: _root
  } do
    :ok = stop_supervised(Hq.Control)
    path = Hq.Control.socket_path()
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :line,
        reuseaddr: true
      ])

    base_ports = length(:erlang.ports())

    for _ <- 1..15 do
      # `request/2` opens two connections per call, not one: `ensure_daemon/0`
      # connects, sees the socket answer, and closes -- purely a health
      # check -- before `request/2` opens its own, second connection to
      # actually carry the verb. The fake server here must accept both, or
      # the second (real) connection sits in the listen backlog forever with
      # nobody to accept it, and `request/2` hangs on its own `recv` for the
      # full 60s regardless of what this test is trying to prove.
      server =
        spawn(fn ->
          {:ok, probe} = :gen_tcp.accept(listen, 2_000)
          :gen_tcp.close(probe)

          case :gen_tcp.accept(listen, 2_000) do
            {:ok, sock} ->
              # linger: {true, 0} makes this an abortive close (RST), which
              # unblocks the client's pending recv immediately. A plain
              # `:gen_tcp.close/1` here sends a graceful FIN instead, and on
              # this socket/OS combination a client `recv` blocked on a
              # `packet: :line` unix socket does not wake up on a bare FIN
              # with no data -- it rides out the full 60s timeout, which is
              # what made an earlier version of this test take 15+ minutes.
              :ok = :inet.setopts(sock, linger: {true, 0})
              :gen_tcp.close(sock)

            _ ->
              :ok
          end
        end)

      ref = Process.monitor(server)
      assert {:error, %{"code" => "no_daemon"}} = Hq.CLI.request("ping", %{})
      assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 2_000
    end

    :gen_tcp.close(listen)

    # A leaked client socket per iteration would grow the port count by ~15;
    # a properly closed one leaves only incidental noise from unrelated
    # concurrency elsewhere in the VM.
    assert length(:erlang.ports()) - base_ports < 8
  end

  # -- rendering ---------------------------------------------------------------
  #
  # `Hq.SessionSup.list/0` reports a busy session as `"status" => "busy"` with
  # `"mailbox" => nil` (its Session process is occupied delivering mail, so
  # its depth can't be read without blocking `hq ls` itself). The brief's
  # renderer used the `~B` (integer-only) format directive unconditionally,
  # which raises `ArgumentError` the first time `hq ls` runs while any
  # session is busy.
  test "ls renders a busy session (mailbox: nil) without crashing" do
    session = %{
      "name" => "worker-a",
      "pane_id" => nil,
      "cwd" => nil,
      "status" => "busy",
      "spawned_by" => nil,
      "mailbox" => nil
    }

    assert Hq.CLI.render("ls", %{"sessions" => [session]}) =~ "worker-a"
    assert Hq.CLI.render("ls", %{"sessions" => [session]}) =~ "busy"
  end

  test "ls renders a normal session's numeric mailbox depth" do
    session = %{
      "name" => "worker-a",
      "pane_id" => "w1:p1",
      "cwd" => "/tmp",
      "status" => "idle",
      "spawned_by" => "operator",
      "mailbox" => 3
    }

    assert Hq.CLI.render("ls", %{"sessions" => [session]}) =~ "mail:3"
  end

  test "ls with no sessions" do
    assert Hq.CLI.render("ls", %{"sessions" => []}) == "no live sessions"
  end

  test "inbox with no pending messages" do
    assert Hq.CLI.render("inbox", %{"pending" => []}) == "inbox empty"
  end

  test "inbox renders pending messages" do
    pending = [%{"from" => "worker-a", "body" => "hi"}]
    assert Hq.CLI.render("inbox", %{"pending" => pending}) == "worker-a: hi"
  end

  # -- daemon autostart: O_EXCL lock ------------------------------------------
  #
  # The test above ("concurrent ensure_daemon calls start exactly one
  # daemon") starts Hq.Control in `setup` before it ever runs, so every
  # caller's very first `connect()` inside `ensure_daemon/0` already succeeds
  # -- the whole `with_lock/1` branch, including the O_EXCL open, is never
  # reached. That makes it a test that would pass identically against a
  # version of `with_lock/1` with no locking at all (verified below and in
  # the task report). These two tests stop Hq.Control first, so every caller
  # is forced through `with_lock/1`, and replace the real `hq` binary on
  # `$PATH` with a stub that only records that it ran -- proving the lock's
  # mutual-exclusion property against the real code, not a re-implementation
  # of it, without needing a real daemon to come up.
  test "a burst of concurrent ensure_daemon calls starts exactly one daemon (O_EXCL lock)", %{
    root: root
  } do
    :ok = stop_supervised(Hq.Control)
    log_path = install_fake_hq(root)

    results =
      1..10
      |> Task.async_stream(fn _ -> Hq.CLI.ensure_daemon() end,
        max_concurrency: 10,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # No real daemon ever comes up -- the stub just records and exits -- so
    # every caller eventually times out waiting for the socket. That is fine:
    # the property under test is how many times `start_daemon/0` itself ran.
    assert Enum.all?(results, &(&1 == {:error, :daemon_did_not_start}))
    assert count_starts(log_path) == 1
  end

  test "a stale lock file from a crashed starter does not wedge ensure_daemon", %{root: root} do
    :ok = stop_supervised(Hq.Control)
    log_path = install_fake_hq(root)
    write_stale_lock(root, 40)

    assert {:error, :daemon_did_not_start} = Hq.CLI.ensure_daemon()
    assert count_starts(log_path) == 1
  end

  # -- helpers -----------------------------------------------------------------

  # Installs a fake `hq` executable ahead of the real one on $PATH. It only
  # ever does one thing: when invoked as `hq daemon`, append a line to
  # `log_path` and exit. `start_daemon/0` finds it via
  # `System.find_executable("hq")`, which is checked before
  # `:escript.script_name/0` (never reached here, and it raises outside a
  # real escript anyway).
  defp install_fake_hq(root) do
    bin_dir = Path.join(root, "fakebin")
    File.mkdir_p!(bin_dir)
    log_path = Path.join(root, "fake-hq-starts.log")

    script = """
    #!/bin/sh
    if [ "$1" = "daemon" ]; then
      echo "started $$" >> "#{log_path}"
    fi
    exit 0
    """

    hq_path = Path.join(bin_dir, "hq")
    File.write!(hq_path, script)
    File.chmod!(hq_path, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (old_path || ""))

    on_exit(fn ->
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
    end)

    log_path
  end

  defp count_starts(log_path) do
    case File.read(log_path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  # Simulates a starter that crashed before it could remove its own lock
  # file, by backdating the lock's mtime past `@lock_stale_ms` (30s).
  defp write_stale_lock(root, age_s) do
    path = Path.join(root, "daemon.lock")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")

    stat = File.stat!(path, time: :posix)
    File.write_stat!(path, %{stat | mtime: stat.mtime - age_s}, time: :posix)
  end
end
