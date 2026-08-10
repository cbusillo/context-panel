import hashlib
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import uuid
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_validation import (
    ASCEvidence,
    MacEvidence,
    ExpectedSurfaceIdentity,
    RuntimeEvidenceState,
    RuntimeReceiptEvidence,
    SessionStateStore,
    Target,
    VisualApprovalError,
    VisualApprovalState,
    VisualApprovalStore,
    build_final_report_payload,
    build_report,
    build_visual_approval_report,
    load_visual_review_plan,
    render_final_report,
)
from context_panel_validation import cli as cli_module
from context_panel_validation.runtime_evidence import RuntimeObservationSummary


NOW = datetime(2026, 8, 8, 2, 0, tzinfo=timezone.utc)
TARGET = Target("1.0.54", "202608080200")
MANIFEST_ID = "a" * 64
CONTRACT_ID = "b" * 64
EXECUTABLE_UUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"


def sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def identity(surface: str, platform: str) -> ExpectedSurfaceIdentity:
    return ExpectedSurfaceIdentity(
        surface=surface,
        platform=platform,
        artifact_id=surface,
        bundle_identifier=f"com.example.{surface}",
        marketing_version=TARGET.version,
        build_number=TARGET.build_number,
        manifest_id=MANIFEST_ID,
        contract_fingerprint=CONTRACT_ID,
        render_fingerprint=sha(f"{surface}:render"),
        runtime_fingerprint=sha(f"{surface}:runtime"),
        placement_fingerprint=sha(f"{surface}:placement"),
        combined_fingerprint=sha(f"{surface}:combined"),
        executable_uuids=(EXECUTABLE_UUID,),
        expected_build_id=sha(f"{surface}:build"),
    )


def runtime_state(session_id: str, expected: ExpectedSurfaceIdentity) -> RuntimeEvidenceState:
    receipt = RuntimeReceiptEvidence(
        receipt_id=sha("receipt"),
        runtime_session_id=str(uuid.UUID("00000000-0000-0000-0000-000000000111")).upper(),
        surface=expected.surface,
        source="local",
        server_received_at=None,
        observed_at="2026-08-08T02:01:00Z",
        process_instance_id=str(uuid.UUID("00000000-0000-0000-0000-000000000222")).upper(),
        process_sequence=1,
        loaded_executable_uuids=(EXECUTABLE_UUID,),
        identity_digest=expected.identity_digest(),
        state_branch="available",
        outcome="success",
    )
    return RuntimeEvidenceState(
        schema_version=1,
        coordinator_session_id=session_id,
        target=TARGET,
        requested_surfaces=(expected.surface,),
        updated_at="2026-08-08T02:01:00Z",
        revision=1,
        expected_surfaces=(expected,),
        receipts=(receipt,),
        last_observation=None,
    )


class VisualApprovalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.store = SessionStateStore(root=self.root, legacy_root=self.root / "Legacy")
        self.shared_identity = identity("watchos.app", "watchOS")
        self.placement_identity = identity("watchos.complication", "watchOS")

    def write_plan_files(self) -> tuple[Path, Path]:
        comparison = {
            "schemaVersion": 1,
            "train": "beta",
            "previousManifestId": "c" * 64,
            "currentManifestId": MANIFEST_ID,
            "contractChanged": False,
            "exactBuildSame": False,
            "removedSurfaces": [],
            "requiredSurfaces": {
                "shared-view": ["watchos.app", "watchos.complication"],
                "actual-runtime": ["watchos.complication"],
                "os-composited-placement": ["watchos.complication"],
            },
            "requiresRuntimeSession": True,
            "requiresPlacementReview": True,
            "surfaces": [
                {
                    "surfaceId": "watchos.app",
                    "freshEvidence": ["shared-view"],
                },
                {
                    "surfaceId": "watchos.complication",
                    "freshEvidence": [
                        "shared-view",
                        "actual-runtime",
                        "os-composited-placement",
                    ],
                },
            ],
            "releaseRequiresApprovedRCTarget": True,
        }
        requirements = {
            "schemaVersion": 1,
            "kind": "context-panel-visual-review-requirements",
            "currentManifestID": MANIFEST_ID,
            "requirements": [
                {
                    "id": "watch.app.shared.dark",
                    "evidenceClass": "shared-view",
                    "surface": "watchos.app",
                    "fixtureContractID": sha("watch-app-gallery"),
                    "presentation": "usage-list",
                    "appearance": "dark",
                    "accessibility": "default",
                    "hostOS": None,
                    "presentationFamily": None,
                    "placementHost": None,
                },
                {
                    "id": "watch.complication.shared.corner",
                    "evidenceClass": "shared-view",
                    "surface": "watchos.complication",
                    "fixtureContractID": sha("watch-complication-gallery"),
                    "presentation": "corner",
                    "appearance": "dark",
                    "accessibility": "default",
                    "hostOS": None,
                    "presentationFamily": None,
                    "placementHost": None,
                },
                {
                    "id": "watch.complication.placement.corner",
                    "evidenceClass": "os-composited-placement",
                    "surface": "watchos.complication",
                    "fixtureContractID": None,
                    "presentation": None,
                    "appearance": "dark",
                    "accessibility": "default",
                    "hostOS": "watchOS 27.0",
                    "presentationFamily": "corner",
                    "placementHost": "watch face",
                },
            ],
        }
        comparison_path = self.root / "comparison.json"
        requirements_path = self.root / "requirements.json"
        comparison_path.write_text(json.dumps(comparison))
        requirements_path.write_text(json.dumps(requirements))
        return comparison_path, requirements_path

    def configured_state(self):
        comparison_path, requirements_path = self.write_plan_files()
        runtime_surfaces, requirements, current_manifest_id = load_visual_review_plan(
            comparison_path,
            requirements_path,
            (self.shared_identity, self.placement_identity),
        )
        session, _ = self.store.start_session(
            TARGET,
            runtime_surfaces,
            NOW,
            timedelta(hours=2),
            timedelta(days=1),
        )
        state = VisualApprovalStore(self.store).configure(
            session,
            current_manifest_id,
            requirements,
            NOW,
        )
        return session, state

    def test_plan_binds_exact_identities_and_runtime_scope(self) -> None:
        comparison_path, requirements_path = self.write_plan_files()

        runtime_surfaces, requirements, current_manifest_id = load_visual_review_plan(
            comparison_path,
            requirements_path,
            (self.shared_identity, self.placement_identity),
        )

        self.assertEqual(runtime_surfaces, ("watchos.complication",))
        self.assertEqual(current_manifest_id, MANIFEST_ID)
        self.assertEqual(len(requirements), 3)
        placement = next(item for item in requirements if item.evidence_class.endswith("placement"))
        self.assertEqual(placement.render_fingerprint, self.placement_identity.render_fingerprint)
        self.assertEqual(
            placement.placement_fingerprint,
            self.placement_identity.placement_fingerprint,
        )

    def test_plan_uses_fresh_evidence_scope_and_leaves_carry_forward_to_release_gate(self) -> None:
        comparison_path, requirements_path = self.write_plan_files()
        comparison = json.loads(comparison_path.read_text())
        comparison["surfaces"][0]["freshEvidence"] = []
        comparison["surfaces"][1]["freshEvidence"] = [
            "shared-view",
            "actual-runtime",
            "os-composited-placement",
        ]
        comparison_path.write_text(json.dumps(comparison))
        requirement_payload = json.loads(requirements_path.read_text())
        requirement_payload["requirements"] = [
            item
            for item in requirement_payload["requirements"]
            if item["surface"] != "watchos.app"
        ]
        requirements_path.write_text(json.dumps(requirement_payload))

        runtime_surfaces, requirements, current_manifest_id = load_visual_review_plan(
            comparison_path,
            requirements_path,
            (self.shared_identity, self.placement_identity),
        )

        self.assertEqual(runtime_surfaces, ("watchos.complication",))
        self.assertEqual(current_manifest_id, MANIFEST_ID)
        self.assertEqual(
            [item.id for item in requirements],
            [
                "watch.complication.placement.corner",
                "watch.complication.shared.corner",
            ],
        )
        self.assertEqual(
            [item.evidence_class for item in requirements],
            ["os-composited-placement", "shared-view"],
        )

        session, _ = self.store.start_session(
            TARGET,
            runtime_surfaces,
            NOW,
            timedelta(hours=2),
            timedelta(days=1),
        )
        report = build_visual_approval_report(
            VisualApprovalStore(self.store).configure(
                session,
                current_manifest_id,
                requirements,
                NOW,
            ),
            runtime_state(session.id, self.placement_identity),
        )
        self.assertEqual(report["state"], "pending")
        self.assertEqual(report["requirementCount"], 2)
        self.assertEqual(report["readyReviewCount"], 2)

    def test_nonrequired_comparison_surface_does_not_require_an_attached_identity(self) -> None:
        comparison_path, requirements_path = self.write_plan_files()
        comparison = json.loads(comparison_path.read_text())
        comparison["surfaces"].append(
            {
                "surfaceId": "macos.app",
                "freshEvidence": [],
            }
        )
        comparison_path.write_text(json.dumps(comparison))

        runtime_surfaces, requirements, _ = load_visual_review_plan(
            comparison_path,
            requirements_path,
            (self.shared_identity, self.placement_identity),
        )

        self.assertEqual(runtime_surfaces, ("watchos.complication",))
        self.assertEqual(len(requirements), 3)

    def test_missing_required_comparison_surface_is_rejected(self) -> None:
        comparison_path, requirements_path = self.write_plan_files()
        comparison = json.loads(comparison_path.read_text())
        comparison["surfaces"] = [
            item
            for item in comparison["surfaces"]
            if item["surfaceId"] != "watchos.app"
        ]
        comparison_path.write_text(json.dumps(comparison))

        with self.assertRaisesRegex(VisualApprovalError, "surface comparison is incomplete"):
            load_visual_review_plan(
                comparison_path,
                requirements_path,
                (self.shared_identity, self.placement_identity),
            )

    def test_optional_fresh_fallback_can_cover_carry_forward_eligible_surface(self) -> None:
        comparison_path, requirements_path = self.write_plan_files()
        comparison = json.loads(comparison_path.read_text())
        comparison["surfaces"][0]["freshEvidence"] = []
        comparison_path.write_text(json.dumps(comparison))

        _, requirements, _ = load_visual_review_plan(
            comparison_path,
            requirements_path,
            (self.shared_identity, self.placement_identity),
        )

        self.assertEqual(len(requirements), 3)

    def test_unknown_fresh_evidence_class_is_rejected(self) -> None:
        comparison_path, requirements_path = self.write_plan_files()
        comparison = json.loads(comparison_path.read_text())
        comparison["surfaces"][0]["freshEvidence"] = ["credential-dump"]
        comparison_path.write_text(json.dumps(comparison))

        with self.assertRaisesRegex(
            VisualApprovalError,
            "visual review surface requirements are invalid",
        ):
            load_visual_review_plan(
                comparison_path,
                requirements_path,
                (self.shared_identity, self.placement_identity),
            )

    def test_all_carry_forward_visual_plan_reports_not_required(self) -> None:
        comparison_path, requirements_path = self.write_plan_files()
        comparison = json.loads(comparison_path.read_text())
        comparison["surfaces"][0]["freshEvidence"] = []
        comparison["surfaces"][1]["freshEvidence"] = ["actual-runtime"]
        comparison_path.write_text(json.dumps(comparison))
        requirements = json.loads(requirements_path.read_text())
        requirements["requirements"] = []
        requirements_path.write_text(json.dumps(requirements))

        runtime_surfaces, normalized, current_manifest_id = load_visual_review_plan(
            comparison_path,
            requirements_path,
            (self.shared_identity, self.placement_identity),
        )
        self.assertEqual(runtime_surfaces, ("watchos.complication",))
        self.assertEqual(normalized, ())

        session, _ = self.store.start_session(
            TARGET,
            runtime_surfaces,
            NOW,
            timedelta(hours=2),
            timedelta(days=1),
        )
        state = VisualApprovalStore(self.store).configure(
            session,
            current_manifest_id,
            normalized,
            NOW,
        )
        report = build_visual_approval_report(state, None)

        self.assertEqual(report["state"], "not-required")
        self.assertEqual(report["requirementCount"], 0)
        self.assertFalse(report["reviewBatches"])

    def test_plan_rejects_requirement_outside_comparison_scope(self) -> None:
        comparison_path, requirements_path = self.write_plan_files()
        payload = json.loads(requirements_path.read_text())
        payload["requirements"][0]["surface"] = "macos.app"
        requirements_path.write_text(json.dumps(payload))

        with self.assertRaisesRegex(VisualApprovalError, "outside the required comparison scope"):
            load_visual_review_plan(
                comparison_path,
                requirements_path,
                (self.shared_identity, self.placement_identity),
            )

    def test_shared_only_plan_uses_empty_runtime_scope(self) -> None:
        comparison_path, requirements_path = self.write_plan_files()
        comparison = json.loads(comparison_path.read_text())
        comparison["requiredSurfaces"] = {
            "shared-view": ["watchos.app"],
            "actual-runtime": [],
            "os-composited-placement": [],
        }
        comparison["requiresRuntimeSession"] = False
        comparison["requiresPlacementReview"] = False
        comparison["surfaces"] = [
            {
                "surfaceId": "watchos.app",
                "freshEvidence": ["shared-view"],
            }
        ]
        comparison_path.write_text(json.dumps(comparison))
        requirements = json.loads(requirements_path.read_text())
        requirements["requirements"] = [requirements["requirements"][0]]
        requirements_path.write_text(json.dumps(requirements))

        runtime_surfaces, normalized, current_manifest_id = load_visual_review_plan(
            comparison_path,
            requirements_path,
            (self.shared_identity,),
        )
        session, _ = self.store.start_session(
            TARGET,
            runtime_surfaces,
            NOW,
            timedelta(hours=2),
            timedelta(days=1),
        )
        state = VisualApprovalStore(self.store).configure(
            session,
            current_manifest_id,
            normalized,
            NOW,
        )

        report = build_visual_approval_report(state, None)

        self.assertEqual(session.requested_surfaces, ())
        self.assertEqual(report["state"], "pending")
        self.assertEqual(report["reviewBatches"][0]["device"], "Apple Watch")

    def test_state_round_trips_and_contains_no_private_paths(self) -> None:
        _, state = self.configured_state()

        decoded = VisualApprovalState.from_dict(state.to_dict())
        serialized = json.dumps(decoded.to_dict(), sort_keys=True)

        self.assertEqual(decoded, state)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn("artifactPath", serialized)

    def test_shared_decision_is_idempotent_and_supersedes_explicitly(self) -> None:
        session, _ = self.configured_state()
        store = VisualApprovalStore(self.store)

        approved_state, approved = store.record(
            session,
            "watch.app.shared.dark",
            "approved",
            NOW + timedelta(minutes=1),
            None,
            artifact_digest=sha("private-artifact"),
        )
        same_state, same = store.record(
            session,
            "watch.app.shared.dark",
            "approved",
            NOW + timedelta(minutes=2),
            None,
            artifact_digest=sha("private-artifact"),
        )
        rejected_state, rejected = store.record(
            session,
            "watch.app.shared.dark",
            "rejected",
            NOW + timedelta(minutes=3),
            None,
        )

        self.assertEqual(same.id, approved.id)
        self.assertEqual(same_state.revision, approved_state.revision)
        self.assertEqual(rejected.supersedes_decision_id, approved.id)
        self.assertEqual(rejected.sequence, 2)
        self.assertEqual(rejected_state.revision, approved_state.revision + 1)

    def test_placement_fails_closed_without_matching_runtime_and_host_os(self) -> None:
        session, _ = self.configured_state()
        store = VisualApprovalStore(self.store)

        with self.assertRaisesRegex(VisualApprovalError, "host OS"):
            store.record(
                session,
                "watch.complication.placement.corner",
                "approved",
                NOW + timedelta(minutes=1),
                None,
                host_os="watchOS 26.0",
            )
        with self.assertRaisesRegex(VisualApprovalError, "matching current runtime evidence"):
            store.record(
                session,
                "watch.complication.placement.corner",
                "approved",
                NOW + timedelta(minutes=1),
                None,
                host_os="watchOS 27.0",
            )

    def test_placement_binds_current_runtime_receipt(self) -> None:
        session, _ = self.configured_state()
        runtime = runtime_state(session.id, self.placement_identity)

        state, decision = VisualApprovalStore(self.store).record(
            session,
            "watch.complication.placement.corner",
            "approved",
            NOW + timedelta(minutes=2),
            runtime,
            host_os="watchOS 27.0",
        )
        report = build_visual_approval_report(state, runtime)
        placement = next(
            item
            for item in report["requirements"]
            if item["id"] == "watch.complication.placement.corner"
        )

        self.assertEqual(decision.runtime_receipt_id, sha("receipt"))
        self.assertEqual(placement["state"], "approved")

    def test_machine_waiting_suppresses_same_device_review_batch(self) -> None:
        _, state = self.configured_state()

        report = build_visual_approval_report(state, None)

        self.assertEqual(report["state"], "waiting")
        self.assertEqual(report["readyReviewCount"], 2)
        self.assertEqual(report["machineWaitingCount"], 1)
        self.assertFalse(report["reviewBatches"])

    def test_missing_recorded_runtime_receipt_invalidates_placement_green(self) -> None:
        session, _ = self.configured_state()
        runtime = runtime_state(session.id, self.placement_identity)
        state, _ = VisualApprovalStore(self.store).record(
            session,
            "watch.complication.placement.corner",
            "approved",
            NOW + timedelta(minutes=2),
            runtime,
            host_os="watchOS 27.0",
        )
        without_receipt = replace(runtime, receipts=())

        report = build_visual_approval_report(state, without_receipt)
        placement = next(
            item
            for item in report["requirements"]
            if item["id"] == "watch.complication.placement.corner"
        )

        self.assertEqual(placement["state"], "waiting")
        self.assertNotEqual(report["state"], "approved")

    def test_newer_build_runtime_diagnostic_invalidates_placement_green(self) -> None:
        session, _ = self.configured_state()
        runtime = runtime_state(session.id, self.placement_identity)
        state, _ = VisualApprovalStore(self.store).record(
            session,
            "watch.complication.placement.corner",
            "approved",
            NOW + timedelta(minutes=2),
            runtime,
            host_os="watchOS 27.0",
        )
        superseded = replace(
            runtime,
            last_observation=RuntimeObservationSummary(
                attempted_at="2026-08-08T02:03:00Z",
                result="diagnostic",
                runtime_session_id=None,
                runtime_session_active=None,
                runtime_session_created_at=None,
                runtime_session_expires_at=None,
                expected_manifest_id=None,
                enabled_surfaces=(),
                exported_at=None,
                sync_healthy=None,
                sync_action=None,
                uploaded_receipt_count=0,
                downloaded_receipt_count=0,
                deleted_remote_receipt_count=0,
                diagnostics=(),
                surface_diagnostics=(
                    ("watchos.complication", "newer-build-observed"),
                ),
            ),
        )

        report = build_visual_approval_report(state, superseded)
        placement = next(
            item
            for item in report["requirements"]
            if item["id"] == "watch.complication.placement.corner"
        )

        self.assertEqual(placement["state"], "waiting")
        self.assertEqual(
            placement["reason"],
            "approved-runtime-evidence-is-no-longer-current",
        )
        self.assertNotEqual(report["state"], "approved")

    def test_final_report_uses_approval_state_without_carry_forward(self) -> None:
        report = build_report(
            TARGET,
            ASCEvidence("available", "fixture", ()),
            MacEvidence(
                None,
                None,
                "unknown",
                "unknown",
                "not_running",
                "unknown",
                "unknown",
                "unknown",
            ),
            (),
            None,
            NOW,
            requested_surfaces=(),
        )
        report = replace(
            report,
            session={
                "lifecycle": "active",
                "revision": 1,
                "createdAt": "2026-08-08T02:00:00Z",
                "updatedAt": "2026-08-08T02:00:00Z",
                "requestedSurfaces": [],
            },
            visual_approvals={
                "state": "approved",
                "requirementCount": 1,
                "approvedCount": 1,
                "rejectedCount": 0,
                "readyReviewCount": 0,
                "machineWaitingCount": 0,
                "reviewBatches": [],
                "requirements": [
                    {
                        "id": "watch.app.shared.dark",
                        "evidenceClass": "shared-view",
                        "surface": "watchos.app",
                        "device": "Apple Watch",
                        "state": "approved",
                        "reason": "review-approved",
                    }
                ],
            },
        )

        payload = build_final_report_payload(report)

        self.assertEqual(payload["obtainedEvidenceClasses"]["visualApproval"], "approved")
        self.assertNotIn("review-pending", payload["residualRisks"])
        self.assertEqual(payload["carryForwardLineage"]["state"], "not-evaluated")
        rendered = render_final_report(report)
        self.assertIn("## Visual Reviews", rendered)
        self.assertIn("`1/1` approved", rendered)

    def test_cli_records_and_exports_bounded_public_metadata(self) -> None:
        self.configured_state()
        record_args = SimpleNamespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            requirement_id="watch.app.shared.dark",
            decision="approved",
            host_os=None,
            artifact=None,
            json=True,
        )
        export_args = SimpleNamespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            json=True,
        )

        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(self.root)},
                clear=False,
            ),
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=1)),
            contextlib.redirect_stdout(io.StringIO()) as record_output,
        ):
            self.assertEqual(cli_module.run_record_visual_review(record_args), 0)
        recorded = json.loads(record_output.getvalue())

        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(self.root)},
                clear=False,
            ),
            mock.patch.object(cli_module, "utc_now", return_value=NOW + timedelta(minutes=2)),
            contextlib.redirect_stdout(io.StringIO()) as export_output,
        ):
            self.assertEqual(cli_module.run_export_visual_reviews(export_args), 30)
        exported = json.loads(export_output.getvalue())
        serialized = json.dumps(exported, sort_keys=True)

        self.assertEqual(recorded["decision"]["decision"], "approved")
        self.assertEqual(exported["approvedCount"], 1)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn("artifactPath", serialized)

    def test_visual_sidecar_is_pruned_with_terminal_session_retention(self) -> None:
        session, _ = self.configured_state()
        path = self.store.visual_approval_path(session.id)
        self.store.transition(
            TARGET,
            "stopped",
            NOW + timedelta(minutes=1),
            "operator-stopped",
        )

        self.store.prune(NOW + timedelta(days=2))

        self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
