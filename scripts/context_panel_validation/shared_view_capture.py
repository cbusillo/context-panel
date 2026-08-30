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
import tempfile
import time
from typing import Any, Callable
from urllib.parse import urlencode
import uuid
import zlib

from context_panel_surface_manifest import SurfacePolicyError, embedded_manifest

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
EMBEDDED_MANIFEST_DIGEST_DOMAIN = "context-panel-shared-view-capture-embedded-manifest/v1"
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
SIMCTL_CONTAINER_TIMEOUT = 30
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


def _bundle_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        for candidate in sorted(path.rglob("*"), key=lambda item: item.relative_to(path).as_posix()):
            relative = candidate.relative_to(path).as_posix().encode()
            candidate_stat = candidate.lstat()
            if stat.S_ISDIR(candidate_stat.st_mode):
                kind, content = b"D", b""
            elif stat.S_ISREG(candidate_stat.st_mode):
                kind, content = b"F", candidate.read_bytes()
            elif stat.S_ISLNK(candidate_stat.st_mode):
                kind, content = b"L", os.readlink(candidate).encode()
            else:
                raise SharedViewCaptureError("capture app bundle is invalid")
            digest.update(kind + len(relative).to_bytes(8, "big") + relative)
            digest.update(stat.S_IMODE(candidate_stat.st_mode).to_bytes(4, "big"))
            digest.update(len(content).to_bytes(8, "big") + content)
    except OSError as error:
        raise SharedViewCaptureError("capture app bundle is unreadable") from error
    return digest.hexdigest()


def _embedded_manifest_metadata(path: Path) -> tuple[str, str, str, frozenset[str]]:
    resources = path / "Contents" / "Resources" if (path / "Contents").is_dir() else path
    manifest_path = resources / "ContextPanelSurfaceManifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise SharedViewCaptureError("capture app surface manifest is invalid")
    try:
        payload = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SharedViewCaptureError("capture app surface manifest is invalid") from error
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


def _expected_embedded_manifest(path: Path) -> dict[str, Any]:
    source_manifest = _load_json_object(path, "current surface manifest")
    try:
        return embedded_manifest(source_manifest)
    except SurfacePolicyError as error:
        raise SharedViewCaptureError("current surface manifest is invalid") from error


def _app_metadata(
    path: Path,
) -> tuple[str, str, str, str, str, frozenset[str], str, str, str]:
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
    if (
        len(version) > 64
        or len(build) > 64
        or not BUNDLE_VERSION_PATTERN.fullmatch(version)
        or not BUNDLE_VERSION_PATTERN.fullmatch(build)
    ):
        raise SharedViewCaptureError("capture app version metadata is invalid")
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
    return (
        bundle_identifier,
        _stream_sha256(executable, "capture app executable"),
        _bundle_sha256(path),
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
        ) = _app_metadata(app_bundle)
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
        except FileExistsError:
            pass
        except OSError as error:
            raise SharedViewCaptureError("capture artifact root is unavailable") from error
        if directory.is_symlink() or not directory.is_dir():
            raise SharedViewCaptureError("capture artifact root is invalid")
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except OSError as error:
        raise SharedViewCaptureError("capture artifact root is unavailable") from error
    if mode != 0o700:
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
        os.chmod(staging_directory, 0o700)
        return run_id, staging_directory, run_directory
    raise SharedViewCaptureError("capture run identifier is not unique")


