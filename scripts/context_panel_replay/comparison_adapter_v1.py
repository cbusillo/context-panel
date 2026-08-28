from __future__ import annotations

import hashlib
import inspect
import json
from typing import Any

import context_panel_comparison_schema as comparison_schema


ADAPTER_SCHEMA_VERSION = 1
V1_REPLAY_OUTPUT_IDENTITY = {
    "kind": "context-panel-surface-comparison",
    "schemaVersion": 2,
}
V1_ROOT_KEYS = comparison_schema.LEGACY_V1_ROOT_KEYS
ADAPTER_CONTRACT = {
    "adapterSchemaVersion": ADAPTER_SCHEMA_VERSION,
    "inputSchemaVersion": 1,
    "inputRootKeys": sorted(V1_ROOT_KEYS),
    "outputIdentity": V1_REPLAY_OUTPUT_IDENTITY,
    "validator": "context_panel_comparison_schema.validate_legacy_v1_comparison_for_reconstruction",
    "validatorOptions": {},
    "operation": "validate-frozen-v1-and-return-deep-copied-v2-reconstruction",
}
ADAPTER_CONTRACT_DIGEST = "b75a0eb0f30eac298f95c7b267c797427641612f3ae729c6a2e3e08345f2761e"
ADAPTER_IMPLEMENTATION_DIGEST = "27a8bd159bdb0763a54ac96a96eeb30dfcd332a821729b22405589b260228b42"
ADAPTER_DEPENDENCY_DIGEST = "520ad05b6654f9c112d60ceb638b89ff2a0f53c38dde84647a87dcc469db4032"


class ComparisonAdapterV1Error(RuntimeError):
    pass


def adapter_contract_digest() -> str:
    return hashlib.sha256(
        json.dumps(ADAPTER_CONTRACT, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def _source_digest(functions: tuple[object, ...]) -> str:
    try:
        source = "\n".join(inspect.getsource(function) for function in functions)
    except (OSError, TypeError) as error:
        raise ComparisonAdapterV1Error("retained v1 adapter source is unavailable") from error
    return hashlib.sha256(source.encode("utf-8")).hexdigest()


def _schema_dependency_contract() -> dict[str, object]:
    return {
        "comparisonKind": comparison_schema.COMPARISON_KIND,
        "currentSchemaVersion": comparison_schema.CURRENT_COMPARISON_SCHEMA_VERSION,
        "evidenceClasses": list(comparison_schema.EVIDENCE_CLASSES),
        "trainNames": list(comparison_schema.TRAIN_NAMES),
        "rootKeys": sorted(comparison_schema.ROOT_KEYS),
        "legacyV1RootKeys": sorted(comparison_schema.LEGACY_V1_ROOT_KEYS),
        "surfaceKeys": sorted(comparison_schema.SURFACE_KEYS),
        "changeKeys": sorted(comparison_schema.CHANGE_KEYS),
        "carryRuleKeys": sorted(comparison_schema.CARRY_RULE_KEYS),
        "reasonCodes": list(comparison_schema.REASON_CODES),
        "placementCarryConditions": list(comparison_schema.PLACEMENT_CARRY_CONDITIONS),
        "sha256Pattern": comparison_schema.SHA256_PATTERN.pattern,
        "sha256Flags": comparison_schema.SHA256_PATTERN.flags,
    }


def adapter_dependency_digest() -> str:
    dependency = {
        "constants": _schema_dependency_contract(),
        "sourceDigest": _source_digest(
            (
                comparison_schema.ComparisonSchemaError,
                comparison_schema._error,
                comparison_schema._is_sha256,
                comparison_schema._canonical_subset,
                comparison_schema._expected_reason_codes,
                comparison_schema.validate_comparison_v2,
                comparison_schema.validate_legacy_v1_comparison_for_reconstruction,
            )
        ),
    }
    return hashlib.sha256(
        json.dumps(dependency, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def adapter_implementation_digest() -> str:
    return _source_digest(
        (
            _source_digest,
            _schema_dependency_contract,
            adapter_contract_digest,
            adapter_dependency_digest,
            _verify_adapter_contract,
            adapt_v1_comparison,
        )
    )


def _verify_adapter_contract() -> None:
    if adapter_contract_digest() != ADAPTER_CONTRACT_DIGEST:
        raise ComparisonAdapterV1Error("retained v1 adapter contract digest is invalid")
    if adapter_implementation_digest() != ADAPTER_IMPLEMENTATION_DIGEST:
        raise ComparisonAdapterV1Error("retained v1 adapter implementation digest is invalid")
    if adapter_dependency_digest() != ADAPTER_DEPENDENCY_DIGEST:
        raise ComparisonAdapterV1Error("retained v1 adapter dependency digest is invalid")


def adapt_v1_comparison(comparison: object) -> dict[str, Any]:
    if (
        not isinstance(comparison, dict)
        or set(comparison) != V1_ROOT_KEYS
        or type(comparison.get("schemaVersion")) is not int
        or comparison.get("schemaVersion") != ADAPTER_CONTRACT["inputSchemaVersion"]
    ):
        raise ComparisonAdapterV1Error("retained v1 comparison contract is invalid")
    _verify_adapter_contract()
    try:
        return comparison_schema.validate_legacy_v1_comparison_for_reconstruction(comparison)
    except comparison_schema.ComparisonSchemaError as error:
        raise ComparisonAdapterV1Error("retained v1 comparison payload is invalid") from error
