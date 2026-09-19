#!/usr/bin/env bash
# Fails when Validation Gallery code is linked into an app extension.
# The gallery is operator-only host-app code; widget, Watch widget, and Top Shelf
# extensions must never carry it. The host app must visibly carry it, which proves
# the detector can see gallery code in this build configuration.
set -euo pipefail

marker="ContextPanelValidation"

usage() {
	echo "Usage: $0 APP_BUNDLE | --products-root BUILD_PRODUCTS_DIR" >&2
}

bundle_executable() {
	local bundle="$1" name=""
	if [[ -f "$bundle/Info.plist" ]]; then
		name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist" 2>/dev/null || true)"
	fi
	if [[ -z "$name" ]]; then
		name="$(basename "$bundle")"
		name="${name%.*}"
	fi
	printf '%s/%s' "$bundle" "$name"
}

binary_reference_count() {
	local binary="$1" symbols strings_count
	symbols="$(nm "$binary" 2>/dev/null | grep -c "$marker" || true)"
	strings_count="$(strings -a "$binary" 2>/dev/null | grep -c "$marker" || true)"
	printf '%s' "$((symbols + strings_count))"
}

# Debug builds keep the target's code in <name>.debug.dylib beside a stub
# executable, so count the executable and every dylib at the bundle's top level.
gallery_reference_count() {
	local bundle="$1" total=0 candidate
	for candidate in "$(bundle_executable "$bundle")" "$bundle"/*.dylib; do
		[[ -f "$candidate" ]] || continue
		total=$((total + $(binary_reference_count "$candidate")))
	done
	printf '%s' "$total"
}

check_app_bundle() {
	local app_bundle="$1" host_binary extension extension_binary count
	local status=0 extension_count=0
	if [[ ! -d "$app_bundle" ]]; then
		echo "app bundle not found: $app_bundle" >&2
		return 2
	fi
	host_binary="$(bundle_executable "$app_bundle")"
	if [[ ! -f "$host_binary" ]]; then
		echo "app executable not found: $host_binary" >&2
		return 2
	fi
	if [[ "$(gallery_reference_count "$app_bundle")" == "0" ]]; then
		echo "cannot verify gallery isolation: no Validation Gallery code is visible in the host app $host_binary" >&2
		return 1
	fi
	while IFS= read -r -d '' extension; do
		extension_count=$((extension_count + 1))
		extension_binary="$(bundle_executable "$extension")"
		if [[ ! -f "$extension_binary" ]]; then
			echo "extension executable not found: $extension_binary" >&2
			status=1
			continue
		fi
		count="$(gallery_reference_count "$extension")"
		if [[ "$count" != "0" ]]; then
			echo "Validation Gallery code is linked into an extension ($count references): $extension_binary" >&2
			status=1
		fi
	done < <(find "$app_bundle" -type d -name '*.appex' -print0)
	if ((status == 0)); then
		echo "Validation Gallery isolation OK: $app_bundle ($extension_count extensions carry no gallery code)"
	fi
	return "$status"
}

app_bundles=()
if [[ $# -eq 2 && "$1" == "--products-root" ]]; then
	while IFS= read -r -d '' found; do
		app_bundles+=("$found")
	done < <(find "$2" -mindepth 2 -maxdepth 2 -type d -name 'Context Panel*.app' -print0 2>/dev/null)
	if ((${#app_bundles[@]} == 0)); then
		echo "no app bundle found under build products: $2" >&2
		exit 2
	fi
elif [[ $# -eq 1 ]]; then
	app_bundles=("$1")
else
	usage
	exit 2
fi

overall=0
for app_bundle in "${app_bundles[@]}"; do
	check_app_bundle "$app_bundle" || overall=$?
done
exit "$overall"
