from __future__ import annotations

import hashlib
import json
import plistlib
import re
import subprocess
from pathlib import Path
from typing import Any, Callable, Sequence

from context_panel_expected_build import SIGNING_CLASSES, hash_parts

from .core import SurfacePolicyError, load_json_object, manifest_surface_map


CommandRunner = Callable[[Sequence[str]], subprocess.CompletedProcess[bytes]]
UUID_LINE_PATTERN = re.compile(
    rb"^UUID: ([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    rb"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}) \(([^)]+)\)",
    re.MULTILINE,
)
SIGNING_IDENTIFIER_PATTERN = re.compile(rb"^Identifier=(.+)$", re.MULTILINE)
TEAM_IDENTIFIER_PATTERN = re.compile(rb"^TeamIdentifier=(.+)$", re.MULTILINE)
AUTHORITY_PATTERN = re.compile(rb"^Authority=(.+)$", re.MULTILINE)
SIGNATURE_PATTERN = re.compile(rb"^Signature=(.+)$", re.MULTILINE)
ORDER_SENSITIVE_ENTITLEMENT_KEYS = frozenset({"keychain-access-groups"})


def run_command(arguments: Sequence[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        list(arguments),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_hash(payload: object) -> str:
    return sha256_bytes(
        json.dumps(
            payload,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    )


def info_plist_path(bundle: Path) -> Path:
    macos_path = bundle / "Contents/Info.plist"
    return macos_path if macos_path.is_file() else bundle / "Info.plist"


def resources_path(bundle: Path) -> Path:
    macos_path = bundle / "Contents/Resources"
    return macos_path if (bundle / "Contents").is_dir() else bundle


def executable_path(bundle: Path, info: dict[str, Any]) -> Path:
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable:
        raise SurfacePolicyError("artifact bundle executable name is missing")
    macos_path = bundle / "Contents/MacOS" / executable
    return macos_path if macos_path.is_file() else bundle / executable


def profile_path(bundle: Path, override: Path | None = None) -> Path:
    if override is not None:
        if override.is_file():
            return override
        raise SurfacePolicyError("artifact provisioning profile override is missing")
    for relative_path in ("Contents/embedded.provisionprofile", "embedded.mobileprovision"):
        candidate = bundle / relative_path
        if candidate.is_file():
            return candidate
    raise SurfacePolicyError("artifact provisioning profile is missing")


def plist_from_command_output(data: bytes, unavailable: str, invalid: str) -> Any:
    start = data.find(b"<?xml")
    if start < 0:
        start = data.find(b"bplist")
    if start < 0:
        raise SurfacePolicyError(unavailable)
    try:
        payload = plistlib.loads(data[start:])
    except Exception as error:
        raise SurfacePolicyError(invalid) from error
    return payload


def semantic_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): semantic_value(value[key]) for key in sorted(value)}
    if isinstance(value, (list, tuple, set)):
        members = [semantic_value(item) for item in value]
        by_key = {
            json.dumps(item, ensure_ascii=True, separators=(",", ":"), sort_keys=True): item
            for item in members
        }
        return [by_key[key] for key in sorted(by_key)]
    if isinstance(value, bytes):
        return value.hex()
    return value


def semantic_entitlements(value: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key in sorted(value):
        item = value[key]
        if key in ORDER_SENSITIVE_ENTITLEMENT_KEYS and isinstance(item, list):
            result[str(key)] = [semantic_value(member) for member in item]
        else:
            result[str(key)] = semantic_value(item)
    return result


def canonical_entitlements(data: bytes) -> dict[str, Any]:
    entitlements = plist_from_command_output(
        data,
        "artifact signed entitlements are unavailable",
        "artifact signed entitlements are invalid",
    )
    if not isinstance(entitlements, dict) or not entitlements:
        raise SurfacePolicyError("artifact signed entitlements are invalid")
    return semantic_entitlements(entitlements)


def canonical_entitlements_hash(data: bytes) -> str:
    entitlements = plist_from_command_output(
        data,
        "artifact signed entitlements are unavailable",
        "artifact signed entitlements are invalid",
    )
    if not isinstance(entitlements, dict) or not entitlements:
        raise SurfacePolicyError("artifact signed entitlements are invalid")
    canonical = plistlib.dumps(entitlements, fmt=plistlib.FMT_BINARY, sort_keys=True)
    return sha256_bytes(canonical)


def entitlement_contract_hash(entitlements: dict[str, Any]) -> str:
    return canonical_json_hash({"effectiveEntitlements": entitlements})


def signing_class(authorities: list[str], signature: str = "") -> str:
    if not authorities:
        if signature.lower() == "adhoc":
            return "ad-hoc"
        raise SurfacePolicyError("artifact signing authority is unavailable")
    leaf_authority = authorities[0].strip()
    for candidate in sorted(SIGNING_CLASSES - {"ad-hoc"}, key=len, reverse=True):
        if leaf_authority == candidate or leaf_authority.startswith(f"{candidate}:"):
            return candidate
    raise SurfacePolicyError("artifact signing class is unsupported")


def inspect_signing_metadata(
    bundle: Path,
    bundle_identifier: str,
    runner: CommandRunner,
) -> tuple[str, str, str]:
    result = runner(["/usr/bin/codesign", "-d", "--verbose=4", str(bundle)])
    if result.returncode != 0:
        raise SurfacePolicyError("artifact code signing metadata is unavailable")
    identifier = _first_metadata_value(SIGNING_IDENTIFIER_PATTERN, result.stderr)
    if identifier != bundle_identifier:
        raise SurfacePolicyError("artifact signing identifier does not match bundle identifier")
    team_identifier = _first_metadata_value(TEAM_IDENTIFIER_PATTERN, result.stderr)
    authorities = [match.decode("utf-8", "replace") for match in AUTHORITY_PATTERN.findall(result.stderr)]
    signature = _first_metadata_value(SIGNATURE_PATTERN, result.stderr)
    normalized_class = signing_class(authorities, signature)
    if normalized_class == "ad-hoc" or not team_identifier:
        raise SurfacePolicyError("artifact distribution signing identity is unavailable")
    team_identity_sha256 = hash_parts(
        "context-panel-artifact/signing-team/v1",
        [team_identifier],
    )
    contract = {
        "identifierMatchesBundleIdentifier": True,
        "signingClass": normalized_class,
        "teamIdentitySha256": team_identity_sha256,
    }
    return normalized_class, canonical_json_hash(contract), team_identifier


def _first_metadata_value(pattern: re.Pattern[bytes], data: bytes) -> str:
    match = pattern.search(data)
    return match.group(1).decode("utf-8", "replace").strip() if match else ""


def profile_payload(path: Path, runner: CommandRunner) -> dict[str, Any]:
    result = runner(["/usr/bin/security", "cms", "-D", "-i", str(path)])
    if result.returncode != 0:
        raise SurfacePolicyError("artifact provisioning profile is undecodable")
    payload = plist_from_command_output(
        result.stdout,
        "artifact provisioning profile is undecodable",
        "artifact provisioning profile is invalid",
    )
    if not isinstance(payload, dict) or not payload:
        raise SurfacePolicyError("artifact provisioning profile is invalid")
    return payload


def profile_capability_hash(payload: dict[str, Any]) -> str:
    effective_entitlements = payload.get("Entitlements")
    team_identifiers = payload.get("TeamIdentifier")
    application_prefixes = payload.get("ApplicationIdentifierPrefix")
    platforms = payload.get("Platform")
    if (
        not isinstance(effective_entitlements, dict)
        or not effective_entitlements
        or not isinstance(team_identifiers, list)
        or not team_identifiers
        or not isinstance(application_prefixes, list)
        or not application_prefixes
        or not isinstance(platforms, list)
        or not platforms
    ):
        raise SurfacePolicyError("artifact provisioning profile entitlements are invalid")
    contract = {
        "TeamIdentifier": semantic_value(team_identifiers),
        "ApplicationIdentifierPrefix": semantic_value(application_prefixes),
        "Platform": semantic_value(platforms),
        "ProvisionsAllDevices": bool(payload.get("ProvisionsAllDevices"))
        if "ProvisionsAllDevices" in payload
        else None,
        "Entitlements": semantic_entitlements(effective_entitlements),
    }
    return canonical_json_hash(contract)


def bundle_contract_hash(
    *,
    artifact_id: str,
    bundle_identifier: str,
    package_type: str,
    executable_name: str,
) -> str:
    return canonical_json_hash(
        {
            "artifactId": artifact_id,
            "bundleIdentifier": bundle_identifier,
            "packageType": package_type,
            "executableName": executable_name,
        }
    )


def inspect_bundle(
    bundle: Path,
    artifact_id: str,
    expected: dict[str, str],
    source_manifest_id: str,
    profile_override: Path | None = None,
    runner: CommandRunner = run_command,
) -> dict[str, Any]:
    info_path = info_plist_path(bundle)
    if not bundle.is_dir() or not info_path.is_file():
        raise SurfacePolicyError(f"archive artifact bundle is missing: {artifact_id}")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise SurfacePolicyError(f"archive artifact Info.plist is invalid: {artifact_id}") from error
    if not isinstance(info, dict):
        raise SurfacePolicyError(f"archive artifact Info.plist is invalid: {artifact_id}")
    actual_identity = {
        "bundleIdentifier": str(info.get("CFBundleIdentifier") or ""),
        "marketingVersion": str(info.get("CFBundleShortVersionString") or ""),
        "buildNumber": str(info.get("CFBundleVersion") or ""),
    }
    for key, expected_value in expected.items():
        if key in actual_identity and actual_identity[key] != expected_value:
            raise SurfacePolicyError(f"archive artifact identity mismatch: {artifact_id}: {key}")

    embedded_path = resources_path(bundle) / "ContextPanelSurfaceManifest.json"
    embedded_manifest = load_json_object(embedded_path, "embedded surface manifest")
    if embedded_manifest.get("manifestId") != source_manifest_id:
        raise SurfacePolicyError(f"archive artifact surface manifest mismatch: {artifact_id}")

    executable = executable_path(bundle, info)
    if not executable.is_file():
        raise SurfacePolicyError(f"archive artifact executable is missing: {artifact_id}")
    signature = runner(["/usr/bin/codesign", "--verify", "--strict", str(bundle)])
    if signature.returncode != 0:
        raise SurfacePolicyError(f"archive artifact code signature is invalid: {artifact_id}")
    signing_class_name, signing_contract_sha256, signing_team_identifier = inspect_signing_metadata(
        bundle,
        actual_identity["bundleIdentifier"],
        runner,
    )
    entitlements = runner(
        ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(bundle)]
    )
    if entitlements.returncode != 0:
        raise SurfacePolicyError(f"archive artifact entitlements are unavailable: {artifact_id}")
    canonical_signed_entitlements = canonical_entitlements(entitlements.stdout)
    uuids_result = runner(["/usr/bin/xcrun", "dwarfdump", "--uuid", str(executable)])
    if uuids_result.returncode != 0:
        raise SurfacePolicyError(f"archive artifact UUIDs are unavailable: {artifact_id}")
    uuid_entries = UUID_LINE_PATTERN.findall(uuids_result.stdout)
    uuids = sorted({match[0].decode("ascii").upper() for match in uuid_entries})
    architectures = sorted({match[1].decode("ascii").strip() for match in uuid_entries})
    if not uuids or not architectures or any(not architecture for architecture in architectures):
        raise SurfacePolicyError(f"archive artifact UUIDs are unavailable: {artifact_id}")
    embedded_profile = profile_path(bundle, profile_override)
    decoded_profile = profile_payload(embedded_profile, runner)
    profile_team_identifiers = decoded_profile.get("TeamIdentifier")
    if (
        not isinstance(profile_team_identifiers, list)
        or signing_team_identifier not in profile_team_identifiers
    ):
        raise SurfacePolicyError("artifact signing team does not match provisioning profile")

    return {
        "artifactId": artifact_id,
        **expected,
        "codeSignatureValid": True,
        "executableSha256": sha256_file(executable),
        "executableUUIDs": uuids,
        "entitlementsSha256": canonical_entitlements_hash(entitlements.stdout),
        "profileSha256": sha256_file(embedded_profile),
        "bundleContractSha256": bundle_contract_hash(
            artifact_id=artifact_id,
            bundle_identifier=actual_identity["bundleIdentifier"],
            package_type=str(info.get("CFBundlePackageType") or ""),
            executable_name=str(info.get("CFBundleExecutable") or ""),
        ),
        "signingClass": signing_class_name,
        "signingContractSha256": signing_contract_sha256,
        "entitlementContractSha256": entitlement_contract_hash(canonical_signed_entitlements),
        "profileCapabilitySha256": profile_capability_hash(decoded_profile),
        "architectures": architectures,
    }


def collect_archive_evidence(
    source_manifest: dict[str, Any],
    archive_path: Path,
    layout_name: str,
    profile_paths: dict[str, Path] | None = None,
    runner: CommandRunner = run_command,
) -> dict[str, Any]:
    source_manifest_id = str(source_manifest.get("manifestId") or "")
    source = source_manifest.get("source")
    archive_layouts = source_manifest.get("archiveLayouts")
    if not source_manifest_id or not isinstance(source, dict) or not isinstance(archive_layouts, dict):
        raise SurfacePolicyError("source manifest cannot describe archive evidence")
    layout = archive_layouts.get(layout_name)
    if not isinstance(layout, dict) or not layout:
        raise SurfacePolicyError(f"unknown archive layout: {layout_name}")
    profile_paths = profile_paths or {}
    unknown_profile_artifacts = sorted(set(profile_paths) - set(layout))
    if unknown_profile_artifacts:
        raise SurfacePolicyError(
            "profile overrides reference artifacts outside the archive layout: "
            + ", ".join(unknown_profile_artifacts)
        )
    surfaces = manifest_surface_map(source_manifest, "source")
    contracts: dict[str, dict[str, str]] = {}
    for surface in surfaces.values():
        artifact_id = str(surface.get("artifactId") or "")
        if artifact_id not in layout:
            continue
        contract = {
            "bundleIdentifier": str(surface.get("bundleIdentifier") or ""),
            "marketingVersion": str(source.get("marketingVersion") or ""),
            "buildNumber": str(source.get("buildNumber") or ""),
            "sourceCommit": str(source.get("commit") or ""),
            "configuration": str(source.get("configuration") or ""),
            "xcodeBuild": str(source.get("xcodeBuild") or ""),
            "treeState": str(source.get("treeState") or ""),
        }
        previous = contracts.get(artifact_id)
        if previous is not None and previous != contract:
            raise SurfacePolicyError(f"source manifest artifact contract drifted: {artifact_id}")
        contracts[artifact_id] = contract

    archive_root = archive_path.resolve()
    artifacts = []
    for artifact_id, relative_path in sorted(layout.items()):
        candidate = archive_root / str(relative_path)
        try:
            candidate.resolve().relative_to(archive_root)
        except ValueError as error:
            raise SurfacePolicyError(f"archive artifact path escapes the archive: {artifact_id}") from error
        artifact_contract = contracts.get(str(artifact_id))
        if artifact_contract is None:
            raise SurfacePolicyError(f"archive layout artifact contract is missing: {artifact_id}")
        artifacts.append(
            inspect_bundle(
                candidate,
                str(artifact_id),
                artifact_contract,
                source_manifest_id,
                profile_paths.get(str(artifact_id)),
                runner,
            )
        )
    return {
        "schemaVersion": 2,
        "sourceManifestId": source_manifest_id,
        "layout": layout_name,
        "archiveName": archive_path.name,
        "artifacts": artifacts,
    }
