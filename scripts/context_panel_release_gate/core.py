from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
from typing import Any

from context_panel_validation.models import Target
from context_panel_validation.runtime_evidence import ExpectedSurfaceIdentity
from context_panel_validation.session import iso8601, parse_iso8601


RELEASE_EVIDENCE_SCHEMA_VERSION = 1
RELEASE_EVIDENCE_KIND = "context-panel-release-evidence"
HOST_OS_EVIDENCE_KIND = "context-panel-host-os-evidence"
SHADOW_EVIDENCE_KIND = "context-panel-shadow-comparison"
TRAINS = {"beta", "rc", "release"}
MODES = {"shadow", "enforce"}
EVIDENCE_CLASSES = (
    "shared-view",
    "actual-runtime",
    "os-composited-placement",
)
LEDGER_KEYS = {
    "schemaVersion",
    "kind",
    "mode",
    "train",
    "state",
    "target",
    "previousManifestID",
    "currentManifestID",
    "contractFingerprint",
    "validationReportDigest",
    "generatedAt",
    "expiresAt",
    "requiredEvidence",
    "surfaces",
    "shadow",
    "blockers",
    "privacy",
    "ledgerID",
}
EVIDENCE_KEYS = {
    "state",
    "source",
    "fingerprint",
    "observedAt",
    "decisionIDs",
    "hostOS",
    "runtimeReceiptIDs",
}
SHADOW_CLASSIFICATIONS = {"ledger-correct", "runbook-correct", "equivalent"}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
HOST_OS_PATTERN = re.compile(
    r"^(?P<platform>[A-Za-z][A-Za-z0-9 ]*) "
    r"(?P<major>\d+)\.(?P<minor>\d+)(?:\.(?P<patch>\d+))?(?: .*)?$"
)


class ReleaseEvidenceError(ValueError):
    pass


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.expanduser().read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseEvidenceError(f"{label} is unavailable or invalid") from error
    if not isinstance(payload, dict):
        raise ReleaseEvidenceError(f"{label} must be a JSON object")
    return payload


def _is_sha256(value: object) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def _hash_payload(payload: object) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def canonical_payload_digest(payload: object) -> str:
    return _hash_payload(payload)


def _ledger_id(payload: dict[str, Any]) -> str:
    return _hash_payload({key: value for key, value in payload.items() if key != "ledgerID"})


def _target(payload: object, label: str) -> Target:
    if not isinstance(payload, dict):
        raise ReleaseEvidenceError(f"{label} target is invalid")
    version = payload.get("version")
    build_number = payload.get("buildNumber")
    if not isinstance(version, str) or not version or not isinstance(build_number, str) or not build_number:
        raise ReleaseEvidenceError(f"{label} target is invalid")
    return Target(version, build_number)


def _validate_policy(policy: dict[str, Any]) -> dict[str, Any]:
    if set(policy) != {
        "schemaVersion",
        "maximumEvidenceAgeDays",
        "requiredShadowTrainCount",
        "hostOSCompatibility",
    } or policy.get("schemaVersion") != 1:
        raise ReleaseEvidenceError("release evidence policy is invalid")
    maximum_age = policy.get("maximumEvidenceAgeDays")
    shadow_count = policy.get("requiredShadowTrainCount")
    compatibility = policy.get("hostOSCompatibility")
    if (
        not isinstance(maximum_age, int)
        or isinstance(maximum_age, bool)
        or maximum_age < 1
        or maximum_age > 90
        or not isinstance(shadow_count, int)
        or isinstance(shadow_count, bool)
        or shadow_count < 2
        or not isinstance(compatibility, dict)
        or set(compatibility) != {
            "invalidateMajorMinorChanges",
            "patchSensitiveSurfaces",
        }
        or compatibility.get("invalidateMajorMinorChanges") is not True
        or not isinstance(compatibility.get("patchSensitiveSurfaces"), list)
        or any(not isinstance(item, str) for item in compatibility["patchSensitiveSurfaces"])
        or len(set(compatibility["patchSensitiveSurfaces"]))
        != len(compatibility["patchSensitiveSurfaces"])
    ):
        raise ReleaseEvidenceError("release evidence policy is invalid")
    return policy


