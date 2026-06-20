#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scheme="ContextPanelCompanion"
configuration="Debug"
team_id="${APPLE_TEAM_ID:-MM5YXC7T6E}"
derived_data_path="$repo_root/.build/avp-dogfood/xcode-derived"
device_id="${CONTEXT_PANEL_AVP_DEVICE_ID:-}"
launch=1
build_only=0
install_json=""
build_destination="generic/platform=visionOS"
resolved_device_id=""

usage() {
	cat <<'USAGE'
Usage: scripts/dogfood-visionos-companion.sh [options]

Builds the companion app for local Apple Vision Pro dogfood with Debug
automatic development signing, then installs and launches it on an available
paired physical visionOS device.

This is not App Store Connect, TestFlight, or App Review release evidence. The
release upload path remains gated by the visionOS layered icon and distribution
profile checks.

Options:
  --device ID                 Apple Vision Pro CoreDevice identifier. Defaults
                              to the first paired physical visionOS device.
  --team-id ID                Apple Developer Team ID. Default: APPLE_TEAM_ID or
                              MM5YXC7T6E.
  --derived-data-path PATH    Xcode DerivedData path. Default:
                              .build/avp-dogfood/xcode-derived.
  --build-only                Build the signed visionOS app but do not install.
  --no-launch                 Install but do not launch.
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
	--derived-data-path)
		if [[ "$2" == /* ]]; then
			derived_data_path="$2"
		else
			derived_data_path="$repo_root/${2#./}"
		fi
		shift 2
		;;
	--build-only)
		build_only=1
		launch=0
		shift
		;;
	--no-launch)
		launch=0
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

xcodebuild_system_path() {
	local developer_dir
	local system_path
	developer_dir="$(/usr/bin/xcode-select -p)"
	system_path="/usr/bin:/bin:/usr/sbin:/sbin:$developer_dir/usr/bin:$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
	if [[ -n "${PATH:-}" ]]; then
		printf '%s:%s' "$system_path" "$PATH"
	else
		printf '%s' "$system_path"
	fi
}

run_xcodebuild() {
	PATH="$(xcodebuild_system_path)" /usr/bin/xcodebuild "$@"
}

device_json=""

load_device_json() {
	device_json="$(mktemp)"
	xcrun devicectl list devices --json-output "$device_json" >/dev/null
}

cleanup() {
	if [[ -n "$device_json" ]]; then
		rm -f "$device_json"
	fi
	if [[ -n "$install_json" ]]; then
		rm -f "$install_json"
	fi
}
trap cleanup EXIT

resolve_avp_device_id() {
	jq -r '
        .result.devices[]
        | select(.hardwareProperties.platform == "visionOS")
        | select(.hardwareProperties.reality == "physical")
        | select(.connectionProperties.pairingState == "paired")
        | .identifier
    ' "$device_json" | head -n 1
}

describe_device() {
	local id="$1"
	jq -r --arg id "$id" '
        .result.devices[]
        | select(.identifier == $id or .hardwareProperties.udid == $id or .deviceProperties.name == $id)
        | [
            .deviceProperties.name,
            .identifier,
            .hardwareProperties.platform,
            .hardwareProperties.reality,
            .connectionProperties.pairingState,
            .connectionProperties.tunnelState,
            .deviceProperties.developerModeStatus
        ]
        | @tsv
    ' "$device_json" | head -n 1
}

require_available_avp() {
	local id="$1"
	local description name identifier platform reality pairing tunnel developer_mode
	description="$(describe_device "$id")"
	if [[ -z "$description" ]]; then
		echo "Apple Vision Pro device not found by CoreDevice: $id" >&2
		echo "Run: xcrun devicectl list devices" >&2
		exit 1
	fi
	IFS=$'\t' read -r name identifier platform reality pairing tunnel developer_mode <<<"$description"
	if [[ "$platform" != "visionOS" || "$reality" != "physical" ]]; then
		echo "selected device is not a physical visionOS device: $name ($identifier, $platform, $reality)" >&2
		exit 1
	fi
	if [[ "$pairing" != "paired" ]]; then
		echo "Apple Vision Pro is not paired: $name ($identifier, pairing=$pairing)" >&2
		exit 1
	fi
	if [[ "$developer_mode" != "enabled" ]]; then
		echo "Apple Vision Pro Developer Mode is not enabled: $name ($identifier, developerMode=$developer_mode)" >&2
		exit 1
	fi
	if [[ "$tunnel" == "unavailable" ]]; then
		cat >&2 <<MSG
Apple Vision Pro is paired but unavailable to CoreDevice: $name ($identifier).
Wake and unlock the headset, keep it near this Mac, confirm Developer Mode is enabled, then rerun this script.
MSG
		exit 1
	fi
	printf '%s\n' "$identifier"
}

require_command jq
require_command xcodegen
require_command xcrun

cd "$repo_root"
xcodegen generate --spec project.yml

if ! ((build_only)); then
	load_device_json
	if [[ -z "$device_id" ]]; then
		device_id="$(resolve_avp_device_id)"
	fi
	if [[ -z "$device_id" ]]; then
		echo "No paired physical Apple Vision Pro was found by CoreDevice." >&2
		echo "Run: xcrun devicectl list devices" >&2
		exit 1
	fi
	resolved_device_id="$(require_available_avp "$device_id")"
	build_destination="platform=visionOS,id=$resolved_device_id"
fi

run_xcodebuild \
	-project ContextPanel.xcodeproj \
	-scheme "$scheme" \
	-configuration "$configuration" \
	-destination "$build_destination" \
	-derivedDataPath "$derived_data_path" \
	-allowProvisioningUpdates \
	-allowProvisioningDeviceRegistration \
	DEVELOPMENT_TEAM="$team_id" \
	CODE_SIGN_STYLE=Automatic \
	build

app_path="$derived_data_path/Build/Products/Debug-xros/Context Panel.app"
if [[ ! -d "$app_path" ]]; then
	echo "built app was not found: $app_path" >&2
	exit 1
fi

printf 'Built signed visionOS companion app: %s\n' "$app_path"

if ((build_only)); then
	exit 0
fi

install_json="$(mktemp)"
xcrun devicectl device install app \
	--device "$resolved_device_id" \
	--json-output "$install_json" \
	"$app_path"

launch_identifier="$(jq -r '.. | objects | .launchServicesIdentifier? // empty' "$install_json" | head -n 1)"
if [[ "$launch_identifier" == "unknown" ]]; then
	launch_identifier=""
fi
rm -f "$install_json"
install_json=""

printf 'Installed Context Panel on Apple Vision Pro: %s\n' "$resolved_device_id"

if ((launch)); then
	launch_args=(
		device process launch
		--device "$resolved_device_id"
		--terminate-existing
	)
	if [[ -n "$launch_identifier" ]]; then
		launch_args+=(--launch-persistent-identifier "$launch_identifier")
	fi
	launch_args+=(com.shinycomputers.contextpanel)
	xcrun devicectl "${launch_args[@]}"
	printf 'Launched Context Panel on Apple Vision Pro.\n'
fi
