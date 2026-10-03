#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["PyYAML>=6,<7"]
# ///
"""Lint the release approval graph and print a secretless all-channel plan.

This checks workflow configuration, not live GitHub environment settings.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

CHANNEL_ENVIRONMENT = (
    "${{ github.workflow_ref == format('{0}/.github/workflows/ship.yml@refs/heads/main', "
    "github.repository) && vars.RELEASE_CHANNELS_CONFIGURED == 'true' && 'release-channels' || 'release' }}"
)
CHANNELS = {
    "github-release": "release.yml",
    "app-store-upload": "app-store-connect-upload.yml",
    "companion-app-store-upload": "app-store-connect-companion-upload.yml",
    "testflight-beta": "testflight-beta-distribution.yml",
}
STANDALONE_ONLY = ("submit-app-store-review.yml", "upload-app-store-screenshots.yml")


def needs(job: dict) -> list[str]:
    value = job.get("needs", [])
    return [value] if isinstance(value, str) else value


def environment(job: dict) -> str | None:
    value = job.get("environment")
    return value.get("name") if isinstance(value, dict) else value


def secret_bearing(job: dict) -> bool:
    return "secrets." in json.dumps(job)


def top_level_or(condition: str) -> bool:
    # OR inside a parenthesized channel choice does not bypass intent success.
    unquoted = re.sub(r"'(?:[^']|'')*'", "''", condition)
    depth = 0
    for index, char in enumerate(unquoted):
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif depth == 0 and unquoted[index:index + 2] == "||":
            return True
    return False


def check(workflows: dict[str, dict]) -> dict:
    """Validate parsed documents. Fixtures can exercise failures without Git state."""
    def require(ok: bool, message: str) -> None:
        if not ok:
            raise ValueError(message)

    def guard_check(jobs: dict, workflow_name: str) -> None:
        guard = jobs["guard"]
        require(environment(guard) is None and not secret_bearing(guard),
                f"{workflow_name}: trust guard must be secretless")
        steps = guard.get("steps", [])
        require(any(step.get("uses", "").startswith("actions/checkout@")
                    and step.get("with", {}).get("fetch-depth") == 0 for step in steps),
                f"{workflow_name}: trust guard needs full history")
        require(any("scripts/release-workflow-guard.sh" in step.get("run", "") for step in steps),
                f"{workflow_name}: missing executable trusted-source guard")
        require(not guard.get("if") and not guard.get("continue-on-error"),
                f"{workflow_name}: trust guard must run and succeed")

    ship = workflows["ship.yml"]["jobs"]
    guard_check(ship, "ship.yml")
    intent = ship["validate"]
    require(environment(intent) == "release", "Ship intent must require release review")
    require(not intent.get("if") and not intent.get("continue-on-error"),
            "Ship intent cannot be optional or tolerate failure")
    require(needs(intent) == ["guard"], "Ship intent must follow trusted-source guard")
    for job_id, job in ship.items():
        require(job_id == "validate" or environment(job) is None,
                f"Ship/{job_id}: only intent may attach an environment")
        require(not secret_bearing(job) or job_id == "validate",
                f"Ship/{job_id}: secrets must stay in intent or guarded channels")
        if "uses" in job:
            require(job_id in CHANNELS, f"unclassified Ship channel: {job_id}")
    for channel, filename in CHANNELS.items():
        call = ship[channel]
        require(call.get("uses") == f"./.github/workflows/{filename}",
                f"{channel}: channel must use the same-commit local workflow")
        require("validate" in needs(call), f"{channel}: missing intent dependency")
        require(not call.get("continue-on-error"), f"{channel}: cannot tolerate failure")
        condition = re.sub(r"\s+", " ", call.get("if", "")).strip()
        if re.search(r"\b(always|failure|cancelled)\s*\(", condition):
            # The TestFlight join intentionally runs with skipped upload channels.
            # Its top-level conjunction must still require approved intent success.
            require(condition.startswith(
                "${{ always() && inputs.testflight_beta && needs.validate.result == 'success' &&"
            ) and channel == "testflight-beta" and not top_level_or(condition),
                    f"{channel}: status condition must require successful intent")
        else:
            require(not condition or re.fullmatch(
                r"\$\{\{ inputs\.[a-z_]+(?: != 'skip')? }}", condition) is not None,
                    f"{channel}: unsupported channel condition")
        document = workflows[filename]
        require("workflow_dispatch" in document["on"] and "workflow_call" in document["on"],
                f"{filename}: recovery dispatch and reusable call must remain supported")
        guard_check(document["jobs"], filename)
        count = 0
        for job_id, job in document["jobs"].items():
            if environment(job) is not None:
                count += 1
                require(environment(job) == CHANNEL_ENVIRONMENT,
                        f"{filename}/{job_id}: caller identity must select channel environment")
                require(needs(job) == ["guard"] and not job.get("if"),
                        f"{filename}/{job_id}: must require successful guard")
            require(not secret_bearing(job) or environment(job) == CHANNEL_ENVIRONMENT,
                    f"{filename}/{job_id}: secrets require guarded environment")
            require("uses" not in job, f"{filename}: nested channels require approval policy review")
        require(count == 1, f"{filename}: expected one guarded channel job")
    for filename in STANDALONE_ONLY:
        guard_check(workflows[filename]["jobs"], filename)
        for job_id, job in workflows[filename]["jobs"].items():
            require(not secret_bearing(job) or environment(job) == "release",
                    f"{filename}/{job_id}: standalone secrets require release review")
    return {
        "proof": "structural dry-run; live environment configuration is owner-confirmed",
        "activation": "Repository variable RELEASE_CHANNELS_CONFIGURED=true after owner setup",
        "fallback": "Unset/false activation keeps every channel on reviewed release",
        "ship": {"reviewed_jobs": ["validate"], "approval_count": 1,
                 "channel_environment": "release-channels", "channels": list(CHANNELS)},
        "standalone": {name: "release" for name in (*CHANNELS.values(), *STANDALONE_ONLY)},
    }


def main() -> int:
    import yaml

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflows-root", type=Path,
                        default=Path(__file__).resolve().parents[1] / ".github/workflows")
    args = parser.parse_args()
    try:
        names = ("ship.yml", *CHANNELS.values(), *STANDALONE_ONLY)
        documents = {name: yaml.safe_load((args.workflows_root / name).read_text()) for name in names}
        print(json.dumps(check(documents), indent=2))
    except (ValueError, KeyError, TypeError, OSError, yaml.YAMLError) as error:
        parser.exit(1, f"release approval policy: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
