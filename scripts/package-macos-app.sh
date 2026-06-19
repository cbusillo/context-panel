#!/usr/bin/env bash
set -euo pipefail

product="ContextPanelApp"
display_name="Context Panel"
bundle_id="com.shinycomputers.contextpanel"
configuration="release"
output_dir="dist"
signing_identity="auto"

usage() {
	cat <<'USAGE'
Usage: scripts/package-macos-app.sh [options]

Builds a SwiftPM executable and wraps it in a launchable macOS .app bundle.

Options:
  --product NAME          SwiftPM executable product. Default: ContextPanelApp
  --display-name NAME     App display name. Default: Context Panel
  --bundle-id ID          CFBundleIdentifier. Default: com.shinycomputers.contextpanel
  --debug                 Build debug instead of release
  --output DIR            Output directory. Default: dist
  --identity VALUE        codesign identity, "auto", or "-" for ad-hoc. Default: auto
  -h, --help              Show this help

The script never reads private keys or credentials. When --identity auto is
used, it asks Keychain for signing identities and prefers Developer ID
Application, then Apple Development, then ad-hoc signing.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--product)
		product="${2:?--product requires a value}"
		shift 2
		;;
	--display-name)
		display_name="${2:?--display-name requires a value}"
		shift 2
		;;
	--bundle-id)
		bundle_id="${2:?--bundle-id requires a value}"
		shift 2
		;;
	--debug)
		configuration="debug"
		shift
		;;
	--output)
		output_dir="${2:?--output requires a value}"
		shift 2
		;;
	--identity)
		signing_identity="${2:?--identity requires a value}"
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

build_args=(--product "$product")
if [[ "$configuration" == "release" ]]; then
	build_args+=(--configuration release)
fi

swift build "${build_args[@]}"

bin_path_args=(--show-bin-path)
if [[ "$configuration" == "release" ]]; then
	bin_path_args+=(--configuration release)
fi
triple=$(swift build "${bin_path_args[@]}" 2>/dev/null || true)
if [[ -z "$triple" ]]; then
	if [[ "$configuration" == "release" ]]; then
		triple=".build/release"
	else
		triple=".build/debug"
	fi
fi

executable_path="$triple/$product"
if [[ ! -x "$executable_path" ]]; then
	echo "built executable not found: $executable_path" >&2
	exit 1
fi

app_path="$output_dir/$display_name.app"
contents="$app_path/Contents"
macos="$contents/MacOS"
resources="$contents/Resources"

rm -rf "$app_path"
mkdir -p "$macos" "$resources"
cp "$executable_path" "$macos/$product"

cat >"$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$product</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$display_name</string>
  <key>CFBundleDisplayName</key>
  <string>$display_name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' >"$contents/PkgInfo"

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
			sed -n 's/^.*"\(Apple Development:[^"]*\)".*$/\1/p' |
			head -n 1)
	fi
	printf '%s\n' "${identity:--}"
}

resolved_identity=$(resolve_identity)
if [[ "$resolved_identity" == "-" ]]; then
	codesign --force --sign - "$app_path"
else
	if ! codesign --force --options runtime --timestamp --sign "$resolved_identity" "$app_path"; then
		echo "Developer signing failed; retrying ad-hoc signing." >&2
		codesign --force --sign - "$app_path"
		resolved_identity="-"
	fi
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path" || true

echo "Packaged: $app_path"
echo "Executable: $product"
echo "Bundle ID: $bundle_id"
echo "Signing identity: $resolved_identity"
