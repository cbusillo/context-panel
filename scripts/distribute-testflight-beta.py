#!/usr/bin/env python3
"""Associate an uploaded App Store Connect build with TestFlight beta groups."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey


API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_BUNDLE_ID = "com.shinycomputers.contextpanel"
DEFAULT_BUILD_WAIT_TIMEOUT_SECONDS = 10 * 60
DEFAULT_BUILD_POLL_SECONDS = 20


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


def required_first(payload: dict[str, Any], label: str) -> dict[str, Any]:
    data = payload.get("data") or []
    if not data:
        raise AppStoreConnectError(f"missing {label}", payload=payload)
    return data[0]


def paginated_get(
    client: ASCClient,
    path: str,
    params: dict[str, Any] | None = None,
    limit: int = 50,
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
        if not next_query:
            break
        next_path = next_parts.path
        if next_path.startswith("/v1/"):
            page_path = next_path[3:]
        elif next_path:
            page_path = next_path
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


def comma_separated_values(values: list[str] | None) -> list[str]:
    result: list[str] = []
    for value in values or []:
        result.extend(part.strip() for part in value.split(","))
    return [value for value in result if value]


def ensure_build(
    client: ASCClient,
    app_id: str,
    marketing_version: str,
    build_number: str,
    non_exempt_encryption: bool | None,
    dry_run: bool,
    wait_timeout_seconds: int,
    poll_seconds: int,
) -> dict[str, Any]:
    deadline = time.monotonic() + max(0, wait_timeout_seconds)
    last_payload: dict[str, Any] | None = None
    while True:
        payload = client.request(
            "GET",
            "/builds",
            {
                "filter[app]": app_id,
                "filter[version]": build_number,
                "include": "preReleaseVersion",
                "fields[builds]": "version,processingState,uploadedDate,expired,usesNonExemptEncryption,preReleaseVersion",
                "fields[preReleaseVersions]": "version,platform",
                "limit": 1,
            },
        )
        last_payload = payload
        builds = payload.get("data") or []
        if builds:
            build = builds[0]
            validate_build_marketing_version(payload, build, marketing_version, build_number)
            attributes = build["attributes"]
            if attributes.get("processingState") == "VALID":
                if non_exempt_encryption is not None and attributes.get("usesNonExemptEncryption") != non_exempt_encryption:
                    if dry_run:
                        print(f"Dry run: would update build {build_number} non-exempt encryption setting")
                    else:
                        client.request(
                            "PATCH",
                            f"/builds/{build['id']}",
                            body={
                                "data": {
                                    "type": "builds",
                                    "id": build["id"],
                                    "attributes": {"usesNonExemptEncryption": non_exempt_encryption},
                                }
                            },
                        )
                print(f"Using valid build {build_number}: {build['id']}")
                return build
            if attributes.get("processingState") in {"FAILED", "INVALID"}:
                raise AppStoreConnectError(
                    f"build {build_number} processing failed: {attributes.get('processingState')}",
                    payload=build,
                )
            if time.monotonic() >= deadline:
                raise AppStoreConnectError(
                    f"build {build_number} is not valid: {attributes.get('processingState')}",
                    payload=build,
                )
            print(
                f"Build {build_number} is {attributes.get('processingState')}; "
                f"waiting {poll_seconds}s for App Store Connect processing"
            )
        else:
            if time.monotonic() >= deadline:
                raise AppStoreConnectError(f"missing build {build_number}", payload=last_payload)
            print(f"Build {build_number} is not visible yet; waiting {poll_seconds}s")
        time.sleep(max(1, poll_seconds))


def validate_build_marketing_version(
    payload: dict[str, Any], build: dict[str, Any], marketing_version: str, build_number: str
) -> None:
    relationship = build.get("relationships", {}).get("preReleaseVersion", {}).get("data")
    pre_release_id = relationship.get("id") if isinstance(relationship, dict) else None
    included = {
        item["id"]: item
        for item in payload.get("included") or []
        if item.get("type") == "preReleaseVersions"
    }
    pre_release = included.get(pre_release_id) if pre_release_id else None
    found_version = pre_release.get("attributes", {}).get("version") if pre_release else None
    if found_version != marketing_version:
        raise AppStoreConnectError(
            f"build {build_number} belongs to marketing version {found_version or '<unknown>'}, not {marketing_version}",
            payload=build,
        )


def beta_groups(client: ASCClient, app_id: str) -> list[dict[str, Any]]:
    payload = paginated_get(
        client,
        f"/apps/{app_id}/betaGroups",
        {
            "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds",
        },
        limit=100,
    )
    return payload.get("data") or []


def selected_beta_groups(
    groups: list[dict[str, Any]],
    names: list[str],
    include_internal: bool,
) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    if names:
        by_name = {group["attributes"].get("name", "").casefold(): group for group in groups}
        for name in names:
            group = by_name.get(name.casefold())
            if group is None:
                available = ", ".join(group["attributes"].get("name", "<unnamed>") for group in groups)
                raise AppStoreConnectError(f"missing TestFlight beta group {name!r}; available groups: {available}")
            selected.append(group)
    if include_internal:
        selected.extend(group for group in groups if group["attributes"].get("isInternalGroup") is True)

    deduped: dict[str, dict[str, Any]] = {}
    for group in selected:
        deduped[group["id"]] = group
    result = list(deduped.values())
    if not result:
        raise AppStoreConnectError("no TestFlight beta groups selected")
    return result


def group_has_build(client: ASCClient, group_id: str, build_id: str) -> bool:
    payload = paginated_get(
        client,
        f"/betaGroups/{group_id}/builds",
        {"fields[builds]": "version,processingState"},
        limit=100,
    )
    return any(build.get("id") == build_id for build in payload.get("data") or [])


def add_build_to_group(client: ASCClient, build: dict[str, Any], group: dict[str, Any], dry_run: bool) -> str:
    build_id = build["id"]
    group_id = group["id"]
    group_name = group["attributes"].get("name", group_id)
    if group["attributes"].get("hasAccessToAllBuilds") is True:
        print(f"TestFlight group {group_name} already has access to all builds: {group_id}")
        return "already-present"
    if group_has_build(client, group_id, build_id):
        print(f"Build already available to TestFlight group {group_name}: {group_id}")
        return "already-present"
    if dry_run:
        print(f"Dry run: would add build {build_id} to TestFlight group {group_name}: {group_id}")
        return "dry-run"
    try:
        client.request(
            "POST",
            f"/betaGroups/{group_id}/relationships/builds",
            body={"data": [{"type": "builds", "id": build_id}]},
            allowed=(200, 201, 204),
        )
    except AppStoreConnectError as error:
        if error.status == 409:
            if group_has_build(client, group_id, build_id):
                print(f"Build already available to TestFlight group {group_name}: {group_id}")
                return "already-present"
        raise
    print(f"Added build {build_id} to TestFlight group {group_name}: {group_id}")
    return "added"


def parse_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "y"}:
        return True
    if normalized in {"0", "false", "no", "n"}:
        return False
    raise argparse.ArgumentTypeError(f"expected boolean, got {value!r}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--version", required=True, help="App Store marketing version, for example 1.0.22")
    parser.add_argument("--build-number", required=True, help="CFBundleVersion uploaded to App Store Connect")
    parser.add_argument(
        "--beta-group",
        action="append",
        help="TestFlight beta group name. May be provided multiple times or as comma-separated names.",
    )
    parser.add_argument(
        "--skip-internal-beta-groups",
        action="store_true",
        help="Do not automatically include internal TestFlight beta groups.",
    )
    parser.add_argument("--api-key", default=os.environ.get("APP_STORE_CONNECT_API_KEY_PATH"))
    parser.add_argument("--api-key-id", default=os.environ.get("APP_STORE_CONNECT_KEY_ID"))
    parser.add_argument("--api-issuer-id", default=os.environ.get("APP_STORE_CONNECT_ISSUER_ID"))
    parser.add_argument("--non-exempt-encryption", type=parse_bool, default=False)
    parser.add_argument("--wait-timeout-seconds", type=int, default=DEFAULT_BUILD_WAIT_TIMEOUT_SECONDS)
    parser.add_argument("--poll-seconds", type=int, default=DEFAULT_BUILD_POLL_SECONDS)
    parser.add_argument("--dry-run", action="store_true")
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
        app_payload = client.request(
            "GET",
            "/apps",
            {"filter[bundleId]": args.bundle_id, "limit": 1, "fields[apps]": "name,bundleId,sku,primaryLocale"},
        )
        app = required_first(app_payload, f"app {args.bundle_id}")
        app_id = app["id"]
        print(f"Using app {app['attributes'].get('name')}: {app_id}")
        build = ensure_build(
            client,
            app_id,
            args.version,
            args.build_number,
            args.non_exempt_encryption,
            args.dry_run,
            args.wait_timeout_seconds,
            args.poll_seconds,
        )
        groups = selected_beta_groups(
            beta_groups(client, app_id),
            comma_separated_values(args.beta_group),
            include_internal=not args.skip_internal_beta_groups,
        )
        results = [add_build_to_group(client, build, group, args.dry_run) for group in groups]
        added_count = sum(1 for result in results if result == "added")
        already_count = sum(1 for result in results if result == "already-present")
        dry_run_count = sum(1 for result in results if result == "dry-run")
        print(
            f"TestFlight beta distribution complete for {args.version} ({args.build_number}): "
            f"added={added_count}, already_present={already_count}, dry_run={dry_run_count}"
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
