#!/usr/bin/env bash
# bdherd — dispatch beads-ready tasks to Claude agents in Herdr worktrees.
#
# Reads the independent (unblocked) tasks out of a beads database, and for each
# one creates a local git worktree, opens it as a Herdr workspace, starts a
# Claude agent in it, and hands it the issue.
#
# Branches and worktrees are LOCAL ONLY. Nothing is ever pushed and no PR is
# opened, but --watch does merge locally: a task's worktree gets its
# dependencies' branches merged in before its agent starts, and once the whole
# graph finishes every branch is folded into the base branch.
#
#   bdherd --dry-run              show what would be dispatched
#   bdherd                        dispatch every ready task (up to --max)
#   bdherd --epic plan-kai        dispatch only that epic's ready children
#   bdherd plan-kai.1 plan-kai.4  dispatch specific issues
#   bdherd --epic plan-kai --watch
#                                 run the whole epic: dispatch a wave, wait for
#                                 it, close it, merge it, dispatch the next
#   bdherd --epic plan-kai --watch --no-merge
#                                 same, but never touch any branch
#
# --watch trades the review gate for automation: it closes each issue once its
# agent finishes, without checking the work, and merges on completion. Use it
# for tests and low-risk runs. Any conflict stops it with nothing half-merged.
#
# Requires: herdr (server running), bd, git, jq.

set -euo pipefail

PLAN_DB="${BDHERD_PLAN_DB:-$HOME/beads-planning}"
REPO="${BDHERD_REPO:-}"
BASE="${BDHERD_BASE:-main}"
MAX="${BDHERD_MAX:-3}"
KIND="${BDHERD_AGENT:-claude}"
SESSION="${BDHERD_SESSION:-}"
TIMEOUT="${BDHERD_TIMEOUT:-1800000}"   # ms to wait for one agent, default 30m
MAX_ROUNDS="${BDHERD_MAX_ROUNDS:-20}"  # safety stop for --watch
RESULTS_DIR="${BDHERD_RESULTS:-}"      # where each agent's RESULT line is kept
EPIC=""
DRY_RUN=false
WATCH=false
MERGE=true                             # --no-merge to leave every branch alone
IDS=()

die()  { printf '\033[31merror\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[32m>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1" >&2; }

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --epic)     EPIC="${2:?--epic needs an issue id}"; shift 2 ;;
    --max)      MAX="${2:?--max needs a number}"; shift 2 ;;
    --base)     BASE="${2:?--base needs a git ref}"; shift 2 ;;
    --repo)     REPO="${2:?--repo needs a path}"; shift 2 ;;
    --plan-db)  PLAN_DB="${2:?--plan-db needs a path}"; shift 2 ;;
    --agent)    KIND="${2:?--agent needs an agent kind}"; shift 2 ;;
    --timeout)  TIMEOUT="${2:?--timeout needs milliseconds}"; shift 2 ;;
    --watch)    WATCH=true; shift ;;
    --no-merge) MERGE=false; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  usage 0 ;;
    -*)         die "unknown option: $1 (try --help)" ;;
    *)          IDS[${#IDS[@]}]="$1"; shift ;;
  esac
done

# herdr needs --session before the subcommand, so keep it as an array.
HERDR=(herdr)
if [ -n "$SESSION" ]; then HERDR=(herdr --session "$SESSION"); fi

# ---------------------------------------------------------------- preflight --

for tool in herdr bd git jq; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not on your PATH"
done

[ -d "$PLAN_DB/.beads" ] || die "no beads database at $PLAN_DB (set BDHERD_PLAN_DB)"

if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$REPO" ] || die "run this inside a git repo, or pass --repo <path>"
fi
git -C "$REPO" rev-parse --verify --quiet "$BASE" >/dev/null \
  || die "base ref '$BASE' does not exist in $REPO"

# One file per finished issue, holding the RESULT line its agent reported. This
# is how a task's output reaches the tasks that depend on it: the orchestrator
# collects it and writes it into their prompts. Kept outside the repo, and
# outside the worktrees, so it survives their cleanup.
[ -n "$RESULTS_DIR" ] || RESULTS_DIR="$HOME/.cache/bdherd/$(basename "$REPO")"
mkdir -p "$RESULTS_DIR"

# Every control command goes over the socket, so the server has to be up. It
# does not autostart: `herdr` in a terminal starts it and leaves it running.
# A dry run touches nothing, so it does not need one.
if ! $DRY_RUN; then
  # Captured rather than piped to grep: `grep -q` closes the pipe on its first
  # match, and under `set -o pipefail` that SIGPIPE fails the whole pipeline.
  herdr_status="$("${HERDR[@]}" status 2>/dev/null || true)"
  case "$herdr_status" in
    *"status: running"*) ;;
    *) die "no herdr server running — start one with 'herdr' in a terminal first" ;;
  esac
