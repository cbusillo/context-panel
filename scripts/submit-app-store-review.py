#!/usr/bin/env python3
"""Create or update an App Store version and submit it for review."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from context_panel_comparison_schema import ComparisonSchemaError, validate_current_comparison
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey

from context_panel_release_gate import (
    ReleaseEvidenceError,
    load_json_object,
    release_evidence_report_blockers,
)
from context_panel_validation import (
    RUNTIME_SURFACES,
    RuntimeEvidenceError,
    Target,
)
from context_panel_validation.runtime_evidence import expected_surface_identities_from_payloads


API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_BUNDLE_ID = "com.shinycomputers.contextpanel"
DEFAULT_COPYRIGHT = "2026 Shiny Computers Leasing LLC"
DEFAULT_RELEASE_TYPE = "AFTER_APPROVAL"
DEFAULT_RELEASE_EVIDENCE_POLICY = "Config/ContextPanelReleaseEvidencePolicy.json"
DEFAULT_SURFACE_EVIDENCE_POLICY = "Config/ContextPanelSurfacePolicy.json"
LOCKED_VERSION_STATES = {
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "PENDING_DEVELOPER_RELEASE",
    "READY_FOR_SALE",
}
ACTIVE_REVIEW_SUBMISSION_STATES = {
    "READY_FOR_REVIEW",
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "UNRESOLVED_ISSUES",
}
BLOCKING_REVIEW_VERSION_STATES = {
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "UNRESOLVED_ISSUES",
    "PENDING_DEVELOPER_RELEASE",
}
REMOVABLE_REVIEW_VERSION_STATES = {"WAITING_FOR_REVIEW", "IN_REVIEW"}
VERSION_CREATION_BLOCKING_STATES = BLOCKING_REVIEW_VERSION_STATES | {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}
REJECTED_RELEASE_CANDIDATE_STATES = {
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}
CREATE_VERSION_MAX_ATTEMPTS = 6
CREATE_VERSION_RETRY_SECONDS = 10
DEFAULT_BUILD_WAIT_TIMEOUT_SECONDS = 10 * 60
DEFAULT_BUILD_POLL_SECONDS = 20
DEFAULT_VERSION_UNLOCK_WAIT_TIMEOUT_SECONDS = 2 * 60
DEFAULT_VERSION_UNLOCK_POLL_SECONDS = 5
DEFAULT_REVIEW_ITEM_OWNER_WAIT_TIMEOUT_SECONDS = 2 * 60
DEFAULT_REVIEW_ITEM_OWNER_POLL_SECONDS = 5
DEFAULT_REVIEW_LIMIT_OWNER_WAIT_TIMEOUT_SECONDS = 20
TVOS_DEMO_NOTES_HEADING = "Physical Apple TV demo (reviewer-accessible, no login required):"
REQUIRED_RUNTIME_SURFACES_BY_PLATFORM = {
    "MAC_OS": frozenset({"macos.app", "macos.refresh-agent", "macos.widget"}),
    "IOS": frozenset(
        {
            "ios.app",
            "ios.widget",
            "ipados.app",
            "ipados.widget",
            "watchos.app",
            "watchos.complication",
        }
    ),
    "VISION_OS": frozenset({"visionos.app", "visionos.widget"}),
    "TV_OS": frozenset({"tvos.app", "tvos.top-shelf"}),
}


class AppStoreConnectError(RuntimeError):
    def __init__(self, message: str, status: int | None = None, payload: dict[str, Any] | None = None):
        super().__init__(message)
        self.status = status
        self.payload = payload


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_token(key_path: Path, key_id: str, issuer_id: str) -> str:
    private_key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    if not isinstance(private_key, EllipticCurvePrivateKey):
        raise AppStoreConnectError("App Store Connect API key must be an elliptic-curve private key")
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"}
    signing_input = (
        f"{b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    ).encode()
    signature = private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r_value, s_value = utils.decode_dss_signature(signature)
    raw_signature = r_value.to_bytes(32, "big") + s_value.to_bytes(32, "big")
    return signing_input.decode() + "." + b64url(raw_signature)


class ASCClient:
    def __init__(self, token: str):
        self.token = token

    def request(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
        allowed: tuple[int, ...] = (200,),
    ) -> dict[str, Any]:
        url = API_BASE + path
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                payload = json.loads(raw) if raw else None
                if response.status not in allowed:
                    raise AppStoreConnectError(
                        f"unexpected App Store Connect status {response.status}",
                        response.status,
                        payload,
                    )
                return payload or {}
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8", errors="replace")
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                payload = {"raw": raw}
            raise AppStoreConnectError(
                f"App Store Connect request failed: {method} {path}",
                error.code,
                payload,
            ) from error
        except (urllib.error.URLError, TimeoutError) as error:
            raise AppStoreConnectError(
                f"App Store Connect request failed: {method} {path}"
            ) from error


def required_first(payload: dict[str, Any], label: str) -> dict[str, Any]:
    data = payload.get("data") or []
    if not data:
        raise AppStoreConnectError(f"missing {label}", payload=payload)
    return data[0]


def paginated_get(
    client: ASCClient,
    path: str,
    params: dict[str, Any] | None = None,
    limit: int = 50,
) -> dict[str, Any]:
    collected: dict[str, Any] = {"data": [], "included": []}
    page_path = path
    page_params = dict(params or {})
    page_params["limit"] = limit
    while True:
        payload = client.request("GET", page_path, page_params)
        data = payload.get("data") or []
        collected["data"].extend(data)
        collected["included"].extend(payload.get("included") or [])
        next_url = payload.get("links", {}).get("next")
        if not next_url:
            break
        next_parts = urllib.parse.urlparse(next_url)
        next_query = urllib.parse.parse_qs(next_parts.query)
        if not next_query:
            break
        next_path = next_parts.path
        if next_path.startswith("/v1/"):
            page_path = next_path[3:]
        elif next_path:
            page_path = next_path
        page_params = {
            key: values if len(values) > 1 else values[0]
            for key, values in next_query.items()
        }
    return collected


def included_by_id(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in payload.get("included", [])}


def relationship_id(resource: dict[str, Any], name: str) -> str | None:
    data = resource.get("relationships", {}).get(name, {}).get("data")
    if isinstance(data, list):
        return data[0]["id"] if data else None
    if isinstance(data, dict):
        return data.get("id")
    return None


def namespace_platform(args: argparse.Namespace) -> str:
    return getattr(args, "platform", "MAC_OS")


def namespace_copy_from_platform(args: argparse.Namespace) -> str:
    return getattr(args, "copy_from_platform", None) or namespace_platform(args)


def version_state(resource: dict[str, Any]) -> str | None:
    attributes = resource.get("attributes", {})
    return attributes.get("appStoreState") or attributes.get("appVersionState")


def review_submission_item_ids(submission: dict[str, Any]) -> list[str]:
    return [
        item["id"]
        for item in submission.get("relationships", {}).get("items", {}).get("data", [])
    ]


def review_submission_version_ids(
    submission: dict[str, Any],
    included: dict[str, dict[str, Any]],
) -> set[str]:
    version_ids: set[str] = set()
    submission_version_id = relationship_id(submission, "appStoreVersionForReview")
    if submission_version_id is not None:
        version_ids.add(submission_version_id)
    for item_id in review_submission_item_ids(submission):
        item_version_id = relationship_id(included.get(item_id, {}), "appStoreVersion")
        if item_version_id is not None:
            version_ids.add(item_version_id)
    return version_ids


def is_orphan_ready_for_sale_review_draft(
    submission: dict[str, Any],
    app_store_version: dict[str, Any] | None,
) -> bool:
    attributes = submission.get("attributes", {})
    return (
        attributes.get("state") == "READY_FOR_REVIEW"
        and attributes.get("platform") is None
        and attributes.get("submittedDate") is None
        and relationship_id(submission, "appStoreVersionForReview") is not None
        and not review_submission_item_ids(submission)
        and app_store_version is not None
        and version_state(app_store_version) == "READY_FOR_SALE"
    )


def print_active_review_submissions(submissions: dict[str, Any]) -> None:
    included = included_by_id(submissions)
    print("Active App Store review submissions:")
    for submission in submissions.get("data", []):
        attributes = submission.get("attributes", {})
        state = attributes.get("state")
        if state not in ACTIVE_REVIEW_SUBMISSION_STATES:
            continue
        version_labels: list[str] = []
        for version_id in sorted(review_submission_version_ids(submission, included)):
            version = included.get(version_id, {})
            version_attributes = version.get("attributes", {})
            version_labels.append(
                " ".join(
                    part
                    for part in (
                        version_attributes.get("platform"),
                        version_attributes.get("versionString") or version_id,
                        version_state(version),
                    )
                    if part
                )
            )
        print(
            f"- {submission.get('id', '<unknown>')} state={state or '<unknown>'} "
            f"versions={','.join(version_labels) or '<none>'} "
            f"items={len(review_submission_item_ids(submission))}"
        )


def expanded_key_path(args: argparse.Namespace) -> tuple[Path, Path | None]:
    if args.api_key:
        return Path(args.api_key).expanduser(), None
    encoded_key = os.environ.get("APP_STORE_CONNECT_API_KEY_P8_BASE64", "").strip()
    if not encoded_key:
        raise AppStoreConnectError("App Store Connect API key is required")
    temporary = tempfile.NamedTemporaryFile(delete=False)
    temporary.write(base64.b64decode(encoded_key))
    temporary.flush()
    temporary.close()
    key_path = Path(temporary.name)
    key_path.chmod(0o600)
    return key_path, key_path


def latest_source_metadata(
    client: ASCClient,
    app_id: str,
    prefer_version: str | None,
    platform: str = "MAC_OS",
) -> tuple[dict[str, Any], dict[str, Any]]:
    payload = paginated_get(
        client,
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": platform,
            "include": "appStoreVersionLocalizations,appStoreReviewDetail",
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,appStoreVersionLocalizations,appStoreReviewDetail",
            "fields[appStoreVersionLocalizations]": "locale,description,keywords,marketingUrl,promotionalText,supportUrl,whatsNew",
            "fields[appStoreReviewDetails]": "contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountName,demoAccountRequired,notes",
        },
    )
    versions = payload.get("data", [])
    if not versions:
        raise AppStoreConnectError("no existing App Store versions found to copy metadata from", payload=payload)
    source = None
    if prefer_version:
        source = next((version for version in versions if version["attributes"].get("versionString") == prefer_version), None)
    if source is None:
        source = next(
            (
                version
                for version in versions
                if version_state(version) == "READY_FOR_SALE"
            ),
            versions[0],
        )
    included = included_by_id(payload)
    localization = included.get(relationship_id(source, "appStoreVersionLocalizations") or "", {}).get("attributes", {})
    review_detail = included.get(relationship_id(source, "appStoreReviewDetail") or "", {}).get("attributes", {})
    return localization, review_detail


def app_store_version(
    client: ASCClient,
    app_id: str,
    version_string: str,
    platform: str = "MAC_OS",
) -> dict[str, Any] | None:
    payload = client.request(
        "GET",
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": platform,
            "filter[versionString]": version_string,
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState",
            "limit": 1,
        },
    )
    versions = payload.get("data") or []
    return versions[0] if versions else None


def app_store_version_id(
    client: ASCClient,
    app_id: str,
    version_string: str,
    platform: str = "MAC_OS",
) -> str | None:
    version = app_store_version(client, app_id, version_string, platform)
    return version["id"] if version else None


def active_review_version_ids(client: ASCClient, app_id: str, platform: str = "MAC_OS") -> set[str]:
    submissions = paginated_get(
        client,
        "/reviewSubmissions",
        {
            "filter[app]": app_id,
            "filter[platform]": platform,
            "include": "items,appStoreVersionForReview",
            "fields[reviewSubmissions]": "platform,state,submittedDate,items,appStoreVersionForReview",
            "fields[reviewSubmissionItems]": "state,appStoreVersion",
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,platform",
        },
        limit=20,
    )
    included = included_by_id(submissions)
    version_ids: set[str] = set()
    for submission in submissions.get("data", []):
        state = submission["attributes"].get("state")
        if state not in ACTIVE_REVIEW_SUBMISSION_STATES:
            continue
        submission_version_id = relationship_id(submission, "appStoreVersionForReview")
        submission_version = included.get(submission_version_id or "")
        if is_orphan_ready_for_sale_review_draft(submission, submission_version):
            continue
        if submission_version_id:
            version_ids.add(submission_version_id)
        item_ids = review_submission_item_ids(submission)
        for item_id in item_ids:
            item_version_id = relationship_id(included.get(item_id, {}), "appStoreVersion")
            if item_version_id:
                version_ids.add(item_version_id)
    return version_ids


def app_store_versions_by_id(
    client: ASCClient,
    app_id: str,
    platform: str,
) -> dict[str, dict[str, Any]]:
    payload = paginated_get(
        client,
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": platform,
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState",
        },
    )
    return {
        version["id"]: version
        for version in payload.get("data", [])
        if isinstance(version, dict) and isinstance(version.get("id"), str)
    }


def describe_app_store_version(version: dict[str, Any] | None, fallback_id: str) -> str:
    if version is None:
        return fallback_id
    attributes = version.get("attributes", {})
    version_string = attributes.get("versionString") or fallback_id
    state = version_state(version)
    return f"{version_string} ({state})" if state else version_string


def version_creation_blocking_app_store_versions(
    client: ASCClient,
    app_id: str,
    platform: str = "MAC_OS",
) -> list[dict[str, Any]]:
    payload = paginated_get(
        client,
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": platform,
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState",
        },
    )
    return [
        version
        for version in payload.get("data", [])
        if version_state(version) in VERSION_CREATION_BLOCKING_STATES
    ]


def replacement_version_guidance(version: dict[str, Any]) -> str:
    state = version_state(version)
    version_string = version.get("attributes", {}).get("versionString") or version["id"]
    if state == "PENDING_DEVELOPER_RELEASE":
        return (
            f"App Store version {version_string} is {state}; release or reject that version in "
            "App Store Connect before submitting a replacement"
        )
    if state in {"WAITING_FOR_REVIEW", "IN_REVIEW"}:
        return (
            f"App Store version {version_string} is {state}; rerun with "
            f"--remove-active-review-version {version_string} before submitting a replacement"
        )
    if state in REJECTED_RELEASE_CANDIDATE_STATES:
        return (
            f"App Store version {version_string} is {state}; resolve the App Review rejection "
            "cause, then prepare the next marketing version and copy the approved metadata "
            "and screenshots there before submitting a replacement"
        )
    return (
        f"App Store version {version_string} is {state}; rerun with "
        f"--remove-active-review-version {version_string} to reuse it as the replacement version"
    )


def rejected_source_reuse_message(source_version_string: str, target_version_string: str, state: str | None) -> str:
    return (
        f"App Store version {source_version_string} is {state}; do not reuse it as "
        f"{target_version_string} for review submission. Run --prepare-only first to move the "
        "approved metadata, build, and screenshots onto the next marketing version, then dry-run "
        "and submit that prepared version."
    )


def remove_active_review_version(
    client: ASCClient,
    app_id: str,
    version_string: str,
    platform: str = "MAC_OS",
    dry_run: bool = False,
) -> None:
    version = app_store_version(client, app_id, version_string, platform)
    if version is None:
        print(f"No App Store version {version_string} found to remove from review")
        return
    version_id = version["id"]

    submissions = paginated_get(
        client,
        "/reviewSubmissions",
        {
            "filter[app]": app_id,
            "filter[platform]": platform,
            "include": "items,appStoreVersionForReview",
            "fields[reviewSubmissions]": "platform,state,submittedDate,items,appStoreVersionForReview",
            "fields[reviewSubmissionItems]": "state,appStoreVersion",
        },
        limit=20,
    )
    included = included_by_id(submissions)
    for submission in submissions.get("data", []):
        state = submission["attributes"].get("state")
        if state not in ACTIVE_REVIEW_SUBMISSION_STATES:
            continue
        submission_version_id = relationship_id(submission, "appStoreVersionForReview")
        if submission_version_id not in (None, version_id):
            continue
        item_ids = review_submission_item_ids(submission)
        for item_id in item_ids:
            item = included.get(item_id, {})
            item_version_id = relationship_id(item, "appStoreVersion")
            if item_version_id not in (None, version_id):
                continue
            if submission_version_id != version_id and item_version_id != version_id:
                continue
            if dry_run:
                print(f"Dry run: would remove App Store version {version_string} from review submission: {item_id}")
                return
            try:
                client.request("DELETE", f"/reviewSubmissionItems/{item_id}", allowed=(204,))
                print(f"Removed App Store version {version_string} from review submission: {item_id}")
                return
            except AppStoreConnectError as error:
                if not is_submitted_review_item_conflict(error):
                    raise
                print(f"Review item {item_id} was already submitted; removing submitted review item instead")
                try:
                    remove_submitted_review_item(client, item_id, version_string, dry_run=False)
                except AppStoreConnectError as submitted_item_error:
                    if not is_review_submission_state_invalid_for_item_removal(submitted_item_error):
                        raise
                    raise AppStoreConnectError(
                        f"App Store version {version_string} review item could not be removed because "
                        "the owning review submission is not in a removable state; cancel or resolve "
                        "that review submission in App Store Connect before retrying"
                    ) from submitted_item_error
                return
        if submission_version_id == version_id and is_orphan_ready_for_sale_review_draft(submission, version):
            cancel_review_submission(client, submission["id"], version_string, dry_run=dry_run)
            return
    state = version_state(version)
    if state in BLOCKING_REVIEW_VERSION_STATES:
        raise AppStoreConnectError(
            f"App Store version {version_string} is {state}, but no active review submission item was found to remove"
        )
    print(f"No active review submission item found for App Store version {version_string}")


def remove_submitted_review_item(
    client: ASCClient, item_id: str, version_string: str, dry_run: bool = False
) -> None:
    if dry_run:
        print(f"Dry run: would remove submitted App Store version {version_string} review item: {item_id}")
        return
    client.request(
        "PATCH",
        f"/reviewSubmissionItems/{item_id}",
        body={
            "data": {
                "type": "reviewSubmissionItems",
                "id": item_id,
                "attributes": {"removed": True},
            }
        },
    )
    print(f"Removed submitted App Store version {version_string} review item: {item_id}")


def cancel_review_submission(
    client: ASCClient, submission_id: str, version_string: str, dry_run: bool = False
) -> None:
    if dry_run:
        print(f"Dry run: would cancel App Store version {version_string} review submission: {submission_id}")
        return
    client.request(
        "PATCH",
        f"/reviewSubmissions/{submission_id}",
        body={
            "data": {
                "type": "reviewSubmissions",
                "id": submission_id,
                "attributes": {"canceled": True},
            }
        },
    )
    print(f"Canceled App Store version {version_string} review submission: {submission_id}")


def cancel_unowned_review_submission(client: ASCClient, submission_id: str) -> bool:
    try:
        client.request(
            "PATCH",
            f"/reviewSubmissions/{submission_id}",
            body={
                "data": {
                    "type": "reviewSubmissions",
                    "id": submission_id,
                    "attributes": {"canceled": True},
                }
            },
        )
    except Exception:
        print(
            f"Warning: could not cancel unowned review submission created by this run: {submission_id}",
            file=sys.stderr,
        )
        return False
    print(f"Canceled unowned review submission created by this run: {submission_id}")
    return True


def cancel_unowned_review_submission_if_still_empty(
    client: ASCClient,
    submission_id: str,
) -> bool:
    try:
        version_ids = review_submission_item_version_ids(client, submission_id)
    except Exception:
        print(
            f"Warning: could not verify that review submission is still empty; leaving it untouched: {submission_id}",
            file=sys.stderr,
        )
        return False
    if version_ids:
        print(
            f"Review submission gained an item before cleanup; leaving it untouched: {submission_id}",
            file=sys.stderr,
        )
        return False
    return cancel_unowned_review_submission(client, submission_id)


def cancel_app_store_version_submission(
    client: ASCClient, version_id: str, version_string: str, dry_run: bool = False
) -> None:
    payload = client.request(
        "GET",
        f"/appStoreVersions/{version_id}/relationships/appStoreVersionSubmission",
    )
    submission = payload.get("data")
    if not submission:
        raise AppStoreConnectError(
            f"App Store version {version_string} was already submitted, but no submitted version review was found to cancel"
        )
    submission_id = submission["id"]
    if dry_run:
        print(f"Dry run: would cancel submitted App Store version {version_string} review: {submission_id}")
        return
    client.request("DELETE", f"/appStoreVersionSubmissions/{submission_id}", allowed=(204,))
    print(f"Canceled submitted App Store version {version_string} review: {submission_id}")


def wait_for_editable_version(
    client: ASCClient,
    app_id: str,
    version_string: str,
    platform: str,
    timeout_seconds: int = DEFAULT_VERSION_UNLOCK_WAIT_TIMEOUT_SECONDS,
    poll_seconds: int = DEFAULT_VERSION_UNLOCK_POLL_SECONDS,
) -> None:
    deadline = time.monotonic() + max(0, timeout_seconds)
    while True:
        version = app_store_version(client, app_id, version_string, platform)
        if version is None:
            return
        state = version_state(version)
        if state not in LOCKED_VERSION_STATES:
            print(f"App Store version {version_string} is editable: {state}")
            return
        if time.monotonic() >= deadline:
            print(f"App Store version {version_string} is still {state}; continuing")
            return
        print(
            f"App Store version {version_string} is still {state}; "
            f"waiting {poll_seconds}s for App Store Connect to unlock it"
        )
        time.sleep(max(1, poll_seconds))


def is_version_creation_state_conflict(error: AppStoreConnectError) -> bool:
    if error.status != 409:
        return False
    text = json.dumps(error.payload or {}, sort_keys=True).lower()
    return "current state" in text or "another version" in text or "new version" in text


def is_submitted_review_item_conflict(error: AppStoreConnectError) -> bool:
    if error.status != 409:
        return False
    text = json.dumps(error.payload or {}, sort_keys=True).lower()
    return "item was already submitted" in text


def is_existing_review_item_conflict(error: AppStoreConnectError) -> bool:
    if error.status != 409:
        return False
    text = f"{error} {json.dumps(error.payload or {}, sort_keys=True)}".lower()
    return "already exists" in text or "was already added to this reviewsubmission" in text


def is_review_submission_version_slot_taken(error: AppStoreConnectError) -> bool:
    if error.status != 409:
        return False
    text = f"{error} {json.dumps(error.payload or {}, sort_keys=True)}".lower()
    return "only one appstoreversion can be present" in text


def is_review_submission_state_invalid_for_item_removal(error: AppStoreConnectError) -> bool:
    if error.status != 409:
        return False
    text = json.dumps(error.payload or {}, sort_keys=True).lower()
    return "cannot remove item" in text and "reviewsubmission" in text


def is_locked_whats_new_error(error: AppStoreConnectError) -> bool:
    if error.status != 409:
        return False
    text = json.dumps(error.payload or {}, sort_keys=True).lower()
    return "whatsnew" in text and "cannot be edited" in text


def is_review_submission_limit_exceeded(error: AppStoreConnectError) -> bool:
    if error.status not in (409, 422):
        return False
    text = json.dumps(error.payload or {}, sort_keys=True).lower()
    return "concurrent_review_submission_limit_exceeded" in text


def create_app_store_version(client: ASCClient, app_id: str, args: argparse.Namespace) -> dict[str, Any]:
    return client.request(
        "POST",
        "/appStoreVersions",
        body={
            "data": {
                "type": "appStoreVersions",
                "attributes": {
                    "platform": namespace_platform(args),
                    "versionString": args.version,
                    "releaseType": args.release_type,
                    "copyright": args.copyright,
                },
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
        allowed=(201,),
    )["data"]


def create_app_store_version_with_retry(
    client: ASCClient,
    app_id: str,
    args: argparse.Namespace,
    attempts: int = CREATE_VERSION_MAX_ATTEMPTS,
    retry_seconds: int = CREATE_VERSION_RETRY_SECONDS,
) -> dict[str, Any]:
    for attempt in range(attempts):
        try:
            return create_app_store_version(client, app_id, args)
        except AppStoreConnectError as error:
            if attempt == attempts - 1 or not is_version_creation_state_conflict(error):
                raise
            print("App Store Connect is still releasing the previous review state; retrying version creation")
            time.sleep(retry_seconds)
    raise AppStoreConnectError(f"failed to create App Store version {args.version}")


def ensure_version(client: ASCClient, app_id: str, args: argparse.Namespace) -> dict[str, Any]:
    existing = client.request(
        "GET",
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": namespace_platform(args),
            "filter[versionString]": args.version,
            "include": "build,appStoreVersionLocalizations,appStoreReviewDetail",
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,copyright,releaseType,usesIdfa,build,appStoreVersionLocalizations,appStoreReviewDetail",
            "limit": 1,
        },
    )
    if existing.get("data"):
        version = existing["data"][0]
        print(f"Using App Store version {args.version}: {version['id']}")
    else:
        version = create_app_store_version_with_retry(client, app_id, args)
        print(f"Created App Store version {args.version}: {version['id']}")
    attributes: dict[str, Any] = {
        "releaseType": args.release_type,
        "copyright": args.copyright,
        "usesIdfa": args.uses_idfa,
    }
    state = version_state(version)
    if state in REJECTED_RELEASE_CANDIDATE_STATES:
        raise AppStoreConnectError(
            f"App Store version {args.version} is {state}; do not resubmit a rejected "
            "release candidate. Prepare the next marketing version, copy the approved "
            "metadata and screenshots there, and rerun with --version set to that next version.",
            payload=version,
        )
    if state in LOCKED_VERSION_STATES:
        print(f"Skipping attribute update because App Store version is {state}")
    else:
        client.request(
            "PATCH",
            f"/appStoreVersions/{version['id']}",
            body={"data": {"type": "appStoreVersions", "id": version["id"], "attributes": attributes}},
        )
    return version


def reuse_removed_app_store_version(
    client: ASCClient, app_id: str, source_version_string: str, args: argparse.Namespace
) -> dict[str, Any]:
    version = app_store_version(client, app_id, source_version_string, namespace_platform(args))
    if version is None:
        raise AppStoreConnectError(f"App Store version {source_version_string} is not available to reuse")
    state = version_state(version)
    prepare_only = bool(getattr(args, "prepare_only", False))
    if state in REJECTED_RELEASE_CANDIDATE_STATES and not prepare_only:
        raise AppStoreConnectError(
            rejected_source_reuse_message(source_version_string, args.version, state),
            payload=version,
        )
    if state in LOCKED_VERSION_STATES:
        raise AppStoreConnectError(
            f"App Store version {source_version_string} is still {state}; cannot reuse it as {args.version}",
            payload=version,
        )
    updated = client.request(
        "PATCH",
        f"/appStoreVersions/{version['id']}",
        body={
            "data": {
                "type": "appStoreVersions",
                "id": version["id"],
                "attributes": {
                    "versionString": args.version,
                    "releaseType": args.release_type,
                    "copyright": args.copyright,
                    "usesIdfa": args.uses_idfa,
                },
            }
        },
    )["data"]
    print(f"Reused App Store version {source_version_string} as {args.version}: {updated['id']}")
    return updated


def ensure_replacement_version(client: ASCClient, app_id: str, args: argparse.Namespace) -> tuple[dict[str, Any], bool]:
    try:
        version = ensure_version(client, app_id, args)
        return version, bool(args.remove_active_review_version)
    except AppStoreConnectError as error:
        source_version = args.remove_active_review_version
        if not source_version or not is_version_creation_state_conflict(error):
            raise
        source = app_store_version(client, app_id, source_version, namespace_platform(args))
        if source is None:
            raise AppStoreConnectError(f"App Store version {source_version} is not available to reuse")
        source_state = version_state(source)
        prepare_only = bool(getattr(args, "prepare_only", False))
        if source_state in REJECTED_RELEASE_CANDIDATE_STATES and not prepare_only:
            raise AppStoreConnectError(
                rejected_source_reuse_message(source_version, args.version, source_state),
                payload=source,
            )
        print(
            f"App Store Connect still blocks creating {args.version}; "
            f"reusing removed version {source_version} instead"
        )
        return reuse_removed_app_store_version(client, app_id, source_version, args), True


def dry_run_version_path(
    client: ASCClient,
    app_id: str,
    args: argparse.Namespace,
    removable_review_version: str | None = None,
) -> None:
    platform = namespace_platform(args)
    existing = app_store_version(client, app_id, args.version, platform)
    target_version_id = existing["id"] if existing else None
    removable_version_id = None
    source = None
    if args.remove_active_review_version:
        source = app_store_version(client, app_id, args.remove_active_review_version, platform)
        removable_version_id = source["id"] if source else None

    active_ids = active_review_version_ids(client, app_id, platform)
    allowed_active_ids = {version_id for version_id in (target_version_id, removable_version_id) if version_id}
    blocking_ids = active_ids - allowed_active_ids
    if blocking_ids:
        versions = app_store_versions_by_id(client, app_id, platform)
        blocking = ", ".join(
            describe_app_store_version(versions.get(version_id), version_id)
            for version_id in sorted(blocking_ids)
        )
        raise AppStoreConnectError(
            f"another App Store version is already in review: {blocking}; rerun with "
            "--remove-active-review-version for the active version before submitting a replacement"
        )

    prepare_only = bool(getattr(args, "prepare_only", False))
    blocking_versions = [
        version
        for version in version_creation_blocking_app_store_versions(client, app_id, platform)
        if version["id"] not in allowed_active_ids
        and not (prepare_only and version_state(version) in REJECTED_RELEASE_CANDIDATE_STATES)
    ]
    if blocking_versions:
        raise AppStoreConnectError(replacement_version_guidance(blocking_versions[0]), payload=blocking_versions[0])

    if existing is not None:
        state = version_state(existing)
        if state in REJECTED_RELEASE_CANDIDATE_STATES:
            raise AppStoreConnectError(
                f"App Store version {args.version} is {state}; do not resubmit a rejected "
                "release candidate. Prepare the next marketing version, copy the approved "
                "metadata and screenshots there, and rerun with --version set to that next version.",
                payload=existing,
            )
        if state in LOCKED_VERSION_STATES:
            raise AppStoreConnectError(
                f"App Store version {args.version} is {state}; cannot attach build {args.build_number}",
                payload=existing,
            )
        print(f"Dry run: would use App Store version {args.version}: {existing['id']} ({state})")
        return

    if not args.remove_active_review_version:
        print(f"Dry run: would create App Store version {args.version}")
        return

    if source is None:
        raise AppStoreConnectError(
            f"App Store version {args.remove_active_review_version} is not available to reuse as {args.version}"
        )
    state = version_state(source)
    removal_validated = removable_review_version == args.remove_active_review_version
    if state in REJECTED_RELEASE_CANDIDATE_STATES and not prepare_only:
        raise AppStoreConnectError(
            rejected_source_reuse_message(args.remove_active_review_version, args.version, state),
            payload=source,
        )
    if state in LOCKED_VERSION_STATES and not (removal_validated and state in REMOVABLE_REVIEW_VERSION_STATES):
        raise AppStoreConnectError(
            f"App Store version {args.remove_active_review_version} is still {state}; cannot reuse it as {args.version}",
            payload=source,
        )
    print(
        f"Dry run: target App Store version {args.version} does not exist; "
        f"apply mode can reuse {args.remove_active_review_version} ({state}) as {args.version} if creation remains blocked"
    )


def version_build_id(client: ASCClient, version_id: str) -> str | None:
    payload = client.request(
        "GET",
        f"/appStoreVersions/{version_id}",
        {
            "include": "build",
            "fields[appStoreVersions]": "build",
            "fields[builds]": "version,processingState",
        },
    )
    return relationship_id(payload["data"], "build")


def attach_build(client: ASCClient, version: dict[str, Any], build: dict[str, Any], args: argparse.Namespace) -> None:
    version_id = version["id"]
    state = version_state(version)
    attached_build_id = relationship_id(version, "build") or version_build_id(client, version_id)
    if attached_build_id == build["id"]:
        print(f"Build {args.build_number} is already attached")
        return
    if state in LOCKED_VERSION_STATES:
        raise AppStoreConnectError(
            f"App Store version {args.version} is {state}; cannot attach build {args.build_number}",
            payload=version,
        )
    client.request(
        "PATCH",
        f"/appStoreVersions/{version_id}/relationships/build",
        body={"data": {"type": "builds", "id": build["id"]}},
        allowed=(200, 204),
    )
    print(f"Attached build {args.build_number} to App Store version {args.version}")


def build_marketing_version_and_platform(payload: dict[str, Any], build: dict[str, Any]) -> tuple[str | None, str | None]:
    relationship = build.get("relationships", {}).get("preReleaseVersion", {}).get("data")
    pre_release_id = relationship.get("id") if isinstance(relationship, dict) else None
    included = {
        item["id"]: item
        for item in payload.get("included") or []
        if item.get("type") == "preReleaseVersions"
    }
    pre_release = included.get(pre_release_id) if pre_release_id else None
    found_version = pre_release.get("attributes", {}).get("version") if pre_release else None
    found_platform = pre_release.get("attributes", {}).get("platform") if pre_release else None
    return found_version, found_platform


def validate_build_marketing_version(
    payload: dict[str, Any], build: dict[str, Any], marketing_version: str, build_number: str
) -> None:
    found_version, _ = build_marketing_version_and_platform(payload, build)
    if found_version != marketing_version:
        raise AppStoreConnectError(
            f"build {build_number} belongs to marketing version {found_version or '<unknown>'}, not {marketing_version}",
            payload=build,
        )


def select_build_for_marketing_version(
    payload: dict[str, Any], builds: list[dict[str, Any]], marketing_version: str
) -> dict[str, Any]:
    for build in builds:
        found_version, _ = build_marketing_version_and_platform(payload, build)
        if found_version == marketing_version:
            return build
    return builds[0]


def ensure_build(
    client: ASCClient,
    app_id: str,
    args: argparse.Namespace,
    allow_updates: bool = True,
    wait_timeout_seconds: int | None = None,
    poll_seconds: int | None = None,
) -> dict[str, Any]:
    wait_timeout = DEFAULT_BUILD_WAIT_TIMEOUT_SECONDS if wait_timeout_seconds is None else wait_timeout_seconds
    poll_interval = DEFAULT_BUILD_POLL_SECONDS if poll_seconds is None else poll_seconds
    deadline = time.monotonic() + max(0, wait_timeout)
    last_payload: dict[str, Any] | None = None
    last_build: dict[str, Any] | None = None
    platform = namespace_platform(args)
    while True:
        payload = client.request(
            "GET",
            "/builds",
            {
                "filter[app]": app_id,
                "filter[version]": args.build_number,
                "include": "preReleaseVersion,appStoreVersion",
                "fields[builds]": "version,processingState,uploadedDate,expired,usesNonExemptEncryption,appStoreVersion,preReleaseVersion",
                "fields[preReleaseVersions]": "version,platform",
                "limit": 20,
            },
        )
        last_payload = payload
        included = included_by_id(payload)
        builds = [
            build
            for build in payload.get("data") or []
            if isinstance(build, dict)
            if included.get(relationship_id(build, "preReleaseVersion") or "", {}).get("attributes", {}).get("platform")
            == platform
        ]
        if builds:
            last_build = select_build_for_marketing_version(payload, builds, args.version)
            attributes = last_build.get("attributes", {})
            if attributes.get("processingState") == "VALID":
                validate_build_marketing_version(payload, last_build, args.version, args.build_number)
                break
            if time.monotonic() >= deadline:
                raise AppStoreConnectError(
                    f"build {args.build_number} is not valid: {attributes.get('processingState')}",
                    payload=last_build,
                )
            print(
                f"Build {args.build_number} is {attributes.get('processingState')}; "
                f"waiting {poll_interval}s for App Store Connect processing"
            )
        else:
            if time.monotonic() >= deadline:
                raise AppStoreConnectError(
                    f"missing {platform} build {args.build_number}", payload=last_payload
                )
            print(
                f"{platform} build {args.build_number} is not visible yet; "
                f"waiting {poll_interval}s for App Store Connect processing"
            )
        time.sleep(max(1, poll_interval))
    if last_build is None:
        raise AppStoreConnectError(f"missing {platform} build {args.build_number}", payload=last_payload)
    build = last_build
    attributes = build["attributes"]
    if args.non_exempt_encryption is not None and attributes.get("usesNonExemptEncryption") != args.non_exempt_encryption:
        if allow_updates:
            client.request(
                "PATCH",
                f"/builds/{build['id']}",
                body={
                    "data": {
                        "type": "builds",
                        "id": build["id"],
                        "attributes": {"usesNonExemptEncryption": args.non_exempt_encryption},
                    }
                },
            )
        else:
            print(f"Dry run: would update build {args.build_number} non-exempt encryption setting")
    print(f"Using valid build {args.build_number}: {build['id']}")
    return build


def ensure_metadata(client: ASCClient, version_id: str, source_localization: dict[str, Any], source_review_detail: dict[str, Any], args: argparse.Namespace) -> None:
    current = client.request(
        "GET",
        f"/appStoreVersions/{version_id}",
        {
            "include": "appStoreVersionLocalizations,appStoreReviewDetail",
            "fields[appStoreVersions]": "appStoreState,appVersionState,appStoreVersionLocalizations,appStoreReviewDetail",
            "fields[appStoreVersionLocalizations]": "locale,description,keywords,marketingUrl,promotionalText,supportUrl,whatsNew",
            "fields[appStoreReviewDetails]": "contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountName,demoAccountRequired,notes",
        },
    )
    version = current["data"]
    state = version_state(version)
    if state in LOCKED_VERSION_STATES:
        print(f"Skipping metadata update because App Store version is {state}")
        return
    localization_id = relationship_id(version, "appStoreVersionLocalizations")
    review_detail_id = relationship_id(version, "appStoreReviewDetail")
    localization = {
        "locale": args.locale or source_localization.get("locale") or "en-US",
        "description": source_localization.get("description"),
        "keywords": source_localization.get("keywords"),
        "supportUrl": args.support_url or source_localization.get("supportUrl"),
        "whatsNew": args.whats_new,
    }
    for optional in ("marketingUrl", "promotionalText"):
        if source_localization.get(optional) is not None:
            localization[optional] = source_localization[optional]
    localization = {key: value for key, value in localization.items() if value is not None}
    if localization_id:
        update = {key: value for key, value in localization.items() if key != "locale"}
        try:
            client.request(
                "PATCH",
                f"/appStoreVersionLocalizations/{localization_id}",
                body={
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": localization_id,
                        "attributes": update,
                    }
                },
            )
        except AppStoreConnectError as error:
            if "whatsNew" not in update or not is_locked_whats_new_error(error):
                raise
            update_without_whats_new = {key: value for key, value in update.items() if key != "whatsNew"}
            if update_without_whats_new:
                client.request(
                    "PATCH",
                    f"/appStoreVersionLocalizations/{localization_id}",
                    body={
                        "data": {
                            "type": "appStoreVersionLocalizations",
                            "id": localization_id,
                            "attributes": update_without_whats_new,
                        }
                    },
                )
            print(f"Skipped What's New update because App Store Connect locked it: {localization_id}")
        print(f"Updated localization: {localization_id}")
    else:
        created = client.request(
            "POST",
            "/appStoreVersionLocalizations",
            body={
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": localization,
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}},
                }
            },
            allowed=(201,),
        )
        print(f"Created localization: {created['data']['id']}")
    review_attributes = {
        key: source_review_detail.get(key)
        for key in (
            "contactFirstName",
            "contactLastName",
            "contactPhone",
            "contactEmail",
            "demoAccountName",
            "demoAccountRequired",
            "notes",
        )
        if source_review_detail.get(key) is not None
    }
    review_notes = effective_review_notes(args)
    if review_notes is not None:
        review_attributes["notes"] = review_notes
    if review_detail_id and review_attributes:
        client.request(
            "PATCH",
            f"/appStoreReviewDetails/{review_detail_id}",
            body={
                "data": {
                    "type": "appStoreReviewDetails",
                    "id": review_detail_id,
                    "attributes": review_attributes,
                }
            },
        )
        print(f"Updated review detail: {review_detail_id}")
        if getattr(args, "platform", None) == "TV_OS" and review_notes == "":
            print("Cleared copied prior-version TV_OS review notes")


def create_review_submission(
    client: ASCClient,
    app_id: str,
    platform: str | None = None,
) -> dict[str, Any]:
    data: dict[str, Any] = {
        "type": "reviewSubmissions",
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
    }
    if platform is not None:
        data["attributes"] = {"platform": platform}
    body = {"data": data}
    return client.request("POST", "/reviewSubmissions", body=body, allowed=(201,))["data"]


def review_submission_item_version_ids(
    client: ASCClient,
    submission_id: str,
) -> set[str]:
    payload = paginated_get(
        client,
        f"/reviewSubmissions/{submission_id}/items",
        {
            "include": "appStoreVersion",
            "fields[reviewSubmissionItems]": "state,appStoreVersion",
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,platform",
        },
        limit=20,
    )
    if any(relationship_id(item, "appStoreVersion") is None for item in payload.get("data", [])):
        raise AppStoreConnectError(
            "review submission contains an item whose App Store version ownership is unavailable; "
            "inspect App Store Connect before retrying"
        )
    return {
        version_id
        for item in payload.get("data", [])
        if (version_id := relationship_id(item, "appStoreVersion")) is not None
    }


def review_submissions_for_app(
    client: ASCClient,
    app_id: str,
) -> dict[str, Any]:
    return paginated_get(
        client,
        "/reviewSubmissions",
        {
            "filter[app]": app_id,
            "include": "items,appStoreVersionForReview",
            "fields[reviewSubmissions]": "platform,state,submittedDate,items,appStoreVersionForReview",
            "fields[reviewSubmissionItems]": "state,appStoreVersion",
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,platform",
        },
        limit=20,
    )


def active_review_submission_for_version(
    client: ASCClient,
    submissions: dict[str, Any],
    version_id: str,
) -> dict[str, Any] | None:
    included = included_by_id(submissions)
    matches: list[dict[str, Any]] = []
    for submission in submissions.get("data", []):
        state = submission["attributes"].get("state")
        if state not in ACTIVE_REVIEW_SUBMISSION_STATES:
            continue
        submission_version_id = relationship_id(submission, "appStoreVersionForReview")
        submission_version = included.get(submission_version_id or "")
        if is_orphan_ready_for_sale_review_draft(submission, submission_version):
            continue
        version_ids = review_submission_version_ids(submission, included)
        item_ids = review_submission_item_ids(submission)
        unresolved_item_ids = [
            item_id
            for item_id in item_ids
            if relationship_id(included.get(item_id, {}), "appStoreVersion") is None
        ]
        if unresolved_item_ids:
            version_ids.update(review_submission_item_version_ids(client, submission["id"]))
        if version_id not in version_ids:
            continue
        if version_ids != {version_id}:
            raise AppStoreConnectError(
                "review submission already contains another App Store version; "
                "submit each platform and version in a separate review submission"
            )
        matches.append(submission)
    if len(matches) > 1:
        raise AppStoreConnectError(
            "multiple active review submissions claim the same App Store version; "
            "inspect App Store Connect before retrying"
        )
    return matches[0] if matches else None


def wait_for_active_review_submission_for_version(
    client: ASCClient,
    app_id: str,
    version_id: str,
    timeout_seconds: int = DEFAULT_REVIEW_ITEM_OWNER_WAIT_TIMEOUT_SECONDS,
    poll_seconds: int = DEFAULT_REVIEW_ITEM_OWNER_POLL_SECONDS,
) -> dict[str, Any] | None:
    deadline = time.monotonic() + max(0, timeout_seconds)
    while True:
        submission = active_review_submission_for_version(
            client,
            review_submissions_for_app(client, app_id),
            version_id,
        )
        if submission is not None or time.monotonic() >= deadline:
            return submission
        print(
            "Review submission item owner is not visible yet; "
            f"waiting {poll_seconds}s for App Store Connect consistency"
        )
        time.sleep(max(1, poll_seconds))


def ensure_review_submission(
    client: ASCClient,
    app_id: str,
    version_id: str,
    platform: str | None = None,
) -> dict[str, Any]:
    submissions = review_submissions_for_app(client, app_id)
    existing = active_review_submission_for_version(client, submissions, version_id)
    created_submission_id = None
    if existing:
        state = existing["attributes"].get("state")
        if state in {"WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}:
            print(f"Review submission is already submitted: {existing['id']} ({state})")
            return existing
        print(f"Using existing review submission: {existing['id']} ({state})")
        submission = existing
    else:
        try:
            submission = create_review_submission(client, app_id, platform)
            created_submission_id = submission["id"]
            print(f"Created review submission: {submission['id']}")
        except AppStoreConnectError as error:
            if not is_review_submission_limit_exceeded(error):
                raise
            owner = wait_for_active_review_submission_for_version(
                client,
                app_id,
                version_id,
                timeout_seconds=DEFAULT_REVIEW_LIMIT_OWNER_WAIT_TIMEOUT_SECONDS,
            )
            if owner is not None:
                submission = owner
                existing = owner
                print(f"Using existing review submission: {submission['id']} ({submission['attributes'].get('state')})")
            else:
                print_active_review_submissions(review_submissions_for_app(client, app_id))
                raise AppStoreConnectError(
                    "review submission limit exceeded; itemless submissions are not reused because "
                    "their marketing-version ownership is ambiguous; inspect the active submissions before retrying",
                    status=error.status,
                    payload=error.payload,
                ) from error
    existing_version_ids = review_submission_item_version_ids(client, submission["id"]) if existing else set()
    if version_id in existing_version_ids:
        print(f"Review submission item already exists for App Store version: {version_id}")
    elif existing_version_ids:
        raise AppStoreConnectError(
            "review submission already contains another App Store version; "
            "submit each platform and version in a separate review submission"
        )
    else:
        try:
            item = client.request(
                "POST",
                "/reviewSubmissionItems",
                body={
                    "data": {
                        "type": "reviewSubmissionItems",
                        "relationships": {
                            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
                            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
                        },
                    }
                },
                allowed=(201,),
            )
            print(f"Created review submission item: {item['data']['id']}")
        except AppStoreConnectError as error:
            if not (
                is_existing_review_item_conflict(error)
                or is_review_submission_version_slot_taken(error)
            ):
                raise
            visible_version_ids = review_submission_item_version_ids(client, submission["id"])
            if version_id in visible_version_ids:
                print(f"Review submission item already exists for App Store version: {version_id}")
            elif visible_version_ids:
                raise AppStoreConnectError(
                    "review submission already contains another App Store version; "
                    "submit each platform and version in a separate review submission",
                    status=error.status,
                    payload=error.payload,
                ) from error
            else:
                try:
                    owner = wait_for_active_review_submission_for_version(
                        client,
                        app_id,
                        version_id,
                    )
                except Exception as owner_error:
                    if created_submission_id is not None:
                        cancel_unowned_review_submission_if_still_empty(client, created_submission_id)
                    if isinstance(owner_error, AppStoreConnectError):
                        raise
                    raise AppStoreConnectError(
                        "review submission owner discovery failed; inspect App Store Connect before retrying"
                    ) from owner_error
                if owner is None:
                    if created_submission_id is not None:
                        cancel_unowned_review_submission_if_still_empty(client, created_submission_id)
                    raise AppStoreConnectError(
                        "review submission item conflict did not resolve to an active owning review submission; "
                        "inspect App Store Connect before retrying",
                        status=error.status,
                        payload=error.payload,
                    ) from error
                if created_submission_id is not None and owner["id"] != created_submission_id:
                    cancel_unowned_review_submission_if_still_empty(client, created_submission_id)
                submission = owner
                print(f"Review submission item already exists for App Store version: {version_id}")
    state = submission["attributes"].get("state") if submission.get("attributes") else None
    if state in {"WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}:
        print(f"Review submission is already submitted: {submission['id']} ({state})")
        return submission
    submitted = client.request(
        "PATCH",
        f"/reviewSubmissions/{submission['id']}",
        body={
            "data": {
                "type": "reviewSubmissions",
                "id": submission["id"],
                "attributes": {"submitted": True},
            }
        },
    )["data"]
    print(f"Submitted review submission: {submitted['id']} ({submitted['attributes'].get('state')})")
    return submitted


def parse_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "y"}:
        return True
    if normalized in {"0", "false", "no", "n"}:
        return False
    raise argparse.ArgumentTypeError(f"expected boolean, got {value!r}")


def is_https_url(value: str) -> bool:
    parsed = urllib.parse.urlparse(value)
    return parsed.scheme.lower() == "https" and bool(parsed.netloc) and not any(character.isspace() for character in value)


def effective_review_notes(args: argparse.Namespace) -> str | None:
    review_notes = (getattr(args, "review_notes", None) or "").strip()
    if getattr(args, "platform", None) != "TV_OS":
        return review_notes or None
    demo_video_url = (getattr(args, "tvos_demo_video_url", None) or "").strip()
    if not demo_video_url:
        return review_notes
    evidence_notes = f"{TVOS_DEMO_NOTES_HEADING}\n{demo_video_url}"
    return f"{evidence_notes}\n\n{review_notes}" if review_notes else evidence_notes


def print_tvos_review_notes_dry_run_action(args: argparse.Namespace) -> None:
    if getattr(args, "platform", None) != "TV_OS" or effective_review_notes(args) != "":
        return
    print("Dry run: would clear copied prior-version TV_OS review notes")


def validation_report_required(args: argparse.Namespace) -> bool:
    if getattr(args, "validate_report_only", False):
        return True
    if getattr(args, "dry_run", False) or getattr(args, "cancel_review_only", False):
        return False
    return not getattr(args, "prepare_only", False) or bool(
        getattr(args, "build_number", None)
    )


def validation_report_blockers(
    payload: object,
    *,
    version: str,
    build_number: str,
    platform: str,
) -> list[str]:
    if not isinstance(payload, dict):
        return ["the validation report root must be a JSON object"]

    blockers: list[str] = []
    if payload.get("schemaVersion") != 1:
        blockers.append("schemaVersion must be 1")

    target = payload.get("target")
    if not isinstance(target, dict):
        blockers.append("target is missing or malformed")
    else:
        if target.get("version") != version:
            blockers.append(f"target version must be {version}")
        if target.get("buildNumber") != build_number:
            blockers.append(f"target build number must be {build_number}")

    summary = payload.get("summary")
    if not isinstance(summary, dict):
        blockers.append("summary is missing or malformed")
    else:
        if summary.get("state") != "complete_for_slice":
            blockers.append("summary state must be complete_for_slice")
        if summary.get("exitCode") != 0:
            blockers.append("summary exit code must be 0")

    obtained = payload.get("obtainedEvidenceClasses")
    runtime_receipts: dict[str, Any] = {}
    if not isinstance(obtained, dict):
        blockers.append("obtainedEvidenceClasses is missing or malformed")
    else:
        if obtained.get("appStoreConnect") != "available":
            blockers.append("App Store Connect evidence must be available")
        if obtained.get("canonicalMacProductionRuntime") != "proven":
            blockers.append("the canonical Mac Production runtime must be proven")
        raw_runtime_receipts = obtained.get("exactBuildRuntimeReceipts")
        if not isinstance(raw_runtime_receipts, dict):
            blockers.append("exact-build runtime receipt evidence is missing or malformed")
        else:
            runtime_receipts = raw_runtime_receipts
            proven = runtime_receipts.get("proven")
            required = runtime_receipts.get("required")
            if runtime_receipts.get("state") != "proven":
                blockers.append("exact-build runtime receipt state must be proven")
            if not isinstance(required, int) or required <= 0:
                blockers.append("at least one exact-build runtime surface must be required")
            if proven != required:
                blockers.append("every requested runtime surface must be proven")
            if runtime_receipts.get("runtimeSessionResult") != "healthy":
                blockers.append("the runtime receipt session result must be healthy")
            diagnostics = runtime_receipts.get("diagnostics")
            if not isinstance(diagnostics, list) or diagnostics:
                blockers.append("runtime receipt diagnostics must be empty")

        if platform == "IOS" and obtained.get("watchRestartAttestation") != "recorded":
            blockers.append("the physical Watch restart attestation must be recorded")

    session = payload.get("session")
    requested_surfaces: set[str] = set()
    if not isinstance(session, dict):
        blockers.append("session is missing or malformed")
    else:
        raw_requested_surfaces = session.get("requestedSurfaces")
        if not isinstance(raw_requested_surfaces, list) or not all(
            isinstance(item, str) for item in raw_requested_surfaces
        ):
            blockers.append("session requested surfaces are missing or malformed")
        else:
            requested_surfaces = set(raw_requested_surfaces)
            if len(requested_surfaces) != len(raw_requested_surfaces):
                blockers.append("session requested surfaces contain duplicates")

    runtime_surfaces = payload.get("runtimeSurfaces")
    proven_surfaces: set[str] = set()
    if not isinstance(runtime_surfaces, list):
        blockers.append("runtimeSurfaces is missing or malformed")
    else:
        observed_surfaces: list[str] = []
        for item in runtime_surfaces:
            if not isinstance(item, dict) or not isinstance(item.get("surface"), str):
                blockers.append("a runtime surface entry is malformed")
                continue
            surface = item["surface"]
            observed_surfaces.append(surface)
            if item.get("state") == "proven":
                proven_surfaces.add(surface)
            else:
                blockers.append(f"runtime surface {surface} is not proven")
        if len(set(observed_surfaces)) != len(observed_surfaces):
            blockers.append("runtime surfaces contain duplicates")
        if requested_surfaces and set(observed_surfaces) != requested_surfaces:
            blockers.append("runtime surfaces do not match the requested session surfaces")
        if runtime_receipts.get("required") != len(observed_surfaces):
            blockers.append("runtime surface count does not match the receipt summary")

    required_surfaces = REQUIRED_RUNTIME_SURFACES_BY_PLATFORM[platform]
    missing_surfaces = sorted(required_surfaces - requested_surfaces)
    if missing_surfaces:
        blockers.append(
            f"{platform} validation is missing required surfaces: {', '.join(missing_surfaces)}"
        )
    unproven_required_surfaces = sorted(required_surfaces - proven_surfaces)
    if unproven_required_surfaces:
        blockers.append(
            f"{platform} required surfaces are not proven: "
            + ", ".join(unproven_required_surfaces)
        )

    operator_flow = payload.get("operatorFlow")
    if not isinstance(operator_flow, dict):
        blockers.append("operatorFlow is missing or malformed")
    else:
        if operator_flow.get("state") != "complete":
            blockers.append("operator flow state must be complete")
        if operator_flow.get("readyActionCount") != 0:
            blockers.append("operator flow must have no ready actions")
        if operator_flow.get("deferredActionCount") != 0:
            blockers.append("operator flow must have no deferred actions")
        active_deferrals = operator_flow.get("activeDeferrals")
        if not isinstance(active_deferrals, list) or active_deferrals:
            blockers.append("operator flow must have no active deferrals")
        runtime_diagnostics = operator_flow.get("runtimeDiagnostics")
        if not isinstance(runtime_diagnostics, list) or runtime_diagnostics:
            blockers.append("operator flow runtime diagnostics must be empty")

    report_blockers = payload.get("blockers")
    if not isinstance(report_blockers, list) or report_blockers:
        blockers.append("the validation report must have no blockers")

    return blockers


def validate_validation_report(args: argparse.Namespace) -> None:
    report_path = Path(args.validation_report)
    try:
        payload = json.loads(report_path.read_text())
    except OSError as error:
        raise AppStoreConnectError(
            f"validation report is unavailable: {report_path}"
        ) from error
    except json.JSONDecodeError as error:
        raise AppStoreConnectError("validation report is not valid JSON") from error

    blockers = validation_report_blockers(
        payload,
        version=args.version,
        build_number=args.build_number,
        platform=args.platform,
    )
    if blockers:
        details = "\n".join(f"- {blocker}" for blocker in blockers)
        raise AppStoreConnectError(f"validation report rejected:\n{details}")
    print(
        f"Accepted exact-build validation report for {args.platform} "
        f"{args.version} ({args.build_number})"
    )
    print("This gate proves required runtime evidence; visual approval and carry-forward remain separate.")


def validate_release_evidence_report(args: argparse.Namespace) -> None:
    release_report_value = getattr(args, "release_evidence_report", None)
    validation_report_value = getattr(args, "validation_report", None)
    comparison_value = getattr(args, "release_evidence_comparison", None)
    manifest_values = getattr(args, "release_evidence_expected_build_manifests", None)
    policy_value = getattr(args, "release_evidence_policy", None)
    surface_policy_value = getattr(args, "release_evidence_surface_policy", None)
    if (
        not release_report_value
        or not validation_report_value
        or not comparison_value
        or not manifest_values
        or not policy_value
        or not surface_policy_value
    ):
        raise AppStoreConnectError(
            "release evidence requires its report, exact validation report, comparison, "
            "expected-build manifests, and configured policy"
        )
    report_path = Path(release_report_value)
    try:
        payload = json.loads(report_path.read_text())
    except OSError as error:
        raise AppStoreConnectError(
            f"release evidence report is unavailable: {report_path}"
        ) from error
    except json.JSONDecodeError as error:
        raise AppStoreConnectError("release evidence report is not valid JSON") from error
    validation_report_path = Path(validation_report_value)
    try:
        validation_payload = json.loads(validation_report_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AppStoreConnectError(
            "exact validation report is unavailable for release evidence binding"
        ) from error
    try:
        comparison = load_json_object(Path(comparison_value), "surface comparison")
        validate_current_comparison(comparison)
        policy = load_json_object(Path(policy_value), "release evidence policy")
        surface_policy = load_json_object(
            Path(surface_policy_value),
            "surface evidence policy",
        )
        expected_build_manifests = tuple(
            load_json_object(Path(value), "expected signed build manifest")
            for value in manifest_values
        )
        identities = expected_surface_identities_from_payloads(
            list(expected_build_manifests),
            Target(args.version, args.build_number),
            tuple(RUNTIME_SURFACES),
        )
        previous_ledger = (
            load_json_object(
                Path(args.release_evidence_previous_ledger),
                "previous release evidence ledger",
            )
            if getattr(args, "release_evidence_previous_ledger", None)
            else None
        )
        selected_rc_ledger = (
            load_json_object(
                Path(args.release_evidence_selected_rc_ledger),
                "selected RC release evidence ledger",
            )
            if getattr(args, "release_evidence_selected_rc_ledger", None)
            else None
        )
        host_os_evidence = (
            load_json_object(
                Path(args.release_evidence_host_os_evidence),
                "host OS evidence",
            )
            if getattr(args, "release_evidence_host_os_evidence", None)
            else None
        )
        shadow_evidence = (
            load_json_object(
                Path(args.release_evidence_shadow_evidence),
                "shadow evidence",
            )
            if getattr(args, "release_evidence_shadow_evidence", None)
            else None
        )
    except (ComparisonSchemaError, ReleaseEvidenceError, RuntimeEvidenceError) as error:
        raise AppStoreConnectError(f"release evidence binding is invalid: {error}") from error
    blockers = release_evidence_report_blockers(
        payload,
        version=args.version,
        build_number=args.build_number,
        train=getattr(args, "validation_train"),
        enforce=getattr(args, "release_evidence_mode", "enforce") == "enforce",
        validation_report=validation_payload,
        comparison=comparison,
        identities=identities,
        expected_build_manifests=expected_build_manifests,
        policy=policy,
        surface_policy=surface_policy,
        previous_ledger=previous_ledger,
        selected_rc_ledger=selected_rc_ledger,
        host_os_evidence=host_os_evidence,
        shadow_evidence=shadow_evidence,
    )
    if blockers:
        details = "\n".join(f"- {blocker}" for blocker in blockers)
        raise AppStoreConnectError(f"release evidence report rejected:\n{details}")
    print(
        f"Accepted {getattr(args, 'release_evidence_mode', 'enforce')} release evidence report for "
        f"{getattr(args, 'validation_train')} {args.version} ({args.build_number})"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument(
        "--platform",
        default="MAC_OS",
        choices=("IOS", "MAC_OS", "TV_OS", "VISION_OS"),
        help="App Store platform to submit for review",
    )
    parser.add_argument("--version", required=True, help="App Store marketing version, for example 1.0.12")
    parser.add_argument("--build-number", help="CFBundleVersion uploaded to App Store Connect")
    parser.add_argument("--whats-new")
    parser.add_argument("--review-notes", help="Override App Review notes copied from the source version")
    parser.add_argument(
        "--tvos-demo-video-url",
        help="Optional reviewer-accessible HTTPS URL for current physical Apple TV evidence",
    )
    parser.add_argument("--copy-from-version", help="Existing App Store version to copy localization and review details from")
    parser.add_argument(
        "--copy-from-platform",
        choices=("IOS", "MAC_OS", "TV_OS", "VISION_OS"),
        help="Platform containing --copy-from-version metadata; defaults to --platform",
    )
    parser.add_argument(
        "--remove-active-review-version",
        help="Existing App Store version to remove from active review before creating the target version",
    )
    parser.add_argument(
        "--cancel-review-only",
        action="store_true",
        help="Cancel/remove the active review for --remove-active-review-version and exit without creating a replacement",
    )
    parser.add_argument(
        "--prepare-only",
        action="store_true",
        help="Create/update the App Store version and metadata without creating or submitting review",
    )
    parser.add_argument("--api-key", default=os.environ.get("APP_STORE_CONNECT_API_KEY_PATH"))
    parser.add_argument("--api-key-id", default=os.environ.get("APP_STORE_CONNECT_KEY_ID"))
    parser.add_argument("--api-issuer-id", default=os.environ.get("APP_STORE_CONNECT_ISSUER_ID"))
    parser.add_argument("--release-type", default=DEFAULT_RELEASE_TYPE, choices=("AFTER_APPROVAL", "MANUAL", "SCHEDULED"))
    parser.add_argument("--copyright", default=DEFAULT_COPYRIGHT)
    parser.add_argument("--locale")
    parser.add_argument("--support-url")
    parser.add_argument("--uses-idfa", type=parse_bool, default=False)
    parser.add_argument("--non-exempt-encryption", type=parse_bool, default=False)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate metadata, build, blocked-version recovery, and target version path without making App Store Connect changes",
    )
    parser.add_argument(
        "--validation-report",
        help="Machine-readable JSON from context-panel-validation.py final-report --json",
    )
    parser.add_argument(
        "--validation-train",
        choices=("beta", "rc", "release"),
        help="Release-evidence policy tier for --release-evidence-report",
    )
    parser.add_argument(
        "--release-evidence-report",
        help="Machine-readable JSON from context-panel-release-gate.py",
    )
    parser.add_argument(
        "--release-evidence-mode",
        choices=("shadow", "enforce"),
        default="enforce",
    )
    parser.add_argument("--release-evidence-comparison")
    parser.add_argument(
        "--release-evidence-expected-build-manifest",
        dest="release_evidence_expected_build_manifests",
        action="append",
    )
    parser.add_argument(
        "--release-evidence-policy",
        default=DEFAULT_RELEASE_EVIDENCE_POLICY,
    )
    parser.add_argument(
        "--release-evidence-surface-policy",
        default=DEFAULT_SURFACE_EVIDENCE_POLICY,
    )
    parser.add_argument("--release-evidence-previous-ledger")
    parser.add_argument("--release-evidence-selected-rc-ledger")
    parser.add_argument("--release-evidence-host-os-evidence")
    parser.add_argument("--release-evidence-shadow-evidence")
    parser.add_argument(
        "--validate-report-only",
        action="store_true",
        help="Validate exact-build evidence and exit without using App Store Connect credentials",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    release_evidence_mode = getattr(args, "release_evidence_mode", "enforce")
    validation_train = getattr(args, "validation_train", None)
    if release_evidence_mode not in {"shadow", "enforce"}:
        raise AppStoreConnectError("--release-evidence-mode must be shadow or enforce")
    if validation_train is not None and validation_train not in {"beta", "rc", "release"}:
        raise AppStoreConnectError("--validation-train must be beta, rc, or release")
    if getattr(args, "validate_report_only", False):
        if args.dry_run or args.cancel_review_only or args.prepare_only:
            raise AppStoreConnectError(
                "--validate-report-only is mutually exclusive with --dry-run, "
                "--cancel-review-only, and --prepare-only"
            )
        if not args.build_number:
            raise AppStoreConnectError("--validate-report-only requires --build-number")
        if not getattr(args, "validation_report", None):
            raise AppStoreConnectError("--validate-report-only requires --validation-report")
        if (
            getattr(args, "release_evidence_mode", "enforce") == "enforce"
            and not getattr(args, "release_evidence_report", None)
        ):
            raise AppStoreConnectError(
                "--validate-report-only with enforced release evidence requires "
                "--release-evidence-report"
            )
        return
    if args.prepare_only:
        if args.cancel_review_only:
            raise AppStoreConnectError("--prepare-only and --cancel-review-only are mutually exclusive")
    if args.cancel_review_only:
        if not args.remove_active_review_version:
            raise AppStoreConnectError("--cancel-review-only requires --remove-active-review-version")
        return
    if not args.build_number and not args.prepare_only:
        raise AppStoreConnectError("--build-number is required unless --cancel-review-only or --prepare-only is used")
    if not args.whats_new:
        raise AppStoreConnectError("--whats-new is required unless --cancel-review-only is used")
    if getattr(args, "platform", None) == "TV_OS":
        raw_demo_video_url = getattr(args, "tvos_demo_video_url", None)
        demo_video_url = (raw_demo_video_url or "").strip()
        if raw_demo_video_url is not None and not demo_video_url:
            raise AppStoreConnectError("--tvos-demo-video-url must be a valid HTTPS URL")
        if demo_video_url and not is_https_url(demo_video_url):
            raise AppStoreConnectError("--tvos-demo-video-url must be a valid HTTPS URL")
    elif getattr(args, "tvos_demo_video_url", None):
        raise AppStoreConnectError("--tvos-demo-video-url is only valid with --platform TV_OS")
    if validation_report_required(args) and not getattr(args, "validation_report", None):
        raise AppStoreConnectError(
            "--validation-report is required before attaching or submitting a build"
        )
    if validation_report_required(args) and validation_train != "release":
        raise AppStoreConnectError(
            "live build attachment or submission requires --validation-train release"
        )
    release_evidence_report = getattr(args, "release_evidence_report", None)
    if release_evidence_report and not validation_train:
        raise AppStoreConnectError(
            "--release-evidence-report requires --validation-train"
        )
    if release_evidence_report and not getattr(args, "validation_report", None):
        raise AppStoreConnectError(
            "--release-evidence-report requires --validation-report"
        )
    if release_evidence_report and (
        not getattr(args, "release_evidence_comparison", None)
        or not getattr(args, "release_evidence_expected_build_manifests", None)
    ):
        raise AppStoreConnectError(
            "--release-evidence-report requires --release-evidence-comparison and "
            "--release-evidence-expected-build-manifest"
        )
    if (
        release_evidence_report
        and validation_train == "release"
        and not getattr(args, "release_evidence_selected_rc_ledger", None)
    ):
        raise AppStoreConnectError(
            "release-train evidence requires --release-evidence-selected-rc-ledger"
        )
    if (
        release_evidence_report
        and release_evidence_mode == "enforce"
        and not getattr(args, "release_evidence_shadow_evidence", None)
    ):
        raise AppStoreConnectError(
            "enforced release evidence requires --release-evidence-shadow-evidence"
        )
    if validation_report_required(args):
        if not release_evidence_report:
            raise AppStoreConnectError(
                "--release-evidence-report is required for live shadow or enforce validation"
            )


def main() -> int:
    args = parse_args()
    temporary_key_path: Path | None = None
    try:
        validate_args(args)
        if validation_report_required(args):
            validate_validation_report(args)
        if getattr(args, "release_evidence_report", None):
            validate_release_evidence_report(args)
        if args.validate_report_only:
            print("Validation report preflight succeeded; no App Store Connect request was made")
            return 0
        if not args.api_key_id or not args.api_issuer_id:
            raise AppStoreConnectError("APP_STORE_CONNECT_KEY_ID and APP_STORE_CONNECT_ISSUER_ID are required")
        key_path, temporary_key_path = expanded_key_path(args)
        if not key_path.exists():
            raise AppStoreConnectError(f"App Store Connect API key not found: {key_path}")
        client = ASCClient(make_token(key_path, args.api_key_id, args.api_issuer_id))
        app_payload = client.request(
            "GET",
            "/apps",
            {"filter[bundleId]": args.bundle_id, "limit": 1, "fields[apps]": "name,bundleId,sku,primaryLocale"},
        )
        app = required_first(app_payload, f"app {args.bundle_id}")
        app_id = app["id"]
        print(f"Using app {app['attributes'].get('name')}: {app_id}")
        if args.cancel_review_only:
            remove_active_review_version(
                client,
                app_id,
                args.remove_active_review_version,
                args.platform,
                dry_run=args.dry_run,
            )
            if args.dry_run:
                print("Dry run: review cancellation was validated; no App Store Connect changes were made")
            else:
                print(f"Canceled active review for App Store version {args.remove_active_review_version}")
            return 0
        source_localization, source_review_detail = latest_source_metadata(
            client,
            app_id,
            args.copy_from_version,
            namespace_copy_from_platform(args),
        )
        build = ensure_build(client, app_id, args, allow_updates=not args.dry_run) if args.build_number else None
        removable_review_version = None
        if args.remove_active_review_version and not args.prepare_only:
            # App Store Connect blocks creating a replacement version while another
            # version is actively in review. Validate the source metadata and uploaded
            # build first, then remove the old review item immediately before creating
            # and submitting the replacement.
            remove_active_review_version(
                client,
                app_id,
                args.remove_active_review_version,
                args.platform,
                dry_run=args.dry_run,
            )
            if args.dry_run:
                removable_review_version = args.remove_active_review_version
            else:
                wait_for_editable_version(
                    client,
                    app_id,
                    args.remove_active_review_version,
                    args.platform,
                )
        if args.dry_run:
            dry_run_version_path(client, app_id, args, removable_review_version=removable_review_version)
            print_tvos_review_notes_dry_run_action(args)
            print("Dry run: metadata, build, and version path validated; no App Store Connect changes were made")
            return 0
        version, reused_removed_version = ensure_replacement_version(client, app_id, args)
        if build is not None:
            attach_build(client, version, build, args)
        elif args.prepare_only:
            print("Prepared App Store version without build attachment")
        ensure_metadata(client, version["id"], source_localization, source_review_detail, args)
        if args.prepare_only:
            final = client.request(
                "GET",
                f"/appStoreVersions/{version['id']}",
                {
                    "include": "build,appStoreVersionLocalizations,appStoreReviewDetail",
                    "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,releaseType,usesIdfa,build,appStoreVersionLocalizations,appStoreReviewDetail",
                    "fields[builds]": "version,processingState,uploadedDate,expired,usesNonExemptEncryption",
                    "fields[appStoreVersionLocalizations]": "locale,whatsNew,supportUrl",
                },
            )
            state = version_state(final["data"])
            print(f"Prepared App Store version {args.version}: {version['id']} ({state})")
            print("Prepare only: review submission was not created or submitted")
            return 0
        submission = ensure_review_submission(
            client,
            app_id,
            version["id"],
            args.platform,
        )
        final = client.request(
            "GET",
            f"/appStoreVersions/{version['id']}",
            {
                "include": "build,appStoreVersionLocalizations,appStoreReviewDetail",
                "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,releaseType,usesIdfa,build,appStoreVersionLocalizations,appStoreReviewDetail",
                "fields[builds]": "version,processingState,uploadedDate,expired,usesNonExemptEncryption",
                "fields[appStoreVersionLocalizations]": "locale,whatsNew,supportUrl",
            },
        )
        state = version_state(final["data"])
        submission_state = submission["attributes"].get("state") if submission.get("attributes") else "unknown"
        print(f"App Store version {args.version} state: {state}")
        print(f"Review submission state: {submission_state}")
        return 0
    except AppStoreConnectError as error:
        print(f"submit-app-store-review failed: {error}", file=sys.stderr)
        if error.status is not None:
            print(f"status: {error.status}", file=sys.stderr)
        if error.payload is not None:
            print(json.dumps(error.payload, indent=2)[:12000], file=sys.stderr)
        return 1
    finally:
        if temporary_key_path is not None:
            try:
                temporary_key_path.unlink()
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
