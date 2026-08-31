from __future__ import annotations

import argparse
from dataclasses import replace
import hashlib
import json
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import cast

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
from .operator_flow import (
    DEFERRAL_REASONS,
    MAXIMUM_DEFERRAL_HOURS,
    RESIDUAL_RISKS,
    OperatorFlowError,
    OperatorFlowStore,
    apply_operator_flow_to_report,
    build_final_report_payload,
    render_final_report,
)
from .runtime_evidence import (
    RuntimeEvidenceError,
    RuntimeEvidenceStore,
    RuntimeSessionAdapter,
    apply_runtime_evidence_to_report,
    build_runtime_evidence_report,
    load_expected_surface_identities,
)
from .automation import (
    AUTOMATION_COOLDOWN,
    AUTOMATION_KIND_LIMITS,
    MAXIMUM_AUTOMATION_ATTEMPT_COUNT,
    AutomationError,
    AutomationState,
    AutomationStore,
    attempts_for_kind,
    build_automation_report,
    macos_app_window_digest,
    make_attempt,
    new_automation_state,
    runtime_report_digest,
    shared_view_capture_window_digest,
)
from .shared_view_evidence import (
    DEFAULT_MATRIX_PATH,
    DEFAULT_SURFACE_POLICY_PATH,
    SharedViewEvidenceError,
    load_shared_view_matrix,
    load_surface_policy,
    plan_shared_view_evidence,
    write_requirements_payload,
)
from .shared_view_capture import SharedViewCaptureError, execute_shared_view_capture
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
    parse_iso8601,
)
from .system import (
    SubprocessRunner,
    collect_device_evidence,
    collect_mac_evidence,
    launch_canonical_mac_app,
)
from .visual_approvals import (
    VISUAL_DECISIONS,
    VisualApprovalError,
    VisualApprovalStore,
    apply_visual_approvals_to_report,
    build_visual_approval_report,
    load_visual_review_plan,
)


MACOS_LAUNCH_VERIFY_ATTEMPTS = 3
MACOS_LAUNCH_VERIFY_DELAY_SECONDS = 1.0


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


