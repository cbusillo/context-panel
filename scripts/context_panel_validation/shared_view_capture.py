from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import sys
import tempfile
import time
from typing import Any, Callable
from urllib.parse import urlencode
import uuid
import zlib

from context_panel_surface_manifest import SurfacePolicyError, embedded_manifest
from context_panel_surface_manifest.core import canonical_json as manifest_canonical_json
from context_panel_surface_manifest.core import hash_parts as manifest_hash_parts

from .models import CommandResult, EXIT_BLOCKED, EXIT_OK, EXIT_UNKNOWN, Runner, iso8601, utc_now
from .shared_view_evidence import (
    DEFAULT_MATRIX_PATH,
    DEFAULT_SURFACE_POLICY_PATH,
    PIXEL_DIFF_POLICY,
    SharedViewCell,
    SharedViewEvidenceError,
    SharedViewMatrix,
    SurfacePolicySurface,
    canonical_json_hash,
    load_shared_view_matrix,
    load_surface_policy,
    plan_shared_view_evidence,
    project_shared_view_requirements,
    shared_view_requirement_id,
)
from .system import SubprocessRunner


REPO_ROOT = Path(__file__).resolve().parents[2]
CAPTURE_CONFIG_SCHEMA_VERSION = 2
CAPTURE_CONFIG_KIND = "context-panel-shared-view-capture-config"
CAPTURE_RECEIPT_SCHEMA_VERSION = 1
CAPTURE_RECEIPT_KIND = "context-panel-shared-view-capture-receipt"
REQUIREMENTS_SCHEMA_VERSION = 1
REQUIREMENTS_KIND = "context-panel-visual-review-requirements"
REQUIREMENTS_DIGEST_DOMAIN = "context-panel-shared-view-capture-requirements/v1"
EMBEDDED_MANIFEST_DIGEST_DOMAIN = "context-panel-shared-view-capture-embedded-manifest/v1"
APP_BUNDLE_IDENTIFIER = "com.shinycomputers.contextpanel"
WATCH_APP_BUNDLE_IDENTIFIER = "com.shinycomputers.contextpanel.watch"
SIMCTL_CATALOG_TIMEOUT = 30
MAX_SIMULATOR_DEVICE_COUNT = 256
SIMCTL_CREATE_TIMEOUT = 30
SIMCTL_BOOT_TIMEOUT = 60
SIMCTL_BOOTSTATUS_TIMEOUT = 300
SIMCTL_INSTALL_TIMEOUT = 120
SIMCTL_VISIONOS_INSTALL_TIMEOUT = 300
SIMCTL_CONTAINER_TIMEOUT = 120
SIMCTL_TERMINATE_TIMEOUT = 30
SIMCTL_UI_TIMEOUT = 30
SIMCTL_LAUNCH_TIMEOUT = 60
SIMCTL_VISIONOS_LAUNCH_TIMEOUT = 300
SIMCTL_VISIONOS_SHUTDOWN_TIMEOUT = 60
SIMCTL_VISIONOS_ERASE_TIMEOUT = 300
SIMCTL_VISIONOS_BOOTSTATUS_TIMEOUT = 300
SIMCTL_SCREENSHOT_TIMEOUT = 60
SIMCTL_CLEANUP_TIMEOUT = 30
XCODEBUILD_VISIONOS_CAPTURE_TIMEOUT = 600
XCRESULT_EXPORT_TIMEOUT = 60
CAPTURE_SETTLE_SECONDS = 3.0
MAX_STABILITY_SAMPLE_COUNT = 6
VISIONOS_UI_TEST_TARGET = "ContextPanelCompanionSharedViewCaptureUITests"
VISIONOS_UI_TEST_CLASS = "ContextPanelCompanionSharedViewCaptureUITests"
VISIONOS_UI_TEST_METHOD = "testCaptureSharedView"
VISIONOS_UI_TEST_IDENTIFIER = (
    f"{VISIONOS_UI_TEST_TARGET}/{VISIONOS_UI_TEST_CLASS}/{VISIONOS_UI_TEST_METHOD}"
)
VISIONOS_UI_TEST_ENVIRONMENT = {
    "url": "CONTEXT_PANEL_SHARED_VIEW_URL",
    "fixture": "CONTEXT_PANEL_SHARED_VIEW_FIXTURE",
    "fixture_title": "CONTEXT_PANEL_SHARED_VIEW_FIXTURE_TITLE",
    "family": "CONTEXT_PANEL_SHARED_VIEW_FAMILY",
    "family_title": "CONTEXT_PANEL_SHARED_VIEW_FAMILY_TITLE",
    "appearance": "CONTEXT_PANEL_SHARED_VIEW_APPEARANCE",
    "appearance_title": "CONTEXT_PANEL_SHARED_VIEW_APPEARANCE_TITLE",
    "presentation": "CONTEXT_PANEL_SHARED_VIEW_PRESENTATION",
    "presentation_title": "CONTEXT_PANEL_SHARED_VIEW_PRESENTATION_TITLE",
}
VALIDATION_FIXTURE_TITLES = {
    "healthy": "Healthy portfolio",
    "reset-visible": "Reset pressure",
    "cache-visible": "Cache telemetry",
    "stale": "Saved stale data",
    "loading": "Refreshing",
    "missing": "No configured limits",
    "failed": "Refresh failed",
    "dense-accounts": "Dense accounts",
    "fit-fallback": "Fit fallback",
}
VALIDATION_FAMILY_TITLES = {
    "systemSmall": "Small",
    "systemMedium": "Medium",
    "systemLarge": "Large",
}
VALIDATION_APPEARANCE_TITLES = {
    "adaptive": "System",
    "light": "Light",
    "dark": "Dark",
}
VALIDATION_PRESENTATION_TITLES = {
    "overview": "Overview",
    "detail": "Detail",
    "reconnect": "Reconnect",
    "diagnostics": "Diagnostics",
    "settings": "Settings",
    "widget": "Widget",
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_PNG_FILE_BYTES = 64 * 1024 * 1024
MAX_PNG_DECOMPRESSED_BYTES = 256 * 1024 * 1024
MIN_VISIONOS_CAPTURE_DIMENSION = 100
MAX_PNG_DIMENSION = 8_192
MAX_PNG_PIXELS = 33_554_432
MAX_PNG_CHUNKS = 4_096
MAX_JSON_FILE_BYTES = 16 * 1024 * 1024
MAX_PLIST_FILE_BYTES = 4 * 1024 * 1024
MAX_BUNDLE_FILE_BYTES = 512 * 1024 * 1024
MAX_BUNDLE_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_BUNDLE_ENTRIES = 100_000
SOURCE_MANIFEST_ROOT_KEYS = set(
    "schemaVersion algorithm digestDomain contractFingerprint source toolchain archiveLayouts "
    "evidencePolicy artifactEvidenceContract files ignoredInputs surfaces manifestId".split()
)
SOURCE_IDENTITY_KEYS = set(
    "marketingVersion buildNumber commit configuration xcodeBuild treeState policySha256 "
    "projectSourceSha256".split()
)
EXPECTED_ARTIFACT_KEYS = set(
    "artifactId bundleIdentifier marketingVersion buildNumber sourceCommit configuration "
    "xcodeBuild treeState".split()
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SIMULATOR_UDID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
CAPTURE_RUN_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$")
BUNDLE_VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){0,2}$")
RUNTIME_IDENTIFIER_PATTERN = re.compile(
    r"^com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9][A-Za-z0-9.-]{0,127}$"
)
DEVICE_TYPE_IDENTIFIER_PATTERN = re.compile(
    r"^com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9][A-Za-z0-9.-]{0,127}$"
)


class SharedViewCaptureError(SharedViewEvidenceError):
    pass


@dataclass(frozen=True)
class CaptureProfile:
    name: str
    runtime_identifier: str
    device_type_identifier: str
    app_bundle: Path
    bundle_identifier: str
    executable_sha256: str
    bundle_sha256: str
    manifest_id: str
    manifest_digest: str
    contract_fingerprint: str
    manifest_surfaces: frozenset[str]
    version: str
    build: str
    ui_test_run: Path | None
    ui_test_products_sha256: str | None

    def public_dict(
        self,
        metadata: SimulatorProfileMetadata | None,
        cleanup_status: str,
    ) -> dict[str, object]:
        return {
            "profile": self.name,
            "runtimeIdentifier": self.runtime_identifier if metadata is not None else None,
            "runtimeName": metadata.runtime_name if metadata is not None else None,
            "runtimePlatform": metadata.runtime_platform if metadata is not None else None,
            "deviceTypeIdentifier": self.device_type_identifier if metadata is not None else None,
            "deviceTypeName": metadata.device_type_name if metadata is not None else None,
            "productFamily": metadata.product_family if metadata is not None else None,
            "appBundleIdentifier": self.bundle_identifier,
            "appExecutableSHA256": self.executable_sha256,
            "appBundleSHA256": self.bundle_sha256,
            "appManifestID": self.manifest_id,
            "appSurfaceManifestDigest": self.manifest_digest,
            "appContractFingerprint": self.contract_fingerprint,
            "appVersion": self.version,
            "appBuild": self.build,
            "uiTestProductsSHA256": self.ui_test_products_sha256,
            "cleanupStatus": cleanup_status,
        }


@dataclass(frozen=True)
class SimulatorProfileMetadata:
    runtime_name: str
    runtime_platform: str
    device_type_name: str
    product_family: str


@dataclass(frozen=True)
class CaptureRequirement:
    requirement_id: str
    surface: str
    cell_id: str
    fixture_contract_id: str
    fixture_id: str
    family: str
    appearance: str
    presentation: str
    accessibility: str


@dataclass(frozen=True)
class SimulatorCaptureProfile:
    surface_prefix: str
    bundle_identifier: str
    bundle_platform: str
    device_family: int
    runtime_platforms: tuple[str, ...]
    product_family: str
    route_kind: str
    applies_simulator_appearance: bool


SIMULATOR_CAPTURE_PROFILES = {
    "ios": SimulatorCaptureProfile(
        surface_prefix="ios.",
        bundle_identifier=APP_BUNDLE_IDENTIFIER,
        bundle_platform="iPhoneSimulator",
        device_family=1,
        runtime_platforms=("iOS",),
        product_family="iPhone",
        route_kind="xcuitest",
        applies_simulator_appearance=True,
    ),
    "ipados": SimulatorCaptureProfile(
        surface_prefix="ipados.",
        bundle_identifier=APP_BUNDLE_IDENTIFIER,
        bundle_platform="iPhoneSimulator",
        device_family=2,
        runtime_platforms=("iOS",),
        product_family="iPad",
        route_kind="xcuitest",
        applies_simulator_appearance=True,
    ),
    "visionos": SimulatorCaptureProfile(
        surface_prefix="visionos.",
        bundle_identifier=APP_BUNDLE_IDENTIFIER,
        bundle_platform="XRSimulator",
        device_family=7,
        runtime_platforms=("xrOS", "visionOS"),
        product_family="Apple Vision",
        route_kind="xcuitest",
        applies_simulator_appearance=True,
    ),
    "watchos": SimulatorCaptureProfile(
        surface_prefix="watchos.",
        bundle_identifier=WATCH_APP_BUNDLE_IDENTIFIER,
        bundle_platform="WatchSimulator",
        device_family=4,
        runtime_platforms=("watchOS",),
        product_family="Apple Watch",
        route_kind="launch",
        applies_simulator_appearance=False,
    ),
}
SUPPORTED_PROFILES = tuple(SIMULATOR_CAPTURE_PROFILES)
COMPANION_UI_TEST_PROFILES = frozenset({"ios", "ipados", "visionos"})


@dataclass(frozen=True)
class CapturePlan:
    current_manifest_id: str
    requirements_digest: str
    requirements: tuple[CaptureRequirement, ...]


@dataclass(frozen=True)
class PNGSnapshot:
    byte_count: int
    artifact_digest: str
    pixel_digest: str
    width: int
    height: int


@dataclass(frozen=True)
class ProfileCaptureOutcome:
    results: dict[str, dict[str, object]]
    cleanup_status: str


def _simulator_capture_profile(name: str) -> SimulatorCaptureProfile:
    try:
        return SIMULATOR_CAPTURE_PROFILES[name]
    except KeyError as error:
        raise SharedViewCaptureError("capture simulator profile is invalid") from error


def _load_json_object(path: Path, label: str) -> dict[str, Any]:
    data = _read_bounded_file(path, label, MAX_JSON_FILE_BYTES)
    try:
        payload = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise SharedViewCaptureError(f"{label} is unavailable or invalid") from error
    if not isinstance(payload, dict):
        raise SharedViewCaptureError(f"{label} is invalid")
    return payload


def _read_bounded_file(path: Path, label: str, maximum_bytes: int) -> bytes:
    descriptor = -1
    try:
        descriptor = os.open(
            path.expanduser(),
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode) or not 0 < file_stat.st_size <= maximum_bytes:
            raise SharedViewCaptureError(f"{label} is unavailable or invalid")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            data = stream.read(maximum_bytes + 1)
    except OSError as error:
        raise SharedViewCaptureError(f"{label} is unavailable or invalid") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(data) != file_stat.st_size:
        raise SharedViewCaptureError(f"{label} is unavailable or invalid")
    return data


def _require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise SharedViewCaptureError(f"{label} is invalid")
    return value


def _require_sha256(value: object, label: str) -> str:
    value = _require_string(value, label)
    if not SHA256_PATTERN.fullmatch(value):
        raise SharedViewCaptureError(f"{label} is invalid")
    return value


def _reject_symlink_ancestors(path: Path, label: str) -> None:
    for candidate in (path, *path.parents):
        if candidate.is_symlink():
            raise SharedViewCaptureError(f"{label} must not use symlinks")


def _absolute_existing_directory(path: Path, label: str) -> Path:
    if not path.is_absolute() or path.is_symlink() or not path.is_dir():
        raise SharedViewCaptureError(f"{label} is invalid")
    _reject_symlink_ancestors(path, label)
    return path.resolve()


def _absolute_existing_file(path: Path, label: str, maximum_bytes: int) -> Path:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise SharedViewCaptureError(f"{label} is invalid")
    _reject_symlink_ancestors(path, label)
    try:
        file_stat = path.stat()
    except OSError as error:
        raise SharedViewCaptureError(f"{label} is invalid") from error
    if not stat.S_ISREG(file_stat.st_mode) or not 0 < file_stat.st_size <= maximum_bytes:
        raise SharedViewCaptureError(f"{label} is invalid")
    return path.resolve()


def _resolved_test_product_path(
    value: object,
    test_root: Path,
    label: str,
    *,
    test_host: Path | None = None,
) -> Path:
    path_value = _require_string(value, label)
    replacements = {"__TESTROOT__": str(test_root)}
    if test_host is not None:
        replacements["__TESTHOST__"] = str(test_host)
    for marker, replacement in replacements.items():
        path_value = path_value.replace(marker, replacement)
    if "__" in path_value:
        raise SharedViewCaptureError("capture visionOS UI test run is invalid")
    path = Path(path_value)
    if not path.is_absolute() or path.is_symlink():
        raise SharedViewCaptureError("capture visionOS UI test run is invalid")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise SharedViewCaptureError("capture visionOS UI test run is invalid") from error
    if resolved != test_root and test_root not in resolved.parents:
        raise SharedViewCaptureError("capture visionOS UI test run is invalid")
    return resolved


def _validate_visionos_ui_test_run(path: Path, app_bundle: Path) -> None:
    try:
        payload = plistlib.loads(
            _read_bounded_file(path, "capture visionOS UI test run", MAX_PLIST_FILE_BYTES)
        )
    except plistlib.InvalidFileException as error:
        raise SharedViewCaptureError("capture visionOS UI test run is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {
        "__xctestrun_metadata__",
        VISIONOS_UI_TEST_TARGET,
    }:
        raise SharedViewCaptureError("capture visionOS UI test run is invalid")
    target = payload[VISIONOS_UI_TEST_TARGET]
    if (
        not isinstance(target, dict)
        or target.get("BlueprintName") != VISIONOS_UI_TEST_TARGET
        or target.get("ProductModuleName") != VISIONOS_UI_TEST_TARGET
        or target.get("IsUITestBundle") is not True
        or target.get("IsXCTRunnerHostedTestBundle") is not True
        or not isinstance(target.get("EnvironmentVariables"), dict)
        or not isinstance(target.get("UITargetAppEnvironmentVariables"), dict)
    ):
        raise SharedViewCaptureError("capture visionOS UI test run is invalid")
    test_root = path.parent
    resolved_app = _resolved_test_product_path(
        target.get("UITargetAppPath"),
        test_root,
        "capture visionOS UI target app",
    )
    if resolved_app != app_bundle:
        raise SharedViewCaptureError("capture visionOS UI target app does not match app bundle")
    test_host = _resolved_test_product_path(
        target.get("TestHostPath"),
        test_root,
        "capture visionOS UI test host",
    )
    test_bundle = _resolved_test_product_path(
        target.get("TestBundlePath"),
        test_root,
        "capture visionOS UI test bundle",
        test_host=test_host,
    )
    if not test_host.is_dir() or test_host.suffix != ".app":
        raise SharedViewCaptureError("capture visionOS UI test host is invalid")
    if not test_bundle.is_dir() or test_bundle.suffix != ".xctest":
        raise SharedViewCaptureError("capture visionOS UI test bundle is invalid")
    dependent_paths = target.get("DependentProductPaths")
    if not isinstance(dependent_paths, list) or not dependent_paths:
        raise SharedViewCaptureError("capture visionOS UI test products are invalid")
    resolved_dependencies = {
        _resolved_test_product_path(
            item,
            test_root,
            "capture visionOS UI test product",
            test_host=test_host,
        )
        for item in dependent_paths
    }
    if not {app_bundle, test_host, test_bundle}.issubset(resolved_dependencies):
        raise SharedViewCaptureError("capture visionOS UI test products are invalid")


def _stream_sha256(path: Path, label: str) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise SharedViewCaptureError(f"{label} is unreadable") from error
    return digest.hexdigest()


def _bundle_sha256(path: Path, *, include_modes: bool = True) -> str:
    digest = hashlib.sha256()
    try:
        bundle_root = path.resolve(strict=True)
        candidates: list[Path] = []
        total_file_bytes = 0
        for candidate in path.rglob("*"):
            if len(candidates) >= MAX_BUNDLE_ENTRIES:
                raise SharedViewCaptureError("capture app bundle is invalid")
            candidates.append(candidate)
        for candidate in sorted(candidates, key=lambda item: item.relative_to(path).as_posix()):
            relative = candidate.relative_to(path).as_posix().encode()
            candidate_stat = candidate.lstat()
            if stat.S_ISDIR(candidate_stat.st_mode):
                kind, content = b"D", b""
            elif stat.S_ISREG(candidate_stat.st_mode):
                total_file_bytes += candidate_stat.st_size
                if (
                    candidate_stat.st_size > MAX_BUNDLE_FILE_BYTES
                    or total_file_bytes > MAX_BUNDLE_TOTAL_BYTES
                ):
                    raise SharedViewCaptureError("capture app bundle is invalid")
                kind, content = b"F", None
            elif stat.S_ISLNK(candidate_stat.st_mode):
                link_target = os.readlink(candidate)
                if Path(link_target).is_absolute():
                    raise SharedViewCaptureError("capture app bundle is invalid")
                resolved_target = (candidate.parent / link_target).resolve(strict=True)
                if resolved_target != bundle_root and bundle_root not in resolved_target.parents:
                    raise SharedViewCaptureError("capture app bundle is invalid")
                kind, content = b"L", link_target.encode()
            else:
                raise SharedViewCaptureError("capture app bundle is invalid")
            digest.update(kind + len(relative).to_bytes(8, "big") + relative)
            if include_modes:
                digest.update(stat.S_IMODE(candidate_stat.st_mode).to_bytes(4, "big"))
            content_length = candidate_stat.st_size if content is None else len(content)
            digest.update(content_length.to_bytes(8, "big"))
            if content is None:
                with candidate.open("rb") as stream:
                    while chunk := stream.read(1024 * 1024):
                        digest.update(chunk)
            else:
                digest.update(content)
    except SharedViewCaptureError:
        raise
    except (OSError, RuntimeError, ValueError) as error:
        raise SharedViewCaptureError("capture app bundle is unreadable") from error
    return digest.hexdigest()


def _embedded_manifest_metadata(path: Path) -> tuple[str, str, str, frozenset[str]]:
    resources = path / "Contents" / "Resources" if (path / "Contents").is_dir() else path
    manifest_path = resources / "ContextPanelSurfaceManifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise SharedViewCaptureError("capture app surface manifest is invalid")
    payload = _load_json_object(manifest_path, "capture app surface manifest")
    if not isinstance(payload, dict) or set(payload) != {
        "schemaVersion", "kind", "manifestId", "contractFingerprint", "surfaces"
    } or payload.get("schemaVersion") != 1 or payload.get("kind") != "context-panel-surface-build-intent":
        raise SharedViewCaptureError("capture app surface manifest is invalid")
    manifest_id = _require_sha256(payload.get("manifestId"), "capture app surface manifest identifier")
    contract_fingerprint = _require_sha256(
        payload.get("contractFingerprint"), "capture app surface contract fingerprint"
    )
    raw_surfaces = payload.get("surfaces")
    if not isinstance(raw_surfaces, list) or not raw_surfaces:
        raise SharedViewCaptureError("capture app surface manifest is invalid")
    surface_ids: set[str] = set()
    for raw_surface in raw_surfaces:
        if not isinstance(raw_surface, dict) or set(raw_surface) != {
            "id", "artifactId", "bundleIdentifier", "fingerprints"
        }:
            raise SharedViewCaptureError("capture app surface manifest is invalid")
        surface_id = _require_string(raw_surface.get("id"), "capture app surface identifier")
        _require_string(raw_surface.get("artifactId"), "capture app surface artifact identifier")
        _require_string(raw_surface.get("bundleIdentifier"), "capture app surface bundle identifier")
        fingerprints = raw_surface.get("fingerprints")
        if surface_id in surface_ids or not isinstance(fingerprints, dict) or set(fingerprints) != {
            "render", "runtime", "placement", "combined"
        }:
            raise SharedViewCaptureError("capture app surface manifest is invalid")
        for kind in ("render", "runtime", "placement", "combined"):
            _require_sha256(fingerprints.get(kind), f"capture app surface {kind} fingerprint")
        surface_ids.add(surface_id)
    return (
        manifest_id,
        canonical_json_hash(EMBEDDED_MANIFEST_DIGEST_DOMAIN, payload),
        contract_fingerprint,
        frozenset(surface_ids),
    )


def _expected_embedded_manifest(
    path: Path,
    policy: dict[str, Any],
    policy_sha256: str,
) -> tuple[dict[str, Any], str, str]:
    manifest = _load_json_object(path, "current surface manifest")
    manifest_id = manifest.get("manifestId")
    digest_domain = manifest.get("digestDomain")
    source = manifest.get("source")
    surfaces = manifest.get("surfaces")
    files = manifest.get("files")
    if (
        set(manifest) != SOURCE_MANIFEST_ROOT_KEYS
        or type(manifest.get("schemaVersion")) is not int
        or manifest.get("schemaVersion") != 1
        or any(
            manifest.get(key) != policy.get(key)
            for key in ("algorithm", "digestDomain", "toolchain", "archiveLayouts", "evidencePolicy")
        )
        or manifest.get("ignoredInputs") != (policy.get("inventory") or {}).get("ignoredInputs", [])
        or not isinstance(source, dict)
        or set(source) != SOURCE_IDENTITY_KEYS
        or source.get("treeState") not in {"clean", "dirty", "unknown"}
        or source.get("policySha256") != policy_sha256
        or not SHA256_PATTERN.fullmatch(str(source.get("projectSourceSha256") or ""))
        or any(
            not isinstance(manifest.get(key), dict)
            for key in ("toolchain", "archiveLayouts", "evidencePolicy", "artifactEvidenceContract")
        )
        or not isinstance(files, dict)
        or not files
        or any(
            not isinstance(file_path, str)
            or not file_path
            or Path(file_path).is_absolute()
            or ".." in Path(file_path).parts
            or not SHA256_PATTERN.fullmatch(str(file_digest))
            for file_path, file_digest in files.items()
        )
        or not isinstance(surfaces, list)
        or not surfaces
    ):
        raise SharedViewCaptureError("current surface manifest is invalid")
    source_values = {
        key: _require_string(source.get(key), f"current surface manifest source {key}")
        for key in (
            "marketingVersion",
            "buildNumber",
            "commit",
            "configuration",
            "xcodeBuild",
        )
    }
    _require_sha256(
        manifest.get("contractFingerprint"),
        "current surface manifest contract fingerprint",
    )
    for raw_surface in surfaces:
        if not isinstance(raw_surface, dict):
            raise SharedViewCaptureError("current surface manifest is invalid")
        artifact_id = _require_string(
            raw_surface.get("artifactId"), "current surface manifest artifact identifier"
        )
        bundle_identifier = _require_string(
            raw_surface.get("bundleIdentifier"), "current surface manifest bundle identifier"
        )
        artifact = raw_surface.get("expectedArtifact")
        if not isinstance(artifact, dict) or set(artifact) != EXPECTED_ARTIFACT_KEYS:
            raise SharedViewCaptureError("current surface manifest expected artifact is invalid")
        if artifact != {
            "artifactId": artifact_id,
            "bundleIdentifier": bundle_identifier,
            "marketingVersion": source_values["marketingVersion"],
            "buildNumber": source_values["buildNumber"],
            "sourceCommit": source_values["commit"],
            "configuration": source_values["configuration"],
            "xcodeBuild": source_values["xcodeBuild"],
            "treeState": source["treeState"],
        }:
            raise SharedViewCaptureError("current surface manifest expected artifact is invalid")
    unhashed_manifest = dict(manifest)
    unhashed_manifest.pop("manifestId", None)
    if (
        not isinstance(digest_domain, str)
        or not digest_domain
        or not isinstance(manifest_id, str)
        or manifest_hash_parts(
            f"{digest_domain}/manifest",
            [manifest_canonical_json(unhashed_manifest)],
        )
        != manifest_id
    ):
        raise SharedViewCaptureError("current surface manifest identity is invalid")
    try:
        return (
            embedded_manifest(manifest),
            source_values["marketingVersion"],
            source_values["buildNumber"],
        )
    except SurfacePolicyError as error:
        raise SharedViewCaptureError("current surface manifest is invalid") from error


def _app_metadata(
    path: Path,
    profile_name: str,
    *,
    include_modes: bool = True,
) -> tuple[str, str, str, str, str, frozenset[str], str, str, str]:
    info_path = path / "Info.plist"
    if not info_path.is_file() or info_path.is_symlink():
        raise SharedViewCaptureError("capture app bundle Info.plist is invalid")
    try:
        info = plistlib.loads(
            _read_bounded_file(info_path, "capture app bundle Info.plist", MAX_PLIST_FILE_BYTES)
        )
    except (OSError, plistlib.InvalidFileException) as error:
        raise SharedViewCaptureError("capture app bundle Info.plist is invalid") from error
    if not isinstance(info, dict):
        raise SharedViewCaptureError("capture app bundle Info.plist is invalid")
    bundle_identifier = _require_string(info.get("CFBundleIdentifier"), "capture app bundle identifier")
    capture_profile = _simulator_capture_profile(profile_name)
    if bundle_identifier != capture_profile.bundle_identifier:
        raise SharedViewCaptureError("capture app bundle identifier is invalid")
    executable_name = _require_string(info.get("CFBundleExecutable"), "capture app executable")
    if (
        executable_name in {".", ".."}
        or Path(executable_name).name != executable_name
        or "/" in executable_name
        or "\\" in executable_name
    ):
        raise SharedViewCaptureError("capture app executable is invalid")
    version = _require_string(info.get("CFBundleShortVersionString"), "capture app version")
    build = _require_string(info.get("CFBundleVersion"), "capture app build")
    if (
        len(version) > 64
        or len(build) > 64
        or not BUNDLE_VERSION_PATTERN.fullmatch(version)
        or not BUNDLE_VERSION_PATTERN.fullmatch(build)
    ):
        raise SharedViewCaptureError("capture app version metadata is invalid")
    supported_platforms = info.get("CFBundleSupportedPlatforms")
    device_families = info.get("UIDeviceFamily")
    if (
        not isinstance(supported_platforms, list)
        or not supported_platforms
        or any(not isinstance(value, str) or not value for value in supported_platforms)
        or len(supported_platforms) != len(set(supported_platforms))
        or capture_profile.bundle_platform not in supported_platforms
        or not isinstance(device_families, list)
        or not device_families
        or any(type(value) is not int or value <= 0 for value in device_families)
        or len(device_families) != len(set(device_families))
        or capture_profile.device_family not in device_families
    ):
        raise SharedViewCaptureError("capture app platform metadata is invalid")
    executable = path / executable_name
    try:
        executable_stat = executable.lstat()
        resolved_executable = executable.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SharedViewCaptureError("capture app executable is invalid") from error
    if (
        stat.S_ISLNK(executable_stat.st_mode)
        or not stat.S_ISREG(executable_stat.st_mode)
        or resolved_executable.parent != path
    ):
        raise SharedViewCaptureError("capture app executable is invalid")
    manifest_id, manifest_digest, contract_fingerprint, manifest_surfaces = (
        _embedded_manifest_metadata(path)
    )
    bundle_sha256 = _bundle_sha256(path, include_modes=include_modes)
    return (
        bundle_identifier,
        _stream_sha256(executable, "capture app executable"),
        bundle_sha256,
        manifest_id,
        manifest_digest,
        manifest_surfaces,
        contract_fingerprint,
        version,
        build,
    )


def load_capture_config(path: Path) -> dict[str, CaptureProfile]:
    payload = _load_json_object(path, "shared-view capture config")
    if set(payload) != {"schemaVersion", "kind", "profiles"}:
        raise SharedViewCaptureError("shared-view capture config root keys are invalid")
    if (
        type(payload["schemaVersion"]) is not int
        or payload["schemaVersion"] != CAPTURE_CONFIG_SCHEMA_VERSION
        or payload["kind"] != CAPTURE_CONFIG_KIND
    ):
        raise SharedViewCaptureError("shared-view capture config identity is invalid")
    raw_profiles = payload["profiles"]
    if not isinstance(raw_profiles, dict) or not set(raw_profiles).issubset(SUPPORTED_PROFILES):
        raise SharedViewCaptureError("shared-view capture config profiles are invalid")
    profiles: dict[str, CaptureProfile] = {}
    for name in SUPPORTED_PROFILES:
        if name not in raw_profiles:
            continue
        raw_profile = raw_profiles[name]
        expected_profile_keys = {
            "runtimeIdentifier",
            "deviceTypeIdentifier",
            "appBundle",
        }
        if name in COMPANION_UI_TEST_PROFILES:
            expected_profile_keys.add("uiTestRun")
        if not isinstance(raw_profile, dict) or set(raw_profile) != expected_profile_keys:
            raise SharedViewCaptureError("shared-view capture profile keys are invalid")
        app_bundle = _absolute_existing_directory(
            Path(_require_string(raw_profile["appBundle"], "capture app bundle")),
            "capture app bundle",
        )
        if app_bundle.suffix != ".app":
            raise SharedViewCaptureError("capture app bundle is invalid")
        (
            bundle_identifier,
            executable_sha256,
            bundle_sha256,
            manifest_id,
            manifest_digest,
            manifest_surfaces,
            contract_fingerprint,
            version,
            build,
        ) = _app_metadata(app_bundle, name)
        runtime_identifier = _require_string(
            raw_profile["runtimeIdentifier"], "capture runtime identifier"
        )
        device_type_identifier = _require_string(
            raw_profile["deviceTypeIdentifier"], "capture device type identifier"
        )
        if (
            not RUNTIME_IDENTIFIER_PATTERN.fullmatch(runtime_identifier)
            or not DEVICE_TYPE_IDENTIFIER_PATTERN.fullmatch(device_type_identifier)
        ):
            raise SharedViewCaptureError("capture simulator identifier is invalid")
        ui_test_run: Path | None = None
        ui_test_products_sha256: str | None = None
        if name in COMPANION_UI_TEST_PROFILES:
            ui_test_run = _absolute_existing_file(
                Path(_require_string(raw_profile["uiTestRun"], "capture companion UI test run")),
                "capture companion UI test run",
                MAX_PLIST_FILE_BYTES,
            )
            test_root = _absolute_existing_directory(
                ui_test_run.parent,
                "capture companion UI test products",
            )
            if app_bundle != test_root and test_root not in app_bundle.parents:
                raise SharedViewCaptureError(
                    "capture companion UI test products do not contain app bundle"
                )
            _validate_visionos_ui_test_run(ui_test_run, app_bundle)
            ui_test_products_sha256 = _bundle_sha256(test_root)
        profiles[name] = CaptureProfile(
            name=name,
            runtime_identifier=runtime_identifier,
            device_type_identifier=device_type_identifier,
            app_bundle=app_bundle,
            bundle_identifier=bundle_identifier,
            executable_sha256=executable_sha256,
            bundle_sha256=bundle_sha256,
            manifest_id=manifest_id,
            manifest_digest=manifest_digest,
            contract_fingerprint=contract_fingerprint,
            manifest_surfaces=manifest_surfaces,
            version=version,
            build=build,
            ui_test_run=ui_test_run,
            ui_test_products_sha256=ui_test_products_sha256,
        )
    return profiles


def _matrix_cells(
    matrix: SharedViewMatrix,
    surface_policy: tuple[SurfacePolicySurface, ...],
) -> dict[str, tuple[SurfacePolicySurface, SharedViewCell]]:
    policy_by_id = {surface.id: surface for surface in surface_policy}
    cells: dict[str, tuple[SurfacePolicySurface, SharedViewCell]] = {}
    for matrix_surface in matrix.surfaces:
        policy_surface = policy_by_id.get(matrix_surface.id)
        if policy_surface is None:
            raise SharedViewCaptureError("shared-view surface policy is invalid")
        for cell in matrix_surface.cells:
            cells[shared_view_requirement_id(matrix_surface.id, cell.id)] = (policy_surface, cell)
    return cells


def load_capture_requirements(
    path: Path,
    planned_payload: dict[str, object],
    matrix: SharedViewMatrix,
    surface_policy: tuple[SurfacePolicySurface, ...],
) -> CapturePlan:
    payload = _load_json_object(path, "shared-view capture requirements")
    if set(payload) != {"schemaVersion", "kind", "currentManifestID", "requirements"}:
        raise SharedViewCaptureError("shared-view capture requirements root keys are invalid")
    if (
        type(payload["schemaVersion"]) is not int
        or payload["schemaVersion"] != REQUIREMENTS_SCHEMA_VERSION
        or payload["kind"] != REQUIREMENTS_KIND
    ):
        raise SharedViewCaptureError("shared-view capture requirements identity is invalid")
    try:
        projected_payload = project_shared_view_requirements(payload, planned_payload)
    except SharedViewEvidenceError as error:
        raise SharedViewCaptureError(str(error)) from error
    manifest_id = _require_sha256(payload["currentManifestID"], "shared-view capture manifest identifier")
    raw_requirements = projected_payload["requirements"]
    if not isinstance(raw_requirements, list) or not raw_requirements:
        raise SharedViewCaptureError("shared-view capture has no planned work")
    if len(raw_requirements) > matrix.max_cell_count:
        raise SharedViewCaptureError("shared-view capture requirements are invalid")
    expected = _matrix_cells(matrix, surface_policy)
    requirements: list[CaptureRequirement] = []
    for raw_requirement in raw_requirements:
        if not isinstance(raw_requirement, dict):
            raise SharedViewCaptureError("shared-view capture requirement is invalid")
        requirement_id = _require_string(raw_requirement.get("id"), "shared-view capture requirement identifier")
        policy_surface, cell = expected[requirement_id]
        if cell.accessibility != "default":
            raise SharedViewCaptureError(
                "shared-view capture accessibility context is unsupported"
            )
        requirements.append(
            CaptureRequirement(
                requirement_id=requirement_id,
                surface=policy_surface.id,
                cell_id=cell.id,
                fixture_contract_id=_require_sha256(
                    raw_requirement.get("fixtureContractID"),
                    "shared-view capture fixture contract identifier",
                ),
                fixture_id=cell.fixture_id,
                family=cell.family,
                appearance=cell.appearance,
                presentation=cell.presentation,
                accessibility=cell.accessibility,
            )
        )
    return CapturePlan(
        current_manifest_id=manifest_id,
        requirements_digest=canonical_json_hash(
            REQUIREMENTS_DIGEST_DOMAIN,
            projected_payload,
        ),
        requirements=tuple(requirements),
    )


def _profile_for_surface(surface: str) -> str | None:
    for profile_name, profile in SIMULATOR_CAPTURE_PROFILES.items():
        if surface.startswith(profile.surface_prefix):
            return profile_name
    return None


def _validate_artifact_root(path: Path) -> Path:
    if not path.is_absolute() or path == Path(path.anchor):
        raise SharedViewCaptureError("capture artifact root is invalid")
    _reject_symlink_ancestors(path, "capture artifact root")
    try:
        resolved = path.resolve(strict=False)
        repo_root = REPO_ROOT.resolve()
        if resolved == repo_root or repo_root in resolved.parents:
            raise SharedViewCaptureError("capture artifact root must be outside the repository")
        existing_ancestor = resolved
        while not existing_ancestor.exists():
            existing_ancestor = existing_ancestor.parent
        for ancestor in (existing_ancestor, *existing_ancestor.parents):
            ancestor_mode = ancestor.stat().st_mode
            if ancestor_mode & 0o022 and not ancestor_mode & stat.S_ISVTX:
                raise SharedViewCaptureError("capture artifact root ancestry is unsafe")
    except SharedViewCaptureError:
        raise
    except (OSError, RuntimeError, ValueError) as error:
        raise SharedViewCaptureError("capture artifact root is unavailable") from error
    return resolved


def _validate_output_path(path: Path) -> Path:
    if not path.is_absolute():
        raise SharedViewCaptureError("capture receipt output is invalid")
    _reject_symlink_ancestors(path, "capture receipt output")
    return path.resolve(strict=False)


def _paths_overlap(left: Path, right: Path) -> bool:
    return left == right or left in right.parents or right in left.parents


def _reject_capture_path_overlap(
    artifact_root: Path,
    output_path: Path,
    profiles: dict[str, CaptureProfile],
    input_paths: tuple[Path, ...],
) -> None:
    if _paths_overlap(artifact_root, output_path):
        raise SharedViewCaptureError("capture artifact and output paths overlap")
    for profile in profiles.values():
        if _paths_overlap(artifact_root, profile.app_bundle) or _paths_overlap(
            output_path, profile.app_bundle
        ):
            raise SharedViewCaptureError("capture paths overlap an app bundle")
        if profile.ui_test_run is not None:
            test_root = profile.ui_test_run.parent
            if _paths_overlap(artifact_root, test_root) or _paths_overlap(
                output_path, test_root
            ):
                raise SharedViewCaptureError("capture paths overlap UI test products")
    for input_path in input_paths:
        resolved_input = input_path.expanduser().resolve(strict=True)
        if _paths_overlap(artifact_root, resolved_input) or output_path == resolved_input:
            raise SharedViewCaptureError("capture output paths overlap a capture input")


def _prepare_private_directory(path: Path) -> None:
    missing: list[Path] = []
    candidate = path
    while not candidate.exists():
        missing.append(candidate)
        candidate = candidate.parent
    if candidate.is_symlink() or not candidate.is_dir():
        raise SharedViewCaptureError("capture artifact root is invalid")
    for directory in reversed(missing):
        try:
            directory.mkdir(mode=0o700)
            _fsync_directory(directory.parent)
        except FileExistsError:
            pass
        except OSError as error:
            raise SharedViewCaptureError("capture artifact root is unavailable") from error
        if directory.is_symlink() or not directory.is_dir():
            raise SharedViewCaptureError("capture artifact root is invalid")
    try:
        path_stat = path.stat()
        mode = stat.S_IMODE(path_stat.st_mode)
    except OSError as error:
        raise SharedViewCaptureError("capture artifact root is unavailable") from error
    if mode != 0o700 or path_stat.st_uid != os.geteuid():
        raise SharedViewCaptureError("capture artifact root permissions are invalid")


def _create_run_directories(
    manifest_directory: Path,
    run_id_factory: Callable[[], str],
) -> tuple[str, Path, Path]:
    for _ in range(8):
        run_id = run_id_factory()
        if not isinstance(run_id, str) or not CAPTURE_RUN_ID_PATTERN.fullmatch(run_id):
            raise SharedViewCaptureError("capture run identifier is invalid")
        run_directory = manifest_directory / run_id
        staging_directory = manifest_directory / f".{run_id}.staging"
        if run_directory.exists():
            continue
        try:
            staging_directory.mkdir(mode=0o700)
        except FileExistsError:
            continue
        except OSError as error:
            raise SharedViewCaptureError("capture run directory is unavailable") from error
        try:
            os.chmod(staging_directory, 0o700)
            _fsync_directory(manifest_directory)
        except OSError as error:
            try:
                shutil.rmtree(staging_directory)
                _fsync_directory(manifest_directory)
                if os.path.lexists(staging_directory):
                    raise OSError
            except OSError as rollback_error:
                raise SharedViewCaptureError("capture run rollback failed") from rollback_error
            raise SharedViewCaptureError("capture run directory is unavailable") from error
        return run_id, staging_directory, run_directory
    raise SharedViewCaptureError("capture run identifier is not unique")


def _atomic_write_json(path: Path, payload: dict[str, Any], mode: int) -> None:
    if path.is_symlink() or path.parent.is_symlink():
        raise SharedViewCaptureError("capture output path is invalid")
    missing_directories: list[Path] = []
    candidate = path.parent
    while not candidate.exists():
        missing_directories.append(candidate)
        candidate = candidate.parent
    if candidate.is_symlink() or not candidate.is_dir():
        raise SharedViewCaptureError("capture output path is invalid")
    for directory in reversed(missing_directories):
        try:
            directory.mkdir()
            _fsync_directory(directory.parent)
        except OSError as error:
            raise SharedViewCaptureError("capture output is unavailable") from error
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    replaced = False
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        _rename_exclusive(temporary_path, path)
        replaced = True
        _fsync_directory(path.parent)
    except OSError as error:
        if replaced:
            try:
                path.unlink(missing_ok=True)
                _fsync_directory(path.parent)
            except OSError as rollback_error:
                raise SharedViewCaptureError("capture output rollback failed") from rollback_error
        raise SharedViewCaptureError("capture output is unavailable") from error
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def _fsync_path(path: Path, flags: int) -> None:
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_directory(path: Path) -> None:
    _fsync_path(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))