fi

$WATCH && $DRY_RUN && die "--watch and --dry-run do not go together"
$WATCH && [ "${#IDS[@]}" -gt 0 ] \
  && die "--watch follows the dependency graph; pass --epic, not specific ids"

# --------------------------------------------------------------- selection --

READY_JSON=""

# Fills READY with the ids that can be dispatched right now. Epics are
# containers, never work, so they are always excluded.
READY=()
select_ready() {
  READY=()
  READY_JSON="$(bd -C "$PLAN_DB" ready --json 2>/dev/null || echo '[]')"
  local line
  # macOS ships bash 3.2, which has no mapfile — read the ids the portable way.
  while IFS= read -r line; do
    [ -n "$line" ] && READY[${#READY[@]}]="$line"
  done < <(printf '%s' "$READY_JSON" | jq -r --arg e "$EPIC" '
      .[]
      | select(.issue_type != "epic")
      | select($e == "" or (.id | startswith($e + ".")))
      | .id')
}

title_of() {
  local t
  t="$(printf '%s' "$READY_JSON" | jq -r --arg i "$1" \
        '.[] | select(.id==$i) | .title' 2>/dev/null || true)"
  [ -n "$t" ] && printf '%s' "$t" || printf '%s' "$1"
}

slug_of() {
  # Herdr agent names allow [a-z][a-z0-9_-]{0,31}; beads ids contain dots.
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
  printf '%s' "${s%-}"
}

# ---------------------------------------------------------------- dispatch --

# dispatch_one <id> — returns 0 when an agent is running on it, 1 otherwise.
dispatch_one() {
  local id="$1" slug branch path title created pane started issue prompt
  local deps dep depbranch upstream handoff
  slug="$(slug_of "$id")"
  branch="agent/$slug"
  path="$REPO/.worktree/$slug"
  title="$(title_of "$id")"

  if [ -e "$path" ] || git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    warn "$id — worktree or branch already exists, skipping"
    return 1
  fi

  if $DRY_RUN; then
    printf '  %-14s %s\n                 → %s\n                 → %s\n' \
      "$id" "$title" "$branch" "$path"
    return 0
  fi

  info "$id — $title"

  # 1. Local worktree, opened as its own Herdr workspace. --base keeps the new
  #    branch off $BASE with no upstream, so it can never be pushed by accident.
  created="$("${HERDR[@]}" worktree create \
    --cwd "$REPO" --branch "$branch" --base "$BASE" \
    --path "$path" --label "$id" 2>&1)" \
    || { warn "$id — worktree create failed: $created"; return 1; }

  pane="$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')"
  [ -n "$pane" ] || { warn "$id — no pane id in herdr's response"; return 1; }

  deps="$(bd -C "$PLAN_DB" dep list "$id" --type blocks --json 2>/dev/null \
            | jq -r '.[].id' 2>/dev/null || true)"

  # 2. Intermediate merge: this task's worktree must contain the work of the
  #    tasks it depends on, or it builds on a stale base. A dependency that
  #    produced no commits merges as a no-op.
  if $MERGE; then
    for dep in $deps; do
      depbranch="agent/$(slug_of "$dep")"
      git -C "$REPO" show-ref --verify --quiet "refs/heads/$depbranch" || continue
      if ! git -C "$path" merge --no-ff --no-edit "$depbranch" >/dev/null 2>&1; then
        git -C "$path" merge --abort >/dev/null 2>&1 || true
        warn "$id — cannot merge $depbranch into $branch (conflict)"
        warn "     resolve it in $path, then re-run; not dispatching this task"
        return 1
      fi
    done
  fi

  # 3. This monorepo derives per-checkout compose ports from the checkout
  #    directory name; without this the new worktree's apps collide with others.
  if [ -x "$REPO/tools/worktree-env.sh" ]; then
    "$REPO/tools/worktree-env.sh" "$path" >/dev/null 2>&1 \
      || warn "$id — worktree-env.sh failed; app ports in this checkout may collide"
  fi

  # 4. Stale ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN exports in the shell
  #    profile make Claude Code open a credential dialog and sit there blocked.
  #    Clearing them in the pane lets it use the real Keychain credential.
  "${HERDR[@]}" pane run "$pane" \
    'unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN' >/dev/null 2>&1 || true
  sleep 2

  # 5. Start the agent. Returns only once Herdr sees it ready for input.
  started="$("${HERDR[@]}" agent start "$slug" --kind "$KIND" --pane "$pane" 2>&1)" || true
  if printf '%s' "$started" | jq -e '.error' >/dev/null 2>&1; then
    warn "$id — agent did not start: $(printf '%s' "$started" | jq -r '.error.message')"
    warn "     the worktree is still at $path; start an agent in it by hand"
    return 1
  fi

  # 6. Collect what this task's dependencies reported, so their output reaches
  #    it. Agents never talk to each other directly — every handoff goes
  #    through here.
  upstream=""
  for dep in $deps; do
    if [ -f "$RESULTS_DIR/$dep" ]; then
      upstream="$upstream
  $dep — $(cat "$RESULTS_DIR/$dep")"
    else
      upstream="$upstream
  $dep — (finished earlier; no captured result)"
    fi
  done

  handoff=""
  if [ -n "$upstream" ]; then
    handoff="
--- results handed to you by the tasks you depend on ---$upstream
--- end of upstream results ---

Use those values directly. Do not re-derive them and do not go looking for them
elsewhere; they are the authoritative output of those tasks.
"
  fi

  # 7. Hand it the issue. No --wait: a whole wave starts before anything blocks.
  issue="$(bd -C "$PLAN_DB" show "$id" 2>/dev/null || printf '%s: %s' "$id" "$title")"
  prompt="You are implementing one task in an isolated git worktree.

Worktree: $path
Branch:   $branch (branched from $BASE, local only)

--- the task, from the beads tracker ---
$issue
--- end of task ---
$handoff
Rules for this run:
- Implement only this task. Follow AGENTS.md and CLAUDE.md in this worktree.
- Commit your work to '$branch' with a clear message. If the task produces no
  repository changes, that is fine — do not invent a commit.
- Do NOT push, do NOT open a pull request, do NOT touch any other branch.
  This branch is reviewed locally.
- Do not close or reopen the beads issue; that is handled outside this session.
- If you get blocked or the task turns out to be underspecified, stop and say so
  rather than guessing at scope.
- Finish by summarizing what you did, and make the VERY LAST line of your final
  message exactly:
    RESULT: <the value or one-line outcome this task produces>
  That line is the only thing passed on to the tasks that depend on this one, so
  it must stand alone and carry the actual value."

  "${HERDR[@]}" agent prompt "$slug" "$prompt" >/dev/null 2>&1 \
    || warn "$id — prompt may not have been delivered; check the pane"

  # 8. Reflect it in beads so a second run does not dispatch it again.
  bd -C "$PLAN_DB" update "$id" --claim >/dev/null 2>&1 \
    || warn "$id — could not mark it claimed in beads"

  printf '                 agent \033[1m%s\033[0m in %s\n' "$slug" "$path"
  return 0
}

# settle_one <id> — wait for the agent, then close the issue so the next wave
# unblocks. Only used by --watch.
settle_one() {
  local id="$1" slug state raw value
  slug="$(slug_of "$id")"

  "${HERDR[@]}" agent wait "$slug" --timeout "$TIMEOUT" >/dev/null 2>&1 || true
  state="$("${HERDR[@]}" agent get "$slug" 2>/dev/null \
            | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null || echo unknown)"

  case "$state" in
    blocked)
      warn "$id — agent is blocked, waiting on input. Leaving the issue open."
      warn "     look at it:  herdr agent read $slug --source detection"
      return 1
      ;;
    idle|done)
      # Take the agent's reported RESULT out of its pane and keep it, so the
      # tasks that depend on this one get handed the value. The prompt we sent
      # also contains the word RESULT, so skip the placeholder line ('<...>')
      # and take the last real one — the agent's own.
      raw="$("${HERDR[@]}" agent read "$slug" --source recent-unwrapped --lines 300 2>/dev/null || true)"
      value="$(printf '%s' "$raw" \
                 | grep -oE 'RESULT:[[:print:]]*' \
                 | grep -v '<' \
                 | tail -1 \
                 | sed -e 's/^RESULT:[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
      [ -n "$value" ] || value="(agent reported no RESULT line — see its pane)"
      printf '%s\n' "$value" > "$RESULTS_DIR/$id"

      bd -C "$PLAN_DB" close "$id" --reason="agent finished (bdherd --watch)" \
        >/dev/null 2>&1 || { warn "$id — could not close the issue"; return 1; }
      printf '  \033[32m✓\033[0m %-14s \033[1m%s\033[0m\n' "$id" "$value"
      return 0
      ;;
    *)
      warn "$id — agent ended in state '$state'; leaving the issue open"
      return 1
      ;;
  esac
}

