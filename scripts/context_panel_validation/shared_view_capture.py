from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
import time
from typing import Any, Callable
from urllib.parse import urlencode

from .models import CommandResult, EXIT_BLOCKED, EXIT_OK, EXIT_UNKNOWN, Runner, iso8601, utc_now
from .shared_view_evidence import (
    DEFAULT_MATRIX_PATH,
    DEFAULT_SURFACE_POLICY_PATH,
    PIXEL_DIFF_POLICY,
    SharedViewCell,
    SharedViewEvidenceError,
    SharedViewMatrix,
    SurfacePolicySurface,
    fixture_contract_id,
    load_shared_view_matrix,
    load_surface_policy,
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
SUPPORTED_PROFILES = ("ios", "ipados", "visionos")
PROFILE_SURFACE_PREFIXES = {
    "ios": "ios.",
    "ipados": "ipados.",
    "visionos": "visionos.",
}
SIMCTL_CREATE_TIMEOUT = 30
SIMCTL_BOOT_TIMEOUT = 60
SIMCTL_BOOTSTATUS_TIMEOUT = 120
SIMCTL_INSTALL_TIMEOUT = 120
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

    def public_dict(self) -> dict[str, str]:
        return {
            "profile": self.name,
            "appBundleIdentifier": self.bundle_identifier,
            "appExecutableSHA256": self.executable_sha256,
            "appVersion": self.version,
            "appBuild": self.build,
        }


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
    requirements: tuple[CaptureRequirement, ...]


def _load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text())
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
    if bundle_identifier != "com.shinycomputers.contextpanel":
        raise SharedViewCaptureError("capture app bundle identifier is invalid")
    executable_name = _require_string(info.get("CFBundleExecutable"), "capture app executable")
    version = _require_string(info.get("CFBundleShortVersionString"), "capture app version")
    build = _require_string(info.get("CFBundleVersion"), "capture app build")
    executable = path / executable_name
    if not executable.is_file() or executable.is_symlink():
        raise SharedViewCaptureError("capture app executable is invalid")
    return (
        bundle_identifier,
        hashlib.sha256(executable.read_bytes()).hexdigest(),
        version,
        build,
    )


def load_capture_config(path: Path) -> dict[str, CaptureProfile]:
    payload = _load_json_object(path, "shared-view capture config")
    if set(payload) != {"schemaVersion", "kind", "profiles"}:
        raise SharedViewCaptureError("shared-view capture config root keys are invalid")
    if payload["schemaVersion"] != CAPTURE_CONFIG_SCHEMA_VERSION or payload["kind"] != CAPTURE_CONFIG_KIND:
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
    matrix: SharedViewMatrix,
    surface_policy: tuple[SurfacePolicySurface, ...],
) -> CapturePlan:
    payload = _load_json_object(path, "shared-view capture requirements")
    if set(payload) != {"schemaVersion", "kind", "currentManifestID", "requirements"}:
        raise SharedViewCaptureError("shared-view capture requirements root keys are invalid")
    if payload["schemaVersion"] != REQUIREMENTS_SCHEMA_VERSION or payload["kind"] != REQUIREMENTS_KIND:
        raise SharedViewCaptureError("shared-view capture requirements identity is invalid")
    manifest_id = _require_sha256(payload["currentManifestID"], "shared-view capture manifest identifier")
    raw_requirements = payload["requirements"]
    if not isinstance(raw_requirements, list) or len(raw_requirements) > matrix.max_cell_count:
        raise SharedViewCaptureError("shared-view capture requirements are invalid")
    expected = _matrix_cells(matrix, surface_policy)
    expected_order = {requirement_id: position for position, requirement_id in enumerate(expected)}
    requirements: list[CaptureRequirement] = []
    observed_ids: set[str] = set()
    previous_position = -1
    expected_keys = {
        "id",
        "evidenceClass",
        "surface",
        "fixtureContractID",
        "presentation",
        "appearance",
        "accessibility",
        "hostOS",
        "presentationFamily",
        "placementHost",
    }
    for raw_requirement in raw_requirements:
        if not isinstance(raw_requirement, dict) or set(raw_requirement) != expected_keys:
            raise SharedViewCaptureError("shared-view capture requirement keys are invalid")
        requirement_id = _require_string(raw_requirement["id"], "shared-view capture requirement identifier")
        if (
            raw_requirement["evidenceClass"] != "shared-view"
            or raw_requirement["hostOS"] is not None
            or raw_requirement["presentationFamily"] is not None
            or raw_requirement["placementHost"] is not None
            or requirement_id in observed_ids
            or requirement_id not in expected
        ):
            raise SharedViewCaptureError("shared-view capture requirement is invalid")
        position = expected_order[requirement_id]
        if position <= previous_position:
            raise SharedViewCaptureError("shared-view capture requirements are not canonical")
        previous_position = position
        policy_surface, cell = expected[requirement_id]
        if (
            raw_requirement["surface"] != policy_surface.id
            or raw_requirement["fixtureContractID"] != fixture_contract_id(matrix, policy_surface, cell)
            or raw_requirement["presentation"] != cell.presentation
            or raw_requirement["appearance"] != cell.appearance
            or raw_requirement["accessibility"] != cell.accessibility
        ):
            raise SharedViewCaptureError("shared-view capture requirement contract is invalid")
        observed_ids.add(requirement_id)
        requirements.append(
            CaptureRequirement(
                requirement_id=requirement_id,
                surface=policy_surface.id,
                cell_id=cell.id,
                fixture_contract_id=raw_requirement["fixtureContractID"],
                fixture_id=cell.fixture_id,
                family=cell.family,
                appearance=cell.appearance,
                presentation=cell.presentation,
                accessibility=cell.accessibility,
            )
        )
    return CapturePlan(manifest_id, tuple(requirements))


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
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def _png_dimensions(path: Path) -> tuple[int, int]:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise SharedViewCaptureError("captured image is invalid") from error
    if (
        path.is_symlink()
        or len(data) < 24
        or data[:8] != PNG_SIGNATURE
        or int.from_bytes(data[8:12], "big") != 13
        or data[12:16] != b"IHDR"
    ):
        raise SharedViewCaptureError("captured image is invalid")
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    if width <= 0 or height <= 0:
        raise SharedViewCaptureError("captured image is invalid")
    return width, height


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