def _fsync_file(path: Path) -> None:
    _fsync_path(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))


def _rename_exclusive(source: Path, destination: Path) -> None:
    renamex_np = getattr(ctypes.CDLL(None, use_errno=True), "renamex_np", None)
    if renamex_np is None:
        if os.path.lexists(destination):
            raise FileExistsError(destination)
        os.rename(source, destination)
        return
    renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex_np.restype = ctypes.c_int
    if renamex_np(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), destination)


def _png_snapshot(path: Path) -> PNGSnapshot:
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
        )
        image_stat = os.fstat(descriptor)
        if (
            not stat.S_ISREG(image_stat.st_mode)
            or image_stat.st_size < len(PNG_SIGNATURE)
            or image_stat.st_size > MAX_PNG_FILE_BYTES
        ):
            raise SharedViewCaptureError("captured image is invalid")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            data = stream.read(MAX_PNG_FILE_BYTES + 1)
    except OSError as error:
        raise SharedViewCaptureError("captured image is invalid") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (
        len(data) != image_stat.st_size
        or len(data) > MAX_PNG_FILE_BYTES
        or data[:8] != PNG_SIGNATURE
    ):
        raise SharedViewCaptureError("captured image is invalid")
    offset = len(PNG_SIGNATURE)
    chunk_index = 0
    width = 0
    height = 0
    bit_depth = 0
    color_type = 0
    saw_idat = False
    idat_ended = False
    saw_plte = False
    saw_iend = False
    compressed_image = bytearray()
    while offset < len(data):
        if chunk_index >= MAX_PNG_CHUNKS:
            raise SharedViewCaptureError("captured image is invalid")
        if len(data) - offset < 12:
            raise SharedViewCaptureError("captured image is invalid")
        chunk_length = int.from_bytes(data[offset : offset + 4], "big")
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data_start = offset + 8
        chunk_data_end = chunk_data_start + chunk_length
        chunk_end = chunk_data_end + 4
        if chunk_end > len(data):
            raise SharedViewCaptureError("captured image is invalid")
        chunk_data = data[chunk_data_start:chunk_data_end]
        expected_crc = int.from_bytes(data[chunk_data_end:chunk_end], "big")
        actual_crc = zlib.crc32(chunk_data, zlib.crc32(chunk_type)) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise SharedViewCaptureError("captured image is invalid")
        if any(
            not (ord("A") <= byte <= ord("Z") or ord("a") <= byte <= ord("z"))
            for byte in chunk_type
        ) or chunk_type[2] & 0x20:
            raise SharedViewCaptureError("captured image is invalid")
        if chunk_type[0] & 0x20 == 0 and chunk_type not in {
            b"IHDR", b"PLTE", b"IDAT", b"IEND"
        }:
            raise SharedViewCaptureError("captured image is invalid")
        if chunk_type == b"tRNS":
            raise SharedViewCaptureError("captured image is invalid")
        if chunk_index == 0:
            if chunk_type != b"IHDR" or chunk_length != 13:
                raise SharedViewCaptureError("captured image is invalid")
            width = int.from_bytes(chunk_data[0:4], "big")
            height = int.from_bytes(chunk_data[4:8], "big")
            bit_depth = chunk_data[8]
            color_type = chunk_data[9]
            if (
                width <= 0
                or height <= 0
                or width > MAX_PNG_DIMENSION
                or height > MAX_PNG_DIMENSION
                or width * height > MAX_PNG_PIXELS
            ):
                raise SharedViewCaptureError("captured image is invalid")
            if (
                bit_depth not in {8, 16}
                or color_type not in {2, 6}
                or chunk_data[10:13] != b"\x00\x00\x00"
            ):
                raise SharedViewCaptureError(
                    "captured image is invalid: unsupported-format"
                )
        elif chunk_type == b"IHDR":
            raise SharedViewCaptureError("captured image is invalid")
        if chunk_type == b"PLTE":
            if saw_plte or saw_idat or chunk_length == 0 or chunk_length > 768 or chunk_length % 3:
                raise SharedViewCaptureError("captured image is invalid")
            saw_plte = True
        if chunk_type == b"IDAT":
            if idat_ended:
                raise SharedViewCaptureError("captured image is invalid")
            saw_idat = True
            compressed_image.extend(chunk_data)
        elif saw_idat and chunk_type != b"IEND":
            idat_ended = True
        if chunk_type == b"IEND":
            if chunk_length != 0 or chunk_end != len(data):
                raise SharedViewCaptureError("captured image is invalid")
            saw_iend = True
        offset = chunk_end
        chunk_index += 1
        if saw_iend:
            break
    if not saw_idat or not saw_iend or offset != len(data):
        raise SharedViewCaptureError("captured image is invalid")
    channels = 3 if color_type == 2 else 4
    bytes_per_sample = bit_depth // 8
    bytes_per_pixel = channels * bytes_per_sample
    row_size = 1 + (width * bytes_per_pixel)
    expected_size = height * row_size
    if expected_size > MAX_PNG_DECOMPRESSED_BYTES:
        raise SharedViewCaptureError("captured image is invalid")
    try:
        decompressor = zlib.decompressobj()
        image_data = decompressor.decompress(compressed_image, expected_size + 1)
    except zlib.error as error:
        raise SharedViewCaptureError("captured image is invalid") from error
    if (
        len(image_data) != expected_size
        or decompressor.unconsumed_tail
        or not decompressor.eof
        or decompressor.unused_data
    ):
        raise SharedViewCaptureError("captured image is invalid")
    prior_row = bytearray(width * bytes_per_pixel)
    pixel_hasher = hashlib.sha256()
    digest_domain = (
        b"context-panel/png-rgba8/v1\0"
        if bit_depth == 8
        else b"context-panel/png-rgba16be/v1\0"
    )
    pixel_hasher.update(
        digest_domain + width.to_bytes(4, "big") + height.to_bytes(4, "big")
    )
    for row_offset in range(0, len(image_data), row_size):
        filter_type = image_data[row_offset]
        if filter_type > 4:
            raise SharedViewCaptureError("captured image is invalid")
        row = bytearray(image_data[row_offset + 1 : row_offset + row_size])
        for index, value in enumerate(row):
            left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = prior_row[index]
            upper_left = (
                prior_row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            )
            if filter_type == 1:
                row[index] = (value + left) & 0xFF
            elif filter_type == 2:
                row[index] = (value + above) & 0xFF
            elif filter_type == 3:
                row[index] = (value + ((left + above) // 2)) & 0xFF
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
                predictor = (left, above, upper_left)[distances.index(min(distances))]
                row[index] = (value + predictor) & 0xFF
        if channels == 3:
            rgba_row = bytearray(width * 4 * bytes_per_sample)
            source_pixel_bytes = 3 * bytes_per_sample
            destination_pixel_bytes = 4 * bytes_per_sample
            opaque_alpha = b"\xff" * bytes_per_sample
            for pixel_index in range(width):
                source_index = pixel_index * source_pixel_bytes
                destination_index = pixel_index * destination_pixel_bytes
                rgba_row[
                    destination_index : destination_index + source_pixel_bytes
                ] = row[source_index : source_index + source_pixel_bytes]
                rgba_row[
                    destination_index
                    + source_pixel_bytes : destination_index
                    + destination_pixel_bytes
                ] = opaque_alpha
            pixel_hasher.update(rgba_row)
        else:
            pixel_hasher.update(row)
        prior_row = row
    return PNGSnapshot(
        byte_count=len(data),
        artifact_digest=hashlib.sha256(data).hexdigest(),
        pixel_digest=pixel_hasher.hexdigest(),
        width=width,
        height=height,
    )


def _capture_url(requirement: CaptureRequirement) -> str:
    return "contextpanelcompanion://validation-gallery?" + urlencode(
        [
            ("fixture", requirement.fixture_id),
            ("family", requirement.family),
            ("appearance", requirement.appearance),
            ("presentation", requirement.presentation),
        ]
    )


def _capture_route(
    profile: CaptureProfile,
    simulator_id: str,
    requirement: CaptureRequirement,
) -> tuple[list[str], str, str | None]:
    capture_profile = _simulator_capture_profile(profile.name)
    if capture_profile.route_kind == "launch":
        if requirement.surface == "watchos.app":
            if requirement.family != "not-applicable" or requirement.fixture_id not in {
                "healthy", "dense-accounts"
            }:
                raise SharedViewCaptureError("capture Watch app selector is invalid")
            selectors = [
                "--context-panel-validation-surface", requirement.surface,
                "--context-panel-validation-fixture", requirement.fixture_id,
            ]
        elif requirement.surface == "watchos.complication":
            if (requirement.fixture_id, requirement.family) not in {
                ("healthy", "circular"),
                ("reset-visible", "rectangular"),
            }:
                raise SharedViewCaptureError("capture Watch complication selector is invalid")
            selectors = [
                "--context-panel-validation-surface", requirement.surface,
                "--context-panel-validation-fixture", requirement.fixture_id,
                "--context-panel-validation-family", requirement.family,
            ]
        else:
            raise SharedViewCaptureError("capture Watch surface is invalid")
        return (
            [
                "xcrun",
                "simctl",
                "launch",
                "--terminate-running-process",
                simulator_id,
                profile.bundle_identifier,
                "--context-panel-validation-gallery",
                *selectors,
            ],
            "simctl-launch",
            None,
        )
    raise SharedViewCaptureError("capture simulator profile route is invalid")


def _run(runner: Runner, args: list[str], timeout: int) -> CommandResult:
    return runner.run(args, timeout=timeout, environment=None)


def _command_error_code(result: CommandResult, base: str) -> str:
    return f"{base}-timeout" if result.timed_out else f"{base}-failed"


def _result(
    requirement: CaptureRequirement,
    *,
    status: str,
    captured_at: datetime,
    host_mechanism: str,
    appearance_mechanism: str | None,
    error_code: str | None = None,
    snapshot: PNGSnapshot | None = None,
) -> dict[str, object]:
    return {
        "requirementID": requirement.requirement_id,
        "surface": requirement.surface,
        "cellID": requirement.cell_id,
        "fixtureContractID": requirement.fixture_contract_id,
        "status": status,
        "artifactDigest": snapshot.artifact_digest if snapshot is not None else None,
        "artifactBytes": snapshot.byte_count if snapshot is not None else None,
        "pixelWidth": snapshot.width if snapshot is not None else None,
        "pixelHeight": snapshot.height if snapshot is not None else None,
        "hostMechanism": host_mechanism,
        "appearanceMechanism": appearance_mechanism,
        "capturedAt": iso8601(captured_at),
        "errorCode": error_code,
    }


def _unknown_results(
    requirements: tuple[CaptureRequirement, ...],
    error_code: str,
    now: Callable[[], datetime],
) -> dict[str, dict[str, object]]:
    return {
        requirement.requirement_id: _result(
            requirement,
            status="unknown",
            captured_at=now(),
            host_mechanism="simctl-gallery",
            appearance_mechanism=None,
            error_code=error_code,
        )
        for requirement in requirements
    }


def _blocked_results(
    requirements: tuple[CaptureRequirement, ...],
    error_code: str,
    now: Callable[[], datetime],
    host_mechanism: str = "unconfigured-profile",
) -> dict[str, dict[str, object]]:
    return {
        requirement.requirement_id: _result(
            requirement,
            status="blocked",
            captured_at=now(),
            host_mechanism=host_mechanism,
            appearance_mechanism=None,
            error_code=error_code,
        )
        for requirement in requirements
    }


def _mark_result_unknown(
    result: dict[str, object],
    error_code: str,
    captured_at: datetime,
) -> None:
    result.update(
        {
            "status": "unknown",
            "artifactDigest": None,
            "artifactBytes": None,
            "pixelWidth": None,
            "pixelHeight": None,
            "capturedAt": iso8601(captured_at),
            "errorCode": error_code,
        }
    )


def _created_simulator_id(result: CommandResult) -> str | None:
    simulator_ids = [
        line.strip()
        for line in result.stdout.splitlines()
        if SIMULATOR_UDID_PATTERN.fullmatch(line.strip())
    ]
    return simulator_ids[0] if len(simulator_ids) == 1 else None


def _verify_created_simulator(
    runner: Runner,
    profile: CaptureProfile,
    simulator_name: str,
    simulator_id: str,
) -> str | None:
    matches, error = _matching_simulators(runner, profile, simulator_name)
    if error is not None or matches is None:
        return error
    return None if matches == {simulator_id} else "simctl-created-device-mismatch"


def _matching_simulators(
    runner: Runner,
    profile: CaptureProfile,
    simulator_name: str,
    error_base: str = "simctl-created-device",
    strict_identity: bool = True,
    target_id: str | None = None,
) -> tuple[set[str] | None, str | None]:
    command = ["xcrun", "simctl", "list", "-j", "devices"]
    result = _run(
        runner,
        command,
        SIMCTL_CATALOG_TIMEOUT,
    )
    if result.returncode != 0 or result.timed_out:
        return None, _command_error_code(result, error_base)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None, f"{error_base}-invalid"
    if not isinstance(payload, dict) or not isinstance(payload.get("devices"), dict):
        return None, f"{error_base}-invalid"
    matches: set[str] = set()
    device_count = 0
    for runtime_identifier, raw_devices in payload["devices"].items():
        if not isinstance(runtime_identifier, str) or not isinstance(raw_devices, list):
            return None, f"{error_base}-invalid"
        device_count += len(raw_devices)
        if device_count > MAX_SIMULATOR_DEVICE_COUNT:
            return None, f"{error_base}-invalid"
        for raw_device in raw_devices:
            if not isinstance(raw_device, dict):
                return None, f"{error_base}-invalid"
            simulator_id = raw_device.get("udid")
            name_matches = raw_device.get("name") == simulator_name
            valid_id = isinstance(simulator_id, str) and bool(
                SIMULATOR_UDID_PATTERN.fullmatch(simulator_id)
            )
            if target_id is None and name_matches and not valid_id:
                return None, f"{error_base}-invalid"
            if (
                (simulator_id == target_id if target_id is not None else name_matches)
                and valid_id
                and (
                    not strict_identity
                    or (
                        runtime_identifier == profile.runtime_identifier
                        and raw_device.get("deviceTypeIdentifier")
                        == profile.device_type_identifier
                        and raw_device.get("isAvailable") is True
                    )
                )
            ):
                if simulator_id in matches:
                    return None, f"{error_base}-mismatch"
                matches.add(simulator_id)
    return matches, None


def _simulator_catalog(
    runner: Runner,
) -> tuple[dict[str, dict[str, object]] | None, dict[str, dict[str, object]] | None, str | None]:
    result = _run(runner, ["xcrun", "simctl", "list", "-j"], SIMCTL_CATALOG_TIMEOUT)
    if result.returncode != 0 or result.timed_out:
        return None, None, _command_error_code(result, "simctl-catalog")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None, None, "simctl-catalog-invalid"
    if not isinstance(payload, dict):
        return None, None, "simctl-catalog-invalid"
    raw_runtimes = payload.get("runtimes")
    raw_device_types = payload.get("devicetypes")
    if not isinstance(raw_runtimes, list) or not isinstance(raw_device_types, list):
        return None, None, "simctl-catalog-invalid"
    runtimes = _catalog_entries_by_identifier(raw_runtimes)
    device_types = _catalog_entries_by_identifier(raw_device_types)
    if runtimes is None or device_types is None:
        return None, None, "simctl-catalog-invalid"
    return runtimes, device_types, None


def _catalog_entries_by_identifier(
    raw_entries: list[object],
) -> dict[str, dict[str, object]] | None:
    entries: dict[str, dict[str, object]] = {}
    for raw_entry in raw_entries:
        if not isinstance(raw_entry, dict):
            return None
        identifier = raw_entry.get("identifier")
        if not isinstance(identifier, str) or not identifier or identifier in entries:
            return None
        entries[identifier] = raw_entry
    return entries


def _profile_catalog_metadata(
    profile: CaptureProfile,
    runtimes: dict[str, dict[str, object]],
    device_types: dict[str, dict[str, object]],
) -> tuple[SimulatorProfileMetadata | None, str | None]:
    runtime = runtimes.get(profile.runtime_identifier)
    device_type = device_types.get(profile.device_type_identifier)
    if runtime is None or device_type is None:
        return None, "simctl-profile-not-found"
    runtime_name = runtime.get("name")
    runtime_platform = runtime.get("platform")
    device_type_name = device_type.get("name")
    product_family = device_type.get("productFamily")
    if (
        not isinstance(runtime_name, str)
        or not runtime_name
        or not isinstance(runtime_platform, str)
        or not runtime_platform
        or runtime.get("isAvailable") is not True
        or not isinstance(device_type_name, str)
        or not device_type_name
        or not isinstance(product_family, str)
        or not product_family
    ):
        return None, "simctl-profile-invalid"
    metadata = SimulatorProfileMetadata(
        runtime_name=runtime_name,
        runtime_platform=runtime_platform,
        device_type_name=device_type_name,
        product_family=product_family,
    )
    capture_profile = _simulator_capture_profile(profile.name)
    if (
        runtime_platform not in capture_profile.runtime_platforms
        or product_family != capture_profile.product_family
    ):
        return metadata, "simctl-profile-mismatch"
    return metadata, None


def _visionos_ui_test_environment(requirement: CaptureRequirement) -> dict[str, str]:
    try:
        return {
            VISIONOS_UI_TEST_ENVIRONMENT["url"]: _capture_url(requirement),
            VISIONOS_UI_TEST_ENVIRONMENT["fixture"]: requirement.fixture_id,
            VISIONOS_UI_TEST_ENVIRONMENT["fixture_title"]: VALIDATION_FIXTURE_TITLES[
                requirement.fixture_id
            ],
            VISIONOS_UI_TEST_ENVIRONMENT["family"]: requirement.family,
            VISIONOS_UI_TEST_ENVIRONMENT["family_title"]: VALIDATION_FAMILY_TITLES[
                requirement.family
            ],
            VISIONOS_UI_TEST_ENVIRONMENT["appearance"]: requirement.appearance,
            VISIONOS_UI_TEST_ENVIRONMENT["appearance_title"]: (
                VALIDATION_APPEARANCE_TITLES[requirement.appearance]
            ),
            VISIONOS_UI_TEST_ENVIRONMENT["presentation"]: requirement.presentation,
            VISIONOS_UI_TEST_ENVIRONMENT["presentation_title"]: (
                VALIDATION_PRESENTATION_TITLES[requirement.presentation]
            ),
        }
    except KeyError as error:
        raise SharedViewCaptureError("capture visionOS UI test selector is invalid") from error


def _write_visionos_ui_test_run(
    profile: CaptureProfile,
    requirement: CaptureRequirement,
) -> Path:
    if profile.ui_test_run is None:
        raise SharedViewCaptureError("capture visionOS UI test run is unavailable")
    try:
        payload = plistlib.loads(
            _read_bounded_file(
                profile.ui_test_run,
                "capture visionOS UI test run",
                MAX_PLIST_FILE_BYTES,
            )
        )
    except plistlib.InvalidFileException as error:
        raise SharedViewCaptureError("capture visionOS UI test run is invalid") from error
    target = payload.get(VISIONOS_UI_TEST_TARGET) if isinstance(payload, dict) else None
    if not isinstance(target, dict) or not isinstance(target.get("EnvironmentVariables"), dict):
        raise SharedViewCaptureError("capture visionOS UI test run is invalid")
    environment = dict(target["EnvironmentVariables"])
    requested_environment = _visionos_ui_test_environment(requirement)
    if set(environment).intersection(requested_environment):
        raise SharedViewCaptureError("capture visionOS UI test environment is invalid")
    environment.update(requested_environment)
    target["EnvironmentVariables"] = environment
    target["SystemAttachmentLifetime"] = "deleteOnSuccess"
    target["UserAttachmentLifetime"] = "keepAlways"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{requirement.requirement_id}.",
        suffix=".xctestrun",
        dir=profile.ui_test_run.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            plistlib.dump(payload, stream, fmt=plistlib.FMT_BINARY, sort_keys=True)
            stream.flush()
            os.fchmod(stream.fileno(), 0o600)
            os.fsync(stream.fileno())
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
    return temporary_path


def _temporary_absent_path(directory: Path, prefix: str, suffix: str) -> Path:
    descriptor, name = tempfile.mkstemp(prefix=prefix, suffix=suffix, dir=directory)
    os.close(descriptor)
    path = Path(name)
    path.unlink()
    return path


def _load_attachment_manifest(path: Path) -> list[dict[str, Any]]:
    data = _read_bounded_file(path, "visionOS UI test attachment manifest", MAX_JSON_FILE_BYTES)
    try:
        payload = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise SharedViewCaptureError("visionOS UI test attachment manifest is invalid") from error
    if not isinstance(payload, list):
        raise SharedViewCaptureError("visionOS UI test attachment manifest is invalid")
    return payload


def _attachment_sample_name(value: object) -> tuple[str, int] | None:
    if not isinstance(value, str):
        return None
    match = re.fullmatch(
        r"(baseline|routed)-([1-6])_0_[0-9A-Fa-f-]{36}\.png",
        value,
    )
    if match is None:
        return None
    return match.group(1), int(match.group(2))


def _preserve_invalid_png(
    source: Path,
    diagnostic_directory: Path,
    diagnostic_name: str,
) -> None:
    data = _read_bounded_file(source, "visionOS UI test invalid PNG", MAX_PNG_FILE_BYTES)
    if diagnostic_directory.is_symlink():
        raise SharedViewCaptureError("visionOS UI test invalid PNG diagnostics are unavailable")
    diagnostic_directory.mkdir(mode=0o700, exist_ok=True)
    os.chmod(diagnostic_directory, 0o700)
    destination = diagnostic_directory / diagnostic_name
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), 0o600)
            os.fsync(stream.fileno())
        _fsync_directory(diagnostic_directory)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


