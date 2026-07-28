#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scheme="ContextPanel"
configuration="Release"
output_dir="dist"
derived_data_path=".build/xcode-derived-release"
display_name="Context Panel"
version="1.0.0"
build_number=""
signing_identity="auto"
codesigning_identity_output=""
app_provisioning_profile=""
widget_provisioning_profile=""
refresh_agent_provisioning_profile=""
notarize="false"
notary_keychain_profile=""
notary_key=""
notary_key_id="${APP_STORE_CONNECT_KEY_ID:-}"
notary_issuer="${APP_STORE_CONNECT_ISSUER_ID:-}"

usage() {
	cat <<'USAGE'
Usage: scripts/package-native-macos-app.sh [options]

Builds the native Xcode app target with its embedded WidgetKit extension,
signs the bundle, optionally notarizes it, and writes a zip artifact.

Options:
  --version VERSION                    Release version used in the zip name.
  --build-number VALUE                 Override CURRENT_PROJECT_VERSION.
  --output DIR                         Output directory. Default: dist
  --derived-data-path DIR              Xcode derived data path.
  --configuration NAME                 Xcode configuration. Default: Release
  --identity VALUE                     SHA-1 fingerprint, exact Keychain identity name,
                                      "auto", or "-" for ad-hoc.
  --app-provisioning-profile PATH      App profile; required for non-ad-hoc Release.
  --widget-provisioning-profile PATH   Widget profile; required for non-ad-hoc signing.
  --refresh-agent-provisioning-profile PATH
                                      Refresh-agent profile; required for non-ad-hoc Release.
  --notarize                           Submit the zipped app to Apple notarization.
  --notary-keychain-profile NAME       notarytool keychain profile for notarization.
  --notary-key PATH                    App Store Connect API private key path.
  --notary-key-id ID                   App Store Connect API key ID.
  --notary-issuer ID                   App Store Connect API issuer ID.
  -h, --help                           Show this help.

Notarization uses --notary-keychain-profile when provided, then App Store
Connect API key options or APP_STORE_CONNECT_KEY_ID and APP_STORE_CONNECT_ISSUER_ID
from the environment, then APPLE_ID, APPLE_TEAM_ID, and
APPLE_APP_SPECIFIC_PASSWORD from the environment. Signing is performed by
macOS Keychain through codesign.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--version)
		version="${2:?--version requires a value}"
		shift 2
		;;
	--build-number)
		build_number="${2:?--build-number requires a value}"
		shift 2
		;;
	--output)
		output_dir="${2:?--output requires a value}"
		shift 2
		;;
	--derived-data-path)
		derived_data_path="${2:?--derived-data-path requires a value}"
		shift 2
		;;
	--configuration)
		configuration="${2:?--configuration requires a value}"
		shift 2
		;;
	--identity)
		signing_identity="${2:?--identity requires a value}"
		shift 2
		;;
	--app-provisioning-profile)
		app_provisioning_profile="${2:?--app-provisioning-profile requires a value}"
		shift 2
		;;
	--widget-provisioning-profile)
		widget_provisioning_profile="${2:?--widget-provisioning-profile requires a value}"
		shift 2
		;;
	--refresh-agent-provisioning-profile)
		refresh_agent_provisioning_profile="${2:?--refresh-agent-provisioning-profile requires a value}"
		shift 2
		;;
	--notarize)
		notarize="true"
		shift
		;;
	--notary-keychain-profile)
		notary_keychain_profile="${2:?--notary-keychain-profile requires a value}"
		shift 2
		;;
	--notary-key)
		notary_key="${2:?--notary-key requires a value}"
		shift 2
		;;
	--notary-key-id)
		notary_key_id="${2:?--notary-key-id requires a value}"
		shift 2
		;;
	--notary-issuer)
		notary_issuer="${2:?--notary-issuer requires a value}"
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

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "required command not found: $1" >&2
		exit 1
	fi
}

normalize_certificate_fingerprint() {
	printf '%s' "$1" | tr -d ':' | tr '[:lower:]' '[:upper:]'
}

