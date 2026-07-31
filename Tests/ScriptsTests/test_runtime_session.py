import json
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "context-panel-runtime-session.py"


class RuntimeSessionScriptTests(unittest.TestCase):
    def run_script(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=ROOT,
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
    def receipt(session: dict[str, object]) -> dict[str, object]:
        created_at = datetime.strptime(
            str(session["createdAt"]), "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)
        observed_at = created_at + timedelta(seconds=1)
        retention_expires_at = observed_at + timedelta(
            seconds=int(session["receiptTTLSeconds"])
        )
        executable_uuid = "11111111-2222-3333-4444-555555555555"
        process_uuid = "00000000-0000-0000-0000-000000000001"
        receipt: dict[str, object] = {
            "schemaVersion": 1,
            "evidenceClass": "actual-runtime",
            "sessionID": session["id"],
            "sessionCreatedAt": session["createdAt"],
            "sessionExpiresAt": session["expiresAt"],
            "observedAt": observed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "retentionExpiresAt": retention_expires_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "processInstanceID": process_uuid,
            "processSequence": 1,
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
            "1",
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
