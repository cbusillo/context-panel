import argparse
import contextlib
import io
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_validation import (
    AutomationError,
    AutomationStore,
    CommandResult,
    CoordinatorSessionState,
    CoordinatorSessionStateError,
    ExpectedSurfaceIdentity,
    MacEvidence,
    RuntimeEvidenceStore,
    RuntimeSessionObservation,
    SessionStateStore,
    Target,
    build_automation_report,
    make_attempt,
    new_automation_state,
)
from context_panel_validation import cli as cli_module
from context_panel_validation import operator_flow as operator_flow_module


NOW = datetime(2026, 8, 30, 12, 0, tzinfo=timezone.utc)
TARGET = Target("1.0.54", "202608300100")
SURFACES = ("macos.app",)
SHA = "a" * 64
UUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"


def runtime_status(
    *,
    active: bool = True,
    session_id: str = "00000000-0000-0000-0000-000000000001",
    expires_at: str = "2026-08-30T12:30:00Z",
) -> dict[str, object]:
    return {
        "active": active,
        "valid": True,
        "id": session_id,
        "createdAt": "2026-08-30T12:00:00Z",
        "expiresAt": expires_at,
        "expectedManifestID": SHA,
        "enabledSurfaces": ["macos.app"],
        "receiptCount": 0,
        "localReceiptCount": 0,
        "remoteReceiptCount": 0,
        "retainedSessionCount": 1,
        "retainedSessionIDs": [session_id],
        "observedSurfaces": [],
    }


def runtime_observation(
    *,
    healthy: bool = True,
    diagnostics: tuple[str, ...] | None = None,
    observed_at: datetime = NOW,
    session_id: str = "00000000-0000-0000-0000-000000000001",
    expires_at: str = "2026-08-30T12:30:00Z",
) -> RuntimeSessionObservation:
    status = runtime_status(session_id=session_id, expires_at=expires_at)
    return RuntimeSessionObservation(
        observed_at,
        {
            "healthy": healthy,
            "sessionAction": "unchanged" if healthy else "failed",
            "uploadedReceiptCount": 0,
            "downloadedReceiptCount": 0,
            "deletedRemoteReceiptCount": 0,
            "messages": [],
        },
        status,
        {
            "schemaVersion": 1,
            "active": True,
            "exportedAt": "2026-08-30T12:00:01Z",
            "session": {
                "schemaVersion": 1,
                "id": status["id"],
                "createdAt": status["createdAt"],
                "expiresAt": status["expiresAt"],
                "expectedManifestID": SHA,
                "enabledSurfaces": ["macos.app"],
                "minimumWriteIntervalSeconds": 30,
                "receiptTTLSeconds": 86400,
                "maximumReceiptCount": 128,
            },
            "receiptCount": 0,
            "localReceiptCount": 0,
            "remoteReceiptCount": 0,
            "receipts": [],
        },
        diagnostics if diagnostics is not None else () if healthy else ("sync-degraded",),
    )


def expected_identity() -> ExpectedSurfaceIdentity:
    return ExpectedSurfaceIdentity(
        surface="macos.app",
        platform="macOS",
        artifact_id="macos.app",
        bundle_identifier="com.shinycomputers.contextpanel",
        marketing_version=TARGET.version,
        build_number=TARGET.build_number,
        manifest_id=SHA,
        contract_fingerprint="b" * 64,
        render_fingerprint="c" * 64,
        runtime_fingerprint="d" * 64,
        placement_fingerprint="e" * 64,
        combined_fingerprint="f" * 64,
        executable_uuids=(UUID,),
        expected_build_id="1" * 64,
    )


def mac_evidence(
    *,
    baseline_state: str = "identity_verified_app_not_running",
    process_state: str = "not_running",
) -> MacEvidence:
    return MacEvidence(
        TARGET.version,
        TARGET.build_number,
        "current",
        baseline_state,
        process_state,
        "TestFlight",
        "Production",
        "Production",
        None,
    )


