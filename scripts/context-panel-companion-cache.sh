#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
artifact_cache_root="${CONTEXT_PANEL_ARTIFACT_CACHE_ROOT:-}"
companion_derived_data_root="${CONTEXT_PANEL_COMPANION_DERIVED_DATA_ROOT:-}"
command_name="${1:-}"
requested_root=""

usage() {
	cat <<'USAGE'
Usage: scripts/context-panel-companion-cache.sh <command> [--root PATH]

Commands:
  preflight      Read-only scan. Exits nonzero when generated companion bundles remain.
  quarantine     Move generated bundle roots to a same-volume quarantine. Requires --root.
  validate-root  Validate one companion-build-validation root without scanning it.

Options:
  --root PATH    Exact .build/companion-build-validation or
                 derived-data/companion-build-validation root.
  -h, --help     Show this help.
USAGE
}

if [[ -z "$command_name" ]]; then
	usage >&2
	exit 2
fi
shift

while [[ $# -gt 0 ]]; do
	case "$1" in
	--root)
		requested_root="${2:?--root requires a value}"
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

case "$command_name" in
preflight | quarantine | validate-root) ;;
*)
	echo "unknown command: $command_name" >&2
	usage >&2
	exit 2
	;;
esac

if [[ "$command_name" != "preflight" && -z "$requested_root" ]]; then
	echo "$command_name requires --root" >&2
	exit 2
fi

root_validation_error() {
	printf 'companion-cache root rejected: %s\n' "$1" >&2
	return 2
}

