from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
from typing import Any

from context_panel_comparison_schema import (
    ComparisonSchemaError,
    EVIDENCE_CLASSES,
    validate_current_comparison,
    validate_legacy_v1_comparison_for_reconstruction,
    validate_legacy_v2_comparison_for_reconstruction,
    validate_legacy_v3_comparison_for_reconstruction,
)
from context_panel_validation.models import Target
from context_panel_validation.runtime_evidence import (
    ExpectedSurfaceIdentity,
    RuntimeEvidenceError,
    expected_surface_identities_from_payloads,
)
from context_panel_validation.session import RUNTIME_SURFACES, iso8601, parse_iso8601


RELEASE_EVIDENCE_SCHEMA_VERSION = 1
RELEASE_EVIDENCE_KIND = "context-panel-release-evidence"
RELEASE_EVIDENCE_LINEAGE_KIND = "context-panel-release-evidence-lineage"
HOST_OS_EVIDENCE_KIND = "context-panel-host-os-evidence"
SHADOW_EVIDENCE_KIND = "context-panel-shadow-comparison"
MAX_LINEAGE_DEPTH = 8
TRAINS = {"beta", "rc", "release"}
MODES = {"shadow", "enforce"}
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
    "comparisonDigest",
    "surfacePolicyDigest",
    "policyDigest",
    "expectedBuildIdentityDigest",
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
SHADOW_CLASSIFICATIONS = {
    "ledger-correct",
    "runbook-correct",
    "equivalent",
    "unresolved",
}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
HOST_OS_PATTERN = re.compile(
    r"^(?P<platform>macOS|iOS|iPadOS|tvOS|visionOS|watchOS) "
    r"(?P<major>\d+)\.(?P<minor>\d+)(?:\.(?P<patch>\d+))?$"
)
PUBLIC_TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}$")
BUILD_NUMBER_PATTERN = re.compile(r"^[0-9]+$")
PRIVACY_MARKER = "context-panel-release-evidence-public-v1"
WATCHLIST_REQUIRED_EVIDENCE = (
    ("actual-runtime",),
    ("actual-runtime", "os-composited-placement"),
)
GENERATION_KEYS = {
    "comparison",
    "validationReport",
    "expectedBuildManifests",
    "previousLedger",
    "selectedRCLedger",
    "hostOSEvidence",
    "shadowEvidence",
}


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
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def canonical_payload_digest(payload: object) -> str:
    return _hash_payload(payload)


def build_release_evidence_lineage(
    ledger: dict[str, Any],
    *,
    comparison: dict[str, Any],
    validation_report: dict[str, Any],
    expected_build_manifests: tuple[dict[str, Any], ...],
    previous_ledger: dict[str, Any] | None = None,
    selected_rc_ledger: dict[str, Any] | None = None,
    host_os_evidence: dict[str, Any] | None = None,
    shadow_evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "kind": RELEASE_EVIDENCE_LINEAGE_KIND,
        "ledger": ledger,
        "generation": {
            "comparison": comparison,
            "validationReport": validation_report,
            "expectedBuildManifests": list(expected_build_manifests),
            "previousLedger": previous_ledger,
            "selectedRCLedger": selected_rc_ledger,
            "hostOSEvidence": host_os_evidence,
            "shadowEvidence": shadow_evidence,
        },
    }


def _expected_identity_digest(identities: tuple[ExpectedSurfaceIdentity, ...]) -> str:
    return _hash_payload(
        [
            {
                "surface": identity.surface,
                "manifestID": identity.manifest_id,
                "contractFingerprint": identity.contract_fingerprint,
                "expectedBuildID": identity.expected_build_id,
                "identityDigest": identity.identity_digest(),
                "renderFingerprint": identity.render_fingerprint,
                "runtimeFingerprint": identity.runtime_fingerprint,
                "placementFingerprint": identity.placement_fingerprint,
            }
            for identity in sorted(identities, key=lambda item: item.surface)
        ]
    )


def _ledger_id(payload: dict[str, Any]) -> str:
    return _hash_payload({key: value for key, value in payload.items() if key != "ledgerID"})


def _target(payload: object, label: str) -> Target:
    if not isinstance(payload, dict):
        raise ReleaseEvidenceError(f"{label} target is invalid")
    version = payload.get("version")
    build_number = payload.get("buildNumber")
    if (
        not isinstance(version, str)
        or VERSION_PATTERN.fullmatch(version) is None
        or not isinstance(build_number, str)
        or BUILD_NUMBER_PATTERN.fullmatch(build_number) is None
    ):
        raise ReleaseEvidenceError(f"{label} target is invalid")
    return Target(version, build_number)


def _validated_shadow_disagreement(
    payload: object,
    *,
    error_message: str,
) -> dict[str, str]:
    if (
        not isinstance(payload, dict)
        or set(payload)
        != {"surface", "evidenceClass", "classification", "resolution"}
        or payload.get("surface") not in RUNTIME_SURFACES
        or payload.get("evidenceClass") not in EVIDENCE_CLASSES
        or payload.get("classification") not in SHADOW_CLASSIFICATIONS
        or not isinstance(payload.get("resolution"), str)
        or PUBLIC_TOKEN_PATTERN.fullmatch(payload["resolution"]) is None
    ):
        raise ReleaseEvidenceError(error_message)
    return {
        "surface": payload["surface"],
        "evidenceClass": payload["evidenceClass"],
        "classification": payload["classification"],
        "resolution": payload["resolution"].strip(),
    }


