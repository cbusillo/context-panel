#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_cache_root="${CONTEXT_PANEL_ARTIFACT_CACHE_ROOT:-}"
swiftpm_scratch_path="${CONTEXT_PANEL_SWIFTPM_SCRATCH_PATH:-}"

if [[ -z "$swiftpm_scratch_path" && -n "$artifact_cache_root" ]]; then
	swiftpm_scratch_path="$artifact_cache_root/swiftpm"
fi

swift_args=()
if [[ -n "$swiftpm_scratch_path" ]]; then
	mkdir -p "$swiftpm_scratch_path"
	swift_args+=(--scratch-path "$swiftpm_scratch_path")
else
	swift_args+=(--scratch-path "$repo_root/.build")
fi

swift build "${swift_args[@]}"
swift test "${swift_args[@]}"
