from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from .inventory import InventoryError, load_json, parse_root_bindings
from .replay import (
    ReplayError,
    build_report,
    check_replay,
    release_gate_diagnostics,
    reconstruct_bundle,
    verify_replay,
    write_json,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INVENTORY_POLICY = REPO_ROOT / "Config/ContextPanelReplayInventoryPolicy.json"
DEFAULT_INVENTORY = Path(__file__).resolve().parent / "inventory/signed-trains.json"
DEFAULT_RELEASE_POLICY = REPO_ROOT / "Config/ContextPanelReleaseEvidencePolicy.json"
DEFAULT_SURFACE_POLICY = REPO_ROOT / "Config/ContextPanelSurfacePolicy.json"
DEFAULT_BUNDLE = Path(__file__).resolve().parent / "replay/signed-trains-bundle.json"
DEFAULT_REPORT = Path(__file__).resolve().parent / "replay/signed-trains-report.json"


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--inventory-policy", type=Path, default=DEFAULT_INVENTORY_POLICY)
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--release-policy", type=Path, default=DEFAULT_RELEASE_POLICY)
    parser.add_argument("--surface-policy", type=Path, default=DEFAULT_SURFACE_POLICY)
    parser.add_argument("--bundle", type=Path, default=DEFAULT_BUNDLE)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--json", action="store_true")


def _roots(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--root",
        action="append",
        default=[],
        metavar="ROOT_ID=ABSOLUTE_PATH",
        help="Bind every symbolic inventory root to an explicit private path.",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Reconstruct and check the public-safe signed-train replay bundle."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    reconstruct = subparsers.add_parser(
        "reconstruct", help="Tier B: reconstruct and write bundle plus report."
    )
    _common(reconstruct)
    _roots(reconstruct)
    verify = subparsers.add_parser(
        "verify", help="Tier B: require retained roots to match committed artifacts."
    )
    _common(verify)
    _roots(verify)
    check = subparsers.add_parser(
        "check", help="Tier A: validate bundle and regenerate report offline."
    )
    _common(check)
    diagnostics = subparsers.add_parser(
        "diagnostics", help="Create a post-gate diagnostics sidecar from canonical replay."
    )
    _common(diagnostics)
    diagnostics.add_argument("--release-evidence", type=Path, required=True)
    diagnostics.add_argument("--output", type=Path, required=True)
    return parser


def _summary(report: dict[str, object]) -> dict[str, object]:
    return {
        "state": report.get("sourceState"),
        "reportId": report.get("reportId"),
        "summary": report.get("summary"),
    }


def _reject_collisions(inputs: list[Path], outputs: list[Path]) -> None:
    resolved_inputs = {path.resolve() for path in inputs}
    resolved_outputs = [path.resolve() for path in outputs]
    if len(resolved_outputs) != len(set(resolved_outputs)) or resolved_inputs.intersection(
        resolved_outputs
    ):
        raise ReplayError("replay inputs and outputs must use distinct paths")


def _reject_root_outputs(roots: dict[str, Path], outputs: list[Path]) -> None:
    for output in outputs:
        for root in roots.values():
            try:
                output.resolve().relative_to(root.resolve())
            except ValueError:
                continue
            raise ReplayError("replay outputs must be outside retained source roots")


def run(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    common_inputs = [
        arguments.inventory_policy,
        arguments.inventory,
        arguments.release_policy,
        arguments.surface_policy,
        arguments.bundle,
        arguments.report,
    ]
    if arguments.command == "reconstruct":
        _reject_collisions(common_inputs[:-2], [arguments.bundle, arguments.report])
    elif arguments.command == "diagnostics":
        _reject_collisions(common_inputs + [arguments.release_evidence], [arguments.output])
    if arguments.command in {"check", "diagnostics"}:
        report = check_replay(
            inventory_policy_path=arguments.inventory_policy,
            inventory_path=arguments.inventory,
            release_policy_path=arguments.release_policy,
            surface_policy_path=arguments.surface_policy,
            bundle_path=arguments.bundle,
            report_path=arguments.report,
        )
        if arguments.command == "diagnostics":
            try:
                release_evidence = load_json(arguments.release_evidence, "release evidence ledger")
            except InventoryError as error:
                raise ReplayError(str(error)) from error
            diagnostics = release_gate_diagnostics(report, release_evidence)
            write_json(diagnostics, arguments.output)
            result = {
                "state": diagnostics["sourceState"],
                "diagnosticsId": diagnostics["diagnosticsId"],
                "residualRiskCount": len(diagnostics["residualRisks"]),
            }
    else:
        try:
            roots = parse_root_bindings(arguments.root)
        except InventoryError as error:
            raise ReplayError(str(error)) from error
        if arguments.command == "reconstruct":
            _reject_root_outputs(roots, [arguments.bundle, arguments.report])
        if arguments.command == "verify":
            report = verify_replay(
                inventory_policy_path=arguments.inventory_policy,
                inventory_path=arguments.inventory,
                release_policy_path=arguments.release_policy,
                surface_policy_path=arguments.surface_policy,
                bundle_path=arguments.bundle,
                report_path=arguments.report,
                root_bindings=roots,
            )
        else:
            bundle = reconstruct_bundle(
                inventory_policy_path=arguments.inventory_policy,
                inventory_path=arguments.inventory,
                release_policy_path=arguments.release_policy,
                surface_policy_path=arguments.surface_policy,
                root_bindings=roots,
            )
            report = build_report(bundle)
            write_json(bundle, arguments.bundle)
            write_json(report, arguments.report)
    if arguments.command != "diagnostics":
        result = _summary(report)
    if arguments.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    elif arguments.command == "diagnostics":
        print(
            "signed-train replay diagnostics OK: "
            f"{result['residualRiskCount']} residual risks"
        )
    else:
        summary = result["summary"] or {}
        print(
            "signed-train replay OK: "
            f"{summary.get('trainCount', 0)} trains, "
            f"{summary.get('surfaceCount', 0)} train-surfaces, "
            f"{summary.get('residualRiskCount', 0)} residual risks"
        )
    return 0


def main() -> int:
    try:
        return run()
    except ReplayError as error:
        print(f"error: {error}", file=sys.stderr)
        return 20
