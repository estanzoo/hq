---
name: hq
description: Use when coordinating several Claude Code sessions as an orchestrator — running an epic across parallel worker agents, spawning workers in worktrees, or sending a message to another named session. Requires a running Herdr server and the hq daemon.
---

# hq — coordinating parallel sessions

`hq` lets Claude Code sessions running in Herdr panes message each other.
Messages are queued and typed into the target session's visible I/O when it
next goes idle, so an arriving message is also the target's wakeup. `hq`
autostarts its own daemon on first use — you never start it by hand.

`hq stop` and `hq restart` exist for the rare case the daemon itself needs to
come down (usually: picking up a new build after `./install.sh`, which does
NOT reload a daemon that is already running). `hq stop` asks the daemon to
shut itself down over its own control socket; never reach for `pkill` or
`killall` here — matching a running process by a command-line pattern across
the whole machine is exactly what has previously killed unrelated terminal
sessions and editor processes that merely shared a substring with the
daemon's own invocation.

## Check you can use it

```bash
test -n "${HERDR_PANE_ID:-}" && hq ls
```

If `HERDR_PANE_ID` is unset you are not in a Herdr-managed pane; say so and
stop.

## Naming: register yourself first

hq names are **global to the machine**, not per-orchestrator — one daemon is
shared by every session in every Herdr pane. Two orchestrators running at once
cannot share a name, and if you register one another live orchestrator holds,
`hq register` fails. The fix is to pick a different name, never to proceed
unregistered: an unregistered orchestrator is unaddressable, so its workers
cannot report back to it.

**The convention, which keeps every name in a run self-identifying:**

- **Orchestrator** — a shortened form of the epic you are running. Strip the
  `plan-` prefix and the random suffix, then shorten what is left until it is
  recognisable but brief.
- **Workers** — the orchestrator's name plus a suffix identifying which agent
  it is. Use the bead it implements when there is one, so a name says both
  which run it belongs to and which task it holds.

```
epic          plan-custom-actions-ingress-y2w
orchestrator  ca-ingress
workers       ca-ingress-1   ca-ingress-3   ca-ingress-4
```

```bash
hq register ca-ingress
hq spawn ca-ingress-1 --worktree --base main --cwd "$PWD" --task "..."
```

Two constraints to respect when you shorten:

- A name must match `[a-z][a-z0-9_-]{0,31}` — **32 characters**. The suffix
  has to fit too, so keep the orchestrator name to roughly 20 characters or
  fewer. `ca-ingress` leaves plenty; `custom-actions-ingress` leaves almost
  none.
- Names must be unique among *live* agents only. A finished run frees its
  names, so you may reuse a slug once its sessions are gone.

Register before spawning anyone. If it fails with `name_taken`, the error
names what currently holds it — shorten differently and register again.

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
   hq spawn ca-ingress-1 --worktree --base main --cwd "$PWD" \
     --task "Implement <bead>. Commit to your branch. Do not push."
   ```

   Ordered tasks sharing a branch — spawn them **sequentially into the same
   worktree**, waiting for each to finish. The first call creates the
   worktree; read its path out of `hq ls` (the `cwd` column) and pass it to
   the rest with `--cwd` and no `--worktree`, so they land in that same
   checkout:

   ```bash
   # first task creates the worktree and the branch
   hq spawn ca-ingress-1 --worktree --base main --cwd "$PWD" \
     --task "Implement <bead .1> ONLY. Commit to this branch. Do not push."

   # ... wait for ca-ingress-1 to report, then:
   hq release ca-ingress-1
   hq spawn ca-ingress-3 --cwd "<that worktree path>" \
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

   Each worker is told its parent by the spawn preamble itself (`hq send
   <name-you-registered> "<message>"`) — you don't need to spell out "report
   to `<your-name>`" in `--task`. Don't tell a worker to message "orchestrator"
   by that literal name; it should address whatever name you actually
   registered, which the preamble already gave it.

## Messaging

```bash
hq send ca-ingress-3 "the schema is frozen: users.id is uuid"
hq ls        # who is live, their status, how much mail is queued
hq inbox     # what is queued for you
```

A message to a working agent is queued, not dropped, and delivered the moment
it goes idle. Tell peers what you have decided rather than waiting to be asked.

## Rules

- Names must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents.
  Orchestrator = shortened epic name; worker = that name plus a task suffix.
- `hq` never answers an approval dialog. If `hq ls` shows a worker `blocked`,
  look at it with `herdr agent read <name> --source detection` and ask the user.
- `--permissive` starts a worker with permissions skipped. Use it only when the
  user has asked for an unattended run.
- `hq release <name>` stops supervising a session; it does not kill the agent.
- `hq stop` / `hq restart` stop or restart the daemon itself -- never `pkill`
  or `killall` it. After `./install.sh`, `hq restart` is required for an
  already-running daemon to pick up the new build.
- One task per agent by default. Batching tasks into one agent accumulates
  context across them and makes a single wedge lose the whole chain.
- There is no branch merging. For work that shares files, prefer sequential
  agents in one worktree (above) over either batching them into one agent or
  merging branches yourself afterwards.
