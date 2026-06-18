#!/usr/bin/env bash
set -euo pipefail

required_major="26"

usage() {
	cat <<'USAGE'
Usage: scripts/validate-release-xcode.sh [--required-major VERSION]

Fails fast when a release/upload workflow is not running on the expected Xcode
major version. Keep release jobs pinned to an App Store Connect-supported Xcode
train; do not rely on macos-latest.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--required-major)
		required_major="${2:?--required-major requires a value}"
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

if ! command -v xcodebuild >/dev/null 2>&1; then
	echo "xcodebuild is required for release/upload jobs" >&2
	exit 1
fi

xcode_version_output="$(xcodebuild -version)"
developer_dir="$(xcode-select -p 2>/dev/null || true)"
major="$(printf '%s\n' "$xcode_version_output" | awk '/^Xcode / { split($2, parts, "."); print parts[1]; exit }')"

printf '%s\n' "$xcode_version_output"
if [[ -n "$developer_dir" ]]; then
	printf 'Developer dir: %s\n' "$developer_dir"
fi

if [[ -z "$major" ]]; then
	echo "could not determine Xcode major version" >&2
	exit 1
fi

if [[ "$major" != "$required_major" ]]; then
	cat >&2 <<EOF
Release/upload jobs require Xcode $required_major.x.
Current Xcode major is $major.

Use an explicit macos-$required_major runner/image for App Store compatible
uploads. Update this gate only after App Store Connect release notes or a
controlled upload canary confirm that the newer Xcode train is accepted.
EOF
	exit 1
fi