def _validate_comparison(comparison: dict[str, Any], train: str) -> dict[str, dict[str, Any]]:
    if comparison.get("schemaVersion") != 1 or comparison.get("train") != train:
        raise ReleaseEvidenceError("surface comparison does not match the requested train")
    if not _is_sha256(comparison.get("previousManifestId")) or not _is_sha256(
        comparison.get("currentManifestId")
    ):
        raise ReleaseEvidenceError("surface comparison manifest identity is invalid")
    release_requires_rc = comparison.get("releaseRequiresApprovedRCTarget")
    if not isinstance(release_requires_rc, bool) or (train == "release" and not release_requires_rc):
        raise ReleaseEvidenceError("surface comparison release RC requirement is invalid")
    surfaces = comparison.get("surfaces")
    required = comparison.get("requiredSurfaces")
    if (
        not isinstance(surfaces, list)
        or not isinstance(required, dict)
        or set(required) != set(EVIDENCE_CLASSES)
    ):
        raise ReleaseEvidenceError("surface comparison is invalid")
    surface_map: dict[str, dict[str, Any]] = {}
    for item in surfaces:
        if not isinstance(item, dict) or not isinstance(item.get("surfaceId"), str):
            raise ReleaseEvidenceError("surface comparison contains an invalid surface")
        surface = item["surfaceId"]
        if surface in surface_map:
            raise ReleaseEvidenceError("surface comparison duplicates a surface")
        carry_forward = item.get("carryForward")
        required_evidence = item.get("requiredEvidence")
        if (
            not isinstance(carry_forward, dict)
            or set(carry_forward) != set(EVIDENCE_CLASSES)
            or not isinstance(required_evidence, list)
            or any(value not in EVIDENCE_CLASSES for value in required_evidence)
            or len(required_evidence) != len(set(required_evidence))
        ):
            raise ReleaseEvidenceError("surface comparison evidence is invalid")
        for evidence_class, carry_rule in carry_forward.items():
            if (
                not isinstance(carry_rule, dict)
                or not isinstance(carry_rule.get("eligible"), bool)
                or not isinstance(carry_rule.get("conditions"), list)
                or any(not isinstance(value, str) for value in carry_rule["conditions"])
                or len(carry_rule["conditions"]) != len(set(carry_rule["conditions"]))
            ):
                raise ReleaseEvidenceError(
                    f"surface comparison carry-forward rule is invalid for {surface}:{evidence_class}"
                )
        surface_map[surface] = item
    for evidence_class in EVIDENCE_CLASSES:
        values = required[evidence_class]
        if (
            not isinstance(values, list)
            or any(not isinstance(value, str) or value not in surface_map for value in values)
            or len(values) != len(set(values))
        ):
            raise ReleaseEvidenceError("surface comparison requirements are invalid")
        expected = {
            surface
            for surface, item in surface_map.items()
            if evidence_class in item["requiredEvidence"]
        }
        if set(values) != expected:
            raise ReleaseEvidenceError("surface comparison requirements do not match its surfaces")
    return surface_map


def _validate_report(report: dict[str, Any], current_manifest_id: str) -> Target:
    if report.get("schemaVersion") != 1:
        raise ReleaseEvidenceError("validation report schema is invalid")
    target = _target(report.get("target"), "validation report")
    summary = report.get("summary")
    session = report.get("session")
    if not isinstance(summary, dict) or not isinstance(session, dict):
        raise ReleaseEvidenceError("validation report is invalid")
    if summary.get("exitCode") != 0:
        raise ReleaseEvidenceError("validation report is blocked")
    blockers = report.get("blockers")
    if not isinstance(blockers, list) or blockers:
        raise ReleaseEvidenceError("validation report contains blockers")
    visual = report.get("visualApprovals")
    runtime = report.get("runtimeSurfaces")
    if not isinstance(visual, dict) or not isinstance(runtime, list):
        raise ReleaseEvidenceError("validation report evidence is invalid")
    requirements = visual.get("requirements")
    if not isinstance(requirements, list):
        raise ReleaseEvidenceError("validation report visual approvals are invalid")
    for item in requirements:
        if not isinstance(item, dict) or item.get("evidenceClass") not in {
            "shared-view",
            "os-composited-placement",
        }:
            raise ReleaseEvidenceError("validation report visual approval is invalid")
        fingerprint_key = (
            "renderFingerprint"
            if item["evidenceClass"] == "shared-view"
            else "placementFingerprint"
        )
        if not _is_sha256(item.get(fingerprint_key)):
            raise ReleaseEvidenceError("validation report visual fingerprint is invalid")
    if not _is_sha256(current_manifest_id):
        raise ReleaseEvidenceError("current manifest identity is invalid")
    return target


def _identity_fingerprint(identity: ExpectedSurfaceIdentity, evidence_class: str) -> str:
    if evidence_class == "shared-view":
        return identity.render_fingerprint
    if evidence_class == "actual-runtime":
        return identity.runtime_fingerprint
    return identity.placement_fingerprint


