import json
from pathlib import Path
import tempfile
import unittest

from Tests.ScriptsTests.fixtures.runtime_relay import RuntimeRelayFixture


class RuntimeReceiptIntegrationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.fixture = RuntimeRelayFixture(Path(directory.name))
        self.fixture.write_agent()
        issued = self.fixture.issue_receipt()
        self.assertEqual(issued.returncode, 0, issued.stderr)

    def test_runtime_receipt_sync_requires_valid_production_schema_receipt(self):
        receipt = json.loads(self.fixture.receipt_path.read_text())
        receipt["seal"] = "invalid-seal"
        self.fixture.receipt_path.write_text(json.dumps(receipt))

        result = self.fixture.sync()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime receipt relay blocked", result.stderr)
        self.assertIn("receipt seal is invalid", result.stderr)
        self.assertFalse(self.fixture.marker_path.exists())

    def test_runtime_receipt_sync_rejects_a_valid_receipt_for_another_commit(self):
        issued = self.fixture.issue_receipt(source_commit="b" * 40)
        self.assertEqual(issued.returncode, 0, issued.stderr)

        result = self.fixture.sync()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("receipt source commit does not match", result.stderr)
        self.assertFalse(self.fixture.marker_path.exists())

    def test_runtime_receipt_sync_rejects_a_missing_receipt_without_launching(self):
        self.fixture.receipt_path.unlink()

        result = self.fixture.sync()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime receipt relay blocked", result.stderr)
        self.assertFalse(self.fixture.marker_path.exists())

    def test_runtime_receipt_sync_relays_after_schema_receipt_verification(self):
        result = self.fixture.sync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.fixture.marker_path.exists())
        self.assertTrue(json.loads(result.stdout)["healthy"])

    def test_runtime_receipt_sync_rejects_invalid_agent_output(self):
        for output in ("not JSON", "[]", "{}"):
            with self.subTest(output=output):
                self.fixture.write_agent(raw_output=output)
                result = self.fixture.sync()

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("runtime receipt host synchronization returned", result.stderr)
                self.assertTrue(self.fixture.marker_path.exists())

    def test_runtime_receipt_sync_rejects_invalid_transfer_counts(self):
        for field in ("uploadedReceiptCount", "downloadedReceiptCount", "deletedRemoteReceiptCount"):
            for count in (True, -1, "1"):
                with self.subTest(field=field, count=count):
                    payload = {
                        "healthy": True, "sessionAction": "published", "messages": [],
                        "uploadedReceiptCount": 0, "downloadedReceiptCount": 0,
                        "deletedRemoteReceiptCount": 0,
                    }
                    payload[field] = count
                    self.fixture.write_agent(payload=payload)

                    result = self.fixture.sync()

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("unsupported result", result.stderr)

    def test_runtime_receipt_sync_preserves_agent_failures(self):
        for healthy, exit_code in ((False, 0), (True, 3)):
            with self.subTest(healthy=healthy, exit_code=exit_code):
                payload = {
                    "healthy": healthy, "sessionAction": "failed", "messages": [],
                    "uploadedReceiptCount": 0, "downloadedReceiptCount": 0,
                    "deletedRemoteReceiptCount": 0,
                }
                self.fixture.write_agent(payload=payload, exit_code=exit_code)

                result = self.fixture.sync()

                self.assertEqual(result.returncode, exit_code or 2)
                self.assertEqual(json.loads(result.stdout), payload)


if __name__ == "__main__":
    unittest.main()
