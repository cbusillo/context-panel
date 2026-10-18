#!/usr/bin/env python3
"""Pack release evidence for the Submit App Store Review workflow, or unpack it there.

The workflow cannot take the evidence as dispatch inputs: GitHub caps all inputs
at 65,535 characters, and a full release's evidence is several times larger.
The release agent packs the files into one bundle, commits it as
`submission-evidence.json` on the branch `release-evidence/<version>-<build>`,
and dispatches the workflow with the bundle's SHA-256. The workflow unpacks the
bundle only when that digest, the version and the build number all match, then
runs the same submission validation as the local route.

Each member keeps its exact file text, so digests the release gate bound to
those files still hold after unpacking.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import re
import sys
from pathlib import Path

KIND = "context-panel-submission-evidence"
SCHEMA_VERSION = 1
BUNDLE_FILENAME = "submission-evidence.json"
BRANCH_PREFIX = "release-evidence/"

# Bundle member -> (submission flag, required). Unknown members are refused.
MEMBERS: dict[str, tuple[str, bool]] = {
    "validationReport": ("--validation-report", True),
    "releaseEvidenceReport": ("--release-evidence-report", True),
    "comparison": ("--release-evidence-comparison", True),
    "selectedRCLedger": ("--release-evidence-selected-rc-ledger", False),
    "previousLedger": ("--release-evidence-previous-ledger", False),
    "hostOSEvidence": ("--release-evidence-host-os-evidence", False),
    "historicalPolicyArchive": ("--release-evidence-historical-policy-archive", False),
}
MANIFEST_FLAG = "--release-evidence-expected-build-manifest"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class BundleError(Exception):
    pass


def evidence_branch(version: str, build_number: str) -> str:
    return f"{BRANCH_PREFIX}{version}-{build_number}"


def read_json_text(path: Path, label: str) -> str:
    try:
        # Decode bytes directly: read_text() would turn CRLF into LF.
        text = path.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise BundleError(f"{label}: cannot read {path}: {error}") from error
    parse_json(text, label)
    return text


def parse_json(text: str, label: str) -> object:
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise BundleError(f"{label} is not valid JSON: {error}") from error


def create(args: argparse.Namespace) -> int:
    members = {
        name: read_json_text(path, name)
        for name, path in (
            ("validationReport", args.validation_report),
            ("releaseEvidenceReport", args.release_evidence_report),
            ("comparison", args.comparison),
            ("selectedRCLedger", args.selected_rc_ledger),
            ("previousLedger", args.previous_ledger),
            ("hostOSEvidence", args.host_os_evidence),
            ("historicalPolicyArchive", args.historical_policy_archive),
        )
        if path is not None
    }
    manifests = [
        read_json_text(path, "expected-build manifest")
        for path in args.expected_build_manifest
    ]
    bundle = {
        "kind": KIND,
        "schemaVersion": SCHEMA_VERSION,
        "version": args.version,
        "buildNumber": args.build_number,
        "members": members,
        "expectedBuildManifests": manifests,
    }
    validate_bundle(bundle, args.version, args.build_number)
    data = (json.dumps(bundle, indent=1, sort_keys=True) + "\n").encode("utf-8")
    args.output.write_bytes(data)
    print(f"bundle: {args.output}")
    print(f"branch: {evidence_branch(args.version, args.build_number)}")
    print(f"evidence_bundle_sha256: {hashlib.sha256(data).hexdigest()}")
    return 0


def validate_bundle(bundle: object, version: str, build_number: str) -> None:
    if not isinstance(bundle, dict):
        raise BundleError("bundle must be a JSON object")
    expected_keys = {"kind", "schemaVersion", "version", "buildNumber", "members", "expectedBuildManifests"}
    if set(bundle) != expected_keys:
        raise BundleError(f"bundle keys must be exactly {sorted(expected_keys)}")
    if bundle["kind"] != KIND or bundle["schemaVersion"] != SCHEMA_VERSION:
        raise BundleError(f"bundle is not a {KIND} v{SCHEMA_VERSION} bundle")
    if bundle["version"] != version or bundle["buildNumber"] != build_number:
        raise BundleError(
            f"bundle is for {bundle['version']} ({bundle['buildNumber']}), "
            f"not {version} ({build_number})"
        )
    members = bundle["members"]
    if not isinstance(members, dict):
        raise BundleError("bundle members must be an object")
    unknown = sorted(set(members) - set(MEMBERS))
    if unknown:
        raise BundleError(f"bundle has unknown members: {', '.join(unknown)}")
    for name, (_, required) in MEMBERS.items():
        if name not in members:
            if required:
                raise BundleError(f"bundle is missing required member {name}")
            continue
        if not isinstance(members[name], str):
            raise BundleError(f"bundle member {name} must be file text")
        parse_json(members[name], name)
    manifests = bundle["expectedBuildManifests"]
    if not isinstance(manifests, list) or not manifests:
        raise BundleError("bundle needs at least one expected-build manifest")
    for manifest in manifests:
        if not isinstance(manifest, str) or not isinstance(parse_json(manifest, "expected-build manifest"), dict):
            raise BundleError("each expected-build manifest must be the text of a JSON object")


def extract(args: argparse.Namespace) -> int:
    expected = args.sha256.strip().lower()
    if not SHA256_PATTERN.fullmatch(expected):
        raise BundleError("evidence_bundle_sha256 must be 64 lowercase hexadecimal characters")
    try:
        data = args.bundle.read_bytes()
    except OSError as error:
        raise BundleError(f"cannot read evidence bundle: {error}") from error
    actual = hashlib.sha256(data).hexdigest()
    if not hmac.compare_digest(actual, expected):
        raise BundleError(f"evidence bundle SHA-256 is {actual}, not the dispatched {expected}")
    try:
        bundle = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BundleError(f"evidence bundle is not UTF-8 JSON: {error}") from error
    validate_bundle(bundle, args.version, args.build_number)

    output = args.output_dir
    manifest_dir = output / "expected-build-manifests"
    manifest_dir.mkdir(parents=True, exist_ok=True)
    submit_args: list[str] = []
    for name, (flag, _) in MEMBERS.items():
        if name in bundle["members"]:
            path = output / f"{name}.json"
            path.write_text(bundle["members"][name], encoding="utf-8", newline="")
            submit_args += [flag, str(path)]
    for index, manifest in enumerate(bundle["expectedBuildManifests"]):
        path = manifest_dir / f"{index:03d}.json"
        path.write_text(manifest, encoding="utf-8", newline="")
        submit_args += [MANIFEST_FLAG, str(path)]
    print("\n".join(submit_args))
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    pack = commands.add_parser("create", help="pack evidence files into one bundle")
    pack.add_argument("--version", required=True)
    pack.add_argument("--build-number", required=True)
    pack.add_argument("--validation-report", type=Path, required=True)
    pack.add_argument("--release-evidence-report", type=Path, required=True)
    pack.add_argument("--comparison", type=Path, required=True)
    pack.add_argument("--expected-build-manifest", type=Path, action="append", required=True)
    pack.add_argument("--selected-rc-ledger", type=Path)
    pack.add_argument("--previous-ledger", type=Path)
    pack.add_argument("--host-os-evidence", type=Path)
    pack.add_argument("--historical-policy-archive", type=Path)
    pack.add_argument("--output", type=Path, default=Path(BUNDLE_FILENAME))
    pack.set_defaults(handler=create)

    unpack = commands.add_parser(
        "extract", help="verify a bundle and print submit-app-store-review.py evidence arguments, one per line"
    )
    unpack.add_argument("--bundle", type=Path, required=True)
    unpack.add_argument("--sha256", required=True)
    unpack.add_argument("--version", required=True)
    unpack.add_argument("--build-number", required=True)
    unpack.add_argument("--output-dir", type=Path, required=True)
    unpack.set_defaults(handler=extract)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return args.handler(args)
    except BundleError as error:
        print(f"submission evidence bundle refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