def _validate_evidence_record(
    evidence: object,
    *,
    evidence_class: str,
    label: str,
) -> dict[str, Any]:
    expected_state = "proven" if evidence_class == "actual-runtime" else "approved"
    if (
        not isinstance(evidence, dict)
        or set(evidence) != EVIDENCE_KEYS
        or evidence.get("state") != expected_state
        or evidence.get("source") not in {"fresh", "carry-forward", "selected-rc"}
        or not _is_sha256(evidence.get("fingerprint"))
        or not isinstance(evidence.get("decisionIDs"), list)
        or any(not _is_sha256(value) for value in evidence["decisionIDs"])
        or len(evidence["decisionIDs"]) != len(set(evidence["decisionIDs"]))
        or not isinstance(evidence.get("runtimeReceiptIDs"), list)
        or any(not _is_sha256(value) for value in evidence["runtimeReceiptIDs"])
        or len(evidence["runtimeReceiptIDs"]) != len(set(evidence["runtimeReceiptIDs"]))
    ):
        raise ReleaseEvidenceError(f"{label} contains invalid evidence")
    observed_at = evidence.get("observedAt")
    if observed_at is not None and parse_iso8601(observed_at) is None:
        raise ReleaseEvidenceError(f"{label} contains invalid evidence")
    host_os = evidence.get("hostOS")
    if evidence_class == "os-composited-placement":
        if not isinstance(host_os, str) or HOST_OS_PATTERN.fullmatch(host_os) is None:
            raise ReleaseEvidenceError(f"{label} contains invalid evidence")
    elif host_os is not None:
        raise ReleaseEvidenceError(f"{label} contains invalid evidence")
    return {
        "state": evidence["state"],
        "source": evidence["source"],
        "fingerprint": evidence["fingerprint"],
        "observedAt": observed_at,
        "decisionIDs": sorted(evidence["decisionIDs"]),
        "hostOS": host_os,
        "runtimeReceiptIDs": sorted(evidence["runtimeReceiptIDs"]),
    }


