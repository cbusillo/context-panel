#!/usr/bin/env bash
set -euo pipefail

scheme="ContextPanelCompanion"
configuration="Debug"
artifact_cache_root="${CONTEXT_PANEL_ARTIFACT_CACHE_ROOT:-}"
derived_data_root=""
platforms=()

artifact_cache_root_is_available() {
	local cache_parent cache_namespace
	cache_parent="$(dirname "$artifact_cache_root")"
	cache_namespace="$(dirname "$cache_parent")"
	[[ -d "$artifact_cache_root" || -d "$cache_namespace" ]]
}

default_derived_data_root() {
	if [[ -n "${CONTEXT_PANEL_COMPANION_DERIVED_DATA_ROOT:-}" ]]; then
		printf '%s' "$CONTEXT_PANEL_COMPANION_DERIVED_DATA_ROOT"
	elif [[ -n "$artifact_cache_root" ]] && artifact_cache_root_is_available; then
		printf '%s' "$artifact_cache_root/derived-data/companion-build-validation"
	else
		printf '%s' ".build/companion-build-validation"
	fi
}

derived_data_root="$(default_derived_data_root)"

usage() {
	cat <<'USAGE'
Usage: scripts/validate-companion-builds.sh [options] [platform...]

Builds the companion app for generic Apple companion platforms without code
signing. This catches iOS/visionOS source, project, asset, and WidgetKit compile
regressions without requiring provisioning profiles or a physical device.

Platforms:
  ios        Build generic iOS.
  visionos   Build generic visionOS.

Options:
  --configuration VALUE       Xcode configuration. Default: Debug.
  --derived-data-root PATH    DerivedData root. Default: artifact cache when mounted,
                              otherwise .build/companion-build-validation.
  -h, --help                  Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--configuration)
		configuration="${2:?--configuration requires a value}"
		shift 2
		;;
	--derived-data-root)
		derived_data_root="${2:?--derived-data-root requires a value}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	ios | visionos)
		platforms+=("$1")
		shift
		;;
	*)
		echo "unsupported companion validation platform: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

if [[ ${#platforms[@]} -eq 0 ]]; then
	platforms=(ios visionos)
fi

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

destination_for_platform() {
	case "$1" in
	ios)
		printf 'generic/platform=iOS'
		;;
	visionos)
		printf 'generic/platform=visionOS'
		;;
	*)
		echo "unsupported companion validation platform: $1" >&2
		exit 2
		;;
	esac
}

require_command xcodegen
require_command xcodebuild

xcodegen generate --spec project.yml
echo "companion validation DerivedData root: $derived_data_root"

for platform in "${platforms[@]}"; do
	destination="$(destination_for_platform "$platform")"
	derived_data_path="$derived_data_root/$platform"
	echo "Validating $scheme for $destination"
	run_xcodebuild \
		-project ContextPanel.xcodeproj \
		-scheme "$scheme" \
		-configuration "$configuration" \
		-destination "$destination" \
		-derivedDataPath "$derived_data_path" \
		CODE_SIGNING_ALLOWED=NO \
		build
done
