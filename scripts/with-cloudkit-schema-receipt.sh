#!/usr/bin/env bash
# Runs a live release command on an operator machine with a valid Production
# CloudKit schema receipt in its environment:
#
#   scripts/with-cloudkit-schema-receipt.sh -- scripts/distribute-testflight-beta.py ...
#
# Reuses .build/cloudkit-production-schema-receipt.json while it is still valid for
# the current commit; otherwise runs the live schema gate to issue a fresh one.
# The receipt key comes from CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY or the
# operator Keychain. It is never printed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
receipt_path="${CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_PATH:-$repo_root/.build/cloudkit-production-schema-receipt.json}"
keychain_service="com.shinycomputers.contextpanel.cloudkit-schema-receipt"

if [[ "${1:-}" != "--" || $# -lt 2 ]]; then
	echo "Usage: $0 -- COMMAND [ARGUMENT...]" >&2
	exit 2
fi
shift

if [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${GITHUB_SHA:-}" ]]; then
	source_commit="$GITHUB_SHA"
else
	source_commit="$(git -C "$repo_root" rev-parse HEAD)"
fi

if [[ -z "${CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY:-}" ]]; then
	CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY="$(security find-generic-password -a "$USER" -s "$keychain_service" -w 2>/dev/null || true)"
fi
if [[ -z "$CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY" ]]; then
	echo "the CloudKit schema receipt key is not in the environment or the Keychain ($keychain_service)" >&2
	exit 1
fi
export CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY
export CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_PATH="$receipt_path"
unset CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_BASE64

gate=("$repo_root/scripts/require-cloudkit-schema-receipt.sh" --source-commit "$source_commit")
if [[ ! -f "$receipt_path" ]] || ! "${gate[@]}" >/dev/null 2>&1; then
	echo "Issuing a fresh Production CloudKit schema receipt for $source_commit"
	mkdir -p "$(dirname "$receipt_path")"
	"$repo_root/scripts/validate-cloudkit-companion-schema.sh" \
		--live \
		--environment production \
		--source-commit "$source_commit" \
		--receipt-output "$receipt_path"
fi

cd "$repo_root"
exec "$@"