expected_physical_path() {
	local alias path="$1" physical_alias
	for alias in /var /tmp; do
		if [[ -L "$alias" && ("$path" == "$alias" || "$path" == "$alias"/*) ]]; then
			physical_alias="$(cd "$alias" && /bin/pwd -P)" || return 1
			printf '%s%s\n' "$physical_alias" "${path#"$alias"}"
			return 0
		fi
	done
	printf '%s\n' "$path"
}

validated_root() {
	local input="$1"
	local component expected_probe parent parent_name physical_container physical_parent physical_probe physical_root probe root_name suffix

	if [[ -z "$input" || "$input" != /* || "$input" == "/" ]]; then
		root_validation_error "path must be a non-root absolute path"
		return $?
	fi
	if [[ "$input" == *$'\n'* || "$input" == */../* || "$input" == */./* || "$input" == */.. || "$input" == */. ]]; then
		root_validation_error "path must not contain traversal or newline components"
		return $?
	fi
	while [[ "$input" != "/" && "$input" == */ ]]; do
		input="${input%/}"
	done
	root_name="${input##*/}"
	parent="${input%/*}"
	parent_name="${parent##*/}"
	if [[ "$root_name" != "companion-build-validation" ]]; then
		root_validation_error "final component must be companion-build-validation"
		return $?
	fi
	if [[ -z "$parent" || "$parent" == "/" || ("$parent_name" != ".build" && "$parent_name" != "derived-data") ]]; then
		root_validation_error "root must be contained by .build or derived-data"
		return $?
	fi
	if [[ -L "$input" ]]; then
		root_validation_error "root must not be a symbolic link"
		return $?
	fi
	if [[ -e "$input" && ! -d "$input" ]]; then
		root_validation_error "root must be a directory when present"
		return $?
	fi
	probe="$parent"
	suffix=""
	while [[ ! -d "$probe" ]]; do
		if [[ -z "$probe" || -e "$probe" || -L "$probe" || "$probe" == "/" ]]; then
			root_validation_error "root ancestry must contain only directories"
			return $?
		fi
		component="${probe##*/}"
		suffix="/$component$suffix"
		probe="${probe%/*}"
	done
	if [[ -L "$probe" ]]; then
		root_validation_error "root ancestry must not contain symbolic links"
		return $?
	fi
	physical_probe="$(cd "$probe" && /bin/pwd -P)" || {
		root_validation_error "root ancestry cannot be resolved"
		return $?
	}
	expected_probe="$(expected_physical_path "$probe")" || {
		root_validation_error "root ancestry cannot be normalized"
		return $?
	}
	if [[ "$physical_probe" != "$expected_probe" ]]; then
		root_validation_error "root ancestry must not traverse symbolic links"
		return $?
	fi
	physical_parent="$physical_probe$suffix"
	physical_container="${physical_parent%/*}"
	if [[ -z "$physical_container" || "$physical_container" == "/" ]]; then
		root_validation_error "root must not be contained directly beneath the filesystem root"
		return $?
	fi
	if [[ -d "$input" ]]; then
		physical_root="$(cd "$input" && /bin/pwd -P)" || {
			root_validation_error "root cannot be resolved"
			return $?
		}
		if [[ "$physical_root" != "$physical_parent/companion-build-validation" ]]; then
			root_validation_error "resolved root escaped its validated parent"
			return $?
		fi
	fi
	printf '%s\n' "$physical_parent/companion-build-validation"
}

default_roots() {
	local path retry_parent root roots=()
	roots+=("$repo_root/.build/companion-build-validation")
	if [[ -n "$companion_derived_data_root" ]]; then
		roots+=("$companion_derived_data_root")
	fi
	if [[ -n "$artifact_cache_root" ]]; then
		roots+=("$artifact_cache_root")
	fi
	roots+=("/Volumes/Developer-Artifacts/github-actions/cache/cbusillo/context-panel")

	for root in "${roots[@]}"; do
		[[ -n "$root" ]] || continue
		if [[ "$root" == */companion-build-validation ]]; then
			[[ -e "$root" || -L "$root" ]] && printf '%s\n' "$root"
			continue
		fi
		path="$root/derived-data/companion-build-validation"
		[[ -e "$path" || -L "$path" ]] && printf '%s\n' "$path"
		for path in "$root"/checkouts/*/derived-data/companion-build-validation; do
			[[ -e "$path" || -L "$path" ]] || continue
			printf '%s\n' "$path"
		done
	done

	for retry_parent in "${RUNNER_TEMP:-}" "${TMPDIR:-/tmp}" /tmp; do
		[[ -n "$retry_parent" ]] || continue
		for path in "$retry_parent"/context-panel-companion-retry.*/derived-data/companion-build-validation; do
			[[ -e "$path" || -L "$path" ]] || continue
			printf '%s\n' "$path"
		done
	done | /usr/bin/awk 'NF && !seen[$0]++'
}

default_legacy_retry_roots() {
	local path platform retry_parent retry_root
	for retry_parent in "${RUNNER_TEMP:-}" "${TMPDIR:-/tmp}" /tmp; do
		[[ -n "$retry_parent" ]] || continue
		for retry_root in "$retry_parent"/context-panel-companion-retry.*; do
			[[ -d "$retry_root" && ! -L "$retry_root" ]] || continue
			for platform in ios visionos watchos tvos; do
				path="$retry_root/$platform"
				[[ -e "$path" || -L "$path" ]] || continue
				printf '%s\n' "$path"
			done
		done
	done | /usr/bin/awk 'NF && !seen[$0]++'
}

validated_legacy_retry_root() {
	local allowed_parent allowed_physical input="$1" parent physical_parent physical_root physical_temp platform retry_name temp_parent trusted=0
	if [[ -z "$input" || "$input" != /* || "$input" == *$'\n'* || "$input" == */../* || "$input" == */./* ]]; then
		root_validation_error "legacy retry path is not a safe absolute path"
		return $?
	fi
	while [[ "$input" != "/" && "$input" == */ ]]; do
		input="${input%/}"
	done
	platform="${input##*/}"
	parent="${input%/*}"
	retry_name="${parent##*/}"
	temp_parent="${parent%/*}"
	case "$platform" in
	ios | visionos | watchos | tvos) ;;
	*)
		root_validation_error "legacy retry path has an unsupported platform"
		return $?
		;;
	esac
	if [[ "$retry_name" != context-panel-companion-retry.?* || ! -d "$input" || -L "$input" || -L "$parent" ]]; then
		root_validation_error "legacy retry path has an unsafe layout"
		return $?
	fi
	physical_temp="$(cd "$temp_parent" && /bin/pwd -P)" || return 2
	for allowed_parent in "${RUNNER_TEMP:-}" "${TMPDIR:-/tmp}" /tmp; do
		[[ -d "$allowed_parent" ]] || continue
		allowed_physical="$(cd "$allowed_parent" && /bin/pwd -P)" || continue
		if [[ "$physical_temp" == "$allowed_physical" ]]; then
			trusted=1
			break
		fi
	done
	if ((trusted == 0)); then
		root_validation_error "legacy retry path is outside trusted temporary roots"
		return $?
	fi
	physical_parent="$(cd "$parent" && /bin/pwd -P)" || return 2
	physical_root="$(cd "$input" && /bin/pwd -P)" || return 2
	if [[ "$physical_parent" != "$physical_temp/$retry_name" || "$physical_root" != "$physical_parent/$platform" ]]; then
		root_validation_error "legacy retry path escaped its temporary root"
		return $?
	fi
	printf '%s\n' "$physical_root"
}

