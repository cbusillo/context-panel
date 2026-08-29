from __future__ import annotations

import copy
import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, Callable, NoReturn


def _load_v3_schema() -> ModuleType:
    path = Path(__file__).with_name("context_panel_surface_manifest") / "comparison_schema_v3.py"
    spec = importlib.util.spec_from_file_location(
        "context_panel_surface_manifest.comparison_schema_v3", path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("frozen comparison schema v3 is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


comparison_schema_v3 = _load_v3_schema()
_v3 = comparison_schema_v3
comparison_schema_v2 = _v3.comparison_schema_v2
_v2 = comparison_schema_v2


COMPARISON_KIND = _v3.COMPARISON_KIND
V2_COMPARISON_SCHEMA_VERSION = _v3.V2_COMPARISON_SCHEMA_VERSION
V3_COMPARISON_SCHEMA_VERSION = _v3.CURRENT_COMPARISON_SCHEMA_VERSION
CURRENT_COMPARISON_SCHEMA_VERSION = 4
EVIDENCE_CLASSES = _v3.EVIDENCE_CLASSES
TRAIN_NAMES = _v3.TRAIN_NAMES
V3_ROOT_KEYS = _v3.ROOT_KEYS
ROOT_KEYS = V3_ROOT_KEYS | {
    "toolchainChanged",
    "riskCodes",
    "riskSurfaces",
    "observationRiskCodes",
}
SURFACE_KEYS = _v3.SURFACE_KEYS
CHANGE_KEYS = _v3.CHANGE_KEYS
CARRY_RULE_KEYS = _v3.CARRY_RULE_KEYS
REASON_CODES = _v3.REASON_CODES
RUNTIME_STATES = _v3.RUNTIME_STATES
RUNTIME_STATE_REASON_CODES = _v3.RUNTIME_STATE_REASON_CODES
PLACEMENT_CARRY_CONDITIONS = _v3.PLACEMENT_CARRY_CONDITIONS
SHA256_PATTERN = _v3.SHA256_PATTERN
LEGACY_V1_ROOT_KEYS = _v3.LEGACY_V1_ROOT_KEYS
LEGACY_V2_ROOT_KEYS = _v2.ROOT_KEYS
LEGACY_V3_ROOT_KEYS = _v3.ROOT_KEYS
RISK_CODES = (
    "unmapped-surface",
    "render-divergence",
    "runtime-divergence",
    "placement-divergence",
    "contract-divergence",
    "toolchain-divergence",
)
OBSERVATION_RISK_CODES = ("host-os-divergence",)
RISK_CHANGE_KEYS = {
    "render-divergence": "render",
    "runtime-divergence": "runtime",
    "placement-divergence": "placement",
    "contract-divergence": "contract",
}
ComparisonSchemaError = _v3.ComparisonSchemaError
_error: Callable[[str], NoReturn] = getattr(_v3, "_error")
_is_sha256 = getattr(_v3, "_is_sha256")
_canonical_subset = getattr(_v3, "_canonical_subset")
_expected_reason_codes = getattr(_v3, "_expected_reason_codes")
derive_runtime_decision = _v3.derive_runtime_decision
validate_comparison_v2 = _v2.validate_comparison_v2
validate_comparison_v3 = _v3.validate_comparison_v3
validate_legacy_v1_comparison_for_reconstruction = (
    _v3.validate_legacy_v1_comparison_for_reconstruction
)
validate_legacy_v2_comparison_for_reconstruction = (
    _v3.validate_legacy_v2_comparison_for_reconstruction
)


def toolchain_changed(previous: dict[str, Any], current: dict[str, Any]) -> bool:
    previous_source = previous.get("source")
    current_source = current.get("source")
    if not isinstance(previous_source, dict) or not isinstance(current_source, dict):
        return True
    if "xcodeBuild" not in previous_source or "xcodeBuild" not in current_source:
        return True
    if "toolchain" not in previous or "toolchain" not in current:
        return True
    return (
        previous_source["xcodeBuild"] != current_source["xcodeBuild"]
        or previous["toolchain"] != current["toolchain"]
    )


def derive_risk_fields(
    surfaces: list[dict[str, Any]],
    *,
    toolchain_delta: bool,
    runtime_capable_surface_ids: set[str],
    requires_placement_review: bool,
) -> tuple[list[str], dict[str, list[str]], list[str]]:
    if (
        not isinstance(surfaces, list)
        or type(toolchain_delta) is not bool
        or not isinstance(runtime_capable_surface_ids, set)
        or any(
            not isinstance(surface_id, str) or not surface_id
            for surface_id in runtime_capable_surface_ids
        )
        or type(requires_placement_review) is not bool
    ):
        _error("surface comparison risk inputs are invalid")
    for surface in surfaces:
        if (
            not isinstance(surface, dict)
            or not isinstance(surface.get("surfaceId"), str)
            or not surface["surfaceId"]
            or not isinstance(surface.get("reasonCodes"), list)
            or any(not isinstance(value, str) for value in surface["reasonCodes"])
            or not isinstance(surface.get("changes"), dict)
            or any(
                type(surface["changes"].get(change_key)) is not bool
                for change_key in RISK_CHANGE_KEYS.values()
            )
        ):
            _error("surface comparison risk inputs are invalid")
    risk_surfaces: dict[str, list[str]] = {
        "unmapped-surface": sorted(
            surface["surfaceId"]
            for surface in surfaces
            if "new-surface" in surface["reasonCodes"]
        )
    }
    if not risk_surfaces["unmapped-surface"]:
        risk_surfaces.pop("unmapped-surface")
    for risk_code, change_key in RISK_CHANGE_KEYS.items():
        affected = [
            surface["surfaceId"]
            for surface in surfaces
            if surface["changes"][change_key]
        ]
        if affected:
            risk_surfaces[risk_code] = sorted(affected)
    if toolchain_delta:
        affected = sorted(
            surface["surfaceId"]
            for surface in surfaces
            if surface["surfaceId"] in runtime_capable_surface_ids
        )
        if affected:
            risk_surfaces["toolchain-divergence"] = affected
    risk_codes = [code for code in RISK_CODES if code in risk_surfaces]
    observation_risk_codes: list[str] = (
        ["host-os-divergence"] if requires_placement_review else []
    )
    return (
        risk_codes,
        {code: risk_surfaces[code] for code in risk_codes},
        observation_risk_codes,
    )


def _validate_risk_surfaces(
    comparison: dict[str, Any],
    *,
    runtime_capable_surface_ids: set[str] | None,
) -> None:
    risk_codes = comparison["riskCodes"]
    if not isinstance(risk_codes, list) or any(
        not isinstance(value, str) for value in risk_codes
    ) or risk_codes != [code for code in RISK_CODES if code in risk_codes]:
        _error("surface comparison risk codes are not canonical")
    risk_surfaces = comparison["riskSurfaces"]
    if (
        not isinstance(risk_surfaces, dict)
        or set(risk_surfaces) != set(risk_codes)
        or list(risk_surfaces) != risk_codes
    ):
        _error("surface comparison risk surface map is invalid")
    surface_id_set = {surface["surfaceId"] for surface in comparison["surfaces"]}
    for risk_code in risk_codes:
        values = risk_surfaces[risk_code]
        if (
            not isinstance(values, list)
            or any(not isinstance(value, str) or not value for value in values)
            or values != sorted(set(values))
            or not set(values) <= surface_id_set
        ):
            _error("surface comparison risk surface map is not canonical")
    inferred_runtime_capable_surface_ids = {
        surface["surfaceId"]
        for surface in comparison["surfaces"]
        if "actual-runtime" in surface["carryForward"]
    }
    if (
        runtime_capable_surface_ids is not None
        and surface_id_set & runtime_capable_surface_ids
        != inferred_runtime_capable_surface_ids
    ):
        _error("surface comparison runtime capability set is inconsistent")
    expected_codes, expected_surfaces, _ = derive_risk_fields(
        comparison["surfaces"],
        toolchain_delta=comparison["toolchainChanged"],
        runtime_capable_surface_ids=inferred_runtime_capable_surface_ids,
        requires_placement_review=comparison["requiresPlacementReview"],
    )
    if risk_codes != expected_codes or risk_surfaces != expected_surfaces:
        _error("surface comparison risk surface map is inconsistent")


def validate_comparison_v4(
    comparison: object,
    *,
    runtime_capable_surface_ids: set[str] | None = None,
) -> dict[str, Any]:
    if not isinstance(comparison, dict) or set(comparison) != ROOT_KEYS:
        _error("surface comparison root keys are invalid")
    if type(comparison["schemaVersion"]) is not int or comparison[
        "schemaVersion"
    ] != CURRENT_COMPARISON_SCHEMA_VERSION:
        _error("surface comparison identity is invalid")
    v3 = {key: copy.deepcopy(comparison[key]) for key in V3_ROOT_KEYS}
    v3["schemaVersion"] = V3_COMPARISON_SCHEMA_VERSION
    validate_comparison_v3(v3)
    if not isinstance(comparison["toolchainChanged"], bool):
        _error("surface comparison toolchain flag is invalid")
    _validate_risk_surfaces(
        comparison,
        runtime_capable_surface_ids=runtime_capable_surface_ids,
    )
    observation_risk_codes = comparison["observationRiskCodes"]
    if observation_risk_codes not in ([], list(OBSERVATION_RISK_CODES)):
        _error("surface comparison observation risk codes are invalid")
    if comparison["requiresPlacementReview"] != bool(observation_risk_codes):
        _error("surface comparison observation risk codes are inconsistent")
    return comparison


def validate_current_comparison(
    comparison: object,
    *,
    runtime_capable_surface_ids: set[str] | None = None,
) -> dict[str, Any]:
    return validate_comparison_v4(
        comparison,
        runtime_capable_surface_ids=runtime_capable_surface_ids,
    )


def validate_legacy_v3_comparison_for_reconstruction(
    comparison: object,
) -> dict[str, Any]:
    return validate_comparison_v3(comparison)
