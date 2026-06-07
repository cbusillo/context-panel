#!/usr/bin/env bash
set -euo pipefail

scheme="ContextPanel"
configuration="Release"
team_id="${APPLE_TEAM_ID:-MM5YXC7T6E}"
archive_path=".build/testflight/ContextPanel.xcarchive"
derived_data_path=".build/testflight/xcode-derived"
export_path=".build/testflight/upload"
export_options_path=".build/testflight/UploadOptions.plist"
app_profile="${MACOS_APP_STORE_APP_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanel.provisionprofile}"
widget_profile="${MACOS_APP_STORE_WIDGET_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanelWidgetExtension.provisionprofile}"
refresh_agent_profile="${MACOS_APP_STORE_REFRESH_AGENT_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanelRefreshAgent.provisionprofile}"
api_key_path="${APP_STORE_CONNECT_API_KEY_PATH:-}"
api_key_id="${APP_STORE_CONNECT_KEY_ID:-}"
api_issuer_id="${APP_STORE_CONNECT_ISSUER_ID:-}"
build_number="${CURRENT_PROJECT_VERSION:-}"
marketing_version="${MARKETING_VERSION:-}"
destination="upload"
upload="true"

usage() {
	cat <<'USAGE'
Usage: scripts/upload-testflight-macos-app.sh [options]

Archives Context Panel for the Mac App Store and exports or uploads the signed
package to App Store Connect/TestFlight.

Options:
  --build-number VALUE                 Override CURRENT_PROJECT_VERSION.
  --version VALUE                      Override MARKETING_VERSION.
  --archive-path PATH                  Archive output path.
  --derived-data-path PATH             Xcode derived data path.
  --export-path PATH                   Export/upload output path.
  --export-options-path PATH           Generated ExportOptions.plist path.
  --app-profile PATH                   Mac App Store app provisioning profile.
  --widget-profile PATH                Mac App Store widget provisioning profile.
  --refresh-agent-profile PATH         Mac App Store refresh agent provisioning profile.
  --api-key PATH                       App Store Connect API private key path.
  --api-key-id ID                      App Store Connect API key ID.
  --api-issuer-id ID                   App Store Connect API issuer ID.
  --team-id ID                         Apple Developer Team ID.
  --export-only                        Export a local pkg instead of uploading.
  -h, --help                           Show this help.

The API key can also be supplied with APP_STORE_CONNECT_API_KEY_P8_BASE64,
APP_STORE_CONNECT_KEY_ID, and APP_STORE_CONNECT_ISSUER_ID.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--build-number)
		build_number="${2:?--build-number requires a value}"
		shift 2
		;;
	--version)
		marketing_version="${2:?--version requires a value}"
		shift 2
		;;
	--archive-path)
		archive_path="${2:?--archive-path requires a value}"
		shift 2
		;;
	--derived-data-path)
		derived_data_path="${2:?--derived-data-path requires a value}"
		shift 2
		;;
	--export-path)
		export_path="${2:?--export-path requires a value}"
		shift 2
		;;
	--export-options-path)
		export_options_path="${2:?--export-options-path requires a value}"
		shift 2
		;;
	--app-profile)
		app_profile="${2:?--app-profile requires a value}"
		shift 2
		;;
	--widget-profile)
		widget_profile="${2:?--widget-profile requires a value}"
		shift 2
		;;
	--refresh-agent-profile)
		refresh_agent_profile="${2:?--refresh-agent-profile requires a value}"
		shift 2
		;;
	--api-key)
		api_key_path="${2:?--api-key requires a value}"
		shift 2
		;;
	--api-key-id)
		api_key_id="${2:?--api-key-id requires a value}"
		shift 2
		;;
	--api-issuer-id)
		api_issuer_id="${2:?--api-issuer-id requires a value}"
		shift 2
		;;
	--team-id)
		team_id="${2:?--team-id requires a value}"
		shift 2
		;;
	--export-only)
		upload="false"
		destination="export"
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

