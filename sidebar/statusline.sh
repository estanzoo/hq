#!/bin/bash
# statusline.sh: Claude Code status line. Shows context-window usage as a bar,
# and, when the session runs in a Herdr pane, reports the same bar to Herdr as
# the `ctx` sidebar token (README, "Sidebar"). Needs jq.
#
# stdin: the status line JSON from Claude Code. stdout: one status line.

input=$(cat)

read -r pct model < <(jq -r '
  (.context_window.used_percentage
   // (if .context_window.current_usage and .context_window.context_window_size then
         ((.context_window.current_usage.input_tokens // 0)
          + (.context_window.current_usage.cache_creation_input_tokens // 0)
          + (.context_window.current_usage.cache_read_input_tokens // 0))
         * 100 / .context_window.context_window_size
       else null end)) as $p
  | "\(if $p == null then "-" else ($p | round) end) \(.model.display_name // "")"
' <<<"$input" 2>/dev/null)

if [[ "$pct" =~ ^[0-9]+$ ]]; then
  filled=$(( (pct + 10) / 20 ))
  (( filled > 5 )) && filled=5
  bar=""
  for i in 1 2 3 4 5; do
    if (( i <= filled )); then bar+="▰"; else bar+="▱"; fi
  done
  ctx="$bar $pct%"
else
  ctx="▱▱▱▱▱ –"
fi

if [[ -n "$HERDR_PANE_ID" ]]; then
  ( herdr pane report-metadata "$HERDR_PANE_ID" --source claude-ctx \
      --token "ctx=$ctx" >/dev/null 2>&1 & )
fi

printf '%s · ctx %s\n' "${model:-Claude}" "$ctx"