def _atomic_write_json(path: Path, payload: dict[str, Any], mode: int) -> None:
    if path.is_symlink() or path.parent.is_symlink():
        raise SharedViewCaptureError("capture output path is invalid")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    replaced = False
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
        replaced = True
        _fsync_directory(path.parent)
    except OSError as error:
        if replaced:
            path.unlink(missing_ok=True)
        raise SharedViewCaptureError("capture output is unavailable") from error
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


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
        if chunk_type[0] & 0x20 == 0 and chunk_type not in {b"IHDR", b"PLTE", b"IDAT", b"IEND"}:
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
) -> tuple[set[str] | None, str | None]:
    result = _run(
        runner,
        ["xcrun", "simctl", "list", "-j", "devices", simulator_name],
        SIMCTL_CATALOG_TIMEOUT,
    )
    if result.returncode != 0 or result.timed_out:
        return None, _command_error_code(result, "simctl-created-device")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None, "simctl-created-device-invalid"
    if not isinstance(payload, dict) or not isinstance(payload.get("devices"), dict):
        return None, "simctl-created-device-invalid"
    matches: set[str] = set()
    for runtime_identifier, raw_devices in payload["devices"].items():
        if not isinstance(runtime_identifier, str) or not isinstance(raw_devices, list):
            return None, "simctl-created-device-invalid"
        for raw_device in raw_devices:
            if not isinstance(raw_device, dict):
                return None, "simctl-created-device-invalid"
            simulator_id = raw_device.get("udid")
            if (
                raw_device.get("name") == simulator_name
                and runtime_identifier == profile.runtime_identifier
                and raw_device.get("deviceTypeIdentifier") == profile.device_type_identifier
                and raw_device.get("isAvailable") is True
                and isinstance(simulator_id, str)
                and SIMULATOR_UDID_PATTERN.fullmatch(simulator_id)
            ):
                if simulator_id in matches:
                    return None, "simctl-created-device-mismatch"
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


