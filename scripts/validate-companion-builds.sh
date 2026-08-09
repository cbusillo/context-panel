#!/usr/bin/env bash
set -euo pipefail

scheme="ContextPanelCompanion"
configuration="Debug"
archive=0
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
artifact_cache_root="${CONTEXT_PANEL_ARTIFACT_CACHE_ROOT:-}"
derived_data_root=""
platforms=()
companion_cache_helper="$repo_root/scripts/context-panel-companion-cache.sh"
cleanup_roots=()
active_xcodebuild_pid=""
active_xcodebuild_process_group=""

artifact_cache_root_is_available() {
	local cache_parent cache_namespace
	cache_parent="$(dirname "$artifact_cache_root")"
	cache_namespace="$(dirname "$cache_parent")"
	[[ -d "$artifact_cache_root" || -d "$cache_namespace" ]]
}

checkout_cache_key() {
	local digest
	command -v shasum >/dev/null 2>&1 || return 1
	digest="$(
		printf '%s\0' "$repo_root" |
			shasum -a 256 |
			awk '{ print substr($1, 1, 16) }'
	)" || return 1
	[[ "$digest" =~ ^[0-9a-f]{16}$ ]] || return 1
	printf '%s' "$digest"
}

default_derived_data_root() {
	local cache_key
	if [[ -n "${CONTEXT_PANEL_COMPANION_DERIVED_DATA_ROOT:-}" ]]; then
		printf '%s' "$CONTEXT_PANEL_COMPANION_DERIVED_DATA_ROOT"
	elif [[ -n "$artifact_cache_root" ]] && artifact_cache_root_is_available; then
		if cache_key="$(checkout_cache_key)"; then
			printf '%s' "$artifact_cache_root/checkouts/$cache_key/derived-data/companion-build-validation"
		else
			printf '%s' "$repo_root/.build/companion-build-validation"
		fi
	else
		printf '%s' "$repo_root/.build/companion-build-validation"
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
  --derived-data-root PATH    DerivedData root. Default: checkout-scoped artifact cache when mounted,
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

finalize_companion_validation() {
	local original_status=$?
	local cleanup_status=0 root root_status
	trap - EXIT
	trap '' HUP INT TERM

	for root in "${cleanup_roots[@]}"; do
		set +e
		"$companion_cache_helper" quarantine --root "$root"
		root_status=$?
		set -e
		if ((root_status != 0 && cleanup_status == 0)); then
			cleanup_status="$root_status"
		fi
	done

	if ((original_status != 0)); then
		if ((cleanup_status != 0)); then
			echo "companion cache cleanup also failed with status $cleanup_status; preserving validation status $original_status" >&2
		fi
		exit "$original_status"
	fi
	if ((cleanup_status != 0)); then
		exit "$cleanup_status"
	fi
	exit 0
}

handle_validation_signal() {
	local signal_status="$1"
	if [[ -n "$active_xcodebuild_pid" && -n "$active_xcodebuild_process_group" ]]; then
		terminate_xcodebuild_job "$active_xcodebuild_pid" "$active_xcodebuild_process_group" || true
	fi
	exit "$signal_status"
}

clear_active_xcodebuild_job() {
	active_xcodebuild_pid=""
	active_xcodebuild_process_group=""
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

xcodebuild_descendant_pids() {
	local child_pid
	local parent_pid="$1"

	for child_pid in $(/usr/bin/pgrep -P "$parent_pid" 2>/dev/null || true); do
		xcodebuild_descendant_pids "$child_pid"
		printf '%s\n' "$child_pid"
	done
}

xcodebuild_processes_are_alive() {
	local descendant_pids="$3"
	local job_pid="$1"
	local process_group="$2"
	local process_pid

	if /bin/kill -0 "$job_pid" 2>/dev/null || /bin/kill -0 "-$process_group" 2>/dev/null; then
		return 0
	fi
	for process_pid in $descendant_pids; do
		if /bin/kill -0 "$process_pid" 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

signal_xcodebuild_processes() {
	local descendant_pids="$3"
	local process_group="$2"
	local process_pid
	local signal_name="$1"

	for process_pid in $descendant_pids; do
		/bin/kill -"$signal_name" "$process_pid" 2>/dev/null || true
	done
	/bin/kill -"$signal_name" "-$process_group" 2>/dev/null || true
}

terminate_xcodebuild_job() {
	local job_pid="$1"
	local process_group="$2"
	local attempt
	local descendant_pids
	local remaining_descendants

	descendant_pids="$(xcodebuild_descendant_pids "$job_pid")"
	signal_xcodebuild_processes TERM "$process_group" "$descendant_pids"
	for ((attempt = 0; attempt < 5; attempt++)); do
		if ! xcodebuild_processes_are_alive "$job_pid" "$process_group" "$descendant_pids"; then
			wait "$job_pid" 2>/dev/null || true
			return 0
		fi
		/bin/sleep 1
	done

	remaining_descendants="$(xcodebuild_descendant_pids "$job_pid")"
	descendant_pids="$descendant_pids $remaining_descendants"
	signal_xcodebuild_processes KILL "$process_group" "$descendant_pids"
	for ((attempt = 0; attempt < 5; attempt++)); do
		if ! xcodebuild_processes_are_alive "$job_pid" "$process_group" "$descendant_pids"; then
			wait "$job_pid" 2>/dev/null || true
			return 0
		fi
		/bin/sleep 1
	done

	echo "xcodebuild validation process did not exit after SIGKILL" >&2
	return 1
}

wait_for_xcodebuild_exit() {
	local job_pid="$1"
	local attempt

	for ((attempt = 0; attempt < 5; attempt++)); do
		if ! /bin/kill -0 "$job_pid" 2>/dev/null; then
			wait "$job_pid" 2>/dev/null || true
			return 0
		fi
		/bin/sleep 1
	done
	return 1
}

run_xcodebuild() {
	local action_count=0
	local current_log_size
	local deadline
	local job_pid
	local last_log_size=0
	local last_output_at
	local log_file
	local marker
	local monitor_was_enabled=0
	local process_group
	local status

	marker="** BUILD SUCCEEDED **"
	for argument in "$@"; do
		case "$argument" in
		build)
			action_count=$((action_count + 1))
			;;
		archive)
			action_count=$((action_count + 1))
			marker="** ARCHIVE SUCCEEDED **"
			;;
		esac
	done
	if ((action_count != 1)); then
		echo "xcodebuild validation requires exactly one build or archive action" >&2
		return 2
	fi

	log_file="$(mktemp "${TMPDIR:-/tmp}/context-panel-xcodebuild.XXXXXX")"
	if [[ $- == *m* ]]; then
		monitor_was_enabled=1
	fi
	set -m
	(
		set -o pipefail
		PATH="$(xcodebuild_system_path)" /usr/bin/xcodebuild "$@" 2>&1 |
			/usr/bin/tee "$log_file"
	) &
	job_pid=$!
	process_group="$job_pid"
	active_xcodebuild_pid="$job_pid"
	active_xcodebuild_process_group="$process_group"
	if ((monitor_was_enabled == 0)); then
		set +m
	fi
	deadline=$((SECONDS + 30 * 60))
	last_output_at=$SECONDS

	while /bin/kill -0 "$job_pid" 2>/dev/null; do
		if /usr/bin/tail -n 500 "$log_file" | /usr/bin/grep -Fq "$marker"; then
			if wait_for_xcodebuild_exit "$job_pid"; then
				clear_active_xcodebuild_job
				/bin/rm -f "$log_file"
				return 0
			fi
			if ! terminate_xcodebuild_job "$job_pid" "$process_group"; then
				clear_active_xcodebuild_job
				/bin/rm -f "$log_file"
				return 1
			fi
			clear_active_xcodebuild_job
			/bin/rm -f "$log_file"
			return 0
		fi
		if /usr/bin/tail -n 500 "$log_file" | /usr/bin/grep -Eq '\*\* (BUILD|ARCHIVE) FAILED \*\*'; then
			terminate_xcodebuild_job "$job_pid" "$process_group" || true
			clear_active_xcodebuild_job
			/bin/rm -f "$log_file"
			return 1
		fi
		current_log_size="$(/usr/bin/stat -f %z "$log_file" 2>/dev/null || printf '0')"
		if [[ "$current_log_size" != "$last_log_size" ]]; then
			last_log_size="$current_log_size"
			last_output_at=$SECONDS
		elif ((SECONDS - last_output_at >= 5 * 60)); then
			echo "xcodebuild produced no output for 5 minutes" >&2
			terminate_xcodebuild_job "$job_pid" "$process_group" || true
			clear_active_xcodebuild_job
			/bin/rm -f "$log_file"
			return 124
		fi
		if ((SECONDS >= deadline)); then
			echo "xcodebuild did not reach a terminal result within 30 minutes" >&2
			terminate_xcodebuild_job "$job_pid" "$process_group" || true
			clear_active_xcodebuild_job
			/bin/rm -f "$log_file"
			return 124
		fi
		/bin/sleep 1
	done

	status=0
	wait "$job_pid" || status=$?
	clear_active_xcodebuild_job
	if /usr/bin/tail -n 500 "$log_file" | /usr/bin/grep -Fq "$marker"; then
		/bin/rm -f "$log_file"
		return 0
	fi
	/bin/rm -f "$log_file"
	return "$status"
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
		if ! /usr/bin/plutil -extract UIRequiredDeviceCapabilities json -o - "$top_shelf_path/Info.plist" 2>/dev/null |
			/usr/bin/grep -q '"arm64"'; then
			echo "tvOS Top Shelf extension is missing the required arm64 device capability" >&2
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

validate_platform() {
	local archive_path
	local derived_data_path="$2"
	local destination
	local platform="$1"
	local scheme

	destination="$(destination_for_platform "$platform")"
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
			archive || return $?
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
			build || return $?
	fi
}

require_command xcodegen
require_command xcodebuild
require_command "$companion_cache_helper"

"$companion_cache_helper" validate-root --root "$derived_data_root"
cleanup_roots+=("$derived_data_root")
trap finalize_companion_validation EXIT
trap 'handle_validation_signal 129' HUP
trap 'handle_validation_signal 130' INT
trap 'handle_validation_signal 143' TERM

xcodegen generate --spec project.yml
echo "companion validation DerivedData root: $derived_data_root"

for platform in "${platforms[@]}"; do
	derived_data_path="$derived_data_root/$platform"
	status=0
	if validate_platform "$platform" "$derived_data_path"; then
		continue
	else
		status=$?
	fi
	if ((status != 124)); then
		exit "$status"
	fi

	retry_parent="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/context-panel-companion-retry.XXXXXX")"
	retry_root="$retry_parent/derived-data/companion-build-validation"
	/bin/mkdir -p "${retry_root%/*}"
	"$companion_cache_helper" validate-root --root "$retry_root"
	cleanup_roots+=("$retry_root")
	retry_derived_data_path="$retry_root/$platform"
	echo "Retrying $platform validation once with isolated DerivedData: $retry_derived_data_path" >&2
	/bin/sleep 2
	if validate_platform "$platform" "$retry_derived_data_path"; then
		continue
	else
		status=$?
	fi
	exit "$status"
done
