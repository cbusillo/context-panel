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
app_profile="${COMPANION_APP_STORE_APP_PROVISIONING_PROFILE:-}"
widget_profile="${COMPANION_APP_STORE_WIDGET_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanelCompanionWidgetExtension.provisionprofile}"
watch_profile="${COMPANION_APP_STORE_WATCH_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanelWatch.provisionprofile}"
watch_widget_profile="${COMPANION_APP_STORE_WATCH_WIDGET_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanelWatchWidgetExtension.provisionprofile}"
tv_top_shelf_profile="${COMPANION_APP_STORE_TV_TOP_SHELF_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanelTVTopShelfExtension.provisionprofile}"
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
  --platform VALUE                     Companion platform: ios, visionos, or tvos. Default: ios.
  --build-number VALUE                 Override CURRENT_PROJECT_VERSION.
  --version VALUE                      Override MARKETING_VERSION.
  --archive-path PATH                  Archive output path.
  --derived-data-path PATH             Xcode derived data path.
  --export-path PATH                   Export/upload output path.
  --export-options-path PATH           Generated ExportOptions.plist path.
  --app-profile PATH                   Companion app provisioning profile.
  --widget-profile PATH                Companion widget provisioning profile.
  --watch-profile PATH                 Companion watch app provisioning profile.
  --watch-widget-profile PATH          Companion watch widget provisioning profile.
  --tv-top-shelf-profile PATH          tvOS Top Shelf extension provisioning profile.
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
	--watch-profile)
		watch_profile="${2:?--watch-profile requires a value}"
		shift 2
		;;
	--watch-widget-profile)
		watch_widget_profile="${2:?--watch-widget-profile requires a value}"
		shift 2
		;;
	--tv-top-shelf-profile)
		tv_top_shelf_profile="${2:?--tv-top-shelf-profile requires a value}"
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
	local app_group="${3:-group.com.shinycomputers.contextpanel}"
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

assert_profile_user_management() {
	local profile="$1"
	local label="$2"
	local capability="runs-as-current-user-with-user-independent-keychain"
	local plist
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	if ! plist_array_contains_value "$plist" 'Entitlements:com.apple.developer.user-management' "$capability"; then
		rm -f "$plist"
		echo "$label provisioning profile does not authorize current-user isolation" >&2
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

assert_profile_icloud_environment() {
	local profile="$1"
	local label="$2"
	local environment="$3"
	local plist
	local configured_environment
	plist="$(mktemp)"
	security cms -D -i "$profile" -o "$plist"
	configured_environment="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' "$plist" 2>/dev/null || true)"
	if [[ "$configured_environment" != "$environment" ]] \
		&& ! plist_array_contains_value "$plist" 'Entitlements:com.apple.developer.icloud-container-environment' "$environment"; then
		rm -f "$plist"
		echo "$label provisioning profile does not authorize iCloud environment: $environment" >&2
		exit 1
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
	local destination="$directory/$uuid.provisionprofile"
	mkdir -p "$directory"
	if [[ "$profile" == "$destination" ]]; then
		return 0
	fi
	cp "$profile" "$destination"
}

validate_marketing_version() {
	if [[ -z "$marketing_version" ]]; then
		echo "App Store marketing version is required; pass --version <active-companion-app-store-version>" >&2
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
	app_profile="${app_profile:-.build/provisioning-appstore/ContextPanelCompanion.provisionprofile}"
	xcode_destination="generic/platform=iOS"
	platform_label="iOS"
	app_store_platform="IOS"
	profile_platforms=(iOS)
	;;
visionos)
	app_profile="${app_profile:-.build/provisioning-appstore/ContextPanelCompanion.provisionprofile}"
	xcode_destination="generic/platform=visionOS"
	platform_label="visionOS"
	app_store_platform="VISION_OS"
	profile_platforms=(visionOS xrOS)
	assert_visionos_packaging_ready
	;;
tvos)
	scheme="ContextPanelTV"
	app_profile="${app_profile:-${COMPANION_APP_STORE_TV_PROVISIONING_PROFILE:-.build/provisioning-appstore/ContextPanelTV.provisionprofile}}"
	xcode_destination="generic/platform=tvOS"
	platform_label="tvOS"
	app_store_platform="TV_OS"
	profile_platforms=(tvOS)
	;;
