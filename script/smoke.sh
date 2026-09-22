#!/usr/bin/env bash
# script/smoke.sh — verify hq against a real Herdr server.
#
# FakeHerdr (the test double all 104 unit tests run against) encodes
# assumptions about the real Herdr server that can change under it. This
# script is the one check that talks to the real thing: it spawns two
# throwaway agents, has one message the other, confirms the message actually
# lands in the target's terminal prefixed `[hq]`, then cleans up every trace
# of itself — the agents, the panes, and the scratch directory.
#
# Only ever acts on agents this run creates itself (name-prefixed `smoke-`).
# It must never touch any other agent already registered with Herdr.
set -euo pipefail

command -v herdr >/dev/null || { echo "herdr not on PATH"; exit 1; }
command -v hq    >/dev/null || { echo "hq not on PATH; run ./install.sh"; exit 1; }
command -v jq    >/dev/null || { echo "jq not on PATH; required to parse spawn responses"; exit 1; }

# Captured rather than piped straight to `grep -q`: grep closes the pipe on
# its first match, and under `set -o pipefail` that SIGPIPEs `herdr status`
# and fails the whole pipeline even though grep matched (see
# reference/bdherd.bash's own comment on this — same trap, same fix).
herdr_status="$(herdr status 2>/dev/null || true)"
case "$herdr_status" in
  *"status: running"*) ;;
  *) echo "no herdr server running"; exit 1 ;;
esac

NAME_A="smoke-a"
NAME_B="smoke-b"

# A FIXED path, not a fresh mktemp one, and never removed on cleanup below.
# Claude Code shows an interactive "do you trust this folder?" dialog the
# first time it ever sees a directory, and that dialog has no scriptable
# "yes" path (see script/smoke.sh's own commit message / task-15-report.md
# for how thoroughly this was checked: neither --dangerously-skip-permissions
# nor blind key-sends reliably clear it). Claude Code remembers the answer
# per directory in ~/.claude.json (`projects.<path>.hasTrustDialogAccepted`)
# forever after, so reusing the SAME path every run means the dialog is a
# ONE-TIME manual step rather than a permanent blocker:
#   herdr agent attach smoke-a   (while this script is paused at the spawn
#                                 step, or run `hq spawn` by hand once)
# and answer the "quick safety check" prompt yourself, once, ever. After
# that this script is fully unattended.
SCRATCH="${TMPDIR:-/tmp}/hq-smoke-scratch"
mkdir -p "$SCRATCH"
PANE_A=""
PANE_B=""

# Idempotent: if a previous run of this script died before its own cleanup,
# a stale smoke-a/smoke-b roster entry would make `hq spawn` fail with
# name_taken. Clearing them first (release does not kill anything, only
# un-supervises the name) makes re-running this script safe.
hq release "$NAME_A" >/dev/null 2>&1 || true
hq release "$NAME_B" >/dev/null 2>&1 || true

cleanup() {
  echo "==> cleanup"
  hq release "$NAME_A" 2>/dev/null || true
  hq release "$NAME_B" 2>/dev/null || true

  if [[ -n "$PANE_A" ]]; then
    herdr pane close "$PANE_A" 2>/dev/null || echo "warning: could not close pane $PANE_A ($NAME_A)"
  fi
  if [[ -n "$PANE_B" ]]; then
    herdr pane close "$PANE_B" 2>/dev/null || echo "warning: could not close pane $PANE_B ($NAME_B)"
  fi

  # $SCRATCH itself is deliberately NOT removed — see the comment above it:
  # its whole value is staying the same path run after run, so Claude
  # Code's one-time trust answer for it keeps applying. Only its contents
  # (whatever the agents happened to create) are cleared.
  find "$SCRATCH" -mindepth 1 -delete 2>/dev/null || true
}
trap cleanup EXIT

echo "==> spawning two agents in scratch dir $SCRATCH (not a git repo, no --worktree)"

# Deliberately NOT --permissive: that maps to Claude Code's
# --dangerously-skip-permissions, which opens a SECOND interactive dialog
# ("WARNING: Claude Code running in Bypass Permissions mode") on top of the
# one-time workspace-trust dialog above -- and unlike workspace trust,
# accepting it is not remembered per directory, so it would reappear on
# every single run. The tasks below never touch a tool that needs approval
# (they only ever have to reply in chat), so plain permission mode never
# prompts for anything and no such dialog appears at all.
spawn_a_json="$(hq spawn "$NAME_A" --cwd "$SCRATCH" --task "Reply with the word ALPHA and nothing else.")"
echo "$spawn_a_json"
PANE_A="$(echo "$spawn_a_json" | jq -r '.pane_id')"

spawn_b_json="$(hq spawn "$NAME_B" --cwd "$SCRATCH" --task "Wait for a message from smoke-a.")"
echo "$spawn_b_json"
PANE_B="$(echo "$spawn_b_json" | jq -r '.pane_id')"

echo "==> roster"
hq ls

echo "==> smoke-a messages smoke-b"
hq send "$NAME_B" "This is a test from the smoke script. Reply to smoke-a via: hq send smoke-a \"got it\""

echo "==> waiting 60s for delivery"
sleep 60

echo "==> roster after"
hq ls

echo "==> smoke-b's pane (the message should be visible, prefixed [hq])"
pane_b_output="$(herdr agent read "$NAME_B" --source recent-unwrapped --lines 40)"
echo "$pane_b_output"

echo
if grep -q '\[hq\] message from' <<<"$pane_b_output"; then
  echo "PASS: [hq]-prefixed message is visible in smoke-b's pane above."
else
  echo "FAIL: no [hq]-prefixed message found in smoke-b's pane above."
  echo "      Check 'hq ls' output for mailbox depth and status: a session"
  echo "      stuck outside idle/done (e.g. the one-time trust dialog above,"
  echo "      or a stale hq status cache — see task-15-report.md) will queue"
  echo "      mail forever without ever delivering or erroring."
fi
echo "==> tearing down smoke-a/smoke-b and their panes (see cleanup below)"
