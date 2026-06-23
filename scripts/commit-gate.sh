#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_cache_root="${CONTEXT_PANEL_ARTIFACT_CACHE_ROOT:-}"
swiftpm_scratch_path="${CONTEXT_PANEL_SWIFTPM_SCRATCH_PATH:-}"

artifact_cache_root_is_available() {
	local cache_parent cache_namespace
	cache_parent="$(dirname "$artifact_cache_root")"
	cache_namespace="$(dirname "$cache_parent")"
	[[ -d "$artifact_cache_root" || -d "$cache_namespace" ]]
}

if [[ -z "$swiftpm_scratch_path" && -n "$artifact_cache_root" ]] && artifact_cache_root_is_available; then
	swiftpm_scratch_path="$artifact_cache_root/swiftpm"
fi

swift_args=()
if [[ -n "$swiftpm_scratch_path" ]]; then
	mkdir -p "$swiftpm_scratch_path"
	swift_args+=(--scratch-path "$swiftpm_scratch_path")
else
	swiftpm_scratch_path="$repo_root/.build"
	swift_args+=(--scratch-path "$swiftpm_scratch_path")
fi

echo "commit gate SwiftPM scratch path: $swiftpm_scratch_path"

swift build "${swift_args[@]}"
swift test "${swift_args[@]}"
