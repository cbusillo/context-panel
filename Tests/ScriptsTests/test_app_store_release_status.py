import importlib.util
import json
import shlex
import sys
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from unittest import mock

PATH = Path(__file__).resolve().parents[2] / "scripts" / "app-store-release-status.py"
SPEC = importlib.util.spec_from_file_location("store_release_status", PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {PATH}")
status = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = status
SPEC.loader.exec_module(status)
NOW = datetime(2030, 1, 10, tzinfo=UTC)


def record(platform: str = "MAC_OS", version: str = "2.0.10", hours: int = 49, build: str = "900") -> dict[str, Any]:
    return {
        "platform": platform, "version": version, "buildNumber": build,
        "sourceCommit": "a" * 40, "uploadedAt": (NOW - timedelta(hours=hours)).isoformat(),
        "github": "success", "testflight": "success", "appStore": "App Store submission pending",
        "runURL": "https://github.com/example/panel/actions/runs/123",
    }


def issue(number: int, value: dict, state: str = "open") -> dict:
    return {"number": number, "body": status.marker(status.RECORD, value), "state": state}


def page(platform: str, versions: list[str], app_id: str = "42") -> str:
    return '<script id="serialized-server-data" type="application/json">' + json.dumps({"data": [{
        "intent": {"platform": status.PLATFORMS[platform], "id": app_id},
        "data": {"appPlatforms": ["pad" if p == "ipad" else p for p in status.PLATFORMS.values()], "shelfMapping": {
            "mostRecentVersion": {"seeAllAction": {"pageData": {"shelves": [
                {"items": [{"primarySubtitle": version} for version in versions]}
            ]}}}
        }},
    }]}) + '</script>'


class FakeGitHub:
    repository = "example/panel"

    def __init__(self) -> None:
        self.writes = []
        self.comments = {}
        self.children = {}
        self.release = None

    def api(self, path: str, body: dict | None = None, method: str = "POST") -> dict:
        if body is None:
            if path == "releases/latest":
                return self.release
            raise AssertionError(path)
        self.writes.append((path, body))
        if path == "issues":
            return {"number": 77, "id": 7700, "html_url": "https://github.com/example/panel/issues/77", **body}
        if path.endswith("/comments"):
            self.comments.setdefault(path, []).append(body)
            return body
        if path.endswith("/sub_issues"):
            return {}
        if method == "PATCH" and path.count("/") == 1:
            return body
        raise AssertionError(path)

    def pages(self, path: str) -> list[dict]:
        if path.endswith("/sub_issues"):
            return self.children.get(path, [])
        return self.comments.get(path, [])


def mark_submitted(client: FakeGitHub, number: int, value: dict, hours: int) -> None:
    mark = {key: value[key] for key in status.IDENTITY}
    mark["submittedAt"] = (NOW - timedelta(hours=hours)).isoformat()
    client.comments.setdefault(f"issues/{number}/comments", []).append(
        {"body": "In review.\n\n" + status.marker(status.SUBMISSION, mark)})


PARENT = 50


def under_release(item: dict) -> dict:
    return {**item, "parent_issue_url": f"https://api.github.com/repos/example/panel/issues/{PARENT}"}


def store(versions: dict[str, str]) -> Any:
    by_page = {value: platform for platform, value in status.PLATFORMS.items()}

    def fetch(url: str) -> str:
        platform = by_page[url.rsplit("platform=", 1)[1]]
        return page(platform, [versions[platform]])
    return fetch


def release_records(client: FakeGitHub) -> list[dict]:
    """One submitted record per platform, each a sub-issue of the release."""
    items = []
    for number, platform in enumerate(sorted(status.PLATFORMS), start=1):
        value = record(platform, hours=10)
        mark_submitted(client, number, value, hours=5)
        items.append(under_release(issue(number, value)))
    return items


def closes(client: FakeGitHub) -> list[str]:
    return [path for path, body in client.writes if body.get("state") == "closed"]


class StoreReleaseStatusTests(unittest.TestCase):
    def test_numeric_versions_not_lexicographic(self) -> None:
        self.assertTrue(status.evaluate(record(), "2.0.9", NOW, 48)["alert"])
        self.assertFalse(status.evaluate(record(version="2.0.9"), "2.0.10", NOW, 48)["alert"])

    def test_trailing_zero_versions_agree_with_version_authority(self) -> None:
        self.assertEqual(status.version_guard.compare_versions("2.1", "2.1.0"), 0)
        self.assertFalse(status.evaluate(record(version="2.1.0"), "2.1", NOW, 48)["alert"])

    def test_grace_boundary_and_unknown(self) -> None:
        self.assertFalse(status.evaluate(record(hours=47), "2.0.9", NOW, 48)["alert"])
        self.assertTrue(status.evaluate(record(hours=48), "2.0.9", NOW, 48)["alert"])
        result = status.evaluate(record(hours=0), None, NOW, 48)
        self.assertTrue(result["alert"])
        self.assertIsNone(result["publicVersion"])

    def test_invalid_versions_and_future_dates_are_not_green(self) -> None:
        for version in ("", "2.beta", "2.-1"):
            with self.subTest(version=version), self.assertRaises(status.version_guard.AppStoreConnectError):
                status.evaluate(record(), version, NOW, 48)
        with self.assertRaises(status.StatusError):
            status.evaluate(record(hours=-1), "2.0.10", NOW, 48)

    def test_latest_record_is_selected_per_platform_including_closed_records(self) -> None:
        mac = record()
        vision = record("VISION_OS", version="1.8")
        items = [issue(1, record(version="2.0.9", hours=100)), issue(2, mac, "closed"),
                 issue(3, vision), issue(4, record("IOS", version="1.9"))]
        latest = status.latest_records(items)
        self.assertEqual(latest[mac["platform"]][1], mac)
        self.assertEqual(latest[vision["platform"]][1], vision)
        self.assertEqual(set(latest), {item["platform"] for item in (mac, vision, record("IOS"))})

    def test_newer_build_of_same_version_wins(self) -> None:
        older, newer = record(hours=80), record(hours=1, build="901")
        self.assertEqual(status.latest_records([issue(2, newer), issue(1, older)])["MAC_OS"][1], newer)

    def test_public_page_is_bound_to_app_and_platform(self) -> None:
        for platform in status.PLATFORMS:
            self.assertEqual(status.public_page_version(page(platform, ["2.0.9", "2.0.10"]), platform, "42"), "2.0.10")
        with self.assertRaises(status.StatusError):
            status.public_page_version(page("IOS", ["2.0.10"]), "TV_OS", "42")
        with self.assertRaises(status.StatusError):
            status.public_page_version(page("MAC_OS", ["2.0.10"]), "MAC_OS", "99")
        with self.assertRaises(status.StatusError):
            status.public_page_version("<html>unavailable</html>", "MAC_OS", "42")

    def test_empty_and_changed_public_history_are_unknown(self) -> None:
        for versions in ([], ["2.0.10", "bad"]):
            with self.subTest(versions=versions), self.assertRaises(status.StatusError):
                status.public_page_version(page("MAC_OS", versions), "MAC_OS", "42")

    def test_successful_upload_is_recorded_when_other_channels_fail(self) -> None:
        env = {
            "VALIDATE_RESULT": "success", "INPUT_VERSION": "2.0.10", "GITHUB_SHA": "a" * 40,
            "GITHUB_REPOSITORY": "example/panel", "GITHUB_RUN_ID": "123", "BUILD_NUMBER": "900",
            "INPUT_APP_STORE_CHANNEL": "upload", "APP_STORE_UPLOAD_RESULT": "success",
            "INPUT_COMPANION_APP_STORE_CHANNEL": "upload", "COMPANION_APP_STORE_UPLOAD_RESULT": "failure",
            "GITHUB_RELEASE_RESULT": "failure", "INPUT_TESTFLIGHT_BETA": "true",
            "TESTFLIGHT_BETA_RESULT": "skipped",
        }
        records = status.ship_records(env, NOW)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["platform"], "MAC_OS")
        self.assertEqual(records[0]["testflight"], env["TESTFLIGHT_BETA_RESULT"])
        env["INPUT_APP_STORE_CHANNEL"] = "export-only"
        self.assertEqual(status.ship_records(env, NOW), [])
        env["VALIDATE_RESULT"] = "failure"
        self.assertEqual(status.ship_records(env, NOW), [])

    def test_one_ship_records_every_platform_at_one_build(self) -> None:
        env = {
            "VALIDATE_RESULT": "success", "INPUT_VERSION": "2.0.10", "GITHUB_SHA": "a" * 40,
            "GITHUB_REPOSITORY": "example/panel", "GITHUB_RUN_ID": "123", "BUILD_NUMBER": "901",
            "INPUT_APP_STORE_CHANNEL": "upload", "APP_STORE_UPLOAD_RESULT": "success",
            "INPUT_COMPANION_APP_STORE_CHANNEL": "upload", "COMPANION_APP_STORE_UPLOAD_RESULT": "success",
            "INPUT_TESTFLIGHT_BETA": "true", "TESTFLIGHT_BETA_RESULT": "success",
        }
        records = status.ship_records(env, NOW)
        self.assertEqual(
            sorted(item["platform"] for item in records), sorted(status.PLATFORMS)
        )
        self.assertEqual({item["buildNumber"] for item in records}, {"901"})
        self.assertEqual({item["testflight"] for item in records}, {"success"})
        env["INPUT_TESTFLIGHT_BETA"] = "false"
        self.assertEqual(
            {item["testflight"] for item in status.ship_records(env, NOW)}, {"not selected"}
        )
        command = shlex.split(status.next_command("example/panel", records[1]))
        for key, value in (("platform", records[1]["platform"]), ("version", records[1]["version"]),
                           ("build_number", records[1]["buildNumber"]), ("dry_run", "true")):
            self.assertIn(f"{key}={value}", command)

    def test_record_retries_reuse_exact_identity(self) -> None:
        client, items, value = FakeGitHub(), [], record()
        first = status.ensure_record(client, items, value)
        again = status.ensure_record(client, items, {**value, "uploadedAt": NOW.isoformat()})
        self.assertEqual(first, again)
        self.assertEqual(len(client.writes), 1)
        self.assertEqual(status.read_marker(status.RECORD, first["body"]), value)

    def test_retry_updates_failed_testflight_result_without_duplicate_issues(self) -> None:
        client, items = FakeGitHub(), []
        first = status.ensure_record(client, items, {**record(), "testflight": "failure"})
        status.ensure_record(client, items, record())
        status.ensure_record(client, items, record())
        self.assertEqual(len(client.writes), 2)
        self.assertEqual(client.writes[-1][0], f"issues/{first['number']}/comments")
        result = status.read_marker(status.CHANNELS, client.writes[-1][1]["body"])
        self.assertEqual(result["testflight"], record()["testflight"])

    def test_record_entrypoint_fails_if_durable_issue_cannot_be_written(self) -> None:
        env = {
            "GITHUB_REPOSITORY": "example/panel", "VALIDATE_RESULT": "success",
            "INPUT_VERSION": "2.0.10", "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123",
            "INPUT_APP_STORE_CHANNEL": "upload", "APP_STORE_UPLOAD_RESULT": "success", "BUILD_NUMBER": "900",
        }
        client = mock.Mock(spec=status.GitHub, repository=env["GITHUB_REPOSITORY"])
        client.issues.return_value = []
        client.api.side_effect = status.StatusError("write failed")
        with mock.patch.dict(status.os.environ, env, clear=True), mock.patch.object(sys, "argv", ["status", "record-ship"]), \
                mock.patch.dict(status.__dict__, {"GitHub": mock.Mock(return_value=client)}), \
                mock.patch("sys.stderr"):
            self.assertNotEqual(status.main(), 0)

    def test_monitor_is_platform_scoped_deduplicated_and_records_recovery(self) -> None:
        client = FakeGitHub()
        items = [issue(1, record()), issue(2, record("VISION_OS", version="1.8"))]

        def fetch(url: str) -> str:
            platform = "MAC_OS" if "platform=mac" in url else "VISION_OS"
            return page(platform, ["2.0.9" if platform == "MAC_OS" else "1.8"])

        results = status.monitor(client, items, NOW, 48, lookup=lambda: "42", fetch=fetch)
        self.assertTrue(results[0]["alert"])
        self.assertFalse(results[1]["alert"])
        self.assertEqual(len(client.writes), 2)
        status.monitor(client, items, NOW + timedelta(hours=1), 48, lookup=lambda: "42", fetch=fetch)
        self.assertEqual(len(client.writes), 2)
        status.monitor(client, items[:1], NOW, 48, lookup=lambda: "42", fetch=lambda _: page("MAC_OS", ["2.0.10"]))
        self.assertEqual(len(client.writes), 3)
        self.assertTrue(all(path.endswith("/comments") for path, _ in client.writes))

    def test_failed_lookup_alerts_instead_of_reporting_live(self) -> None:
        client = FakeGitHub()

        def fail() -> str:
            raise OSError("unavailable")

        results = status.monitor(client, [issue(1, record(hours=0))], NOW, 48, lookup=fail)
        self.assertTrue(results[0]["alert"])
        self.assertIsNone(results[0]["publicVersion"])
        self.assertEqual(len(client.writes), 1)

    def test_legacy_mac_baseline_uses_sealed_release_without_inventing_companion_uploads(self) -> None:
        client = FakeGitHub()
        value = record()
        identity = status.publication.ReleaseIdentity(
            tag=f"v{value['version']}", source_commit=value["sourceCommit"],
            version=value["version"], build_number=value["buildNumber"], assets=(),
        )
        client.release = {"body": status.publication.identity_marker(identity), "published_at": value["uploadedAt"],
                          "html_url": "https://github.com/example/panel/releases/tag/v2.0.10"}
        items = []
        status.include_published_mac(client, items)
        self.assertEqual(set(status.latest_records(items)), {"MAC_OS"})
        stored = status.latest_records(items)["MAC_OS"][1]
        self.assertEqual(stored["version"], identity.version)
        self.assertNotEqual(stored["testflight"], "success")
        status.include_published_mac(client, items)
        self.assertEqual(len(client.writes), 1)

    def test_testflight_upload_after_submission_does_not_alert(self) -> None:
        client = FakeGitHub()
        in_review, testflight_only = record(hours=60), record(version="2.0.11", build="901")
        mark_submitted(client, 1, in_review, hours=2)
        items = [issue(1, in_review), issue(2, testflight_only)]
        result = status.monitor(client, items, NOW, 48, lookup=lambda: "42", fetch=lambda _: page("MAC_OS", ["2.0.9"]))
        self.assertEqual((result[0]["version"], result[0]["alert"]), ("2.0.10", False))
        self.assertNotIn("issues/2/comments", client.comments)

    def test_overdue_submitted_build_alerts(self) -> None:
        client = FakeGitHub()
        in_review = record(hours=60)
        mark_submitted(client, 1, in_review, hours=49)
        items = [issue(1, in_review), issue(2, record(version="2.0.11", hours=1, build="901"))]
        result = status.monitor(client, items, NOW, 48, lookup=lambda: "42", fetch=lambda _: page("MAC_OS", ["2.0.9"]))
        self.assertEqual((result[0]["version"], result[0]["status"], result[0]["alert"]), ("2.0.10", "App Store drift", True))

    def test_closed_superseded_records_are_never_the_target(self) -> None:
        client = FakeGitHub()
        candidate, superseded = record(hours=10), record(version="2.0.11", hours=60, build="901")
        mark_submitted(client, 2, superseded, hours=55)
        items = [issue(1, candidate), {**issue(2, superseded, "closed"), "state_reason": "not_planned"}]
        target = status.target_records(client, items)["MAC_OS"]
        self.assertEqual((target[1], target[2]), (candidate, None))

    def test_submission_marks_its_exact_record_once(self) -> None:
        client = FakeGitHub()
        value = record()
        items = [issue(1, record(build="899")), issue(2, value)]
        env = {"INPUT_PLATFORM": "MAC_OS", "INPUT_VERSION": value["version"], "INPUT_BUILD_NUMBER": value["buildNumber"],
               "GITHUB_REPOSITORY": "example/panel", "GITHUB_RUN_ID": "7"}
        self.assertEqual(status.record_submission(client, items, env, NOW)["number"], 2)
        status.record_submission(client, items, env, NOW + timedelta(minutes=5))
        self.assertEqual([path for path, _ in client.writes], ["issues/2/comments"])
        self.assertEqual(status.target_records(client, items)["MAC_OS"][2]["submittedAt"], NOW.isoformat())
        self.assertIsNone(status.record_submission(client, items, {**env, "INPUT_BUILD_NUMBER": "950"}, NOW))
        unrecorded = [path for path, body in client.writes[1:]
                      if status.read_marker(status.UNRECORDED, body["body"]) is not None]
        self.assertEqual(unrecorded, ["issues/1/comments", "issues/2/comments"])
        self.assertFalse(status.only_submitted_build(client, items, value))


    def test_live_record_with_one_submitted_build_closes_with_proof(self) -> None:
        client, value = FakeGitHub(), record()
        mark_submitted(client, 1, value, hours=10)
        items = [issue(1, value)]
        status.monitor(client, items, NOW, 48, lookup=lambda: "42", fetch=store({"MAC_OS": "2.0.10"}))
        self.assertEqual(closes(client), ["issues/1"])
        self.assertIn("only build submitted", client.comments["issues/1/comments"][-1]["body"])
        writes = len(client.writes)
        status.monitor(client, items, NOW + timedelta(hours=6), 48, lookup=lambda: "42", fetch=store({"MAC_OS": "2.0.10"}))
        self.assertEqual(len(client.writes), writes)

    def test_record_stays_open_without_single_submitted_live_proof(self) -> None:
        def unreadable(_: str) -> str:
            return "<html>unavailable</html>"

        cases = {"behind": ("2.0.9", True, False), "unreadable": (None, True, False),
                 "never submitted": ("2.0.10", False, False), "two submissions": ("2.0.10", True, True)}
        for name, (public, submitted, second) in cases.items():
            with self.subTest(name):
                client, value = FakeGitHub(), record(hours=1, build="901")
                items = [issue(1, value)]
                if submitted:
                    mark_submitted(client, 1, value, hours=1)
                if second:
                    earlier = record(hours=60)
                    mark_submitted(client, 2, earlier, hours=50)
                    items.append(issue(2, earlier))
                fetch = unreadable if public is None else store({"MAC_OS": public})
                status.monitor(client, items, NOW, 48, lookup=lambda: "42", fetch=fetch)
                self.assertEqual(closes(client), [])

    def test_all_older_records_close_as_superseded_once(self) -> None:
        client = FakeGitHub()
        items = [issue(1, record(version="2.0.8")), issue(2, record(version="2.0.9")),
                 issue(3, record()), issue(4, record(version="2.0.11"))]
        mark_submitted(client, 2, record(version="2.0.9"), hours=10)
        mark_submitted(client, 4, record(version="2.0.11"), hours=1)
        fetch = store({"MAC_OS": "2.0.10"})
        status.monitor(client, items, NOW, 48, lookup=lambda: "42", fetch=fetch)
        self.assertEqual(closes(client), ["issues/1", "issues/2"])
        for number in (1, 2):
            self.assertEqual(items[number - 1]["state_reason"], "not_planned")
            self.assertIn("2.0.10", client.comments[f"issues/{number}/comments"][-1]["body"])
        writes = len(client.writes)
        status.monitor(client, items, NOW, 48, lookup=lambda: "42", fetch=fetch)
        self.assertEqual(len(client.writes), writes)

    def test_supersession_requires_newer_public_version_on_the_same_platform(self) -> None:
        for public in ("2.0.9", "2.0.10", "2.0.10.0", None):
            with self.subTest(public=public):
                client = FakeGitHub()
                value = record("VISION_OS")
                mark_submitted(client, 1, value, hours=1)
                items = [issue(1, value), issue(2, record("MAC_OS", version="2.0.11"))]
                def fetch(url: str, public: str | None = public) -> str:
                    if "platform=mac" in url:
                        return page("MAC_OS", ["2.0.12"])
                    return "unavailable" if public is None else page("VISION_OS", [public])
                status.monitor(client, items, NOW, 48, lookup=lambda: "42", fetch=fetch)
                self.assertEqual(items[0]["state"], "closed" if public in ("2.0.10", "2.0.10.0") else "open")
                self.assertNotEqual(items[0].get("state_reason"), "not_planned")

    def test_old_parent_closes_with_live_and_superseded_children_after_targets_move(self) -> None:
        client = FakeGitHub()
        items = release_records(client)
        for item in items[:-1]:
            item.update(state="closed", state_reason="completed")
        parent = {"number": PARENT, "state": "open", "body": "Release", "labels": []}
        client.children[f"issues/{PARENT}/sub_issues"] = items
        newer = [issue(number, record(platform, version="2.0.11"))
                 for number, platform in enumerate(sorted(status.PLATFORMS), start=10)]
        versions = {platform: "2.0.11" for platform in status.PLATFORMS}
        versions["IOS"] = "2.0.10"
        status.monitor(client, [*items, *newer, parent], NOW, 48, lookup=lambda: "42", fetch=store(versions))
        self.assertEqual(parent["state"], "closed")
        summary = client.comments[f"issues/{PARENT}/comments"][-1]["body"]
        self.assertIn("2.0.11", summary)
        self.assertTrue(all(item["state"] == "open" for item in newer))

    def test_parent_reconciliation_resumes_after_every_record_was_superseded(self) -> None:
        client = FakeGitHub()
        items = release_records(client)
        for item in items:
            item.update(state="closed", state_reason="not_planned")
        parent = {"number": PARENT, "state": "open", "body": "Release", "labels": []}
        client.children[f"issues/{PARENT}/sub_issues"] = items
        with self.assertRaises(status.StatusError):
            status.monitor(client, [*items, parent], NOW, 48, lookup=lambda: "42",
                           fetch=store({platform: "2.0.11" for platform in status.PLATFORMS}))
        self.assertEqual(closes(client), [f"issues/{PARENT}"])

    def test_interrupted_closure_does_not_repeat_its_comment(self) -> None:
        for outcome in ("live", "superseded", "parent"):
            with self.subTest(outcome=outcome):
                client = FakeGitHub()
                items = release_records(client)
                parent = {"number": PARENT, "state": "open", "body": "Release", "labels": []}
                client.children[f"issues/{PARENT}/sub_issues"] = items
                versions = {platform: "2.0.11" if outcome == "superseded" else "2.0.10"
                            for platform in status.PLATFORMS}
                newer = issue(10, record(version="2.0.12"))
                mark_submitted(client, 10, record(version="2.0.12"), hours=1)
                target = f"issues/{PARENT}" if outcome == "parent" else f"issues/{items[0]['number']}"
                api = client.api
                def interrupt(path: str, body: dict | None = None, method: str = "POST",
                              target: str = target, api: Any = api) -> dict:
                    if path == target and method == "PATCH":
                        raise status.StatusError("interrupted close")
                    return api(path, body, method)
                with mock.patch.object(client, "api", side_effect=interrupt), self.assertRaises(status.StatusError):
                    status.monitor(client, [*items, newer, parent], NOW, 48, lookup=lambda: "42", fetch=store(versions))
                before = list(client.comments[f"{target}/comments"])
                status.monitor(client, [*items, newer, parent], NOW, 48, lookup=lambda: "42", fetch=store(versions))
                self.assertEqual(client.comments[f"{target}/comments"], before)
                self.assertEqual(parent["state"], "closed")

    def test_release_closes_only_when_every_platform_is_live(self) -> None:
        client = FakeGitHub()
        items = release_records(client)
        parent = {"number": PARENT, "state": "open", "body": "Release",
                  "labels": [{"name": "plan"}, {"name": "plan:waiting"}, {"name": "release"}]}
        client.children[f"issues/{PARENT}/sub_issues"] = items
        versions = {platform: "2.0.10" for platform in status.PLATFORMS} | {"IOS": "2.0.9"}
        status.monitor(client, [*items, parent], NOW, 48, lookup=lambda: "42", fetch=store(versions))
        self.assertEqual(len(closes(client)), 3)
        self.assertEqual(parent["state"], "open")
        status.monitor(client, [*items, parent], NOW, 48, lookup=lambda: "42", fetch=store(versions | {"IOS": "2.0.10"}))
        self.assertEqual(closes(client)[-1], f"issues/{PARENT}")
        self.assertEqual(client.writes[-1][1]["labels"], ["plan", "release", "plan:done"])
        summary = client.comments[f"issues/{PARENT}/comments"][-1]["body"]
        self.assertTrue(all(platform in summary for platform in status.PLATFORMS))

    def test_submission_without_a_ship_record_keeps_the_record_open(self) -> None:
        client, value = FakeGitHub(), record()
        mark_submitted(client, 1, value, hours=10)
        items = [issue(1, value)]
        env = {"INPUT_PLATFORM": "MAC_OS", "INPUT_VERSION": value["version"], "INPUT_BUILD_NUMBER": "950",
               "GITHUB_REPOSITORY": "example/panel", "GITHUB_RUN_ID": "8"}
        status.record_submission(client, items, env, NOW)
        status.monitor(client, items, NOW, 48, lookup=lambda: "42", fetch=store({"MAC_OS": "2.0.10"}))
        self.assertEqual(closes(client), [])

    def test_hand_closed_record_completes_a_release_only_when_seen_live(self) -> None:
        for public, expected in (("2.0.9", "open"), ("2.0.10", "closed")):
            with self.subTest(public=public):
                client = FakeGitHub()
                items = release_records(client)
                mac = next(item for item in items if "MAC_OS" in item["body"])
                mac.update(state="closed", state_reason="completed")
                parent = {"number": PARENT, "state": "open", "body": "Release", "labels": []}
                client.children[f"issues/{PARENT}/sub_issues"] = items
                versions = {platform: "2.0.10" for platform in status.PLATFORMS} | {"MAC_OS": public}
                status.monitor(client, [*items, parent], NOW, 48, lookup=lambda: "42", fetch=store(versions))
                self.assertEqual(len([path for path in closes(client) if path != f"issues/{PARENT}"]), 3)
                self.assertEqual(parent["state"], expected)

    def test_hand_closed_record_without_single_build_proof_does_not_complete_a_release(self) -> None:
        client = FakeGitHub()
        items = release_records(client)
        mac = next(item for item in items if "MAC_OS" in item["body"])
        mac.update(state="closed", state_reason="completed")
        env = {"INPUT_PLATFORM": "MAC_OS", "INPUT_VERSION": "2.0.10", "INPUT_BUILD_NUMBER": "950",
               "GITHUB_REPOSITORY": "example/panel", "GITHUB_RUN_ID": "8"}
        status.record_submission(client, items, env, NOW)
        parent = {"number": PARENT, "state": "open", "body": "Release", "labels": []}
        client.children[f"issues/{PARENT}/sub_issues"] = items
        status.monitor(client, [*items, parent], NOW, 48, lookup=lambda: "42",
                       fetch=store({platform: "2.0.10" for platform in status.PLATFORMS}))
        self.assertEqual(parent["state"], "open")

    def test_superseded_records_do_not_complete_a_release(self) -> None:
        client = FakeGitHub()
        items = []
        for number, platform in enumerate(("IOS", "TV_OS", "VISION_OS"), start=1):
            value = record(platform, hours=10)
            mark_submitted(client, number, value, hours=5)
            items.append(under_release(issue(number, value)))
        superseded = {**under_release(issue(4, record())), "state": "closed", "state_reason": "not_planned"}
        parent = {"number": PARENT, "state": "open", "body": "Release", "labels": []}
        client.children[f"issues/{PARENT}/sub_issues"] = [*items, superseded]
        status.monitor(client, [*items, superseded, parent], NOW, 48, lookup=lambda: "42",
                       fetch=store({platform: "2.0.10" for platform in status.PLATFORMS}))
        self.assertEqual(len(closes(client)), 3)
        self.assertEqual(parent["state"], "open")

    def test_record_without_a_release_closes_alone(self) -> None:
        client, value = FakeGitHub(), record()
        mark_submitted(client, 1, value, hours=10)
        status.monitor(client, [issue(1, value)], NOW, 48, lookup=lambda: "42", fetch=store({"MAC_OS": "2.0.10"}))
        self.assertEqual(closes(client), ["issues/1"])
        self.assertFalse(any(path.endswith("/sub_issues") for path, _ in client.writes))

    def test_ship_links_records_to_the_named_release_once(self) -> None:
        client = FakeGitHub()
        parent = {"number": PARENT, "state": "open"}
        items = [parent]
        self.assertIsNone(status.release_issue(items, ""))
        for value in ("abc", "51"):
            with self.subTest(value), self.assertRaises(status.StatusError):
                status.release_issue(items, value)
        with self.assertRaises(status.StatusError):
            status.release_issue([{**parent, "state": "closed"}], str(PARENT))
        created = status.ensure_record(client, items, record())
        status.link_to_release(client, created, status.release_issue(items, str(PARENT)))
        status.link_to_release(client, status.ensure_record(client, items, record()), parent)
        self.assertEqual([body for path, body in client.writes if path.endswith("/sub_issues")],
                         [{"sub_issue_id": created["id"]}])
        elsewhere = {**created, "parent_issue_url": "https://api.github.com/repos/example/panel/issues/9"}
        with self.assertRaises(status.StatusError):
            status.link_to_release(client, elsewhere, parent)


if __name__ == "__main__":
    unittest.main()