class ValidationAutomationTests(unittest.TestCase):
    def setUp(self) -> None:
        patcher = mock.patch.object(
            cli_module,
            "collect_mac_evidence",
            return_value=MacEvidence(
                None,
                None,
                "not_installed",
                "install_missing",
                "not_running",
                "unknown",
                "unknown",
                "unknown",
                "canonical app is not installed",
            ),
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        sleep_patcher = mock.patch.object(cli_module.time, "sleep")
        sleep_patcher.start()
        self.addCleanup(sleep_patcher.stop)

    @staticmethod
    def fixture(*, attach_runtime: bool = True) -> tuple[
        tempfile.TemporaryDirectory[str],
        SessionStateStore,
        CoordinatorSessionState,
    ]:
        temporary = tempfile.TemporaryDirectory()
        store = SessionStateStore(Path(temporary.name) / "Coordinator")
        session, _ = store.start_session(
            TARGET,
            SURFACES,
            NOW,
            timedelta(hours=72),
            timedelta(days=30),
        )
        if attach_runtime:
            runtime_store = RuntimeEvidenceStore(store)
            runtime_store.attach_expected(session, (expected_identity(),), NOW)
        return temporary, store, session

    def test_state_round_trip_is_public_safe_and_rejects_tampering(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        automation_store = AutomationStore(store)
        initial = new_automation_state(session, NOW)
        attempt = make_attempt(
            initial,
            result="skipped-precondition",
            reason_code="runtime-evidence-unavailable",
            started_at=NOW,
            finished_at=NOW,
            runtime_report=None,
        )
        state = automation_store.record(session, attempt, NOW)
        payload = state.to_dict()

        self.assertEqual(AutomationStore(store).load(session), state)
        serialized = json.dumps(payload)
        self.assertNotIn(session.id, serialized)
        self.assertNotIn(TARGET.version, serialized)
        self.assertNotIn(str(store.root), serialized)
        payload["attempts"][0]["reasonCode"] = "private-message"
        store.automation_path(session.id).write_text(json.dumps(payload))
        with self.assertRaises(AutomationError):
            automation_store.load(session)

    def test_sidecar_uses_mode_0600_rejects_symlinks_and_prunes_with_session(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        automation_store = AutomationStore(store)
        state = new_automation_state(session, NOW)
        attempt = make_attempt(
            state,
            result="skipped-precondition",
            reason_code="runtime-evidence-unavailable",
            started_at=NOW,
            finished_at=NOW,
            runtime_report=None,
        )
        automation_store.record(session, attempt, NOW)
        path = store.automation_path(session.id)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(list(path.parent.glob(f".{path.name}.*")), [])

        store.transition(TARGET, "stopped", NOW + timedelta(minutes=1), "operator-stopped")
        store.prune(NOW + timedelta(days=34))
        self.assertFalse(path.exists())

        outside = Path(temporary.name) / "outside"
        outside.mkdir()
        store.automation_directory.rmdir()
        store.automation_directory.symlink_to(outside)
        with self.assertRaises(CoordinatorSessionStateError):
            automation_store.record(session, attempt, NOW)

    def test_state_binds_session_target_and_requested_surfaces_and_limits_attempts(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        automation_store = AutomationStore(store)
        state = new_automation_state(session, NOW)
        for index in range(64):
            attempt = make_attempt(
                state,
                result="skipped-precondition",
                reason_code="runtime-evidence-unavailable",
                started_at=NOW + timedelta(minutes=index),
                finished_at=NOW + timedelta(minutes=index),
                runtime_report=None,
            )
            state = automation_store.record(session, attempt, NOW + timedelta(minutes=index))
        self.assertEqual(build_automation_report(state)["remainingAttemptCount"], 0)
        with self.assertRaises(AutomationError):
            automation_store.record(
                session,
                make_attempt(
                    state,
                    result="skipped-precondition",
                    reason_code="runtime-evidence-unavailable",
                    started_at=NOW + timedelta(hours=2),
                    finished_at=NOW + timedelta(hours=2),
                    runtime_report=None,
                ),
                NOW + timedelta(hours=2),
            )
        payload = state.to_dict()
        payload["targetDigest"] = "0" * 64
        store.automation_path(session.id).write_text(json.dumps(payload))
        with self.assertRaises(AutomationError):
            automation_store.load(session)

    def test_failed_proven_attempt_does_not_satisfy_automation(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        proven_report = {
            "state": "proven",
            "requestedSurfaceCount": 1,
            "provenSurfaceCount": 1,
            "diagnostics": ["invalid-receipt-entry"],
            "runtimeSession": None,
            "surfaces": [{"receiptCount": 1}],
        }
        attempt = make_attempt(
            new_automation_state(session, NOW),
            result="failed",
            reason_code="runtime-sync-degraded",
            started_at=NOW,
            finished_at=NOW,
            runtime_report=proven_report,
        )
        state = AutomationStore(store).record(session, attempt, NOW)

        self.assertTrue(attempt.summary.runtime_evidence_is_proven())
        self.assertFalse(attempt.summary.evidence_satisfied)
        self.assertFalse(build_automation_report(state)["evidenceSatisfied"])
        self.assertEqual(AutomationStore(store).load(session), state)

    def test_runtime_report_remains_top_level_with_per_kind_reports(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        automation_store = AutomationStore(store)
        state = automation_store.record(
            session,
            make_attempt(
                new_automation_state(session, NOW),
                result="failed",
                reason_code="runtime-sync-degraded",
                started_at=NOW,
                finished_at=NOW,
                runtime_report=None,
            ),
            NOW,
        )
        state = automation_store.record(
            session,
            make_attempt(
                state,
                kind="macos.app.launch",
                result="failed",
                reason_code="macos-app-launch-command-failed",
                started_at=NOW + timedelta(seconds=1),
                finished_at=NOW + timedelta(seconds=1),
                receipt_window_digest="b" * 64,
                runtime_report=None,
            ),
            NOW + timedelta(seconds=1),
        )

        report = build_automation_report(state)

        self.assertEqual(report["attemptCount"], 1)
        self.assertEqual(report["lastAttempt"]["kind"], "runtime.receipt.sync")
        self.assertEqual(report["totalAttemptCount"], 2)
        self.assertEqual(report["kindReports"]["macos.app.launch"]["attemptCount"], 1)
        self.assertEqual(report["kindReports"]["shared-view.capture"]["attemptCount"], 0)

    def test_macos_launch_precedes_receipt_sync_and_records_success(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        events: list[str] = []
        runner = mock.Mock()

        def launch(*_args: object, **_kwargs: object) -> CommandResult:
            events.append("launch")
            return CommandResult(0, "", "")

        def sync(*_args: object, **_kwargs: object) -> RuntimeSessionObservation:
            events.append("sync")
            return runtime_observation()

        def capture(*args: object, **_kwargs: object):
            events.append("capture")
            return args[3], 0

        runner.run.side_effect = launch
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(cli_module, "SubprocessRunner", return_value=runner),
            mock.patch.object(
                cli_module,
                "collect_mac_evidence",
                side_effect=[
                    mac_evidence(),
                    mac_evidence(),
                    mac_evidence(baseline_state="proven", process_state="running"),
                ],
            ),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                side_effect=sync,
            ),
            mock.patch.object(
                cli_module,
                "_advance_shared_view_capture",
                side_effect=capture,
            ),
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            exit_code = cli_module.run_advance_automation(args)

        self.assertEqual(exit_code, 0)
        self.assertEqual(events, ["launch", "sync", "capture"])
        cli_module.time.sleep.assert_called_once_with(1.0)
        runner.run.assert_called_once()
        self.assertEqual(
            runner.run.call_args.args[0],
            ["/usr/bin/open", "-g", "/Applications/Context Panel.app"],
        )
        state = AutomationStore(store).load(session)
        self.assertIsNotNone(state)
        assert state is not None
        launch_attempts = [
            attempt for attempt in state.attempts if attempt.kind == "macos.app.launch"
        ]
        self.assertEqual(len(launch_attempts), 1)
        self.assertEqual(launch_attempts[0].result, "succeeded")
        self.assertEqual(launch_attempts[0].reason_code, "macos-app-launch-verified")

    def test_macos_launch_failure_cools_down_and_stops_after_two_attempts(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        runner = mock.Mock()
        runner.run.return_value = CommandResult(1, "private stdout", "private stderr")
        exits = []
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(cli_module, "SubprocessRunner", return_value=runner),
            mock.patch.object(
                cli_module,
                "collect_mac_evidence",
                return_value=mac_evidence(),
            ) as collect_mac,
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(),
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            for offset in (0, 1, 6, 12):
                with mock.patch.object(
                    cli_module,
                    "utc_now",
                    return_value=NOW + timedelta(minutes=offset),
                ):
                    exits.append(cli_module.run_advance_automation(args))

        self.assertEqual(exits, [30, 30, 30, 30])
        self.assertEqual(runner.run.call_count, 2)
        self.assertEqual(collect_mac.call_count, 4)
        state = AutomationStore(store).load(session)
        self.assertIsNotNone(state)
        assert state is not None
        launch_attempts = [
            attempt for attempt in state.attempts if attempt.kind == "macos.app.launch"
        ]
        self.assertEqual(len(launch_attempts), 2)
        serialized = json.dumps(state.to_dict())
        self.assertNotIn("private stdout", serialized)
        self.assertNotIn("private stderr", serialized)
        self.assertNotIn("/Applications/Context Panel.app", serialized)

    def test_running_mac_clears_prior_launch_failures(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        automation_store = AutomationStore(store)
        state = new_automation_state(session, NOW)
        window_digest = cli_module.macos_app_window_digest(mac_evidence())
        for offset in (0, 6):
            state = automation_store.record(
                session,
                make_attempt(
                    state,
                    kind="macos.app.launch",
                    result="failed",
                    reason_code="macos-app-launch-command-failed",
                    started_at=NOW + timedelta(minutes=offset),
                    finished_at=NOW + timedelta(minutes=offset),
                    receipt_window_digest=window_digest,
                    runtime_report=None,
                ),
                NOW + timedelta(minutes=offset),
            )
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        runner = mock.Mock()
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(cli_module, "SubprocessRunner", return_value=runner),
            mock.patch.object(
                cli_module,
                "collect_mac_evidence",
                return_value=mac_evidence(baseline_state="proven", process_state="running"),
            ),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(observed_at=NOW + timedelta(minutes=12)),
            ),
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=12)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            exit_code = cli_module.run_advance_automation(args)

        self.assertEqual(exit_code, 0)
        runner.run.assert_not_called()

    def test_macos_launch_transient_precondition_records_manual_fallback(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        transient = mac_evidence(baseline_state="unknown", process_state="unknown")
        runner = mock.Mock()
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(cli_module, "SubprocessRunner", return_value=runner),
            mock.patch.object(cli_module, "collect_mac_evidence", return_value=transient),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(),
            ),
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            exit_code = cli_module.run_advance_automation(args)

        self.assertEqual(exit_code, 30)
        runner.run.assert_not_called()
        state = AutomationStore(store).load(session)
        self.assertIsNotNone(state)
        assert state is not None
        launch_attempts = [
            attempt for attempt in state.attempts if attempt.kind == "macos.app.launch"
        ]
        self.assertEqual(len(launch_attempts), 1)
        self.assertEqual(launch_attempts[0].result, "skipped-precondition")
        self.assertEqual(
            launch_attempts[0].reason_code,
            "macos-app-launch-precondition-not-met",
        )

    def test_shared_view_capture_records_public_attempt(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        manifest_id = "9" * 64
        requirement_ids = ["shared-view.requirement"]
        window_digest = cli_module.shared_view_capture_window_digest(
            manifest_id,
            requirement_ids,
        )
        args = argparse.Namespace(
            surface_comparison=Path("comparison.json"),
            current_manifest=Path("manifest.json"),
            requirements=Path("requirements.json"),
            capture_config=Path("capture.json"),
            artifact_root=Path("/private/artifacts"),
            capture_output=Path("/private/receipt.json"),
        )
        receipt = {
            "currentManifestID": manifest_id,
            "captures": [{"requirementID": requirement_ids[0]}],
        }
        with (
            mock.patch.object(
                cli_module,
                "_shared_view_capture_window",
                return_value=window_digest,
            ),
            mock.patch.object(
                cli_module,
                "execute_shared_view_capture",
                return_value=(0, receipt),
            ) as capture,
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
        ):
            state, exit_code = cli_module._advance_shared_view_capture(
                args,
                store,
                session,
                None,
                NOW,
            )

        self.assertEqual(exit_code, 0)
        capture.assert_called_once()
        self.assertIsNotNone(state)
        assert state is not None
        attempt = state.attempts[-1]
        self.assertEqual(attempt.kind, "shared-view.capture")
        self.assertEqual(attempt.result, "succeeded")
        serialized = json.dumps(state.to_dict())
        self.assertNotIn("/private/artifacts", serialized)
        self.assertNotIn("/private/receipt.json", serialized)

    def test_shared_view_capture_missing_inputs_records_unsupported(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        manifest_id = "7" * 64
        requirement_id = "shared-view.requirement"
        window_digest = cli_module.shared_view_capture_window_digest(
            manifest_id,
            [requirement_id],
        )
        args = argparse.Namespace(
            surface_comparison=None,
            current_manifest=None,
            requirements=None,
            capture_config=None,
            artifact_root=None,
            capture_output=None,
        )
        with (
            mock.patch.object(
                cli_module,
                "_shared_view_capture_window",
                return_value=window_digest,
            ),
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
        ):
            state, exit_code = cli_module._advance_shared_view_capture(
                args,
                store,
                session,
                None,
                NOW,
            )

        self.assertEqual(exit_code, 0)
        self.assertIsNotNone(state)
        assert state is not None
        attempt = state.attempts[-1]
        self.assertEqual(attempt.result, "unsupported")
        self.assertEqual(attempt.reason_code, "shared-view-capture-unavailable")

        args = argparse.Namespace(
            surface_comparison=Path("comparison.json"),
            current_manifest=Path("manifest.json"),
            requirements=Path("requirements.json"),
            capture_config=Path("capture.json"),
            artifact_root=Path("/private/artifacts"),
            capture_output=Path("/private/receipt.json"),
        )
        receipt = {
            "currentManifestID": manifest_id,
            "captures": [
                {
                    "requirementID": requirement_id,
                    "status": "blocked",
                    "errorCode": "unsupported-host-mechanism",
                }
            ],
        }
        with (
            mock.patch.object(
                cli_module,
                "_shared_view_capture_window",
                return_value=window_digest,
            ),
            mock.patch.object(
                cli_module,
                "execute_shared_view_capture",
                side_effect=[(30, receipt), (0, receipt)],
            ) as capture,
            mock.patch.object(
                cli_module,
                "utc_now",
                return_value=NOW + timedelta(minutes=1),
            ),
        ):
            state, exit_code = cli_module._advance_shared_view_capture(
                args,
                store,
                session,
                state,
                NOW + timedelta(minutes=1),
            )
            state, cooldown_exit = cli_module._advance_shared_view_capture(
                args,
                store,
                session,
                state,
                NOW + timedelta(minutes=2),
            )
            state, recovered_exit = cli_module._advance_shared_view_capture(
                args,
                store,
                session,
                state,
                NOW + timedelta(minutes=7),
            )

        self.assertEqual(exit_code, 30)
        self.assertEqual(cooldown_exit, 30)
        self.assertEqual(recovered_exit, 0)
        self.assertEqual(capture.call_count, 2)
        self.assertIsNotNone(state)
        assert state is not None
        capture_attempts = [
            item for item in state.attempts if item.kind == "shared-view.capture"
        ]
        self.assertEqual(
            [item.result for item in capture_attempts],
            ["unsupported", "failed", "succeeded"],
        )

    def test_shared_view_capture_blocked_host_is_non_degrading_unsupported(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        manifest_id = "6" * 64
        requirement_id = "shared-view.requirement"
        window_digest = cli_module.shared_view_capture_window_digest(
            manifest_id,
            [requirement_id],
        )
        args = argparse.Namespace(
            surface_comparison=Path("comparison.json"),
            current_manifest=Path("manifest.json"),
            requirements=Path("requirements.json"),
            capture_config=Path("capture.json"),
            artifact_root=Path("/private/artifacts"),
            capture_output=Path("/private/receipt.json"),
        )
        receipt = {
            "currentManifestID": manifest_id,
            "captures": [
                {
                    "requirementID": requirement_id,
                    "status": "blocked",
                    "errorCode": "unsupported-host-mechanism",
                }
            ],
        }
        with (
            mock.patch.object(
                cli_module,
                "_shared_view_capture_window",
                return_value=window_digest,
            ),
            mock.patch.object(
                cli_module,
                "execute_shared_view_capture",
                return_value=(20, receipt),
            ),
        ):
            state, exit_code = cli_module._advance_shared_view_capture(
                args,
                store,
                session,
                None,
                NOW,
            )

        self.assertEqual(exit_code, 0)
        self.assertIsNotNone(state)
        assert state is not None
        self.assertEqual(state.attempts[-1].result, "unsupported")
        self.assertEqual(
            state.attempts[-1].reason_code,
            "shared-view-capture-host-unsupported",
        )

    def test_shared_view_capture_recoverable_block_is_failed(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        manifest_id = "4" * 64
        requirement_id = "shared-view.requirement"
        window_digest = cli_module.shared_view_capture_window_digest(
            manifest_id,
            [requirement_id],
        )
        args = argparse.Namespace(
            surface_comparison=Path("comparison.json"),
            current_manifest=Path("manifest.json"),
            requirements=Path("requirements.json"),
            capture_config=Path("capture.json"),
            artifact_root=Path("/private/artifacts"),
            capture_output=Path("/private/receipt.json"),
        )
        receipt = {
            "currentManifestID": manifest_id,
            "captures": [
                {
                    "requirementID": requirement_id,
                    "status": "blocked",
                    "errorCode": "profile-not-configured",
                }
            ],
        }
        with (
            mock.patch.object(
                cli_module,
                "_shared_view_capture_window",
                return_value=window_digest,
            ),
            mock.patch.object(
                cli_module,
                "execute_shared_view_capture",
                return_value=(20, receipt),
            ),
        ):
            state, exit_code = cli_module._advance_shared_view_capture(
                args,
                store,
                session,
                None,
                NOW,
            )

        self.assertEqual(exit_code, 30)
        self.assertIsNotNone(state)
        assert state is not None
        self.assertEqual(state.attempts[-1].result, "failed")
        self.assertEqual(state.attempts[-1].reason_code, "shared-view-capture-failed")

    def test_shared_view_capture_rejects_mismatched_receipt(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        manifest_id = "5" * 64
        window_digest = cli_module.shared_view_capture_window_digest(
            manifest_id,
            ["expected.requirement"],
        )
        args = argparse.Namespace(
            surface_comparison=Path("comparison.json"),
            current_manifest=Path("manifest.json"),
            requirements=Path("requirements.json"),
            capture_config=Path("capture.json"),
            artifact_root=Path("/private/artifacts"),
            capture_output=Path("/private/receipt.json"),
        )
        receipt = {
            "currentManifestID": manifest_id,
            "captures": [{"requirementID": "wrong.requirement"}],
        }
        with (
            mock.patch.object(
                cli_module,
                "_shared_view_capture_window",
                return_value=window_digest,
            ),
            mock.patch.object(
                cli_module,
                "execute_shared_view_capture",
                return_value=(0, receipt),
            ),
        ):
            state, exit_code = cli_module._advance_shared_view_capture(
                args,
                store,
                session,
                None,
                NOW,
            )

        self.assertEqual(exit_code, 30)
        self.assertIsNotNone(state)
        assert state is not None
        self.assertEqual(state.attempts[-1].result, "failed")

    def test_advance_rejects_partial_capture_inputs(self) -> None:
        with (
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            cli_module.parse_args(
                [
                    "advance-automation",
                    "--version",
                    TARGET.version,
                    "--build-number",
                    TARGET.build_number,
                    "--capture-config",
                    "capture.json",
                ]
            )

    def test_advance_syncs_once_then_repeats_idempotently_without_second_sync(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(),
            ) as sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            first_exit = cli_module.run_advance_automation(args)
            first_payload = json.loads(output.getvalue())
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(cli_module.RuntimeSessionAdapter, "sync_and_collect") as repeat_sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=1)),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            second_exit = cli_module.run_advance_automation(args)
            second_payload = json.loads(output.getvalue())

        self.assertEqual(first_exit, 0)
        self.assertEqual(second_exit, 0)
        sync.assert_called_once()
        repeat_sync.assert_not_called()
        self.assertEqual(first_payload["automation"]["attemptCount"], 1)
        self.assertEqual(second_payload["automation"]["attemptCount"], 1)
        self.assertEqual(first_payload["runtimeEvidence"], second_payload["runtimeEvidence"])

        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(observed_at=NOW + timedelta(minutes=6)),
            ) as cooldown_sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=6)),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            third_exit = cli_module.run_advance_automation(args)
            third_payload = json.loads(output.getvalue())

        self.assertEqual(third_exit, 0)
        cooldown_sync.assert_called_once()
        self.assertEqual(third_payload["automation"]["attemptCount"], 2)

    def test_unsupported_sync_retries_after_cooldown(self) -> None:
        temporary, store, _ = self.fixture()
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        unavailable = runtime_observation(
            healthy=False,
            diagnostics=("sync-unavailable",),
        )
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=unavailable,
            ) as first_sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(cli_module.run_advance_automation(args), 30)
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(cli_module.RuntimeSessionAdapter, "sync_and_collect") as cooldown_sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=1)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(cli_module.run_advance_automation(args), 30)
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(observed_at=NOW + timedelta(minutes=6)),
            ) as recovered_sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=6)),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            self.assertEqual(cli_module.run_advance_automation(args), 0)
            payload = json.loads(output.getvalue())

        first_sync.assert_called_once()
        cooldown_sync.assert_not_called()
        recovered_sync.assert_called_once()
        self.assertEqual(payload["automation"]["attemptCount"], 2)
        self.assertEqual(payload["automation"]["lastAttempt"]["result"], "succeeded")

    def test_stale_prelock_attempt_ids_append_without_losing_reconciled_work(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        automation_store = AutomationStore(store)
        stale_state = new_automation_state(session, NOW)
        first = make_attempt(
            stale_state,
            result="failed",
            reason_code="runtime-sync-degraded",
            started_at=NOW,
            finished_at=NOW,
            runtime_report=None,
        )
        second = make_attempt(
            stale_state,
            result="unsupported",
            reason_code="runtime-sync-unavailable",
            started_at=NOW + timedelta(seconds=1),
            finished_at=NOW + timedelta(seconds=1),
            runtime_report=None,
        )

        automation_store.record(session, second, NOW + timedelta(seconds=1))
        state = automation_store.record(session, first, NOW)

        self.assertEqual(len(state.attempts), 2)
        self.assertEqual(state.attempts[-1].result, first.result)
        self.assertEqual(state.attempts[-1].finished_at, second.finished_at)
        self.assertNotEqual(state.attempts[-1].id, first.id)
        self.assertEqual(state.updated_at, state.attempts[-1].finished_at)

    def test_concurrent_advance_calls_share_one_relay_and_one_attempt(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        sync_started = threading.Event()
        release_sync = threading.Event()
        second_finished = threading.Event()
        exits: list[int] = []
        failures: list[BaseException] = []

        def sync_once(*_args: object, **_kwargs: object) -> RuntimeSessionObservation:
            sync_started.set()
            if not release_sync.wait(timeout=5):
                raise AssertionError("test relay release timed out")
            return runtime_observation()

        def advance(*, mark_finished: bool = False) -> None:
            try:
                exits.append(cli_module.run_advance_automation(args))
            except BaseException as error:
                failures.append(error)
            finally:
                if mark_finished:
                    second_finished.set()

        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                side_effect=sync_once,
            ) as sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
            mock.patch("builtins.print"),
        ):
            first_thread = threading.Thread(target=advance)
            second_thread = threading.Thread(target=advance, kwargs={"mark_finished": True})
            first_thread.start()
            self.assertTrue(sync_started.wait(timeout=5))
            second_thread.start()
            self.assertFalse(second_finished.wait(timeout=0.1))
            release_sync.set()
            first_thread.join(timeout=5)
            second_thread.join(timeout=5)

        self.assertFalse(first_thread.is_alive())
        self.assertFalse(second_thread.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(sorted(exits), [0, 0])
        sync.assert_called_once()
        state = AutomationStore(store).load(session)
        self.assertIsNotNone(state)
        assert state is not None
        self.assertEqual(len(state.attempts), 1)

    def test_advance_bootstraps_missing_runtime_evidence(self) -> None:
        temporary, store, session = self.fixture(attach_runtime=False)
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[Path("fixture-manifest.json")],
            json=True,
        )
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module,
                "load_expected_surface_identities",
                return_value=(expected_identity(),),
            ) as load_identities,
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(),
            ) as sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            exit_code = cli_module.run_advance_automation(args)

        self.assertEqual(exit_code, 0)
        load_identities.assert_called_once()
        sync.assert_called_once()
        self.assertIsNotNone(RuntimeEvidenceStore(store).load(session))
        state = AutomationStore(store).load(session)
        self.assertIsNotNone(state)
        assert state is not None
        self.assertEqual(state.attempts[-1].reason_code, "runtime-receipts-reconciled")

    def test_final_report_projection_drops_unreviewed_automation_fields(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        state = AutomationStore(store).record(
            session,
            make_attempt(
                new_automation_state(session, NOW),
                result="failed",
                reason_code="runtime-sync-degraded",
                started_at=NOW,
                finished_at=NOW,
                runtime_report=None,
            ),
            NOW,
        )
        report = build_automation_report(state)
        report["privatePath"] = "/private/operator/path"
        last_attempt = report["lastAttempt"]
        assert isinstance(last_attempt, dict)
        last_attempt["privateArgv"] = ["secret"]
        summary = last_attempt["summary"]
        assert isinstance(summary, dict)
        summary["rawReceipts"] = ["secret"]
        kind_reports = report["kindReports"]
        assert isinstance(kind_reports, dict)
        runtime_kind = kind_reports["runtime.receipt.sync"]
        assert isinstance(runtime_kind, dict)
        runtime_kind["privateCommand"] = ["secret"]

        projected = operator_flow_module.project_automation_report(report)

        self.assertNotIn("privatePath", projected)
        projected_kinds = projected["kindReports"]
        assert isinstance(projected_kinds, dict)
        self.assertNotIn("privateCommand", projected_kinds["runtime.receipt.sync"])
        projected_attempt = projected["lastAttempt"]
        assert isinstance(projected_attempt, dict)
        self.assertNotIn("privateArgv", projected_attempt)
        projected_summary = projected_attempt["summary"]
        assert isinstance(projected_summary, dict)
        self.assertNotIn("rawReceipts", projected_summary)

    def test_cli_attempt_limit_and_paused_session_do_not_sync(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        automation_store = AutomationStore(store)
        state = new_automation_state(session, NOW)
        for index in range(64):
            attempt = make_attempt(
                state,
                result="failed",
                reason_code="runtime-sync-degraded",
                started_at=NOW + timedelta(seconds=index),
                finished_at=NOW + timedelta(seconds=index),
                runtime_report=None,
            )
            state = automation_store.record(session, attempt, NOW + timedelta(seconds=index))
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(cli_module.RuntimeSessionAdapter, "sync_and_collect") as limited_sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=2)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(cli_module.run_advance_automation(args), 30)
        limited_sync.assert_not_called()

        paused_temporary, paused_store, _ = self.fixture()
        self.addCleanup(paused_temporary.cleanup)
        paused_store.transition(TARGET, "paused", NOW + timedelta(minutes=1), "external-wait")
        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(paused_store.root)},
            ),
            mock.patch.object(cli_module.RuntimeSessionAdapter, "sync_and_collect") as paused_sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=2)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(cli_module.run_advance_automation(args), 30)
        paused_sync.assert_not_called()

    def test_proven_attempt_at_limit_remains_idempotently_successful(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        automation_store = AutomationStore(store)
        state = new_automation_state(session, NOW)
        for index in range(63):
            state = automation_store.record(
                session,
                make_attempt(
                    state,
                    result="failed",
                    reason_code="runtime-sync-degraded",
                    started_at=NOW + timedelta(seconds=index),
                    finished_at=NOW + timedelta(seconds=index),
                    runtime_report=None,
                ),
                NOW + timedelta(seconds=index),
            )
        proven_report = {
            "state": "proven",
            "requestedSurfaceCount": 1,
            "provenSurfaceCount": 1,
            "diagnostics": [],
            "runtimeSession": None,
            "surfaces": [{"receiptCount": 1}],
        }
        state = automation_store.record(
            session,
            make_attempt(
                state,
                result="succeeded",
                reason_code="runtime-receipts-reconciled",
                started_at=NOW + timedelta(seconds=63),
                finished_at=NOW + timedelta(seconds=63),
                runtime_report=proven_report,
            ),
            NOW + timedelta(seconds=63),
        )
        self.assertEqual(len(state.attempts), 64)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        runtime_state = SimpleNamespace(
            last_observation=SimpleNamespace(result="healthy"),
        )
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module.RuntimeEvidenceStore,
                "load",
                return_value=runtime_state,
            ),
            mock.patch.object(
                cli_module,
                "build_runtime_evidence_report",
                return_value=proven_report,
            ),
            mock.patch.object(cli_module.RuntimeSessionAdapter, "sync_and_collect") as sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=2)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(cli_module.run_advance_automation(args), 0)
        sync.assert_not_called()

    def test_changed_window_advances_after_previously_proven_attempt(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        automation_store = AutomationStore(store)
        proven_report = {
            "state": "proven",
            "requestedSurfaceCount": 1,
            "provenSurfaceCount": 1,
            "diagnostics": [],
            "runtimeSession": None,
            "surfaces": [{"receiptCount": 1}],
        }
        automation_store.record(
            session,
            make_attempt(
                new_automation_state(session, NOW),
                result="succeeded",
                reason_code="runtime-receipts-reconciled",
                started_at=NOW,
                finished_at=NOW,
                runtime_report=proven_report,
            ),
            NOW,
        )
        changed_report = {
            "state": "waiting",
            "requestedSurfaceCount": 1,
            "provenSurfaceCount": 0,
            "diagnostics": [],
            "runtimeSession": None,
            "surfaces": [{"receiptCount": 0}],
        }
        runtime_state = SimpleNamespace(
            last_observation=SimpleNamespace(result="healthy", diagnostics=()),
        )
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module.RuntimeEvidenceStore,
                "load",
                return_value=runtime_state,
            ),
            mock.patch.object(
                cli_module,
                "build_runtime_evidence_report",
                return_value=changed_report,
            ),
            mock.patch.object(
                cli_module,
                "sync_and_reconcile_runtime_evidence",
                return_value=(session, runtime_state, changed_report, False),
            ) as sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=1)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            exit_code = cli_module.run_advance_automation(args)

        self.assertEqual(exit_code, 0)
        sync.assert_called_once()
        state = automation_store.load(session)
        self.assertIsNotNone(state)
        assert state is not None
        self.assertEqual(len(state.attempts), 2)
        self.assertFalse(state.attempts[-1].summary.evidence_satisfied)

    def test_proven_diagnostic_runtime_retries_after_cooldown(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        proven_report = {
            "state": "proven",
            "requestedSurfaceCount": 1,
            "provenSurfaceCount": 1,
            "diagnostics": ["export-unavailable"],
            "runtimeSession": None,
            "surfaces": [{"receiptCount": 1}],
        }
        runtime_state = SimpleNamespace(
            last_observation=SimpleNamespace(
                result="diagnostic",
                diagnostics=("export-unavailable",),
            ),
        )
        exits = []
        sync_counts = []
        with mock.patch.dict(
            os.environ,
            {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)},
        ):
            for offset in (0, 1, 6):
                with (
                    mock.patch.object(
                        cli_module.RuntimeEvidenceStore,
                        "load",
                        return_value=runtime_state,
                    ),
                    mock.patch.object(
                        cli_module,
                        "build_runtime_evidence_report",
                        return_value=proven_report,
                    ),
                    mock.patch.object(
                        cli_module,
                        "sync_and_reconcile_runtime_evidence",
                        return_value=(session, runtime_state, proven_report, False),
                    ) as sync,
                    mock.patch.object(
                        cli_module,
                        "utc_now",
                        return_value=NOW + timedelta(minutes=offset),
                    ),
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    exits.append(cli_module.run_advance_automation(args))
                sync_counts.append(sync.call_count)

        self.assertEqual(exits, [30, 30, 30])
        self.assertEqual(sync_counts, [1, 0, 1])

    def test_proven_healthy_polling_records_once_per_window(self) -> None:
        temporary, store, session = self.fixture()
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        proven_report = {
            "state": "proven",
            "requestedSurfaceCount": 1,
            "provenSurfaceCount": 1,
            "diagnostics": [],
            "runtimeSession": None,
            "surfaces": [{"receiptCount": 1}],
        }
        runtime_state = SimpleNamespace(
            last_observation=SimpleNamespace(result="healthy"),
        )
        exits = []
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module.RuntimeEvidenceStore,
                "load",
                return_value=runtime_state,
            ),
            mock.patch.object(
                cli_module,
                "build_runtime_evidence_report",
                return_value=proven_report,
            ),
            mock.patch.object(cli_module.RuntimeSessionAdapter, "sync_and_collect") as sync,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            for offset in range(70):
                with mock.patch.object(
                    cli_module,
                    "utc_now",
                    return_value=NOW + timedelta(minutes=offset * 6),
                ):
                    exits.append(cli_module.run_advance_automation(args))

        self.assertEqual(exits, [0] * 70)
        sync.assert_not_called()
        state = AutomationStore(store).load(session)
        self.assertIsNotNone(state)
        assert state is not None
        self.assertEqual(len(state.attempts), 1)

    def test_advance_records_degraded_sync_without_satisfying_evidence(self) -> None:
        temporary, store, _ = self.fixture()
        self.addCleanup(temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(healthy=False),
            ),
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            exit_code = cli_module.run_advance_automation(args)

        payload = json.loads(output.getvalue())
        self.assertEqual(exit_code, 30)
        self.assertEqual(payload["automation"]["lastAttempt"]["result"], "failed")
        self.assertFalse(payload["automation"]["evidenceSatisfied"])
        self.assertNotEqual(payload["runtimeEvidence"]["state"], "proven")

    def test_advance_closed_and_superseded_sessions_fail_closed(self) -> None:
        temporary, store, _ = self.fixture()
        self.addCleanup(temporary.cleanup)
        store.transition(TARGET, "superseded", NOW + timedelta(minutes=1), "newer-build-observed")
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)}),
            mock.patch.object(cli_module.RuntimeSessionAdapter, "sync_and_collect") as sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=2)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            exit_code = cli_module.run_advance_automation(args)
        self.assertEqual(exit_code, 20)
        sync.assert_not_called()

    def test_advance_runtime_evidence_matches_explicit_runtime_sync(self) -> None:
        explicit_temporary, explicit_store, _ = self.fixture()
        advance_temporary, advance_store, _ = self.fixture()
        self.addCleanup(explicit_temporary.cleanup)
        self.addCleanup(advance_temporary.cleanup)
        args = argparse.Namespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            expected_build_manifests=[],
            json=True,
        )
        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(explicit_store.root)},
            ),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(),
            ) as sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            explicit_exit = cli_module.run_sync_runtime_evidence(args)
        explicit_payload = json.loads(output.getvalue())
        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(advance_store.root)},
            ),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation(),
            ) as advance_sync,
            mock.patch.object(cli_module, "utc_now", return_value=NOW),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            advance_exit = cli_module.run_advance_automation(args)
        advance_payload = json.loads(output.getvalue())

        self.assertEqual(explicit_exit, advance_exit)
        self.assertEqual(explicit_payload["runtimeEvidence"], advance_payload["runtimeEvidence"])
        sync.assert_called_once()
        advance_sync.assert_called_once()


if __name__ == "__main__":
    unittest.main()