def _visionos_ui_test_attachments(
    attachment_directory: Path,
    diagnostic_directory: Path,
    diagnostic_prefix: str,
) -> tuple[list[tuple[PNGSnapshot, Path]], list[tuple[PNGSnapshot, Path]]]:
    payload = _load_attachment_manifest(attachment_directory / "manifest.json")
    expected_test_identifier = f"{VISIONOS_UI_TEST_TARGET}/{VISIONOS_UI_TEST_METHOD}()"
    if len(payload) != 1 or not isinstance(payload[0], dict):
        raise SharedViewCaptureError("visionOS UI test attachments are invalid")
    record = payload[0]
    if record.get("testIdentifier") != expected_test_identifier:
        raise SharedViewCaptureError("visionOS UI test attachments are invalid")
    raw_attachments = record.get("attachments")
    if not isinstance(raw_attachments, list) or not 4 <= len(raw_attachments) <= 12:
        raise SharedViewCaptureError("visionOS UI test attachments are invalid")
    samples: dict[str, dict[int, tuple[PNGSnapshot, Path]]] = {
        "baseline": {},
        "routed": {},
    }
    for attachment in raw_attachments:
        if not isinstance(attachment, dict):
            raise SharedViewCaptureError("visionOS UI test attachments are invalid")
        sample = _attachment_sample_name(attachment.get("suggestedHumanReadableName"))
        exported_name = attachment.get("exportedFileName")
        if (
            sample is None
            or not isinstance(exported_name, str)
            or Path(exported_name).name != exported_name
            or not exported_name.endswith(".png")
            or attachment.get("isAssociatedWithFailure") is not False
        ):
            raise SharedViewCaptureError("visionOS UI test attachments are invalid")
        prefix, sample_index = sample
        if sample_index in samples[prefix]:
            raise SharedViewCaptureError("visionOS UI test attachments are invalid")
        image_path = attachment_directory / exported_name
        try:
            snapshot = _png_snapshot(image_path)
            if (
                snapshot.width < MIN_VISIONOS_CAPTURE_DIMENSION
                or snapshot.height < MIN_VISIONOS_CAPTURE_DIMENSION
            ):
                raise SharedViewCaptureError(
                    "captured image is invalid: placeholder-dimensions"
                )
        except (SharedViewCaptureError, MemoryError) as error:
            _preserve_invalid_png(
                image_path,
                diagnostic_directory,
                f"{diagnostic_prefix}-{prefix}-{sample_index}.png",
            )
            raise SharedViewCaptureError(
                f"visionOS UI test captured image is invalid: {error}"
            ) from error
        samples[prefix][sample_index] = (snapshot, image_path)
    ordered: dict[str, list[tuple[PNGSnapshot, Path]]] = {}
    for prefix, indexed_samples in samples.items():
        indices = sorted(indexed_samples)
        if not 2 <= len(indices) <= MAX_STABILITY_SAMPLE_COUNT or indices != list(
            range(1, len(indices) + 1)
        ):
            raise SharedViewCaptureError("visionOS UI test attachments are invalid")
        ordered[prefix] = [indexed_samples[index] for index in indices]
    return ordered["baseline"], ordered["routed"]


