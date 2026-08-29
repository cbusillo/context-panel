from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import tempfile
import time
from typing import Any, Callable
from urllib.parse import urlencode
import uuid
import zlib

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
    shared_view_requirement_id,
)
from .system import SubprocessRunner


REPO_ROOT = Path(__file__).resolve().parents[2]
CAPTURE_CONFIG_SCHEMA_VERSION = 1
CAPTURE_CONFIG_KIND = "context-panel-shared-view-capture-config"
CAPTURE_RECEIPT_SCHEMA_VERSION = 1
CAPTURE_RECEIPT_KIND = "context-panel-shared-view-capture-receipt"
REQUIREMENTS_SCHEMA_VERSION = 1
REQUIREMENTS_KIND = "context-panel-visual-review-requirements"
REQUIREMENTS_DIGEST_DOMAIN = "context-panel-shared-view-capture-requirements/v1"
APP_BUNDLE_IDENTIFIER = "com.shinycomputers.contextpanel"
SUPPORTED_PROFILES = ("ios", "ipados", "visionos")
PROFILE_SURFACE_PREFIXES = {
    "ios": "ios.",
    "ipados": "ipados.",
    "visionos": "visionos.",
}
PROFILE_CATALOG_EXPECTATIONS = {
    "ios": (("iOS",), "iPhone"),
    "ipados": (("iOS",), "iPad"),
    "visionos": (("xrOS", "visionOS"), "Apple Vision"),
}
SIMCTL_CATALOG_TIMEOUT = 30
SIMCTL_CREATE_TIMEOUT = 30
SIMCTL_BOOT_TIMEOUT = 60
SIMCTL_BOOTSTATUS_TIMEOUT = 120
SIMCTL_INSTALL_TIMEOUT = 120
SIMCTL_TERMINATE_TIMEOUT = 30
SIMCTL_UI_TIMEOUT = 30
SIMCTL_OPENURL_TIMEOUT = 30
SIMCTL_SCREENSHOT_TIMEOUT = 60
SIMCTL_CLEANUP_TIMEOUT = 30
CAPTURE_SETTLE_SECONDS = 1.0
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SIMULATOR_UDID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
CAPTURE_RUN_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$")


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
    version: str
    build: str

    def public_dict(
        self,
        metadata: SimulatorProfileMetadata | None,
        cleanup_status: str,
    ) -> dict[str, object]:
        return {
            "profile": self.name,
            "runtimeIdentifier": self.runtime_identifier,
            "runtimeName": metadata.runtime_name if metadata is not None else None,
            "runtimePlatform": metadata.runtime_platform if metadata is not None else None,
            "deviceTypeIdentifier": self.device_type_identifier,
            "deviceTypeName": metadata.device_type_name if metadata is not None else None,
            "productFamily": metadata.product_family if metadata is not None else None,
            "appBundleIdentifier": self.bundle_identifier,
            "appExecutableSHA256": self.executable_sha256,
            "appVersion": self.version,
            "appBuild": self.build,
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
class CapturePlan:
    current_manifest_id: str
    requirements_digest: str
    requirements: tuple[CaptureRequirement, ...]


@dataclass(frozen=True)
class PNGSnapshot:
    content: bytes
    digest: str
    width: int
    height: int


@dataclass(frozen=True)
class ProfileCaptureOutcome:
    results: dict[str, dict[str, object]]
    cleanup_status: str


def _load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.expanduser().read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SharedViewCaptureError(f"{label} is unavailable or invalid") from error
    if not isinstance(payload, dict):
        raise SharedViewCaptureError(f"{label} is invalid")
    return payload


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


def _stream_sha256(path: Path, label: str) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise SharedViewCaptureError(f"{label} is unreadable") from error
    return digest.hexdigest()


def _app_metadata(path: Path) -> tuple[str, str, str, str]:
    info_path = path / "Info.plist"
    if not info_path.is_file() or info_path.is_symlink():
        raise SharedViewCaptureError("capture app bundle Info.plist is invalid")
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise SharedViewCaptureError("capture app bundle Info.plist is invalid") from error
    if not isinstance(info, dict):
        raise SharedViewCaptureError("capture app bundle Info.plist is invalid")
    bundle_identifier = _require_string(info.get("CFBundleIdentifier"), "capture app bundle identifier")
    if bundle_identifier != APP_BUNDLE_IDENTIFIER:
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
    return (
        bundle_identifier,
        _stream_sha256(executable, "capture app executable"),
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
        if not isinstance(raw_profile, dict) or set(raw_profile) != {
            "runtimeIdentifier",
            "deviceTypeIdentifier",
            "appBundle",
        }:
            raise SharedViewCaptureError("shared-view capture profile keys are invalid")
        app_bundle = _absolute_existing_directory(
            Path(_require_string(raw_profile["appBundle"], "capture app bundle")),
            "capture app bundle",
        )
        if app_bundle.suffix != ".app":
            raise SharedViewCaptureError("capture app bundle is invalid")
        bundle_identifier, executable_sha256, version, build = _app_metadata(app_bundle)
        profiles[name] = CaptureProfile(
            name=name,
            runtime_identifier=_require_string(
                raw_profile["runtimeIdentifier"], "capture runtime identifier"
            ),
            device_type_identifier=_require_string(
                raw_profile["deviceTypeIdentifier"], "capture device type identifier"
            ),
            app_bundle=app_bundle,
            bundle_identifier=bundle_identifier,
            executable_sha256=executable_sha256,
            version=version,
            build=build,
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
    if payload != planned_payload:
        raise SharedViewCaptureError(
            "shared-view capture requirements do not exactly match the canonical planner output"
        )
    manifest_id = _require_sha256(payload["currentManifestID"], "shared-view capture manifest identifier")
    raw_requirements = payload["requirements"]
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
        requirements_digest=canonical_json_hash(REQUIREMENTS_DIGEST_DOMAIN, planned_payload),
        requirements=tuple(requirements),
    )


def _profile_for_surface(surface: str) -> str | None:
    for profile, prefix in PROFILE_SURFACE_PREFIXES.items():
        if surface.startswith(prefix):
            return profile
    return None


def _validate_artifact_root(path: Path) -> Path:
    if not path.is_absolute() or path == Path(path.anchor):
        raise SharedViewCaptureError("capture artifact root is invalid")
    _reject_symlink_ancestors(path, "capture artifact root")
    resolved = path.resolve(strict=False)
    repo_root = REPO_ROOT.resolve()
    if resolved == repo_root or repo_root in resolved.parents:
        raise SharedViewCaptureError("capture artifact root must be outside the repository")
    return resolved


def _validate_output_path(path: Path) -> Path:
    if not path.is_absolute():
        raise SharedViewCaptureError("capture receipt output is invalid")
    _reject_symlink_ancestors(path, "capture receipt output")
    return path.resolve(strict=False)


def _prepare_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise SharedViewCaptureError("capture artifact root is invalid")
    os.chmod(path, 0o700)


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
        os.chmod(staging_directory, 0o700)
        return run_id, staging_directory, run_directory
    raise SharedViewCaptureError("capture run identifier is not unique")


def _atomic_write_json(path: Path, payload: dict[str, Any], mode: int) -> None:
    if path.is_symlink() or path.parent.is_symlink():
        raise SharedViewCaptureError("capture output path is invalid")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
        os.chmod(path, mode)
    except OSError as error:
        raise SharedViewCaptureError("capture output is unavailable") from error
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def _png_snapshot(path: Path) -> PNGSnapshot:
    try:
        if path.is_symlink():
            raise SharedViewCaptureError("captured image is invalid")
        data = path.read_bytes()
    except OSError as error:
        raise SharedViewCaptureError("captured image is invalid") from error
    if len(data) < len(PNG_SIGNATURE) or data[:8] != PNG_SIGNATURE:
        raise SharedViewCaptureError("captured image is invalid")
    offset = len(PNG_SIGNATURE)
    chunk_index = 0
    width = 0
    height = 0
    bit_depth = 0
    color_type = 0
    saw_idat = False
    saw_iend = False
    compressed_image = bytearray()
    while offset < len(data):
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
                or bit_depth != 8
                or color_type not in {2, 6}
                or chunk_data[10:13] != b"\x00\x00\x00"
            ):
                raise SharedViewCaptureError("captured image is invalid")
        elif chunk_type == b"IHDR":
            raise SharedViewCaptureError("captured image is invalid")
        if chunk_type == b"IDAT":
            saw_idat = True
            compressed_image.extend(chunk_data)
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
    try:
        image_data = zlib.decompress(bytes(compressed_image))
    except zlib.error as error:
        raise SharedViewCaptureError("captured image is invalid") from error
    row_size = 1 + (width * channels)
    if len(image_data) != height * row_size:
        raise SharedViewCaptureError("captured image is invalid")
    for row_offset in range(0, len(image_data), row_size):
        if image_data[row_offset] > 4:
            raise SharedViewCaptureError("captured image is invalid")
    return PNGSnapshot(
        content=data,
        digest=hashlib.sha256(data).hexdigest(),
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
        "artifactDigest": snapshot.digest if snapshot is not None else None,
        "artifactBytes": len(snapshot.content) if snapshot is not None else None,
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
) -> dict[str, dict[str, object]]:
    return {
        requirement.requirement_id: _result(
            requirement,
            status="blocked",
            captured_at=now(),
            host_mechanism="unconfigured-profile",
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
    simulator_id: str | None = None
    for line in result.stdout.splitlines():
        candidate = line.strip()
        if SIMULATOR_UDID_PATTERN.fullmatch(candidate):
            simulator_id = candidate
    return simulator_id


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
    expected_platforms, expected_family = PROFILE_CATALOG_EXPECTATIONS[profile.name]
    if runtime_platform not in expected_platforms or product_family != expected_family:
        return metadata, "simctl-profile-mismatch"
    return metadata, None


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
    except SharedViewCaptureError:
        temporary_path.unlink(missing_ok=True)
        return None, None, invalid_error_code
    return snapshot, temporary_path, None


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
    if deleted.timed_out:
        return "delete-timeout", "simctl-delete-timeout"
    if deleted.returncode != 0:
        return "delete-failed", "simctl-delete-failed"
    if shutdown.timed_out:
        return "deleted-after-shutdown-timeout", None
    if shutdown.returncode != 0:
        return "deleted-after-shutdown-failure", None
    return "deleted", None


def _simulator_name(profile_name: str, capture_run_id: str) -> str:
    return f"ContextPanelSharedView-{profile_name}-{capture_run_id}"


def _capture_profile(
    profile: CaptureProfile,
    requirements: tuple[CaptureRequirement, ...],
    artifact_directory: Path,
    capture_run_id: str,
    runner: Runner,
    sleeper: Callable[[float], None],
    now: Callable[[], datetime],
) -> ProfileCaptureOutcome:
    results: dict[str, dict[str, object]] = {}
    artifact_paths: dict[str, Path] = {}
    simulator_name = _simulator_name(profile.name, capture_run_id)
    lifecycle_error: str | None = None
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
    if created.timed_out:
        lifecycle_error = _command_error_code(created, "simctl-create")
        cleanup_target = simulator_name
    elif created.returncode != 0:
        lifecycle_error = _command_error_code(created, "simctl-create")
    else:
        simulator_id = _created_simulator_id(created)
        cleanup_target = simulator_id or simulator_name
        if simulator_id is None:
            lifecycle_error = "simctl-create-invalid-udid"

    prerequisites = (
        ("boot", SIMCTL_BOOT_TIMEOUT, "simctl-boot"),
        ("bootstatus", SIMCTL_BOOTSTATUS_TIMEOUT, "simctl-bootstatus"),
        ("install", SIMCTL_INSTALL_TIMEOUT, "simctl-install"),
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

    if lifecycle_error is not None:
        results = _unknown_results(requirements, lifecycle_error, now)
    elif simulator_id is not None:
        seen_digests: dict[str, str | None] = {}
        for index, requirement in enumerate(requirements):
            appearance_mechanism: str | None = None
            if index > 0:
                terminated = _run(
                    runner,
                    ["xcrun", "simctl", "terminate", simulator_id, profile.bundle_identifier],
                    SIMCTL_TERMINATE_TIMEOUT,
                )
                if terminated.returncode != 0 or terminated.timed_out:
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism="simctl-gallery",
                        appearance_mechanism=None,
                        error_code=_command_error_code(terminated, "simctl-terminate"),
                    )
                    continue
            if requirement.appearance in {"light", "dark"}:
                appearance = _run(
                    runner,
                    ["xcrun", "simctl", "ui", simulator_id, "appearance", requirement.appearance],
                    SIMCTL_UI_TIMEOUT,
                )
                if appearance.returncode != 0 or appearance.timed_out:
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism="simctl-gallery",
                        appearance_mechanism=None,
                        error_code=_command_error_code(appearance, "simctl-ui"),
                    )
                    continue
                appearance_mechanism = "simctl-ui-appearance"
            route_baseline, route_baseline_path, route_baseline_error = _take_screenshot(
                runner,
                simulator_id,
                artifact_directory,
                f".{requirement.requirement_id}.baseline.",
                "simctl-baseline-screenshot",
                "simulator-baseline-image-invalid",
            )
            if route_baseline_path is not None:
                route_baseline_path.unlink(missing_ok=True)
            if route_baseline_error is not None or route_baseline is None:
                results[requirement.requirement_id] = _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism=appearance_mechanism,
                    error_code=route_baseline_error,
                )
                continue
            opened = _run(
                runner,
                ["xcrun", "simctl", "openurl", simulator_id, _capture_url(requirement)],
                SIMCTL_OPENURL_TIMEOUT,
            )
            if opened.returncode != 0 or opened.timed_out:
                results[requirement.requirement_id] = _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism=appearance_mechanism,
                    error_code=_command_error_code(opened, "simctl-openurl"),
                )
                continue
            appearance_mechanism = (
                "gallery-route"
                if requirement.appearance == "adaptive"
                else "simctl-ui-appearance+gallery-route"
            )
            sleeper(CAPTURE_SETTLE_SECONDS)
            first_snapshot, first_path, first_error = _take_screenshot(
                runner,
                simulator_id,
                artifact_directory,
                f".{requirement.requirement_id}.first.",
                "simctl-screenshot",
                "captured-image-invalid",
            )
            if first_error is not None or first_snapshot is None:
                results[requirement.requirement_id] = _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism=appearance_mechanism,
                    error_code=first_error,
                )
                continue
            try:
                sleeper(CAPTURE_SETTLE_SECONDS)
                second_snapshot, second_path, second_error = _take_screenshot(
                    runner,
                    simulator_id,
                    artifact_directory,
                    f".{requirement.requirement_id}.second.",
                    "simctl-screenshot",
                    "captured-image-invalid",
                )
                if second_error is not None or second_snapshot is None or second_path is None:
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism="simctl-gallery",
                        appearance_mechanism=appearance_mechanism,
                        error_code=second_error,
                    )
                    continue
                try:
                    if first_snapshot.digest != second_snapshot.digest:
                        results[requirement.requirement_id] = _result(
                            requirement,
                            status="unknown",
                            captured_at=now(),
                            host_mechanism="simctl-gallery",
                            appearance_mechanism=appearance_mechanism,
                            error_code="capture-unstable",
                        )
                        continue
                    if second_snapshot.digest == route_baseline.digest:
                        results[requirement.requirement_id] = _result(
                            requirement,
                            status="unknown",
                            captured_at=now(),
                            host_mechanism="simctl-gallery",
                            appearance_mechanism=appearance_mechanism,
                            error_code="route-baseline-unchanged",
                        )
                        continue
                    duplicate_owner = seen_digests.get(second_snapshot.digest)
                    if second_snapshot.digest in seen_digests:
                        if duplicate_owner is not None:
                            prior_path = artifact_paths.pop(duplicate_owner, None)
                            if prior_path is not None:
                                prior_path.unlink(missing_ok=True)
                            _mark_result_unknown(
                                results[duplicate_owner],
                                "duplicate-artifact-digest",
                                now(),
                            )
                        seen_digests[second_snapshot.digest] = None
                        results[requirement.requirement_id] = _result(
                            requirement,
                            status="unknown",
                            captured_at=now(),
                            host_mechanism="simctl-gallery",
                            appearance_mechanism=appearance_mechanism,
                            error_code="duplicate-artifact-digest",
                        )
                        continue
                    final_path = artifact_directory / f"{requirement.requirement_id}.png"
                    try:
                        os.chmod(second_path, 0o600)
                        os.replace(second_path, final_path)
                        os.chmod(final_path, 0o600)
                    except OSError:
                        final_path.unlink(missing_ok=True)
                        results[requirement.requirement_id] = _result(
                            requirement,
                            status="unknown",
                            captured_at=now(),
                            host_mechanism="simctl-gallery",
                            appearance_mechanism=appearance_mechanism,
                            error_code="artifact-publish-failed",
                        )
                        continue
                    seen_digests[second_snapshot.digest] = requirement.requirement_id
                    artifact_paths[requirement.requirement_id] = final_path
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="captured",
                        captured_at=now(),
                        host_mechanism="simctl-gallery",
                        appearance_mechanism=appearance_mechanism,
                        snapshot=second_snapshot,
                    )
                finally:
                    second_path.unlink(missing_ok=True)
            finally:
                first_path.unlink(missing_ok=True)

    if cleanup_target is None:
        cleanup_status, cleanup_error = "not-created", None
    else:
        cleanup_status, cleanup_error = _cleanup_simulator(runner, cleanup_target)
    if cleanup_error is not None:
        artifacts_removed = _remove_profile_artifacts(artifact_paths)
        final_error = cleanup_error if artifacts_removed else "artifact-cleanup-failed"
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
            else:
                _mark_result_unknown(result, final_error, now())
    return ProfileCaptureOutcome(results=results, cleanup_status=cleanup_status)


