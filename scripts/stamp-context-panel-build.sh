#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="${1:-$repo_root/.build/DerivedData/Build/Products/Debug/Context Panel.app}"
fingerprint="$("$repo_root/scripts/context-panel-build-fingerprint.sh")"

stamp_bundle() {
	local bundle="$1"
	[[ -d "$bundle" ]] || return 0
	local resources="$bundle/Contents/Resources"
	mkdir -p "$resources"
	printf '%s\n' "$fingerprint" >"$resources/ContextPanelBuildFingerprint.txt"
}

stamp_bundle "$app_path"

printf 'ContextPanelBuildFingerprint=%s\n' "$fingerprint"
