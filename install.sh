#!/usr/bin/env bash
# install.sh — build hq and wire it into the local environment.
#   ./install.sh               also sets up the sidebar (README, "Sidebar")
#   ./install.sh --no-sidebar  leaves Claude Code's and Herdr's config alone
set -euo pipefail

sidebar=1
for arg in "$@"; do
  case "$arg" in
    --no-sidebar) sidebar=0 ;;
    *) echo "usage: ./install.sh [--no-sidebar]" >&2; exit 2 ;;
  esac
done

repo="$(cd "$(dirname "$0")" && pwd)"
bindir="${HQ_BINDIR:-$HOME/.local/bin}"
skilldir="${HQ_SKILLDIR:-$HOME/.claude/skills}"

command -v elixir >/dev/null 2>&1 || {
  echo "installing elixir..."
  brew install elixir
}

# Herdr's own installer is the fallback where Homebrew is not available.
command -v herdr >/dev/null 2>&1 || {
  echo "installing herdr..."
  if command -v brew >/dev/null 2>&1; then
    brew install herdr
  else
    curl -fsSL https://herdr.dev/install.sh | sh
  fi
  command -v herdr >/dev/null 2>&1 || {
    echo "herdr is installed but not on your PATH; open a new terminal or add its folder to PATH." >&2
  }
}

# The sidebar's scripts read JSON with jq. Without Homebrew, setup.sh says
# how to finish once jq is installed.
if [ "$sidebar" = 1 ] && ! command -v jq >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  echo "installing jq..."
  brew install jq
fi

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
if [ "$sidebar" = 1 ]; then
  # Context use and activity of each agent in Herdr's sidebar (README,
  # "Sidebar"). Changes only what it needs, and backs up each file it changes.
  "$repo/sidebar/setup.sh" || echo "sidebar: set-up failed; hq itself is installed. Run $repo/sidebar/setup.sh again to retry." >&2
else
  echo "sidebar: skipped (--no-sidebar). Run $repo/sidebar/setup.sh to set it up later."
fi
echo
echo "hq needs a running Herdr server. Start one with 'herdr' in a terminal."
echo
echo "If a daemon from a previous build is still running, it will keep serving"
echo "that OLD build -- it does not reload itself. Run 'hq restart' to have it"
echo "pick up what was just installed (safe: never pkill/killall, signal-verified)."