*)
	echo "unsupported companion platform: $platform" >&2
	exit 2
	;;
esac

archive_path="${archive_path:-.build/app-store-connect-companion/$scheme-$platform_label.xcarchive}"
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

assert_tvos_archive_ready() {
	local app_path="$archive_path/Products/Applications/Context Panel.app"
	local top_shelf_path="$app_path/PlugIns/ContextPanelTVTopShelfExtension.appex"
	local icon_name top_shelf_image top_shelf_image_wide
	if [[ -e "$app_path/PlugIns/ContextPanelCompanionWidgetExtension.appex" ]]; then
		echo "tvOS archive unexpectedly contains the iOS/visionOS companion widget" >&2
		exit 1
	fi
	if [[ ! -d "$top_shelf_path" ]]; then
		echo "tvOS archive is missing the embedded Top Shelf extension: $top_shelf_path" >&2
		exit 1
	fi
	if ! /usr/bin/plutil -extract UIRequiredDeviceCapabilities json -o - "$top_shelf_path/Info.plist" 2>/dev/null \
		| /usr/bin/grep -q '"arm64"'; then
		echo "tvOS Top Shelf extension is missing the required arm64 device capability" >&2
		exit 1
	fi
	if [[ ! -f "$app_path/Assets.car" ]]; then
		echo "tvOS archive is missing compiled brand assets: $app_path/Assets.car" >&2
		exit 1
	fi
	icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon' "$app_path/Info.plist" 2>/dev/null || true)"
	if [[ "$icon_name" != "App Icon - Small" ]]; then
		echo "tvOS archive is missing the primary layered app icon" >&2
		exit 1
	fi
	top_shelf_image="$(/usr/libexec/PlistBuddy -c 'Print :TVTopShelfImage:TVTopShelfPrimaryImage' "$app_path/Info.plist" 2>/dev/null || true)"
	top_shelf_image_wide="$(/usr/libexec/PlistBuddy -c 'Print :TVTopShelfImage:TVTopShelfPrimaryImageWide' "$app_path/Info.plist" 2>/dev/null || true)"
	if [[ -z "$top_shelf_image" || -z "$top_shelf_image_wide" ]]; then
		echo "tvOS archive is missing required standard or wide Top Shelf artwork" >&2
		exit 1
	fi
}

extract_signed_entitlements() {
	local bundle="$1"
	local label="$2"
	local destination="$3"
	if ! /usr/bin/codesign -d --entitlements - --xml "$bundle" >"$destination" 2>/dev/null; then
		echo "could not read signed entitlements from $label: $bundle" >&2
		exit 1
	fi
	if ! /usr/bin/plutil -lint "$destination" >/dev/null; then
		echo "$label signed entitlements are not a valid property list" >&2
		exit 1
	fi
}

assert_signed_entitlement_array_value() {
	local entitlements="$1"
	local label="$2"
	local key="$3"
	local value="$4"
	if ! plist_array_contains_value "$entitlements" "$key" "$value"; then
		echo "$label signed entitlements do not contain $key value: $value" >&2
		exit 1
	fi
}

assert_signed_entitlement_array_value_absent() {
	local entitlements="$1"
	local label="$2"
	local key="$3"
	local value="$4"
	if plist_array_contains_value "$entitlements" "$key" "$value"; then
		echo "$label signed entitlements unexpectedly contain $key value: $value" >&2
		exit 1
	fi
}

assert_signed_entitlement_value() {
	local entitlements="$1"
	local label="$2"
	local key="$3"
	local expected_value="$4"
	local actual_value
	actual_value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" 2>/dev/null || true)"
	if [[ "$actual_value" != "$expected_value" ]]; then
		echo "$label signed entitlements have $key value '$actual_value', expected '$expected_value'" >&2
		exit 1
	fi
}

