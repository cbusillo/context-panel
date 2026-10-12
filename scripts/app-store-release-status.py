#!/usr/bin/env python3
"""Track Ship uploads and observe public App Store drift; never submit a build."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from urllib.parse import urlencode
from urllib.request import urlopen


def load_script(name: str, filename: str):
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
RECORD = "context-panel-store-release:v1"
OBSERVATION = "context-panel-store-observation:v1"
CHANNELS = "context-panel-store-channels:v1"
DEFINITION = "docs/release.md#definition-of-released"


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
    selected = []
    if env.get("INPUT_APP_STORE_CHANNEL") == "upload" and env.get("APP_STORE_UPLOAD_RESULT") == "success":
        selected.append(("MAC_OS", env.get("MAC_BUILD_NUMBER", "")))
    if env.get("INPUT_COMPANION_APP_STORE_CHANNEL") == "upload" and env.get("COMPANION_APP_STORE_UPLOAD_RESULT") == "success":
        selected.append((env.get("COMPANION_PLATFORM", ""), env.get("COMPANION_BUILD_NUMBER", "")))
    records = []
    for platform, build in selected:
        version = env["INPUT_VERSION"]
        version_guard.version_components(version)
        if platform not in PLATFORMS or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", build):
            raise StatusError("successful upload is missing its platform/build identity")
        source = env["GITHUB_SHA"]
        if not publication.COMMIT_PATTERN.fullmatch(source):
            raise StatusError("successful upload is missing its source commit")
        beta_platform = "MAC_OS" if env.get("INPUT_TESTFLIGHT_BETA_SOURCE") == "macos" else env.get("COMPANION_PLATFORM")
        records.append({
            "platform": platform, "version": version, "buildNumber": build,
            "sourceCommit": source, "uploadedAt": now.isoformat(),
            "github": env.get("GITHUB_RELEASE_RESULT", "unknown"),
            "testflight": env.get("TESTFLIGHT_BETA_RESULT", "unknown") if beta_platform == platform else "not selected",
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
        "Keep this issue open until the exact build is approved and live; "
        "public version equality alone cannot identify its build number.\n\n"
        + marker(RECORD, record) + "\n"
    )


class GitHub:
    """Workflow-token transport. Only issue creation and comments are mutations."""

    def __init__(self, repository: str):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise StatusError("invalid GitHub repository")
        self.repository = repository

    def api(self, path: str, body: dict | None = None):
        args = ["gh", "api", f"repos/{self.repository}/{path}"]
        if body is not None:
            args += ["--method", "POST", "--input", "-"]
        result = subprocess.run(args, input=json.dumps(body) if body is not None else None,
                                text=True, capture_output=True, timeout=60, check=False)
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


def ensure_record(client, issues: list[dict], record: dict) -> dict:
    for issue in issues:
        previous = read_marker(RECORD, issue.get("body") or "")
        if previous and all(previous.get(k) == record[k] for k in ("platform", "version", "buildNumber", "sourceCommit")):
            outcomes = {key: record[key] for key in ("github", "testflight")}
            current = {key: previous[key] for key in outcomes}
            updates = [read_marker(CHANNELS, comment.get("body") or "")
                       for comment in client.pages(f"issues/{issue['number']}/comments")]
            updates = [update for update in updates if update is not None]
            if updates:
                current = updates[-1]
            if outcomes != current:
                client.api(f"issues/{issue['number']}/comments", {"body":
                    f"[Ship retry channel results]({record['runURL']}): GitHub {record['github']}; "
                    f"TestFlight {record['testflight']}. Public App Store delivery remains unverified.\n\n"
                    + marker(CHANNELS, outcomes)})
            return issue
    issue = client.api("issues", {
        "title": f"App Store submission pending: {record['platform']} {record['version']} ({record['buildNumber']})",
        "body": record_body(client.repository, record),
    })
    issues.append(issue)
    return issue


def include_published_mac(client, issues: list[dict]) -> None:
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
    def __init__(self):
        super().__init__()
        self.collecting = False
        self.chunks = []

    def handle_starttag(self, tag, attrs):
        if tag == "script" and dict(attrs).get("id") == "serialized-server-data":
            self.collecting = True

    def handle_endtag(self, tag):
        if tag == "script":
            self.collecting = False

    def handle_data(self, data):
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


def evaluate(record: dict, public_version: str | None, now: datetime, lag_hours: int) -> dict:
    age = now - timestamp(record["uploadedAt"])
    if age < timedelta(0):
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


def monitor(client, issues: list[dict], now: datetime, lag_hours: int, lookup=public_app_id, fetch=fetch_text) -> list[dict]:
    latest = latest_records(issues)
    if not latest:
        raise StatusError("no Ship release records; public delivery is unknown")
    try:
        app_id = lookup()
    except (OSError, ValueError, KeyError, StatusError):
        app_id = None
    observations = []
    for platform, (issue, record) in sorted(latest.items()):
        try:
            if app_id is None:
                raise StatusError("public App Store lookup unavailable")
            url = f"https://apps.apple.com/us/app/id{app_id}?platform={PLATFORMS[platform]}"
            version = public_page_version(fetch(url), platform, app_id)
        except (OSError, ValueError, StatusError):
            version = None
        result = evaluate(record, version, now, lag_hours)
        observation = {"platform": platform, "version": record["version"], "buildNumber": record["buildNumber"], **result}
        previous = [read_marker(OBSERVATION, comment.get("body") or "")
                    for comment in client.pages(f"issues/{issue['number']}/comments")]
        previous = [item for item in previous if item is not None]
        if not previous or previous[-1] != observation:
            prefix = "Alert" if result["alert"] else "Observation"
            body = (f"{prefix}: {platform} — {result['status']}.\n\n"
                    f"Uploaded target: {record['version']} ({record['buildNumber']}); "
                    f"public App Store (US): {version or 'unknown'}. "
                    "Upload/TestFlight success is separate from live App Store delivery. "
                    "Public marketing-version equality cannot prove the exact build, approval, or TestFlight state.\n\n"
                    f"Next release-agent preflight:\n```sh\n{next_command(client.repository, record)}\n```\n\n"
                    "Supervisor watchers: this release-tracking issue remains the durable handoff; "
                    "no submission or store mutation was performed.\n\n" + marker(OBSERVATION, observation))
            client.api(f"issues/{issue['number']}/comments", {"body": body})
        observations.append(observation)
    return observations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("record-ship", "check"))
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--lag-hours", type=int, default=48)
    args = parser.parse_args()
    try:
        if args.lag_hours <= 0:
            raise StatusError("lag hours must be positive")
        client = GitHub(args.repo or "")
        issues = client.issues()
        now = datetime.now(timezone.utc)
        if args.mode == "record-ship":
            records = ship_records(dict(os.environ), now)
            for record in records:
                issue = ensure_record(client, issues, record)
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
