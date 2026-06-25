import importlib.util
import io
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from typing import Any


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "submit-app-store-review.py"
SPEC = importlib.util.spec_from_file_location("submit_app_store_review", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
submit_app_store_review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(submit_app_store_review)


def assert_review_submission_submit_body(test_case, patch_body):
    test_case.assertEqual(patch_body["data"]["attributes"], {"submitted": True})
    test_case.assertNotIn("relationships", patch_body["data"])


def valid_build(build_id="build-1", state="VALID", uses_non_exempt_encryption=None, platform="MAC_OS"):
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
                "attributes": {"platform": platform},
            }
        ],
    }


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
        if method == "DELETE" and path == "/reviewSubmissionItems/item-1":
            self.deleted_paths.append(path)
            return {}
        raise AssertionError(f"unexpected request: {method} {path}")


class SubmittedReviewItemClient(FakeASCClient):
    def __init__(self):
        super().__init__()
        self.canceled_paths: list[str] = []

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        if method == "DELETE" and path == "/reviewSubmissionItems/item-1":
            raise submit_app_store_review.AppStoreConnectError(
                "App Store Connect request failed: DELETE /reviewSubmissionItems/item-1",
                status=409,
                payload={"errors": [{"detail": "Item was already submitted"}]},
            )
        if method == "GET" and path == "/appStoreVersions/version-1-0-13/relationships/appStoreVersionSubmission":
            self.requests.append((method, path, params, body, allowed))
            return {"data": {"type": "appStoreVersionSubmissions", "id": "submitted-version-review-1"}}
        if method == "DELETE" and path == "/appStoreVersionSubmissions/submitted-version-review-1":
            self.requests.append((method, path, params, body, allowed))
            self.canceled_paths.append(path)
            return {}
        return super().request(method, path, params, body, allowed)


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


