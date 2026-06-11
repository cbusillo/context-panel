import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any


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
                        "attributes": {"version": self.marketing_version, "platform": "MAC_OS"},
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
                False,
                False,
                wait_timeout_seconds=60,
                poll_seconds=1,
            )

        self.assertIn("belongs to marketing version 1.0.22", str(context.exception))


if __name__ == "__main__":
    unittest.main()
