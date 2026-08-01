from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import timedelta
from pathlib import Path

from .asc import DEFAULT_ASC_ENV_FILE, collect_asc_evidence
from .models import (
    EXIT_BLOCKED,
    EXIT_INTERNAL,
    EXIT_UNKNOWN,
    Target,
    build_report,
    device_is_in_scope,
    iso8601,
    report_scope,
    render_text,
    utc_now,
)
from .runtime_evidence import (
    RuntimeEvidenceError,
    RuntimeEvidenceStore,
    RuntimeSessionAdapter,
    apply_runtime_evidence_to_report,
    build_runtime_evidence_report,
    load_expected_surface_identities,
)
from .session import (
    ACTIVE_SESSION_LIFECYCLES,
    DEFAULT_DURATION_HOURS,
    DEFAULT_RETENTION_DAYS,
    MAXIMUM_DURATION_HOURS,
    MAXIMUM_RETENTION_DAYS,
    PAUSE_REASONS,
    RUNTIME_SURFACES,
    CoordinatorSessionConflictError,
    CoordinatorSessionError,
    CoordinatorSessionState,
    SessionStateStore,
    apply_session_state_to_report,
)
from .system import SubprocessRunner, collect_device_evidence, collect_mac_evidence


VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")
BUILD_PATTERN = re.compile(r"^[0-9]+$")


def add_target_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--version", required=True, help="Marketing version, for example 1.0.52")
    parser.add_argument("--build-number", required=True, help="Coordinated CFBundleVersion")
    parser.add_argument("--json", action="store_true", help="Emit stable JSON instead of operator text")


def add_expected_build_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--expected-build-manifest",
        action="append",
        dest="expected_build_manifests",
        type=Path,
        help="Sealed ExpectedBuildManifest JSON; repeat for each requested platform",
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Report read-only signed validation evidence.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    status = subparsers.add_parser("status", help="Collect read-only validation status")
    add_target_arguments(status)
    add_expected_build_arguments(status)
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
    start_session = subparsers.add_parser(
        "start-session",
        help="Create or recover a durable signed-validation session",
    )
    add_target_arguments(start_session)
    add_expected_build_arguments(start_session)
    start_session.add_argument(
        "--surface",
        action="append",
        dest="surfaces",
        choices=RUNTIME_SURFACES,
        help="Required runtime surface; defaults to every shipping surface",
    )
    start_session.add_argument("--duration-hours", type=int, default=DEFAULT_DURATION_HOURS)
    start_session.add_argument("--retention-days", type=int, default=DEFAULT_RETENTION_DAYS)
    start_session.add_argument("--replace", action="store_true")
    pause_session = subparsers.add_parser(
        "pause-session",
        help="Pause coordinator timers without deleting evidence",
    )
    add_target_arguments(pause_session)
    pause_session.add_argument("--reason", required=True, choices=sorted(PAUSE_REASONS))
    resume_session = subparsers.add_parser(
        "resume-session",
        help="Resume a paused signed-validation session",
    )
    add_target_arguments(resume_session)
    stop_session = subparsers.add_parser(
        "stop-session",
        help="Close a signed-validation session without deleting evidence",
    )
    add_target_arguments(stop_session)
    sync_runtime = subparsers.add_parser(
        "sync-runtime-evidence",
        help="Relay runtime receipts through the signed host and reconcile sanitized exports",
    )
    add_target_arguments(sync_runtime)
    add_expected_build_arguments(sync_runtime)
    args = parser.parse_args(argv)
    if not VERSION_PATTERN.fullmatch(args.version):
        parser.error("--version must contain numeric dot-separated components")
    if not BUILD_PATTERN.fullmatch(args.build_number):
        parser.error("--build-number must contain digits only")
    return args


