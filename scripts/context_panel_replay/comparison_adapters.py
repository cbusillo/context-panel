from __future__ import annotations

from typing import Any

from context_panel_comparison_schema import CURRENT_COMPARISON_SCHEMA_VERSION, validate_current_comparison

from .comparison_adapter_v1 import ComparisonAdapterV1Error, adapt_v1_comparison


class ComparisonAdapterError(RuntimeError):
    pass


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
    if schema_version == CURRENT_COMPARISON_SCHEMA_VERSION:
        try:
            return validate_current_comparison(comparison)
        except RuntimeError as error:
            raise ComparisonAdapterError("retained current comparison is invalid") from error
    raise ComparisonAdapterError("retained comparison schema is unsupported")
