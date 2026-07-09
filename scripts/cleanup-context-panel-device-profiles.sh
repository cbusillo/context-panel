#!/usr/bin/env bash
set -euo pipefail

team_id="${APPLE_TEAM_ID:-MM5YXC7T6E}"
device_id=""
allow_without_preserve=0
preserve_apps=()
preserve_uuids=()

usage() {
	cat <<'USAGE'
Usage: scripts/cleanup-context-panel-device-profiles.sh --device ID [options]

Removes stale Context Panel development provisioning profiles from a physical
device while preserving profiles embedded in the app bundle passed with
--preserve-app. App Store/TestFlight profiles are intentionally left alone.

Options:
  --device ID                 CoreDevice identifier, UDID, or device name.
  --team-id ID                Apple Developer Team ID. Default: APPLE_TEAM_ID or
                              MM5YXC7T6E.
  --preserve-app PATH         App bundle whose embedded.mobileprovision files
                              must be kept. May be repeated.
  --preserve-profile-uuid ID  Provisioning profile UUID to keep. May be repeated.
  --allow-without-preserve    Allow cleanup with no preserved profile UUIDs.
                              Use only for TestFlight/App Store-installed apps.
  -h, --help                  Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--device)
		device_id="${2:?--device requires a value}"
		shift 2
		;;
	--team-id)
		team_id="${2:?--team-id requires a value}"
		shift 2
		;;
	--preserve-app)
		preserve_apps+=("${2:?--preserve-app requires a value}")
		shift 2
		;;
	--preserve-profile-uuid)
		preserve_uuids+=("${2:?--preserve-profile-uuid requires a value}")
		shift 2
		;;
	--allow-without-preserve)
		allow_without_preserve=1
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

if [[ -z "$device_id" ]]; then
	echo "--device is required" >&2
	usage >&2
	exit 2
fi

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "required command not found: $1" >&2
		exit 1
	fi
}

embedded_profile_uuids() {
	local app="$1"
	local profile plist
	if [[ ! -d "$app" ]]; then
		echo "preserve app not found: $app" >&2
		exit 1
	fi
	while IFS= read -r -d '' profile; do
		plist="$(mktemp)"
		if security cms -D -i "$profile" -o "$plist" >/dev/null 2>&1; then
			/usr/libexec/PlistBuddy -c 'Print :UUID' "$plist" 2>/dev/null || true
		fi
		rm -f "$plist"
	done < <(find "$app" -name embedded.mobileprovision -type f -print0)
}

uuid_is_preserved() {
	local uuid="$1"
	local preserved
	for preserved in "${preserve_uuids[@]}"; do
		if [[ "$uuid" == "$preserved" ]]; then
			return 0
		fi
	done
	return 1
}

require_command jq
require_command xcrun

for app in "${preserve_apps[@]}"; do
	while IFS= read -r uuid; do
		if [[ -n "$uuid" ]]; then
			preserve_uuids+=("$uuid")
		fi
	done < <(embedded_profile_uuids "$app")
done

if ((allow_without_preserve == 0)) && ((${#preserve_uuids[@]} == 0)); then
	cat >&2 <<'MSG'
No preserved provisioning profile UUIDs were found. Refusing to remove profiles
because that could break a currently installed development build. Pass
--preserve-app for freshly installed dev builds, or --allow-without-preserve
only when cleaning a TestFlight/App Store device.
MSG
	exit 1
fi

profiles_json="$(mktemp)"
trap 'rm -f "$profiles_json"' EXIT

if ! xcrun devicectl device profile list \
	--device "$device_id" \
	--type provisioning \
	--json-output "$profiles_json" >/dev/null; then
	echo "unable to list device provisioning profiles" >&2
	exit 1
fi

removed_count=0
while IFS=$'\t' read -r uuid name; do
	if [[ -z "$uuid" ]] || uuid_is_preserved "$uuid"; then
		continue
	fi
	if xcrun devicectl device profile remove \
		--device "$device_id" \
		--type provisioning \
		"$uuid" >/dev/null; then
		removed_count=$((removed_count + 1))
		printf 'Removed stale Context Panel provisioning profile: %s (%s)\n' "$name" "$uuid"
	else
		printf 'warning: failed to remove stale Context Panel provisioning profile: %s (%s)\n' "$name" "$uuid" >&2
	fi
done < <(
	jq -r --arg team_id "$team_id" '
        .result.provisioningProfiles[]?
        | select(.teamIdentifier == $team_id)
        | select(.name | startswith("iOS Team Provisioning Profile: com.shinycomputers.contextpanel"))
        | [.uuid, .name]
        | @tsv
    ' "$profiles_json"
)

printf 'Removed %s stale Context Panel provisioning profile(s).\n' "$removed_count"