def execute_shared_view_capture(
    surface_comparison_path: Path,
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
    surface_policy = load_surface_policy(surface_policy_path)
    matrix = load_shared_view_matrix(matrix_path, surface_policy)
    comparison = _load_json_object(surface_comparison_path, "surface comparison")
    planned_payload = plan_shared_view_evidence(comparison, matrix, surface_policy)
    plan = load_capture_requirements(requirements_path, planned_payload, matrix, surface_policy)
    profiles = load_capture_config(config_path)
    private_root = _validate_artifact_root(artifact_root)
    public_output = _validate_output_path(output_path)
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

    _prepare_private_directory(private_root)
    manifest_directory = private_root / plan.current_manifest_id
    _prepare_private_directory(manifest_directory)
    capture_run_id, staging_directory, run_directory = _create_run_directories(
        manifest_directory,
        run_id_factory,
    )
    cleanup_statuses = {profile_name: "not-started" for profile_name in active_profile_names}
    run_published = False
    try:
        for profile_name in active_profile_names:
            requirements = tuple(configured_groups[profile_name])
            profile_error = profile_errors.get(profile_name)
            if profile_error is not None:
                if profile_error.startswith("simctl-profile-"):
                    capture_results.update(_blocked_results(requirements, profile_error, now))
                else:
                    capture_results.update(_unknown_results(requirements, profile_error, now))
                continue
            profile_capture_completed = False
            try:
                outcome = _capture_profile(
                    profiles[profile_name],
                    requirements,
                    staging_directory,
                    capture_run_id,
                    active_runner,
                    sleeper,
                    now,
                )
                profile_capture_completed = True
            finally:
                if not profile_capture_completed:
                    _cleanup_simulator(
                        active_runner,
                        _simulator_name(profile_name, capture_run_id),
                    )
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
            os.replace(staging_directory, run_directory)
        except OSError as error:
            raise SharedViewCaptureError("capture run publication failed") from error
        _atomic_write_json(public_output, receipt, 0o644)
        run_published = True
    finally:
        if not run_published:
            shutil.rmtree(staging_directory, ignore_errors=True)
            shutil.rmtree(run_directory, ignore_errors=True)
    statuses = {capture["status"] for capture in captures}
    if statuses == {"captured"}:
        return EXIT_OK, receipt
    if "unknown" in statuses:
        return EXIT_UNKNOWN, receipt
    return EXIT_BLOCKED, receipt
