#!/usr/bin/env bash
# install.sh — build hq and wire it into the local environment.
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
bindir="${HQ_BINDIR:-$HOME/.local/bin}"
skilldir="${HQ_SKILLDIR:-$HOME/.claude/skills}"

command -v elixir >/dev/null 2>&1 || {
  echo "installing elixir..."
  brew install elixir
}

echo "building hq..."
cd "$repo"
mix deps.get >/dev/null 2>&1 || true
MIX_ENV=prod mix escript.build

mkdir -p "$bindir" "$skilldir"
ln -sf "$repo/hq" "$bindir/hq"
ln -sfn "$repo/skills/hq" "$skilldir/hq"

echo
echo "installed:"
echo "  $bindir/hq      -> $repo/hq"
echo "  $skilldir/hq    -> $repo/skills/hq"
echo
echo "Add hq to your Claude permission allowlist so peer messaging never"
echo "stalls on an approval dialog. In ~/.claude/settings.json:"
echo
cat <<'JSON'
  { "permissions": { "allow": ["Bash(hq:*)"] } }
JSON
echo
echo "Optional: Herdr's agent sidebar can show each session's context use and"
echo "activity (⏳ script wait, 📝 coding time). See README, \"Sidebar\". Needs jq."
echo "In ~/.claude/settings.json (merge \"hooks\" with any hooks you have):"
echo
a="$repo/sidebar/activity.sh"
hook="[{ \"type\": \"command\", \"command\": \"$a\", \"timeout\": 5 }]"
cat <<JSON
  {
    "statusLine": { "type": "command", "command": "$repo/sidebar/statusline.sh" },
    "hooks": {
      "UserPromptSubmit":   [{ "hooks": $hook }],
      "PreToolUse":         [{ "matcher": "Bash", "hooks": $hook }],
      "PostToolUse":        [{ "matcher": "Bash", "hooks": $hook }],
      "PostToolUseFailure": [{ "matcher": "Bash", "hooks": $hook }],
      "PostToolBatch":      [{ "hooks": [{ "type": "command", "command": "$a", "timeout": 5, "async": true }] }],
      "Stop":               [{ "hooks": $hook }],
      "StopFailure":        [{ "hooks": $hook }],
      "SessionEnd":         [{ "hooks": $hook }]
    }
  }
JSON
echo
echo "In ~/.config/herdr/config.toml, then run 'herdr server reload-config':"
echo
cat <<'TOML'
  [ui.sidebar.agents]
  rows = [["state_icon", "machine", "workspace", "tab"], [{ token = "$ctx", dim = true }, { token = "$activity" }, "agent"]]
TOML
echo
echo "hq needs a running Herdr server. Start one with 'herdr' in a terminal."
echo
echo "If a daemon from a previous build is still running, it will keep serving"
echo "that OLD build -- it does not reload itself. Run 'hq restart' to have it"
echo "pick up what was just installed (safe: never pkill/killall, signal-verified)."
