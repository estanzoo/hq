#!/bin/bash
# activity.sh: shows what a Claude Code session in a Herdr pane is doing, as the
# `activity` token in Herdr's agent sidebar:
#
#   ⏳ 4m    script wait: a Bash command has run for 4 minutes, in the
#            foreground of a turn or as a background shell the session waits for
#   📝 9m    coding time: the session has worked on its current turn for 9 minutes
#   (none)   the session is idle
#
# Claude Code hooks run this script with the hook's JSON on stdin (README,
# "Sidebar"). A hook only writes, renames or deletes small files and returns at
# once: it never calls Herdr, so a slow Herdr never slows a tool call. One loop
# for each pane (`activity.sh --loop <pane>`, started by a hook) reads those
# files, sets the token when its text changes, and ends when nothing is left.
#
# The files, in $DIR/<pane>/, each hold a start time in epoch seconds:
#   turn-<session>              a turn runs
#   script-<session>-<call>     a foreground Bash call runs
#   bg-<session>-<task>         a background shell runs
# They are kept per session, so a `claude` started inside the pane (for
# example by a Bash call) cannot end the records of the session around it.
#
# Outside a Herdr pane ($HERDR_PANE_ID unset) it does nothing. Needs jq.
#
# The environment can change these values (the tests do):
#   HQ_ACTIVITY_DIR           state folder (default ~/.hq/activity)
#   HQ_ACTIVITY_TICK          seconds between two looks at the files (default 5)
#   HQ_ACTIVITY_SCRIPT_AFTER  seconds a foreground Bash call runs before ⏳ shows (default 15)
#   HQ_ACTIVITY_STALE_AFTER   age in seconds at which a turn is checked against Herdr (default 60)
#   HQ_ACTIVITY_CHECK_EVERY   seconds between two checks against Herdr (default 30)
set -u
DIR=${HQ_ACTIVITY_DIR:-$HOME/.hq/activity}
TICK=${HQ_ACTIVITY_TICK:-5}
SCRIPT_AFTER=${HQ_ACTIVITY_SCRIPT_AFTER:-15}
STALE_AFTER=${HQ_ACTIVITY_STALE_AFTER:-60}
CHECK_EVERY=${HQ_ACTIVITY_CHECK_EVERY:-30}
SOURCE=hq-activity
SELF=${BASH_SOURCE[0]}
US=$'\x1f' # field separator for the hook's parsed JSON; unlike a tab, it keeps empty fields

safe() { local s=${1//[^A-Za-z0-9_.]/_}; printf '%s' "${s:-none}"; }
# Write a whole file at once, so a reader never sees it half written. The
# temporary name starts with a dot, so the globs below skip it.
put() { local tmp="${1%/*}/.tmp.$$"; printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
# "<1m", "4m", "1h05m"
dur() {
  if [ "$1" -lt 60 ]; then echo "<1m"
  elif [ "$1" -lt 3600 ]; then echo "$(($1 / 60))m"
  else printf '%dh%02dm\n' $(($1 / 3600)) $(($1 % 3600 / 60)); fi
}
any() { compgen -G "$1" >/dev/null; }
has_state() { any "$D/turn-*" || any "$D/script-*" || any "$D/bg-*"; }
# The oldest start time among the files that match a glob; empty if none.
oldest() {
  local f t o=""
  for f in $1; do
    [ -f "$f" ] || continue
    { t=$(<"$f"); } 2>/dev/null
    case $t in ""|*[!0-9]*) continue;; esac
    if [ -z "$o" ] || [ "$t" -lt "$o" ]; then o=$t; fi
  done
  echo "$o"
}

# ---- the loop: the only part that talks to Herdr ---------------------------

report() { herdr pane report-metadata "$PANE" --source "$SOURCE" --token "activity=$1" >/dev/null 2>&1; }
unreport() { herdr pane report-metadata "$PANE" --source "$SOURCE" --clear-token activity >/dev/null 2>&1; }

# The text the token shows now. Empty: nothing to show.
current() {
  local now t
  now=$(date +%s)
  t=$(oldest "$D/script-*")
  if [ -n "$t" ] && [ $((now - t)) -ge "$SCRIPT_AFTER" ]; then echo "⏳ $(dur $((now - t)))"; return; fi
  t=$(oldest "$D/turn-*")
  if [ -n "$t" ]; then echo "📝 $(dur $((now - t)))"; return; fi
  t=$(oldest "$D/bg-*")
  if [ -n "$t" ]; then echo "⏳ $(dur $((now - t)))"; fi
}

# Records whose hook never came are checked against Herdr. A missed Stop (a
# crash, an interrupt) leaves a turn behind, so an old turn ends when Herdr
# reports the pane idle. A background shell is kept while the pane is idle,
# because the session waits for it on purpose; all records end when the pane
# has no agent any more. Herdr can report idle for a moment between two
# phases of one turn, so each rule needs two answers in a row.
idle_seen=0; gone_seen=0; last_check=0
check_stale() {
  local now t old_turn=0 answer st agent
  now=$(date +%s)
  t=$(oldest "$D/turn-*")
  [ -n "$t" ] && [ $((now - t)) -ge "$STALE_AFTER" ] && old_turn=1
  [ "$old_turn" -eq 1 ] || any "$D/bg-*" || return
  [ "$idle_seen" -eq 1 ] || [ "$gone_seen" -eq 1 ] || [ $((now - last_check)) -ge "$CHECK_EVERY" ] || return
  last_check=$now
  answer=$(herdr pane get "$PANE" 2>/dev/null |
    jq -r '"\(.result.pane.agent_status // .error.code // "")\u001f\(.result.pane.agent // "")"' 2>/dev/null)
  IFS=$US read -r st agent <<< "$answer"
  [ -n "${st:-}" ] || return # Herdr gave no answer: decide nothing
  if [ "$st" = pane_not_found ] || [ -z "${agent:-}" ]; then
    if [ "$gone_seen" -eq 1 ]; then rm -f "$D"/turn-* "$D"/script-* "$D"/bg-*; gone_seen=0; else gone_seen=1; fi
    return
  fi
  gone_seen=0
  case $st in
    idle|done)
      [ "$old_turn" -eq 1 ] || return
      if [ "$idle_seen" -eq 1 ]; then rm -f "$D"/turn-* "$D"/script-*; idle_seen=0; else idle_seen=1; fi ;;
    *) idle_seen=0 ;;
  esac
}