# -------------------------------------------------------------------- main --

if ! $WATCH; then
  # One shot: dispatch what is ready now and hand back to the user.
  if [ "${#IDS[@]}" -eq 0 ]; then
    select_ready
    IDS=(${READY[@]+"${READY[@]}"})
    if [ "${#IDS[@]}" -eq 0 ]; then
      [ -n "$EPIC" ] && die "no ready tasks under epic '$EPIC'" || die "nothing is ready in $PLAN_DB"
    fi
  else
    READY_JSON="$(bd -C "$PLAN_DB" ready --json 2>/dev/null || echo '[]')"
  fi

  if [ "${#IDS[@]}" -gt "$MAX" ]; then
    warn "${#IDS[@]} tasks ready, dispatching the first $MAX (raise with --max)"
    IDS=("${IDS[@]:0:$MAX}")
  fi

  dispatched=0; skipped=0
  for id in "${IDS[@]}"; do
    if dispatch_one "$id"; then dispatched=$((dispatched + 1)); else skipped=$((skipped + 1)); fi
  done

  echo
  if $DRY_RUN; then
    info "$dispatched would be dispatched, $skipped skipped (dry run, nothing changed)"
  else
    info "$dispatched dispatched, $skipped skipped"
    if [ "$dispatched" -gt 0 ]; then cat <<'EOF'

  Watch them:      herdr            (each task is its own workspace)
  Check on one:    herdr agent list
                   herdr agent read <name> --source recent-unwrapped --lines 60
  When one lands:  bd -C ~/beads-planning close <id>   then run bdherd again
  Or let it run:   bdherd --epic <id> --watch
