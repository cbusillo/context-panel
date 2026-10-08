#!/usr/bin/env python3
"""Publication-time schema request/receipt transport. No CloudKit credential in CI."""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import importlib.util
import io
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "cbusillo/context-panel"
WORKFLOWS = {
    "ship.yml",
    "release.yml",
    "app-store-connect-upload.yml",
    "app-store-connect-companion-upload.yml",
    "testflight-beta-distribution.yml",
    "submit-app-store-review.yml",
}
CHANNELS = {"github", "macos", "companion", "testflight", "review"}
REQUEST_PREFIX = "cloudkit-request-"
RESULT_PREFIX = "cloudkit-result-"
MAX_BYTES = 65536
spec = importlib.util.spec_from_file_location(
    "schema_receipt", ROOT / "scripts/cloudkit-schema-receipt.py"
)
assert spec and spec.loader
receipts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipts)


class RelayError(RuntimeError):
    pass


class CheckerPreparationError(RelayError):
    """No live check started; a later operator pass can recover."""


class GitHubReadError(RelayError):
    def __init__(self, *, retryable, status=None, retry_after=15):
        super().__init__("GitHub relay read failed")
        self.retryable = retryable
        self.status = status
        self.retry_after = retry_after


def digest(request: dict) -> str:
    return hashlib.sha256(
        json.dumps(request, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def validate_request(request: dict) -> None:
    if set(request) != {
        "repository",
        "sourceCommit",
        "runID",
        "runAttempt",
        "channel",
        "nonce",
    }:
        raise RelayError("invalid publication request fields")
    if request["repository"] != REPOSITORY or request["channel"] not in CHANNELS:
        raise RelayError("unsupported repository or channel")
    if not isinstance(request["sourceCommit"], str) or not re.fullmatch(
        r"[0-9a-f]{40}", request["sourceCommit"]
    ):
        raise RelayError("invalid source commit")
    if any(
        type(request[k]) is not int or request[k] <= 0 for k in ("runID", "runAttempt")
    ):
        raise RelayError("invalid run identity")
    if not isinstance(request["nonce"], str) or not re.fullmatch(
        r"[0-9a-f]{64}", request["nonce"]
    ):
        raise RelayError("invalid publication nonce")


def request_from_environment(channel: str, environment=None) -> dict:
    env = os.environ if environment is None else environment
    if (
        env.get("GITHUB_ACTIONS") != "true"
        or env.get("GITHUB_REF") != "refs/heads/main"
    ):
        raise RelayError("publication requests require a protected-main Actions run")
    request = {
        "repository": env["GITHUB_REPOSITORY"],
        "sourceCommit": env["GITHUB_SHA"],
        "runID": int(env["GITHUB_RUN_ID"]),
        "runAttempt": int(env["GITHUB_RUN_ATTEMPT"]),
        "channel": channel,
        "nonce": secrets.token_hex(32),
    }
    validate_request(request)
    return request


class GitHub:
    def __init__(self, executable="gh"):
        self.executable = executable

    def call(self, args, *, body=None, binary=False):
        try:
            result = subprocess.run(
                [self.executable, *args],
                input=body,
                capture_output=True,
                check=False,
                timeout=30,
            )
        except subprocess.TimeoutExpired as error:
            raise GitHubReadError(retryable=True) from error
        if result.returncode:
            # Classify without exposing CLI stderr/authentication diagnostics.
            transient = re.search(
                rb"HTTP (?:500|502|503|504)|connection reset|connection refused|timed out",
                result.stderr,
            )
            status_match = re.search(rb"HTTP ([0-9]{3})", result.stderr)
            status = int(status_match[1]) if status_match else None
            rate_limited = status == 429 or (
                status == 403
                and re.search(
                    rb"rate limit|abuse detection", result.stderr, re.IGNORECASE
                )
            )
            delay_match = re.search(
                rb"Retry-After[: =]+([0-9]+)", result.stderr, re.IGNORECASE
            )
            delay = int(delay_match[1]) if delay_match else (60 if rate_limited else 15)
            raise GitHubReadError(
                retryable=bool(transient or rate_limited),
                status=status,
                retry_after=delay,
            )
        return result.stdout if binary else json.loads(result.stdout)

    def api(self, path):
        return self.call(["api", f"repos/{REPOSITORY}/{path}"])

    def artifacts(self, run_id=None, name=None):
        endpoint = f"actions/runs/{run_id}/artifacts" if run_id else "actions/artifacts"
        for page in range(1, 11):
            query = {"per_page": 100, "page": page}
            if name is not None:
                query["name"] = name
            entries = self.api(f"{endpoint}?{urlencode(query)}")["artifacts"]
            yield from entries
            if len(entries) < 100:
                return
        raise RelayError("artifact inventory truncated; narrow or clean the mailbox")

    def pending_requests(self):
        result = self.api(
            "actions/runs?branch=main&event=workflow_dispatch&status=in_progress&per_page=100"
        )
        if result["total_count"] >= 100:
            raise RelayError("active release run inventory truncated")
        for run in result["workflow_runs"]:
            if run.get("path") not in {
                f".github/workflows/{name}" for name in WORKFLOWS
            }:
                continue
            yield from self.artifacts(run["id"])

    def download(self, artifact):
        raw = self.call(
            ["api", f"repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip"],
            binary=True,
        )
        return decode_artifact(raw)

    def respond(self, receipt):
        body = json.dumps(
            {
                "ref": "main",
                "inputs": {
                    "receipt_base64": base64.b64encode(
                        json.dumps(receipt).encode()
                    ).decode()
                },
            }
        ).encode()
        result = subprocess.run(
            [
                self.executable,
                "api",
                "--method",
                "POST",
                f"repos/{REPOSITORY}/actions/workflows/cloudkit-schema-result.yml/dispatches",
                "--input",
                "-",
            ],
            input=body,
            capture_output=True,
            check=False,
            timeout=30,
        )
        if result.returncode:
            raise RelayError("schema result dispatch failed")


def decode_artifact(raw: bytes) -> dict:
    if len(raw) > MAX_BYTES:
        raise RelayError("relay artifact is too large")
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries = archive.infolist()
        if len(entries) != 1 or entries[0].file_size > MAX_BYTES:
            raise RelayError("relay artifact must contain one small JSON file")
        value = json.loads(archive.read(entries[0]))
    if not isinstance(value, dict):
        raise RelayError("relay artifact must contain a JSON object")
    return value


def trusted_run(request, run, jobs) -> None:
    validate_request(request)
    if (
        run.get("id") != request["runID"]
        or run.get("run_attempt") != request["runAttempt"]
        or run.get("head_sha") != request["sourceCommit"]
        or run.get("head_branch") != "main"
        or run.get("event") != "workflow_dispatch"
        or run.get("status") != "in_progress"
        or run.get("path") not in {f".github/workflows/{name}" for name in WORKFLOWS}
    ):
        raise RelayError("schema request is not from an active trusted release run")
    for name in ("Approve Release Intent", "Validate Trusted Release Source"):
        matching = [job for job in jobs if job.get("name") == name]
        if any(job.get("run_attempt") is None for job in matching) and any(
            job.get("conclusion") != "success" for job in matching
        ):
            raise RelayError(
                "approval/guard history cannot prove a successful latest execution"
            )
    latest = {}
    for job in jobs:
        name = job.get("name")
        if name not in latest or job.get("run_attempt", 1) > latest[name].get(
            "run_attempt", 1
        ):
            latest[name] = job
    names = {name: job.get("conclusion") for name, job in latest.items()}
    if (
        names.get("Approve Release Intent") != "success"
        or names.get("Validate Trusted Release Source") != "success"
    ):
        raise RelayError(
            "release trust and owner approval must succeed before the schema check"
        )


def verify_result(
    receipt, request, *, now=None, schema=None, ckdb=None, key=None
) -> None:
    validate_request(request)
    receipts.verify_receipt(
        receipt,
        environment="production",
        container_identifier=receipts.CONTAINER_IDENTIFIER,
        source_commit=request["sourceCommit"],
        schema_path=schema or ROOT / "CloudKit/companion-sync.schema.json",
        cktool_schema_path=ckdb or ROOT / "CloudKit/companion-sync.schema.ckdb",
        key=receipts.require_key() if key is None else key,
        now=now,
        publication_request_digest=digest(request),
    )


def wait_for_result(
    request, github, *, timeout=1200, clock=time.monotonic, sleep=time.sleep
):
    key = receipts.require_key()
    deadline = clock() + timeout
    name = RESULT_PREFIX + digest(request)
    while clock() < deadline:
        retry_after = 15
        try:
            run = github.api(f"actions/runs/{request['runID']}")
            if (
                run.get("status") != "in_progress"
                or run.get("run_attempt") != request["runAttempt"]
            ):
                raise RelayError("release run ended or changed attempt")
            for artifact in github.artifacts(name=name):
                if artifact.get("name") != name or artifact.get("expired"):
                    continue
                try:
                    receipt = github.download(artifact)
                    verify_result(receipt, request, key=key)
                except GitHubReadError as error:
                    if error.status in {404, 410}:
                        continue
                    raise
                except (
                    RelayError,
                    receipts.ReceiptError,
                    ValueError,
                    KeyError,
                    zipfile.BadZipFile,
                ):
                    continue
                return receipt
        except GitHubReadError as error:
            if not error.retryable:
                raise
            retry_after = error.retry_after
        sleep(min(retry_after, max(0, deadline - clock())))
    raise RelayError(
        "Mac schema checker unavailable: timed out; publication remains blocked"
    )


def check_on_mac(request, github, *, schema_check=None, before_export=None):
    run = github.api(f"actions/runs/{request['runID']}")
    jobs = github.api(f"actions/runs/{request['runID']}/jobs?filter=all&per_page=100")
    if jobs.get("total_count", len(jobs["jobs"])) >= 100:
        raise RelayError("release job inventory incomplete")
    trusted_run(request, run, jobs["jobs"])
    comparison = github.api(f"compare/{request['sourceCommit']}...main")
    if comparison.get("status") not in {"ahead", "identical"}:
        raise RelayError("release commit is not in current protected main")
    if schema_check is None:
        receipt = live_check(request, before_export=before_export)
    else:
        if before_export is not None:
            before_export()
        receipt = schema_check(request)
    # Cancellation/re-run during the export never produces a relayed result.
    trusted_run(request, github.api(f"actions/runs/{request['runID']}"), jobs["jobs"])
    github.respond(receipt)


def source_bytes(request, path):
    try:
        return subprocess.run(
            ["git", "-C", str(ROOT), "show", f"{request['sourceCommit']}:{path}"],
            check=True,
            capture_output=True,
            timeout=30,
        ).stdout
    except subprocess.SubprocessError as error:
        raise CheckerPreparationError("release Git objects unavailable") from error


def live_check(request, *, before_export=None):
    # Use only fixed local executable code, never scripts supplied by an artifact.
    for name in (
        "validate-cloudkit-companion-schema.sh",
        "cloudkit-schema-receipt.py",
        "cloudkit-publication-relay.py",
    ):
        path = ROOT / "scripts" / name
        if source_bytes(request, f"scripts/{name}") != path.read_bytes():
            raise CheckerPreparationError(
                "update the Mac checker to the release's reviewed gate code"
            )
    with tempfile.TemporaryDirectory(prefix="context-panel-schema-") as directory:
        scratch = Path(directory)
        for name in ("companion-sync.schema.json", "companion-sync.schema.ckdb"):
            (scratch / name).write_bytes(source_bytes(request, f"CloudKit/{name}"))
        output = scratch / "receipt.json"
        if before_export is not None:
            before_export()
        subprocess.run(
            [
                str(ROOT / "scripts/validate-cloudkit-companion-schema.sh"),
                "--live",
                "--schema",
                str(scratch / "companion-sync.schema.json"),
                "--cktool-schema",
                str(scratch / "companion-sync.schema.ckdb"),
                "--source-commit",
                request["sourceCommit"],
                "--receipt-output",
                str(output),
                "--publication-request-digest",
                digest(request),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=180,
        )
        receipt = receipts.load_receipt(output)
        verify_result(
            receipt,
            request,
            schema=scratch / "companion-sync.schema.json",
            ckdb=scratch / "companion-sync.schema.ckdb",
        )
        return receipt


def serve_requests(github, state_path):
    state_path.parent.mkdir(parents=True, exist_ok=True)
    with state_path.with_suffix(".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        served = json.loads(state_path.read_text()) if state_path.exists() else {}
        served = {
            name: entry
            for name, entry in served.items()
            if entry["at"] > time.time() - 86400
        }
        failed = False
        for artifact in github.pending_requests():
            if not artifact.get("name", "").startswith(REQUEST_PREFIX) or artifact.get(
                "expired"
            ):
                continue
            request_digest = None
            try:
                request = github.download(artifact)
                validate_request(request)
                request_digest = digest(request)
                if (
                    artifact["name"] != REQUEST_PREFIX + request_digest
                    or artifact.get("workflow_run", {}).get("id") != request["runID"]
                ):
                    raise RelayError("request artifact/run binding mismatch")
                if request_digest in served:
                    continue
                run = github.api(f"actions/runs/{request['runID']}")
                if (
                    run.get("status") != "in_progress"
                    or run.get("run_attempt") != request["runAttempt"]
                ):
                    continue

                def record_export_start(bound_digest=request_digest):
                    served[bound_digest] = {"at": time.time(), "outcome": "checking"}
                    receipts.write_receipt(state_path, served)

                check_on_mac(request, github, before_export=record_export_start)
                served[request_digest] = {"at": time.time(), "outcome": "dispatched"}
            except (
                RelayError,
                receipts.ReceiptError,
                OSError,
                ValueError,
                KeyError,
                subprocess.SubprocessError,
                zipfile.BadZipFile,
            ) as error:
                failed = True
                if request_digest is not None and not (
                    (
                        isinstance(error, CheckerPreparationError)
                        or isinstance(error, GitHubReadError)
                        and error.retryable
                    )
                    and request_digest not in served
                ):
                    served[request_digest] = {"at": time.time(), "outcome": "failed"}
                reason = (
                    str(error)
                    if isinstance(error, RelayError)
                    else type(error).__name__
                )
                print(f"Mac schema request refused: {reason}", file=sys.stderr)
            receipts.write_receipt(state_path, served)
        return 1 if failed else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("request", "wait", "serve-once", "accept"))
    parser.add_argument("--channel", choices=sorted(CHANNELS))
    parser.add_argument(
        "--request", type=Path, default=Path(".build/cloudkit-publication-request.json")
    )
    parser.add_argument(
        "--output", type=Path, default=Path(".build/cloudkit-publication-receipt.json")
    )
    parser.add_argument("--github-cli", default="gh")
    parser.add_argument(
        "--served-state", type=Path, default=ROOT / ".build/cloudkit-relay-served.json"
    )
    args = parser.parse_args(argv)
    try:
        if args.command == "request":
            receipts.require_key()
            request = request_from_environment(args.channel)
            receipts.write_receipt(args.request, request)
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f"artifact={REQUEST_PREFIX}{digest(request)}\n")
        elif args.command == "wait":
            receipt = wait_for_result(
                json.loads(args.request.read_text()), GitHub(args.github_cli)
            )
            receipts.write_receipt(args.output, receipt)
            with open(os.environ["GITHUB_ENV"], "a") as output:
                output.write(
                    f"CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_PATH={args.output.resolve()}\n"
                )
                output.write(
                    f"CONTEXT_PANEL_CLOUDKIT_PUBLICATION_REQUEST_PATH={args.request.resolve()}\n"
                )
        elif args.command == "accept":
            receipt = receipts.load_receipt_base64(
                os.environ.get("INPUT_RECEIPT_BASE64", "")
            )
            request_digest = receipt.get("publicationRequestDigest", "")
            if not isinstance(request_digest, str) or not re.fullmatch(
                r"[0-9a-f]{64}", request_digest
            ):
                raise RelayError("result lacks publication binding")
            # The mailbox is untrusted transport. Only the waiting publication
            # has its exact schema/request and authenticates the seal.
            receipts.write_receipt(args.output, receipt)
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f"artifact={RESULT_PREFIX}{request_digest}\n")
        else:
            return serve_requests(GitHub(args.github_cli), args.served_state)
    except (
        RelayError,
        receipts.ReceiptError,
        OSError,
        ValueError,
        KeyError,
        subprocess.SubprocessError,
        zipfile.BadZipFile,
    ):
        # Artifact contents and subprocess diagnostics must never reach public logs.
        print(
            "CloudKit publication relay failed; publication remains blocked",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