def _stable_attachment(
    samples: list[tuple[PNGSnapshot, Path]],
) -> tuple[PNGSnapshot, Path] | None:
    for previous, current in zip(samples, samples[1:]):
        if previous[0].pixel_digest == current[0].pixel_digest:
            return current
    return None


def _copy_private_png(source: Path, directory: Path, prefix: str) -> tuple[PNGSnapshot, Path]:
    data = _read_bounded_file(source, "visionOS UI test captured image", MAX_PNG_FILE_BYTES)
    descriptor, name = tempfile.mkstemp(prefix=prefix, suffix=".png", dir=directory)
    destination = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), 0o600)
            os.fsync(stream.fileno())
        snapshot = _png_snapshot(destination)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    return snapshot, destination


def _take_visionos_ui_test_capture(
    runner: Runner,
    simulator_id: str,
    profile: CaptureProfile,
    requirement: CaptureRequirement,
    artifact_directory: Path,
) -> tuple[PNGSnapshot | None, PNGSnapshot | None, Path | None, str | None]:
    if profile.ui_test_run is None or profile.ui_test_products_sha256 is None:
        return None, None, None, "xcuitest-products-unavailable"
    xctestrun_path: Path | None = None
    result_bundle = _temporary_absent_path(
        artifact_directory,
        f".{requirement.requirement_id}.",
        ".xcresult",
    )
    attachment_directory = _temporary_absent_path(
        artifact_directory,
        f".{requirement.requirement_id}.attachments.",
        "",
    )
    try:
        prepared_test_run = _write_visionos_ui_test_run(profile, requirement)
        xctestrun_path = prepared_test_run
        executed = _run(
            runner,
            [
                "xcodebuild",
                "test-without-building",
                "-xctestrun",
                str(prepared_test_run),
                "-destination",
                f"id={simulator_id}",
                "-parallel-testing-enabled",
                "NO",
                "-resultBundlePath",
                str(result_bundle),
                f"-only-testing:{VISIONOS_UI_TEST_IDENTIFIER}",
            ],
            XCODEBUILD_VISIONOS_CAPTURE_TIMEOUT,
        )
        if executed.returncode != 0 or executed.timed_out:
            return None, None, None, _command_error_code(executed, "xcuitest-capture")
        installed_app_error = _installed_app_error(runner, simulator_id, profile)
        if installed_app_error is not None:
            return None, None, None, installed_app_error
        exported = _run(
            runner,
            [
                "xcrun",
                "xcresulttool",
                "export",
                "attachments",
                "--path",
                str(result_bundle),
                "--output-path",
                str(attachment_directory),
            ],
            XCRESULT_EXPORT_TIMEOUT,
        )
        if exported.returncode != 0 or exported.timed_out:
            return None, None, None, _command_error_code(
                exported,
                "xcresult-attachment-export",
            )
        try:
            baseline_samples, routed_samples = _visionos_ui_test_attachments(
                attachment_directory,
                artifact_directory / "invalid-png-diagnostics",
                requirement.requirement_id,
            )
        except SharedViewCaptureError as error:
            if "captured image" in str(error):
                if "unsupported-format" in str(error):
                    return None, None, None, "captured-image-format-unsupported"
                if "placeholder-dimensions" in str(error):
                    return None, None, None, "captured-image-placeholder"
                return None, None, None, "captured-image-invalid"
            return None, None, None, "xcuitest-attachments-invalid"
        baseline = _stable_attachment(baseline_samples)
        if baseline is None:
            return None, None, None, "baseline-unstable"
        routed = _stable_attachment(routed_samples)
        if routed is None:
            return None, None, None, "capture-unstable"
        stable_snapshot, stable_path = _copy_private_png(
            routed[1],
            artifact_directory,
            f".{requirement.requirement_id}.capture.",
        )
        if stable_snapshot.pixel_digest != routed[0].pixel_digest:
            stable_path.unlink(missing_ok=True)
            return None, None, None, "captured-image-invalid"
        return baseline[0], stable_snapshot, stable_path, None
    except (OSError, SharedViewCaptureError):
        return None, None, None, "xcuitest-capture-input-invalid"
    finally:
        if xctestrun_path is not None:
            xctestrun_path.unlink(missing_ok=True)
        shutil.rmtree(result_bundle, ignore_errors=True)
        shutil.rmtree(attachment_directory, ignore_errors=True)
        try:
            products_unchanged = (
                _bundle_sha256(profile.ui_test_run.parent)
                == profile.ui_test_products_sha256
            )
        except SharedViewCaptureError:
            products_unchanged = False
        if not products_unchanged:
            raise SharedViewCaptureError("capture UI test products changed")


