#!/bin/bash
# setup.sh: sets up the sidebar (README, "Sidebar") in this user's config.
# install.sh runs it; `./install.sh --no-sidebar` skips it. Safe to run again.
#
# - Claude Code settings, ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json:
#   statusLine runs sidebar/statusline.sh, and the hooks run sidebar/activity.sh.
#   All other settings and hooks are kept. An activity.sh hook from another
#   checkout of hq is replaced. A statusLine of your own is kept, with a note:
#   the context bar then does not show.
# - Herdr's config file ($HERDR_CONFIG_PATH, or the one `herdr --help` names):
#   gets the agent rows with $ctx and $activity if it has no
#   [ui.sidebar.agents] yet. Rows of your own are kept, with a note. If
#   `herdr config check` rejects the result, the file is put back.
#
# Each file is backed up as <file>.bak-hq-<time> before it changes. Needs jq.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
statusline="$repo/sidebar/statusline.sh"
activity="$repo/sidebar/activity.sh"
stamp=$(date +%Y%m%d-%H%M%S)

say() { echo "sidebar: $*"; }
# Put the content of file $1 into file $2, and remove $1. A config file that
# is a symlink (for example from a dotfiles repo) stays a link: the content
# goes through it to the real file. A plain file is replaced in one step.
replace() { if [ -L "$2" ]; then cat "$1" > "$2" && rm -f "$1"; else mv -f "$1" "$2"; fi; }
note() { echo "sidebar: $*" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  note "jq is not installed, so the sidebar was not set up. Install jq and run $repo/sidebar/setup.sh."
  exit 0
fi

# ---- Claude Code settings -------------------------------------------------

claude_settings() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" file new tmp created=0
  file="$dir/settings.json"
  mkdir -p "$dir"
  if [ ! -s "$file" ]; then echo '{}' > "$file"; created=1; fi
  if ! jq empty "$file" 2>/dev/null; then
    note "$file is not valid JSON, so the statusline and hooks were not added."
    return
  fi

  # Each event gets one entry that runs activity.sh. Entries for activity.sh
  # (this checkout or another one) are removed first, so a second run, or a
  # run from a moved checkout, leaves exactly one.
  new=$(jq --arg sl "$statusline" --arg a "$activity" '
    def ours: (.command // "") | endswith("/sidebar/activity.sh");
    def entry($m; $async):
      {hooks: [{type: "command", command: $a, timeout: 5} + (if $async then {async: true} else {} end)]}
      + (if $m then {matcher: $m} else {} end);
    .hooks = (.hooks // {})
    | reduce (
        ["UserPromptSubmit", null, false],
        ["PreToolUse", "Bash", false],
        ["PostToolUse", "Bash", false],
        ["PostToolUseFailure", "Bash", false],
        ["PostToolBatch", null, true],
        ["Stop", null, false],
        ["StopFailure", null, false],
        ["SessionEnd", null, false]
      ) as [$e, $m, $async] (.;
        .hooks[$e] = (
          [(.hooks[$e] // [])[]
            | .hooks = [(.hooks // [])[] | select(ours | not)]
            | select((.hooks | length) > 0)]
          + [entry($m; $async)]))
    | if .statusLine == null or ((.statusLine.command // "") | endswith("/sidebar/statusline.sh"))
      then .statusLine = {type: "command", command: $sl}
      else . end
  ' "$file")

  if [ "$(jq -S . "$file")" = "$(jq -S . <<< "$new")" ]; then
    say "Claude Code settings already set up ($file)"
  else
    tmp="$file.tmp-hq-$$"
    printf '%s\n' "$new" > "$tmp"
    if [ "$created" -eq 1 ]; then
      replace "$tmp" "$file"
      say "created $file with the statusline and hooks"
    else
      cp -p "$file" "$file.bak-hq-$stamp"
      replace "$tmp" "$file"
      say "added the statusline and hooks to $file (backup: $file.bak-hq-$stamp)"
    fi
  fi

  if [ "$(jq -r '.statusLine.command // ""' "$file")" != "$statusline" ]; then
    note "$file keeps your own statusLine, so the context bar does not show."
    note "  To use hq's: set statusLine.command to $statusline"
  fi
}

# ---- Herdr config -----------------------------------------------------------

herdr_rows() {
  local file row backup
  file="${HERDR_CONFIG_PATH:-}"
  if [ -z "$file" ] && command -v herdr >/dev/null 2>&1; then
    file=$(herdr --help 2>/dev/null | sed -n 's/^Config: *//p' | head -1)
  fi
  file="${file:-$HOME/.config/herdr/config.toml}"
  row='rows = [["state_icon", "machine", "workspace", "tab"], [{ token = "$ctx", dim = true }, { token = "$activity" }, "agent"]]'

  if grep -q '^[[:space:]]*\[ui\.sidebar\.agents\][[:space:]]*$' "$file" 2>/dev/null; then
    if grep -qF '"$ctx"' "$file" && grep -qF '"$activity"' "$file"; then
      say "Herdr sidebar rows already set up ($file)"
    else
      note "$file keeps your own [ui.sidebar.agents] rows. To show context use and"
      note "  activity, add { token = \"\$ctx\", dim = true } and { token = \"\$activity\" } to a row, for example:"
      note "  $row"
    fi
    return
  fi

  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ]; then cp -p "$file" "$file.bak-hq-$stamp"; fi
  printf '\n# Added by hq (README, "Sidebar"): context use and activity of each agent.\n[ui.sidebar.agents]\n%s\n' "$row" >> "$file"

  if command -v herdr >/dev/null 2>&1 && ! HERDR_CONFIG_PATH="$file" herdr config check >/dev/null 2>&1; then
    if [ -f "$file.bak-hq-$stamp" ]; then replace "$file.bak-hq-$stamp" "$file"; else rm -f "$file"; fi
    note "Herdr rejected $file with the sidebar rows, so it was put back. Add this yourself:"
    note "  [ui.sidebar.agents]"
    note "  $row"
    return
  fi

  backup=""
  if [ -f "$file.bak-hq-$stamp" ]; then backup=" (backup: $file.bak-hq-$stamp)"; fi
  say "added the sidebar rows to $file$backup"
  # A running Herdr server shows them at once; otherwise they apply when it starts.
  if command -v herdr >/dev/null 2>&1; then herdr server reload-config >/dev/null 2>&1 || true; fi
}

claude_settings
herdr_rows
