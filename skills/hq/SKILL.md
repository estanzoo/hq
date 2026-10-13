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
hq spawn ca-ingress-1 --worktree --base <feature branch> --cwd "$PWD" --task "..."
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

## Record yourself in the epic ledger

The user keeps a record of every epic in the **hq Epic Ledger**, https://claude.ai/artifact/QDXVmVJS8MJr9qvWXyM7Ez —
its orchestrator, its workers, and the command that reopens each
conversation. You keep your own epic's entry current, and you are its only
writer. Create it the moment you register.

Write with the `ArtifactData` tool. Every call passes `url` = the link above
and `collection` = `epics`; your document id is the epic's bead id.

**Rules for every write**

- **Read, then write.** `get` the document, then `update` it with `if_version`
  set to the `version` you just read. If the write is refused because the
  version changed, `get` it again and repeat the same update.
- **Write one entry at a time.** Workers live under `workers.<worker-name>`
  and your sessions under `sessions.<session-id>`. An `update` merges nested
  objects, so writing one worker, or one field of one worker, never touches
  the others. Never resend the whole `workers` or `sessions` map — you would
  overwrite entries you did not mean to change.
- **Time** is ISO 8601 UTC: `date -u +%Y-%m-%dT%H:%M:%SZ`.
- **Your session id** is `$CLAUDE_CODE_SESSION_ID` (`echo $CLAUDE_CODE_SESSION_ID`).
  It is what lets the user reopen this conversation later, so always record it.

**1. When you register.** `get` your document first: an epic can be resumed by
a new orchestrator, and its entry may already exist.

- If it does not exist, `set` it:

  ```json
  {
    "epic": "<epic bead id>",
    "title": "<epic title, from br show>",
    "orchestrator": "<the name you registered>",
    "repo": "<absolute path of the repository root>",
    "status": "running",
    "source": "self-reported",
    "started_at": "<now>",
    "updated_at": "<now>",
    "sessions": { "<your session id>": { "cwd": "<absolute $PWD>", "started_at": "<now>" } },
    "workers": {}
  }
  ```

- If it exists, `update` it with `"status": "running"`, `"orchestrator"`,
  `"updated_at"`, and your own entry under `sessions`.

**2. When you set up the feature worktree** (step 2 below), `update`
`feature_branch` and `feature_worktree` (absolute path).

**3. When you spawn a worker**, after `hq spawn` succeeds, `update`:

```json
{
  "updated_at": "<now>",
  "workers": {
    "<worker name>": {
      "name": "<worker name>",
      "bead": "<bead id>",
      "bead_title": "<bead title>",
      "branch": "<its branch, from git worktree list>",
      "base": "<the --base you passed>",
      "worktree": "<absolute worktree path>",
      "spawned_at": "<now>",
      "status": "running",
      "worktree_exists": true
    }
  }
}
```

End every worker's `--task` with this sentence, so its session id reaches you:
*"End your final report with a line `session: ` followed by the output of
`echo $CLAUDE_CODE_SESSION_ID`."*

**4. When a worker reports it is done**, `update` its entry with
`session_id` (from its `session:` line), `"status": "done"`, `finished_at`,
and the epic's `updated_at`. If its report has no `session:` line, ask for it
with `hq send` before you record it.

**5. When the work lands** (step 7 below), `update` `"status": "landed"`,
`landed_at`, `landed_commits`, and `"landed": true` on each worker whose
branch is now inside the feature branch.

**6. At cleanup** (step 8 below), for each worktree `hq cleanup --yes`
removed, `update` that worker's `"worktree_exists": false`. The ledger then
shows the command that recreates the worktree before reopening it.

**If you do not have the `ArtifactData` tool,** do not skip the record.
Append each write as one JSON line —
`{"doc_id": "...", "op": "set" | "update", "data": {...}}` — to
`~/.hq/ledger-pending.jsonl`, and tell the user once, so it can be imported.

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

### 2. Set up your feature worktree

Every epic has exactly one **feature branch** — the branch its PR will come
from — checked out in a worktree named after you, `.worktree/<your-name>`. All
of the epic's work ends up there, so the finished result can be read in one
place instead of on whichever worker happened to run last.

- If the user names a feature branch, or the epic already has one (often the
  branch its spec was written on), use that.
- Check where it is checked out with `git worktree list`. If it is already at
  `.worktree/<your-name>`, use it. If it is not checked out anywhere, check it
  out there:

  ```bash
  git worktree add .worktree/<your-name> <feature branch>
  ```

  If it is checked out somewhere else — in the main checkout, say — stop and
  ask the user before going on.
- If there is no feature branch yet, create one from `main`:

  ```bash
  git worktree add -b feat/<your-name> .worktree/<your-name> main
  ```

This worktree is yours. Never spawn a worker into it, and `hq cleanup` never
removes it. **Ledger:** record `feature_branch` and `feature_worktree` now.

### 3. One rule: every task gets its own worktree, based on its dependencies

