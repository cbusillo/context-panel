#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="check"
launch_after_reset=0
open_url_after_reset=0
reset_widget_placement=0
include_btm_diagnostics=0

usage() {
	cat <<'USAGE'
Usage: scripts/context-panel-runtime-baseline.sh [check|install|reset] [--launch] [--open-url] [--reset-widget-placement]

check  Print a runtime receipt and fail if Context Panel is not isolated to this checkout.
install
       Build this checkout and update /Applications/Context Panel.app in place while preserving
       the user's placed widget and runtime storage.
reset  Build this checkout, clear Context Panel storage, quarantine conflicting bundles, and
       update /Applications/Context Panel.app in place so widget placement is preserved.

--launch    With reset, launch the checked-out app after cleanup.
--open-url  With reset, open contextpanel://overview after launch to exercise widget click-through.
--reset-widget-placement
            Also clear WidgetKit/Chrono placement caches. This may remove the widget from the UI.
--btm-diagnostics
            Include sfltool Background Task Management diagnostics. macOS may prompt for a password.
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

derived_data_path="$repo_root/.build/runtime-baseline-derived-data"
built_app_path="$derived_data_path/Build/Products/Debug/Context Panel.app"
built_widget_path="$built_app_path/Contents/PlugIns/ContextPanelWidgetExtension.appex"
built_refresh_agent_path="$built_app_path/Contents/Library/LoginItems/ContextPanelRefreshAgent.app"
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
			\( -name accounts.json -o -name file-bookmarks.json -o -name current-snapshot.json -o -name history.json -o -name reset-primer-settings.json -o -name reset-primer-runs.json -o -name background-refresh-settings.json \) \
			-print 2>/dev/null || true
	done
}