def _take_screenshot(
    runner: Runner,
    simulator_id: str,
    artifact_directory: Path,
    prefix: str,
    command_base: str,
    invalid_error_code: str,
) -> tuple[PNGSnapshot | None, Path | None, str | None]:
    descriptor, temporary_name = tempfile.mkstemp(prefix=prefix, suffix=".png", dir=artifact_directory)
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    temporary_path.unlink()
    result = _run(
        runner,
        ["xcrun", "simctl", "io", simulator_id, "screenshot", str(temporary_path)],
        SIMCTL_SCREENSHOT_TIMEOUT,
    )
    if result.returncode != 0 or result.timed_out:
        temporary_path.unlink(missing_ok=True)
        return None, None, _command_error_code(result, command_base)
    try:
        snapshot = _png_snapshot(temporary_path)
    except (SharedViewCaptureError, MemoryError):
        temporary_path.unlink(missing_ok=True)
        return None, None, invalid_error_code
    return snapshot, temporary_path, None


def _take_stable_screenshot(
    runner: Runner,
    simulator_id: str,
    artifact_directory: Path,
    prefix: str,
    command_base: str,
    invalid_error_code: str,
    unstable_error_code: str,
    sleeper: Callable[[float], None],
) -> tuple[PNGSnapshot | None, Path | None, str | None]:
    previous_snapshot, previous_path, error = _take_screenshot(
        runner,
        simulator_id,
        artifact_directory,
        f"{prefix}1.",
        command_base,
        invalid_error_code,
    )
    if error is not None or previous_snapshot is None or previous_path is None:
        return None, None, error
    for sample_index in range(2, MAX_STABILITY_SAMPLE_COUNT + 1):
        sleeper(CAPTURE_SETTLE_SECONDS)
        current_snapshot, current_path, error = _take_screenshot(
            runner,
            simulator_id,
            artifact_directory,
            f"{prefix}{sample_index}.",
            command_base,
            invalid_error_code,
        )
        if error is not None or current_snapshot is None or current_path is None:
            previous_path.unlink(missing_ok=True)
            return None, None, error
        if previous_snapshot.pixel_digest == current_snapshot.pixel_digest:
            previous_path.unlink(missing_ok=True)
            return current_snapshot, current_path, None
        previous_path.unlink(missing_ok=True)
        previous_snapshot = current_snapshot
        previous_path = current_path
    previous_path.unlink(missing_ok=True)
    return None, None, unstable_error_code


