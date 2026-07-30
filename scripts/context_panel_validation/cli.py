from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from .asc import DEFAULT_ASC_ENV_FILE, collect_asc_evidence
from .models import EXIT_INTERNAL, EXIT_UNKNOWN, Target, build_report, iso8601, render_text, utc_now
from .system import SessionStateStore, SubprocessRunner, collect_device_evidence, collect_mac_evidence


VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")
BUILD_PATTERN = re.compile(r"^[0-9]+$")


def add_target_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--version", required=True, help="Marketing version, for example 1.0.52")
    parser.add_argument("--build-number", required=True, help="Coordinated CFBundleVersion")
    parser.add_argument("--json", action="store_true", help="Emit stable JSON instead of operator text")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Report read-only signed validation evidence.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    status = subparsers.add_parser("status", help="Collect read-only validation status")
    add_target_arguments(status)
    status.add_argument(
        "--asc-env-file",
        type=Path,
        default=DEFAULT_ASC_ENV_FILE,
        help="Private App Store Connect env file; values are never printed",
    )
    record = subparsers.add_parser(
        "record-watch-restart",
        help="Record operator confirmation of the required post-install Watch restart",
    )
    add_target_arguments(record)
    args = parser.parse_args(argv)
    if not VERSION_PATTERN.fullmatch(args.version):
        parser.error("--version must contain numeric dot-separated components")
    if not BUILD_PATTERN.fullmatch(args.build_number):
        parser.error("--build-number must contain digits only")
    return args


def run_status(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    runner = SubprocessRunner()
    asc = collect_asc_evidence(runner, target, args.asc_env_file.expanduser())
    mac = collect_mac_evidence(runner, target)
    devices = collect_device_evidence(runner, target)
    store = SessionStateStore()
    report = build_report(
        target,
        asc,
        mac,
        devices,
        store.watch_restart_recorded_at(target),
        utc_now(),
    )
    if args.json:
        print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
    else:
        print(render_text(report))
    return report.exit_code


def run_record_watch_restart(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    devices = collect_device_evidence(SubprocessRunner(), target)
    exact_watch_observed = any(
        item.platform == "watchOS" and item.install_state == "current"
        for item in devices
    )
    if not exact_watch_observed:
        payload = {
            "schemaVersion": 1,
            "version": target.version,
            "buildNumber": target.build_number,
            "recorded": False,
            "reason": "exact Watch build is not currently observable",
        }
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(
                f"Did not record the Watch restart for {target.version} ({target.build_number}).\n"
                "The exact Watch build is not currently observable; rerun after it is reachable."
            )
        return EXIT_UNKNOWN
    recorded_at = utc_now()
    SessionStateStore().record_watch_restart(target, recorded_at)
    payload = {
        "schemaVersion": 1,
        "version": target.version,
        "buildNumber": target.build_number,
        "watchRestartRecordedAt": iso8601(recorded_at),
        "proof": "operator_attestation",
        "limitation": "This does not prove complication runtime.",
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(
            f"Recorded the post-install Watch restart for {target.version} ({target.build_number}).\n"
            "This does not prove complication runtime."
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "status":
            return run_status(args)
        if args.command == "record-watch-restart":
            return run_record_watch_restart(args)
        raise RuntimeError(f"unsupported command: {args.command}")
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return EXIT_INTERNAL
    except Exception:
        print("Coordinator internal error; no evidence was recorded.", file=sys.stderr)
        return EXIT_INTERNAL
