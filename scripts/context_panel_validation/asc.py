from __future__ import annotations

import base64
import binascii
import json
import os
import shlex
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from .models import (
    APP_BUNDLE_ID,
    ASC_PLATFORMS,
    ASCEvidence,
    ASCPlatformEvidence,
    Runner,
    Target,
)


ASC_API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_ASC_ENV_FILE = Path("~/.appstoreconnect/asc.env").expanduser()
DEFAULT_ASC_KEY_DIRECTORY = Path("~/.appstoreconnect/private_keys").expanduser()
RETRYABLE_HTTP_STATUS_CODES = {429, 500, 502, 503, 504}


class ASCReadError(RuntimeError):
    pass


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def read_der_length(data: bytes, index: int) -> tuple[int, int]:
    if index >= len(data):
        raise ASCReadError("invalid App Store Connect signing response")
    value = data[index]
    index += 1
    if value < 0x80:
        return value, index
    byte_count = value & 0x7F
    if byte_count == 0 or index + byte_count > len(data):
        raise ASCReadError("invalid App Store Connect signing response")
    length = int.from_bytes(data[index : index + byte_count], "big")
    return length, index + byte_count


def read_der_integer(data: bytes, index: int) -> tuple[bytes, int]:
    if index >= len(data) or data[index] != 0x02:
        raise ASCReadError("invalid App Store Connect signing response")
    length, value_index = read_der_length(data, index + 1)
    value = data[value_index : value_index + length]
    if len(value) != length:
        raise ASCReadError("invalid App Store Connect signing response")
    value = value.lstrip(b"\x00") or b"\x00"
    if len(value) > 32:
        raise ASCReadError("invalid App Store Connect signing response")
    return value.rjust(32, b"\x00"), value_index + length


def der_ecdsa_signature_to_raw(signature: bytes) -> bytes:
    if len(signature) < 8 or signature[0] != 0x30:
        raise ASCReadError("invalid App Store Connect signing response")
    sequence_length, index = read_der_length(signature, 1)
    if index + sequence_length != len(signature):
        raise ASCReadError("invalid App Store Connect signing response")
    first_value, index = read_der_integer(signature, index)
    second_value, index = read_der_integer(signature, index)
    if index != len(signature):
        raise ASCReadError("invalid App Store Connect signing response")
    return first_value + second_value