assert_signed_entitlement_absent() {
	local entitlements="$1"
	local label="$2"
	local key="$3"
	if /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" >/dev/null 2>&1; then
		echo "$label signed entitlements unexpectedly contain: $key" >&2
		exit 1
	fi
}

assert_ios_watch_archive_ready() {
	local watch_app_path="$archive_path/Products/Applications/Context Panel.app/Watch/Context Panel.app"
	local watch_widget_path="$watch_app_path/PlugIns/ContextPanelWatchWidgetExtension.appex"
	local entitlements_dir
	local watch_app_entitlements
	local watch_widget_entitlements
	if [[ ! -d "$watch_app_path" ]]; then
		echo "iOS archive is missing the embedded Watch app: $watch_app_path" >&2
		exit 1
	fi
	if [[ ! -d "$watch_widget_path" ]]; then
		echo "iOS archive is missing the embedded Watch complication extension: $watch_widget_path" >&2
		exit 1
	fi
	entitlements_dir="$(mktemp -d)"
	watch_app_entitlements="$entitlements_dir/watch-app.plist"
	watch_widget_entitlements="$entitlements_dir/watch-widget.plist"
	extract_signed_entitlements "$watch_app_path" "companion Watch app" "$watch_app_entitlements"
	extract_signed_entitlements "$watch_widget_path" "companion Watch widget" "$watch_widget_entitlements"
	assert_signed_entitlement_absent "$watch_app_entitlements" "companion Watch app" \
		'com.apple.security.application-groups'
	assert_signed_entitlement_array_value "$watch_app_entitlements" "companion Watch app" \
		'com.apple.developer.icloud-container-identifiers' 'iCloud.com.shinycomputers.contextpanel'
	assert_signed_entitlement_array_value "$watch_app_entitlements" "companion Watch app" \
		'com.apple.developer.icloud-services' 'CloudKit'
	assert_signed_entitlement_value "$watch_app_entitlements" "companion Watch app" \
		'com.apple.developer.icloud-container-environment' 'Production'
	assert_signed_entitlement_absent "$watch_widget_entitlements" "companion Watch widget" \
		'com.apple.security.application-groups'
	assert_signed_entitlement_array_value "$watch_widget_entitlements" "companion Watch widget" \
		'com.apple.developer.icloud-container-identifiers' 'iCloud.com.shinycomputers.contextpanel'
	assert_signed_entitlement_array_value "$watch_widget_entitlements" "companion Watch widget" \
		'com.apple.developer.icloud-services' 'CloudKit'
	assert_signed_entitlement_value "$watch_widget_entitlements" "companion Watch widget" \
		'com.apple.developer.icloud-container-environment' 'Production'
	rm -rf "$entitlements_dir"
}

assert_companion_widget_archive_ready() {
	local widget_path="$archive_path/Products/Applications/Context Panel.app/PlugIns/ContextPanelCompanionWidgetExtension.appex"
	local entitlements_dir
	local widget_entitlements
	if [[ ! -d "$widget_path" ]]; then
		echo "companion archive is missing the embedded widget extension: $widget_path" >&2
		exit 1
	fi
	entitlements_dir="$(mktemp -d)"
	widget_entitlements="$entitlements_dir/companion-widget.plist"
	extract_signed_entitlements "$widget_path" "companion widget" "$widget_entitlements"
	assert_signed_entitlement_array_value "$widget_entitlements" "companion widget" \
		'com.apple.security.application-groups' 'group.com.shinycomputers.contextpanel'
	assert_signed_entitlement_array_value "$widget_entitlements" "companion widget" \
		'com.apple.developer.icloud-container-identifiers' 'iCloud.com.shinycomputers.contextpanel'
	assert_signed_entitlement_array_value "$widget_entitlements" "companion widget" \
		'com.apple.developer.icloud-services' 'CloudKit'
	assert_signed_entitlement_array_value_absent "$widget_entitlements" "companion widget" \
		'com.apple.developer.icloud-services' 'CloudDocuments'
	assert_signed_entitlement_value "$widget_entitlements" "companion widget" \
		'com.apple.developer.icloud-container-environment' 'Production'
	assert_signed_entitlement_absent "$widget_entitlements" "companion widget" \
		'com.apple.developer.ubiquity-container-identifiers'
	assert_signed_entitlement_absent "$widget_entitlements" "companion widget" \
		'aps-environment'
	rm -rf "$entitlements_dir"
}