class RemoveActiveReviewVersionTests(unittest.TestCase):
    def test_validate_args_allows_cancel_only_without_build_metadata(self):
        args = SimpleNamespace(
            cancel_review_only=True,
            remove_active_review_version="1.0.13",
            build_number=None,
            whats_new=None,
        )

        submit_app_store_review.validate_args(args)

    def test_validate_args_requires_cancel_target_for_cancel_only(self):
        args = SimpleNamespace(
            cancel_review_only=True,
            remove_active_review_version=None,
            build_number=None,
            whats_new=None,
        )

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.validate_args(args)

        self.assertIn("--remove-active-review-version", str(context.exception))

    def test_validate_args_requires_submission_metadata_for_normal_review(self):
        args = SimpleNamespace(
            cancel_review_only=False,
            remove_active_review_version=None,
            build_number=None,
            whats_new="Fixes",
        )

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.validate_args(args)

        self.assertIn("--build-number", str(context.exception))

    def test_deletes_matching_item(self):
        client = FakeASCClient()

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

        self.assertEqual(client.deleted_paths, ["/reviewSubmissionItems/item-1"])

    def test_cancels_submitted_version_review_when_review_item_is_already_submitted(self):
        client = SubmittedReviewItemClient()

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

        self.assertEqual(client.canceled_paths, ["/appStoreVersionSubmissions/submitted-version-review-1"])

    def test_dry_run_does_not_delete(self):
        client = FakeASCClient()

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13", dry_run=True)

        self.assertEqual(client.deleted_paths, [])

    def test_deletes_when_submission_version_relationship_is_missing(self):
        client = FakeASCClient(include_submission_version=False)

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

        self.assertEqual(client.deleted_paths, ["/reviewSubmissionItems/item-1"])

    def test_raises_when_blocking_version_has_no_matching_submission_item(self):
        client = FakeASCClient(include_submission_version=False, include_item_version=False)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError):
            submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

    def test_raises_when_only_app_version_state_is_blocking(self):
        client = FakeASCClient(
            include_submission_version=False,
            include_item_version=False,
            app_store_state=None,
            app_version_state="WAITING_FOR_REVIEW",
        )

        with self.assertRaises(submit_app_store_review.AppStoreConnectError):
            submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

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
        args = SimpleNamespace(build_number="202606021931", non_exempt_encryption=False)

        submit_app_store_review.ensure_build(client, "app-id", args, allow_updates=False)

        self.assertEqual([request[0] for request in client.requests], ["GET"])

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
        args = SimpleNamespace(build_number="202606071340", non_exempt_encryption=False)

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

    def test_reuses_removed_version_when_replacement_creation_is_blocked(self):
        class ReplacementClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string == "1.0.14":
                        return {"data": []}
                    if version_string == "1.0.13":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-13",
                                    "attributes": {
                                        "versionString": "1.0.13",
                                        "appStoreState": "DEVELOPER_REJECTED",
                                    },
                                }
                            ]
                        }
                if method == "POST" and path == "/appStoreVersions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /appStoreVersions",
                        status=409,
                        payload={"errors": [{"detail": "You cannot create a new version of the App in the current state."}]},
                    )
                if method == "PATCH" and path == "/appStoreVersions/version-1-0-13":
                    return {
                        "data": {
                            "id": "version-1-0-13",
                            "attributes": {"versionString": "1.0.14", "appStoreState": "PREPARE_FOR_SUBMISSION"},
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ReplacementClient()
        args = SimpleNamespace(
            version="1.0.14",
            remove_active_review_version="1.0.13",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
        )

        version = None
        try:
            submit_app_store_review.create_app_store_version_with_retry(
                client,
                "app-id",
                args,
                attempts=1,
                retry_seconds=0,
            )
        except submit_app_store_review.AppStoreConnectError as error:
            self.assertTrue(submit_app_store_review.is_version_creation_state_conflict(error))
            version = submit_app_store_review.reuse_removed_app_store_version(client, "app-id", "1.0.13", args)
        if version is None:
            self.fail("expected replacement version creation to be blocked")

        self.assertEqual(version["id"], "version-1-0-13")
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        self.assertEqual(patch_body["data"]["attributes"]["versionString"], "1.0.14")

    def test_dry_run_version_path_reports_existing_target_version(self):
        class VersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string is None:
                        return {"data": []}
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
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version=None)
        output = io.StringIO()

        with redirect_stdout(output):
            submit_app_store_review.dry_run_version_path(VersionClient(), "app-id", args)

        self.assertIn("would use App Store version 1.0.14", output.getvalue())

    def test_dry_run_version_path_allows_missing_target_when_no_review_is_active(self):
        class MissingVersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    return {"data": []}
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version=None)
        output = io.StringIO()

        with redirect_stdout(output):
            submit_app_store_review.dry_run_version_path(MissingVersionClient(), "app-id", args)

        self.assertIn("would create App Store version 1.0.14", output.getvalue())

    def test_dry_run_version_path_rejects_unrelated_active_review(self):
        class BlockingReviewClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    return {"data": []}
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "submission-1",
                                "attributes": {"state": "WAITING_FOR_REVIEW"},
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    },
                                    "items": {"data": []},
                                },
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version=None)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.dry_run_version_path(BlockingReviewClient(), "app-id", args)

        self.assertIn("another App Store version is already in review", str(context.exception))

    def test_dry_run_version_path_rejects_ready_for_review_submission(self):
        class ReadyForReviewClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    return {"data": []}
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "submission-1",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    },
                                    "items": {"data": []},
                                },
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version=None)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.dry_run_version_path(ReadyForReviewClient(), "app-id", args)

        self.assertIn("another App Store version is already in review", str(context.exception))

    def test_dry_run_version_path_validates_reusable_replacement_version(self):
        class ReusableVersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string is None:
                        return {"data": []}
                    if version_string == "1.0.14":
                        return {"data": []}
                    if version_string == "1.0.13":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-13",
                                    "attributes": {
                                        "versionString": "1.0.13",
                                        "appStoreState": "DEVELOPER_REJECTED",
                                    },
                                }
                            ]
                        }
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version="1.0.13")
        output = io.StringIO()

        with redirect_stdout(output):
            submit_app_store_review.dry_run_version_path(ReusableVersionClient(), "app-id", args)

        self.assertIn("apply mode can reuse 1.0.13", output.getvalue())

    def test_dry_run_version_path_rejects_locked_replacement_version(self):
        class LockedVersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string is None:
                        return {"data": []}
                    if version_string == "1.0.14":
                        return {"data": []}
                    if version_string == "1.0.13":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-13",
                                    "attributes": {
                                        "versionString": "1.0.13",
                                        "appStoreState": "WAITING_FOR_REVIEW",
                                    },
                                }
                            ]
                        }
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version="1.0.13")

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.dry_run_version_path(LockedVersionClient(), "app-id", args)

        self.assertIn("still WAITING_FOR_REVIEW", str(context.exception))

    def test_dry_run_version_path_accepts_removable_active_replacement_version(self):
        class RemovableActiveVersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string is None:
                        return {"data": []}
                    if version_string == "1.0.14":
                        return {"data": []}
                    if version_string == "1.0.13":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-13",
                                    "attributes": {
                                        "versionString": "1.0.13",
                                        "appStoreState": "WAITING_FOR_REVIEW",
                                    },
                                }
                            ]
                        }
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "submission-1",
                                "attributes": {"state": "WAITING_FOR_REVIEW"},
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    },
                                    "items": {"data": []},
                                },
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version="1.0.13")
        output = io.StringIO()

        with redirect_stdout(output):
            submit_app_store_review.dry_run_version_path(
                RemovableActiveVersionClient(),
                "app-id",
                args,
                removable_review_version="1.0.13",
            )

        self.assertIn("apply mode can reuse 1.0.13", output.getvalue())

    def test_dry_run_version_path_rejects_ready_for_sale_replacement_version(self):
        class ReadyForSaleVersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string is None:
                        return {"data": []}
                    if version_string == "1.0.14":
                        return {"data": []}
                    if version_string == "1.0.13":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-13",
                                    "attributes": {
                                        "versionString": "1.0.13",
                                        "appStoreState": "READY_FOR_SALE",
                                    },
                                }
                            ]
                        }
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version="1.0.13")

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.dry_run_version_path(
                ReadyForSaleVersionClient(),
                "app-id",
                args,
                removable_review_version="1.0.13",
            )

        self.assertIn("still READY_FOR_SALE", str(context.exception))

    def test_dry_run_version_path_rejects_unrelated_prepare_for_submission_version(self):
        class PrepareForSubmissionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string == "1.0.14":
                        return {"data": []}
                    if version_string is None:
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
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version=None)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.dry_run_version_path(PrepareForSubmissionClient(), "app-id", args)

        self.assertIn("1.0.13 is PREPARE_FOR_SUBMISSION", str(context.exception))
        self.assertIn("--remove-active-review-version 1.0.13", str(context.exception))

    def test_dry_run_version_path_rejects_unrelated_pending_release_version(self):
        class PendingReleaseClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string == "1.0.14":
                        return {"data": []}
                    if version_string is None:
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-13",
                                    "attributes": {
                                        "versionString": "1.0.13",
                                        "appStoreState": "PENDING_DEVELOPER_RELEASE",
                                    },
                                }
                            ]
                        }
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version=None)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.dry_run_version_path(PendingReleaseClient(), "app-id", args)

        self.assertIn("1.0.13 is PENDING_DEVELOPER_RELEASE", str(context.exception))
        self.assertIn("release or reject that version", str(context.exception))

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

    def test_dry_run_version_path_rejects_locked_target_version(self):
        class LockedTargetClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string is None:
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-14",
                                    "attributes": {
                                        "versionString": "1.0.14",
                                        "appStoreState": "WAITING_FOR_REVIEW",
                                    },
                                }
                            ]
                        }
                    if version_string == "1.0.14":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-14",
                                    "attributes": {
                                        "versionString": "1.0.14",
                                        "appStoreState": "WAITING_FOR_REVIEW",
                                    },
                                }
                            ]
                        }
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "submission-1",
                                "attributes": {"state": "WAITING_FOR_REVIEW"},
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-14"}
                                    },
                                    "items": {"data": []},
                                },
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", build_number="202606062346", remove_active_review_version=None)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.dry_run_version_path(LockedTargetClient(), "app-id", args)

        self.assertIn("cannot attach build 202606062346", str(context.exception))

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
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    return {"data": {"id": "new-item"}}
                if method == "PATCH" and path == "/reviewSubmissions/old-submission":
                    return {"data": {"id": "old-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ReviewSubmissionClient()
        args = SimpleNamespace(dry_run=False)

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-13",
            args,
        )

        self.assertEqual(submission["id"], "old-submission")
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, ["/reviewSubmissionItems"])
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/old-submission"])
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        assert_review_submission_submit_body(self, patch_body)

    def test_ensure_review_submission_returns_submitted_existing_submission(self):
        class ReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "old-submission",
                                "attributes": {"state": "WAITING_FOR_REVIEW"},
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
        args = SimpleNamespace(dry_run=False)

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-13",
            args,
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
                    return valid_build()
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

    def test_ensure_review_submission_reuses_empty_ready_submission(self):
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
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {"items": {"data": []}},
                            }
                        ]
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    return {"data": {"id": "item-1"}}
                if method == "PATCH" and path == "/reviewSubmissions/new-submission":
                    return {"data": {"id": "new-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = EmptyReviewSubmissionClient()
        args = SimpleNamespace(dry_run=False)

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-14",
            args,
        )

        self.assertEqual(submission["id"], "new-submission")
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, ["/reviewSubmissions", "/reviewSubmissionItems"])
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/new-submission"])
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        assert_review_submission_submit_body(self, patch_body)

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
        args = SimpleNamespace(dry_run=False)

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-14",
            args,
        )

        self.assertEqual(submission["id"], "new-submission")
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, ["/reviewSubmissions", "/reviewSubmissionItems"])
        submission_post_body = next(
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissions"
        )
        self.assertEqual(
            submission_post_body["data"]["relationships"]["appStoreVersionForReview"],
            {"data": {"type": "appStoreVersions", "id": "version-1-0-14"}},
        )

    def test_ensure_review_submission_retries_create_without_rejected_version_relationship(self):
        class CreateFallbackReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                if method == "POST" and path == "/reviewSubmissions":
                    assert body is not None
                    relationships = body["data"]["relationships"]
                    if "appStoreVersionForReview" in relationships:
                        raise submit_app_store_review.AppStoreConnectError(
                            "App Store Connect request failed: POST /reviewSubmissions",
                            status=409,
                            payload={
                                "errors": [
                                    {
                                        "code": "ENTITY_ERROR.RELATIONSHIP.NOT_ALLOWED",
                                        "detail": "The relationship 'appStoreVersionForReview' can not be included in a 'CREATE' operation",
                                        "source": {"pointer": "/data/relationships/appStoreVersionForReview"},
                                    }
                                ]
                            },
                        )
                    return {"data": {"id": "fallback-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    return {"data": {"id": "fallback-item"}}
                if method == "PATCH" and path == "/reviewSubmissions/fallback-submission":
                    return {"data": {"id": "fallback-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = CreateFallbackReviewSubmissionClient()
        args = SimpleNamespace(dry_run=False)

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-35",
            args,
        )

        self.assertEqual(submission["id"], "fallback-submission")
        submission_posts = [
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissions"
        ]
        self.assertEqual(len(submission_posts), 2)
        assert submission_posts[0] is not None
        assert submission_posts[1] is not None
        self.assertIn("appStoreVersionForReview", submission_posts[0]["data"]["relationships"])
        self.assertNotIn("appStoreVersionForReview", submission_posts[1]["data"]["relationships"])
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
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-14"}
                                    },
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
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "already exists", status=409, payload={}
                    )
                if method == "PATCH" and path == "/reviewSubmissions/ready-submission":
                    return {"data": {"id": "ready-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ReadyReviewSubmissionClient()
        args = SimpleNamespace(dry_run=False)

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-14",
            args,
        )

        self.assertEqual(submission["id"], "ready-submission")
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/ready-submission"])
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        assert_review_submission_submit_body(self, patch_body)

    def test_ensure_review_submission_adds_additional_platform_versions(self):
        class MultiPlatformReviewSubmissionClient:
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
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "mac-version"}
                                    },
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "mac-item"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "mac-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "mac-version"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissionItems":
                    assert body is not None
                    version_id = body["data"]["relationships"]["appStoreVersion"]["data"]["id"]
                    if version_id == "mac-version":
                        raise submit_app_store_review.AppStoreConnectError(
                            "already exists", status=409, payload={}
                        )
                    return {"data": {"id": f"item-{version_id}"}}
                if method == "PATCH" and path == "/reviewSubmissions/ready-submission":
                    return {"data": {"id": "ready-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = MultiPlatformReviewSubmissionClient()
        args = SimpleNamespace(dry_run=False, additional_review_version=["ios-version", "mac-version"])

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "mac-version",
            args,
        )

        self.assertEqual(submission["id"], "ready-submission")
        posted_version_ids = [
            request[3]["data"]["relationships"]["appStoreVersion"]["data"]["id"]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissionItems"
        ]
        self.assertEqual(posted_version_ids, ["mac-version", "ios-version"])


if __name__ == "__main__":
    unittest.main()
