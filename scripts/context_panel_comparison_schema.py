from __future__ import annotations

import copy
import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, cast


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
ARTIFACT_EVIDENCE_STATES = ("complete", "legacy-incomplete", "missing", "not-evaluated")
ESCALATION_STATES = ("resolved", "unknown-fail-closed")
ARTIFACT_RISK_CODES = (
    "artifact-mapping-changed",
    "bundle-contract-changed",
    "signing-contract-changed",
    "entitlement-contract-changed",
    "profile-capability-changed",
    "architecture-loss",
    "unexplained-executable-drift",
    "artifact-evidence-unknown",
)
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
        ):
            _error("surface comparison artifact risk surface map is not canonical")
    unknown = "artifact-evidence-unknown" in codes
    if comparison["escalationState"] not in ESCALATION_STATES or (
        comparison["escalationState"] == "unknown-fail-closed"
    ) != unknown:
        _error("surface comparison artifact escalation state is invalid")
    if evidence["previousState"] == evidence["currentState"] == "not-evaluated" and (
        codes or comparison["escalationState"] != "resolved"
    ):
        _error("surface comparison unevaluated artifact evidence is invalid")


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
    if isinstance(comparison, dict) and comparison.get("schemaVersion") == V4_COMPARISON_SCHEMA_VERSION:
        return validate_comparison_v4(
            comparison, runtime_capable_surface_ids=runtime_capable_surface_ids
        )
    return validate_comparison_v5(
        comparison, runtime_capable_surface_ids=runtime_capable_surface_ids
    )