collect_bundles() {
	local root="$1"
	local output="$2"
	local prune_mode="${3:-0}"
	[[ -d "$root" ]] || return 0
	if [[ "$prune_mode" == "1" ]]; then
		if ! /usr/bin/find -P "$root" \
			\( \
			-name 'Context Panel.app' -o \
			-name 'ContextPanelWidgetExtension.appex' -o \
			-name 'ContextPanelCompanionWidgetExtension.appex' -o \
			-name 'ContextPanelRefreshAgent.app' -o \
			-name 'ContextPanelWatchWidgetExtension.appex' -o \
			-name 'ContextPanelTVTopShelfExtension.appex' \
			\) \
			\( -type d -o -type l \) \
			-print0 -prune >>"$output" 2>/dev/null; then
			printf 'companion-cache inventory=FAILED\n' >&2
			return 2
		fi
	else
		if ! /usr/bin/find -P "$root" \
			\( \
			-name 'Context Panel.app' -o \
			-name 'ContextPanelWidgetExtension.appex' -o \
			-name 'ContextPanelCompanionWidgetExtension.appex' -o \
			-name 'ContextPanelRefreshAgent.app' -o \
			-name 'ContextPanelWatchWidgetExtension.appex' -o \
			-name 'ContextPanelTVTopShelfExtension.appex' \
			\) \
			\( -type d -o -type l \) -print0 >>"$output" 2>/dev/null; then
			printf 'companion-cache inventory=FAILED\n' >&2
			return 2
		fi
	fi
}

bundle_classification() {
	case "${1##*/}" in
	'Context Panel.app') printf 'app\n' ;;
	ContextPanelWidgetExtension.appex | ContextPanelCompanionWidgetExtension.appex) printf 'widget\n' ;;
	ContextPanelRefreshAgent.app) printf 'refresh-agent\n' ;;
	ContextPanelWatchWidgetExtension.appex) printf 'watch-widget\n' ;;
	ContextPanelTVTopShelfExtension.appex) printf 'top-shelf\n' ;;
	*) printf 'unknown\n' ;;
	esac
}

bundle_contains_signature_material() {
	local bundle="$1"
	local marker_file
	[[ -L "$bundle" ]] && return 1
	marker_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/context-panel-signature-scan.XXXXXX")" || return 2
	if ! /usr/bin/find -P "$bundle" \
		\( -name embedded.mobileprovision -o -path '*/_CodeSignature/CodeResources' \) \
		-type f -print >"$marker_file" 2>/dev/null; then
		/bin/rm -f "$marker_file"
		return 2
	fi
	if [[ -s "$marker_file" ]]; then
		/bin/rm -f "$marker_file"
		return 0
	fi
	/bin/rm -f "$marker_file"
	return 1
}