def _current_runtime(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    surfaces: dict[str, dict[str, Any]] = {}
    for item in report.get("runtimeSurfaces") or []:
        if isinstance(item, dict) and item.get("state") == "proven" and isinstance(item.get("surface"), str):
            surfaces[item["surface"]] = item
    return surfaces


def _current_visual(report: dict[str, Any]) -> dict[tuple[str, str], list[dict[str, Any]]]:
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    requirements = report.get("visualApprovals", {}).get("requirements") or []
    for item in requirements:
        if isinstance(item, dict) and isinstance(item.get("surface"), str):
            grouped.setdefault((item["surface"], item["evidenceClass"]), []).append(item)
    return grouped


def _fresh_evidence(
    surface: str,
    evidence_class: str,
    identity: ExpectedSurfaceIdentity,
    runtime_surfaces: dict[str, dict[str, Any]],
    visual: dict[tuple[str, str], list[dict[str, Any]]],
    now: datetime,
    maximum_age_days: int,
) -> dict[str, Any] | None:
    fingerprint = _identity_fingerprint(identity, evidence_class)
    if evidence_class == "actual-runtime":
        runtime = runtime_surfaces.get(surface)
        if (
            runtime is None
            or runtime.get("manifestID") != identity.manifest_id
            or runtime.get("expectedBuildID") != identity.expected_build_id
            or runtime.get("identityDigest") != identity.identity_digest()
            or runtime.get("runtimeFingerprint") != identity.runtime_fingerprint
            or not isinstance(runtime.get("receiptIDs"), list)
            or not runtime["receiptIDs"]
            or any(not _is_sha256(item) for item in runtime["receiptIDs"])
        ):
            return None
        return {
            "state": "proven",
            "source": "fresh",
            "fingerprint": fingerprint,
            "observedAt": None,
            "decisionIDs": [],
            "hostOS": None,
            "runtimeReceiptIDs": sorted(runtime["receiptIDs"]),
        }
    requirements = visual.get((surface, evidence_class)) or []
    if (
        not requirements
        or any(item.get("state") != "approved" for item in requirements)
        or any(item.get("manifestID") != identity.manifest_id for item in requirements)
        or any(item.get("expectedBuildID") != identity.expected_build_id for item in requirements)
        or any(item.get("contractFingerprint") != identity.contract_fingerprint for item in requirements)
        or any(item.get("identityDigest") != identity.identity_digest() for item in requirements)
    ):
        return None
    fingerprint_key = (
        "renderFingerprint" if evidence_class == "shared-view" else "placementFingerprint"
    )
    if any(item.get(fingerprint_key) != fingerprint for item in requirements):
        return None
    decisions = [item.get("decision") for item in requirements]
    decision_times = [
        parse_iso8601(item.get("observedAt")) if isinstance(item, dict) else None
        for item in decisions
    ]
    if any(
        not isinstance(item, dict)
        or not _is_sha256(item.get("id"))
        or item.get("value") != "approved"
        for item in decisions
    ) or any(
        observed_at is None
        or observed_at > now
        or observed_at < now - timedelta(days=maximum_age_days)
        for observed_at in decision_times
    ):
        return None
    observed = max(str(item["observedAt"]) for item in decisions if item.get("observedAt"))
    receipt_ids = sorted(
        {
            str(item["runtimeReceiptID"])
            for item in decisions
            if item.get("runtimeReceiptID") is not None
        }
    )
    if any(not _is_sha256(item) for item in receipt_ids):
        return None
    host_os_values = {item.get("hostOS") for item in requirements}
    if evidence_class == "os-composited-placement":
        runtime = runtime_surfaces.get(surface)
        current_receipts = set(runtime.get("receiptIDs") or []) if runtime is not None else set()
        if (
            len(host_os_values) != 1
            or None in host_os_values
            or not receipt_ids
            or runtime is None
            or not set(receipt_ids).issubset(current_receipts)
        ):
            return None
        host_os = str(next(iter(host_os_values)))
    else:
        host_os = None
    return {
        "state": "approved",
        "source": "fresh",
        "fingerprint": fingerprint,
        "observedAt": observed,
        "decisionIDs": sorted(str(item["id"]) for item in decisions),
        "hostOS": host_os,
        "runtimeReceiptIDs": receipt_ids,
    }


def _validate_ledger(
    ledger: dict[str, Any],
    *,
    expected_manifest_id: str | None,
    now: datetime,
    label: str,
    maximum_age_days: int,
    allowed_states: frozenset[str] = frozenset({"approved"}),
) -> dict[str, dict[str, Any]]:
    if (
        set(ledger) != LEDGER_KEYS
        or ledger.get("schemaVersion") != RELEASE_EVIDENCE_SCHEMA_VERSION
        or ledger.get("kind") != RELEASE_EVIDENCE_KIND
        or ledger.get("mode") not in MODES
        or ledger.get("train") not in TRAINS
        or ledger.get("state") not in allowed_states
        or not _is_sha256(ledger.get("previousManifestID"))
        or not _is_sha256(ledger.get("currentManifestID"))
        or not _is_sha256(ledger.get("contractFingerprint"))
        or not _is_sha256(ledger.get("validationReportDigest"))
        or not _is_sha256(ledger.get("ledgerID"))
        or ledger.get("ledgerID") != _ledger_id(ledger)
    ):
        raise ReleaseEvidenceError(f"{label} is not an approved release evidence ledger")
    if expected_manifest_id is not None and ledger.get("currentManifestID") != expected_manifest_id:
        raise ReleaseEvidenceError(f"{label} manifest identity does not match")
    _target(ledger.get("target"), label)
    generated_at = parse_iso8601(ledger.get("generatedAt"))
    expires_at = parse_iso8601(ledger.get("expiresAt"))
    if (
        generated_at is None
        or expires_at is None
        or generated_at > now
        or expires_at <= now
        or expires_at > generated_at + timedelta(days=maximum_age_days)
    ):
        raise ReleaseEvidenceError(f"{label} is expired")
    required = ledger.get("requiredEvidence")
    surfaces = ledger.get("surfaces")
    if (
        not isinstance(required, dict)
        or set(required) != set(EVIDENCE_CLASSES)
        or not isinstance(surfaces, list)
        or not isinstance(ledger.get("blockers"), list)
        or ledger["blockers"]
        or not isinstance(ledger.get("shadow"), dict)
        or not isinstance(ledger.get("privacy"), str)
    ):
        raise ReleaseEvidenceError(f"{label} surfaces are invalid")
    if any(not isinstance(value, str) for value in ledger["blockers"]):
        raise ReleaseEvidenceError(f"{label} blockers are invalid")
    shadow = ledger["shadow"]
    if (
        set(shadow)
        != {"state", "requiredTrainCount", "observedTrainCount", "disagreements"}
        or shadow.get("state") not in {"pending", "passed"}
        or not isinstance(shadow.get("requiredTrainCount"), int)
        or isinstance(shadow.get("requiredTrainCount"), bool)
        or shadow["requiredTrainCount"] < 2
        or not isinstance(shadow.get("observedTrainCount"), int)
        or isinstance(shadow.get("observedTrainCount"), bool)
        or shadow["observedTrainCount"] < 0
        or not isinstance(shadow.get("disagreements"), list)
    ):
        raise ReleaseEvidenceError(f"{label} shadow evidence is invalid")
    for disagreement in shadow["disagreements"]:
        if (
            not isinstance(disagreement, dict)
            or set(disagreement)
            != {"surface", "evidenceClass", "classification", "resolution"}
            or not isinstance(disagreement.get("surface"), str)
            or disagreement.get("evidenceClass") not in EVIDENCE_CLASSES
            or disagreement.get("classification") not in SHADOW_CLASSIFICATIONS
            or not isinstance(disagreement.get("resolution"), str)
            or not disagreement["resolution"].strip()
            or len(disagreement["resolution"]) > 500
        ):
            raise ReleaseEvidenceError(f"{label} shadow evidence is invalid")
    for evidence_class, values in required.items():
        if (
            not isinstance(values, list)
            or any(not isinstance(value, str) for value in values)
            or len(values) != len(set(values))
        ):
            raise ReleaseEvidenceError(f"{label} surfaces are invalid")
    surface_map: dict[str, dict[str, Any]] = {}
    for item in surfaces:
        if (
            not isinstance(item, dict)
            or set(item) != {"surface", "identityDigest", "evidence"}
            or not isinstance(item.get("surface"), str)
            or not _is_sha256(item.get("identityDigest"))
        ):
            raise ReleaseEvidenceError(f"{label} contains an invalid surface")
        if item["surface"] in surface_map or not isinstance(item.get("evidence"), dict):
            raise ReleaseEvidenceError(f"{label} contains invalid evidence")
        for evidence_class, evidence in item["evidence"].items():
            if evidence_class not in EVIDENCE_CLASSES:
                raise ReleaseEvidenceError(f"{label} contains invalid evidence")
            _validate_evidence_record(
                evidence,
                evidence_class=evidence_class,
                label=label,
            )
        surface_map[item["surface"]] = item
    required_scope = {
        surface
        for evidence_class in EVIDENCE_CLASSES
        for surface in required[evidence_class]
    }
    if set(surface_map) != required_scope:
        raise ReleaseEvidenceError(f"{label} surfaces do not match required evidence")
    for surface, item in surface_map.items():
        expected_classes = {
            evidence_class
            for evidence_class in EVIDENCE_CLASSES
            if surface in required[evidence_class]
        }
        if set(item["evidence"]) != expected_classes:
            raise ReleaseEvidenceError(f"{label} surfaces do not match required evidence")
    return surface_map


def _host_os_evidence(
    payload: dict[str, Any] | None,
    *,
    target: Target,
    current_manifest_id: str,
    current_runtime: dict[str, dict[str, Any]],
    now: datetime,
    maximum_age_days: int,
) -> dict[str, str]:
    if payload is None:
        return {}
    observed_at = parse_iso8601(payload.get("observedAt"))
    if (
        set(payload)
        != {"schemaVersion", "kind", "target", "currentManifestID", "observedAt", "surfaces"}
        or payload.get("schemaVersion") != 1
        or payload.get("kind") != HOST_OS_EVIDENCE_KIND
        or _target(payload.get("target"), "host OS evidence") != target
        or payload.get("currentManifestID") != current_manifest_id
        or observed_at is None
        or observed_at > now
        or observed_at < now - timedelta(days=maximum_age_days)
        or not isinstance(payload.get("surfaces"), dict)
    ):
        raise ReleaseEvidenceError("host OS evidence is invalid")
    surfaces = payload["surfaces"]
    result: dict[str, str] = {}
    for surface, item in surfaces.items():
        runtime = current_runtime.get(surface)
        if (
            not isinstance(surface, str)
            or not isinstance(item, dict)
            or set(item) != {"hostOS", "runtimeReceiptID"}
            or not isinstance(item.get("hostOS"), str)
            or HOST_OS_PATTERN.fullmatch(item["hostOS"]) is None
            or not _is_sha256(item.get("runtimeReceiptID"))
            or runtime is None
            or item["runtimeReceiptID"] not in set(runtime.get("receiptIDs") or [])
        ):
            raise ReleaseEvidenceError("host OS evidence is invalid")
        result[surface] = item["hostOS"]
    return result


def _host_os_compatible(
    previous: str,
    current: str,
    surface: str,
    patch_sensitive: set[str],
) -> bool:
    previous_match = HOST_OS_PATTERN.fullmatch(previous)
    current_match = HOST_OS_PATTERN.fullmatch(current)
    if previous_match is None or current_match is None:
        return False
    if previous_match["platform"] != current_match["platform"]:
        return False
    if (
        previous_match["major"],
        previous_match["minor"],
    ) != (
        current_match["major"],
        current_match["minor"],
    ):
        return False
    return surface not in patch_sensitive or previous_match["patch"] == current_match["patch"]


def _carried_evidence(
    *,
    prior_surface: dict[str, Any] | None,
    surface: str,
    evidence_class: str,
    fingerprint: str,
    current_runtime: dict[str, dict[str, Any]],
    current_host_os: dict[str, str],
    patch_sensitive: set[str],
    source: str,
    require_current_runtime: bool,
    expected_identity_digest: str | None = None,
) -> dict[str, Any] | None:
    if prior_surface is None:
        return None
    if (
        expected_identity_digest is not None
        and prior_surface.get("identityDigest") != expected_identity_digest
    ):
        return None
    evidence = prior_surface.get("evidence", {}).get(evidence_class)
    if not isinstance(evidence, dict) or evidence.get("fingerprint") != fingerprint:
        return None
    expected_state = "proven" if evidence_class == "actual-runtime" else "approved"
    if evidence.get("state") != expected_state:
        return None
    if evidence_class == "os-composited-placement":
        previous_host_os = evidence.get("hostOS")
        observed_host_os = current_host_os.get(surface)
        if (
            (require_current_runtime and surface not in current_runtime)
            or not isinstance(previous_host_os, str)
            or not isinstance(observed_host_os, str)
            or not _host_os_compatible(
                previous_host_os,
                observed_host_os,
                surface,
                patch_sensitive,
            )
        ):
            return None
    carried = _validate_evidence_record(
        evidence,
        evidence_class=evidence_class,
        label="carried release evidence",
    )
    carried["source"] = source
    if evidence_class == "os-composited-placement":
        carried["hostOS"] = current_host_os[surface]
    return carried


def _shadow_state(
    payload: dict[str, Any] | None,
    required_count: int,
    *,
    now: datetime,
    maximum_age_days: int,
) -> dict[str, Any]:
    if payload is None:
        return {
            "state": "pending",
            "requiredTrainCount": required_count,
            "observedTrainCount": 0,
            "disagreements": [],
        }
    if (
        set(payload) != {"schemaVersion", "kind", "runs"}
        or payload.get("schemaVersion") != 1
        or payload.get("kind") != SHADOW_EVIDENCE_KIND
        or not isinstance(payload.get("runs"), list)
    ):
        raise ReleaseEvidenceError("shadow comparison evidence is invalid")
    disagreements: list[dict[str, Any]] = []
    run_identities: set[tuple[str, str, str, str]] = set()
    for run in payload["runs"]:
        if (
            not isinstance(run, dict)
            or set(run)
            != {
                "train",
                "target",
                "manifestID",
                "ledgerID",
                "observedAt",
                "runbookState",
                "ledgerState",
                "disagreements",
            }
            or run.get("train") not in TRAINS
            or not _is_sha256(run.get("manifestID"))
            or not _is_sha256(run.get("ledgerID"))
            or run.get("runbookState") not in {"approved", "blocked"}
            or run.get("ledgerState") not in {"approved", "blocked"}
            or not isinstance(run.get("disagreements"), list)
        ):
            raise ReleaseEvidenceError("shadow comparison evidence is invalid")
        run_target = _target(run.get("target"), "shadow comparison")
        observed_at = parse_iso8601(run.get("observedAt"))
        if (
            observed_at is None
            or observed_at > now
            or observed_at < now - timedelta(days=maximum_age_days)
        ):
            raise ReleaseEvidenceError("shadow comparison evidence is invalid")
        run_identity = (
            run_target.version,
            run_target.build_number,
            run["manifestID"],
            run["ledgerID"],
        )
        if run_identity in run_identities:
            raise ReleaseEvidenceError("shadow comparison duplicates a signed train")
        run_identities.add(run_identity)
        for disagreement in run["disagreements"]:
            if (
                not isinstance(disagreement, dict)
                or set(disagreement)
                != {"surface", "evidenceClass", "classification", "resolution"}
                or not isinstance(disagreement.get("surface"), str)
                or disagreement.get("evidenceClass") not in EVIDENCE_CLASSES
                or disagreement.get("classification") not in SHADOW_CLASSIFICATIONS
                or not isinstance(disagreement.get("resolution"), str)
                or not disagreement["resolution"].strip()
                or len(disagreement["resolution"]) > 500
            ):
                raise ReleaseEvidenceError("shadow disagreement is invalid")
            disagreements.append(
                {
                    "surface": disagreement["surface"],
                    "evidenceClass": disagreement["evidenceClass"],
                    "classification": disagreement["classification"],
                    "resolution": disagreement["resolution"].strip(),
                }
            )
    run_count = len(run_identities)
    return {
        "state": "passed" if run_count >= required_count else "pending",
        "requiredTrainCount": required_count,
        "observedTrainCount": run_count,
        "disagreements": disagreements,
    }


def evaluate_release_evidence(
    *,
    train: str,
    mode: str,
    comparison: dict[str, Any],
    validation_report: dict[str, Any],
    identities: tuple[ExpectedSurfaceIdentity, ...],
    policy: dict[str, Any],
    previous_ledger: dict[str, Any] | None = None,
    selected_rc_ledger: dict[str, Any] | None = None,
    host_os_evidence: dict[str, Any] | None = None,
    shadow_evidence: dict[str, Any] | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    if train not in TRAINS or mode not in MODES:
        raise ReleaseEvidenceError("release evidence train or mode is invalid")
    policy = _validate_policy(policy)
    surface_comparison = _validate_comparison(comparison, train)
    current_manifest_id = str(comparison["currentManifestId"])
    target = _validate_report(validation_report, current_manifest_id)
    validation_report_digest = _hash_payload(validation_report)
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    identity_by_surface = {item.surface: item for item in identities}
    if not identity_by_surface or any(item.manifest_id != current_manifest_id for item in identities):
        raise ReleaseEvidenceError("expected signed-build identity does not match the comparison")
    required_surfaces = comparison["requiredSurfaces"]
    required_scope = {
        surface
        for evidence_class in EVIDENCE_CLASSES
        for surface in required_surfaces[evidence_class]
    }
    if any(surface not in identity_by_surface for surface in required_scope):
        raise ReleaseEvidenceError("expected signed-build manifests do not cover the comparison")

    previous_surfaces: dict[str, dict[str, Any]] = {}
    previous_expires_at: datetime | None = None
    if previous_ledger is not None:
        previous_surfaces = _validate_ledger(
            previous_ledger,
            expected_manifest_id=str(comparison["previousManifestId"]),
            now=now,
            label="previous release evidence",
            maximum_age_days=policy["maximumEvidenceAgeDays"],
        )
        previous_expires_at = parse_iso8601(previous_ledger.get("expiresAt"))
    selected_rc_surfaces: dict[str, dict[str, Any]] = {}
    selected_rc_expires_at: datetime | None = None
    if selected_rc_ledger is not None:
        selected_rc_target = _target(selected_rc_ledger.get("target"), "selected RC evidence")
        if selected_rc_target != target:
            raise ReleaseEvidenceError("selected RC target does not match the release target")
        selected_rc_surfaces = _validate_ledger(
            selected_rc_ledger,
            expected_manifest_id=current_manifest_id,
            now=now,
            label="selected RC evidence",
            maximum_age_days=policy["maximumEvidenceAgeDays"],
        )
        selected_rc_expires_at = parse_iso8601(selected_rc_ledger.get("expiresAt"))
        if (
            selected_rc_ledger.get("train") != "rc"
            or selected_rc_ledger.get("mode") != "enforce"
            or not isinstance(selected_rc_ledger.get("shadow"), dict)
            or selected_rc_ledger["shadow"].get("state") != "passed"
        ):
            raise ReleaseEvidenceError("selected RC evidence is not an enforced approved RC")
    if train == "release" and not selected_rc_surfaces:
        raise ReleaseEvidenceError("release evidence requires the selected exact approved RC")

    runtime_surfaces = _current_runtime(validation_report)
    visual = _current_visual(validation_report)
    current_host_os = _host_os_evidence(
        host_os_evidence,
        target=target,
        current_manifest_id=current_manifest_id,
        current_runtime=runtime_surfaces,
        now=now,
        maximum_age_days=policy["maximumEvidenceAgeDays"],
    )
    patch_sensitive = set(policy["hostOSCompatibility"]["patchSensitiveSurfaces"])
    blockers: list[str] = []
    output_surfaces: list[dict[str, Any]] = []
    for surface in sorted(required_scope):
        identity = identity_by_surface[surface]
        comparison_surface = surface_comparison[surface]
        evidence_output: dict[str, Any] = {}
        for evidence_class in EVIDENCE_CLASSES:
            if surface not in required_surfaces[evidence_class]:
                continue
            fingerprint = _identity_fingerprint(identity, evidence_class)
            evidence = _fresh_evidence(
                surface,
                evidence_class,
                identity,
                runtime_surfaces,
                visual,
                now,
                policy["maximumEvidenceAgeDays"],
            )
            if evidence is None and selected_rc_surfaces:
                evidence = _carried_evidence(
                    prior_surface=selected_rc_surfaces.get(surface),
                    surface=surface,
                    evidence_class=evidence_class,
                    fingerprint=fingerprint,
                    current_runtime=runtime_surfaces,
                    current_host_os=current_host_os,
                    patch_sensitive=patch_sensitive,
                    source="selected-rc",
                    require_current_runtime=False,
                    expected_identity_digest=identity.identity_digest(),
                )
            carry_rule = comparison_surface.get("carryForward", {}).get(evidence_class)
            if (
                evidence is None
                and isinstance(carry_rule, dict)
                and carry_rule.get("eligible") is True
            ):
                evidence = _carried_evidence(
                    prior_surface=previous_surfaces.get(surface),
                    surface=surface,
                    evidence_class=evidence_class,
                    fingerprint=fingerprint,
                    current_runtime=runtime_surfaces,
                    current_host_os=current_host_os,
                    patch_sensitive=patch_sensitive,
                    source="carry-forward",
                    require_current_runtime=True,
                )
            if evidence is None:
                blockers.append(f"{surface}:{evidence_class}:missing")
                evidence = {
                    "state": "missing",
                    "source": "none",
                    "fingerprint": fingerprint,
                    "observedAt": None,
                    "decisionIDs": [],
                    "hostOS": current_host_os.get(surface),
                    "runtimeReceiptIDs": [],
                }
            evidence_output[evidence_class] = evidence
        output_surfaces.append(
            {
                "surface": surface,
                "identityDigest": identity.identity_digest(),
                "evidence": evidence_output,
            }
        )

    shadow = _shadow_state(
        shadow_evidence,
        policy["requiredShadowTrainCount"],
        now=now,
        maximum_age_days=policy["maximumEvidenceAgeDays"],
    )
    if mode == "enforce" and shadow["state"] != "passed":
        blockers.append("shadow-comparison:pending")
    state = "approved" if not blockers else "blocked"
    if mode == "shadow" and state == "approved" and shadow["state"] != "passed":
        state = "shadow-approved"
    expires_at = now + timedelta(days=policy["maximumEvidenceAgeDays"])
    evidence_sources = {
        evidence.get("source")
        for surface in output_surfaces
        for evidence in surface["evidence"].values()
    }
    if "carry-forward" in evidence_sources and previous_expires_at is not None:
        expires_at = min(expires_at, previous_expires_at)
    if "selected-rc" in evidence_sources and selected_rc_expires_at is not None:
        expires_at = min(expires_at, selected_rc_expires_at)
    payload = {
        "schemaVersion": RELEASE_EVIDENCE_SCHEMA_VERSION,
        "kind": RELEASE_EVIDENCE_KIND,
        "mode": mode,
        "train": train,
        "state": state,
        "target": {
            "version": target.version,
            "buildNumber": target.build_number,
        },
        "previousManifestID": comparison["previousManifestId"],
        "currentManifestID": current_manifest_id,
        "contractFingerprint": identities[0].contract_fingerprint,
        "validationReportDigest": validation_report_digest,
        "generatedAt": iso8601(now),
        "expiresAt": iso8601(expires_at),
        "requiredEvidence": required_surfaces,
        "surfaces": output_surfaces,
        "shadow": shadow,
        "blockers": sorted(blockers),
        "privacy": (
            "Contains public surface/build fingerprints, bounded host OS versions, "
            "decision and receipt digests, and no device identifiers, account data, "
            "credentials, private paths, raw artifacts, or App Store Connect object IDs."
        ),
    }
    payload["ledgerID"] = _ledger_id(payload)
    return payload


def release_evidence_report_blockers(
    payload: object,
    *,
    version: str,
    build_number: str,
    train: str,
    enforce: bool,
    validation_report_digest: str | None = None,
    now: datetime | None = None,
) -> list[str]:
    if not isinstance(payload, dict):
        return ["the release evidence report root must be a JSON object"]
    blockers: list[str] = []
    observed_now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    allowed_states = (
        frozenset({"approved"})
        if enforce
        else frozenset({"approved", "shadow-approved"})
    )
    try:
        _validate_ledger(
            payload,
            expected_manifest_id=None,
            now=observed_now,
            label="release evidence report",
            maximum_age_days=90,
            allowed_states=allowed_states,
        )
    except ReleaseEvidenceError as error:
        blockers.append(str(error))
    if payload.get("train") != train:
        blockers.append(f"train must be {train}")
    target = payload.get("target")
    if not isinstance(target, dict):
        blockers.append("target is missing or malformed")
    else:
        if target.get("version") != version:
            blockers.append(f"target version must be {version}")
        if target.get("buildNumber") != build_number:
            blockers.append(f"target build number must be {build_number}")
    report_blockers = payload.get("blockers")
    if (
        not _is_sha256(payload.get("ledgerID"))
        or payload.get("ledgerID") != _ledger_id(payload)
    ):
        blockers.append("release evidence ledger identity is invalid")
    if validation_report_digest is not None:
        if not _is_sha256(validation_report_digest):
            blockers.append("validation report digest is invalid")
        elif payload.get("validationReportDigest") != validation_report_digest:
            blockers.append("release evidence does not match the exact validation report")
    if enforce:
        if payload.get("mode") != "enforce":
            blockers.append("release evidence mode must be enforce")
        if payload.get("state") != "approved":
            blockers.append("release evidence state must be approved")
        if isinstance(report_blockers, list) and report_blockers:
            blockers.append("release evidence must have no blockers")
        shadow = payload.get("shadow")
        if not isinstance(shadow, dict) or shadow.get("state") != "passed":
            blockers.append("shadow comparison evidence must be passed")
    elif payload.get("mode") != "shadow":
        blockers.append("shadow validation requires a shadow-mode report")
    return list(dict.fromkeys(blockers))
