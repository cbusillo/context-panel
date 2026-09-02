#!/usr/bin/env python3
"""Fail-closed helpers for the hosted shared-view evidence workflow."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import stat
import sys
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_comparison_schema import ComparisonSchemaError, validate_current_comparison
from context_panel_validation.shared_view_capture import (
    CAPTURE_CONFIG_KIND,
    CAPTURE_CONFIG_SCHEMA_VERSION,
    CAPTURE_RECEIPT_KIND,
    SIMULATOR_CAPTURE_PROFILES,
)
from context_panel_validation.shared_view_evidence import (
    SharedViewEvidenceError,
    load_surface_policy,
    merge_shared_view_requirements,
    plan_shared_view_evidence,
    load_shared_view_matrix,
)


FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
RUN_ID = re.compile(r"^[1-9][0-9]{0,18}$")
EXPECTED_BUILD_ID = re.compile(r"^[0-9a-f]{64}$")
MAX_ARTIFACT_FILES = 256
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
SUPPORTED_CAPTURE_SURFACES = ("ios", "ipados", "visionos", "watchos")
UNSUPPORTED_CAPTURE_SURFACES = ("macos", "tvos")


class WorkflowEvidenceError(ValueError):
    pass


def _read_json(path: Path, label: str, maximum_bytes: int = MAX_MANIFEST_BYTES) -> dict[str, Any]:
    try:
        path_stat = path.lstat()
        if not stat.S_ISREG(path_stat.st_mode) or path_stat.st_size <= 0 or path_stat.st_size > maximum_bytes:
            raise WorkflowEvidenceError(f"{label} is invalid")
        with path.open("rb") as stream:
            payload = json.loads(stream.read())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise WorkflowEvidenceError(f"{label} is invalid") from error
    if not isinstance(payload, dict):
        raise WorkflowEvidenceError(f"{label} is invalid")
    return payload


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _require_full_sha(value: str, label: str) -> str:
    if FULL_SHA.fullmatch(value) is None:
        raise WorkflowEvidenceError(f"{label} must be a full lowercase SHA")
    return value


def _require_run_id(value: str) -> str:
    if RUN_ID.fullmatch(value) is None:
        raise WorkflowEvidenceError("artifact run ID is invalid")
    return value


def validate_artifact_manifest(
    artifact_root: Path,
    *,
    layout: str,
    requested_source_commit: str,
    requested_version: str,
    requested_build: str,
    run_id: str,
    run_source_commit: str,
    artifacts_metadata: Path,
    artifact_name: str,
) -> Path:
    """Validate the sole unexpired expected-build manifest downloaded for one run."""
    _require_full_sha(requested_source_commit, "requested source commit")
    _require_full_sha(run_source_commit, "artifact run source commit")
    _require_run_id(run_id)
    if requested_source_commit != run_source_commit:
        raise WorkflowEvidenceError("artifact run source commit does not match the requested source")
    if not artifact_root.is_dir() or artifact_root.is_symlink():
        raise WorkflowEvidenceError("artifact directory is invalid")
    artifact_files = list(artifact_root.rglob("*"))
    if len(artifact_files) > MAX_ARTIFACT_FILES or any(path.is_symlink() for path in artifact_files):
        raise WorkflowEvidenceError("artifact directory exceeds its safety bound")
    metadata = _read_json(artifacts_metadata, "artifact metadata")
    artifacts = metadata.get("artifacts")
    matching_artifacts = [
        item
        for item in artifacts
        if isinstance(item, dict) and item.get("name") == artifact_name
    ] if isinstance(artifacts, list) else []
    if len(matching_artifacts) != 1 or matching_artifacts[0].get("expired") is not False:
        raise WorkflowEvidenceError("requested expected-build artifact is unavailable or expired")
    candidates: list[Path] = []
    for candidate in artifact_root.rglob(f"ExpectedBuildManifest-{layout}.json"):
        try:
            candidate.relative_to(artifact_root)
        except ValueError as error:
            raise WorkflowEvidenceError("artifact manifest escapes its directory") from error
        if candidate.is_symlink():
            raise WorkflowEvidenceError("artifact manifest is invalid")
        candidates.append(candidate)
    if len(candidates) != 1:
        raise WorkflowEvidenceError("artifact run must contain exactly one requested expected-build manifest")
    manifest = _read_json(candidates[0], "expected-build manifest")
    source = manifest.get("source")
    if (
        manifest.get("schemaVersion") != 2
        or manifest.get("kind") != "context-panel-expected-signed-build"
        or manifest.get("layout") != layout
        or not isinstance(source, dict)
        or source.get("commit") != requested_source_commit
        or source.get("marketingVersion") != requested_version
        or source.get("buildNumber") != requested_build
        or source.get("configuration") != "Release"
        or source.get("treeState") != "clean"
        or not isinstance(manifest.get("expectedBuildId"), str)
        or EXPECTED_BUILD_ID.fullmatch(manifest["expectedBuildId"]) is None
    ):
        raise WorkflowEvidenceError("expected-build manifest does not bind the requested identity")
    return candidates[0]


def placement_base(comparison: dict[str, Any], policy_path: Path) -> dict[str, Any]:
    """Create one generic placement requirement per fresh placement surface."""
    try:
        validated = validate_current_comparison(comparison)
    except ComparisonSchemaError as error:
        raise WorkflowEvidenceError("surface comparison is invalid") from error
    policy = {surface.id: surface for surface in load_surface_policy(policy_path)}
    requirements: list[dict[str, Any]] = []
    for surface in validated["surfaces"]:
        if "os-composited-placement" not in surface["freshEvidence"]:
            continue
        policy_surface = policy.get(surface["surfaceId"])
        if policy_surface is None or "os-composited-placement" not in policy_surface.evidence_capabilities:
            raise WorkflowEvidenceError("fresh placement surface is outside the policy")
        requirements.append(
            {
                "id": f"placement.{policy_surface.id.replace('.', '-')}.default",
                "evidenceClass": "os-composited-placement",
                "surface": policy_surface.id,
                "fixtureContractID": None,
                "presentation": None,
                "appearance": "default",
                "accessibility": "default",
                "hostOS": policy_surface.platform,
                "presentationFamily": "system-managed",
                "placementHost": policy_surface.device_class,
            }
        )
    return {
        "schemaVersion": 1,
        "kind": "context-panel-visual-review-requirements",
        "currentManifestID": validated["currentManifestId"],
        "requirements": requirements,
    }


def combined_visual_plan(comparison_path: Path, policy_path: Path) -> dict[str, Any]:
    comparison = _read_json(comparison_path, "surface comparison")
    base = placement_base(comparison, policy_path)
    matrix = load_shared_view_matrix(REPO_ROOT / "Config" / "ContextPanelSharedViewMatrix.json", load_surface_policy(policy_path))
    try:
        return merge_shared_view_requirements(base, plan_shared_view_evidence(comparison, matrix, load_surface_policy(policy_path)))
    except SharedViewEvidenceError as error:
        raise WorkflowEvidenceError("combined visual plan is invalid") from error


def capture_config(
    catalog: dict[str, Any], bundles: dict[str, str], profiles: tuple[str, ...] = SUPPORTED_CAPTURE_SURFACES
) -> dict[str, Any]:
    runtimes = catalog.get("runtimes")
    device_types = catalog.get("devicetypes")
    if not isinstance(runtimes, list) or not isinstance(device_types, list):
        raise WorkflowEvidenceError("simulator catalog is invalid")
    output: dict[str, Any] = {}
    for name in profiles:
        profile = SIMULATOR_CAPTURE_PROFILES.get(name)
        bundle = bundles.get(name)
        if profile is None or not isinstance(bundle, str) or not Path(bundle).is_absolute():
            raise WorkflowEvidenceError("capture profile input is invalid")
        matching_runtimes = sorted(
            str(item["identifier"])
            for item in runtimes
            if isinstance(item, dict)
            and item.get("isAvailable") is True
            and item.get("platform") in profile.runtime_platforms
            and isinstance(item.get("identifier"), str)
        )
        matching_devices = sorted(
            str(item["identifier"])
            for item in device_types
            if isinstance(item, dict)
            and item.get("productFamily") == profile.product_family
            and isinstance(item.get("identifier"), str)
        )
        if not matching_runtimes or not matching_devices:
            raise WorkflowEvidenceError(f"no available simulator profile for {name}")
        output[name] = {
            "runtimeIdentifier": matching_runtimes[0],
            "deviceTypeIdentifier": matching_devices[0],
            "appBundle": bundle,
        }
    return {"schemaVersion": CAPTURE_CONFIG_SCHEMA_VERSION, "kind": CAPTURE_CONFIG_KIND, "profiles": output}


def qualify_capture_receipt(receipt: dict[str, Any], requirements: dict[str, Any]) -> None:
    if receipt.get("schemaVersion") != 1 or receipt.get("kind") != CAPTURE_RECEIPT_KIND:
        raise WorkflowEvidenceError("capture receipt is invalid")
    if receipt.get("pixelDiffPolicy") != "advisory-only":
        raise WorkflowEvidenceError("capture receipt claims an unsupported evidence mode")
    encoded_receipt = json.dumps(receipt, sort_keys=True, separators=(",", ":"))
    if "actual-runtime" in encoded_receipt or "os-composited-placement" in encoded_receipt:
        raise WorkflowEvidenceError("capture receipt claims evidence outside shared-view")
    expected = {
        item["id"]: item["surface"]
        for item in requirements.get("requirements", [])
        if isinstance(item, dict) and item.get("evidenceClass") == "shared-view"
    }
    captures = receipt.get("captures")
    if not expected or not isinstance(captures, list):
        raise WorkflowEvidenceError("capture receipt requirements are invalid")
    actual = {item.get("requirementID"): item for item in captures if isinstance(item, dict)}
    if set(actual) != set(expected):
        raise WorkflowEvidenceError("capture receipt does not cover the complete shared-view plan")
    for requirement_id, surface in expected.items():
        capture = actual[requirement_id]
        prefix = surface.split(".", 1)[0]
        if prefix in SUPPORTED_CAPTURE_SURFACES:
            if capture.get("status") != "captured":
                raise WorkflowEvidenceError("supported shared-view requirement was not captured")
        elif prefix in UNSUPPORTED_CAPTURE_SURFACES:
            if capture.get("status") != "blocked" or capture.get("errorCode") != "unsupported-host-mechanism":
                raise WorkflowEvidenceError("unsupported shared-view requirement is not an explicit host limitation")
        else:
            raise WorkflowEvidenceError("capture receipt contains an unknown platform")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate-artifact")
    validate.add_argument("--artifact-root", type=Path, required=True)
    validate.add_argument("--layout", required=True)
    validate.add_argument("--source-commit", required=True)
    validate.add_argument("--version", required=True)
    validate.add_argument("--build-number", required=True)
    validate.add_argument("--run-id", required=True)
    validate.add_argument("--run-source-commit", required=True)
    validate.add_argument("--artifacts-metadata", type=Path, required=True)
    validate.add_argument("--artifact-name", required=True)
    combine = commands.add_parser("combine-visual-plan")
    combine.add_argument("--comparison", type=Path, required=True)
    combine.add_argument("--output", type=Path, required=True)
    config = commands.add_parser("capture-config")
    config.add_argument("--catalog", type=Path, required=True)
    config.add_argument("--ios-app", required=True)
    config.add_argument("--visionos-app", required=True)
    config.add_argument("--watchos-app", required=True)
    config.add_argument("--output", type=Path, required=True)
    qualify = commands.add_parser("qualify-receipt")
    qualify.add_argument("--receipt", type=Path, required=True)
    qualify.add_argument("--requirements", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "validate-artifact":
            print(validate_artifact_manifest(args.artifact_root, layout=args.layout, requested_source_commit=args.source_commit, requested_version=args.version, requested_build=args.build_number, run_id=args.run_id, run_source_commit=args.run_source_commit, artifacts_metadata=args.artifacts_metadata, artifact_name=args.artifact_name))
        elif args.command == "combine-visual-plan":
            _write_json(args.output, combined_visual_plan(args.comparison, REPO_ROOT / "Config" / "ContextPanelSurfacePolicy.json"))
        elif args.command == "capture-config":
            _write_json(args.output, capture_config(_read_json(args.catalog, "simulator catalog"), {"ios": args.ios_app, "ipados": args.ios_app, "visionos": args.visionos_app, "watchos": args.watchos_app}))
        else:
            qualify_capture_receipt(_read_json(args.receipt, "capture receipt"), _read_json(args.requirements, "visual review requirements"))
    except WorkflowEvidenceError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
