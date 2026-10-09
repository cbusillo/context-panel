#!/usr/bin/env python3
"""Read environment protection metadata; never read environment secrets."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
from urllib.parse import quote


def fetch_metadata(endpoint: str, *, pages: bool = False) -> dict | list:
    # gh uses the built-in workflow token supplied as GH_TOKEN by Actions.
    command = [os.environ.get("CONTEXT_PANEL_ENVIRONMENT_GH", "gh"),
               "api", "--method", "GET", endpoint]
    if pages:
        command += ["--paginate", "--slurp"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise ValueError("environment metadata is unavailable; refusing release")
    return json.loads(result.stdout)


def check_fields(environment: dict) -> None:
    if not isinstance(environment.get("can_admins_bypass"), bool) or not isinstance(
        environment.get("protection_rules"), list
    ):
        raise ValueError("environment protection metadata is incomplete")
    for rule in environment["protection_rules"]:
        if rule.get("type") == "required_reviewers":
            reviewers = rule.get("reviewers")
            if not isinstance(reviewers, list) or not reviewers or any(
                not (reviewer.get("reviewer") or {}).get("login") for reviewer in reviewers
            ):
                raise ValueError("reviewer metadata is incomplete")


def check(environment: dict) -> None:
    check_fields(environment)
    for rule in environment["protection_rules"]:
        if rule.get("type") == "branch_policy":
            continue
        if rule.get("type") == "wait_timer" and rule.get("wait_timer") == 0:
            continue
        raise ValueError(f"{environment.get('name')}: remove release approval or delay protection by hand")


def check_branches(environment: dict, branches: list[dict]) -> None:
    policy = environment.get("deployment_branch_policy") or {}
    if policy.get("protected_branches") is True and policy.get("custom_branch_policies") is False:
        allowed = [{"name": branch.get("name"), "type": "branch"} for branch in branches]
    elif policy.get("custom_branch_policies") is True and policy.get("protected_branches") is False:
        allowed = [{"name": branch.get("name"), "type": branch.get("type")} for branch in branches]
    else:
        raise ValueError("release secrets need a restricted branch policy")
    if allowed != [{"name": "main", "type": "branch"}]:
        raise ValueError("release secrets must allow only Branch main")


def read_environment(repository: str, name: str) -> dict:
    value = fetch_metadata(f"repos/{repository}/environments/{quote(name, safe='')}")
    if not isinstance(value, dict) or value.get("name") != name:
        raise ValueError("invalid environment metadata")
    check_fields(value)
    return value


def check_secret_store(repository: str) -> None:
    environment = read_environment(repository, "release")
    check(environment)
    if (environment.get("deployment_branch_policy") or {}).get("protected_branches"):
        pages = fetch_metadata(f"repos/{repository}/branches?protected=true&per_page=100", pages=True)
        branches = [branch for page in pages for branch in page]
    else:
        pages = fetch_metadata(f"repos/{repository}/environments/release/deployment-branch-policies?per_page=100",
                               pages=True)
        branches = [branch for page in pages for branch in page.get("branch_policies", [])]
    check_branches(environment, branches)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", action="store_true", help="CI probe of secret-store protection metadata")
    args = parser.parse_args()
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if repository.count("/") != 1:
        parser.exit(1, "GITHUB_REPOSITORY is required\n")
    try:
        check_secret_store(repository)
        if not args.probe:
            check(read_environment(repository, "release-approval"))
        print("secret-store protection metadata verified" if args.probe else "no-click release metadata verified")
    except (ValueError, TypeError, KeyError, AttributeError, OSError) as error:
        parser.exit(1, f"release environment metadata: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
