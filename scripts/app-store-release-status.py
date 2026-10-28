#!/usr/bin/env python3
"""Track Ship uploads, watch public App Store delivery, and close records once live.

Never submits a build or changes App Store Connect."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from html.parser import HTMLParser
from pathlib import Path
from types import ModuleType
from typing import Any
from urllib.parse import urlencode
from urllib.request import urlopen


def load_script(name: str, filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load release helper {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


version_guard = load_script("release_status_version_guard", "app-store-version-guard.py")
publication = load_script("release_status_publication", "publish-github-release.py")
# Apple's iPad public page binds its intent explicitly; the phone route omits it.
# Both represent the IOS App Store version, including the embedded Watch app.
PLATFORMS = {"MAC_OS": "mac", "IOS": "ipad", "VISION_OS": "vision", "TV_OS": "tv"}
COMPANION_PLATFORMS = ("IOS", "VISION_OS", "TV_OS")
RECORD = "context-panel-store-release:v1"
OBSERVATION = "context-panel-store-observation:v1"
CHANNELS = "context-panel-store-channels:v1"
SUBMISSION = "context-panel-store-submission:v1"
UNRECORDED = "context-panel-store-unrecorded-submission:v1"
IDENTITY = ("platform", "version", "buildNumber")
DEFINITION = "docs/release.md#definition-of-released"
PLAN_LABEL = "plan"
PLAN_DONE = "plan:done"


class StatusError(RuntimeError):
    pass


def timestamp(value: str) -> datetime:
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise StatusError("release timestamp must have a timezone")
    return result


def marker(kind: str, value: dict) -> str:
    return f"<!-- {kind} {json.dumps(value, sort_keys=True)} -->"


def read_marker(kind: str, body: str) -> dict | None:
    matches = re.findall(r"<!-- " + re.escape(kind) + r" (.*?) -->", body, re.DOTALL)
    if not matches:
        return None
    if len(matches) != 1:
        raise StatusError("ambiguous release status marker")
    value = json.loads(matches[0])
    if not isinstance(value, dict):
        raise StatusError("invalid release status marker")
    return value


def next_command(repository: str, record: dict) -> str:
    return shlex.join([
        "gh", "workflow", "run", "submit-app-store-review.yml", "--repo", repository,
        "--ref", "main", "-f", f"platform={record['platform']}",
        "-f", f"version={record['version']}", "-f", f"build_number={record['buildNumber']}",
        "-f", "dry_run=true",
    ])


def ship_records(env: dict[str, str], now: datetime) -> list[dict]:
    if env.get("VALIDATE_RESULT") != "success":
        return []
    # Ship uploads every platform with one shared build number. The companion
    # matrix reports one result, so companions are recorded once all succeeded.
    selected = []
    if env.get("INPUT_APP_STORE_CHANNEL") == "upload" and env.get("APP_STORE_UPLOAD_RESULT") == "success":
        selected.append("MAC_OS")
    if env.get("INPUT_COMPANION_APP_STORE_CHANNEL") == "upload" and env.get("COMPANION_APP_STORE_UPLOAD_RESULT") == "success":
        selected.extend(COMPANION_PLATFORMS)
    build = env.get("BUILD_NUMBER", "")
    testflight = (
        env.get("TESTFLIGHT_BETA_RESULT", "unknown")
        if env.get("INPUT_TESTFLIGHT_BETA") == "true"
        else "not selected"
    )
    records = []
    for platform in selected:
        version = env["INPUT_VERSION"]
        version_guard.version_components(version)
        if platform not in PLATFORMS or not version_guard.VERSION_PATTERN.fullmatch(build):
            raise StatusError("successful upload is missing its platform/build identity")
        source = env["GITHUB_SHA"]
        if not publication.COMMIT_PATTERN.fullmatch(source):
            raise StatusError("successful upload is missing its source commit")
        records.append({
            "platform": platform, "version": version, "buildNumber": build,
            "sourceCommit": source, "uploadedAt": now.isoformat(),
            "github": env.get("GITHUB_RELEASE_RESULT", "unknown"),
            "testflight": testflight,
            "appStore": "App Store submission pending",
            "runURL": f"https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}",
        })
    return records


def record_body(repository: str, record: dict) -> str:
    return (
        f"App Store submission pending — {record['platform']} {record['version']} ({record['buildNumber']}).\n\n"
        f"[Channel results]({record['runURL']}): GitHub {record['github']}; "
        f"App Store Connect upload {record.get('upload', 'success')}; TestFlight {record['testflight']}. "
        "Public App Store delivery has not been verified.\n\n"
        f"Source: `{record['sourceCommit']}`.\n\n"
        f"[Release definition](https://github.com/{repository}/blob/main/{DEFINITION}). "
        "Next action: the release agent validates TestFlight and runs this Submit dry run, "
        "then follows the existing review/evidence gates. This record does not authorize submission.\n\n"
        f"```sh\n{next_command(repository, record)}\n```\n\n"
        "The App Store Release Status check closes this record when its exact build is verified live, "
        "or as superseded when a newer public version is live on this platform.\n\n"
        + marker(RECORD, record) + "\n"
    )


class GitHub:
    """Workflow-token transport. Mutations: issue creation, comments, sub-issue links and issue closing."""

    def __init__(self, repository: str) -> None:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise StatusError("invalid GitHub repository")
        self.repository = repository

    def api(self, path: str, body: dict | None = None, method: str = "POST") -> Any:
        args = ["gh", "api", f"repos/{self.repository}/{path}"]
        if body is not None:
            args += ["--method", method, "--input", "-"]
        result = subprocess.run(args, input=json.dumps(body) if body is not None else None,
                                text=True, capture_output=True, timeout=60)
        if result.returncode:
            raise StatusError("GitHub release-status request failed; check workflow token permissions")
        return json.loads(result.stdout)

    def pages(self, path: str) -> list[dict]:
        result = []
        for page in range(1, 101):
            batch = self.api(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
            if not isinstance(batch, list):
                raise StatusError("invalid GitHub page")
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise StatusError("release-status inventory truncated")

    def issues(self) -> list[dict]:
        return [item for item in self.pages("issues?state=all") if "pull_request" not in item]


def ensure_record(client: Any, issues: list[dict], record: dict) -> dict:
    for issue in issues:
        previous = read_marker(RECORD, issue.get("body") or "")
        if previous and all(previous.get(k) == record[k] for k in ("platform", "version", "buildNumber", "sourceCommit")):
            outcomes = {key: record[key] for key in ("github", "testflight")}
            outcomes["upload"] = record.get("upload", "success")
            current = {key: previous[key] for key in ("github", "testflight")}
            current["upload"] = previous.get("upload", "success")
            updates = [read_marker(CHANNELS, comment.get("body") or "")
                       for comment in client.pages(f"issues/{issue['number']}/comments")]
            updates = [update for update in updates if update is not None]
            if updates:
                current = updates[-1]
            if outcomes != current:
                client.api(f"issues/{issue['number']}/comments", {"body":
                    f"[Ship retry channel results]({record['runURL']}): GitHub {record['github']}; "
                    f"upload {outcomes['upload']}; TestFlight {record['testflight']}. "
                    "Public App Store delivery remains unverified.\n\n"
                    + marker(CHANNELS, outcomes)})
            return issue
    issue = client.api("issues", {
        "title": f"App Store submission pending: {record['platform']} {record['version']} ({record['buildNumber']})",
        "body": record_body(client.repository, record),
    })
    issues.append(issue)
    return issue


def release_issue(issues: list[dict], value: str) -> dict | None:
    """The open release issue Ship links its records to; blank means none."""
    if not value.strip():
        return None
    if not value.strip().isdigit():
        raise StatusError("release_issue must be an issue number")
    matches = [issue for issue in issues if issue.get("number") == int(value) and issue.get("state") == "open"]
    if len(matches) != 1:
        raise StatusError("release_issue is not an open issue in this repository")
    return matches[0]


def parent_number(client: Any, issue: dict) -> int | None:
    url = issue.get("parent_issue_url")
    if not isinstance(url, str):
        return None
    match = re.fullmatch(rf"https://api\.github\.com/repos/{re.escape(client.repository)}/issues/(\d+)", url)
    return int(match.group(1)) if match else None


def link_to_release(client: Any, issue: dict, parent: dict) -> None:
    current = parent_number(client, issue)
    if current == parent["number"]:
        return
    if issue.get("parent_issue_url"):
        raise StatusError("release record already belongs to another release issue")
    client.api(f"issues/{parent['number']}/sub_issues", {"sub_issue_id": issue["id"]})
    issue["parent_issue_url"] = f"https://api.github.com/repos/{client.repository}/issues/{parent['number']}"


def include_published_mac(client: Any, issues: list[dict]) -> None:
    """Cover releases predating Ship records, and GitHub-only Mac publications."""
    release = client.api("releases/latest")
    if release.get("draft") or release.get("prerelease"):
        raise StatusError("latest GitHub release is not a public release")
    identity = publication.parse_identity_marker(release.get("body") or "")
    version_guard.version_components(identity["version"])
    if not publication.COMMIT_PATTERN.fullmatch(identity["sourceCommit"]):
        raise StatusError("published Mac release has no exact source identity")
    # A platform upload record has better channel evidence than the legacy baseline.
    if any((record := read_marker(RECORD, issue.get("body") or ""))
           and record.get("platform") == "MAC_OS"
           and version_guard.compare_versions(record["version"], identity["version"]) >= 0
           for issue in issues):
        return
    ensure_record(client, issues, {
        "platform": "MAC_OS", "version": identity["version"],
        "buildNumber": identity["buildNumber"], "sourceCommit": identity["sourceCommit"],
        "uploadedAt": release["published_at"], "github": "published",
        "upload": "unknown (GitHub publication baseline)", "testflight": "unknown",
        "appStore": "App Store submission pending", "runURL": release["html_url"],
    })


class StorePageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.collecting = False
        self.chunks = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "script" and dict(attrs).get("id") == "serialized-server-data":
            self.collecting = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "script":
            self.collecting = False

    def handle_data(self, data: str) -> None:
        if self.collecting:
            self.chunks.append(data)


def public_page_version(html: str, platform: str, app_id: str) -> str:
    parser = StorePageParser()
    parser.feed(html)
    try:
        payload = json.loads("".join(parser.chunks))
        pages = [page for page in payload["data"] if page["intent"].get("platform") == PLATFORMS[platform]
                 and str(page["intent"].get("id")) == app_id]
        family = "pad" if platform == "IOS" else PLATFORMS[platform]
        if len(pages) != 1 or family not in pages[0]["data"]["appPlatforms"]:
            raise StatusError("public page did not confirm the requested platform")
        shelf = pages[0]["data"]["shelfMapping"]["mostRecentVersion"]
        histories = shelf["seeAllAction"]["pageData"]["shelves"]
        versions = [item["primarySubtitle"] for history in histories for item in history["items"]]
        # The history uses plain numeric versions; the overview subtitle is localized.
        latest = version_guard.latest_known_version([
            version_guard.KnownVersion(version, "public App Store") for version in versions
        ])
        if latest is None:
            raise StatusError("public version history is empty")
        return latest.version
    except (KeyError, TypeError, ValueError, version_guard.AppStoreConnectError) as error:
        raise StatusError("public App Store version evidence is unavailable or changed") from error


def fetch_text(url: str) -> str:
    with urlopen(url, timeout=30) as response:
        return response.read().decode("utf-8")


def public_app_id() -> str:
    lookup = json.loads(fetch_text("https://itunes.apple.com/lookup?" + urlencode({
        "bundleId": version_guard.DEFAULT_BUNDLE_ID, "entity": "macSoftware", "country": "us",
    })))
    matches = [item for item in lookup["results"] if item.get("bundleId") == version_guard.DEFAULT_BUNDLE_ID]
    if len(matches) != 1 or not isinstance(matches[0].get("trackId"), int):
        raise StatusError("public App Store lookup did not identify Context Panel")
    return str(matches[0]["trackId"])


def evaluate(record: dict, public_version: str | None, now: datetime, lag_hours: int,
             since: str | None = None) -> dict:
    age = now - timestamp(since or record["uploadedAt"])
    if age < timedelta():
        raise StatusError("release timestamp is in the future")
    if public_version is None:
        return {"status": "unknown", "publicVersion": None, "alert": True}
    comparison = version_guard.compare_versions(public_version, record["version"])
    if comparison >= 0:
        return {"status": "public version current", "publicVersion": public_version, "alert": False}
    overdue = age >= timedelta(hours=lag_hours)
    return {"status": "App Store drift" if overdue else "App Store pending within grace period",
            "publicVersion": public_version, "alert": overdue}


def latest_records(issues: list[dict]) -> dict[str, tuple[dict, dict]]:
    latest = {}
    for issue in issues:
        record = read_marker(RECORD, issue.get("body") or "")
        if record is None:
            continue
        if record.get("platform") not in PLATFORMS:
            raise StatusError("release record has an unsupported platform")
        version_guard.version_components(record["version"])
        timestamp(record["uploadedAt"])
        previous = latest.get(record["platform"])
        if previous is None:
            latest[record["platform"]] = (issue, record)
            continue
        comparison = version_guard.compare_versions(record["version"], previous[1]["version"])
        if comparison > 0 or (comparison == 0 and timestamp(record["uploadedAt"]) > timestamp(previous[1]["uploadedAt"])):
            latest[record["platform"]] = (issue, record)
    return latest


def submission(client: Any, issue: dict, record: dict) -> dict | None:
    """The submission marker that the Submit workflow wrote for this exact build."""
    found = [read_marker(SUBMISSION, comment.get("body") or "")
             for comment in client.pages(f"issues/{issue['number']}/comments")]
    matching = [item for item in found
                if item is not None and all(item.get(key) == record[key] for key in IDENTITY)]
    if matching:
        timestamp(matching[-1]["submittedAt"])
    return matching[-1] if matching else None


def target_records(client: Any, issues: list[dict]) -> dict[str, tuple[dict, dict, dict | None]]:
    """Per platform, the newest build submitted for review; before any submission, the newest upload.

    A record closed as not planned was superseded as the candidate and is never a target.
    """
    candidates = [issue for issue in issues if issue.get("state_reason") != "not_planned"]
    targets = {platform: (issue, record, None) for platform, (issue, record) in latest_records(candidates).items()}
    submitted = []
    submissions = {}
    for issue in candidates:
        record = read_marker(RECORD, issue.get("body") or "")
        if record is not None and (submitted_build := submission(client, issue, record)) is not None:
            submitted.append(issue)
            submissions[issue["number"]] = submitted_build
    for platform, (issue, record) in latest_records(submitted).items():
        targets[platform] = (issue, record, submissions[issue["number"]])
    return targets


def record_submission(client: Any, issues: list[dict], env: dict[str, str], now: datetime) -> dict | None:
    """Mark the Ship record of a build that was just submitted for App Store review.

    A build uploaded outside Ship has no record; the submission already succeeded, so
    that is reported rather than failed. The check cannot watch that build and keeps
    its previous target for the platform. Records of the same platform and version are
    marked, so a live version is never taken as proof that their build is the live one.
    """
    identity = {"platform": env.get("INPUT_PLATFORM", ""), "version": env.get("INPUT_VERSION", ""),
                "buildNumber": env.get("INPUT_BUILD_NUMBER", "")}
    if identity["platform"] not in PLATFORMS or not version_guard.VERSION_PATTERN.fullmatch(identity["buildNumber"]):
        raise StatusError("submission is missing its platform/build identity")
    version_guard.version_components(identity["version"])
    for issue in issues:
        record = read_marker(RECORD, issue.get("body") or "")
        if record is None or any(record.get(key) != identity[key] for key in IDENTITY):
            continue
        if submission(client, issue, record) is None:
            run_url = f"https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}"
            value = {**identity, "submittedAt": now.isoformat(), "runURL": run_url}
            client.api(f"issues/{issue['number']}/comments", {"body":
                f"[Submitted for App Store review]({run_url}): {identity['platform']} {identity['version']} "
                f"({identity['buildNumber']}). The App Store Release Status check now watches this build for this platform. "
                "Keep this record open until the exact build is verified live.\n\n"
                + marker(SUBMISSION, value)})
        return issue
    run_url = f"https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}"
    for issue in issues:
        record = read_marker(RECORD, issue.get("body") or "")
        if (record is not None and record.get("platform") == identity["platform"]
                and version_guard.compare_versions(record["version"], identity["version"]) == 0):
            client.api(f"issues/{issue['number']}/comments", {"body":
                f"[Build {identity['buildNumber']}]({run_url}) was submitted for {identity['platform']} "
                f"{identity['version']} without a Ship record, so this record's build can no longer be proven "
                "live from the public version. The release agent verifies and closes it.\n\n"
                + marker(UNRECORDED, {**identity, "submittedAt": now.isoformat(), "runURL": run_url})})
    return None


def only_submitted_build(client: Any, issues: list[dict], target: dict) -> bool:
    """True when the target is the one record submitted for its platform and version.

    A version can have only one build live, so a live version with one submitted build
    identifies that build. Any second submission for the version leaves it for a person.
    """
    submitted = []
    for issue in issues:
        record = read_marker(RECORD, issue.get("body") or "")
        if (record is None or record.get("platform") != target["platform"]
                or version_guard.compare_versions(record["version"], target["version"]) != 0):
            continue
        comments = client.pages(f"issues/{issue['number']}/comments")
        if any(read_marker(UNRECORDED, comment.get("body") or "") is not None for comment in comments):
            return False
        if submission(client, issue, record) is not None:
            submitted.append(record)
    return len(submitted) == 1 and all(submitted[0].get(key) == target[key] for key in IDENTITY)


def close_issue(client: Any, issue: dict, body: str, update: dict) -> None:
    comments = client.pages(f"issues/{issue['number']}/comments")
    if not any(comment.get("body") == body for comment in comments):
        client.api(f"issues/{issue['number']}/comments", {"body": body})
    client.api(f"issues/{issue['number']}", update, method="PATCH")
    issue.update(update)


def close_live_record(client: Any, issue: dict, record: dict, public_version: str) -> None:
    body = (f"Live on the App Store: {record['platform']} {record['version']} ({record['buildNumber']}).\n\n"
        f"The public US App Store page shows {public_version}. Build {record['buildNumber']} is the only build "
        f"submitted for {record['version']} on this platform, and a version can have only one build live, "
        "so the live version is this build. Closed by the App Store Release Status check.\n\n"
        f"[Release definition](https://github.com/{client.repository}/blob/main/{DEFINITION}).")
    close_issue(client, issue, body, {"state": "closed", "state_reason": "completed"})


def close_superseded_record(client: Any, issue: dict, record: dict, public_version: str) -> None:
    body = (f"Superseded: {record['platform']} {record['version']} ({record['buildNumber']}).\n\n"
        f"The public US App Store page shows newer version {public_version} on {record['platform']}. "
        "This closes the pending record without claiming its build went live. "
        "Closed by the App Store Release Status check.")
    close_issue(client, issue, body, {"state": "closed", "state_reason": "not_planned"})


def reconcile_records(client: Any, issues: list[dict], versions: dict[str, str | None]) -> dict[int, str]:
    resolved = {}
    for issue in issues:
        record = read_marker(RECORD, issue.get("body") or "")
        if record is None or (public_version := versions.get(record["platform"])) is None:
            continue
        comparison = version_guard.compare_versions(public_version, record["version"])
        if comparison > 0:
            if issue.get("state") == "open":
                close_superseded_record(client, issue, record, public_version)
            resolved[issue["number"]] = f"superseded by {public_version}"
        elif (comparison == 0 and issue.get("state_reason") != "not_planned"
              and only_submitted_build(client, issues, record)):
            if issue.get("state") == "open":
                close_live_record(client, issue, record, public_version)
            if issue.get("state_reason") == "completed":
                resolved[issue["number"]] = "live"
    return resolved


def close_finished_release(client: Any, parent: dict, resolved: dict[int, str]) -> bool:
    children = client.pages(f"issues/{parent['number']}/sub_issues")
    if not children or any(child.get("state") != "closed" for child in children):
        return False
    records = [(child, record) for child in sorted(children, key=lambda item: item["number"])
               if (record := read_marker(RECORD, child.get("body") or "")) is not None]
    if (any(child["number"] not in resolved for child, _ in records)
            or {record["platform"] for _, record in records} != set(PLATFORMS)):
        return False
    lines = [f"- {record['platform']}: {record['version']} ({record['buildNumber']}), "
             f"#{child['number']}: {resolved[child['number']]}" for child, record in records]
    body = ("Release records reconciled: every platform record is live or superseded.\n\n"
        + "\n".join(lines) + "\n\n"
        "Closed by the App Store Release Status check once every platform record closed.")
    names = [label["name"] if isinstance(label, dict) else label for label in parent.get("labels", [])]
    update: dict[str, Any] = {"state": "closed", "state_reason": "completed"}
    if PLAN_LABEL in names:
        update["labels"] = [name for name in names if not name.startswith(f"{PLAN_LABEL}:")] + [PLAN_DONE]
    close_issue(client, parent, body, update)
    return True


def monitor(client: Any, issues: list[dict], now: datetime, lag_hours: int,
            lookup: Callable[[], str] = public_app_id,
            fetch: Callable[[str], str] = fetch_text) -> list[dict]:
    latest = target_records(client, issues)
    records = latest_records(issues)
    if not records:
        raise StatusError("no Ship release records; public delivery is unknown")
    try:
        app_id = lookup()
    except (OSError, ValueError, KeyError, StatusError):
        app_id = None
    observations = []
    versions = {}
    for platform in sorted(records):
        try:
            if app_id is None:
                raise StatusError("public App Store lookup unavailable")
            url = f"https://apps.apple.com/us/app/id{app_id}?platform={PLATFORMS[platform]}"
            versions[platform] = public_page_version(fetch(url), platform, app_id)
        except (OSError, ValueError, StatusError):
            versions[platform] = None
    for platform, (issue, record, submitted) in sorted(latest.items()):
        version = versions[platform]
        result = evaluate(record, version, now, lag_hours, since=submitted and submitted["submittedAt"])
        observation = {"platform": platform, "version": record["version"], "buildNumber": record["buildNumber"], **result}
        previous = [read_marker(OBSERVATION, comment.get("body") or "")
                    for comment in client.pages(f"issues/{issue['number']}/comments")]
        previous = [item for item in previous if item is not None]
        if not previous or previous[-1] != observation:
            prefix = "Alert" if result["alert"] else "Observation"
            body = (f"{prefix}: {platform} — {result['status']}.\n\n"
                    f"{'Submitted' if submitted else 'Uploaded'} target: {record['version']} ({record['buildNumber']}); "
                    f"public App Store (US): {version or 'unknown'}. "
                    "Upload/TestFlight success is separate from live App Store delivery. "
                    "Public marketing-version equality alone cannot prove the exact build, approval, or TestFlight state.\n\n"
                    f"Next release-agent preflight:\n```sh\n{next_command(client.repository, record)}\n```\n\n"
                    "Supervisor watchers: this release-tracking issue remains the durable handoff; "
                    "no submission or store mutation was performed.\n\n" + marker(OBSERVATION, observation))
            client.api(f"issues/{issue['number']}/comments", {"body": body})
        observations.append(observation)
    resolved = reconcile_records(client, issues, versions)
    by_number = {item["number"]: item for item in issues}
    parents = set()
    for issue in issues:
        if read_marker(RECORD, issue.get("body") or "") is not None:
            number = parent_number(client, issue)
            if number is not None:
                parents.add(number)
    for parent in sorted(parents):
        if parent in by_number and by_number[parent].get("state") == "open":
            close_finished_release(client, by_number[parent], resolved)
    if not latest:
        raise StatusError("no active Ship release targets; public delivery is unknown")
    return observations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("record-ship", "record-submission", "check"))
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--lag-hours", type=int, default=48)
    args = parser.parse_args()
    try:
        if args.lag_hours <= 0:
            raise StatusError("lag hours must be positive")
        client = GitHub(args.repo or "")
        issues = client.issues()
        now = datetime.now(UTC)
        if args.mode == "record-submission":
            issue = record_submission(client, issues, dict(os.environ), now)
            if issue is None:
                print("::warning::No Ship release record matches the submitted build, so the App Store "
                      "Release Status check cannot watch it and keeps its previous target for this platform")
            else:
                print(f"App Store submission recorded: {issue['html_url']}")
        elif args.mode == "record-ship":
            records = ship_records(dict(os.environ), now)
            parent = release_issue(issues, os.environ.get("RELEASE_ISSUE", "")) if records else None
            for record in records:
                issue = ensure_record(client, issues, record)
                if parent is not None:
                    link_to_release(client, issue, parent)
                print(f"App Store submission pending: {issue['html_url']}")
                summary = os.environ.get("GITHUB_STEP_SUMMARY")
                if summary:
                    with open(summary, "a") as output:
                        output.write(f"\n### App Store submission pending: {record['platform']}\n\n"
                                     f"[Durable release handoff]({issue['html_url']})\n\n"
                                     f"```sh\n{next_command(client.repository, record)}\n```\n")
        else:
            include_published_mac(client, issues)
            results = monitor(client, issues, now, args.lag_hours)
            print(json.dumps(results, indent=2))
            if any(result["alert"] for result in results):
                print("::warning::Public App Store drift or unavailable evidence; see release-tracking issues")
                return 1
        return 0
    except (StatusError, OSError, ValueError, KeyError, subprocess.SubprocessError,
            version_guard.AppStoreConnectError) as error:
        print(f"error: release status unknown: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
