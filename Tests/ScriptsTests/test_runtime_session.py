import json
from datetime import datetime, timedelta, timezone
import hashlib
import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "context-panel-runtime-session.py"


class RuntimeSessionScriptTests(unittest.TestCase):
    def run_script(
        self,
        *arguments: str,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_start_status_and_stop_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(self.manifest()))

            started = self.run_script(
                "start",
                "--root",
                str(root / "validation"),
                "--manifest",
                str(manifest),
                "--surface",
                "macos.widget",
                "--duration-minutes",
                "10",
            )
            self.assertEqual(started.returncode, 0, started.stderr)
            started_payload = json.loads(started.stdout)
            self.assertTrue(started_payload["active"])
            self.assertEqual(started_payload["enabledSurfaces"], ["macos.widget"])

            session_path = root / "validation" / "runtime-session.json"
            session = json.loads(session_path.read_text())
            receipt_directory = root / "validation" / "Runtime Receipts"
            receipt_directory.mkdir()
            receipt = self.receipt(session)
            receipt_path = receipt_directory / f"{receipt['id']}.json"
            receipt_path.write_text(json.dumps(receipt))
            (receipt_directory / "malformed.json").write_text(
                json.dumps({"sessionID": session["id"], "buildIdentity": {"surface": "macos.widget"}})
            )

            status = self.run_script("status", "--root", str(root / "validation"))
            self.assertEqual(status.returncode, 0, status.stderr)
            status_payload = json.loads(status.stdout)
            self.assertTrue(status_payload["active"])
            self.assertEqual(status_payload["receiptCount"], 1)
            self.assertEqual(status_payload["observedSurfaces"], ["macos.widget"])

            stopped = self.run_script("stop", "--root", str(root / "validation"))
            self.assertEqual(stopped.returncode, 0, stopped.stderr)
            self.assertEqual(json.loads(stopped.stdout), {"active": False, "closed": True})
            self.assertFalse(session_path.exists())
            self.assertTrue(receipt_path.exists())

            archived_status = self.run_script(
                "status",
                "--root",
                str(root / "validation"),
            )
            self.assertEqual(archived_status.returncode, 0, archived_status.stderr)
            archived_payload = json.loads(archived_status.stdout)
            self.assertFalse(archived_payload["active"])
            self.assertTrue(archived_payload["valid"])
            self.assertEqual(archived_payload["receiptCount"], 1)

    def test_start_rejects_a_surface_outside_the_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(self.manifest()))

            completed = self.run_script(
                "start",
                "--root",
                str(root / "validation"),
                "--manifest",
                str(manifest),
                "--surface",
                "macos.app",
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("absent from the exact build manifest", completed.stderr)
            self.assertFalse((root / "validation" / "runtime-session.json").exists())

    def test_status_does_not_activate_a_malformed_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            validation_root = root / "validation"
            validation_root.mkdir()
            (validation_root / "runtime-session.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "id": "10000000-0000-0000-0000-000000000001",
                        "createdAt": "2026-07-31T00:00:00Z",
                        "expiresAt": "2099-07-31T00:30:00Z",
                        "expectedManifestID": "a" * 64,
                        "enabledSurfaces": ["macos.widget"],
                        "minimumWriteIntervalSeconds": 30,
                        "receiptTTLSeconds": 86400,
                        "maximumReceiptCount": 999,
                    }
                )
            )

            completed = self.run_script("status", "--root", str(validation_root))

            self.assertEqual(completed.returncode, 0, completed.stderr)
            payload = json.loads(completed.stdout)
            self.assertFalse(payload["active"])
            self.assertFalse(payload["valid"])
            self.assertEqual(payload["receiptCount"], 0)

            stopped = self.run_script("stop", "--root", str(validation_root))
            self.assertEqual(stopped.returncode, 0, stopped.stderr)
            self.assertEqual(json.loads(stopped.stdout), {"active": False, "closed": True})
            self.assertFalse((validation_root / "runtime-session.json").exists())

    def test_start_all_surfaces_archives_the_exact_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest = root / "manifest.json"
            payload = self.manifest()
            surfaces = payload["surfaces"]
            assert isinstance(surfaces, list)
            surfaces.append(
                {
                    "id": "watchos.complication",
                    "artifactId": "watchos.complication",
                    "bundleIdentifier": "com.shinycomputers.contextpanel.watch.widget",
                    "fingerprints": {
                        "render": "1" * 64,
                        "runtime": "2" * 64,
                        "placement": "3" * 64,
                        "combined": "4" * 64,
                    },
                }
            )
            manifest.write_text(json.dumps(payload))

            completed = self.run_script(
                "start",
                "--root",
                str(root / "validation"),
                "--manifest",
                str(manifest),
                "--all-surfaces",
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            started = json.loads(completed.stdout)
            self.assertEqual(
                started["enabledSurfaces"],
                ["macos.widget", "watchos.complication"],
            )
            active = json.loads((root / "validation" / "runtime-session.json").read_text())
            archived = json.loads((root / "validation" / "runtime-session-last.json").read_text())
            self.assertEqual(active, archived)

    def test_status_and_export_merge_remote_receipts_without_upload_loops(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            validation_root = root / "validation"
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(self.manifest()))
            started = self.run_script(
                "start",
                "--root",
                str(validation_root),
                "--manifest",
                str(manifest),
                "--surface",
                "macos.widget",
            )
            self.assertEqual(started.returncode, 0, started.stderr)
            session = json.loads((validation_root / "runtime-session.json").read_text())
            first = self.receipt(session, process_sequence=1, observed_offset_seconds=2)
            second = self.receipt(session, process_sequence=2, observed_offset_seconds=1)
            local_directory = validation_root / "Runtime Receipts"
            local_directory.mkdir()
            (local_directory / f"{second['id']}.json").write_text(json.dumps(second))
            remote_directory = validation_root / "Remote Runtime Receipts"
            remote_directory.mkdir()
            server_received_at = datetime.strptime(
                str(session["createdAt"]), "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=timezone.utc) + timedelta(seconds=10)
            for receipt in (first, second):
                (remote_directory / f"{receipt['id']}.json").write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "receipt": receipt,
                            "serverReceivedAt": server_received_at.strftime(
                                "%Y-%m-%dT%H:%M:%SZ"
                            ),
                        }
                    )
                )

            status = self.run_script("status", "--root", str(validation_root))
            exported = self.run_script("export", "--root", str(validation_root))

            self.assertEqual(status.returncode, 0, status.stderr)
            status_payload = json.loads(status.stdout)
            self.assertEqual(status_payload["receiptCount"], 2)
            self.assertEqual(status_payload["localReceiptCount"], 1)
            self.assertEqual(status_payload["remoteReceiptCount"], 2)
            self.assertEqual(exported.returncode, 0, exported.stderr)
            export_payload = json.loads(exported.stdout)
            self.assertEqual(
                [entry["receipt"]["processSequence"] for entry in export_payload["receipts"]],
                [1, 2],
            )
            self.assertEqual(
                next(
                    entry["source"]
                    for entry in export_payload["receipts"]
                    if entry["receipt"]["id"] == second["id"]
                ),
                "cloudkit",
            )

    def test_start_rejects_a_second_active_session_and_retains_closed_sessions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            validation_root = root / "validation"
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(self.manifest()))
            first_start = self.run_script(
                "start",
                "--root",
                str(validation_root),
                "--manifest",
                str(manifest),
                "--surface",
                "macos.widget",
            )
            self.assertEqual(first_start.returncode, 0, first_start.stderr)
            first_session = json.loads(first_start.stdout)

            rejected = self.run_script(
                "start",
                "--root",
                str(validation_root),
                "--manifest",
                str(manifest),
                "--surface",
                "macos.widget",
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("already active", rejected.stderr)

            receipt = self.receipt(first_session)
            receipt_directory = validation_root / "Runtime Receipts"
            receipt_directory.mkdir()
            (receipt_directory / f"{receipt['id']}.json").write_text(json.dumps(receipt))
            self.assertEqual(
                self.run_script("stop", "--root", str(validation_root)).returncode,
                0,
            )
            second_start = self.run_script(
                "start",
                "--root",
                str(validation_root),
                "--manifest",
                str(manifest),
                "--surface",
                "macos.widget",
            )
            self.assertEqual(second_start.returncode, 0, second_start.stderr)
            second_session = json.loads(second_start.stdout)
            self.assertGreater(second_session["createdAt"], first_session["createdAt"])

            status = self.run_script(
                "status",
                "--root",
                str(validation_root),
                "--session-id",
                str(first_session["id"]),
            )
            exported = self.run_script(
                "export",
                "--root",
                str(validation_root),
                "--session-id",
                str(first_session["id"]),
            )

            self.assertEqual(status.returncode, 0, status.stderr)
            self.assertEqual(json.loads(status.stdout)["receiptCount"], 1)
            self.assertEqual(exported.returncode, 0, exported.stderr)
            self.assertEqual(json.loads(exported.stdout)["session"]["id"], first_session["id"])
            self.assertEqual(len(list((validation_root / "Runtime Sessions").glob("*.json"))), 2)

    def test_export_rejects_injected_fields_and_expired_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            validation_root = root / "validation"
            validation_root.mkdir()
            now = datetime.now(timezone.utc).replace(microsecond=0)
            created_at = now - timedelta(hours=3)
            expires_at = now - timedelta(hours=1)
            session: dict[str, object] = {
                "schemaVersion": 1,
                "id": "10000000-0000-0000-0000-000000000001",
                "createdAt": created_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "expiresAt": expires_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "expectedManifestID": "a" * 64,
                "enabledSurfaces": ["macos.widget"],
                "minimumWriteIntervalSeconds": 0,
                "receiptTTLSeconds": 2 * 60 * 60,
                "maximumReceiptCount": 128,
            }
            for path in (
                validation_root / "runtime-session-last.json",
                validation_root
                / "Runtime Sessions"
                / "10000000-0000-0000-0000-000000000001.json",
            ):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(session))

            expired = self.receipt(session, observed_offset_seconds=1)
            injected = self.receipt(session, process_sequence=2, observed_offset_seconds=2)
            injected["accountID"] = "must-not-leak"
            nested = self.receipt(session, process_sequence=3, observed_offset_seconds=3)
            nested_build = nested["buildIdentity"]
            self.assertIsInstance(nested_build, dict)
            nested_build["privatePath"] = "/Users/example/private"
            local_directory = validation_root / "Runtime Receipts"
            local_directory.mkdir()
            for index, receipt in enumerate((expired, injected, nested)):
                (local_directory / f"local-{index}.json").write_text(json.dumps(receipt))
            remote_directory = validation_root / "Remote Runtime Receipts"
            remote_directory.mkdir()
            (remote_directory / "expired.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "receipt": expired,
                        "serverReceivedAt": (
                            created_at + timedelta(seconds=10)
                        ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    }
                )
            )

            exported = self.run_script("export", "--root", str(validation_root))

            self.assertEqual(exported.returncode, 0, exported.stderr)
            payload = json.loads(exported.stdout)
            self.assertEqual(payload["receiptCount"], 0)
            self.assertNotIn("must-not-leak", exported.stdout)
            self.assertNotIn("/Users/example/private", exported.stdout)

    def test_export_rejects_an_injected_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            validation_root = root / "validation"
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(self.manifest()))
            started = self.run_script(
                "start",
                "--root",
                str(validation_root),
                "--manifest",
                str(manifest),
                "--surface",
                "macos.widget",
            )
            self.assertEqual(started.returncode, 0, started.stderr)
            for path in (
                validation_root / "runtime-session.json",
                validation_root / "runtime-session-last.json",
                next((validation_root / "Runtime Sessions").glob("*.json")),
            ):
                session = json.loads(path.read_text())
                session["accountID"] = "must-not-leak"
                path.write_text(json.dumps(session))

            exported = self.run_script("export", "--root", str(validation_root))

            self.assertNotEqual(exported.returncode, 0)
            self.assertNotIn("must-not-leak", exported.stdout)

    def test_export_order_is_stable_for_server_time_cycle_and_clock_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            validation_root = root / "validation"
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(self.manifest()))
            started = self.run_script(
                "start",
                "--root",
                str(validation_root),
                "--manifest",
                str(manifest),
                "--surface",
                "macos.widget",
            )
            self.assertEqual(started.returncode, 0, started.stderr)
            session = json.loads(started.stdout)
            first_process = "00000000-0000-0000-0000-000000000001"
            other_process = "00000000-0000-0000-0000-000000000002"
            first = self.receipt(
                session,
                process_sequence=1,
                observed_offset_seconds=20,
                process_uuid=first_process,
            )
            second = self.receipt(
                session,
                process_sequence=2,
                observed_offset_seconds=10,
                process_uuid=first_process,
            )
            other = self.receipt(
                session,
                process_sequence=1,
                observed_offset_seconds=15,
                process_uuid=other_process,
            )
            created_at = datetime.strptime(
                str(session["createdAt"]), "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=timezone.utc)
            remote_directory = validation_root / "Remote Runtime Receipts"
            remote_directory.mkdir()
            for name, receipt, offset in (
                ("z.json", second, 10),
                ("x.json", other, 15),
                ("y.json", first, 20),
            ):
                (remote_directory / name).write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "receipt": receipt,
                            "serverReceivedAt": (
                                created_at + timedelta(seconds=offset)
                            ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        }
                    )
                )

            exported = self.run_script("export", "--root", str(validation_root))

            self.assertEqual(exported.returncode, 0, exported.stderr)
            ordered = [entry["receipt"]["id"] for entry in json.loads(exported.stdout)["receipts"]]
            self.assertEqual(ordered, [other["id"], first["id"], second["id"]])

    def test_sync_uses_the_signed_host_result_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            agent = root / "agent"
            schema_receipt = root / "cloudkit-schema-receipt.json"
            source_commit_result = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(
                source_commit_result.returncode,
                0,
                source_commit_result.stderr,
            )
            source_commit = source_commit_result.stdout.strip()
            environment = os.environ.copy()
            environment["CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"] = (
                "runtime-session-schema-receipt-test-key"
            )
            agent.write_text(
                "#!/bin/sh\n"
                "cat <<'JSON'\n"
                '{"healthy":true,"sessionAction":"published",'
                '"uploadedReceiptCount":2,"downloadedReceiptCount":3,'
                '"deletedRemoteReceiptCount":1,"messages":[]}\n'
                "JSON\n"
            )
            agent.chmod(0o755)
            issued = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/cloudkit-schema-receipt.py"),
                    "issue",
                    "--source-commit",
                    source_commit,
                    "--output",
                    str(schema_receipt),
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(issued.returncode, 0, issued.stderr)

            completed = self.run_script(
                "sync",
                "--agent",
                str(agent),
                "--cloudkit-schema-receipt",
                str(schema_receipt),
                environment=environment,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            payload = json.loads(completed.stdout)
            self.assertTrue(payload["healthy"])
            self.assertEqual(payload["uploadedReceiptCount"], 2)

    @staticmethod
    def manifest() -> dict[str, object]:
        return {
            "schemaVersion": 1,
            "kind": "context-panel-surface-build-intent",
            "manifestId": "a" * 64,
            "contractFingerprint": "b" * 64,
            "surfaces": [
                {
                    "id": "macos.widget",
                    "artifactId": "macos.widget",
                    "bundleIdentifier": "com.shinycomputers.contextpanel.widget",
                    "fingerprints": {
                        "render": "c" * 64,
                        "runtime": "d" * 64,
                        "placement": "e" * 64,
                        "combined": "f" * 64,
                    },
                }
            ],
        }

    @staticmethod
    def receipt(
        session: dict[str, object],
        process_sequence: int = 1,
        observed_offset_seconds: int = 1,
        process_uuid: str = "00000000-0000-0000-0000-000000000001",
    ) -> dict[str, object]:
        created_at = datetime.strptime(
            str(session["createdAt"]), "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)
        observed_at = created_at + timedelta(seconds=observed_offset_seconds)
        retention_expires_at = observed_at + timedelta(
            seconds=int(session["receiptTTLSeconds"])
        )
        executable_uuid = "11111111-2222-3333-4444-555555555555"
        receipt: dict[str, object] = {
            "schemaVersion": 1,
            "evidenceClass": "actual-runtime",
            "sessionID": session["id"],
            "sessionCreatedAt": session["createdAt"],
            "sessionExpiresAt": session["expiresAt"],
            "observedAt": observed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "retentionExpiresAt": retention_expires_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "processInstanceID": process_uuid,
            "processSequence": process_sequence,
            "buildIdentity": {
                "surface": "macos.widget",
                "platform": "macOS",
                "artifactID": "macos.widget",
                "bundleIdentifier": "com.shinycomputers.contextpanel.widget",
                "build": {
                    "marketingVersion": "1.0.54",
                    "buildNumber": "2026073101",
                    "manifestID": session["expectedManifestID"],
                    "contractFingerprint": "b" * 64,
                },
                "fingerprints": {
                    "render": "c" * 64,
                    "runtime": "d" * 64,
                    "placement": "e" * 64,
                    "combined": "f" * 64,
                },
                "executableUUIDs": [executable_uuid],
            },
            "trigger": "widget-timeline",
            "presentationMode": "widget-system-small",
            "selectedSource": "app-group-snapshot",
            "presentationDigest": "8" * 64,
            "stateBranch": "ready",
            "outcome": "success",
        }
        build = receipt["buildIdentity"]
        assert isinstance(build, dict)
        build_coordinate = build["build"]
        fingerprints = build["fingerprints"]
        assert isinstance(build_coordinate, dict)
        assert isinstance(fingerprints, dict)
        parts = [
            str(session["id"]).lower(),
            str(int(created_at.timestamp())),
            str(int(datetime.strptime(str(session["expiresAt"]), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())),
            str(int(observed_at.timestamp())),
            str(int(retention_expires_at.timestamp())),
            str(build["surface"]),
            str(build["platform"]),
            str(build["artifactID"]),
            str(build["bundleIdentifier"]),
            str(build_coordinate["marketingVersion"]),
            str(build_coordinate["buildNumber"]),
            str(build_coordinate["manifestID"]),
            str(build_coordinate["contractFingerprint"]),
            str(fingerprints["render"]),
            str(fingerprints["runtime"]),
            str(fingerprints["placement"]),
            str(fingerprints["combined"]),
            executable_uuid,
            process_uuid.lower(),
            str(process_sequence),
            str(receipt["trigger"]),
            str(receipt["presentationMode"]),
            str(receipt["selectedSource"]),
            str(receipt["presentationDigest"]),
            str(receipt["stateBranch"]),
            str(receipt["outcome"]),
        ]
        digest = hashlib.sha256()
        for part in ["context-panel/runtime-receipt/id/v1", *parts]:
            encoded = part.encode()
            digest.update(struct.pack(">Q", len(encoded)))
            digest.update(encoded)
        receipt["id"] = digest.hexdigest()
        return receipt


if __name__ == "__main__":
    unittest.main()
