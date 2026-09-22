defmodule Hq.SessionSupTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, fake} = FakeHerdr.start_link()
    root = Path.join(System.tmp_dir!(), "hq-test-#{System.unique_integer([:positive])}")
    Application.put_env(:hq, :herdr_socket, FakeHerdr.path(fake))
    Application.put_env(:hq, :root, root)
    Application.put_env(:hq, :settle_ms, 10)
    on_exit(fn -> File.rm_rf(root) end)

    start_supervised!({Registry, keys: :unique, name: Hq.Registry})
    start_supervised!(Hq.SessionSup)

    FakeHerdr.stub(fake, "agent.get", %{
      "type" => "agent_get",
      "agent" => %{"agent_status" => "working"}
    })

    %{fake: fake}
  end

  test "starts and lists sessions" do
    {:ok, _} = Hq.SessionSup.start_session(name: "worker-a", pane_id: "w5:p1")
    {:ok, _} = Hq.SessionSup.start_session(name: "worker-b", pane_id: "w6:p1")

    names = Hq.SessionSup.list() |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["worker-a", "worker-b"]
  end

  test "refuses a duplicate name" do
    {:ok, _} = Hq.SessionSup.start_session(name: "worker-a", pane_id: "w5:p1")

    assert {:error, {:already_started, _}} =
             Hq.SessionSup.start_session(name: "worker-a", pane_id: "w5:p1")
  end

  test "stops a session" do
    {:ok, _} = Hq.SessionSup.start_session(name: "worker-a", pane_id: "w5:p1")
    assert :ok = Hq.SessionSup.stop_session("worker-a")

    assert Hq.SessionSup.list() == []
    assert eventually(fn -> not Hq.Session.alive?("worker-a") end)
  end

  test "stopping an unknown session is an error" do
    assert {:error, :not_found} = Hq.SessionSup.stop_session("ghost")
  end

  test "a crashed session restarts and keeps its queued mail" do
    {:ok, pid} = Hq.SessionSup.start_session(name: "worker-a", pane_id: "w5:p1")
    Hq.Session.deliver("worker-a", "boss", "survive the crash")

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    assert eventually(fn -> match?({:ok, %{"mailbox" => 1}}, callable_info("worker-a")) end)
  end

  # A Session can legitimately be busy for up to 10s while it delivers a
  # message: `agent.prompt` is bounded at 10s and runs on the Session
  # process itself (see Hq.Session.flush/1). `list/0` must not silently drop
  # a session just because it did not answer within its short 2s :info
  # timeout — that would make a live, merely-busy session look dead to
  # `hq ls`. Simulate "busy" by suspending the process at the :sys level so
  # it cannot service the :info call within the timeout, without killing it.
  test "a session that does not answer within the timeout is listed as busy, not dropped" do
    {:ok, pid} = Hq.SessionSup.start_session(name: "worker-a", pane_id: "w5:p1")

    :sys.suspend(pid)

    try do
      assert [entry] = Hq.SessionSup.list()
      assert entry["name"] == "worker-a"
      assert entry["status"] == "busy"
      assert entry["mailbox"] == nil
    after
      :sys.resume(pid)
    end

    assert eventually(fn -> Hq.Session.alive?("worker-a") end)
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

  # `Hq.Session.alive?/1` only checks Registry, which briefly still holds a
  # dead :transient restart's old pid until Registry processes its own DOWN.
  # A call through the same :via tuple in that window exits :noproc even
  # though alive? just answered true. Waiting on an actual successful call
  # is the only way to know the name resolves to something that can answer.
  defp callable_info(name) do
    {:ok, Hq.Session.info(name)}
  catch
    :exit, _ -> :error
  end
end
