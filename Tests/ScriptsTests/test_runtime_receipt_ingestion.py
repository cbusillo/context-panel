import hashlib
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_validation import (
    ASCEvidence,
    ASCPlatformEvidence,
    MacEvidence,
    RuntimeEvidenceError,
    RuntimeEvidenceStore,
    RuntimeSessionAdapter,
    RuntimeSessionObservation,
    SessionStateStore,
    Target,
    build_runtime_evidence_report,
    load_expected_surface_identities,
)
from context_panel_validation.models import CommandResult
from context_panel_validation import runtime_evidence as runtime_module
from context_panel_validation import cli as cli_module
from context_panel_surface_manifest.cli import evidence_template
from context_panel_surface_manifest.core import (
    generate_manifest,
    resolve_policy,
    seal_expected_build,
)


NOW = datetime(2026, 8, 1, 12, 0, tzinfo=timezone.utc)
TARGET = Target("1.0.53", "202608010100")
MANIFEST_ID = "a" * 64
CONTRACT_FINGERPRINT = "b" * 64
PROCESS_UUID = "11111111-2222-3333-4444-555555555555"
LOADED_UUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
SECOND_UUID = "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"


SURFACE_BUNDLES = {
    "macos.app": ("macos.app", "com.shinycomputers.contextpanel"),
    "macos.widget": (
        "macos.widget",
        "com.shinycomputers.contextpanel.widget",
    ),
    "macos.refresh-agent": (
        "macos.refresh-agent",
        "com.shinycomputers.contextpanel.refresh-agent",
    ),
    "watchos.app": ("watchos.app", "com.shinycomputers.contextpanel.watch"),
    "watchos.complication": (
        "watchos.complication",
        "com.shinycomputers.contextpanel.watch.widget",
    ),
    "tvos.app": ("tvos.app", "com.shinycomputers.contextpanel.tv"),
    "tvos.top-shelf": (
        "tvos.top-shelf",
        "com.shinycomputers.contextpanel.tv.topshelf",
    ),
}


def sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def fingerprints(surface: str) -> dict[str, str]:
    return {
        "render": sha(f"{surface}:render"),
        "runtime": sha(f"{surface}:runtime"),
        "placement": sha(f"{surface}:placement"),
        "combined": sha(f"{surface}:combined"),
    }


def expected_manifest(surfaces: tuple[str, ...]) -> dict[str, object]:
    artifacts = []
    surface_entries = []
    for surface in surfaces:
        artifact_id, bundle_id = SURFACE_BUNDLES[surface]
        artifacts.append(
            {
                "artifactId": artifact_id,
                "bundleIdentifier": bundle_id,
                "marketingVersion": TARGET.version,
                "buildNumber": TARGET.build_number,
                "sourceCommit": "0123456789abcdef",
                "configuration": "Release",
                "xcodeBuild": "17A000",
                "treeState": "clean",
                "codeSignatureValid": True,
                "executableSha256": sha(f"{artifact_id}:executable"),
                "executableUUIDs": [LOADED_UUID, SECOND_UUID],
                "entitlementsSha256": sha(f"{artifact_id}:entitlements"),
                "profileSha256": sha(f"{artifact_id}:profile"),
            }
        )
        surface_entries.append(
            {
                "id": surface,
                "artifactId": artifact_id,
                "bundleIdentifier": bundle_id,
                "fingerprints": fingerprints(surface),
            }
        )
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "kind": "context-panel-expected-signed-build",
        "algorithm": "sha256",
        "digestDomain": "context-panel-surface/v1",
        "sourceManifestId": MANIFEST_ID,
        "contractFingerprint": CONTRACT_FINGERPRINT,
        "layout": "fixture",
        "archive": {"layout": "fixture", "name": "fixture.xcarchive"},
        "source": {
            "marketingVersion": TARGET.version,
            "buildNumber": TARGET.build_number,
            "commit": "0123456789abcdef",
            "configuration": "Release",
            "xcodeBuild": "17A000",
            "treeState": "clean",
        },
        "artifacts": artifacts,
        "surfaces": surface_entries,
    }
    payload["expectedBuildId"] = runtime_module.hash_parts(
        "context-panel-surface/v1/expected-build",
        [runtime_module.canonical_json(payload)],
    )
    return payload


