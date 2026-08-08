#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

from context_panel_release_gate import canonical_payload_digest, release_evidence_report_blockers


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
    arguments = parser.parse_args()
    try:
        payload = json.loads(arguments.report.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"release evidence report is unavailable or invalid: {error}") from error
    try:
        validation_payload = json.loads(arguments.validation_report.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"validation report is unavailable or invalid: {error}") from error
    blockers = release_evidence_report_blockers(
        payload,
        version=arguments.version,
        build_number=arguments.build_number,
        train=arguments.train,
        enforce=arguments.enforce,
        validation_report_digest=canonical_payload_digest(validation_payload),
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
