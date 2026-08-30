import importlib.util
import contextlib
import copy
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SCRIPTS_PATH = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS_PATH))
PACKAGE_PATH = SCRIPTS_PATH / "context_panel_validation"
SPEC = importlib.util.spec_from_file_location(
    "context_panel_validation",
    PACKAGE_PATH / "__init__.py",
    submodule_search_locations=[str(PACKAGE_PATH)],
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {PACKAGE_PATH}")
context_panel_validation = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = context_panel_validation
SPEC.loader.exec_module(context_panel_validation)
cli_module = __import__("context_panel_validation.cli", fromlist=["main"])


NOW = datetime(2026, 8, 2, 3, 0, tzinfo=timezone.utc)
TARGET = context_panel_validation.Target("1.0.53", "202608020300")


def valid_asc():
    return context_panel_validation.ASCEvidence(
        "available",
        "direct_local_api",
        tuple(
            context_panel_validation.ASCPlatformEvidence(
                platform,
                "valid",
                "available",
                "VALID",
            )
            for platform in context_panel_validation.ASC_PLATFORMS
        ),
    )


def proven_mac(*, running=True, install_state="current"):
    return context_panel_validation.MacEvidence(
        TARGET.version,
        TARGET.build_number,
        install_state,
        "proven" if running else "identity_verified_app_not_running",
        "running" if running else "not_running",
        "testflight",
        "Production",
        "Production",
    )


def device(label, platform, *, condition="reachable", install_state="current", note="fixture"):
    version = TARGET.version if install_state == "current" else "1.0.52"
    build = TARGET.build_number if install_state == "current" else "202607300100"
    if install_state == "superseded":
        version = "1.0.54"
        build = "202608030100"
    if condition != "reachable":
        version = None
        build = None
        install_state = "unknown"
    return context_panel_validation.DeviceEvidence(
        label,
        platform,
        version,
        build,
        install_state,
        condition,
        note,
    )


def runtime_report(surface_states):
    surfaces = []
    for surface, state, reason in surface_states:
        surfaces.append(
            {
                "surface": surface,
                "state": state,
                "reason": reason,
                "receiptCount": 1 if state == "proven" else 0,
                "lastObservedAt": "2026-08-02T03:00:00Z" if state == "proven" else None,
                "latestStateBranch": "available" if state == "proven" else None,
                "latestOutcome": "success" if state == "proven" else None,
            }
        )
    states = {item["state"] for item in surfaces}
    if "superseded" in states:
        overall = "superseded"
    elif states == {"proven"}:
        overall = "proven"
    elif "waiting" in states:
        overall = "waiting"
    else:
        overall = "unknown"
    return {
        "schemaVersion": 1,
        "state": overall,
        "provenSurfaceCount": sum(item["state"] == "proven" for item in surfaces),
        "requestedSurfaceCount": len(surfaces),
        "lastReconciledAt": "2026-08-02T03:00:00Z",
        "runtimeSession": None,
        "diagnostics": [],
        "surfaces": surfaces,
    }


def operator_action(
    *,
    action_id,
    device_name,
    surfaces,
    duration_minutes=1,
    reason_code="device-access-required",
):
    return context_panel_validation.OperatorAction(
        device=device_name,
        estimate=f"about {duration_minutes} minutes",
        instruction="Complete the bounded validation action, then rerun status.",
        id=action_id,
        surfaces=tuple(surfaces),
        reason_code=reason_code,
        action_kind="status-follow-up",
        duration_minutes=duration_minutes,
        simulation_insufficiency={
            "code": "physical-device-interaction-required",
            "explanation": "The exact validation device requires an operator action.",
        },
    )


class OperatorFlowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.store = context_panel_validation.SessionStateStore(
            root=self.root,
            legacy_root=self.root / "Legacy",
        )

    def session(self, surfaces, *, duration=timedelta(hours=2), retention=timedelta(days=1)):
        state, _ = self.store.start_session(
            TARGET,
            tuple(surfaces),
            NOW,
            duration,
            retention,
        )
        return state

    def report(self, surfaces, *, mac=None, devices=(), restart=None, generated_at=NOW):
        return context_panel_validation.build_report(
            TARGET,
            valid_asc(),
            mac or proven_mac(),
            tuple(devices),
            restart,
            generated_at,
            requested_surfaces=tuple(surfaces),
        )

    def test_machine_waits_are_quiet_then_locked_device_escalates_once(self):
        surfaces = ("ios.app",)
        session = self.session(surfaces)
        report = self.report(
            surfaces,
            devices=(device("iPhone", "iOS", condition="locked"),),
        )
        flow_store = context_panel_validation.OperatorFlowStore(self.store)

        state, initial = flow_store.reconcile(session, report, None, NOW)
        state, still_waiting = flow_store.reconcile(
            session,
            report,
            None,
            NOW + timedelta(minutes=14),
        )
        state, escalated = flow_store.reconcile(
            session,
            report,
            None,
            NOW + timedelta(minutes=15),
        )

        self.assertEqual(initial["state"], "waiting")
        self.assertFalse(initial["groups"])
        self.assertFalse(still_waiting["groups"])
        self.assertEqual(escalated["state"], "ready")
        action = escalated["groups"][0]["actions"][0]
        self.assertEqual(action["notificationKind"], "manualUnlockRequired")
        self.assertIn("No extended awake period is required", action["instruction"])
        self.assertNotIn("keep awake", json.dumps(escalated).casefold())
        self.assertEqual(len(escalated["notificationDecisions"]), 1)

        reloaded = context_panel_validation.OperatorFlowStore(self.store).load(session)
        self.assertEqual(reloaded, state)

    def test_processing_and_active_receipt_propagation_never_queue_human_work(self):
        surfaces = ("macos.app",)
        session = self.session(surfaces)
        processing = context_panel_validation.ASCEvidence(
            "available",
            "direct_local_api",
            tuple(
                context_panel_validation.ASCPlatformEvidence(
                    platform,
                    "processing",
                    "processing",
                    "PROCESSING",
                )
                for platform in context_panel_validation.ASC_PLATFORMS
            ),
        )
        report = context_panel_validation.build_report(
            TARGET,
            processing,
            proven_mac(running=False),
            (),
            None,
            NOW,
            requested_surfaces=surfaces,
        )
        runtime = runtime_report((("macos.app", "waiting", "receipt-propagation"),))
        runtime["runtimeSession"] = {"result": "healthy"}

        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            runtime,
            NOW,
        )

        self.assertEqual(flow["state"], "waiting")
        self.assertFalse(flow["groups"])
        self.assertFalse(flow["notificationDecisions"])
        self.assertFalse(flow["runtimeDiagnostics"])

    def test_missing_required_physical_device_never_looks_complete(self):
        surfaces = ("ios.app",)
        session = self.session(surfaces)
        report = self.report(
            surfaces,
            devices=(device("iPhone", "iOS", condition="not_found"),),
        )

        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            None,
            NOW,
        )
        applied = context_panel_validation.apply_operator_flow_to_report(report, flow)

        self.assertEqual(applied.state, "ready_for_you")
        self.assertEqual(applied.exit_code, 10)
        self.assertEqual(flow["groups"][0]["actions"][0]["id"], "device.iphone.connect")
        self.assertEqual(
            flow["groups"][0]["actions"][0]["notificationKind"],
            "blockedDecisionRequired",
        )
        final_payload = context_panel_validation.build_final_report_payload(
            replace(applied, session=session.public_dict())
        )
        self.assertEqual(
            final_payload["obtainedEvidenceClasses"]["exactBuildRuntimeReceipts"][
                "required"
            ],
            1,
        )

    def test_watch_restart_is_grouped_and_attestation_removes_only_that_action(self):
        surfaces = ("watchos.app", "watchos.complication")
        session = self.session(surfaces)
        watch = device("Apple Watch", "watchOS")
        report = self.report(surfaces, devices=(watch,))
        runtime = runtime_report(
            (
                ("watchos.app", "proven", "exact-build-runtime-receipt"),
                ("watchos.complication", "waiting", "receipt-propagation"),
            )
        )
        flow_store = context_panel_validation.OperatorFlowStore(self.store)

        _, before = flow_store.reconcile(session, report, runtime, NOW)
        self.store.record_watch_restart(TARGET, NOW + timedelta(minutes=1))
        updated_session = self.store.load(TARGET, now=NOW + timedelta(minutes=1))
        updated_report = self.report(
            surfaces,
            devices=(watch,),
            restart=updated_session.watch_restart_recorded_at,
            generated_at=NOW + timedelta(minutes=1),
        )
        _, after = flow_store.reconcile(
            updated_session,
            updated_report,
            runtime,
            NOW + timedelta(minutes=1),
        )

        self.assertEqual(before["groups"][0]["actions"][0]["id"], "watchos.restart")
        self.assertEqual(
            before["groups"][0]["actions"][0]["notificationKind"],
            "restartRequired",
        )
        self.assertFalse(after["groups"])
        self.assertEqual(runtime["surfaces"][1]["state"], "waiting")

    def test_deferral_persists_expires_and_never_satisfies_runtime_evidence(self):
        surfaces = ("watchos.app",)
        session = self.session(surfaces)
        runtime = runtime_report((("watchos.app", "proven", "exact-build-runtime-receipt"),))
        report = replace(
            self.report(
                surfaces,
                devices=(device("Apple Watch", "watchOS"),),
            ),
            runtime_evidence=runtime,
        )
        flow_store = context_panel_validation.OperatorFlowStore(self.store)
        _, initial = flow_store.reconcile(session, report, runtime, NOW)
        action_id = initial["groups"][0]["actions"][0]["id"]

        flow_store.defer_action(
            session,
            action_id,
            "release-operator",
            "operator-unavailable",
            "review-pending",
            NOW + timedelta(minutes=1),
            timedelta(hours=1),
        )
        _, deferred = flow_store.reconcile(
            session,
            report,
            runtime,
            NOW + timedelta(minutes=2),
        )
        deferred_report = context_panel_validation.apply_operator_flow_to_report(
            report,
            deferred,
        )
        _, expired = flow_store.reconcile(
            session,
            report,
            runtime,
            NOW + timedelta(hours=1, minutes=2),
        )

        self.assertEqual(deferred["state"], "deferred")
        self.assertEqual(deferred_report.state, "ready_for_you")
        self.assertEqual(deferred_report.stage, "deferred")
        self.assertEqual(deferred_report.exit_code, 10)
        self.assertTrue(deferred_report.to_dict()["summary"]["needsHumanAction"])
        self.assertEqual(runtime["provenSurfaceCount"], 1)
        self.assertEqual(deferred["activeDeferrals"][0]["residualRisk"], "review-pending")
        self.assertEqual(expired["state"], "ready")
        self.assertEqual(expired["deferrals"][0]["status"], "expired")
        self.assertIn("review-pending", expired["residualRisks"])

    def test_stale_extension_recovery_is_bounded_and_non_destructive(self):
        surfaces = ("tvos.app", "tvos.top-shelf")
        session = self.session(surfaces)
        runtime = runtime_report(
            (
                ("tvos.app", "proven", "exact-build-runtime-receipt"),
                (
                    "tvos.top-shelf",
                    "diagnostic",
                    "app-current-extension-stale-or-silent",
                ),
            )
        )
        report = replace(
            self.report(surfaces, devices=(device("Apple TV", "tvOS"),)),
            state="unknown",
            stage="runtime evidence diagnostic",
            exit_code=30,
            actions=(),
            runtime_evidence=runtime,
        )

        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            runtime,
            NOW,
        )

        action = flow["groups"][0]["actions"][0]
        self.assertEqual(action["id"], "tvos.top-shelf.recover")
        self.assertEqual(action["notificationKind"], "blockedDecisionRequired")
        guidance = " ".join(action["recoverySteps"]).casefold()
        for destructive in ("uninstall", "reset container", "clear widgetkit", "reselect"):
            self.assertNotIn(destructive, guidance)
        self.assertIn("current surface placement", guidance)

    def test_receipt_silence_escalates_after_the_bounded_window(self):
        surfaces = ("visionos.widget",)
        session = self.session(surfaces)
        report = self.report(
            surfaces,
            devices=(device("Vision Pro", "visionOS"),),
        )
        waiting_runtime = runtime_report(
            (("visionos.widget", "waiting", "receipt-propagation"),)
        )
        silent_runtime = runtime_report(
            (("visionos.widget", "unknown", "receipt-silence"),)
        )
        flow_store = context_panel_validation.OperatorFlowStore(self.store)

        _, waiting = flow_store.reconcile(session, report, waiting_runtime, NOW)
        diagnostic_report = replace(
            report,
            state="unknown",
            stage="runtime evidence diagnostic",
            exit_code=30,
            actions=(),
            runtime_evidence=silent_runtime,
        )
        _, escalated = flow_store.reconcile(
            session,
            diagnostic_report,
            silent_runtime,
            NOW + timedelta(minutes=30),
        )

        self.assertFalse(waiting["groups"])
        self.assertEqual(
            escalated["groups"][0]["actions"][0]["notificationKind"],
            "blockedDecisionRequired",
        )
        self.assertEqual(diagnostic_report.exit_code, 30)

    def test_notification_decisions_are_allowlisted_stable_and_deduplicated(self):
        surfaces = ("watchos.app",)
        session = self.session(surfaces)
        runtime = runtime_report((("watchos.app", "proven", "exact-build-runtime-receipt"),))
        report = replace(
            self.report(
                surfaces,
                devices=(device("Apple Watch", "watchOS"),),
            ),
            runtime_evidence=runtime,
        )
        flow_store = context_panel_validation.OperatorFlowStore(self.store)

        _, first = flow_store.reconcile(session, report, runtime, NOW)
        _, second = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            runtime,
            NOW + timedelta(minutes=1),
        )

        self.assertEqual(first["notificationDecisions"], second["notificationDecisions"])
        self.assertEqual(len(second["notificationDecisions"]), 1)
        self.assertIn(
            second["notificationDecisions"][0]["kind"],
            context_panel_validation.NOTIFICATION_KINDS,
        )
        invalid = dict(second["notificationDecisions"][0])
        invalid["kind"] = "sendAnything"
        with self.assertRaises(context_panel_validation.OperatorFlowError):
            context_panel_validation.NotificationDecision.from_dict(invalid)
        for kind in context_panel_validation.NOTIFICATION_KINDS:
            valid = dict(second["notificationDecisions"][0])
            valid["kind"] = kind
            valid["id"] = "a" * 64
            context_panel_validation.NotificationDecision.from_dict(valid)

    def test_terminal_sessions_never_generate_fresh_actions_or_notifications(self):
        for lifecycle, reason in (
            ("completed", "evidence-complete"),
            ("superseded", "newer-build-observed"),
        ):
            with self.subTest(lifecycle=lifecycle), tempfile.TemporaryDirectory() as temp_dir:
                store = context_panel_validation.SessionStateStore(
                    root=Path(temp_dir),
                    legacy_root=Path(temp_dir) / "Legacy",
                )
                session, _ = store.start_session(
                    TARGET,
                    ("watchos.app",),
                    NOW,
                    timedelta(hours=2),
                    timedelta(days=1),
                )
                closed = store.transition(
                    TARGET,
                    lifecycle,
                    NOW + timedelta(minutes=1),
                    reason,
                )
                report = replace(
                    context_panel_validation.build_report(
                        TARGET,
                        valid_asc(),
                        proven_mac(),
                        (device("Apple Watch", "watchOS"),),
                        None,
                        NOW + timedelta(minutes=1),
                        requested_surfaces=("watchos.app",),
                    ),
                    runtime_evidence=runtime_report(
                        (("watchos.app", "proven", "exact-build-runtime-receipt"),)
                    ),
                )

                _, flow = context_panel_validation.OperatorFlowStore(store).reconcile(
                    closed,
                    report,
                    report.runtime_evidence,
                    NOW + timedelta(minutes=1),
                )

                self.assertFalse(flow["groups"])
                self.assertFalse(flow["notificationDecisions"])
                self.assertEqual(flow["readyActionCount"], 0)

    def test_reachability_escalation_and_group_order_are_deterministic(self):
        surfaces = ("ios.app", "ipados.app", "visionos.app", "tvos.app")
        session = self.session(surfaces)
        devices = (
            device("Apple TV", "tvOS", condition="unavailable"),
            device("Vision Pro", "visionOS", condition="asleep"),
            device("iPad", "iOS", condition="not_reachable"),
            device("iPhone 2", "iOS", condition="locked"),
        )
        report = self.report(surfaces, devices=devices)
        flow_store = context_panel_validation.OperatorFlowStore(self.store)
        flow_store.reconcile(session, report, None, NOW)

        _, escalated = flow_store.reconcile(
            session,
            report,
            None,
            NOW + timedelta(minutes=30),
        )

        self.assertEqual(
            [group["device"] for group in escalated["groups"]],
            ["iPhone 2", "iPad", "Vision Pro", "Apple TV"],
        )
        kinds = {
            group["device"]: group["actions"][0]["notificationKind"]
            for group in escalated["groups"]
        }
        self.assertEqual(kinds["iPhone 2"], "manualUnlockRequired")
        self.assertEqual(kinds["Vision Pro"], "manualUnlockRequired")
        self.assertEqual(kinds["iPad"], "blockedDecisionRequired")
        self.assertEqual(kinds["Apple TV"], "blockedDecisionRequired")

    def test_top_level_runtime_diagnostic_prevents_a_reassuring_final_report(self):
        surfaces = ("macos.app",)
        session = self.session(surfaces)
        runtime = runtime_report((("macos.app", "proven", "exact-build-runtime-receipt"),))
        runtime["runtimeSession"] = {
            "id": "00000000-0000-0000-0000-000000000001",
            "active": True,
            "expiresAt": "2026-08-02T04:00:00Z",
            "result": "degraded",
        }
        runtime["diagnostics"] = ["export-timeout"]
        report = replace(self.report(surfaces), runtime_evidence=runtime)

        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            runtime,
            NOW,
        )
        applied = context_panel_validation.apply_operator_flow_to_report(report, flow)
        final_payload = context_panel_validation.build_final_report_payload(
            replace(applied, session=session.public_dict())
        )
        markdown = context_panel_validation.render_final_report(
            replace(applied, session=session.public_dict())
        )

        self.assertEqual(applied.state, "unknown")
        self.assertEqual(applied.exit_code, 30)
        self.assertIn("export-timeout", flow["runtimeDiagnostics"])
        self.assertIn(
            "runtime-session-degraded",
            flow["runtimeDiagnostics"],
        )
        self.assertEqual(
            final_payload["obtainedEvidenceClasses"]["exactBuildRuntimeReceipts"][
                "runtimeSessionResult"
            ],
            "degraded",
        )
        self.assertEqual(
            final_payload["obtainedEvidenceClasses"]["exactBuildRuntimeReceipts"][
                "diagnostics"
            ],
            ["export-timeout"],
        )
        self.assertIn("`export-timeout`", markdown)

    def test_superseded_target_stays_blocked_while_exposing_one_decision(self):
        surfaces = ("macos.app",)
        session = self.session(surfaces)
        report = self.report(surfaces, mac=proven_mac(install_state="superseded"))

        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            None,
            NOW,
        )
        applied = context_panel_validation.apply_operator_flow_to_report(report, flow)

        self.assertEqual(applied.state, "blocked")
        self.assertEqual(applied.exit_code, 20)
        self.assertEqual(flow["notificationDecisions"][0]["kind"], "blockedDecisionRequired")

    def test_final_report_is_github_ready_and_omits_private_inputs(self):
        surfaces = ("macos.app",)
        session = self.session(surfaces)
        runtime = runtime_report((("macos.app", "proven", "exact-build-runtime-receipt"),))
        private_note = (
            "/Users/private/secret.p8 device=00008101 account@example.com "
            "asc-id-123 xcrun devicectl device info --device 00008101"
        )
        report = context_panel_validation.build_report(
            TARGET,
            valid_asc(),
            proven_mac(),
            (device("iPhone", "iOS", note=private_note),),
            None,
            NOW,
            requested_surfaces=surfaces,
        )
        report = replace(
            report,
            session=session.public_dict(),
            runtime_evidence=runtime,
        )
        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            runtime,
            NOW,
        )
        report = context_panel_validation.apply_operator_flow_to_report(report, flow)

        payload = context_panel_validation.build_final_report_payload(report)
        markdown = context_panel_validation.render_final_report(report)
        serialized = json.dumps(payload) + markdown

        self.assertIn("# Signed Validation Report", markdown)
        self.assertEqual(payload["target"]["version"], TARGET.version)
        self.assertEqual(payload["carryForwardLineage"]["state"], "not-evaluated")
        for private_value in (
            "/Users/private",
            "secret.p8",
            "00008101",
            "account@example.com",
            "asc-id-123",
            "xcrun devicectl",
            "--device 00008101",
            session.id,
        ):
            self.assertNotIn(private_value, serialized)

    def test_sidecar_is_schema_v1_private_and_pruned_with_parent_retention(self):
        surfaces = ("watchos.app",)
        session = self.session(
            surfaces,
            duration=timedelta(hours=1),
            retention=timedelta(hours=1),
        )
        runtime = runtime_report((("watchos.app", "proven", "exact-build-runtime-receipt"),))
        report = replace(
            self.report(
                surfaces,
                devices=(device("Apple Watch", "watchOS"),),
            ),
            runtime_evidence=runtime,
        )
        context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            runtime,
            NOW,
        )
        sidecar = self.store.operator_flow_path(session.id)
        session_payload = json.loads(self.store.path(TARGET).read_text())
        sidecar_payload = json.loads(sidecar.read_text())

        self.assertEqual(session_payload["schemaVersion"], 1)
        self.assertNotIn("operatorFlow", session_payload)
        self.assertEqual(sidecar_payload["schemaVersion"], 1)
        self.assertEqual(stat.S_IMODE(sidecar.stat().st_mode), 0o600)
        serialized = json.dumps(sidecar_payload)
        for forbidden in ("deviceIdentifier", "account", "credential", "rawReceipt", "/Users/"):
            self.assertNotIn(forbidden, serialized)

        self.store.transition(
            TARGET,
            "completed",
            NOW + timedelta(minutes=30),
            "evidence-complete",
        )
        self.store.prune(NOW + timedelta(hours=2, minutes=1))
        self.assertFalse(sidecar.exists())

    def test_parser_exposes_bounded_deferral_and_final_report_commands(self):
        defer = cli_module.parse_args(
            [
                "defer-action",
                "--version",
                TARGET.version,
                "--build-number",
                TARGET.build_number,
                "--action-id",
                "watchos.restart",
                "--owner",
                "release-operator",
                "--reason",
                "operator-unavailable",
                "--residual-risk",
                "restart-unconfirmed",
                "--duration-hours",
                "4",
            ]
        )
        final = cli_module.parse_args(
            [
                "final-report",
                "--version",
                TARGET.version,
                "--build-number",
                TARGET.build_number,
                "--json",
            ]
        )

        self.assertEqual(defer.action_id, "watchos.restart")
        self.assertEqual(defer.duration_hours, 4)
        self.assertEqual(final.command, "final-report")
        self.assertTrue(final.json)

    def test_deferral_and_final_report_cli_paths_preserve_exit_and_privacy_contracts(self):
        surfaces = ("watchos.app",)
        session = self.session(surfaces)
        runtime = runtime_report((("watchos.app", "proven", "exact-build-runtime-receipt"),))
        report = replace(
            self.report(
                surfaces,
                devices=(device("Apple Watch", "watchOS"),),
            ),
            session=session.public_dict(),
            runtime_evidence=runtime,
        )
        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            runtime,
            NOW,
        )
        report = context_panel_validation.apply_operator_flow_to_report(report, flow)
        defer_args = SimpleNamespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            action_id="watchos.restart",
            owner="release-operator",
            reason="operator-unavailable",
            residual_risk="restart-unconfirmed",
            duration_hours=1,
            json=True,
        )
        clear_args = SimpleNamespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            action_id="watchos.restart",
            json=True,
        )
        final_args = SimpleNamespace(json=True)

        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(self.root)},
                clear=False,
            ),
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=1)),
            contextlib.redirect_stdout(io.StringIO()) as deferred_output,
        ):
            self.assertEqual(cli_module.run_defer_action(defer_args), 0)
        deferred_payload = json.loads(deferred_output.getvalue())
        self.assertFalse(deferred_payload["evidenceSatisfied"])

        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(self.root)},
                clear=False,
            ),
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=2)),
            contextlib.redirect_stdout(io.StringIO()) as cleared_output,
        ):
            self.assertEqual(cli_module.run_clear_deferral(clear_args), 0)
        cleared_payload = json.loads(cleared_output.getvalue())
        self.assertEqual(cleared_payload["deferral"]["status"], "cleared")

        with (
            mock.patch.object(cli_module, "collect_validation_report", return_value=report),
            contextlib.redirect_stdout(io.StringIO()) as final_output,
        ):
            self.assertEqual(cli_module.run_final_report(final_args), 10)
        final_payload = json.loads(final_output.getvalue())
        self.assertNotIn(session.id, json.dumps(final_payload))

    def test_operator_flow_sidecar_rejects_symlinks_and_unknown_schema(self):
        surfaces = ("macos.app",)
        session = self.session(surfaces)
        directory = self.store.operator_flow_directory
        directory.mkdir(parents=True)
        path = self.store.operator_flow_path(session.id)
        external = self.root / "external.json"
        external.write_text("{}")
        path.symlink_to(external)

        with self.assertRaises(context_panel_validation.OperatorFlowError):
            context_panel_validation.OperatorFlowStore(self.store).load(session)

        path.unlink()
        payload = context_panel_validation.OperatorFlowState(
            schema_version=1,
            coordinator_session_id=session.id,
            target=TARGET,
            requested_surfaces=surfaces,
            created_at="2026-08-02T03:00:00Z",
            updated_at="2026-08-02T03:00:00Z",
            revision=1,
            waits=(),
            deferrals=(),
            notification_decisions=(),
            last_action_ids=(),
        ).to_dict()
        payload["schemaVersion"] = 2
        path.write_text(json.dumps(payload))
        os.chmod(path, 0o600)

        with self.assertRaises(context_panel_validation.OperatorFlowError):
            context_panel_validation.OperatorFlowStore(self.store).load(session)

    def test_ready_visual_review_batch_uses_reserved_notification_kind(self):
        surfaces = ("watchos.complication",)
        session = self.session(surfaces)
        report = replace(
            self.report(
                surfaces,
                devices=(device("Apple Watch", "watchOS"),),
                restart="2026-08-02T03:00:00Z",
            ),
            visual_approvals={
                "state": "pending",
                "requirementCount": 1,
                "approvedCount": 0,
                "rejectedCount": 0,
                "readyReviewCount": 1,
                "machineWaitingCount": 0,
                "requirements": [
                    {
                        "id": "watch.complication.placement.corner",
                        "surface": "watchos.complication",
                        "device": "Apple Watch",
                    }
                ],
                "reviewBatches": [
                    {
                        "actionID": "review.apple-watch",
                        "device": "Apple Watch",
                        "requirementIDs": ["watch.complication.placement.corner"],
                        "surfaces": ["watchos.complication"],
                        "requiresRuntime": True,
                        "instruction": "Review one placement glance on Apple Watch.",
                        "estimateMinutes": 2,
                    }
                ],
            },
        )
        runtime = runtime_report(
            (("watchos.complication", "proven", "exact-build-runtime-receipt"),)
        )

        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            runtime,
            NOW,
        )

        action = flow["groups"][0]["actions"][0]
        self.assertEqual(action["id"], "review.apple-watch")
        self.assertEqual(action["notificationKind"], "readyForHumanReview")
        self.assertEqual(flow["readyActionCount"], 1)

    def test_placement_review_batch_is_suppressed_until_runtime_is_proven(self):
        surfaces = ("watchos.complication",)
        session = self.session(surfaces)
        report = replace(
            self.report(
                surfaces,
                devices=(device("Apple Watch", "watchOS"),),
                restart="2026-08-02T03:00:00Z",
            ),
            visual_approvals={
                "state": "waiting",
                "requirements": [
                    {
                        "id": "watch.complication.placement.corner",
                        "surface": "watchos.complication",
                        "device": "Apple Watch",
                    }
                ],
                "reviewBatches": [
                    {
                        "actionID": "review.apple-watch",
                        "device": "Apple Watch",
                        "requirementIDs": ["watch.complication.placement.corner"],
                        "surfaces": ["watchos.complication"],
                        "requiresRuntime": True,
                        "instruction": "Review one placement glance on Apple Watch.",
                        "estimateMinutes": 2,
                    }
                ],
            },
        )
        runtime = runtime_report(
            (("watchos.complication", "waiting", "receipt-propagation"),)
        )

        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            runtime,
            NOW,
        )

        self.assertFalse(flow["groups"])
        self.assertEqual(flow["readyActionCount"], 0)

    def test_shared_view_only_action_uses_visual_scope_without_runtime_surfaces(self):
        session = self.session(())
        report = replace(
            self.report(()),
            visual_approvals={
                "state": "pending",
                "requirementCount": 1,
                "approvedCount": 0,
                "rejectedCount": 0,
                "readyReviewCount": 1,
                "machineWaitingCount": 0,
                "requirements": [
                    {
                        "id": "watch.app.shared.dark",
                        "evidenceClass": "shared-view",
                        "surface": "watchos.app",
                        "device": "Apple Watch",
                        "state": "ready",
                        "reason": "review-ready",
                    }
                ],
                "reviewBatches": [
                    {
                        "actionID": "review.apple-watch",
                        "device": "Apple Watch",
                        "requirementIDs": ["watch.app.shared.dark"],
                        "surfaces": ["watchos.app"],
                        "requiresRuntime": False,
                        "instruction": "Review the signed Watch app.",
                        "estimateMinutes": 2,
                    }
                ],
            },
        )

        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            None,
            NOW,
        )
        applied = context_panel_validation.apply_operator_flow_to_report(report, flow)
        payload = context_panel_validation.build_final_report_payload(
            replace(applied, session=session.public_dict())
        )

        self.assertEqual(flow["groups"][0]["actions"][0]["surfaces"], ["watchos.app"])
        self.assertEqual(payload["operatorFlow"]["totalDurationMinutes"], 2)

        blocked_report = replace(report, state="blocked")
        _, blocked_flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            blocked_report,
            None,
            NOW,
        )
        blocked_action = next(
            action
            for group in blocked_flow["groups"]
            for action in group["actions"]
            if action["id"] == "coordinator.blocked-decision"
        )
        self.assertEqual(blocked_action["surfaces"], ["watchos.app"])

        diagnostic_runtime = runtime_report(())
        diagnostic_runtime["diagnostics"] = ["relay-export-unavailable"]
        _, diagnostic_flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            diagnostic_runtime,
            NOW,
        )
        diagnostic_action = next(
            action
            for group in diagnostic_flow["groups"]
            for action in group["actions"]
            if action["id"] == "coordinator.runtime-diagnostic"
        )
        self.assertEqual(diagnostic_action["surfaces"], ["watchos.app"])

    def test_base_actions_preserve_non_destructive_recovery_steps(self):
        surfaces = ("macos.app", "watchos.app")
        session = self.session(surfaces)
        report = self.report(
            surfaces,
            mac=proven_mac(running=False),
            devices=(device("Apple Watch", "watchOS"),),
        )

        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            None,
            NOW,
        )
        actions = {
            action["id"]: action
            for group in flow["groups"]
            for action in group["actions"]
        }

        self.assertIn("widget placements", " ".join(actions["macos.app.open"]["recoverySteps"]))
        self.assertIn(
            "complication placements intact",
            " ".join(actions["watchos.restart"]["recoverySteps"]),
        )

    def test_candidate_sources_emit_complete_public_action_contracts(self):
        surfaces = ("macos.app", "ios.app", "visionos.app", "watchos.app")
        session = self.session(surfaces)
        flow_store = context_panel_validation.OperatorFlowStore(self.store)
        seen_action_ids = set()

        def reconcile(report, runtime, now):
            _, flow = flow_store.reconcile(session, report, runtime, now)
            for group in flow["groups"]:
                for action in group["actions"]:
                    seen_action_ids.add(action["id"])
                    self.assertEqual(
                        set(action["simulationInsufficiency"]),
                        {"code", "explanation"},
                    )
                    self.assertTrue(action["simulationInsufficiency"]["explanation"])
                    self.assertTrue(action["surfaces"])
                    self.assertTrue(set(action["surfaces"]).issubset(surfaces))
                    self.assertIn(action["reasonCode"], context_panel_validation.REASON_CODES)
                    self.assertIn(action["actionKind"], context_panel_validation.ACTION_KINDS)
                    self.assertGreaterEqual(action["durationMinutes"], 1)
                    self.assertLessEqual(action["durationMinutes"], 60)

        reconcile(
            self.report(
                surfaces,
                mac=proven_mac(running=False),
                devices=(device("Apple Watch", "watchOS"),),
            ),
            None,
            NOW,
        )
        reconcile(
            self.report(surfaces, devices=(device("iPhone", "iOS", condition="not_found"),)),
            None,
            NOW,
        )
        locked = self.report(surfaces, devices=(device("iPhone", "iOS", condition="locked"),))
        reconcile(locked, None, NOW)
        reconcile(locked, None, NOW + timedelta(minutes=15))
        unavailable = self.report(
            surfaces,
            devices=(device("iPhone", "iOS", condition="unavailable"),),
        )
        reconcile(unavailable, None, NOW)
        reconcile(unavailable, None, NOW + timedelta(minutes=30))
        reconcile(
            self.report(surfaces),
            runtime_report(
                (("visionos.app", "diagnostic", "app-current-extension-stale-or-silent"),)
            ),
            NOW,
        )
        diagnostic_runtime = runtime_report((("macos.app", "proven", "receipt"),))
        diagnostic_runtime["diagnostics"] = ["export-timeout"]
        reconcile(self.report(surfaces), diagnostic_runtime, NOW)
        reconcile(
            replace(
                self.report(surfaces),
                visual_approvals={
                    "state": "pending",
                    "requirements": [
                        {
                            "id": "watch.app.shared.dark",
                            "surface": "watchos.app",
                            "device": "Apple Watch",
                        }
                    ],
                    "reviewBatches": [
                        {
                            "actionID": "review.apple-watch",
                            "device": "Apple Watch",
                            "requirementIDs": ["watch.app.shared.dark"],
                            "surfaces": ["watchos.app"],
                            "requiresRuntime": False,
                            "instruction": "Review the signed Watch app.",
                            "estimateMinutes": 2,
                        }
                    ],
                },
            ),
            None,
            NOW,
        )
        reconcile(self.report(surfaces, mac=proven_mac(install_state="superseded")), None, NOW)

        self.assertTrue(
            {
                "macos.app.open",
                "watchos.restart",
                "device.iphone.connect",
                "device.iphone.access",
                "visionos.app.recover",
                "coordinator.runtime-diagnostic",
                "review.apple-watch",
                "coordinator.blocked-decision",
            }.issubset(seen_action_ids)
        )

    def test_invalid_contract_rejects_before_operator_sidecar_write(self):
        surfaces = ("macos.app",)
        session = self.session(surfaces)
        flow_store = context_panel_validation.OperatorFlowStore(self.store)
        valid = operator_action(
            action_id="macos.contract",
            device_name="Mac",
            surfaces=surfaces,
        )
        invalid_actions = (
            replace(valid, simulation_insufficiency=None),
            replace(valid, reason_code="unknown-reason"),
            replace(valid, surfaces=()),
            replace(valid, surfaces=("watchos.app",)),
            replace(valid, duration_minutes=0),
            replace(
                valid,
                instruction="Run xcrun devicectl with --device 00008101, then rerun status.",
            ),
            replace(
                valid,
                instruction="Contact account@example.com before continuing.",
            ),
            replace(
                valid,
                instruction="Use physical device serial C39ABC123456 before continuing.",
            ),
        )

        for action in invalid_actions:
            with self.subTest(action=action):
                report = replace(self.report(surfaces), actions=(action,))
                with self.assertRaisesRegex(
                    context_panel_validation.OperatorFlowError,
                    "operator action contract",
                ):
                    flow_store.reconcile(session, report, None, NOW)
                self.assertFalse(self.store.operator_flow_path(session.id).exists())

        malformed_visual = replace(
            self.report(surfaces),
            visual_approvals={
                "state": "pending",
                "requirements": [
                    {
                        "id": "mac.app.shared.dark",
                        "surface": "macos.app",
                        "device": "Mac",
                    }
                ],
                "reviewBatches": [
                    {
                        "actionID": "review.mac",
                        "device": "Mac",
                        "requirementIDs": ["mac.app.shared.dark"],
                        "surfaces": ["watchos.app"],
                        "requiresRuntime": False,
                        "instruction": "Review the signed Mac app.",
                        "estimateMinutes": 2,
                    }
                ],
            },
        )
        with self.assertRaisesRegex(context_panel_validation.OperatorFlowError, "visual review batch"):
            flow_store.reconcile(session, malformed_visual, None, NOW)
        self.assertFalse(self.store.operator_flow_path(session.id).exists())

    def test_operator_action_contract_reports_aggregate_budget_and_bounds_each_action(self):
        surfaces = ("macos.app",)
        session = self.session(surfaces)
        flow_store = context_panel_validation.OperatorFlowStore(self.store)
        report = replace(
            self.report(surfaces),
            actions=(
                operator_action(
                    action_id="macos.first",
                    device_name="Mac",
                    surfaces=surfaces,
                    duration_minutes=16,
                ),
                operator_action(
                    action_id="macos.second",
                    device_name="Mac",
                    surfaces=surfaces,
                    duration_minutes=16,
                ),
            ),
        )
        _, flow = flow_store.reconcile(session, report, None, NOW)
        self.assertEqual(flow["groups"][0]["durationMinutes"], 32)
        self.assertEqual(flow["totalDurationMinutes"], 32)

        other_root = self.root / "over-budget"
        other_store = context_panel_validation.SessionStateStore(
            root=other_root,
            legacy_root=other_root / "Legacy",
        )
        other_session, _ = other_store.start_session(
            TARGET,
            surfaces,
            NOW,
            timedelta(hours=2),
            timedelta(days=1),
        )
        invalid_report = replace(
            self.report(surfaces),
            actions=(
                operator_action(
                    action_id="macos.over-budget",
                    device_name="Mac",
                    surfaces=surfaces,
                    duration_minutes=61,
                ),
            ),
        )
        with self.assertRaisesRegex(
            context_panel_validation.OperatorFlowError,
            "operator action contract",
        ):
            context_panel_validation.OperatorFlowStore(other_store).reconcile(
                other_session,
                invalid_report,
                None,
                NOW,
            )
        self.assertFalse(other_store.operator_flow_path(other_session.id).exists())

    def test_final_report_rejects_hand_edited_action_contract(self):
        surfaces = ("watchos.app",)
        session = self.session(surfaces)
        report = replace(
            self.report(
                surfaces,
                devices=(device("Apple Watch", "watchOS"),),
            ),
            session=session.public_dict(),
        )
        _, flow = context_panel_validation.OperatorFlowStore(self.store).reconcile(
            session,
            report,
            None,
            NOW,
        )
        malformed = copy.deepcopy(flow)
        malformed["groups"][0]["actions"][0]["reasonCode"] = "unknown-reason"

        with self.assertRaisesRegex(
            context_panel_validation.OperatorFlowError,
            "operator action contract",
        ):
            context_panel_validation.build_final_report_payload(
                replace(report, operator_flow=malformed)
            )


if __name__ == "__main__":
    unittest.main()