def runtime_status(
    surfaces: tuple[str, ...],
    *,
    active: bool = True,
    session_id: str = "00000000-0000-0000-0000-000000000001",
    expires_at: datetime | None = None,
) -> dict[str, object]:
    return {
        "active": active,
        "valid": True,
        "id": str(uuid.UUID(session_id)).upper(),
        "createdAt": "2026-08-01T12:00:00Z",
        "expiresAt": (expires_at or NOW + timedelta(minutes=30))
        .astimezone(timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expectedManifestID": MANIFEST_ID,
        "enabledSurfaces": sorted(surfaces),
        "receiptCount": 0,
        "localReceiptCount": 0,
        "remoteReceiptCount": 0,
        "retainedSessionCount": 1,
        "retainedSessionIDs": [str(uuid.UUID(session_id)).upper()],
        "observedSurfaces": [],
    }


def runtime_receipt(
    surface: str,
    status: dict[str, object],
    *,
    process_sequence: int = 1,
    observed_at: datetime | None = None,
    process_uuid: str = PROCESS_UUID,
    source: str = "cloudkit",
) -> dict[str, object]:
    artifact_id, bundle_id = SURFACE_BUNDLES[surface]
    observed = observed_at or NOW + timedelta(seconds=process_sequence)
    trigger = "app-snapshot-load"
    presentation_mode = "app-overview"
    if surface.endswith("widget") or surface == "watchos.complication":
        trigger = "widget-timeline"
        presentation_mode = "widget-system-small"
    elif surface == "macos.refresh-agent":
        trigger = "background-refresh"
        presentation_mode = "refresh-agent"
    elif surface == "tvos.top-shelf":
        trigger = "top-shelf-content-load"
        presentation_mode = "top-shelf"
    receipt = {
        "schemaVersion": 1,
        "evidenceClass": "actual-runtime",
        "id": sha(f"{surface}:{process_uuid}:{process_sequence}:{observed.isoformat()}"),
        "sessionID": status["id"],
        "sessionCreatedAt": status["createdAt"],
        "sessionExpiresAt": status["expiresAt"],
        "observedAt": observed.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "retentionExpiresAt": (observed + timedelta(hours=24)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "processInstanceID": str(uuid.UUID(process_uuid)).upper(),
        "processSequence": process_sequence,
        "buildIdentity": {
            "surface": surface,
            "platform": runtime_module.SURFACE_PLATFORMS[surface],
            "artifactID": artifact_id,
            "bundleIdentifier": bundle_id,
            "build": {
                "marketingVersion": TARGET.version,
                "buildNumber": TARGET.build_number,
                "manifestID": MANIFEST_ID,
                "contractFingerprint": CONTRACT_FINGERPRINT,
            },
            "fingerprints": fingerprints(surface),
            "executableUUIDs": [LOADED_UUID],
        },
        "trigger": trigger,
        "presentationMode": presentation_mode,
        "selectedSource": "cloudkit",
        "presentationDigest": sha(f"{surface}:presentation"),
        "stateBranch": "ready",
        "outcome": "success",
    }
    return {
        "source": source,
        "serverReceivedAt": (
            (observed + timedelta(seconds=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
            if source == "cloudkit"
            else None
        ),
        "receipt": receipt,
    }


def runtime_export(
    status: dict[str, object],
    entries: list[dict[str, object]],
) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "active": status["active"],
        "exportedAt": "2026-08-01T12:01:00Z",
        "session": {
            "schemaVersion": 1,
            "id": status["id"],
            "createdAt": status["createdAt"],
            "expiresAt": status["expiresAt"],
            "expectedManifestID": status["expectedManifestID"],
            "enabledSurfaces": status["enabledSurfaces"],
            "minimumWriteIntervalSeconds": 30,
            "receiptTTLSeconds": 86400,
            "maximumReceiptCount": 128,
        },
        "receiptCount": len(entries),
        "localReceiptCount": sum(entry["source"] == "local" for entry in entries),
        "remoteReceiptCount": sum(entry["source"] == "cloudkit" for entry in entries),
        "receipts": entries,
    }


def observation(
    status: dict[str, object] | None,
    export: dict[str, object] | None,
    *,
    diagnostics: tuple[str, ...] = (),
    sync_payload: dict[str, object] | None = None,
    attempted_at: datetime = NOW + timedelta(minutes=1),
) -> RuntimeSessionObservation:
    return RuntimeSessionObservation(
        attempted_at,
        sync_payload,
        status,
        export,
        diagnostics,
    )


class QueueRunner:
    def __init__(self, results: list[CommandResult]):
        self.results = list(results)
        self.commands: list[list[str]] = []

    def run(self, args, *, timeout, environment=None):
        self.commands.append(list(args))
        if not self.results:
            raise AssertionError(f"unexpected command: {args}")
        return self.results.pop(0)


class RuntimeReceiptIngestionTests(unittest.TestCase):
    def fixture(self, surfaces: tuple[str, ...]):
        temporary_directory = tempfile.TemporaryDirectory()
        root = Path(temporary_directory.name)
        store = SessionStateStore(root / "Coordinator", root / "Legacy")
        session, _ = store.start_session(
            TARGET,
            surfaces,
            NOW,
            timedelta(hours=72),
            timedelta(days=30),
        )
        manifest_path = root / "ExpectedBuildManifest-fixture.json"
        manifest_path.write_text(json.dumps(expected_manifest(surfaces)))
        identities = load_expected_surface_identities(
            [manifest_path],
            TARGET,
            session.requested_surfaces,
        )
        runtime_store = RuntimeEvidenceStore(store)
        state = runtime_store.attach_expected(session, identities, NOW)
        self.assertIsNotNone(state)
        return temporary_directory, store, runtime_store, session, state

    def test_loader_accepts_the_repository_expected_build_manifest_contract(self):
        source_manifest = generate_manifest(
            resolve_policy(REPO_ROOT),
            marketing_version=TARGET.version,
            build_number=TARGET.build_number,
            source_commit="0123456789abcdef",
            configuration="Release",
            xcode_build="17A000",
            tree_state="clean",
        )
        artifact_evidence = evidence_template(source_manifest)
        for artifact in artifact_evidence["artifacts"]:
            artifact_id = artifact["artifactId"]
            artifact.update(
                {
                    "codeSignatureValid": True,
                    "executableSha256": sha(f"{artifact_id}:executable"),
                    "executableUUIDs": [LOADED_UUID],
                    "entitlementsSha256": sha(f"{artifact_id}:entitlements"),
                    "profileSha256": sha(f"{artifact_id}:profile"),
                }
            )
        sealed = seal_expected_build(source_manifest, artifact_evidence)
        surfaces = tuple(sorted(surface["id"] for surface in sealed["surfaces"]))
        with tempfile.TemporaryDirectory() as temporary_directory:
            manifest_path = Path(temporary_directory) / "ExpectedBuildManifest-fixture.json"
            manifest_path.write_text(json.dumps(sealed))
            identities = load_expected_surface_identities(
                [manifest_path],
                TARGET,
                surfaces,
            )

        self.assertEqual(
            [identity.surface for identity in identities],
            list(surfaces),
        )

    def test_incremental_manifests_cannot_mix_disjoint_contract_identities(self):
        surfaces = ("macos.app", "macos.widget")
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        store = SessionStateStore(root / "Coordinator", root / "Legacy")
        session, _ = store.start_session(
            TARGET,
            surfaces,
            NOW,
            timedelta(hours=72),
            timedelta(days=30),
        )
        app_manifest_path = root / "ExpectedBuildManifest-app.json"
        app_manifest_path.write_text(json.dumps(expected_manifest(("macos.app",))))
        runtime_store = RuntimeEvidenceStore(store)
        runtime_store.attach_expected(
            session,
            load_expected_surface_identities(
                [app_manifest_path],
                TARGET,
                session.requested_surfaces,
            ),
            NOW,
        )
        widget_manifest = expected_manifest(("macos.widget",))
        widget_manifest["sourceManifestId"] = "c" * 64
        widget_manifest["contractFingerprint"] = "d" * 64
        widget_manifest.pop("expectedBuildId")
        widget_manifest["expectedBuildId"] = runtime_module.hash_parts(
            "context-panel-surface/v1/expected-build",
            [runtime_module.canonical_json(widget_manifest)],
        )
        widget_manifest_path = root / "ExpectedBuildManifest-widget.json"
        widget_manifest_path.write_text(json.dumps(widget_manifest))
        widget_identities = load_expected_surface_identities(
            [widget_manifest_path],
            TARGET,
            session.requested_surfaces,
        )

        with self.assertRaisesRegex(RuntimeEvidenceError, "one manifest identity"):
            runtime_store.attach_expected(
                session,
                widget_identities,
                NOW + timedelta(minutes=1),
            )

    def test_adapter_observes_status_and_exact_session_export_without_sync(self):
        surfaces = ("macos.app",)
        status = runtime_status(surfaces)
        export = runtime_export(status, [runtime_receipt("macos.app", status)])
        runner = QueueRunner(
            [
                CommandResult(0, json.dumps(status), ""),
                CommandResult(0, json.dumps(export), ""),
            ]
        )

        result = RuntimeSessionAdapter(runner).collect(NOW)

        self.assertIsNotNone(result.export_payload)
        self.assertEqual([command[-1] for command in runner.commands[:1]], ["status"])
        self.assertEqual(runner.commands[1][-2:], ["--session-id", status["id"]])
        self.assertNotIn("sync", [part for command in runner.commands for part in command])

    def test_explicit_sync_uses_signed_host_contract_and_does_not_persist_messages(self):
        surfaces = ("macos.app",)
        status = runtime_status(surfaces)
        export = runtime_export(status, [runtime_receipt("macos.app", status)])
        sync = {
            "healthy": True,
            "sessionAction": "published",
            "uploadedReceiptCount": 1,
            "downloadedReceiptCount": 1,
            "deletedRemoteReceiptCount": 0,
            "messages": ["private /Users/example/device and token-secret"],
        }
        runner = QueueRunner(
            [
                CommandResult(0, json.dumps(sync), ""),
                CommandResult(0, json.dumps(status), ""),
                CommandResult(0, json.dumps(export), ""),
            ]
        )
        temporary, store, runtime_store, session, _ = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)

        state, _ = runtime_store.reconcile(
            session,
            RuntimeSessionAdapter(runner).sync_and_collect(NOW),
        )

        self.assertEqual([command[-1] for command in runner.commands[:2]], ["sync", "status"])
        persisted = store.runtime_evidence_path(session.id).read_text()
        self.assertNotIn("/Users/example", persisted)
        self.assertNotIn("token-secret", persisted)
        self.assertTrue(state.last_observation.sync_healthy)

    def test_exact_matching_rejects_each_wrong_identity_field(self):
        surfaces = ("macos.app",)
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)
        base_entry = runtime_receipt("macos.app", status)
        mutations = {
            "version": lambda receipt: receipt["buildIdentity"]["build"].update(
                {"marketingVersion": "1.0.52"}
            ),
            "build": lambda receipt: receipt["buildIdentity"]["build"].update(
                {"buildNumber": "202607310099"}
            ),
            "manifest": lambda receipt: receipt["buildIdentity"]["build"].update(
                {"manifestID": "c" * 64}
            ),
            "contract": lambda receipt: receipt["buildIdentity"]["build"].update(
                {"contractFingerprint": "c" * 64}
            ),
            "artifact": lambda receipt: receipt["buildIdentity"].update(
                {"artifactID": "wrong.artifact"}
            ),
            "bundle": lambda receipt: receipt["buildIdentity"].update(
                {"bundleIdentifier": "com.example.wrong"}
            ),
            "platform": lambda receipt: receipt["buildIdentity"].update(
                {"platform": "iOS"}
            ),
            "render-fingerprint": lambda receipt: receipt["buildIdentity"][
                "fingerprints"
            ].update({"render": "c" * 64}),
            "runtime-fingerprint": lambda receipt: receipt["buildIdentity"][
                "fingerprints"
            ].update({"runtime": "c" * 64}),
            "placement-fingerprint": lambda receipt: receipt["buildIdentity"][
                "fingerprints"
            ].update({"placement": "c" * 64}),
            "combined-fingerprint": lambda receipt: receipt["buildIdentity"][
                "fingerprints"
            ].update({"combined": "c" * 64}),
            "uuid": lambda receipt: receipt["buildIdentity"].update(
                {"executableUUIDs": ["CCCCCCCC-DDDD-EEEE-FFFF-000000000000"]}
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                entry = json.loads(json.dumps(base_entry))
                mutate(entry["receipt"])
                next_state, superseded = runtime_module.reconcile_runtime_observation(
                    state,
                    observation(status, runtime_export(status, [entry])),
                )
                report = build_runtime_evidence_report(next_state, NOW + timedelta(minutes=2))
                self.assertFalse(superseded)
                self.assertEqual(report["provenSurfaceCount"], 0)
                self.assertIn(
                    report["surfaces"][0]["state"],
                    {"diagnostic", "unknown"},
                )

    def test_multiarch_expected_manifest_accepts_loaded_uuid_subset(self):
        surfaces = ("macos.app",)
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)

        next_state, superseded = runtime_module.reconcile_runtime_observation(
            state,
            observation(
                status,
                runtime_export(status, [runtime_receipt("macos.app", status)]),
            ),
        )

        self.assertFalse(superseded)
        self.assertEqual(len(next_state.receipts), 1)

    def test_receipt_cannot_prove_a_runtime_session_targeting_another_manifest(self):
        surfaces = ("macos.app",)
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)
        status["expectedManifestID"] = "c" * 64
        next_state, _ = runtime_module.reconcile_runtime_observation(
            state,
            observation(
                status,
                runtime_export(status, [runtime_receipt("macos.app", status)]),
            ),
        )

        report = build_runtime_evidence_report(next_state, NOW + timedelta(minutes=2))
        self.assertEqual(report["provenSurfaceCount"], 0)
        self.assertEqual(
            report["surfaces"][0]["reason"],
            "identity-mismatch:runtime-session-manifest",
        )

    def test_duplicate_receipts_are_deduplicated_and_process_order_is_stable(self):
        surfaces = ("macos.app",)
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)
        second = runtime_receipt("macos.app", status, process_sequence=2)
        first = runtime_receipt("macos.app", status, process_sequence=1)

        next_state, _ = runtime_module.reconcile_runtime_observation(
            state,
            observation(status, runtime_export(status, [second, first, first])),
        )

        self.assertEqual(len(next_state.receipts), 2)
        self.assertEqual(
            [receipt.process_sequence for receipt in next_state.receipts],
            [1, 2],
        )

    def test_active_runtime_window_is_waiting_then_expired_silence_is_unknown(self):
        surfaces = ("macos.app",)
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        active_status = runtime_status(surfaces, expires_at=NOW + timedelta(minutes=30))
        waiting_state, _ = runtime_module.reconcile_runtime_observation(
            state,
            observation(active_status, runtime_export(active_status, [])),
        )
        waiting_report = build_runtime_evidence_report(
            waiting_state,
            NOW + timedelta(minutes=10),
        )
        expired_status = runtime_status(
            surfaces,
            active=False,
            expires_at=NOW + timedelta(minutes=30),
        )
        expired_state, _ = runtime_module.reconcile_runtime_observation(
            waiting_state,
            observation(
                expired_status,
                runtime_export(expired_status, []),
                attempted_at=NOW + timedelta(minutes=31),
            ),
        )
        expired_report = build_runtime_evidence_report(
            expired_state,
            NOW + timedelta(minutes=31),
        )

        self.assertEqual(waiting_report["state"], "waiting")
        self.assertEqual(waiting_report["surfaces"][0]["reason"], "receipt-propagation")
        self.assertEqual(expired_report["state"], "unknown")
        self.assertEqual(expired_report["surfaces"][0]["reason"], "receipt-silence")

    def test_missing_extension_after_exact_host_receipt_is_diagnostic_not_failure(self):
        surfaces = ("macos.app", "macos.widget")
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces, active=False)
        next_state, _ = runtime_module.reconcile_runtime_observation(
            state,
            observation(
                status,
                runtime_export(status, [runtime_receipt("macos.app", status)]),
            ),
        )

        report = build_runtime_evidence_report(next_state, NOW + timedelta(hours=1))
        widget = next(item for item in report["surfaces"] if item["surface"] == "macos.widget")
        self.assertEqual(report["provenSurfaceCount"], 1)
        self.assertEqual(widget["state"], "diagnostic")
        self.assertEqual(widget["reason"], "app-current-extension-stale-or-silent")

    def test_watch_complication_and_top_shelf_require_their_own_receipts(self):
        surfaces = (
            "tvos.app",
            "tvos.top-shelf",
            "watchos.app",
            "watchos.complication",
        )
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces, active=False)
        entries = [
            runtime_receipt("watchos.app", status),
            runtime_receipt("tvos.app", status, process_sequence=2),
        ]
        next_state, _ = runtime_module.reconcile_runtime_observation(
            state,
            observation(status, runtime_export(status, entries)),
        )

        report = build_runtime_evidence_report(next_state, NOW + timedelta(hours=1))
        states = {item["surface"]: item["state"] for item in report["surfaces"]}
        self.assertEqual(report["provenSurfaceCount"], 2)
        self.assertEqual(states["watchos.app"], "proven")
        self.assertEqual(states["tvos.app"], "proven")
        self.assertNotEqual(states["watchos.complication"], "proven")
        self.assertNotEqual(states["tvos.top-shelf"], "proven")

    def test_newer_receipt_supersedes_without_mixing_into_proof(self):
        surfaces = ("macos.app",)
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)
        state, _ = runtime_module.reconcile_runtime_observation(
            state,
            observation(
                status,
                runtime_export(status, [runtime_receipt("macos.app", status)]),
            ),
        )
        entry = runtime_receipt("macos.app", status)
        entry["receipt"]["id"] = sha("newer-runtime-receipt")
        entry["receipt"]["buildIdentity"]["build"].update(
            {"marketingVersion": "1.0.54", "buildNumber": "202608020100"}
        )

        next_state, superseded = runtime_module.reconcile_runtime_observation(
            state,
            observation(status, runtime_export(status, [entry])),
        )

        report = build_runtime_evidence_report(next_state, NOW + timedelta(minutes=2))
        self.assertTrue(superseded)
        self.assertEqual(report["state"], "superseded")
        self.assertEqual(report["provenSurfaceCount"], 0)

    def test_interrupted_export_preserves_previously_reconciled_proof(self):
        surfaces = ("macos.app",)
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)
        proven_state, _ = runtime_module.reconcile_runtime_observation(
            state,
            observation(
                status,
                runtime_export(status, [runtime_receipt("macos.app", status)]),
            ),
        )
        interrupted_state, _ = runtime_module.reconcile_runtime_observation(
            proven_state,
            observation(
                status,
                None,
                diagnostics=("export-timeout",),
                attempted_at=NOW + timedelta(minutes=2),
            ),
        )

        self.assertEqual(interrupted_state.receipts, proven_state.receipts)
        self.assertEqual(
            build_runtime_evidence_report(interrupted_state, NOW + timedelta(minutes=2))[
                "state"
            ],
            "proven",
        )

    def test_later_identity_mismatch_overrides_earlier_proof_without_mixing(self):
        surfaces = ("macos.app",)
        temporary, _, _, _, state = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)
        proven_state, _ = runtime_module.reconcile_runtime_observation(
            state,
            observation(
                status,
                runtime_export(status, [runtime_receipt("macos.app", status)]),
            ),
        )
        mismatched = runtime_receipt("macos.app", status, process_sequence=2)
        mismatched["receipt"]["buildIdentity"]["executableUUIDs"] = [
            "CCCCCCCC-DDDD-EEEE-FFFF-000000000000"
        ]
        diagnostic_state, _ = runtime_module.reconcile_runtime_observation(
            proven_state,
            observation(status, runtime_export(status, [mismatched])),
        )

        report = build_runtime_evidence_report(
            diagnostic_state,
            NOW + timedelta(minutes=2),
        )
        self.assertEqual(report["state"], "unknown")
        self.assertEqual(report["provenSurfaceCount"], 0)
        self.assertEqual(report["surfaces"][0]["state"], "diagnostic")
        self.assertEqual(
            report["surfaces"][0]["reason"],
            "identity-mismatch:executable-uuids",
        )
        retained_diagnostic_state, _ = runtime_module.reconcile_runtime_observation(
            diagnostic_state,
            observation(
                status,
                runtime_export(status, []),
                attempted_at=NOW + timedelta(minutes=3),
            ),
        )
        retained_report = build_runtime_evidence_report(
            retained_diagnostic_state,
            NOW + timedelta(minutes=3),
        )
        self.assertEqual(retained_report["surfaces"][0]["state"], "diagnostic")

    def test_runtime_sidecar_is_additive_to_schema_v1_and_pruned_with_retention(self):
        surfaces = ("macos.app",)
        temporary, store, runtime_store, session, _ = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        session_path = store.path(TARGET)
        session_payload = json.loads(session_path.read_text())
        evidence_path = store.runtime_evidence_path(session.id)

        self.assertEqual(session_payload["schemaVersion"], 1)
        self.assertNotIn("runtimeEvidence", session_payload)
        self.assertTrue(evidence_path.is_file())

        paused = store.transition(
            TARGET,
            "paused",
            NOW + timedelta(minutes=10),
            "operator-unavailable",
        )
        self.assertIsNotNone(runtime_store.load(paused))
        resumed = store.transition(TARGET, "resumed", NOW + timedelta(minutes=20))
        self.assertIsNotNone(runtime_store.load(resumed))
        stopped = store.transition(TARGET, "stopped", NOW + timedelta(hours=1), "operator-stopped")
        self.assertTrue(evidence_path.is_file())
        retention = runtime_module.parse_iso8601(stopped.retention_expires_at)
        store.prune(retention)
        self.assertFalse(session_path.exists())
        self.assertFalse(evidence_path.exists())

    def test_persisted_state_is_privacy_safe_and_not_a_raw_receipt_document(self):
        surfaces = ("macos.app",)
        temporary, store, runtime_store, session, _ = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)
        entry = runtime_receipt("macos.app", status)
        entry["receipt"]["presentationDigest"] = sha("private-account-payload")
        sync = {
            "healthy": False,
            "sessionAction": "failed",
            "uploadedReceiptCount": 0,
            "downloadedReceiptCount": 0,
            "deletedRemoteReceiptCount": 0,
            "messages": ["/private/device/path credential-secret account-123"],
        }
        runtime_store.reconcile(
            session,
            observation(status, runtime_export(status, [entry]), sync_payload=sync),
        )
        persisted = store.runtime_evidence_path(session.id).read_text()

        for forbidden in (
            "/private/device/path",
            "credential-secret",
            "account-123",
            "presentationDigest",
            "selectedSource",
            "bundlePath",
            "rawProviderResponse",
        ):
            self.assertNotIn(forbidden, persisted)

    def test_coordinator_status_reports_exact_surface_proof_from_persisted_export(self):
        surfaces = ("macos.app",)
        temporary, store, _, session, _ = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)
        runtime_observation = observation(
            status,
            runtime_export(status, [runtime_receipt("macos.app", status)]),
        )
        asc = ASCEvidence(
            "available",
            "fixture",
            (ASCPlatformEvidence("MAC_OS", "valid", "available", "VALID"),),
        )
        mac = MacEvidence(
            TARGET.version,
            TARGET.build_number,
            "current",
            "proven",
            "running",
            "testflight",
            "Production",
            "Production",
        )
        manifest_path = Path(temporary.name) / "ExpectedBuildManifest-status.json"
        manifest_path.write_text(json.dumps(expected_manifest(surfaces)))
        args = SimpleNamespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            json=True,
            asc_env_file=Path(temporary.name) / "asc.env",
            expected_build_manifests=[manifest_path],
        )

        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)},
                clear=False,
            ),
            mock.patch.object(cli_module, "collect_asc_evidence", return_value=asc),
            mock.patch.object(cli_module, "collect_mac_evidence", return_value=mac),
            mock.patch.object(cli_module, "collect_device_evidence", return_value=()),
            mock.patch.object(cli_module.RuntimeSessionAdapter, "collect", return_value=runtime_observation),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            exit_code = cli_module.run_status(args)

        payload = json.loads(output.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertEqual(payload["session"]["id"], session.id)
        self.assertEqual(payload["evidence"]["runtimeReceipts"]["state"], "proven")
        self.assertEqual(payload["summary"]["stage"], "exact-build runtime proven")

    def test_coordinator_status_persists_newer_runtime_evidence_as_superseded(self):
        surfaces = ("macos.app",)
        temporary, store, _, _, _ = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces)
        entry = runtime_receipt("macos.app", status)
        entry["receipt"]["buildIdentity"]["build"].update(
            {"marketingVersion": "1.0.54", "buildNumber": "202608020100"}
        )
        runtime_observation = observation(status, runtime_export(status, [entry]))
        asc = ASCEvidence(
            "available",
            "fixture",
            (ASCPlatformEvidence("MAC_OS", "valid", "available", "VALID"),),
        )
        mac = MacEvidence(
            TARGET.version,
            TARGET.build_number,
            "current",
            "proven",
            "running",
            "testflight",
            "Production",
            "Production",
        )
        args = SimpleNamespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            json=True,
            asc_env_file=Path(temporary.name) / "asc.env",
            expected_build_manifests=[],
        )

        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)},
                clear=False,
            ),
            mock.patch.object(cli_module, "collect_asc_evidence", return_value=asc),
            mock.patch.object(cli_module, "collect_mac_evidence", return_value=mac),
            mock.patch.object(cli_module, "collect_device_evidence", return_value=()),
            mock.patch.object(cli_module.RuntimeSessionAdapter, "collect", return_value=runtime_observation),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            exit_code = cli_module.run_status(args)

        payload = json.loads(output.getvalue())
        self.assertEqual(exit_code, 20)
        self.assertEqual(payload["session"]["lifecycle"], "superseded")
        self.assertEqual(payload["session"]["lifecycleReason"], "newer-build-observed")

    def test_explicit_sync_returns_nonfailure_while_bounded_receipt_wait_is_active(self):
        surfaces = ("macos.app",)
        temporary, store, _, _, _ = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces, active=True)
        runtime_observation = observation(status, runtime_export(status, []))
        args = SimpleNamespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            json=True,
            expected_build_manifests=[],
        )

        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)},
                clear=False,
            ),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation,
            ),
            mock.patch.object(
                cli_module,
                "utc_now",
                return_value=NOW + timedelta(minutes=1),
            ),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            exit_code = cli_module.run_sync_runtime_evidence(args)

        payload = json.loads(output.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertEqual(payload["runtimeEvidence"]["state"], "waiting")

    def test_explicit_sync_returns_unknown_when_signed_host_sync_is_degraded(self):
        surfaces = ("macos.app",)
        temporary, store, _, _, _ = self.fixture(surfaces)
        self.addCleanup(temporary.cleanup)
        status = runtime_status(surfaces, active=True)
        sync = {
            "healthy": False,
            "sessionAction": "failed",
            "uploadedReceiptCount": 0,
            "downloadedReceiptCount": 0,
            "deletedRemoteReceiptCount": 0,
            "messages": [],
        }
        runtime_observation = observation(
            status,
            runtime_export(status, []),
            diagnostics=("sync-degraded",),
            sync_payload=sync,
        )
        args = SimpleNamespace(
            version=TARGET.version,
            build_number=TARGET.build_number,
            json=True,
            expected_build_manifests=[],
        )

        with (
            mock.patch.dict(
                os.environ,
                {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(store.root)},
                clear=False,
            ),
            mock.patch.object(
                cli_module.RuntimeSessionAdapter,
                "sync_and_collect",
                return_value=runtime_observation,
            ),
            mock.patch.object(
                cli_module,
                "utc_now",
                return_value=NOW + timedelta(minutes=1),
            ),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            exit_code = cli_module.run_sync_runtime_evidence(args)

        payload = json.loads(output.getvalue())
        self.assertEqual(exit_code, 30)
        self.assertEqual(payload["runtimeEvidence"]["state"], "waiting")
        self.assertEqual(
            payload["runtimeEvidence"]["runtimeSession"]["result"],
            "degraded",
        )


if __name__ == "__main__":
    unittest.main()
