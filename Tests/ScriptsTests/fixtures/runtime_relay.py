"""Private-process fixtures for the real runtime relay and receipt verifier."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[3]
SOURCE_COMMIT = hashlib.sha256(b"runtime relay source fixture").hexdigest()[:40]
SCHEMA_RECEIPT_KEY = "runtime-receipt-test-key-32-bytes-minimum"


class RuntimeRelayFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.receipt_path = root / "schema-receipt.json"
        self.marker_path = root / "agent-ran"
        self.agent_path = root / "refresh-agent"
        self.environment = os.environ.copy()
        self.environment["CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"] = SCHEMA_RECEIPT_KEY
        tools = root / "tools"
        tools.mkdir()
        git = tools / "git"
        git.write_text(
            "#!/bin/sh\n"
            f'[ "$1" = "-C" ] && [ "$2" = {shlex.quote(str(REPO_ROOT))} ] '
            '&& [ "$3" = "rev-parse" ] && [ "$4" = "HEAD" ] || exit 8\n'
            f"printf '%s\\n' {shlex.quote(SOURCE_COMMIT)}\n"
        )
        git.chmod(0o755)
        self.environment["PATH"] = str(tools) + os.pathsep + self.environment.get("PATH", "")

    def issue_receipt(self, *, source_commit: str = SOURCE_COMMIT) -> subprocess.CompletedProcess[str]:
        return self.run(
            REPO_ROOT / "scripts/cloudkit-schema-receipt.py",
            "issue", "--source-commit", source_commit, "--output", str(self.receipt_path),
            "--schema", str(REPO_ROOT / "CloudKit/companion-sync.schema.json"),
            "--cktool-schema", str(REPO_ROOT / "CloudKit/companion-sync.schema.ckdb"),
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
            REPO_ROOT / "scripts/context-panel-runtime-session.py",
            "sync", "--agent", str(self.agent_path),
            "--cloudkit-schema-receipt", str(self.receipt_path),
        )
