#!/usr/bin/env python3
"""Check Production CloudKit only when the committed schema contract changed.

The contract is the checked-in CloudKit schema under CloudKit/. The last
verified release is the newest vMAJOR.MINOR.PATCH tag reachable from the
checked-out commit: publishing that release required this gate. CloudKit
Production accepts only additive schema deployments, so a contract verified
once stays deployed. When the contract changed since that tag, or no tag is
reachable, the live validator must pass against Production. Every other
outcome refuses.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATHS = ("CloudKit",)
VALIDATOR = Path("scripts/validate-cloudkit-companion-schema.sh")
RELEASE_TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)")


class GateError(Exception):
    pass


@dataclass(frozen=True)
class Decision:
    live_check: bool
    reason: str


def git(repo: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *arguments],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError("git is unavailable") from error


def latest_release_tag(repo: Path) -> str | None:
    listed = git(repo, "tag", "--merged", "HEAD", "--list", "v*")
    if listed.returncode != 0:
        raise GateError("release history is unavailable")
    versions = []
    for tag in listed.stdout.split():
        match = RELEASE_TAG.fullmatch(tag)
        if match:
            versions.append((tuple(int(part) for part in match.groups()), tag))
    return max(versions)[1] if versions else None


def decide(repo: Path) -> Decision:
    tag = latest_release_tag(repo)
    if tag is None:
        return Decision(True, "no release tag is reachable from this commit")
    compared = git(repo, "diff", "--quiet", tag, "HEAD", "--", *CONTRACT_PATHS)
    if compared.returncode == 0:
        return Decision(False, f"the schema contract is unchanged since {tag}")
    if compared.returncode == 1:
        return Decision(True, f"the schema contract changed since {tag}")
    raise GateError(f"cannot compare the schema contract with {tag}")


def check(repo: Path) -> int:
    decision = decide(repo)
    if not decision.live_check:
        print(f"CloudKit schema gate: {decision.reason}; no live check needed")
        return 0
    print(f"CloudKit schema gate: {decision.reason}; checking Production")
    try:
        completed = subprocess.run(
            ["/bin/bash", str(repo / VALIDATOR), "--live", "--environment", "production"],
            cwd=repo,
            check=False,
        )
    except OSError as error:
        raise GateError("the live schema validator could not start") from error
    if completed.returncode != 0:
        raise GateError(
            "Production does not match the changed contract, or the check could not run. "
            "Deploy the schema in CloudKit Console, or make the management token available, "
            "then retry; see 'CloudKit Production Schema Gate' in docs/release.md"
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check",))
    parser.add_argument("--repo", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    arguments = parser.parse_args(argv)
    try:
        return check(arguments.repo)
    except GateError as error:
        print(f"CloudKit schema gate refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