codesigning_identity_records() {
	local line fingerprint name
	while IFS= read -r line; do
		fingerprint="$(printf '%s\n' "$line" |
			sed -n 's/^[[:space:]]*[0-9][0-9]*) \([[:xdigit:]][[:xdigit:]]*\) ".*"[[:space:]]*$/\1/p')"
		fingerprint="$(normalize_certificate_fingerprint "$fingerprint")"
		if [[ "${#fingerprint}" -ne 40 || "$fingerprint" == *[!0-9A-F]* ]]; then
			continue
		fi
		name="${line#*\"}"
		if [[ "$name" == "$line" ]]; then
			continue
		fi
		name="${name%%\"*}"
		printf '%s\t%s\n' "$fingerprint" "$name"
	done <<<"$codesigning_identity_output"
}

load_codesigning_identities() {
	local output
	if ! output="$(security find-identity -v -p codesigning 2>&1)"; then
		echo "could not list valid codesigning identities" >&2
		return 1
	fi
	codesigning_identity_output="$output"
}

identity_hashes_for_selector() {
	local selector="$1"
	local mode="$2"
	local fingerprint name
	while IFS=$'\t' read -r fingerprint name; do
		case "$mode" in
		hash)
			[[ "$fingerprint" == "$selector" ]] || continue
			;;
		name)
			[[ "$name" == "$selector" ]] || continue
			;;
		prefix)
			[[ "$name" == "${selector}:"* ]] || continue
			;;
		esac
		printf '%s\n' "$fingerprint"
	done < <(codesigning_identity_records)
}

select_unique_signing_identity_hash() {
	local selector="$1"
	local mode="$2"
	local description="$3"
	local fingerprint existing duplicate
	local fingerprints=()
	while IFS= read -r fingerprint; do
		[[ -n "$fingerprint" ]] || continue
		duplicate=0
		if [[ "${#fingerprints[@]}" -gt 0 ]]; then
			for existing in "${fingerprints[@]}"; do
				if [[ "$existing" == "$fingerprint" ]]; then
					duplicate=1
					break
				fi
			done
		fi
		if [[ "$duplicate" == "0" ]]; then
			fingerprints+=("$fingerprint")
		fi
	done < <(identity_hashes_for_selector "$selector" "$mode")

	if [[ "${#fingerprints[@]}" == "0" ]]; then
		return 1
	fi
	if [[ "${#fingerprints[@]}" != "1" ]]; then
		echo "multiple valid $description signing certificates are available; pass an exact SHA-1 fingerprint with --identity" >&2
		return 2
	fi
	printf '%s\n' "${fingerprints[0]}"
}

resolve_identity() {
	local identity status normalized prefix
	if [[ "$signing_identity" != "auto" ]]; then
		if [[ "$signing_identity" == "-" ]]; then
			printf '%s\n' "-"
			return
		fi
		normalized="$(normalize_certificate_fingerprint "$signing_identity")"
		if [[ "${#normalized}" == "40" && "$normalized" != *[!0-9A-F]* ]]; then
			if identity="$(select_unique_signing_identity_hash "$normalized" hash "requested")"; then
				printf '%s\n' "$identity"
				return
			else
				status=$?
			fi
		else
			if identity="$(select_unique_signing_identity_hash "$signing_identity" name "named")"; then
				printf '%s\n' "$identity"
				return
			else
				status=$?
			fi
		fi
		if [[ "$status" == "1" ]]; then
			echo "signing identity is not available in the keychain: $signing_identity" >&2
		fi
		return "$status"
	fi

	for prefix in "Developer ID Application" "Apple Distribution" "Apple Development"; do
		if identity="$(select_unique_signing_identity_hash "$prefix" prefix "$prefix")"; then
			printf '%s\n' "$identity"
			return
		else
			status=$?
		fi
		if [[ "$status" == "2" ]]; then
			return "$status"
		fi
	done
	printf '%s\n' "-"
}