def _validate_policy(policy: dict[str, Any]) -> dict[str, Any]:
    if set(policy) != {
        "schemaVersion",
        "maximumEvidenceAgeDays",
        "requiredShadowTrainCount",
        "hostOSCompatibility",
        "runtimeRegressionWatchlist",
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
    _validate_runtime_regression_watchlist(policy.get("runtimeRegressionWatchlist"))
    return policy


def _validate_runtime_regression_watchlist(payload: object) -> dict[str, Any]:
    if (
        not isinstance(payload, dict)
        or set(payload)
        != {
            "maximumEntryDays",
            "maximumExtensionDays",
            "maximumExtensions",
            "entries",
        }
    ):
        raise ReleaseEvidenceError("runtime regression watchlist is invalid")
    maximum_entry_days = payload.get("maximumEntryDays")
    maximum_extension_days = payload.get("maximumExtensionDays")
    maximum_extensions = payload.get("maximumExtensions")
    entries = payload.get("entries")
    if (
        not isinstance(maximum_entry_days, int)
        or isinstance(maximum_entry_days, bool)
        or maximum_entry_days < 1
        or maximum_entry_days > 30
        or not isinstance(maximum_extension_days, int)
        or isinstance(maximum_extension_days, bool)
        or maximum_extension_days < 1
        or maximum_extension_days > 14
        or not isinstance(maximum_extensions, int)
        or isinstance(maximum_extensions, bool)
        or maximum_extensions < 0
        or maximum_extensions > 2
        or not isinstance(entries, list)
        or len(entries) > len(RUNTIME_SURFACES)
    ):
        raise ReleaseEvidenceError("runtime regression watchlist is invalid")
    surface_ids: list[str] = []
    for entry in entries:
        if (
            not isinstance(entry, dict)
            or set(entry)
            != {
                "surfaceId",
                "requiredEvidence",
                "reason",
                "exitCriteria",
                "enteredAt",
                "expiresAt",
                "extensions",
            }
        ):
            raise ReleaseEvidenceError("runtime regression watchlist entry is invalid")
        surface_id = entry.get("surfaceId")
        required_evidence = entry.get("requiredEvidence")
        reason = entry.get("reason")
        exit_criteria = entry.get("exitCriteria")
        entered_at = parse_iso8601(entry.get("enteredAt"))
        expires_at = parse_iso8601(entry.get("expiresAt"))
        extensions = entry.get("extensions")
        if (
            surface_id not in RUNTIME_SURFACES
            or not isinstance(required_evidence, list)
            or tuple(required_evidence) not in WATCHLIST_REQUIRED_EVIDENCE
            or not isinstance(reason, str)
            or PUBLIC_TOKEN_PATTERN.fullmatch(reason) is None
            or not isinstance(exit_criteria, str)
            or PUBLIC_TOKEN_PATTERN.fullmatch(exit_criteria) is None
            or entered_at is None
            or expires_at is None
            or expires_at <= entered_at
            or expires_at > entered_at + timedelta(days=maximum_entry_days)
            or not isinstance(extensions, list)
            or len(extensions) > maximum_extensions
        ):
            raise ReleaseEvidenceError("runtime regression watchlist entry is invalid")
        surface_ids.append(surface_id)
        previous_expiry = expires_at
        previous_extension_at: datetime | None = None
        for extension in extensions:
            if (
                not isinstance(extension, dict)
                or set(extension) != {"extendedAt", "expiresAt", "reason"}
            ):
                raise ReleaseEvidenceError("runtime regression watchlist extension is invalid")
            extended_at = parse_iso8601(extension.get("extendedAt"))
            extension_expiry = parse_iso8601(extension.get("expiresAt"))
            extension_reason = extension.get("reason")
            if (
                extended_at is None
                or extension_expiry is None
                or not isinstance(extension_reason, str)
                or PUBLIC_TOKEN_PATTERN.fullmatch(extension_reason) is None
                or extended_at < entered_at
                or extended_at >= previous_expiry
                or (
                    previous_extension_at is not None
                    and extended_at <= previous_extension_at
                )
                or extension_expiry <= previous_expiry
                or extension_expiry
                > previous_expiry + timedelta(days=maximum_extension_days)
            ):
                raise ReleaseEvidenceError("runtime regression watchlist extension is invalid")
            previous_extension_at = extended_at
            previous_expiry = extension_expiry
    if surface_ids != sorted(surface_ids) or len(surface_ids) != len(set(surface_ids)):
        raise ReleaseEvidenceError("runtime regression watchlist entries are invalid")
    return payload


def _effective_required_surfaces(
    required_surfaces: dict[str, list[str]],
    *,
    policy: dict[str, Any],
    surface_policy: dict[str, Any],
    at: datetime,
) -> dict[str, list[str]]:
    capabilities = {
        item["id"]: set(item["evidenceCapabilities"])
        for item in surface_policy["surfaces"]
    }
    required = {
        evidence_class: set(required_surfaces[evidence_class])
        for evidence_class in EVIDENCE_CLASSES
    }
    entries = policy["runtimeRegressionWatchlist"]["entries"]
    for entry in entries:
        surface_id = entry["surfaceId"]
        entry_evidence = set(entry["requiredEvidence"])
        effective_expiry = (
            entry["extensions"][-1]["expiresAt"]
            if entry["extensions"]
            else entry["expiresAt"]
        )
        entered_at = parse_iso8601(entry["enteredAt"])
        expires_at = parse_iso8601(effective_expiry)
        if entered_at is None or expires_at is None:
            raise ReleaseEvidenceError("runtime regression watchlist entry is invalid")
        if at < expires_at and not entry_evidence.issubset(capabilities[surface_id]):
            raise ReleaseEvidenceError(
                f"runtime regression watchlist exceeds evidence capabilities for {surface_id}"
            )
        if entered_at <= at < expires_at:
            for evidence_class in entry["requiredEvidence"]:
                required[evidence_class].add(surface_id)
    return {
        evidence_class: [
            surface
            for surface in RUNTIME_SURFACES
            if surface in required[evidence_class]
        ]
        for evidence_class in EVIDENCE_CLASSES
    }


def _validate_surface_policy(
    surface_policy: dict[str, Any],
    *,
    train: str,
    comparison_surfaces: dict[str, dict[str, Any]],
    toolchain_changed: bool = False,
) -> dict[str, Any]:
    evidence_policy = surface_policy.get("evidencePolicy")
    surfaces = surface_policy.get("surfaces")
    if (
        surface_policy.get("schemaVersion") != 1
        or not isinstance(evidence_policy, dict)
        or not isinstance(surfaces, list)
        or evidence_policy.get("classes") != list(EVIDENCE_CLASSES)
    ):
        raise ReleaseEvidenceError("surface evidence policy is invalid")
    train_minimums = evidence_policy.get("trainMinimumEvidence")
    change_requirements = evidence_policy.get("changeRequirements")
    if (
        not isinstance(train_minimums, dict)
        or set(train_minimums) != TRAINS
        or not isinstance(change_requirements, dict)
        or set(change_requirements) != {"render", "runtime", "unknown", "placement"}
        or any(
            not isinstance(values, list)
            or any(value not in EVIDENCE_CLASSES for value in values)
            for values in (*train_minimums.values(), *change_requirements.values())
        )
        or evidence_policy.get("releaseRequiresApprovedRCTarget") is not True
    ):
        raise ReleaseEvidenceError("surface evidence policy is invalid")
    capabilities_by_surface: dict[str, set[str]] = {}
    artifact_ids_by_surface: dict[str, str] = {}
    for item in surfaces:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise ReleaseEvidenceError("surface evidence policy is invalid")
        capabilities = item.get("evidenceCapabilities")
        artifact_id = item.get("artifactId")
        if (
            item["id"] in capabilities_by_surface
            or item["id"] not in RUNTIME_SURFACES
            or not isinstance(capabilities, list)
            or not isinstance(artifact_id, str)
            or not artifact_id
            or any(value not in EVIDENCE_CLASSES for value in capabilities)
        ):
            raise ReleaseEvidenceError("surface evidence policy is invalid")
        capabilities_by_surface[item["id"]] = set(capabilities)
        artifact_ids_by_surface[item["id"]] = artifact_id
    if set(capabilities_by_surface) != set(RUNTIME_SURFACES):
        raise ReleaseEvidenceError("surface evidence policy is invalid")
    for surface, comparison_surface in comparison_surfaces.items():
        if comparison_surface.get("artifactId") != artifact_ids_by_surface[surface]:
            raise ReleaseEvidenceError(
                f"surface comparison artifact does not match policy for {surface}"
            )
        capabilities = capabilities_by_surface[surface]
        changes = comparison_surface.get("changes")
        reason_codes = comparison_surface.get("reasonCodes")
        if (
            not isinstance(changes, dict)
            or set(changes) != {"render", "runtime", "placement", "contract", "exactBuild"}
            or any(not isinstance(value, bool) for value in changes.values())
            or not isinstance(reason_codes, list)
            or any(not isinstance(value, str) for value in reason_codes)
        ):
            raise ReleaseEvidenceError("surface comparison change evidence is invalid")
        minimum = [
            value
            for value in EVIDENCE_CLASSES
            if value in capabilities and value in train_minimums[train]
        ]
        fresh: set[str] = set()
        if "new-surface" in reason_codes or changes["contract"]:
            fresh.update(change_requirements["unknown"])
        else:
            for change_kind in ("render", "runtime", "placement"):
                if changes[change_kind]:
                    fresh.update(change_requirements[change_kind])
            if (
                changes["exactBuild"]
                and "actual-runtime" in capabilities
                and "actual-runtime" in train_minimums[train]
            ):
                fresh.add("actual-runtime")
            if (
                toolchain_changed
                and train in {"rc", "release"}
                and "actual-runtime" in capabilities
            ):
                fresh.add("actual-runtime")
        fresh_evidence = [
            value for value in EVIDENCE_CLASSES if value in capabilities and value in fresh
        ]
        required_evidence = [
            value
            for value in EVIDENCE_CLASSES
            if value in capabilities and value in {*minimum, *fresh_evidence}
        ]
        expected_carry: dict[str, dict[str, Any]] = {}
        for evidence_class in EVIDENCE_CLASSES:
            if evidence_class not in capabilities:
                continue
            eligible = False
            conditions: list[str] = []
            if "new-surface" not in reason_codes:
                if evidence_class == "shared-view":
                    eligible = not changes["render"] and not changes["contract"]
                elif evidence_class == "actual-runtime":
                    eligible = (
                        not changes["runtime"]
                        and not changes["exactBuild"]
                        and not changes["contract"]
                    )
                else:
                    eligible = not changes["placement"] and not changes["contract"]
                    if eligible:
                        conditions = [
                            "matching-host-os",
                            "matching-current-runtime-receipt",
                        ]
            if evidence_class in fresh_evidence:
                eligible = False
                conditions = []
            expected_carry[evidence_class] = {
                "eligible": eligible,
                "conditions": conditions,
            }
        if (
            comparison_surface.get("minimumEvidence") != minimum
            or comparison_surface.get("freshEvidence") != fresh_evidence
            or comparison_surface.get("requiredEvidence") != required_evidence
            or comparison_surface.get("carryForward") != expected_carry
        ):
            raise ReleaseEvidenceError(
                f"surface comparison violates evidence policy for {surface}"
            )
    return surface_policy


def _validate_comparison(
    comparison: dict[str, Any],
    train: str,
    surface_policy: dict[str, Any] | None = None,
    allow_legacy_reconstruction: bool = False,
) -> dict[str, dict[str, Any]]:
    try:
        validated = (
            validate_legacy_v1_comparison_for_reconstruction(comparison)
            if allow_legacy_reconstruction and comparison.get("schemaVersion") == 1
            else validate_legacy_v2_comparison_for_reconstruction(comparison)
            if allow_legacy_reconstruction and comparison.get("schemaVersion") == 2
            else validate_legacy_v3_comparison_for_reconstruction(comparison)
            if allow_legacy_reconstruction and comparison.get("schemaVersion") == 3
            else validate_current_comparison(
                comparison,
                runtime_capable_surface_ids=set(RUNTIME_SURFACES),
            )
        )
    except ComparisonSchemaError as error:
        raise ReleaseEvidenceError(f"surface comparison is invalid: {error}") from error
    if validated["train"] != train:
        raise ReleaseEvidenceError("surface comparison does not match the requested train")
    if train == "release" and not validated["releaseRequiresApprovedRCTarget"]:
        raise ReleaseEvidenceError("surface comparison release RC requirement is invalid")
    surface_map = {item["surfaceId"]: item for item in validated["surfaces"]}
    if surface_policy is not None:
        _validate_surface_policy(
            surface_policy,
            train=train,
            comparison_surfaces=surface_map,
            toolchain_changed=bool(validated.get("toolchainChanged", False)),
        )
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
        if (
            not isinstance(host_os, str)
            or HOST_OS_PATTERN.fullmatch(host_os) is None
            or not evidence["decisionIDs"]
            or not evidence["runtimeReceiptIDs"]
        ):
            raise ReleaseEvidenceError(f"{label} contains invalid evidence")
    elif host_os is not None:
        raise ReleaseEvidenceError(f"{label} contains invalid evidence")
    if evidence_class == "actual-runtime" and (
        evidence["decisionIDs"]
        or not evidence["runtimeReceiptIDs"]
        or parse_iso8601(observed_at) is None
    ):
        raise ReleaseEvidenceError(f"{label} contains invalid evidence")
    if evidence_class == "shared-view" and (
        not evidence["decisionIDs"] or evidence["runtimeReceiptIDs"]
    ):
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


def _current_runtime(
    report: dict[str, Any],
    identities: dict[str, ExpectedSurfaceIdentity],
    *,
    now: datetime,
    maximum_age_days: int,
) -> dict[str, dict[str, Any]]:
    surfaces: dict[str, dict[str, Any]] = {}
    for item in report.get("runtimeSurfaces") or []:
        if not isinstance(item, dict) or not isinstance(item.get("surface"), str):
            continue
        identity = identities.get(item["surface"])
        observed_at = parse_iso8601(item.get("observedAt"))
        if (
            identity is not None
            and item.get("state") == "proven"
            and item.get("manifestID") == identity.manifest_id
            and item.get("expectedBuildID") == identity.expected_build_id
            and item.get("identityDigest") == identity.identity_digest()
            and item.get("runtimeFingerprint") == identity.runtime_fingerprint
            and isinstance(item.get("receiptIDs"), list)
            and item["receiptIDs"]
            and all(_is_sha256(receipt_id) for receipt_id in item["receiptIDs"])
            and observed_at is not None
            and now - timedelta(days=maximum_age_days) <= observed_at <= now
        ):
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
            "observedAt": runtime["observedAt"],
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
        host_os = next(iter(host_os_values))
        if not isinstance(host_os, str) or HOST_OS_PATTERN.fullmatch(host_os) is None:
            return None
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
    required_shadow_train_count: int,
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
        or not _is_sha256(ledger.get("comparisonDigest"))
        or not _is_sha256(ledger.get("policyDigest"))
        or not _is_sha256(ledger.get("expectedBuildIdentityDigest"))
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
        or ledger.get("privacy") != PRIVACY_MARKER
    ):
        raise ReleaseEvidenceError(f"{label} surfaces are invalid")
    if any(not isinstance(value, str) for value in ledger["blockers"]):
        raise ReleaseEvidenceError(f"{label} blockers are invalid")
    shadow = ledger["shadow"]
    if (
        set(shadow)
        != {
            "state",
            "requiredTrainCount",
            "observedTrainCount",
            "qualifiedTrainCount",
            "disagreements",
            "blockers",
        }
        or shadow.get("state") not in {"pending", "passed"}
        or not isinstance(shadow.get("requiredTrainCount"), int)
        or isinstance(shadow.get("requiredTrainCount"), bool)
        or shadow["requiredTrainCount"] < 2
        or shadow["requiredTrainCount"] != required_shadow_train_count
        or not isinstance(shadow.get("observedTrainCount"), int)
        or isinstance(shadow.get("observedTrainCount"), bool)
        or shadow["observedTrainCount"] < 0
        or not isinstance(shadow.get("qualifiedTrainCount"), int)
        or isinstance(shadow.get("qualifiedTrainCount"), bool)
        or shadow["qualifiedTrainCount"] < 0
        or shadow["qualifiedTrainCount"] > shadow["observedTrainCount"]
        or not isinstance(shadow.get("disagreements"), list)
        or not isinstance(shadow.get("blockers"), list)
        or any(
            not isinstance(value, str) or PUBLIC_TOKEN_PATTERN.fullmatch(value) is None
            for value in shadow.get("blockers", [])
        )
    ):
        raise ReleaseEvidenceError(f"{label} shadow evidence is invalid")
    for disagreement in shadow["disagreements"]:
        _validated_shadow_disagreement(
            disagreement,
            error_message=f"{label} shadow evidence is invalid",
        )
    expected_shadow_state = (
        "passed"
        if shadow["qualifiedTrainCount"] >= shadow["requiredTrainCount"]
        and not shadow["blockers"]
        else "pending"
    )
    if shadow["state"] != expected_shadow_state:
        raise ReleaseEvidenceError(f"{label} shadow evidence is invalid")
    if (
        ledger.get("state") == "approved" and shadow["state"] != "passed"
    ) or (
        ledger.get("state") == "shadow-approved" and shadow["state"] == "passed"
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
) -> dict[str, dict[str, str]]:
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
    result: dict[str, dict[str, str]] = {}
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
        result[surface] = {
            "hostOS": item["hostOS"],
            "runtimeReceiptID": item["runtimeReceiptID"],
        }
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
    if surface not in patch_sensitive:
        return True
    return (
        previous_match["patch"] is not None
        and current_match["patch"] is not None
        and previous_match["patch"] == current_match["patch"]
    )


