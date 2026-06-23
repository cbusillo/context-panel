import importlib.util
import io
import socket
import unittest
import urllib.error
from pathlib import Path
from typing import Any
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "app-store-version-guard.py"
SPEC = importlib.util.spec_from_file_location("app_store_version_guard", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
app_store_version_guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app_store_version_guard)


class FakeASCClient:
    def __init__(self):
        self.app_store_versions: dict[str, list[tuple[str, str]]] = {}
        self.pre_release_versions: dict[str, list[str]] = {}
        self.requests: list[tuple[str, str, dict[str, Any] | None]] = []

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        self.requests.append((method, path, params))
        if method == "GET" and path.endswith("/appStoreVersions"):
            platform = (params or {}).get("filter[platform]")
            return {
                "data": [
                    {
                        "id": f"app-store-{version}",
                        "type": "appStoreVersions",
                        "attributes": {
                            "versionString": version,
                            "appStoreState": state,
                        },
                    }
                    for version, state in self.app_store_versions.get(platform, [])
                ]
            }
        if method == "GET" and path.endswith("/preReleaseVersions"):
            return {
                "data": [
                    {
                        "id": f"pre-release-{version}",
                        "type": "preReleaseVersions",
                        "attributes": {"version": version, "platform": platform},
                    }
                    for platform, versions in self.pre_release_versions.items()
                    for version in versions
                ]
            }
        raise AssertionError(f"unexpected request: {method} {path}")


class MalformedPaginationClient:
    def request(self, method, path, params=None, body=None, allowed=(200,)):
        return {"data": [], "links": {"next": "https://api.appstoreconnect.apple.com/v1/apps/app-1/preReleaseVersions"}}


class FakeResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self):
        return b'{"data": []}'


def http_error(status_code: int, body: bytes = b'{"errors": []}') -> urllib.error.HTTPError:
    error = urllib.error.HTTPError(
        url="https://api.appstoreconnect.apple.com/v1/apps",
        code=status_code,
        msg="error",
        hdrs={},
        fp=io.BytesIO(body),
    )
    return error


