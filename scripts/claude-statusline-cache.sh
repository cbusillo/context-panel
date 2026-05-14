#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
_group_base="$HOME/Library/Group Containers"
_cp_subdir="Context Panel/ClaudeRateLimits"
if [ -d "$_group_base/MM5YXC7T6E.group.com.shinycomputers.contextpanel" ]; then
	_default_dir="$_group_base/MM5YXC7T6E.group.com.shinycomputers.contextpanel/$_cp_subdir"
else
	_default_dir="$HOME/Library/Application Support/Context Panel/ClaudeRateLimits"
fi
out_dir="${CONTEXT_PANEL_CLAUDE_RATE_LIMIT_DIR:-$_default_dir}"
out_file="$out_dir/statusline-cache.json"
tmp_file="${out_file}.tmp"
legacy_dir="$HOME/Library/Application Support/Context Panel/ClaudeRateLimits"
legacy_file="$legacy_dir/statusline-cache.json"
legacy_tmp_file="${legacy_file}.tmp"

mkdir -p "$out_dir"

cache_json="$(jq -c --argjson observed_at "$(date +%s)" '
  def clean_window:
    select(type == "object")
    | {
        used_percentage: (.used_percentage // empty),
        resets_at: (.resets_at // null)
      };

  {
    observed_at: $observed_at,
    rate_limits: {
      five_hour: (.rate_limits.five_hour? | clean_window),
      seven_day: (.rate_limits.seven_day? | clean_window)
    }
  }
  | .rate_limits |= with_entries(select(.value != null))
  | select((.rate_limits | length) > 0)
' <<<"$input")"

if [ -n "$cache_json" ]; then
	printf '%s\n' "$cache_json" >"$tmp_file"
	mv "$tmp_file" "$out_file"
	if [ "$legacy_file" != "$out_file" ]; then
		mkdir -p "$legacy_dir"
		printf '%s\n' "$cache_json" >"$legacy_tmp_file"
		mv "$legacy_tmp_file" "$legacy_file"
	fi
fi

model="$(jq -r '.model.display_name // "Claude"' <<<"$input")"
five_hour="$(jq -r '.rate_limits.five_hour.used_percentage // empty' <<<"$input")"
weekly="$(jq -r '.rate_limits.seven_day.used_percentage // empty' <<<"$input")"

limits=""
if [ -n "$five_hour" ]; then
	limits="5h: $(printf '%.0f' "$five_hour")%"
fi
if [ -n "$weekly" ]; then
	limits="${limits:+$limits }7d: $(printf '%.0f' "$weekly")%"
fi

if [ -n "$limits" ]; then
	printf '[%s] | %s\n' "$model" "$limits"
else
	printf '[%s]\n' "$model"
fi
