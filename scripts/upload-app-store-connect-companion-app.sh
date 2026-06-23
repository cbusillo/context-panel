#!/usr/bin/env bash
set -euo pipefail

scheme="ContextPanelCompanion"
configuration="Release"
platform="ios"
team_id="${APPLE_TEAM_ID:-MM5YXC7T6E}"
archive_path=""
derived_data_path=".build/app-store-connect-companion/xcode-derived"
export_path=""
export_options_path=""
app_profile="${COMPANION_APP_STORE_APP_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanelCompanion.provisionprofile}"
widget_profile="${COMPANION_APP_STORE_WIDGET_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanelCompanionWidgetExtension.provisionprofile}"
api_key_path="${APP_STORE_CONNECT_API_KEY_PATH:-}"
api_key_id="${APP_STORE_CONNECT_KEY_ID:-}"
api_issuer_id="${APP_STORE_CONNECT_ISSUER_ID:-}"
build_number="${CURRENT_PROJECT_VERSION:-}"
marketing_version="${MARKETING_VERSION:-}"
destination="upload"
upload="true"

usage() {
	cat <<'USAGE'
Usage: scripts/upload-app-store-connect-companion-app.sh [options]

Archives the Context Panel companion app and exports or uploads the signed IPA
to App Store Connect.

Options:
  --platform VALUE                     Companion platform: ios or visionos. Default: ios.
  --build-number VALUE                 Override CURRENT_PROJECT_VERSION.
  --version VALUE                      Override MARKETING_VERSION.
  --archive-path PATH                  Archive output path.
  --derived-data-path PATH             Xcode derived data path.
  --export-path PATH                   Export/upload output path.
  --export-options-path PATH           Generated ExportOptions.plist path.
  --app-profile PATH                   Companion app provisioning profile.
  --widget-profile PATH                Companion widget provisioning profile.
  --api-key PATH                       App Store Connect API private key path.
  --api-key-id ID                      App Store Connect API key ID.
  --api-issuer-id ID                   App Store Connect API issuer ID.
  --team-id ID                         Apple Developer Team ID.
  --export-only                        Export a local IPA instead of uploading.
  -h, --help                           Show this help.

The API key can also be supplied with APP_STORE_CONNECT_API_KEY_P8_BASE64,
APP_STORE_CONNECT_KEY_ID, and APP_STORE_CONNECT_ISSUER_ID.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--platform)
		platform="${2:?--platform requires a value}"
		shift 2
		;;
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

json_array_count() {
	local file="$1"
	local key="$2"
	local count
	if ! count="$(plutil -extract "$key" raw -o - "$file" 2>/dev/null)"; then
		return 1
	fi
	if [[ -z "$count" || "$count" == *[!0-9]* ]]; then
		return 1
	fi
	printf '%s' "$count"
}

array_contains_value() {
	local expected="$1"
	shift
	local value
	for value in "$@"; do
		if [[ "$value" == "$expected" ]]; then
			return 0
		fi
	done
	return 1
}

path_basename() {
	local path="$1"
	printf '%s' "${path##*/}"
}

profile_uuid() {
	local profile="$1"
	local plist
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	/usr/libexec/PlistBuddy -c 'Print :UUID' "$plist"
	rm -f "$plist"
}

plist_array_contains_value() {
	local plist="$1"
	local key="$2"
	local required_value="$3"
	local values
	local value
	values="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
	while IFS= read -r value; do
		value="${value#"${value%%[![:space:]]*}"}"
		value="${value%"${value##*[![:space:]]}"}"
		[[ -n "$value" && "$value" != "Array {" && "$value" != "}" ]] || continue
		if [[ "$value" == "$required_value" ]]; then
			return 0
		fi
	done <<<"$values"
	return 1
}

join_values() {
	local output=""
	local value
	for value in "$@"; do
		if [[ -n "$output" ]]; then
			output+=", "
		fi
		output+="$value"
	done
	printf '%s' "$output"
}

assert_profile_platform_any() {
	local profile="$1"
	local label="$2"
	shift 2
	local plist
	local platform
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	for platform in "$@"; do
		if plist_array_contains_value "$plist" 'Platform' "$platform"; then
			rm -f "$plist"
			return 0
		fi
	done
	rm -f "$plist"
	echo "$label provisioning profile does not support platform: $(join_values "$@")" >&2
	exit 1
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
	profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$plist" 2>/dev/null || true)"
	if [[ -z "$profile_app_id" ]]; then
		profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null || true)"
	fi
	rm -f "$plist"
	if [[ "$profile_app_id" != "$expected_app_id" ]]; then
		echo "$label provisioning profile has application identifier '$profile_app_id', expected '$expected_app_id'" >&2
		exit 1
	fi
}