EOF
    fi
  fi
  exit 0
fi

# merge_all — fold every branch this run produced into $BASE, in the order the
# waves finished, which is already a valid dependency order. Runs in the primary
# checkout and stops at the first conflict rather than leaving a half-merge.
merge_all() {
  local cur b id merged=0 empty=0
  [ "${#DONE[@]}" -gt 0 ] || return 0

  cur="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ "$cur" != "$BASE" ]; then
    warn "primary checkout is on '$cur', not '$BASE' — not merging"
    warn "     switch to $BASE, then: git merge --no-ff agent/<slug>"
    return 1
  fi

  echo
  info "merging into $BASE"
  for id in "${DONE[@]}"; do
    b="agent/$(slug_of "$id")"
    git -C "$REPO" show-ref --verify --quiet "refs/heads/$b" || continue
    if [ "$(git -C "$REPO" rev-list --count "$BASE..$b" 2>/dev/null || echo 0)" -eq 0 ]; then
      empty=$((empty + 1))
      continue
    fi
    if git -C "$REPO" merge --no-ff --no-edit "$b" >/dev/null 2>&1; then
      printf '  \033[32m✓\033[0m merged %s\n' "$b"
      merged=$((merged + 1))
    else
      git -C "$REPO" merge --abort >/dev/null 2>&1 || true
      echo
      warn "conflict merging $b into $BASE — stopped, nothing further merged"
      warn "     resolve by hand:  git merge --no-ff $b"
      return 1
    fi
  done

  if [ "$merged" -eq 0 ]; then
    info "nothing to merge — all $empty branch(es) are empty (no commits past $BASE)"
  else
    info "$merged branch(es) merged into $BASE$([ "$empty" -gt 0 ] && printf ', %s empty' "$empty")"
  fi
  return 0
}

