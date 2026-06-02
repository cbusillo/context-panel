import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "submit-app-store-review.py"
SPEC = importlib.util.spec_from_file_location("submit_app_store_review", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
submit_app_store_review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(submit_app_store_review)


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
        if method == "GET" and path == "/appStoreVersionSubmissions":
            self.requests.append((method, path, params, body, allowed))
            return {"data": [{"id": "submitted-version-review-1"}]}
        if method == "DELETE" and path == "/appStoreVersionSubmissions/submitted-version-review-1":
            self.requests.append((method, path, params, body, allowed))
            self.canceled_paths.append(path)
            return {}
        return super().request(method, path, params, body, allowed)


class RemoveActiveReviewVersionTests(unittest.TestCase):
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
                    return {
                        "data": [
                            {
                                "id": "build-1",
                                "attributes": {
                                    "processingState": "VALID",
                                    "usesNonExemptEncryption": None,
                                },
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = BuildClient()
        args = SimpleNamespace(build_number="202606021931", non_exempt_encryption=False)

        submit_app_store_review.ensure_build(client, "app-id", args, allow_updates=False)

        self.assertEqual([request[0] for request in client.requests], ["GET"])

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
                    return {
                        "data": [
                            {
                                "id": "build-1",
                                "attributes": {"processingState": "VALID", "usesNonExemptEncryption": False},
                            }
                        ]
                    }
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


if __name__ == "__main__":
    unittest.main()