**Each task runs in its own worktree, on its own branch, based on the merge of
the branches of the tasks it depends on.** One task per agent, always.
Batching several tasks into one agent carries each task's context into the
next and turns a single wedge into the loss of the whole chain; do it only for
a change that genuinely cannot be committed in pieces.

That one rule covers every shape of epic:

| a task's dependencies | its base |
|---|---|
| none | the feature branch |
| exactly one | that task's branch |
| several | the merge of their branches — which you build first (step 5) |

Because every task has its own worktree, each worker gets its own entry in the
Herdr sidebar, nested under the repo, and stays there after it finishes so the
user can review it.

A task can only start once **all** of its dependencies have finished and
committed. Tasks with no unfinished dependencies can run at the same time.

### 4. Spawning

Find a finished dependency's branch from its worktree — the worker may have
renamed it, so read it rather than assuming `agent/<name>`:

```bash
git worktree list          # every worktree, with the branch checked out in it
```

**No dependencies** — branch from the feature branch, never from `main`.
Starting every chain on the feature branch is what lets step 7 land all the
work there with a plain fast-forward:

```bash
hq spawn ev-limit-1 --worktree --base <feature branch> --cwd "$PWD" \
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

**Ledger:** after each spawn, add the worker to the ledger (write 3), and end
its `--task` with the sentence asking for its session id.

### 5. Several dependencies: merge them first, then spawn into the result

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

### 6. Watch, and let workers report

```bash
hq ls
```

Workers message you and each other as they go. Their mail is typed into your
session prefixed `[hq]`, which wakes you. Each worker is told its parent by the
spawn preamble, so you don't need to say "report to `<your-name>`" in `--task`,
and never tell a worker to message "orchestrator" by that literal name.

When a worker reports it is done, record its session id in the ledger
(write 4 above).

Leave finished workers open — they are the record the user reviews, and each
has its own sidebar entry. The user closes them when done, or asks you to
clean up (step 8).

### 7. When the epic is done: land the work in your feature worktree

Bring every task's work into the feature branch, so the user can read the
finished result in `.worktree/<your-name>`.

1. **Check your feature worktree is clean** — `git -C .worktree/<your-name>
   status --short` must print nothing. If it doesn't, stop and ask.
2. **Find the final tasks:** the ones nothing else depends on
   (`$BR dep list <task> --direction up` prints nothing). Usually there is
   exactly one — the task that depends on everything else, directly or
   through the chain.
3. **One final task — fast-forward onto it:**

   ```bash
   git -C .worktree/<your-name> merge --ff-only <final task's branch>
   ```

   `--ff-only` either moves the feature branch forward onto that work or
   refuses, so it can never rewrite or lose anything. If it refuses, the
   feature branch changed after the epic began: stop and tell the user rather
   than merging.
4. **Several final tasks** (independent leaves) — merge each one in:

   ```bash
   git -C .worktree/<your-name> merge --no-edit <branch>
   ```

   On a conflict, `git -C .worktree/<your-name> merge --abort` and stop:
   resolve it yourself, spawn a worker to resolve it, or ask the user.
5. **Confirm nothing was missed.** Every task's branch must now be inside the
   feature branch:

   ```bash
   git merge-base --is-ancestor <task branch> <feature branch> && echo landed
   ```

6. **Report** that the work is in `.worktree/<your-name>` on `<feature
   branch>`, with how many commits it gained. Do not push or open a PR — the
   user decides when it lands.
7. **Ledger:** mark the epic landed (write 5).

### 8. Ending a feature: cleanup

Only when the user asks you to clean up — never on your own — close your
workers' panes and remove their worktrees:

```bash
hq cleanup          # a DRY RUN: prints the plan, changes nothing
```

1. Run `hq cleanup` and show the user its plan **verbatim** — every line,
   including what it keeps and why. Do not summarise it.
2. Wait for the user's go-ahead.
3. Then run `hq cleanup --yes` and show the user that output too.

Never add `--yes`, `--include-unrecorded` or `--keep` on your own initiative;
pass each only when the user asks for it:

- `--keep <worker-or-dir>` protects something extra (repeatable).
- `--include-unrecorded` also considers `.worktree/<your-name>-*` worktrees
  from runs older than hq's spawn record. They are matched by name only, so
  they are marked as such in the plan for the user to check.

What it will and will not do:

- It only touches **your** workers — the ones you spawned. Another
  orchestrator's run is left alone.
- It **never closes your own pane**.
- It **never deletes a branch**. Removing a clean worktree loses nothing;
  every commit stays on its branch.
- It **keeps the PR worktree**: any worktree whose branch is on `origin`.
  Workers never push, so a branch on `origin` is one the user pushed for
  review.
- It keeps any worktree that is dirty, still has a working or blocked agent,
  is in use by another session, or is your own; and any pane whose close
  Herdr says needs worktree-group confirmation — it never forces one.
- If Herdr cannot be reached it does nothing at all.

**Ledger:** after `--yes`, mark each removed worktree in the ledger (write 6).

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