assert_profile_app_group() {
	local profile="$1"
	local label="$2"
	local app_group="group.com.shinycomputers.contextpanel"
	local plist
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	if ! plist_array_contains_value "$plist" 'Entitlements:com.apple.security.application-groups' "$app_group"; then
		rm -f "$plist"
		echo "$label provisioning profile does not authorize app group: $app_group" >&2
		exit 1
	fi
	rm -f "$plist"
}

assert_profile_icloud_service() {
	local profile="$1"
	local label="$2"
	local service="$3"
	local container="iCloud.com.shinycomputers.contextpanel"
	local plist
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	if ! plist_array_contains_value "$plist" 'Entitlements:com.apple.developer.icloud-container-identifiers' "$container"; then
		rm -f "$plist"
		echo "$label provisioning profile does not authorize iCloud container: $container" >&2
		exit 1
	fi
	if ! plist_array_contains_value "$plist" 'Entitlements:com.apple.developer.icloud-services' "$service"; then
		if ! plist_array_contains_value "$plist" 'Entitlements:com.apple.developer.icloud-services' '*'; then
			rm -f "$plist"
			echo "$label provisioning profile does not authorize $service" >&2
			exit 1
		fi
	fi
	rm -f "$plist"
}

assert_profile_ubiquity_container() {
	local profile="$1"
	local label="$2"
	local container="iCloud.com.shinycomputers.contextpanel"
	local plist
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	if ! plist_array_contains_value "$plist" 'Entitlements:com.apple.developer.ubiquity-container-identifiers' "$container"; then
		rm -f "$plist"
		echo "$label provisioning profile does not authorize ubiquity container: $container" >&2
		exit 1
	fi
	rm -f "$plist"
}

assert_profile_push_notifications() {
	local profile="$1"
	local label="$2"
	local expected_environment="$3"
	local plist
	local environment
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	environment="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$plist" 2>/dev/null || true)"
	rm -f "$plist"
	if [[ "$environment" != "$expected_environment" ]]; then
		echo "$label provisioning profile has APNs environment '$environment', expected '$expected_environment'" >&2
		exit 1
	fi
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
		echo "App Store marketing version is required; pass --version, for example --version 1.0.29" >&2
		exit 1
	fi
	if [[ "$marketing_version" == "1.0" ]]; then
		echo "App Store marketing version 1.0 is closed; pass the next App Store version, for example --version 1.0.29" >&2
		exit 1
	fi
}

