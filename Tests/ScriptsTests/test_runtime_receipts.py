import json
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_RECEIPT_KEY = "runtime-receipt-test-key-32-bytes-minimum"


class RuntimeReceiptIntegrationTests(unittest.TestCase):
    def source_commit(self) -> str:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def issue_cloudkit_schema_receipt(self, path: Path) -> None:
        environment = os.environ.copy()
        environment["CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"] = SCHEMA_RECEIPT_KEY
        result = subprocess.run(
            [
                "python3",
                str(ROOT / "scripts/cloudkit-schema-receipt.py"),
                "issue",
                "--source-commit",
                self.source_commit(),
                "--output",
                str(path),
            ],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def write_fake_sync_agent(self, root: Path) -> tuple[Path, Path]:
        marker_path = root / "agent-ran"
        agent_path = root / "refresh-agent"
        payload = json.dumps(
            {
                "healthy": True,
                "sessionAction": "unchanged",
                "uploadedReceiptCount": 0,
                "downloadedReceiptCount": 0,
                "deletedRemoteReceiptCount": 0,
                "messages": [],
            },
            separators=(",", ":"),
        )
        agent_path.write_text(
            "#!/bin/sh\n"
            "if [ -n \"${CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY:-}\" ]; then\n"
            "  exit 9\n"
            "fi\n"
            f"touch {shlex.quote(str(marker_path))}\n"
            f"printf '%s\\n' {shlex.quote(payload)}\n"
        )
        agent_path.chmod(0o755)
        return agent_path, marker_path

    def test_runtime_receipt_sync_requires_valid_production_schema_receipt(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt_path = root / "schema-receipt.json"
            agent_path, marker_path = self.write_fake_sync_agent(root)
            self.issue_cloudkit_schema_receipt(receipt_path)
            receipt = json.loads(receipt_path.read_text())
            receipt["sourceCommit"] = "b" * 40
            receipt_path.write_text(json.dumps(receipt))
            environment = os.environ.copy()
            environment["CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"] = SCHEMA_RECEIPT_KEY

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "scripts/context-panel-runtime-session.py"),
                    "sync",
                    "--agent",
                    str(agent_path),
                    "--cloudkit-schema-receipt",
                    str(receipt_path),
                ],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runtime receipt relay blocked", result.stderr)
            self.assertFalse(marker_path.exists())

    def test_runtime_receipt_sync_relays_after_schema_receipt_verification(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt_path = root / "schema-receipt.json"
            agent_path, marker_path = self.write_fake_sync_agent(root)
            self.issue_cloudkit_schema_receipt(receipt_path)
            environment = os.environ.copy()
            environment["CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"] = SCHEMA_RECEIPT_KEY

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "scripts/context-panel-runtime-session.py"),
                    "sync",
                    "--agent",
                    str(agent_path),
                    "--cloudkit-schema-receipt",
                    str(receipt_path),
                ],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(marker_path.exists())
            self.assertTrue(json.loads(result.stdout)["healthy"])


if __name__ == "__main__":
    unittest.main()
