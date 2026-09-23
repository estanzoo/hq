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
echo "hq needs a running Herdr server. Start one with 'herdr' in a terminal."