loop() {
  PANE=$1; D=$DIR/$(safe "$PANE")
  local last="" text
  while :; do
    if ! has_state; then
      [ -n "$last" ] && unreport
      # Give the pane back. Then look once more: a hook that wrote a file while
      # this loop was ending saw the lock and started no loop of its own.
      rm -rf "$D/loop"
      if has_state && mkdir "$D/loop" 2>/dev/null; then
        echo $$ > "$D/loop/pid"; last=""; continue
      fi
      exit 0
    fi
    text=$(current)
    if [ "$text" != "$last" ]; then
      if [ -z "$text" ]; then unreport && last=""
      else report "$text" && last=$text; fi
    fi
    check_stale
    sleep "$TICK"
  done
}

# ---- the hook: files only, returns at once ---------------------------------

# Start the pane's loop unless one runs. A lock with no pid yet belongs to a
# hook that is starting a loop now, unless the lock is old (that hook died).
ensure_loop() {
  local pid age
  if ! mkdir "$D/loop" 2>/dev/null; then
    { pid=$(<"$D/loop/pid"); } 2>/dev/null
    if [ -n "$pid" ]; then kill -0 "$pid" 2>/dev/null && return; else
      age=$(( $(date +%s) - $(mtime "$D/loop" || date +%s) ))
      [ "$age" -lt 30 ] && return
    fi
    rm -rf "$D/loop"; mkdir "$D/loop" 2>/dev/null || return
  fi
  nohup "$SELF" --loop "$PANE" </dev/null >/dev/null 2>&1 &
  echo $! > "$D/loop/pid"
}

hook() {
  local input fields event tool call sid task batch shells now f t
  input=$(cat)
  [ -n "${HERDR_PANE_ID:-}" ] || exit 0
  PANE=$HERDR_PANE_ID; D=$DIR/$(safe "$PANE")
  fields=$(printf '%s' "$input" | jq -r '[
      .hook_event_name // "", .tool_name // "", .tool_use_id // "", .session_id // "",
      ((.tool_response | objects | .backgroundTaskId) // ""),
      ([.tool_calls[]?.tool_use_id // empty] | join(" ")),
      ([.background_tasks[]? | select(.type == "shell" and (.status == "running" or .status == "pending")) | .id] | join(" "))
    ] | join("\u001f")' 2>/dev/null) || exit 0
  IFS=$US read -r event tool call sid task batch shells <<< "$fields"
  sid=$(safe "$sid")
  mkdir -p "$D" || exit 0
  now=$(date +%s)
  case ${event:-} in
    UserPromptSubmit)
      # A turn that already runs keeps its start time.
      [ -f "$D/turn-$sid" ] || put "$D/turn-$sid" "$now"
      ensure_loop ;;
    PreToolUse)
      [ "$tool" = Bash ] && [ -n "$call" ] || exit 0
      put "$D/script-$sid-$(safe "$call")" "$now"
      ensure_loop ;;
    PostToolUse)
      f="$D/script-$sid-$(safe "$call")"
      if [ "$tool" = Bash ] && [ -n "$task" ]; then
        # The call started a background shell: keep its start time under the
        # shell's task id, which is the id Stop lists.
        { t=$(<"$f"); } 2>/dev/null || t=$now
        put "$D/bg-$sid-$(safe "$task")" "${t:-$now}"
        ensure_loop
      fi
      rm -f "$f" ;;
    PostToolUseFailure)
      rm -f "$D/script-$sid-$(safe "$call")" ;;
    PostToolBatch)
      # A call that never ran (refused before it started) gets no PostToolUse;
      # its batch still ends.
      for call in $batch; do rm -f "$D/script-$sid-$(safe "$call")"; done ;;
    Stop|StopFailure)
      rm -f "$D/turn-$sid" "$D"/script-"$sid"-*
      # Keep the background shells that Stop still lists as running.
      for f in "$D"/bg-"$sid"-*; do
        [ -f "$f" ] || continue
        task=${f##*/bg-"$sid"-}
        case " $shells " in *" $task "*) ;; *) rm -f "$f";; esac
      done ;;
    SessionEnd)
      rm -f "$D/turn-$sid" "$D"/script-"$sid"-* "$D"/bg-"$sid"-* ;;
  esac
  exit 0
}

if [ "${1:-}" = "--loop" ] && [ -n "${2:-}" ]; then loop "$2"; else hook; fi
