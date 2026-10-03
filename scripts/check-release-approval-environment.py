#!/usr/bin/env python3
"""Read environment protection metadata; never read environment secrets."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
from urllib.parse import quote


def fetch_environment(repository: str, name: str) -> dict:
    # gh uses the built-in workflow token supplied as GH_TOKEN by Actions.
    result = subprocess.run(
        ["gh", "api", "--method", "GET", f"repos/{repository}/environments/{quote(name, safe='')}"],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise ValueError("environment metadata is unavailable; refusing release")
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError("invalid environment metadata")
    return value


def check(environment: dict, owner: str) -> None:
    if environment.get("name") != "release-approval":
        raise ValueError("release-approval environment is missing")
    rules = [rule for rule in environment.get("protection_rules", [])
             if rule.get("type") == "required_reviewers"]
    if len(rules) != 1:
        raise ValueError("release-approval must have a required reviewer")
    reviewers = rules[0].get("reviewers", [])
    if len(reviewers) != 1 or reviewers[0].get("type") != "User" or (
        reviewers[0].get("reviewer", {}).get("login", "").casefold() != owner.casefold()
    ):
        raise ValueError("release-approval must require the repository owner's review")
    if environment.get("can_admins_bypass") is not False:
        raise ValueError("release-approval must disable administrator bypass")
    if rules[0].get("prevent_self_review") is not False:
        raise ValueError("release-approval must allow the solo owner to review")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", help="CI read-only capability probe of an existing environment")
    args = parser.parse_args()
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if repository.count("/") != 1:
        parser.exit(1, "GITHUB_REPOSITORY is required\n")
    try:
        value = fetch_environment(repository, args.probe or "release-approval")
        if not args.probe:
            check(value, repository.split("/", 1)[0])
        print("environment metadata read succeeded" if args.probe else "required owner review verified")
    except (ValueError, TypeError, KeyError, OSError) as error:
        parser.exit(1, f"release review metadata: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
