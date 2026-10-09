#!/usr/bin/env bash
# No environment or secret is attached until the owner confirms release setup.
set -euo pipefail
if [[ "${RELEASE_APPROVALS_CONFIGURED:-}" != "true" ]]; then
  echo "Release setup is incomplete; follow docs/release.md before enabling RELEASE_APPROVALS_CONFIGURED." >&2
  exit 1
fi
