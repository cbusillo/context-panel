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
ARTIFACT_RISK_CODES = (
    "artifact-mapping-changed",
    "bundle-contract-changed",
    "signing-contract-changed",
    "entitlement-contract-changed",
    "profile-capability-changed",
    "architecture-loss",
    "unexplained-executable-drift",
    "artifact-evidence-unknown",
)


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


def derive_artifact_comparison(
    previous_payloads: list[dict[str, Any]] | None,
    current_payloads: list[dict[str, Any]] | None,
    *,
    previous_manifest_id: str,
    current_manifest_id: str,
    previous_contract_fingerprint: str,
    current_contract_fingerprint: str,
    previous_target: tuple[str, str],
    current_target: tuple[str, str],
    previous_surfaces: dict[str, dict[str, Any]],
    current_surfaces: dict[str, dict[str, Any]],
    runtime_capable_surface_ids: set[str],
    train: str,
    toolchain_changed: bool,
    exact_build_same: bool,
) -> dict[str, Any]:
    """Normalize signed-build evidence and derive root-only artifact policy fields."""

    def collect(
        payloads: list[dict[str, Any]] | None,
        *,
        manifest_id: str,
        contract_fingerprint: str,
        target: tuple[str, str],
        source_surfaces: dict[str, dict[str, Any]],
    ) -> tuple[str, list[str], dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
        if payloads is None:
            return "not-evaluated", [], {}, {}
        if not payloads:
            return "missing", [], {}, {}
        validated: list[ValidatedExpectedBuild] = []
        for payload in payloads:
            validated.append(
                validate_expected_build_manifest(
                    payload,
                    version=target[0],
                    build_number=target[1],
                    current_manifest_id=manifest_id,
                    contract_fingerprint=contract_fingerprint,
                    valid_surfaces=set(source_surfaces),
                )
            )
        ids = sorted(item.payload["expectedBuildId"] for item in validated)
        artifacts: dict[str, dict[str, Any]] = {}
        surfaces: dict[str, dict[str, Any]] = {}
        legacy = any(item.payload["schemaVersion"] != EXPECTED_BUILD_SCHEMA_V2 for item in validated)
        for item in validated:
            for artifact_id, artifact in item.artifacts.items():
                if artifact_id in artifacts:
                    raise ExpectedBuildSchemaError("expected signed build artifact is duplicated")
                artifacts[artifact_id] = artifact
            for surface in item.surfaces:
                surface_id = surface["id"]
                if surface_id in surfaces:
                    raise ExpectedBuildSchemaError("expected signed build surface is duplicated")
                source_surface = source_surfaces[surface_id]
                if (
                    surface["artifactId"] != source_surface.get("artifactId")
                    or surface["bundleIdentifier"] != source_surface.get("bundleIdentifier")
                    or surface["fingerprints"] != source_surface.get("fingerprints")
                ):
                    raise ExpectedBuildSchemaError("expected signed build surface does not bind source")
                surfaces[surface_id] = surface
        expected_artifacts = {str(surface.get("artifactId")) for surface in source_surfaces.values()}
        complete = set(surfaces) == set(source_surfaces) and set(artifacts) == expected_artifacts
        if legacy:
            return "legacy-incomplete", ids, artifacts, surfaces
        return ("complete" if complete else "missing"), ids, artifacts, surfaces

    previous_state, previous_ids, previous_artifacts, _ = collect(
        previous_payloads,
        manifest_id=previous_manifest_id,
        contract_fingerprint=previous_contract_fingerprint,
        target=previous_target,
        source_surfaces=previous_surfaces,
    )
    current_state, current_ids, current_artifacts, _ = collect(
        current_payloads,
        manifest_id=current_manifest_id,
        contract_fingerprint=current_contract_fingerprint,
        target=current_target,
        source_surfaces=current_surfaces,
    )
    evidence = {
        "previousState": previous_state,
        "currentState": current_state,
        "previousExpectedBuildIds": previous_ids,
        "currentExpectedBuildIds": current_ids,
    }
    if previous_state == current_state == "not-evaluated":
        return {
            "artifactEvidence": evidence,
            "artifactRiskCodes": [],
            "artifactRiskSurfaces": {},
            "escalationState": "resolved",
        }
    current_by_artifact = {
        artifact_id: sorted(
            surface_id for surface_id, surface in current_surfaces.items()
            if surface.get("artifactId") == artifact_id
        )
        for artifact_id in current_artifacts
    }
    risks: dict[str, list[str]] = {}
    complete = previous_state == current_state == "complete"
    if complete:
        mapping = sorted(
            surface_id for surface_id, surface in current_surfaces.items()
            if surface_id in previous_surfaces
            and previous_surfaces[surface_id].get("artifactId") != surface.get("artifactId")
        )
        if mapping:
            risks["artifact-mapping-changed"] = sorted(
                {
                    affected_surface
                    for surface_id in mapping
                    for affected_surface in current_by_artifact.get(
                        str(current_surfaces[surface_id].get("artifactId")),
                        [surface_id],
                    )
                }
            )
        for artifact_id in sorted(set(previous_artifacts) & set(current_artifacts)):
            previous_artifact = previous_artifacts[artifact_id]
            current_artifact = current_artifacts[artifact_id]
            affected = current_by_artifact.get(artifact_id, [])
            if not affected:
                continue
            comparable_surfaces = [
                surface_id for surface_id in affected if surface_id in previous_surfaces
            ]
            for key, code in (
                ("bundleContractSha256", "bundle-contract-changed"),
                ("signingContractSha256", "signing-contract-changed"),
                ("entitlementContractSha256", "entitlement-contract-changed"),
                ("profileCapabilitySha256", "profile-capability-changed"),
            ):
                if previous_artifact[key] != current_artifact[key]:
                    risks.setdefault(code, []).extend(affected)
            if set(previous_artifact["architectures"]) - set(current_artifact["architectures"]):
                risks.setdefault("architecture-loss", []).extend(affected)
            if (
                previous_artifact["executableSha256"] != current_artifact["executableSha256"]
                and exact_build_same
                and not toolchain_changed
                and comparable_surfaces
                and all(
                    previous_surfaces[surface_id]["fingerprints"]
                    == current_surfaces[surface_id]["fingerprints"]
                    for surface_id in comparable_surfaces
                )
            ):
                risks.setdefault("unexplained-executable-drift", []).extend(affected)
    else:
        unknown = sorted(
            surface_id for surface_id in runtime_capable_surface_ids
            if current_surfaces[surface_id].get("artifactId") not in (
                set(previous_artifacts) & set(current_artifacts)
            ) or previous_state != "complete" or current_state != "complete"
        )
        if unknown:
            risks["artifact-evidence-unknown"] = unknown
    codes = [code for code in ARTIFACT_RISK_CODES if code in risks]
    normalized = {code: sorted(set(risks[code])) for code in codes}
    return {
        "artifactEvidence": evidence,
        "artifactRiskCodes": codes,
        "artifactRiskSurfaces": normalized,
        "escalationState": "unknown-fail-closed" if "artifact-evidence-unknown" in codes else "resolved",
    }
