import importlib.util
import json
from pathlib import Path
import shlex
import sys
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone


PATH = Path(__file__).resolve().parents[2] / "scripts" / "app-store-release-status.py"
SPEC = importlib.util.spec_from_file_location("store_release_status", PATH)
status = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = status
SPEC.loader.exec_module(status)
NOW = datetime(2030, 1, 10, tzinfo=timezone.utc)


def record(platform="MAC_OS", version="2.0.10", hours=49, build="900"):
    return {
        "platform": platform, "version": version, "buildNumber": build,
        "sourceCommit": "a" * 40, "uploadedAt": (NOW - timedelta(hours=hours)).isoformat(),
        "github": "success", "testflight": "success", "appStore": "App Store submission pending",
        "runURL": "https://github.com/example/panel/actions/runs/123",
    }


def issue(number, value, state="open"):
    return {"number": number, "body": status.marker(status.RECORD, value), "state": state}


def page(platform, versions, app_id="42"):
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

    def __init__(self):
        self.writes = []
        self.comments = {}
        self.release = None

    def api(self, path, body=None):
        if body is None:
            if path == "releases/latest":
                return self.release
            raise AssertionError(path)
        self.writes.append((path, body))
        if path == "issues":
            return {"number": 77, "html_url": "https://github.com/example/panel/issues/77", **body}
        if path.endswith("/comments"):
            self.comments.setdefault(path, []).append(body)
            return body
        raise AssertionError(path)

    def pages(self, path):
        return self.comments.get(path, [])


