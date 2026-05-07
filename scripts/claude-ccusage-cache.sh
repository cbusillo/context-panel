#!/usr/bin/env bash
set -euo pipefail

cache_dir="${CONTEXT_PANEL_CLAUDE_RATE_LIMIT_DIR:-$HOME/Library/Application Support/Context Panel/ClaudeRateLimits}"
cache_file="$cache_dir/ccusage-blocks-cache.json"

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
echo "$cache_file"
