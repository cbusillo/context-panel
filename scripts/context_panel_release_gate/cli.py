from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

from context_panel_validation.runtime_evidence import (
    RUNTIME_SURFACES,
    load_expected_surface_identities,
)

from .core import ReleaseEvidenceError, evaluate_release_evidence, load_json_object


DEFAULT_POLICY = Path("Config/ContextPanelReleaseEvidencePolicy.json")
DEFAULT_SURFACE_POLICY = Path("Config/ContextPanelSurfacePolicy.json")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Evaluate Context Panel evidence carry-forward for one release train."
    )
    parser.add_argument("mode", choices=("shadow", "enforce"))
    parser.add_argument("--train", required=True, choices=("beta", "rc", "release"))
    parser.add_argument("--comparison", type=Path, required=True)
    parser.add_argument("--validation-report", type=Path, required=True)
    parser.add_argument(
        "--expected-build-manifest",
        dest="expected_build_manifests",
        type=Path,
        action="append",
        required=True,
    )
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--surface-policy", type=Path, default=DEFAULT_SURFACE_POLICY)
    parser.add_argument("--previous-ledger", type=Path)
    parser.add_argument("--selected-rc-ledger", type=Path)
    parser.add_argument("--host-os-evidence", type=Path)
    parser.add_argument("--shadow-evidence", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--now", help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def _optional_payload(path: Path | None, label: str) -> dict[str, object] | None:
    return load_json_object(path, label) if path is not None else None


def run(argv: list[str] | None = None) -> int:
    arguments = parse_args(argv)
    comparison = load_json_object(arguments.comparison, "surface comparison")
    report = load_json_object(arguments.validation_report, "validation report")
    policy = load_json_object(arguments.policy, "release evidence policy")
    surface_policy = load_json_object(arguments.surface_policy, "surface evidence policy")
    target_payload = report.get("target")
    if not isinstance(target_payload, dict):
        raise ReleaseEvidenceError("validation report target is invalid")
    from context_panel_validation.models import Target

    target = Target(target_payload.get("version"), target_payload.get("buildNumber"))
    required = comparison.get("requiredSurfaces")
    if not isinstance(required, dict):
        raise ReleaseEvidenceError("surface comparison requirements are invalid")
    identities = load_expected_surface_identities(
        arguments.expected_build_manifests,
        target,
        tuple(RUNTIME_SURFACES),
    )
    now = None
    if arguments.now:
        normalized = arguments.now.replace("Z", "+00:00")
        now = datetime.fromisoformat(normalized).astimezone(timezone.utc)
    payload = evaluate_release_evidence(
        train=arguments.train,
        mode=arguments.mode,
        comparison=comparison,
        validation_report=report,
        identities=identities,
        policy=policy,
        surface_policy=surface_policy,
        previous_ledger=_optional_payload(arguments.previous_ledger, "previous ledger"),
        selected_rc_ledger=_optional_payload(arguments.selected_rc_ledger, "selected RC ledger"),
        host_os_evidence=_optional_payload(arguments.host_os_evidence, "host OS evidence"),
        shadow_evidence=_optional_payload(arguments.shadow_evidence, "shadow evidence"),
        now=now,
    )
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if arguments.output is not None:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(rendered)
    else:
        sys.stdout.write(rendered)
    if arguments.mode == "enforce" and payload["state"] != "approved":
        return 20
    return 0


def main() -> None:
    try:
        raise SystemExit(run())
    except ReleaseEvidenceError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(20) from error


if __name__ == "__main__":
    main()
