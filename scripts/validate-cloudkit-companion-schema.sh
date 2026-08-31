#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
environment="production"
schema_path="CloudKit/companion-sync.schema.json"
cktool_schema_path="CloudKit/companion-sync.schema.ckdb"
team_id="${APPLE_TEAM_ID:-MM5YXC7T6E}"
container_id="iCloud.com.shinycomputers.contextpanel"
live="false"
receipt_output=""
receipt_ttl_seconds="21600"
source_commit=""

usage() {
	cat <<'USAGE'
Usage: scripts/validate-cloudkit-companion-schema.sh [options]

Validates the checked-in companion and runtime-receipt CloudKit schema contract
and, when requested and authorized, compares it with the live container schema.

Options:
  --environment NAME   CloudKit environment for live validation. Default: production
  --team-id TEAM       Apple Developer Program team ID. Default: APPLE_TEAM_ID or MM5YXC7T6E
  --container-id ID    iCloud container ID. Default: iCloud.com.shinycomputers.contextpanel
  --schema PATH        Checked-in schema contract. Default: CloudKit/companion-sync.schema.json
  --cktool-schema PATH Checked-in cktool import schema. Default: CloudKit/companion-sync.schema.ckdb
  --live               Export and validate the live schema with xcrun cktool.
  --receipt-output PATH Write a sealed short-lived receipt after successful live validation.
  --receipt-ttl-seconds N
                       Receipt validity in seconds. Default: 21600 (6 hours)
  --source-commit SHA  Full source commit bound to the receipt. Default: GITHUB_SHA or HEAD
  -h, --help           Show this help.

Live validation requires a cktool token provided through cktool save-token,
CLOUDKIT_MANAGEMENT_TOKEN, or --token support from the local toolchain.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--environment)
		environment="${2:?--environment requires a value}"
		shift 2
		;;
	--team-id)
		team_id="${2:?--team-id requires a value}"
		shift 2
		;;
	--container-id)
		container_id="${2:?--container-id requires a value}"
		shift 2
		;;
	--schema)
		schema_path="${2:?--schema requires a value}"
		shift 2
		;;
	--cktool-schema)
		cktool_schema_path="${2:?--cktool-schema requires a value}"
		shift 2
		;;
	--live)
		live="true"
		shift
		;;
	--receipt-output)
		receipt_output="${2:?--receipt-output requires a value}"
		shift 2
		;;
	--receipt-ttl-seconds)
		receipt_ttl_seconds="${2:?--receipt-ttl-seconds requires a value}"
		shift 2
		;;
	--source-commit)
		source_commit="${2:?--source-commit requires a value}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "required command not found: $1" >&2
		exit 1
	fi
}

require_command jq

if [[ -n "$receipt_output" && "$live" != "true" ]]; then
	echo "--receipt-output requires --live" >&2
	exit 2
fi
if [[ -n "$receipt_output" && "$environment" != "production" ]]; then
	echo "CloudKit schema receipts require --environment production" >&2
	exit 2
fi

if [[ ! -f "$schema_path" ]]; then
	echo "CloudKit companion schema contract not found: $schema_path" >&2
	exit 1
fi
if [[ ! -f "$cktool_schema_path" ]]; then
	echo "CloudKit cktool import schema not found: $cktool_schema_path" >&2
	exit 1
fi

contract_record_type="CompanionSyncDocument"
runtime_session_record_type="RuntimeValidationSession"
runtime_receipt_record_type="RuntimeReceipt"
subscription_query_field="snapshotSchemaVersion"
required_fields=(
	payload
	schemaVersion
	documentSchemaVersion
	snapshotSchemaVersion
	generatedAt
	publishedAt
	payloadByteCount
)
runtime_session_required_fields=(
	payload
	schemaVersion
	sessionSchemaVersion
	sessionID
	createdAt
	expiresAt
	retentionExpiresAt
	expectedManifestID
	publishedAt
	sessionState
	stateUpdatedAt
	payloadByteCount
)
runtime_receipt_required_fields=(
	payload
	schemaVersion
	receiptSchemaVersion
	sessionID
	receiptID
	surface
	observedAt
	retentionExpiresAt
	processInstanceID
	processSequence
	payloadByteCount
)

