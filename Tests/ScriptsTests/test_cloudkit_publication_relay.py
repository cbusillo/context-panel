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
        relay.verify_result(received, self.request, now=self.now, key=KEY)
        self.assertEqual(
            received["validatedAt"], relay.receipts.format_timestamp(self.now)
        )

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

        with (
            patch.object(relay.subprocess, "run", side_effect=run),
            self.assertRaisesRegex(relay.RelayError, "update the Mac checker"),
        ):
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

        with (
            patch.object(relay.receipts, "require_key", return_value=KEY),
            self.assertRaisesRegex(relay.RelayError, "unavailable"),
        ):
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
            check.assert_called_once()
            self.assertEqual(check.call_args.args, (self.request, github))

    def test_failed_request_does_not_repeat_or_starve_other_channels(self):
        other = {**self.request, "channel": "macos", "nonce": "c" * 64}
        github = self.github()
        requests = [self.request, other]
        github.pending_requests.return_value = [
            {
                "id": i,
                "name": relay.REQUEST_PREFIX + relay.digest(r),
                "workflow_run": {"id": r["runID"]},
            }
            for i, r in enumerate(requests)
        ]
        github.download.side_effect = lambda artifact: requests[artifact["id"]]

        def check(request, _, **_kwargs):
            if request["channel"] == "github":
                raise relay.receipts.ReceiptError("schema mismatch")

        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(relay, "check_on_mac", side_effect=check) as checked,
        ):
            state = Path(directory) / "served.json"
            self.assertEqual(relay.serve_requests(github, state), 1)
            self.assertEqual(relay.serve_requests(github, state), 0)
            self.assertEqual(checked.call_count, 2)
            self.assertEqual(
                json.loads(state.read_text())[relay.digest(other)]["outcome"],
                "dispatched",
            )

    def test_overlapping_pass_cannot_start_an_export(self):
        github = self.github()
        github.pending_requests.return_value = [
            {
                "id": 1,
                "name": relay.REQUEST_PREFIX + relay.digest(self.request),
                "workflow_run": {"id": 42},
            }
        ]
        github.download.return_value = self.request
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "served.json"

            def check(*_, **_kwargs):
                self.assertEqual(relay.serve_requests(github, state), 0)

            with patch.object(relay, "check_on_mac", side_effect=check) as checked:
                self.assertEqual(relay.serve_requests(github, state), 0)
                checked.assert_called_once()

    def test_invalid_result_and_transient_read_do_not_veto_valid_evidence(self):
        github = self.github()
        handler = github.api.side_effect
        calls = [0]

        def api(path):
            calls[0] += 1
            if calls[0] == 1:
                raise relay.GitHubReadError(retryable=True)
            return handler(path)

        github.api.side_effect = api
        name = relay.RESULT_PREFIX + relay.digest(self.request)
        github.artifacts.return_value = [
            {"name": name, "id": 1},
            {"name": name, "id": 2},
        ]
        good = self.receipt()
        github.download.side_effect = [{**good, "seal": "wrong"}, good]
        elapsed = [0]

        def sleep(seconds):
            elapsed[0] += seconds

        with (
            patch.object(relay.receipts, "require_key", return_value=KEY),
            patch.object(relay.receipts, "datetime", wraps=datetime) as clock,
        ):
            clock.now.return_value = self.now
            self.assertEqual(
                relay.wait_for_result(
                    self.request,
                    github,
                    timeout=30,
                    clock=lambda: elapsed[0],
                    sleep=sleep,
                ),
                good,
            )
        self.assertEqual(elapsed[0], 15)

    def test_partial_rerun_uses_successful_prior_jobs_but_never_a_failed_new_guard(
        self,
    ):
        jobs = [{**job, "run_attempt": 1} for job in self.jobs]
        relay.trusted_run(self.request, self.run, jobs)
        jobs.append(
            {
                "name": "Validate Trusted Release Source",
                "conclusion": "failure",
                "run_attempt": 2,
            }
        )
        with self.assertRaises(relay.RelayError):
            relay.trusted_run(self.request, self.run, jobs)

    def test_final_entrypoint_requires_original_request_for_bound_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            # Issue at the caller's current clock; the verifier is a subprocess.
            receipt = self.receipt(now=datetime.now(UTC))
            path = scratch / "receipt.json"
            request_path = scratch / "request.json"
            path.write_text(json.dumps(receipt))
            request_path.write_text(json.dumps(self.request))
            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith(("CONTEXT_PANEL_", "GITHUB_", "CLOUDKIT_"))
            }
            env.update(
                CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY=KEY.decode(),
                CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_PATH=str(path),
            )
            command = [
                "/bin/bash",
                str(ROOT / "scripts/require-cloudkit-schema-receipt.sh"),
                "--source-commit",
                self.request["sourceCommit"],
            ]
            self.assertNotEqual(
                subprocess.run(
                    command, env=env, capture_output=True, check=False
                ).returncode,
                0,
            )
            env["CONTEXT_PANEL_CLOUDKIT_PUBLICATION_REQUEST_PATH"] = str(request_path)
            self.assertEqual(
                subprocess.run(
                    command, env=env, capture_output=True, check=False
                ).returncode,
                0,
            )
            request_path.write_text(json.dumps({**self.request, "runAttempt": 3}))
            self.assertNotEqual(
                subprocess.run(
                    command, env=env, capture_output=True, check=False
                ).returncode,
                0,
            )

    def test_operator_wrapper_refreshes_objects_without_changing_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            log = scratch / "commands.log"
            tools = {
                "uname": "#!/bin/bash\necho Darwin\n",
                "git": '#!/bin/bash\nprintf "git %s\\n" "$*" >>"$FAKE_COMMAND_LOG"\n'
                'if [[ "$3" == status ]]; then [[ "${FAKE_DIRTY:-}" != true ]] || echo " M source.py"; exit 0; fi\n'
                '[[ "$3 $4 $5 $6" == "fetch --no-tags origin $FAKE_DEFAULT_BRANCH" ]] || exit 64\n',
                "uv": '#!/bin/bash\nprintf "uv %s\\n" "$*" >>"$FAKE_COMMAND_LOG"\n',
                "security": "#!/bin/bash\nexit 64\n",
            }
            for name, content in tools.items():
                path = scratch / name
                path.write_text(content)
                path.chmod(0o755)
            env = {
                k: v
                for k, v in os.environ.items()
                if not k.startswith(("CONTEXT_PANEL_", "GITHUB_", "CLOUDKIT_"))
            }
            env.update(
                PATH=str(scratch) + os.pathsep + env["PATH"],
                FAKE_COMMAND_LOG=str(log),
                FAKE_DEFAULT_BRANCH=json.loads(
                    (ROOT / ".github/github.json").read_text()
                )["defaultBranch"],
                CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY=KEY.decode(),
            )
            command = [
                "/bin/bash",
                str(ROOT / "scripts/cloudkit-schema-operator.sh"),
                str(scratch / "bot-helper"),
            ]
            result = subprocess.run(command, env=env, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = log.read_text().splitlines()
            self.assertIn(
                "fetch --no-tags origin "
                + json.loads((ROOT / ".github/github.json").read_text())[
                    "defaultBranch"
                ],
                commands[1],
            )
            self.assertTrue(commands[2].startswith("uv "))
            log.unlink()
            env["FAKE_DIRTY"] = "true"
            self.assertNotEqual(
                subprocess.run(
                    command, env=env, capture_output=True, check=False
                ).returncode,
                0,
            )
            self.assertEqual(len(log.read_text().splitlines()), 1)

    def test_pre_export_read_failure_can_recover_without_duplicate_export(self):
        github = self.github()
        github.pending_requests.return_value = [
            {
                "id": 1,
                "name": relay.REQUEST_PREFIX + relay.digest(self.request),
                "workflow_run": {"id": self.request["runID"]},
            }
        ]
        github.download.return_value = self.request
        handler = github.api.side_effect
        failed = [False]

        def api(path):
            if "/jobs?" in path and not failed[0]:
                failed[0] = True
                raise relay.GitHubReadError(retryable=True)
            return handler(path)

        github.api.side_effect = api
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(relay, "live_check", return_value=self.receipt()) as check,
        ):
            state = Path(directory) / "served.json"
            self.assertEqual(relay.serve_requests(github, state), 1)
            check.assert_not_called()
            self.assertEqual(json.loads(state.read_text()), {})
            self.assertEqual(relay.serve_requests(github, state), 0)
            self.assertEqual(relay.serve_requests(github, state), 0)
            check.assert_called_once()
            github.respond.assert_called_once()

    def test_rate_limit_read_classification_preserves_server_wait_and_redacts(self):
        server_wait = 90
        result = subprocess.CompletedProcess(
            [],
            1,
            b"",
            f"HTTP 403 secondary rate limit; Retry-After: {server_wait}; {KEY.decode()}".encode(),
        )
        with (
            patch.object(relay.subprocess, "run", return_value=result),
            self.assertRaises(relay.GitHubReadError) as raised,
        ):
            relay.GitHub().api("actions/artifacts")
        self.assertTrue(raised.exception.retryable)
        self.assertEqual(raised.exception.retry_after, server_wait)
        self.assertNotIn(KEY.decode(), str(raised.exception))

    def test_stale_checker_recovers_same_request_before_any_export(self):
        github = self.github()
        github.pending_requests.return_value = [
            {
                "id": 1,
                "name": relay.REQUEST_PREFIX + relay.digest(self.request),
                "workflow_run": {"id": self.request["runID"]},
            }
        ]
        github.download.return_value = self.request
        stale = [True]
        exports = []
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "served.json"

            def run(args, **_kwargs):
                if args[0] == "git":
                    name = args[-1].split(":", 1)[1]
                    return subprocess.CompletedProcess(
                        args,
                        0,
                        b"older validator" if stale[0] else (ROOT / name).read_bytes(),
                        b"",
                    )
                self.assertEqual(
                    json.loads(state.read_text())[relay.digest(self.request)][
                        "outcome"
                    ],
                    "checking",
                )
                exports.append(args)
                output = Path(args[args.index("--receipt-output") + 1])
                output.write_text(json.dumps(self.receipt(now=datetime.now(UTC))))
                return subprocess.CompletedProcess(args, 0)

            with (
                patch.object(relay.subprocess, "run", side_effect=run),
                patch.object(relay.receipts, "require_key", return_value=KEY),
            ):
                self.assertEqual(relay.serve_requests(github, state), 1)
                self.assertEqual(json.loads(state.read_text()), {})
                self.assertEqual(exports, [])
                github.respond.assert_not_called()
                stale[0] = False
                self.assertEqual(relay.serve_requests(github, state), 0)
                self.assertEqual(relay.serve_requests(github, state), 0)
                self.assertEqual(len(exports), 1)
                github.respond.assert_called_once()

    def test_missing_verification_key_refuses_before_request_artifact(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict(os.environ, CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY=""),
            patch.object(relay, "request_from_environment") as request,
        ):
            path = Path(directory) / "request.json"
            self.assertEqual(relay.main(["request", "--request", str(path)]), 1)
            request.assert_not_called()
            self.assertFalse(path.exists())

    def test_ambiguous_response_dispatch_never_repeats_the_write_or_export(self):
        github = self.github()
        github.pending_requests.return_value = [
            {
                "id": 1,
                "name": relay.REQUEST_PREFIX + relay.digest(self.request),
                "workflow_run": {"id": self.request["runID"]},
            }
        ]
        github.download.return_value = self.request
        github.respond.side_effect = relay.GitHubReadError(retryable=True)

        def check(request, *, before_export):
            before_export()
            return self.receipt(request=request)

        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(relay, "live_check", side_effect=check) as live,
        ):
            state = Path(directory) / "served.json"
            self.assertEqual(relay.serve_requests(github, state), 1)
            self.assertEqual(relay.serve_requests(github, state), 0)
            live.assert_called_once()
            github.respond.assert_called_once()
            self.assertEqual(
                json.loads(state.read_text())[relay.digest(self.request)]["outcome"],
                "failed",
            )

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