profile_uuid() {
	local profile="$1"
	local plist
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	/usr/libexec/PlistBuddy -c 'Print :UUID' "$plist"
	rm -f "$plist"
}

plist_array_contains_authorized_value() {
	local plist="$1"
	local key="$2"
	local required_value="$3"
	local values
	local value
	local wildcard_prefix
	values="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
	while IFS= read -r value; do
		value="${value#"${value%%[![:space:]]*}"}"
		value="${value%"${value##*[![:space:]]}"}"
		[[ -n "$value" && "$value" != "Array {" && "$value" != "}" ]] || continue
		if [[ "$value" == "$required_value" ]]; then
			return 0
		fi
		if [[ "$value" == *'.*' ]]; then
			wildcard_prefix="${value%\*}"
			if [[ "$required_value" == "$wildcard_prefix"* ]]; then
				return 0
			fi
		fi
	done <<<"$values"
	return 1
}

assert_profile_bundle_id() {
	local profile="$1"
	local label="$2"
	local bundle_id="$3"
	local plist
	local expected_app_id
	local profile_app_id
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	expected_app_id="$team_id.$bundle_id"
	profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null || true)"
	rm -f "$plist"
	if [[ "$profile_app_id" != "$expected_app_id" ]]; then
		echo "$label provisioning profile has application identifier '$profile_app_id', expected '$expected_app_id'" >&2
		exit 1
	fi
}

assert_profile_app_group() {
	local profile="$1"
	local label="$2"
	local app_group="$team_id.group.com.shinycomputers.contextpanel"
	local plist
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	if ! plist_array_contains_authorized_value "$plist" 'Entitlements:com.apple.security.application-groups' "$app_group"; then
		rm -f "$plist"
		echo "$label provisioning profile does not authorize app group: $app_group" >&2
		exit 1
	fi
	rm -f "$plist"
}

install_profile() {
	local profile="$1"
	local uuid="$2"
	local directory="$HOME/Library/MobileDevice/Provisioning Profiles"
	mkdir -p "$directory"
	cp "$profile" "$directory/$uuid.provisionprofile"
}

validate_marketing_version() {
	if [[ -z "$marketing_version" ]]; then
		echo "App Store marketing version is required; pass --version, for example --version 1.0.18" >&2
		exit 1
	fi
	if [[ "$marketing_version" == "1.0" ]]; then
		echo "App Store marketing version 1.0 is closed; pass the next App Store version, for example --version 1.0.18" >&2
		exit 1
	fi
}

require_command xcodegen
require_command xcodebuild
require_command security

validate_marketing_version

if [[ ! -f "$app_profile" ]]; then
	echo "app provisioning profile not found: $app_profile" >&2
	exit 1
fi
if [[ ! -f "$widget_profile" ]]; then
	echo "widget provisioning profile not found: $widget_profile" >&2
	exit 1
fi
if [[ ! -f "$refresh_agent_profile" ]]; then
	echo "refresh agent provisioning profile not found: $refresh_agent_profile" >&2
	exit 1
fi

tmp_api_key=""
if [[ -z "$api_key_path" && -n "${APP_STORE_CONNECT_API_KEY_P8_BASE64:-}" ]]; then
	if [[ -z "$api_key_id" || -z "$api_issuer_id" ]]; then
		echo "APP_STORE_CONNECT_API_KEY_P8_BASE64 also requires APP_STORE_CONNECT_KEY_ID and APP_STORE_CONNECT_ISSUER_ID" >&2
		exit 1
	fi
	tmp_api_key="$(mktemp)"
	printf '%s' "$APP_STORE_CONNECT_API_KEY_P8_BASE64" | base64 -D >"$tmp_api_key"
	chmod 600 "$tmp_api_key"
	api_key_path="$tmp_api_key"
fi
trap '[[ -n "${tmp_api_key:-}" ]] && rm -f "$tmp_api_key"' EXIT

