#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

from context_panel_release_gate import (
    ReleaseEvidenceError,
    load_json_object,
    release_evidence_report_blockers,
)
from context_panel_validation import RuntimeEvidenceError, Target, load_expected_surface_identities


DEFAULT_POLICY = Path("Config/ContextPanelReleaseEvidencePolicy.json")


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
    arguments = parser.parse_args()
    try:
        payload = json.loads(arguments.report.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"release evidence report is unavailable or invalid: {error}") from error
    try:
        validation_payload = load_json_object(arguments.validation_report, "validation report")
        comparison = load_json_object(arguments.comparison, "surface comparison")
        policy = load_json_object(arguments.policy, "release evidence policy")
        required = comparison.get("requiredSurfaces")
        if not isinstance(required, dict):
            raise ReleaseEvidenceError("surface comparison requirements are invalid")
        required_scope = tuple(
            sorted(
                {
                    surface
                    for surfaces in required.values()
                    if isinstance(surfaces, list)
                    for surface in surfaces
                    if isinstance(surface, str)
                }
            )
        )
        identities = load_expected_surface_identities(
            arguments.expected_build_manifests,
            Target(arguments.version, arguments.build_number),
            required_scope,
        )
    except (ReleaseEvidenceError, RuntimeEvidenceError) as error:
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
        policy=policy,
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
