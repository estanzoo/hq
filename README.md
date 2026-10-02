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
hq cleanup [flags]              close this orchestrator's worker panes and
                                remove their worktrees (DRY RUN unless --yes)
    --yes --keep <worker-or-dir> --include-unrecorded
hq stop                         stop the daemon (safe; never pkill/killall)
hq restart                      stop the daemon, then start a fresh one
hq daemon                       run the daemon in the foreground
```

`./install.sh` rebuilds the escript but does not touch a daemon already
running -- it keeps serving the OLD build until you `hq restart`. Run that
after every install/update where a daemon might already be up.

`hq stop` asks the daemon to shut itself down over its own control socket
first; that is the only path used unless the socket does not answer, in
which case it falls back to signalling the daemon's pid directly -- and only
after confirming, via that pid's own command line, that it actually belongs
to hq. It never uses `pkill` or `killall`: matching by command-line pattern
across every process on the machine is exactly what those do, and exactly
what previously took down unrelated terminal sessions and editor processes
that merely happened to share a substring with the daemon's invocation.

`hq cleanup`, run from an orchestrator's own pane at the end of a feature,
closes that orchestrator's worker panes and removes their worktrees. Without
`--yes` it only prints the plan. It finds the workers from a durable spawn
record (`runs.json` under `~/.hq`) and from live sessions that orchestrator
spawned. It never closes the orchestrator's own pane and never deletes a
branch, and it removes worktrees only with plain `git worktree remove`
(never `--force`). It keeps:

- any worktree whose branch is on `origin`, checked with `git ls-remote`.
  Workers never push, so that branch is the one pushed for the PR. If origin
  cannot be reached, local refs decide, and the plan says so.
- dirty worktrees, the primary checkout and the orchestrator's own worktree.
- worktrees still in use by another session.
- anything named in `--keep`.
- any pane whose agent is not idle, and any pane Herdr will only close with
  worktree-group confirmation.

If Herdr cannot be reached, nothing is closed and nothing is removed.
`--include-unrecorded` also considers `.worktree/<orchestrator>-*` worktrees
from before the record existed, and marks them as matched by name only.

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
