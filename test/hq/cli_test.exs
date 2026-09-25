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

  # -- I2: a known verb called with the wrong arity gets a usage-shaped
  # error naming the verb, not the daemon's opaque `unknown_verb` (which
  # names the verb too, but gives no hint that arity — not spelling — was
  # the mistake). Both parse client-side, before request/2 ever opens a
  # socket, mirroring how require_pane/1 already does this for register/inbox.
  describe "parse/1: usage-shaped errors for a known verb's wrong arity" do
    test "send with the body missing (a bare `hq send worker-a`)" do
      assert {:error, message} = Hq.CLI.parse(["send", "worker-a"])
      assert message =~ "send:"
      assert message =~ "hq send <name>"
    end

    test "send with an unquoted, multi-word message -- the likeliest agent mistake" do
      assert {:error, message} = Hq.CLI.parse(["send", "worker-a", "schema", "is", "frozen"])
      assert message =~ "send:"
    end

    test "register with no name" do
      assert {:error, message} = Hq.CLI.parse(["register"])
      assert message =~ "register:"
    end

    test "release with no name" do
      assert {:error, message} = Hq.CLI.parse(["release"])
      assert message =~ "release:"
    end

    test "a parse error halts with a usage message instead of reaching the daemon" do
      # run_verb/1 is on the far side of System.halt/1 (untestable directly),
      # but parse/1 -> the {:error, _} branch it now takes is exercised here.
      assert {:error, _} = Hq.CLI.parse(["send", "worker-a"])
    end
  end

  # -- I3: silent argument loss ------------------------------------------------
  describe "I3: silent argument loss" do
    test "parse: `inbox <name>` is a name-scoped request, not silently dropped" do
      assert {"inbox", %{"name" => "worker-a"}} = Hq.CLI.parse(["inbox", "worker-a"])
    end

    test "hq inbox <name> end to end reaches THAT session, not the caller's own" do
      System.put_env("HERDR_PANE_ID", "w2:p1")
      on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

      {:ok, _} = Hq.Roster.adopt("worker-c", "w2:p1")
      {:ok, _} = Hq.Roster.adopt("worker-d", "w3:p1")
      Hq.Session.deliver("worker-d", "worker-a", "for worker-d, not worker-c")

      {verb, args} = Hq.CLI.parse(["inbox", "worker-d"])
      args = Hq.CLI.decorate(args)
      assert args["pane_id"] == "w2:p1", "the caller's own pane_id is still attached ambiently"

      assert {:ok, %{"pending" => [%{"body" => "for worker-d, not worker-c"}]}} =
               Hq.CLI.request(verb, args)
    end

    test "spawn rejects an unknown flag instead of silently producing a plain pane" do
      assert {:error, message} = Hq.CLI.parse(["spawn", "worker-a", "--worktre"])
      assert message =~ "unknown flag"
      assert message =~ "--worktre"
    end
  end

  # I1: none of Hq.Control's listen socket, Hq.CLI's client socket, or
  # Hq.Herdr's client socket set `buffer:`, so a `packet: :line` frame past
  # ~9216 bytes truncates (measured: 9044B arrives whole, 12044B does not).
  # A `send` with a body over that line reached the control socket
  # truncated, the server's `JSON.decode` failed on the incomplete line, and
  # the caller saw "hq: unparseable" instead of its message being queued.
  # This drives the REAL client function (`Hq.CLI.request/2`, what every verb
  # actually calls) against the REAL daemon (`Hq.Control` + its Handler),
  # round-tripping the full body back out through the recipient's mailbox —
  # not just checking that some bytes made it across.
  test "a send body well over 9 KB round-trips through the control socket without truncating" do
    {:ok, _} = Hq.Roster.adopt("worker-b", "w6:p1")

    big_body = String.duplicate("The quick brown fox. ", 600)
    assert byte_size(big_body) > 9_216

    assert {:ok, %{"queued" => true}} =
             Hq.CLI.request("send", %{
               "to" => "worker-b",
               "from" => "worker-a",
               "body" => big_body
             })

    assert [%{"body" => body}] = Hq.Session.pending("worker-b")
    assert body == big_body
  end

  # The reverse direction: a large RESPONSE (e.g. `hq inbox` holding a big
  # message) previously truncated on the CLIENT's read, producing
  # "hq: bad_response" plus mangled JSON on stderr rather than the answer.
  test "a large inbox response round-trips through the control socket without truncating" do
    System.put_env("HERDR_PANE_ID", "w2:p1")
    on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

    {:ok, _} = Hq.Roster.adopt("worker-c", "w2:p1")

    big_body = String.duplicate("held message body. ", 600)
    assert byte_size(big_body) > 9_216
    Hq.Session.deliver("worker-c", "worker-a", big_body)

    {verb, args} = Hq.CLI.parse(["inbox"])
    args = Hq.CLI.decorate(args)

    assert {:ok, %{"pending" => [%{"body" => body}]}} = Hq.CLI.request(verb, args)
    assert body == big_body
  end

  test "an error response surfaces as {:error, map}" do
    assert {:error, %{"code" => "unknown_target"}} =
             Hq.CLI.request("send", %{"to" => "ghost", "from" => "x", "body" => "y"})
  end

  # A "concurrent ensure_daemon calls start exactly one daemon" test used to
  # live here. Deleted: `setup` already brings `Hq.Control` up, so every
  # caller's first `connect()` inside `ensure_daemon/0` succeeds immediately
  # and `with_lock/1` -- including the O_EXCL open this test was meant to
  # guard -- is never reached. Reverting `with_lock/1` to no locking at all
  # still passed it. The real lock path is driven, and killed, by "a burst of
  # concurrent ensure_daemon calls starts exactly one daemon (O_EXCL lock)"
  # below, which stops Hq.Control first so every caller is forced through
  # with_lock/1.

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

    # The pane-required guard (see "require_pane/1" below) must not block the
    # happy path: `run_verb/1` checks it before every `request/2`.
    assert :ok = Hq.CLI.require_pane(verb)

    assert {:ok, %{"name" => "boss", "pane_id" => "w1:p1"}} = Hq.CLI.request(verb, args)
    assert Hq.Session.alive?("boss")

    rename = FakeHerdr.calls(fake) |> Enum.find(&(&1["method"] == "agent.rename"))
    assert rename["params"] == %{"target" => "w1:p1", "name" => "boss"}
  end

  # C2: `decorate/1` stamps "from" with the raw pane id ($HERDR_PANE_ID), e.g.
  # "w1:p1" — every downstream consumer of `spawned_by` (Hq.Spawner,
  # Hq.Session, Hq.Notify) expects a session NAME instead, so a pane id
  # reaching them just never matches anything. This drives the REAL pipeline
  # `parse -> decorate -> request` (not a hand-written "from") through the
  # real daemon (Hq.Control + Hq.Control.Handler), exactly as `run_verb/1`
  # does, so a fix that only works when a test hand-writes "from" => "boss"
  # cannot hide behind it.
  test "spawned_by reaching a session is a NAME, not the raw pane id decorate/1 attaches", %{
    fake: fake
  } do
    FakeHerdr.stub(fake, "pane.send_input", %{"type" => "pane_send_input"})

    FakeHerdr.stub(fake, "pane.process_info", %{
      "process_info" => %{
        "foreground_processes" => [%{"name" => "zsh", "pid" => 999}],
        "shell_pid" => 999
      }
    })

    FakeHerdr.stub(fake, "pane.get", %{
      "type" => "pane_info",
      "pane" => %{"pane_id" => "w1:p1", "workspace_id" => "w-boss"}
    })

    FakeHerdr.stub(fake, "tab.create", %{
      "type" => "tab_created",
      "tab" => %{"tab_id" => "t1"},
      "root_pane" => %{"pane_id" => "w1:p2"}
    })

    FakeHerdr.stub(fake, "agent.start", %{
      "type" => "agent_start",
      "agent" => %{"name" => "worker-x"}
    })

    System.put_env("HERDR_PANE_ID", "w1:p1")
    on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

    # "boss" is the session running in the pane the spawn request comes from
    # — the daemon must resolve "w1:p1" (what decorate/1 actually attaches)
    # to "boss" before it ever reaches Hq.Spawner.
    {:ok, _} = Hq.Roster.adopt("boss", "w1:p1")

    {verb, args} = Hq.CLI.parse(["spawn", "worker-x"])
    args = Hq.CLI.decorate(args)
    assert args["from"] == "w1:p1", "decorate/1 must still attach the raw pane id client-side"

    assert :ok = Hq.CLI.require_pane(verb)
    assert {:ok, %{"name" => "worker-x"}} = Hq.CLI.request(verb, args)

    assert Hq.Session.info("worker-x")["spawned_by"] == "boss"
    refute Hq.Session.info("worker-x")["spawned_by"] == "w1:p1"
  end

  # The bug this test guards: Hq.Spawner's fallback used to omit a split
  # target entirely, so Herdr's own documented fallback ("uses the calling
  # pane when HERDR_PANE_ID is available, otherwise the focused pane") took
  # over -- except hq talks to Herdr over the raw socket with no pane context
  # of its own, so it actually landed beside whatever pane the USER happened
  # to have focused at that instant. hq no longer splits at all: it opens a
  # new TAB, and the fallback must resolve the caller's own workspace via
  # `pane.get` and target THAT explicitly, for exactly the same reason --
  # an untargeted `tab.create` has the identical scattering risk an
  # untargeted split did. `decorate/1` already stamps every request's args
  # with `"pane_id"` (the caller's own pane, see the comment on
  # `Hq.Control.Handler.handle/1`); this drives that value through the REAL
  # pipeline -- parse -> decorate -> request -> Hq.Control.Handler ->
  # Hq.Spawner -- and asserts it lands on `tab.create`'s `workspace_id`,
  # rather than hand-writing "pane_id" into spawner args (a hand-written
  # value can't catch the wiring between decorate/1 and the spawner ever
  # breaking).
  test "hq spawn's fallback resolves the caller's workspace via pane.get and opens the tab there, driven through decorate/1",
       %{fake: fake} do
    FakeHerdr.stub(fake, "pane.send_input", %{"type" => "pane_send_input"})

    FakeHerdr.stub(fake, "pane.process_info", %{
      "process_info" => %{
        "foreground_processes" => [%{"name" => "zsh", "pid" => 999}],
        "shell_pid" => 999
      }
    })

    FakeHerdr.stub(fake, "pane.get", %{
      "type" => "pane_info",
      "pane" => %{"pane_id" => "w3:p1", "workspace_id" => "w-caller"}
    })

    FakeHerdr.stub(fake, "tab.create", %{
      "type" => "tab_created",
      "tab" => %{"tab_id" => "t1"},
      "root_pane" => %{"pane_id" => "w1:p2"}
    })

    FakeHerdr.stub(fake, "agent.start", %{
      "type" => "agent_start",
      "agent" => %{"name" => "worker-z"}
    })

    System.put_env("HERDR_PANE_ID", "w3:p1")
    on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

    {verb, args} = Hq.CLI.parse(["spawn", "worker-z", "--cwd", "/tmp/x"])
    args = Hq.CLI.decorate(args)
    assert args["pane_id"] == "w3:p1", "decorate/1 must attach the caller's own pane"

    assert :ok = Hq.CLI.require_pane(verb)
    assert {:ok, %{"name" => "worker-z"}} = Hq.CLI.request(verb, args)

    refute Enum.any?(FakeHerdr.calls(fake), &(&1["method"] == "pane.split")),
           "hq must never pane.split -- every spawn gets its own tab"

    get = FakeHerdr.calls(fake) |> Enum.find(&(&1["method"] == "pane.get"))
    assert get["params"]["pane_id"] == "w3:p1"

    tab = FakeHerdr.calls(fake) |> Enum.find(&(&1["method"] == "tab.create"))
    assert tab["params"]["workspace_id"] == "w-caller"
    assert tab["params"]["label"] == "worker-z"
  end

  # When the calling pane has no supervised session (e.g. the operator's own
  # pane, never `hq register`ed), the pane id must fall back to "operator"
  # rather than reach Hq.Spawner as a raw, un-lookupable pane id.
  test "spawned_by falls back to operator when the calling pane has no supervised session", %{
    fake: fake
  } do
    FakeHerdr.stub(fake, "pane.send_input", %{"type" => "pane_send_input"})

    FakeHerdr.stub(fake, "pane.process_info", %{
      "process_info" => %{
        "foreground_processes" => [%{"name" => "zsh", "pid" => 999}],
        "shell_pid" => 999
      }
    })

    FakeHerdr.stub(fake, "pane.get", %{
      "type" => "pane_info",
      "pane" => %{"pane_id" => "w9:p9", "workspace_id" => "w-operator"}
    })

    FakeHerdr.stub(fake, "tab.create", %{
      "type" => "tab_created",
      "tab" => %{"tab_id" => "t1"},
      "root_pane" => %{"pane_id" => "w1:p2"}
    })

    FakeHerdr.stub(fake, "agent.start", %{
      "type" => "agent_start",
      "agent" => %{"name" => "worker-y"}
    })

    System.put_env("HERDR_PANE_ID", "w9:p9")
    on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

    {verb, args} = Hq.CLI.parse(["spawn", "worker-y"])
    args = Hq.CLI.decorate(args)

    assert {:ok, %{"name" => "worker-y"}} = Hq.CLI.request(verb, args)
    assert Hq.Session.info("worker-y")["spawned_by"] == "operator"
  end

  test "hq inbox resolves the calling pane to its session" do
    System.put_env("HERDR_PANE_ID", "w2:p1")
    on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

    {:ok, _} = Hq.Roster.adopt("worker-c", "w2:p1")
    Hq.Session.deliver("worker-c", "worker-a", "hi from the pane test")

    {verb, args} = Hq.CLI.parse(["inbox"])
    args = Hq.CLI.decorate(args)

    assert :ok = Hq.CLI.require_pane(verb)

    assert {:ok, %{"pending" => [%{"body" => "hi from the pane test"}]}} =
             Hq.CLI.request(verb, args)
  end

  # -- require_pane/1: register / inbox need $HERDR_PANE_ID -------------------
  #
  # Outside a Herdr pane, `register` and `inbox` used to reach the daemon
  # anyway and come back as a bare `unknown_verb` naming the verb itself
  # (e.g. `hq: register`) -- telling the caller neither the real cause nor
  # the remedy. `run_verb/1` now checks `require_pane/1` before `request/2`,
  # so a request that cannot succeed never opens a socket. These tests stop
  # the (in-test) control listener first, so a test that wrongly fell through
  # to `request/2` would surface as a connection failure instead of the clean
  # `no_pane` error asserted here.
  describe "require_pane/1" do
    test "register: clear error with no HERDR_PANE_ID, daemon never contacted" do
      System.delete_env("HERDR_PANE_ID")
      :ok = stop_supervised(Hq.Control)

      assert {:error, %{"code" => "no_pane", "message" => message}} =
               Hq.CLI.require_pane("register")

      assert message =~ "not running inside a Herdr pane"
      assert message =~ "HERDR_PANE_ID"
    end

    test "inbox: clear error with no HERDR_PANE_ID, daemon never contacted" do
      System.delete_env("HERDR_PANE_ID")
      :ok = stop_supervised(Hq.Control)

      assert {:error, %{"code" => "no_pane", "message" => message}} =
               Hq.CLI.require_pane("inbox")

      assert message =~ "not running inside a Herdr pane"
    end

    test "register and inbox pass when HERDR_PANE_ID is set" do
      System.put_env("HERDR_PANE_ID", "w9:p1")
      on_exit(fn -> System.delete_env("HERDR_PANE_ID") end)

      assert :ok = Hq.CLI.require_pane("register")
      assert :ok = Hq.CLI.require_pane("inbox")
    end

    test "other verbs are unaffected by a missing HERDR_PANE_ID" do
      System.delete_env("HERDR_PANE_ID")

      assert :ok = Hq.CLI.require_pane("send")
      assert :ok = Hq.CLI.require_pane("ls")
      assert :ok = Hq.CLI.require_pane("spawn")
      assert :ok = Hq.CLI.require_pane("release")
    end
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

  # -- I4: a genuine timeout must report as a timeout, not `no_daemon` --------
  #
  # `Hq.Spawner`'s worst-case server-side budget (two 15s `wait_for_shell`
  # polls plus up to 8 attempts at a 60s `agent.start` each) comfortably
  # exceeds the old 60s client recv, so a spawn that was simply still
  # running printed `hq: no_daemon` -- implying the daemon had died -- when
  # it was healthy and busy. `request_timeout_ms/0` is configurable (mirrors
  # every other timeout in this codebase, e.g. `settle_ms`) precisely so this
  # can be proven in well under a second rather than by actually waiting out
  # the real budget: a fake server here accepts `ensure_daemon/0`'s probe
  # connection (closing it immediately, exactly like `Hq.Control` answering
  # `ping`) and then accepts the real request, reads it, and simply never
  # replies -- forcing `request/2` down its recv-timeout path deterministically.
  test "a genuine daemon timeout reports `timeout`, not `no_daemon`" do
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

    server =
      spawn(fn ->
        {:ok, probe} = :gen_tcp.accept(listen, 2_000)
        :gen_tcp.close(probe)

        case :gen_tcp.accept(listen, 2_000) do
          {:ok, sock} ->
            :gen_tcp.recv(sock, 0, 2_000)
            # Hold well past the client's (shortened) timeout without ever
            # replying -- the daemon is alive and working, just slow.
            Process.sleep(300)
            :gen_tcp.close(sock)

          _ ->
            :ok
        end
      end)

    Application.put_env(:hq, :request_timeout_ms, 50)
    on_exit(fn -> Application.delete_env(:hq, :request_timeout_ms) end)

    assert {:error, %{"code" => "timeout"}} = Hq.CLI.request("ping", %{})

    Process.exit(server, :kill)
    :gen_tcp.close(listen)
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

  test "ls renders the parent a session was spawned by" do
    session = %{
      "name" => "worker-a",
      "pane_id" => "w1:p1",
      "cwd" => "/tmp",
      "status" => "idle",
      "spawned_by" => "boss",
      "mailbox" => 0
    }

    assert Hq.CLI.render("ls", %{"sessions" => [session]}) =~ "boss"
  end

  # `Hq.Session.info/1` already returns "spawned_by" => nil for a session
  # registered directly rather than spawned; a naive renderer that just
  # interpolates the field (`"#{s["spawned_by"]}"`) would print the literal
  # word "nil" in the parent column, indistinguishable from a session
  # actually named that.
  test "ls renders a session with no parent as blank/'-', not the word nil" do
    session = %{
      "name" => "orchestrator",
      "pane_id" => "w1:p1",
      "cwd" => "/tmp",
      "status" => "idle",
      "spawned_by" => nil,
      "mailbox" => 0
    }

    line = Hq.CLI.render("ls", %{"sessions" => [session]})
    refute line =~ "nil"
    assert line =~ ~r/\s-\s/
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
  # `setup` above brings `Hq.Control` up before any test runs, so a naive
  # "concurrent ensure_daemon calls" test would have every caller's very
  # first `connect()` inside `ensure_daemon/0` already succeed -- the whole
  # `with_lock/1` branch, including the O_EXCL open, would never be reached.
  # That made such a test pass identically against a version of
  # `with_lock/1` with no locking at all (verified in the task report), so it
  # was deleted rather than kept alongside these two, which stop Hq.Control
  # first so every caller is forced through `with_lock/1`, and replace the
  # real `hq` binary on `$PATH` with a stub that only records that it ran --
  # proving the lock's mutual-exclusion property against the real code, not
  # a re-implementation of it, without needing a real daemon to come up.
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

  # `hq daemon`'s `run_daemon/0` used to do `{:ok, _} =
  # Application.ensure_all_started(:hq)`, so when `Hq.Control.init/1` stops
  # with `{:socket_in_use, pid}` (a second daemon started against a root a
  # live one already owns), the user saw a raw `MatchError` and supervisor
  # crash dump instead of being told a daemon is already running.
  # `Application.ensure_all_started/1` buries that reason deep inside OTP's
  # own supervisor-shutdown wrapper; this feeds `daemon_start_error/1` a
  # synthetic reason in that authentic shape (confirmed against a real
  # `Application.ensure_all_started(:hq)` failure while writing this fix)
  # rather than calling it for real, since an application's start callback
  # only runs once per node per start -- `mix test` itself already started
  # `:hq` once, so a second call in-process would just no-op.
  test "daemon_start_error names a live daemon in plain language, not a crash dump" do
    reason = {:hq, {:shutdown, {:failed_to_start_child, Hq.Control, {:socket_in_use, "54321"}}}}

    message = Hq.CLI.daemon_start_error(reason)

    assert message =~ "a daemon is already running"
    assert message =~ "54321"
  end

  test "daemon_start_error falls back to the raw reason for an unrelated startup failure" do
    reason = {:hq, {:shutdown, {:failed_to_start_child, Hq.Roster, :boom}}}

    message = Hq.CLI.daemon_start_error(reason)

    refute message =~ "already running"
    assert message =~ "boom"
  end
end
