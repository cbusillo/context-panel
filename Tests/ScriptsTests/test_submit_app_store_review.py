import importlib.util
import io
import time
import unittest
import urllib.error
import sys
from unittest.mock import patch
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from datetime import timedelta
from types import SimpleNamespace
from typing import Any


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "submit-app-store-review.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("submit_app_store_review", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
submit_app_store_review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(submit_app_store_review)

from Tests.ScriptsTests import test_app_store_submission_gate as gate_tests  # noqa: E402


def assert_review_submission_submit_body(test_case, patch_body):
    test_case.assertEqual(patch_body["data"]["attributes"], {"submitted": True})
    test_case.assertNotIn("relationships", patch_body["data"])


def valid_build(
    build_id="build-1",
    state="VALID",
    uses_non_exempt_encryption=None,
    platform="MAC_OS",
    marketing_version="1.0.39",
):
    return {
        "data": [
            {
                "id": build_id,
                "attributes": {
                    "processingState": state,
                    "usesNonExemptEncryption": uses_non_exempt_encryption,
                },
                "relationships": {
                    "preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "prerelease-1"}}
                },
            }
        ],
        "included": [
            {
                "id": "prerelease-1",
                "type": "preReleaseVersions",
                "attributes": {"platform": platform, "version": marketing_version},
            }
        ],
    }


def build_payload(builds):
    data = []
    included = []
    for build in builds:
        build_id = build.get("build_id", f"build-{len(data) + 1}")
        pre_release_id = build.get("pre_release_id", f"prerelease-{len(included) + 1}")
        data.append(
            {
                "id": build_id,
                "attributes": {
                    "processingState": build.get("state", "VALID"),
                    "usesNonExemptEncryption": build.get("uses_non_exempt_encryption"),
                },
                "relationships": {
                    "preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": pre_release_id}}
                },
            }
        )
        included.append(
            {
                "id": pre_release_id,
                "type": "preReleaseVersions",
                "attributes": {
                    "platform": build.get("platform", "MAC_OS"),
                    "version": build.get("marketing_version", "1.0.39"),
                },
            }
        )
    return {"data": data, "included": included}


class SubmissionGateWiringTests(unittest.TestCase):
    """main() runs the submission gate before App Store Connect credentials are used."""

    @staticmethod
    def args(**overrides):
        values = {
            "dry_run": False, "cancel_review_only": False, "prepare_only": False,
            "remove_active_review_version": None, "build_number": gate_tests.BUILD,
            "version": gate_tests.VERSION, "whats_new": "Fixes", "platform": gate_tests.PLATFORM,
            "tvos_demo_video_url": None, "skip_soak_reason": None,
            "api_key_id": None, "api_issuer_id": None,
        }
        values.update(overrides)
        return SimpleNamespace(**values)

    @staticmethod
    def run_main(args, github, now):
        class FixedClock(submit_app_store_review.datetime):
            @classmethod
            def now(cls, tz=None):
                return now if tz is None else now.astimezone(tz)

        with (
            patch.object(submit_app_store_review, "parse_args", return_value=args),
            patch.object(submit_app_store_review, "fetch_github_json", github),
            patch.object(submit_app_store_review, "datetime", FixedClock),
            patch.dict("os.environ", {"GITHUB_REPOSITORY": gate_tests.REPOSITORY}),
            redirect_stdout(io.StringIO()) as output,
            redirect_stderr(io.StringIO()) as errors,
        ):
            exit_code = submit_app_store_review.main()
        return exit_code, output.getvalue(), errors.getvalue()

    def test_a_live_submission_that_is_not_ready_stops_before_credentials(self):
        exit_code, _, errors = self.run_main(
            self.args(), gate_tests.ready_github(), gate_tests.UPLOADED + timedelta(hours=3)
        )
        self.assertEqual(exit_code, 1)
        self.assertIn("not ready for App Review", errors)
        self.assertNotIn("APP_STORE_CONNECT_KEY_ID", errors)

    def test_a_ready_build_continues_to_app_store_connect(self):
        exit_code, output, errors = self.run_main(self.args(), gate_tests.ready_github(), gate_tests.AFTER_A_DAY)
        self.assertEqual(exit_code, 1)
        self.assertIn("Submission gate passed", output)
        self.assertIn("APP_STORE_CONNECT_KEY_ID", errors)

    def test_the_override_is_recorded_and_the_submission_continues(self):
        exit_code, output, errors = self.run_main(
            self.args(skip_soak_reason="Chris used it all day"),
            gate_tests.ready_github(),
            gate_tests.UPLOADED + timedelta(hours=3),
        )
        self.assertIn("Override recorded (Chris used it all day)", output)
        self.assertIn("APP_STORE_CONNECT_KEY_ID", errors)
        self.assertEqual(exit_code, 1)

    def test_a_dry_run_reports_the_gate_without_stopping(self):
        exit_code, output, errors = self.run_main(
            self.args(dry_run=True), gate_tests.ready_github(), gate_tests.UPLOADED + timedelta(hours=3)
        )
        self.assertIn("a live submission would be refused now", output)
        self.assertIn("APP_STORE_CONNECT_KEY_ID", errors)
        self.assertEqual(exit_code, 1)