class VersionGuardTests(unittest.TestCase):
    def test_rejects_version_lower_than_testflight_pre_release(self):
        client = FakeASCClient()
        client.pre_release_versions["IOS"] = ["1.0.32"]

        with self.assertRaises(app_store_version_guard.AppStoreConnectError) as context:
            app_store_version_guard.assert_not_version_regression(client, "app-1", "IOS", "1.0.29")

        self.assertIn("already has 1.0.32", str(context.exception))
        self.assertIn("TestFlight pre-release version", str(context.exception))

    def test_allows_same_version_with_new_build_number(self):
        client = FakeASCClient()
        client.pre_release_versions["IOS"] = ["1.0.32"]

        latest = app_store_version_guard.assert_not_version_regression(client, "app-1", "IOS", "1.0.32")

        self.assertIsNotNone(latest)
        self.assertEqual(latest.version, "1.0.32")

    def test_allows_version_newer_than_latest_known(self):
        client = FakeASCClient()
        client.pre_release_versions["IOS"] = ["1.0.32"]

        latest = app_store_version_guard.assert_not_version_regression(client, "app-1", "IOS", "1.0.33")

        self.assertIsNotNone(latest)
        self.assertEqual(latest.version, "1.0.32")

    def test_uses_numeric_dotted_comparison(self):
        self.assertLess(app_store_version_guard.compare_versions("1.0.9", "1.0.10"), 0)
        self.assertGreater(app_store_version_guard.compare_versions("1.0.100", "1.0.32"), 0)
        self.assertEqual(app_store_version_guard.compare_versions("1.0.0", "1.0"), 0)

    def test_platform_scopes_known_versions(self):
        client = FakeASCClient()
        client.pre_release_versions["MAC_OS"] = ["1.0.32"]

        latest = app_store_version_guard.assert_not_version_regression(client, "app-1", "IOS", "1.0.29")

        self.assertIsNone(latest)

    def test_pre_release_versions_filters_platform_locally(self):
        client = FakeASCClient()
        client.pre_release_versions["IOS"] = ["1.0.32"]
        client.pre_release_versions["VISION_OS"] = ["2.0.0"]

        versions = app_store_version_guard.pre_release_versions(client, "app-1", "IOS")

        self.assertEqual([version.version for version in versions], ["1.0.32"])
        self.assertNotIn("filter[platform]", client.requests[-1][2])
        self.assertIn("platform", client.requests[-1][2]["fields[preReleaseVersions]"])

    def test_considers_app_store_versions_and_pre_release_versions(self):
        client = FakeASCClient()
        client.app_store_versions["IOS"] = [("1.0.31", "READY_FOR_SALE")]
        client.pre_release_versions["IOS"] = ["1.0.33"]

        with self.assertRaises(app_store_version_guard.AppStoreConnectError) as context:
            app_store_version_guard.assert_not_version_regression(client, "app-1", "IOS", "1.0.32")

        self.assertIn("already has 1.0.33", str(context.exception))
        self.assertIn("TestFlight pre-release version", str(context.exception))

    def test_allows_first_upload_when_platform_has_no_versions(self):
        client = FakeASCClient()

        latest = app_store_version_guard.assert_not_version_regression(client, "app-1", "VISION_OS", "1.0.1")

        self.assertIsNone(latest)

    def test_rejects_non_numeric_marketing_versions(self):
        with self.assertRaises(app_store_version_guard.AppStoreConnectError):
            app_store_version_guard.compare_versions("1.0.32-beta", "1.0.31")

    def test_paginated_get_rejects_malformed_next_url(self):
        with self.assertRaises(app_store_version_guard.AppStoreConnectError) as context:
            app_store_version_guard.paginated_get(MalformedPaginationClient(), "/example")

        self.assertIn("malformed App Store Connect pagination URL", str(context.exception))

    def test_request_retries_transient_http_failures(self):
        client = app_store_version_guard.ASCClient("token")

        with mock.patch.object(app_store_version_guard.time, "sleep") as sleep:
            with mock.patch.object(
                app_store_version_guard.urllib.request,
                "urlopen",
                side_effect=[http_error(500, b'{"errors":[{"status":"500"}]}'), FakeResponse()],
            ) as urlopen:
                payload = client.request("GET", "/apps")

        self.assertEqual(payload, {"data": []})
        self.assertEqual(urlopen.call_count, 2)
        sleep.assert_called_once_with(app_store_version_guard.TRANSIENT_BACKOFF_SECONDS)

    def test_request_retries_rate_limiting(self):
        client = app_store_version_guard.ASCClient("token")

        with mock.patch.object(app_store_version_guard.time, "sleep") as sleep:
            with mock.patch.object(
                app_store_version_guard.urllib.request,
                "urlopen",
                side_effect=[http_error(429), FakeResponse()],
            ) as urlopen:
                payload = client.request("GET", "/apps")

        self.assertEqual(payload, {"data": []})
        self.assertEqual(urlopen.call_count, 2)
        sleep.assert_called_once_with(app_store_version_guard.TRANSIENT_BACKOFF_SECONDS)

    def test_request_retries_transient_http_failures_before_failing_closed(self):
        client = app_store_version_guard.ASCClient("token")

        with mock.patch.object(app_store_version_guard.time, "sleep") as sleep:
            with mock.patch.object(
                app_store_version_guard.urllib.request,
                "urlopen",
                side_effect=[http_error(500) for _ in range(app_store_version_guard.TRANSIENT_ATTEMPTS)],
            ) as urlopen:
                with self.assertRaises(app_store_version_guard.AppStoreConnectError) as context:
                    client.request("GET", "/apps")

        self.assertEqual(context.exception.status, 500)
        self.assertEqual(urlopen.call_count, app_store_version_guard.TRANSIENT_ATTEMPTS)
        self.assertEqual(sleep.call_count, app_store_version_guard.TRANSIENT_ATTEMPTS - 1)

    def test_request_does_not_retry_non_transient_http_failures(self):
        client = app_store_version_guard.ASCClient("token")

        with mock.patch.object(app_store_version_guard.time, "sleep") as sleep:
            with mock.patch.object(
                app_store_version_guard.urllib.request,
                "urlopen",
                side_effect=http_error(401),
            ) as urlopen:
                with self.assertRaises(app_store_version_guard.AppStoreConnectError) as context:
                    client.request("GET", "/apps")

        self.assertEqual(context.exception.status, 401)
        self.assertEqual(urlopen.call_count, 1)
        sleep.assert_not_called()

    def test_request_retries_timeouts_before_failing_closed(self):
        client = app_store_version_guard.ASCClient("token")

        with mock.patch.object(app_store_version_guard.time, "sleep") as sleep:
            with mock.patch.object(
                app_store_version_guard.urllib.request,
                "urlopen",
                side_effect=socket.timeout("timed out"),
            ) as urlopen:
                with self.assertRaises(app_store_version_guard.AppStoreConnectError) as context:
                    client.request("GET", "/apps")

        self.assertIn("timed out", str(context.exception))
        self.assertEqual(urlopen.call_count, app_store_version_guard.TRANSIENT_ATTEMPTS)
        self.assertEqual(sleep.call_count, app_store_version_guard.TRANSIENT_ATTEMPTS - 1)


if __name__ == "__main__":
    unittest.main()
