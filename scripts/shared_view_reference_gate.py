"""Require a green simulator reference image run for the source being submitted.

CI skips the `shared-view-simulator-references` job when a change cannot affect
it, so a commit on main may never have run it. App Store submission therefore
asks GitHub for a passing run of that job on each exact source commit the
expected-build manifests name. Only runs that check out that commit count: a
push, a manual dispatch, or the nightly schedule. A pull request run tests a
merge with its base, not the commit itself.
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Iterable
from typing import Any

JOB_NAME = "shared-view-simulator-references"
WORKFLOW_PATH = ".github/workflows/ci.yml"
EXACT_COMMIT_EVENTS = frozenset({"push", "workflow_dispatch", "schedule"})
DEFAULT_REPOSITORY = "cbusillo/context-panel"
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")

FetchJSON = Callable[[str], Any]


class ReferenceRunError(Exception):
    pass


def source_commits(expected_build_manifests: Iterable[dict[str, Any]]) -> list[str]:
    commits: set[str] = set()
    for manifest in expected_build_manifests:
        artifacts = manifest.get("artifacts") if isinstance(manifest, dict) else None
        if not isinstance(artifacts, list) or not artifacts:
            raise ReferenceRunError("an expected-build manifest lists no artifacts")
        for artifact in artifacts:
            commit = artifact.get("sourceCommit") if isinstance(artifact, dict) else None
            if not isinstance(commit, str) or not COMMIT_PATTERN.fullmatch(commit):
                raise ReferenceRunError("an expected-build artifact has no full sourceCommit")
            commits.add(commit)
    if not commits:
        raise ReferenceRunError("no expected-build manifest names a source commit")
    return sorted(commits)


def passing_run_url(commit: str, repository: str, fetch_json: FetchJSON) -> str | None:
    """The URL of a passing simulator reference job on `commit`, or `None`."""
    runs_url = (
        f"repos/{repository}/actions/workflows/{WORKFLOW_PATH.rsplit('/', 1)[1]}/runs?"
        + urllib.parse.urlencode({"head_sha": commit, "status": "completed", "per_page": 100})
    )
    for run in fetch_json(runs_url).get("workflow_runs", []):
        if (
            run.get("head_sha") != commit
            or run.get("event") not in EXACT_COMMIT_EVENTS
            or run.get("path") != WORKFLOW_PATH
            or (run.get("head_repository") or {}).get("full_name") != repository
        ):
            continue
        jobs = fetch_json(f"repos/{repository}/actions/runs/{run['id']}/jobs?per_page=100").get("jobs", [])
        for job in jobs:
            if job.get("name") == JOB_NAME and job.get("conclusion") == "success":
                return job.get("html_url") or run.get("html_url") or ""
    return None


def how_to_get_one(commit: str) -> str:
    branch = f"reference-check/{commit[:12]}"
    return (
        f"run CI on that commit: push a branch at it and dispatch CI there "
        f"(git push origin {commit}:refs/heads/{branch} && "
        f"gh workflow run ci.yml --ref {branch}); the run's "
        f"{JOB_NAME} job must pass"
    )


def require_reference_runs(
    expected_build_manifests: Iterable[dict[str, Any]],
    *,
    repository: str,
    fetch_json: FetchJSON,
) -> list[tuple[str, str]]:
    """Return (commit, run URL) for each source commit, or raise naming what is missing."""
    found: list[tuple[str, str]] = []
    missing: list[str] = []
    for commit in source_commits(expected_build_manifests):
        url = passing_run_url(commit, repository, fetch_json)
        if url is None:
            missing.append(commit)
        else:
            found.append((commit, url))
    if missing:
        details = "\n".join(f"- {commit}: {how_to_get_one(commit)}" for commit in missing)
        raise ReferenceRunError(
            f"no passing {JOB_NAME} run on the submitted source commit "
            f"(push, dispatch or nightly CI in {repository}):\n{details}"
        )
    return found


def github_fetch_json(path: str) -> Any:
    """GET a GitHub REST path, with GH_TOKEN or GITHUB_TOKEN when set."""
    request = urllib.request.Request(
        f"https://api.github.com/{path}",
        headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"},
    )
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as error:
        raise ReferenceRunError(f"cannot read CI runs from GitHub: {error}") from error


def repository_from_environment() -> str:
    return os.environ.get("GITHUB_REPOSITORY") or DEFAULT_REPOSITORY
