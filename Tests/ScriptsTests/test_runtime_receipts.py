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

    def test_runtime_receipt_sync_relays_when_the_contract_is_unchanged_since_release(self):
        result = self.fixture.sync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.fixture.marker_path.exists())
        self.assertTrue(json.loads(result.stdout)["healthy"])

    def test_runtime_receipt_sync_blocks_a_changed_contract_that_production_lacks(self):
        self.fixture.change_contract()

        result = self.fixture.sync()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime receipt relay blocked", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.fixture.marker_path.exists())

    def test_runtime_receipt_sync_relays_a_changed_contract_after_production_matches(self):
        self.fixture.change_contract()
        self.fixture.write_cktool(exports_contract=True)
        self.fixture.environment["CLOUDKIT_MANAGEMENT_TOKEN"] = "fixture-token"

        result = self.fixture.sync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.fixture.marker_path.exists())

    def test_runtime_receipt_sync_blocks_when_release_history_is_unreadable(self):
        for script in ("#!/bin/sh\nexit 8\n", "#!/bin/sh\nprintf 'invalid output\\n'\n"):
            with self.subTest(script=script):
                git = self.fixture.tools / "git"
                git.write_text(script)
                git.chmod(0o755)

                result = self.fixture.sync()

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("runtime receipt relay blocked", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse(self.fixture.marker_path.exists())

    def test_runtime_receipt_sync_rejects_invalid_agent_output(self):
        for output in ("not JSON", "[]", "{}"):
            with self.subTest(output=output):
                self.fixture.write_agent(raw_output=output)
                result = self.fixture.sync()

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("runtime receipt host synchronization returned", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertTrue(self.fixture.marker_path.exists())

    def test_runtime_receipt_sync_rejects_invalid_transfer_counts(self):
        for field in ("uploadedReceiptCount", "downloadedReceiptCount", "deletedRemoteReceiptCount"):
            for count in (True, -1, "1", 1.5):
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
                    self.assertEqual(result.stdout, "")

    def test_runtime_receipt_sync_rejects_invalid_status_or_messages(self):
        for field, value in (("healthy", "true"), ("sessionAction", "unknown"), ("messages", "error"), ("messages", [1])):
            with self.subTest(field=field, value=value):
                payload = {
                    "healthy": True, "sessionAction": "published", "messages": [],
                    "uploadedReceiptCount": 0, "downloadedReceiptCount": 0,
                    "deletedRemoteReceiptCount": 0,
                }
                payload[field] = value
                self.fixture.write_agent(payload=payload)

                result = self.fixture.sync()

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unsupported result", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_runtime_receipt_sync_preserves_agent_failures(self):
        for healthy, exit_code in ((False, 0), (True, 3), (False, 3)):
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
