import importlib.util
import io
import socket
import unittest
import urllib.error
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "distribute-testflight-beta.py"
SPEC = importlib.util.spec_from_file_location("distribute_testflight_beta", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
distribute_testflight_beta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distribute_testflight_beta)


class FakeASCClient:
    def __init__(self):
        self.requests: list[tuple[Any, ...]] = []
        self.build_state = "VALID"
        self.marketing_version = "1.0.22"
        self.platform = "MAC_OS"
        self.group_builds: dict[str, list[str]] = {"group-internal": []}
        self.conflict_on_add = False

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        self.requests.append((method, path, params, body, allowed))
        if method == "GET" and path == "/builds":
            build_fields = set((params or {}).get("fields[builds]", "").split(","))
            build: dict[str, Any] = {
                "id": "build-1",
                "type": "builds",
                "attributes": {
                    "version": "202606111944",
                    "processingState": self.build_state,
                    "usesNonExemptEncryption": False,
                },
            }
            included = []
            if "preReleaseVersion" in build_fields:
                build["relationships"] = {
                    "preReleaseVersion": {
                        "data": {"type": "preReleaseVersions", "id": "pre-release-1"}
                    }
                }
                included.append(
                    {
                        "id": "pre-release-1",
                        "type": "preReleaseVersions",
                        "attributes": {"version": self.marketing_version, "platform": self.platform},
                    }
                )
            return {
                "data": [build],
                "included": included,
            }
        if method == "GET" and path == "/apps/app-1/betaGroups":
            if params and "sort" in params:
                raise AssertionError("beta group listing does not accept sort")
            return {
                "data": [
                    {
                        "id": "group-internal",
                        "type": "betaGroups",
                        "attributes": {
                            "name": "Internal Testers",
                            "isInternalGroup": True,
                            "hasAccessToAllBuilds": False,
                        },
                    },
                    {
                        "id": "group-named",
                        "type": "betaGroups",
                        "attributes": {
                            "name": "Friends",
                            "isInternalGroup": False,
                            "hasAccessToAllBuilds": False,
                        },
                    },
                ]
            }
        if method == "GET" and path.startswith("/betaGroups/") and path.endswith("/builds"):
            group_id = path.split("/")[2]
            return {
                "data": [
                    {"id": build_id, "type": "builds", "attributes": {}}
                    for build_id in self.group_builds.get(group_id, [])
                ]
            }
        if method == "POST" and path.startswith("/betaGroups/") and path.endswith("/relationships/builds"):
            if body is None:
                raise AssertionError("missing request body")
            if self.conflict_on_add:
                raise distribute_testflight_beta.AppStoreConnectError(
                    "App Store Connect request failed: POST relationship",
                    status=409,
                    payload={"errors": [{"detail": "relationship conflict"}]},
                )
            group_id = path.split("/")[2]
            build_id = body["data"][0]["id"]
            self.group_builds.setdefault(group_id, []).append(build_id)
            return {}
        raise AssertionError(f"unexpected request: {method} {path}")


class FakeResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self):
        return b'{"data": []}'


def http_error(status_code: int, body: bytes = b'{"errors": []}') -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        url="https://api.appstoreconnect.apple.com/v1/apps/app-1/betaGroups",
        code=status_code,
        msg="error",
        hdrs={},
        fp=io.BytesIO(body),
    )


def builds_payload(*builds: tuple[str, str, str, str]) -> dict[str, Any]:
    data = []
    included = []
    for build_id, build_number, marketing_version, platform in builds:
        pre_release_id = f"pre-release-{build_id}"
        data.append(
            {
                "id": build_id,
                "type": "builds",
                "attributes": {
                    "version": build_number,
                    "processingState": "VALID",
                    "usesNonExemptEncryption": False,
                },
                "relationships": {
                    "preReleaseVersion": {
                        "data": {"type": "preReleaseVersions", "id": pre_release_id}
                    }
                },
            }
        )
        included.append(
            {
                "id": pre_release_id,
                "type": "preReleaseVersions",
                "attributes": {"version": marketing_version, "platform": platform},
            }
        )
    return {"data": data, "included": included}