widget_timeline_files() {
	find "$HOME/Library/Containers/com.shinycomputers.contextpanel.widget/Data/SystemData/com.apple.chrono" -maxdepth 6 \
		-name '*.chrono-timeline' -print 2>/dev/null || true
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
	"$lsregister" -dump 2>/dev/null |
		awk '
			/^path:[[:space:]]+/ {
				path = $0
				sub(/^path:[[:space:]]+/, "", path)
				sub(/ \(0x[0-9a-fA-F]+\)$/, "", path)
			}
			/contextpanel/ && path != "" {
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

signed_team_identifier() {
	local bundle="$1"
	codesign -dv --verbose=4 "$bundle" 2>&1 |
		awk -F= '/^TeamIdentifier=/ { print $2; exit }'
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
	local plist name teams
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
	rm -f "$plist"
	if [[ -z "$name" ]]; then
		fail "$label embedded provisioning profile has no Name"
		return
	fi
	if rg -qx --fixed-strings "$developer_team_id" <<<"$teams"; then
		ok "$label provisioning profile: $name"
	else
		printf '%s\n' "$teams"
		fail "$label provisioning profile is not for canonical team $developer_team_id"
	fi
}

bootout_refresh_agent() {
	launchctl bootout "gui/$user_id/com.shinycomputers.contextpanel.refresh-agent" >/dev/null 2>&1 || true
	pkill -x ContextPanelRefreshAgent >/dev/null 2>&1 || true
}

stop_context_panel() {
	pkill -x 'Context Panel' >/dev/null 2>&1 || true
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
	open -W -a "$app" --args --unregister-refresh-agent >/dev/null 2>&1 || true
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
		CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_ID="${CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_ID:-}" \
		CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET="${CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET:-}" \
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
	build_checkout_app

	section "Install"
	local stamp quarantine
	stamp="$(date +%Y%m%d-%H%M%S)"
	quarantine="$HOME/.Trash/ContextPanel-runtime-baseline-$stamp"
	remove_prior_baseline_trash
	mkdir -p "$quarantine"

	stop_context_panel
	bootout_refresh_agent
	install_checkout_app
	quarantine_path "$built_app_path" "$quarantine"
	quarantine_path "$derived_data_path/Build/Products/Debug/ContextPanelWidgetExtension.appex" "$quarantine"
	quarantine_path "$derived_data_path/Build/Products/Debug/ContextPanelRefreshAgent.app" "$quarantine"
	neutralize_bundle_extensions "$quarantine"
	"$lsregister" -f -R -trusted "$app_path"
	pluginkit -a "$widget_path" >/dev/null 2>&1 || true
	unregister_refresh_agent_quietly
	bootout_refresh_agent
	xcrun widgetctl reload all >/dev/null 2>&1 || true
	note "quarantine=$quarantine"

	if [[ "$launch_after_reset" == "1" ]]; then
		open "$app_path"
		sleep 2
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

reset_runtime() {
	build_checkout_app

	section "Reset"
	local stamp quarantine
	stamp="$(date +%Y%m%d-%H%M%S)"
	quarantine="$HOME/.Trash/ContextPanel-runtime-baseline-$stamp"
	remove_prior_baseline_trash
	mkdir -p "$quarantine"

	stop_context_panel
	bootout_refresh_agent
	unregister_stale_plugin_paths
	unregister_stale_launchservices_paths
	# Preserve the installed bundle path during reset. Removing the containing app can
	# make macOS drop the user's placed widget even when WidgetKit caches remain.
	# Known app artifacts with this bundle id that are not the installed runtime app.
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

	unregister_refresh_agent_quietly
	bootout_refresh_agent

	# Known local build roots that Spotlight may miss because the bundle was already moved or deleted.
	for path in \
		"$repo_root/.build/DerivedData/Build/Products/Debug/Context Panel.app" \
		"$repo_root/.build/profile-probe/Build/Products/Release/Context Panel.app" \
		"$HOME/Developer/context-panel-clean-main/.build/dogfood-main-local-nokeychain/Context Panel.app" \
		"$HOME/Developer/context-panel-clean-main/.build/xcode-derived-release/Build/Products/Release/Context Panel.app" \
		"$HOME/Developer/context-panel-baseline-main-20260512/.build/xcode-derived-baseline/Build/Products/Debug/Context Panel.app" \
		"$repo_root/dist/Context Panel.app"; do
		quarantine_path "$path" "$quarantine"
	done
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
	quarantine_path "$built_app_path" "$quarantine"
	quarantine_path "$derived_data_path/Build/Products/Debug/ContextPanelWidgetExtension.appex" "$quarantine"
	quarantine_path "$derived_data_path/Build/Products/Debug/ContextPanelRefreshAgent.app" "$quarantine"
	unregister_bundle_tree "$quarantine"
	neutralize_bundle_extensions "$quarantine"
	"$lsregister" -f -R -trusted "$app_path"
	pluginkit -a "$widget_path" >/dev/null 2>&1 || true
	unregister_refresh_agent_quietly
	bootout_refresh_agent
	xcrun widgetctl reload all >/dev/null 2>&1 || true
	if [[ "$reset_widget_placement" == "1" ]]; then
		killall chronod >/dev/null 2>&1 || true
	fi
	note "quarantine=$quarantine"

	if [[ "$launch_after_reset" == "1" ]]; then
		open "$app_path"
		sleep 2
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

	section "Entitlements"
	check_canonical_app_group "$app_path" "app"
	check_canonical_app_group "$widget_path" "widget"
	check_canonical_app_group "$refresh_agent_path" "refresh agent"
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
	handlers="$(url_handler_paths)"
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
	local files timelines
	files="$(context_files)"
	local saved_at
	saved_at="$(current_snapshot_saved_at)"
	if [[ "$mode" == "reset" ]]; then
		if [[ -z "$files" ]]; then
			ok "no persisted account config/bookmarks/snapshots/reset-primer settings are present"
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
	timelines="$(widget_timeline_files)"
	if [[ -z "$timelines" ]]; then
		ok "no WidgetKit timeline cache files are present"
	else
		printf '%s\n' "$timelines"
		ok "WidgetKit timeline cache files exist after launch"
	fi
}

require pluginkit || true
require mdfind || true
require xcrun || true

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
