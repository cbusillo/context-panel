#!/usr/bin/env python3

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = REPO_ROOT / "Config" / "ContextPanelTestLanes.json"
DEFAULT_REPORT_DIRECTORY = REPO_ROOT / ".build" / "test-lane-timings"
ALLOWED_RUNNERS = {"manual", "none", "python-unittest", "swiftpm"}
ALLOWED_CI_POLICIES = {"safe", "local-only", "trusted-only", "device-only", "never"}
ALLOWED_ROLES = {"test", "support"}


class TestLaneError(RuntimeError):
    pass


def display_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError:
        return path.name


def load_manifest(path: Path = DEFAULT_MANIFEST) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text())
    except FileNotFoundError as error:
        raise TestLaneError(f"test lane manifest not found: {display_path(path)}") from error
    except json.JSONDecodeError as error:
        raise TestLaneError(f"test lane manifest is invalid JSON: {error}") from error
    if not isinstance(payload, dict):
        raise TestLaneError("test lane manifest must contain a JSON object")
    return payload


def discovered_test_files(root: Path = REPO_ROOT / "Tests") -> set[str]:
    completed = subprocess.run(
        [
            "git",
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "--",
            root.relative_to(REPO_ROOT).as_posix(),
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise TestLaneError("could not discover tracked and untracked files under Tests/")
    return {
        path
        for path in completed.stdout.splitlines()
        if path
        and (REPO_ROOT / path).is_file()
        and "__pycache__" not in Path(path).parts
        and Path(path).suffix != ".pyc"
    }


def validate_manifest(payload: dict[str, Any]) -> dict[str, list[str]]:
    if payload.get("schemaVersion") != 1:
        raise TestLaneError("test lane manifest schemaVersion must be 1")
    lanes = payload.get("lanes")
    files_by_lane = payload.get("filesByLane")
    manual_justifications = payload.get("manualLaneJustifications")
    if not isinstance(lanes, dict) or not lanes:
        raise TestLaneError("test lane manifest must define lanes")
    if not isinstance(files_by_lane, dict):
        raise TestLaneError("test lane manifest must define filesByLane")
    if not isinstance(manual_justifications, dict):
        raise TestLaneError("test lane manifest must define manualLaneJustifications")
    if set(files_by_lane) != set(lanes):
        missing = sorted(set(lanes) - set(files_by_lane))
        unknown = sorted(set(files_by_lane) - set(lanes))
        details = []
        if missing:
            details.append("missing lane lists: " + ", ".join(missing))
        if unknown:
            details.append("unknown lane lists: " + ", ".join(unknown))
        raise TestLaneError("; ".join(details))

    normalized: dict[str, list[str]] = {}
    seen_paths: set[str] = set()
    for lane_name, lane in lanes.items():
        if not isinstance(lane, dict):
            raise TestLaneError(f"test lane {lane_name} must be an object")
        runner = lane.get("runner")
        ci_policy = lane.get("ciPolicy")
        role = lane.get("role")
        if runner not in ALLOWED_RUNNERS:
            raise TestLaneError(f"test lane {lane_name} has an unknown runner")
        if ci_policy not in ALLOWED_CI_POLICIES:
            raise TestLaneError(f"test lane {lane_name} has an unknown CI policy")
        if role not in ALLOWED_ROLES:
            raise TestLaneError(f"test lane {lane_name} has an unknown role")
        if role == "support" and runner != "none":
            raise TestLaneError(f"support lane must use the none runner: {lane_name}")
        if role == "test" and runner == "none":
            raise TestLaneError(f"test lane cannot use the none runner: {lane_name}")

        paths = files_by_lane[lane_name]
        if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
            raise TestLaneError(f"test lane file list must contain strings: {lane_name}")
        normalized[lane_name] = sorted(paths)
        for path in paths:
            relative = Path(path)
            if not path.startswith("Tests/") or relative.is_absolute() or ".." in relative.parts:
                raise TestLaneError(f"test lane path must remain under Tests/: {path}")
            if path in seen_paths:
                raise TestLaneError(f"duplicate test lane path: {path}")
            if runner == "manual":
                justification = manual_justifications.get(path)
                if not isinstance(justification, str) or not justification.strip():
                    raise TestLaneError(f"manual test lane path requires a justification: {path}")
            seen_paths.add(path)

    unknown_justifications = sorted(set(manual_justifications) - seen_paths)
    if unknown_justifications:
        raise TestLaneError(
            "manual lane justifications reference unknown paths: "
            + ", ".join(unknown_justifications)
        )

    discovered = discovered_test_files()
    missing = sorted(discovered - seen_paths)
    stale = sorted(seen_paths - discovered)
    if missing:
        raise TestLaneError("unmapped files under Tests/: " + ", ".join(missing))
    if stale:
        raise TestLaneError("manifest paths do not exist: " + ", ".join(stale))
    return normalized


def files_for_lane(payload: dict[str, Any], lane_name: str, *, require_safe: bool = False) -> list[str]:
    normalized = validate_manifest(payload)
    lane = payload["lanes"].get(lane_name)
    if lane is None:
        raise TestLaneError(f"unknown test lane: {lane_name}")
    if require_safe and lane["ciPolicy"] != "safe":
        raise TestLaneError(f"test lane is not safe for routine CI: {lane_name}")
    if lane["role"] != "test":
        return []
    return normalized[lane_name]


def source_commit() -> str | None:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.stdout.strip() if completed.returncode == 0 else None


def command_version(command: list[str]) -> str | None:
    if not command:
        return None
    completed = subprocess.run(
        [command[0], "--version"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.strip().splitlines()[0] if completed.stdout.strip() else None


def runner_identity() -> dict[str, str]:
    identity = {
        "name": "github-actions" if os.environ.get("GITHUB_ACTIONS") == "true" else "local",
        "os": os.environ.get("RUNNER_OS", platform.system()),
        "arch": os.environ.get("RUNNER_ARCH", platform.machine()),
        "pythonVersion": platform.python_version(),
    }
    image_version = os.environ.get("ImageVersion")
    if image_version:
        identity["imageVersion"] = image_version
    return identity


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def append_summary(report: dict[str, Any]) -> None:
    lines = [
        f"### Test lane: `{report['lane']}`",
        "",
        "| Result | Duration | Test file |",
        "| --- | ---: | --- |",
    ]
    if report["results"]:
        for result in report["results"]:
            status = "passed" if result["exitCode"] == 0 else "failed"
            lines.append(f"| {status} | {result['durationMs']} ms | `{result['path']}` |")
    else:
        status = "passed" if report["exitCode"] == 0 else "failed"
        lines.append(f"| {status} | {report['durationMs']} ms | lane command |")
    lines.extend(
        [
            "",
            f"Runner: `{report['runner']['name']}` / `{report['runner']['os']}` / `{report['runner']['arch']}`",
            "",
        ]
    )
    rendered = "\n".join(lines)
    print(rendered)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with Path(summary_path).open("a") as summary:
            summary.write(rendered + "\n")


def base_report(lane_name: str, files: list[str], started_at: datetime) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "lane": lane_name,
        "sourceCommit": source_commit(),
        "startedAt": started_at.isoformat(),
        "runner": runner_identity(),
        "files": files,
    }


def run_python_lane(payload: dict[str, Any], lane_name: str, report_path: Path) -> int:
    lane = payload["lanes"].get(lane_name)
    if lane is None or lane.get("runner") != "python-unittest":
        raise TestLaneError(f"test lane does not use the Python unittest runner: {lane_name}")
    files = files_for_lane(payload, lane_name, require_safe=True)
    if not files:
        raise TestLaneError(f"test lane has no executable files: {lane_name}")

    started_at = datetime.now(timezone.utc)
    lane_started = time.monotonic()
    results: list[dict[str, Any]] = []
    exit_code = 0
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    for path in files:
        print(f"\n=== {path} ===", flush=True)
        file_started = time.monotonic()
        completed = subprocess.run(
            [sys.executable, "-m", "unittest", path],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
        )
        duration_ms = round((time.monotonic() - file_started) * 1000)
        results.append({"path": path, "durationMs": duration_ms, "exitCode": completed.returncode})
        if completed.returncode != 0:
            exit_code = completed.returncode

    report = base_report(lane_name, files, started_at)
    report.update(
        {
            "durationMs": round((time.monotonic() - lane_started) * 1000),
            "exitCode": exit_code,
            "results": results,
            "toolVersion": f"Python {platform.python_version()}",
        }
    )
    write_report(report_path, report)
    append_summary(report)
    return exit_code


def time_command(payload: dict[str, Any], lane_name: str, report_path: Path, command: list[str]) -> int:
    if not command:
        raise TestLaneError("time-command requires a command after --")
    lane = payload["lanes"].get(lane_name)
    if lane is None:
        raise TestLaneError(f"unknown test lane: {lane_name}")
    if lane.get("runner") != "swiftpm":
        raise TestLaneError(f"test lane does not use the SwiftPM runner: {lane_name}")
    if lane.get("ciPolicy") != "safe":
        raise TestLaneError(f"test lane is not safe for routine CI: {lane_name}")
    files = files_for_lane(payload, lane_name, require_safe=True)
    started_at = datetime.now(timezone.utc)
    command_started = time.monotonic()
    try:
        completed = subprocess.run(command, cwd=REPO_ROOT, check=False)
    except FileNotFoundError as error:
        raise TestLaneError(f"test lane command not found: {command[0]}") from error
    report = base_report(lane_name, files, started_at)
    report.update(
        {
            "durationMs": round((time.monotonic() - command_started) * 1000),
            "exitCode": completed.returncode,
            "results": [],
            "commandName": Path(command[0]).name,
            "toolVersion": command_version(command),
        }
    )
    write_report(report_path, report)
    append_summary(report)
    return completed.returncode


def default_report_path(lane_name: str) -> Path:
    return DEFAULT_REPORT_DIRECTORY / f"{lane_name}.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate and execute Context Panel test lanes.")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("validate", help="Validate complete test-file ownership.")

    list_parser = subparsers.add_parser("list", help="List executable files for a lane.")
    list_parser.add_argument("--lane", required=True)
    list_parser.add_argument("--safe", action="store_true")

    run_parser = subparsers.add_parser("run", help="Run a manifest-backed Python test lane.")
    run_parser.add_argument("--lane", required=True)
    run_parser.add_argument("--report", type=Path)

    command_parser = subparsers.add_parser("time-command", help="Time a safe external test command.")
    command_parser.add_argument("--lane", required=True)
    command_parser.add_argument("--report", type=Path)
    command_parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        payload = load_manifest(arguments.manifest)
        normalized = validate_manifest(payload)
        if arguments.action == "validate":
            file_count = sum(len(paths) for paths in normalized.values())
            print(f"Validated {file_count} files across {len(normalized)} test lanes")
            for lane_name in sorted(normalized):
                print(f"- {lane_name}: {len(normalized[lane_name])} files")
            return 0
        if arguments.action == "list":
            for path in files_for_lane(payload, arguments.lane, require_safe=arguments.safe):
                print(path)
            return 0
        if arguments.action == "run":
            return run_python_lane(
                payload,
                arguments.lane,
                arguments.report or default_report_path(arguments.lane),
            )
        command = arguments.command
        if command and command[0] == "--":
            command = command[1:]
        return time_command(
            payload,
            arguments.lane,
            arguments.report or default_report_path(arguments.lane),
            command,
        )
    except TestLaneError as error:
        print(f"context-panel-test-lanes failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