def add_cloudkit_schema_receipt_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--cloudkit-schema-receipt",
        type=Path,
        required=True,
        help="Fresh sealed Production CloudKit schema receipt JSON",
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
    final_report = subparsers.add_parser(
        "final-report",
        help="Render a privacy-safe GitHub-ready validation report",
    )
    add_target_arguments(final_report)
    add_expected_build_arguments(final_report)
    final_report.add_argument(
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
    start_session.add_argument(
        "--surface-comparison",
        type=Path,
        help="Surface-manifest comparison defining fresh visual and runtime requirements",
    )
    start_session.add_argument(
        "--visual-review-requirements",
        type=Path,
        help="Explicit fixture and placement review contexts for the comparison",
    )
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
    add_cloudkit_schema_receipt_argument(sync_runtime)
    advance_automation = subparsers.add_parser(
        "advance-automation",
        help="Advance the bounded runtime-receipt sync automation only",
    )
    add_target_arguments(advance_automation)
    add_expected_build_arguments(advance_automation)
    add_cloudkit_schema_receipt_argument(advance_automation)
    for option, destination in (
        ("--surface-comparison", "surface_comparison"),
        ("--current-manifest", "current_manifest"),
        ("--requirements", "requirements"),
        ("--capture-config", "capture_config"),
        ("--artifact-root", "artifact_root"),
        ("--capture-output", "capture_output"),
    ):
        advance_automation.add_argument(option, dest=destination, type=Path)
    defer_action = subparsers.add_parser(
        "defer-action",
        help="Temporarily defer one outstanding operator action without satisfying evidence",
    )
    add_target_arguments(defer_action)
    defer_action.add_argument("--action-id", required=True)
    defer_action.add_argument("--owner", required=True)
    defer_action.add_argument("--reason", required=True, choices=DEFERRAL_REASONS)
    defer_action.add_argument(
        "--residual-risk",
        required=True,
        choices=RESIDUAL_RISKS,
    )
    defer_action.add_argument("--duration-hours", required=True, type=int)
    clear_deferral = subparsers.add_parser(
        "clear-deferral",
        help="Clear the active deferral for one outstanding operator action",
    )
    add_target_arguments(clear_deferral)
    clear_deferral.add_argument("--action-id", required=True)
    record_visual_review = subparsers.add_parser(
        "record-visual-review",
        help="Record an approve or reject decision for one ready visual requirement",
    )
    add_target_arguments(record_visual_review)
    record_visual_review.add_argument("--requirement-id", required=True)
    record_visual_review.add_argument("--decision", required=True, choices=VISUAL_DECISIONS)
    record_visual_review.add_argument(
        "--host-os",
        help="Observed host OS; required only for OS-composited placement review",
    )
    record_visual_review.add_argument(
        "--artifact",
        type=Path,
        help="Optional private artifact to hash; its path and contents are never persisted",
    )
    export_visual_reviews = subparsers.add_parser(
        "export-visual-reviews",
        help="Export bounded public visual requirement and decision metadata",
    )
    add_target_arguments(export_visual_reviews)
    plan_shared_view_evidence_parser = subparsers.add_parser(
        "plan-shared-view-evidence",
        help="Plan bounded shared-view review requirements without coordinator state",
    )
    plan_shared_view_evidence_parser.add_argument(
        "--surface-comparison",
        required=True,
        type=Path,
        help="Validated current schema-v5 surface-manifest comparison",
    )
    plan_shared_view_evidence_parser.add_argument(
        "--matrix",
        type=Path,
        default=DEFAULT_MATRIX_PATH,
        help="Canonical shared-view matrix JSON",
    )
    plan_shared_view_evidence_parser.add_argument(
        "--surface-policy",
        type=Path,
        default=DEFAULT_SURFACE_POLICY_PATH,
        help="Canonical Context Panel surface policy JSON",
    )
    plan_shared_view_evidence_parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Requirements JSON destination",
    )
    plan_shared_view_evidence_parser.add_argument(
        "--json", action="store_true", help="Emit the planned payload as stable JSON"
    )
    capture_shared_view_evidence_parser = subparsers.add_parser(
        "capture-shared-view-evidence",
        help="Capture private simulator gallery evidence without coordinator state",
    )
    capture_shared_view_evidence_parser.add_argument(
        "--surface-comparison",
        required=True,
        type=Path,
        help="Validated current schema-v5 surface-manifest comparison",
    )
    capture_shared_view_evidence_parser.add_argument(
        "--current-manifest",
        required=True,
        type=Path,
        help="Canonical current source surface manifest",
    )
    capture_shared_view_evidence_parser.add_argument(
        "--matrix",
        type=Path,
        default=DEFAULT_MATRIX_PATH,
        help="Shared-view matrix JSON; its digest is recorded in the receipt",
    )
    capture_shared_view_evidence_parser.add_argument(
        "--surface-policy",
        type=Path,
        default=DEFAULT_SURFACE_POLICY_PATH,
        help="Canonical Context Panel surface policy JSON; alternate paths are rejected",
    )
    capture_shared_view_evidence_parser.add_argument(
        "--requirements",
        required=True,
        type=Path,
        help="Schema-v1 shared-view requirements JSON",
    )
    capture_shared_view_evidence_parser.add_argument(
        "--capture-config",
        required=True,
        type=Path,
        help="Private schema-v1 simulator capture config JSON",
    )
    capture_shared_view_evidence_parser.add_argument(
        "--artifact-root",
        required=True,
        type=Path,
        help="Absolute private artifact directory outside the repository",
    )
    capture_shared_view_evidence_parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Absolute atomic public capture receipt JSON destination",
    )
    capture_shared_view_evidence_parser.add_argument(
        "--json", action="store_true", help="Emit the public receipt as stable JSON"
    )
    args = parser.parse_args(argv)
    if args.command == "advance-automation":
        capture_inputs = (
            args.surface_comparison,
            args.current_manifest,
            args.requirements,
            args.capture_config,
            args.artifact_root,
            args.capture_output,
        )
        if any(value is not None for value in capture_inputs) and not all(
            value is not None for value in capture_inputs
        ):
            parser.error("shared-view capture automation inputs must be supplied together")
    if args.command not in {"plan-shared-view-evidence", "capture-shared-view-evidence"}:
        if not VERSION_PATTERN.fullmatch(args.version):
            parser.error("--version must contain numeric dot-separated components")
        if not BUILD_PATTERN.fullmatch(args.build_number):
            parser.error("--build-number must contain digits only")
    return args


