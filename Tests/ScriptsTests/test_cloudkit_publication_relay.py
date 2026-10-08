"""Secretless relay behavior; clocks, GitHub, schema export and publication are fakes."""

import copy
import importlib.util
import io
import json
import os
import re
import subprocess
import tempfile
import unittest
import zipfile
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "relay", ROOT / "scripts/cloudkit-publication-relay.py"
)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
KEY = b"fake-only-receipt-seal-key-for-tests"


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.request = {
            "repository": relay.REPOSITORY,
            "sourceCommit": "a" * 40,
            "runID": 42,
            "runAttempt": 2,
            "channel": "github",
            "nonce": "b" * 64,
        }
        self.now = datetime(2026, 10, 8, tzinfo=UTC)
        self.run = {
            "id": 42,
            "run_attempt": 2,
            "head_sha": "a" * 40,
            "head_branch": "main",
            "event": "workflow_dispatch",
            "status": "in_progress",
            "path": ".github/workflows/ship.yml",
        }
        self.jobs = [
            {"name": "Approve Release Intent", "conclusion": "success"},
            {"name": "Validate Trusted Release Source", "conclusion": "success"},
        ]

    def receipt(self, *, now=None, request=None, ckdb=None):
        request = self.request if request is None else request
        return relay.receipts.issue_receipt(
            environment="production",
            container_identifier=relay.receipts.CONTAINER_IDENTIFIER,
            schema_path=ROOT / "CloudKit/companion-sync.schema.json",
            cktool_schema_path=ckdb or ROOT / "CloudKit/companion-sync.schema.ckdb",
            source_commit=request["sourceCommit"],
            ttl_seconds=21600,
            key=KEY,
            now=now or self.now,
            publication_request_digest=relay.digest(request),
        )

    def github(self):
        github = Mock()

        def api(path):
            if path.startswith("compare/"):
                return {"status": "ahead"}
            if "/jobs?" in path:
                return {"jobs": self.jobs}
            return self.run

        github.api.side_effect = api
        return github

    def test_approval_days_after_dispatch_gets_one_fresh_live_check(self):
        self.run["created_at"] = (self.now - timedelta(days=3)).isoformat()
        github = self.github()
        check = Mock(return_value=self.receipt())
        relay.check_on_mac(self.request, github, schema_check=check)
        check.assert_called_once_with(self.request)
        result = github.respond.call_args.args[0]
        with (
            patch.object(relay.receipts, "require_key", return_value=KEY),
            patch.object(relay.receipts, "datetime", wraps=datetime) as clock,
        ):
            clock.now.return_value = self.now
            github.artifacts.return_value = [
                {
                    "name": relay.RESULT_PREFIX + relay.digest(self.request),
                    "expired": False,
                }
            ]
            github.download.return_value = result
            received = relay.wait_for_result(self.request, github)
        publish = Mock()
        relay.verify_result(received, self.request, now=self.now, key=KEY)
        publish()
        publish.assert_called_once()

    def test_failed_schema_export_or_mismatch_never_relays_result(self):
        for error in (
            RuntimeError("export failed"),
            relay.receipts.ReceiptError("schema differs"),
        ):
            with self.subTest(error=error):
                github = self.github()
                check = Mock(side_effect=error)
                with self.assertRaises(type(error)):
                    relay.check_on_mac(self.request, github, schema_check=check)
                github.respond.assert_not_called()

    def test_actual_validator_issues_bound_result_only_for_matching_live_schema(self):
        original_run = subprocess.run
        for mismatch in (False, True):
            with (
                self.subTest(mismatch=mismatch),
                tempfile.TemporaryDirectory() as directory,
            ):
                scratch = Path(directory)
                schema = (ROOT / "CloudKit/companion-sync.schema.ckdb").read_text()
                if mismatch:
                    schema = re.sub(r"\bpayload\s+BYTES\b", "payload STRING", schema)
                live = scratch / "live.ckdb"
                live.write_text(schema)
                fake = scratch / "xcrun"
                fake.write_text(
                    '#!/bin/bash\n[[ "$1 $2" == "cktool export-schema" ]] || exit 64\n'
                    'while [[ $# -gt 0 ]]; do if [[ "$1" == "--output-file" ]]; then /bin/cp "$FAKE_SCHEMA" "$2"; exit; fi; shift; done\nexit 64\n'
                )
                fake.chmod(0o755)
                env = {
                    k: v
                    for k, v in os.environ.items()
                    if not k.startswith(("CLOUDKIT_", "CONTEXT_PANEL_"))
                }
                env.update(
                    PATH=str(scratch) + os.pathsep + env["PATH"],
                    FAKE_SCHEMA=str(live),
                    CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY=KEY.decode(),
                )

                def run(args, fixture_environment=env, **kwargs):
                    if args[0] == "git":
                        name = args[-1].split(":", 1)[1]
                        return subprocess.CompletedProcess(
                            args, 0, (ROOT / name).read_bytes(), b""
                        )
                    return original_run(args, **kwargs, env=fixture_environment)

                with (
                    patch.object(relay.subprocess, "run", side_effect=run),
                    patch.object(relay.receipts, "require_key", return_value=KEY),
                ):
                    if mismatch:
                        with self.assertRaises(subprocess.CalledProcessError):
                            relay.live_check(self.request)
                    else:
                        receipt = relay.live_check(self.request)
                        relay.verify_result(receipt, self.request, key=KEY)

    def test_stale_mac_gate_code_refuses_before_cloudkit_access(self):
        def run(args, **kwargs):
            self.assertEqual(args[0], "git")
            return subprocess.CompletedProcess(args, 0, b"older validator", b"")

        with patch.object(relay.subprocess, "run", side_effect=run):
            with self.assertRaisesRegex(relay.RelayError, "update the Mac checker"):
                relay.live_check(self.request)

    def test_other_request_run_attempt_channel_and_schema_cannot_publish(self):
        receipt = self.receipt()
        variants = {
            "nonce": "c" * 64,
            "runID": 43,
            "runAttempt": 3,
            "channel": "macos",
            "sourceCommit": "d" * 40,
        }
        for field, value in variants.items():
            with self.subTest(field=field):
                request = {**self.request, field: value}
                with self.assertRaises(relay.receipts.ReceiptError):
                    relay.verify_result(receipt, request, now=self.now, key=KEY)
        altered = copy.deepcopy(receipt)
        altered["publicationRequestDigest"] = relay.digest(
            {**self.request, "nonce": "c" * 64}
        )
        with self.assertRaises(relay.receipts.ReceiptError):
            relay.verify_result(
                altered, {**self.request, "nonce": "c" * 64}, now=self.now, key=KEY
            )
        with self.assertRaises(relay.receipts.ReceiptError):
            relay.verify_result(
                receipt, self.request, now=self.now + timedelta(hours=7), key=KEY
            )
        with self.assertRaises(relay.receipts.ReceiptError):
            relay.verify_result(
                receipt, self.request, now=self.now, key=KEY, ckdb=ROOT / "README.md"
            )

    def test_untrusted_pending_or_unapproved_run_never_checks_schema(self):
        for field, value in {
            "status": "completed",
            "head_branch": "work/test",
            "event": "pull_request",
            "path": ".github/workflows/ci.yml",
            "head_sha": "f" * 40,
            "run_attempt": 1,
        }.items():
            with self.subTest(field=field):
                github = self.github()
                original = self.run
                self.run = {**original, field: value}
                check = Mock()
                with self.assertRaises(relay.RelayError):
                    relay.check_on_mac(self.request, github, schema_check=check)
                check.assert_not_called()
                github.respond.assert_not_called()
                self.run = original
        self.jobs[0]["conclusion"] = "skipped"
        with self.assertRaises(relay.RelayError):
            relay.check_on_mac(self.request, self.github(), schema_check=Mock())

    def test_cancellation_during_check_never_relays(self):
        github = self.github()

        def check(_):
            self.run["status"] = "completed"
            return self.receipt()

        with self.assertRaises(relay.RelayError):
            relay.check_on_mac(self.request, github, schema_check=check)
        github.respond.assert_not_called()

    def test_unavailable_mac_times_out_without_real_sleep(self):
        github = self.github()
        github.artifacts.return_value = []
        elapsed = [0]

        def sleep(seconds):
            elapsed[0] += seconds

        with self.assertRaisesRegex(relay.RelayError, "unavailable"):
            relay.wait_for_result(
                self.request, github, timeout=30, clock=lambda: elapsed[0], sleep=sleep
            )
        self.assertEqual(elapsed[0], 30)
        github.download.assert_not_called()

    def test_operator_passes_do_not_repeat_a_successfully_dispatched_check(self):
        github = self.github()
        github.pending_requests.return_value = [
            {
                "id": 5,
                "name": relay.REQUEST_PREFIX + relay.digest(self.request),
                "expired": False,
                "workflow_run": {"id": self.request["runID"]},
            }
        ]
        github.download.return_value = self.request
        github.artifacts.return_value = []
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(relay, "GitHub", return_value=github),
            patch.object(relay, "check_on_mac") as check,
        ):
            args = [
                "serve-once",
                "--served-state",
                str(Path(directory) / "served.json"),
            ]
            self.assertEqual(relay.main(args), 0)
            self.assertEqual(relay.main(args), 0)
            check.assert_called_once_with(self.request, github)

    def test_archive_transport_cannot_extract_paths_or_accept_multiple_files(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr("../../ignored.json", json.dumps(self.request))
        self.assertEqual(relay.decode_artifact(stream.getvalue()), self.request)
        with zipfile.ZipFile(stream, "a") as archive:
            archive.writestr("second.json", "{}")
        with self.assertRaises(relay.RelayError):
            relay.decode_artifact(stream.getvalue())

    def test_requests_refuse_other_repositories_and_non_main_runs(self):
        env = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": relay.REPOSITORY,
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "42",
            "GITHUB_RUN_ATTEMPT": "2",
        }
        request = relay.request_from_environment("github", env)
        relay.validate_request(request)
        for change in (
            {"GITHUB_REF": "refs/heads/work/test"},
            {"GITHUB_REPOSITORY": "other/repo"},
        ):
            with self.assertRaises(relay.RelayError):
                relay.request_from_environment("github", {**env, **change})


if __name__ == "__main__":
    unittest.main()
