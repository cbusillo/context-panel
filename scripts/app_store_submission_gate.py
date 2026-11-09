"""Decide whether a TestFlight build may go to App Review.

A build is ready when two things hold:

- its source commit, from the Ship release record, has a passing
  `shared-view-simulator-references` CI job; and
- it has been on TestFlight for a day, and the TestFlight crash watcher filed no
  crash submission for that exact platform and build during that day.

An explicit override skips the day's wait and the crash check, never the
reference job. Records come from GitHub issues the existing tools already
write: Ship's release record (scripts/app-store-release-status.py) and the
crash watcher's per-build issues (shiny-infra-ops TestFlight feedback).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
from types import ModuleType
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

JOB_NAME = "shared-view-simulator-references"
WORKFLOW_PATH = ".github/workflows/ci.yml"
EXACT_COMMIT_EVENTS = frozenset({"push", "workflow_dispatch"})
DEFAULT_REPOSITORY = "cbusillo/context-panel"
SOAK = timedelta(hours=24)
# Wording the crash watcher writes for each submission it files.
CRASH_SUBMISSION = re.compile(r"TestFlight crash submission, (?P<platform>[A-Z_]+), build (?P<build>\S+?)\.\s")
SUBMITTED_AT = re.compile(r"Submitted: (?P<at>\S+?)\.\s")
MAX_PAGES = 50

FetchJSON = Callable[[str], Any]


class SubmissionGateError(Exception):
    pass


def _load_release_status() -> ModuleType:
    name = "submission_gate_release_status"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name("app-store-release-status.py"))
    if spec is None or spec.loader is None:
        raise SubmissionGateError("cannot load scripts/app-store-release-status.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


release_status = _load_release_status()


@dataclass(frozen=True)
class Readiness:
    """What the gate found; `blockers` empty means the build may be submitted."""

    reference_runs: tuple[tuple[str, str], ...]
    blockers: tuple[str, ...]
    waived: tuple[str, ...]
    notes: tuple[str, ...]


def _pages(path: str, fetch_json: FetchJSON) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    separator = "&" if "?" in path else "?"
    for page in range(1, MAX_PAGES + 1):
        batch = fetch_json(f"{path}{separator}per_page=100&page={page}")
        if not isinstance(batch, list):
            raise SubmissionGateError(f"GitHub returned an unexpected page for {path}")
        items.extend(item for item in batch if isinstance(item, dict))
        if len(batch) < 100:
            return items
    raise SubmissionGateError(f"GitHub listing for {path} is longer than {MAX_PAGES} pages")


def ship_records(issues: list[dict[str, Any]], platform: str, version: str, build: str) -> list[dict[str, Any]]:
    """Ship's release records for this exact platform, version and build."""
    identity = {"platform": platform, "version": version, "buildNumber": build}
    records = []
    for issue in issues:
        record = release_status.read_marker(release_status.RECORD, issue.get("body") or "")
        if record is not None and all(record.get(key) == value for key, value in identity.items()):
            records.append(record)
    return records


def passing_run_url(commit: str, repository: str, fetch_json: FetchJSON) -> str | None:
    """The URL of a passing simulator reference job on `commit`, or `None`.

    Only runs that check out the commit itself count: a push or a manual dispatch.
    A pull request run tests a merge with its base, not the commit.
    """
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
        # Every attempt: "re-run failed jobs" leaves a passed reference job in an earlier one.
        jobs = fetch_json(f"repos/{repository}/actions/runs/{run['id']}/jobs?filter=all&per_page=100").get("jobs", [])
        for job in jobs:
            if job.get("name") == JOB_NAME and job.get("conclusion") == "success":
                return job.get("html_url") or run.get("html_url") or ""
    return None


def how_to_get_one(commit: str) -> str:
    branch = f"reference-check/{commit[:12]}"
    return (
        f"run CI on that commit: push a branch at it and dispatch CI there "
        f"(git push origin {commit}:refs/heads/{branch} && "
        f"gh workflow run ci.yml --ref {branch}); the run's {JOB_NAME} job must pass"
    )


def crash_times(
    issues: list[dict[str, Any]],
    platform: str,
    build: str,
    repository: str,
    fetch_json: FetchJSON,
) -> list[datetime | None]:
    """When each crash submission the watcher filed for this build arrived; `None` if unreadable."""
    title = f"TestFlight feedback: {platform} build {build}"
    found: list[datetime | None] = []
    for issue in issues:
        if issue.get("title") != title:
            continue
        texts = [issue.get("body") or ""]
        texts += [comment.get("body") or "" for comment in
                  _pages(f"repos/{repository}/issues/{issue['number']}/comments", fetch_json)]
        for text in texts:
            match = CRASH_SUBMISSION.search(text)
            if match is None or match["platform"] != platform or match["build"] != build:
                continue
            submitted = SUBMITTED_AT.search(text)
            try:
                found.append(release_status.timestamp(submitted["at"]) if submitted else None)
            except (ValueError, release_status.StatusError):
                found.append(None)
    return found


def check(
    platform: str,
    version: str,
    build: str,
    *,
    now: datetime,
    repository: str,
    fetch_json: FetchJSON,
    override_reason: str = "",
) -> Readiness:
    issues = [item for item in _pages(f"repos/{repository}/issues?state=all", fetch_json)
              if "pull_request" not in item]
    records = ship_records(issues, platform, version, build)
    if not records:
        raise SubmissionGateError(
            f"no Ship release record for {platform} {version} ({build}); the gate needs the record's "
            "source commit and upload time, which Ship writes when it uploads a build"
        )
    commits = sorted({str(record.get("sourceCommit")) for record in records})
    uploads: list[datetime] = [release_status.timestamp(record["uploadedAt"]) for record in records]
    uploaded = min(uploads)

    blockers: list[str] = []
    runs: list[tuple[str, str]] = []
    for commit in commits:
        url = passing_run_url(commit, repository, fetch_json)
        if url is None:
            blockers.append(f"no passing {JOB_NAME} job on source {commit}: {how_to_get_one(commit)}")
        else:
            runs.append((commit, url))

    soak_blockers: list[str] = []
    soak_ends = uploaded + SOAK
    if now < soak_ends:
        soak_blockers.append(
            f"the build has been on TestFlight since {uploaded.isoformat()}; its first day ends at "
            f"{soak_ends.isoformat()}"
        )
    crashes = crash_times(issues, platform, build, repository, fetch_json)
    first_day = [at for at in crashes if at is None or at < soak_ends]
    if first_day:
        soak_blockers.append(
            f"the TestFlight crash watcher filed {len(first_day)} crash submission(s) for "
            f"{platform} build {build} in its first day"
        )
    notes = [] if crashes == first_day else [
        f"{len(crashes) - len(first_day)} crash submission(s) for this build arrived after its first day"
    ]
    if override_reason.strip():
        return Readiness(tuple(runs), tuple(blockers), tuple(soak_blockers), tuple(notes))
    return Readiness(tuple(runs), tuple(blockers + soak_blockers), (), tuple(notes))


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
        raise SubmissionGateError(f"cannot read {path} from GitHub: {error}") from error


def repository_from_environment() -> str:
    return os.environ.get("GITHUB_REPOSITORY") or DEFAULT_REPOSITORY
