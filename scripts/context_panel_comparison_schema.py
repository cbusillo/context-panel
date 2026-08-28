from __future__ import annotations

import copy
import re
from typing import Any


COMPARISON_KIND = "context-panel-surface-comparison"
CURRENT_COMPARISON_SCHEMA_VERSION = 2
EVIDENCE_CLASSES = (
    "shared-view",
    "actual-runtime",
    "os-composited-placement",
)
TRAIN_NAMES = ("beta", "rc", "release")
ROOT_KEYS = frozenset(
    {
        "kind",
        "schemaVersion",
        "train",
        "previousManifestId",
        "currentManifestId",
        "contractChanged",
        "exactBuildSame",
        "removedSurfaces",
        "requiredSurfaces",
        "requiresRuntimeSession",
        "requiresPlacementReview",
        "surfaces",
        "releaseRequiresApprovedRCTarget",
    }
)
SURFACE_KEYS = frozenset(
    {
        "surfaceId",
        "artifactId",
        "reasonCodes",
        "changes",
        "minimumEvidence",
        "freshEvidence",
        "requiredEvidence",
        "carryForward",
    }
)
CHANGE_KEYS = frozenset({"render", "runtime", "placement", "contract", "exactBuild"})
CARRY_RULE_KEYS = frozenset({"eligible", "conditions"})
REASON_CODES = (
    "new-surface",
    "render-fingerprint-changed",
    "runtime-fingerprint-changed",
    "placement-fingerprint-changed",
    "contract-fingerprint-changed",
    "exact-build-changed",
    "unchanged",
)
PLACEMENT_CARRY_CONDITIONS = (
    "matching-host-os",
    "matching-current-runtime-receipt",
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
LEGACY_V1_ROOT_KEYS = ROOT_KEYS - {"kind"}


class ComparisonSchemaError(RuntimeError):
    pass


def _error(message: str) -> None:
    raise ComparisonSchemaError(message)


def _is_sha256(value: object) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def _canonical_subset(value: object, order: tuple[str, ...], label: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        _error(f"{label} must be a string list")
    if value != [item for item in order if item in value]:
        _error(f"{label} is not canonically ordered")
    return value


def _expected_reason_codes(changes: dict[str, bool], *, new_surface: bool) -> list[str]:
    if new_surface:
        return ["new-surface"]
    reason_codes = [
        reason_code
        for change_key, reason_code in (
            ("render", "render-fingerprint-changed"),
            ("runtime", "runtime-fingerprint-changed"),
            ("placement", "placement-fingerprint-changed"),
            ("contract", "contract-fingerprint-changed"),
            ("exactBuild", "exact-build-changed"),
        )
        if changes[change_key]
    ]
    return reason_codes or ["unchanged"]


def validate_comparison_v2(
    comparison: object,
    *,
    allow_legacy_v1_carry_forward_order: bool = False,
    allow_legacy_v1_incomplete_carry_forward: bool = False,
) -> dict[str, Any]:
    if not isinstance(comparison, dict) or set(comparison) != ROOT_KEYS:
        _error("surface comparison root keys are invalid")
    if (
        comparison["kind"] != COMPARISON_KIND
        or type(comparison["schemaVersion"]) is not int
        or comparison["schemaVersion"] != CURRENT_COMPARISON_SCHEMA_VERSION
        or comparison["train"] not in TRAIN_NAMES
    ):
        _error("surface comparison identity is invalid")
    if not _is_sha256(comparison["previousManifestId"]) or not _is_sha256(
        comparison["currentManifestId"]
    ):
        _error("surface comparison manifest identity is invalid")
    if any(
        not isinstance(comparison[key], bool)
        for key in (
            "contractChanged",
            "exactBuildSame",
            "requiresRuntimeSession",
            "requiresPlacementReview",
            "releaseRequiresApprovedRCTarget",
        )
    ):
        _error("surface comparison flags are invalid")
    removed_surfaces = comparison["removedSurfaces"]
    if (
        not isinstance(removed_surfaces, list)
        or any(not isinstance(surface, str) or not surface for surface in removed_surfaces)
        or removed_surfaces != sorted(set(removed_surfaces))
    ):
        _error("surface comparison removed surfaces are invalid")
    required_surfaces = comparison["requiredSurfaces"]
    if not isinstance(required_surfaces, dict) or set(required_surfaces) != set(EVIDENCE_CLASSES):
        _error("surface comparison required surface keys are invalid")

    surfaces = comparison["surfaces"]
    if not isinstance(surfaces, list):
        _error("surface comparison surfaces are invalid")
    surface_ids: list[str] = []
    required_by_surface: dict[str, list[str]] = {}
    for surface in surfaces:
        if not isinstance(surface, dict) or set(surface) != SURFACE_KEYS:
            _error("surface comparison surface keys are invalid")
        surface_id = surface["surfaceId"]
        artifact_id = surface["artifactId"]
        if not isinstance(surface_id, str) or not surface_id or not isinstance(artifact_id, str) or not artifact_id:
            _error("surface comparison surface identity is invalid")
        surface_ids.append(surface_id)
        reason_codes = _canonical_subset(
            surface["reasonCodes"], REASON_CODES, "surface comparison reason codes"
        )
        if not reason_codes:
            _error("surface comparison reason codes are empty")
        changes = surface["changes"]
        if not isinstance(changes, dict) or set(changes) != CHANGE_KEYS or any(
            not isinstance(value, bool) for value in changes.values()
        ):
            _error("surface comparison changes are invalid")
        if (
            changes["contract"] != comparison["contractChanged"]
            or changes["exactBuild"] == comparison["exactBuildSame"]
        ):
            _error("surface comparison changes are inconsistent")
        new_surface = "new-surface" in reason_codes
        if new_surface and not all(
            changes[change_key] for change_key in ("render", "runtime", "placement")
        ):
            _error("surface comparison new surface changes are inconsistent")
        if reason_codes != _expected_reason_codes(changes, new_surface=new_surface):
            _error("surface comparison reason codes are inconsistent")
        minimum = _canonical_subset(surface["minimumEvidence"], EVIDENCE_CLASSES, "surface comparison minimum evidence")
        fresh = _canonical_subset(surface["freshEvidence"], EVIDENCE_CLASSES, "surface comparison fresh evidence")
        required = _canonical_subset(surface["requiredEvidence"], EVIDENCE_CLASSES, "surface comparison required evidence")
        expected_required = [
            evidence_class
            for evidence_class in EVIDENCE_CLASSES
            if evidence_class in minimum or evidence_class in fresh
        ]
        if required != expected_required:
            _error("surface comparison required evidence is inconsistent")
        if (
            "os-composited-placement" in required
            and "actual-runtime" not in required
        ):
            _error("surface comparison placement evidence requires runtime evidence")
        carry_forward = surface["carryForward"]
        if not isinstance(carry_forward, dict) or any(
            evidence_class not in EVIDENCE_CLASSES for evidence_class in carry_forward
        ):
            _error("surface comparison carry-forward keys are invalid")
        if (
            not allow_legacy_v1_incomplete_carry_forward
            and not set(required).issubset(carry_forward)
        ):
            _error("surface comparison carry-forward is incomplete")
        if not allow_legacy_v1_carry_forward_order and list(carry_forward) != [
            evidence_class
            for evidence_class in EVIDENCE_CLASSES
            if evidence_class in carry_forward
        ]:
            _error("surface comparison carry-forward keys are not canonically ordered")
        for evidence_class, carry_rule in carry_forward.items():
            if evidence_class not in EVIDENCE_CLASSES or not isinstance(carry_rule, dict) or set(carry_rule) != CARRY_RULE_KEYS:
                _error("surface comparison carry-forward rule is invalid")
            if not isinstance(carry_rule["eligible"], bool) or not isinstance(carry_rule["conditions"], list):
                _error("surface comparison carry-forward rule is invalid")
            expected_conditions = list(PLACEMENT_CARRY_CONDITIONS) if (
                evidence_class == "os-composited-placement" and carry_rule["eligible"]
            ) else []
            if carry_rule["conditions"] != expected_conditions:
                _error("surface comparison carry-forward conditions are invalid")
            expected_eligible = False
            if not new_surface:
                if evidence_class == "shared-view":
                    expected_eligible = not changes["render"] and not changes["contract"]
                elif evidence_class == "actual-runtime":
                    expected_eligible = (
                        not changes["runtime"]
                        and not changes["exactBuild"]
                        and not changes["contract"]
                    )
                elif evidence_class == "os-composited-placement":
                    expected_eligible = not changes["placement"] and not changes["contract"]
            if evidence_class in fresh:
                if carry_rule["eligible"]:
                    _error("surface comparison fresh evidence cannot carry forward")
                expected_eligible = False
            if carry_rule["eligible"] != expected_eligible:
                _error("surface comparison carry-forward eligibility is inconsistent")
        required_by_surface[surface_id] = required
    if surface_ids != sorted(surface_ids) or len(surface_ids) != len(set(surface_ids)):
        _error("surface comparison surfaces are not canonically ordered")
    if set(removed_surfaces) & set(surface_ids):
        _error("surface comparison removed surfaces overlap current surfaces")
    for evidence_class in EVIDENCE_CLASSES:
        actual = required_surfaces[evidence_class]
        expected = [
            surface_id
            for surface_id in surface_ids
            if evidence_class in required_by_surface[surface_id]
        ]
        if actual != expected:
            _error("surface comparison required surfaces are inconsistent")
    if comparison["requiresRuntimeSession"] != bool(required_surfaces["actual-runtime"]):
        _error("surface comparison runtime requirement is inconsistent")
    if comparison["requiresPlacementReview"] != bool(required_surfaces["os-composited-placement"]):
        _error("surface comparison placement requirement is inconsistent")
    return comparison


def validate_current_comparison(comparison: object) -> dict[str, Any]:
    return validate_comparison_v2(comparison)


def validate_legacy_v1_comparison_for_reconstruction(comparison: object) -> dict[str, Any]:
    if (
        not isinstance(comparison, dict)
        or set(comparison) != LEGACY_V1_ROOT_KEYS
        or type(comparison.get("schemaVersion")) is not int
        or comparison.get("schemaVersion") != 1
    ):
        _error("legacy surface comparison identity is invalid")
    adapted = copy.deepcopy(comparison)
    adapted["kind"] = COMPARISON_KIND
    adapted["schemaVersion"] = CURRENT_COMPARISON_SCHEMA_VERSION
    return validate_comparison_v2(
        adapted,
        allow_legacy_v1_carry_forward_order=True,
        allow_legacy_v1_incomplete_carry_forward=True,
    )
