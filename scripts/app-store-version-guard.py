#!/usr/bin/env python3
"""Reject App Store Connect uploads that would regress marketing version."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import namedtuple
from itertools import zip_longest
from pathlib import Path
from typing import Any


API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_BUNDLE_ID = "com.shinycomputers.contextpanel"
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")


class AppStoreConnectError(RuntimeError):
    def __init__(self, message: str, status: int | None = None, payload: dict[str, Any] | None = None):
        super().__init__(message)
        self.status = status
        self.payload = payload


KnownVersion = namedtuple("KnownVersion", "version source state", defaults=(None,))


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def read_der_length(data: bytes, index: int) -> tuple[int, int]:
    if index >= len(data):
        raise AppStoreConnectError("invalid ECDSA signature from openssl")
    value = data[index]
    index += 1
    if value < 0x80:
        return value, index
    byte_count = value & 0x7F
    if byte_count == 0 or index + byte_count > len(data):
        raise AppStoreConnectError("invalid ECDSA signature length from openssl")
    length = int.from_bytes(data[index:index + byte_count], "big")
    return length, index + byte_count


def read_der_integer(data: bytes, index: int) -> tuple[bytes, int]:
    if index >= len(data) or data[index] != 0x02:
        raise AppStoreConnectError("invalid ECDSA signature integer from openssl")
    length, value_index = read_der_length(data, index + 1)
    value = data[value_index:value_index + length]
    if len(value) != length:
        raise AppStoreConnectError("truncated ECDSA signature integer from openssl")
    value = value.lstrip(b"\x00") or b"\x00"
    if len(value) > 32:
        raise AppStoreConnectError("ECDSA signature integer is too large for ES256")
    return value.rjust(32, b"\x00"), value_index + length


def der_ecdsa_signature_to_raw(signature: bytes) -> bytes:
    if len(signature) < 8 or signature[0] != 0x30:
        raise AppStoreConnectError("invalid ECDSA signature from openssl")
    sequence_length, index = read_der_length(signature, 1)
    if index + sequence_length != len(signature):
        raise AppStoreConnectError("unexpected trailing bytes in ECDSA signature")
    r_value, index = read_der_integer(signature, index)
    s_value, index = read_der_integer(signature, index)
    if index != len(signature):
        raise AppStoreConnectError("unexpected trailing data in ECDSA signature")
    return r_value + s_value


def make_token(key_path: Path, key_id: str, issuer_id: str) -> str:
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"}
    signing_input = (
        f"{b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    ).encode()
    try:
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
            input=signing_input,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except FileNotFoundError as error:
        raise AppStoreConnectError("openssl is required to sign App Store Connect requests") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode("utf-8", errors="replace").strip()
        raise AppStoreConnectError(f"failed to sign App Store Connect request: {detail}") from error
    return signing_input.decode() + "." + b64url(der_ecdsa_signature_to_raw(result.stdout))


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


def paginated_get(
    client: ASCClient,
    path: str,
    params: dict[str, Any] | None = None,
    limit: int = 100,
) -> dict[str, Any]:
    collected: dict[str, Any] = {"data": [], "included": []}
    page_path = path
    page_params = dict(params or {})
    page_params["limit"] = limit
    while True:
        payload = client.request("GET", page_path, page_params)
        collected["data"].extend(payload.get("data") or [])
        collected["included"].extend(payload.get("included") or [])
        next_url = payload.get("links", {}).get("next")
        if not next_url:
            break
        next_parts = urllib.parse.urlparse(next_url)
        next_query = urllib.parse.parse_qs(next_parts.query)
        next_path = next_parts.path
        if next_path.startswith("/v1/"):
            page_path = next_path[3:]
        elif next_path:
            page_path = next_path
        else:
            raise AppStoreConnectError(f"malformed App Store Connect pagination URL: {next_url}")
        if not next_query:
            raise AppStoreConnectError(f"malformed App Store Connect pagination URL: {next_url}")
        page_params = {
            key: values if len(values) > 1 else values[0]
            for key, values in next_query.items()
        }
    return collected


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


def app_id_for_bundle_id(client: ASCClient, bundle_id: str) -> str:
    payload = client.request(
        "GET",
        "/apps",
        {"filter[bundleId]": bundle_id, "limit": 1, "fields[apps]": "name,bundleId"},
    )
    apps = payload.get("data") or []
    if not apps:
        raise AppStoreConnectError(f"missing app {bundle_id}", payload=payload)
    app = apps[0]
    print(f"Checking App Store Connect versions for {app['attributes'].get('name', bundle_id)}")
    return app["id"]


def app_store_versions(client: ASCClient, app_id: str, platform: str) -> list[KnownVersion]:
    payload = paginated_get(
        client,
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": platform,
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState",
        },
    )
    versions: list[KnownVersion] = []
    for item in payload.get("data") or []:
        attributes = item.get("attributes") or {}
        version = attributes.get("versionString")
        if isinstance(version, str) and version:
            versions.append(
                KnownVersion(
                    version=version,
                    source="App Store version",
                    state=attributes.get("appStoreState") or attributes.get("appVersionState"),
                )
            )
    return versions


def pre_release_versions(client: ASCClient, app_id: str, platform: str) -> list[KnownVersion]:
    payload = paginated_get(
        client,
        f"/apps/{app_id}/preReleaseVersions",
        {
            "filter[platform]": platform,
            "fields[preReleaseVersions]": "version,platform",
        },
    )
    versions: list[KnownVersion] = []
    for item in payload.get("data") or []:
        attributes = item.get("attributes") or {}
        version = attributes.get("version")
        if isinstance(version, str) and version:
            versions.append(KnownVersion(version=version, source="TestFlight pre-release version"))
    return versions


def version_components(version: str) -> tuple[int, ...]:
    if not VERSION_PATTERN.fullmatch(version):
        raise AppStoreConnectError(
            f"unsupported App Store marketing version {version!r}; expected dot-separated integers"
        )
    return tuple(int(part) for part in version.split("."))


def compare_versions(left: str, right: str) -> int:
    left_parts = version_components(left)
    right_parts = version_components(right)
    for left_part, right_part in zip_longest(left_parts, right_parts, fillvalue=0):
        if left_part < right_part:
            return -1
        if left_part > right_part:
            return 1
    return 0


def latest_known_version(known_versions: list[KnownVersion]) -> KnownVersion | None:
    latest: KnownVersion | None = None
    for known in known_versions:
        version_components(known.version)
        if latest is None or compare_versions(known.version, latest.version) > 0:
            latest = known
    return latest


def assert_not_version_regression(
    client: ASCClient,
    app_id: str,
    platform: str,
    requested_version: str,
) -> KnownVersion | None:
    version_components(requested_version)
    known_versions = app_store_versions(client, app_id, platform) + pre_release_versions(client, app_id, platform)
    latest = latest_known_version(known_versions)
    if latest is None:
        print(f"No existing App Store Connect marketing versions found for {platform}; allowing {requested_version}.")
        return None
    comparison = compare_versions(requested_version, latest.version)
    if comparison < 0:
        state = f" ({latest.state})" if latest.state else ""
        raise AppStoreConnectError(
            f"refusing to upload {platform} marketing version {requested_version}: "
            f"App Store Connect already has {latest.version} from {latest.source}{state}. "
            f"Use {latest.version} with a higher build number or the next marketing version."
        )
    relation = "matches" if comparison == 0 else "is newer than"
    print(
        f"OK: requested {platform} marketing version {requested_version} {relation} "
        f"latest App Store Connect version {latest.version} ({latest.source})."
    )
    return latest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--platform", required=True, choices=("IOS", "MAC_OS", "TV_OS", "VISION_OS"))
    parser.add_argument("--version", required=True, help="Requested App Store marketing version")
    parser.add_argument("--api-key", default=os.environ.get("APP_STORE_CONNECT_API_KEY_PATH"))
    parser.add_argument("--api-key-id", default=os.environ.get("APP_STORE_CONNECT_KEY_ID"))
    parser.add_argument("--api-issuer-id", default=os.environ.get("APP_STORE_CONNECT_ISSUER_ID"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    temporary_key_path: Path | None = None
    try:
        if not args.api_key_id or not args.api_issuer_id:
            raise AppStoreConnectError("APP_STORE_CONNECT_KEY_ID and APP_STORE_CONNECT_ISSUER_ID are required")
        key_path, temporary_key_path = expanded_key_path(args)
        if not key_path.exists():
            raise AppStoreConnectError(f"App Store Connect API key not found: {key_path}")
        client = ASCClient(make_token(key_path, args.api_key_id, args.api_issuer_id))
        app_id = app_id_for_bundle_id(client, args.bundle_id)
        assert_not_version_regression(client, app_id, args.platform, args.version)
        return 0
    except AppStoreConnectError as error:
        print(f"error: {error} [bundle_id={args.bundle_id} platform={args.platform}]", file=sys.stderr)
        if error.payload is not None:
            print(json.dumps(error.payload, indent=2, sort_keys=True), file=sys.stderr)
        return 1
    finally:
        if temporary_key_path is not None:
            temporary_key_path.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