required_field_type() {
	case "$1" in
	payload)
		printf 'BYTES\n'
		;;
	schemaVersion | documentSchemaVersion | snapshotSchemaVersion | sessionSchemaVersion | receiptSchemaVersion | processSequence | payloadByteCount)
		printf 'INT64\n'
		;;
	generatedAt | publishedAt | createdAt | expiresAt | observedAt | retentionExpiresAt | stateUpdatedAt)
		printf 'TIMESTAMP\n'
		;;
	sessionID | receiptID | surface | expectedManifestID | processInstanceID | sessionState)
		printf 'STRING\n'
		;;
	*)
		echo "unknown CloudKit schema field: $1" >&2
		exit 1
		;;
	esac
}

live_schema_has_record_type() {
	local schema="$1"
	local record_type="$2"
	awk -v record_type="$record_type" '
		$0 ~ "^[[:space:]]*RECORD[[:space:]]+TYPE[[:space:]]+\\\"?" record_type "\\\"?([[:space:]]|\\{|\\(|$)" {
			found = 1
		}
		END { exit(found ? 0 : 1) }
	' "$schema"
}

live_schema_has_field_type() {
	local schema="$1"
	local record_type="$2"
	local field_name="$3"
	local field_type="$4"
	awk -v record_type="$record_type" -v field_name="$field_name" -v field_type="$field_type" '
		$0 ~ "^[[:space:]]*RECORD[[:space:]]+TYPE[[:space:]]+\\\"?" record_type "\\\"?([[:space:]]|\\{|\\(|$)" {
			inside = 1
			next
		}
		inside && $0 ~ /^[[:space:]]*(\)|\};|})/ {
			inside = 0
		}
		inside {
			line = $0
			sub(/\/\/.*/, "", line)
			if (line ~ "^[[:space:]]*(FIELD[[:space:]]+)?\\\"?" field_name "\\\"?[[:space:]]*(:|[[:space:]])[[:space:]]*" field_type "([[:space:],;}]|$)") {
				found = 1
			}
		}
		END { exit(found ? 0 : 1) }
	' "$schema"
}

live_schema_field_is_queryable() {
	local schema="$1"
	local record_type="$2"
	local field_name="$3"
	awk -v record_type="$record_type" -v field_name="$field_name" '
		$0 ~ "^[[:space:]]*RECORD[[:space:]]+TYPE[[:space:]]+\\\"?" record_type "\\\"?([[:space:]]|\\{|\\(|$)" {
			inside = 1
			next
		}
		inside && $0 ~ /^[[:space:]]*(\)|\};|})/ {
			inside = 0
		}
		inside {
			line = $0
			sub(/\/\/.*/, "", line)
			if (line ~ "^[[:space:]]*(FIELD[[:space:]]+)?\\\"?" field_name "\\\"?[[:space:]]*(:|[[:space:]])" && line ~ /(^|[[:space:]])QUERYABLE([[:space:],;}]|$)/) {
				found = 1
			}
		}
		END { exit(found ? 0 : 1) }
	' "$schema"
}

live_schema_field_is_sortable() {
	local schema="$1"
	local record_type="$2"
	local field_name="$3"
	awk -v record_type="$record_type" -v field_name="$field_name" '
		$0 ~ "^[[:space:]]*RECORD[[:space:]]+TYPE[[:space:]]+\\\"?" record_type "\\\"?([[:space:]]|\\{|\\(|$)" {
			inside = 1
			next
		}
		inside && $0 ~ /^[[:space:]]*(\)|\};|})/ {
			inside = 0
		}
		inside {
			line = $0
			sub(/\/\/.*/, "", line)
			if (line ~ "^[[:space:]]*(FIELD[[:space:]]+)?\\\"?" field_name "\\\"?[[:space:]]*(:|[[:space:]])" && line ~ /(^|[[:space:]])SORTABLE([[:space:],;}]|$)/) {
				found = 1
			}
		}
		END { exit(found ? 0 : 1) }
	' "$schema"
}

live_schema_record_has_grant() {
	local schema="$1"
	local record_type="$2"
	awk -v record_type="$record_type" '
		$0 ~ "^[[:space:]]*RECORD[[:space:]]+TYPE[[:space:]]+\\\"?" record_type "\\\"?([[:space:]]|\\{|\\(|$)" {
			inside = 1
			next
		}
		inside && $0 ~ /^[[:space:]]*(\)|\};|})/ {
			inside = 0
		}
		inside {
			line = $0
			sub(/\/\/.*/, "", line)
			if (line ~ /^[[:space:]]*GRANT[[:space:]]/) {
				found = 1
			}
		}
		END { exit(found ? 0 : 1) }
	' "$schema"
}