def _snapshot_profile(profile: CaptureProfile, directory: Path) -> CaptureProfile:
    snapshot_path = directory / f".{profile.name}-install.app"
    try:
        shutil.copytree(profile.app_bundle, snapshot_path, symlinks=True)
    except OSError as error:
        raise SharedViewCaptureError("capture app snapshot failed") from error
    snapshot = replace(profile, app_bundle=snapshot_path)
    if _app_metadata(snapshot_path) != _profile_source_identity(profile):
        raise SharedViewCaptureError("capture app snapshot identity changed")
    return snapshot


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
    installed_path = Path(lines[0])
    if not installed_path.is_absolute() or installed_path.is_symlink() or not installed_path.is_dir():
        return "simctl-app-container-invalid"
    try:
        installed_identity = _app_metadata(installed_path)
    except SharedViewCaptureError:
        return "simctl-app-container-invalid"
    return None if installed_identity == _profile_source_identity(profile) else "simctl-app-container-mismatch"


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
    preexisting_ids, inventory_error = _matching_simulators(runner, profile, simulator_name)
    if inventory_error is not None or preexisting_ids is None:
        return ProfileCaptureOutcome(
            results=_unknown_results(requirements, inventory_error or "simctl-created-device-invalid", now),
            cleanup_status="not-started",
        )
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
    if created.timed_out:
        lifecycle_error = _command_error_code(created, "simctl-create")
    elif created.returncode != 0:
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
    if lifecycle_error is not None and cleanup_target is None and (
        created.timed_out or created.returncode == 0
    ):
        observed_ids, _ = _matching_simulators(runner, profile, simulator_name)
        new_ids = (observed_ids or set()) - preexisting_ids
        if len(new_ids) == 1:
            cleanup_target = next(iter(new_ids))

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
            if verb == "install" and _app_metadata(profile.app_bundle) != _profile_source_identity(profile):
                lifecycle_error = "capture-app-bundle-changed"
                break
            if verb == "install":
                lifecycle_error = _installed_app_error(runner, simulator_id, profile)
                if lifecycle_error is not None:
                    break

    if lifecycle_error is not None:
        results = _unknown_results(requirements, lifecycle_error, now)
    elif simulator_id is not None:
        seen_digests: dict[str, str | None] = {}
        for index, requirement in enumerate(requirements):
            appearance_mechanism: str | None = None
            if index > 0:
                _run(
                    runner,
                    ["xcrun", "simctl", "terminate", simulator_id, profile.bundle_identifier],
                    SIMCTL_TERMINATE_TIMEOUT,
                )
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
                    host_mechanism="simctl-gallery",
                    appearance_mechanism=None,
                    error_code=_command_error_code(appearance, "simctl-ui"),
                )
                continue
            appearance_mechanism = "simctl-ui-appearance"
            sleeper(CAPTURE_SETTLE_SECONDS)
            first_baseline, first_baseline_path, first_baseline_error = _take_screenshot(
                runner,
                simulator_id,
                artifact_directory,
                f".{requirement.requirement_id}.baseline.first.",
                "simctl-baseline-screenshot",
                "simulator-baseline-image-invalid",
            )
            if (
                first_baseline_error is not None
                or first_baseline is None
                or first_baseline_path is None
            ):
                results[requirement.requirement_id] = _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism=appearance_mechanism,
                    error_code=first_baseline_error,
                )
                continue
            try:
                sleeper(CAPTURE_SETTLE_SECONDS)
                route_baseline, route_baseline_path, route_baseline_error = _take_screenshot(
                    runner,
                    simulator_id,
                    artifact_directory,
                    f".{requirement.requirement_id}.baseline.second.",
                    "simctl-baseline-screenshot",
                    "simulator-baseline-image-invalid",
                )
                if (
                    route_baseline_error is not None
                    or route_baseline is None
                    or route_baseline_path is None
                ):
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism="simctl-gallery",
                        appearance_mechanism=appearance_mechanism,
                        error_code=route_baseline_error,
                    )
                    continue
                try:
                    if first_baseline.digest != route_baseline.digest:
                        results[requirement.requirement_id] = _result(
                            requirement,
                            status="unknown",
                            captured_at=now(),
                            host_mechanism="simctl-gallery",
                            appearance_mechanism=appearance_mechanism,
                            error_code="baseline-unstable",
                        )
                        continue
                finally:
                    route_baseline_path.unlink(missing_ok=True)
            finally:
                first_baseline_path.unlink(missing_ok=True)
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
            appearance_mechanism = "simctl-ui-appearance+gallery-route"
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
        if not artifacts_removed:
            cleanup_status = "artifact-cleanup-failed"
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
    surface_policy = load_surface_policy(surface_policy_path)
    matrix = load_shared_view_matrix(matrix_path, surface_policy)
    comparison = _load_json_object(surface_comparison_path, "surface comparison")
    planned_payload = plan_shared_view_evidence(comparison, matrix, surface_policy)
    plan = load_capture_requirements(requirements_path, planned_payload, matrix, surface_policy)
    expected_manifest = _expected_embedded_manifest(current_manifest_path)
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
    ownership_path.write_text(ownership_token)
    os.chmod(ownership_path, 0o600)
    cleanup_statuses = {profile_name: "not-started" for profile_name in active_profile_names}
    owns_run_directory = False
    run_published = False
    try:
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
            snapshot_profile = _snapshot_profile(profiles[profile_name], staging_directory)
            try:
                outcome = _capture_profile(
                    snapshot_profile,
                    requirements,
                    staging_directory,
                    capture_run_id,
                    active_runner,
                    sleeper,
                    now,
                )
            finally:
                shutil.rmtree(snapshot_profile.app_bundle, ignore_errors=True)
                if snapshot_profile.app_bundle.exists():
                    raise SharedViewCaptureError("capture app snapshot cleanup failed")
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
            _fsync_directory(manifest_directory)
        except OSError as error:
            raise SharedViewCaptureError("capture run publication failed") from error
        owns_run_directory = True
        _atomic_write_json(public_output, receipt, 0o644)
        run_published = True
    finally:
        if not run_published:
            shutil.rmtree(staging_directory, ignore_errors=True)
            if owns_run_directory:
                published_owner = run_directory / ownership_path.name
                try:
                    owns_published_path = published_owner.read_text() == ownership_token
                except OSError:
                    owns_published_path = False
                if owns_published_path:
                    shutil.rmtree(run_directory, ignore_errors=True)
    statuses = {capture["status"] for capture in captures}
    if statuses == {"captured"}:
        return EXIT_OK, receipt
    if "unknown" in statuses:
        return EXIT_UNKNOWN, receipt
    return EXIT_BLOCKED, receipt
