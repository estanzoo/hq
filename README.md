# hq

A message bus for Claude Code sessions running in [Herdr](https://herdr.dev)
panes. Sessions address each other by name; messages are queued and typed into
the target's visible I/O when it next goes idle.

## Install

```bash
./install.sh
```

Requires a running Herdr server and Elixir 1.18+. The installer builds the
escript, symlinks `hq` onto `$HOME/.local/bin` and `skills/hq` onto
`~/.claude/skills/hq`, and prints the permission allowlist entry to add to
`~/.claude/settings.json` so peer messaging never stalls on an approval
dialog.

## Use

```bash
hq register orchestrator                    # name your own pane
hq spawn worker-a --worktree --task "..."   # create a supervised agent
hq send worker-a "schema is frozen"         # queued; delivered when idle
hq ls                                       # who is live
```

The daemon autostarts on first use of any verb — nothing to run by hand.

```
hq register <name>              name this pane and start supervising it
hq spawn <name> [flags]         create a supervised agent
    --worktree --base <ref> --cwd <path> --kind <kind>
    --task "<text>" --permissive
hq send <name> "<message>"      queue a message; delivered when idle
hq ls                           live sessions, status, mailbox depth
hq inbox                        what is queued for this pane
hq release <name>               stop supervising (does not kill the agent)
hq daemon                       run the daemon in the foreground
```

The `skills/hq/` directory installs as a Claude Code skill so an orchestrating
session can read the workflow itself — see `skills/hq/SKILL.md`.

## How it works

One `Hq.Session` GenServer per agent, each owning a dedicated socket carrying
that pane's Herdr event subscription plus a durable mailbox. Herdr's socket
answers one request per connection and serves only events once subscribed, so
per-agent connections are what the protocol requires, not a stylistic choice.

Delivery targets an *idle* agent, which means a message is also the wakeup:
agent works → idles → mail lands → works again. Nothing polls.

Design notes: `docs/superpowers/specs/2026-09-21-hq-design.md`