live_schema_record_grants() {
	local schema="$1"
	local record_type="$2"
	awk -v record_type="$record_type" '
		$0 ~ "^[[:space:]]*RECORD[[:space:]]+TYPE[[:space:]]+\\\"?" record_type "\\\"?([[:space:]]|\\{|\\(|$)" {
			inside = 1
			next
		}
		inside && $0 ~ /^[[:space:]]*(\)|\};|})/ {
			inside = 0
		}
		inside {
			line = $0
			sub(/\/\/.*/, "", line)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
			gsub(/[\",;]/, "", line)
			count = split(line, parts, /[[:space:]]+/)
			if (count >= 4 && parts[1] == "GRANT" && parts[3] == "TO") {
				print parts[2] ":" parts[4]
			}
		}
	' "$schema"
}

live_schema_record_types() {
	local schema="$1"
	awk '
		$0 ~ /^[[:space:]]*RECORD[[:space:]]+TYPE[[:space:]]+/ {
			line = $0
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
			split(line, parts, /[[:space:]]+/)
			record_type = parts[3]
			gsub(/\"/, "", record_type)
			print record_type
		}
	' "$schema"
}

validate_ckdb_grants() {
	local schema="$1"
	local record_type="$2"
	local expected="$3"
	local label="$4"
	local actual
	actual="$(live_schema_record_grants "$schema" "$record_type" | LC_ALL=C sort)"
	if [[ "$actual" != "$expected" ]]; then
		echo "$label schema grants changed for record type: $record_type" >&2
		return 1
	fi
}

validate_ckdb_schema() {
	local schema="$1"
	local label="$2"
	local require_exact_record_types="${3:-false}"
	local expected_record_types
	local actual_record_types

	if [[ "$require_exact_record_types" == "true" ]]; then
		expected_record_types=$'CompanionSyncDocument\nRuntimeReceipt\nRuntimeValidationSession\nUsers'
		actual_record_types="$(live_schema_record_types "$schema" | LC_ALL=C sort -u)"
		if [[ "$actual_record_types" != "$expected_record_types" ]]; then
			echo "$label schema record types differ from the additive companion/runtime baseline" >&2
			return 1
		fi
	fi

	if ! live_schema_has_record_type "$schema" "$contract_record_type"; then
		echo "$label schema is missing record type: $contract_record_type" >&2
		return 1
	fi
	for field in "${required_fields[@]}"; do
		expected_type="$(required_field_type "$field")"
		if ! live_schema_has_field_type "$schema" "$contract_record_type" "$field" "$expected_type"; then
			echo "$label schema is missing field/type: $contract_record_type.$field $expected_type" >&2
			return 1
		fi
		if ! live_schema_field_is_queryable "$schema" "$contract_record_type" "$field"; then
			echo "$label schema field is not queryable: $contract_record_type.$field" >&2
			return 1
		fi
		if ! live_schema_field_is_sortable "$schema" "$contract_record_type" "$field"; then
			echo "$label schema field is not sortable: $contract_record_type.$field" >&2
			return 1
		fi
	done
	if ! validate_ckdb_grants "$schema" "$contract_record_type" $'CREATE:_icloud\nREAD:_world\nWRITE:_creator' "$label"; then
		return 1
	fi

	if ! live_schema_has_record_type "$schema" Users; then
		echo "$label schema is missing record type: Users" >&2
		return 1
	fi
	if ! live_schema_has_field_type "$schema" Users roles 'LIST<INT64>'; then
		echo "$label schema is missing field/type: Users.roles LIST<INT64>" >&2
		return 1
	fi
	if ! validate_ckdb_grants "$schema" Users $'READ:_world\nWRITE:_creator' "$label"; then
		return 1
	fi

	for record_type in "$runtime_session_record_type" "$runtime_receipt_record_type"; do
		if ! live_schema_has_record_type "$schema" "$record_type"; then
			echo "$label schema is missing record type: $record_type" >&2
			return 1
		fi
		if ! validate_ckdb_grants "$schema" "$record_type" "" "$label"; then
			echo "$label schema must not grant public database access for record type: $record_type" >&2
			return 1
		fi
	done
	for field in "${runtime_session_required_fields[@]}"; do
		expected_type="$(required_field_type "$field")"
		if ! live_schema_has_field_type "$schema" "$runtime_session_record_type" "$field" "$expected_type"; then
			echo "$label schema is missing field/type: $runtime_session_record_type.$field $expected_type" >&2
			return 1
		fi
	done
	for field in "${runtime_receipt_required_fields[@]}"; do
		expected_type="$(required_field_type "$field")"
		if ! live_schema_has_field_type "$schema" "$runtime_receipt_record_type" "$field" "$expected_type"; then
			echo "$label schema is missing field/type: $runtime_receipt_record_type.$field $expected_type" >&2
			return 1
		fi
	done
	for field in sessionID retentionExpiresAt; do
		if ! live_schema_field_is_queryable "$schema" "$runtime_receipt_record_type" "$field"; then
			echo "$label schema field is not queryable: $runtime_receipt_record_type.$field" >&2
			return 1
		fi
	done
	if ! live_schema_field_is_sortable "$schema" "$runtime_receipt_record_type" retentionExpiresAt; then
		echo "$label schema field is not sortable: $runtime_receipt_record_type.retentionExpiresAt" >&2
		return 1
	fi
}

contract_container="$(jq -r '.containerIdentifier // empty' "$schema_path")"
contract_database="$(jq -r '.database // empty' "$schema_path")"
if [[ "$contract_container" != "$container_id" ]]; then
	echo "schema contract container mismatch: expected $container_id, found ${contract_container:-missing}" >&2
	exit 1
fi
if [[ "$contract_database" != "private" ]]; then
	echo "schema contract database must be private" >&2
	exit 1
fi
contract_record_name="$(jq -r --arg name "$contract_record_type" '.recordTypes[]? | select(.name == $name) | .recordName // empty' "$schema_path")"
if [[ "$contract_record_name" != "current-v2" ]]; then
	echo "schema contract record name mismatch: expected current-v2, found ${contract_record_name:-missing}" >&2
	exit 1
fi
if ! jq -e --arg name "$contract_record_type" '.recordTypes[]? | select(.name == $name)' "$schema_path" >/dev/null; then
	echo "schema contract is missing record type: $contract_record_type" >&2
	exit 1
fi
for field in "${required_fields[@]}"; do
	expected_type="$(required_field_type "$field")"
	actual_type="$(jq -r --arg record "$contract_record_type" --arg field "$field" \
		'.recordTypes[]? | select(.name == $record) | .fields[]? | select(.name == $field) | .type // empty' \
		"$schema_path")"
	if [[ -z "$actual_type" ]]; then
		echo "schema contract is missing field: $contract_record_type.$field" >&2
		exit 1
	fi
	if [[ "$actual_type" != "$expected_type" ]]; then
		echo "schema contract field type mismatch: $contract_record_type.$field expected $expected_type, found $actual_type" >&2
		exit 1
	fi
done
contract_queryable="$(jq -r --arg record "$contract_record_type" --arg field "$subscription_query_field" \
	'.recordTypes[]? | select(.name == $record) | .fields[]? | select(.name == $field) | .queryable // false' \
	"$schema_path")"
if [[ "$contract_queryable" != "true" ]]; then
	echo "schema contract field must be queryable: $contract_record_type.$subscription_query_field" >&2
	exit 1
fi

runtime_session_record_name="$(jq -r --arg name "$runtime_session_record_type" '.recordTypes[]? | select(.name == $name) | .recordName // empty' "$schema_path")"
if [[ "$runtime_session_record_name" != "runtime-validation-session-current-v1" ]]; then
	echo "schema contract record name mismatch: expected runtime-validation-session-current-v1, found ${runtime_session_record_name:-missing}" >&2
	exit 1
fi
runtime_receipt_record_name_pattern="$(jq -r --arg name "$runtime_receipt_record_type" '.recordTypes[]? | select(.name == $name) | .recordNamePattern // empty' "$schema_path")"
if [[ "$runtime_receipt_record_name_pattern" != "runtime-receipt-<sha256>" ]]; then
	echo "schema contract record name pattern mismatch: expected runtime-receipt-<sha256>, found ${runtime_receipt_record_name_pattern:-missing}" >&2
	exit 1
fi
for record_type in "$runtime_session_record_type" "$runtime_receipt_record_type"; do
	if ! jq -e --arg name "$record_type" '.recordTypes[]? | select(.name == $name)' "$schema_path" >/dev/null; then
		echo "schema contract is missing record type: $record_type" >&2
		exit 1
	fi
	if ! jq -e --arg name "$record_type" '.recordTypes[]? | select(.name == $name) | .publicDatabaseGrants == []' "$schema_path" >/dev/null; then
		echo "schema contract must prohibit public database grants for record type: $record_type" >&2
		exit 1
	fi
done
for field in "${runtime_session_required_fields[@]}"; do
	expected_type="$(required_field_type "$field")"
	actual_type="$(jq -r --arg record "$runtime_session_record_type" --arg field "$field" \
		'.recordTypes[]? | select(.name == $record) | .fields[]? | select(.name == $field) | .type // empty' \
		"$schema_path")"
	if [[ "$actual_type" != "$expected_type" ]]; then
		echo "schema contract field mismatch: $runtime_session_record_type.$field expected $expected_type, found ${actual_type:-missing}" >&2
		exit 1
	fi
done
for field in "${runtime_receipt_required_fields[@]}"; do
	expected_type="$(required_field_type "$field")"
	actual_type="$(jq -r --arg record "$runtime_receipt_record_type" --arg field "$field" \
		'.recordTypes[]? | select(.name == $record) | .fields[]? | select(.name == $field) | .type // empty' \
		"$schema_path")"
	if [[ "$actual_type" != "$expected_type" ]]; then
		echo "schema contract field mismatch: $runtime_receipt_record_type.$field expected $expected_type, found ${actual_type:-missing}" >&2
		exit 1
	fi
done
for field in sessionID retentionExpiresAt; do
	contract_queryable="$(jq -r --arg record "$runtime_receipt_record_type" --arg field "$field" \
		'.recordTypes[]? | select(.name == $record) | .fields[]? | select(.name == $field) | .queryable // false' \
		"$schema_path")"
	if [[ "$contract_queryable" != "true" ]]; then
		echo "schema contract field must be queryable: $runtime_receipt_record_type.$field" >&2
		exit 1
	fi
done
contract_sortable="$(jq -r --arg record "$runtime_receipt_record_type" --arg field retentionExpiresAt \
	'.recordTypes[]? | select(.name == $record) | .fields[]? | select(.name == $field) | .sortable // false' \
	"$schema_path")"
if [[ "$contract_sortable" != "true" ]]; then
	echo "schema contract field must be sortable: $runtime_receipt_record_type.retentionExpiresAt" >&2
	exit 1
fi

validate_ckdb_schema "$cktool_schema_path" "checked-in cktool" "true"

if [[ "$live" != "true" ]]; then
	echo "CloudKit companion and runtime receipt schema contracts OK: $schema_path and $cktool_schema_path"
	exit 0
fi

require_command xcrun

live_schema="$(mktemp)"
trap 'rm -f "$live_schema"' EXIT

cktool_export_args=(
	cktool
	export-schema
	--team-id "$team_id"
	--container-id "$container_id"
	--environment "$environment"
	--output-file "$live_schema"
)
if [[ -n "${CLOUDKIT_MANAGEMENT_TOKEN:-}" ]]; then
	cktool_export_args+=(--token "$CLOUDKIT_MANAGEMENT_TOKEN")
fi

if ! xcrun "${cktool_export_args[@]}" >/dev/null 2>&1; then
	if [[ -n "$receipt_output" ]]; then
		echo "CloudKit live schema validation failed: cktool export-schema failed for $container_id/$environment." >&2
	else
		echo "CloudKit live schema validation skipped: cktool export-schema failed for $container_id/$environment." >&2
	fi
	echo "Run xcrun cktool save-token or set CLOUDKIT_MANAGEMENT_TOKEN, then rerun with --live." >&2
	if [[ -n "$receipt_output" ]]; then
		exit 1
	fi
	exit 77
fi

validate_ckdb_schema "$live_schema" "live CloudKit $environment"

if [[ -n "$receipt_output" ]]; then
	require_command python3
	if [[ -z "$source_commit" ]]; then
		source_commit="${GITHUB_SHA:-}"
	fi
	if [[ -z "$source_commit" ]]; then
		require_command git
		source_commit="$(git -C "$repo_root" rev-parse HEAD)"
	fi
	python3 "$repo_root/scripts/cloudkit-schema-receipt.py" issue \
		--environment "$environment" \
		--container-id "$container_id" \
		--schema "$schema_path" \
		--cktool-schema "$cktool_schema_path" \
		--source-commit "$source_commit" \
		--ttl-seconds "$receipt_ttl_seconds" \
		--output "$receipt_output"
fi

echo "CloudKit live schema contains private-only companion sync and runtime receipt contracts with required query and range indexes in $environment."
