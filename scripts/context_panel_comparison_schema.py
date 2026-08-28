from __future__ import annotations

import copy
import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, Callable, NoReturn


def _load_v2_schema() -> ModuleType:
    path = Path(__file__).with_name("context_panel_surface_manifest") / "comparison_schema_v2.py"
    spec = importlib.util.spec_from_file_location("context_panel_comparison_schema_v2", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("frozen comparison schema v2 is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.modules["context_panel_surface_manifest.comparison_schema_v2"] = module
    spec.loader.exec_module(module)
    return module


comparison_schema_v2 = _load_v2_schema()
_v2 = comparison_schema_v2


COMPARISON_KIND = _v2.COMPARISON_KIND
V2_COMPARISON_SCHEMA_VERSION = _v2.CURRENT_COMPARISON_SCHEMA_VERSION
CURRENT_COMPARISON_SCHEMA_VERSION = 3
EVIDENCE_CLASSES = _v2.EVIDENCE_CLASSES
TRAIN_NAMES = _v2.TRAIN_NAMES
V2_ROOT_KEYS = _v2.ROOT_KEYS
ROOT_KEYS = V2_ROOT_KEYS | {"runtimeState", "runtimeStateReasons"}
SURFACE_KEYS = _v2.SURFACE_KEYS
CHANGE_KEYS = _v2.CHANGE_KEYS
CARRY_RULE_KEYS = _v2.CARRY_RULE_KEYS
REASON_CODES = _v2.REASON_CODES
RUNTIME_STATES = (
    "required-with-session",
    "not-required-no-session",
    "unknown-fail-closed",
)
RUNTIME_STATE_REASON_CODES = (
    "train-minimum-required",
    "new-surface",
    "runtime-fingerprint-changed",
    "placement-fingerprint-changed",
    "contract-fingerprint-changed",
    "exact-build-changed",
)
UNKNOWN_RUNTIME_REASON_CODES = frozenset(
    {"new-surface", "contract-fingerprint-changed"}
)
PLACEMENT_CARRY_CONDITIONS = _v2.PLACEMENT_CARRY_CONDITIONS
SHA256_PATTERN = _v2.SHA256_PATTERN
LEGACY_V1_ROOT_KEYS = _v2.LEGACY_V1_ROOT_KEYS
ComparisonSchemaError = _v2.ComparisonSchemaError
_error: Callable[[str], NoReturn] = getattr(_v2, "_error")
_is_sha256 = getattr(_v2, "_is_sha256")
_canonical_subset = getattr(_v2, "_canonical_subset")
_expected_reason_codes = getattr(_v2, "_expected_reason_codes")
validate_comparison_v2 = _v2.validate_comparison_v2
validate_legacy_v1_comparison_for_reconstruction = (
    _v2.validate_legacy_v1_comparison_for_reconstruction
)


def derive_runtime_decision(surfaces: list[dict[str, Any]]) -> tuple[str, list[str]]:
    reasons: set[str] = set()
    has_runtime = False
    unknown = False
    for surface in surfaces:
        required = surface.get("requiredEvidence")
        minimum = surface.get("minimumEvidence")
        fresh = surface.get("freshEvidence")
        reason_codes = surface.get("reasonCodes")
        if not all(isinstance(value, list) for value in (required, minimum, fresh, reason_codes)):
            _error("surface comparison runtime decision inputs are invalid")
        if "actual-runtime" not in required:
            continue
        has_runtime = True
        if "actual-runtime" in minimum:
            reasons.add("train-minimum-required")
        if "actual-runtime" in fresh:
            reasons.update(
                reason
                for reason in reason_codes
                if reason in RUNTIME_STATE_REASON_CODES
            )
        if UNKNOWN_RUNTIME_REASON_CODES.intersection(reason_codes):
            unknown = True
    state = (
        "unknown-fail-closed"
        if unknown
        else "required-with-session"
        if has_runtime
        else "not-required-no-session"
    )
    return state, [reason for reason in RUNTIME_STATE_REASON_CODES if reason in reasons]


def validate_comparison_v3(comparison: object) -> dict[str, Any]:
    if not isinstance(comparison, dict) or set(comparison) != ROOT_KEYS:
        _error("surface comparison root keys are invalid")
    validated = comparison
    if type(validated["schemaVersion"]) is not int or validated[
        "schemaVersion"
    ] != CURRENT_COMPARISON_SCHEMA_VERSION:
        _error("surface comparison identity is invalid")
    v2 = {key: copy.deepcopy(validated[key]) for key in V2_ROOT_KEYS}
    v2["schemaVersion"] = V2_COMPARISON_SCHEMA_VERSION
    validate_comparison_v2(v2)
    state, reasons = derive_runtime_decision(v2["surfaces"])
    if validated["runtimeState"] != state:
        _error("surface comparison runtime state is inconsistent")
    if validated["runtimeStateReasons"] != reasons:
        _error("surface comparison runtime state reasons are inconsistent")
    if validated["requiresRuntimeSession"] != (
        state != "not-required-no-session"
    ):
        _error("surface comparison runtime state contradicts session requirement")
    return validated


def validate_current_comparison(comparison: object) -> dict[str, Any]:
    return validate_comparison_v3(comparison)


def validate_legacy_v2_comparison_for_reconstruction(
    comparison: object,
) -> dict[str, Any]:
    return validate_comparison_v2(comparison)
