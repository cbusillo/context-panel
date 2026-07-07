#!/usr/bin/env python3
"""Upload approved App Store screenshots through the App Store Connect API."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey


API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_BUNDLE_ID = "com.shinycomputers.contextpanel"
DEFAULT_LOCALE = "en-US"
DEFAULT_SCREENSHOT_ROOT = Path("Resources/AppStore/Screenshots")
DEFAULT_PROCESSING_TIMEOUT_SECONDS = 10 * 60
DEFAULT_PROCESSING_POLL_SECONDS = 10
MAX_SCREENSHOTS_PER_DISPLAY_TYPE = 10


@dataclass(frozen=True)
class ScreenshotAsset:
    display_type: str
    path: Path


@dataclass(frozen=True)
class StoredScreenshot:
    id: str
    path: Path


APPROVED_SETS: dict[str, tuple[ScreenshotAsset, ...]] = {
    "macos": (
        ScreenshotAsset("APP_DESKTOP", Path("final/context-panel-appstore-1-app.png")),
        ScreenshotAsset("APP_DESKTOP", Path("final/context-panel-appstore-2-widget.png")),
        ScreenshotAsset("APP_DESKTOP", Path("final/context-panel-appstore-3-app-dark-current.png")),
        ScreenshotAsset("APP_DESKTOP", Path("final/context-panel-appstore-4-widgets-live-redacted.png")),
        ScreenshotAsset("APP_DESKTOP", Path("final/context-panel-appstore-5-glance-detail-redacted.png")),
    ),
    "iphone": (
        ScreenshotAsset("APP_IPHONE_61", Path("iphone/iphone-6-3-app-light-synced.png")),
        ScreenshotAsset("APP_IPHONE_61", Path("iphone/iphone-6-3-app-dark-synced.png")),
        ScreenshotAsset("APP_IPHONE_61", Path("iphone/iphone-6-3-widget-light-home.png")),
        ScreenshotAsset("APP_IPHONE_61", Path("iphone/iphone-6-3-widget-dark-home.png")),
    ),
    "ipad": (
        ScreenshotAsset("APP_IPAD_PRO_3GEN_129", Path("ipad/ipad-12-9-app-light-synced.png")),
        ScreenshotAsset("APP_IPAD_PRO_3GEN_129", Path("ipad/ipad-12-9-app-dark-synced.png")),
    ),
    "watch": (
        ScreenshotAsset("APP_WATCH_ULTRA", Path("watch/watch-ultra-healthy.png")),
        ScreenshotAsset("APP_WATCH_ULTRA", Path("watch/watch-ultra-limited.png")),
    ),
    "ios": (
        ScreenshotAsset("APP_IPHONE_61", Path("iphone/iphone-6-3-app-light-synced.png")),
        ScreenshotAsset("APP_IPHONE_61", Path("iphone/iphone-6-3-app-dark-synced.png")),
        ScreenshotAsset("APP_IPHONE_61", Path("iphone/iphone-6-3-widget-light-home.png")),
        ScreenshotAsset("APP_IPHONE_61", Path("iphone/iphone-6-3-widget-dark-home.png")),
        ScreenshotAsset("APP_IPAD_PRO_3GEN_129", Path("ipad/ipad-12-9-app-light-synced.png")),
        ScreenshotAsset("APP_IPAD_PRO_3GEN_129", Path("ipad/ipad-12-9-app-dark-synced.png")),
        ScreenshotAsset("APP_WATCH_ULTRA", Path("watch/watch-ultra-healthy.png")),
        ScreenshotAsset("APP_WATCH_ULTRA", Path("watch/watch-ultra-limited.png")),
    ),
    "visionpro": (
        ScreenshotAsset("APP_APPLE_VISION_PRO", Path("visionpro/visionpro-app-light-synced-simulator.png")),
        ScreenshotAsset("APP_APPLE_VISION_PRO", Path("visionpro/visionpro-app-dark-synced-simulator.png")),
        ScreenshotAsset("APP_APPLE_VISION_PRO", Path("visionpro/visionpro-app-stale-sync-simulator.png")),
        ScreenshotAsset("APP_APPLE_VISION_PRO", Path("visionpro/visionpro-widget-small-healthy-light-rendered.png")),
        ScreenshotAsset("APP_APPLE_VISION_PRO", Path("visionpro/visionpro-widget-small-healthy-dark-rendered.png")),
        ScreenshotAsset("APP_APPLE_VISION_PRO", Path("visionpro/visionpro-widget-medium-healthy-light-rendered.png")),
        ScreenshotAsset("APP_APPLE_VISION_PRO", Path("visionpro/visionpro-widget-medium-healthy-dark-rendered.png")),
    ),
}

PLATFORM_FOR_SET = {
    "macos": "MAC_OS",
    "iphone": "IOS",
    "ipad": "IOS",
    "watch": "IOS",
    "ios": "IOS",
    "visionpro": "VISION_OS",
}

FULL_PLATFORM_DISPLAY_TYPES = {
    "MAC_OS": {"APP_DESKTOP"},
    "IOS": {"APP_IPHONE_61", "APP_IPAD_PRO_3GEN_129", "APP_WATCH_ULTRA"},
    "VISION_OS": {"APP_APPLE_VISION_PRO"},
}


class AppStoreConnectError(RuntimeError):
    def __init__(self, message: str, status: int | None = None, payload: dict[str, Any] | None = None):
        super().__init__(message)
        self.status = status
        self.payload = payload


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_token(key_path: Path, key_id: str, issuer_id: str) -> str:
    private_key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    if not isinstance(private_key, EllipticCurvePrivateKey):
        raise AppStoreConnectError("App Store Connect API key must be an elliptic-curve private key")
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"}
    signing_input = (
        f"{b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    ).encode()
    signature = private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r_value, s_value = utils.decode_dss_signature(signature)
    raw_signature = r_value.to_bytes(32, "big") + s_value.to_bytes(32, "big")
    return signing_input.decode() + "." + b64url(raw_signature)


class ASCClient:
    def __init__(self, token: str):
        self.token = token

    def request(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
        allowed: tuple[int, ...] = (200,),
    ) -> dict[str, Any]:
        url = API_BASE + path
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                payload = json.loads(raw) if raw else None
                if response.status not in allowed:
                    raise AppStoreConnectError(
                        f"unexpected App Store Connect status {response.status}",
                        response.status,
                        payload,
                    )
                return payload or {}
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8", errors="replace")
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                payload = {"raw": raw}
            raise AppStoreConnectError(
                f"App Store Connect request failed: {method} {path}",
                error.code,
                payload,
            ) from error

    def upload(self, operation: dict[str, Any], source: bytes) -> None:
        offset = int(operation.get("offset", 0))
        length = int(operation["length"])
        chunk = source[offset : offset + length]
        headers = {header["name"]: header["value"] for header in operation.get("requestHeaders", [])}
        request = urllib.request.Request(operation["url"], data=chunk, method=operation.get("method", "PUT"), headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                if response.status < 200 or response.status >= 300:
                    raise AppStoreConnectError(f"unexpected upload status {response.status}", response.status)
        except urllib.error.HTTPError as error:
            raise AppStoreConnectError("screenshot asset upload failed", error.code) from error

    def download(self, url: str) -> bytes:
        request = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            raise AppStoreConnectError("screenshot asset download failed", error.code) from error


def expanded_key_path(args: argparse.Namespace) -> tuple[Path, Path | None]:
    if args.api_key:
        return Path(args.api_key).expanduser(), None
    encoded_key = os.environ.get("APP_STORE_CONNECT_API_KEY_P8_BASE64", "").strip()
    if not encoded_key:
        raise AppStoreConnectError("App Store Connect API key is required")
    temporary = tempfile.NamedTemporaryFile(delete=False)
    temporary.write(base64.b64decode(encoded_key))
    temporary.flush()
    temporary.close()
    key_path = Path(temporary.name)
    key_path.chmod(0o600)
    return key_path, key_path


def required_first(payload: dict[str, Any], label: str) -> dict[str, Any]:
    data = payload.get("data") or []
    if not data:
        raise AppStoreConnectError(f"missing {label}", payload=payload)
    return data[0]


def relationship_id(resource: dict[str, Any], name: str) -> str | None:
    relationship = resource.get("relationships", {}).get(name, {})
    data = relationship.get("data")
    if isinstance(data, dict):
        value = data.get("id")
        return value if isinstance(value, str) else None
    if isinstance(data, list) and data:
        value = data[0].get("id")
        return value if isinstance(value, str) else None
    return None


def paginated_get(client: ASCClient, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = client.request("GET", path, params or {})
    merged = dict(payload)
    merged["data"] = list(payload.get("data") or [])
    merged["included"] = list(payload.get("included") or [])
    next_url = payload.get("links", {}).get("next")
    while next_url:
        parsed = urllib.parse.urlparse(next_url)
        query = dict(urllib.parse.parse_qsl(parsed.query))
        page = client.request("GET", parsed.path.removeprefix("/v1"), query)
        merged["data"].extend(page.get("data") or [])
        merged["included"].extend(page.get("included") or [])
        next_url = page.get("links", {}).get("next")
    return merged


def app_id_for_bundle_id(client: ASCClient, bundle_id: str) -> str:
    payload = client.request(
        "GET",
        "/apps",
        {"filter[bundleId]": bundle_id, "limit": 1, "fields[apps]": "name,bundleId"},
    )
    return required_first(payload, f"app {bundle_id}")["id"]


def app_store_version(client: ASCClient, app_id: str, version_string: str, platform: str) -> dict[str, Any]:
    payload = client.request(
        "GET",
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": platform,
            "filter[versionString]": version_string,
            "include": "appStoreVersionLocalizations",
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,appStoreVersionLocalizations",
            "fields[appStoreVersionLocalizations]": "locale",
            "limit": 1,
        },
    )
    return required_first(payload, f"{platform} App Store version {version_string}")


def app_store_version_localization(client: ASCClient, version_id: str, locale: str) -> str:
    payload = paginated_get(
        client,
        f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        {"fields[appStoreVersionLocalizations]": "locale", "limit": 50},
    )
    for localization in payload.get("data") or []:
        if localization.get("attributes", {}).get("locale") == locale:
            return localization["id"]
    raise AppStoreConnectError(f"missing {locale} localization for App Store version {version_id}", payload=payload)


def screenshot_sets(client: ASCClient, localization_id: str) -> dict[str, dict[str, Any]]:
    payload = paginated_get(
        client,
        f"/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
        {
            "fields[appScreenshotSets]": "screenshotDisplayType,appScreenshots",
            "limit": 50,
        },
    )
    return {
        screenshot_set.get("attributes", {}).get("screenshotDisplayType"): screenshot_set
        for screenshot_set in payload.get("data") or []
    }


def create_screenshot_set(client: ASCClient, localization_id: str, display_type: str, dry_run: bool) -> str:
    if dry_run:
        return f"dry-run-set-{display_type}"
    created = client.request(
        "POST",
        "/appScreenshotSets",
        body={
            "data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display_type},
                "relationships": {
                    "appStoreVersionLocalization": {
                        "data": {"type": "appStoreVersionLocalizations", "id": localization_id}
                    }
                },
            }
        },
        allowed=(201,),
    )
    print(f"Created screenshot set {display_type}: {created['data']['id']}")
    return created["data"]["id"]


def existing_screenshots(client: ASCClient, screenshot_set_id: str) -> list[dict[str, Any]]:
    payload = paginated_get(
        client,
        f"/appScreenshotSets/{screenshot_set_id}/appScreenshots",
        {"fields[appScreenshots]": "fileName,imageAsset", "limit": 50},
    )
    return [screenshot for screenshot in payload.get("data") or [] if isinstance(screenshot, dict)]


def image_asset_url(screenshot: dict[str, Any]) -> str | None:
    image_asset = screenshot.get("attributes", {}).get("imageAsset") or {}
    for key in ("downloadUrl", "url"):
        value = image_asset.get(key)
        if isinstance(value, str) and value:
            return value
    template_url = image_asset.get("templateUrl")
    if not isinstance(template_url, str) or not template_url:
        return None
    width = image_asset.get("width")
    height = image_asset.get("height")
    if width and height:
        return template_url.replace("{w}", str(width)).replace("{h}", str(height)).replace("{f}", "png")
    return template_url.replace("{w}", "0").replace("{h}", "0").replace("{f}", "png")


def backup_existing_screenshots(
    client: ASCClient,
    screenshots: list[dict[str, Any]],
    backup_dir: Path,
) -> list[StoredScreenshot]:
    backups: list[StoredScreenshot] = []
    backup_dir.mkdir(parents=True, exist_ok=True)
    for index, screenshot in enumerate(screenshots):
        screenshot_id = screenshot["id"]
        url = image_asset_url(screenshot)
        if url is None:
            raise AppStoreConnectError(
                f"cannot safely replace screenshot {screenshot_id}: App Store Connect did not expose a downloadable image asset"
            )
        filename = screenshot.get("attributes", {}).get("fileName") or f"existing-{index}.png"
        path = backup_dir / f"{index:02d}-{Path(filename).name}"
        path.write_bytes(client.download(url))
        backups.append(StoredScreenshot(screenshot_id, path))
    return backups


def delete_screenshots(client: ASCClient, screenshots: list[dict[str, Any]], dry_run: bool) -> int:
    if dry_run:
        return len(screenshots)
    for screenshot in screenshots:
        client.request("DELETE", f"/appScreenshots/{screenshot['id']}", allowed=(204,))
        print(f"Deleted existing screenshot: {screenshot['id']}")
    return len(screenshots)


def prune_unapproved_display_type_screenshots(
    client: ASCClient,
    sets: dict[str, dict[str, Any]],
    approved_display_types: set[str],
    dry_run: bool,
) -> None:
    for display_type, screenshot_set in sets.items():
        if display_type in approved_display_types:
            continue
        screenshots = existing_screenshots(client, screenshot_set["id"])
        if not screenshots:
            continue
        action = "Would delete" if dry_run else "Deleted"
        deleted = delete_screenshots(client, screenshots, dry_run)
        print(f"{action} {deleted} unapproved {display_type} screenshots")


def cleanup_created_screenshots(client: ASCClient, screenshot_ids: list[str]) -> None:
    for screenshot_id in reversed(screenshot_ids):
        try:
            client.request("DELETE", f"/appScreenshots/{screenshot_id}", allowed=(204,))
            print(f"Cleaned up newly-created screenshot after failure: {screenshot_id}")
        except AppStoreConnectError as cleanup_error:
            print(f"warning: failed to clean up newly-created screenshot {screenshot_id}: {cleanup_error}", file=sys.stderr)


def upload_paths(
    client: ASCClient,
    screenshot_set_id: str,
    paths: list[Path],
    dry_run: bool,
    wait: bool,
    timeout_seconds: int,
    poll_seconds: int,
) -> list[str]:
    screenshot_ids: list[str] = []
    try:
        for path in paths:
            created_id = create_screenshot(
                client,
                screenshot_set_id,
                path,
                dry_run,
                wait,
                timeout_seconds,
                poll_seconds,
            )
            screenshot_ids.append(created_id)
        return screenshot_ids
    except AppStoreConnectError:
        if not dry_run:
            cleanup_created_screenshots(client, screenshot_ids)
        raise


def restore_screenshots(
    client: ASCClient,
    screenshot_set_id: str,
    backups: list[StoredScreenshot],
    wait: bool,
    timeout_seconds: int,
    poll_seconds: int,
) -> None:
    restored_ids: list[str] = []
    try:
        for backup in backups:
            restored_ids.append(
                create_screenshot(client, screenshot_set_id, backup.path, False, wait, timeout_seconds, poll_seconds)
            )
    except AppStoreConnectError:
        cleanup_created_screenshots(client, restored_ids)
        raise


def replace_without_exceeding_cap(
    client: ASCClient,
    screenshot_set_id: str,
    old_screenshots: list[dict[str, Any]],
    paths: list[Path],
    dry_run: bool,
    wait: bool,
    timeout_seconds: int,
    poll_seconds: int,
) -> list[str]:
    if len(old_screenshots) + len(paths) <= MAX_SCREENSHOTS_PER_DISPLAY_TYPE:
        new_ids = upload_paths(client, screenshot_set_id, paths, dry_run, wait, timeout_seconds, poll_seconds)
        if old_screenshots:
            delete_screenshots(client, old_screenshots, dry_run)
        return new_ids

    if dry_run:
        return [f"dry-run-screenshot-{path.name}" for path in paths]

    with tempfile.TemporaryDirectory(prefix="asc-screenshot-backup-") as backup_root:
        backups = backup_existing_screenshots(client, old_screenshots, Path(backup_root))
        delete_screenshots(client, old_screenshots, False)
        try:
            return upload_paths(client, screenshot_set_id, paths, False, wait, timeout_seconds, poll_seconds)
        except AppStoreConnectError as upload_error:
            try:
                restore_screenshots(client, screenshot_set_id, backups, wait, timeout_seconds, poll_seconds)
            except AppStoreConnectError as restore_error:
                raise AppStoreConnectError(
                    f"replacement failed and rollback failed: {restore_error}",
                    payload=getattr(restore_error, "payload", None),
                ) from upload_error
            raise


def wait_for_screenshot_processing(
    client: ASCClient,
    screenshot_id: str,
    timeout_seconds: int,
    poll_seconds: int,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while True:
        payload = client.request(
            "GET",
            f"/appScreenshots/{screenshot_id}",
            {"fields[appScreenshots]": "assetDeliveryState,fileName,imageAsset"},
        )
        state = payload.get("data", {}).get("attributes", {}).get("assetDeliveryState", {}).get("state")
        if state == "COMPLETE":
            print(f"Screenshot processing complete: {screenshot_id}")
            return
        if state == "FAILED":
            raise AppStoreConnectError(f"screenshot processing failed: {screenshot_id}", payload=payload)
        if time.monotonic() >= deadline:
            raise AppStoreConnectError(f"timed out waiting for screenshot processing: {screenshot_id}", payload=payload)
        print(f"Screenshot {screenshot_id} processing state={state or '<unknown>'}; waiting {poll_seconds}s")
        time.sleep(poll_seconds)


def create_screenshot(
    client: ASCClient,
    screenshot_set_id: str,
    path: Path,
    dry_run: bool,
    wait: bool,
    timeout_seconds: int,
    poll_seconds: int,
) -> str:
    data = path.read_bytes()
    if dry_run:
        return f"dry-run-screenshot-{path.name}"
    created = client.request(
        "POST",
        "/appScreenshots",
        body={
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileName": path.name, "fileSize": len(data)},
                "relationships": {
                    "appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": screenshot_set_id}}
                },
            }
        },
        allowed=(201,),
    )
    screenshot = created["data"]
    try:
        operations = screenshot.get("attributes", {}).get("uploadOperations") or []
        for operation in operations:
            client.upload(operation, data)
        checksum = hashlib.md5(data).hexdigest()
        client.request(
            "PATCH",
            f"/appScreenshots/{screenshot['id']}",
            body={
                "data": {
                    "type": "appScreenshots",
                    "id": screenshot["id"],
                    "attributes": {"uploaded": True, "sourceFileChecksum": checksum},
                }
            },
        )
        if wait:
            wait_for_screenshot_processing(client, screenshot["id"], timeout_seconds, poll_seconds)
    except AppStoreConnectError:
        cleanup_created_screenshots(client, [screenshot["id"]])
        raise
    print(f"Uploaded screenshot {path.name}: {screenshot['id']}")
    return screenshot["id"]


def selected_assets(names: list[str], root: Path) -> list[ScreenshotAsset]:
    assets: list[ScreenshotAsset] = []
    for name in names:
        for asset in APPROVED_SETS[name]:
            assets.append(ScreenshotAsset(asset.display_type, root / asset.path))
    return assets


def upload_screenshot_set(
    client: ASCClient,
    app_id: str,
    platform: str,
    version: str,
    locale: str,
    assets: list[ScreenshotAsset],
    dry_run: bool,
    wait: bool,
    timeout_seconds: int,
    poll_seconds: int,
) -> None:
    version_resource = app_store_version(client, app_id, version, platform)
    localization_id = app_store_version_localization(client, version_resource["id"], locale)
    sets = screenshot_sets(client, localization_id)
    by_display: dict[str, list[Path]] = {}
    for asset in assets:
        by_display.setdefault(asset.display_type, []).append(asset.path)
    print(f"Target {platform} {version} {locale}: {version_resource['id']}")
    for display_type, paths in by_display.items():
        for path in paths:
            if not path.exists():
                raise AppStoreConnectError(f"missing screenshot file: {path}")
        screenshot_set = sets.get(display_type)
        screenshot_set_id = (
            screenshot_set["id"]
            if screenshot_set
            else create_screenshot_set(client, localization_id, display_type, dry_run)
        )
        old_screenshots = [] if screenshot_set_id.startswith("dry-run-") else existing_screenshots(client, screenshot_set_id)
        existing_count = len(old_screenshots)
        action = "would replace" if dry_run else "replaced"
        print(f"{action} {existing_count} existing {display_type} screenshots with {len(paths)} approved files")
        created_ids = replace_without_exceeding_cap(
            client,
            screenshot_set_id,
            old_screenshots,
            paths,
            dry_run,
            wait,
            timeout_seconds,
            poll_seconds,
        )
        for path, created_id in zip(paths, created_ids):
            print(f"{'Would upload' if dry_run else 'Committed'} {display_type}: {path} ({created_id})")
    full_platform_display_types = FULL_PLATFORM_DISPLAY_TYPES.get(platform, set())
    if full_platform_display_types and set(by_display) == full_platform_display_types:
        prune_unapproved_display_type_screenshots(client, sets, full_platform_display_types, dry_run)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--version", required=True, help="App Store marketing version to update")
    parser.add_argument("--locale", default=DEFAULT_LOCALE)
    parser.add_argument("--screenshot-root", type=Path, default=DEFAULT_SCREENSHOT_ROOT)
    parser.add_argument("--api-key", help="App Store Connect API private key path")
    parser.add_argument("--api-key-id", default=os.environ.get("APP_STORE_CONNECT_KEY_ID"))
    parser.add_argument("--api-issuer-id", default=os.environ.get("APP_STORE_CONNECT_ISSUER_ID"))
    parser.add_argument("--dry-run", action="store_true", help="Validate intended changes without writing screenshots")
    parser.add_argument("--no-wait", action="store_true", help="Do not wait for App Store Connect screenshot processing")
    parser.add_argument("--processing-timeout-seconds", type=int, default=DEFAULT_PROCESSING_TIMEOUT_SECONDS)
    parser.add_argument("--processing-poll-seconds", type=int, default=DEFAULT_PROCESSING_POLL_SECONDS)
    parser.add_argument(
        "--set",
        action="append",
        required=True,
        choices=tuple(APPROVED_SETS.keys()),
        help="Approved screenshot set to upload. Repeat to target multiple sets.",
    )
    parser.add_argument(
        "--platform",
        choices=("MAC_OS", "IOS", "VISION_OS"),
        help="Override the App Store Connect platform. Inferred when one set is selected.",
    )
    return parser.parse_args()


def inferred_platform(set_names: list[str], explicit_platform: str | None) -> str:
    if explicit_platform:
        mismatched_sets = [name for name in set_names if PLATFORM_FOR_SET[name] != explicit_platform]
        if mismatched_sets:
            raise AppStoreConnectError(
                f"--platform {explicit_platform} does not match screenshot set(s): {', '.join(mismatched_sets)}"
            )
        return explicit_platform
    if len(set_names) != 1:
        raise AppStoreConnectError("--platform is required when uploading multiple screenshot sets")
    return PLATFORM_FOR_SET[set_names[0]]


def main() -> int:
    args = parse_args()
    temporary_key_path: Path | None = None
    try:
        if not args.api_key_id or not args.api_issuer_id:
            raise AppStoreConnectError("APP_STORE_CONNECT_KEY_ID and APP_STORE_CONNECT_ISSUER_ID are required")
        key_path, temporary_key_path = expanded_key_path(args)
        if not key_path.exists():
            raise AppStoreConnectError(f"App Store Connect API key not found: {key_path}")
        platform = inferred_platform(args.set, args.platform)
        assets = selected_assets(args.set, args.screenshot_root)
        client = ASCClient(make_token(key_path, args.api_key_id, args.api_issuer_id))
        app_id = app_id_for_bundle_id(client, args.bundle_id)
        upload_screenshot_set(
            client,
            app_id,
            platform,
            args.version,
            args.locale,
            assets,
            args.dry_run,
            not args.no_wait,
            args.processing_timeout_seconds,
            args.processing_poll_seconds,
        )
        return 0
    except AppStoreConnectError as error:
        print(f"error: {error}", file=sys.stderr)
        if error.payload is not None:
            print(json.dumps(error.payload, indent=2, sort_keys=True), file=sys.stderr)
        return 1
    finally:
        if temporary_key_path is not None:
            temporary_key_path.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
