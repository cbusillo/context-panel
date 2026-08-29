from __future__ import annotations

import hashlib
import json
import re
import struct
import uuid
from dataclasses import dataclass
from typing import Any, Callable


EXPECTED_BUILD_SCHEMA_V1 = 1
EXPECTED_BUILD_SCHEMA_V2 = 2
EXPECTED_BUILD_KIND = "context-panel-expected-signed-build"
SURFACE_MANIFEST_ALGORITHM = "sha256"
SURFACE_DIGEST_DOMAIN = "context-panel-surface/v1"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ARCHITECTURE_PATTERN = re.compile(r"^[A-Za-z0-9_.+-]{1,64}$")
UUID_PATTERN = re.compile(
    r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
)
SIGNING_CLASSES = frozenset(
    {
        "3rd Party Mac Developer Application",
        "3rd Party Mac Developer Installer",
        "Apple Development",
        "Apple Distribution",
        "Apple Mac OS Application Signing",
        "Developer ID Application",
        "Developer ID Installer",
        "Mac Developer",
        "TestFlight Beta Distribution",
        "iPhone Developer",
        "iPhone Distribution",
        "ad-hoc",
    }
)
DISTRIBUTION_SIGNING_CLASSES = SIGNING_CLASSES - {"ad-hoc"}
FINGERPRINT_KEYS = {"render", "runtime", "placement", "combined"}
EXPECTED_MANIFEST_KEYS = {
    "schemaVersion",
    "kind",
    "algorithm",
    "digestDomain",
    "sourceManifestId",
    "contractFingerprint",
    "layout",
    "archive",
    "source",
    "artifacts",
    "surfaces",
    "expectedBuildId",
}
EXPECTED_ARTIFACT_KEYS_V1 = {
    "artifactId",
    "bundleIdentifier",
    "marketingVersion",
    "buildNumber",
    "sourceCommit",
    "configuration",
    "xcodeBuild",
    "treeState",
    "codeSignatureValid",
    "executableSha256",
    "executableUUIDs",
    "entitlementsSha256",
    "profileSha256",
}
EXPECTED_ARTIFACT_KEYS_V2 = EXPECTED_ARTIFACT_KEYS_V1 | {
    "bundleContractSha256",
    "signingClass",
    "signingContractSha256",
    "entitlementContractSha256",
    "profileCapabilitySha256",
    "architectures",
}
EXPECTED_SURFACE_KEYS = {"id", "artifactId", "bundleIdentifier", "fingerprints"}


class ExpectedBuildSchemaError(ValueError):
    pass


@dataclass(frozen=True)
class ValidatedExpectedBuild:
    payload: dict[str, Any]
    artifacts: dict[str, dict[str, Any]]
    surfaces: list[dict[str, Any]]


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def hash_parts(domain: str, parts: list[bytes | str]) -> str:
    digest = hashlib.sha256()
    for part in [domain, *parts]:
        encoded = part if isinstance(part, bytes) else part.encode("utf-8")
        digest.update(struct.pack(">Q", len(encoded)))
        digest.update(encoded)
    return digest.hexdigest()


