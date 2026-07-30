from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Sequence

from .artifact import collect_archive_evidence
from .core import (
    DEFAULT_POLICY_PATH,
    SurfacePolicyError,
    compare_manifests,
    embedded_manifest,
    generate_manifest,
    load_json_object,
    manifest_surface_map,
    resolve_policy,
    seal_expected_build,
    validation_summary,
)


def default_root() -> Path:
    return Path(__file__).resolve().parents[2]


def add_policy_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", type=Path, default=default_root())
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY_PATH)


def write_json(payload: dict[str, Any], output: Path | None) -> None:
    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(encoded)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=output.parent,
        prefix=f".{output.name}.",
        delete=False,
    ) as handle:
        temporary_path = Path(handle.name)
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_path, output)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate and compare Context Panel per-surface build fingerprints."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser(
        "validate", help="Validate policy coverage against the shipping project graph."
    )
    add_policy_arguments(validate_parser)
    validate_parser.add_argument("--json", action="store_true")

    generate_parser = subparsers.add_parser(
        "generate", help="Generate a deterministic source and expected-artifact manifest."
    )
    add_policy_arguments(generate_parser)
    generate_parser.add_argument("--marketing-version", required=True)
    generate_parser.add_argument("--build-number", required=True)
    generate_parser.add_argument("--commit", required=True)
    generate_parser.add_argument("--configuration", required=True)
    generate_parser.add_argument("--xcode-build", required=True)
    generate_parser.add_argument(
        "--tree-state", choices=("clean", "dirty", "unknown"), required=True
    )
    generate_parser.add_argument("--output", type=Path)

    fingerprint_parser = subparsers.add_parser(
        "fingerprint", help="Print one source-only surface fingerprint."
    )
    add_policy_arguments(fingerprint_parser)
    fingerprint_parser.add_argument("--surface", required=True)
    fingerprint_parser.add_argument(
        "--kind", choices=("render", "runtime", "combined"), default="combined"
    )

    compare_parser = subparsers.add_parser(
        "compare", help="Derive required and carry-forward evidence between manifests."
    )
    compare_parser.add_argument("--previous", type=Path, required=True)
    compare_parser.add_argument("--current", type=Path, required=True)
    compare_parser.add_argument("--train", choices=("beta", "rc", "release"), required=True)
    compare_parser.add_argument("--output", type=Path)

    template_parser = subparsers.add_parser(
        "evidence-template", help="Emit the required signed-artifact evidence shape."
    )
    template_parser.add_argument("--manifest", type=Path, required=True)
    template_parser.add_argument("--layout")
    template_parser.add_argument("--output", type=Path)

    seal_parser = subparsers.add_parser(
        "seal", help="Bind complete signed-artifact evidence to a source manifest."
    )
    seal_parser.add_argument("--manifest", type=Path, required=True)
    seal_parser.add_argument("--artifact-evidence", type=Path, required=True)
    seal_parser.add_argument("--output", type=Path)

    embed_parser = subparsers.add_parser(
        "embed", help="Reduce a full source manifest to its privacy-safe bundle form."
    )
    embed_parser.add_argument("--manifest", type=Path, required=True)
    embed_parser.add_argument("--output", type=Path)

    collect_parser = subparsers.add_parser(
        "collect-archive",
        help="Verify an XCArchive and emit its exact signed-build manifest.",
    )
    collect_parser.add_argument("--manifest", type=Path, required=True)
    collect_parser.add_argument("--archive", type=Path, required=True)
    collect_parser.add_argument("--layout", required=True)
    collect_parser.add_argument(
        "--profile",
        action="append",
        default=[],
        metavar="ARTIFACT_ID=PATH",
        help="Use an explicit provisioning profile for one artifact.",
    )
    collect_parser.add_argument("--output", type=Path)
    return parser