assert_visionos_packaging_ready() {
	local icon_stack="Resources/Assets.xcassets/AppIcon.solidimagestack"
	local icon_stack_contents="$icon_stack/Contents.json"
	local layer_dirs=()
	local layer_basenames=()
	local layer_dir
	local layer_count
	local declared_layer_count
	local declared_layer_filename
	local declared_layer_filename_count=0
	local declared_layer_filenames=()
	local image_count
	local image_filename
	local image_filename_count
	local image_filenames=()
	local image_index
	local image_set
	local layer_index
	if [[ ! -f "$icon_stack_contents" ]]; then
		cat >&2 <<MSG
visionOS companion packaging is blocked because no visionOS layered app icon is present.
Add Resources/Assets.xcassets/AppIcon.solidimagestack before using --platform visionos as signed release evidence.
MSG
		exit 1
	fi
	shopt -s nullglob
	layer_dirs=("$icon_stack"/*.solidimagestacklayer)
	shopt -u nullglob
	layer_count="${#layer_dirs[@]}"
	if ((layer_count < 2 || layer_count > 3)); then
		cat >&2 <<MSG
visionOS companion packaging is blocked because AppIcon.solidimagestack must contain two or three solid image stack layers.
Add background and foreground .solidimagestacklayer entries before using --platform visionos as signed release evidence.
MSG
		exit 1
	fi
	if ! declared_layer_count="$(json_array_count "$icon_stack_contents" 'layers')"; then
		echo "visionOS companion packaging is blocked because AppIcon.solidimagestack/Contents.json does not contain a readable layers array." >&2
		exit 1
	fi
	if [[ "$declared_layer_count" != "$layer_count" ]]; then
		cat >&2 <<MSG
visionOS companion packaging is blocked because AppIcon.solidimagestack/Contents.json does not declare the same number of layers present on disk.
Declare each .solidimagestacklayer in the root layers array before using --platform visionos as signed release evidence.
MSG
		exit 1
	fi
	for layer_dir in "${layer_dirs[@]}"; do
		layer_basenames+=("$(path_basename "$layer_dir")")
	done
	for ((layer_index = 0; layer_index < declared_layer_count; layer_index++)); do
		declared_layer_filename="$(plutil -extract "layers.$layer_index.filename" raw -o - "$icon_stack_contents" 2>/dev/null || true)"
		if [[ -z "$declared_layer_filename" || "$declared_layer_filename" != *.solidimagestacklayer || "$declared_layer_filename" != "$(path_basename "$declared_layer_filename")" ]]; then
			cat >&2 <<MSG
visionOS companion packaging is blocked because AppIcon.solidimagestack/Contents.json declares an invalid layer filename.
Every root layer filename must be a .solidimagestacklayer basename before using --platform visionos as signed release evidence.
MSG
			exit 1
		fi
		if ((declared_layer_filename_count > 0)) && array_contains_value "$declared_layer_filename" "${declared_layer_filenames[@]}"; then
			cat >&2 <<MSG
visionOS companion packaging is blocked because AppIcon.solidimagestack/Contents.json declares a duplicate layer.
Every root layer filename must be unique before using --platform visionos as signed release evidence.
MSG
			exit 1
		fi
		if ! array_contains_value "$declared_layer_filename" "${layer_basenames[@]}"; then
			cat >&2 <<MSG
visionOS companion packaging is blocked because AppIcon.solidimagestack/Contents.json declares a missing layer.
Every root layer filename must match a .solidimagestacklayer directory before using --platform visionos as signed release evidence.
MSG
			exit 1
		fi
		declared_layer_filenames+=("$declared_layer_filename")
		declared_layer_filename_count=$((declared_layer_filename_count + 1))
	done
	for layer_dir in "${layer_dirs[@]}"; do
		if ! array_contains_value "$(path_basename "$layer_dir")" "${declared_layer_filenames[@]}"; then
			cat >&2 <<MSG
visionOS companion packaging is blocked because AppIcon.solidimagestack contains an undeclared layer directory.
Every .solidimagestacklayer directory must be declared in the root layers array before using --platform visionos as signed release evidence.
MSG
			exit 1
		fi
	done
	for layer_dir in "${layer_dirs[@]}"; do
		if [[ ! -f "$layer_dir/Contents.json" || ! -f "$layer_dir/Content.imageset/Contents.json" ]]; then
			cat >&2 <<MSG
visionOS companion packaging is blocked because $(path_basename "$layer_dir") is incomplete.
Each .solidimagestacklayer must include Contents.json and Content.imageset/Contents.json before using --platform visionos as signed release evidence.
MSG
			exit 1
		fi
		image_set="$layer_dir/Content.imageset"
		if ! image_count="$(json_array_count "$image_set/Contents.json" 'images')"; then
			cat >&2 <<MSG
visionOS companion packaging is blocked because $(path_basename "$layer_dir")/Content.imageset/Contents.json does not contain a readable images array.
Each layer image set must reference at least one image file before using --platform visionos as signed release evidence.
MSG
			exit 1
		fi
		if ((image_count < 1)); then
			cat >&2 <<MSG
visionOS companion packaging is blocked because $(path_basename "$layer_dir") has no image entries.
Each layer image set must reference at least one image file before using --platform visionos as signed release evidence.
MSG
			exit 1
		fi
		image_filenames=()
		image_filename_count=0
		for ((image_index = 0; image_index < image_count; image_index++)); do
			image_filename="$(plutil -extract "images.$image_index.filename" raw -o - "$image_set/Contents.json" 2>/dev/null || true)"
			if [[ -z "$image_filename" || "$image_filename" != "$(path_basename "$image_filename")" ]]; then
				cat >&2 <<MSG
visionOS companion packaging is blocked because $(path_basename "$layer_dir") has an invalid image filename.
Every image entry must name a file basename beside Content.imageset/Contents.json before using --platform visionos as signed release evidence.
MSG
				exit 1
			fi
			if ((image_filename_count > 0)) && array_contains_value "$image_filename" "${image_filenames[@]}"; then
				cat >&2 <<MSG
visionOS companion packaging is blocked because $(path_basename "$layer_dir") declares a duplicate image filename.
Every image filename must be unique within its layer before using --platform visionos as signed release evidence.
MSG
				exit 1
			fi
			if [[ ! -f "$image_set/$image_filename" ]]; then
				cat >&2 <<MSG
visionOS companion packaging is blocked because $(path_basename "$layer_dir") has a missing image file.
Every image entry must name a file that exists beside Content.imageset/Contents.json before using --platform visionos as signed release evidence.
MSG
				exit 1
			fi
			image_filenames+=("$image_filename")
			image_filename_count=$((image_filename_count + 1))
		done
	done
}

case "$platform" in
ios)
	xcode_destination="generic/platform=iOS"
	platform_label="iOS"
	app_store_platform="IOS"
	profile_platforms=(iOS)
	;;
visionos)
	xcode_destination="generic/platform=visionOS"
	platform_label="visionOS"
	app_store_platform="VISION_OS"
	profile_platforms=(visionOS xrOS)
	assert_visionos_packaging_ready
	;;
*)
	echo "unsupported companion platform: $platform" >&2
	exit 2
	;;
esac

archive_path="${archive_path:-.build/app-store-connect-companion/ContextPanelCompanion-$platform_label.xcarchive}"
export_path="${export_path:-.build/app-store-connect-companion/upload-$platform_label}"
export_options_path="${export_options_path:-.build/app-store-connect-companion/UploadOptions-$platform_label.plist}"

require_command xcodegen
require_command xcodebuild
require_command security
require_command python3

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

validate_marketing_version

if [[ ! -f "$app_profile" ]]; then
	echo "companion app provisioning profile not found: $app_profile" >&2
	exit 1
fi
if [[ ! -f "$widget_profile" ]]; then
	echo "companion widget provisioning profile not found: $widget_profile" >&2
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

if [[ "$upload" == "true" ]]; then
	python3 scripts/app-store-version-guard.py \
		--bundle-id com.shinycomputers.contextpanel \
		--platform "$app_store_platform" \
		--version "$marketing_version" \
		--api-key "$api_key_path" \
		--api-key-id "$api_key_id" \
		--api-issuer-id "$api_issuer_id"
fi

app_profile_uuid="$(profile_uuid "$app_profile")"
widget_profile_uuid="$(profile_uuid "$widget_profile")"
assert_profile_bundle_id "$app_profile" "companion app" "com.shinycomputers.contextpanel"
assert_profile_bundle_id "$widget_profile" "companion widget" "com.shinycomputers.contextpanel.widget"
assert_profile_platform_any "$app_profile" "companion app" "${profile_platforms[@]}"
assert_profile_platform_any "$widget_profile" "companion widget" "${profile_platforms[@]}"
assert_profile_app_group "$app_profile" "companion app"
assert_profile_app_group "$widget_profile" "companion widget"
assert_profile_icloud_service "$app_profile" "companion app" "CloudDocuments"
assert_profile_icloud_service "$app_profile" "companion app" "CloudKit"
assert_profile_ubiquity_container "$app_profile" "companion app"
assert_profile_push_notifications "$app_profile" "companion app" "production"
install_profile "$app_profile" "$app_profile_uuid"
install_profile "$widget_profile" "$widget_profile_uuid"

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
	<key>provisioningProfiles</key>
	<dict>
		<key>com.shinycomputers.contextpanel</key>
		<string>$app_profile_uuid</string>
		<key>com.shinycomputers.contextpanel.widget</key>
		<string>$widget_profile_uuid</string>
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
	-destination "$xcode_destination"
	-archivePath "$archive_path"
	-derivedDataPath "$derived_data_path"
	-allowProvisioningUpdates
	-authenticationKeyPath "$api_key_path"
	-authenticationKeyID "$api_key_id"
	-authenticationKeyIssuerID "$api_issuer_id"
	CODE_SIGN_STYLE=Manual
	DEVELOPMENT_TEAM="$team_id"
	CONTEXT_PANEL_APP_STORE_COMPANION_PROFILE_SPECIFIER="$app_profile_uuid"
	CONTEXT_PANEL_APP_STORE_COMPANION_WIDGET_PROFILE_SPECIFIER="$widget_profile_uuid"
)
if [[ -n "$build_number" ]]; then
	archive_args+=(CURRENT_PROJECT_VERSION="$build_number")
fi
if [[ -n "$marketing_version" ]]; then
	archive_args+=(MARKETING_VERSION="$marketing_version")
fi

rm -rf "$archive_path" "$derived_data_path" "$export_path"
run_xcodebuild "${archive_args[@]}" archive

run_xcodebuild \
	-exportArchive \
	-archivePath "$archive_path" \
	-exportPath "$export_path" \
	-exportOptionsPlist "$export_options_path" \
	-allowProvisioningUpdates \
	-authenticationKeyPath "$api_key_path" \
	-authenticationKeyID "$api_key_id" \
	-authenticationKeyIssuerID "$api_issuer_id"

if [[ "$upload" == "true" ]]; then
	echo "Uploaded Context Panel companion ($platform_label) to App Store Connect."
else
	find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print
fi