def _carried_evidence(
    *,
    prior_surface: dict[str, Any] | None,
    surface: str,
    evidence_class: str,
    fingerprint: str,
    current_runtime: dict[str, dict[str, Any]],
    current_host_os: dict[str, dict[str, str]],
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
    if evidence_class == "actual-runtime":
        if (
            expected_identity_digest is None
            or prior_surface.get("identityDigest") != expected_identity_digest
            or (require_current_runtime and surface not in current_runtime)
        ):
            return None
    if evidence_class == "os-composited-placement":
        previous_host_os = evidence.get("hostOS")
        observed_host = current_host_os.get(surface)
        observed_host_os = observed_host.get("hostOS") if observed_host is not None else None
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
        carried["hostOS"] = current_host_os[surface]["hostOS"]
        carried["runtimeReceiptIDs"] = [current_host_os[surface]["runtimeReceiptID"]]
    return carried


def _generation_identities(
    payload: object,
    *,
    label: str,
    target: Target,
) -> tuple[ExpectedSurfaceIdentity, ...]:
    if (
        not isinstance(payload, dict)
        or set(payload) != GENERATION_KEYS
        or not isinstance(payload.get("comparison"), dict)
        or not isinstance(payload.get("validationReport"), dict)
        or not isinstance(payload.get("expectedBuildManifests"), list)
    ):
        raise ReleaseEvidenceError(f"{label} generation context is invalid")
    try:
        manifests = payload["expectedBuildManifests"]
        if any(not isinstance(item, dict) for item in manifests):
            raise RuntimeEvidenceError("expected signed build manifest is invalid")
        return expected_surface_identities_from_payloads(
            manifests,
            target,
            tuple(RUNTIME_SURFACES),
        )
    except (KeyError, TypeError, ValueError, RuntimeEvidenceError) as error:
        raise ReleaseEvidenceError(
            f"{label} expected-build identities are invalid"
        ) from error


def _verified_lineage_ledger(
    payload: object,
    *,
    label: str,
    policy: dict[str, Any],
    surface_policy: dict[str, Any],
    lineage_depth: int,
    lineage_seen: frozenset[str],
) -> dict[str, Any]:
    if lineage_depth >= MAX_LINEAGE_DEPTH:
        raise ReleaseEvidenceError(f"{label} exceeds the lineage depth limit")
    if (
        not isinstance(payload, dict)
        or set(payload) != {"schemaVersion", "kind", "ledger", "generation"}
        or payload.get("schemaVersion") != 1
        or payload.get("kind") != RELEASE_EVIDENCE_LINEAGE_KIND
        or not isinstance(payload.get("ledger"), dict)
    ):
        raise ReleaseEvidenceError(f"{label} lineage is invalid")
    ledger = payload["ledger"]
    ledger_target = _target(ledger.get("target"), f"{label} lineage")
    ledger_id = ledger.get("ledgerID")
    if not _is_sha256(ledger_id):
        raise ReleaseEvidenceError(f"{label} lineage ledger is invalid")
    if ledger_id in lineage_seen:
        raise ReleaseEvidenceError(f"{label} lineage repeats a ledger")
    generation = payload.get("generation")
    identities = _generation_identities(
        generation,
        label=label,
        target=ledger_target,
    )
    generated_at = parse_iso8601(ledger.get("generatedAt"))
    if generated_at is None:
        raise ReleaseEvidenceError(f"{label} lineage ledger is invalid")
    reconstructed = evaluate_release_evidence(
        train=ledger.get("train"),
        mode=ledger.get("mode"),
        comparison=generation["comparison"],
        validation_report=generation["validationReport"],
        identities=identities,
        policy=policy,
        surface_policy=surface_policy,
        previous_ledger=generation["previousLedger"],
        selected_rc_ledger=generation["selectedRCLedger"],
        host_os_evidence=generation["hostOSEvidence"],
        shadow_evidence=generation["shadowEvidence"],
        now=generated_at,
        _lineage_depth=lineage_depth + 1,
        _lineage_seen=lineage_seen | {ledger_id},
        _allow_legacy_comparison=True,
    )
    if reconstructed != ledger:
        raise ReleaseEvidenceError(
            f"{label} ledger does not match its generation context"
        )
    return ledger


def _shadow_state(
    payload: dict[str, Any] | None,
    required_count: int,
    *,
    now: datetime,
    maximum_age_days: int,
    policy: dict[str, Any],
    surface_policy: dict[str, Any],
    lineage_depth: int,
    lineage_seen: frozenset[str],
) -> dict[str, Any]:
    if payload is None:
        return {
            "state": "pending",
            "requiredTrainCount": required_count,
            "observedTrainCount": 0,
            "qualifiedTrainCount": 0,
            "disagreements": [],
            "blockers": ["insufficient-shadow-trains"],
        }
    if (
        set(payload) != {"schemaVersion", "kind", "runs"}
        or payload.get("schemaVersion") != 1
        or payload.get("kind") != SHADOW_EVIDENCE_KIND
        or not isinstance(payload.get("runs"), list)
        or len(payload["runs"]) > required_count
    ):
        raise ReleaseEvidenceError("shadow comparison evidence is invalid")
    disagreements: list[dict[str, Any]] = []
    blockers: set[str] = set()
    run_identities: dict[tuple[str, str, str], tuple[str, str]] = {}
    ledger_ids: set[str] = set()
    for run in payload["runs"]:
        if (
            not isinstance(run, dict)
            or set(run)
            != {
                "train",
                "target",
                "manifestID",
                "expectedBuildIdentityDigest",
                "ledgerID",
                "observedAt",
                "runbookState",
                "ledgerState",
                "disagreements",
                "ledger",
                "generation",
            }
            or run.get("train") not in TRAINS
            or not _is_sha256(run.get("manifestID"))
            or not _is_sha256(run.get("expectedBuildIdentityDigest"))
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
            run["train"],
            run_target.version,
            run_target.build_number,
        )
        if run_identity in run_identities:
            raise ReleaseEvidenceError("shadow comparison duplicates a signed train")
        if run["ledgerID"] in ledger_ids:
            raise ReleaseEvidenceError("shadow comparison reuses a release evidence ledger")
        ledger_ids.add(run["ledgerID"])
        embedded_ledger = run.get("ledger")
        if run["ledgerState"] == "approved":
            if not isinstance(embedded_ledger, dict):
                raise ReleaseEvidenceError("shadow comparison ledger is invalid")
            _validate_ledger(
                embedded_ledger,
                expected_manifest_id=run["manifestID"],
                now=now,
                label="shadow comparison ledger",
                maximum_age_days=maximum_age_days,
                required_shadow_train_count=required_count,
                allowed_states=frozenset({"approved", "shadow-approved"}),
            )
            if (
                _target(embedded_ledger.get("target"), "shadow comparison ledger")
                != run_target
                or embedded_ledger.get("train") != run["train"]
                or embedded_ledger.get("mode") != "shadow"
                or embedded_ledger.get("ledgerID") != run["ledgerID"]
                or embedded_ledger.get("expectedBuildIdentityDigest")
                != run["expectedBuildIdentityDigest"]
                or embedded_ledger.get("policyDigest") != _hash_payload(policy)
                or embedded_ledger.get("surfacePolicyDigest")
                != _hash_payload(surface_policy)
            ):
                raise ReleaseEvidenceError("shadow comparison ledger binding is invalid")
            generation = run.get("generation")
            generation_identities = _generation_identities(
                generation,
                label="shadow comparison",
                target=run_target,
            )
            if generation["shadowEvidence"] is not None:
                raise ReleaseEvidenceError(
                    "shadow comparison generation must be a leaf evaluation"
                )
            embedded_generated_at = parse_iso8601(embedded_ledger.get("generatedAt"))
            if embedded_generated_at is None:
                raise ReleaseEvidenceError("shadow comparison ledger is invalid")
            reconstructed_ledger = evaluate_release_evidence(
                train=run["train"],
                mode="shadow",
                comparison=generation["comparison"],
                validation_report=generation["validationReport"],
                identities=generation_identities,
                policy=policy,
                surface_policy=surface_policy,
                previous_ledger=generation["previousLedger"],
                selected_rc_ledger=generation["selectedRCLedger"],
                host_os_evidence=generation["hostOSEvidence"],
                shadow_evidence=generation["shadowEvidence"],
                now=embedded_generated_at,
                _lineage_depth=lineage_depth + 1,
                _lineage_seen=lineage_seen | {run["ledgerID"]},
                _allow_legacy_comparison=True,
            )
            if reconstructed_ledger != embedded_ledger:
                raise ReleaseEvidenceError(
                    "shadow comparison ledger does not match its generation context"
                )
        elif embedded_ledger is not None:
            raise ReleaseEvidenceError("blocked shadow comparison must not claim an approved ledger")
        elif run.get("generation") is not None:
            raise ReleaseEvidenceError("blocked shadow comparison must not claim generation context")
        run_identities[run_identity] = (
            run["manifestID"],
            run["expectedBuildIdentityDigest"],
        )
        if run["runbookState"] != run["ledgerState"]:
            blockers.add("runbook-ledger-state-mismatch")
        if run["runbookState"] != "approved" or run["ledgerState"] != "approved":
            blockers.add("shadow-run-not-approved")
        for disagreement in run["disagreements"]:
            disagreements.append(
                _validated_shadow_disagreement(
                    disagreement,
                    error_message="shadow disagreement is invalid",
                )
            )
            if disagreement["classification"] in {"unresolved", "runbook-correct"}:
                blockers.add("shadow-disagreement-not-ledger-safe")
    run_count = len(run_identities)
    qualified_count = run_count if not blockers else 0
    if run_count < required_count:
        blockers.add("insufficient-shadow-trains")
    return {
        "state": "passed" if not blockers else "pending",
        "requiredTrainCount": required_count,
        "observedTrainCount": run_count,
        "qualifiedTrainCount": qualified_count,
        "disagreements": disagreements,
        "blockers": sorted(blockers),
    }


def evaluate_release_evidence(
    *,
    train: str,
    mode: str,
    comparison: dict[str, Any],
    validation_report: dict[str, Any],
    identities: tuple[ExpectedSurfaceIdentity, ...],
    policy: dict[str, Any],
    surface_policy: dict[str, Any],
    previous_ledger: dict[str, Any] | None = None,
    selected_rc_ledger: dict[str, Any] | None = None,
    host_os_evidence: dict[str, Any] | None = None,
    shadow_evidence: dict[str, Any] | None = None,
    now: datetime | None = None,
    _lineage_depth: int = 0,
    _lineage_seen: frozenset[str] | None = None,
    _allow_legacy_comparison: bool = False,
) -> dict[str, Any]:
    if train not in TRAINS or mode not in MODES:
        raise ReleaseEvidenceError("release evidence train or mode is invalid")
    if _lineage_depth > MAX_LINEAGE_DEPTH:
        raise ReleaseEvidenceError("release evidence exceeds the lineage depth limit")
    lineage_seen = _lineage_seen or frozenset()
    policy = _validate_policy(policy)
    surface_comparison = _validate_comparison(
        comparison,
        train,
        surface_policy,
        allow_legacy_reconstruction=_allow_legacy_comparison,
    )
    policy_digest = _hash_payload(policy)
    surface_policy_digest = _hash_payload(surface_policy)
    comparison_digest = _hash_payload(comparison)
    current_manifest_id = str(comparison["currentManifestId"])
    target = _validate_report(validation_report, current_manifest_id)
    validation_report_digest = _hash_payload(validation_report)
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if set(surface_comparison) != set(RUNTIME_SURFACES):
        raise ReleaseEvidenceError("surface comparison does not cover every shipping surface")
    required_surfaces: dict[str, list[str]] = _effective_required_surfaces(
        comparison["requiredSurfaces"],
        policy=policy,
        surface_policy=surface_policy,
        at=now,
    )
    required_scope: set[str] = {
        surface
        for evidence_class in EVIDENCE_CLASSES
        for surface in required_surfaces[evidence_class]
    }
    if not required_scope:
        raise ReleaseEvidenceError("release evidence requires a non-empty authoritative scope")
    identity_by_surface = {item.surface: item for item in identities}
    if not identity_by_surface or any(
        item.manifest_id != current_manifest_id
        or item.marketing_version != target.version
        or item.build_number != target.build_number
        for item in identities
    ):
        raise ReleaseEvidenceError("expected signed-build identity does not match the comparison")
    if set(identity_by_surface) != set(RUNTIME_SURFACES):
        raise ReleaseEvidenceError("expected signed-build manifests do not cover every shipping surface")
    if any(
        identity_by_surface[surface].artifact_id != comparison_surface["artifactId"]
        for surface, comparison_surface in surface_comparison.items()
    ):
        raise ReleaseEvidenceError("expected signed-build artifact does not match the comparison")
    contract_fingerprints = {item.contract_fingerprint for item in identities}
    if len(contract_fingerprints) != 1:
        raise ReleaseEvidenceError("expected signed-build identities do not share one contract")
    expected_identity_digest = _expected_identity_digest(identities)

    previous_surfaces: dict[str, dict[str, Any]] = {}
    previous_expires_at: datetime | None = None
    if previous_ledger is not None:
        verified_previous_ledger = _verified_lineage_ledger(
            previous_ledger,
            label="previous release evidence",
            policy=policy,
            surface_policy=surface_policy,
            lineage_depth=_lineage_depth,
            lineage_seen=lineage_seen,
        )
        if verified_previous_ledger.get("policyDigest") != policy_digest:
            raise ReleaseEvidenceError("previous release evidence policy does not match")
        if verified_previous_ledger.get("surfacePolicyDigest") != surface_policy_digest:
            raise ReleaseEvidenceError("previous surface evidence policy does not match")
        previous_surfaces = _validate_ledger(
            verified_previous_ledger,
            expected_manifest_id=str(comparison["previousManifestId"]),
            now=now,
            label="previous release evidence",
            maximum_age_days=policy["maximumEvidenceAgeDays"],
            required_shadow_train_count=policy["requiredShadowTrainCount"],
        )
        previous_expires_at = parse_iso8601(verified_previous_ledger.get("expiresAt"))
    selected_rc_surfaces: dict[str, dict[str, Any]] = {}
    selected_rc_expires_at: datetime | None = None
    if selected_rc_ledger is not None:
        verified_selected_rc_ledger = _verified_lineage_ledger(
            selected_rc_ledger,
            label="selected RC evidence",
            policy=policy,
            surface_policy=surface_policy,
            lineage_depth=_lineage_depth,
            lineage_seen=lineage_seen,
        )
        if verified_selected_rc_ledger.get("policyDigest") != policy_digest:
            raise ReleaseEvidenceError("selected RC evidence policy does not match")
        if verified_selected_rc_ledger.get("surfacePolicyDigest") != surface_policy_digest:
            raise ReleaseEvidenceError("selected RC surface policy does not match")
        selected_rc_target = _target(
            verified_selected_rc_ledger.get("target"),
            "selected RC evidence",
        )
        if selected_rc_target != target:
            raise ReleaseEvidenceError("selected RC target does not match the release target")
        selected_rc_surfaces = _validate_ledger(
            verified_selected_rc_ledger,
            expected_manifest_id=current_manifest_id,
            now=now,
            label="selected RC evidence",
            maximum_age_days=policy["maximumEvidenceAgeDays"],
            required_shadow_train_count=policy["requiredShadowTrainCount"],
        )
        selected_rc_expires_at = parse_iso8601(
            verified_selected_rc_ledger.get("expiresAt")
        )
        selected_rc_generated_at = parse_iso8601(
            verified_selected_rc_ledger.get("generatedAt")
        )
        if selected_rc_generated_at is None:
            raise ReleaseEvidenceError("selected RC evidence is invalid")
        selected_rc_required_surfaces = _effective_required_surfaces(
            comparison["requiredSurfaces"],
            policy=policy,
            surface_policy=surface_policy,
            at=selected_rc_generated_at,
        )
        if (
            verified_selected_rc_ledger.get("train") != "rc"
            or verified_selected_rc_ledger.get("mode") != "enforce"
            or verified_selected_rc_ledger.get("contractFingerprint")
            != next(iter(contract_fingerprints))
            or verified_selected_rc_ledger.get("expectedBuildIdentityDigest")
            != expected_identity_digest
            or verified_selected_rc_ledger.get("requiredEvidence")
            != selected_rc_required_surfaces
            or not isinstance(verified_selected_rc_ledger.get("shadow"), dict)
            or verified_selected_rc_ledger["shadow"].get("state") != "passed"
        ):
            raise ReleaseEvidenceError("selected RC evidence is not an enforced approved RC")
    if train == "release" and not selected_rc_surfaces:
        raise ReleaseEvidenceError("release evidence requires the selected exact approved RC")

    runtime_surfaces = _current_runtime(
        validation_report,
        identity_by_surface,
        now=now,
        maximum_age_days=policy["maximumEvidenceAgeDays"],
    )
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
                and not selected_rc_surfaces
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
                    expected_identity_digest=(
                        identity.identity_digest()
                        if evidence_class == "actual-runtime"
                        else None
                    ),
                )
            if evidence is None:
                blockers.append(f"{surface}:{evidence_class}:missing")
                evidence = {
                    "state": "missing",
                    "source": "none",
                    "fingerprint": fingerprint,
                    "observedAt": None,
                    "decisionIDs": [],
                    "hostOS": (
                        current_host_os[surface]["hostOS"]
                        if surface in current_host_os
                        else None
                    ),
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
        policy=policy,
        surface_policy=surface_policy,
        lineage_depth=_lineage_depth,
        lineage_seen=lineage_seen,
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
        "comparisonDigest": comparison_digest,
        "surfacePolicyDigest": surface_policy_digest,
        "policyDigest": policy_digest,
        "expectedBuildIdentityDigest": expected_identity_digest,
        "validationReportDigest": validation_report_digest,
        "generatedAt": iso8601(now),
        "expiresAt": iso8601(expires_at),
        "requiredEvidence": required_surfaces,
        "surfaces": output_surfaces,
        "shadow": shadow,
        "blockers": sorted(blockers),
        "privacy": PRIVACY_MARKER,
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
    validation_report: dict[str, Any] | None = None,
    comparison: dict[str, Any] | None = None,
    identities: tuple[ExpectedSurfaceIdentity, ...] = (),
    policy: dict[str, Any] | None = None,
    surface_policy: dict[str, Any] | None = None,
    previous_ledger: dict[str, Any] | None = None,
    selected_rc_ledger: dict[str, Any] | None = None,
    host_os_evidence: dict[str, Any] | None = None,
    shadow_evidence: dict[str, Any] | None = None,
    now: datetime | None = None,
) -> list[str]:
    if not isinstance(payload, dict):
        return ["the release evidence report root must be a JSON object"]
    blockers: list[str] = []
    observed_now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    generated_at = parse_iso8601(payload.get("generatedAt"))
    allowed_states = (
        frozenset({"approved"})
        if enforce
        else frozenset({"approved", "shadow-approved"})
    )
    validated_policy: dict[str, Any] | None = None
    authoritative_required: dict[str, list[str]] | None = None
    authoritative_scope: set[str] = set()
    validated_comparison_surfaces: dict[str, dict[str, Any]] = {}
    try:
        if policy is None:
            raise ReleaseEvidenceError("configured release evidence policy is required")
        validated_policy = _validate_policy(policy)
    except ReleaseEvidenceError as error:
        blockers.append(str(error))
    try:
        if comparison is None:
            raise ReleaseEvidenceError("authoritative surface comparison is required")
        if surface_policy is None:
            raise ReleaseEvidenceError("configured surface evidence policy is required")
        validated_comparison_surfaces = _validate_comparison(
            comparison,
            train,
            surface_policy,
        )
        if set(validated_comparison_surfaces) != set(RUNTIME_SURFACES):
            blockers.append("surface comparison does not cover every shipping surface")
        authoritative_required = comparison["requiredSurfaces"]
        if validated_policy is not None and generated_at is not None:
            authoritative_required = _effective_required_surfaces(
                comparison["requiredSurfaces"],
                policy=validated_policy,
                surface_policy=surface_policy,
                at=generated_at,
            )
        authoritative_scope = {
            surface
            for evidence_class in EVIDENCE_CLASSES
            for surface in authoritative_required[evidence_class]
        }
        if payload.get("requiredEvidence") != authoritative_required:
            blockers.append("release evidence required scope does not match the comparison")
        if payload.get("comparisonDigest") != _hash_payload(comparison):
            blockers.append("release evidence comparison binding is invalid")
        if payload.get("currentManifestID") != comparison.get("currentManifestId"):
            blockers.append("release evidence manifest does not match the comparison")
    except (KeyError, ReleaseEvidenceError) as error:
        blockers.append(str(error))
    identity_by_surface = {identity.surface: identity for identity in identities}
    surfaces = payload.get("surfaces")
    surface_payloads = {
        item.get("surface"): item
        for item in surfaces
        if isinstance(item, dict) and isinstance(item.get("surface"), str)
    } if isinstance(surfaces, list) else {}
    if set(identity_by_surface) != set(RUNTIME_SURFACES):
        blockers.append("expected signed-build manifests do not cover every shipping surface")
    elif identities:
        expected_target = Target(version, build_number)
        manifest_ids = {identity.manifest_id for identity in identities}
        contract_fingerprints = {identity.contract_fingerprint for identity in identities}
        if (
            any(
                identity.marketing_version != expected_target.version
                or identity.build_number != expected_target.build_number
                for identity in identities
            )
            or len(manifest_ids) != 1
            or len(contract_fingerprints) != 1
            or payload.get("currentManifestID") not in manifest_ids
            or payload.get("contractFingerprint") not in contract_fingerprints
            or payload.get("expectedBuildIdentityDigest")
            != _expected_identity_digest(identities)
        ):
            blockers.append("release evidence expected-build binding is invalid")
        for surface in sorted(authoritative_scope):
            identity = identity_by_surface[surface]
            item = surface_payloads.get(surface)
            if not isinstance(item, dict) or item.get("identityDigest") != identity.identity_digest():
                blockers.append(f"{surface}:expected-build-identity:mismatch")
                continue
            evidence_payload = item.get("evidence")
            if not isinstance(evidence_payload, dict):
                blockers.append(f"{surface}:evidence:missing")
                continue
            for evidence_class in EVIDENCE_CLASSES:
                if (
                    authoritative_required is None
                    or surface not in authoritative_required[evidence_class]
                ):
                    continue
                evidence = evidence_payload.get(evidence_class)
                if (
                    not isinstance(evidence, dict)
                    or evidence.get("fingerprint")
                    != _identity_fingerprint(identity, evidence_class)
                ):
                    blockers.append(f"{surface}:{evidence_class}:fingerprint-mismatch")
    if validated_policy is not None:
        if payload.get("policyDigest") != _hash_payload(validated_policy):
            blockers.append("release evidence policy binding is invalid")
        maximum_age_days = validated_policy["maximumEvidenceAgeDays"]
    else:
        maximum_age_days = 1
    if surface_policy is None:
        blockers.append("configured surface evidence policy is required")
    else:
        try:
            _validate_surface_policy(
                surface_policy,
                train=train,
                comparison_surfaces=(
                    validated_comparison_surfaces
                    if comparison is not None
                    else {}
                ),
                toolchain_changed=(
                    bool(comparison.get("toolchainChanged", False))
                    if comparison is not None
                    else False
                ),
            )
            if payload.get("surfacePolicyDigest") != _hash_payload(surface_policy):
                blockers.append("release evidence surface policy binding is invalid")
        except ReleaseEvidenceError as error:
            blockers.append(str(error))
    if validation_report is None:
        blockers.append("exact validation report is required for release evidence binding")
    else:
        try:
            report_target = _validate_report(
                validation_report,
                str(payload.get("currentManifestID") or ""),
            )
            if report_target != Target(version, build_number):
                blockers.append("release evidence validation report targets another build")
            if payload.get("validationReportDigest") != _hash_payload(validation_report):
                blockers.append("release evidence does not match the exact validation report")
        except ReleaseEvidenceError as error:
            blockers.append(str(error))
        if validated_policy is not None and set(identity_by_surface) == set(RUNTIME_SURFACES):
            current_runtime = _current_runtime(
                validation_report,
                identity_by_surface,
                now=observed_now,
                maximum_age_days=maximum_age_days,
            )
            current_visual = _current_visual(validation_report)
            for surface in sorted(authoritative_scope):
                identity = identity_by_surface[surface]
                item = surface_payloads.get(surface)
                evidence_payload = item.get("evidence") if isinstance(item, dict) else None
                if not isinstance(evidence_payload, dict):
                    continue
                for evidence_class in EVIDENCE_CLASSES:
                    if (
                        authoritative_required is None
                        or surface not in authoritative_required[evidence_class]
                    ):
                        continue
                    evidence = evidence_payload.get(evidence_class)
                    if not isinstance(evidence, dict):
                        continue
                    source = evidence.get("source")
                    if source == "fresh":
                        expected_fresh = _fresh_evidence(
                            surface,
                            evidence_class,
                            identity,
                            current_runtime,
                            current_visual,
                            observed_now,
                            maximum_age_days,
                        )
                        if expected_fresh is None or evidence != expected_fresh:
                            blockers.append(
                                f"{surface}:{evidence_class}:validation-report-lineage-mismatch"
                            )
                    elif evidence_class == "actual-runtime" and source == "carry-forward":
                        blockers.append(
                            f"{surface}:actual-runtime:carry-forward-without-fresh-receipt"
                        )
                    elif evidence_class == "os-composited-placement" and source == "carry-forward":
                        runtime = current_runtime.get(surface)
                        current_receipts = set(runtime.get("receiptIDs") or []) if runtime else set()
                        if not set(evidence.get("runtimeReceiptIDs") or []).issubset(current_receipts):
                            blockers.append(
                                f"{surface}:os-composited-placement:current-receipt-mismatch"
                            )
                    elif source == "selected-rc" and train != "release":
                        blockers.append(f"{surface}:{evidence_class}:selected-rc-invalid-train")
    try:
        _validate_ledger(
            payload,
            expected_manifest_id=None,
            now=observed_now,
            label="release evidence report",
            maximum_age_days=maximum_age_days,
            required_shadow_train_count=(
                validated_policy["requiredShadowTrainCount"]
                if validated_policy is not None
                else 2
            ),
            allowed_states=allowed_states,
        )
    except ReleaseEvidenceError as error:
        blockers.append(str(error))
    if payload.get("train") != train:
        blockers.append(f"train must be {train}")
    try:
        target = _target(payload.get("target"), "release evidence report")
    except ReleaseEvidenceError:
        blockers.append("target is missing or malformed")
    else:
        if target.version != version:
            blockers.append(f"target version must be {version}")
        if target.build_number != build_number:
            blockers.append(f"target build number must be {build_number}")
    report_blockers = payload.get("blockers")
    if (
        not _is_sha256(payload.get("ledgerID"))
        or payload.get("ledgerID") != _ledger_id(payload)
    ):
        blockers.append("release evidence ledger identity is invalid")
    if enforce:
        if not authoritative_scope:
            blockers.append("enforced release evidence requires a non-empty authoritative scope")
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
    if (
        generated_at is not None
        and validation_report is not None
        and comparison is not None
        and policy is not None
        and surface_policy is not None
        and set(identity_by_surface) == set(RUNTIME_SURFACES)
        and payload.get("mode") in MODES
        and payload.get("train") in TRAINS
    ):
        try:
            reconstructed = evaluate_release_evidence(
                train=str(payload["train"]),
                mode=str(payload["mode"]),
                comparison=comparison,
                validation_report=validation_report,
                identities=identities,
                policy=policy,
                surface_policy=surface_policy,
                previous_ledger=previous_ledger,
                selected_rc_ledger=selected_rc_ledger,
                host_os_evidence=host_os_evidence,
                shadow_evidence=shadow_evidence,
                now=generated_at,
            )
            if reconstructed != payload:
                blockers.append(
                    "release evidence does not match reconstructed authoritative evaluation"
                )
        except ReleaseEvidenceError as error:
            blockers.append(f"release evidence reconstruction failed: {error}")
    return list(dict.fromkeys(blockers))