# --watch: dispatch a wave, wait for it, close it, repeat until the graph is done.
round=0
total=0
DONE=()
complete=false
while [ "$round" -lt "$MAX_ROUNDS" ]; do
  round=$((round + 1))
  select_ready

  if [ "${#READY[@]}" -eq 0 ]; then
    if [ "$round" -eq 1 ]; then
      [ -n "$EPIC" ] && die "no ready tasks under epic '$EPIC'" || die "nothing is ready in $PLAN_DB"
    fi
    echo
    info "graph complete — $total task(s) run over $((round - 1)) wave(s)"
    complete=true
    break
  fi

  WAVE=(${READY[@]+"${READY[@]}"})
  if [ "${#WAVE[@]}" -gt "$MAX" ]; then
    warn "${#WAVE[@]} ready, running the first $MAX this wave (raise with --max)"
    WAVE=("${WAVE[@]:0:$MAX}")
  fi

  echo
  info "wave $round — dispatching ${#WAVE[@]} task(s)"

  LIVE=()
  for id in "${WAVE[@]}"; do
    if dispatch_one "$id"; then LIVE[${#LIVE[@]}]="$id"; fi
  done

  if [ "${#LIVE[@]}" -eq 0 ]; then
    warn "nothing in wave $round could be dispatched; stopping"
    break
  fi

  info "waiting for ${#LIVE[@]} agent(s)..."
  stuck=0
  for id in "${LIVE[@]}"; do
    if settle_one "$id"; then
      total=$((total + 1))
      DONE[${#DONE[@]}]="$id"
    else
      stuck=$((stuck + 1))
    fi
  done

  if [ "$stuck" -gt 0 ]; then
    echo
    warn "$stuck task(s) did not finish cleanly — stopping so you can look"
    warn "resume with the same command once they are sorted out"
    break
  fi
done

[ "$round" -ge "$MAX_ROUNDS" ] && warn "hit the $MAX_ROUNDS-wave safety stop"

# Only fold the branches in once the whole graph has actually finished. A run
# that stopped on a blocked agent leaves them alone for you to look at.
if $MERGE; then
  if $complete; then
    merge_all || true
  else
    echo
    warn "run did not complete — skipping the merge into $BASE"
  fi
fi

cat <<EOF

  Worktrees are still on disk for review:
    git -C $REPO worktree list
  Clean one up:
    git -C $REPO worktree remove --force .worktree/<slug> && git -C $REPO branch -D agent/<slug>
EOF
