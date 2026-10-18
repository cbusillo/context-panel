#!/usr/bin/env bash
# Validates Ship workflow inputs, preflights the App Store marketing version for
# each selected upload channel, and resolves the build number.
# Inputs arrive as INPUT_* environment variables from .github/workflows/ship.yml.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"

if [[ -z "${INPUT_VERSION}" ]]; then
  echo "version is required" >&2
  exit 1
fi
if [[ "${INPUT_VERSION}" == "1.0" ]]; then
  echo "version 1.0 is closed for App Store submissions" >&2
  exit 1
fi
github_release_selected="${INPUT_GITHUB_RELEASE}"
if [[ "${github_release_selected}" == "true" && "${INPUT_NOTARIZE_GITHUB_RELEASE}" != "true" ]]; then
  echo "GitHub Releases require notarization; use Release with create_github_release=false and notarize=false for validation artifacts" >&2
  exit 1
fi
app_store_channel="${INPUT_APP_STORE_CHANNEL}"
companion_app_store_channel="${INPUT_COMPANION_APP_STORE_CHANNEL}"
testflight_beta_selected="${INPUT_TESTFLIGHT_BETA}"
if [[ "${github_release_selected}" != "true" ]]; then
  if [[ "${app_store_channel}" == "skip" && "${companion_app_store_channel}" == "skip" ]]; then
    echo "select at least one release channel" >&2
    exit 1
  fi
fi
# Every uploaded platform is distributed together; TestFlight needs an upload.
testflight_platforms=()
if [[ "${app_store_channel}" == "upload" ]]; then
  testflight_platforms+=(MAC_OS)
fi
if [[ "${companion_app_store_channel}" == "upload" ]]; then
  testflight_platforms+=(IOS VISION_OS TV_OS)
fi
if [[ "${testflight_beta_selected}" == "true" && ${#testflight_platforms[@]} -eq 0 ]]; then
  echo "testflight_beta=true requires app_store_channel=upload or companion_app_store_channel=upload" >&2
  exit 1
fi
preflight_app_store_version() {
  local platform="$1"
  if [[ -z "${APP_STORE_CONNECT_API_KEY_P8_BASE64:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
    echo "App Store Connect API credentials are required for Ship App Store version preflight" >&2
    exit 1
  fi
  python3 "$repo_root/scripts/app-store-version-guard.py" \
    --bundle-id com.shinycomputers.contextpanel \
    --platform "${platform}" \
    --version "${INPUT_VERSION}"
}
if [[ "${app_store_channel}" == "upload" ]]; then
  preflight_app_store_version MAC_OS
fi
if [[ "${companion_app_store_channel}" == "upload" ]]; then
  preflight_app_store_version IOS
  preflight_app_store_version VISION_OS
  preflight_app_store_version TV_OS
fi
build_number="${INPUT_BUILD_NUMBER}"
if [[ -z "${build_number}" ]]; then
  build_number="$(date -u +%Y%m%d%H%M)"
fi
testflight_platforms_json="[]"
if ((${#testflight_platforms[@]})); then
  printf -v quoted_platforms '"%s",' "${testflight_platforms[@]}"
  testflight_platforms_json="[${quoted_platforms%,}]"
fi
{
  echo "build_number=${build_number}"
  echo "testflight_platforms=${testflight_platforms_json}"
} >>"${GITHUB_OUTPUT}"
{
  echo "### Release Intent"
  echo
  echo "- Version: ${INPUT_VERSION}"
  echo "- Build number: ${build_number}"
  echo "- Commit: ${GITHUB_SHA}"
  echo "- GitHub Release: ${INPUT_GITHUB_RELEASE}"
  echo "- GitHub notarization: ${INPUT_NOTARIZE_GITHUB_RELEASE}"
  echo "- Mac App Store channel: ${INPUT_APP_STORE_CHANNEL}"
  echo "- Companion App Store channel (iPhone/iPad/Watch, Vision Pro, Apple TV): ${INPUT_COMPANION_APP_STORE_CHANNEL}"
  echo "- TestFlight beta: ${INPUT_TESTFLIGHT_BETA} (${testflight_platforms_json})"
  echo "- TestFlight groups: ${INPUT_TESTFLIGHT_BETA_GROUPS}"
  echo "- Include internal TestFlight groups: ${INPUT_INCLUDE_INTERNAL_TESTFLIGHT_GROUPS}"
} >>"${GITHUB_STEP_SUMMARY}"