copy_profile_if_present() {
	local source="$1"
	local destination="$2"
	if [[ -n "$source" ]]; then
		if [[ ! -f "$source" ]]; then
			echo "provisioning profile not found: $source" >&2
			exit 1
		fi
		cp "$source" "$destination"
	fi
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

decode_provisioning_profile() {
	local profile="$1"
	local output="$2"
	if ! security cms -D -i "$profile" >"$output" 2>/dev/null; then
		echo "could not decode provisioning profile: $profile" >&2
		exit 1
	fi
}

merge_profile_application_entitlements() {
	local entitlements="$1"
	local profile="$2"
	if [[ -z "$profile" ]]; then
		return
	fi

	local profile_plist application_identifier team_identifier
	profile_plist=$(mktemp)
	decode_provisioning_profile "$profile" "$profile_plist"

	application_identifier="$(profile_entitlement_value "$profile_plist" com.apple.application-identifier)"
	if [[ -z "$application_identifier" ]]; then
		application_identifier="$(profile_entitlement_value "$profile_plist" application-identifier)"
	fi
	team_identifier="$(profile_entitlement_value "$profile_plist" com.apple.developer.team-identifier)"
	if [[ -z "$team_identifier" ]]; then
		team_identifier="$(plist_array_values "$profile_plist" TeamIdentifier | head -n 1)"
	fi
	rm -f "$profile_plist"

	if [[ -z "$application_identifier" ]]; then
		echo "provisioning profile is missing application identifier: $profile" >&2
		exit 1
	fi
	if [[ -z "$team_identifier" ]]; then
		echo "provisioning profile is missing team identifier: $profile" >&2
		exit 1
	fi

	/usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$entitlements" >/dev/null 2>&1 || true
	/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $application_identifier" "$entitlements"
	/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$entitlements" >/dev/null 2>&1 || true
	/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team_identifier" "$entitlements"
}

requires_cloudkit_profile() {
	local entitlements="$1"
	/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services' "$entitlements" 2>/dev/null |
		grep -Fq CloudKit
}

require_profile_for_cloudkit_entitlements() {
	local entitlements="$1"
	local profile="$2"
	local label="$3"
	if [[ "$resolved_identity" == "-" ]]; then
		return
	fi
	if requires_cloudkit_profile "$entitlements" && [[ -z "$profile" ]]; then
		echo "$label uses CloudKit entitlements and requires an embedded provisioning profile" >&2
		exit 1
	fi
}

require_non_ad_hoc_for_provisioning_profiles() {
	if [[ "$resolved_identity" == "-" && -n "$app_provisioning_profile$widget_provisioning_profile$refresh_agent_provisioning_profile" ]]; then
		echo "Context Panel packaging with provisioning profiles requires a non-ad-hoc signing identity" >&2
		exit 1
	fi
}

check_profile_authorizes_array_entitlement() {
	local profile_plist="$1"
	local entitlements_plist="$2"
	local label="$3"
	local entitlement="$4"
	local value
	while IFS= read -r value; do
		[[ -n "$value" ]] || continue
		if ! profile_entitlement_authorizes_value "$profile_plist" "$entitlement" "$value"; then
			echo "$label provisioning profile does not authorize $entitlement: $value" >&2
			exit 1
		fi
	done < <(plist_array_values "$entitlements_plist" "$entitlement")
}

check_profile_authorizes_scalar_entitlement() {
	local profile_plist="$1"
	local entitlements_plist="$2"
	local label="$3"
	local entitlement="$4"
	local expected profile_value
	expected="$(plist_scalar_value "$entitlements_plist" "$entitlement")"
	[[ -n "$expected" ]] || return 0
	if profile_entitlement_authorizes_value "$profile_plist" "$entitlement" "$expected"; then
		return 0
	fi
	echo "$label provisioning profile does not authorize $entitlement: $expected" >&2
	exit 1
}

validate_profile_covers_entitlements() {
	local profile="$1"
	local entitlements="$2"
	local label="$3"
	local bundle_identifier="$4"
	[[ -n "$profile" ]] || return 0

	local profile_plist profile_name profile_team entitlements_team profile_app_id expected_app_id
	profile_plist=$(mktemp)
	decode_provisioning_profile "$profile" "$profile_plist"

	profile_name="$(plist_scalar_value "$profile_plist" Name)"
	profile_team="$(plist_array_values "$profile_plist" TeamIdentifier | head -n 1)"
	entitlements_team="$(profile_entitlement_value "$profile_plist" com.apple.developer.team-identifier)"
	[[ -n "$profile_team" ]] || profile_team="$entitlements_team"
	profile_app_id="$(profile_entitlement_value "$profile_plist" com.apple.application-identifier)"
	[[ -n "$profile_app_id" ]] || profile_app_id="$(profile_entitlement_value "$profile_plist" application-identifier)"
	expected_app_id="${profile_team}.${bundle_identifier}"

	if [[ -z "$profile_name" ]]; then
		rm -f "$profile_plist"
		echo "$label provisioning profile has no Name" >&2
		exit 1
	fi
	if [[ -z "$profile_team" ]]; then
		rm -f "$profile_plist"
		echo "$label provisioning profile is missing team identifier" >&2
		exit 1
	fi
	if [[ "$profile_app_id" == *"*" ]]; then
		rm -f "$profile_plist"
		echo "$label provisioning profile must use an explicit application identifier for CloudKit packaging" >&2
		exit 1
	fi
	if [[ "$profile_app_id" != "$expected_app_id" ]]; then
		rm -f "$profile_plist"
		echo "$label provisioning profile does not authorize application identifier: $expected_app_id" >&2
		exit 1
	fi

	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements" "$label" "com.apple.security.application-groups"
	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements" "$label" "keychain-access-groups"
	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements" "$label" "com.apple.developer.icloud-container-identifiers"
	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements" "$label" "com.apple.developer.icloud-services"
	check_profile_authorizes_array_entitlement "$profile_plist" "$entitlements" "$label" "com.apple.developer.ubiquity-container-identifiers"
	check_profile_authorizes_scalar_entitlement "$profile_plist" "$entitlements" "$label" "com.apple.developer.icloud-container-environment"
	check_profile_authorizes_scalar_entitlement "$profile_plist" "$entitlements" "$label" "com.apple.developer.team-identifier"
	rm -f "$profile_plist"
}

require_profile_for_signed_bundle() {
	local profile="$1"
	local label="$2"
	if [[ "$resolved_identity" != "-" && -z "$profile" ]]; then
		echo "$label requires an embedded provisioning profile for non-ad-hoc signing" >&2
		exit 1
	fi
	return 0
}

assert_profile_authorizes_signing_identity() {
	local profile="$1"
	local label="$2"
	[[ "$resolved_identity" != "-" && -n "$profile" ]] || return 0

	local temp_dir profile_plist candidate_base64 candidate_der candidate_fingerprint index matched
	temp_dir="$(mktemp -d)"
	profile_plist="$temp_dir/profile.plist"
	candidate_base64="$temp_dir/certificate.base64"
	candidate_der="$temp_dir/certificate.der"
	decode_provisioning_profile "$profile" "$profile_plist"

	index=0
	matched=0
	while plutil -extract "DeveloperCertificates.$index" raw -o - "$profile_plist" >"$candidate_base64" 2>/dev/null; do
		if /usr/bin/base64 -D <"$candidate_base64" >"$candidate_der" 2>/dev/null; then
			candidate_fingerprint="$(shasum -a 1 "$candidate_der" | awk '{ print toupper($1) }')"
			if [[ "$candidate_fingerprint" == "$resolved_identity" ]]; then
				matched=1
				break
			fi
		fi
		index=$((index + 1))
	done
	rm -rf "$temp_dir"
	if [[ "$matched" != "1" ]]; then
		echo "$label provisioning profile does not authorize signing certificate $resolved_identity" >&2
		exit 1
	fi
}

assert_profile_matches_signing_certificate() {
	local bundle_path="$1"
	local profile="$2"
	local label="$3"
	[[ "$resolved_identity" != "-" && -n "$profile" ]] || return 0

	local temp_dir profile_plist candidate_base64 candidate_der index matched
	temp_dir="$(mktemp -d)"
	profile_plist="$temp_dir/profile.plist"
	candidate_base64="$temp_dir/certificate.base64"
	candidate_der="$temp_dir/certificate.der"
	decode_provisioning_profile "$profile" "$profile_plist"
	if ! codesign -d --extract-certificates="$temp_dir/signed-certificate" "$bundle_path" >/dev/null 2>&1; then
		rm -rf "$temp_dir"
		echo "could not extract the signing certificate for $label: $bundle_path" >&2
		exit 1
	fi

	index=0
	matched=0
	while plutil -extract "DeveloperCertificates.$index" raw -o - "$profile_plist" >"$candidate_base64" 2>/dev/null; do
		if /usr/bin/base64 -D <"$candidate_base64" >"$candidate_der" 2>/dev/null &&
			cmp -s "$temp_dir/signed-certificate0" "$candidate_der"; then
			matched=1
			break
		fi
		index=$((index + 1))
	done
	rm -rf "$temp_dir"
	if [[ "$matched" != "1" ]]; then
		echo "$label provisioning profile does not authorize the actual signing certificate" >&2
		exit 1
	fi
}

prepared_entitlements() {
	local source="$1"
	local profile="$2"
	local destination
	destination=$(mktemp)
	cp "$source" "$destination"
	merge_profile_application_entitlements "$destination" "$profile"
	printf '%s\n' "$destination"
}

assert_app_group_entitlement() {
	local bundle_path="$1"
	local label="$2"
	local plist
	plist=$(mktemp)
	if ! codesign -d --entitlements :- "$bundle_path" >"$plist" 2>/dev/null; then
		rm -f "$plist"
		echo "could not read signed entitlements for $label: $bundle_path" >&2
		exit 1
	fi
	if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$plist" 2>/dev/null |
		grep -Fq "MM5YXC7T6E.group.com.shinycomputers.contextpanel"; then
		rm -f "$plist"
		echo "$label is missing app group entitlement: MM5YXC7T6E.group.com.shinycomputers.contextpanel" >&2
		exit 1
	fi
	rm -f "$plist"
}

assert_entitlement_enabled() {
	local bundle_path="$1"
	local label="$2"
	local entitlement="$3"
	local plist
	plist=$(mktemp)
	if ! codesign -d --entitlements :- "$bundle_path" >"$plist" 2>/dev/null; then
		rm -f "$plist"
		echo "could not read signed entitlements for $label: $bundle_path" >&2
		exit 1
	fi
	if [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$plist" 2>/dev/null || true)" != "true" ]]; then
		rm -f "$plist"
		echo "$label is missing entitlement: $entitlement" >&2
		exit 1
	fi
	rm -f "$plist"
}