neutralize_bundle_tree() {
	local bundle="$1"
	local bundle_inventory candidate
	bundle_inventory="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/context-panel-bundle-neutralize.XXXXXX")" || return 1
	if ! /usr/bin/find -P "$bundle" -depth \
		\( -name '*.app' -o -name '*.appex' \) \
		\( -type d -o -type l \) -print0 >"$bundle_inventory"; then
		/bin/rm -f "$bundle_inventory"
		return 1
	fi
	exec 3<"$bundle_inventory"
	while IFS= read -r -d '' candidate <&3; do
		if [[ -e "$candidate.quarantined" || -L "$candidate.quarantined" ]]; then
			exec 3<&-
			/bin/rm -f "$bundle_inventory"
			return 1
		fi
	done
	exec 3<&-
	exec 3<"$bundle_inventory"
	while IFS= read -r -d '' candidate <&3; do
		if ! /bin/mv "$candidate" "$candidate.quarantined"; then
			exec 3<&-
			/bin/rm -f "$bundle_inventory"
			return 1
		fi
	done
	exec 3<&-
	/bin/rm -f "$bundle_inventory"
}

prepare_quarantine_root() {
	local quarantine_base="$1"
	local physical_base physical_quarantine quarantine_root stamp
	if [[ -L "$quarantine_base" || (-e "$quarantine_base" && ! -d "$quarantine_base") ]]; then
		printf 'companion-cache quarantine=REFUSED unsafe-quarantine-base\n' >&2
		return 3
	fi
	/bin/mkdir -p "$quarantine_base"
	physical_base="$(cd "$quarantine_base" && /bin/pwd -P)" || return 3
	if [[ "$physical_base" != "$quarantine_base" ]]; then
		printf 'companion-cache quarantine=REFUSED escaped-quarantine-base\n' >&2
		return 3
	fi
	stamp="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
	quarantine_root="$(/usr/bin/mktemp -d "$quarantine_base/$stamp.XXXXXX")" || return 3
	physical_quarantine="$(cd "$quarantine_root" && /bin/pwd -P)" || return 3
	if [[ "$physical_quarantine" != "$quarantine_base"/"$stamp".* ]]; then
		printf 'companion-cache quarantine=REFUSED escaped-quarantine-root\n' >&2
		return 3
	fi
	printf '%s\n' "$physical_quarantine"
}

scan_inventory() {
	local inventory="$1"
	local move_inventory="$2"
	shift 2
	local canonical root
	: >"$inventory"
	: >"$move_inventory"
	for root in "$@"; do
		canonical="$(validated_root "$root")" || return $?
		collect_bundles "$canonical" "$inventory"
		collect_bundles "$canonical" "$move_inventory" 1
	done
}

print_inventory_summary() {
	local inventory="$1"
	local prefix="$2"
	local app_count=0 bundle bundle_count=0 classification
	local refresh_count=0 symlink_count=0 top_shelf_count=0 watch_widget_count=0 widget_count=0

	while IFS= read -r -d '' bundle; do
		bundle_count=$((bundle_count + 1))
		[[ -L "$bundle" ]] && symlink_count=$((symlink_count + 1))
		classification="$(bundle_classification "$bundle")"
		case "$classification" in
		app) app_count=$((app_count + 1)) ;;
		widget) widget_count=$((widget_count + 1)) ;;
		refresh-agent) refresh_count=$((refresh_count + 1)) ;;
		watch-widget) watch_widget_count=$((watch_widget_count + 1)) ;;
		top-shelf) top_shelf_count=$((top_shelf_count + 1)) ;;
		esac
	done <"$inventory"

	printf '%s bundles=%d apps=%d widgets=%d refresh-agents=%d watch-widgets=%d top-shelf=%d symlinks=%d\n' \
		"$prefix" "$bundle_count" "$app_count" "$widget_count" "$refresh_count" "$watch_widget_count" "$top_shelf_count" "$symlink_count"
	summary_bundle_count="$bundle_count"
}

inventory="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/context-panel-companion-cache.XXXXXX")"
move_inventory="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/context-panel-companion-moves.XXXXXX")"
cleanup_inventory_files() {
	local status=$?
	trap - EXIT
	/bin/rm -f "$inventory" "$move_inventory" || true
	exit "$status"
}
trap cleanup_inventory_files EXIT

