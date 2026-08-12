import importlib.util
import hashlib
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from typing import Any
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "upload-app-store-screenshots.py"
SCREENSHOT_ROOT = MODULE_PATH.parents[1] / "Resources" / "AppStore" / "Screenshots"
SPEC = importlib.util.spec_from_file_location("upload_app_store_screenshots", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
upload_app_store_screenshots = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = upload_app_store_screenshots
SPEC.loader.exec_module(upload_app_store_screenshots)


class FakeASCClient:
    def __init__(self):
        self.requests: list[tuple[Any, ...]] = []
        self.uploads: list[tuple[dict[str, Any], bytes]] = []
        self.downloads: list[str] = []
        self.fail_upload = False
        self.fail_uploads_remaining = 0
        self.existing_screenshots = [
            {
                "type": "appScreenshots",
                "id": "old-shot-1",
                "attributes": {"fileName": "old-1.png", "imageAsset": {"downloadUrl": "https://download.example/old-1.png"}},
            },
            {
                "type": "appScreenshots",
                "id": "old-shot-2",
                "attributes": {"fileName": "old-2.png", "imageAsset": {"downloadUrl": "https://download.example/old-2.png"}},
            },
        ]
        self.screenshot_sets = [
            {
                "type": "appScreenshotSets",
                "id": "set-1",
                "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
            }
        ]
        self.screenshots_by_set: dict[str, list[dict[str, Any]]] = {}

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        self.requests.append((method, path, params, body, allowed))
        if method == "GET" and path == "/apps/app-1/appStoreVersions":
            return {
                "data": [
                    {
                        "type": "appStoreVersions",
                        "id": "version-1",
                        "attributes": {"versionString": "1.0.38"},
                    }
                ]
            }
        if method == "GET" and path == "/appStoreVersions/version-1/appStoreVersionLocalizations":
            return {
                "data": [
                    {
                        "type": "appStoreVersionLocalizations",
                        "id": "loc-1",
                        "attributes": {"locale": "en-US"},
                    }
                ]
            }
        if method == "GET" and path == "/appStoreVersionLocalizations/loc-1/appScreenshotSets":
            return {"data": self.screenshot_sets}
        if method == "GET" and path.startswith("/appScreenshotSets/") and path.endswith("/appScreenshots"):
            screenshot_set_id = path.split("/")[2]
            return {"data": self.screenshots_by_set.get(screenshot_set_id, self.existing_screenshots)}
        if method == "DELETE" and path.startswith("/appScreenshots/"):
            return {}
        if method == "POST" and path == "/appScreenshots":
            assert body is not None
            filename = body["data"]["attributes"]["fileName"]
            return {
                "data": {
                    "type": "appScreenshots",
                    "id": f"new-{filename}",
                    "attributes": {
                        "uploadOperations": [
                            {
                                "method": "PUT",
                                "url": "https://upload.example.test/asset",
                                "offset": 0,
                                "length": body["data"]["attributes"]["fileSize"],
                                "requestHeaders": [{"name": "Content-Type", "value": "image/png"}],
                            }
                        ]
                    },
                }
            }
        if method == "PATCH" and path.startswith("/appScreenshots/"):
            assert body is not None
            return {"data": {"type": "appScreenshots", "id": path.rsplit("/", 1)[-1]}}
        if method == "GET" and path.startswith("/appScreenshots/"):
            return {
                "data": {
                    "type": "appScreenshots",
                    "id": path.rsplit("/", 1)[-1],
                    "attributes": {"assetDeliveryState": {"state": "COMPLETE"}},
                }
            }
        raise AssertionError(f"unexpected request: {method} {path}")

    def upload(self, operation, source):
        if self.fail_uploads_remaining:
            self.fail_uploads_remaining -= 1
            raise upload_app_store_screenshots.AppStoreConnectError("forced upload failure")
        if self.fail_upload:
            raise upload_app_store_screenshots.AppStoreConnectError("forced upload failure")
        self.uploads.append((operation, source))

    def download(self, url):
        self.downloads.append(url)
        return f"downloaded:{url}".encode()


class UploadAppStoreScreenshotsTests(unittest.TestCase):
    def test_dry_run_does_not_delete_or_upload_screenshots(self):
        client = FakeASCClient()
        with tempfile.TemporaryDirectory() as temp_dir:
            screenshot = Path(temp_dir) / "shot.png"
            screenshot.write_bytes(b"png-data")

            upload_app_store_screenshots.upload_screenshot_set(
                client,
                "app-1",
                "MAC_OS",
                "1.0.38",
                "en-US",
                [upload_app_store_screenshots.ScreenshotAsset("APP_DESKTOP", screenshot)],
                dry_run=True,
                wait=False,
                timeout_seconds=60,
                poll_seconds=1,
            )

        methods = [request[0] for request in client.requests]
        self.assertNotIn("DELETE", methods)
        self.assertNotIn("POST", methods)
        self.assertNotIn("PATCH", methods)
        self.assertEqual(client.uploads, [])

    def test_upload_replaces_existing_screenshots_and_commits_new_asset(self):
        client = FakeASCClient()
        with tempfile.TemporaryDirectory() as temp_dir:
            screenshot = Path(temp_dir) / "shot.png"
            screenshot.write_bytes(b"png-data")

            upload_app_store_screenshots.upload_screenshot_set(
                client,
                "app-1",
                "MAC_OS",
                "1.0.38",
                "en-US",
                [upload_app_store_screenshots.ScreenshotAsset("APP_DESKTOP", screenshot)],
                dry_run=False,
                wait=False,
                timeout_seconds=60,
                poll_seconds=1,
            )

        delete_paths = [request[1] for request in client.requests if request[0] == "DELETE"]
        self.assertEqual(delete_paths, ["/appScreenshots/old-shot-1", "/appScreenshots/old-shot-2"])
        post_request = next(request for request in client.requests if request[0] == "POST")
        self.assertEqual(post_request[1], "/appScreenshots")
        self.assertEqual(post_request[3]["data"]["attributes"], {"fileName": "shot.png", "fileSize": 8})
        patch_request = next(request for request in client.requests if request[0] == "PATCH")
        self.assertEqual(patch_request[1], "/appScreenshots/new-shot.png")
        self.assertEqual(
            patch_request[3]["data"]["attributes"],
            {"uploaded": True, "sourceFileChecksum": hashlib.md5(b"png-data").hexdigest()},
        )
        self.assertEqual(client.uploads[0][1], b"png-data")
        post_index = next(index for index, request in enumerate(client.requests) if request[0] == "POST")
        first_delete_index = next(index for index, request in enumerate(client.requests) if request[0] == "DELETE")
        self.assertGreater(first_delete_index, post_index)

    def test_upload_failure_preserves_existing_screenshots_and_cleans_new_asset(self):
        client = FakeASCClient()
        client.fail_uploads_remaining = 1
        with tempfile.TemporaryDirectory() as temp_dir:
            screenshot = Path(temp_dir) / "shot.png"
            screenshot.write_bytes(b"png-data")

            with self.assertRaises(upload_app_store_screenshots.AppStoreConnectError):
                upload_app_store_screenshots.upload_screenshot_set(
                    client,
                    "app-1",
                    "MAC_OS",
                    "1.0.38",
                    "en-US",
                    [upload_app_store_screenshots.ScreenshotAsset("APP_DESKTOP", screenshot)],
                    dry_run=False,
                    wait=False,
                    timeout_seconds=60,
                    poll_seconds=1,
                )

        delete_paths = [request[1] for request in client.requests if request[0] == "DELETE"]
        self.assertEqual(delete_paths, ["/appScreenshots/new-shot.png"])

    def test_cap_constrained_replacement_backs_up_and_deletes_before_upload(self):
        client = FakeASCClient()
        client.existing_screenshots = [
            {
                "type": "appScreenshots",
                "id": f"old-shot-{index}",
                "attributes": {
                    "fileName": f"old-{index}.png",
                    "imageAsset": {"downloadUrl": f"https://download.example/old-{index}.png"},
                },
            }
            for index in range(7)
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            paths = []
            for index in range(7):
                screenshot = Path(temp_dir) / f"shot-{index}.png"
                screenshot.write_bytes(f"png-data-{index}".encode())
                paths.append(upload_app_store_screenshots.ScreenshotAsset("APP_DESKTOP", screenshot))

            upload_app_store_screenshots.upload_screenshot_set(
                client,
                "app-1",
                "MAC_OS",
                "1.0.38",
                "en-US",
                paths,
                dry_run=False,
                wait=False,
                timeout_seconds=60,
                poll_seconds=1,
            )

        delete_paths = [request[1] for request in client.requests if request[0] == "DELETE"]
        post_index = next(index for index, request in enumerate(client.requests) if request[0] == "POST")
        last_old_delete_index = max(
            index
            for index, request in enumerate(client.requests)
            if request[0] == "DELETE" and request[1].startswith("/appScreenshots/old-shot-")
        )
        self.assertEqual(len(client.downloads), 7)
        self.assertEqual(delete_paths[:7], [f"/appScreenshots/old-shot-{index}" for index in range(7)])
        self.assertLess(last_old_delete_index, post_index)

    def test_cap_constrained_upload_failure_restores_backed_up_screenshots(self):
        client = FakeASCClient()
        client.fail_uploads_remaining = 1
        client.existing_screenshots = [
            {
                "type": "appScreenshots",
                "id": f"old-shot-{index}",
                "attributes": {
                    "fileName": f"old-{index}.png",
                    "imageAsset": {"downloadUrl": f"https://download.example/old-{index}.png"},
                },
            }
            for index in range(7)
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            paths = []
            for index in range(7):
                screenshot = Path(temp_dir) / f"shot-{index}.png"
                screenshot.write_bytes(f"png-data-{index}".encode())
                paths.append(upload_app_store_screenshots.ScreenshotAsset("APP_DESKTOP", screenshot))

            with self.assertRaises(upload_app_store_screenshots.AppStoreConnectError):
                upload_app_store_screenshots.upload_screenshot_set(
                    client,
                    "app-1",
                    "MAC_OS",
                    "1.0.38",
                    "en-US",
                    paths,
                    dry_run=False,
                    wait=False,
                    timeout_seconds=60,
                    poll_seconds=1,
                )

        uploaded_sources = [source for _, source in client.uploads]
        delete_paths = [request[1] for request in client.requests if request[0] == "DELETE"]
        self.assertEqual(len(client.downloads), 7)
        self.assertIn(b"downloaded:https://download.example/old-0.png", uploaded_sources)
        self.assertEqual(delete_paths[:7], [f"/appScreenshots/old-shot-{index}" for index in range(7)])

    def test_cap_constrained_replacement_requires_downloadable_existing_screenshots(self):
        client = FakeASCClient()
        client.existing_screenshots = [
            {
                "type": "appScreenshots",
                "id": f"old-shot-{index}",
                "attributes": {"fileName": f"old-{index}.png", "imageAsset": {}},
            }
            for index in range(7)
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            paths = []
            for index in range(7):
                screenshot = Path(temp_dir) / f"shot-{index}.png"
                screenshot.write_bytes(f"png-data-{index}".encode())
                paths.append(upload_app_store_screenshots.ScreenshotAsset("APP_DESKTOP", screenshot))

            with self.assertRaises(upload_app_store_screenshots.AppStoreConnectError):
                upload_app_store_screenshots.upload_screenshot_set(
                    client,
                    "app-1",
                    "MAC_OS",
                    "1.0.38",
                    "en-US",
                    paths,
                    dry_run=False,
                    wait=False,
                    timeout_seconds=60,
                    poll_seconds=1,
                )

        delete_paths = [request[1] for request in client.requests if request[0] == "DELETE"]
        self.assertEqual(delete_paths, [])

    def test_waits_for_screenshot_processing_after_upload(self):
        client = FakeASCClient()
        with tempfile.TemporaryDirectory() as temp_dir:
            screenshot = Path(temp_dir) / "shot.png"
            screenshot.write_bytes(b"png-data")

            upload_app_store_screenshots.upload_screenshot_set(
                client,
                "app-1",
                "MAC_OS",
                "1.0.38",
                "en-US",
                [upload_app_store_screenshots.ScreenshotAsset("APP_DESKTOP", screenshot)],
                dry_run=False,
                wait=True,
                timeout_seconds=60,
                poll_seconds=1,
            )

        get_paths = [request[1] for request in client.requests if request[0] == "GET"]
        self.assertIn("/appScreenshots/new-shot.png", get_paths)

    def test_infers_platform_for_single_named_set(self):
        self.assertEqual(upload_app_store_screenshots.inferred_platform(["macos"], None), "MAC_OS")
        self.assertEqual(upload_app_store_screenshots.inferred_platform(["ios"], None), "IOS")
        self.assertEqual(upload_app_store_screenshots.inferred_platform(["iphone"], None), "IOS")
        self.assertEqual(upload_app_store_screenshots.inferred_platform(["ipad"], None), "IOS")
        self.assertEqual(upload_app_store_screenshots.inferred_platform(["watch"], None), "IOS")
        self.assertEqual(upload_app_store_screenshots.inferred_platform(["visionpro"], None), "VISION_OS")
        self.assertEqual(upload_app_store_screenshots.inferred_platform(["tvos"], None), "TV_OS")

    def test_approved_sets_have_valid_platform_assets(self):
        approved_sets = upload_app_store_screenshots.APPROVED_SETS
        platform_for_set = upload_app_store_screenshots.PLATFORM_FOR_SET
        display_types_by_platform = upload_app_store_screenshots.FULL_PLATFORM_DISPLAY_TYPES
        expected_display_types = {
            "macos": {"APP_DESKTOP"},
            "iphone": {"APP_IPHONE_61"},
            "iphone65": {"APP_IPHONE_65"},
            "ipad": {"APP_IPAD_PRO_3GEN_129"},
            "watch": {"APP_WATCH_ULTRA"},
            "ios": display_types_by_platform["IOS"],
            "visionpro": {"APP_APPLE_VISION_PRO"},
            "tvos": {"APP_APPLE_TV"},
        }

        self.assertEqual(set(approved_sets), set(platform_for_set))
        self.assertEqual(set(approved_sets), set(expected_display_types))
        full_platforms = set()
        for set_name, assets in approved_sets.items():
            with self.subTest(set_name=set_name):
                self.assertTrue(assets)
                paths = [asset.path for asset in assets]
                self.assertEqual(len(paths), len(set(paths)))
                self.assertTrue(all((SCREENSHOT_ROOT / path).is_file() for path in paths))

                platform = platform_for_set[set_name]
                allowed_display_types = display_types_by_platform[platform]
                actual_display_types = {asset.display_type for asset in assets}
                self.assertLessEqual(actual_display_types, allowed_display_types)
                self.assertEqual(actual_display_types, expected_display_types[set_name])
                if actual_display_types == allowed_display_types:
                    full_platforms.add(platform)

                counts = Counter(asset.display_type for asset in assets)
                self.assertTrue(
                    all(
                        0 < count <= upload_app_store_screenshots.MAX_SCREENSHOTS_PER_DISPLAY_TYPE
                        for count in counts.values()
                    )
                )

        self.assertEqual(full_platforms, set(display_types_by_platform))

    def test_device_specific_approved_sets_do_not_reuse_screenshot_paths(self):
        approved_sets = upload_app_store_screenshots.APPROVED_SETS
        leaf_set_names = ("macos", "iphone", "iphone65", "ipad", "watch", "visionpro", "tvos")
        paths = [asset.path for set_name in leaf_set_names for asset in approved_sets[set_name]]

        self.assertEqual(len(paths), len(set(paths)))

    def test_ios_approved_set_composes_the_device_specific_sets_in_upload_order(self):
        approved_sets = upload_app_store_screenshots.APPROVED_SETS

        expected = sum(
            (approved_sets[set_name] for set_name in ("iphone", "iphone65", "ipad", "watch")),
            (),
        )

        self.assertEqual(approved_sets["ios"], expected)

    def test_selected_assets_preserves_configured_set_and_asset_order(self):
        configured_sets = {
            "first": (
                upload_app_store_screenshots.ScreenshotAsset("DISPLAY_A", Path("first-a.png")),
                upload_app_store_screenshots.ScreenshotAsset("DISPLAY_A", Path("first-b.png")),
            ),
            "second": (
                upload_app_store_screenshots.ScreenshotAsset("DISPLAY_B", Path("second.png")),
            ),
        }

        with mock.patch.object(upload_app_store_screenshots, "APPROVED_SETS", configured_sets):
            assets = upload_app_store_screenshots.selected_assets(
                ["second", "first"], Path("approved-root")
            )

        self.assertEqual(
            assets,
            [
                upload_app_store_screenshots.ScreenshotAsset(
                    "DISPLAY_B", Path("approved-root/second.png")
                ),
                upload_app_store_screenshots.ScreenshotAsset(
                    "DISPLAY_A", Path("approved-root/first-a.png")
                ),
                upload_app_store_screenshots.ScreenshotAsset(
                    "DISPLAY_A", Path("approved-root/first-b.png")
                ),
            ],
        )

    def test_full_platform_upload_prunes_unapproved_display_type_screenshots(self):
        client = FakeASCClient()
        client.screenshot_sets = [
            {
                "type": "appScreenshotSets",
                "id": "set-iphone",
                "attributes": {"screenshotDisplayType": "APP_IPHONE_61"},
            },
            {
                "type": "appScreenshotSets",
                "id": "set-iphone-65",
                "attributes": {"screenshotDisplayType": "APP_IPHONE_65"},
            },
            {
                "type": "appScreenshotSets",
                "id": "set-ipad",
                "attributes": {"screenshotDisplayType": "APP_IPAD_PRO_3GEN_129"},
            },
            {
                "type": "appScreenshotSets",
                "id": "set-watch",
                "attributes": {"screenshotDisplayType": "APP_WATCH_ULTRA"},
            },
            {
                "type": "appScreenshotSets",
                "id": "set-iphone-58",
                "attributes": {"screenshotDisplayType": "APP_IPHONE_58"},
            },
        ]
        client.screenshots_by_set = {
            "set-iphone": [],
            "set-iphone-65": [],
            "set-ipad": [],
            "set-watch": [],
            "set-iphone-58": [
                {
                    "type": "appScreenshots",
                    "id": "old-iphone-58",
                    "attributes": {"fileName": "old-iphone-58.png", "imageAsset": {}},
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            paths = {
                "APP_IPHONE_61": temp / "iphone.png",
                "APP_IPHONE_65": temp / "iphone65.png",
                "APP_IPAD_PRO_3GEN_129": temp / "ipad.png",
                "APP_WATCH_ULTRA": temp / "watch.png",
            }
            for path in paths.values():
                path.write_bytes(b"png-data")

            upload_app_store_screenshots.upload_screenshot_set(
                client,
                "app-1",
                "IOS",
                "1.0.39",
                "en-US",
                [
                    upload_app_store_screenshots.ScreenshotAsset(display_type, path)
                    for display_type, path in paths.items()
                ],
                dry_run=False,
                wait=False,
                timeout_seconds=60,
                poll_seconds=1,
            )

        delete_paths = [request[1] for request in client.requests if request[0] == "DELETE"]
        self.assertEqual(delete_paths, ["/appScreenshots/old-iphone-58"])

    def test_missing_localization_is_an_error(self):
        client = FakeASCClient()

        def missing_locale_request(method, path, params=None, body=None, allowed=(200,)):
            if method == "GET" and path == "/appStoreVersions/version-1/appStoreVersionLocalizations":
                return {"data": []}
            return FakeASCClient.request(client, method, path, params, body, allowed)

        client.request = missing_locale_request

        with self.assertRaises(upload_app_store_screenshots.AppStoreConnectError):
            upload_app_store_screenshots.upload_screenshot_set(
                client,
                "app-1",
                "MAC_OS",
                "1.0.38",
                "en-US",
                [],
                dry_run=True,
                wait=False,
                timeout_seconds=60,
                poll_seconds=1,
            )

    def test_requires_platform_for_multiple_sets(self):
        with self.assertRaises(upload_app_store_screenshots.AppStoreConnectError):
            upload_app_store_screenshots.inferred_platform(["iphone", "watch"], None)

    def test_rejects_mismatched_platform_override(self):
        with self.assertRaises(upload_app_store_screenshots.AppStoreConnectError):
            upload_app_store_screenshots.inferred_platform(["iphone"], "MAC_OS")


if __name__ == "__main__":
    unittest.main()
