#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_path=""
layout=""
marketing_version=""
build_number=""
configuration="Release"
output_path=""
profile_args=()

usage() {
	cat <<'USAGE'
Usage: scripts/context-panel-write-expected-build.sh \
  --archive PATH --layout NAME --version VERSION --build-number NUMBER \
  [--configuration NAME] [--profile ARTIFACT_ID=PATH] [--output PATH]
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--archive)
		archive_path="${2:?--archive requires a value}"
		shift 2
		;;
	--layout)
		layout="${2:?--layout requires a value}"
		shift 2
		;;
	--version)
		marketing_version="${2:?--version requires a value}"
		shift 2
		;;
	--build-number)
		build_number="${2:?--build-number requires a value}"
		shift 2
		;;
	--configuration)
		configuration="${2:?--configuration requires a value}"
		shift 2
		;;
	--profile)
		profile_args+=(--profile "${2:?--profile requires a value}")
		shift 2
		;;
	--output)
		output_path="${2:?--output requires a value}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

if [[ -z "$archive_path" || -z "$layout" || -z "$marketing_version" || -z "$build_number" ]]; then
	usage >&2
	exit 1
fi
if [[ ! -d "$archive_path" ]]; then
	echo "archive is unavailable" >&2
	exit 1
fi
if [[ -n "$(git -C "$repo_root" status --porcelain -- . ':(exclude)ContextPanel.xcodeproj/**')" ]]; then
	echo "expected-build manifests require a clean source tree" >&2
	exit 1
fi

source_commit="$(git -C "$repo_root" rev-parse HEAD)"
xcode_build="$(/usr/bin/xcodebuild -version | /usr/bin/awk '/Build version/ { print $3; exit }')"
if [[ -z "$xcode_build" ]]; then
	echo "Xcode build version is unavailable" >&2
	exit 1
fi
if [[ -z "$output_path" ]]; then
	output_path="$(dirname "$archive_path")/ExpectedBuildManifest-${layout}.json"
fi

source_manifest="$(mktemp)"
trap 'rm -f "$source_manifest"' EXIT

"$repo_root/scripts/context-panel-surface-manifest.py" generate \
	--root "$repo_root" \
	--marketing-version "$marketing_version" \
	--build-number "$build_number" \
	--commit "$source_commit" \
	--configuration "$configuration" \
	--xcode-build "$xcode_build" \
	--tree-state clean \
	--output "$source_manifest"

"$repo_root/scripts/context-panel-surface-manifest.py" collect-archive \
	--manifest "$source_manifest" \
	--archive "$archive_path" \
	--layout "$layout" \
	"${profile_args[@]}" \
	--output "$output_path"

printf 'Expected build manifest: %s\n' "$output_path"
