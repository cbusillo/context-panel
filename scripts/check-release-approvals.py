#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["PyYAML>=6,<7"]
# ///
"""Lint the no-click release graph and print a secretless all-channel plan.

This checks the classified local graph, not live settings or remote callees.
"""
from __future__ import annotations

import argparse
from collections.abc import Iterator
import json
import os
from pathlib import Path
import re
import shlex
import sys

SHIP_CALLER = "github.workflow_ref == format('{0}/.github/workflows/ship.yml@refs/heads/main', github.repository)"
STANDALONE_INTENT = "${{ !(" + SHIP_CALLER + ") }}"
CHANNEL_READY = (
    "${{ !cancelled() && needs.guard.result == 'success' && "
    "(needs.intent.result == 'success' || (" + SHIP_CALLER +
    " && needs.intent.result == 'skipped')) }}"
)
CHANNELS = {
    "github-release": "release.yml",
    "app-store-upload": "app-store-connect-upload.yml",
    "companion-app-store-upload": "app-store-connect-companion-upload.yml",
    "testflight-beta": "testflight-beta-distribution.yml",
}
STANDALONE_ONLY = ("submit-app-store-review.yml", "upload-app-store-screenshots.yml")
RELEASE_ENVIRONMENTS = ("release", "release-approval", "release-channels")


def may_select_release_environment(name: str) -> bool:
    """Overapproximate simple interpolations without evaluating Actions code.

    Each context lookup can be any string, including empty. Complex expressions
    are opaque; use a literal unrelated name or a fixed, disjoint namespace
    around simple lookups instead. No variables or live settings are read.
    """
    lookup = re.compile(r"\$\{\{\s*(?:github|inputs|vars|needs|strategy|matrix)"
                        r"(?:\.[A-Za-z_][A-Za-z0-9_-]*)+\s*}}")
    parts = []
    offset = 0
    for match in lookup.finditer(name):
        literal = name[offset:match.start()]
        if "${{" in literal:
            return True
        parts.extend((re.escape(literal), ".*"))
        offset = match.end()
    tail = name[offset:]
    if "${{" in tail:
        return True
    parts.append(re.escape(tail))
    pattern = "".join(parts)
    return any(re.fullmatch(pattern, reserved, re.IGNORECASE | re.DOTALL)
               for reserved in RELEASE_ENVIRONMENTS)


def needs(job: dict) -> list[str]:
    value = job.get("needs", [])
    return [value] if isinstance(value, str) else value


def environment(job: dict) -> str | None:
    value = job.get("environment")
    return value.get("name") if isinstance(value, dict) else value


def strings(value: object) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def secret_bearing(job: dict) -> bool:
    return any(re.search(r"\bsecrets\b", body)
               for value in strings(job)
               for body in re.findall(r"\$\{\{(.*?)}}", value, re.DOTALL))


