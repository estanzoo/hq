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

You own all the policy. `hq` only moves messages and starts agents — it never
merges branches. Merging, when a task needs it, is your job.

### 1. Read the epic and its dependency graph

```bash
BR="br --db $HOME/beads-planning/.beads/beads.db"
$BR show <epic>            # what the epic is
$BR dep tree <epic>        # the whole graph: which task waits on which
$BR dep list <task>        # what one task waits on (its dependencies)
```

The dependency graph decides everything below. Read it before spawning anyone.

### 2. One rule: every task gets its own worktree, based on its dependencies

**Each task runs in its own worktree, on its own branch, based on the merge of
the branches of the tasks it depends on.** One task per agent, always.
Batching several tasks into one agent carries each task's context into the
next and turns a single wedge into the loss of the whole chain; do it only for
a change that genuinely cannot be committed in pieces.

That one rule covers every shape of epic:

| a task's dependencies | its base |
|---|---|
| none | `main` |
| exactly one | that task's branch |
| several | the merge of their branches — which you build first (step 4) |

Because every task has its own worktree, each worker gets its own entry in the
Herdr sidebar, nested under the repo, and stays there after it finishes so the
user can review it.

A task can only start once **all** of its dependencies have finished and
committed. Tasks with no unfinished dependencies can run at the same time.

### 3. Spawning

Find a finished dependency's branch from its worktree — the worker may have
renamed it, so read it rather than assuming `agent/<name>`:

```bash
git worktree list          # every worktree, with the branch checked out in it
```

**No dependencies** — branch from `main`:

```bash
hq spawn ev-limit-1 --worktree --base main --cwd "$PWD" \
  --task "Implement <bead .1>. Commit to your branch. Do not push."
```

**One dependency** — branch from it, so the new task builds on its commits:

```bash
hq spawn ev-limit-2 --worktree --base <ev-limit-1's branch> --cwd "$PWD" \
  --task "Implement <bead .2>. Commit to your branch. Do not push."
```

Add `--kind <kind>` to pick a non-default agent kind, or `--permissive` to
skip that worker's permission prompts entirely — only when the user has asked
for an unattended run.

### 4. Several dependencies: merge them first, then spawn into the result

When a task depends on several others — say `.4` needs `.1`, `.2` and `.3` —
build its worktree yourself by merging their branches, and only then spawn the
agent into it. Do this from the repository root, never inside the primary
checkout's working tree:

```bash
# a new worktree + branch for .4, starting from the first dependency
git worktree add -b feat/ev-limit-4 .worktree/ev-limit-4 <branch of .1>

# merge the remaining dependencies into it
git -C .worktree/ev-limit-4 merge --no-edit <branch of .2> <branch of .3>
```

**If the merge conflicts, stop.** Run `git -C .worktree/ev-limit-4 merge
--abort` and do not spawn onto a conflicted tree. A conflict means those tasks
were not independent after all. Either resolve it yourself, or spawn a worker
whose only task is resolving it, or ask the user — but decide deliberately.

When the merge is clean, spawn the task into that worktree with `--cwd` and no
`--worktree`. hq opens it as its own workspace, so it still gets its own
sidebar entry:

```bash
hq spawn ev-limit-4 --cwd "$PWD/.worktree/ev-limit-4" \
  --task "Implement <bead .4>. Commit to this branch. Do not push."
```

Always give `--cwd` an **absolute** path, as above. hq hands it to its daemon,
which does not share your working directory — a relative path is resolved
against wherever the daemon happened to start, not where you are.

### 5. Watch, and let workers report

```bash
hq ls
```

Workers message you and each other as they go. Their mail is typed into your
session prefixed `[hq]`, which wakes you. Each worker is told its parent by the
spawn preamble, so you don't need to say "report to `<your-name>`" in `--task`,
and never tell a worker to message "orchestrator" by that literal name.

Leave finished workers open — they are the record the user reviews, and each
has its own sidebar entry. The user closes them when done.

### 6. When the epic is done

The task that depends on everything else — directly or through the chain —
has a branch containing all of the epic's work. **Report which branch that is**
in your summary to the user. Do not push, open a PR, or move a shared branch
such as the feature branch; the user decides how it lands.

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
- One task per agent, each in its own worktree, based on the merge of its
  dependencies' branches.
- hq never merges. When a task has several dependencies you merge their
  branches into its worktree yourself, before spawning — and stop on a
  conflict rather than spawning onto it.
