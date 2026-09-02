from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
from typing import Any

from context_panel_validation.runtime_evidence import (
    RUNTIME_SURFACES,
    expected_surface_identities_from_payloads,
)

from .core import (
    ReleaseEvidenceError,
    build_release_evidence_lineage,
    evaluate_release_evidence,
    load_historical_policy_archive,
    load_json_object,
)


GENERATION_RENDER_ORDER = (
    "comparison",
    "validationReport",
    "expectedBuildManifests",
    "previousLedger",
    "selectedRCLedger",
    "hostOSEvidence",
    "shadowEvidence",
)


def _render_member(
    *,
    indent: int,
    key: str,
    value: object,
    comma: bool,
    raw_value: bytes | None = None,
) -> bytes:
    spaces = b" " * indent
    suffix = b"," if comma else b""
    encoded_key = json.dumps(key).encode()
    if raw_value is not None:
        return spaces + encoded_key + b":\n" + raw_value + suffix + b"\n"
    rendered = json.dumps(value, indent=2).splitlines()
    first_line = spaces + encoded_key + b": " + rendered[0].encode()
    remaining = b"\n".join(spaces + line.encode() for line in rendered[1:])
    body = first_line if not remaining else first_line + b"\n" + remaining
    return body + suffix + b"\n"


def render_lineage(
    lineage: dict[str, Any],
    *,
    raw_previous_ledger: bytes | None = None,
    raw_selected_rc_ledger: bytes | None = None,
) -> bytes:
    if raw_previous_ledger is None and raw_selected_rc_ledger is None:
        return (json.dumps(lineage, indent=2) + "\n").encode()
    generation = lineage["generation"]
    rendered = b"{\n"
    rendered += _render_member(
        indent=2,
        key="schemaVersion",
        value=lineage["schemaVersion"],
        comma=True,
    )
    rendered += _render_member(
        indent=2,
        key="kind",
        value=lineage["kind"],
        comma=True,
    )
    rendered += _render_member(
        indent=2,
        key="ledger",
        value=lineage["ledger"],
        comma=True,
    )
    rendered += b'  "generation": {\n'
    for index, key in enumerate(GENERATION_RENDER_ORDER):
        raw_value = None
        if key == "previousLedger":
            raw_value = raw_previous_ledger
        elif key == "selectedRCLedger":
            raw_value = raw_selected_rc_ledger
        rendered += _render_member(
            indent=4,
            key=key,
            value=generation[key],
            comma=index < len(GENERATION_RENDER_ORDER) - 1,
            raw_value=raw_value,
        )
    rendered += b"  }\n}"
    return rendered + b"\n"


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
    parser.add_argument(
        "--historical-policy-archive",
        dest="historical_policy_archives",
        type=Path,
        action="append",
        help="Optional directory or archive JSON containing digest-verified historical policy preimages.",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--lineage-output",
        type=Path,
        help="Write the replayable lineage bundle required for later carry-forward.",
    )
    parser.add_argument("--now", help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def _optional_payload(path: Path | None, label: str) -> dict[str, object] | None:
    return load_json_object(path, label) if path is not None else None


def _optional_lineage_payload(
    path: Path | None,
    label: str,
) -> tuple[dict[str, object] | None, bytes | None]:
    if path is None:
        return None, None
    try:
        raw = path.expanduser().read_bytes()
        payload = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseEvidenceError(f"{label} is unavailable or invalid") from error
    if not isinstance(payload, dict):
        raise ReleaseEvidenceError(f"{label} must be a JSON object")
    return payload, raw


def run(argv: list[str] | None = None) -> int:
    arguments = parse_args(argv)
    if (
        arguments.output is not None
        and arguments.lineage_output is not None
        and arguments.output == arguments.lineage_output
    ):
        raise ReleaseEvidenceError("lineage output must differ from ledger output")
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
    expected_build_manifests = tuple(
        load_json_object(path, "expected signed build manifest")
        for path in arguments.expected_build_manifests
    )
    historical_policy_archive = load_historical_policy_archive(
        tuple(arguments.historical_policy_archives or ())
    )
    identities = expected_surface_identities_from_payloads(
        list(expected_build_manifests),
        target,
        tuple(RUNTIME_SURFACES),
    )
    now = None
    if arguments.now:
        normalized = arguments.now.replace("Z", "+00:00")
        now = datetime.fromisoformat(normalized).astimezone(timezone.utc)
    previous_ledger, raw_previous_ledger = _optional_lineage_payload(
        arguments.previous_ledger,
        "previous ledger",
    )
    selected_rc_ledger, raw_selected_rc_ledger = _optional_lineage_payload(
        arguments.selected_rc_ledger,
        "selected RC ledger",
    )
    host_os_evidence = _optional_payload(arguments.host_os_evidence, "host OS evidence")
    shadow_evidence = _optional_payload(arguments.shadow_evidence, "shadow evidence")
    payload = evaluate_release_evidence(
        train=arguments.train,
        mode=arguments.mode,
        comparison=comparison,
        validation_report=report,
        identities=identities,
        expected_build_manifests=expected_build_manifests,
        policy=policy,
        surface_policy=surface_policy,
        previous_ledger=previous_ledger,
        selected_rc_ledger=selected_rc_ledger,
        host_os_evidence=host_os_evidence,
        shadow_evidence=shadow_evidence,
        historical_policy_archive=historical_policy_archive,
        now=now,
    )
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if arguments.output is not None:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(rendered)
    else:
        sys.stdout.write(rendered)
    if arguments.lineage_output is not None:
        lineage = build_release_evidence_lineage(
            payload,
            comparison=comparison,
            validation_report=report,
            expected_build_manifests=expected_build_manifests,
            previous_ledger=previous_ledger,
            selected_rc_ledger=selected_rc_ledger,
            host_os_evidence=host_os_evidence,
            shadow_evidence=shadow_evidence,
        )
        arguments.lineage_output.parent.mkdir(parents=True, exist_ok=True)
        arguments.lineage_output.write_bytes(
            render_lineage(
                lineage,
                raw_previous_ledger=raw_previous_ledger,
                raw_selected_rc_ledger=raw_selected_rc_ledger,
            )
        )
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