assert_entitlement_absent() {
	local bundle_path="$1"
	local label="$2"
	local entitlement="$3"
	local plist
	plist=$(mktemp)
	if ! codesign -d --entitlements :- "$bundle_path" >"$plist" 2>/dev/null; then
		rm -f "$plist"
		echo "could not read signed entitlements for $label: $bundle_path" >&2
		exit 1
	fi
	if /usr/libexec/PlistBuddy -c "Print :$entitlement" "$plist" >/dev/null 2>&1; then
		rm -f "$plist"
		echo "$label should not carry entitlement: $entitlement" >&2
		exit 1
	fi
	rm -f "$plist"
}

assert_entitlement_present() {
	local bundle_path="$1"
	local label="$2"
	local entitlement="$3"
	if [[ "$resolved_identity" == "-" ]]; then
		return
	fi
	local plist
	plist=$(mktemp)
	if ! codesign -d --entitlements :- "$bundle_path" >"$plist" 2>/dev/null; then
		rm -f "$plist"
		echo "could not read signed entitlements for $label: $bundle_path" >&2
		exit 1
	fi
	if ! /usr/libexec/PlistBuddy -c "Print :$entitlement" "$plist" >/dev/null 2>&1; then
		rm -f "$plist"
		echo "$label is missing entitlement: $entitlement" >&2
		exit 1
	fi
	rm -f "$plist"
}