def _result(
    requirement: CaptureRequirement,
    *,
    status: str,
    captured_at: datetime,
    host_mechanism: str,
    appearance_mechanism: str | None,
    error_code: str | None = None,
    artifact_path: Path | None = None,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "requirementID": requirement.requirement_id,
        "surface": requirement.surface,
        "cellID": requirement.cell_id,
        "fixtureContractID": requirement.fixture_contract_id,
        "status": status,
        "artifactDigest": None,
        "artifactBytes": None,
        "pixelWidth": None,
        "pixelHeight": None,
        "hostMechanism": host_mechanism,
        "appearanceMechanism": appearance_mechanism,
        "capturedAt": iso8601(captured_at),
        "errorCode": error_code,
    }
    if artifact_path is not None:
        width, height = _png_dimensions(artifact_path)
        content = artifact_path.read_bytes()
        payload.update(
            {
                "artifactDigest": hashlib.sha256(content).hexdigest(),
                "artifactBytes": len(content),
                "pixelWidth": width,
                "pixelHeight": height,
            }
        )
    return payload


def _created_simulator_id(result: CommandResult) -> str | None:
    candidate = result.stdout.strip()
    return candidate if SIMULATOR_UDID_PATTERN.fullmatch(candidate) else None


def _capture_profile(
    profile: CaptureProfile,
    requirements: tuple[CaptureRequirement, ...],
    artifact_directory: Path,
    runner: Runner,
    sleeper: Callable[[float], None],
    now: Callable[[], datetime],
) -> dict[str, dict[str, object]]:
    results: dict[str, dict[str, object]] = {}
    simulator_id: str | None = None
    try:
        created = _run(
            runner,
            [
                "xcrun",
                "simctl",
                "create",
                f"ContextPanelSharedView-{profile.name}",
                profile.device_type_identifier,
                profile.runtime_identifier,
            ],
            SIMCTL_CREATE_TIMEOUT,
        )
        if created.returncode != 0:
            return {
                requirement.requirement_id: _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism="simctl-ui-appearance",
                    error_code="simctl-create-failed",
                )
                for requirement in requirements
            }
        simulator_id = _created_simulator_id(created)
        if simulator_id is None:
            return {
                requirement.requirement_id: _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism="simctl-ui-appearance",
                    error_code="simctl-create-invalid-udid",
                )
                for requirement in requirements
            }
        prerequisites = (
            (["xcrun", "simctl", "boot", simulator_id], SIMCTL_BOOT_TIMEOUT, "simctl-boot-failed"),
            (
                ["xcrun", "simctl", "bootstatus", simulator_id, "-b"],
                SIMCTL_BOOTSTATUS_TIMEOUT,
                "simctl-bootstatus-failed",
            ),
            (
                ["xcrun", "simctl", "install", simulator_id, str(profile.app_bundle)],
                SIMCTL_INSTALL_TIMEOUT,
                "simctl-install-failed",
            ),
        )
        for command, timeout, error_code in prerequisites:
            if _run(runner, command, timeout).returncode != 0:
                return {
                    requirement.requirement_id: _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism="simctl-gallery",
                        appearance_mechanism="simctl-ui-appearance",
                        error_code=error_code,
                    )
                    for requirement in requirements
                }
        for requirement in requirements:
            if _run(
                runner,
                ["xcrun", "simctl", "ui", simulator_id, "appearance", requirement.appearance],
                SIMCTL_UI_TIMEOUT,
            ).returncode != 0:
                results[requirement.requirement_id] = _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism="simctl-ui-appearance",
                    error_code="simctl-ui-failed",
                )
                continue
            if _run(
                runner,
                ["xcrun", "simctl", "openurl", simulator_id, _capture_url(requirement)],
                SIMCTL_OPENURL_TIMEOUT,
            ).returncode != 0:
                results[requirement.requirement_id] = _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism="simctl-ui-appearance",
                    error_code="simctl-openurl-failed",
                )
                continue
            sleeper(CAPTURE_SETTLE_SECONDS)
            final_path = artifact_directory / f"{requirement.requirement_id}.png"
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{requirement.requirement_id}.", suffix=".png", dir=artifact_directory
            )
            os.close(descriptor)
            temporary_path = Path(temporary_name)
            try:
                screenshot = _run(
                    runner,
                    ["xcrun", "simctl", "io", simulator_id, "screenshot", str(temporary_path)],
                    SIMCTL_SCREENSHOT_TIMEOUT,
                )
                if screenshot.returncode != 0:
                    results[requirement.requirement_id] = _result(
                        requirement,
                        status="unknown",
                        captured_at=now(),
                        host_mechanism="simctl-gallery",
                        appearance_mechanism="simctl-ui-appearance",
                        error_code="simctl-screenshot-failed",
                    )
                    continue
                _png_dimensions(temporary_path)
                os.chmod(temporary_path, 0o600)
                os.replace(temporary_path, final_path)
                os.chmod(final_path, 0o600)
                results[requirement.requirement_id] = _result(
                    requirement,
                    status="captured",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism="simctl-ui-appearance",
                    artifact_path=final_path,
                )
            except SharedViewCaptureError:
                results[requirement.requirement_id] = _result(
                    requirement,
                    status="unknown",
                    captured_at=now(),
                    host_mechanism="simctl-gallery",
                    appearance_mechanism="simctl-ui-appearance",
                    error_code="captured-image-invalid",
                )
            finally:
                if temporary_path.exists():
                    temporary_path.unlink()
    finally:
        if simulator_id is not None:
            _run(runner, ["xcrun", "simctl", "shutdown", simulator_id], SIMCTL_CLEANUP_TIMEOUT)
            _run(runner, ["xcrun", "simctl", "delete", simulator_id], SIMCTL_CLEANUP_TIMEOUT)
    return results