def _remove_profile_artifacts(
    artifact_paths: dict[str, Path],
) -> bool:
    removed = True
    for artifact_path in artifact_paths.values():
        try:
            artifact_path.unlink(missing_ok=True)
        except OSError:
            removed = False
    return removed


def _cleanup_simulator(
    runner: Runner,
    cleanup_target: str,
    profile: CaptureProfile,
    simulator_name: str,
) -> tuple[str, str | None]:
    shutdown = _run(
        runner,
        ["xcrun", "simctl", "shutdown", cleanup_target],
        SIMCTL_CLEANUP_TIMEOUT,
    )
    deleted = _run(
        runner,
        ["xcrun", "simctl", "delete", cleanup_target],
        SIMCTL_CLEANUP_TIMEOUT,
    )
    target_matches, verification_error = _matching_simulators(
        runner,
        profile,
        simulator_name,
        "simctl-delete-verification",
        strict_identity=False,
        target_id=cleanup_target,
    )
    if verification_error is not None or target_matches is None:
        return "delete-unverified", verification_error or "simctl-delete-verification-invalid"
    if target_matches:
        if deleted.timed_out:
            return "delete-timeout", "simctl-delete-timeout"
        if deleted.returncode != 0:
            return "delete-failed", "simctl-delete-failed"
        return "delete-persisted", "simctl-delete-persisted"
    remaining, verification_error = _matching_simulators(
        runner,
        profile,
        simulator_name,
        "simctl-delete-verification",
        strict_identity=False,
    )
    if verification_error is not None or remaining is None:
        return "delete-unverified", verification_error or "simctl-delete-verification-invalid"
    if remaining:
        return "delete-persisted", "simctl-delete-persisted"
    if shutdown.timed_out:
        return "deleted-after-shutdown-timeout", None
    if shutdown.returncode != 0:
        return "deleted-after-shutdown-failure", None
    return "deleted", None


def _simulator_name(profile_name: str, capture_run_id: str) -> str:
    return f"ContextPanelSharedView-{profile_name}-{capture_run_id}"


def _profile_source_identity(profile: CaptureProfile) -> tuple[object, ...]:
    return (
        profile.bundle_identifier,
        profile.executable_sha256,
        profile.bundle_sha256,
        profile.manifest_id,
        profile.manifest_digest,
        profile.manifest_surfaces,
        profile.contract_fingerprint,
        profile.version,
        profile.build,
    )


def _copy_snapshot_directory(source: Path, destination: Path) -> None:
    total_bytes = entries = 0

    def bounded_entries(_directory: str, names: list[str]) -> list[str]:
        nonlocal entries
        entries += len(names)
        if entries > MAX_BUNDLE_ENTRIES:
            raise SharedViewCaptureError("capture app snapshot failed")
        return []

    def bounded_copy(copy_source: str, copy_destination: str) -> str:
        nonlocal total_bytes
        with os.fdopen(
            os.open(copy_source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)), "rb"
        ) as input_stream, open(copy_destination, "xb") as output_stream:
            source_stat = os.fstat(input_stream.fileno())
            total_bytes += source_stat.st_size
            if (
                not stat.S_ISREG(source_stat.st_mode)
                or source_stat.st_size > MAX_BUNDLE_FILE_BYTES
                or total_bytes > MAX_BUNDLE_TOTAL_BYTES
            ):
                raise SharedViewCaptureError("capture app snapshot failed")
            remaining = source_stat.st_size
            while remaining:
                chunk = input_stream.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise SharedViewCaptureError("capture app snapshot failed")
                output_stream.write(chunk)
                remaining -= len(chunk)
            if input_stream.read(1):
                raise SharedViewCaptureError("capture app snapshot failed")
            os.fchmod(output_stream.fileno(), stat.S_IMODE(source_stat.st_mode))
        return copy_destination

    try:
        shutil.copytree(
            source,
            destination,
            symlinks=True,
            ignore=bounded_entries,
            copy_function=bounded_copy,
        )
    except (OSError, shutil.Error) as error:
        raise SharedViewCaptureError("capture input snapshot failed") from error