def evidence_template(
    manifest: dict[str, Any], layout_name: str | None = None
) -> dict[str, Any]:
    source = manifest.get("source")
    if not isinstance(source, dict):
        raise SurfacePolicyError("source manifest identity is missing")
    surfaces = manifest_surface_map(manifest, "source")
    layout_artifacts: set[str] | None = None
    if layout_name is not None:
        archive_layouts = manifest.get("archiveLayouts")
        layout = archive_layouts.get(layout_name) if isinstance(archive_layouts, dict) else None
        if not isinstance(layout, dict) or not layout:
            raise SurfacePolicyError(f"unknown archive layout: {layout_name}")
        layout_artifacts = {str(artifact_id) for artifact_id in layout}
    artifacts: dict[str, dict[str, Any]] = {}
    for surface in surfaces.values():
        artifact_id = str(surface.get("artifactId") or "")
        if layout_artifacts is not None and artifact_id not in layout_artifacts:
            continue
        artifact: dict[str, Any] = {
            "artifactId": artifact_id,
            "bundleIdentifier": surface.get("bundleIdentifier"),
            "marketingVersion": source.get("marketingVersion"),
            "buildNumber": source.get("buildNumber"),
            "sourceCommit": source.get("commit"),
            "configuration": source.get("configuration"),
            "xcodeBuild": source.get("xcodeBuild"),
            "treeState": source.get("treeState"),
            "codeSignatureValid": None,
            "executableSha256": None,
            "executableUUIDs": [],
            "entitlementsSha256": None,
            "profileSha256": None,
        }
        previous = artifacts.get(artifact_id)
        if previous is not None and previous != artifact:
            raise SurfacePolicyError(f"source manifest artifact contract drifted: {artifact_id}")
        artifacts[artifact_id] = artifact
    return {
        "schemaVersion": 1,
        "sourceManifestId": manifest.get("manifestId"),
        "layout": layout_name,
        "artifacts": [artifacts[artifact_id] for artifact_id in sorted(artifacts)],
    }


def profile_bindings(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        artifact_id, separator, raw_path = value.partition("=")
        if not separator or not artifact_id or not raw_path:
            raise SurfacePolicyError("profile binding must use ARTIFACT_ID=PATH")
        if artifact_id in result:
            raise SurfacePolicyError(f"profile binding is duplicated: {artifact_id}")
        result[artifact_id] = Path(raw_path)
    return result


def run(arguments: argparse.Namespace) -> None:
    if arguments.command == "validate":
        summary = validation_summary(resolve_policy(arguments.root, arguments.policy))
        if arguments.json:
            write_json(summary, None)
        else:
            print(
                "surface policy OK: "
                f"{summary['surfaceCount']} surfaces, "
                f"{summary['artifactCount']} artifacts, "
                f"{summary['mappedInputCount']} mapped inputs, "
                f"{summary['ignoredInputCount']} intentional ignores"
            )
        return
    if arguments.command == "generate":
        resolved = resolve_policy(arguments.root, arguments.policy)
        write_json(
            generate_manifest(
                resolved,
                marketing_version=arguments.marketing_version,
                build_number=arguments.build_number,
                source_commit=arguments.commit,
                configuration=arguments.configuration,
                xcode_build=arguments.xcode_build,
                tree_state=arguments.tree_state,
            ),
            arguments.output,
        )
        return
    if arguments.command == "fingerprint":
        resolved = resolve_policy(arguments.root, arguments.policy)
        manifest = generate_manifest(
            resolved,
            marketing_version="source-only",
            build_number="source-only",
            source_commit="source-only",
            configuration="source-only",
            xcode_build="source-only",
            tree_state="unknown",
        )
        surfaces = manifest_surface_map(manifest, "source")
        surface = surfaces.get(arguments.surface)
        if surface is None:
            raise SurfacePolicyError(f"unknown surface: {arguments.surface}")
        print(surface["fingerprints"][arguments.kind])
        return
    if arguments.command == "compare":
        previous = load_json_object(arguments.previous, "previous surface manifest")
        current = load_json_object(arguments.current, "current surface manifest")
        write_json(compare_manifests(previous, current, arguments.train), arguments.output)
        return
    if arguments.command == "evidence-template":
        manifest = load_json_object(arguments.manifest, "surface manifest")
        write_json(evidence_template(manifest, arguments.layout), arguments.output)
        return
    if arguments.command == "seal":
        manifest = load_json_object(arguments.manifest, "surface manifest")
        artifact_evidence = load_json_object(arguments.artifact_evidence, "artifact evidence")
        write_json(seal_expected_build(manifest, artifact_evidence), arguments.output)
        return
    if arguments.command == "embed":
        manifest = load_json_object(arguments.manifest, "surface manifest")
        write_json(embedded_manifest(manifest), arguments.output)
        return
    if arguments.command == "collect-archive":
        manifest = load_json_object(arguments.manifest, "surface manifest")
        evidence = collect_archive_evidence(
            manifest,
            arguments.archive,
            arguments.layout,
            profile_bindings(arguments.profile),
        )
        write_json(seal_expected_build(manifest, evidence), arguments.output)
        return
    raise SurfacePolicyError("unknown command")


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    try:
        run(arguments)
    except SurfacePolicyError as error:
        print(f"surface manifest error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