if [[ "$command_name" == "validate-root" ]]; then
	validated_root "$requested_root" >/dev/null
	printf 'companion-cache root=OK\n'
	exit 0
fi

legacy_roots=()
roots=()
legacy_root_count=0
root_count=0
if [[ -n "$requested_root" ]]; then
	roots+=("$requested_root")
	root_count=1
else
	while IFS= read -r root; do
		[[ -n "$root" ]] || continue
		roots+=("$root")
		root_count=$((root_count + 1))
	done < <(default_roots)
	while IFS= read -r root; do
		[[ -n "$root" ]] || continue
		legacy_roots+=("$root")
		legacy_root_count=$((legacy_root_count + 1))
	done < <(default_legacy_retry_roots)
fi

if ((root_count == 0 && legacy_root_count == 0)); then
	printf 'companion-cache preflight=OK roots=0 bundles=0\n'
	exit 0
fi

if ((root_count > 0)); then
	scan_inventory "$inventory" "$move_inventory" "${roots[@]}"
else
	: >"$inventory"
	: >"$move_inventory"
fi
if ((legacy_root_count > 0)); then
	for root in "${legacy_roots[@]}"; do
		canonical_legacy_root="$(validated_legacy_retry_root "$root")"
		collect_bundles "$canonical_legacy_root" "$inventory"
	done
fi

if [[ "$command_name" == "preflight" ]]; then
	scan_root_count=$((root_count + legacy_root_count))
	print_inventory_summary "$inventory" "companion-cache preflight=SCAN roots=$scan_root_count"
	if ((summary_bundle_count > 0)); then
		printf 'companion-cache preflight=FAIL generated validation bundles remain\n' >&2
		exit 1
	fi
	printf 'companion-cache preflight=OK\n'
	exit 0
fi

inspection_error_count=0
protected_count=0
while IFS= read -r -d '' bundle; do
	if bundle_contains_signature_material "$bundle"; then
		protected_count=$((protected_count + 1))
	else
		inspection_status=$?
		if ((inspection_status != 1)); then
			inspection_error_count=$((inspection_error_count + 1))
		fi
	fi
done <"$move_inventory"
if ((inspection_error_count > 0)); then
	printf 'companion-cache quarantine=REFUSED signature-inspection-errors=%d\n' "$inspection_error_count" >&2
	exit 3
fi
if ((protected_count > 0)); then
	printf 'companion-cache quarantine=REFUSED protected-signed-bundles=%d\n' "$protected_count" >&2
	exit 3
fi

print_inventory_summary "$inventory" "companion-cache quarantine=SCAN roots=1"
if ((summary_bundle_count == 0)); then
	printf 'companion-cache quarantine=OK moved=0\n'
	exit 0
fi

canonical_root="$(validated_root "$requested_root")"
root_parent="${canonical_root%/*}"
root_container="${root_parent%/*}"
quarantine_base="$root_container/.context-panel-companion-quarantine"
quarantine_root="$(prepare_quarantine_root "$quarantine_base")"
quarantine_id="${quarantine_root##*/}"
trap '' HUP INT TERM

moved_count=0
while IFS= read -r -d '' bundle; do
	relative_path="${bundle#"$canonical_root"/}"
	if [[ "$relative_path" == "$bundle" || "$relative_path" == /* || "$relative_path" == ../* || "$relative_path" == */../* || "$relative_path" == */.. ]]; then
		printf 'companion-cache quarantine=REFUSED candidate escaped validated root\n' >&2
		exit 3
	fi
	if ! neutralize_bundle_tree "$bundle"; then
		printf 'companion-cache quarantine=FAILED bundle-neutralization\n' >&2
		exit 3
	fi
	neutralized_bundle="$bundle.quarantined"
	destination="$quarantine_root/$relative_path.quarantined"
	/bin/mkdir -p "${destination%/*}"
	/bin/mv "$neutralized_bundle" "$destination"
	moved_count=$((moved_count + 1))
done <"$move_inventory"

printf 'companion-cache quarantine=OK moved=%d quarantine=.context-panel-companion-quarantine/%s\n' \
	"$moved_count" "$quarantine_id"
