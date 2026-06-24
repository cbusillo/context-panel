#!/usr/bin/env bash
set -euo pipefail

environment="production"
schema_path="CloudKit/companion-sync.schema.json"
team_id="${APPLE_TEAM_ID:-MM5YXC7T6E}"
container_id="iCloud.com.shinycomputers.contextpanel"
live="false"

usage() {
	cat <<'USAGE'
Usage: scripts/validate-cloudkit-companion-schema.sh [options]

Validates the checked-in companion CloudKit schema contract and, when requested
and authorized, compares it with the live CloudKit container schema.

Options:
  --environment NAME   CloudKit environment for live validation. Default: production
  --team-id TEAM       Apple Developer Program team ID. Default: APPLE_TEAM_ID or MM5YXC7T6E
  --container-id ID    iCloud container ID. Default: iCloud.com.shinycomputers.contextpanel
  --schema PATH        Checked-in schema contract. Default: CloudKit/companion-sync.schema.json
  --live               Export and validate the live schema with xcrun cktool.
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
	--live)
		live="true"
		shift
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

if [[ ! -f "$schema_path" ]]; then
	echo "CloudKit companion schema contract not found: $schema_path" >&2
	exit 1
fi

contract_record_type="CompanionSyncDocument"
required_fields=(
	payload
	schemaVersion
	documentSchemaVersion
	snapshotSchemaVersion
	generatedAt
	publishedAt
	payloadByteCount
)

required_field_type() {
	case "$1" in
	payload)
		printf 'BYTES\n'
		;;
	schemaVersion | documentSchemaVersion | snapshotSchemaVersion | payloadByteCount)
		printf 'INT64\n'
		;;
	generatedAt | publishedAt)
		printf 'TIMESTAMP\n'
		;;
	*)
		echo "unknown CloudKit companion schema field: $1" >&2
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
if [[ "$contract_record_name" != "current" ]]; then
	echo "schema contract record name mismatch: expected current, found ${contract_record_name:-missing}" >&2
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

if [[ "$live" != "true" ]]; then
	echo "CloudKit companion schema contract OK: $schema_path"
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
	echo "CloudKit live schema validation skipped: cktool export-schema failed for $container_id/$environment." >&2
	echo "Run xcrun cktool save-token or set CLOUDKIT_MANAGEMENT_TOKEN, then rerun with --live." >&2
	exit 77
fi

if ! live_schema_has_record_type "$live_schema" "$contract_record_type"; then
	echo "live CloudKit $environment schema is missing record type: $contract_record_type" >&2
	exit 1
fi
for field in "${required_fields[@]}"; do
	expected_type="$(required_field_type "$field")"
	if ! live_schema_has_field_type "$live_schema" "$contract_record_type" "$field" "$expected_type"; then
		echo "live CloudKit $environment schema is missing field/type: $contract_record_type.$field $expected_type" >&2
		exit 1
	fi
done

echo "CloudKit companion live schema contains $contract_record_type with required field types in $environment."