if [[ -z "$api_key_path" || -z "$api_key_id" || -z "$api_issuer_id" ]]; then
	echo "App Store Connect API credentials are required" >&2
	exit 1
fi
if [[ ! -f "$api_key_path" ]]; then
	echo "App Store Connect API key not found: $api_key_path" >&2
	exit 1
fi

app_profile_uuid="$(profile_uuid "$app_profile")"
widget_profile_uuid="$(profile_uuid "$widget_profile")"
refresh_agent_profile_uuid="$(profile_uuid "$refresh_agent_profile")"
assert_profile_bundle_id "$app_profile" "app" "com.shinycomputers.contextpanel"
assert_profile_bundle_id "$widget_profile" "widget" "com.shinycomputers.contextpanel.widget"
assert_profile_bundle_id "$refresh_agent_profile" "refresh agent" "com.shinycomputers.contextpanel.refresh-agent"
assert_profile_app_group "$app_profile" "app"
assert_profile_app_group "$widget_profile" "widget"
assert_profile_app_group "$refresh_agent_profile" "refresh agent"
install_profile "$app_profile" "$app_profile_uuid"
install_profile "$widget_profile" "$widget_profile_uuid"
install_profile "$refresh_agent_profile" "$refresh_agent_profile_uuid"

mkdir -p "$(dirname "$export_options_path")"
cat >"$export_options_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>$destination</string>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$team_id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>installerSigningCertificate</key>
	<string>3rd Party Mac Developer Installer</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>com.shinycomputers.contextpanel</key>
		<string>$app_profile_uuid</string>
		<key>com.shinycomputers.contextpanel.widget</key>
		<string>$widget_profile_uuid</string>
		<key>com.shinycomputers.contextpanel.refresh-agent</key>
		<string>$refresh_agent_profile_uuid</string>
	</dict>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

xcodegen generate --spec project.yml

archive_args=(
	-project ContextPanel.xcodeproj
	-scheme "$scheme"
	-configuration "$configuration"
	-destination 'generic/platform=macOS'
	-archivePath "$archive_path"
	-derivedDataPath "$derived_data_path"
	-allowProvisioningUpdates
	-authenticationKeyPath "$api_key_path"
	-authenticationKeyID "$api_key_id"
	-authenticationKeyIssuerID "$api_issuer_id"
	CODE_SIGN_STYLE=Manual
	DEVELOPMENT_TEAM="$team_id"
	CONTEXT_PANEL_APP_STORE_APP_PROFILE_SPECIFIER="$app_profile_uuid"
	CONTEXT_PANEL_APP_STORE_WIDGET_PROFILE_SPECIFIER="$widget_profile_uuid"
	CONTEXT_PANEL_APP_STORE_REFRESH_AGENT_PROFILE_SPECIFIER="$refresh_agent_profile_uuid"
	CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_ID="${CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_ID:-}"
	CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET="${CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET:-}"
)
if [[ -n "$build_number" ]]; then
	archive_args+=(CURRENT_PROJECT_VERSION="$build_number")
fi
if [[ -n "$marketing_version" ]]; then
	archive_args+=(MARKETING_VERSION="$marketing_version")
fi

rm -rf "$archive_path" "$derived_data_path" "$export_path"
xcodebuild "${archive_args[@]}" archive

xcodebuild \
	-exportArchive \
	-archivePath "$archive_path" \
	-exportPath "$export_path" \
	-exportOptionsPlist "$export_options_path" \
	-allowProvisioningUpdates \
	-authenticationKeyPath "$api_key_path" \
	-authenticationKeyID "$api_key_id" \
	-authenticationKeyIssuerID "$api_issuer_id"

if [[ "$upload" == "true" ]]; then
	echo "Uploaded ContextPanel to App Store Connect."
else
	find "$export_path" -maxdepth 1 -type f -name '*.pkg' -print
fi