require_command xcodegen
require_command xcodebuild
require_command codesign
require_command ditto
require_command security
require_command shasum
require_command xcrun

if [[ "$signing_identity" != "-" ]]; then
	load_codesigning_identities
fi
resolved_identity=$(resolve_identity)
app_name="$display_name.app"
product_dir="$derived_data_path/Build/Products/$configuration"
built_app_path="$product_dir/$app_name"
app_path="$output_dir/$app_name"
zip_path="$output_dir/ContextPanel-$version-macOS.zip"
metadata_path="$output_dir/release-metadata.json"
app_entitlements="Config/ContextPanel.entitlements"
widget_entitlements="Config/ContextPanelWidget.entitlements"
refresh_agent_entitlements="Config/ContextPanelRefreshAgent.entitlements"
if [[ "$configuration" == "Release" ]]; then
	app_entitlements="Config/ContextPanelAppStore.entitlements"
	refresh_agent_entitlements="Config/ContextPanelRefreshAgentAppStore.entitlements"
fi
require_profile_for_cloudkit_entitlements "$app_entitlements" "$app_provisioning_profile" "Context Panel app"
require_profile_for_cloudkit_entitlements "$refresh_agent_entitlements" "$refresh_agent_provisioning_profile" "Context Panel refresh agent"
require_non_ad_hoc_for_provisioning_profiles
validate_profile_covers_entitlements "$app_provisioning_profile" "$app_entitlements" "Context Panel app" "com.shinycomputers.contextpanel"
validate_profile_covers_entitlements "$refresh_agent_provisioning_profile" "$refresh_agent_entitlements" "Context Panel refresh agent" "com.shinycomputers.contextpanel.refresh-agent"
require_profile_for_signed_bundle "$widget_provisioning_profile" "Context Panel widget"
validate_profile_covers_entitlements "$widget_provisioning_profile" "$widget_entitlements" "Context Panel widget" "com.shinycomputers.contextpanel.widget"
assert_profile_authorizes_signing_identity "$app_provisioning_profile" "Context Panel app"
assert_profile_authorizes_signing_identity "$widget_provisioning_profile" "Context Panel widget"
assert_profile_authorizes_signing_identity "$refresh_agent_provisioning_profile" "Context Panel refresh agent"