def secret_names(value: object) -> set[str]:
    pattern = r"\bsecrets(?:\.([A-Za-z_][A-Za-z0-9_]*)|\[['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\])"
    return {dot or bracket for text in strings(value)
            for dot, bracket in re.findall(pattern, text)}


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
        guard_steps = [step for step in steps if "release-workflow-guard.sh" in step.get("run", "")]
        require(len(guard_steps) == 1, f"{workflow_name}: expected one executable trust guard")
        step = guard_steps[0]
        require(not step.get("if") and not step.get("continue-on-error"),
                f"{workflow_name}: trust guard step cannot be skipped or tolerate failure")
        command = shlex.split(step["run"].replace("\\\n", ""))
        expected = ["scripts/release-workflow-guard.sh", "--version", "${INPUT_VERSION}"]
        require(command in (expected, expected + ["--build-number", "${INPUT_BUILD_NUMBER}"]),
                f"{workflow_name}: trust guard must be invoked directly with release inputs")
        require(not guard.get("if") and not guard.get("continue-on-error"),
                f"{workflow_name}: trust guard must run and succeed")
        setup_steps = [step for step in steps if step.get("run") == "scripts/release-approval-config.sh"]
        require(len(setup_steps) == 1 and not setup_steps[0].get("if")
                and not setup_steps[0].get("continue-on-error")
                and setup_steps[0].get("env", {}).get("RELEASE_APPROVALS_CONFIGURED")
                == "${{ vars.RELEASE_APPROVALS_CONFIGURED }}",
                f"{workflow_name}: owner-confirmed setup is required before environment jobs")
        metadata_steps = [step for step in steps if step.get("run")
                          == "python3 scripts/check-release-approval-environment.py"]
        require(len(metadata_steps) == 1 and not metadata_steps[0].get("if")
                and not metadata_steps[0].get("continue-on-error")
                and metadata_steps[0].get("env", {}).get("GH_TOKEN") == "${{ github.token }}"
                and guard.get("permissions", {}).get("actions") == "read",
                f"{workflow_name}: live no-click environment metadata must be checked")

    def intent_check(jobs: dict, workflow_name: str, reusable: bool = False) -> None:
        record = jobs.get("intent", {})
        require(environment(record) == "release-approval" and not secret_bearing(record),
                f"{workflow_name}: intent gate must be secretless in release-approval")
        require(needs(record) == ["guard"] and not record.get("continue-on-error"),
                f"{workflow_name}: intent gate must follow successful trust guard")
        require(record.get("if", "") == (STANDALONE_INTENT if reusable else ""),
                f"{workflow_name}: only the exact Ship caller may skip standalone intent recording")

    for filename in ("ship.yml", *CHANNELS.values(), *STANDALONE_ONLY):
        document = workflows[filename]
        require(not secret_bearing({"env": document.get("env"), "defaults": document.get("defaults")}),
                f"{filename}: workflow-level secrets would reach the secretless gates")
    ship = workflows["ship.yml"]["jobs"]
    guard_check(ship, "ship.yml")
    intent_check(ship, "ship.yml")
    intent = ship["validate"]
    require(environment(intent) == "release",
            "Ship preflight must use the sole release secret environment")
    require(not intent.get("if") and not intent.get("continue-on-error"),
            "Ship preflight cannot be optional or tolerate failure")
    require(needs(intent) == ["intent"], "Ship preflight must follow recorded intent")
    for job_id, job in ship.items():
        require(job_id in ("intent", "validate") or environment(job) is None,
                f"Ship/{job_id}: only intent and preflight may attach environments")
        require(not secret_bearing(job) or job_id == "validate",
                f"Ship/{job_id}: only guarded preflight may reference secrets")
        if "uses" in job:
            require(job_id in CHANNELS, f"unclassified Ship channel: {job_id}")
            require(job.get("secrets") == "inherit",
                    f"Ship/{job_id}: channel must inherit repository secrets")
    for channel, filename in CHANNELS.items():
        call = ship[channel]
        require(call.get("uses") == f"./.github/workflows/{filename}",
                f"{channel}: channel must use the same-commit local workflow")
        require("validate" in needs(call), f"{channel}: missing intent dependency")
        require(not call.get("continue-on-error"), f"{channel}: cannot tolerate failure")
        require(call.get("permissions", {}).get("actions") == "read"
                and call.get("permissions", {}).get("contents") in ("read", "write"),
                f"{channel}: caller must grant metadata read and checkout permissions")
        condition = re.sub(r"\s+", " ", call.get("if", "")).strip()
        if re.search(r"\b(always|failure|cancelled)\s*\(", condition):
            # The TestFlight join intentionally runs with skipped upload channels.
            # Its top-level conjunction must still require recorded intent success.
            require(condition.startswith(
                "${{ !cancelled() && inputs.testflight_beta && needs.validate.result == 'success' &&"
            ) and channel == "testflight-beta" and not top_level_or(condition)
                and condition.endswith("}}")
                and condition.count("${{") == condition.count("}}") == 1,
                    f"{channel}: status condition must require successful intent")
        else:
            require(not condition or re.fullmatch(
                r"\$\{\{ inputs\.[a-z_]+(?: != 'skip')? }}", condition) is not None,
                    f"{channel}: unsupported channel condition")
        document = workflows[filename]
        require("workflow_dispatch" in document["on"] and "workflow_call" in document["on"],
                f"{filename}: recovery dispatch and reusable call must remain supported")
        guard_check(document["jobs"], filename)
        intent_check(document["jobs"], filename, reusable=True)
        count = 0
        for job_id, job in document["jobs"].items():
            if job_id not in ("guard", "intent"):
                count += 1
                require(environment(job) == "release",
                        f"{filename}/{job_id}: channel must use the sole release secret environment")
                require(needs(job) == ["guard", "intent"]
                        and re.sub(r"\s+", " ", job.get("if", "")).strip() == CHANNEL_READY
                        and not job.get("continue-on-error"),
                        f"{filename}/{job_id}: must require guard and standalone or Ship intent")
            require(not secret_bearing(job) or environment(job) == "release",
                    f"{filename}/{job_id}: secrets require the single guarded environment")
            require("uses" not in job, f"{filename}: nested channels require release policy review")
        require(count == 1, f"{filename}: expected one guarded channel job")
    for filename in STANDALONE_ONLY:
        standalone_jobs = workflows[filename]["jobs"]
        guard_check(standalone_jobs, filename)
        intent_check(standalone_jobs, filename)
        require(len(standalone_jobs) == 3, f"{filename}: classify additional jobs before adding them")
        for job_id, job in standalone_jobs.items():
            if job_id not in ("guard", "intent"):
                require(environment(job) == "release",
                        f"{filename}/{job_id}: standalone secrets require the sole release secret environment")
                require(needs(job) == ["guard", "intent"] and not job.get("if")
                        and not job.get("continue-on-error"),
                        f"{filename}/{job_id}: standalone secrets require successful intent recording")
    all_names = set().union(*(secret_names(workflows[filename]) for filename in
                             ("ship.yml", *CHANNELS.values(), *STANDALONE_ONLY)))
    classified = {"ship.yml", *CHANNELS.values(), *STANDALONE_ONLY}
    unclassified_calls = []
    for filename, document in workflows.items():
        if filename not in classified:
            for job_id, job in document.get("jobs", {}).items():
                if "uses" in job:
                    unclassified_calls.append({
                        "workflow": filename, "job": job_id, "uses": job["uses"],
                    })
                name = environment(job)
                require(name is None or (isinstance(name, str)
                        and not may_select_release_environment(name.strip())),
                        f"{filename}/{job_id}: cannot rule out a release environment; "
                        "classify release workflows, or use a literal unrelated name or "
                        "a disjoint namespace such as preview-${{ inputs.target }}")
    intent_jobs = [job_id for job_id, job in ship.items()
                     if environment(job) == "release-approval"]
    return {
        "proof": "classified release graph structural dry-run; live no-click environment configuration requires metadata verification",
        "secret_inventory_scope": "names referenced by jobs using each environment, not actual storage locations",
        "reusable_workflow_coverage": {
            "complete": not unclassified_calls,
            "unclassified_calls": unclassified_calls,
            "limitation": "Unclassified reusable calls are accepted but their intent dependencies "
                          "are not checked. Remote jobs and nested calls are not fetched or executed.",
        },
        "secret_names_by_environment": {"release": sorted(all_names), "release-approval": sorted(set().union(*(
            secret_names(workflows[filename]["jobs"]["intent"])
            for filename in ("ship.yml", *CHANNELS.values(), *STANDALONE_ONLY))))},
        "activation": "RELEASE_APPROVALS_CONFIGURED=true; owner removes environment reviewer before no-click runs",
        "fallback": "Unset/false activation refuses new release workflows before any environment job",
        "ship": {"intent_jobs": intent_jobs, "approval_count": 0,
                 "secret_environment": "release", "channels": list(CHANNELS),
                 "repository_secrets": "inherited by same-commit local channels"},
        "standalone": {
            filename: {"intent_jobs": [job_id for job_id, job in workflows[filename]["jobs"].items()
                                        if environment(job) == "release-approval"],
                       "approval_count": 0,
                       "secret_environment": "release"}
            for filename in (*CHANNELS.values(), *STANDALONE_ONLY)
        },
    }


def main() -> int:
    import yaml

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflows-root", type=Path,
                        default=Path(__file__).resolve().parents[1] / ".github/workflows")
    args = parser.parse_args()
    try:
        documents = {path.name: yaml.safe_load(path.read_text())
                     for path in sorted([*args.workflows_root.glob("*.yml"),
                                         *args.workflows_root.glob("*.yaml")])}
        report = check(documents)
        print(json.dumps(report, indent=2))
        if not report["reusable_workflow_coverage"]["complete"]:
            prefix = "::warning::" if os.environ.get("GITHUB_ACTIONS") == "true" else ""
            print(prefix + "release approval coverage incomplete: inspect unclassified reusable calls "
                  "in reusable_workflow_coverage; see docs/release.md", file=sys.stderr)
    except (ValueError, KeyError, TypeError, OSError, yaml.YAMLError) as error:
        parser.exit(1, f"release approval policy: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