validate_marketing_version

if [[ ! -f "$app_profile" ]]; then
	echo "companion app provisioning profile not found: $app_profile" >&2
	exit 1
fi
if [[ "$platform" != "tvos" && ! -f "$widget_profile" ]]; then
	echo "companion widget provisioning profile not found: $widget_profile" >&2
	exit 1
fi
if [[ "$platform" == "ios" && ! -f "$watch_profile" ]]; then
	echo "companion watch provisioning profile not found: $watch_profile" >&2
	exit 1
fi
if [[ "$platform" == "ios" && ! -f "$watch_widget_profile" ]]; then
	echo "companion watch widget provisioning profile not found: $watch_widget_profile" >&2
	exit 1
fi
if [[ "$platform" == "tvos" && ! -f "$tv_top_shelf_profile" ]]; then
	echo "tvOS Top Shelf provisioning profile not found: $tv_top_shelf_profile" >&2
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
widget_profile_uuid=""
watch_profile_uuid=""
watch_widget_profile_uuid=""
tv_top_shelf_profile_uuid=""
if [[ "$platform" != "tvos" ]]; then
	widget_profile_uuid="$(profile_uuid "$widget_profile")"
fi
if [[ "$platform" == "ios" ]]; then
	watch_profile_uuid="$(profile_uuid "$watch_profile")"
	watch_widget_profile_uuid="$(profile_uuid "$watch_widget_profile")"
fi
if [[ "$platform" == "tvos" ]]; then
	tv_top_shelf_profile_uuid="$(profile_uuid "$tv_top_shelf_profile")"
fi
assert_profile_bundle_id "$app_profile" "companion app" "com.shinycomputers.contextpanel"
assert_profile_platform_any "$app_profile" "companion app" "${profile_platforms[@]}"
if [[ "$platform" != "tvos" ]]; then
	assert_profile_bundle_id "$widget_profile" "companion widget" "com.shinycomputers.contextpanel.widget"
	assert_profile_platform_any "$widget_profile" "companion widget" "${profile_platforms[@]}"
	assert_profile_icloud_service "$widget_profile" "companion widget" "CloudKit"
	assert_profile_icloud_environment "$widget_profile" "companion widget" "Production"
fi
if [[ "$platform" == "ios" ]]; then
	assert_profile_bundle_id "$watch_profile" "companion watch" "com.shinycomputers.contextpanel.watch"
	assert_profile_bundle_id "$watch_widget_profile" "companion watch widget" "com.shinycomputers.contextpanel.watch.widget"
	assert_profile_platform_any "$watch_profile" "companion watch" iOS watchOS
	assert_profile_platform_any "$watch_widget_profile" "companion watch widget" iOS watchOS
	assert_profile_icloud_service "$watch_profile" "companion watch" "CloudKit"
	assert_profile_icloud_service "$watch_widget_profile" "companion watch widget" "CloudKit"
	assert_profile_icloud_environment "$watch_profile" "companion watch" "Production"
	assert_profile_icloud_environment "$watch_widget_profile" "companion watch widget" "Production"
fi
if [[ "$platform" == "tvos" ]]; then
	assert_profile_bundle_id "$tv_top_shelf_profile" "tvOS Top Shelf" "com.shinycomputers.contextpanel.topshelf"
	assert_profile_platform_any "$tv_top_shelf_profile" "tvOS Top Shelf" tvOS
