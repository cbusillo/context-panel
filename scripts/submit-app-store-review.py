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

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey


API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_BUNDLE_ID = "com.shinycomputers.contextpanel"
DEFAULT_COPYRIGHT = "2026 Shiny Computers Leasing LLC"
DEFAULT_RELEASE_TYPE = "AFTER_APPROVAL"
LOCKED_VERSION_STATES = {
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "PENDING_DEVELOPER_RELEASE",
    "READY_FOR_SALE",
}
ACTIVE_REVIEW_SUBMISSION_STATES = {"READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW"}
BLOCKING_REVIEW_VERSION_STATES = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE"}
CREATE_VERSION_MAX_ATTEMPTS = 6
CREATE_VERSION_RETRY_SECONDS = 10


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


def required_first(payload: dict[str, Any], label: str) -> dict[str, Any]:
    data = payload.get("data") or []
    if not data:
        raise AppStoreConnectError(f"missing {label}", payload=payload)
    return data[0]


def included_by_id(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in payload.get("included", [])}


def relationship_id(resource: dict[str, Any], name: str) -> str | None:
    data = resource.get("relationships", {}).get(name, {}).get("data")
    if isinstance(data, list):
        return data[0]["id"] if data else None
    if isinstance(data, dict):
        return data.get("id")
    return None


def version_state(resource: dict[str, Any]) -> str | None:
    attributes = resource.get("attributes", {})
    return attributes.get("appStoreState") or attributes.get("appVersionState")


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