class FakeASCClient:
    def __init__(
        self,
        include_submission_version=True,
        include_item_version=True,
        app_store_state: str | None = "WAITING_FOR_REVIEW",
        app_version_state: str | None = None,
    ):
        self.deleted_paths: list[str] = []
        self.requests: list[tuple[Any, ...]] = []
        self.include_submission_version = include_submission_version
        self.include_item_version = include_item_version
        self.app_store_state = app_store_state
        self.app_version_state = app_version_state

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        self.requests.append((method, path, params, body, allowed))
        if method == "GET" and path == "/apps/app-id/appStoreVersions":
            attributes = {"versionString": "1.0.13"}
            if self.app_store_state is not None:
                attributes["appStoreState"] = self.app_store_state
            if self.app_version_state is not None:
                attributes["appVersionState"] = self.app_version_state
            return {
                "data": [
                    {
                        "id": "version-1-0-13",
                        "attributes": attributes,
                    }
                ]
            }
        if method == "GET" and path == "/reviewSubmissions":
            submission_relationships: dict[str, Any] = {
                "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]},
            }
            if self.include_submission_version:
                submission_relationships["appStoreVersionForReview"] = {
                    "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                }
            item_relationships: dict[str, Any] = {}
            if self.include_item_version:
                item_relationships["appStoreVersion"] = {
                    "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                }
            return {
                "data": [
                    {
                        "id": "submission-1",
                        "attributes": {"state": "WAITING_FOR_REVIEW"},
                        "relationships": submission_relationships,
                    }
                ],
                "included": [
                    {
                        "id": "item-1",
                        "type": "reviewSubmissionItems",
                        "relationships": item_relationships,
                    }
                ],
            }
        if method == "GET" and path == "/reviewSubmissions/submission-1/items":
            return {"data": [{
                "id": "item-1",
                "relationships": {"appStoreVersion": {"data": {
                    "type": "appStoreVersions", "id": "version-1-0-13",
                }}},
            }]}
        if method == "DELETE" and path == "/reviewSubmissionItems/item-1":
            self.deleted_paths.append(path)
            return {}
        raise AssertionError(f"unexpected request: {method} {path}")


class OrphanReadyForReviewClient:
    def __init__(self, app_store_state="READY_FOR_SALE"):
        self.app_store_state = app_store_state
        self.requests: list[tuple[Any, ...]] = []

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        self.requests.append((method, path, params, body, allowed))
        if method == "GET" and path == "/apps/app-id/appStoreVersions":
            return {
                "data": [{
                    "id": "version-1-0-13",
                    "attributes": {
                        "versionString": "1.0.13",
                        "appStoreState": self.app_store_state,
                    },
                }]
            }
        if method == "GET" and path == "/reviewSubmissions":
            version = {
                "id": "version-1-0-13",
                "type": "appStoreVersions",
                "attributes": {
                    "versionString": "1.0.13",
                    "appStoreState": self.app_store_state,
                    "platform": "IOS",
                },
            }
            return {
                "data": [{
                    "id": "orphan-submission",
                    "attributes": {
                        "state": "READY_FOR_REVIEW",
                        "platform": None,
                        "submittedDate": None,
                    },
                    "relationships": {
                        "items": {"data": []},
                        "appStoreVersionForReview": {
                            "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                        },
                    },
                }],
                "included": [version],
            }
        if method == "PATCH" and path == "/reviewSubmissions/orphan-submission":
            return {"data": {"id": "orphan-submission", "type": "reviewSubmissions"}}
        raise AssertionError(f"unexpected request: {method} {path}")


class SubmittedReviewItemClient(FakeASCClient):
    def request(self, method, path, params=None, body=None, allowed=(200,)):
        if method == "DELETE" and path == "/reviewSubmissionItems/item-1":
            self.requests.append((method, path, params, body, allowed))
            raise submit_app_store_review.AppStoreConnectError(
                "App Store Connect request failed: DELETE /reviewSubmissionItems/item-1",
                status=409,
                payload={"errors": [{"detail": "Item was already submitted"}]},
            )
        if method == "PATCH" and path == "/reviewSubmissionItems/item-1":
            self.requests.append((method, path, params, body, allowed))
            return {
                "data": {
                    "id": "item-1",
                    "type": "reviewSubmissionItems",
                    "attributes": {"state": "REMOVED"},
                }
            }
        return super().request(method, path, params, body, allowed)


class SubmittedReviewItemBlockedBySubmissionStateClient(SubmittedReviewItemClient):
    def __init__(self, items: list[dict[str, Any]] | None = None, cancel_state: str = "COMPLETE", withdrawn_state: str = "DEVELOPER_REJECTED", cancel_read_status: int = 200) -> None:
        super().__init__()
        self.items = items
        self.cancel_state = cancel_state
        self.withdrawn_state = withdrawn_state
        self.cancel_read_status = cancel_read_status

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        if method == "PATCH" and path == "/reviewSubmissionItems/item-1":
            self.requests.append((method, path, params, body, allowed))
            raise submit_app_store_review.AppStoreConnectError(
                "App Store Connect request failed: PATCH /reviewSubmissionItems/item-1",
                status=409,
                payload={
                    "errors": [
                        {
                            "code": "STATE_ERROR.ENTITY_STATE_INVALID",
                            "detail": "Cannot remove item because of state of reviewSubmission.",
                        }
                    ]
                },
            )
        if method == "GET" and path == "/appStoreVersions/version-1-0-13":
            self.requests.append((method, path, params, body, allowed))
            return {"data": {"id": "version-1-0-13", "attributes": {"appStoreState": self.withdrawn_state}}}
        if path == "/reviewSubmissions/submission-1/items" and self.items is not None:
            self.requests.append((method, path, params, body, allowed))
            return {"data": self.items}
        if path == "/reviewSubmissions/submission-1":
            self.requests.append((method, path, params, body, allowed))
            if method == "GET" and self.cancel_read_status != 200:
                raise submit_app_store_review.AppStoreConnectError("cancel readback", status=self.cancel_read_status)
            return {"data": {"id": "submission-1", "attributes": {"state": self.cancel_state}}}
        return super().request(method, path, params, body, allowed)


class PlatformArgumentTests(unittest.TestCase):
    def parse(self, *arguments: str):
        with patch.object(
            sys,
            "argv",
            ["submit-app-store-review.py", "--version", "1.0.54", *arguments],
        ):
            return submit_app_store_review.parse_args()

    def assert_rejected(self, *arguments: str) -> str:
        error_output = io.StringIO()
        with redirect_stderr(error_output), self.assertRaises(SystemExit) as context:
            self.parse(*arguments)
        self.assertEqual(context.exception.code, 2)
        return error_output.getvalue()

    def test_platform_accepts_every_app_store_platform(self):
        for platform in ("MAC_OS", "IOS", "TV_OS", "VISION_OS"):
            with self.subTest(platform=platform):
                self.assertEqual(self.parse("--platform", platform).platform, platform)

    def test_platform_defaults_to_mac_os(self):
        self.assertEqual(self.parse().platform, "MAC_OS")

    def test_platform_rejects_unsupported_miscased_and_empty_values(self):
        for platform in ("WATCH_OS", "ios", ""):
            with self.subTest(platform=platform):
                self.assertIn(
                    "argument --platform:",
                    self.assert_rejected("--platform", platform),
                )

    def test_copy_from_platform_defaults_to_none_and_accepts_supported_platforms(self):
        self.assertIsNone(self.parse().copy_from_platform)
        for platform in ("MAC_OS", "IOS", "TV_OS", "VISION_OS"):
            with self.subTest(platform=platform):
                self.assertEqual(
                    self.parse("--copy-from-platform", platform).copy_from_platform,
                    platform,
                )

    def test_copy_from_platform_rejects_unsupported_platforms(self):
        self.assertIn(
            "argument --copy-from-platform:",
            self.assert_rejected("--copy-from-platform", "WATCH_OS"),
        )


class MetadataSourcePlatformTests(unittest.TestCase):
    def test_copy_from_platform_defaults_to_target_platform(self):
        args = SimpleNamespace(platform="TV_OS", copy_from_platform=None)

        self.assertEqual(submit_app_store_review.namespace_copy_from_platform(args), "TV_OS")

    def test_copy_from_platform_can_select_existing_cross_platform_metadata(self):
        args = SimpleNamespace(platform="TV_OS", copy_from_platform="MAC_OS")

        self.assertEqual(submit_app_store_review.namespace_copy_from_platform(args), "MAC_OS")


class PaginationTests(unittest.TestCase):
    def test_paginated_get_follows_next_link_query_parameters(self):
        class CursorClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if params and params.get("cursor") == "next-page":
                    return {
                        "data": [{"id": "second"}],
                        "included": [{"id": "included-second"}],
                    }
                return {
                    "data": [{"id": "first"}],
                    "included": [{"id": "included-first"}],
                    "links": {
                        "next": "https://api.appstoreconnect.apple.com/v1/other-things?cursor=next-page&limit=50"
                    },
                }

        client = CursorClient()

        payload = submit_app_store_review.paginated_get(client, "/things", {"filter[app]": "app-id"})

        self.assertEqual([item["id"] for item in payload["data"]], ["first", "second"])
        self.assertEqual([item["id"] for item in payload["included"]], ["included-first", "included-second"])
        self.assertEqual(client.requests[1][1], "/other-things")
        self.assertEqual(client.requests[0][2], {"filter[app]": "app-id", "limit": 50})
        self.assertEqual(client.requests[1][2], {"cursor": "next-page", "limit": "50"})

    def test_asc_client_wraps_url_error(self):
        client = submit_app_store_review.ASCClient("token")

        with patch.object(
            submit_app_store_review.urllib.request,
            "urlopen",
            side_effect=urllib.error.URLError("offline"),
        ):
            with self.assertRaisesRegex(
                submit_app_store_review.AppStoreConnectError,
                "App Store Connect request failed: GET /apps",
            ):
                client.request("GET", "/apps")


class RemoveActiveReviewVersionTests(unittest.TestCase):
    def test_validate_args_mode_and_tvos_demo_rules(self):
        cancel = {"cancel_review_only": True, "remove_active_review_version": "1.0.13", "build_number": None}
        prepare = {"cancel_review_only": False, "remove_active_review_version": None, "build_number": None,
                   "whats_new": "Fixes", "prepare_only": True}
        tvos = {"cancel_review_only": False, "remove_active_review_version": None, "build_number": "202607241933",
                "whats_new": "Adds the Apple TV companion.", "prepare_only": False, "platform": "TV_OS",
                "review_notes": "The app uses a Mac-published CloudKit snapshot."}
        demo_url = "https://example.com/physical-apple-tv-demo.mp4"
        # name: (arguments, refusal or None when accepted)
        cases = {
            "cancel-only without build metadata": (
                {**cancel, "whats_new": None, "prepare_only": False, "platform": "TV_OS", "review_notes": None,
                 "tvos_demo_video_url": None}, None,
            ),
            "cancel-only without target": (
                {**cancel, "remove_active_review_version": None, "whats_new": None, "prepare_only": False},
                "--remove-active-review-version",
            ),
            "normal review without build": ({**prepare, "prepare_only": False}, "--build-number"),
            "prepare-only without build": (prepare, None),
            "prepare-only without release notes": ({**prepare, "whats_new": None}, "--whats-new"),
            "prepare-only with cancel-only": ({**cancel, "whats_new": "Fixes", "prepare_only": True}, "mutually exclusive"),
            "prepare-only reusing a version": ({**prepare, "remove_active_review_version": "1.0.13"}, None),
            "tvOS without demo video": ({**tvos, "tvos_demo_video_url": None, "dry_run": True}, None),
            "tvOS demo video over HTTP": (
                {**tvos, "tvos_demo_video_url": "http://example.com/physical-apple-tv-demo.mp4"}, "valid HTTPS URL",
            ),
            "blank tvOS demo video": ({**tvos, "tvos_demo_video_url": "   "}, "valid HTTPS URL"),
            "demo video for another platform": (
                {**tvos, "platform": "IOS", "review_notes": "Physical iPhone demo.", "tvos_demo_video_url": demo_url},
                "only valid with --platform TV_OS",
            ),
            "structured tvOS demo video": ({**tvos, "tvos_demo_video_url": demo_url, "dry_run": True}, None),
        }
        for name, (arguments, refusal) in cases.items():
            with self.subTest(name):
                args = SimpleNamespace(**arguments)
                if refusal is None:
                    submit_app_store_review.validate_args(args)
                else:
                    with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
                        submit_app_store_review.validate_args(args)
                    self.assertIn(refusal, str(context.exception))

    def test_effective_review_notes_prepends_standardized_tvos_evidence(self):
        args = SimpleNamespace(
            platform="TV_OS",
            review_notes="No demo account or tvOS permission prompt is required.",
            tvos_demo_video_url="https://example.com/physical-apple-tv-demo.mp4",
        )

        self.assertEqual(
            submit_app_store_review.effective_review_notes(args),
            "Physical Apple TV demo (reviewer-accessible, no login required):\n"
            "https://example.com/physical-apple-tv-demo.mp4\n\n"
            "No demo account or tvOS permission prompt is required.",
        )

    def test_effective_review_notes_clears_copied_tvos_notes_without_current_override(self):
        args = SimpleNamespace(
            platform="TV_OS",
            review_notes=None,
            tvos_demo_video_url=None,
        )

        self.assertEqual(submit_app_store_review.effective_review_notes(args), "")

    def test_effective_review_notes_keeps_current_tvos_notes_without_demo_video(self):
        args = SimpleNamespace(
            platform="TV_OS",
            review_notes="No demo account or tvOS permission prompt is required.",
            tvos_demo_video_url=None,
        )

        self.assertEqual(
            submit_app_store_review.effective_review_notes(args),
            "No demo account or tvOS permission prompt is required.",
        )

    def test_deletes_matching_item(self):
        client = FakeASCClient()

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

        self.assertEqual(client.deleted_paths, ["/reviewSubmissionItems/item-1"])

    def test_removes_submitted_review_item_without_canceling_owner(self):
        client = SubmittedReviewItemClient()

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

        mutations = [(request[0], request[1]) for request in client.requests if request[0] in {"DELETE", "PATCH"}]
        self.assertEqual(
            mutations,
            [
                ("DELETE", "/reviewSubmissionItems/item-1"),
                ("PATCH", "/reviewSubmissionItems/item-1"),
            ],
        )
        patch_body = client.requests[-1][3]
        self.assertEqual(patch_body["data"]["attributes"], {"removed": True})

    def test_cancels_only_exact_sole_item_and_reads_back_before_returning(self) -> None:
        for platform in ("MAC_OS", "IOS", "VISION_OS", "TV_OS"):
            with self.subTest(platform=platform):
                client = SubmittedReviewItemBlockedBySubmissionStateClient()
                submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13", platform)
                operations = [(r[0], r[1]) for r in client.requests]
                self.assertEqual(operations[-4:], [
                    ("GET", "/reviewSubmissions/submission-1/items"),
                    ("PATCH", "/reviewSubmissions/submission-1"),
                    ("GET", "/reviewSubmissions/submission-1"),
                    ("GET", "/appStoreVersions/version-1-0-13"),
                ])
                self.assertEqual(client.requests[-3][3]["data"]["attributes"], {"canceled": True})
                for request in client.requests:
                    if request[1] in {"/reviewSubmissions", "/apps/app-id/appStoreVersions"}:
                        self.assertEqual(request[2]["filter[platform]"], platform)

    def test_refuses_owner_cancellation_for_any_other_item_mix(self) -> None:
        target = {"id": "item-1", "relationships": {"appStoreVersion": {
            "data": {"type": "appStoreVersions", "id": "version-1-0-13"},
        }}}
        other = {"id": "other", "relationships": {"appStoreVersion": {
            "data": {"type": "appStoreVersions", "id": "other-version"},
        }}}
        for items in ([], [other], [{"id": "item-1"}], [target, other], [target, {"id": "event"}], [target, target]):
            with self.subTest(items=items):
                client = SubmittedReviewItemBlockedBySubmissionStateClient(items=items)
                with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                    submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
                self.assertFalse(any(r[0] == "PATCH" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests))

    def test_unconfirmed_cancel_stops_after_one_write(self) -> None:
        client = SubmittedReviewItemBlockedBySubmissionStateClient(cancel_state="WAITING_FOR_REVIEW")
        with patch.object(time, "monotonic", side_effect=(0, submit_app_store_review.DEFAULT_VERSION_UNLOCK_WAIT_TIMEOUT_SECONDS + 1)):
            with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
        self.assertEqual(sum(r[0] == "PATCH" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests), 1)
        self.assertEqual(client.requests[-1][:2], ("GET", "/reviewSubmissions/submission-1"))

    def test_missing_canceled_submission_requires_exact_withdrawn_version(self) -> None:
        for status, state, accepted in (
            (404, "DEVELOPER_REJECTED", True),
            (404, "WAITING_FOR_REVIEW", False),
            (404, "READY_FOR_SALE", False),
            (403, "DEVELOPER_REJECTED", False),
            (500, "DEVELOPER_REJECTED", False),
        ):
            with self.subTest(status=status, state=state):
                client = SubmittedReviewItemBlockedBySubmissionStateClient(withdrawn_state=state, cancel_read_status=status)
                with patch.object(time, "monotonic", side_effect=(0, submit_app_store_review.DEFAULT_VERSION_UNLOCK_WAIT_TIMEOUT_SECONDS + 1)):
                    if accepted:
                        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
                    else:
                        with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                            submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
                self.assertEqual(sum(r[0] == "PATCH" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests), 1)
                if accepted:
                    self.assertEqual(client.requests[-1][:2], ("GET", "/appStoreVersions/version-1-0-13"))

    def test_completed_review_without_withdrawn_version_stops(self) -> None:
        for state in ("WAITING_FOR_REVIEW", "READY_FOR_SALE"):
            with self.subTest(state=state):
                client = SubmittedReviewItemBlockedBySubmissionStateClient(withdrawn_state=state)
                with patch.object(time, "monotonic", side_effect=(0, submit_app_store_review.DEFAULT_VERSION_UNLOCK_WAIT_TIMEOUT_SECONDS + 1)):
                    with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
                self.assertEqual(client.requests[-1][:2], ("GET", "/appStoreVersions/version-1-0-13"))

    def test_dry_run_reads_sole_item_scope_without_mutations(self) -> None:
        for items in (None, [{"id": "event"}]):
            with self.subTest(items=items):
                client = SubmittedReviewItemBlockedBySubmissionStateClient(items=items)
                output = io.StringIO()
                with redirect_stdout(output):
                    submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13", dry_run=True)
                self.assertIn(("GET", "/reviewSubmissions/submission-1/items"), [(r[0], r[1]) for r in client.requests])
                self.assertFalse(any(r[0] != "GET" for r in client.requests))

    def test_second_page_item_prevents_whole_submission_cancellation(self) -> None:
        client = SubmittedReviewItemBlockedBySubmissionStateClient()
        request = client.request

        def paged_request(method: str, path: str, params: dict[str, Any] | None = None,
                          body: dict[str, Any] | None = None, allowed: tuple[int, ...] = (200,)) -> dict[str, Any]:
            if path == "/reviewSubmissions/submission-1/items":
                if params and "cursor" in params:
                    return {"data": [{"id": "event"}]}
                page: dict[str, Any] = request(method, path, params, body, allowed)
                page["links"] = {"next": "https://api.appstoreconnect.apple.com/v1/reviewSubmissions/submission-1/items?cursor=next"}
                return page
            return request(method, path, params, body, allowed)

        with patch.object(client, "request", side_effect=paged_request):
            with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
        self.assertFalse(any(r[0] == "PATCH" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests))

    def test_cancellation_waits_for_complete_after_canceling(self) -> None:
        client = SubmittedReviewItemBlockedBySubmissionStateClient()
        request = client.request
        states = iter(("CANCELING", "COMPLETE", "COMPLETE"))
        version_states = iter(("WAITING_FOR_REVIEW", "DEVELOPER_REJECTED"))

        def cancellation_request(method: str, path: str, params: dict[str, Any] | None = None,
                                 body: dict[str, Any] | None = None, allowed: tuple[int, ...] = (200,)) -> dict[str, Any]:
            if method == "GET" and path == "/reviewSubmissions/submission-1":
                client.cancel_state = next(states)
            if method == "GET" and path == "/appStoreVersions/version-1-0-13":
                client.withdrawn_state = next(version_states)
            return request(method, path, params, body, allowed)

        with patch.object(client, "request", side_effect=cancellation_request), patch.object(time, "sleep"):
            submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
        self.assertEqual(sum(r[0] == "GET" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests), 3)

    def test_dry_run_does_not_delete(self):
        client = FakeASCClient()

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13", dry_run=True)

        self.assertEqual(client.deleted_paths, [])

    def test_dry_run_cancels_orphan_ready_for_sale_review_draft(self):
        client = OrphanReadyForReviewClient()
        output = io.StringIO()

        with redirect_stdout(output):
            submit_app_store_review.remove_active_review_version(
                client,
                "app-id",
                "1.0.13",
                platform="IOS",
                dry_run=True,
            )

        self.assertIn("would cancel App Store version 1.0.13 review submission", output.getvalue())
        self.assertFalse(any(request[0] in {"DELETE", "PATCH"} for request in client.requests))

    def test_apply_cancels_orphan_ready_for_sale_review_draft(self):
        client = OrphanReadyForReviewClient()

        submit_app_store_review.remove_active_review_version(
            client,
            "app-id",
            "1.0.13",
            platform="IOS",
        )

        mutations = [request for request in client.requests if request[0] in {"DELETE", "PATCH"}]
        self.assertEqual([(request[0], request[1]) for request in mutations], [
            ("PATCH", "/reviewSubmissions/orphan-submission"),
        ])
        self.assertEqual(mutations[0][3]["data"]["attributes"], {"canceled": True})

    def test_active_review_ids_ignore_orphan_ready_for_sale_review_draft(self):
        client = OrphanReadyForReviewClient()

        version_ids = submit_app_store_review.active_review_version_ids(client, "app-id", "TV_OS")

        self.assertEqual(version_ids, set())

    def test_active_review_ids_keep_direct_draft_for_non_live_version(self):
        client = OrphanReadyForReviewClient(app_store_state="WAITING_FOR_REVIEW")

        version_ids = submit_app_store_review.active_review_version_ids(client, "app-id", "TV_OS")

        self.assertEqual(version_ids, {"version-1-0-13"})

    def test_deletes_when_submission_version_relationship_is_missing(self):
        client = FakeASCClient(include_submission_version=False)

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

        self.assertEqual(client.deleted_paths, ["/reviewSubmissionItems/item-1"])

    def test_raises_when_blocking_version_has_no_matching_submission_item(self):
        for state, app_version_state in (
            ("WAITING_FOR_REVIEW", None), ("UNRESOLVED_ISSUES", None), (None, "WAITING_FOR_REVIEW"),
        ):
            with self.subTest(app_store_state=state, app_version_state=app_version_state):
                client = FakeASCClient(
                    include_submission_version=False,
                    include_item_version=False,
                    app_store_state=state,
                    app_version_state=app_version_state,
                )

                with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
                    submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

                self.assertIn(state or app_version_state, str(context.exception))

    def test_dry_run_build_check_does_not_patch_encryption(self):
        class BuildClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/builds":
                    return valid_build(uses_non_exempt_encryption=None)
                raise AssertionError(f"unexpected request: {method} {path}")

        client = BuildClient()
        args = SimpleNamespace(version="1.0.39", build_number="202606021931", non_exempt_encryption=False)

        submit_app_store_review.ensure_build(client, "app-id", args, allow_updates=False)

        self.assertEqual([request[0] for request in client.requests], ["GET"])

    def test_ensure_build_rejects_mismatched_marketing_version(self):
        class BuildClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/builds":
                    return valid_build(
                        uses_non_exempt_encryption=False,
                        platform="IOS",
                        marketing_version="1.0.36",
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.39", build_number="202606262249", non_exempt_encryption=False, platform="IOS")

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.ensure_build(BuildClient(), "app-id", args, allow_updates=False)

        self.assertIn("build 202606262249 belongs to marketing version 1.0.36", str(context.exception))
        self.assertIn("not 1.0.39", str(context.exception))

    def test_ensure_build_selects_matching_marketing_version_when_same_build_number_is_reused(self):
        class BuildClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/builds":
                    return build_payload(
                        [
                            {
                                "build_id": "stale-build",
                                "platform": "IOS",
                                "marketing_version": "1.0.36",
                                "uses_non_exempt_encryption": False,
                            },
                            {
                                "build_id": "target-build",
                                "platform": "IOS",
                                "marketing_version": "1.0.39",
                                "uses_non_exempt_encryption": False,
                            },
                        ]
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.39", build_number="202606262249", non_exempt_encryption=False, platform="IOS")

        build = submit_app_store_review.ensure_build(BuildClient(), "app-id", args, allow_updates=False)

        self.assertEqual(build["id"], "target-build")

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_ensure_build_polls_until_uploaded_build_is_valid(self, _sleep):
        class PollingBuildClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/builds":
                    call_count = len([request for request in self.requests if request[1] == "/builds"])
                    if call_count == 1:
                        return {"data": []}
                    if call_count == 2:
                        return valid_build(state="PROCESSING")
                    return valid_build(uses_non_exempt_encryption=False)
                raise AssertionError(f"unexpected request: {method} {path}")

        client = PollingBuildClient()
        args = SimpleNamespace(version="1.0.39", build_number="202606071340", non_exempt_encryption=False)

        build = submit_app_store_review.ensure_build(
            client,
            "app-id",
            args,
            wait_timeout_seconds=60,
            poll_seconds=1,
        )

        self.assertEqual(build["id"], "build-1")
        self.assertEqual(len([request for request in client.requests if request[1] == "/builds"]), 3)

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    @patch.object(submit_app_store_review.time, "monotonic", side_effect=[0, 0, 10])
    def test_ensure_build_times_out_when_uploaded_build_is_missing(self, _monotonic, _sleep):
        class MissingBuildClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/builds":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(build_number="202606071340", non_exempt_encryption=False)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.ensure_build(
                MissingBuildClient(),
                "app-id",
                args,
                wait_timeout_seconds=1,
                poll_seconds=1,
            )

        self.assertIn("missing MAC_OS build 202606071340", str(context.exception))

    def test_dry_run_version_path_reports_or_refuses_version_state(self):
        def version(version_string, state):
            return {
                "id": "version-" + version_string.replace(".", "-"),
                "attributes": {"versionString": version_string, "appStoreState": state},
            }

        class VersionPathClient:
            """Serves versions by versionString filter (None: the unfiltered list) and one optional review."""

            def __init__(self, versions, review):
                self.versions = versions
                self.review = review

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    return {"data": [version(*item) for item in self.versions.get(version_string, [])]}
                if method == "GET" and path == "/reviewSubmissions":
                    if self.review is None:
                        return {"data": []}
                    state, version_string = self.review
                    target = {"type": "appStoreVersions", "id": "version-" + version_string.replace(".", "-")}
                    return {"data": [{
                        "id": "submission-1",
                        "attributes": {"state": state},
                        "relationships": {"appStoreVersionForReview": {"data": target}, "items": {"data": []}},
                    }]}
                raise AssertionError(f"unexpected request: {method} {path}")

        target = {"version": "1.0.14", "remove_active_review_version": None}
        replace_13 = {"version": "1.0.14", "remove_active_review_version": "1.0.13"}
        removable = {"removable_review_version": "1.0.13"}
        waiting_13 = ("1.0.13", "WAITING_FOR_REVIEW")
        # name: (args, versions by filter, active review, call options, refused, expected text, absent text)
        cases = {
            "existing target": (
                target, {"1.0.14": [("1.0.14", "PREPARE_FOR_SUBMISSION")]}, None, {}, False,
                ("would use App Store version 1.0.14",), (),
            ),
            "missing target without active review": (
                target, {}, None, {}, False, ("would create App Store version 1.0.14",), (),
            ),
            "unrelated active review": (
                target, {}, ("WAITING_FOR_REVIEW", "1.0.13"), {}, True,
                ("another App Store version is already in review",), (),
            ),
            "ready-for-review submission": (
                target, {}, ("READY_FOR_REVIEW", "1.0.13"), {}, True,
                ("another App Store version is already in review",), (),
            ),
            "named blocking active review": (
                target, {None: [waiting_13]}, ("WAITING_FOR_REVIEW", "1.0.13"), {}, True,
                ("1.0.13 (WAITING_FOR_REVIEW)", "--remove-active-review-version"), (),
            ),
            "withdrawn source permits exact replacement": (
                {**replace_13, "prepare_only": False, "build_number": "new-build"},
                {None: [("1.0.13", "DEVELOPER_REJECTED")], "1.0.13": [("1.0.13", "DEVELOPER_REJECTED")]}, None, {}, False, (), (),
            ),
            "withdrawn source still has an active owner": (
                {**replace_13, "prepare_only": False, "build_number": "new-build"},
                {None: [("1.0.13", "DEVELOPER_REJECTED")], "1.0.13": [("1.0.13", "DEVELOPER_REJECTED")]},
                ("WAITING_FOR_REVIEW", "1.0.13"), {}, True, (), (),
            ),
            "rejected replacement for review submission": (
                {**replace_13, "prepare_only": False}, {"1.0.13": [("1.0.13", "REJECTED")]}, None, {}, True,
                (), (),
            ),
            "rejected replacement for prepare-only": (
                {**replace_13, "prepare_only": True}, {"1.0.13": [("1.0.13", "DEVELOPER_REJECTED")]}, None, {}, False,
                ("apply mode can reuse 1.0.13",), (),
            ),
            "fresh prepare-only beside rejected version": (
                {**target, "prepare_only": True}, {None: [("1.0.13", "REJECTED")]}, None, {}, False,
                ("would create App Store version 1.0.14",), (),
            ),
            "locked replacement": (
                replace_13, {"1.0.13": [waiting_13]}, None, {}, True, ("still WAITING_FOR_REVIEW",), (),
            ),
            "removable active replacement": (
                replace_13, {"1.0.13": [waiting_13]}, ("WAITING_FOR_REVIEW", "1.0.13"), removable, False,
                ("apply mode can reuse 1.0.13",), (),
            ),
            "ready-for-sale replacement": (
                replace_13, {"1.0.13": [("1.0.13", "READY_FOR_SALE")]}, None, removable, True,
                ("still READY_FOR_SALE",), (),
            ),
            "unrelated prepare-for-submission version": (
                target, {None: [("1.0.13", "PREPARE_FOR_SUBMISSION")]}, None, {}, True,
                ("1.0.13 is PREPARE_FOR_SUBMISSION", "--remove-active-review-version 1.0.13"), (),
            ),
            "unrelated pending release version": (
                target, {None: [("1.0.13", "PENDING_DEVELOPER_RELEASE")]}, None, {}, True,
                ("1.0.13 is PENDING_DEVELOPER_RELEASE", "release or reject that version"), (),
            ),
            "blocking rejected version": (
                {"version": "1.0.40", "remove_active_review_version": None},
                {None: [("1.0.39", "REJECTED")]}, None, {}, True,
                ("1.0.39 is REJECTED", "prepare the next marketing version"), ("reuse it as the replacement",),
            ),
            "locked target version": (
                {**target, "build_number": "202606062346"},
                {None: [("1.0.14", "WAITING_FOR_REVIEW")], "1.0.14": [("1.0.14", "WAITING_FOR_REVIEW")]},
                ("WAITING_FOR_REVIEW", "1.0.14"), {}, True, ("cannot attach build 202606062346",), (),
            ),
            "rejected target version": (
                {"version": "1.0.39", "build_number": "202606262249", "remove_active_review_version": None},
                {"1.0.39": [("1.0.39", "REJECTED")]}, None, {}, True,
                ("do not resubmit a rejected release candidate",), (),
            ),
        }
        for name, (args, versions, review, options, refused, expected, absent) in cases.items():
            with self.subTest(name):
                client = VersionPathClient(versions, review)
                output = io.StringIO()
                with redirect_stdout(output):
                    if refused:
                        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
                            submit_app_store_review.dry_run_version_path(
                                client, "app-id", SimpleNamespace(**args), **options,
                            )
                        message = str(context.exception)
                    else:
                        submit_app_store_review.dry_run_version_path(
                            client, "app-id", SimpleNamespace(**args), **options,
                        )
                        message = output.getvalue()
                for text in expected:
                    self.assertIn(text, message)
                for text in absent:
                    self.assertNotIn(text, message)

    def test_dry_run_version_path_rejects_blocking_version_on_second_page(self):
        class PagedBlockingVersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    offset = params.get("offset") if params else None
                    if version_string == "1.0.14":
                        return {"data": []}
                    if offset:
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-13",
                                    "attributes": {
                                        "versionString": "1.0.13",
                                        "appStoreState": "PREPARE_FOR_SUBMISSION",
                                    },
                                }
                            ]
                        }
                    return {
                        "data": [
                            {
                                "id": "version-1-0-12",
                                "attributes": {
                                    "versionString": "1.0.12",
                                    "appStoreState": "READY_FOR_SALE",
                                },
                            }
                        ],
                        "links": {"next": "https://api.appstoreconnect.apple.com/v1/apps/app-id/appStoreVersions?offset=1"},
                    }
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version=None)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.dry_run_version_path(PagedBlockingVersionClient(), "app-id", args)

        self.assertIn("1.0.13 is PREPARE_FOR_SUBMISSION", str(context.exception))

    def test_ensure_version_rejects_rejected_target_version(self):
        class RejectedVersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    return {
                        "data": [
                            {
                                "id": "version-1-0-39",
                                "attributes": {"versionString": "1.0.39", "appStoreState": "REJECTED"},
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(
            version="1.0.39",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
        )

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.ensure_version(RejectedVersionClient(), "app-id", args)

        self.assertIn("Prepare the next marketing version", str(context.exception))

    def test_supersede_run_force_prepares_existing_replacement_version(self):
        class ExistingReplacementClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    return {
                        "data": [
                            {
                                "id": "version-1-0-14",
                                "attributes": {"versionString": "1.0.14", "appStoreState": "PREPARE_FOR_SUBMISSION"},
                            }
                        ]
                    }
                if method == "PATCH" and path == "/appStoreVersions/version-1-0-14":
                    return {"data": {"id": "version-1-0-14"}}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(
            version="1.0.14",
            remove_active_review_version="1.0.13",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
        )

        version, force_prepare = submit_app_store_review.ensure_replacement_version(
            ExistingReplacementClient(),
            "app-id",
            args,
        )

        self.assertEqual(version["id"], "version-1-0-14")
        self.assertTrue(force_prepare)

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_prepare_only_can_reuse_rejected_version_without_review_removal(self, _sleep):
        class RejectedReuseClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if path.startswith("/reviewSubmission"):
                    raise AssertionError(f"prepare-only reuse should not touch review endpoint: {method} {path}")
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string == "1.0.38":
                        return {"data": []}
                    if version_string == "1.0.36":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-36",
                                    "attributes": {"versionString": "1.0.36", "appStoreState": "REJECTED"},
                                }
                            ]
                        }
                    raise AssertionError(f"unexpected version query: {params}")
                if method == "POST" and path == "/appStoreVersions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /appStoreVersions",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "code": "STATE_ERROR",
                                    "detail": "You cannot create a new version of the App in the current state.",
                                }
                            ]
                        },
                    )
                if method == "PATCH" and path == "/appStoreVersions/version-1-0-36":
                    assert body is not None
                    return {
                        "data": {
                            "id": "version-1-0-36",
                            "attributes": body["data"]["attributes"],
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = RejectedReuseClient()
        args = SimpleNamespace(
            version="1.0.38",
            remove_active_review_version="1.0.36",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
            prepare_only=True,
        )

        version, reused_removed_version = submit_app_store_review.ensure_replacement_version(client, "app-id", args)

        self.assertEqual(version["id"], "version-1-0-36")
        self.assertTrue(reused_removed_version)
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        self.assertEqual(patch_body["data"]["attributes"]["versionString"], "1.0.38")
        review_paths = [request[1] for request in client.requests if request[1].startswith("/reviewSubmission")]
        self.assertEqual(review_paths, [])

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_review_submission_cannot_reuse_rejected_version_without_prepare_only(self, _sleep):
        class RejectedReuseClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string == "1.0.38":
                        return {"data": []}
                    if version_string == "1.0.36":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-36",
                                    "attributes": {"versionString": "1.0.36", "appStoreState": "REJECTED"},
                                }
                            ]
                        }
                    raise AssertionError(f"unexpected version query: {params}")
                if method == "POST" and path == "/appStoreVersions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /appStoreVersions",
                        status=409,
                        payload={"errors": [{"detail": "You cannot create a new version of the App in the current state."}]},
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(
            version="1.0.38",
            remove_active_review_version="1.0.36",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
            prepare_only=False,
        )

        with self.assertRaises(submit_app_store_review.AppStoreConnectError):
            submit_app_store_review.ensure_replacement_version(RejectedReuseClient(), "app-id", args)


    def test_live_replacement_reuses_only_named_withdrawn_source_with_new_build_and_no_review(self) -> None:
        class WithdrawnClient:
            def __init__(self, withdrawn_state: str, has_active_owner: bool) -> None:
                self.state = withdrawn_state
                self.active = has_active_owner
                self.current_version = "old"
                self.attached_build = "old-build"
                self.owner_state = "WAITING_FOR_REVIEW"
                self.patches: list[dict[str, Any]] = []
                self.build_patches = 0
                self.submitted_owners = 0
                self.retained_old = False
                self.submissions: dict[str, Any] | None = None
                self.items: dict[str, list[dict[str, Any]]] = {"owner": [{
                    "id": "item", "relationships": {"appStoreVersion": {"data": {"id": "old-id"}}},
                }]}

            def version(self) -> dict[str, Any]:
                return {"id": "old-id", "attributes": {"versionString": self.current_version, "appStoreState": self.state},
                        "relationships": {"build": {"data": {"id": self.attached_build}}}}

            def request(self, method: str, path: str, params: dict[str, Any] | None = None,
                        body: dict[str, Any] | None = None, **_options: Any) -> dict[str, Any]:
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    requested = params.get("filter[versionString]") if params else None
                    if requested is None or requested == self.current_version:
                        return {"data": [self.version()]}
                    if requested == "old" and self.retained_old:
                        return {"data": [{"id": "other-old", "attributes": {"versionString": "old"}}]}
                    return {"data": []}
                if method == "POST" and path == "/appStoreVersions":
                    raise submit_app_store_review.AppStoreConnectError("create blocked", status=409, payload={
                        "errors": [{"detail": "You cannot create a new version of the App in the current state."}],
                    })
                if method == "GET" and path == "/reviewSubmissions":
                    if self.submissions is not None:
                        return self.submissions
                    if not self.active:
                        return {"data": []}
                    return {"data": [{"id": "owner", "attributes": {"state": self.owner_state}, "relationships": {
                        "appStoreVersionForReview": {"data": {"type": "appStoreVersions", "id": "old-id"}},
                    }}]}
                if method == "GET" and path.startswith("/reviewSubmissions/") and path.endswith("/items"):
                    return {"data": self.items[path.split("/")[2]]}
                if method == "GET" and path == "/appStoreVersions/old-id":
                    return {"data": self.version()}
                if method == "PATCH" and path == "/appStoreVersions/old-id":
                    assert body is not None
                    self.patches.append(body)
                    self.current_version = body["data"]["attributes"].get("versionString", self.current_version)
                    return {"data": self.version()}
                if method == "PATCH" and path == "/appStoreVersions/old-id/relationships/build":
                    assert body is not None
                    self.attached_build = body["data"]["id"]
                    self.build_patches += 1
                    return {}
                if method == "PATCH" and path == "/reviewSubmissions/owner":
                    self.submitted_owners += 1
                    return {"data": {"id": "owner", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        for state, active, build, accepted in (
            ("DEVELOPER_REJECTED", False, "new-build", True),
            ("DEVELOPER_REJECTED", True, "new-build", False),
            ("DEVELOPER_REJECTED", False, None, False),
            ("REJECTED", False, "new-build", False),
            ("METADATA_REJECTED", False, "new-build", False),
            ("INVALID_BINARY", False, "new-build", False),
        ):
            with self.subTest(state=state, active=active, build=build):
                client = WithdrawnClient(state, active)
                args = SimpleNamespace(version="new", remove_active_review_version="old", build_number=build,
                                       release_type="AFTER_APPROVAL", copyright="fixture", uses_idfa=False)
                with patch.object(time, "sleep"):
                    if accepted:
                        version, _ = submit_app_store_review.ensure_replacement_version(client, "app-id", args)
                        self.assertEqual(version["attributes"]["versionString"], args.version)
                    else:
                        with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                            submit_app_store_review.ensure_replacement_version(client, "app-id", args)
                self.assertEqual(len(client.patches), int(accepted))

        args = SimpleNamespace(version="new", remove_active_review_version="old", build_number="new-build",
                               release_type="AFTER_APPROVAL", copyright="fixture", uses_idfa=False)
        client = WithdrawnClient("DEVELOPER_REJECTED", False)
        with patch.object(time, "sleep"):
            renamed, _ = submit_app_store_review.ensure_replacement_version(client, "app-id", args)
        submit_app_store_review.dry_run_version_path(client, "app-id", args)
        resumed, _ = submit_app_store_review.ensure_replacement_version(client, "app-id", args)
        self.assertEqual(resumed["id"], renamed["id"])
        build = {"id": "new-build", "attributes": {"processingState": "VALID"}}
        submit_app_store_review.attach_build(client, resumed, build, args)
        submit_app_store_review.dry_run_version_path(client, "app-id", args)
        client.active = True
        client.owner_state = "READY_FOR_REVIEW"
        resumed, _ = submit_app_store_review.ensure_replacement_version(client, "app-id", args)
        submit_app_store_review.attach_build(client, resumed, build, args)
        submit_app_store_review.dry_run_version_path(client, "app-id", args)
        submit_app_store_review.ensure_review_submission(client, "app-id", resumed["id"])
        self.assertEqual(sum("versionString" in patch_body["data"]["attributes"] for patch_body in client.patches), 1)
        self.assertEqual(client.build_patches, 1)
        self.assertEqual(client.submitted_owners, 1)

        target = {"id": "old-id", "attributes": {"versionString": "new", "appStoreState": "DEVELOPER_REJECTED"}}
        owner: dict[str, Any] = {"id": "owner", "attributes": {"state": "READY_FOR_REVIEW", "platform": "MAC_OS"},
                 "relationships": {"appStoreVersionForReview": {"data": {"id": "old-id"}}}}
        for mode in ("old exists", "missing build", "missing old", "same version", "Apple rejected", "unknown item",
                     "mixed items", "empty owner", "duplicate owners", "another owner"):
            with self.subTest(resume_refusal=mode):
                client = WithdrawnClient("DEVELOPER_REJECTED", True)
                client.current_version = "new"
                client.owner_state = "READY_FOR_REVIEW"
                options = vars(args).copy()
                if mode == "old exists":
                    client.retained_old = True
                elif mode == "missing build":
                    options["build_number"] = None
                elif mode == "missing old":
                    options["remove_active_review_version"] = None
                elif mode == "same version":
                    options["remove_active_review_version"] = "new"
                elif mode == "Apple rejected":
                    client.state = "REJECTED"
                elif mode == "unknown item":
                    client.items["owner"] = [{"id": "unknown"}]
                elif mode == "mixed items":
                    client.items["owner"].append({"id": "event"})
                elif mode == "empty owner":
                    client.items["owner"] = []
                    client.submissions = {"data": [{"id": "owner", "attributes": {"state": "READY_FOR_REVIEW"}}]}
                elif mode == "duplicate owners":
                    client.submissions = {"data": [owner, {**owner, "id": "second"}]}
                    client.items["second"] = client.items["owner"]
                elif mode == "another owner":
                    client.items["owner"] = [{"id": "other", "relationships": {"appStoreVersion": {"data": {"id": "other-id"}}}}]
                with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                    submit_app_store_review.ensure_version(client, "app-id", SimpleNamespace(**options))
                self.assertFalse(client.patches)

        client = WithdrawnClient("DEVELOPER_REJECTED", False)
        client.current_version = "new"
        client.submissions = {"data": [{**owner, "attributes": {**owner["attributes"], "platform": "IOS"}}]}
        self.assertTrue(submit_app_store_review.can_replace_withdrawn_version(client, "app-id", target, args))

        class EmptyOrphanClient(OrphanReadyForReviewClient):
            def __init__(self, authoritative_items: list[dict[str, Any]]) -> None:
                super().__init__()
                self.authoritative_items = authoritative_items

            def request(self, method: str, path: str, params: dict[str, Any] | None = None,
                        body: dict[str, Any] | None = None, allowed: tuple[int, ...] = (200,)) -> dict[str, Any]:
                if method == "GET" and path == "/reviewSubmissions/orphan-submission/items":
                    return {"data": self.authoritative_items}
                return super().request(method, path, params, body, allowed)

        for items in ([], [{"id": "gained-item"}]):
            with self.subTest(orphan_items=items):
                source = {"id": "withdrawn-id", "attributes": {"versionString": "old", "appStoreState": "DEVELOPER_REJECTED"}}
                if items:
                    with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                        submit_app_store_review.can_replace_withdrawn_version(EmptyOrphanClient(items), "app-id", source, args)
                else:
                    self.assertTrue(submit_app_store_review.can_replace_withdrawn_version(EmptyOrphanClient(items), "app-id", source, args))

    def test_failed_item_creation_cleans_only_its_still_empty_new_submission(self) -> None:
        class FailedItemClient:
            def __init__(self, result_after_failure: str) -> None:
                self.item_result = result_after_failure
                self.canceled = False
                self.failure = submit_app_store_review.AppStoreConnectError("item creation failed", status=500)

            def request(self, method: str, path: str, params: dict[str, Any] | None = None,
                        body: dict[str, Any] | None = None, **_options: Any) -> dict[str, Any]:
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "created", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise self.failure
                if method == "GET" and path == "/reviewSubmissions/created/items":
                    if self.item_result == "read failure":
                        raise submit_app_store_review.AppStoreConnectError("items read failed", status=500)
                    if self.item_result == "empty":
                        return {"data": []}
                    if self.item_result == "unknown owner":
                        return {"data": [{"id": "unknown"}]}
                    return {"data": [{"id": "created-item", "relationships": {"appStoreVersion": {"data": {"id": "target"}}}}]}
                if method == "PATCH" and path == "/reviewSubmissions/created":
                    assert body is not None
                    self.canceled = body["data"]["attributes"].get("canceled") is True
                    return {}
                raise AssertionError(f"unexpected request: {method} {path} {params}")

        for item_result in ("empty", "created item", "unknown owner", "read failure"):
            with self.subTest(item_result=item_result):
                client = FailedItemClient(item_result)
                with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
                    submit_app_store_review.ensure_review_submission(client, "app-id", "target", "VISION_OS")
                self.assertIs(context.exception, client.failure)
                self.assertEqual(client.canceled, item_result == "empty")

    def test_ensure_review_submission_reuses_existing_matching_ready_submission(self):
        class ReviewSubmissionClient:
            def __init__(self, state="READY_FOR_REVIEW"):
                self.requests: list[tuple[Any, ...]] = []
                self.state = state

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "old-submission",
                                "attributes": {"state": self.state},
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    },
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "old-item"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "old-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "GET" and path == "/reviewSubmissions/old-submission/items":
                    return {
                        "data": [
                            {
                                "id": "old-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    }
                                },
                            }
                        ]
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "PATCH" and path == "/reviewSubmissions/old-submission":
                    return {"data": {"id": "old-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-13",
        )

        self.assertEqual(submission["id"], "old-submission")
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, [])
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/old-submission"])
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        assert_review_submission_submit_body(self, patch_body)

    def test_ensure_review_submission_returns_submitted_existing_submission(self):
        class ReviewSubmissionClient:
            def __init__(self, state="WAITING_FOR_REVIEW"):
                self.requests: list[tuple[Any, ...]] = []
                self.state = state

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "old-submission",
                                "attributes": {"state": self.state},
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    },
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "old-item"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "old-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    }
                                },
                            }
                        ],
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-13",
        )

        self.assertEqual(submission["id"], "old-submission")
        mutation_methods = [request[0] for request in client.requests if request[0] in {"POST", "PATCH"}]
        self.assertEqual(mutation_methods, [])

        client = ReviewSubmissionClient(state="UNRESOLVED_ISSUES")
        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-13",
        )

        self.assertEqual(submission["id"], "old-submission")
        mutation_methods = [request[0] for request in client.requests if request[0] in {"POST", "PATCH"}]
        self.assertEqual(mutation_methods, [])

    def test_dry_run_main_returns_before_version_or_submission_mutations(self):
        class MainClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/apps":
                    return {"data": [{"id": "app-id", "attributes": {"name": "Context Panel"}}]}
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    if params and params.get("filter[versionString]") == "1.0.14":
                        raise AssertionError("dry run should not create or query target version")
                    return {
                        "data": [
                            {
                                "id": "version-1-0-13",
                                "attributes": {"versionString": "1.0.13", "appStoreState": "READY_FOR_SALE"},
                                "relationships": {
                                    "appStoreVersionLocalizations": {
                                        "data": [{"type": "appStoreVersionLocalizations", "id": "loc-1"}]
                                    },
                                    "appStoreReviewDetail": {
                                        "data": {"type": "appStoreReviewDetails", "id": "detail-1"}
                                    },
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "loc-1",
                                "type": "appStoreVersionLocalizations",
                                "attributes": {"locale": "en-US", "description": "desc", "supportUrl": "https://example.com"},
                            },
                            {
                                "id": "detail-1",
                                "type": "appStoreReviewDetails",
                                "attributes": {"contactEmail": "review@example.com"},
                            },
                        ],
                    }
                if method == "GET" and path == "/builds":
                    return valid_build(marketing_version="1.0.14")
                raise AssertionError(f"unexpected request: {method} {path}")

        client = MainClient()
        args = SimpleNamespace(
            api_key_id="key-id",
            api_issuer_id="issuer-id",
            bundle_id="com.shinycomputers.contextpanel",
            copy_from_version="1.0.13",
            build_number="202606021931",
            non_exempt_encryption=False,
            remove_active_review_version=None,
            dry_run=True,
            version="1.0.14",
            whats_new="Fixes",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
        )

        source_localization, source_review_detail = submit_app_store_review.latest_source_metadata(
            client, "app-id", args.copy_from_version
        )
        submit_app_store_review.ensure_build(client, "app-id", args, allow_updates=not args.dry_run)
        self.assertTrue(source_localization)
        self.assertTrue(source_review_detail)

        mutation_methods = [request[0] for request in client.requests if request[0] != "GET"]
        self.assertEqual(mutation_methods, [])

    def test_ensure_metadata_retries_without_locked_whats_new(self):
        class MetadataClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/appStoreVersions/version-1-0-35":
                    return {
                        "data": {
                            "id": "version-1-0-35",
                            "attributes": {"appStoreState": "PREPARE_FOR_SUBMISSION"},
                            "relationships": {
                                "appStoreVersionLocalizations": {
                                    "data": [{"type": "appStoreVersionLocalizations", "id": "loc-1"}]
                                },
                                "appStoreReviewDetail": {
                                    "data": {"type": "appStoreReviewDetails", "id": "detail-1"}
                                },
                            },
                        }
                    }
                if method == "PATCH" and path == "/appStoreVersionLocalizations/loc-1":
                    assert body is not None
                    attributes = body["data"]["attributes"]
                    if "whatsNew" in attributes:
                        raise submit_app_store_review.AppStoreConnectError(
                            "App Store Connect request failed: PATCH /appStoreVersionLocalizations/loc-1",
                            status=409,
                            payload={
                                "errors": [
                                    {
                                        "code": "STATE_ERROR",
                                        "detail": "Attribute 'whatsNew' cannot be edited at this time",
                                    }
                                ]
                            },
                        )
                    return {"data": {"id": "loc-1"}}
                if method == "PATCH" and path == "/appStoreReviewDetails/detail-1":
                    return {"data": {"id": "detail-1"}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = MetadataClient()
        args = SimpleNamespace(
            locale=None,
            support_url=None,
            whats_new="Adds CloudKit companion sync.",
            review_notes="Physical Apple TV demo: https://example.com/reviewer-demo.mp4",
        )

        submit_app_store_review.ensure_metadata(
            client,
            "version-1-0-35",
            {"locale": "en-US", "description": "desc", "keywords": "usage", "supportUrl": "https://example.com"},
            {"contactEmail": "review@example.com"},
            args,
        )

        localization_updates = []
        for request in client.requests:
            if request[0] != "PATCH" or request[1] != "/appStoreVersionLocalizations/loc-1":
                continue
            body = request[3]
            assert body is not None
            localization_updates.append(body["data"]["attributes"])
        self.assertIn("whatsNew", localization_updates[0])
        self.assertNotIn("whatsNew", localization_updates[1])
        self.assertEqual(localization_updates[1]["description"], "desc")
        review_detail_update = next(
            request[3]["data"]["attributes"]
            for request in client.requests
            if request[0] == "PATCH" and request[1] == "/appStoreReviewDetails/detail-1"
        )
        self.assertEqual(
            review_detail_update["notes"],
            "Physical Apple TV demo: https://example.com/reviewer-demo.mp4",
        )
        self.assertEqual(review_detail_update["contactEmail"], "review@example.com")

    def test_ensure_metadata_clears_copied_tvos_review_notes(self):
        class MetadataClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/appStoreVersions/version-1-0-50":
                    return {
                        "data": {
                            "id": "version-1-0-50",
                            "attributes": {"appStoreState": "PREPARE_FOR_SUBMISSION"},
                            "relationships": {
                                "appStoreVersionLocalizations": {
                                    "data": [{"type": "appStoreVersionLocalizations", "id": "loc-1"}]
                                },
                                "appStoreReviewDetail": {
                                    "data": {"type": "appStoreReviewDetails", "id": "detail-1"}
                                },
                            },
                        }
                    }
                if method == "PATCH" and path in {
                    "/appStoreVersionLocalizations/loc-1",
                    "/appStoreReviewDetails/detail-1",
                }:
                    return {"data": {"id": path.rsplit("/", maxsplit=1)[-1]}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = MetadataClient()
        args = SimpleNamespace(
            platform="TV_OS",
            tvos_demo_video_url=None,
            review_notes=None,
            locale=None,
            support_url=None,
            whats_new="Improves synced provider availability.",
        )

        submit_app_store_review.ensure_metadata(
            client,
            "version-1-0-50",
            {"locale": "en-US", "description": "desc", "supportUrl": "https://example.com"},
            {"contactEmail": "review@example.com", "notes": "Physical Apple TV demo:\nhttps://old.example/demo.mp4"},
            args,
        )

        review_detail_update = next(
            request[3]["data"]["attributes"]
            for request in client.requests
            if request[0] == "PATCH" and request[1] == "/appStoreReviewDetails/detail-1"
        )
        self.assertEqual(review_detail_update["notes"], "")
        self.assertEqual(review_detail_update["contactEmail"], "review@example.com")

    def test_prepare_only_path_does_not_create_or_submit_review(self):
        class PrepareOnlyClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if "/reviewSubmissions" in path or "/reviewSubmissionItems" in path:
                    raise AssertionError(f"prepare-only must not call review endpoint: {method} {path}")
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    return {
                        "data": [
                            {
                                "id": "version-1-0-14",
                                "attributes": {
                                    "versionString": "1.0.14",
                                    "appStoreState": "PREPARE_FOR_SUBMISSION",
                                },
                            }
                        ]
                    }
                if method == "PATCH" and path == "/appStoreVersions/version-1-0-14":
                    return {"data": {"id": "version-1-0-14"}}
                if method == "GET" and path == "/appStoreVersions/version-1-0-14":
                    return {
                        "data": {
                            "id": "version-1-0-14",
                            "attributes": {"appStoreState": "PREPARE_FOR_SUBMISSION"},
                            "relationships": {
                                "appStoreVersionLocalizations": {
                                    "data": [{"type": "appStoreVersionLocalizations", "id": "loc-1"}]
                                },
                                "appStoreReviewDetail": {
                                    "data": {"type": "appStoreReviewDetails", "id": "detail-1"}
                                },
                            },
                        }
                    }
                if method == "PATCH" and path == "/appStoreVersionLocalizations/loc-1":
                    return {"data": {"id": "loc-1"}}
                if method == "PATCH" and path == "/appStoreReviewDetails/detail-1":
                    return {"data": {"id": "detail-1"}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = PrepareOnlyClient()
        args = SimpleNamespace(
            version="1.0.14",
            remove_active_review_version=None,
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
            locale=None,
            support_url=None,
            whats_new="Fixes and improvements.",
        )

        version, _ = submit_app_store_review.ensure_replacement_version(client, "app-id", args)
        submit_app_store_review.ensure_metadata(
            client,
            version["id"],
            {"locale": "en-US", "description": "desc", "supportUrl": "https://example.com"},
            {"contactEmail": "review@example.com"},
            args,
        )

        review_paths = [
            request[1]
            for request in client.requests
            if "/reviewSubmissions" in request[1] or "/reviewSubmissionItems" in request[1]
        ]
        self.assertEqual(review_paths, [])

    def test_ensure_review_submission_does_not_reuse_empty_ready_submission(self):
        class EmptyReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "empty-submission",
                                "attributes": {"state": "READY_FOR_REVIEW", "platform": "MAC_OS"},
                                "relationships": {"items": {"data": []}},
                            }
                        ]
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    assert body is not None
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    assert body is not None
                    assert (
                        body["data"]["relationships"]["reviewSubmission"]["data"]["id"]
                        == "new-submission"
                    )
                    return {"data": {"id": "item-1"}}
                if method == "PATCH" and path == "/reviewSubmissions/new-submission":
                    return {"data": {"id": "new-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = EmptyReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-14",
            "MAC_OS",
        )

        self.assertEqual(submission["id"], "new-submission")
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, ["/reviewSubmissions", "/reviewSubmissionItems"])
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/new-submission"])
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        assert_review_submission_submit_body(self, patch_body)
        submission_post_body = next(
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissions"
        )
        self.assertEqual(submission_post_body["data"]["attributes"], {"platform": "MAC_OS"})

    def test_ensure_review_submission_does_not_reuse_cross_platform_ready_for_sale_orphan(self):
        class CrossPlatformOrphanReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    if params and "filter[platform]" in params:
                        return {"data": []}
                    return {
                        "data": [
                            {
                                "id": "cross-platform-orphan-submission",
                                "attributes": {
                                    "state": "READY_FOR_REVIEW",
                                    "platform": None,
                                    "submittedDate": None,
                                },
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "released-ios-version"}
                                    },
                                    "items": {"data": []},
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "released-ios-version",
                                "type": "appStoreVersions",
                                "attributes": {
                                    "platform": "IOS",
                                    "versionString": "1.0.48",
                                    "appStoreState": "READY_FOR_SALE",
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    assert body is not None
                    assert "appStoreVersionForReview" not in body["data"]["relationships"]
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    return {"data": {"id": "vision-item"}}
                if method == "PATCH" and path == "/reviewSubmissions/new-submission":
                    return {
                        "data": {
                            "id": "new-submission",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = CrossPlatformOrphanReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "vision-version",
        )

        self.assertEqual(submission["id"], "new-submission")
        get_params = next(request[2] for request in client.requests if request[0] == "GET")
        self.assertNotIn("filter[platform]", get_params)
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, ["/reviewSubmissions", "/reviewSubmissionItems"])

    @patch.object(submit_app_store_review, "wait_for_active_review_submission_for_version", return_value=None)
    def test_ensure_review_submission_reports_active_reviews_at_limit(self, _wait_for_owner):
        class LegitimateReviewSubmissionLimitClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "submitted-mac-review",
                                "attributes": {
                                    "state": "WAITING_FOR_REVIEW",
                                    "platform": "MAC_OS",
                                    "submittedDate": "2026-07-24T18:00:00Z",
                                },
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "mac-version"}
                                    },
                                    "items": {"data": []},
                                },
                            }
                        ],
                        "included": [],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "review submission limit exceeded",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "code": "STATE_ERROR.CONCURRENT_REVIEW_SUBMISSION_LIMIT_EXCEEDED"
                                }
                            ]
                        },
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        client = LegitimateReviewSubmissionLimitClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "inspect the active submissions",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "vision-version",
            )

        canceled_requests = [
            request
            for request in client.requests
            if request[0] == "PATCH"
        ]
        self.assertEqual(canceled_requests, [])

    @patch.object(submit_app_store_review, "wait_for_active_review_submission_for_version", return_value=None)
    def test_ensure_review_submission_rejects_ambiguous_empty_submission_at_limit(self, _wait_for_owner):
        class AmbiguousReviewSubmissionLimitClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "ownerless-submission",
                                "attributes": {"state": "READY_FOR_REVIEW", "platform": "VISION_OS"},
                                "relationships": {"items": {"data": []}},
                            }
                        ]
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "review submission limit exceeded",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "code": "STATE_ERROR.CONCURRENT_REVIEW_SUBMISSION_LIMIT_EXCEEDED"
                                }
                            ]
                        },
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        client = AmbiguousReviewSubmissionLimitClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "itemless submissions are not reused",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
                "VISION_OS",
            )

        self.assertFalse(any(request[1] == "/reviewSubmissionItems" for request in client.requests))
        self.assertFalse(any(request[0] == "PATCH" for request in client.requests))

    def test_ensure_review_submission_recovers_exact_owner_when_creation_hits_limit(self):
        class ExactOwnerReviewSubmissionLimitClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count == 1:
                        return {"data": [], "included": []}
                    return {
                        "data": [
                            {
                                "id": "winning-submission",
                                "attributes": {"state": "READY_FOR_REVIEW", "platform": "IOS"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "target-version"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "review submission limit exceeded",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "code": "STATE_ERROR.CONCURRENT_REVIEW_SUBMISSION_LIMIT_EXCEEDED"
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/winning-submission/items":
                    return {
                        "data": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "target-version"}
                                    }
                                },
                            }
                        ]
                    }
                if method == "PATCH" and path == "/reviewSubmissions/winning-submission":
                    return {
                        "data": {
                            "id": "winning-submission",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ExactOwnerReviewSubmissionLimitClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "target-version",
            "IOS",
        )

        self.assertEqual(submission["id"], "winning-submission")
        self.assertFalse(any(request[1] == "/reviewSubmissionItems" for request in client.requests))
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/winning-submission"])

    def test_ensure_review_submission_ignores_ready_submission_for_other_version(self):
        class StaleReadyReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "stale-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "stale-item"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "stale-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    return {"data": {"id": "new-item"}}
                if method == "PATCH" and path == "/reviewSubmissions/new-submission":
                    return {"data": {"id": "new-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = StaleReadyReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-14",
        )

        self.assertEqual(submission["id"], "new-submission")
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, ["/reviewSubmissions", "/reviewSubmissionItems"])
        submission_post_body = next(
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissions"
        )
        self.assertNotIn("appStoreVersionForReview", submission_post_body["data"]["relationships"])
        self.assertEqual(
            submission_post_body["data"]["relationships"]["app"],
            {"data": {"type": "apps", "id": "app-id"}},
        )

    def test_ensure_review_submission_creates_app_only_submission(self):
        class AppOnlyReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                if method == "POST" and path == "/reviewSubmissions":
                    assert body is not None
                    relationships = body["data"]["relationships"]
                    assert "appStoreVersionForReview" not in relationships
                    assert body["data"]["attributes"] == {"platform": "TV_OS"}
                    return {"data": {"id": "app-only-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    return {"data": {"id": "app-only-item"}}
                if method == "PATCH" and path == "/reviewSubmissions/app-only-submission":
                    return {"data": {"id": "app-only-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = AppOnlyReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-35",
            "TV_OS",
        )

        self.assertEqual(submission["id"], "app-only-submission")
        submission_posts = [
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissions"
        ]
        self.assertEqual(len(submission_posts), 1)
        assert submission_posts[0] is not None
        self.assertNotIn("appStoreVersionForReview", submission_posts[0]["data"]["relationships"])
        self.assertEqual(submission_posts[0]["data"]["attributes"], {"platform": "TV_OS"})
        review_item_posts = [
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissionItems"
        ]
        self.assertEqual(
            review_item_posts[0]["data"]["relationships"]["appStoreVersion"]["data"]["id"],
            "version-1-0-35",
        )

    def test_ensure_review_submission_submits_matching_ready_submission(self):
        class ReadyReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "ready-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-14"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "GET" and path == "/reviewSubmissions/ready-submission/items":
                    return {
                        "data": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-14"}
                                    }
                                },
                            }
                        ]
                    }
                if method == "PATCH" and path == "/reviewSubmissions/ready-submission":
                    return {"data": {"id": "ready-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ReadyReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-14",
        )

        self.assertEqual(submission["id"], "ready-submission")
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/ready-submission"])
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        assert_review_submission_submit_body(self, patch_body)

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_ensure_review_submission_retries_live_duplicate_item_conflict(self, _sleep):
        class ExistingItemDelayedVisibilityClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count < 3:
                        return {"data": [], "included": []}
                    return {
                        "data": [
                            {
                                "id": "winning-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-40"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "losing-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id version-1-0-40 was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/losing-submission/items":
                    return {"data": []}
                if method == "PATCH" and path == "/reviewSubmissions/losing-submission":
                    assert body is not None
                    assert body["data"]["attributes"] == {"canceled": True}
                    return {"data": {"id": "losing-submission", "attributes": {"state": "CANCELED"}}}
                if method == "PATCH" and path == "/reviewSubmissions/winning-submission":
                    return {"data": {"id": "winning-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ExistingItemDelayedVisibilityClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-40",
        )

        self.assertEqual(submission["id"], "winning-submission")
        self.assertEqual(client.review_submissions_get_count, 3)
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(
            patch_paths,
            [
                "/reviewSubmissions/losing-submission",
                "/reviewSubmissions/winning-submission",
            ],
        )

    def test_ensure_review_submission_does_not_cancel_unresolved_item_owner(self):
        class UnresolvedItemOwnerClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": [], "included": []}
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id target-version was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/new-submission/items":
                    return {
                        "data": [
                            {
                                "id": "unresolved-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {},
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = UnresolvedItemOwnerClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "ownership is unavailable",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
                "IOS",
            )

        self.assertFalse(any(request[0] == "PATCH" for request in client.requests))

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_ensure_review_submission_continues_when_losing_draft_cleanup_fails(self, _sleep):
        class CleanupFailureClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count == 1:
                        return {"data": [], "included": []}
                    return {
                        "data": [
                            {
                                "id": "winning-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "target-version"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "losing-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id target-version was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/losing-submission/items":
                    return {"data": []}
                if method == "PATCH" and path == "/reviewSubmissions/losing-submission":
                    raise urllib.error.URLError("temporary cleanup failure")
                if method == "PATCH" and path == "/reviewSubmissions/winning-submission":
                    return {
                        "data": {
                            "id": "winning-submission",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = CleanupFailureClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "target-version",
            "IOS",
        )

        self.assertEqual(submission["id"], "winning-submission")
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(
            patch_paths,
            [
                "/reviewSubmissions/losing-submission",
                "/reviewSubmissions/winning-submission",
            ],
        )

    def test_ensure_review_submission_revalidates_before_canceling_after_owner_error(self):
        class DelayedUnresolvedOwnerClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0
                self.item_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count == 1:
                        return {"data": [], "included": []}
                    return {
                        "data": [
                            {
                                "id": "created-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {
                                        "data": [
                                            {
                                                "type": "reviewSubmissionItems",
                                                "id": "late-item",
                                            }
                                        ]
                                    }
                                },
                            }
                        ],
                        "included": [],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {
                        "data": {
                            "id": "created-submission",
                            "attributes": {"state": "READY_FOR_REVIEW"},
                        }
                    }
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id target-version was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/created-submission/items":
                    self.item_get_count += 1
                    if self.item_get_count == 1:
                        return {"data": []}
                    return {
                        "data": [
                            {
                                "id": "late-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {},
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = DelayedUnresolvedOwnerClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "ownership is unavailable",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
                "IOS",
            )

        self.assertGreaterEqual(client.item_get_count, 3)
        self.assertFalse(any(request[0] == "PATCH" for request in client.requests))

    def test_ensure_review_submission_cleans_empty_draft_when_owner_discovery_transport_fails(self):
        class OwnerDiscoveryTransportFailureClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0
                self.item_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count == 1:
                        return {"data": [], "included": []}
                    raise urllib.error.URLError("offline")
                if method == "POST" and path == "/reviewSubmissions":
                    return {
                        "data": {
                            "id": "created-submission",
                            "attributes": {"state": "READY_FOR_REVIEW"},
                        }
                    }
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id target-version was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/created-submission/items":
                    self.item_get_count += 1
                    return {"data": []}
                if method == "PATCH" and path == "/reviewSubmissions/created-submission":
                    assert body is not None
                    assert body["data"]["attributes"] == {"canceled": True}
                    return {
                        "data": {
                            "id": "created-submission",
                            "attributes": {"state": "CANCELED"},
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = OwnerDiscoveryTransportFailureClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "owner discovery failed",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
                "IOS",
            )

        self.assertEqual(client.item_get_count, 2)
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/created-submission"])

    def test_wait_for_active_review_submission_for_version_returns_none_after_timeout(self):
        class InvisibleOwnerClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": [], "included": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        submission = submit_app_store_review.wait_for_active_review_submission_for_version(
            InvisibleOwnerClient(),
            "app-id",
            "version-1-0-40",
            timeout_seconds=0,
        )

        self.assertIsNone(submission)

    def test_active_review_submission_rejects_mixed_version_ownership(self):
        class NoRequestsClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                raise AssertionError(f"unexpected request: {method} {path}")

        submissions = {
            "data": [
                {
                    "id": "mixed-submission",
                    "attributes": {"state": "READY_FOR_REVIEW"},
                    "relationships": {
                        "appStoreVersionForReview": {
                            "data": {"type": "appStoreVersions", "id": "target-version"}
                        },
                        "items": {"data": [{"type": "reviewSubmissionItems", "id": "other-item"}]},
                    },
                }
            ],
            "included": [
                {
                    "id": "other-item",
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": "other-version"}
                        }
                    },
                }
            ],
        }

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "already contains another App Store version",
        ):
            submit_app_store_review.active_review_submission_for_version(
                NoRequestsClient(),
                submissions,
                "target-version",
            )

    def test_active_review_submission_rejects_multiple_exact_owners(self):
        class NoRequestsClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                raise AssertionError(f"unexpected request: {method} {path}")

        submissions = {
            "data": [
                {
                    "id": "submission-1",
                    "attributes": {"state": "READY_FOR_REVIEW"},
                    "relationships": {
                        "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                    },
                },
                {
                    "id": "submission-2",
                    "attributes": {"state": "READY_FOR_REVIEW"},
                    "relationships": {
                        "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-2"}]}
                    },
                },
            ],
            "included": [
                {
                    "id": "item-1",
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": "target-version"}
                        }
                    },
                },
                {
                    "id": "item-2",
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": "target-version"}
                        }
                    },
                },
            ],
        }

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "multiple active review submissions claim",
        ):
            submit_app_store_review.active_review_submission_for_version(
                NoRequestsClient(),
                submissions,
                "target-version",
            )

    def test_active_review_submission_resolves_missing_included_item_owner(self):
        class ItemOwnerClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions/submission-1/items":
                    return {
                        "data": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "target-version"}
                                    }
                                },
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        submissions = {
            "data": [
                {
                    "id": "submission-1",
                    "attributes": {"state": "READY_FOR_REVIEW"},
                    "relationships": {
                        "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                    },
                }
            ],
            "included": [],
        }
        client = ItemOwnerClient()

        submission = submit_app_store_review.active_review_submission_for_version(
            client,
            submissions,
            "target-version",
        )

        self.assertEqual(submission["id"], "submission-1")
        self.assertEqual(
            [request[1] for request in client.requests],
            ["/reviewSubmissions/submission-1/items"],
        )

    def test_active_review_submission_ignores_ready_for_sale_orphan(self):
        class NoRequestsClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                raise AssertionError(f"unexpected request: {method} {path}")

        submissions = {
            "data": [
                {
                    "id": "released-orphan",
                    "attributes": {
                        "state": "READY_FOR_REVIEW",
                        "platform": None,
                        "submittedDate": None,
                    },
                    "relationships": {
                        "appStoreVersionForReview": {
                            "data": {"type": "appStoreVersions", "id": "target-version"}
                        },
                        "items": {"data": []},
                    },
                }
            ],
            "included": [
                {
                    "id": "target-version",
                    "type": "appStoreVersions",
                    "attributes": {
                        "platform": "IOS",
                        "versionString": "1.0.50",
                        "appStoreState": "READY_FOR_SALE",
                    },
                }
            ],
        }

        submission = submit_app_store_review.active_review_submission_for_version(
            NoRequestsClient(),
            submissions,
            "target-version",
        )

        self.assertIsNone(submission)

    def test_ensure_review_submission_rejects_taken_version_slot(self):
        class TakenVersionSlotClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {"title": "Only one appStoreVersion can be present in reviewSubmissions."}
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/new-submission/items":
                    return {
                        "data": [
                            {
                                "id": "other-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "other-version"}
                                    }
                                },
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = TakenVersionSlotClient()

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
            )

        self.assertIn("separate review submission", str(context.exception))
        self.assertFalse(any(request[0] == "PATCH" for request in client.requests))


if __name__ == "__main__":
    unittest.main()