class TestFlightDistributionTests(unittest.TestCase):
    def test_selects_internal_groups_by_default(self):
        client = FakeASCClient()

        groups = distribute_testflight_beta.selected_beta_groups(
            distribute_testflight_beta.beta_groups(client, "app-1"),
            [],
            include_internal=True,
        )

        self.assertEqual([group["id"] for group in groups], ["group-internal"])

    def test_selects_named_and_internal_groups_without_duplicates(self):
        client = FakeASCClient()

        groups = distribute_testflight_beta.selected_beta_groups(
            distribute_testflight_beta.beta_groups(client, "app-1"),
            ["Friends", "Internal Testers"],
            include_internal=True,
        )

        self.assertEqual([group["id"] for group in groups], ["group-named", "group-internal"])

    def test_add_build_to_group_is_idempotent(self):
        client = FakeASCClient()
        group = {"id": "group-internal", "attributes": {"name": "Internal Testers"}}
        build = {"id": "build-1", "attributes": {}}

        self.assertEqual(distribute_testflight_beta.add_build_to_group(client, build, group, False), "added")
        self.assertEqual(distribute_testflight_beta.add_build_to_group(client, build, group, False), "already-present")

        post_requests = [request for request in client.requests if request[0] == "POST"]
        self.assertEqual(len(post_requests), 1)

    def test_conflict_only_succeeds_when_follow_up_read_confirms_membership(self):
        client = FakeASCClient()
        client.conflict_on_add = True
        group = {"id": "group-internal", "attributes": {"name": "Internal Testers"}}
        build = {"id": "build-1", "attributes": {}}

        with self.assertRaises(distribute_testflight_beta.AppStoreConnectError):
            distribute_testflight_beta.add_build_to_group(client, build, group, False)

        client.group_builds["group-internal"] = ["build-1"]

        self.assertEqual(distribute_testflight_beta.add_build_to_group(client, build, group, False), "already-present")

    def test_ensure_build_fails_immediately_on_failed_processing(self):
        client = FakeASCClient()
        client.build_state = "FAILED"

        with self.assertRaises(distribute_testflight_beta.AppStoreConnectError) as context:
            distribute_testflight_beta.ensure_build(
                client,
                "app-1",
                "1.0.22",
                "202606111944",
                None,
                False,
                False,
                wait_timeout_seconds=60,
                poll_seconds=1,
            )

        self.assertIn("processing failed", str(context.exception))

    def test_ensure_build_rejects_mismatched_marketing_version(self):
        client = FakeASCClient()

        with self.assertRaises(distribute_testflight_beta.AppStoreConnectError) as context:
            distribute_testflight_beta.ensure_build(
                client,
                "app-1",
                "1.0.21",
                "202606111944",
                None,
                False,
                False,
                wait_timeout_seconds=60,
                poll_seconds=1,
            )

        self.assertIn("belongs to marketing version 1.0.22", str(context.exception))

    def test_ensure_build_selects_requested_platform(self):
        client = FakeASCClient()
        client.platform = "IOS"

        build = distribute_testflight_beta.ensure_build(
            client,
            "app-1",
            "1.0.22",
            "202606111944",
            "IOS",
            False,
            False,
            wait_timeout_seconds=0,
            poll_seconds=1,
        )

        self.assertEqual(build["id"], "build-1")

    def test_ensure_build_selects_requested_visionos_platform(self):
        client = FakeASCClient()
        client.platform = "VISION_OS"

        build = distribute_testflight_beta.ensure_build(
            client,
            "app-1",
            "1.0.22",
            "202606111944",
            "VISION_OS",
            False,
            False,
            wait_timeout_seconds=0,
            poll_seconds=1,
        )

        self.assertEqual(build["id"], "build-1")

    def test_ensure_build_rejects_missing_requested_platform(self):
        client = FakeASCClient()

        with self.assertRaises(distribute_testflight_beta.AppStoreConnectError) as context:
            distribute_testflight_beta.ensure_build(
                client,
                "app-1",
                "1.0.22",
                "202606111944",
                "IOS",
                False,
                False,
                wait_timeout_seconds=0,
                poll_seconds=1,
            )

        self.assertIn("missing build 202606111944 for platform IOS", str(context.exception))

    def test_ensure_build_waits_for_requested_platform_when_build_number_is_shared(self):
        client = mock.Mock()
        client.request.side_effect = [
            builds_payload(("build-tv", "202606111944", "1.0.45", "TV_OS")),
            builds_payload(
                ("build-tv", "202606111944", "1.0.45", "TV_OS"),
                ("build-mac", "202606111944", "1.0.44", "MAC_OS"),
            ),
        ]

        with mock.patch.object(distribute_testflight_beta.time, "sleep") as sleep:
            build = distribute_testflight_beta.ensure_build(
                client,
                "app-1",
                "1.0.44",
                "202606111944",
                "MAC_OS",
                False,
                False,
                wait_timeout_seconds=60,
                poll_seconds=1,
            )

        self.assertEqual(build["id"], "build-mac")
        sleep.assert_called_once_with(1)

    def test_parse_args_requires_platform(self):
        with mock.patch(
            "sys.argv",
            [
                "distribute-testflight-beta.py",
                "--version",
                "1.0.22",
                "--build-number",
                "202606111944",
            ],
        ):
            with mock.patch("sys.stderr", new_callable=io.StringIO):
                with self.assertRaises(SystemExit):
                    distribute_testflight_beta.parse_args()

    def test_request_retries_transient_http_failures(self):
        client = distribute_testflight_beta.ASCClient("token")

        with mock.patch.object(distribute_testflight_beta.time, "sleep") as sleep:
            with mock.patch.object(
                distribute_testflight_beta.urllib.request,
                "urlopen",
                side_effect=[http_error(500, b'{"errors":[{"status":"500"}]}'), FakeResponse()],
            ) as urlopen:
                payload = client.request("GET", "/apps/app-1/betaGroups")

        self.assertEqual(payload, {"data": []})
        self.assertEqual(urlopen.call_count, 2)
        sleep.assert_called_once_with(distribute_testflight_beta.TRANSIENT_BACKOFF_SECONDS)

    def test_request_retries_transient_http_failures_before_failing_closed(self):
        client = distribute_testflight_beta.ASCClient("token")

        with mock.patch.object(distribute_testflight_beta.time, "sleep") as sleep:
            with mock.patch.object(
                distribute_testflight_beta.urllib.request,
                "urlopen",
                side_effect=[http_error(500) for _ in range(distribute_testflight_beta.TRANSIENT_ATTEMPTS)],
            ) as urlopen:
                with self.assertRaises(distribute_testflight_beta.AppStoreConnectError) as context:
                    client.request("GET", "/apps/app-1/betaGroups")

        self.assertEqual(context.exception.status, 500)
        self.assertEqual(urlopen.call_count, distribute_testflight_beta.TRANSIENT_ATTEMPTS)
        self.assertEqual(sleep.call_count, distribute_testflight_beta.TRANSIENT_ATTEMPTS - 1)

    def test_request_does_not_retry_non_transient_http_failures(self):
        client = distribute_testflight_beta.ASCClient("token")

        with mock.patch.object(distribute_testflight_beta.time, "sleep") as sleep:
            with mock.patch.object(
                distribute_testflight_beta.urllib.request,
                "urlopen",
                side_effect=http_error(401),
            ) as urlopen:
                with self.assertRaises(distribute_testflight_beta.AppStoreConnectError) as context:
                    client.request("GET", "/apps/app-1/betaGroups")

        self.assertEqual(context.exception.status, 401)
        self.assertEqual(urlopen.call_count, 1)
        sleep.assert_not_called()

    def test_request_retries_timeouts_before_failing_closed(self):
        client = distribute_testflight_beta.ASCClient("token")

        with mock.patch.object(distribute_testflight_beta.time, "sleep") as sleep:
            with mock.patch.object(
                distribute_testflight_beta.urllib.request,
                "urlopen",
                side_effect=socket.timeout("timed out"),
            ) as urlopen:
                with self.assertRaises(distribute_testflight_beta.AppStoreConnectError) as context:
                    client.request("GET", "/apps/app-1/betaGroups")

        self.assertIn("timed out", str(context.exception))
        self.assertEqual(urlopen.call_count, distribute_testflight_beta.TRANSIENT_ATTEMPTS)
        self.assertEqual(sleep.call_count, distribute_testflight_beta.TRANSIENT_ATTEMPTS - 1)


if __name__ == "__main__":
    unittest.main()