fi
assert_profile_icloud_service "$app_profile" "companion app" "CloudKit"
assert_profile_icloud_environment "$app_profile" "companion app" "Production"
assert_profile_push_notifications "$app_profile" "companion app" "production"
if [[ "$platform" == "tvos" ]]; then
	assert_profile_app_group "$app_profile" "tvOS app"
	assert_profile_user_management "$app_profile" "tvOS app"
	assert_profile_app_group "$tv_top_shelf_profile" "tvOS Top Shelf"
	assert_profile_user_management "$tv_top_shelf_profile" "tvOS Top Shelf"
else
	assert_profile_app_group "$app_profile" "companion app"
	assert_profile_app_group "$widget_profile" "companion widget"
	assert_profile_icloud_service "$app_profile" "companion app" "CloudDocuments"
	assert_profile_ubiquity_container "$app_profile" "companion app"
fi
install_profile "$app_profile" "$app_profile_uuid"
if [[ "$platform" != "tvos" ]]; then
	install_profile "$widget_profile" "$widget_profile_uuid"
fi
if [[ "$platform" == "ios" ]]; then
	install_profile "$watch_profile" "$watch_profile_uuid"
	install_profile "$watch_widget_profile" "$watch_widget_profile_uuid"
fi
if [[ "$platform" == "tvos" ]]; then
	install_profile "$tv_top_shelf_profile" "$tv_top_shelf_profile_uuid"
fi

mkdir -p "$(dirname "$export_options_path")"
widget_export_profile_plist=""
watch_export_profile_plist=""
tv_top_shelf_export_profile_plist=""
if [[ "$platform" != "tvos" ]]; then
	widget_export_profile_plist="
			<key>com.shinycomputers.contextpanel.widget</key>
			<string>$widget_profile_uuid</string>"
fi
if [[ "$platform" == "ios" ]]; then
	watch_export_profile_plist="
		<key>com.shinycomputers.contextpanel.watch</key>
		<string>$watch_profile_uuid</string>
		<key>com.shinycomputers.contextpanel.watch.widget</key>
		<string>$watch_widget_profile_uuid</string>"
fi
if [[ "$platform" == "tvos" ]]; then
	tv_top_shelf_export_profile_plist="
		<key>com.shinycomputers.contextpanel.topshelf</key>
		<string>$tv_top_shelf_profile_uuid</string>"
fi
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
$tv_top_shelf_export_profile_plist
$widget_export_profile_plist
$watch_export_profile_plist
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
)
if [[ "$platform" == "tvos" ]]; then
	archive_args+=(CONTEXT_PANEL_APP_STORE_TV_PROFILE_SPECIFIER="$app_profile_uuid")
	archive_args+=(CONTEXT_PANEL_APP_STORE_TV_TOP_SHELF_PROFILE_SPECIFIER="$tv_top_shelf_profile_uuid")
else
	archive_args+=(CONTEXT_PANEL_APP_STORE_COMPANION_PROFILE_SPECIFIER="$app_profile_uuid")
	archive_args+=(CONTEXT_PANEL_APP_STORE_COMPANION_WIDGET_PROFILE_SPECIFIER="$widget_profile_uuid")
fi
if [[ "$platform" == "ios" ]]; then
	archive_args+=(CONTEXT_PANEL_APP_STORE_WATCH_PROFILE_SPECIFIER="$watch_profile_uuid")
	archive_args+=(CONTEXT_PANEL_APP_STORE_WATCH_WIDGET_PROFILE_SPECIFIER="$watch_widget_profile_uuid")
fi
if [[ -n "$build_number" ]]; then
	archive_args+=(CURRENT_PROJECT_VERSION="$build_number")
fi
if [[ -n "$marketing_version" ]]; then
	archive_args+=(MARKETING_VERSION="$marketing_version")
fi

rm -rf "$archive_path" "$derived_data_path" "$export_path"
run_xcodebuild "${archive_args[@]}" archive
if [[ "$platform" == "tvos" ]]; then
	assert_tvos_archive_ready
else
	assert_companion_widget_archive_ready
	if [[ "$platform" == "ios" ]]; then
		assert_ios_watch_archive_ready
	fi
fi

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
