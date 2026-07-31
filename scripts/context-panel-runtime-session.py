#!/usr/bin/env python3
"""Manage bounded exact-build runtime validation sessions."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import tempfile
import uuid


APP_GROUP_ID = "MM5YXC7T6E.group.com.shinycomputers.contextpanel"
DEFAULT_VALIDATION_ROOT = (
    Path.home()
    / "Library"
    / "Group Containers"
    / APP_GROUP_ID
    / "Context Panel"
    / "Validation"
)
DEFAULT_MANIFEST = (
    Path("/Applications/Context Panel.app")
    / "Contents"
    / "Resources"
    / "ContextPanelSurfaceManifest.json"
)
DEFAULT_MAC_SURFACES = (
    "macos.app",
    "macos.widget",
    "macos.refresh-agent",
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SURFACE_PLATFORMS = {
    "macos.app": "macOS",
    "macos.widget": "macOS",
    "macos.refresh-agent": "macOS",
    "ios.app": "iOS",
    "ios.widget": "iOS",
    "ipados.app": "iPadOS",
    "ipados.widget": "iPadOS",
    "visionos.app": "visionOS",
    "visionos.widget": "visionOS",
    "watchos.app": "watchOS",
    "watchos.complication": "watchOS",
    "tvos.app": "tvOS",
    "tvos.top-shelf": "tvOS",
}
RECEIPT_TRIGGERS = {
    "app-snapshot-load",
    "widget-snapshot",
    "widget-timeline",
    "refresh-once",
    "background-refresh",
}
PRESENTATION_MODES = {
    "app-overview",
    "widget-system-small",
    "widget-system-medium",
    "widget-system-large",
    "widget-system-extra-large",
    "widget-accessory-circular",
    "widget-accessory-rectangular",
    "widget-accessory-inline",
    "widget-accessory-corner",
    "widget-unknown",
    "refresh-agent",
    "watch-app",
    "top-shelf",
}
SELECTED_SOURCES = {
    "app-group-snapshot",
    "widget-sandbox-mirror",
    "refreshed-snapshot",
    "companion-app-group",
    "companion-local-cache",
    "cloudkit",
    "icloud",
    "none",
}
STATE_BRANCHES = {
    "ready",
    "setup-needed",
    "stale",
    "failure",
    "refreshed",
    "skipped-fresh",
    "skipped-already-running",
    "skipped-no-reports",
    "unknown",
}
OUTCOMES = {"success", "degraded", "failure"}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Open, inspect, or close a privacy-safe runtime receipt session."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    start = subparsers.add_parser("start", help="Open an expiring validation session.")
    start.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    start.add_argument("--root", type=Path, default=DEFAULT_VALIDATION_ROOT)
    start.add_argument("--duration-minutes", type=int, default=30)
    start.add_argument("--surface", action="append", dest="surfaces")
    start.add_argument("--minimum-write-interval-seconds", type=int, default=30)
    start.add_argument("--receipt-ttl-hours", type=int, default=24)
    start.add_argument("--maximum-receipt-count", type=int, default=128)

    status = subparsers.add_parser("status", help="Inspect the current session and receipt count.")
    status.add_argument("--root", type=Path, default=DEFAULT_VALIDATION_ROOT)

    stop = subparsers.add_parser("stop", help="Close the current session without deleting receipts.")
    stop.add_argument("--root", type=Path, default=DEFAULT_VALIDATION_ROOT)

    return parser.parse_args()


def load_json_object(path: Path, label: str) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"{label} is unavailable or invalid: {path}") from error
    if not isinstance(payload, dict):
        raise SystemExit(f"{label} must be a JSON object: {path}")
    return payload


def load_manifest(path: Path) -> tuple[str, set[str]]:
    manifest = load_json_object(path, "surface manifest")
    manifest_id = manifest.get("manifestId")
    surfaces = manifest.get("surfaces")
    if (
        manifest.get("schemaVersion") != 1
        or manifest.get("kind") != "context-panel-surface-build-intent"
        or not isinstance(manifest_id, str)
        or not SHA256_PATTERN.fullmatch(manifest_id)
        or not isinstance(surfaces, list)
    ):
        raise SystemExit("surface manifest identity is unsupported or invalid")

    surface_ids: set[str] = set()
    for surface in surfaces:
        if not isinstance(surface, dict) or not isinstance(surface.get("id"), str):
            raise SystemExit("surface manifest contains an invalid surface")
        surface_id = str(surface["id"])
        if surface_id not in SURFACE_PLATFORMS:
            raise SystemExit(f"surface manifest contains an unsupported surface: {surface_id}")
        if surface_id in surface_ids:
            raise SystemExit(f"surface manifest duplicates surface: {surface_id}")
        surface_ids.add(surface_id)
    if not surface_ids:
        raise SystemExit("surface manifest contains no surfaces")
    return manifest_id, surface_ids


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def iso8601(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso8601(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def normalized_uuid(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError:
        return None


def whole_seconds(value: datetime) -> int:
    return int(value.timestamp())


def is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def validated_session(
    session: dict[str, object],
    now: datetime,
) -> tuple[datetime, datetime] | None:
    created_at = parse_iso8601(session.get("createdAt"))
    expires_at = parse_iso8601(session.get("expiresAt"))
    enabled_surfaces = session.get("enabledSurfaces")
    minimum_interval = session.get("minimumWriteIntervalSeconds")
    receipt_ttl = session.get("receiptTTLSeconds")
    maximum_count = session.get("maximumReceiptCount")
    if (
        session.get("schemaVersion") != 1
        or normalized_uuid(session.get("id")) is None
        or not isinstance(session.get("expectedManifestID"), str)
        or not SHA256_PATTERN.fullmatch(str(session["expectedManifestID"]))
        or created_at is None
        or expires_at is None
        or created_at > expires_at
        or expires_at - created_at > timedelta(hours=6)
        or created_at > now + timedelta(minutes=5)
        or not isinstance(enabled_surfaces, list)
        or not enabled_surfaces
        or any(not isinstance(surface, str) for surface in enabled_surfaces)
        or len(enabled_surfaces) != len(set(enabled_surfaces))
        or any(surface not in SURFACE_PLATFORMS for surface in enabled_surfaces)
        or not is_number(minimum_interval)
        or not 0 <= float(minimum_interval) <= 300
        or not float(minimum_interval).is_integer()
        or not is_number(receipt_ttl)
        or not 60 <= float(receipt_ttl) <= 7 * 24 * 60 * 60
        or not float(receipt_ttl).is_integer()
        or not isinstance(maximum_count, int)
        or isinstance(maximum_count, bool)
        or not 1 <= maximum_count <= 512
    ):
        return None
    return created_at, expires_at


def hash_parts(domain: str, parts: list[str]) -> str:
    digest = hashlib.sha256()
    for part in [domain, *parts]:
        encoded = part.encode()
        digest.update(struct.pack(">Q", len(encoded)))
        digest.update(encoded)
    return digest.hexdigest()


def validated_receipt_surface(
    receipt: dict[str, object],
    session: dict[str, object],
    session_times: tuple[datetime, datetime],
) -> str | None:
    created_at, expires_at = session_times
    observed_at = parse_iso8601(receipt.get("observedAt"))
    retention_expires_at = parse_iso8601(receipt.get("retentionExpiresAt"))
    build_identity = receipt.get("buildIdentity")
    if not isinstance(build_identity, dict):
        return None
    build = build_identity.get("build")
    fingerprints = build_identity.get("fingerprints")
    executable_uuids = build_identity.get("executableUUIDs")
    surface = build_identity.get("surface")
    platform = build_identity.get("platform")
    if (
        receipt.get("schemaVersion") != 1
        or receipt.get("evidenceClass") != "actual-runtime"
        or normalized_uuid(receipt.get("sessionID"))
        != normalized_uuid(session.get("id"))
        or parse_iso8601(receipt.get("sessionCreatedAt")) != created_at
        or parse_iso8601(receipt.get("sessionExpiresAt")) != expires_at
        or observed_at is None
        or observed_at < created_at - timedelta(minutes=5)
        or observed_at >= expires_at
        or retention_expires_at is None
        or retention_expires_at <= observed_at
        or retention_expires_at - observed_at > timedelta(days=7)
        or retention_expires_at - observed_at
        != timedelta(seconds=float(session.get("receiptTTLSeconds", 0)))
        or normalized_uuid(receipt.get("processInstanceID")) is None
        or not isinstance(receipt.get("processSequence"), int)
        or isinstance(receipt.get("processSequence"), bool)
        or int(receipt["processSequence"]) <= 0
        or not isinstance(surface, str)
        or surface not in session.get("enabledSurfaces", [])
        or platform != SURFACE_PLATFORMS.get(surface)
        or not isinstance(build_identity.get("artifactID"), str)
        or not build_identity.get("artifactID")
        or not isinstance(build_identity.get("bundleIdentifier"), str)
        or not build_identity.get("bundleIdentifier")
        or not isinstance(build, dict)
        or not isinstance(fingerprints, dict)
        or not isinstance(executable_uuids, list)
        or not executable_uuids
        or any(normalized_uuid(value) is None for value in executable_uuids)
        or executable_uuids
        != sorted({normalized_uuid(value) for value in executable_uuids})
        or receipt.get("trigger") not in RECEIPT_TRIGGERS
        or receipt.get("presentationMode") not in PRESENTATION_MODES
        or receipt.get("selectedSource") not in SELECTED_SOURCES
        or receipt.get("stateBranch") not in STATE_BRANCHES
        or receipt.get("outcome") not in OUTCOMES
        or not isinstance(receipt.get("presentationDigest"), str)
        or not SHA256_PATTERN.fullmatch(str(receipt["presentationDigest"]))
    ):
        return None

    build_strings = [
        build.get("marketingVersion"),
        build.get("buildNumber"),
        build.get("manifestID"),
        build.get("contractFingerprint"),
    ]
    fingerprint_values = [
        fingerprints.get("render"),
        fingerprints.get("runtime"),
        fingerprints.get("placement"),
        fingerprints.get("combined"),
    ]
    if (
        any(not isinstance(value, str) or not value for value in build_strings[:2])
        or any(
            not isinstance(value, str) or not SHA256_PATTERN.fullmatch(value)
            for value in [*build_strings[2:], *fingerprint_values]
        )
        or build.get("manifestID") != session.get("expectedManifestID")
    ):
        return None

    expected_id = hash_parts(
        "context-panel/runtime-receipt/id/v1",
        [
            str(uuid.UUID(str(receipt["sessionID"]))).lower(),
            str(whole_seconds(created_at)),
            str(whole_seconds(expires_at)),
            str(whole_seconds(observed_at)),
            str(whole_seconds(retention_expires_at)),
            surface,
            str(platform),
            str(build_identity["artifactID"]),
            str(build_identity["bundleIdentifier"]),
            str(build["marketingVersion"]),
            str(build["buildNumber"]),
            str(build["manifestID"]),
            str(build["contractFingerprint"]),
            *[str(value) for value in fingerprint_values],
            ",".join(str(value) for value in executable_uuids),
            str(uuid.UUID(str(receipt["processInstanceID"]))).lower(),
            str(receipt["processSequence"]),
            str(receipt["trigger"]),
            str(receipt["presentationMode"]),
            str(receipt["selectedSource"]),
            str(receipt["presentationDigest"]),
            str(receipt["stateBranch"]),
            str(receipt["outcome"]),
        ],
    )
    receipt_id = receipt.get("id")
    if not isinstance(receipt_id, str) or receipt_id != expected_id:
        return None
    return surface


def atomic_write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=path.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def validate_start_bounds(arguments: argparse.Namespace) -> None:
    if not 1 <= arguments.duration_minutes <= 360:
        raise SystemExit("duration must be between 1 and 360 minutes")
    if not 0 <= arguments.minimum_write_interval_seconds <= 300:
        raise SystemExit("minimum write interval must be between 0 and 300 seconds")
    if not 1 <= arguments.receipt_ttl_hours <= 168:
        raise SystemExit("receipt TTL must be between 1 and 168 hours")
    if not 1 <= arguments.maximum_receipt_count <= 512:
        raise SystemExit("maximum receipt count must be between 1 and 512")


def start_session(arguments: argparse.Namespace) -> None:
    validate_start_bounds(arguments)
    manifest_id, manifest_surfaces = load_manifest(arguments.manifest)
    requested_surfaces = sorted(set(arguments.surfaces or DEFAULT_MAC_SURFACES))
    unknown_surfaces = sorted(set(requested_surfaces) - manifest_surfaces)
    if unknown_surfaces:
        raise SystemExit(
            "requested surfaces are absent from the exact build manifest: "
            + ", ".join(unknown_surfaces)
        )

    created_at = utc_now()
    expires_at = created_at + timedelta(minutes=arguments.duration_minutes)
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "id": str(uuid.uuid4()).upper(),
        "createdAt": iso8601(created_at),
        "expiresAt": iso8601(expires_at),
        "expectedManifestID": manifest_id,
        "enabledSurfaces": requested_surfaces,
        "minimumWriteIntervalSeconds": arguments.minimum_write_interval_seconds,
        "receiptTTLSeconds": arguments.receipt_ttl_hours * 60 * 60,
        "maximumReceiptCount": arguments.maximum_receipt_count,
    }
    atomic_write_json(arguments.root / "runtime-session.json", payload)
    print(json.dumps({"active": True, **payload}, indent=2, sort_keys=True))


def receipt_summary(
    root: Path,
    session: dict[str, object],
    session_times: tuple[datetime, datetime],
) -> tuple[int, list[str]]:
    receipt_directory = root / "Runtime Receipts"
    receipt_count = 0
    surfaces: set[str] = set()
    for path in receipt_directory.glob("*.json"):
        try:
            receipt = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(receipt, dict):
            continue
        surface = validated_receipt_surface(receipt, session, session_times)
        if surface is None:
            continue
        receipt_count += 1
        surfaces.add(surface)
    return receipt_count, sorted(surfaces)


def session_status(arguments: argparse.Namespace) -> None:
    session_path = arguments.root / "runtime-session.json"
    if not session_path.is_file():
        print(json.dumps({"active": False, "receiptCount": 0}, indent=2, sort_keys=True))
        return

    session = load_json_object(session_path, "runtime validation session")
    now = utc_now()
    session_times = validated_session(session, now)
    active = session_times is not None and now < session_times[1]
    receipt_count, observed_surfaces = (
        receipt_summary(arguments.root, session, session_times)
        if session_times is not None
        else (0, [])
    )
    print(
        json.dumps(
            {
                "active": active,
                "valid": session_times is not None,
                "id": session.get("id"),
                "createdAt": session.get("createdAt"),
                "expiresAt": session.get("expiresAt"),
                "expectedManifestID": session.get("expectedManifestID"),
                "enabledSurfaces": session.get("enabledSurfaces"),
                "receiptCount": receipt_count,
                "observedSurfaces": observed_surfaces,
            },
            indent=2,
            sort_keys=True,
        )
    )


def stop_session(arguments: argparse.Namespace) -> None:
    session_path = arguments.root / "runtime-session.json"
    was_active = session_path.is_file()
    session_path.unlink(missing_ok=True)
    print(json.dumps({"active": False, "closed": was_active}, indent=2, sort_keys=True))


def main() -> None:
    arguments = parse_arguments()
    if arguments.command == "start":
        start_session(arguments)
    elif arguments.command == "status":
        session_status(arguments)
    else:
        stop_session(arguments)


if __name__ == "__main__":
    main()