def make_asc_token(key_path: Path, key_id: str, issuer_id: str) -> str:
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"}
    signing_input = (
        f"{b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    ).encode()
    try:
        completed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
            input=signing_input,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ASCReadError("local App Store Connect signing is unavailable") from error
    return signing_input.decode() + "." + b64url(der_ecdsa_signature_to_raw(completed.stdout))


class ReadOnlyASCClient:
    def __init__(self, token: str, timeout: int = 15):
        self.token = token
        self.timeout = timeout

    def get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        url = ASC_API_BASE + path
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        request = urllib.request.Request(
            url,
            method="GET",
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/json"},
        )
        for attempt in range(2):
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    raw = response.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as error:
                try:
                    error.read()
                finally:
                    error.close()
                if error.code in RETRYABLE_HTTP_STATUS_CODES and attempt == 0:
                    time.sleep(1)
                    continue
                raise ASCReadError(f"App Store Connect read failed with HTTP {error.code}") from None
            except (TimeoutError, socket.timeout, urllib.error.URLError) as error:
                if attempt == 0:
                    time.sleep(1)
                    continue
                raise ASCReadError("App Store Connect read timed out") from error
            except json.JSONDecodeError as error:
                raise ASCReadError("App Store Connect returned malformed JSON") from error
        raise ASCReadError("App Store Connect read failed")


def paginated_get(
    client: ReadOnlyASCClient,
    path: str,
    params: dict[str, Any] | None = None,
) -> dict[str, Any]:
    collected: dict[str, Any] = {"data": [], "included": []}
    next_path = path
    next_params = dict(params or {})
    next_params["limit"] = 200
    while True:
        payload = client.get(next_path, next_params)
        collected["data"].extend(payload.get("data") or [])
        collected["included"].extend(payload.get("included") or [])
        next_url = payload.get("links", {}).get("next")
        if not next_url:
            return collected
        parsed = urllib.parse.urlparse(next_url)
        if parsed.netloc and parsed.netloc != "api.appstoreconnect.apple.com":
            raise ASCReadError("App Store Connect returned an unexpected pagination host")
        next_path = parsed.path[3:] if parsed.path.startswith("/v1/") else parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        if not next_path or not query:
            raise ASCReadError("App Store Connect returned malformed pagination data")
        next_params = {key: values if len(values) > 1 else values[0] for key, values in query.items()}


def load_asc_environment(_runner: Runner, env_file: Path) -> dict[str, str]:
    selected_keys = {
        "APP_STORE_CONNECT_KEY_ID",
        "APP_STORE_CONNECT_ISSUER_ID",
        "APP_STORE_CONNECT_API_KEY_PATH",
        "APP_STORE_CONNECT_API_KEY_P8_BASE64",
    }
    environment = {key: value for key, value in os.environ.items() if key in selected_keys}
    has_identity = bool(
        environment.get("APP_STORE_CONNECT_KEY_ID")
        and environment.get("APP_STORE_CONNECT_ISSUER_ID")
    )
    has_key_material = bool(
        environment.get("APP_STORE_CONNECT_API_KEY_PATH")
        or environment.get("APP_STORE_CONNECT_API_KEY_P8_BASE64")
    )
    if has_identity and has_key_material:
        return environment
    if not env_file.is_file():
        return environment
    try:
        lines = env_file.read_text().splitlines()
    except OSError:
        return environment
    for line in lines:
        entry = line.strip()
        if not entry or entry.startswith("#"):
            continue
        if entry.startswith("export "):
            entry = entry.removeprefix("export ").strip()
        key, separator, value = entry.partition("=")
        key = key.strip()
        if not separator or key not in selected_keys:
            continue
        try:
            parsed_value = shlex.split(value, comments=True, posix=True)
        except ValueError:
            continue
        if len(parsed_value) == 1:
            environment[key] = parsed_value[0]
    return environment


def asc_credentials(
    runner: Runner,
    env_file: Path,
) -> tuple[str, str, Path, Path | None] | None:
    environment = load_asc_environment(runner, env_file)
    key_id = environment.get("APP_STORE_CONNECT_KEY_ID", "").strip()
    issuer_id = environment.get("APP_STORE_CONNECT_ISSUER_ID", "").strip()
    if not key_id or not issuer_id:
        return None
    temporary_key_path: Path | None = None
    configured_path = environment.get("APP_STORE_CONNECT_API_KEY_PATH", "").strip()
    if configured_path:
        key_path = Path(configured_path).expanduser()
    else:
        encoded_key = environment.get("APP_STORE_CONNECT_API_KEY_P8_BASE64", "").strip()
        if encoded_key:
            try:
                decoded_key = base64.b64decode(encoded_key, validate=True)
            except (ValueError, binascii.Error):
                return None
            temporary_key_path = None
            try:
                with tempfile.NamedTemporaryFile(delete=False) as temporary:
                    temporary_key_path = Path(temporary.name)
                    temporary.write(decoded_key)
                    temporary.flush()
                temporary_key_path.chmod(0o600)
            except OSError:
                if temporary_key_path is not None:
                    temporary_key_path.unlink(missing_ok=True)
                return None
            key_path = temporary_key_path
        else:
            key_path = DEFAULT_ASC_KEY_DIRECTORY / f"AuthKey_{key_id}.p8"
    if not key_path.is_file():
        if temporary_key_path is not None:
            temporary_key_path.unlink(missing_ok=True)
        return None
    return key_id, issuer_id, key_path, temporary_key_path


def build_version_and_platform(
    payload: dict[str, Any],
    build: dict[str, Any],
) -> tuple[str | None, str | None]:
    relationship = build.get("relationships", {}).get("preReleaseVersion", {}).get("data")
    pre_release_id = relationship.get("id") if isinstance(relationship, dict) else None
    included = {
        item.get("id"): item
        for item in payload.get("included") or []
        if item.get("type") == "preReleaseVersions"
    }
    attributes = included.get(pre_release_id, {}).get("attributes", {})
    return attributes.get("version"), attributes.get("platform")


def query_asc_with_client(
    client: ReadOnlyASCClient,
    target: Target,
) -> ASCEvidence:
    apps = client.get(
        "/apps",
        {"filter[bundleId]": APP_BUNDLE_ID, "fields[apps]": "name,bundleId", "limit": 1},
    ).get("data") or []
    if not apps:
        raise ASCReadError("Context Panel is unavailable in App Store Connect")
    app_id = apps[0]["id"]
    builds_payload = client.get(
        "/builds",
        {
            "filter[app]": app_id,
            "filter[version]": target.build_number,
            "include": "preReleaseVersion",
            "fields[builds]": "version,processingState,uploadedDate,expired,preReleaseVersion",
            "fields[preReleaseVersions]": "version,platform",
            "limit": 200,
        },
    )
    builds = builds_payload.get("data") or []
    groups_payload = paginated_get(
        client,
        f"/apps/{app_id}/betaGroups",
        {"fields[betaGroups]": "isInternalGroup,hasAccessToAllBuilds"},
    )
    internal_groups = [
        group
        for group in groups_payload.get("data") or []
        if group.get("attributes", {}).get("isInternalGroup") is True
    ]
    group_build_ids: dict[str, set[str]] = {}
    for group in internal_groups:
        if group.get("attributes", {}).get("hasAccessToAllBuilds") is True:
            continue
        group_builds = paginated_get(
            client,
            f"/betaGroups/{group['id']}/builds",
            {"fields[builds]": "version,processingState"},
        )
        group_build_ids[group["id"]] = {item["id"] for item in group_builds.get("data") or []}

    platform_evidence: list[ASCPlatformEvidence] = []
    for platform in ASC_PLATFORMS:
        matches = [
            build
            for build in builds
            if build_version_and_platform(builds_payload, build) == (target.version, platform)
        ]
        if not matches:
            platform_evidence.append(
                ASCPlatformEvidence(platform, "missing", "processing", reason="build is not visible yet")
            )
            continue
        if len(matches) > 1:
            platform_evidence.append(
                ASCPlatformEvidence(platform, "unknown", "unknown", reason="multiple matching builds")
            )
            continue
        build = matches[0]
        attributes = build.get("attributes", {})
        processing_state = str(attributes.get("processingState") or "UNKNOWN")
        if attributes.get("expired") is True:
            platform_evidence.append(
                ASCPlatformEvidence(platform, "expired", "unavailable", processing_state)
            )
        elif processing_state in {"FAILED", "INVALID"}:
            platform_evidence.append(
                ASCPlatformEvidence(platform, processing_state.lower(), "unavailable", processing_state)
            )
        elif processing_state != "VALID":
            platform_evidence.append(
                ASCPlatformEvidence(platform, "processing", "processing", processing_state)
            )
        elif not internal_groups:
            platform_evidence.append(
                ASCPlatformEvidence(platform, "valid", "unknown", processing_state, "no internal group visible")
            )
        else:
            assigned_to_every_internal_group = all(
                group.get("attributes", {}).get("hasAccessToAllBuilds") is True
                or build["id"] in group_build_ids.get(group["id"], set())
                for group in internal_groups
            )
            platform_evidence.append(
                ASCPlatformEvidence(
                    platform,
                    "valid",
                    "available" if assigned_to_every_internal_group else "waiting_for_assignment",
                    processing_state,
                )
            )
    return ASCEvidence("available", "direct_local_api", tuple(platform_evidence))


def collect_asc_evidence(runner: Runner, target: Target, env_file: Path) -> ASCEvidence:
    credentials = asc_credentials(runner, env_file)
    if credentials is None:
        unknown = tuple(
            ASCPlatformEvidence(platform, "unknown", "unknown", reason="operator config unavailable")
            for platform in ASC_PLATFORMS
        )
        return ASCEvidence("unavailable", "none", unknown, "local operator config unavailable")
    key_id, issuer_id, key_path, temporary_key_path = credentials
    try:
        token = make_asc_token(key_path, key_id, issuer_id)
        return query_asc_with_client(ReadOnlyASCClient(token), target)
    except ASCReadError as error:
        unknown = tuple(
            ASCPlatformEvidence(platform, "unknown", "unknown", reason="read unavailable")
            for platform in ASC_PLATFORMS
        )
        return ASCEvidence("unavailable", "direct_local_api", unknown, str(error))
    finally:
        if temporary_key_path is not None:
            temporary_key_path.unlink(missing_ok=True)