def collect_validation_report(args: argparse.Namespace):
    target = Target(args.version, args.build_number)
    generated_at = utc_now()
    store = SessionStateStore()
    session = store.load(target, now=generated_at)
    runtime_store = RuntimeEvidenceStore(store)
    runtime_state = None
    runtime_superseded = False
    if session is not None:
        identities = (
            load_expected_surface_identities(
                getattr(args, "expected_build_manifests", None) or [],
                target,
                session.requested_surfaces,
            )
            if session.requested_surfaces
            else ()
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
    if session is not None:
        visual_state = VisualApprovalStore(store).load(session)
        if visual_state is not None:
            report = apply_visual_approvals_to_report(
                report,
                build_visual_approval_report(visual_state, runtime_state),
            )
    report = apply_session_state_to_report(report, session)
    if session is not None:
        automation_state = AutomationStore(store).load(session)
        report = replace(
            report,
            automation=build_automation_report(automation_state),
        )
        _, operator_flow = OperatorFlowStore(store).reconcile(
            session,
            report,
            report.runtime_evidence,
            generated_at,
        )
        report = apply_operator_flow_to_report(report, operator_flow)
    return report


def run_status(args: argparse.Namespace) -> int:
    report = collect_validation_report(args)
    if args.json:
        print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
    else:
        print(render_text(report))
    return report.exit_code


def run_final_report(args: argparse.Namespace) -> int:
    report = collect_validation_report(args)
    if report.session is None:
        raise OperatorFlowError("signed validation session does not exist")
    if args.json:
        print(json.dumps(build_final_report_payload(report), indent=2, sort_keys=True))
    else:
        print(render_final_report(report))
    return report.exit_code


def run_plan_shared_view_evidence(args: argparse.Namespace) -> int:
    try:
        comparison = json.loads(args.surface_comparison.expanduser().read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SharedViewEvidenceError("surface comparison is unavailable or invalid") from error
    surface_policy = load_surface_policy(args.surface_policy)
    matrix = load_shared_view_matrix(args.matrix, surface_policy)
    payload = plan_shared_view_evidence(comparison, matrix, surface_policy)
    write_requirements_payload(args.output, payload)
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        requirements = cast(list[dict[str, object]], payload["requirements"])
        surfaces = {item["surface"] for item in requirements}
        print(
            f"Planned {len(requirements)} shared-view requirements across "
            f"{len(surfaces)} fresh shared-view surfaces."
        )
    return 0


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
    comparison_path = getattr(args, "surface_comparison", None)
    requirements_path = getattr(args, "visual_review_requirements", None)
    if (comparison_path is None) != (requirements_path is None):
        raise VisualApprovalError(
            "surface comparison and visual review requirements must be supplied together"
        )
    visual_requirements = None
    current_manifest_id = None
    if comparison_path is not None and requirements_path is not None:
        all_identities = load_expected_surface_identities(
            getattr(args, "expected_build_manifests", None) or [],
            target,
            RUNTIME_SURFACES,
        )
        requested_surfaces, visual_requirements, current_manifest_id = load_visual_review_plan(
            comparison_path,
            requirements_path,
            all_identities,
        )
        if args.surfaces is not None and tuple(sorted(set(args.surfaces))) != requested_surfaces:
            raise VisualApprovalError(
                "explicit runtime surfaces do not match the surface comparison"
            )
    else:
        requested_surfaces = tuple(sorted(set(args.surfaces or RUNTIME_SURFACES)))
        all_identities = load_expected_surface_identities(
            getattr(args, "expected_build_manifests", None) or [],
            target,
            requested_surfaces,
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
    runtime_identities = tuple(
        identity for identity in all_identities if identity.surface in requested_surfaces
    )
    if runtime_identities:
        RuntimeEvidenceStore(store).attach_expected(state, runtime_identities, utc_now())
    if visual_requirements is not None and current_manifest_id is not None:
        VisualApprovalStore(store).configure(
            state,
            current_manifest_id,
            visual_requirements,
            utc_now(),
        )
    emit_session_state(
        state,
        args.json,
        "Started signed validation session" if created else "Recovered signed validation session",
        created,
    )
    return 0


def sync_and_reconcile_runtime_evidence(
    store: SessionStateStore,
    session: CoordinatorSessionState,
    expected_build_manifests: list[Path],
    cloudkit_schema_receipt: Path | None,
    now,
):
    runtime_store = RuntimeEvidenceStore(store)
    identities = load_expected_surface_identities(
        expected_build_manifests,
        session.target,
        session.requested_surfaces,
    )
    runtime_state = runtime_store.attach_expected(session, identities, now)
    if runtime_state is None:
        raise RuntimeEvidenceError("runtime expected build evidence is unavailable")
    observation = RuntimeSessionAdapter(
        SubprocessRunner(),
        cloudkit_schema_receipt=cloudkit_schema_receipt,
    ).sync_and_collect(now)
    runtime_state, superseded = runtime_store.reconcile(session, observation)
    if superseded:
        session = store.transition(
            session.target,
            "superseded",
            now,
            "newer-build-observed",
        )
    runtime_report = build_runtime_evidence_report(runtime_state, now)
    return session, runtime_state, runtime_report, superseded


def runtime_sync_exit_code(runtime_state, runtime_report: dict[str, object], superseded: bool) -> int:
    if superseded:
        return EXIT_BLOCKED
    if (
        runtime_report["state"] == "unknown"
        or runtime_state.last_observation is None
        or runtime_state.last_observation.result != "healthy"
    ):
        return EXIT_UNKNOWN
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
    session, runtime_state, runtime_report, superseded = sync_and_reconcile_runtime_evidence(
        store,
        session,
        getattr(args, "expected_build_manifests", None) or [],
        getattr(args, "cloudkit_schema_receipt", None),
        now,
    )
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
    return runtime_sync_exit_code(runtime_state, runtime_report, superseded)


def emit_automation_payload(
    args: argparse.Namespace,
    session: CoordinatorSessionState,
    runtime_report: dict[str, object] | None,
    automation_state: AutomationState | None,
) -> None:
    automation_report = build_automation_report(automation_state)
    payload = {
        "schemaVersion": 1,
        "session": session.public_dict(),
        "runtimeEvidence": runtime_report,
        "automation": automation_report,
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        automation_state_name = automation_report.get("state")
        attempt_count = automation_report.get("attemptCount")
        if not isinstance(automation_state_name, str) or not isinstance(attempt_count, int):
            raise AutomationError("automation report is invalid")
        print(
            f"Automation {automation_state_name}: {attempt_count} of "
            f"{AUTOMATION_KIND_LIMITS['runtime.receipt.sync']} receipt attempts recorded."
        )
        kind_reports = automation_report.get("kindReports")
        launch_report = (
            kind_reports.get("macos.app.launch")
            if isinstance(kind_reports, dict)
            else None
        )
        if isinstance(launch_report, dict):
            launch_state = launch_report.get("state")
            launch_attempt_count = launch_report.get("attemptCount")
            if isinstance(launch_state, str) and isinstance(launch_attempt_count, int):
                print(
                    f"Mac launch automation {launch_state}: {launch_attempt_count} of "
                    f"{AUTOMATION_KIND_LIMITS['macos.app.launch']} attempts recorded."
                )
        capture_report = (
            kind_reports.get("shared-view.capture")
            if isinstance(kind_reports, dict)
            else None
        )
        if isinstance(capture_report, dict):
            capture_state = capture_report.get("state")
            capture_attempt_count = capture_report.get("attemptCount")
            if isinstance(capture_state, str) and isinstance(capture_attempt_count, int):
                print(
                    f"Shared-view capture automation {capture_state}: "
                    f"{capture_attempt_count} of "
                    f"{AUTOMATION_KIND_LIMITS['shared-view.capture']} attempts recorded."
                )


def _advance_macos_app_launch(
    store: SessionStateStore,
    session: CoordinatorSessionState,
    automation_state: AutomationState | None,
    runner: SubprocessRunner,
    now: datetime,
) -> tuple[AutomationState | None, bool]:
    if not any(surface.startswith("macos.") for surface in session.requested_surfaces):
        return automation_state, False

    observed_mac = collect_mac_evidence(runner, session.target)
    window_digest = macos_app_window_digest(observed_mac)
    launch_identity_ready = (
        observed_mac.install_state == "current"
        and observed_mac.app_cloudkit == "Production"
        and observed_mac.refresh_agent_cloudkit == "Production"
    )
    if not launch_identity_ready:
        return automation_state, False
    if (
        observed_mac.baseline_state == "proven"
        and observed_mac.app_process_state == "running"
    ):
        return automation_state, False

    launch_attempts = tuple(
        attempt
        for attempt in attempts_for_kind(automation_state, "macos.app.launch")
        if attempt.receipt_window_digest == window_digest
    )
    if len(launch_attempts) >= 2:
        return automation_state, launch_attempts[-1].result != "succeeded"
    if launch_attempts:
        finished_at = parse_iso8601(launch_attempts[-1].finished_at)
        assert finished_at is not None
        if now < finished_at + AUTOMATION_COOLDOWN:
            return automation_state, launch_attempts[-1].result != "succeeded"

    if automation_state is not None and (
        len(attempts_for_kind(automation_state, "macos.app.launch"))
        >= AUTOMATION_KIND_LIMITS["macos.app.launch"]
        or len(automation_state.attempts) >= MAXIMUM_AUTOMATION_ATTEMPT_COUNT
    ):
        return automation_state, True

    if not (
        observed_mac.baseline_state == "identity_verified_app_not_running"
        and observed_mac.app_process_state == "not_running"
    ):
        attempt = make_attempt(
            automation_state or new_automation_state(session, now),
            kind="macos.app.launch",
            result="skipped-precondition",
            reason_code="macos-app-launch-precondition-not-met",
            started_at=now,
            finished_at=utc_now(),
            receipt_window_digest=window_digest,
            runtime_report=None,
        )
        return AutomationStore(store).record(session, attempt, now), True

    launch_result = launch_canonical_mac_app(runner)
    post_launch_mac = observed_mac
    if launch_result.returncode == 0 and not launch_result.timed_out:
        post_launch_mac = collect_mac_evidence(runner, session.target)
        for _ in range(MACOS_LAUNCH_VERIFY_ATTEMPTS - 1):
            if (
                post_launch_mac.baseline_state == "proven"
                and post_launch_mac.app_process_state == "running"
            ):
                break
            time.sleep(MACOS_LAUNCH_VERIFY_DELAY_SECONDS)
            post_launch_mac = collect_mac_evidence(runner, session.target)
    if launch_result.returncode == 127:
        result, reason_code = "unsupported", "macos-app-launch-unavailable"
    elif launch_result.returncode != 0 or launch_result.timed_out:
        result, reason_code = "failed", "macos-app-launch-command-failed"
    elif (
        post_launch_mac.baseline_state == "proven"
        and post_launch_mac.app_process_state == "running"
    ):
        result, reason_code = "succeeded", "macos-app-launch-verified"
    else:
        result, reason_code = "failed", "macos-app-launch-unverified"

    attempt = make_attempt(
        automation_state or new_automation_state(session, now),
        kind="macos.app.launch",
        result=result,
        reason_code=reason_code,
        started_at=now,
        finished_at=utc_now(),
        receipt_window_digest=window_digest,
        runtime_report=None,
    )
    updated_state = AutomationStore(store).record(session, attempt, now)
    return updated_state, result != "succeeded"


def _combine_automation_exit(runtime_exit: int, launch_failed: bool) -> int:
    if runtime_exit == EXIT_BLOCKED:
        return runtime_exit
    return EXIT_UNKNOWN if launch_failed else runtime_exit


def _shared_view_capture_window(
    store: SessionStateStore,
    session: CoordinatorSessionState,
) -> str | None:
    visual_state = VisualApprovalStore(store).load(session)
    if visual_state is None:
        return None
    requirements = tuple(
        requirement
        for requirement in visual_state.requirements
        if requirement.evidence_class == "shared-view"
    )
    if not requirements:
        return None
    manifest_ids = {requirement.manifest_id for requirement in requirements}
    if len(manifest_ids) != 1:
        raise AutomationError("shared-view capture requirements are invalid")
    manifest_id = next(iter(manifest_ids))
    return shared_view_capture_window_digest(
        manifest_id,
        [requirement.id for requirement in requirements],
    )


def _advance_shared_view_capture(
    args: argparse.Namespace,
    store: SessionStateStore,
    session: CoordinatorSessionState,
    automation_state: AutomationState | None,
    now: datetime,
) -> tuple[AutomationState | None, int]:
    if session.lifecycle != "active":
        return automation_state, (
            EXIT_BLOCKED if session.lifecycle in {"blocked", "superseded"} else EXIT_UNKNOWN
        )
    window_digest = _shared_view_capture_window(store, session)
    if window_digest is None:
        return automation_state, 0
    all_capture_attempts = attempts_for_kind(automation_state, "shared-view.capture")
    last_capture_attempt = all_capture_attempts[-1] if all_capture_attempts else None
    capture_inputs = (
        getattr(args, "surface_comparison", None),
        getattr(args, "current_manifest", None),
        getattr(args, "requirements", None),
        getattr(args, "capture_config", None),
        getattr(args, "artifact_root", None),
        getattr(args, "capture_output", None),
    )
    inputs_available = all(value is not None for value in capture_inputs)
    current_window_attempts = tuple(
        attempt
        for attempt in all_capture_attempts
        if attempt.receipt_window_digest == window_digest
    )
    executed_window_attempts = tuple(
        attempt
        for attempt in current_window_attempts
        if attempt.reason_code != "shared-view-capture-unavailable"
    )
    if last_capture_attempt is not None and last_capture_attempt.receipt_window_digest == window_digest:
        if last_capture_attempt.result == "succeeded":
            return automation_state, 0
        if last_capture_attempt.reason_code == "shared-view-capture-host-unsupported":
            return automation_state, 0
        if last_capture_attempt.result == "unsupported":
            if not inputs_available:
                return automation_state, 0
        elif last_capture_attempt.result == "failed":
            if len(executed_window_attempts) >= 2:
                return automation_state, EXIT_UNKNOWN
            finished_at = parse_iso8601(last_capture_attempt.finished_at)
            assert finished_at is not None
            if now < finished_at + AUTOMATION_COOLDOWN:
                return automation_state, EXIT_UNKNOWN
    if automation_state is not None and (
        len(attempts_for_kind(automation_state, "shared-view.capture"))
        >= AUTOMATION_KIND_LIMITS["shared-view.capture"]
        or len(automation_state.attempts) >= MAXIMUM_AUTOMATION_ATTEMPT_COUNT
    ):
        return automation_state, EXIT_UNKNOWN

    if not inputs_available:
        if executed_window_attempts and executed_window_attempts[-1].result == "failed":
            return automation_state, EXIT_UNKNOWN
        result, reason_code, capture_exit = (
            "unsupported",
            "shared-view-capture-unavailable",
            0,
        )
    else:
        try:
            capture_exit, receipt = execute_shared_view_capture(
                *cast(tuple[Path, Path, Path, Path, Path, Path], capture_inputs),
            )
            captures = receipt.get("captures")
            manifest_id = receipt.get("currentManifestID")
            if not isinstance(captures, list) or not isinstance(manifest_id, str):
                raise SharedViewCaptureError("shared-view capture receipt is invalid")
            captured_requirement_ids = [
                item.get("requirementID")
                for item in captures
                if isinstance(item, dict) and isinstance(item.get("requirementID"), str)
            ]
            if (
                len(captured_requirement_ids) != len(captures)
                or shared_view_capture_window_digest(manifest_id, captured_requirement_ids)
                != window_digest
            ):
                raise SharedViewCaptureError("shared-view capture receipt does not match the session")
            if capture_exit == 0:
                result, reason_code = "succeeded", "shared-view-capture-recorded"
            elif capture_exit == EXIT_BLOCKED:
                error_codes = {
                    item.get("errorCode")
                    for item in captures
                    if isinstance(item, dict) and item.get("status") != "captured"
                }
                if error_codes and error_codes <= {"unsupported-host-mechanism"}:
                    result, reason_code, capture_exit = (
                        "unsupported",
                        "shared-view-capture-host-unsupported",
                        0,
                    )
                else:
                    result, reason_code, capture_exit = (
                        "failed",
                        "shared-view-capture-failed",
                        EXIT_UNKNOWN,
                    )
            else:
                result, reason_code = "failed", "shared-view-capture-failed"
                capture_exit = EXIT_UNKNOWN
        except (SharedViewEvidenceError, OSError):
            result, reason_code, capture_exit = (
                "failed",
                "shared-view-capture-failed",
                EXIT_UNKNOWN,
            )

    attempt = make_attempt(
        automation_state or new_automation_state(session, now),
        kind="shared-view.capture",
        result=result,
        reason_code=reason_code,
        started_at=now,
        finished_at=utc_now(),
        receipt_window_digest=window_digest,
        runtime_report=None,
    )
    return AutomationStore(store).record(session, attempt, now), capture_exit


def _worst_automation_exit(*exit_codes: int) -> int:
    if EXIT_BLOCKED in exit_codes:
        return EXIT_BLOCKED
    if EXIT_UNKNOWN in exit_codes:
        return EXIT_UNKNOWN
    return max(exit_codes)


def _finish_automation(
    args: argparse.Namespace,
    store: SessionStateStore,
    session: CoordinatorSessionState,
    automation_state: AutomationState | None,
    runtime_report: dict[str, object] | None,
    runtime_exit: int,
    launch_failed: bool,
    now: datetime,
) -> int:
    automation_state, capture_exit = _advance_shared_view_capture(
        args,
        store,
        session,
        automation_state,
        now,
    )
    emit_automation_payload(args, session, runtime_report, automation_state)
    return _worst_automation_exit(
        _combine_automation_exit(runtime_exit, launch_failed),
        capture_exit,
    )


def _run_advance_automation_locked(
    args: argparse.Namespace,
    store: SessionStateStore,
    session: CoordinatorSessionState,
    now,
) -> int:
    automation_store = AutomationStore(store)
    automation_state = automation_store.load(session)
    runtime_state = RuntimeEvidenceStore(store).load(session)
    runtime_report = (
        build_runtime_evidence_report(runtime_state, now) if runtime_state is not None else None
    )
    if session.lifecycle != "active":
        emit_automation_payload(args, session, runtime_report, automation_state)
        return EXIT_BLOCKED if session.lifecycle in {"blocked", "superseded"} else EXIT_UNKNOWN

    runner = SubprocessRunner()
    automation_state, launch_failed = _advance_macos_app_launch(
        store,
        session,
        automation_state,
        runner,
        now,
    )

    runtime_attempts = attempts_for_kind(automation_state, "runtime.receipt.sync")
    last_attempt = runtime_attempts[-1] if runtime_attempts else None
    window_digest = runtime_report_digest(runtime_report)
    current_runtime_exit = (
        runtime_sync_exit_code(runtime_state, runtime_report, False)
        if runtime_state is not None and runtime_report is not None
        else EXIT_UNKNOWN
    )
    if (
        last_attempt is not None
        and last_attempt.result == "succeeded"
        and last_attempt.summary.evidence_satisfied
        and last_attempt.receipt_window_digest == window_digest
    ):
        return _finish_automation(
            args, store, session, automation_state, runtime_report,
            current_runtime_exit, launch_failed, now,
        )
    if (
        last_attempt is not None
        and last_attempt.receipt_window_digest == window_digest
        and runtime_report is not None
        and runtime_report["state"] == "proven"
        and current_runtime_exit == 0
    ):
        return _finish_automation(
            args, store, session, automation_state, runtime_report,
            0, launch_failed, now,
        )
    if len(runtime_attempts) >= AUTOMATION_KIND_LIMITS["runtime.receipt.sync"]:
        runtime_exit = (
            current_runtime_exit
            if runtime_report and runtime_report["state"] == "proven"
            else EXIT_UNKNOWN
        )
        return _finish_automation(
            args, store, session, automation_state, runtime_report,
            runtime_exit, launch_failed, now,
        )
    if last_attempt is not None:
        finished_at = parse_iso8601(last_attempt.finished_at)
        assert finished_at is not None
        same_window = last_attempt.receipt_window_digest == window_digest
        cooldown_active = now < finished_at + AUTOMATION_COOLDOWN
        if same_window and cooldown_active:
            return _finish_automation(
                args, store, session, automation_state, runtime_report,
                current_runtime_exit, launch_failed, now,
            )

    started_at = now
    if (
        runtime_report is not None
        and runtime_report["state"] == "proven"
        and current_runtime_exit == 0
    ):
        attempt = make_attempt(
            automation_state or new_automation_state(session, now),
            result="skipped-precondition",
            reason_code="runtime-evidence-complete",
            started_at=started_at,
            finished_at=utc_now(),
            runtime_report=runtime_report,
        )
        automation_state = automation_store.record(session, attempt, now)
        return _finish_automation(
            args, store, session, automation_state, runtime_report,
            runtime_sync_exit_code(runtime_state, runtime_report, False),
            launch_failed, now,
        )
    try:
        session, runtime_state, runtime_report, superseded = sync_and_reconcile_runtime_evidence(
            store,
            session,
            getattr(args, "expected_build_manifests", None) or [],
            getattr(args, "cloudkit_schema_receipt", None),
            now,
        )
    except RuntimeEvidenceError:
        attempt = make_attempt(
            automation_state or new_automation_state(session, now),
            result="failed",
            reason_code="runtime-reconciliation-failed",
            started_at=started_at,
            finished_at=utc_now(),
            runtime_report=runtime_report,
        )
        automation_state = automation_store.record(session, attempt, now)
        return _finish_automation(
            args, store, session, automation_state, runtime_report,
            EXIT_UNKNOWN, launch_failed, now,
        )
    diagnostics = set(runtime_state.last_observation.diagnostics) if runtime_state.last_observation else set()
    if superseded:
        result, reason_code = "failed", "runtime-evidence-superseded"
    elif {"sync-unavailable", "status-unavailable", "export-unavailable"} & diagnostics:
        result, reason_code = "unsupported", "runtime-sync-unavailable"
    elif runtime_state.last_observation is None or runtime_state.last_observation.result != "healthy":
        result, reason_code = "failed", "runtime-sync-degraded"
    else:
        result, reason_code = "succeeded", "runtime-receipts-reconciled"
    attempt = make_attempt(
        automation_state or new_automation_state(session, now),
        result=result,
        reason_code=reason_code,
        started_at=started_at,
        finished_at=utc_now(),
        runtime_report=runtime_report,
    )
    automation_state = automation_store.record(session, attempt, now)
    return _finish_automation(
        args, store, session, automation_state, runtime_report,
        runtime_sync_exit_code(runtime_state, runtime_report, superseded),
        launch_failed, now,
    )


def run_advance_automation(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    store = SessionStateStore()
    initial_session = store.load(target, now=utc_now())
    if initial_session is None:
        raise RuntimeEvidenceError("signed validation session does not exist")
    automation_store = AutomationStore(store)
    with automation_store.advance_lock():
        now = utc_now()
        session = store.load(target, now=now)
        if session is None or session.id != initial_session.id:
            raise RuntimeEvidenceError("signed validation session changed during automation")
        return _run_advance_automation_locked(args, store, session, now)


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


def run_defer_action(args: argparse.Namespace) -> int:
    if not 1 <= args.duration_hours <= MAXIMUM_DEFERRAL_HOURS:
        raise OperatorFlowError(
            f"deferral duration must be between 1 and {MAXIMUM_DEFERRAL_HOURS} hours"
        )
    target = Target(args.version, args.build_number)
    now = utc_now()
    session_store = SessionStateStore()
    session = session_store.load(target, now=now)
    if session is None:
        raise OperatorFlowError("signed validation session does not exist")
    state, deferral = OperatorFlowStore(session_store).defer_action(
        session,
        args.action_id,
        args.owner,
        args.reason,
        args.residual_risk,
        now,
        timedelta(hours=args.duration_hours),
    )
    payload = {
        "schemaVersion": 1,
        "session": session.public_dict(),
        "operatorFlowRevision": state.revision,
        "deferral": {**deferral.to_dict(), "status": "active"},
        "evidenceSatisfied": False,
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(
            f"Deferred {deferral.action_id} until {deferral.expires_at}.\n"
            f"Residual risk remains: {deferral.residual_risk}."
        )
    return 0


def run_clear_deferral(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    now = utc_now()
    session_store = SessionStateStore()
    session = session_store.load(target, now=now)
    if session is None:
        raise OperatorFlowError("signed validation session does not exist")
    state, deferral = OperatorFlowStore(session_store).clear_deferral(
        session,
        args.action_id,
        now,
    )
    payload = {
        "schemaVersion": 1,
        "session": session.public_dict(),
        "operatorFlowRevision": state.revision,
        "deferral": {**deferral.to_dict(), "status": "cleared"},
        "evidenceSatisfied": False,
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(
            f"Cleared the deferral for {deferral.action_id}.\n"
            f"Residual risk remains until evidence is satisfied: {deferral.residual_risk}."
        )
    return 0


def _private_artifact_digest(path: Path | None) -> str | None:
    if path is None:
        return None
    try:
        digest = hashlib.sha256()
        with path.expanduser().open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError as error:
        raise VisualApprovalError("private visual review artifact is unavailable") from error


def run_record_visual_review(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    now = utc_now()
    store = SessionStateStore()
    session = store.load(target, now=now)
    if session is None:
        raise VisualApprovalError("signed validation session does not exist")
    runtime_state = RuntimeEvidenceStore(store).load(session)
    state, decision = VisualApprovalStore(store).record(
        session,
        args.requirement_id,
        args.decision,
        now,
        runtime_state,
        artifact_digest=_private_artifact_digest(args.artifact),
        host_os=args.host_os,
    )
    payload = {
        "schemaVersion": 1,
        "target": {
            "version": target.version,
            "buildNumber": target.build_number,
        },
        "planID": state.plan_id,
        "decision": decision.to_dict(),
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(
            f"Recorded {decision.decision} for visual requirement "
            f"{decision.requirement_id} at {decision.observed_at}."
        )
    return 0


def run_export_visual_reviews(args: argparse.Namespace) -> int:
    target = Target(args.version, args.build_number)
    now = utc_now()
    store = SessionStateStore()
    session = store.load(target, now=now)
    if session is None:
        raise VisualApprovalError("signed validation session does not exist")
    state = VisualApprovalStore(store).load(session)
    if state is None:
        raise VisualApprovalError("visual review requirements are not configured")
    payload = state.public_dict(RuntimeEvidenceStore(store).load(session))
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(
            f"Visual review {payload['state']}: {payload['approvedCount']} of "
            f"{payload['requirementCount']} requirements approved."
        )
    if payload["state"] == "rejected":
        return EXIT_BLOCKED
    if payload["state"] in {"waiting", "unknown"}:
        return EXIT_UNKNOWN
    if payload["state"] == "pending":
        return 10
    return 0


def run_capture_shared_view_evidence(args: argparse.Namespace) -> int:
    exit_code, receipt = execute_shared_view_capture(
        args.surface_comparison,
        args.current_manifest,
        args.requirements,
        args.capture_config,
        args.artifact_root,
        args.output,
        matrix_path=args.matrix,
        surface_policy_path=args.surface_policy,
    )
    if args.json:
        print(json.dumps(receipt, indent=2, sort_keys=True))
    else:
        captures = cast(list[dict[str, object]], receipt["captures"])
        print(
            f"Shared-view capture recorded {sum(item['status'] == 'captured' for item in captures)} "
            f"of {len(captures)} required captures."
        )
    return exit_code


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
        if args.command == "final-report":
            return run_final_report(args)
        if args.command == "plan-shared-view-evidence":
            return run_plan_shared_view_evidence(args)
        if args.command == "capture-shared-view-evidence":
            return run_capture_shared_view_evidence(args)
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
        if args.command == "advance-automation":
            return run_advance_automation(args)
        if args.command == "defer-action":
            return run_defer_action(args)
        if args.command == "clear-deferral":
            return run_clear_deferral(args)
        if args.command == "record-visual-review":
            return run_record_visual_review(args)
        if args.command == "export-visual-reviews":
            return run_export_visual_reviews(args)
        raise RuntimeError(f"unsupported command: {args.command}")
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return EXIT_INTERNAL
    except CoordinatorSessionConflictError as error:
        print(str(error), file=sys.stderr)
        return EXIT_BLOCKED
    except (CoordinatorSessionError, SharedViewCaptureError, SharedViewEvidenceError) as error:
        print(str(error), file=sys.stderr)
        return EXIT_UNKNOWN
    except Exception:
        print("Coordinator internal error; no evidence was recorded.", file=sys.stderr)
        return EXIT_INTERNAL
