from __future__ import annotations

from typing import Any

from context_panel_comparison_schema import (
    CURRENT_COMPARISON_SCHEMA_VERSION,
    comparison_schema_v2,
    comparison_schema_v3,
    comparison_schema_v4,
    validate_current_comparison,
)

from .comparison_adapter_v1 import ComparisonAdapterV1Error, adapt_v1_comparison


class ComparisonAdapterError(RuntimeError):
    pass


V2_COMPARISON_SCHEMA_VERSION = comparison_schema_v2.CURRENT_COMPARISON_SCHEMA_VERSION
V3_COMPARISON_SCHEMA_VERSION = comparison_schema_v3.CURRENT_COMPARISON_SCHEMA_VERSION
V4_COMPARISON_SCHEMA_VERSION = comparison_schema_v4.CURRENT_COMPARISON_SCHEMA_VERSION
validate_comparison_v2 = comparison_schema_v2.validate_comparison_v2
validate_comparison_v3 = comparison_schema_v3.validate_comparison_v3
validate_comparison_v4 = comparison_schema_v4.validate_comparison_v4


def adapt_comparison_for_replay(comparison: object) -> dict[str, Any]:
    if not isinstance(comparison, dict):
        raise ComparisonAdapterError("retained comparison is invalid")
    schema_version = comparison.get("schemaVersion")
    if type(schema_version) is not int:
        raise ComparisonAdapterError("retained comparison schema is unsupported")
    if schema_version == 1:
        try:
            return adapt_v1_comparison(comparison)
        except ComparisonAdapterV1Error as error:
            raise ComparisonAdapterError("retained v1 comparison is invalid") from error
    if schema_version == V2_COMPARISON_SCHEMA_VERSION:
        try:
            return validate_comparison_v2(comparison)
        except RuntimeError as error:
            raise ComparisonAdapterError("retained v2 comparison is invalid") from error
    if schema_version == V3_COMPARISON_SCHEMA_VERSION:
        try:
            return validate_comparison_v3(comparison)
        except RuntimeError as error:
            raise ComparisonAdapterError("retained v3 comparison is invalid") from error
    if schema_version == V4_COMPARISON_SCHEMA_VERSION:
        try:
            return validate_comparison_v4(comparison)
        except RuntimeError as error:
            raise ComparisonAdapterError("retained v4 comparison is invalid") from error
    if schema_version == CURRENT_COMPARISON_SCHEMA_VERSION:
        try:
            return validate_current_comparison(comparison)
        except RuntimeError as error:
            raise ComparisonAdapterError("retained current comparison is invalid") from error
    raise ComparisonAdapterError("retained comparison schema is unsupported")