def run_status(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    generated_at = utc_now()
    store = SessionStateStore()
    session = store.load(target, now=generated_at)
    runtime_store = RuntimeEvidenceStore(store)
    runtime_state = None
    runtime_superseded = False
    if session is not None:
        identities = load_expected_surface_identities(
            getattr(args, "expected_build_manifests", None) or [],
            target,
            session.requested_surfaces,
        )
        runtime_state = runtime_store.attach_expected(
            session,
            identities,
            generated_at,
        )
        if runtime_state is not None and session.lifecycle in ACTIVE_SESSION_LIFECYCLES:
            observation = RuntimeSessionAdapter(SubprocessRunner()).collect(generated_at)
            runtime_state, runtime_superseded = runtime_store.reconcile(session, observation)
    runner = SubprocessRunner()
    asc = collect_asc_evidence(runner, target, args.asc_env_file.expanduser())
    mac = collect_mac_evidence(runner, target)
    devices = collect_device_evidence(runner, target)
    report = build_report(
        target,
        asc,
        mac,
        devices,
        store.watch_restart_recorded_at(target, now=generated_at),
        generated_at,
        requested_surfaces=session.requested_surfaces if session is not None else None,
    )
    if session is not None and session.lifecycle in ACTIVE_SESSION_LIFECYCLES:
        include_mac, _, device_labels = report_scope(session.requested_surfaces)
        install_superseded = (include_mac and mac.install_state == "superseded") or any(
            item.install_state == "superseded" and device_is_in_scope(item, device_labels)
            for item in devices
        )
        if runtime_superseded or install_superseded:
            session = store.transition(
                target,
                "superseded",
                generated_at,
                "newer-build-observed",
            )
    if runtime_state is not None:
        report = apply_runtime_evidence_to_report(
            report,
            build_runtime_evidence_report(runtime_state, generated_at),
        )
    report = apply_session_state_to_report(report, session)
    if args.json:
        print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
    else:
        print(render_text(report))
    return report.exit_code


def emit_session_state(
    state: CoordinatorSessionState,
    json_output: bool,
    message: str,
    created: bool | None = None,
) -> None:
    payload: dict[str, object] = {"schemaVersion": 1, "session": state.public_dict()}
    if created is not None:
        payload["created"] = created
    if json_output:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return
    print(f"{message}: {state.target.version} ({state.target.build_number})")
    print(
        f"Session {state.lifecycle} · revision {state.revision} · "
        f"expires {state.expires_at}"
    )


def run_start_session(args: argparse.Namespace) -> int:
    if not 1 <= args.duration_hours <= MAXIMUM_DURATION_HOURS:
        raise CoordinatorSessionError(
            f"session duration must be between 1 and {MAXIMUM_DURATION_HOURS} hours"
        )
    if not 1 <= args.retention_days <= MAXIMUM_RETENTION_DAYS:
        raise CoordinatorSessionError(
            f"session retention must be between 1 and {MAXIMUM_RETENTION_DAYS} days"
        )
    target = Target(args.version, args.build_number)
    requested_surfaces = tuple(args.surfaces or RUNTIME_SURFACES)
    identities = load_expected_surface_identities(
        getattr(args, "expected_build_manifests", None) or [],
        target,
        tuple(sorted(set(requested_surfaces))),
    )
    store = SessionStateStore()
    state, created = store.start_session(
        target,
        requested_surfaces,
        utc_now(),
        timedelta(hours=args.duration_hours),
        timedelta(days=args.retention_days),
        replace_existing=args.replace,
    )
    RuntimeEvidenceStore(store).attach_expected(state, identities, utc_now())
    emit_session_state(
        state,
        args.json,
        "Started signed validation session" if created else "Recovered signed validation session",
        created,
    )
    return 0


def run_sync_runtime_evidence(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    now = utc_now()
    store = SessionStateStore()
    session = store.load(target, now=now)
    if session is None:
        raise RuntimeEvidenceError("signed validation session does not exist")
    if session.lifecycle not in ACTIVE_SESSION_LIFECYCLES:
        raise RuntimeEvidenceError("runtime evidence cannot be synced for a closed session")
    runtime_store = RuntimeEvidenceStore(store)
    identities = load_expected_surface_identities(
        getattr(args, "expected_build_manifests", None) or [],
        target,
        session.requested_surfaces,
    )
    runtime_state = runtime_store.attach_expected(session, identities, now)
    if runtime_state is None:
        raise RuntimeEvidenceError("runtime expected build evidence is unavailable")
    observation = RuntimeSessionAdapter(SubprocessRunner()).sync_and_collect(now)
    runtime_state, superseded = runtime_store.reconcile(session, observation)
    if superseded:
        session = store.transition(
            target,
            "superseded",
            now,
            "newer-build-observed",
        )
    runtime_report = build_runtime_evidence_report(runtime_state, now)
    payload = {
        "schemaVersion": 1,
        "session": session.public_dict(),
        "runtimeEvidence": runtime_report,
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(
            f"Reconciled runtime evidence for {target.version} ({target.build_number}): "
            f"{runtime_report['provenSurfaceCount']} of "
            f"{runtime_report['requestedSurfaceCount']} surfaces proven."
        )
    if superseded:
        return EXIT_BLOCKED
    if (
        runtime_report["state"] == "unknown"
        or runtime_state.last_observation is None
        or runtime_state.last_observation.result != "healthy"
    ):
        return EXIT_UNKNOWN
    return 0


def run_pause_session(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    state = SessionStateStore().transition(target, "paused", utc_now(), args.reason)
    emit_session_state(state, args.json, "Paused signed validation session")
    return 0


def run_resume_session(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    state = SessionStateStore().transition(target, "resumed", utc_now())
    emit_session_state(state, args.json, "Resumed signed validation session")
    return 0


def run_stop_session(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    state = SessionStateStore().transition(
        target,
        "stopped",
        utc_now(),
        "operator-stopped",
    )
    emit_session_state(state, args.json, "Stopped signed validation session")
    return 0


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
        if args.command == "start-session":
            return run_start_session(args)
        if args.command == "pause-session":
            return run_pause_session(args)
        if args.command == "resume-session":
            return run_resume_session(args)
        if args.command == "stop-session":
            return run_stop_session(args)
        if args.command == "sync-runtime-evidence":
            return run_sync_runtime_evidence(args)
        raise RuntimeError(f"unsupported command: {args.command}")
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return EXIT_INTERNAL
    except CoordinatorSessionConflictError as error:
        print(str(error), file=sys.stderr)
        return EXIT_BLOCKED
    except CoordinatorSessionError as error:
        print(str(error), file=sys.stderr)
        return EXIT_UNKNOWN
    except Exception:
        print("Coordinator internal error; no evidence was recorded.", file=sys.stderr)
        return EXIT_INTERNAL