def _snapshot_profile(
    profile: CaptureProfile,
    directory: Path,
) -> tuple[CaptureProfile, Path]:
    if profile.ui_test_run is not None:
        source_root = profile.ui_test_run.parent
        snapshot_root = directory / f".{profile.name}-test-products"
        try:
            app_relative_path = profile.app_bundle.relative_to(source_root)
            run_relative_path = profile.ui_test_run.relative_to(source_root)
        except ValueError as error:
            raise SharedViewCaptureError("capture visionOS UI test products are invalid") from error
        _copy_snapshot_directory(source_root, snapshot_root)
        snapshot = replace(
            profile,
            app_bundle=snapshot_root / app_relative_path,
            ui_test_run=snapshot_root / run_relative_path,
        )
        if (
            profile.ui_test_products_sha256 is None
            or _bundle_sha256(snapshot_root) != profile.ui_test_products_sha256
        ):
            raise SharedViewCaptureError("capture UI test snapshot identity changed")
        if _app_metadata(snapshot.app_bundle, profile.name) != _profile_source_identity(profile):
            raise SharedViewCaptureError("capture app snapshot identity changed")
        _validate_visionos_ui_test_run(snapshot.ui_test_run, snapshot.app_bundle)
        return snapshot, snapshot_root

    snapshot_path = directory / f".{profile.name}-install.app"
    _copy_snapshot_directory(profile.app_bundle, snapshot_path)
    snapshot = replace(profile, app_bundle=snapshot_path)
    if _app_metadata(snapshot_path, profile.name) != _profile_source_identity(profile):
        raise SharedViewCaptureError("capture app snapshot identity changed")
    return snapshot, snapshot_path


def _installed_app_error(runner: Runner, simulator_id: str, profile: CaptureProfile) -> str | None:
    result = _run(
        runner,
        ["xcrun", "simctl", "get_app_container", simulator_id, profile.bundle_identifier, "app"],
        SIMCTL_CONTAINER_TIMEOUT,
    )
    if result.returncode != 0 or result.timed_out:
        return _command_error_code(result, "simctl-app-container")
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        return "simctl-app-container-invalid"
    raw_installed_path = Path(lines[0])
    if not raw_installed_path.is_absolute():
        return "simctl-app-container-invalid"
    try:
        installed_path = raw_installed_path.resolve(strict=True)
        if not installed_path.is_dir():
            return "simctl-app-container-invalid"
        installed_identity = _app_metadata(installed_path, profile.name, include_modes=False)
        source_identity = _app_metadata(profile.app_bundle, profile.name, include_modes=False)
    except (OSError, RuntimeError, ValueError, SharedViewCaptureError):
        return "simctl-app-container-invalid"
    return None if installed_identity == source_identity else "simctl-app-container-mismatch"


def _reset_visionos_cell(
    runner: Runner,
    simulator_id: str,
    simulator_name: str,
    profile: CaptureProfile,
) -> str | None:
    shutdown = _run(
        runner,
        ["xcrun", "simctl", "shutdown", simulator_id],
        SIMCTL_VISIONOS_SHUTDOWN_TIMEOUT,
    )
    if shutdown.timed_out:
        return "simctl-visionos-cell-shutdown-timeout"
    commands = (
        (
            ["xcrun", "simctl", "erase", simulator_id],
            SIMCTL_VISIONOS_ERASE_TIMEOUT,
            "simctl-visionos-cell-erase",
        ),
        (
            ["xcrun", "simctl", "boot", simulator_id],
            SIMCTL_BOOT_TIMEOUT,
            "simctl-visionos-cell-boot",
        ),
        (
            ["xcrun", "simctl", "bootstatus", simulator_id, "-b"],
            SIMCTL_VISIONOS_BOOTSTATUS_TIMEOUT,
            "simctl-visionos-cell-bootstatus",
        ),
        (
            ["xcrun", "simctl", "install", simulator_id, str(profile.app_bundle)],
            SIMCTL_VISIONOS_INSTALL_TIMEOUT,
            "simctl-visionos-cell-install",
        ),
    )
    for command, timeout, error_base in commands:
        result = _run(runner, command, timeout)
        if result.returncode != 0 or result.timed_out:
            return _command_error_code(result, error_base)
    if _app_metadata(profile.app_bundle, profile.name) != _profile_source_identity(profile):
        return "capture-app-bundle-changed"
    installed_app_error = _installed_app_error(runner, simulator_id, profile)
    if installed_app_error is not None:
        return installed_app_error
    matches, identity_error = _matching_simulators(
        runner,
        profile,
        simulator_name,
        error_base="simctl-visionos-cell-device",
    )
    if identity_error is not None or matches is None:
        return identity_error or "simctl-visionos-cell-device-invalid"
    return None if matches == {simulator_id} else "simctl-visionos-cell-device-mismatch"


def _capture_profile(
    profile: CaptureProfile,
    requirements: tuple[CaptureRequirement, ...],
    artifact_directory: Path,
    capture_run_id: str,
    runner: Runner,
    sleeper: Callable[[float], None],
    now: Callable[[], datetime],
    seen_digests: dict[str, str | None],
    prior_results: dict[str, dict[str, object]],
    published_artifact_paths: dict[str, Path],
    cleanup_target_observer: Callable[[str], None] = lambda _: None,
) -> ProfileCaptureOutcome:
    results: dict[str, dict[str, object]] = {}
    artifact_paths: dict[str, Path] = {}
    simulator_name = _simulator_name(profile.name, capture_run_id)
    lifecycle_error: str | None = None
    preexisting_ids, inventory_error = _matching_simulators(
        runner,
        profile,
        simulator_name,
        "simctl-device-inventory",
        strict_identity=False,
    )
    if inventory_error is not None:
        return ProfileCaptureOutcome(
            results=_unknown_results(requirements, inventory_error, now),
            cleanup_status="not-started",
        )
    if preexisting_ids is None:
        raise SharedViewCaptureError("simulator inventory result is invalid")
    if preexisting_ids:
        return ProfileCaptureOutcome(
            results=_unknown_results(requirements, "simctl-create-name-collision", now),
            cleanup_status="not-started",
        )
    created = _run(
        runner,
        [
            "xcrun",
            "simctl",
            "create",
            simulator_name,
            profile.device_type_identifier,
            profile.runtime_identifier,
        ],
        SIMCTL_CREATE_TIMEOUT,
    )
    simulator_id: str | None = None
    cleanup_target: str | None = None
    if created.timed_out or created.returncode != 0:
        lifecycle_error = _command_error_code(created, "simctl-create")
    else:
        simulator_id = _created_simulator_id(created)
        if simulator_id is None:
            lifecycle_error = "simctl-create-invalid-udid"
        else:
            identity_error = _verify_created_simulator(
                runner,
                profile,
                simulator_name,
                simulator_id,
            )
            if identity_error is not None:
                lifecycle_error = identity_error
            else:
                cleanup_target = simulator_id
                cleanup_target_observer(simulator_id)
    cleanup_inventory_unknown = False
    if lifecycle_error is not None and cleanup_target is None:
        observed_ids, observed_error = _matching_simulators(
            runner, profile, simulator_name, strict_identity=False
        )
        cleanup_inventory_unknown = observed_error is not None
        new_ids = (observed_ids or set()) - preexisting_ids
        if simulator_id in new_ids or simulator_id is None and len(new_ids) == 1:
            cleanup_target = simulator_id or next(iter(new_ids))
            cleanup_target_observer(cleanup_target)

    install_timeout = (
        SIMCTL_VISIONOS_INSTALL_TIMEOUT
        if profile.name == "visionos"
        else SIMCTL_INSTALL_TIMEOUT
    )
    bootstatus_timeout = (
        SIMCTL_VISIONOS_BOOTSTATUS_TIMEOUT
        if profile.name == "visionos"
        else SIMCTL_BOOTSTATUS_TIMEOUT
    )
    prerequisites = (
        ("boot", SIMCTL_BOOT_TIMEOUT, "simctl-boot"),
        ("bootstatus", bootstatus_timeout, "simctl-bootstatus"),
        ("install", install_timeout, "simctl-install"),
    )
    if lifecycle_error is None and simulator_id is not None:
        for verb, timeout, error_base in prerequisites:
            if verb == "bootstatus":
                command = ["xcrun", "simctl", verb, simulator_id, "-b"]
            elif verb == "install":
                command = ["xcrun", "simctl", verb, simulator_id, str(profile.app_bundle)]
            else:
                command = ["xcrun", "simctl", verb, simulator_id]
            command_result = _run(runner, command, timeout)
            if command_result.returncode != 0 or command_result.timed_out:
                lifecycle_error = _command_error_code(command_result, error_base)
                break
            if verb == "install" and _app_metadata(
                profile.app_bundle, profile.name
            ) != _profile_source_identity(profile):
                lifecycle_error = "capture-app-bundle-changed"
                break
            if verb == "install":
                lifecycle_error = _installed_app_error(runner, simulator_id, profile)
                if lifecycle_error is not None:
                    break

    if lifecycle_error is not None:
        results = _unknown_results(requirements, lifecycle_error, now)
    elif simulator_id is not None:
        capture_profile = _simulator_capture_profile(profile.name)
        for index, requirement in enumerate(requirements):
            host_mechanism = (
                "xcuitest-shared-view-renderer"
                if profile.ui_test_run is not None
                else "simctl-gallery"
            )
            appearance_mechanism: str | None = None
            route_baseline: PNGSnapshot | None = None
            stable_snapshot: PNGSnapshot | None = None
            stable_path: Path | None = None
            if index > 0:
                if profile.name == "visionos":
                    reset_error = _reset_visionos_cell(
                        runner,
                        simulator_id,
                        simulator_name,
                        profile,
                    )
                    if reset_error is not None:
                        results[requirement.requirement_id] = _result(
                            requirement,
                            status="unknown",
                            captured_at=now(),
                            host_mechanism=host_mechanism,
                            appearance_mechanism=None,
                            error_code=reset_error,
                        )
                        continue
                else:
                    _run(
                        runner,
                        [
                            "xcrun",
                            "simctl",
                            "terminate",
                            simulator_id,
                            profile.bundle_identifier,
                        ],
                        SIMCTL_TERMINATE_TIMEOUT,
                    )
            if profile.ui_test_run is not None:
                (
                    route_baseline,
                    stable_snapshot,
                    stable_path,
                    capture_error,
                ) = _take_visionos_ui_test_capture(
                    runner,
                    simulator_id,
                    profile,
                    requirement,
                    artifact_directory,
                )
                appearance_mechanism = "xcuitest-gallery-route"
                if (
                    capture_error is not None
                    or route_baseline is None
                    or stable_snapshot is None
                    or stable_path is None
                ):
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism=host_mechanism,
                        appearance_mechanism=appearance_mechanism,
                        error_code=capture_error,
                    )
                    continue
            elif capture_profile.applies_simulator_appearance:
                simulator_appearance = (
                    requirement.appearance
                    if requirement.appearance in {"light", "dark"}
                    else "automatic"
                )
                appearance = _run(
                    runner,
                    ["xcrun", "simctl", "ui", simulator_id, "appearance", simulator_appearance],
                    SIMCTL_UI_TIMEOUT,
                )
                if appearance.returncode != 0 or appearance.timed_out:
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism=host_mechanism,
                        appearance_mechanism=None,
                        error_code=_command_error_code(appearance, "simctl-ui"),
                    )
                    continue
                appearance_mechanism = "simctl-ui-appearance"
                sleeper(CAPTURE_SETTLE_SECONDS)
            if profile.ui_test_run is None:
                route_baseline, route_baseline_path, baseline_error = _take_stable_screenshot(
                    runner,
                    simulator_id,
                    artifact_directory,
                    f".{requirement.requirement_id}.baseline.",
                    "simctl-baseline-screenshot",
                    "simulator-baseline-image-invalid",
                    "baseline-unstable",
                    sleeper,
                )
                if (
                    baseline_error is not None
                    or route_baseline is None
                    or route_baseline_path is None
                ):
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism=host_mechanism,
                        appearance_mechanism=appearance_mechanism,
                        error_code=baseline_error,
                    )
                    continue
                route_baseline_path.unlink(missing_ok=True)
                route_command, route_error_base, route_appearance_mechanism = _capture_route(
                    profile,
                    simulator_id,
                    requirement,
                )
                routed = _run(runner, route_command, SIMCTL_LAUNCH_TIMEOUT)
                if routed.returncode != 0 or routed.timed_out:
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism=host_mechanism,
                        appearance_mechanism=appearance_mechanism,
                        error_code=_command_error_code(routed, route_error_base),
                    )
                    continue
                appearance_mechanism = route_appearance_mechanism
                sleeper(CAPTURE_SETTLE_SECONDS)
                stable_snapshot, stable_path, capture_error = _take_stable_screenshot(
                    runner,
                    simulator_id,
                    artifact_directory,
                    f".{requirement.requirement_id}.capture.",
                    "simctl-screenshot",
                    "captured-image-invalid",
                    "capture-unstable",
                    sleeper,
                )
                if capture_error is not None or stable_snapshot is None or stable_path is None:
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism=host_mechanism,
                        appearance_mechanism=appearance_mechanism,
                        error_code=capture_error,
                    )
                    continue
            if route_baseline is None or stable_snapshot is None or stable_path is None:
                raise SharedViewCaptureError("capture result is unavailable")
            try:
                if stable_snapshot.pixel_digest == route_baseline.pixel_digest:
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism=host_mechanism,
                        appearance_mechanism=appearance_mechanism,
                        error_code="route-baseline-unchanged",
                    )
                    continue
                duplicate_owner = seen_digests.get(stable_snapshot.pixel_digest)
                if stable_snapshot.pixel_digest in seen_digests:
                    if duplicate_owner is not None:
                        prior_path = artifact_paths.pop(duplicate_owner, None)
                        if prior_path is None:
                            prior_path = published_artifact_paths.pop(
                                duplicate_owner, None
                            )
                        else:
                            published_artifact_paths.pop(duplicate_owner, None)
                        if prior_path is not None:
                            prior_path.unlink(missing_ok=True)
                        prior_result = results.get(duplicate_owner) or prior_results.get(
                            duplicate_owner
                        )
                        if prior_result is None:
                            raise SharedViewCaptureError(
                                "captured artifact ownership is invalid"
                            )
                        _mark_result_unknown(
                            prior_result,
                            "duplicate-artifact-digest",
                            now(),
                        )
                    seen_digests[stable_snapshot.pixel_digest] = None
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism=host_mechanism,
                        appearance_mechanism=appearance_mechanism,
                        error_code="duplicate-artifact-digest",
                    )
                    continue
                final_path = artifact_directory / f"{requirement.requirement_id}.png"
                try:
                    os.chmod(stable_path, 0o600)
                    _fsync_file(stable_path)
                    os.replace(stable_path, final_path)
                    os.chmod(final_path, 0o600)
                except OSError:
                    final_path.unlink(missing_ok=True)
                    seen_digests[stable_snapshot.pixel_digest] = None
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism=host_mechanism,
                        appearance_mechanism=appearance_mechanism,
                        error_code="artifact-publish-failed",
                    )
                    continue
                seen_digests[stable_snapshot.pixel_digest] = requirement.requirement_id
                artifact_paths[requirement.requirement_id] = final_path
                published_artifact_paths[requirement.requirement_id] = final_path
                results[requirement.requirement_id] = _result(
                    requirement,
                    status="captured",
                    captured_at=now(),
                    host_mechanism=host_mechanism,
                    appearance_mechanism=appearance_mechanism,
                    snapshot=stable_snapshot,
                )
            finally:
                stable_path.unlink(missing_ok=True)

    if cleanup_target is None:
        if cleanup_inventory_unknown:
            cleanup_status = "inventory-unknown"
        else:
            cleanup_status = "identity-unverified"
        cleanup_error = None
    else:
        cleanup_status, cleanup_error = _cleanup_simulator(
            runner, cleanup_target, profile, simulator_name
        )
    if cleanup_error is not None:
        withdrawn_requirement_ids = set(artifact_paths)
        for digest, requirement_id in list(seen_digests.items()):
            if requirement_id in withdrawn_requirement_ids:
                seen_digests[digest] = None
        artifacts_removed = _remove_profile_artifacts(artifact_paths)
        for requirement_id in artifact_paths:
            published_artifact_paths.pop(requirement_id, None)
        final_error = cleanup_error
        if not artifacts_removed:
            cleanup_status = f"{cleanup_status}-and-artifact-cleanup-failed"
            final_error = f"{cleanup_error}-and-artifact-cleanup-failed"
        for requirement in requirements:
            result = results.get(requirement.requirement_id)
            if result is None:
                result = _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism=None,
                    error_code=final_error,
                )
                results[requirement.requirement_id] = result
            elif result["status"] == "captured":
                _mark_result_unknown(result, final_error, now())
    return ProfileCaptureOutcome(results=results, cleanup_status=cleanup_status)


