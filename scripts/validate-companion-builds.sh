#!/usr/bin/env bash
set -euo pipefail

scheme="ContextPanelCompanion"
configuration="Debug"
archive=0
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

Builds the companion app surfaces for generic Apple companion platforms without
code signing. This catches iOS/visionOS/watchOS/tvOS source, project, asset, and
WidgetKit compile regressions without requiring provisioning profiles or a
physical device.

With --archive, validates companion app archive packaging for iOS, visionOS,
and tvOS. The watchOS target is embedded in the iOS companion archive and
remains a build-only standalone validation target in this gate.

Platforms:
  ios        Build generic iOS.
  visionos   Build generic visionOS.
  watchos    Build generic watchOS.
  tvos       Build generic tvOS.

Options:
  --archive                   Archive iOS/visionOS/tvOS companion apps instead
                              of building them. Not supported for watchOS.
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
	--archive)
		archive=1
		shift
		;;
	--derived-data-root)
		derived_data_root="${2:?--derived-data-root requires a value}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	ios | visionos | watchos | tvos)
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
	platforms=(ios visionos watchos tvos)
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

validate_archive_contents() {
	local platform archive_path app_path watch_path watch_widget_path icon_name top_shelf_image top_shelf_image_wide
	platform="$1"
	archive_path="$2"
	app_path="$archive_path/Products/Applications/Context Panel.app"
	watch_path="$app_path/Watch/Context Panel.app"
	watch_widget_path="$watch_path/PlugIns/ContextPanelWatchWidgetExtension.appex"

	if [[ ! -d "$app_path" ]]; then
		echo "companion archive is missing app bundle: $app_path" >&2
		exit 1
	fi

	case "$platform" in
	ios)
		if [[ ! -d "$watch_path" ]]; then
			echo "iOS companion archive is missing embedded watch app: $watch_path" >&2
			exit 1
		fi
		if [[ ! -d "$watch_widget_path" ]]; then
			echo "iOS companion archive is missing embedded watch widget: $watch_widget_path" >&2
			exit 1
		fi
		;;
	visionos)
		if [[ -e "$app_path/Watch" ]]; then
			echo "visionOS companion archive unexpectedly contains watch content: $app_path/Watch" >&2
			exit 1
		fi
		;;
	tvos)
		local top_shelf_path="$app_path/PlugIns/ContextPanelTVTopShelfExtension.appex"
		if [[ -e "$app_path/Watch" ]]; then
			echo "tvOS companion archive unexpectedly contains watch content: $app_path/Watch" >&2
			exit 1
		fi
		if [[ -e "$app_path/PlugIns/ContextPanelCompanionWidgetExtension.appex" ]]; then
			echo "tvOS companion archive unexpectedly contains the iOS/visionOS companion widget" >&2
			exit 1
		fi
		if [[ ! -d "$top_shelf_path" ]]; then
			echo "tvOS companion archive is missing embedded Top Shelf extension: $top_shelf_path" >&2
			exit 1
		fi
		if [[ ! -f "$app_path/Assets.car" ]]; then
			echo "tvOS companion archive is missing compiled brand assets: $app_path/Assets.car" >&2
			exit 1
		fi
		icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon' "$app_path/Info.plist" 2>/dev/null || true)"
		if [[ "$icon_name" != "App Icon - Small" ]]; then
			echo "tvOS companion archive is missing the primary layered app icon" >&2
			exit 1
		fi
		top_shelf_image="$(/usr/libexec/PlistBuddy -c 'Print :TVTopShelfImage:TVTopShelfPrimaryImage' "$app_path/Info.plist" 2>/dev/null || true)"
		top_shelf_image_wide="$(/usr/libexec/PlistBuddy -c 'Print :TVTopShelfImage:TVTopShelfPrimaryImageWide' "$app_path/Info.plist" 2>/dev/null || true)"
		if [[ -z "$top_shelf_image" || -z "$top_shelf_image_wide" ]]; then
			echo "tvOS companion archive is missing required standard or wide Top Shelf artwork" >&2
			exit 1
		fi
		;;
	esac
}

destination_for_platform() {
	case "$1" in
	ios)
		printf 'generic/platform=iOS'
		;;
	visionos)
		printf 'generic/platform=visionOS'
		;;
	watchos)
		printf 'generic/platform=watchOS'
		;;
	tvos)
		printf 'generic/platform=tvOS'
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
	if [[ "$platform" == "watchos" ]]; then
		if ((archive)); then
			echo "archive validation is not supported for standalone watchOS" >&2
			exit 2
		fi
		scheme="ContextPanelWatch"
	elif [[ "$platform" == "tvos" ]]; then
		scheme="ContextPanelTV"
	else
		scheme="ContextPanelCompanion"
	fi
	if ((archive)); then
		archive_path="$derived_data_path/$scheme-$configuration.xcarchive"
		echo "Validating $scheme archive for $destination"
		rm -rf "$archive_path"
		run_xcodebuild \
			-project ContextPanel.xcodeproj \
			-scheme "$scheme" \
			-configuration "$configuration" \
			-destination "$destination" \
			-derivedDataPath "$derived_data_path" \
			-archivePath "$archive_path" \
			CODE_SIGNING_ALLOWED=NO \
			archive
		validate_archive_contents "$platform" "$archive_path"
	else
		echo "Validating $scheme build for $destination"
		run_xcodebuild \
			-project ContextPanel.xcodeproj \
			-scheme "$scheme" \
			-configuration "$configuration" \
			-destination "$destination" \
			-derivedDataPath "$derived_data_path" \
			CODE_SIGNING_ALLOWED=NO \
			build
	fi
done
