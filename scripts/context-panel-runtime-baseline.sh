#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="check"
launch_after_reset=0
open_url_after_reset=0
reset_widget_placement=0
include_btm_diagnostics=0
require_production_runtime=0
expected_bookmark_current=""
expected_bookmark_resolvable=""
source_only=0

usage() {
	cat <<'USAGE'
Usage: scripts/context-panel-runtime-baseline.sh [check|install|reset] [--launch] [--open-url] [--reset-widget-placement] [--require-production-runtime] [--expect-bookmark-current <count>] [--expect-bookmark-resolvable <count>]

check  Print a runtime receipt and fail if Context Panel is not isolated to this checkout.
install
       Build this checkout and update /Applications/Context Panel.app in place while preserving
       the user's placed widget and runtime storage. Refuses to replace a Production, TestFlight,
       App Store, or unverified installed runtime.
reset  Build this checkout, clear Context Panel storage, quarantine conflicting bundles, and
       update /Applications/Context Panel.app in place so widget placement is preserved. Refuses
       to replace a Production, TestFlight, App Store, or unverified installed runtime.

--launch    With install or reset, launch the checked-out app after cleanup.
--open-url  With reset, open contextpanel://overview after launch to exercise widget click-through.
--reset-widget-placement
            Also clear WidgetKit/Chrono placement caches. This may remove the widget from the UI.
--btm-diagnostics
            Include sfltool Background Task Management diagnostics. macOS may prompt for a password.
--require-production-runtime
            With check, require Production CloudKit entitlements for the app and refresh agent.
--expect-bookmark-current <count>
            With check, require the refresh agent to report exactly this many current bookmarks.
--expect-bookmark-resolvable <count>
            With check, require the refresh agent to resolve exactly this many bookmarks.

USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	check | install | reset)
		mode="$1"
		shift
		;;
	--launch)
		launch_after_reset=1
		shift
		;;
	--open-url)
		launch_after_reset=1
		open_url_after_reset=1
		shift
		;;
	--reset-widget-placement)
		reset_widget_placement=1
		shift
		;;
	--btm-diagnostics)
		include_btm_diagnostics=1
		shift
		;;
	--require-production-runtime)
		require_production_runtime=1
		shift
		;;
	--expect-bookmark-current)
		if [[ $# -lt 2 || ! "${2:-}" =~ ^[0-9]+$ ]]; then
			echo "--expect-bookmark-current requires a non-negative integer" >&2
			exit 2
		fi
		expected_bookmark_current="$2"
		shift 2
		;;
	--expect-bookmark-resolvable)
		if [[ $# -lt 2 || ! "${2:-}" =~ ^[0-9]+$ ]]; then
			echo "--expect-bookmark-resolvable requires a non-negative integer" >&2
			exit 2
		fi
		expected_bookmark_resolvable="$2"
		shift 2
		;;
	--source-only)
		source_only=1
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

if [[ "$require_production_runtime" == "1" && "$mode" != "check" ]]; then
	echo "--require-production-runtime is only valid with check" >&2
	usage >&2
	exit 2
fi

if [[ "$mode" != "check" && (-n "$expected_bookmark_current" || -n "$expected_bookmark_resolvable") ]]; then
	echo "bookmark count expectations are only valid with check" >&2
	usage >&2
	exit 2
fi

if [[ -n "$expected_bookmark_current" && -z "$expected_bookmark_resolvable" ]] ||
	[[ -z "$expected_bookmark_current" && -n "$expected_bookmark_resolvable" ]]; then
	echo "--expect-bookmark-current and --expect-bookmark-resolvable must be used together" >&2
	usage >&2
	exit 2
fi

derived_data_path="$repo_root/.build/runtime-baseline-derived-data"
built_app_path="$derived_data_path/Build/Products/Debug/Context Panel.app"
built_widget_path="$built_app_path/Contents/PlugIns/ContextPanelWidgetExtension.appex"
built_refresh_agent_path="$built_app_path/Contents/Library/LoginItems/ContextPanelRefreshAgent.app"
artifact_cache_root="${CONTEXT_PANEL_ARTIFACT_CACHE_ROOT:-}"
companion_derived_data_root="${CONTEXT_PANEL_COMPANION_DERIVED_DATA_ROOT:-}"
app_path="/Applications/Context Panel.app"
widget_path="$app_path/Contents/PlugIns/ContextPanelWidgetExtension.appex"
refresh_agent_path="$app_path/Contents/Library/LoginItems/ContextPanelRefreshAgent.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
user_id="$(id -u)"
expected_fingerprint="$("${repo_root}/scripts/context-panel-build-fingerprint.sh" 2>/dev/null || true)"
canonical_app_group="MM5YXC7T6E.group.com.shinycomputers.contextpanel"
legacy_app_group="group.com.shinycomputers.contextpanel"
developer_team_id="MM5YXC7T6E"
developer_signing_identity=""

failures=0

note() { printf '%s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }
fail() {
	printf 'FAIL: %s\n' "$*"
	failures=$((failures + 1))
}
ok() { printf 'OK: %s\n' "$*"; }

run_with_timeout() {
	local seconds="$1"
	shift
	local stdout stderr pid waited status
	stdout="$(mktemp)"
	stderr="$(mktemp)"
	"$@" >"$stdout" 2>"$stderr" &
	pid=$!
	waited=0
	while kill -0 "$pid" >/dev/null 2>&1; do
		if ((waited >= seconds)); then
			kill "$pid" >/dev/null 2>&1 || true
			sleep 1
			kill -9 "$pid" >/dev/null 2>&1 || true
			cat "$stdout" "$stderr"
			rm -f "$stdout" "$stderr"
			return 124
		fi
		sleep 1
		waited=$((waited + 1))
	done
	set +e
	wait "$pid"
	status=$?
	set -e
	cat "$stdout" "$stderr"
	rm -f "$stdout" "$stderr"
	return "$status"
}

has_wrapping_quotes() {
	local value="$1"
	[[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]
}

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		fail "required command not found: $1"
		return 1
	fi
}

resolve_developer_signing_identity() {
	if [[ -n "${CONTEXT_PANEL_CODESIGN_IDENTITY:-}" ]]; then
		printf '%s\n' "$CONTEXT_PANEL_CODESIGN_IDENTITY"
		return 0
	fi
	local identity subject
	while IFS= read -r identity; do
		[[ -n "$identity" ]] || continue
		subject="$(security find-certificate -c "$identity" -p 2>/dev/null |
			openssl x509 -noout -subject 2>/dev/null || true)"
		if [[ "$subject" =~ OU[[:space:]]*=[[:space:]]*${developer_team_id}([^[:alnum:]]|$) ]]; then
			printf '%s\n' "$identity"
			return 0
		fi
	done < <(
		security find-identity -v -p codesigning 2>/dev/null |
			sed -n 's/^.*"\(Apple Development:[^"]*\)".*$/\1/p'
	)
}

plist_value() {
	local plist="$1"
	local key="$2"
	/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

active_context_processes() {
	ps axww -o pid=,command= |
		awk '
				$0 ~ /\/Context Panel\.app\/Contents\/MacOS\/Context Panel$/ ||
				$0 ~ /\/ContextPanelRefreshAgent\.app\/Contents\/MacOS\/ContextPanelRefreshAgent$/ ||
				$0 ~ /\/ContextPanelWidgetExtension\.appex\/Contents\/MacOS\/ContextPanelWidgetExtension$/ ||
				$0 ~ /\/ContextPanelApp$/ ||
				$0 ~ /\/ContextPanelPreview$/ {
				sub(/^[[:space:]]+/, "")
				print
			}
		' || true
}

context_files() {
	local roots=()
	roots+=("$HOME/Library/Group Containers/MM5YXC7T6E.group.com.shinycomputers.contextpanel")
	roots+=("$HOME/Library/Containers/com.shinycomputers.contextpanel")
	roots+=("$HOME/Library/Containers/com.shinycomputers.contextpanel.widget")
	roots+=("$HOME/Library/Containers/com.shinycomputers.contextpanel.refresh-agent")
	roots+=("$HOME/Library/Application Support/Context Panel")

	local root
	for root in "${roots[@]}"; do
		[[ -e "$root" ]] || continue
		find "$root" -maxdepth 12 \
			\( -name accounts.json -o -name file-bookmarks.json -o -name current-snapshot.json -o -name history.json -o -name background-refresh-settings.json -o -name reset-expiry-refresh-state.json -o -name limit-warning-settings.json -o -name limit-warning-state.json -o -name limit-warning-pending-notifications.json -o -name webhook-settings.json -o -name webhook-delivery-state.json \) \
			-print 2>/dev/null || true
	done
}

non_snapshot_context_files() {
	context_files | grep -v '/Snapshots/current-snapshot\.json$' || true
}

current_snapshot_is_fresh_reset_state() {
	local snapshot="$HOME/Library/Group Containers/$canonical_app_group/Context Panel/Snapshots/current-snapshot.json"
	[[ -f "$snapshot" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	jq -e '
        ((.promptCacheObservations // []) | length) == 0
        and ((.snapshot.limits // []) | length) == 0
        and ((.reports // []) | length) > 0
        and all((.reports // [])[]; .status == "failure")
    ' "$snapshot" >/dev/null 2>&1
}

widget_timeline_files() {
	find "$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/SystemData/com.apple.chrono" -maxdepth 6 \
		-name '*.chrono-timeline' -print 2>/dev/null || true
}

widget_render_cache_files() {
	local root="$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/SystemData/com.apple.chrono"
	find "$root/snapshots/ContextPanelWidget" "$root/timelines/ContextPanelWidget" -maxdepth 1 \
		-name '*.chrono-timeline' -print 2>/dev/null || true
}

widget_active_timeline_files() {
	local root="${1:-$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/SystemData/com.apple.chrono}"
	find "$root/timelines/ContextPanelWidget" -maxdepth 1 \
		-name 'system*.chrono-timeline' ! -name '*----*' -print 2>/dev/null || true
}

widget_timeline_cache_is_current_for_build() {
	local root="$1"
	local reference="$2"
	local reference_mtime path timeline_mtime
	[[ -f "$reference" ]] || return 1
	reference_mtime="$(stat -f %m "$reference" 2>/dev/null)" || return 1
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		timeline_mtime="$(stat -f %m "$path" 2>/dev/null)" || continue
		if ((timeline_mtime >= reference_mtime)); then
			return 0
		fi
	done < <(widget_active_timeline_files "$root")
	return 1
}

widget_placeholder_cache_files() {
	local root="$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/SystemData/com.apple.chrono"
	find "$root/placeholders/ContextPanelWidget" -maxdepth 1 \
		-name '*.chrono-timeline' -print 2>/dev/null || true
}

print_widget_cache_report() {
	local files now path mtime age_seconds bucket family
	files="$1"
	[[ -n "$files" ]] || return 0
	now="$(date +%s)"
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		mtime="$(stat -f %m "$path" 2>/dev/null || printf '0')"
		age_seconds=$((now - mtime))
		bucket="other"
		case "$path" in
		*/snapshots/ContextPanelWidget/*) bucket="snapshot" ;;
		*/timelines/ContextPanelWidget/*) bucket="timeline" ;;
		*/placeholders/ContextPanelWidget/*) bucket="placeholder" ;;
		esac
		family="$(basename "$path" | sed -E 's/^(system[A-Za-z]+).*/\1/')"
		printf '%s age=%ss family=%s %s\n' "$bucket" "$age_seconds" "$family" "$path"
	done <<<"$files"
}

refresh_widget_runtime() {
	pkill -x ContextPanelWidgetExtension >/dev/null 2>&1 || true
	xcrun widgetctl reload all >/dev/null 2>&1 || true
	/usr/bin/swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.shinycomputers.contextpanel.widget-snapshot-updated"), object: nil, userInfo: nil, deliverImmediately: true); Thread.sleep(forTimeInterval: 1)' >/dev/null 2>&1 || true
}

provider_credential_state() {
	local executable="$refresh_agent_path/Contents/MacOS/ContextPanelRefreshAgent"
	if [[ ! -x "$executable" ]]; then
		printf 'Context Panel provider credential check unavailable: missing %s\n' "$executable"
		return 2
	fi

	local output status
	set +e
	output="$(run_with_timeout 10 "$executable" --provider-credentials-present 2>&1)"
	status=$?
	set -e
	printf '%s\n' "$output"
	case "$status" in
	0) return 0 ;;
	10) return 10 ;;
	*) return 2 ;;
	esac
}

bookmark_access_state() {
	local executable="$refresh_agent_path/Contents/MacOS/ContextPanelRefreshAgent"
	if [[ ! -x "$executable" ]]; then
		printf 'Context Panel bookmark access check unavailable: missing %s\n' "$executable"
		return 2
	fi

	local output status
	set +e
	output="$(run_with_timeout 10 "$executable" --bookmark-access-summary 2>&1)"
	status=$?
	set -e
	printf '%s\n' "$output"
	[[ "$status" == "0" ]]
}

verify_bookmark_access_expectations() {
	local summary="$1"
	local total current legacy document_scoped invalid resolvable
	[[ -n "$expected_bookmark_current" ]] || return 0

	if ! total="$(bookmark_summary_count "$summary" total)" ||
		! current="$(bookmark_summary_count "$summary" current)" ||
		! legacy="$(bookmark_summary_count "$summary" legacy)" ||
		! document_scoped="$(bookmark_summary_count "$summary" document-scoped)" ||
		! invalid="$(bookmark_summary_count "$summary" invalid)" ||
		! resolvable="$(bookmark_summary_count "$summary" resolvable)"; then
		fail "bookmark summary did not report every required count"
		return
	fi

	if [[ "$current" == "$expected_bookmark_current" ]]; then
		ok "bookmark current count matches expected value $expected_bookmark_current"
	else
		fail "bookmark current count expected $expected_bookmark_current but found $current"
	fi
	if [[ "$resolvable" == "$expected_bookmark_resolvable" ]]; then
		ok "bookmark resolvable count matches expected value $expected_bookmark_resolvable"
	else
		fail "bookmark resolvable count expected $expected_bookmark_resolvable but found $resolvable"
	fi
	[[ "$total" == "$current" ]] || fail "strict bookmark gate requires total=$total to equal current=$current"
	[[ "$legacy" == "0" ]] || fail "strict bookmark gate found legacy=$legacy"
	[[ "$document_scoped" == "0" ]] || fail "strict bookmark gate found document-scoped=$document_scoped"
	[[ "$invalid" == "0" ]] || fail "strict bookmark gate found invalid=$invalid"
}

bookmark_summary_count() {
	local summary="$1"
	local key="$2"
	if [[ "$summary" =~ (^|[[:space:]])${key}=([0-9]+)($|[[:space:]]) ]]; then
		printf '%s' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

clear_provider_credentials() {
	local executable="$refresh_agent_path/Contents/MacOS/ContextPanelRefreshAgent"
	if [[ ! -x "$executable" ]]; then
		fail "Context Panel provider credential cleanup unavailable: missing $executable"
		return 1
	fi

	local output status
	set +e
	output="$(run_with_timeout 10 "$executable" --clear-provider-credentials 2>&1)"
	status=$?
	set -e
	if [[ -n "$output" ]]; then
		printf '%s\n' "$output"
	fi
	if [[ "$status" == "0" ]]; then
		ok "removed Context Panel provider credentials from Keychain"
	else
		fail "Context Panel provider credential cleanup failed"
		return 1
	fi
}

webhook_credential_state() {
	local executable="$refresh_agent_path/Contents/MacOS/ContextPanelRefreshAgent"
	if [[ ! -x "$executable" ]]; then
		printf 'Context Panel webhook credential check unavailable: missing %s\n' "$executable"
		return 2
	fi

	local output status
	set +e
	output="$(run_with_timeout 10 "$executable" --webhook-credentials-present 2>&1)"
	status=$?
	set -e
	printf '%s\n' "$output"
	case "$status" in
	0) return 0 ;;
	10) return 10 ;;
	*) return 2 ;;
	esac
}

clear_webhook_credentials() {
	local executable="$refresh_agent_path/Contents/MacOS/ContextPanelRefreshAgent"
	if [[ ! -x "$executable" ]]; then
		fail "Context Panel webhook credential cleanup unavailable: missing $executable"
		return 1
	fi

	local output status
	set +e
	output="$(run_with_timeout 10 "$executable" --clear-webhook-credentials 2>&1)"
	status=$?
	set -e
	if [[ -n "$output" ]]; then
		printf '%s\n' "$output"
	fi
	if [[ "$status" == "0" ]]; then
		ok "removed Context Panel webhook credentials from Keychain"
	else
		fail "Context Panel webhook credential cleanup failed"
		return 1
	fi
}

current_snapshot_saved_at() {
	local snapshot="$HOME/Library/Group Containers/$canonical_app_group/Context Panel/Snapshots/current-snapshot.json"
	[[ -f "$snapshot" ]] || return 0
	if command -v jq >/dev/null 2>&1; then
		jq -r '.savedAt // .snapshot.generatedAt // empty' "$snapshot" 2>/dev/null || true
	fi
}

discoverable_bundles() {
	mdfind 'kMDItemCFBundleIdentifier == "com.shinycomputers.contextpanel" || kMDItemCFBundleIdentifier == "com.shinycomputers.contextpanel.widget" || kMDItemCFBundleIdentifier == "com.shinycomputers.contextpanel.refresh-agent"' 2>/dev/null || true
}

local_build_bundles() {
	find_context_panel_bundles "$repo_root/.build"
	artifact_cache_companion_build_validation_bundles
}

artifact_cache_companion_build_validation_root() {
	local path root roots=()
	if [[ -n "$artifact_cache_root" ]]; then
		roots+=("$artifact_cache_root")
	fi
	roots+=("/Volumes/Developer-Artifacts/github-actions/cache/cbusillo/context-panel")
	{
		if [[ -n "$companion_derived_data_root" ]]; then
			printf '%s\n' "$companion_derived_data_root"
		fi
		printf '%s\n' "${roots[@]}" |
			awk 'NF && !seen[$0]++' |
			while IFS= read -r root; do
				printf '%s\n' "$root/derived-data/companion-build-validation"
				for path in "$root"/checkouts/*/derived-data/companion-build-validation; do
					[[ -d "$path" ]] || continue
					printf '%s\n' "$path"
				done
			done
	} | awk 'NF && !seen[$0]++'
}

artifact_cache_companion_build_validation_bundles() {
	local path
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		find_context_panel_bundles "$path"
	done < <(artifact_cache_companion_build_validation_root)
}

find_context_panel_bundles() {
	local root="$1"
	[[ -d "$root" ]] || return 0
	find -L "$root" \( -name 'Context Panel.app' -o -name 'ContextPanelWidgetExtension.appex' -o -name 'ContextPanelRefreshAgent.app' \) -type d -print 2>/dev/null || true
}

plugin_paths() {
	pluginkit -m -v -i com.shinycomputers.contextpanel.widget 2>/dev/null |
		awk -F '\t' '/com\.shinycomputers\.contextpanel\.widget/ { print $NF }' || true
}

unregister_stale_plugin_paths() {
	local plugin
	while IFS= read -r plugin; do
		[[ -n "$plugin" ]] || continue
		case "$plugin" in
		"$widget_path" | "$built_widget_path") ;;
		*) pluginkit -r "$plugin" >/dev/null 2>&1 || true ;;
		esac
	done < <(plugin_paths)
}

url_handler_paths() {
	local scheme="${1:-contextpanel}"
	"$lsregister" -dump 2>/dev/null |
		awk -v scheme="$scheme" '
			/^path:[[:space:]]+/ {
				path = $0
				sub(/^path:[[:space:]]+/, "", path)
				sub(/ \(0x[0-9a-fA-F]+\)$/, "", path)
			}
			index($0, scheme) && path != "" {
				seen[path] = 1
			}
			END {
				for (path in seen) print path
			}
		' || true
}

lsregistered_context_paths() {
	"$lsregister" -dump 2>/dev/null |
		awk '
			/^path:[[:space:]]+/ {
				path = $0
				sub(/^path:[[:space:]]+/, "", path)
				sub(/ \(0x[0-9a-fA-F]+\)$/, "", path)
			}
			/bundle id:[[:space:]]+(com\.shinycomputers\.contextpanel|com\.shinycomputers\.contextpanel\.widget|com\.shinycomputers\.contextpanel\.refresh-agent|Context Panel)$/ && path != "" {
				seen[path] = 1
			}
			END {
				for (path in seen) print path
			}
		' || true
}

unregister_stale_launchservices_paths() {
	local path
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		case "$path" in
		"$app_path" | "$widget_path" | "$refresh_agent_path" | "$built_app_path" | "$built_widget_path" | "$built_refresh_agent_path") ;;
		*) "$lsregister" -u "$path" >/dev/null 2>&1 || true ;;
		esac
	done < <(lsregistered_context_paths)
}

btm_context_entries() {
	if [[ "$include_btm_diagnostics" != "1" ]]; then
		return 0
	fi
	if command -v gtimeout >/dev/null 2>&1; then
		gtimeout 10s sfltool dumpbtm 2>/dev/null | grep -i -C 2 -E 'Context Panel|contextpanel|shinycomputers' || true
	elif command -v timeout >/dev/null 2>&1; then
		timeout 10s sfltool dumpbtm 2>/dev/null | grep -i -C 2 -E 'Context Panel|contextpanel|shinycomputers' || true
	else
		sfltool dumpbtm 2>/dev/null | grep -i -C 2 -E 'Context Panel|contextpanel|shinycomputers' || true
	fi
}

signed_app_groups() {
	local bundle="$1"
	local plist
	plist="$(mktemp)"
	if ! codesign -d --entitlements :- "$bundle" >"$plist" 2>/dev/null; then
		rm -f "$plist"
		return 1
	fi
	/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$plist" 2>/dev/null |
		awk '/^[[:space:]]+[A-Za-z0-9][A-Za-z0-9_.-]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }'
	rm -f "$plist"
}

check_canonical_app_group() {
	local bundle="$1"
	local label="$2"
	local groups
	if ! groups="$(signed_app_groups "$bundle")"; then
		fail "could not read signed app-group entitlements for $label"
		return
	fi
	if rg -qx --fixed-strings "$canonical_app_group" <<<"$groups"; then
		ok "$label is signed for canonical app group"
	else
		printf '%s\n' "$groups"
		fail "$label is missing canonical app group: $canonical_app_group"
	fi
	if rg -qx --fixed-strings "$legacy_app_group" <<<"$groups"; then
		printf '%s\n' "$groups"
		fail "$label still carries legacy app group: $legacy_app_group"
	fi
}

signed_entitlement_enabled() {
	local bundle="$1"
	local entitlement="$2"
	local plist value
	plist="$(mktemp)"
	if ! codesign -d --entitlements :- "$bundle" >"$plist" 2>/dev/null; then
		rm -f "$plist"
		return 2
	fi
	value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$plist" 2>/dev/null || true)"
	rm -f "$plist"
	[[ "$value" == "true" ]]
}

signed_entitlement_present() {
	local bundle="$1"
	local entitlement="$2"
	local plist value
	plist="$(mktemp)"
	if ! codesign -d --entitlements :- "$bundle" >"$plist" 2>/dev/null; then
		rm -f "$plist"
		return 2
	fi
	value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$plist" 2>/dev/null || true)"
	rm -f "$plist"
	[[ -n "$value" ]]
}

check_entitlement_enabled() {
	local bundle="$1"
	local label="$2"
	local entitlement="$3"
	local required_for="$4"
	if signed_entitlement_enabled "$bundle" "$entitlement"; then
		ok "$label has $entitlement for $required_for"
	else
		fail "$label is missing $entitlement required for $required_for"
	fi
}

check_entitlement_absent() {
	local bundle="$1"
	local label="$2"
	local entitlement="$3"
	local status
	set +e
	signed_entitlement_present "$bundle" "$entitlement"
	status=$?
	set -e
	case "$status" in
	0)
		fail "$label unexpectedly has $entitlement"
		;;
	1)
		ok "$label does not have $entitlement"
		;;
	*)
		fail "could not read signed entitlements for $label"
		;;
	esac
}

signed_team_identifier() {
	local bundle="$1"
	codesign -dv --verbose=4 "$bundle" 2>&1 |
		awk -F= '/^TeamIdentifier=/ { print $2; exit }'
}

plist_scalar_value() {
	local plist="$1"
	local key_path="$2"
	/usr/libexec/PlistBuddy -c "Print :$key_path" "$plist" 2>/dev/null || true
}

plist_array_values() {
	local plist="$1"
	local key_path="$2"
	/usr/libexec/PlistBuddy -c "Print :$key_path" "$plist" 2>/dev/null |
		awk '/^[[:space:]]+[^{}[:space:]][^{}]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' || true
}

plist_array_contains_value() {
	local plist="$1"
	local key_path="$2"
	local expected="$3"
	rg -qx --fixed-strings "$expected" <<<"$(plist_array_values "$plist" "$key_path")"
}

profile_entitlement_value() {
	local profile_plist="$1"
	local entitlement="$2"
	plist_scalar_value "$profile_plist" "Entitlements:$entitlement"
}

profile_entitlement_authorizes_value() {
	local profile_plist="$1"
	local entitlement="$2"
	local expected="$3"
	local profile_value value wildcard_prefix
	profile_value="$(profile_entitlement_value "$profile_plist" "$entitlement")"
	if [[ "$profile_value" == "$expected" || "$profile_value" == "*" ]]; then
		return 0
	fi
	while IFS= read -r value; do
		[[ -n "$value" ]] || continue
		if [[ "$value" == "$expected" || "$value" == "*" ]]; then
			return 0
		fi
		if [[ "$value" == *"*" ]]; then
			wildcard_prefix="${value%\*}"
			if [[ -n "$wildcard_prefix" && "$expected" == "$wildcard_prefix"* ]]; then
				return 0
			fi
		fi
	done < <(plist_array_values "$profile_plist" "Entitlements:$entitlement")
	return 1
}

signed_entitlement_value() {
	local entitlements_plist="$1"
	local entitlement="$2"
	plist_scalar_value "$entitlements_plist" "$entitlement"
}

signed_entitlement_array_values() {
	local entitlements_plist="$1"
	local entitlement="$2"
	plist_array_values "$entitlements_plist" "$entitlement"
}

check_profile_authorizes_scalar_entitlement() {
	local profile_plist="$1"
	local entitlements_plist="$2"
	local label="$3"
	local entitlement="$4"
	local expected profile_value value
	expected="$(signed_entitlement_value "$entitlements_plist" "$entitlement")"
	[[ -n "$expected" ]] || return 0
	profile_value="$(profile_entitlement_value "$profile_plist" "$entitlement")"
	if [[ "$profile_value" == "$expected" || "$profile_value" == "*" ]]; then
		return 0
	fi
	while IFS= read -r value; do
		if [[ "$value" == "$expected" ]]; then
			return 0
		fi
	done < <(plist_array_values "$profile_plist" "Entitlements:$entitlement")
	fail "$label provisioning profile does not authorize $entitlement: $expected"
	return 1
}

check_profile_authorizes_array_entitlement() {
	local profile_plist="$1"
	local entitlements_plist="$2"
	local label="$3"
	local entitlement="$4"
	local value missing=0
	while IFS= read -r value; do
		[[ -n "$value" ]] || continue
		if ! profile_entitlement_authorizes_value "$profile_plist" "$entitlement" "$value"; then
			fail "$label provisioning profile does not authorize $entitlement: $value"
			missing=1
		fi
	done < <(signed_entitlement_array_values "$entitlements_plist" "$entitlement")
	[[ "$missing" == "0" ]]
}

check_profile_plist_covers_entitlements() {
	local profile_plist="$1"
	local entitlements_plist="$2"
	local label="$3"
	local profile_name profile_team signed_team signed_app_id profile_app_id
	local failures_before="$failures"

	if [[ ! -f "$profile_plist" ]]; then
		fail "$label provisioning profile is missing: $profile_plist"
		return 1
	fi
	if [[ ! -f "$entitlements_plist" ]]; then
		fail "$label signed entitlements are missing: $entitlements_plist"
		return 1
	fi

	profile_name="$(plist_scalar_value "$profile_plist" Name)"
	profile_team="$(plist_array_values "$profile_plist" TeamIdentifier | head -n 1)"
	signed_team="$(signed_entitlement_value "$entitlements_plist" com.apple.developer.team-identifier)"
	signed_app_id="$(signed_entitlement_value "$entitlements_plist" com.apple.application-identifier)"
	[[ -n "$signed_app_id" ]] || signed_app_id="$(signed_entitlement_value "$entitlements_plist" application-identifier)"
	profile_app_id="$(profile_entitlement_value "$profile_plist" com.apple.application-identifier)"
	[[ -n "$profile_app_id" ]] || profile_app_id="$(profile_entitlement_value "$profile_plist" application-identifier)"

	if [[ -z "$profile_name" ]]; then
		fail "$label provisioning profile has no Name"
	fi
	if [[ -n "$signed_team" && "$profile_team" != "$signed_team" ]]; then
		fail "$label provisioning profile team ${profile_team:-unknown} does not match signed team $signed_team"
	fi
	if [[ -n "$signed_app_id" && "$profile_app_id" != "$signed_app_id" ]]; then
		fail "$label provisioning profile does not authorize application identifier: $signed_app_id"
	fi

	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements_plist" "$label" "com.apple.security.application-groups" || true
	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements_plist" "$label" "keychain-access-groups" || true
	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements_plist" "$label" "com.apple.developer.icloud-container-identifiers" || true
	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements_plist" "$label" "com.apple.developer.icloud-services" || true
	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements_plist" "$label" "com.apple.developer.ubiquity-container-identifiers" || true
	check_profile_authorizes_scalar_entitlement "$profile_plist" "$entitlements_plist" "$label" "com.apple.developer.icloud-container-environment" || true
	check_profile_authorizes_scalar_entitlement "$profile_plist" "$entitlements_plist" "$label" "com.apple.developer.team-identifier" || true

	if [[ "$failures" == "$failures_before" ]]; then
		ok "$label provisioning profile covers signed entitlements${profile_name:+: $profile_name}"
		return 0
	fi
	return 1
}

decode_provisioning_profile() {
	local profile="$1"
	local output="$2"
	security cms -D -i "$profile" >"$output" 2>/dev/null
}

signed_entitlements_plist() {
	local bundle="$1"
	local output="$2"
	codesign -d --entitlements :- "$bundle" >"$output" 2>/dev/null
}

bundle_cloudkit_environment() {
	local bundle="$1"
	local entitlements value
	if [[ ! -e "$bundle" ]]; then
		printf 'absent\n'
		return 0
	fi
	entitlements="$(mktemp)"
	if ! signed_entitlements_plist "$bundle" "$entitlements"; then
		rm -f "$entitlements"
		printf 'unreadable\n'
		return 0
	fi
	value="$(signed_entitlement_value "$entitlements" "com.apple.developer.icloud-container-environment")"
	rm -f "$entitlements"
	if [[ -n "$value" ]]; then
		printf '%s\n' "$value"
	else
		printf 'unknown\n'
	fi
}

bundle_beta_reports_active() {
	local bundle="$1"
	local entitlements value
	if [[ ! -e "$bundle" ]]; then
		printf 'absent\n'
		return 0
	fi
	entitlements="$(mktemp)"
	if ! signed_entitlements_plist "$bundle" "$entitlements"; then
		rm -f "$entitlements"
		printf 'unreadable\n'
		return 0
	fi
	value="$(signed_entitlement_value "$entitlements" "beta-reports-active")"
	rm -f "$entitlements"
	if [[ "$value" == "true" ]]; then
		printf 'true\n'
	else
		printf 'false\n'
	fi
}

bundle_store_receipt_status() {
	local bundle="$1"
	if [[ -f "$bundle/Contents/_MASReceipt/receipt" ]]; then
		printf 'present\n'
	else
		printf 'absent\n'
	fi
}

runtime_distribution_identity() {
	local cloudkit_environment="$1"
	local beta_reports_active="$2"
	local store_receipt="$3"
	if [[ "$cloudkit_environment" == "absent" ]]; then
		printf 'absent\n'
	elif [[ "$beta_reports_active" == "true" ]]; then
		printf 'testflight\n'
	elif [[ "$store_receipt" == "present" ]]; then
		printf 'app-store\n'
	elif [[ "$cloudkit_environment" == "Production" ]]; then
		printf 'production-signed\n'
	elif [[ "$cloudkit_environment" == "Development" ]]; then
		printf 'development\n'
	elif [[ "$cloudkit_environment" == "unreadable" ]]; then
		printf 'unreadable\n'
	else
		printf 'unknown\n'
	fi
}

guard_installed_runtime_replacement() {
	local installed_app="${1:-$app_path}"
	local installed_refresh_agent="${2:-$refresh_agent_path}"
	local app_environment refresh_environment beta_reports_active store_receipt distribution reason

	section "Runtime Replacement Guard"
	if [[ ! -e "$installed_app" ]]; then
		ok "no existing canonical app will be replaced"
		return 0
	fi

	app_environment="$(bundle_cloudkit_environment "$installed_app")"
	refresh_environment="$(bundle_cloudkit_environment "$installed_refresh_agent")"
	beta_reports_active="$(bundle_beta_reports_active "$installed_app")"
	store_receipt="$(bundle_store_receipt_status "$installed_app")"
	distribution="$(runtime_distribution_identity "$app_environment" "$beta_reports_active" "$store_receipt")"
	note "app-cloudkit=$app_environment"
	note "refresh-agent-cloudkit=$refresh_environment"
	note "distribution=$distribution"
	note "beta-reports-active=$beta_reports_active"
	note "app-store-receipt=$store_receipt"

	reason=""
	if [[ "$beta_reports_active" == "true" ]]; then
		reason="the installed app is a TestFlight runtime"
	elif [[ "$store_receipt" == "present" ]]; then
		reason="the installed app has an App Store receipt"
	elif [[ "$beta_reports_active" == "unreadable" ]]; then
		reason="the installed app's beta entitlement cannot be verified"
	elif [[ "$app_environment" == "Production" ]]; then
		reason="the installed app uses Production CloudKit"
	elif [[ "$refresh_environment" == "Production" ]]; then
		reason="the installed refresh agent uses Production CloudKit"
	elif [[ "$app_environment" != "Development" ]]; then
		reason="the installed app's CloudKit environment is not verified as Development"
	elif [[ "$refresh_environment" != "Development" && "$refresh_environment" != "absent" ]]; then
		reason="the installed refresh agent's CloudKit environment is not verified as Development"
	fi

	if [[ -n "$reason" ]]; then
		fail "refusing to replace $installed_app because $reason"
		note "install and reset build a local Debug runtime that uses Development CloudKit."
		note "For signed companion validation, keep the installed runtime and run:"
		note "  scripts/context-panel-runtime-baseline.sh check --require-production-runtime"
		note "To intentionally return to local development, first remove or relocate the installed app outside this script."
		return 1
	fi

	ok "existing canonical runtime is verified as Development"
}

check_runtime_identity() {
	local installed_app="${1:-$app_path}"
	local installed_refresh_agent="${2:-$refresh_agent_path}"
	local app_environment refresh_environment beta_reports_active store_receipt distribution
	app_environment="$(bundle_cloudkit_environment "$installed_app")"
	refresh_environment="$(bundle_cloudkit_environment "$installed_refresh_agent")"
	beta_reports_active="$(bundle_beta_reports_active "$installed_app")"
	store_receipt="$(bundle_store_receipt_status "$installed_app")"
	distribution="$(runtime_distribution_identity "$app_environment" "$beta_reports_active" "$store_receipt")"

	note "app-cloudkit=$app_environment"
	note "refresh-agent-cloudkit=$refresh_environment"
	note "distribution=$distribution"
	note "beta-reports-active=$beta_reports_active"
	note "app-store-receipt=$store_receipt"

	if [[ "$require_production_runtime" != "1" ]]; then
		return 0
	fi
	if [[ "$app_environment" == "Production" ]]; then
		ok "app uses Production CloudKit"
	else
		fail "app must use Production CloudKit for signed companion validation; found $app_environment"
	fi
	if [[ "$refresh_environment" == "Production" ]]; then
		ok "refresh agent uses Production CloudKit"
	else
		fail "refresh agent must use Production CloudKit for signed companion validation; found $refresh_environment"
	fi
}

check_bundle_cloudkit_environment() {
	local bundle="$1"
	local label="$2"
	local expected="$3"
	local actual
	actual="$(bundle_cloudkit_environment "$bundle")"
	if [[ "$actual" == "$expected" ]]; then
		ok "$label uses $expected CloudKit"
		return 0
	fi
	fail "$label must use $expected CloudKit; found $actual"
	return 1
}

check_bundle_profile_covers_signed_entitlements() {
	local bundle="$1"
	local label="$2"
	local profile="$bundle/Contents/embedded.provisionprofile"
	local profile_plist entitlements_plist status team_id
	if [[ ! -f "$profile" ]]; then
		team_id="$(signed_team_identifier "$bundle")"
		if [[ "$team_id" == "$developer_team_id" ]]; then
			ok "$label has no embedded provisioning profile; signed team authorizes runtime entitlements"
			return 0
		fi
		fail "$label has no embedded provisioning profile for restricted entitlement validation"
		return 1
	fi
	profile_plist="$(mktemp)"
	entitlements_plist="$(mktemp)"
	set +e
	decode_provisioning_profile "$profile" "$profile_plist"
	status=$?
	set -e
	if [[ "$status" != "0" ]]; then
		rm -f "$profile_plist" "$entitlements_plist"
		fail "$label embedded provisioning profile could not be decoded"
		return 1
	fi
	set +e
	signed_entitlements_plist "$bundle" "$entitlements_plist"
	status=$?
	set -e
	if [[ "$status" != "0" ]]; then
		rm -f "$profile_plist" "$entitlements_plist"
		fail "$label signed entitlements could not be read"
		return 1
	fi
	check_profile_plist_covers_entitlements "$profile_plist" "$entitlements_plist" "$label"
	status=$?
	rm -f "$profile_plist" "$entitlements_plist"
	return "$status"
}

preflight_built_runtime_profiles() {
	section "Built Runtime Profile Preflight"
	local failures_before="$failures"
	check_bundle_cloudkit_environment "$built_app_path" "built app" "Development" || true
	check_bundle_cloudkit_environment "$built_refresh_agent_path" "built refresh agent" "Development" || true
	check_bundle_profile_covers_signed_entitlements "$built_app_path" "built app" || true
	check_bundle_profile_covers_signed_entitlements "$built_widget_path" "built widget" || true
	check_bundle_profile_covers_signed_entitlements "$built_refresh_agent_path" "built refresh agent" || true
	if [[ "$failures" != "$failures_before" ]]; then
		return 1
	fi
}

check_canonical_team_identifier() {
	local bundle="$1"
	local label="$2"
	local team_id
	team_id="$(signed_team_identifier "$bundle")"
	if [[ "$team_id" == "$developer_team_id" ]]; then
		ok "$label is signed for canonical team $developer_team_id"
	else
		fail "$label is signed for team ${team_id:-unknown}, expected $developer_team_id"
	fi
}

check_provisioning_profile() {
	local bundle="$1"
	local label="$2"
	local profile="$bundle/Contents/embedded.provisionprofile"
	local plist name teams temp_dir candidate_base64 candidate_der index matched
	if [[ ! -f "$profile" ]]; then
		ok "$label has no embedded provisioning profile"
		return
	fi
	plist="$(mktemp)"
	if ! security cms -D -i "$profile" >"$plist" 2>/dev/null; then
		rm -f "$plist"
		fail "$label embedded provisioning profile could not be decoded"
		return
	fi
	name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$plist" 2>/dev/null || true)"
	teams="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier' "$plist" 2>/dev/null |
		awk '/^[[:space:]]+[A-Za-z0-9]+$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' || true)"
	if [[ -z "$name" ]]; then
		rm -f "$plist"
		fail "$label embedded provisioning profile has no Name"
		return
	fi
	if ! rg -qx --fixed-strings "$developer_team_id" <<<"$teams"; then
		printf '%s\n' "$teams"
		rm -f "$plist"
		fail "$label provisioning profile is not for canonical team $developer_team_id"
		return
	fi

	temp_dir="$(mktemp -d)"
	candidate_base64="$temp_dir/certificate.base64"
	candidate_der="$temp_dir/certificate.der"
	if ! codesign -d --extract-certificates="$temp_dir/signed-certificate" "$bundle" >/dev/null 2>&1; then
		rm -f "$plist"
		rm -rf "$temp_dir"
		fail "$label signing certificate could not be extracted"
		return
	fi
	index=0
	matched=0
	while plutil -extract "DeveloperCertificates.$index" raw -o - "$plist" >"$candidate_base64" 2>/dev/null; do
		if /usr/bin/base64 -D <"$candidate_base64" >"$candidate_der" 2>/dev/null &&
			cmp -s "$temp_dir/signed-certificate0" "$candidate_der"; then
			matched=1
			break
		fi
		index=$((index + 1))
	done
	rm -f "$plist"
	rm -rf "$temp_dir"
	if [[ "$matched" != "1" ]]; then
		fail "$label provisioning profile does not authorize the actual signing certificate"
		return
	fi
	ok "$label provisioning profile: $name"
}

bootout_refresh_agent() {
	launchctl bootout "gui/$user_id/com.shinycomputers.contextpanel.refresh-agent" >/dev/null 2>&1 || true
	pkill -x ContextPanelRefreshAgent >/dev/null 2>&1 || true
}

stop_context_panel() {
	pkill -x 'Context Panel' >/dev/null 2>&1 || true
	pkill -x ContextPanelApp >/dev/null 2>&1 || true
	pkill -x ContextPanelPreview >/dev/null 2>&1 || true
	pkill -x ContextPanelRefreshAgent >/dev/null 2>&1 || true
	pkill -x ContextPanelWidgetExtension >/dev/null 2>&1 || true
	sleep 1
}

quarantine_path() {
	local source="$1"
	local root="$2"
	[[ -e "$source" ]] || return 0
	if [[ "$source" == "$root"/* ]]; then
		return 0
	fi
	local dest="$root/${source#/}"
	mkdir -p "$(dirname "$dest")"
	mv "$source" "$dest"
}

unregister_refresh_agent_with_app() {
	local app="$1"
	[[ -d "$app" ]] || return 0
	run_with_timeout 10 "$app/Contents/MacOS/Context Panel" --unregister-refresh-agent >/dev/null 2>&1 || true
}

unregister_refresh_agent_quietly() {
	# SMAppService unregister has to run from inside the containing app bundle.
	# Keep this to the installed runtime app only; launching old copies can surface
	# macOS login-item prompts and is noisier than the cleanup is worth.
	unregister_refresh_agent_with_app "$app_path"
}

unregister_bundle_tree() {
	local root="$1"
	[[ -d "$root" ]] || return 0
	find "$root" \( -name '*.app' -o -name '*.appex' \) -print0 2>/dev/null |
		while IFS= read -r -d '' bundle; do
			"$lsregister" -u "$bundle" >/dev/null 2>&1 || true
		done || true
}

neutralize_bundle_extensions() {
	local root="$1"
	[[ -d "$root" ]] || return 0
	find "$root" -depth \( -name '*.app' -o -name '*.appex' \) -print0 2>/dev/null |
		while IFS= read -r -d '' bundle; do
			local neutralized
			neutralized="${bundle%.app}.app-quarantined"
			neutralized="${neutralized%.appex}.appex-quarantined"
			mv "$bundle" "$neutralized" 2>/dev/null || true
		done || true
	find "$root" -depth \( -name '*.app.quarantined' -o -name '*.appex.quarantined' \) -print0 2>/dev/null |
		while IFS= read -r -d '' bundle; do
			local neutralized
			neutralized="${bundle/.app.quarantined/.app-quarantined}"
			neutralized="${neutralized/.appex.quarantined/.appex-quarantined}"
			mv "$bundle" "$neutralized" 2>/dev/null || true
		done || true
	find "$root" -path '*/Contents/Info.plist' -print0 2>/dev/null |
		while IFS= read -r -d '' plist; do
			if /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null |
				grep -q '^com\.shinycomputers\.contextpanel'; then
				mv "$plist" "${plist}.quarantined" 2>/dev/null || true
			fi
		done || true
}

remove_prior_baseline_trash() {
	find "$HOME/.Trash" -maxdepth 1 -type d \
		\( -name 'ContextPanel-runtime-baseline-*' -o -name 'ContextPanel-stale-runtime-*' \) \
		-exec rm -rf {} + 2>/dev/null || true
}

build_checkout_app() {
	section "Build Checkout App"
	local fingerprint
	require xcodegen
	require xcodebuild
	require codesign
	require ditto
	require rsync

	xcodegen generate --spec "$repo_root/project.yml"
	xcodebuild \
		-project "$repo_root/ContextPanel.xcodeproj" \
		-scheme ContextPanel \
		-configuration Debug \
		-derivedDataPath "$derived_data_path" \
		-allowProvisioningUpdates \
		build
	fingerprint="$("${repo_root}/scripts/context-panel-build-fingerprint.sh" 2>/dev/null || true)"
	expected_fingerprint="$fingerprint"
	ok "built $built_app_path"
}

install_checkout_app() {
	section "Install Checkout App"
	if [[ ! -d "$built_app_path" ]]; then
		fail "built app is missing: $built_app_path"
		return 1
	fi
	guard_installed_runtime_replacement
	developer_signing_identity="$(resolve_developer_signing_identity)"
	if [[ -z "$developer_signing_identity" ]]; then
		fail "could not find an Apple Development signing identity"
		return 1
	fi
	if [[ -d "$app_path" ]]; then
		rsync -aE --delete "$built_app_path/" "$app_path/"
	else
		ditto "$built_app_path" "$app_path"
	fi
	"$repo_root/scripts/stamp-context-panel-build.sh" "$app_path"
	local entitlements
	entitlements="$(mktemp)"
	if ! codesign -d --entitlements :- "$app_path" >"$entitlements" 2>/dev/null; then
		rm -f "$entitlements"
		fail "could not read installed app entitlements before re-signing"
		return 1
	fi
	if ! /usr/bin/codesign --force --sign "$developer_signing_identity" \
		--entitlements "$entitlements" \
		--timestamp=none \
		--generate-entitlement-der \
		"$app_path" >/dev/null; then
		rm -f "$entitlements"
		fail "could not re-sign installed app after stamping build fingerprint"
		return 1
	fi
	rm -f "$entitlements"
	ok "installed and stamped $app_path"
}

install_runtime() {
	guard_installed_runtime_replacement
	build_checkout_app
	preflight_built_runtime_profiles
	guard_installed_runtime_replacement

	section "Install"
	local stamp quarantine
	stamp="$(date +%Y%m%d-%H%M%S)"
	quarantine="$HOME/.Trash/ContextPanel-runtime-baseline-$stamp"
	remove_prior_baseline_trash
	mkdir -p "$quarantine"

	stop_context_panel
	bootout_refresh_agent
	quarantine_stale_runtime_bundles "$quarantine"
	install_checkout_app
	quarantine_path "$built_app_path" "$quarantine"
	quarantine_path "$derived_data_path/Build/Products/Debug/ContextPanelWidgetExtension.appex" "$quarantine"
	quarantine_path "$derived_data_path/Build/Products/Debug/ContextPanelRefreshAgent.app" "$quarantine"
	neutralize_bundle_extensions "$quarantine"
	"$lsregister" -f -R -trusted "$app_path"
	pluginkit -a "$widget_path" >/dev/null 2>&1 || true
	unregister_refresh_agent_quietly
	bootout_refresh_agent
	refresh_widget_runtime
	note "quarantine=$quarantine"

	if [[ "$launch_after_reset" == "1" ]]; then
		open "$app_path"
		sleep 2
		refresh_widget_runtime
	fi
	if [[ "$open_url_after_reset" == "1" ]]; then
		open 'contextpanel://overview'
		sleep 4
	fi
}

btm_has_enabled_checkout_agent() {
	local btm="$1"
	grep -q "Disposition: \[enabled" <<<"$btm" && grep -q "$app_path" <<<"$btm"
}

is_runtime_or_build_artifact() {
	case "$1" in
	"$app_path" | "$widget_path" | "$refresh_agent_path" | "$built_app_path" | "$built_widget_path" | "$built_refresh_agent_path")
		return 0
		;;
	*)
		return 1
		;;
	esac
}

btm_has_enabled_context_entries() {
	local btm="$1"
	grep -q "Disposition: \[enabled" <<<"$btm"
}

quarantine_stale_runtime_bundles() {
	local quarantine="$1"
	local bundle path
	unregister_stale_plugin_paths
	unregister_stale_launchservices_paths
	while IFS= read -r bundle; do
		[[ -n "$bundle" ]] || continue
		case "$bundle" in
		"$HOME/.Trash"/*) ;;
		*)
			if is_runtime_or_build_artifact "$bundle"; then
				:
			else
				quarantine_path "$bundle" "$quarantine"
			fi
			;;
		esac
	done < <(discoverable_bundles)

	quarantine_path "$repo_root/dist/Context Panel.app" "$quarantine"
	while IFS= read -r -d '' bundle; do
		if is_runtime_or_build_artifact "$bundle"; then
			:
		else
			quarantine_path "$bundle" "$quarantine"
		fi
	done < <(find -L "$repo_root/.build" \( -name 'Context Panel.app' -o -name 'ContextPanelWidgetExtension.appex' -o -name 'ContextPanelRefreshAgent.app' \) -type d -print0 2>/dev/null)
	while IFS= read -r bundle; do
		if is_runtime_or_build_artifact "$bundle"; then
			:
		else
			quarantine_path "$bundle" "$quarantine"
		fi
	done < <(find_context_panel_bundles "$HOME/.code/working/context-panel")
	while IFS= read -r bundle; do
		if is_runtime_or_build_artifact "$bundle"; then
			:
		else
			quarantine_path "$bundle" "$quarantine"
		fi
	done < <(find_context_panel_bundles "$HOME/Library/Developer/Xcode/DerivedData")
	while IFS= read -r bundle; do
		if is_runtime_or_build_artifact "$bundle"; then
			:
		else
			quarantine_path "$bundle" "$quarantine"
		fi
	done < <(find_context_panel_bundles "${TMPDIR:-/tmp}")
	while IFS= read -r bundle; do
		if is_runtime_or_build_artifact "$bundle"; then
			:
		else
			quarantine_path "$bundle" "$quarantine"
		fi
	done < <(find_context_panel_bundles "/tmp")
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		while IFS= read -r bundle; do
			if is_runtime_or_build_artifact "$bundle"; then
				:
			else
				quarantine_path "$bundle" "$quarantine"
			fi
		done < <(find_context_panel_bundles "$path")
	done < <(artifact_cache_companion_build_validation_root)

	unregister_bundle_tree "$quarantine"
	unregister_stale_plugin_paths
	unregister_stale_launchservices_paths
}

reset_runtime() {
	guard_installed_runtime_replacement
	build_checkout_app
	preflight_built_runtime_profiles
	guard_installed_runtime_replacement

	section "Reset"
	local stamp quarantine
	stamp="$(date +%Y%m%d-%H%M%S)"
	quarantine="$HOME/.Trash/ContextPanel-runtime-baseline-$stamp"
	remove_prior_baseline_trash
	mkdir -p "$quarantine"

	stop_context_panel
	bootout_refresh_agent
	# Preserve the installed bundle path during reset. Removing the containing app can
	# make macOS drop the user's placed widget even when WidgetKit caches remain.
	quarantine_stale_runtime_bundles "$quarantine"
	unregister_refresh_agent_quietly
	bootout_refresh_agent

	for path in \
		"$HOME/Library/Application Scripts/com.shinycomputers.contextpanel" \
		"$HOME/Library/Application Scripts/com.shinycomputers.contextpanel.widget" \
		"$HOME/Library/Application Scripts/com.shinycomputers.contextpanel.refresh-agent" \
		"$HOME/Library/Group Containers/MM5YXC7T6E.group.com.shinycomputers.contextpanel/Context Panel" \
		"$HOME/Library/Group Containers/group.com.shinycomputers.contextpanel/Context Panel" \
		"$HOME/Library/Group Containers/MM5YXC7T6E.group.com.shinycomputers.contextpanel/Library/Preferences" \
		"$HOME/Library/Group Containers/group.com.shinycomputers.contextpanel/Library/Preferences" \
		"$HOME/Library/Application Support/Context Panel" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel/Data/Library/Application Support/Context Panel" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel/Data/Library/Application Scripts/com.shinycomputers.contextpanel" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/Library/Application Support/Context Panel" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/Library/Application Scripts/com.shinycomputers.contextpanel.widget" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.refresh-agent/Data/Library/Application Support/Context Panel" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.refresh-agent/Data/Library/Application Scripts/com.shinycomputers.contextpanel.refresh-agent" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel/Data/Library/Saved Application State" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel/Data/Library/Caches" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel/Data/Library/HTTPStorages" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel/Data/Library/Preferences/com.shinycomputers.contextpanel.plist" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel/Data/tmp/TemporaryItems" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/Library/Caches" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/Library/HTTPStorages" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/Library/Preferences/com.shinycomputers.contextpanel.widget.plist" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/tmp/TemporaryItems" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.refresh-agent/Data/Library/Caches" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.refresh-agent/Data/Library/HTTPStorages" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.refresh-agent/Data/Library/Preferences/com.shinycomputers.contextpanel.refresh-agent.plist" \
		"$HOME/Library/Containers/com.shinycomputers.contextpanel.refresh-agent/Data/tmp/TemporaryItems" \
		"$HOME/Library/Containers/com.apple.widgetkit.simulator/Data/tmp/9DF6F286-546A-4A09-8FE8-F8C1C3305734/widget_data/com.shinycomputers.contextpanel.widget"; do
		quarantine_path "$path" "$quarantine"
	done
	if [[ "$reset_widget_placement" == "1" ]]; then
		for path in \
			"$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/SystemData/com.apple.chrono/snapshots/ContextPanelWidget" \
			"$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/SystemData/com.apple.chrono/placeholders/ContextPanelWidget" \
			"$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/SystemData/com.apple.chrono/timelines/ContextPanelWidget"; do
			quarantine_path "$path" "$quarantine"
		done
	fi

	unregister_bundle_tree "$quarantine"
	unregister_stale_plugin_paths
	unregister_stale_launchservices_paths
	neutralize_bundle_extensions "$quarantine"
	neutralize_bundle_extensions "$HOME/.Trash"
	install_checkout_app
	clear_provider_credentials
	clear_webhook_credentials
	quarantine_path "$built_app_path" "$quarantine"
	quarantine_path "$derived_data_path/Build/Products/Debug/ContextPanelWidgetExtension.appex" "$quarantine"
	quarantine_path "$derived_data_path/Build/Products/Debug/ContextPanelRefreshAgent.app" "$quarantine"
	unregister_bundle_tree "$quarantine"
	neutralize_bundle_extensions "$quarantine"
	"$lsregister" -f -R -trusted "$app_path"
	pluginkit -a "$widget_path" >/dev/null 2>&1 || true
	unregister_refresh_agent_quietly
	bootout_refresh_agent
	refresh_widget_runtime
	if [[ "$reset_widget_placement" == "1" ]]; then
		killall chronod >/dev/null 2>&1 || true
	fi
	note "quarantine=$quarantine"

	if [[ "$launch_after_reset" == "1" ]]; then
		open "$app_path"
		sleep 2
		refresh_widget_runtime
	fi
	if [[ "$open_url_after_reset" == "1" ]]; then
		open 'contextpanel://overview'
		sleep 4
	fi
}

check_runtime() {
	section "Expected Build"
	if [[ -d "$app_path" ]]; then
		ok "app exists: $app_path"
	else
		fail "expected app is missing: $app_path"
	fi
	if [[ -d "$widget_path" ]]; then
		ok "widget exists: $widget_path"
	else
		fail "expected widget extension is missing: $widget_path"
	fi
	if [[ -d "$refresh_agent_path" ]]; then
		ok "refresh agent exists: $refresh_agent_path"
	else
		fail "expected refresh agent is missing: $refresh_agent_path"
	fi

	if [[ -f "$app_path/Contents/Info.plist" ]]; then
		local app_id
		app_id="$(plist_value "$app_path/Contents/Info.plist" CFBundleIdentifier)"
		if [[ "$app_id" == "com.shinycomputers.contextpanel" ]]; then
			ok "app bundle id: $app_id"
		else
			fail "unexpected app bundle id: $app_id"
		fi
	fi

	section "Runtime Identity"
	check_runtime_identity "$app_path" "$refresh_agent_path"

	section "Entitlements"
	check_canonical_app_group "$app_path" "app"
	check_canonical_app_group "$widget_path" "widget"
	check_canonical_app_group "$refresh_agent_path" "refresh agent"
	check_entitlement_absent "$app_path" "app" "com.apple.security.network.server"
	check_canonical_team_identifier "$app_path" "app"
	check_canonical_team_identifier "$widget_path" "widget"
	check_canonical_team_identifier "$refresh_agent_path" "refresh agent"

	section "Provisioning Profiles"
	check_provisioning_profile "$app_path" "app"
	check_provisioning_profile "$widget_path" "widget"
	check_provisioning_profile "$refresh_agent_path" "refresh agent"

	section "Build Fingerprint"
	if [[ -z "$expected_fingerprint" ]]; then
		fail "could not compute expected source fingerprint"
	else
		note "expected=$expected_fingerprint"
		local stamp
		stamp=""
		if [[ -f "$app_path/Contents/Resources/ContextPanelBuildFingerprint.txt" ]]; then
			stamp="$(cat "$app_path/Contents/Resources/ContextPanelBuildFingerprint.txt")"
		fi
		if [[ "$stamp" == "$expected_fingerprint" ]]; then
			ok "Context Panel.app fingerprint matches"
		else
			fail "Context Panel.app fingerprint mismatch: ${stamp:-missing}"
		fi
	fi

	section "Active Processes"
	local active
	active="$(active_context_processes)"
	if [[ -z "$active" ]]; then
		if [[ "$launch_after_reset" == "1" ]]; then
			fail "Context Panel was launched for validation, but no matching process is running"
		else
			ok "no Context Panel processes are running"
		fi
	else
		printf '%s\n' "$active"
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			case "$line" in
			*"$app_path/Contents/MacOS/Context Panel"*)
				ok "app process is running from installed runtime app"
				;;
			*"Context Panel.app/Contents/MacOS/Context Panel"*)
				fail "app process is running from unexpected bundle: $line"
				;;
			*"$refresh_agent_path/Contents/MacOS/ContextPanelRefreshAgent"*)
				ok "refresh agent process is running from installed runtime app"
				;;
			*"ContextPanelRefreshAgent"*)
				fail "refresh agent is running from unexpected bundle: $line"
				;;
			*) fail "unexpected Context Panel process: $line" ;;
			esac
		done <<<"$active"
	fi

	section "PluginKit"
	local plugins
	plugins="$(plugin_paths)"
	if [[ -z "$plugins" ]]; then
		fail "PluginKit has no registered Context Panel widget"
	else
		printf '%s\n' "$plugins"
		while IFS= read -r plugin; do
			[[ -n "$plugin" ]] || continue
			if [[ "$plugin" == "$widget_path" ]]; then
				ok "widget registration points to checkout"
			else
				fail "widget registration points elsewhere: $plugin"
			fi
		done <<<"$plugins"
	fi

	section "URL Handler"
	local handlers
	handlers="$(url_handler_paths contextpanel)"
	if rg -qx --fixed-strings "$app_path" <<<"$handlers"; then
		ok "contextpanel:// resolves to installed runtime app"
	else
		printf '%s\n' "$handlers"
		fail "contextpanel:// does not resolve to installed runtime app"
	fi

	section "Conflicting Bundles"
	local bundles conflicts
	bundles="$(discoverable_bundles)"
	conflicts=""
	while IFS= read -r bundle; do
		[[ -n "$bundle" ]] || continue
		case "$bundle" in
		"$app_path" | "$widget_path" | "$refresh_agent_path") ;;
		*) conflicts+="$bundle"$'\n' ;;
		esac
	done <<<"$bundles"
	if [[ -z "$conflicts" ]]; then
		ok "no discoverable conflicting Context Panel bundles"
	else
		printf '%s' "$conflicts"
		fail "conflicting bundles are discoverable"
	fi

	section "Local Build Bundles"
	local local_bundles local_conflicts
	local_bundles="$(local_build_bundles)"
	local_conflicts=""
	while IFS= read -r bundle; do
		[[ -n "$bundle" ]] || continue
		case "$bundle" in
		"$app_path" | "$widget_path" | "$refresh_agent_path") ;;
		*) local_conflicts+="$bundle"$'\n' ;;
		esac
	done <<<"$local_bundles"
	if [[ -z "$local_conflicts" ]]; then
		ok "no stale local Context Panel build bundles remain"
	else
		printf '%s' "$local_conflicts"
		fail "stale local Context Panel build bundles remain"
	fi

	section "Login Items"
	local launch_entry btm
	launch_entry="$(launchctl print "gui/$user_id/com.shinycomputers.contextpanel.refresh-agent" 2>/dev/null || true)"
	if [[ -z "$launch_entry" ]]; then
		ok "refresh login item is not loaded"
	elif [[ "$launch_entry" == *"job state = running"* || "$launch_entry" == *"state = running"* ]]; then
		printf '%s\n' "$launch_entry" | sed -n '1,80p'
		ok "refresh login item is running from installed runtime app"
	elif [[ "$launch_entry" == *"spawn failed"* || "$launch_entry" == *"last exit code"* ]]; then
		printf '%s\n' "$launch_entry" | sed -n '1,80p'
		fail "refresh login item is registered but failed to launch"
	else
		printf '%s\n' "$launch_entry" | sed -n '1,80p'
		ok "refresh login item is registered from installed runtime app"
	fi
	btm="$(btm_context_entries)"
	if [[ -n "$btm" ]]; then
		printf '%s\n' "$btm"
		if btm_has_enabled_checkout_agent "$btm"; then
			fail "BTM has enabled checkout Context Panel login item entries"
		elif btm_has_enabled_context_entries "$btm"; then
			ok "BTM has stale enabled Context Panel metadata, but no checkout login item is loaded"
		elif grep -q "$app_path" <<<"$btm"; then
			ok "BTM references installed runtime app"
		else
			ok "BTM only has disabled stale Context Panel entries"
		fi
	else
		if [[ "$include_btm_diagnostics" == "1" ]]; then
			ok "BTM has no Context Panel entries"
		else
			ok "BTM diagnostics skipped; pass --btm-diagnostics to run sfltool dumpbtm"
		fi
	fi

	section "Storage And Widget Caches"
	local files timelines render_cache placeholder_cache active_timelines widget_cache_root widget_build_reference
	files="$(context_files)"
	local saved_at
	saved_at="$(current_snapshot_saved_at)"
	if [[ "$mode" == "reset" ]]; then
		local reset_blocking_files
		reset_blocking_files="$(non_snapshot_context_files)"
		if [[ -z "$files" ]]; then
			ok "no persisted account config/bookmarks/snapshots/settings are present"
			note "note: the app still shows built-in default accounts when accounts.json is absent"
		elif [[ -z "$reset_blocking_files" && "$(current_snapshot_is_fresh_reset_state && printf yes || true)" == "yes" ]]; then
			printf '%s\n' "$files"
			ok "only fresh first-launch failure snapshot is present after reset"
			note "note: the app still shows built-in default accounts when accounts.json is absent"
		else
			printf '%s\n' "$files"
			fail "persisted runtime storage exists"
		fi
	else
		if [[ -z "$files" ]]; then
			ok "no persisted runtime storage is present"
		else
			printf '%s\n' "$files"
			ok "persisted runtime storage is present and preserved"
		fi
	fi
	if [[ -n "$saved_at" ]]; then
		ok "current snapshot savedAt=$saved_at"
	fi
	local bookmark_state bookmark_status
	set +e
	bookmark_state="$(bookmark_access_state)"
	bookmark_status=$?
	set -e
	if [[ -n "$bookmark_state" ]]; then
		printf '%s\n' "$bookmark_state"
	fi
	if [[ "$bookmark_status" == "0" ]]; then
		ok "refresh agent emitted a privacy-safe bookmark access summary"
		verify_bookmark_access_expectations "$bookmark_state"
		if [[ -z "$expected_bookmark_current" && -z "$expected_bookmark_resolvable" ]]; then
			note "Bookmark counts are informational; pass --expect-bookmark-current and --expect-bookmark-resolvable for a strict release gate."
		fi
	else
		fail "could not verify refresh-agent bookmark access"
	fi
	render_cache="$(widget_render_cache_files)"
	placeholder_cache="$(widget_placeholder_cache_files)"
	timelines="$(widget_timeline_files)"
	widget_cache_root="$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/SystemData/com.apple.chrono"
	active_timelines="$(widget_active_timeline_files "$widget_cache_root")"
	widget_build_reference="$app_path/Contents/Resources/ContextPanelBuildFingerprint.txt"
	[[ -f "$widget_build_reference" ]] || widget_build_reference="$app_path/Contents/MacOS/Context Panel"
	if [[ -n "$render_cache" ]]; then
		print_widget_cache_report "$render_cache"
		if [[ "$active" == *"$app_path/Contents/MacOS/Context Panel"* ]]; then
			if [[ -z "$active_timelines" ]]; then
				fail "WidgetKit has no active Context Panel timeline after launching the installed build"
			elif widget_timeline_cache_is_current_for_build "$widget_cache_root" "$widget_build_reference"; then
				ok "WidgetKit has a timeline generated by the installed build"
			else
				fail "WidgetKit timelines predate the installed build"
			fi
		else
			ok "WidgetKit render cache files exist for passive validation"
		fi
	elif [[ -n "$placeholder_cache" ]]; then
		print_widget_cache_report "$placeholder_cache"
		fail "WidgetKit only has placeholder cache files after launch"
	elif [[ -n "$timelines" ]]; then
		printf '%s\n' "$timelines"
		fail "WidgetKit timeline cache files exist, but none are Context Panel render snapshots or timelines"
	else
		ok "no WidgetKit timeline cache files are present"
	fi

	section "Provider Credentials"
	local credential_state credential_status
	set +e
	credential_state="$(provider_credential_state)"
	credential_status=$?
	set -e
	if [[ -n "$credential_state" ]]; then
		printf '%s\n' "$credential_state"
	fi
	if [[ "$mode" == "reset" ]]; then
		if [[ "$credential_status" == "0" ]]; then
			ok "no Context Panel provider credentials are present in Keychain"
		elif [[ "$credential_status" == "10" ]]; then
			fail "Context Panel provider credentials remain in Keychain"
		else
			fail "could not verify Context Panel provider credentials"
		fi
	else
		if [[ "$credential_status" == "0" ]]; then
			ok "no Context Panel provider credentials are present in Keychain"
		elif [[ "$credential_status" == "10" ]]; then
			ok "Context Panel provider credentials are present in Keychain"
		else
			fail "could not verify Context Panel provider credentials"
		fi
	fi

	section "Webhook Credentials"
	local webhook_state webhook_status
	set +e
	webhook_state="$(webhook_credential_state)"
	webhook_status=$?
	set -e
	if [[ -n "$webhook_state" ]]; then
		printf '%s\n' "$webhook_state"
	fi
	if [[ "$mode" == "reset" ]]; then
		if [[ "$webhook_status" == "0" ]]; then
			ok "no Context Panel webhook credentials are present in Keychain"
		elif [[ "$webhook_status" == "10" ]]; then
			fail "Context Panel webhook credentials remain in Keychain"
		else
			fail "could not verify Context Panel webhook credentials"
		fi
	else
		if [[ "$webhook_status" == "0" ]]; then
			ok "no Context Panel webhook credentials are present in Keychain"
		elif [[ "$webhook_status" == "10" ]]; then
			ok "Context Panel webhook credentials are present in Keychain"
		else
			fail "could not verify Context Panel webhook credentials"
		fi
	fi
}

require pluginkit || true
require mdfind || true
require xcrun || true

if [[ "$source_only" == "1" ]]; then
	# shellcheck disable=SC2317
	return 0 2>/dev/null || exit 0
fi

case "$mode" in
install)
	install_runtime
	;;
reset)
	reset_runtime
	;;
esac

check_runtime

section "Result"
if [[ "$failures" -gt 0 ]]; then
	note "baseline=FAIL failures=$failures"
	exit 1
fi
note "baseline=OK app=$app_path"
