"""Isolated source checkout for the real runtime relay and receipt verifier."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_RECEIPT_KEY = "runtime-receipt-test-key-32-bytes-minimum"


class RuntimeRelayFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.checkout = root / "checkout"
        self.receipt_path = root / "schema-receipt.json"
        self.marker_path = root / "agent-ran"
        self.agent_path = root / "refresh-agent"
        self.tools = root / "tools"
        self.tools.mkdir()
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.environment["CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"] = SCHEMA_RECEIPT_KEY
        self.environment["GIT_CONFIG_NOSYSTEM"] = "1"
        self.environment["GIT_CONFIG_GLOBAL"] = os.devnull
        for relative in (
            "scripts/context-panel-runtime-session.py", "scripts/cloudkit-schema-receipt.py",
            "CloudKit/companion-sync.schema.json", "CloudKit/companion-sync.schema.ckdb",
        ):
            destination = self.checkout / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO_ROOT / relative, destination)
        self.git("init", "--quiet")
        self.git("add", "--all")
        self.git(
            "-c", "user.name=Runtime relay fixture", "-c", "user.email=fixture@context-panel.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "--quiet", "--message", "fixture",
        )
        self.source_commit = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments], cwd=self.checkout, env=self.environment,
            text=True, capture_output=True, check=True,
        )

    def issue_receipt(self, *, source_commit: str | None = None) -> subprocess.CompletedProcess[str]:
        return self.run(
            self.checkout / "scripts/cloudkit-schema-receipt.py",
            "issue", "--source-commit", source_commit or self.source_commit,
            "--output", str(self.receipt_path),
            "--schema", str(self.checkout / "CloudKit/companion-sync.schema.json"),
            "--cktool-schema", str(self.checkout / "CloudKit/companion-sync.schema.ckdb"),
        )

    def write_agent(self, *, payload: object = None, raw_output: str | None = None, exit_code: int = 0) -> None:
        self.marker_path.unlink(missing_ok=True)
        if payload is None:
            payload = {
                "healthy": True, "sessionAction": "unchanged", "messages": [],
                "uploadedReceiptCount": 0, "downloadedReceiptCount": 0,
                "deletedRemoteReceiptCount": 0,
            }
        output = json.dumps(payload) if raw_output is None else raw_output
        self.agent_path.write_text(
            "#!/bin/sh\n"
            '[ "$1" = "--sync-runtime-receipts" ] || exit 7\n'
            'if [ -n "${CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY:-}" ]; then exit 9; fi\n'
            f"touch {shlex.quote(str(self.marker_path))}\n"
            f"printf '%s\\n' {shlex.quote(output)}\n"
            f"exit {exit_code}\n"
        )
        self.agent_path.chmod(0o755)

    def run(self, script: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(script), *arguments], cwd=self.root, env=self.environment,
            text=True, capture_output=True, check=False,
        )

    def sync(self) -> subprocess.CompletedProcess[str]:
        return self.run(
            self.checkout / "scripts/context-panel-runtime-session.py",
            "sync", "--agent", str(self.agent_path),
            "--cloudkit-schema-receipt", str(self.receipt_path),
        )
