#!/usr/bin/env python3
"""Manage bounded exact-build runtime validation sessions."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path


APP_GROUP_ID = "MM5YXC7T6E.group.com.shinycomputers.contextpanel"
REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLOUDKIT_SCHEMA_RECEIPT_TOOL = REPO_ROOT / "scripts/cloudkit-schema-receipt.py"
CLOUDKIT_SCHEMA_RECEIPT_KEY_ENVIRONMENT_VARIABLE = (
    "CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"
)
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
DEFAULT_REFRESH_AGENT = (
    Path("/Applications/Context Panel.app")
    / "Contents"
    / "Library"
    / "LoginItems"
    / "ContextPanelRefreshAgent.app"
    / "Contents"
    / "MacOS"
    / "ContextPanelRefreshAgent"
)
DEFAULT_MAC_SURFACES = (
    "macos.app",
    "macos.widget",
    "macos.refresh-agent",
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
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
    "top-shelf-content-load",
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
    "widget-accessory-unknown",
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
SESSION_KEYS = {
    "schemaVersion",
    "id",
    "createdAt",
    "expiresAt",
    "expectedManifestID",
    "enabledSurfaces",
    "minimumWriteIntervalSeconds",
    "receiptTTLSeconds",
    "maximumReceiptCount",
}
RECEIPT_KEYS = {
    "schemaVersion",
    "evidenceClass",
    "id",
    "sessionID",
    "sessionCreatedAt",
    "sessionExpiresAt",
    "observedAt",
    "retentionExpiresAt",
    "processInstanceID",
    "processSequence",
    "buildIdentity",
    "trigger",
    "presentationMode",
    "selectedSource",
    "presentationDigest",
    "stateBranch",
    "outcome",
}
BUILD_IDENTITY_KEYS = {
    "surface",
    "platform",
    "artifactID",
    "bundleIdentifier",
    "build",
    "fingerprints",
    "executableUUIDs",
}
BUILD_KEYS = {
    "marketingVersion",
    "buildNumber",
    "manifestID",
    "contractFingerprint",
}
FINGERPRINT_KEYS = {"render", "runtime", "placement", "combined"}
REMOTE_ENVELOPE_KEYS = {"schemaVersion", "receipt", "serverReceivedAt"}
MAXIMUM_RETAINED_SESSION_COUNT = 128


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
    start.add_argument("--all-surfaces", action="store_true")
    start.add_argument("--minimum-write-interval-seconds", type=int, default=30)
    start.add_argument("--receipt-ttl-hours", type=int, default=24)
    start.add_argument("--maximum-receipt-count", type=int, default=128)

    status = subparsers.add_parser("status", help="Inspect the current session and receipt count.")
    status.add_argument("--root", type=Path, default=DEFAULT_VALIDATION_ROOT)
    status.add_argument("--session-id")

    sync = subparsers.add_parser(
        "sync",
        help="Ask the canonical signed refresh agent to relay the session and receipts.",
    )
    sync.add_argument("--agent", type=Path, default=DEFAULT_REFRESH_AGENT)
    sync.add_argument("--cloudkit-schema-receipt", type=Path, required=True)

    export = subparsers.add_parser(
        "export",
        help="Export validated local and relayed receipts as one redacted bundle.",
    )
    export.add_argument("--root", type=Path, default=DEFAULT_VALIDATION_ROOT)
    export.add_argument("--output", type=Path)
    export.add_argument("--session-id")

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
        set(session) != SESSION_KEYS
        or session.get("schemaVersion") != 1
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


def session_retention_expires_at(
    session: dict[str, object],
    session_times: tuple[datetime, datetime],
) -> datetime:
    return session_times[1] + timedelta(seconds=int(session["receiptTTLSeconds"]))


def normalized_session_payload(session: dict[str, object]) -> dict[str, object]:
    return {
        "schemaVersion": session["schemaVersion"],
        "id": session["id"],
        "createdAt": session["createdAt"],
        "expiresAt": session["expiresAt"],
        "expectedManifestID": session["expectedManifestID"],
        "enabledSurfaces": list(session["enabledSurfaces"]),
        "minimumWriteIntervalSeconds": session["minimumWriteIntervalSeconds"],
        "receiptTTLSeconds": session["receiptTTLSeconds"],
        "maximumReceiptCount": session["maximumReceiptCount"],
    }


def normalized_receipt_payload(receipt: dict[str, object]) -> dict[str, object]:
    build_identity = receipt["buildIdentity"]
    assert isinstance(build_identity, dict)
    build = build_identity["build"]
    fingerprints = build_identity["fingerprints"]
    executable_uuids = build_identity["executableUUIDs"]
    assert isinstance(build, dict)
    assert isinstance(fingerprints, dict)
    assert isinstance(executable_uuids, list)
    return {
        "schemaVersion": receipt["schemaVersion"],
        "evidenceClass": receipt["evidenceClass"],
        "id": receipt["id"],
        "sessionID": receipt["sessionID"],
        "sessionCreatedAt": receipt["sessionCreatedAt"],
        "sessionExpiresAt": receipt["sessionExpiresAt"],
        "observedAt": receipt["observedAt"],
        "retentionExpiresAt": receipt["retentionExpiresAt"],
        "processInstanceID": receipt["processInstanceID"],
        "processSequence": receipt["processSequence"],
        "buildIdentity": {
            "surface": build_identity["surface"],
            "platform": build_identity["platform"],
            "artifactID": build_identity["artifactID"],
            "bundleIdentifier": build_identity["bundleIdentifier"],
            "build": {key: build[key] for key in BUILD_KEYS},
            "fingerprints": {
                key: fingerprints[key] for key in FINGERPRINT_KEYS
            },
            "executableUUIDs": list(executable_uuids),
        },
        "trigger": receipt["trigger"],
        "presentationMode": receipt["presentationMode"],
        "selectedSource": receipt["selectedSource"],
        "presentationDigest": receipt["presentationDigest"],
        "stateBranch": receipt["stateBranch"],
        "outcome": receipt["outcome"],
    }


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
        set(receipt) != RECEIPT_KEYS
        or set(build_identity) != BUILD_IDENTITY_KEYS
        or not isinstance(build, dict)
        or set(build) != BUILD_KEYS
        or not isinstance(fingerprints, dict)
        or set(fingerprints) != FINGERPRINT_KEYS
        or receipt.get("schemaVersion") != 1
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
        or int(receipt["processSequence"]) > 2**63 - 1
        or not isinstance(surface, str)
        or surface not in session.get("enabledSurfaces", [])
        or platform != SURFACE_PLATFORMS.get(surface)
        or not isinstance(build_identity.get("artifactID"), str)
        or not build_identity.get("artifactID")
        or not isinstance(build_identity.get("bundleIdentifier"), str)
        or not build_identity.get("bundleIdentifier")
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


@contextmanager
def validation_lock(root: Path):
    root.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(root / ".write.lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


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
    if arguments.all_surfaces and arguments.surfaces:
        raise SystemExit("--all-surfaces cannot be combined with --surface")
    manifest_id, manifest_surfaces = load_manifest(arguments.manifest)
    requested_surfaces = sorted(
        manifest_surfaces
        if arguments.all_surfaces
        else set(arguments.surfaces or DEFAULT_MAC_SURFACES)
    )
    unknown_surfaces = sorted(set(requested_surfaces) - manifest_surfaces)
    if unknown_surfaces:
        raise SystemExit(
            "requested surfaces are absent from the exact build manifest: "
            + ", ".join(unknown_surfaces)
        )

    with validation_lock(arguments.root):
        start_session_locked(arguments, manifest_id, requested_surfaces)


def start_session_locked(
    arguments: argparse.Namespace,
    manifest_id: str,
    requested_surfaces: list[str],
) -> None:
    wall_now = utc_now()
    active_path = arguments.root / "runtime-session.json"
    if active_path.is_file():
        active_session = load_json_object(active_path, "runtime validation session")
        active_times = validated_session(active_session, wall_now)
        if active_times is None:
            raise SystemExit("the existing runtime validation session is invalid; stop it before starting another")
        if wall_now < active_times[1]:
            raise SystemExit("a runtime validation session is already active; stop it before starting another")
        archive_session(arguments.root, active_session)
    retained = retained_sessions(arguments.root, wall_now)
    if len(retained) >= MAXIMUM_RETAINED_SESSION_COUNT:
        raise SystemExit(
            "the retained runtime validation session limit has been reached; wait for older evidence to expire"
        )
    created_at = wall_now
    if retained:
        created_at = max(created_at, retained[-1][1][0] + timedelta(seconds=1))

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
    atomic_write_json(active_path, payload)
    atomic_write_json(arguments.root / "runtime-session-last.json", payload)
    archive_session(arguments.root, payload)
    prune_session_journal(arguments.root, created_at)
    print(json.dumps({"active": True, **payload}, indent=2, sort_keys=True))


def archive_session(root: Path, session: dict[str, object]) -> None:
    session_id = normalized_uuid(session.get("id"))
    if session_id is None:
        raise SystemExit("runtime validation session identifier is invalid")
    path = root / "Runtime Sessions" / f"{session_id.lower()}.json"
    if path.is_file():
        existing = load_json_object(path, "archived runtime validation session")
        if (
            validated_session(existing, utc_now()) is None
            or normalized_session_payload(existing) != normalized_session_payload(session)
        ):
            raise SystemExit("archived runtime validation session conflicts with the active session")
        return
    atomic_write_json(path, normalized_session_payload(session))


def retained_sessions(
    root: Path,
    now: datetime,
) -> list[tuple[dict[str, object], tuple[datetime, datetime]]]:
    paths = [root / "runtime-session.json", root / "runtime-session-last.json"]
    paths.extend(sorted((root / "Runtime Sessions").glob("*.json")))
    sessions_by_id: dict[
        str,
        tuple[dict[str, object], tuple[datetime, datetime]],
    ] = {}
    conflicting_ids: set[str] = set()
    for path in paths:
        if not path.is_file():
            continue
        try:
            session = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(session, dict):
            continue
        session_times = validated_session(session, now)
        session_id = normalized_uuid(session.get("id"))
        if (
            session_times is None
            or session_id is None
            or now >= session_retention_expires_at(session, session_times)
        ):
            continue
        normalized = normalized_session_payload(session)
        existing = sessions_by_id.get(session_id)
        if existing is not None and existing[0] != normalized:
            sessions_by_id.pop(session_id, None)
            conflicting_ids.add(session_id)
        elif session_id not in conflicting_ids:
            sessions_by_id[session_id] = (normalized, session_times)
    return sorted(
        sessions_by_id.values(),
        key=lambda value: (value[1][0], str(value[0]["id"])),
    )


def reporting_session(
    root: Path,
    now: datetime,
    requested_session_id: str | None = None,
) -> tuple[dict[str, object], tuple[datetime, datetime], bool] | None:
    sessions = retained_sessions(root, now)
    if not sessions:
        return None
    requested_id = normalized_uuid(requested_session_id) if requested_session_id else None
    if requested_session_id and requested_id is None:
        raise SystemExit("requested runtime validation session identifier is invalid")

    active_id: str | None = None
    active_path = root / "runtime-session.json"
    if active_path.is_file():
        try:
            active = json.loads(active_path.read_text())
        except (OSError, json.JSONDecodeError):
            active = None
        if isinstance(active, dict):
            active_times = validated_session(active, now)
            if active_times is not None and now < active_times[1]:
                active_id = normalized_uuid(active.get("id"))

    if requested_id is not None:
        selected = next(
            (value for value in sessions if normalized_uuid(value[0].get("id")) == requested_id),
            None,
        )
        if selected is None:
            raise SystemExit("requested runtime validation session is unavailable or expired")
    elif active_id is not None:
        selected = next(
            (
                value
                for value in sessions
                if normalized_uuid(value[0].get("id")) == active_id
            ),
            sessions[-1],
        )
    else:
        selected = sessions[-1]
    return selected[0], selected[1], normalized_uuid(selected[0].get("id")) == active_id


def prune_session_journal(root: Path, now: datetime) -> None:
    known: list[tuple[Path, datetime]] = []
    for path in (root / "Runtime Sessions").glob("*.json"):
        try:
            session = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(session, dict):
            continue
        session_times = validated_session(session, now)
        if session_times is None:
            continue
        known.append((path, session_retention_expires_at(session, session_times)))
    retained_entries = [
        value
        for value in sorted(known, key=lambda value: (value[1], value[0].name))
        if now < value[1]
    ]
    retained = {path for path, _ in retained_entries}
    for path, _ in known:
        if path not in retained:
            path.unlink(missing_ok=True)


def validated_receipt_entries(
    root: Path,
    session: dict[str, object],
    session_times: tuple[datetime, datetime],
    now: datetime,
) -> tuple[list[dict[str, object]], int, int]:
    entries_by_id: dict[str, dict[str, object]] = {}
    local_ids: set[str] = set()
    remote_ids: set[str] = set()

    for path in (root / "Runtime Receipts").glob("*.json"):
        try:
            receipt = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(receipt, dict):
            continue
        surface = validated_receipt_surface(receipt, session, session_times)
        retention_expires_at = parse_iso8601(receipt.get("retentionExpiresAt"))
        if surface is None or retention_expires_at is None or now >= retention_expires_at:
            continue
        receipt_id = str(receipt["id"])
        local_ids.add(receipt_id)
        entries_by_id[receipt_id] = {
            "source": "local",
            "serverReceivedAt": None,
            "receipt": normalized_receipt_payload(receipt),
        }

    created_at, _ = session_times
    for path in (root / "Remote Runtime Receipts").glob("*.json"):
        try:
            envelope = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if (
            not isinstance(envelope, dict)
            or set(envelope) != REMOTE_ENVELOPE_KEYS
            or envelope.get("schemaVersion") != 1
        ):
            continue
        receipt = envelope.get("receipt")
        server_received_at = parse_iso8601(envelope.get("serverReceivedAt"))
        if not isinstance(receipt, dict) or server_received_at is None:
            continue
        surface = validated_receipt_surface(receipt, session, session_times)
        retention_expires_at = parse_iso8601(receipt.get("retentionExpiresAt"))
        if (
            surface is None
            or retention_expires_at is None
            or now >= retention_expires_at
            or server_received_at < created_at - timedelta(minutes=5)
            or server_received_at > retention_expires_at + timedelta(minutes=5)
        ):
            continue
        receipt_id = str(receipt["id"])
        remote_ids.add(receipt_id)
        entries_by_id[receipt_id] = {
            "source": "cloudkit",
            "serverReceivedAt": iso8601(server_received_at),
            "receipt": normalized_receipt_payload(receipt),
        }

    entries = ordered_receipt_entries(list(entries_by_id.values()))
    return entries, len(local_ids), len(remote_ids)


def ordered_receipt_entries(
    entries: list[dict[str, object]],
) -> list[dict[str, object]]:
    entries_by_process: dict[str, list[dict[str, object]]] = {}
    for entry in entries:
        receipt = entry["receipt"]
        assert isinstance(receipt, dict)
        process_id = str(receipt["processInstanceID"]).lower()
        entries_by_process.setdefault(process_id, []).append(entry)

    decorated: list[tuple[datetime, str, int, str, dict[str, object]]] = []
    minimum_date = datetime.min.replace(tzinfo=timezone.utc)
    for process_id, process_entries in entries_by_process.items():
        effective_time = minimum_date
        for entry in sorted(
            process_entries,
            key=lambda value: (
                int(value["receipt"]["processSequence"]),
                str(value["receipt"]["observedAt"]),
                str(value["receipt"]["id"]),
            ),
        ):
            receipt = entry["receipt"]
            assert isinstance(receipt, dict)
            candidate_time = parse_iso8601(entry.get("serverReceivedAt"))
            if candidate_time is None:
                candidate_time = parse_iso8601(receipt.get("observedAt")) or minimum_date
            effective_time = max(effective_time, candidate_time)
            decorated.append(
                (
                    effective_time,
                    process_id,
                    int(receipt["processSequence"]),
                    str(receipt["id"]),
                    entry,
                )
            )
    return [value[4] for value in sorted(decorated, key=lambda value: value[:4])]


def session_status(arguments: argparse.Namespace) -> None:
    now = utc_now()
    reporting = reporting_session(arguments.root, now, arguments.session_id)
    if reporting is None:
        print(
            json.dumps(
                {
                    "active": False,
                    "valid": False,
                    "receiptCount": 0,
                    "localReceiptCount": 0,
                    "remoteReceiptCount": 0,
                    "observedSurfaces": [],
                },
                indent=2,
                sort_keys=True,
            )
        )
        return

    session, session_times, active = reporting
    entries, local_receipt_count, remote_receipt_count = validated_receipt_entries(
        arguments.root,
        session,
        session_times,
        now,
    )
    retained = retained_sessions(arguments.root, now)
    observed_surfaces = sorted(
        {
            str(entry["receipt"]["buildIdentity"]["surface"])
            for entry in entries
            if isinstance(entry.get("receipt"), dict)
            and isinstance(entry["receipt"].get("buildIdentity"), dict)
        }
    )
    print(
        json.dumps(
            {
                "active": active,
                "valid": True,
                "id": session.get("id"),
                "createdAt": session.get("createdAt"),
                "expiresAt": session.get("expiresAt"),
                "expectedManifestID": session.get("expectedManifestID"),
                "enabledSurfaces": session.get("enabledSurfaces"),
                "receiptCount": len(entries),
                "localReceiptCount": local_receipt_count,
                "remoteReceiptCount": remote_receipt_count,
                "retainedSessionCount": len(retained),
                "retainedSessionIDs": [value[0]["id"] for value in retained],
                "observedSurfaces": observed_surfaces,
            },
            indent=2,
            sort_keys=True,
        )
    )


def export_receipts(arguments: argparse.Namespace) -> None:
    now = utc_now()
    reporting = reporting_session(arguments.root, now, arguments.session_id)
    if reporting is None:
        raise SystemExit("no valid current or archived runtime validation session is available")
    session, session_times, active = reporting
    entries, local_receipt_count, remote_receipt_count = validated_receipt_entries(
        arguments.root,
        session,
        session_times,
        now,
    )
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "active": active,
        "exportedAt": iso8601(now),
        "session": normalized_session_payload(session),
        "receiptCount": len(entries),
        "localReceiptCount": local_receipt_count,
        "remoteReceiptCount": remote_receipt_count,
        "receipts": entries,
    }
    if arguments.output is None:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return
    atomic_write_json(arguments.output, payload)
    print(
        json.dumps(
            {
                "exported": True,
                "receiptCount": len(entries),
                "output": str(arguments.output),
            },
            indent=2,
            sort_keys=True,
        )
    )


def sync_runtime_receipts(arguments: argparse.Namespace) -> None:
    if not arguments.agent.is_file() or not os.access(arguments.agent, os.X_OK):
        raise SystemExit("canonical signed refresh agent is unavailable")
    try:
        source_commit_result = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit("repository source commit is unavailable") from error
    source_commit = source_commit_result.stdout.strip().lower()
    if source_commit_result.returncode != 0 or not COMMIT_PATTERN.fullmatch(source_commit):
        raise SystemExit("repository source commit is unavailable")
    receipt_verification = subprocess.run(
        [
            sys.executable,
            str(DEFAULT_CLOUDKIT_SCHEMA_RECEIPT_TOOL),
            "verify",
            "--receipt",
            str(arguments.cloudkit_schema_receipt),
            "--environment",
            "production",
            "--container-id",
            "iCloud.com.shinycomputers.contextpanel",
            "--source-commit",
            source_commit,
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if receipt_verification.returncode != 0:
        message = receipt_verification.stderr.strip().splitlines()
        detail = message[-1] if message else "receipt verification did not complete"
        raise SystemExit(f"runtime receipt relay blocked: {detail}")
    agent_environment = os.environ.copy()
    agent_environment.pop(CLOUDKIT_SCHEMA_RECEIPT_KEY_ENVIRONMENT_VARIABLE, None)
    try:
        completed = subprocess.run(
            [str(arguments.agent), "--sync-runtime-receipts"],
            env=agent_environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit("runtime receipt host synchronization did not complete") from error
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise SystemExit("runtime receipt host synchronization returned invalid output") from error
    valid_actions = {"published", "cleared", "mirrored", "rejected", "unchanged", "failed"}
    count_fields = (
        "uploadedReceiptCount",
        "downloadedReceiptCount",
        "deletedRemoteReceiptCount",
    )
    if (
        not isinstance(payload, dict)
        or not isinstance(payload.get("healthy"), bool)
        or payload.get("sessionAction") not in valid_actions
        or any(
            not isinstance(payload.get(field), int)
            or isinstance(payload.get(field), bool)
            or int(payload[field]) < 0
            for field in count_fields
        )
        or not isinstance(payload.get("messages"), list)
        or any(not isinstance(message, str) for message in payload["messages"])
    ):
        raise SystemExit("runtime receipt host synchronization returned an unsupported result")
    print(json.dumps(payload, indent=2, sort_keys=True))
    if completed.returncode != 0 or not payload["healthy"]:
        raise SystemExit(completed.returncode or 2)


def stop_session(arguments: argparse.Namespace) -> None:
    with validation_lock(arguments.root):
        was_active = stop_session_locked(arguments.root)
    print(json.dumps({"active": False, "closed": was_active}, indent=2, sort_keys=True))


def stop_session_locked(root: Path) -> bool:
    session_path = root / "runtime-session.json"
    was_active = session_path.is_file()
    now = utc_now()
    if was_active:
        session = load_json_object(session_path, "runtime validation session")
        if validated_session(session, now) is not None:
            archive_session(root, session)
    session_path.unlink(missing_ok=True)
    prune_session_journal(root, now)
    return was_active


def main() -> None:
    arguments = parse_arguments()
    if arguments.command == "start":
        start_session(arguments)
    elif arguments.command == "status":
        session_status(arguments)
    elif arguments.command == "sync":
        sync_runtime_receipts(arguments)
    elif arguments.command == "export":
        export_receipts(arguments)
    else:
        stop_session(arguments)


if __name__ == "__main__":
    main()
