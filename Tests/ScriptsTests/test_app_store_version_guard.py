import importlib.util
import unittest
from pathlib import Path
from typing import Any


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
            platform = (params or {}).get("filter[platform]")
            return {
                "data": [
                    {
                        "id": f"pre-release-{version}",
                        "type": "preReleaseVersions",
                        "attributes": {"version": version, "platform": platform},
                    }
                    for version in self.pre_release_versions.get(platform, [])
                ]
            }
        raise AssertionError(f"unexpected request: {method} {path}")


class MalformedPaginationClient:
    def request(self, method, path, params=None, body=None, allowed=(200,)):
        return {"data": [], "links": {"next": "https://api.appstoreconnect.apple.com/v1/apps/app-1/preReleaseVersions"}}


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


if __name__ == "__main__":
    unittest.main()
