from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
from typing import Any
import uuid

from .models import (
    EXIT_BLOCKED,
    EXIT_OK,
    EXIT_UNKNOWN,
    Runner,
    Target,
    ValidationReport,
    classify_install,
    iso8601,
)
from .session import (
    ACTIVE_SESSION_LIFECYCLES,
    RUNTIME_SURFACES,
    CoordinatorSessionState,
    CoordinatorSessionStateError,
    SessionStateStore,
    normalize_utc,
    parse_iso8601,
    validate_target,
)


RUNTIME_EVIDENCE_SCHEMA_VERSION = 1
MAXIMUM_RUNTIME_RECEIPT_COUNT = 4096
SURFACE_MANIFEST_ALGORITHM = "sha256"
SURFACE_DIGEST_DOMAIN = "context-panel-surface/v1"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
UUID_PATTERN = re.compile(
    r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
)
RUNTIME_SESSION_SCRIPT = Path(__file__).resolve().parents[1] / "context-panel-runtime-session.py"

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
EXTENSION_HOST_SURFACES = {
    "macos.widget": "macos.app",
    "ios.widget": "ios.app",
    "ipados.widget": "ipados.app",
    "visionos.widget": "visionos.app",
    "watchos.complication": "watchos.app",
    "tvos.top-shelf": "tvos.app",
}
EXPECTED_MANIFEST_KEYS = {
    "schemaVersion",
    "kind",
    "algorithm",
    "digestDomain",
    "sourceManifestId",
    "contractFingerprint",
    "layout",
    "archive",
    "source",
    "artifacts",
    "surfaces",
    "expectedBuildId",
}
EXPECTED_ARTIFACT_KEYS = {
    "artifactId",
    "bundleIdentifier",
    "marketingVersion",
    "buildNumber",
    "sourceCommit",
    "configuration",
    "xcodeBuild",
    "treeState",
    "codeSignatureValid",
    "executableSha256",
    "executableUUIDs",
    "entitlementsSha256",
    "profileSha256",
}
EXPECTED_SURFACE_KEYS = {"id", "artifactId", "bundleIdentifier", "fingerprints"}
FINGERPRINT_KEYS = {"render", "runtime", "placement", "combined"}
RUNTIME_SESSION_KEYS = {
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
RUNTIME_STATUS_EMPTY_KEYS = {
    "active",
    "valid",
    "receiptCount",
    "localReceiptCount",
    "remoteReceiptCount",
    "observedSurfaces",
}
RUNTIME_STATUS_KEYS = RUNTIME_STATUS_EMPTY_KEYS | {
    "id",
    "createdAt",
    "expiresAt",
    "expectedManifestID",
    "enabledSurfaces",
    "retainedSessionCount",
    "retainedSessionIDs",
}
RUNTIME_EXPORT_KEYS = {
    "schemaVersion",
    "active",
    "exportedAt",
    "session",
    "receiptCount",
    "localReceiptCount",
    "remoteReceiptCount",
    "receipts",
}
RUNTIME_ENTRY_KEYS = {"source", "serverReceivedAt", "receipt"}
RUNTIME_RECEIPT_KEYS = {
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
RUNTIME_BUILD_IDENTITY_KEYS = {
    "surface",
    "platform",
    "artifactID",
    "bundleIdentifier",
    "build",
    "fingerprints",
    "executableUUIDs",
}
RUNTIME_BUILD_KEYS = {
    "marketingVersion",
    "buildNumber",
    "manifestID",
    "contractFingerprint",
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


class RuntimeEvidenceError(CoordinatorSessionStateError):
    pass


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def hash_parts(domain: str, parts: list[bytes | str]) -> str:
    digest = hashlib.sha256()
    for part in [domain, *parts]:
        encoded = part if isinstance(part, bytes) else part.encode("utf-8")
        digest.update(struct.pack(">Q", len(encoded)))
        digest.update(encoded)
    return digest.hexdigest()


def normalized_uuid(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError:
        return None


def normalized_uuid_list(value: object) -> tuple[str, ...] | None:
    if not isinstance(value, list) or not value:
        return None
    normalized_values = [normalized_uuid(item) for item in value]
    if any(item is None for item in normalized_values):
        return None
    normalized = tuple(sorted(str(item) for item in set(normalized_values)))
    if len(normalized) != len(value):
        return None
    return normalized


def is_nonnegative_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def is_sha256(value: object) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def is_sorted_unique_strings(
    value: object,
    allowed: tuple[str, ...] | set[str] | None = None,
) -> bool:
    return (
        isinstance(value, list)
        and all(isinstance(item, str) for item in value)
        and value == sorted(set(value))
        and (allowed is None or all(item in allowed for item in value))
    )


@dataclass(frozen=True)
class ExpectedSurfaceIdentity:
    surface: str
    platform: str
    artifact_id: str
    bundle_identifier: str
    marketing_version: str
    build_number: str
    manifest_id: str
    contract_fingerprint: str
    render_fingerprint: str
    runtime_fingerprint: str
    placement_fingerprint: str
    combined_fingerprint: str
    executable_uuids: tuple[str, ...]
    expected_build_id: str

    def to_dict(self) -> dict[str, object]:
        return {
            "surface": self.surface,
            "platform": self.platform,
            "artifactID": self.artifact_id,
            "bundleIdentifier": self.bundle_identifier,
            "marketingVersion": self.marketing_version,
            "buildNumber": self.build_number,
            "manifestID": self.manifest_id,
            "contractFingerprint": self.contract_fingerprint,
            "fingerprints": {
                "render": self.render_fingerprint,
                "runtime": self.runtime_fingerprint,
                "placement": self.placement_fingerprint,
                "combined": self.combined_fingerprint,
            },
            "executableUUIDs": list(self.executable_uuids),
            "expectedBuildID": self.expected_build_id,
        }

    @classmethod
    def from_dict(cls, payload: object) -> ExpectedSurfaceIdentity:
        expected_keys = {
            "surface",
            "platform",
            "artifactID",
            "bundleIdentifier",
            "marketingVersion",
            "buildNumber",
            "manifestID",
            "contractFingerprint",
            "fingerprints",
            "executableUUIDs",
            "expectedBuildID",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise RuntimeEvidenceError("runtime expected surface identity is invalid")
        fingerprints = payload.get("fingerprints")
        executable_uuids = normalized_uuid_list(payload.get("executableUUIDs"))
        if (
            not isinstance(fingerprints, dict)
            or set(fingerprints) != FINGERPRINT_KEYS
            or executable_uuids is None
        ):
            raise RuntimeEvidenceError("runtime expected surface identity is invalid")
        identity = cls(
            surface=payload.get("surface"),
            platform=payload.get("platform"),
            artifact_id=payload.get("artifactID"),
            bundle_identifier=payload.get("bundleIdentifier"),
            marketing_version=payload.get("marketingVersion"),
            build_number=payload.get("buildNumber"),
            manifest_id=payload.get("manifestID"),
            contract_fingerprint=payload.get("contractFingerprint"),
            render_fingerprint=fingerprints.get("render"),
            runtime_fingerprint=fingerprints.get("runtime"),
            placement_fingerprint=fingerprints.get("placement"),
            combined_fingerprint=fingerprints.get("combined"),
            executable_uuids=executable_uuids,
            expected_build_id=payload.get("expectedBuildID"),
        )
        validate_expected_identity(identity)
        return identity

    def identity_digest(self) -> str:
        return hashlib.sha256(canonical_json(self.to_dict())).hexdigest()


def validate_expected_identity(identity: ExpectedSurfaceIdentity) -> None:
    if (
        not isinstance(identity.surface, str)
        or identity.surface not in RUNTIME_SURFACES
        or identity.platform != SURFACE_PLATFORMS.get(identity.surface)
        or not isinstance(identity.artifact_id, str)
        or not identity.artifact_id
        or not isinstance(identity.bundle_identifier, str)
        or not identity.bundle_identifier
        or not isinstance(identity.marketing_version, str)
        or not identity.marketing_version
        or not isinstance(identity.build_number, str)
        or not identity.build_number
        or any(
            not is_sha256(value)
            for value in (
                identity.manifest_id,
                identity.contract_fingerprint,
                identity.render_fingerprint,
                identity.runtime_fingerprint,
                identity.placement_fingerprint,
                identity.combined_fingerprint,
                identity.expected_build_id,
            )
        )
        or not identity.executable_uuids
        or tuple(sorted(set(identity.executable_uuids))) != identity.executable_uuids
        or any(UUID_PATTERN.fullmatch(value) is None for value in identity.executable_uuids)
    ):
        raise RuntimeEvidenceError("runtime expected surface identity is invalid")


@dataclass(frozen=True)
class RuntimeReceiptEvidence:
    receipt_id: str
    runtime_session_id: str
    surface: str
    source: str
    server_received_at: str | None
    observed_at: str
    process_instance_id: str
    process_sequence: int
    loaded_executable_uuids: tuple[str, ...]
    identity_digest: str
    state_branch: str
    outcome: str

    def has_same_receipt_payload(self, other: RuntimeReceiptEvidence) -> bool:
        return (
            self.receipt_id,
            self.runtime_session_id,
            self.surface,
            self.observed_at,
            self.process_instance_id,
            self.process_sequence,
            self.loaded_executable_uuids,
            self.identity_digest,
            self.state_branch,
            self.outcome,
        ) == (
            other.receipt_id,
            other.runtime_session_id,
            other.surface,
            other.observed_at,
            other.process_instance_id,
            other.process_sequence,
            other.loaded_executable_uuids,
            other.identity_digest,
            other.state_branch,
            other.outcome,
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "receiptID": self.receipt_id,
            "runtimeSessionID": self.runtime_session_id,
            "surface": self.surface,
            "source": self.source,
            "serverReceivedAt": self.server_received_at,
            "observedAt": self.observed_at,
            "processInstanceID": self.process_instance_id,
            "processSequence": self.process_sequence,
            "loadedExecutableUUIDs": list(self.loaded_executable_uuids),
            "identityDigest": self.identity_digest,
            "stateBranch": self.state_branch,
            "outcome": self.outcome,
        }

    @classmethod
    def from_dict(cls, payload: object) -> RuntimeReceiptEvidence:
        expected_keys = {
            "receiptID",
            "runtimeSessionID",
            "surface",
            "source",
            "serverReceivedAt",
            "observedAt",
            "processInstanceID",
            "processSequence",
            "loadedExecutableUUIDs",
            "identityDigest",
            "stateBranch",
            "outcome",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise RuntimeEvidenceError("runtime receipt evidence is invalid")
        evidence = cls(
            receipt_id=payload.get("receiptID"),
            runtime_session_id=payload.get("runtimeSessionID"),
            surface=payload.get("surface"),
            source=payload.get("source"),
            server_received_at=payload.get("serverReceivedAt"),
            observed_at=payload.get("observedAt"),
            process_instance_id=payload.get("processInstanceID"),
            process_sequence=payload.get("processSequence"),
            loaded_executable_uuids=(
                normalized_uuid_list(payload.get("loadedExecutableUUIDs")) or ()
            ),
            identity_digest=payload.get("identityDigest"),
            state_branch=payload.get("stateBranch"),
            outcome=payload.get("outcome"),
        )
        if (
            not is_sha256(evidence.receipt_id)
            or normalized_uuid(evidence.runtime_session_id) != evidence.runtime_session_id
            or evidence.surface not in RUNTIME_SURFACES
            or evidence.source not in {"local", "cloudkit"}
            or parse_iso8601(evidence.observed_at) is None
            or (
                evidence.server_received_at is not None
                and parse_iso8601(evidence.server_received_at) is None
            )
            or normalized_uuid(evidence.process_instance_id) != evidence.process_instance_id
            or not isinstance(evidence.process_sequence, int)
            or isinstance(evidence.process_sequence, bool)
            or evidence.process_sequence <= 0
            or not evidence.loaded_executable_uuids
            or not is_sha256(evidence.identity_digest)
            or evidence.state_branch not in STATE_BRANCHES
            or evidence.outcome not in OUTCOMES
        ):
            raise RuntimeEvidenceError("runtime receipt evidence is invalid")
        return evidence


def merged_duplicate_receipt(
    existing: RuntimeReceiptEvidence,
    candidate: RuntimeReceiptEvidence,
) -> RuntimeReceiptEvidence | None:
    if not existing.has_same_receipt_payload(candidate):
        return None
    if existing.source == candidate.source:
        if existing.source != "cloudkit":
            return existing
        existing_received_at = parse_iso8601(existing.server_received_at)
        candidate_received_at = parse_iso8601(candidate.server_received_at)
        if candidate_received_at is not None and (
            existing_received_at is None or candidate_received_at > existing_received_at
        ):
            return candidate
        return existing
    return existing if existing.source == "cloudkit" else candidate


@dataclass(frozen=True)
class RuntimeObservationSummary:
    attempted_at: str
    result: str
    runtime_session_id: str | None
    runtime_session_active: bool | None
    runtime_session_created_at: str | None
    runtime_session_expires_at: str | None
    expected_manifest_id: str | None
    enabled_surfaces: tuple[str, ...]
    exported_at: str | None
    sync_healthy: bool | None
    sync_action: str | None
    uploaded_receipt_count: int
    downloaded_receipt_count: int
    deleted_remote_receipt_count: int
    diagnostics: tuple[str, ...]
    surface_diagnostics: tuple[tuple[str, str], ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "attemptedAt": self.attempted_at,
            "result": self.result,
            "runtimeSessionID": self.runtime_session_id,
            "runtimeSessionActive": self.runtime_session_active,
            "runtimeSessionCreatedAt": self.runtime_session_created_at,
            "runtimeSessionExpiresAt": self.runtime_session_expires_at,
            "expectedManifestID": self.expected_manifest_id,
            "enabledSurfaces": list(self.enabled_surfaces),
            "exportedAt": self.exported_at,
            "sync": {
                "healthy": self.sync_healthy,
                "sessionAction": self.sync_action,
                "uploadedReceiptCount": self.uploaded_receipt_count,
                "downloadedReceiptCount": self.downloaded_receipt_count,
                "deletedRemoteReceiptCount": self.deleted_remote_receipt_count,
            },
            "diagnostics": list(self.diagnostics),
            "surfaceDiagnostics": [
                {"surface": surface, "code": code}
                for surface, code in self.surface_diagnostics
            ],
        }

    @classmethod
    def from_dict(cls, payload: object) -> RuntimeObservationSummary:
        expected_keys = {
            "attemptedAt",
            "result",
            "runtimeSessionID",
            "runtimeSessionActive",
            "runtimeSessionCreatedAt",
            "runtimeSessionExpiresAt",
            "expectedManifestID",
            "enabledSurfaces",
            "exportedAt",
            "sync",
            "diagnostics",
            "surfaceDiagnostics",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise RuntimeEvidenceError("runtime observation summary is invalid")
        sync = payload.get("sync")
        diagnostics = payload.get("diagnostics")
        enabled_surfaces = payload.get("enabledSurfaces")
        surface_diagnostics_payload = payload.get("surfaceDiagnostics")
        if (
            not isinstance(sync, dict)
            or set(sync)
            != {
                "healthy",
                "sessionAction",
                "uploadedReceiptCount",
                "downloadedReceiptCount",
                "deletedRemoteReceiptCount",
            }
            or not isinstance(diagnostics, list)
            or not isinstance(enabled_surfaces, list)
            or not isinstance(surface_diagnostics_payload, list)
        ):
            raise RuntimeEvidenceError("runtime observation summary is invalid")
        surface_diagnostics: list[tuple[str, str]] = []
        for item in surface_diagnostics_payload:
            if (
                not isinstance(item, dict)
                or set(item) != {"surface", "code"}
                or item.get("surface") not in RUNTIME_SURFACES
                or not isinstance(item.get("code"), str)
                or not item.get("code")
            ):
                raise RuntimeEvidenceError("runtime observation summary is invalid")
            surface_diagnostics.append((str(item["surface"]), str(item["code"])))
        summary = cls(
            attempted_at=payload.get("attemptedAt"),
            result=payload.get("result"),
            runtime_session_id=payload.get("runtimeSessionID"),
            runtime_session_active=payload.get("runtimeSessionActive"),
            runtime_session_created_at=payload.get("runtimeSessionCreatedAt"),
            runtime_session_expires_at=payload.get("runtimeSessionExpiresAt"),
            expected_manifest_id=payload.get("expectedManifestID"),
            enabled_surfaces=tuple(enabled_surfaces),
            exported_at=payload.get("exportedAt"),
            sync_healthy=sync.get("healthy"),
            sync_action=sync.get("sessionAction"),
            uploaded_receipt_count=sync.get("uploadedReceiptCount"),
            downloaded_receipt_count=sync.get("downloadedReceiptCount"),
            deleted_remote_receipt_count=sync.get("deletedRemoteReceiptCount"),
            diagnostics=tuple(diagnostics),
            surface_diagnostics=tuple(surface_diagnostics),
        )
        validate_observation_summary(summary)
        return summary


def validate_observation_summary(summary: RuntimeObservationSummary) -> None:
    optional_timestamps = (
        summary.runtime_session_created_at,
        summary.runtime_session_expires_at,
        summary.exported_at,
    )
    if (
        parse_iso8601(summary.attempted_at) is None
        or summary.result not in {"healthy", "degraded", "missing", "diagnostic"}
        or (
            summary.runtime_session_id is not None
            and normalized_uuid(summary.runtime_session_id) != summary.runtime_session_id
        )
        or (
            summary.runtime_session_active is not None
            and not isinstance(summary.runtime_session_active, bool)
        )
        or any(value is not None and parse_iso8601(value) is None for value in optional_timestamps)
        or (
            summary.expected_manifest_id is not None
            and not is_sha256(summary.expected_manifest_id)
        )
        or tuple(sorted(set(summary.enabled_surfaces))) != summary.enabled_surfaces
        or any(surface not in RUNTIME_SURFACES for surface in summary.enabled_surfaces)
        or (
            summary.sync_healthy is not None
            and not isinstance(summary.sync_healthy, bool)
        )
        or (
            summary.sync_action is not None
            and summary.sync_action
            not in {"published", "cleared", "mirrored", "rejected", "unchanged", "failed"}
        )
        or any(
            not is_nonnegative_integer(value)
            for value in (
                summary.uploaded_receipt_count,
                summary.downloaded_receipt_count,
                summary.deleted_remote_receipt_count,
            )
        )
        or any(not isinstance(value, str) or not value for value in summary.diagnostics)
        or tuple(sorted(set(summary.diagnostics))) != summary.diagnostics
        or tuple(sorted(set(summary.surface_diagnostics))) != summary.surface_diagnostics
    ):
        raise RuntimeEvidenceError("runtime observation summary is invalid")


@dataclass(frozen=True)
class RuntimeEvidenceState:
    schema_version: int
    coordinator_session_id: str
    target: Target
    requested_surfaces: tuple[str, ...]
    updated_at: str
    revision: int
    expected_surfaces: tuple[ExpectedSurfaceIdentity, ...]
    receipts: tuple[RuntimeReceiptEvidence, ...]
    last_observation: RuntimeObservationSummary | None

    def to_dict(self) -> dict[str, object]:
        return {
            "schemaVersion": self.schema_version,
            "coordinatorSessionID": self.coordinator_session_id,
            "target": {
                "version": self.target.version,
                "buildNumber": self.target.build_number,
            },
            "requestedSurfaces": list(self.requested_surfaces),
            "updatedAt": self.updated_at,
            "revision": self.revision,
            "expectedSurfaces": [identity.to_dict() for identity in self.expected_surfaces],
            "receipts": [receipt.to_dict() for receipt in self.receipts],
            "lastObservation": (
                self.last_observation.to_dict() if self.last_observation is not None else None
            ),
        }

    @classmethod
    def from_dict(cls, payload: object) -> RuntimeEvidenceState:
        expected_keys = {
            "schemaVersion",
            "coordinatorSessionID",
            "target",
            "requestedSurfaces",
            "updatedAt",
            "revision",
            "expectedSurfaces",
            "receipts",
            "lastObservation",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise RuntimeEvidenceError("runtime evidence state is invalid")
        target = payload.get("target")
        requested_surfaces = payload.get("requestedSurfaces")
        expected_surfaces = payload.get("expectedSurfaces")
        receipts = payload.get("receipts")
        if (
            not isinstance(target, dict)
            or set(target) != {"version", "buildNumber"}
            or not isinstance(requested_surfaces, list)
            or not isinstance(expected_surfaces, list)
            or not isinstance(receipts, list)
        ):
            raise RuntimeEvidenceError("runtime evidence state is invalid")
        last_observation_payload = payload.get("lastObservation")
        state = cls(
            schema_version=payload.get("schemaVersion"),
            coordinator_session_id=payload.get("coordinatorSessionID"),
            target=Target(target.get("version"), target.get("buildNumber")),
            requested_surfaces=tuple(requested_surfaces),
            updated_at=payload.get("updatedAt"),
            revision=payload.get("revision"),
            expected_surfaces=tuple(
                ExpectedSurfaceIdentity.from_dict(item) for item in expected_surfaces
            ),
            receipts=tuple(RuntimeReceiptEvidence.from_dict(item) for item in receipts),
            last_observation=(
                RuntimeObservationSummary.from_dict(last_observation_payload)
                if last_observation_payload is not None
                else None
            ),
        )
        validate_runtime_evidence_state(state)
        return state


def validate_runtime_evidence_state(state: RuntimeEvidenceState) -> None:
    validate_target(state.target)
    expected_surface_ids = tuple(identity.surface for identity in state.expected_surfaces)
    expected_manifest_identities = {
        (identity.manifest_id, identity.contract_fingerprint)
        for identity in state.expected_surfaces
    }
    receipt_ids = tuple(receipt.receipt_id for receipt in state.receipts)
    if (
        state.schema_version != RUNTIME_EVIDENCE_SCHEMA_VERSION
        or normalized_uuid(state.coordinator_session_id) != state.coordinator_session_id
        or any(not isinstance(surface, str) for surface in state.requested_surfaces)
        or tuple(sorted(set(state.requested_surfaces))) != state.requested_surfaces
        or not state.requested_surfaces
        or any(surface not in RUNTIME_SURFACES for surface in state.requested_surfaces)
        or parse_iso8601(state.updated_at) is None
        or not isinstance(state.revision, int)
        or isinstance(state.revision, bool)
        or state.revision < 1
        or tuple(sorted(expected_surface_ids)) != expected_surface_ids
        or len(expected_surface_ids) != len(set(expected_surface_ids))
        or len(expected_manifest_identities) > 1
        or any(surface not in state.requested_surfaces for surface in expected_surface_ids)
        or len(receipt_ids) != len(set(receipt_ids))
        or len(state.receipts) > MAXIMUM_RUNTIME_RECEIPT_COUNT
        or any(receipt.surface not in state.requested_surfaces for receipt in state.receipts)
    ):
        raise RuntimeEvidenceError("runtime evidence state is invalid")
    expected_by_surface = {identity.surface: identity for identity in state.expected_surfaces}
    for receipt in state.receipts:
        expected = expected_by_surface.get(receipt.surface)
        if (
            expected is None
            or receipt.identity_digest != expected.identity_digest()
            or not set(receipt.loaded_executable_uuids).issubset(expected.executable_uuids)
        ):
            raise RuntimeEvidenceError("runtime evidence state is invalid")
    if tuple(ordered_receipt_evidence(state.receipts)) != state.receipts:
        raise RuntimeEvidenceError("runtime evidence state is invalid")


@dataclass(frozen=True)
class RuntimeSessionObservation:
    attempted_at: datetime
    sync_payload: dict[str, object] | None
    status_payload: dict[str, object] | None
    export_payload: dict[str, object] | None
    diagnostics: tuple[str, ...]


def load_expected_surface_identities(
    paths: list[Path],
    target: Target,
    requested_surfaces: tuple[str, ...],
) -> tuple[ExpectedSurfaceIdentity, ...]:
    payloads: list[dict[str, object]] = []
    for path in paths:
        try:
            payload = json.loads(path.expanduser().read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeEvidenceError("expected signed build manifest is unavailable or invalid") from error
        if not isinstance(payload, dict):
            raise RuntimeEvidenceError("expected signed build manifest is invalid")
        payloads.append(payload)
    return expected_surface_identities_from_payloads(
        payloads,
        target,
        requested_surfaces,
    )


def expected_surface_identities_from_payloads(
    payloads: list[dict[str, object]] | tuple[dict[str, object], ...],
    target: Target,
    requested_surfaces: tuple[str, ...],
) -> tuple[ExpectedSurfaceIdentity, ...]:
    identities: dict[str, ExpectedSurfaceIdentity] = {}
    manifest_identity: tuple[str, str] | None = None
    requested = set(requested_surfaces)
    for payload in payloads:
        if not isinstance(payload, dict) or set(payload) != EXPECTED_MANIFEST_KEYS:
            raise RuntimeEvidenceError("expected signed build manifest is invalid")
        digest_domain = payload.get("digestDomain")
        expected_build_id = payload.get("expectedBuildId")
        unsigned_payload = {key: value for key, value in payload.items() if key != "expectedBuildId"}
        if (
            payload.get("schemaVersion") != 1
            or payload.get("kind") != "context-panel-expected-signed-build"
            or payload.get("algorithm") != SURFACE_MANIFEST_ALGORITHM
            or digest_domain != SURFACE_DIGEST_DOMAIN
            or not is_sha256(payload.get("sourceManifestId"))
            or not is_sha256(payload.get("contractFingerprint"))
            or not is_sha256(expected_build_id)
            or hash_parts(
                f"{digest_domain}/expected-build",
                [canonical_json(unsigned_payload)],
            )
            != expected_build_id
        ):
            raise RuntimeEvidenceError("expected signed build manifest is invalid")
        source = payload.get("source")
        artifacts_payload = payload.get("artifacts")
        surfaces_payload = payload.get("surfaces")
        if (
            not isinstance(source, dict)
            or source.get("marketingVersion") != target.version
            or source.get("buildNumber") != target.build_number
            or not isinstance(artifacts_payload, list)
            or not isinstance(surfaces_payload, list)
        ):
            raise RuntimeEvidenceError("expected signed build manifest targets another build")
        current_manifest_identity = (
            str(payload["sourceManifestId"]),
            str(payload["contractFingerprint"]),
        )
        if manifest_identity is not None and manifest_identity != current_manifest_identity:
            raise RuntimeEvidenceError("expected signed build manifests do not share one identity")
        manifest_identity = current_manifest_identity

        artifacts: dict[str, dict[str, object]] = {}
        for artifact in artifacts_payload:
            if not isinstance(artifact, dict) or set(artifact) != EXPECTED_ARTIFACT_KEYS:
                raise RuntimeEvidenceError("expected signed build artifact is invalid")
            artifact_id = artifact.get("artifactId")
            executable_uuids = normalized_uuid_list(artifact.get("executableUUIDs"))
            if (
                not isinstance(artifact_id, str)
                or not artifact_id
                or artifact_id in artifacts
                or not isinstance(artifact.get("bundleIdentifier"), str)
                or not artifact.get("bundleIdentifier")
                or artifact.get("marketingVersion") != target.version
                or artifact.get("buildNumber") != target.build_number
                or artifact.get("codeSignatureValid") is not True
                or executable_uuids is None
                or any(
                    not is_sha256(artifact.get(key))
                    for key in ("executableSha256", "entitlementsSha256", "profileSha256")
                )
            ):
                raise RuntimeEvidenceError("expected signed build artifact is invalid")
            artifacts[artifact_id] = {**artifact, "executableUUIDs": executable_uuids}

        seen_manifest_surfaces: set[str] = set()
        for surface_payload in surfaces_payload:
            if not isinstance(surface_payload, dict) or set(surface_payload) != EXPECTED_SURFACE_KEYS:
                raise RuntimeEvidenceError("expected signed build surface is invalid")
            surface = surface_payload.get("id")
            if surface not in RUNTIME_SURFACES or surface in seen_manifest_surfaces:
                raise RuntimeEvidenceError("expected signed build surface is invalid")
            seen_manifest_surfaces.add(str(surface))
            if surface not in requested:
                continue
            artifact_id = surface_payload.get("artifactId")
            artifact = artifacts.get(str(artifact_id))
            fingerprints = surface_payload.get("fingerprints")
            if (
                artifact is None
                or surface_payload.get("bundleIdentifier") != artifact.get("bundleIdentifier")
                or not isinstance(fingerprints, dict)
                or set(fingerprints) != FINGERPRINT_KEYS
                or any(not is_sha256(fingerprints.get(key)) for key in FINGERPRINT_KEYS)
            ):
                raise RuntimeEvidenceError("expected signed build surface is invalid")
            identity = ExpectedSurfaceIdentity(
                surface=str(surface),
                platform=SURFACE_PLATFORMS[str(surface)],
                artifact_id=str(artifact_id),
                bundle_identifier=str(surface_payload["bundleIdentifier"]),
                marketing_version=target.version,
                build_number=target.build_number,
                manifest_id=current_manifest_identity[0],
                contract_fingerprint=current_manifest_identity[1],
                render_fingerprint=str(fingerprints["render"]),
                runtime_fingerprint=str(fingerprints["runtime"]),
                placement_fingerprint=str(fingerprints["placement"]),
                combined_fingerprint=str(fingerprints["combined"]),
                executable_uuids=tuple(artifact["executableUUIDs"]),
                expected_build_id=str(expected_build_id),
            )
            validate_expected_identity(identity)
            existing = identities.get(identity.surface)
            if existing is not None and existing != identity:
                raise RuntimeEvidenceError("expected signed build surface identity conflicts")
            identities[identity.surface] = identity
    if payloads and not identities:
        raise RuntimeEvidenceError("expected signed build manifests do not cover requested surfaces")
    return tuple(identities[surface] for surface in sorted(identities))


class RuntimeSessionAdapter:
    def __init__(self, runner: Runner, script: Path = RUNTIME_SESSION_SCRIPT):
        self.runner = runner
        self.script = script

    def collect(self, now: datetime) -> RuntimeSessionObservation:
        return self._collect(now, sync=False)

    def sync_and_collect(self, now: datetime) -> RuntimeSessionObservation:
        return self._collect(now, sync=True)

    def _collect(self, now: datetime, *, sync: bool) -> RuntimeSessionObservation:
        diagnostics: set[str] = set()
        sync_payload: dict[str, object] | None = None
        if sync:
            sync_result = self.runner.run(
                [sys.executable, str(self.script), "sync"],
                timeout=130,
            )
            parsed_sync = self._parse_json_object(sync_result.stdout)
            if sync_result.timed_out:
                diagnostics.add("sync-timeout")
            elif parsed_sync is None or not self._valid_sync_payload(parsed_sync):
                diagnostics.add("sync-unavailable" if sync_result.returncode else "sync-invalid")
            else:
                sync_payload = parsed_sync
                if sync_result.returncode != 0 or sync_payload["healthy"] is not True:
                    diagnostics.add("sync-degraded")

        status_result = self.runner.run(
            [sys.executable, str(self.script), "status"],
            timeout=30,
        )
        status_payload = self._parse_json_object(status_result.stdout)
        if status_result.timed_out:
            diagnostics.add("status-timeout")
        if (
            status_result.returncode != 0
            or status_payload is None
            or not self._valid_status_payload(status_payload)
        ):
            diagnostics.add("status-unavailable")
            return RuntimeSessionObservation(
                normalize_utc(now),
                sync_payload,
                None,
                None,
                tuple(sorted(diagnostics)),
            )
        if status_payload["valid"] is False:
            diagnostics.add("runtime-session-missing")
            return RuntimeSessionObservation(
                normalize_utc(now),
                sync_payload,
                status_payload,
                None,
                tuple(sorted(diagnostics)),
            )

        session_id = str(status_payload["id"])
        export_result = self.runner.run(
            [
                sys.executable,
                str(self.script),
                "export",
                "--session-id",
                session_id,
            ],
            timeout=30,
        )
        export_payload = self._parse_json_object(export_result.stdout)
        if export_result.timed_out:
            diagnostics.add("export-timeout")
        if (
            export_result.returncode != 0
            or export_payload is None
            or not self._valid_export_payload(export_payload, status_payload)
        ):
            diagnostics.add("export-unavailable")
            export_payload = None
        return RuntimeSessionObservation(
            normalize_utc(now),
            sync_payload,
            status_payload,
            export_payload,
            tuple(sorted(diagnostics)),
        )

    @staticmethod
    def _parse_json_object(output: str) -> dict[str, object] | None:
        try:
            payload = json.loads(output)
        except json.JSONDecodeError:
            return None
        return payload if isinstance(payload, dict) else None

    @staticmethod
    def _valid_sync_payload(payload: dict[str, object]) -> bool:
        return (
            isinstance(payload.get("healthy"), bool)
            and payload.get("sessionAction")
            in {"published", "cleared", "mirrored", "rejected", "unchanged", "failed"}
            and all(
                is_nonnegative_integer(payload.get(key))
                for key in (
                    "uploadedReceiptCount",
                    "downloadedReceiptCount",
                    "deletedRemoteReceiptCount",
                )
            )
            and isinstance(payload.get("messages"), list)
            and all(isinstance(message, str) for message in payload["messages"])
        )

    @staticmethod
    def _valid_status_payload(payload: dict[str, object]) -> bool:
        if payload.get("valid") is False:
            return (
                set(payload) == RUNTIME_STATUS_EMPTY_KEYS
                and payload.get("active") is False
                and all(
                    is_nonnegative_integer(payload.get(key))
                    for key in ("receiptCount", "localReceiptCount", "remoteReceiptCount")
                )
                and payload.get("observedSurfaces") == []
            )
        enabled_surfaces = payload.get("enabledSurfaces")
        observed_surfaces = payload.get("observedSurfaces")
        retained_session_ids = payload.get("retainedSessionIDs")
        return (
            set(payload) == RUNTIME_STATUS_KEYS
            and payload.get("valid") is True
            and isinstance(payload.get("active"), bool)
            and normalized_uuid(payload.get("id")) == payload.get("id")
            and parse_iso8601(payload.get("createdAt")) is not None
            and parse_iso8601(payload.get("expiresAt")) is not None
            and is_sha256(payload.get("expectedManifestID"))
            and is_sorted_unique_strings(enabled_surfaces, RUNTIME_SURFACES)
            and is_sorted_unique_strings(observed_surfaces, RUNTIME_SURFACES)
            and all(
                is_nonnegative_integer(payload.get(key))
                for key in (
                    "receiptCount",
                    "localReceiptCount",
                    "remoteReceiptCount",
                    "retainedSessionCount",
                )
            )
            and isinstance(retained_session_ids, list)
            and all(isinstance(value, str) for value in retained_session_ids)
            and all(normalized_uuid(value) == value for value in retained_session_ids)
            and len(retained_session_ids) == payload.get("retainedSessionCount")
        )

    @staticmethod
    def _valid_export_payload(
        payload: dict[str, object],
        status: dict[str, object],
    ) -> bool:
        session = payload.get("session")
        receipts = payload.get("receipts")
        if (
            set(payload) != RUNTIME_EXPORT_KEYS
            or payload.get("schemaVersion") != 1
            or not isinstance(payload.get("active"), bool)
            or parse_iso8601(payload.get("exportedAt")) is None
            or not isinstance(session, dict)
            or set(session) != RUNTIME_SESSION_KEYS
            or not isinstance(receipts, list)
            or not all(isinstance(entry, dict) for entry in receipts)
            or not all(
                is_nonnegative_integer(payload.get(key))
                for key in ("receiptCount", "localReceiptCount", "remoteReceiptCount")
            )
            or payload.get("receiptCount") != len(receipts)
            or payload.get("active") != status.get("active")
        ):
            return False
        status_session = {
            "id": status.get("id"),
            "createdAt": status.get("createdAt"),
            "expiresAt": status.get("expiresAt"),
            "expectedManifestID": status.get("expectedManifestID"),
            "enabledSurfaces": status.get("enabledSurfaces"),
        }
        return all(session.get(key) == value for key, value in status_session.items())


class RuntimeEvidenceStore:
    def __init__(self, session_store: SessionStateStore):
        self.session_store = session_store

    def load(self, session: CoordinatorSessionState) -> RuntimeEvidenceState | None:
        path = self.session_store.runtime_evidence_path(session.id)
        if path.is_symlink() or path.parent.is_symlink():
            raise RuntimeEvidenceError("runtime evidence path is invalid")
        if not path.is_file():
            return None
        state = self._load_path(path)
        self._validate_session_binding(state, session)
        return state

    def attach_expected(
        self,
        session: CoordinatorSessionState,
        identities: tuple[ExpectedSurfaceIdentity, ...],
        now: datetime,
    ) -> RuntimeEvidenceState | None:
        if not identities:
            return self.load(session)
        if session.lifecycle not in ACTIVE_SESSION_LIFECYCLES:
            raise RuntimeEvidenceError("runtime expected build evidence cannot change for a closed session")
        with self.session_store.lock():
            current_session = self.session_store._load_path(
                self.session_store.path(session.target),
                session.target,
            )
            if current_session is None or current_session.id != session.id:
                raise RuntimeEvidenceError("coordinator session changed during runtime reconciliation")
            path = self.session_store.runtime_evidence_path(session.id)
            created = not path.is_file()
            state = self._new_state(session, now) if created else self._load_path(path)
            self._validate_session_binding(state, current_session)
            expected_by_surface = {item.surface: item for item in state.expected_surfaces}
            expected_manifest_identity = (
                (
                    state.expected_surfaces[0].manifest_id,
                    state.expected_surfaces[0].contract_fingerprint,
                )
                if state.expected_surfaces
                else None
            )
            changed = False
            for identity in identities:
                if identity.surface not in session.requested_surfaces:
                    continue
                if expected_manifest_identity is not None and expected_manifest_identity != (
                    identity.manifest_id,
                    identity.contract_fingerprint,
                ):
                    raise RuntimeEvidenceError(
                        "runtime expected surfaces do not share one manifest identity"
                    )
                existing = expected_by_surface.get(identity.surface)
                if existing is not None and existing != identity:
                    raise RuntimeEvidenceError("runtime expected surface identity conflicts")
                if existing is None:
                    expected_by_surface[identity.surface] = identity
                    changed = True
            if not changed:
                return state
            next_state = replace(
                state,
                expected_surfaces=tuple(
                    expected_by_surface[surface] for surface in sorted(expected_by_surface)
                ),
                updated_at=iso8601(max(normalize_utc(now), parse_iso8601(state.updated_at))),
                revision=state.revision if created else state.revision + 1,
            )
            validate_runtime_evidence_state(next_state)
            self._write_path(path, next_state)
            return next_state

    def reconcile(
        self,
        session: CoordinatorSessionState,
        observation: RuntimeSessionObservation,
    ) -> tuple[RuntimeEvidenceState, bool]:
        if session.lifecycle not in ACTIVE_SESSION_LIFECYCLES:
            raise RuntimeEvidenceError("runtime evidence cannot be reconciled for a closed session")
        with self.session_store.lock():
            current_session = self.session_store._load_path(
                self.session_store.path(session.target),
                session.target,
            )
            if current_session is None or current_session.id != session.id:
                raise RuntimeEvidenceError("coordinator session changed during runtime reconciliation")
            path = self.session_store.runtime_evidence_path(session.id)
            if not path.is_file():
                raise RuntimeEvidenceError("runtime expected build evidence is unavailable")
            state = self._load_path(path)
            self._validate_session_binding(state, current_session)
            next_state, superseded = reconcile_runtime_observation(state, observation)
            if next_state != state:
                self._write_path(path, next_state)
            return next_state, superseded

    @staticmethod
    def _new_state(session: CoordinatorSessionState, now: datetime) -> RuntimeEvidenceState:
        state = RuntimeEvidenceState(
            schema_version=RUNTIME_EVIDENCE_SCHEMA_VERSION,
            coordinator_session_id=session.id,
            target=session.target,
            requested_surfaces=session.requested_surfaces,
            updated_at=iso8601(normalize_utc(now)),
            revision=1,
            expected_surfaces=(),
            receipts=(),
            last_observation=None,
        )
        validate_runtime_evidence_state(state)
        return state

    @staticmethod
    def _validate_session_binding(
        state: RuntimeEvidenceState,
        session: CoordinatorSessionState,
    ) -> None:
        if (
            state.coordinator_session_id != session.id
            or state.target != session.target
            or state.requested_surfaces != session.requested_surfaces
        ):
            raise RuntimeEvidenceError("runtime evidence does not match its coordinator session")

    @staticmethod
    def _load_path(path: Path) -> RuntimeEvidenceState:
        if path.is_symlink() or path.parent.is_symlink():
            raise RuntimeEvidenceError("runtime evidence path is invalid")
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeEvidenceError("runtime evidence state is unreadable") from error
        return RuntimeEvidenceState.from_dict(payload)

    @staticmethod
    def _write_path(path: Path, state: RuntimeEvidenceState) -> None:
        validate_runtime_evidence_state(state)
        if path.is_symlink() or path.parent.is_symlink():
            raise RuntimeEvidenceError("runtime evidence path is invalid")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path.parent, 0o700)
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary_path = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(state.to_dict(), stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temporary_path, 0o600)
            os.replace(temporary_path, path)
            try:
                directory_descriptor = os.open(path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory_descriptor)
                finally:
                    os.close(directory_descriptor)
            except OSError:
                pass
        finally:
            temporary_path.unlink(missing_ok=True)


def reconcile_runtime_observation(
    state: RuntimeEvidenceState,
    observation: RuntimeSessionObservation,
) -> tuple[RuntimeEvidenceState, bool]:
    diagnostics = set(observation.diagnostics)
    status = observation.status_payload
    runtime_session_id = (
        normalized_uuid(status.get("id"))
        if status is not None and status.get("valid") is True
        else None
    )
    previous_runtime_session_id = (
        state.last_observation.runtime_session_id
        if state.last_observation is not None
        else None
    )
    latest_surface_diagnostics: dict[str, str | None] = (
        dict(state.last_observation.surface_diagnostics)
        if state.last_observation is not None
        and (
            runtime_session_id is None
            or runtime_session_id == previous_runtime_session_id
        )
        else {}
    )
    superseded_surfaces: set[str] = set()
    exact_receipts: list[RuntimeReceiptEvidence] = []
    superseded = False
    export = observation.export_payload
    expected_by_surface = {identity.surface: identity for identity in state.expected_surfaces}

    if export is not None and status is not None:
        raw_receipts = export.get("receipts")
        assert isinstance(raw_receipts, list)
        seen_in_export: dict[str, RuntimeReceiptEvidence] = {}
        conflicting_ids: set[str] = set()
        conflicting_surfaces: set[str] = set()
        for entry in raw_receipts:
            parsed, diagnostic = validated_runtime_receipt(
                entry,
                export,
                state.target,
                state.requested_surfaces,
                expected_by_surface,
            )
            if diagnostic is not None:
                surface, code = diagnostic
                if surface is not None:
                    latest_surface_diagnostics[surface] = code
                    if code == "newer-build-observed":
                        superseded = True
                        superseded_surfaces.add(surface)
                else:
                    diagnostics.add(code)
                continue
            if parsed is None:
                continue
            assert parsed is not None
            if parsed.surface not in conflicting_surfaces:
                latest_surface_diagnostics[parsed.surface] = None
            existing = seen_in_export.get(parsed.receipt_id)
            if existing is not None:
                merged = merged_duplicate_receipt(existing, parsed)
                if merged is None:
                    conflicting_ids.add(parsed.receipt_id)
                    conflicting_surfaces.add(parsed.surface)
                    latest_surface_diagnostics[parsed.surface] = "conflicting-duplicate-receipt"
                elif parsed.receipt_id not in conflicting_ids:
                    seen_in_export[parsed.receipt_id] = merged
            elif parsed.receipt_id not in conflicting_ids:
                seen_in_export[parsed.receipt_id] = parsed
        exact_receipts = [
            receipt
            for receipt_id, receipt in seen_in_export.items()
            if receipt_id not in conflicting_ids
        ]

    receipts_by_id = {receipt.receipt_id: receipt for receipt in state.receipts}
    for receipt in exact_receipts:
        existing = receipts_by_id.get(receipt.receipt_id)
        if existing is not None:
            merged = merged_duplicate_receipt(existing, receipt)
            if merged is None:
                receipts_by_id.pop(receipt.receipt_id, None)
                latest_surface_diagnostics[receipt.surface] = "conflicting-duplicate-receipt"
            else:
                receipts_by_id[receipt.receipt_id] = merged
        else:
            receipts_by_id[receipt.receipt_id] = receipt
    ordered_receipts = tuple(ordered_receipt_evidence(tuple(receipts_by_id.values())))
    if len(ordered_receipts) > MAXIMUM_RUNTIME_RECEIPT_COUNT:
        raise RuntimeEvidenceError("runtime evidence receipt limit was exceeded")

    sync = observation.sync_payload or {}
    runtime_session_active = status.get("active") if runtime_session_id is not None else None
    runtime_session_created_at = status.get("createdAt") if runtime_session_id is not None else None
    runtime_session_expires_at = status.get("expiresAt") if runtime_session_id is not None else None
    expected_manifest_id = status.get("expectedManifestID") if runtime_session_id is not None else None
    enabled_surfaces = (
        tuple(status.get("enabledSurfaces", [])) if runtime_session_id is not None else ()
    )
    exported_at = export.get("exportedAt") if export is not None else None
    result = "healthy"
    surface_diagnostics = {
        (surface, code)
        for surface, code in latest_surface_diagnostics.items()
        if code is not None
    }
    surface_diagnostics.update(
        (surface, "newer-build-observed") for surface in superseded_surfaces
    )
    if runtime_session_id is None:
        result = "missing"
    elif export is None:
        result = "diagnostic"
    elif diagnostics or surface_diagnostics:
        result = "degraded"
    summary = RuntimeObservationSummary(
        attempted_at=iso8601(observation.attempted_at),
        result=result,
        runtime_session_id=runtime_session_id,
        runtime_session_active=runtime_session_active,
        runtime_session_created_at=runtime_session_created_at,
        runtime_session_expires_at=runtime_session_expires_at,
        expected_manifest_id=expected_manifest_id,
        enabled_surfaces=tuple(sorted(enabled_surfaces)),
        exported_at=exported_at,
        sync_healthy=sync.get("healthy") if sync else None,
        sync_action=sync.get("sessionAction") if sync else None,
        uploaded_receipt_count=int(sync.get("uploadedReceiptCount", 0)),
        downloaded_receipt_count=int(sync.get("downloadedReceiptCount", 0)),
        deleted_remote_receipt_count=int(sync.get("deletedRemoteReceiptCount", 0)),
        diagnostics=tuple(sorted(diagnostics)),
        surface_diagnostics=tuple(sorted(surface_diagnostics)),
    )
    validate_observation_summary(summary)
    next_state = replace(
        state,
        updated_at=iso8601(
            max(observation.attempted_at, parse_iso8601(state.updated_at))
        ),
        revision=state.revision + 1,
        receipts=ordered_receipts,
        last_observation=summary,
    )
    validate_runtime_evidence_state(next_state)
    return next_state, superseded


def validated_runtime_receipt(
    entry: object,
    export: dict[str, object],
    target: Target,
    requested_surfaces: tuple[str, ...],
    expected_by_surface: dict[str, ExpectedSurfaceIdentity],
) -> tuple[RuntimeReceiptEvidence | None, tuple[str | None, str] | None]:
    if not isinstance(entry, dict) or set(entry) != RUNTIME_ENTRY_KEYS:
        return None, (None, "invalid-receipt-entry")
    receipt = entry.get("receipt")
    if not isinstance(receipt, dict) or set(receipt) != RUNTIME_RECEIPT_KEYS:
        return None, (None, "invalid-receipt-contract")
    build_identity = receipt.get("buildIdentity")
    if not isinstance(build_identity, dict) or set(build_identity) != RUNTIME_BUILD_IDENTITY_KEYS:
        return None, (None, "invalid-receipt-contract")
    build = build_identity.get("build")
    fingerprints = build_identity.get("fingerprints")
    executable_uuids = normalized_uuid_list(build_identity.get("executableUUIDs"))
    session = export.get("session")
    if (
        not isinstance(build, dict)
        or set(build) != RUNTIME_BUILD_KEYS
        or not isinstance(fingerprints, dict)
        or set(fingerprints) != FINGERPRINT_KEYS
        or executable_uuids is None
        or not isinstance(session, dict)
    ):
        return None, (None, "invalid-receipt-contract")
    surface = build_identity.get("surface")
    if not isinstance(surface, str) or surface not in RUNTIME_SURFACES:
        return None, (None, "invalid-receipt-surface")
    if surface not in requested_surfaces:
        return None, None
    server_received_at = entry.get("serverReceivedAt")
    observed_at = receipt.get("observedAt")
    retention_expires_at = receipt.get("retentionExpiresAt")
    if (
        receipt.get("schemaVersion") != 1
        or receipt.get("evidenceClass") != "actual-runtime"
        or not is_sha256(receipt.get("id"))
        or normalized_uuid(receipt.get("sessionID")) != session.get("id")
        or receipt.get("sessionCreatedAt") != session.get("createdAt")
        or receipt.get("sessionExpiresAt") != session.get("expiresAt")
        or parse_iso8601(observed_at) is None
        or parse_iso8601(retention_expires_at) is None
        or parse_iso8601(retention_expires_at) <= parse_iso8601(observed_at)
        or normalized_uuid(receipt.get("processInstanceID")) is None
        or not isinstance(receipt.get("processSequence"), int)
        or isinstance(receipt.get("processSequence"), bool)
        or int(receipt["processSequence"]) <= 0
        or entry.get("source") not in {"local", "cloudkit"}
        or (
            server_received_at is not None
            and parse_iso8601(server_received_at) is None
        )
        or (entry.get("source") == "local" and server_received_at is not None)
        or (entry.get("source") == "cloudkit" and server_received_at is None)
        or receipt.get("trigger") not in RECEIPT_TRIGGERS
        or receipt.get("presentationMode") not in PRESENTATION_MODES
        or receipt.get("selectedSource") not in SELECTED_SOURCES
        or not is_sha256(receipt.get("presentationDigest"))
        or receipt.get("stateBranch") not in STATE_BRANCHES
        or receipt.get("outcome") not in OUTCOMES
        or not isinstance(build.get("marketingVersion"), str)
        or not build.get("marketingVersion")
        or not isinstance(build.get("buildNumber"), str)
        or not build.get("buildNumber")
        or not is_sha256(build.get("manifestID"))
        or not is_sha256(build.get("contractFingerprint"))
        or not isinstance(build_identity.get("platform"), str)
        or not isinstance(build_identity.get("artifactID"), str)
        or not build_identity.get("artifactID")
        or not isinstance(build_identity.get("bundleIdentifier"), str)
        or not build_identity.get("bundleIdentifier")
        or any(not is_sha256(fingerprints.get(key)) for key in FINGERPRINT_KEYS)
    ):
        return None, (surface, "invalid-receipt-contract")

    install_state = classify_install(
        build.get("marketingVersion"),
        build.get("buildNumber"),
        target,
    )
    if install_state == "superseded":
        return None, (surface, "newer-build-observed")
    if install_state != "current":
        return None, (surface, "mixed-build-evidence")
    expected = expected_by_surface.get(surface)
    if expected is None:
        return None, (surface, "expected-identity-missing")
    if session.get("expectedManifestID") != expected.manifest_id:
        return None, (surface, "identity-mismatch:runtime-session-manifest")
    actual_values = {
        "platform": build_identity.get("platform"),
        "artifact": build_identity.get("artifactID"),
        "bundle": build_identity.get("bundleIdentifier"),
        "manifest": build.get("manifestID"),
        "contract": build.get("contractFingerprint"),
        "render-fingerprint": fingerprints.get("render"),
        "runtime-fingerprint": fingerprints.get("runtime"),
        "placement-fingerprint": fingerprints.get("placement"),
        "combined-fingerprint": fingerprints.get("combined"),
    }
    expected_values = {
        "platform": expected.platform,
        "artifact": expected.artifact_id,
        "bundle": expected.bundle_identifier,
        "manifest": expected.manifest_id,
        "contract": expected.contract_fingerprint,
        "render-fingerprint": expected.render_fingerprint,
        "runtime-fingerprint": expected.runtime_fingerprint,
        "placement-fingerprint": expected.placement_fingerprint,
        "combined-fingerprint": expected.combined_fingerprint,
    }
    mismatches = [
        key for key, expected_value in expected_values.items() if actual_values[key] != expected_value
    ]
    if not set(executable_uuids).issubset(expected.executable_uuids):
        mismatches.append("executable-uuids")
    if mismatches:
        return None, (surface, f"identity-mismatch:{mismatches[0]}")
    return (
        RuntimeReceiptEvidence(
            receipt_id=str(receipt["id"]),
            runtime_session_id=str(session["id"]),
            surface=surface,
            source=str(entry["source"]),
            server_received_at=server_received_at,
            observed_at=str(observed_at),
            process_instance_id=str(normalized_uuid(receipt["processInstanceID"])),
            process_sequence=int(receipt["processSequence"]),
            loaded_executable_uuids=executable_uuids,
            identity_digest=expected.identity_digest(),
            state_branch=str(receipt["stateBranch"]),
            outcome=str(receipt["outcome"]),
        ),
        None,
    )


def ordered_receipt_evidence(
    receipts: tuple[RuntimeReceiptEvidence, ...],
) -> list[RuntimeReceiptEvidence]:
    by_process: dict[str, list[RuntimeReceiptEvidence]] = {}
    for receipt in receipts:
        by_process.setdefault(receipt.process_instance_id, []).append(receipt)
    decorated: list[tuple[datetime, str, int, str, RuntimeReceiptEvidence]] = []
    minimum_date = datetime.min.replace(tzinfo=timezone.utc)
    for process_id, process_receipts in by_process.items():
        effective_time = minimum_date
        for receipt in sorted(
            process_receipts,
            key=lambda item: (item.process_sequence, item.observed_at, item.receipt_id),
        ):
            candidate = parse_iso8601(receipt.server_received_at)
            if candidate is None:
                candidate = parse_iso8601(receipt.observed_at) or minimum_date
            effective_time = max(effective_time, candidate)
            decorated.append(
                (
                    effective_time,
                    process_id.lower(),
                    receipt.process_sequence,
                    receipt.receipt_id,
                    receipt,
                )
            )
    return [item[4] for item in sorted(decorated, key=lambda item: item[:4])]


def build_runtime_evidence_report(
    state: RuntimeEvidenceState,
    now: datetime,
) -> dict[str, Any]:
    expected_by_surface = {item.surface: item for item in state.expected_surfaces}
    receipts_by_surface: dict[str, list[RuntimeReceiptEvidence]] = {}
    for receipt in state.receipts:
        receipts_by_surface.setdefault(receipt.surface, []).append(receipt)
    observation = state.last_observation
    surface_diagnostics = dict(observation.surface_diagnostics) if observation else {}
    surfaces: list[dict[str, object]] = []
    for surface in state.requested_surfaces:
        receipts = receipts_by_surface.get(surface, [])
        diagnostic = surface_diagnostics.get(surface)
        if diagnostic == "newer-build-observed":
            state_name, reason = "superseded", diagnostic
        elif diagnostic is not None:
            state_name, reason = "diagnostic", diagnostic
        elif receipts:
            latest = receipts[-1]
            expected = expected_by_surface.get(surface)
            surfaces.append(
                {
                    "surface": surface,
                    "state": "proven",
                    "reason": "exact-build-runtime-receipt",
                    "receiptCount": len(receipts),
                    "lastObservedAt": latest.observed_at,
                    "latestStateBranch": latest.state_branch,
                    "latestOutcome": latest.outcome,
                    "manifestID": expected.manifest_id if expected is not None else None,
                    "expectedBuildID": expected.expected_build_id if expected is not None else None,
                    "identityDigest": expected.identity_digest() if expected is not None else None,
                    "runtimeFingerprint": expected.runtime_fingerprint if expected is not None else None,
                    "receiptIDs": [item.receipt_id for item in receipts],
                }
            )
            continue
        elif surface not in expected_by_surface:
            state_name, reason = "unknown", "expected-build-identity-missing"
        elif observation is None:
            state_name, reason = "unknown", "runtime-reconciliation-pending"
        elif observation.runtime_session_id is None:
            state_name, reason = "unknown", "runtime-session-missing"
        elif observation.expected_manifest_id != expected_by_surface[surface].manifest_id:
            state_name, reason = "diagnostic", "runtime-session-manifest-mismatch"
        elif surface not in observation.enabled_surfaces:
            state_name, reason = "diagnostic", "surface-not-enabled"
        else:
            expires_at = parse_iso8601(observation.runtime_session_expires_at)
            if observation.runtime_session_active is True and expires_at is not None and now < expires_at:
                state_name, reason = "waiting", "receipt-propagation"
            elif (
                surface in EXTENSION_HOST_SURFACES
                and receipts_by_surface.get(EXTENSION_HOST_SURFACES[surface])
            ):
                state_name, reason = "diagnostic", "app-current-extension-stale-or-silent"
            else:
                state_name, reason = "unknown", "receipt-silence"
        surfaces.append(
            {
                "surface": surface,
                "state": state_name,
                "reason": reason,
                "receiptCount": 0,
                "lastObservedAt": None,
                "latestStateBranch": None,
                "latestOutcome": None,
                "manifestID": expected_by_surface[surface].manifest_id if surface in expected_by_surface else None,
                "expectedBuildID": expected_by_surface[surface].expected_build_id if surface in expected_by_surface else None,
                "identityDigest": expected_by_surface[surface].identity_digest() if surface in expected_by_surface else None,
                "runtimeFingerprint": expected_by_surface[surface].runtime_fingerprint if surface in expected_by_surface else None,
                "receiptIDs": [],
            }
        )
    proven_count = sum(item["state"] == "proven" for item in surfaces)
    states = {str(item["state"]) for item in surfaces}
    if "superseded" in states:
        overall_state = "superseded"
    elif proven_count == len(surfaces):
        overall_state = "proven"
    elif "waiting" in states:
        overall_state = "waiting"
    else:
        overall_state = "unknown"
    return {
        "schemaVersion": 1,
        "state": overall_state,
        "provenSurfaceCount": proven_count,
        "requestedSurfaceCount": len(surfaces),
        "lastReconciledAt": state.updated_at,
        "runtimeSession": (
            {
                "id": observation.runtime_session_id,
                "active": observation.runtime_session_active,
                "expiresAt": observation.runtime_session_expires_at,
                "result": observation.result,
            }
            if observation is not None
            else None
        ),
        "diagnostics": list(observation.diagnostics) if observation is not None else [],
        "surfaces": surfaces,
    }


def apply_runtime_evidence_to_report(
    report: ValidationReport,
    runtime_evidence: dict[str, Any] | None,
) -> ValidationReport:
    if runtime_evidence is None:
        return report
    runtime_state = runtime_evidence["state"]
    proven_count = int(runtime_evidence["provenSurfaceCount"])
    requested_count = int(runtime_evidence["requestedSurfaceCount"])
    state = report.state
    stage = report.stage
    exit_code = report.exit_code
    actions = report.actions
    closing = report.headline.rsplit(" · ", 1)[-1]
    if runtime_state == "superseded":
        state, stage, exit_code = "blocked", "superseded", EXIT_BLOCKED
        actions = ()
        closing = "blocked: newer runtime receipt evidence superseded the target"
    elif report.state not in {"blocked", "unknown", "waiting"}:
        if runtime_state == "waiting" and not actions:
            state, stage, exit_code = "waiting", "waiting on runtime receipts", EXIT_OK
            closing = "nothing needs you right now"
        elif runtime_state == "unknown":
            state, stage, exit_code = "unknown", "runtime evidence diagnostic", EXIT_UNKNOWN
            actions = ()
            closing = "not enough evidence: runtime receipt diagnostics required"
        elif runtime_state == "proven" and not actions:
            state, stage, exit_code = (
                "complete_for_slice",
                "exact-build runtime proven",
                EXIT_OK,
            )
            closing = "nothing needs you right now"
    limitations = tuple(
        item
        for item in report.limitations
        if item != "Extension runtime receipts are not proven by this slice."
    )
    if runtime_state == "proven":
        limitations = (
            "Runtime receipts do not prove OS-composited placement.",
            *limitations,
        )
    else:
        limitations = (
            "Unproven runtime surfaces remain waiting or diagnostic, not product failures.",
            *limitations,
        )
    headline = (
        f"{report.target.version} ({report.target.build_number}) — {stage} · "
        f"{proven_count} of {requested_count} surfaces proven · {closing}"
    )
    return replace(
        report,
        state=state,
        stage=stage,
        headline=headline,
        exit_code=exit_code,
        actions=actions,
        limitations=limitations,
        runtime_evidence=runtime_evidence,
    )