def latest_source_metadata(client: ASCClient, app_id: str, prefer_version: str | None) -> tuple[dict[str, Any], dict[str, Any]]:
    payload = client.request(
        "GET",
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": "MAC_OS",
            "include": "appStoreVersionLocalizations,appStoreReviewDetail",
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,appStoreVersionLocalizations,appStoreReviewDetail",
            "fields[appStoreVersionLocalizations]": "locale,description,keywords,marketingUrl,promotionalText,supportUrl,whatsNew",
            "fields[appStoreReviewDetails]": "contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountName,demoAccountRequired,notes",
            "limit": 50,
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


def app_store_version(client: ASCClient, app_id: str, version_string: str) -> dict[str, Any] | None:
    payload = client.request(
        "GET",
        f"/apps/{app_id}/appStoreVersions",
        {
            "filter[platform]": "MAC_OS",
            "filter[versionString]": version_string,
            "fields[appStoreVersions]": "versionString,appStoreState,appVersionState",
            "limit": 1,
        },
    )
    versions = payload.get("data") or []
    return versions[0] if versions else None


def app_store_version_id(client: ASCClient, app_id: str, version_string: str) -> str | None:
    version = app_store_version(client, app_id, version_string)
    return version["id"] if version else None


def remove_active_review_version(client: ASCClient, app_id: str, version_string: str, dry_run: bool = False) -> None:
    version = app_store_version(client, app_id, version_string)
    if version is None:
        print(f"No App Store version {version_string} found to remove from review")
        return
    version_id = version["id"]

    submissions = client.request(
        "GET",
        "/reviewSubmissions",
        {
            "filter[app]": app_id,
            "filter[platform]": "MAC_OS",
            "include": "items,appStoreVersionForReview",
            "fields[reviewSubmissions]": "platform,state,items,appStoreVersionForReview",
            "fields[reviewSubmissionItems]": "state,appStoreVersion",
            "limit": 20,
        },
    )
    included = included_by_id(submissions)
    for submission in submissions.get("data", []):
        state = submission["attributes"].get("state")
        if state not in ACTIVE_REVIEW_SUBMISSION_STATES:
            continue
        submission_version_id = relationship_id(submission, "appStoreVersionForReview")
        if submission_version_id not in (None, version_id):
            continue
        item_ids = [item["id"] for item in submission.get("relationships", {}).get("items", {}).get("data", [])]
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
                print(f"Review item {item_id} was already submitted; canceling submitted version review instead")
                cancel_app_store_version_submission(client, version_id, version_string, dry_run=False)
                return
    state = version_state(version)
    if state in BLOCKING_REVIEW_VERSION_STATES:
        raise AppStoreConnectError(
            f"App Store version {version_string} is {state}, but no active review submission item was found to remove"
        )
    print(f"No active review submission item found for App Store version {version_string}")


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


def create_app_store_version(client: ASCClient, app_id: str, args: argparse.Namespace) -> dict[str, Any]:
    return client.request(
        "POST",
        "/appStoreVersions",
        body={
            "data": {
                "type": "appStoreVersions",
                "attributes": {
                    "platform": "MAC_OS",
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
            "filter[platform]": "MAC_OS",
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
    version = app_store_version(client, app_id, source_version_string)
    if version is None:
        raise AppStoreConnectError(f"App Store version {source_version_string} is not available to reuse")
    state = version_state(version)
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
        print(
            f"App Store Connect still blocks creating {args.version}; "
            f"reusing removed version {source_version} instead"
        )
        return reuse_removed_app_store_version(client, app_id, source_version, args), True


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


def ensure_build(client: ASCClient, app_id: str, args: argparse.Namespace, allow_updates: bool = True) -> dict[str, Any]:
    payload = client.request(
        "GET",
        "/builds",
        {
            "filter[app]": app_id,
            "filter[version]": args.build_number,
            "include": "preReleaseVersion,appStoreVersion",
            "fields[builds]": "version,processingState,uploadedDate,expired,usesNonExemptEncryption,appStoreVersion,preReleaseVersion",
            "fields[preReleaseVersions]": "version,platform",
            "limit": 1,
        },
    )
    build = required_first(payload, f"build {args.build_number}")
    attributes = build["attributes"]
    if attributes.get("processingState") != "VALID":
        raise AppStoreConnectError(f"build {args.build_number} is not valid: {attributes.get('processingState')}", payload=build)
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


def ensure_review_submission(
    client: ASCClient,
    app_id: str,
    version_id: str,
    args: argparse.Namespace,
    force_prepare: bool = False,
) -> dict[str, Any]:
    submissions = client.request(
        "GET",
        "/reviewSubmissions",
        {
            "filter[app]": app_id,
            "filter[platform]": "MAC_OS",
            "include": "items,appStoreVersionForReview",
            "fields[reviewSubmissions]": "platform,state,submittedDate,items,appStoreVersionForReview",
            "fields[reviewSubmissionItems]": "state,appStoreVersion",
            "limit": 20,
        },
    )
    existing = None
    included = included_by_id(submissions)
    for submission in submissions.get("data", []):
        state = submission["attributes"].get("state")
        if state not in ACTIVE_REVIEW_SUBMISSION_STATES:
            continue
        submission_version_id = relationship_id(submission, "appStoreVersionForReview")
        item_ids = [item["id"] for item in submission.get("relationships", {}).get("items", {}).get("data", [])]
        item_version_ids = {relationship_id(included.get(item_id, {}), "appStoreVersion") for item_id in item_ids}
        if submission_version_id == version_id or version_id in item_version_ids or state == "READY_FOR_REVIEW":
            existing = submission
            break
    if existing:
        state = existing["attributes"].get("state")
        if state in {"WAITING_FOR_REVIEW", "IN_REVIEW"}:
            print(f"Review submission is already submitted: {existing['id']} ({state})")
            return existing
        print(f"Using existing review submission: {existing['id']} ({state})")
        submission = existing
    else:
        submission = client.request(
            "POST",
            "/reviewSubmissions",
            body={"data": {"type": "reviewSubmissions", "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}},
            allowed=(201,),
        )["data"]
        print(f"Created review submission: {submission['id']}")
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
        if error.status != 409:
            raise
        print("Review submission item already exists")
    if args.dry_run:
        print("Dry run: review submission was prepared but not submitted")
        return submission
    state = submission["attributes"].get("state") if submission.get("attributes") else None
    if state in {"WAITING_FOR_REVIEW", "IN_REVIEW"}:
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
                "relationships": {
                    "appStoreVersionForReview": {
                        "data": {"type": "appStoreVersions", "id": version_id}
                    }
                },
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--version", required=True, help="App Store marketing version, for example 1.0.12")
    parser.add_argument("--build-number", required=True, help="CFBundleVersion uploaded to App Store Connect")
    parser.add_argument("--whats-new", required=True)
    parser.add_argument("--copy-from-version", help="Existing App Store version to copy localization and review details from")
    parser.add_argument(
        "--remove-active-review-version",
        help="Existing App Store version to remove from active review before creating the target version",
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
    parser.add_argument("--dry-run", action="store_true", help="Prepare the version and submission item without submitting for review")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    temporary_key_path: Path | None = None
    try:
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
        source_localization, source_review_detail = latest_source_metadata(client, app_id, args.copy_from_version)
        build = ensure_build(client, app_id, args, allow_updates=not args.dry_run)
        if args.remove_active_review_version:
            # App Store Connect blocks creating a replacement version while another
            # version is actively in review. Validate the source metadata and uploaded
            # build first, then remove the old review item immediately before creating
            # and submitting the replacement.
            remove_active_review_version(client, app_id, args.remove_active_review_version, dry_run=args.dry_run)
        if args.dry_run:
            print("Dry run: metadata and build validated; no App Store Connect changes were made")
            return 0
        version, reused_removed_version = ensure_replacement_version(client, app_id, args)
        attach_build(client, version, build, args)
        ensure_metadata(client, version["id"], source_localization, source_review_detail, args)
        submission = ensure_review_submission(
            client,
            app_id,
            version["id"],
            args,
            force_prepare=reused_removed_version,
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
