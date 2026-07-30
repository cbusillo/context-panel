#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="${1:-$repo_root/.build/DerivedData/Build/Products/Debug/Context Panel.app}"
manifest_tmp="$(mktemp)"
trap 'rm -f "$manifest_tmp"' EXIT

marketing_version="${MARKETING_VERSION:-1.0}"
build_number="${CURRENT_PROJECT_VERSION:-1}"
configuration="${CONFIGURATION:-Debug}"
source_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf 'unknown')"
tree_state="unknown"
if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	if [[ -n "$(git -C "$repo_root" status --porcelain -- . ':(exclude)ContextPanel.xcodeproj/**' 2>/dev/null)" ]]; then
		tree_state="dirty"
	else
		tree_state="clean"
	fi
fi
xcode_build="${XCODE_PRODUCT_BUILD_VERSION:-}"
if [[ -z "$xcode_build" ]]; then
	xcode_build="$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/awk '/Build version/ { print $3; exit }')"
fi
xcode_build="${xcode_build:-unknown}"

manifest_status="valid"
if ! "$repo_root/scripts/context-panel-surface-manifest.py" generate \
	--root "$repo_root" \
	--marketing-version "$marketing_version" \
	--build-number "$build_number" \
	--commit "$source_commit" \
	--configuration "$configuration" \
	--xcode-build "$xcode_build" \
	--tree-state "$tree_state" \
	--output "$manifest_tmp"; then
	manifest_status="unknown"
	cat >"$manifest_tmp" <<JSON
{
  "schemaVersion": 1,
  "kind": "context-panel-surface-build-intent",
  "state": "unknown",
  "reason": "surface-policy-validation-failed"
}
JSON
fi

fingerprint="unknown"
if [[ "$manifest_status" == "valid" ]]; then
	fingerprint="$(
		/usr/bin/python3 - "$manifest_tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
for surface in manifest["surfaces"]:
    if surface["id"] == "macos.app":
        print(surface["fingerprints"]["combined"])
        break
else:
    raise SystemExit("macos.app surface is missing")
PY
	)"
fi

stamp_bundle() {
	local bundle="$1"
	[[ -d "$bundle" ]] || return 0
	local resources="$bundle"
	if [[ -d "$bundle/Contents" ]]; then
		resources="$bundle/Contents/Resources"
	fi
	mkdir -p "$resources"
	cp "$manifest_tmp" "$resources/ContextPanelSurfaceManifest.json"
	if [[ -f "$bundle/Contents/MacOS/Context Panel" ]]; then
		printf '%s\n' "$fingerprint" >"$resources/ContextPanelBuildFingerprint.txt"
	fi
}

stamp_bundle "$app_path"

printf 'ContextPanelBuildFingerprint=%s\n' "$fingerprint"
printf 'ContextPanelSurfaceManifest=%s\n' "$manifest_status"
