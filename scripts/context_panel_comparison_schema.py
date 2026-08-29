from __future__ import annotations

import copy
import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, cast


def _load_artifact_comparison() -> ModuleType:
    path = (
        Path(__file__).with_name("context_panel_surface_manifest")
        / "artifact_comparison.py"
    )
    spec = importlib.util.spec_from_file_location(
        "context_panel_artifact_comparison", path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("artifact comparison policy is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _load_v4_schema() -> ModuleType:
    path = Path(__file__).with_name("context_panel_surface_manifest") / "comparison_schema_v4.py"
    spec = importlib.util.spec_from_file_location(
        "context_panel_surface_manifest.comparison_schema_v4", path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("frozen comparison schema v4 is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


comparison_schema_v4 = _load_v4_schema()
_v4 = comparison_schema_v4
artifact_comparison = _load_artifact_comparison()
comparison_schema_v3 = _v4.comparison_schema_v3
comparison_schema_v2 = _v4.comparison_schema_v2

COMPARISON_KIND = _v4.COMPARISON_KIND
V2_COMPARISON_SCHEMA_VERSION = _v4.V2_COMPARISON_SCHEMA_VERSION
V3_COMPARISON_SCHEMA_VERSION = _v4.V3_COMPARISON_SCHEMA_VERSION
V4_COMPARISON_SCHEMA_VERSION = _v4.CURRENT_COMPARISON_SCHEMA_VERSION
CURRENT_COMPARISON_SCHEMA_VERSION = 5
EVIDENCE_CLASSES = _v4.EVIDENCE_CLASSES
TRAIN_NAMES = _v4.TRAIN_NAMES
V3_ROOT_KEYS = _v4.V3_ROOT_KEYS
V4_ROOT_KEYS = _v4.ROOT_KEYS
ROOT_KEYS = V4_ROOT_KEYS | {
    "artifactEvidence",
    "artifactRiskCodes",
    "artifactRiskSurfaces",
    "escalationState",
}
SURFACE_KEYS = _v4.SURFACE_KEYS
CHANGE_KEYS = _v4.CHANGE_KEYS
CARRY_RULE_KEYS = _v4.CARRY_RULE_KEYS
REASON_CODES = _v4.REASON_CODES
RUNTIME_STATES = _v4.RUNTIME_STATES
RUNTIME_STATE_REASON_CODES = _v4.RUNTIME_STATE_REASON_CODES
PLACEMENT_CARRY_CONDITIONS = _v4.PLACEMENT_CARRY_CONDITIONS
SHA256_PATTERN = _v4.SHA256_PATTERN
LEGACY_V1_ROOT_KEYS = _v4.LEGACY_V1_ROOT_KEYS
LEGACY_V2_ROOT_KEYS = _v4.LEGACY_V2_ROOT_KEYS
LEGACY_V3_ROOT_KEYS = _v4.LEGACY_V3_ROOT_KEYS
ARTIFACT_RISK_CODES = artifact_comparison.ARTIFACT_RISK_CODES
artifact_runtime_escalation_surfaces = (
    artifact_comparison.artifact_runtime_escalation_surfaces
)
derive_artifact_comparison = artifact_comparison.derive_artifact_comparison
ARTIFACT_EVIDENCE_STATES = ("complete", "legacy-incomplete", "missing", "not-evaluated")
ESCALATION_STATES = ("resolved", "unknown-fail-closed")
ComparisonSchemaError = _v4.ComparisonSchemaError
validate_comparison_v2 = _v4.validate_comparison_v2
validate_comparison_v3 = _v4.validate_comparison_v3
validate_comparison_v4 = _v4.validate_comparison_v4
derive_runtime_decision = _v4.derive_runtime_decision
derive_risk_fields = _v4.derive_risk_fields
toolchain_changed = _v4.toolchain_changed
_expected_reason_codes = _v4._expected_reason_codes
validate_legacy_v1_comparison_for_reconstruction = _v4.validate_legacy_v1_comparison_for_reconstruction
validate_legacy_v2_comparison_for_reconstruction = _v4.validate_legacy_v2_comparison_for_reconstruction
validate_legacy_v3_comparison_for_reconstruction = _v4.validate_legacy_v3_comparison_for_reconstruction


def _error(message: str) -> None:
    raise ComparisonSchemaError(message)


def _validate_artifact_fields(comparison: dict[str, Any]) -> None:
    evidence = comparison["artifactEvidence"]
    if not isinstance(evidence, dict) or set(evidence) != {
        "previousState", "currentState", "previousExpectedBuildIds", "currentExpectedBuildIds"
    }:
        _error("surface comparison artifact evidence is invalid")
    for key in ("previousState", "currentState"):
        if evidence[key] not in ARTIFACT_EVIDENCE_STATES:
            _error("surface comparison artifact evidence is invalid")
    for key in ("previousExpectedBuildIds", "currentExpectedBuildIds"):
        values = evidence[key]
        if not isinstance(values, list) or values != sorted(set(values)) or any(
            not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None
            for value in values
        ):
            _error("surface comparison artifact evidence is not canonical")
        state_key = "previousState" if key.startswith("previous") else "currentState"
        state = evidence[state_key]
        if (state == "not-evaluated" and values) or (
            state in {"complete", "legacy-incomplete"} and not values
        ):
            _error("surface comparison artifact evidence identity is inconsistent")
    codes = comparison["artifactRiskCodes"]
    if not isinstance(codes, list) or codes != [code for code in ARTIFACT_RISK_CODES if code in codes]:
        _error("surface comparison artifact risk codes are not canonical")
    surfaces = comparison["artifactRiskSurfaces"]
    known_surfaces = {item["surfaceId"] for item in comparison["surfaces"]}
    if not isinstance(surfaces, dict) or list(surfaces) != codes:
        _error("surface comparison artifact risk surface map is invalid")
    for code in codes:
        values = surfaces[code]
        if not isinstance(values, list) or values != sorted(set(values)) or any(
            not isinstance(value, str) or value not in known_surfaces for value in values
        ) or not values:
            _error("surface comparison artifact risk surface map is not canonical")
    unknown = "artifact-evidence-unknown" in codes
    if comparison["escalationState"] not in ESCALATION_STATES or (
        comparison["escalationState"] == "unknown-fail-closed"
    ) != unknown:
        _error("surface comparison artifact escalation state is invalid")
    evidence_complete = evidence["previousState"] == evidence["currentState"] == "complete"
    evidence_not_evaluated = (
        evidence["previousState"] == evidence["currentState"] == "not-evaluated"
    )
    runtime_surfaces = sorted(
        item["surfaceId"]
        for item in comparison["surfaces"]
        if "actual-runtime" in item["carryForward"]
    )
    if evidence_complete:
        if unknown:
            _error("surface comparison complete artifact evidence is inconsistent")
    elif evidence_not_evaluated:
        if codes or surfaces or comparison["escalationState"] != "resolved":
            _error("surface comparison unevaluated artifact evidence is inconsistent")
    elif runtime_surfaces and (
        codes != ["artifact-evidence-unknown"]
        or surfaces != {"artifact-evidence-unknown": runtime_surfaces}
    ):
        _error("surface comparison incomplete artifact evidence is not fail-closed")
    elif not runtime_surfaces and (
        codes or surfaces or comparison["escalationState"] != "resolved"
    ):
        _error("surface comparison inapplicable artifact evidence is inconsistent")
    artifact_runtime = artifact_runtime_escalation_surfaces(
        train=comparison["train"],
        artifact_risk_surfaces=surfaces,
        runtime_capable_surface_ids=set(runtime_surfaces),
    )
    if artifact_runtime:
        required_runtime = set(comparison["requiredSurfaces"]["actual-runtime"])
        if not artifact_runtime <= required_runtime:
            _error("surface comparison artifact risk is not fail-closed")
        by_surface = {
            item["surfaceId"]: item for item in comparison["surfaces"]
        }
        for surface_id in artifact_runtime:
            surface = by_surface[surface_id]
            if (
                "actual-runtime" not in surface["freshEvidence"]
                or "actual-runtime" not in surface["requiredEvidence"]
                or surface["carryForward"].get("actual-runtime")
                != {"eligible": False, "conditions": []}
            ):
                _error("surface comparison artifact risk is not fail-closed")


def validate_comparison_v5(
    comparison: object,
    *,
    runtime_capable_surface_ids: set[str] | None = None,
) -> dict[str, Any]:
    if not isinstance(comparison, dict) or set(comparison) != ROOT_KEYS:
        _error("surface comparison root keys are invalid")
    payload = cast(dict[str, Any], comparison)
    if payload.get("schemaVersion") != CURRENT_COMPARISON_SCHEMA_VERSION:
        _error("surface comparison identity is invalid")
    v4 = {key: copy.deepcopy(payload[key]) for key in V4_ROOT_KEYS}
    v4["schemaVersion"] = V4_COMPARISON_SCHEMA_VERSION
    validate_comparison_v4(v4, runtime_capable_surface_ids=runtime_capable_surface_ids)
    _validate_artifact_fields(payload)
    return payload


def validate_current_comparison(
    comparison: object,
    *,
    runtime_capable_surface_ids: set[str] | None = None,
) -> dict[str, Any]:
    return validate_comparison_v5(
        comparison, runtime_capable_surface_ids=runtime_capable_surface_ids
    )
