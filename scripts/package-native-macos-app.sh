#!/usr/bin/env bash
set -euo pipefail

scheme="ContextPanel"
configuration="Release"
output_dir="dist"
derived_data_path=".build/xcode-derived-release"
display_name="Context Panel"
version="1.0.0"
signing_identity="auto"
app_provisioning_profile=""
widget_provisioning_profile=""
notarize="false"

usage() {
	cat <<'USAGE'
Usage: scripts/package-native-macos-app.sh [options]

Builds the native Xcode app target with its embedded WidgetKit extension,
signs the bundle, optionally notarizes it, and writes a zip artifact.

Options:
  --version VERSION                    Release version used in the zip name.
  --output DIR                         Output directory. Default: dist
  --derived-data-path DIR              Xcode derived data path.
  --configuration NAME                 Xcode configuration. Default: Release
  --identity VALUE                     codesign identity, "auto", or "-" for ad-hoc.
  --app-provisioning-profile PATH      Optional app embedded.provisionprofile.
  --widget-provisioning-profile PATH   Optional widget embedded.provisionprofile.
  --notarize                           Submit the zipped app to Apple notarization.
  -h, --help                           Show this help.

Notarization reads APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD
from the environment. The script does not read private keys or credentials;
signing is performed by macOS Keychain through codesign.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--version)
		version="${2:?--version requires a value}"
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
	--notarize)
		notarize="true"
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

resolve_identity() {
	if [[ "$signing_identity" != "auto" ]]; then
		printf '%s\n' "$signing_identity"
		return
	fi

	local identity
	identity=$(security find-identity -v -p codesigning 2>/dev/null |
		sed -n 's/^.*"\(Developer ID Application:[^"]*\)".*$/\1/p' |
		head -n 1)
	if [[ -z "$identity" ]]; then
		identity=$(security find-identity -v -p codesigning 2>/dev/null |
			sed -n 's/^.*"\(Apple Distribution:[^"]*\)".*$/\1/p' |
			head -n 1)
	fi
	if [[ -z "$identity" ]]; then
		identity=$(security find-identity -v -p codesigning 2>/dev/null |
			sed -n 's/^.*"\(Apple Development:[^"]*\)".*$/\1/p' |
			head -n 1)
	fi
	printf '%s\n' "${identity:--}"
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

require_command xcodegen
require_command xcodebuild
require_command codesign
require_command ditto

resolved_identity=$(resolve_identity)
app_name="$display_name.app"
product_dir="$derived_data_path/Build/Products/$configuration"
built_app_path="$product_dir/$app_name"
app_path="$output_dir/$app_name"
zip_path="$output_dir/ContextPanel-$version-macOS.zip"
metadata_path="$output_dir/release-metadata.json"

xcodegen generate --spec project.yml

xcodebuild \
	-project ContextPanel.xcodeproj \
	-scheme "$scheme" \
	-configuration "$configuration" \
	-derivedDataPath "$derived_data_path" \
	-destination 'platform=macOS' \
	CODE_SIGNING_ALLOWED=NO \
	build

if [[ ! -d "$built_app_path" ]]; then
	echo "built app not found: $built_app_path" >&2
	exit 1
fi

rm -rf "$app_path" "$zip_path"
mkdir -p "$output_dir"
ditto "$built_app_path" "$app_path"

widget_path="$app_path/Contents/PlugIns/ContextPanelWidgetExtension.appex"
if [[ ! -d "$widget_path" ]]; then
	echo "embedded widget extension not found: $widget_path" >&2
	exit 1
fi

copy_profile_if_present "$widget_provisioning_profile" "$widget_path/Contents/embedded.provisionprofile"
copy_profile_if_present "$app_provisioning_profile" "$app_path/Contents/embedded.provisionprofile"

codesign --force --sign "$resolved_identity" \
	--entitlements Config/ContextPanelWidget.entitlements \
	"$widget_path"
codesign --force --sign "$resolved_identity" \
	--entitlements Config/ContextPanel.entitlements \
	"$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

if [[ "$notarize" == "true" ]]; then
	if [[ "$resolved_identity" == "-" ]]; then
		echo "notarization requires a non-ad-hoc signing identity" >&2
		exit 1
	fi
	for name in APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; do
		if [[ -z "${!name:-}" ]]; then
			echo "notarization requires $name" >&2
			exit 1
		fi
	done

	notary_zip="$output_dir/ContextPanel-$version-notary.zip"
	rm -f "$notary_zip"
	ditto -c -k --keepParent "$app_path" "$notary_zip"
	xcrun notarytool submit "$notary_zip" \
		--apple-id "$APPLE_ID" \
		--team-id "$APPLE_TEAM_ID" \
		--password "$APPLE_APP_SPECIFIC_PASSWORD" \
		--wait
	xcrun stapler staple "$app_path"
	xcrun stapler validate "$app_path"
fi

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

cat >"$metadata_path" <<JSON
{
  "version": "$version",
  "configuration": "$configuration",
  "app": "$app_path",
  "zip": "$zip_path",
  "signingIdentity": "$resolved_identity",
  "notarized": $notarize
}
JSON

echo "Packaged: $app_path"
echo "Zip: $zip_path"
echo "Signing identity: $resolved_identity"
echo "Notarized: $notarize"