def execute_shared_view_capture(
    surface_comparison_path: Path,
    current_manifest_path: Path,
    requirements_path: Path,
    config_path: Path,
    artifact_root: Path,
    output_path: Path,
    *,
    runner: Runner | None = None,
    sleeper: Callable[[float], None] = time.sleep,
    now: Callable[[], datetime] = utc_now,
    run_id_factory: Callable[[], str] = lambda: uuid.uuid4().hex,
    matrix_path: Path = DEFAULT_MATRIX_PATH,
    surface_policy_path: Path = DEFAULT_SURFACE_POLICY_PATH,
) -> tuple[int, dict[str, object]]:
    resolved_policy_path = surface_policy_path.expanduser().resolve(strict=True)
    policy_bytes = _read_bounded_file(
        resolved_policy_path,
        "surface policy",
        MAX_JSON_FILE_BYTES,
    )
    matrix_bytes = _read_bounded_file(
        matrix_path.expanduser().resolve(strict=True),
        "shared-view matrix",
        MAX_JSON_FILE_BYTES,
    )
    try:
        policy = json.loads(policy_bytes)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise SharedViewCaptureError("surface policy is unavailable or invalid") from error
    if not isinstance(policy, dict):
        raise SharedViewCaptureError("surface policy is unavailable or invalid")
    with tempfile.NamedTemporaryFile(suffix=".json") as policy_snapshot, tempfile.NamedTemporaryFile(
        suffix=".json"
    ) as matrix_snapshot:
        policy_snapshot.write(policy_bytes)
        policy_snapshot.flush()
        matrix_snapshot.write(matrix_bytes)
        matrix_snapshot.flush()
        surface_policy = load_surface_policy(Path(policy_snapshot.name))
        matrix = load_shared_view_matrix(Path(matrix_snapshot.name), surface_policy)
    comparison = _load_json_object(surface_comparison_path, "surface comparison")
    planned_payload = plan_shared_view_evidence(comparison, matrix, surface_policy)
    plan = load_capture_requirements(requirements_path, planned_payload, matrix, surface_policy)
    expected_manifest, expected_version, expected_build = _expected_embedded_manifest(
        current_manifest_path,
        policy,
        hashlib.sha256(policy_bytes).hexdigest(),
    )
    expected_manifest_id = _require_sha256(
        expected_manifest.get("manifestId"), "current surface manifest identifier"
    )
    expected_manifest_digest = canonical_json_hash(
        EMBEDDED_MANIFEST_DIGEST_DOMAIN, expected_manifest
    )
    if expected_manifest_id != plan.current_manifest_id:
        raise SharedViewCaptureError("current surface manifest does not match comparison")
    profiles = load_capture_config(config_path)
    private_root = _validate_artifact_root(artifact_root)
    public_output = _validate_output_path(output_path)
    _reject_capture_path_overlap(
        private_root,
        public_output,
        profiles,
        (
            surface_comparison_path,
            current_manifest_path,
            requirements_path,
            config_path,
            matrix_path,
            resolved_policy_path,
        ),
    )
    active_runner = runner or SubprocessRunner()
    configured_groups: dict[str, list[CaptureRequirement]] = {profile: [] for profile in SUPPORTED_PROFILES}
    capture_results: dict[str, dict[str, object]] = {}
    for requirement in plan.requirements:
        profile_name = _profile_for_surface(requirement.surface)
        if profile_name is None:
            capture_results[requirement.requirement_id] = _result(
                requirement,
                status="blocked",
                captured_at=now(),
                host_mechanism="unsupported-host-mechanism",
                appearance_mechanism=None,
                error_code="unsupported-host-mechanism",
            )
        elif profile_name not in profiles:
            capture_results[requirement.requirement_id] = _result(
                requirement,
                status="blocked",
                captured_at=now(),
                host_mechanism="unconfigured-profile",
                appearance_mechanism=None,
                error_code="profile-not-configured",
            )
        else:
            configured_groups[profile_name].append(requirement)

    active_profile_names = [
        profile_name for profile_name in SUPPORTED_PROFILES if configured_groups[profile_name]
    ]
    if any(
        profiles[profile_name].manifest_id != plan.current_manifest_id
        or profiles[profile_name].manifest_digest != expected_manifest_digest
        or not {item.surface for item in configured_groups[profile_name]}.issubset(
            profiles[profile_name].manifest_surfaces
        )
        for profile_name in active_profile_names
    ):
        raise SharedViewCaptureError("capture app surface manifest does not match comparison")
    if any(
        profiles[profile_name].version != expected_version
        or profiles[profile_name].build != expected_build
        for profile_name in active_profile_names
    ):
        raise SharedViewCaptureError(
            "capture app version does not match current surface manifest"
        )
    _prepare_private_directory(private_root)
    catalog_metadata: dict[str, SimulatorProfileMetadata | None] = {
        profile_name: None for profile_name in active_profile_names
    }
    profile_errors: dict[str, str] = {}
    if active_profile_names:
        runtimes, device_types, catalog_error = _simulator_catalog(active_runner)
        if catalog_error is not None or runtimes is None or device_types is None:
            for profile_name in active_profile_names:
                profile_errors[profile_name] = catalog_error or "simctl-catalog-invalid"
        else:
            for profile_name in active_profile_names:
                metadata, profile_error = _profile_catalog_metadata(
                    profiles[profile_name], runtimes, device_types
                )
                catalog_metadata[profile_name] = metadata
                if profile_error is not None:
                    profile_errors[profile_name] = profile_error

    manifest_directory = private_root / plan.current_manifest_id
    _prepare_private_directory(manifest_directory)
    capture_run_id, staging_directory, run_directory = _create_run_directories(
        manifest_directory,
        run_id_factory,
    )
    ownership_token = uuid.uuid4().hex
    ownership_path = staging_directory / ".capture-owner"
    cleanup_statuses = {profile_name: "not-started" for profile_name in active_profile_names}
    seen_digests: dict[str, str | None] = {}
    published_artifact_paths: dict[str, Path] = {}
    owns_run_directory = False
    run_published = False
    captures: list[dict[str, object]] = []
    receipt: dict[str, object] = {}
    try:
        try:
            ownership_descriptor = os.open(
                ownership_path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(ownership_descriptor, "w") as ownership_stream:
                ownership_stream.write(ownership_token)
                ownership_stream.flush()
                os.fsync(ownership_stream.fileno())
        except OSError as error:
            raise SharedViewCaptureError("capture run ownership marker is unavailable") from error
        for profile_name in active_profile_names:
            requirements = tuple(configured_groups[profile_name])
            profile_error = profile_errors.get(profile_name)
            if profile_error is not None:
                if profile_error.startswith("simctl-profile-"):
                    capture_results.update(
                        _blocked_results(
                            requirements,
                            profile_error,
                            now,
                            host_mechanism="simctl-profile-validation",
                        )
                    )
                else:
                    capture_results.update(_unknown_results(requirements, profile_error, now))
                continue
            snapshot_profile, snapshot_path = _snapshot_profile(
                profiles[profile_name], staging_directory
            )
            emergency_cleanup_targets: list[str] = []
            profile_capture_completed = False
            try:
                outcome = _capture_profile(
                    snapshot_profile,
                    requirements,
                    staging_directory,
                    capture_run_id,
                    active_runner,
                    sleeper,
                    now,
                    seen_digests,
                    capture_results,
                    published_artifact_paths,
                    emergency_cleanup_targets.append,
                )
                profile_capture_completed = True
            except BaseException as capture_error:
                if emergency_cleanup_targets:
                    _, emergency_cleanup_error = _cleanup_simulator(
                        active_runner,
                        emergency_cleanup_targets[-1],
                        snapshot_profile,
                        _simulator_name(profile_name, capture_run_id),
                    )
                    if emergency_cleanup_error is not None:
                        raise SharedViewCaptureError(
                            "capture failed and emergency simulator cleanup did not complete: "
                            f"{emergency_cleanup_error}"
                        ) from capture_error
                raise
            finally:
                shutil.rmtree(snapshot_path, ignore_errors=True)
                if snapshot_path.exists() and profile_capture_completed:
                    raise SharedViewCaptureError("capture input snapshot cleanup failed")
            cleanup_statuses[profile_name] = outcome.cleanup_status
            capture_results.update(outcome.results)
        captures = [capture_results[requirement.requirement_id] for requirement in plan.requirements]
        receipt = {
            "schemaVersion": CAPTURE_RECEIPT_SCHEMA_VERSION,
            "kind": CAPTURE_RECEIPT_KIND,
            "captureRunID": capture_run_id,
            "currentManifestID": plan.current_manifest_id,
            "requirementsDigest": plan.requirements_digest,
            "matrixDigest": matrix.digest(),
            "pixelDiffPolicy": PIXEL_DIFF_POLICY,
            "profiles": [
                profiles[profile_name].public_dict(
                    catalog_metadata[profile_name], cleanup_statuses[profile_name]
                )
                for profile_name in active_profile_names
            ],
            "captures": captures,
        }
        _atomic_write_json(staging_directory / "index.json", receipt, 0o600)
        try:
            _rename_exclusive(staging_directory, run_directory)
            owns_run_directory = True
            _fsync_directory(manifest_directory)
            run_published = True
        except OSError as error:
            raise SharedViewCaptureError("capture run publication failed") from error
        _atomic_write_json(public_output, receipt, 0o644)
    finally:
        failure_in_flight = sys.exc_info()[1]
        if not run_published:
            rollback_error: OSError | None = None
            if staging_directory.exists():
                try:
                    shutil.rmtree(staging_directory)
                    _fsync_directory(manifest_directory)
                except OSError as error:
                    rollback_error = error
            if owns_run_directory:
                published_owner = run_directory / ownership_path.name
                try:
                    owns_published_path = _read_bounded_file(
                        published_owner, "capture run ownership marker", 128
                    ) == ownership_token.encode()
                except SharedViewCaptureError:
                    owns_published_path = False
                if owns_published_path:
                    try:
                        shutil.rmtree(run_directory)
                        _fsync_directory(manifest_directory)
                    except OSError as error:
                        rollback_error = rollback_error or error
            if rollback_error is not None:
                raise SharedViewCaptureError("capture run rollback failed") from (
                    failure_in_flight or rollback_error
                )
    statuses = {capture["status"] for capture in captures}
    if statuses == {"captured"}:
        return EXIT_OK, receipt
    if "unknown" in statuses:
        return EXIT_UNKNOWN, receipt
    return EXIT_BLOCKED, receipt
