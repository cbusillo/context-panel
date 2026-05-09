#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/context-panel-claude-statusline.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

cache_dir="$tmp_dir/ClaudeRateLimits"
stats_path="$tmp_dir/stats-cache.json"
claude_stub="$tmp_dir/claude"

cat >"$claude_stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "auth" ] && [ "$2" = "status" ] && [ "$3" = "--json" ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro","email":"redacted@example.com","orgId":"org_secret"}'
  exit 0
fi
printf 'unexpected claude stub arguments\n' >&2
exit 2
STUB
chmod +x "$claude_stub"

cat >"$stats_path" <<'JSON'
{
  "version": 1,
  "lastComputedDate": "2026-05-09T00:00:00Z",
  "totalSessions": 1,
  "totalMessages": 1
}
JSON

CONTEXT_PANEL_CLAUDE_RATE_LIMIT_DIR="$cache_dir" \
  "$repo_root/scripts/claude-statusline-cache.sh" <<'JSON' >/dev/null
{
  "model": { "display_name": "Claude" },
  "rate_limits": {
    "five_hour": { "used_percentage": 42.4, "resets_at": 1788397200 },
    "seven_day": { "used_percentage": 51.6, "resets_at": 1788984000 }
  },
  "transcript_path": "/Users/example/.claude/projects/secret.jsonl",
  "session_id": "secret-session"
}
JSON

cache_path="$cache_dir/statusline-cache.json"
test -s "$cache_path"

output="$(
  cd "$repo_root"
  swift run ClaudeLimitProbe \
    --claude-bin "$claude_stub" \
    --stats "$stats_path" \
    --rate-limit-cache "$cache_path"
)"

grep -Fq 'statusline cache:' <<<"$output"
grep -Fq 'limits: 2' <<<"$output"
grep -Fq 'Claude 5-hour: healthy 42/100 percent' <<<"$output"
grep -Fq 'Claude Weekly: healthy 52/100 percent' <<<"$output"
grep -Fq 'source: Claude Code statusline' <<<"$output"

if grep -Eq 'redacted@example\.com|org_secret|secret-session|secret\.jsonl' <<<"$output"; then
  printf 'Claude validation output leaked synthetic secret data\n' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

printf 'Claude statusline pipeline validation passed.\n'
