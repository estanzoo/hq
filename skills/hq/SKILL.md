---
name: hq
description: Use when coordinating several Claude Code sessions as an orchestrator — running an epic across parallel worker agents, spawning workers in worktrees, or sending a message to another named session. Requires a running Herdr server and the hq daemon.
---

# hq — coordinating parallel sessions

`hq` lets Claude Code sessions running in Herdr panes message each other.
Messages are queued and typed into the target session's visible I/O when it
next goes idle, so an arriving message is also the target's wakeup. `hq`
autostarts its own daemon on first use — you never start it by hand.

## Check you can use it

```bash
test -n "${HERDR_PANE_ID:-}" && hq ls
```

If `HERDR_PANE_ID` is unset you are not in a Herdr-managed pane; say so and
stop.

## Register yourself first

```bash
hq register orchestrator
```

This names your pane so peers can address you. Do it before spawning anyone.

## Running an epic

You own all the policy. `hq` only moves messages and starts agents.

1. Read the epic yourself:

   ```bash
   br --db ~/beads-planning/.beads/beads.db ready --json
   ```

2. Decide which tasks can run in parallel. Tasks that touch the same files
   should not — there is no merge handling, so overlapping work collides.

3. Spawn a worker per task:

   ```bash
   hq spawn worker-a --worktree --base main --cwd "$PWD" \
     --task "Implement <task>. Commit to your branch. Do not push."
   ```

   Add `--kind <kind>` to pick a non-default agent kind, or `--permissive` to
   skip that worker's permission prompts entirely — only when the user has
   asked for an unattended run.

4. Watch them:

   ```bash
   hq ls
   ```

5. Workers message you and each other as they go. Their mail is typed into
   your session prefixed `[hq]`, which wakes you.

## Messaging

```bash
hq send worker-b "the schema is frozen: users.id is uuid"
hq ls        # who is live, their status, how much mail is queued
hq inbox     # what is queued for you
```

A message to a working agent is queued, not dropped, and delivered the moment
it goes idle. Tell peers what you have decided rather than waiting to be asked.

## Rules

- Names must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents.
- `hq` never answers an approval dialog. If `hq ls` shows a worker `blocked`,
  look at it with `herdr agent read <name> --source detection` and ask the user.
- `--permissive` starts a worker with permissions skipped. Use it only when the
  user has asked for an unattended run.
- `hq release <name>` stops supervising a session; it does not kill the agent.
- There is no branch merging. Either serialise work that shares files, or merge
  the workers' branches yourself once they land.