xcodegen generate --spec project.yml

xcodebuild_args=(
	-project ContextPanel.xcodeproj
	-scheme "$scheme"
	-configuration "$configuration"
	-derivedDataPath "$derived_data_path"
	-destination 'platform=macOS'
	MARKETING_VERSION="$version"
	CODE_SIGNING_ALLOWED=NO
)
if [[ -n "$build_number" ]]; then
	xcodebuild_args+=(CURRENT_PROJECT_VERSION="$build_number")
fi
xcodebuild "${xcodebuild_args[@]}" build

if [[ ! -d "$built_app_path" ]]; then
	echo "built app not found: $built_app_path" >&2
	exit 1
fi

rm -rf "$app_path" "$zip_path"
mkdir -p "$output_dir"
ditto "$built_app_path" "$app_path"
"$repo_root/scripts/stamp-context-panel-build.sh" "$app_path"

widget_path="$app_path/Contents/PlugIns/ContextPanelWidgetExtension.appex"
if [[ ! -d "$widget_path" ]]; then
	echo "embedded widget extension not found: $widget_path" >&2
	exit 1
fi
refresh_agent_path="$app_path/Contents/Library/LoginItems/ContextPanelRefreshAgent.app"
if [[ ! -d "$refresh_agent_path" ]]; then
	echo "embedded refresh agent not found: $refresh_agent_path" >&2
	exit 1
fi

copy_profile_if_present "$widget_provisioning_profile" "$widget_path/Contents/embedded.provisionprofile"
copy_profile_if_present "$refresh_agent_provisioning_profile" "$refresh_agent_path/Contents/embedded.provisionprofile"
copy_profile_if_present "$app_provisioning_profile" "$app_path/Contents/embedded.provisionprofile"

widget_signing_entitlements="$(prepared_entitlements Config/ContextPanelWidget.entitlements "$widget_provisioning_profile")"
refresh_agent_signing_entitlements="$(prepared_entitlements "$refresh_agent_entitlements" "$refresh_agent_provisioning_profile")"
app_signing_entitlements="$(prepared_entitlements "$app_entitlements" "$app_provisioning_profile")"
trap 'rm -f "$widget_signing_entitlements" "$refresh_agent_signing_entitlements" "$app_signing_entitlements"' EXIT

codesign_options=(--force --sign "$resolved_identity")
hardened_runtime="false"
if [[ "$resolved_identity" != "-" ]]; then
	codesign_options+=(--options runtime --timestamp)
	hardened_runtime="true"
fi

codesign "${codesign_options[@]}" \
	--entitlements "$widget_signing_entitlements" \
	"$widget_path"
codesign "${codesign_options[@]}" \
	--entitlements "$refresh_agent_signing_entitlements" \
	"$refresh_agent_path"