class StoreReleaseStatusTests(unittest.TestCase):
    def test_numeric_versions_not_lexicographic(self):
        self.assertTrue(status.evaluate(record(version="2.0.10"), "2.0.9", NOW, 48)["alert"])
        self.assertFalse(status.evaluate(record(version="2.0.9"), "2.0.10", NOW, 48)["alert"])

    def test_trailing_zero_versions_agree_with_version_authority(self):
        self.assertEqual(status.version_guard.compare_versions("2.1", "2.1.0"), 0)
        self.assertFalse(status.evaluate(record(version="2.1.0"), "2.1", NOW, 48)["alert"])

    def test_grace_boundary_and_unknown(self):
        self.assertFalse(status.evaluate(record(hours=47), "2.0.9", NOW, 48)["alert"])
        self.assertTrue(status.evaluate(record(hours=48), "2.0.9", NOW, 48)["alert"])
        result = status.evaluate(record(hours=0), None, NOW, 48)
        self.assertTrue(result["alert"])
        self.assertIsNone(result["publicVersion"])

    def test_invalid_versions_and_future_dates_are_not_green(self):
        for version in ("", "2.beta", "2.-1"):
            with self.subTest(version=version), self.assertRaises(status.version_guard.AppStoreConnectError):
                status.evaluate(record(), version, NOW, 48)
        with self.assertRaises(status.StatusError):
            status.evaluate(record(hours=-1), "2.0.10", NOW, 48)

    def test_latest_record_is_selected_per_platform_including_closed_records(self):
        mac = record()
        vision = record("VISION_OS", version="1.8")
        items = [issue(1, record(version="2.0.9", hours=100)), issue(2, mac, "closed"),
                 issue(3, vision), issue(4, record("IOS", version="1.9"))]
        latest = status.latest_records(items)
        self.assertEqual(latest[mac["platform"]][1], mac)
        self.assertEqual(latest[vision["platform"]][1], vision)
        self.assertEqual(set(latest), {item["platform"] for item in (mac, vision, record("IOS"))})

    def test_newer_build_of_same_version_wins(self):
        older, newer = record(hours=80), record(hours=1, build="901")
        self.assertEqual(status.latest_records([issue(2, newer), issue(1, older)])["MAC_OS"][1], newer)

    def test_public_page_is_bound_to_app_and_platform(self):
        for platform in status.PLATFORMS:
            self.assertEqual(status.public_page_version(page(platform, ["2.0.9", "2.0.10"]), platform, "42"), "2.0.10")
        with self.assertRaises(status.StatusError):
            status.public_page_version(page("IOS", ["2.0.10"]), "TV_OS", "42")
        with self.assertRaises(status.StatusError):
            status.public_page_version(page("MAC_OS", ["2.0.10"]), "MAC_OS", "99")
        with self.assertRaises(status.StatusError):
            status.public_page_version("<html>unavailable</html>", "MAC_OS", "42")

    def test_empty_and_changed_public_history_are_unknown(self):
        for versions in ([], ["Version 2.0.10"], ["2.0.10", "bad"]):
            with self.subTest(versions=versions), self.assertRaises(status.StatusError):
                status.public_page_version(page("MAC_OS", versions), "MAC_OS", "42")

    def test_successful_upload_is_recorded_when_other_channels_fail(self):
        env = {
            "VALIDATE_RESULT": "success", "INPUT_VERSION": "2.0.10", "GITHUB_SHA": "a" * 40,
            "GITHUB_REPOSITORY": "example/panel", "GITHUB_RUN_ID": "123",
            "INPUT_APP_STORE_CHANNEL": "upload", "APP_STORE_UPLOAD_RESULT": "success", "MAC_BUILD_NUMBER": "900",
            "INPUT_COMPANION_APP_STORE_CHANNEL": "upload", "COMPANION_APP_STORE_UPLOAD_RESULT": "failure",
            "COMPANION_PLATFORM": "TV_OS", "COMPANION_BUILD_NUMBER": "900",
            "GITHUB_RELEASE_RESULT": "failure", "TESTFLIGHT_BETA_RESULT": "failure",
            "INPUT_TESTFLIGHT_BETA_SOURCE": "macos",
        }
        records = status.ship_records(env, NOW)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["platform"], "MAC_OS")
        self.assertEqual(records[0]["testflight"], env["TESTFLIGHT_BETA_RESULT"])
        env["INPUT_APP_STORE_CHANNEL"] = "export-only"
        self.assertEqual(status.ship_records(env, NOW), [])
        env["VALIDATE_RESULT"] = "failure"
        self.assertEqual(status.ship_records(env, NOW), [])

    def test_companion_testflight_is_not_attributed_to_mac(self):
        env = {
            "VALIDATE_RESULT": "success", "INPUT_VERSION": "2.0.10", "GITHUB_SHA": "a" * 40,
            "GITHUB_REPOSITORY": "example/panel", "GITHUB_RUN_ID": "123",
            "INPUT_APP_STORE_CHANNEL": "upload", "APP_STORE_UPLOAD_RESULT": "success", "MAC_BUILD_NUMBER": "900",
            "INPUT_COMPANION_APP_STORE_CHANNEL": "upload", "COMPANION_APP_STORE_UPLOAD_RESULT": "success",
            "COMPANION_PLATFORM": "VISION_OS", "COMPANION_BUILD_NUMBER": "901",
            "INPUT_TESTFLIGHT_BETA_SOURCE": "companion", "TESTFLIGHT_BETA_RESULT": "success",
        }
        records = status.ship_records(env, NOW)
        self.assertEqual(records[0]["testflight"], "not selected")
        self.assertEqual(records[1]["testflight"], env["TESTFLIGHT_BETA_RESULT"])
        command = shlex.split(status.next_command("example/panel", records[1]))
        for key, value in (("platform", records[1]["platform"]), ("version", records[1]["version"]),
                           ("build_number", records[1]["buildNumber"]), ("dry_run", "true")):
            self.assertIn(f"{key}={value}", command)

    def test_record_retries_reuse_exact_identity(self):
        client, items, value = FakeGitHub(), [], record()
        first = status.ensure_record(client, items, value)
        again = status.ensure_record(client, items, {**value, "uploadedAt": NOW.isoformat()})
        self.assertEqual(first, again)
        self.assertEqual(len(client.writes), 1)
        self.assertEqual(status.read_marker(status.RECORD, first["body"]), value)

    def test_retry_updates_failed_testflight_result_without_duplicate_issues(self):
        client, items = FakeGitHub(), []
        first = status.ensure_record(client, items, {**record(), "testflight": "failure"})
        status.ensure_record(client, items, record())
        status.ensure_record(client, items, record())
        self.assertEqual(len(client.writes), 2)
        self.assertEqual(client.writes[-1][0], f"issues/{first['number']}/comments")
        result = status.read_marker(status.CHANNELS, client.writes[-1][1]["body"])
        self.assertEqual(result["testflight"], record()["testflight"])

    def test_record_entrypoint_fails_if_durable_issue_cannot_be_written(self):
        env = {
            "GITHUB_REPOSITORY": "example/panel", "VALIDATE_RESULT": "success",
            "INPUT_VERSION": "2.0.10", "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123",
            "INPUT_APP_STORE_CHANNEL": "upload", "APP_STORE_UPLOAD_RESULT": "success", "MAC_BUILD_NUMBER": "900",
        }
        with mock.patch.dict(status.os.environ, env, clear=True), mock.patch.object(sys, "argv", ["status", "record-ship"]), \
                mock.patch.object(status.GitHub, "issues", return_value=[]), \
                mock.patch.object(status.GitHub, "api", side_effect=status.StatusError("write failed")), \
                mock.patch.object(status.sys, "stderr"):
            self.assertNotEqual(status.main(), 0)

    def test_monitor_is_platform_scoped_deduplicated_and_records_recovery(self):
        client = FakeGitHub()
        items = [issue(1, record()), issue(2, record("VISION_OS", version="1.8"))]

        def fetch(url):
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

    def test_failed_lookup_alerts_instead_of_reporting_live(self):
        client = FakeGitHub()

        def fail():
            raise OSError("unavailable")

        results = status.monitor(client, [issue(1, record(hours=0))], NOW, 48, lookup=fail)
        self.assertTrue(results[0]["alert"])
        self.assertIsNone(results[0]["publicVersion"])
        self.assertEqual(len(client.writes), 1)

    def test_legacy_mac_baseline_uses_sealed_release_without_inventing_companion_uploads(self):
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


if __name__ == "__main__":
    unittest.main()
