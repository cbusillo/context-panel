#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

from context_panel_comparison_schema import ComparisonSchemaError, validate_current_comparison
from context_panel_release_gate import (
    ReleaseEvidenceError,
    load_json_object,
    release_evidence_report_blockers,
)
from context_panel_validation import (
    RUNTIME_SURFACES,
    RuntimeEvidenceError,
    Target,
)
from context_panel_validation.runtime_evidence import expected_surface_identities_from_payloads


DEFAULT_POLICY = Path("Config/ContextPanelReleaseEvidencePolicy.json")
DEFAULT_SURFACE_POLICY = Path("Config/ContextPanelSurfacePolicy.json")


def optional_payload(path: Path | None, label: str):
    return load_json_object(path, label) if path is not None else None


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate a Context Panel release evidence report."
    )
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--train", required=True, choices=("beta", "rc", "release"))
    parser.add_argument("--enforce", action="store_true")
    parser.add_argument("--validation-report", type=Path, required=True)
    parser.add_argument("--comparison", type=Path, required=True)
    parser.add_argument(
        "--expected-build-manifest",
        dest="expected_build_manifests",
        type=Path,
        action="append",
        required=True,
    )
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--surface-policy", type=Path, default=DEFAULT_SURFACE_POLICY)
    parser.add_argument(
        "--previous-ledger",
        type=Path,
        help="Replayable lineage bundle for the prior approved ledger.",
    )
    parser.add_argument(
        "--selected-rc-ledger",
        type=Path,
        help="Replayable lineage bundle for the exact approved RC ledger.",
    )
    parser.add_argument("--host-os-evidence", type=Path)
    parser.add_argument("--shadow-evidence", type=Path)
    arguments = parser.parse_args()
    try:
        payload = json.loads(arguments.report.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"release evidence report is unavailable or invalid: {error}") from error
    try:
        validation_payload = load_json_object(arguments.validation_report, "validation report")
        comparison = load_json_object(arguments.comparison, "surface comparison")
        validate_current_comparison(comparison)
        policy = load_json_object(arguments.policy, "release evidence policy")
        surface_policy = load_json_object(
            arguments.surface_policy,
            "surface evidence policy",
        )
        expected_build_manifests = tuple(
            load_json_object(path, "expected signed build manifest")
            for path in arguments.expected_build_manifests
        )
        identities = expected_surface_identities_from_payloads(
            list(expected_build_manifests),
            Target(arguments.version, arguments.build_number),
            tuple(RUNTIME_SURFACES),
        )
    except (ComparisonSchemaError, ReleaseEvidenceError, RuntimeEvidenceError) as error:
        raise SystemExit(f"release evidence binding is invalid: {error}") from error
    blockers = release_evidence_report_blockers(
        payload,
        version=arguments.version,
        build_number=arguments.build_number,
        train=arguments.train,
        enforce=arguments.enforce,
        validation_report=validation_payload,
        comparison=comparison,
        identities=identities,
        expected_build_manifests=expected_build_manifests,
        policy=policy,
        surface_policy=surface_policy,
        previous_ledger=optional_payload(arguments.previous_ledger, "previous ledger"),
        selected_rc_ledger=optional_payload(
            arguments.selected_rc_ledger,
            "selected RC ledger",
        ),
        host_os_evidence=optional_payload(arguments.host_os_evidence, "host OS evidence"),
        shadow_evidence=optional_payload(arguments.shadow_evidence, "shadow evidence"),
    )
    if blockers:
        details = "\n".join(f"- {blocker}" for blocker in blockers)
        raise SystemExit(f"release evidence report rejected:\n{details}")
    mode = "enforced" if arguments.enforce else "shadow"
    print(
        f"Accepted {mode} release evidence report for {arguments.train} "
        f"{arguments.version} ({arguments.build_number})"
    )


if __name__ == "__main__":
    main()