codesign "${codesign_options[@]}" \
	--entitlements "$app_signing_entitlements" \
	"$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
assert_profile_matches_signing_certificate "$app_path" "$app_provisioning_profile" "Context Panel app"
assert_profile_matches_signing_certificate "$widget_path" "$widget_provisioning_profile" "Context Panel widget"
assert_profile_matches_signing_certificate "$refresh_agent_path" "$refresh_agent_provisioning_profile" "Context Panel refresh agent"
assert_app_group_entitlement "$app_path" "Context Panel app"
assert_app_group_entitlement "$widget_path" "Context Panel widget"
assert_app_group_entitlement "$refresh_agent_path" "Context Panel refresh agent"
assert_entitlement_present "$app_path" "Context Panel app" "com.apple.application-identifier"
assert_entitlement_present "$refresh_agent_path" "Context Panel refresh agent" "com.apple.application-identifier"
assert_entitlement_enabled "$app_path" "Context Panel app" "com.apple.security.app-sandbox"
assert_entitlement_enabled "$app_path" "Context Panel app" "com.apple.security.network.client"
assert_entitlement_absent "$app_path" "Context Panel app" "com.apple.security.network.server"
assert_entitlement_enabled "$app_path" "Context Panel app" "com.apple.security.files.bookmarks.app-scope"
assert_entitlement_absent "$widget_path" "Context Panel widget" "com.apple.security.network.server"
assert_entitlement_enabled "$refresh_agent_path" "Context Panel refresh agent" "com.apple.security.app-sandbox"
assert_entitlement_enabled "$refresh_agent_path" "Context Panel refresh agent" "com.apple.security.network.client"
assert_entitlement_absent "$refresh_agent_path" "Context Panel refresh agent" "com.apple.security.network.server"
assert_entitlement_enabled "$refresh_agent_path" "Context Panel refresh agent" "com.apple.security.files.bookmarks.app-scope"

if [[ "$notarize" == "true" ]]; then
	if [[ "$resolved_identity" == "-" ]]; then
		echo "notarization requires a non-ad-hoc signing identity" >&2
		exit 1
	fi
	notary_zip="$output_dir/ContextPanel-$version-notary.zip"
	rm -f "$notary_zip"
	ditto -c -k --keepParent "$app_path" "$notary_zip"
	notary_args=(notarytool submit "$notary_zip" --wait)
	if [[ -n "$notary_keychain_profile" ]]; then
		notary_args+=(--keychain-profile "$notary_keychain_profile")
	elif [[ -n "$notary_key" || -n "$notary_key_id" || -n "$notary_issuer" ]]; then
		if [[ -z "$notary_key" || -z "$notary_key_id" || -z "$notary_issuer" ]]; then
			echo "notarization with App Store Connect API requires --notary-key, --notary-key-id, and --notary-issuer" >&2
			exit 1
		fi
		if [[ ! -f "$notary_key" ]]; then
			echo "notary API private key not found: $notary_key" >&2
			exit 1
		fi
		notary_args+=(
			--key "$notary_key"
			--key-id "$notary_key_id"
			--issuer "$notary_issuer"
		)
	else
		for name in APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; do
			if [[ -z "${!name:-}" ]]; then
				echo "notarization requires --notary-keychain-profile, App Store Connect API credentials, or $name" >&2
				exit 1
			fi
		done
		notary_args+=(
			--apple-id "$APPLE_ID"
			--team-id "$APPLE_TEAM_ID"
			--password "$APPLE_APP_SPECIFIC_PASSWORD"
		)
	fi
	xcrun "${notary_args[@]}"
	xcrun stapler staple "$app_path"
	xcrun stapler validate "$app_path"
fi

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

cat >"$metadata_path" <<JSON
{
  "version": "$version",
  "buildNumber": "$build_number",
  "configuration": "$configuration",
  "app": "$app_path",
  "zip": "$zip_path",
  "signingIdentity": "$resolved_identity",
  "hardenedRuntime": $hardened_runtime,
  "notarized": $notarize
}
JSON

echo "Packaged: $app_path"
echo "Zip: $zip_path"
echo "Signing identity: $resolved_identity"
echo "Notarized: $notarize"
