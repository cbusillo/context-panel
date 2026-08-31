#!/usr/bin/env bash
set -euo pipefail

version=""
build_number=""

while (($#)); do
	case "$1" in
	--version)
		if (($# < 2)); then
			echo "--version requires a value" >&2
			exit 2
		fi
		version="$2"
		shift 2
		;;
	--build-number)
		if (($# < 2)); then
			echo "--build-number requires a value" >&2
			exit 2
		fi
		build_number="$2"
		shift 2
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done

if [[ -n "$version" && ! "$version" =~ ^[0-9]{1,4}(\.[0-9]{1,4}){1,3}$ ]]; then
	echo "release version must contain two to four numeric components" >&2
	exit 2
fi

if [[ -n "$build_number" && ! "$build_number" =~ ^[0-9]{1,18}$ ]]; then
	echo "release build number must contain only digits" >&2
	exit 2
fi

if [[ "${GITHUB_REF:-}" != "refs/heads/main" || "${GITHUB_REF_TYPE:-}" != "branch" || "${GITHUB_REF_NAME:-}" != "main" ]]; then
	echo "release workflows must run from refs/heads/main" >&2
	exit 1
fi

if [[ "${GITHUB_REF_PROTECTED:-false}" != "true" ]]; then
	echo "release workflows require a protected main branch" >&2
	exit 1
fi

if [[ -z "${GITHUB_SHA:-}" ]]; then
	echo "GITHUB_SHA is required" >&2
	exit 2
fi

git fetch --no-tags --prune origin \
	+refs/heads/main:refs/remotes/origin/main

if [[ "$(git rev-parse HEAD)" != "$GITHUB_SHA" ]]; then
	echo "checked-out commit does not match GITHUB_SHA" >&2
	exit 1
fi

if ! git merge-base --is-ancestor "$GITHUB_SHA" refs/remotes/origin/main; then
	echo "refusing release workflow for a commit outside origin/main" >&2
	exit 1
fi

echo "release workflow trust guard OK"
