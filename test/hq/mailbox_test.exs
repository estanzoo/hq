defmodule Hq.MailboxTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "hq-test-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:hq, :root)
    Application.put_env(:hq, :root, root)

    on_exit(fn ->
      Application.put_env(:hq, :root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  test "starts empty" do
    mb = Hq.Mailbox.load("worker-a")
    assert Hq.Mailbox.depth(mb) == 0
  end

  test "preserves FIFO order" do
    mb =
      Hq.Mailbox.load("worker-a")
      |> Hq.Mailbox.enqueue("alice", "first")
      |> Hq.Mailbox.enqueue("bob", "second")

    {msgs, mb} = Hq.Mailbox.drain(mb)

    assert ["first", "second"] == Enum.map(msgs, & &1["body"])
    assert ["alice", "bob"] == Enum.map(msgs, & &1["from"])
    assert Hq.Mailbox.depth(mb) == 0
  end

  test "survives a reload — a daemon restart must not eat queued mail" do
    Hq.Mailbox.load("worker-a") |> Hq.Mailbox.enqueue("alice", "durable")

    reloaded = Hq.Mailbox.load("worker-a")
    assert Hq.Mailbox.depth(reloaded) == 1
    assert [%{"body" => "durable"}] = reloaded.pending
  end

  test "a drain is persisted, so drained mail is not redelivered after a restart" do
    mb = Hq.Mailbox.load("worker-a") |> Hq.Mailbox.enqueue("alice", "once")
    {_msgs, _mb} = Hq.Mailbox.drain(mb)

    assert Hq.Mailbox.depth(Hq.Mailbox.load("worker-a")) == 0
  end

  test "mailboxes are per-name" do
    Hq.Mailbox.load("worker-a") |> Hq.Mailbox.enqueue("alice", "for a")

    assert Hq.Mailbox.depth(Hq.Mailbox.load("worker-b")) == 0
  end

  test "skips truncated final line — daemon killed mid-rewrite" do
    # Simulate daemon killed mid-write: two complete lines followed by truncated JSON
    root = Application.get_env(:hq, :root)
    path = Path.join([root, "mailbox", "worker-c.ndjson"])
    File.mkdir_p!(Path.dirname(path))

    valid1 = JSON.encode!(%{"from" => "alice", "body" => "first", "at" => "2026-09-21T00:00:00Z"})
    valid2 = JSON.encode!(%{"from" => "bob", "body" => "second", "at" => "2026-09-21T00:01:00Z"})
    truncated = ~s({"from":"carol","bo)

    File.write!(path, "#{valid1}\n#{valid2}\n#{truncated}")

    # Load should skip the truncated line and return only the two complete messages
    mb = Hq.Mailbox.load("worker-c")
    assert Hq.Mailbox.depth(mb) == 2
    bodies = Enum.map(mb.pending, & &1["body"])
    assert bodies == ["first", "second"]
  end

  test "old content survives a failed write" do
    # First enqueue two messages
    mb =
      Hq.Mailbox.load("worker-d")
      |> Hq.Mailbox.enqueue("alice", "msg1")
      |> Hq.Mailbox.enqueue("bob", "msg2")

    assert Hq.Mailbox.depth(mb) == 2

    # Now make persist fail by creating a directory at the .tmp path
    # so File.write! to .tmp will raise
    root = Application.get_env(:hq, :root)
    tmp_path = Path.join([root, "mailbox", "worker-d.ndjson.tmp"])
    File.mkdir_p!(tmp_path)

    # Try to enqueue a third message; this should raise when trying to write .tmp
    assert_raise File.Error, fn ->
      Hq.Mailbox.enqueue(mb, "carol", "msg3")
    end

    # Clean up the directory we created
    File.rmdir(tmp_path)

    # Verify the original two messages are still there — the failed write did not destroy them
    reloaded = Hq.Mailbox.load("worker-d")
    assert Hq.Mailbox.depth(reloaded) == 2
    bodies = Enum.map(reloaded.pending, & &1["body"])
    assert bodies == ["msg1", "msg2"]
  end
end
