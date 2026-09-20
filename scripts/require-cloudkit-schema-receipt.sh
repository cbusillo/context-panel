#!/usr/bin/env bash
# Refuses to continue unless a valid Production CloudKit schema receipt exists for
# the commit being released. Every live release mutation calls this itself, so the
# rule holds in GitHub Actions and on an operator machine alike. There is no
# override: dry-run and export-only paths simply do not call it.
#
# Receipt: CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_BASE64, or a file named by
#          CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_PATH.
# Key:     CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY.
# Commit:  --source-commit, else GITHUB_SHA inside GitHub Actions, else the checkout's HEAD.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
source_commit=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--source-commit)
		source_commit="${2:?--source-commit requires a value}"
		shift 2
		;;
	*)
		echo "Usage: $0 [--source-commit SHA]" >&2
		exit 2
		;;
	esac
done

if [[ -z "$source_commit" && "${GITHUB_ACTIONS:-}" == "true" ]]; then
	source_commit="${GITHUB_SHA:-}"
fi
if [[ -z "$source_commit" ]]; then
	source_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
fi
if [[ -z "$source_commit" ]]; then
	echo "refusing live release mutation: the source commit is unknown" >&2
	exit 1
fi

receipt_args=()
if [[ -n "${CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_BASE64:-}" ]]; then
	receipt_args=(--receipt-base64-env CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_BASE64)
elif [[ -n "${CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_PATH:-}" ]]; then
	receipt_args=(--receipt "$CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_PATH")
else
	echo "refusing live release mutation: no Production CloudKit schema receipt was provided" >&2
	echo "Run the live schema gate first; see 'CloudKit Production Schema Gate' in docs/release.md." >&2
	exit 1
fi

if ! python3 "$repo_root/scripts/cloudkit-schema-receipt.py" verify \
	"${receipt_args[@]}" \
	--environment production \
	--container-id iCloud.com.shinycomputers.contextpanel \
	--source-commit "$source_commit"; then
	echo "refusing live release mutation: the Production CloudKit schema receipt is not valid for $source_commit" >&2
	exit 1
fi
