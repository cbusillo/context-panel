#!/usr/bin/env bash
# Operator-only. Activation requires Chris's approval; never run as a task test.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /absolute/path/to/gh-with-env-token" >&2
  exit 2
fi
if [[ "${GITHUB_ACTIONS:-}" == true || "$(uname -s)" != Darwin ]]; then
  echo "The CloudKit checker runs only outside Actions on the operator Mac" >&2
  exit 1
fi
if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
  echo "Use a clean, reviewed operator checkout" >&2
  exit 1
fi
if [[ -z "${CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY:-}" ]]; then
  CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY="$(security find-generic-password -a "$USER" -s com.shinycomputers.contextpanel.cloudkit-schema-receipt -w)"
fi
export CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY
cd "$repo_root"
exec uv run --no-project python "$repo_root/scripts/cloudkit-publication-relay.py" serve-once --github-cli "$1"
