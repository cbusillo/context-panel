#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
artifact_cache_root="${CONTEXT_PANEL_ARTIFACT_CACHE_ROOT:-}"
swiftpm_scratch_path="${CONTEXT_PANEL_SWIFTPM_SCRATCH_PATH:-}"
run_swift=true

usage() {
	echo "usage: scripts/commit-gate.sh [--skip-swift]" >&2
}

while (($# > 0)); do
	case "$1" in
	# For pull requests whose changed paths cannot affect the Swift package;
	# scripts/ci-change-scope.py makes that decision in CI.
	--skip-swift) run_swift=false ;;
	*)
		usage
		exit 64
		;;
	esac
	shift
done

artifact_cache_root_is_available() {
	local cache_parent cache_namespace
	cache_parent="$(dirname "$artifact_cache_root")"
	cache_namespace="$(dirname "$cache_parent")"
	[[ -d "$artifact_cache_root" || -d "$cache_namespace" ]]
}

checkout_cache_key() {
	local digest
	command -v shasum >/dev/null 2>&1 || return 1
	digest="$(
		printf '%s\0' "$repo_root" |
			shasum -a 256 |
			awk '{ print substr($1, 1, 16) }'
	)" || return 1
	[[ "$digest" =~ ^[0-9a-f]{16}$ ]] || return 1
	printf '%s' "$digest"
}

if [[ -z "$swiftpm_scratch_path" && -n "$artifact_cache_root" ]] && artifact_cache_root_is_available; then
	if cache_key="$(checkout_cache_key)"; then
		swiftpm_scratch_path="$artifact_cache_root/checkouts/$cache_key/swiftpm"
	fi
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

PYTHONDONTWRITEBYTECODE=1 \
	python3 scripts/context-panel-surface-manifest.py validate
PYTHONDONTWRITEBYTECODE=1 \
	python3 scripts/context-panel-test-lanes.py validate
PYTHONDONTWRITEBYTECODE=1 \
	python3 scripts/context-panel-test-lanes.py run \
		--lane fast-local-python

if [[ "$run_swift" != "true" ]]; then
	echo "commit gate: skipping swift build and swift test (--skip-swift)"
	exit 0
fi

swift build "${swift_args[@]}"
python3 scripts/context-panel-test-lanes.py time-command \
	--lane routine-ci-swift \
	-- swift test "${swift_args[@]}"