def execute_shared_view_capture(
    requirements_path: Path,
    config_path: Path,
    artifact_root: Path,
    output_path: Path,
    *,
    runner: Runner | None = None,
    sleeper: Callable[[float], None] = time.sleep,
    now: Callable[[], datetime] = utc_now,
    matrix_path: Path = DEFAULT_MATRIX_PATH,
    surface_policy_path: Path = DEFAULT_SURFACE_POLICY_PATH,
) -> tuple[int, dict[str, object]]:
    surface_policy = load_surface_policy(surface_policy_path)
    matrix = load_shared_view_matrix(matrix_path, surface_policy)
    plan = load_capture_requirements(requirements_path, matrix, surface_policy)
    profiles = load_capture_config(config_path)
    private_root = _validate_artifact_root(artifact_root)
    public_output = _validate_output_path(output_path)
    _prepare_private_directory(private_root)
    manifest_directory = private_root / plan.current_manifest_id
    _prepare_private_directory(manifest_directory)
    capture_results: dict[str, dict[str, object]] = {}
    configured_groups: dict[str, list[CaptureRequirement]] = {profile: [] for profile in SUPPORTED_PROFILES}
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
    for profile_name in SUPPORTED_PROFILES:
        requirements = tuple(configured_groups[profile_name])
        if not requirements:
            continue
        capture_results.update(
            _capture_profile(
                profiles[profile_name],
                requirements,
                manifest_directory,
                runner or SubprocessRunner(),
                sleeper,
                now,
            )
        )
    captures = [capture_results[requirement.requirement_id] for requirement in plan.requirements]
    receipt = {
        "schemaVersion": CAPTURE_RECEIPT_SCHEMA_VERSION,
        "kind": CAPTURE_RECEIPT_KIND,
        "currentManifestID": plan.current_manifest_id,
        "matrixDigest": matrix.digest(),
        "pixelDiffPolicy": PIXEL_DIFF_POLICY,
        "profiles": [
            profiles[profile_name].public_dict()
            for profile_name in SUPPORTED_PROFILES
            if configured_groups[profile_name]
        ],
        "captures": captures,
    }
    _atomic_write_json(manifest_directory / "index.json", receipt, 0o600)
    _atomic_write_json(public_output, receipt, 0o644)
    statuses = {capture["status"] for capture in captures}
    if statuses == {"captured"} or not statuses:
        return EXIT_OK, receipt
    if "unknown" in statuses:
        return EXIT_UNKNOWN, receipt
    return EXIT_BLOCKED, receipt
