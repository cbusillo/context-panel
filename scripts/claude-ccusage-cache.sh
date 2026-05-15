#!/usr/bin/env bash
set -euo pipefail

_group_base="$HOME/Library/Group Containers"
_cp_subdir="Context Panel/ClaudeRateLimits"
if [ -d "$_group_base/MM5YXC7T6E.group.com.shinycomputers.contextpanel" ]; then
	_default_dir="$_group_base/MM5YXC7T6E.group.com.shinycomputers.contextpanel/$_cp_subdir"
else
	_default_dir="$HOME/Library/Application Support/Context Panel/ClaudeRateLimits"
fi
cache_dir="${CONTEXT_PANEL_CLAUDE_RATE_LIMIT_DIR:-$_default_dir}"
cache_file="$cache_dir/ccusage-blocks-cache.json"
legacy_dir="$HOME/Library/Application Support/Context Panel/ClaudeRateLimits"
legacy_file="$legacy_dir/ccusage-blocks-cache.json"

mkdir -p "$cache_dir"

if command -v ccusage >/dev/null 2>&1; then
  ccusage blocks --json --offline >"$cache_file.tmp"
elif command -v bunx >/dev/null 2>&1; then
  bunx ccusage@latest blocks --json --offline >"$cache_file.tmp"
else
  echo "ccusage or bunx is required" >&2
  exit 127
fi

mv "$cache_file.tmp" "$cache_file"
if [ "$legacy_file" != "$cache_file" ]; then
  mkdir -p "$legacy_dir"
  cp "$cache_file" "$legacy_file"
fi
echo "$cache_file"
