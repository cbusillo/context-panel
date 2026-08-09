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

validated_root() {
	local input="$1"
	local component parent parent_name physical_parent physical_probe physical_root probe root_name suffix

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
		if [[ -e "$probe" || -L "$probe" || "$probe" == "/" ]]; then
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
	physical_parent="$physical_probe$suffix"
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
	local path root roots=()
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
	done | /usr/bin/awk 'NF && !seen[$0]++'
}

collect_bundles() {
	local root="$1"
	local output="$2"
	local prune_mode="${3:-0}"
	[[ -d "$root" ]] || return 0
	if [[ "$prune_mode" == "1" ]]; then
		/usr/bin/find -P "$root" \
			\( \
			-name 'Context Panel.app' -o \
			-name 'ContextPanelWidgetExtension.appex' -o \
			-name 'ContextPanelCompanionWidgetExtension.appex' -o \
			-name 'ContextPanelRefreshAgent.app' -o \
			-name 'ContextPanelWatchWidgetExtension.appex' -o \
			-name 'ContextPanelTVTopShelfExtension.appex' \
			\) \
			\( -type d -o -type l \) \
			-print0 -prune >>"$output"
	else
		/usr/bin/find -P "$root" \
			\( \
			-name 'Context Panel.app' -o \
			-name 'ContextPanelWidgetExtension.appex' -o \
			-name 'ContextPanelCompanionWidgetExtension.appex' -o \
			-name 'ContextPanelRefreshAgent.app' -o \
			-name 'ContextPanelWatchWidgetExtension.appex' -o \
			-name 'ContextPanelTVTopShelfExtension.appex' \
			\) \
			\( -type d -o -type l \) -print0 >>"$output"
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
	local marker
	[[ -L "$bundle" ]] && return 1
	marker="$(
		/usr/bin/find -P "$bundle" \
			\( -name embedded.mobileprovision -o -path '*/_CodeSignature/CodeResources' \) \
			-type f -print 2>/dev/null | /usr/bin/head -n 1 || true
	)"
	[[ -n "$marker" ]]
}

neutralize_quarantined_bundles() {
	local bundle quarantine_root="$1"
	while IFS= read -r -d '' bundle; do
		/bin/mv "$bundle" "$bundle.quarantined"
	done < <(
		/usr/bin/find -P "$quarantine_root" -depth \
			\( -name '*.app' -o -name '*.appex' \) \
			\( -type d -o -type l \) -print0
	)
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
trap '/bin/rm -f "$inventory" "$move_inventory"' EXIT

if [[ "$command_name" == "validate-root" ]]; then
	validated_root "$requested_root" >/dev/null
	printf 'companion-cache root=OK\n'
	exit 0
fi

roots=()
if [[ -n "$requested_root" ]]; then
	roots+=("$requested_root")
else
	while IFS= read -r root; do
		[[ -n "$root" ]] || continue
		roots+=("$root")
	done < <(default_roots)
fi

if [[ ${#roots[@]} -eq 0 ]]; then
	printf 'companion-cache preflight=OK roots=0 bundles=0\n'
	exit 0
fi

scan_inventory "$inventory" "$move_inventory" "${roots[@]}"

if [[ "$command_name" == "preflight" ]]; then
	print_inventory_summary "$inventory" "companion-cache preflight=SCAN roots=${#roots[@]}"
	if ((summary_bundle_count > 0)); then
		printf 'companion-cache preflight=FAIL generated validation bundles remain\n' >&2
		exit 1
	fi
	printf 'companion-cache preflight=OK\n'
	exit 0
fi

protected_count=0
while IFS= read -r -d '' bundle; do
	if bundle_contains_signature_material "$bundle"; then
		protected_count=$((protected_count + 1))
	fi
done <"$move_inventory"
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
quarantine_id="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
quarantine_root="$root_container/.context-panel-companion-quarantine/$quarantine_id"
/bin/mkdir -p "$quarantine_root"

moved_count=0
while IFS= read -r -d '' bundle; do
	relative_path="${bundle#"$canonical_root"/}"
	if [[ "$relative_path" == "$bundle" || "$relative_path" == /* || "$relative_path" == ../* || "$relative_path" == */../* ]]; then
		printf 'companion-cache quarantine=REFUSED candidate escaped validated root\n' >&2
		exit 3
	fi
	destination="$quarantine_root/$relative_path"
	/bin/mkdir -p "${destination%/*}"
	/bin/mv "$bundle" "$destination"
	moved_count=$((moved_count + 1))
done <"$move_inventory"

neutralize_quarantined_bundles "$quarantine_root"

printf 'companion-cache quarantine=OK moved=%d quarantine=.context-panel-companion-quarantine/%s\n' \
	"$moved_count" "$quarantine_id"
