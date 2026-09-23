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

2. Sort the tasks into three groups. There is no branch merging, so what
   matters is which tasks would collide on the same files:

   - **Independent** — touch different files. Run them in parallel, each in
     its own worktree.
   - **Ordered, same branch** — touch the same files, or must land in a set
     order. Run them one at a time in ONE worktree, a fresh agent per task.
     This is the common case for an epic's numbered children, and it needs
     no merging at all.
   - **Genuinely inseparable** — one change that cannot be committed in
     pieces. Only these go to a single agent as a batch.

3. **Spawn one agent per task. One task per agent is the default; batching
   several tasks into one agent is the exception you opt into deliberately.**

   A batched agent carries every earlier task's context into the later ones,
   and if it wedges partway you lose the whole chain rather than one task.

   Independent tasks, in parallel:

   ```bash
   hq spawn worker-a --worktree --base main --cwd "$PWD" \
     --task "Implement <task>. Commit to your branch. Do not push."
   ```

   Ordered tasks sharing a branch — spawn them **sequentially into the same
   worktree**, waiting for each to finish. The first call creates the
   worktree; read its path out of `hq ls` (the `cwd` column) and pass it to
   the rest with `--cwd` and no `--worktree`, so they land in that same
   checkout:

   ```bash
   # first task creates the worktree and the branch
   hq spawn worker-1 --worktree --base main --cwd "$PWD" \
     --task "Implement <bead .1> ONLY. Commit to this branch. Do not push."

   # ... wait for worker-1 to report, then:
   hq release worker-1
   hq spawn worker-3 --cwd "<that worktree path>" \
     --task "Implement <bead .3> ONLY. Commit to this branch. Do not push."
   ```

   Each task starts with clean context, the order is preserved, and every
   commit lands on one branch — so nothing has to be merged afterwards.

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
- One task per agent by default. Batching tasks into one agent accumulates
  context across them and makes a single wedge lose the whole chain.
- There is no branch merging. For work that shares files, prefer sequential
  agents in one worktree (above) over either batching them into one agent or
  merging branches yourself afterwards.
