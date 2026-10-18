#!/usr/bin/env bash
# Operator-only: runs on the operator Mac, never as a task test.
# --follow-main fast-forwards this checkout's main branch to protected main
# before the pass, so the scheduled operator checkout never runs stale gate code.
# --log appends output and each pass's exit status to FILE, keeping one
# previous file once it passes 1 MiB.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
follow_main=false
log_file=
while [[ $# -gt 1 ]]; do
  case "$1" in
  --follow-main) follow_main=true ;;
  --log)
    log_file="$2"
    shift
    ;;
  *) break ;;
  esac
  shift
done
if [[ $# -ne 1 || "$1" == --* ]]; then
  echo "Usage: $0 [--follow-main] [--log FILE] /absolute/path/to/gh-with-env-token" >&2
  exit 2
fi
if [[ -n "$log_file" ]]; then
  if [[ -f "$log_file" ]] && (($(wc -c <"$log_file") > 1048576)); then
    mv -f "$log_file" "$log_file.1"
  fi
  exec >>"$log_file" 2>&1
  log_exit() {
    local status=$?
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) operator pass exit $status"
  }
  trap log_exit EXIT
fi
if [[ "${GITHUB_ACTIONS:-}" == true || "$(uname -s)" != Darwin ]]; then
  echo "The CloudKit checker runs only outside Actions on the operator Mac" >&2
  exit 1
fi
if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
  echo "Use a clean, reviewed operator checkout" >&2
  exit 1
fi
git -C "$repo_root" fetch --no-tags origin main --quiet
if [[ "$follow_main" == true ]]; then
  if [[ "$(git -C "$repo_root" symbolic-ref --quiet --short HEAD || true)" != main ]]; then
    echo "--follow-main needs the operator checkout on its main branch" >&2
    exit 1
  fi
  before="$(git -C "$repo_root" rev-parse HEAD)"
  if ! git -C "$repo_root" merge-base --is-ancestor HEAD FETCH_HEAD; then
    echo "The operator checkout has commits that are not on protected main; refusing" >&2
    exit 1
  fi
  git -C "$repo_root" merge --ff-only --quiet FETCH_HEAD
  if [[ "$(git -C "$repo_root" rev-parse HEAD)" != "$before" ]]; then
    # Run the pass with the wrapper that main now holds, not this older copy.
    exec /bin/bash "$repo_root/scripts/cloudkit-schema-operator.sh" \
      ${log_file:+--log "$log_file"} "$1"
  fi
fi
if [[ -z "${CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY:-}" ]]; then
  CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY="$(security find-generic-password -a "$USER" -s com.shinycomputers.contextpanel.cloudkit-schema-receipt -w)"
fi
export CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY
cd "$repo_root"
relay=(uv run --no-project python "$repo_root/scripts/cloudkit-publication-relay.py" serve-once --github-cli "$1")
if [[ -n "$log_file" ]]; then
  "${relay[@]}"
else
  exec "${relay[@]}"
fi