def is_sha256(value: object) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def normalized_uuid(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError:
        return None


def normalized_uuid_list(value: object) -> tuple[str, ...] | None:
    if not isinstance(value, list) or not value:
        return None
    normalized_values = [normalized_uuid(item) for item in value]
    if any(item is None for item in normalized_values):
        return None
    normalized = tuple(sorted(str(item) for item in set(normalized_values)))
    if len(normalized) != len(value):
        return None
    return normalized


def sorted_unique_nonempty_strings(value: object) -> tuple[str, ...] | None:
    if not isinstance(value, list) or not value:
        return None
    if any(not isinstance(item, str) or not item for item in value):
        return None
    canonical = tuple(sorted(set(value)))
    if len(canonical) != len(value):
        return None
    return canonical


def validate_expected_build_manifest(
    payload: dict[str, Any],
    *,
    version: str,
    build_number: str,
    current_manifest_id: str | None = None,
    contract_fingerprint: str | None = None,
    valid_surfaces: set[str] | None = None,
    error: Callable[[str], Exception] = ExpectedBuildSchemaError,
) -> ValidatedExpectedBuild:
    def fail(message: str) -> None:
        raise error(message)

    if not isinstance(payload, dict) or set(payload) != EXPECTED_MANIFEST_KEYS:
        fail("expected signed build manifest is invalid")
    schema_version = payload.get("schemaVersion")
    if schema_version not in {EXPECTED_BUILD_SCHEMA_V1, EXPECTED_BUILD_SCHEMA_V2}:
        fail("expected signed build manifest is invalid")
    digest_domain = payload.get("digestDomain")
    expected_build_id = payload.get("expectedBuildId")
    unsigned = {key: value for key, value in payload.items() if key != "expectedBuildId"}
    if (
        payload.get("kind") != EXPECTED_BUILD_KIND
        or payload.get("algorithm") != SURFACE_MANIFEST_ALGORITHM
        or digest_domain != SURFACE_DIGEST_DOMAIN
        or not is_sha256(payload.get("sourceManifestId"))
        or not is_sha256(payload.get("contractFingerprint"))
        or not is_sha256(expected_build_id)
        or hash_parts(f"{digest_domain}/expected-build", [canonical_json(unsigned)])
        != expected_build_id
    ):
        fail("expected signed build manifest is invalid")
    if current_manifest_id is not None and payload.get("sourceManifestId") != current_manifest_id:
        fail("expected signed build manifest target is invalid")
    if contract_fingerprint is not None and payload.get("contractFingerprint") != contract_fingerprint:
        fail("expected signed build manifest target is invalid")
    source = payload.get("source")
    artifacts_payload = payload.get("artifacts")
    surfaces_payload = payload.get("surfaces")
    if (
        not isinstance(source, dict)
        or source.get("marketingVersion") != version
        or source.get("buildNumber") != build_number
        or not isinstance(artifacts_payload, list)
        or not isinstance(surfaces_payload, list)
    ):
        fail("expected signed build manifest target is invalid")

    artifact_keys = (
        EXPECTED_ARTIFACT_KEYS_V2
        if schema_version == EXPECTED_BUILD_SCHEMA_V2
        else EXPECTED_ARTIFACT_KEYS_V1
    )
    artifacts: dict[str, dict[str, Any]] = {}
    for artifact in artifacts_payload:
        if not isinstance(artifact, dict) or set(artifact) != artifact_keys:
            fail("expected signed build artifact is invalid")
        artifact_id = artifact.get("artifactId")
        executable_uuids = normalized_uuid_list(artifact.get("executableUUIDs"))
        if (
            not isinstance(artifact_id, str)
            or not artifact_id
            or artifact_id in artifacts
            or not isinstance(artifact.get("bundleIdentifier"), str)
            or not artifact.get("bundleIdentifier")
            or artifact.get("marketingVersion") != version
            or artifact.get("buildNumber") != build_number
            or artifact.get("codeSignatureValid") is not True
            or executable_uuids is None
        ):
            fail("expected signed build artifact is invalid")
        for key in ("executableSha256", "entitlementsSha256", "profileSha256"):
            if not is_sha256(artifact.get(key)):
                fail("expected signed build artifact is invalid")
        normalized_artifact = {**artifact, "executableUUIDs": executable_uuids}
        if schema_version == EXPECTED_BUILD_SCHEMA_V2:
            architectures = sorted_unique_nonempty_strings(artifact.get("architectures"))
            if (
                architectures is None
                or any(ARCHITECTURE_PATTERN.fullmatch(value) is None for value in architectures)
                or artifact.get("signingClass") not in DISTRIBUTION_SIGNING_CLASSES
            ):
                fail("expected signed build artifact is invalid")
            for key in (
                "bundleContractSha256",
                "signingContractSha256",
                "entitlementContractSha256",
                "profileCapabilitySha256",
            ):
                if not is_sha256(artifact.get(key)):
                    fail("expected signed build artifact is invalid")
            normalized_artifact["architectures"] = architectures
        artifacts[artifact_id] = normalized_artifact

    seen_surfaces: set[str] = set()
    for surface_payload in surfaces_payload:
        if not isinstance(surface_payload, dict) or set(surface_payload) != EXPECTED_SURFACE_KEYS:
            fail("expected signed build surface is invalid")
        surface = surface_payload.get("id")
        if not isinstance(surface, str) or not surface or surface in seen_surfaces:
            fail("expected signed build surface is invalid")
        if valid_surfaces is not None and surface not in valid_surfaces:
            fail("expected signed build surface is invalid")
        seen_surfaces.add(surface)
        artifact = artifacts.get(str(surface_payload.get("artifactId")))
        fingerprints = surface_payload.get("fingerprints")
        if (
            artifact is None
            or surface_payload.get("bundleIdentifier") != artifact.get("bundleIdentifier")
            or not isinstance(fingerprints, dict)
            or set(fingerprints) != FINGERPRINT_KEYS
            or any(not is_sha256(fingerprints.get(key)) for key in FINGERPRINT_KEYS)
        ):
            fail("expected signed build surface is invalid")

    return ValidatedExpectedBuild(payload=payload, artifacts=artifacts, surfaces=surfaces_payload)
