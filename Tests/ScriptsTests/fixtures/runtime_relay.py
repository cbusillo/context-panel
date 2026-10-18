"""Isolated source checkout for the real runtime relay and CloudKit schema gate."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[3]
CONTRACT_SCHEMA = "CloudKit/companion-sync.schema.json"


class RuntimeRelayFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.checkout = root / "checkout"
        self.marker_path = root / "agent-ran"
        self.agent_path = root / "refresh-agent"
        self.tools = root / "tools"
        self.tools.mkdir()
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_") and key != "CLOUDKIT_MANAGEMENT_TOKEN"
        }
        self.environment["GIT_CONFIG_NOSYSTEM"] = "1"
        self.environment["GIT_CONFIG_GLOBAL"] = os.devnull
        # Never reach the real cktool or its saved token.
        self.environment["PATH"] = f"{self.tools}:{self.environment['PATH']}"
        self.write_cktool(exports_contract=False)
        for relative in (
            "scripts/context-panel-runtime-session.py", "scripts/cloudkit-schema-gate.py",
            "scripts/validate-cloudkit-companion-schema.sh",
            CONTRACT_SCHEMA, "CloudKit/companion-sync.schema.ckdb",
        ):
            destination = self.checkout / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO_ROOT / relative, destination)
        self.git("init", "--quiet")
        self.commit("released contract")
        self.git("tag", "v1.0.0")

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments], cwd=self.checkout, env=self.environment,
            text=True, capture_output=True, check=True,
        )

    def commit(self, message: str) -> None:
        self.git("add", "--all")
        self.git(
            "-c", "user.name=Runtime relay fixture", "-c", "user.email=fixture@context-panel.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "--quiet", "--message", message,
        )

    def change_contract(self) -> None:
        contract = self.checkout / CONTRACT_SCHEMA
        contract.write_text(contract.read_text() + "\n")
        self.commit("change contract")

    def write_cktool(self, *, exports_contract: bool) -> None:
        """A fake xcrun whose export matches the contract, or fails."""
        body = (
            'while [ "$#" -gt 0 ]; do [ "$1" = "--output-file" ] && output="$2"; shift; done\n'
            f'cp {shlex.quote(str(REPO_ROOT / "CloudKit/companion-sync.schema.ckdb"))} "$output"\n'
            if exports_contract else "exit 42\n"
        )
        xcrun = self.tools / "xcrun"
        xcrun.write_text("#!/bin/sh\n" + body)
        xcrun.chmod(0o755)

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
            'if [ -n "${CLOUDKIT_MANAGEMENT_TOKEN:-}" ]; then exit 9; fi\n'
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
        )
