from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Protocol
from urllib.parse import urlencode
import uuid
import zlib

from context_panel_shared_view_references import (
    ReferenceImageError,
    decode_png,
    encode_png,
    fill_regions,
)

from context_panel_shared_view_matrix import (
    DEFAULT_MATRIX_PATH,
    DEFAULT_SURFACE_POLICY_PATH,
    SharedViewEvidenceError,
    canonical_json_hash,
    load_shared_view_matrix,
    load_surface_policy,
    shared_view_requirement_id,
)


REPO_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool = False


class Runner(Protocol):
    def run(
        self,
        args: list[str],
        *,
        timeout: int,
        environment: dict[str, str] | None = None,
    ) -> CommandResult: ...


class SubprocessRunner:
    def run(
        self,
        args: list[str],
        *,
        timeout: int,
        environment: dict[str, str] | None = None,
    ) -> CommandResult:
        try:
            completed = subprocess.run(
                args,
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=timeout,
            )
            return CommandResult(completed.returncode, completed.stdout, completed.stderr)
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout if isinstance(error.stdout, str) else ""
            stderr = error.stderr if isinstance(error.stderr, str) else ""
            return CommandResult(124, stdout, stderr, timed_out=True)
        except OSError as error:
            return CommandResult(127, "", str(error))


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso8601(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
CAPTURE_CONFIG_SCHEMA_VERSION = 2
CAPTURE_CONFIG_KIND = "context-panel-shared-view-capture-config"
EMBEDDED_MANIFEST_DIGEST_DOMAIN = "context-panel-shared-view-capture-embedded-manifest/v1"
APP_BUNDLE_IDENTIFIER = "com.shinycomputers.contextpanel"
WATCH_APP_BUNDLE_IDENTIFIER = "com.shinycomputers.contextpanel.watch"
# On a loaded hosted runner CoreSimulator stalls queries after a visionOS reset:
# a device listing passed 30 seconds (CI run 39180325140, normally under 6) and an
# app-container query took 65 seconds (CI run 39191727857, normally about 2).
SIMCTL_CATALOG_TIMEOUT = 120
MAX_SIMULATOR_DEVICE_COUNT = 256
SIMCTL_CREATE_TIMEOUT = 30
SIMCTL_BOOT_TIMEOUT = 60
SIMCTL_BOOTSTATUS_TIMEOUT = 300
SIMCTL_INSTALL_TIMEOUT = 120
SIMCTL_VISIONOS_INSTALL_TIMEOUT = 300
SIMCTL_CONTAINER_TIMEOUT = 300
SIMCTL_TERMINATE_TIMEOUT = 30
SIMCTL_UI_TIMEOUT = 30
SIMCTL_LAUNCH_TIMEOUT = 60
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
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SIMULATOR_UDID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
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


@dataclass(frozen=True)
class CaptureRequirement:
    requirement_id: str
    surface: str
    cell_id: str
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
    relaunch_needs_settle: bool = False


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
    "tvos": SimulatorCaptureProfile(
        surface_prefix="tvos.",
        bundle_identifier=APP_BUNDLE_IDENTIFIER,
        bundle_platform="AppleTVSimulator",
        device_family=3,
        runtime_platforms=("tvOS",),
        product_family="Apple TV",
        route_kind="launch",
        applies_simulator_appearance=False,
        relaunch_needs_settle=True,
    ),
}
SUPPORTED_PROFILES = tuple(SIMULATOR_CAPTURE_PROFILES)
# macOS has no simulator, and building the Mac app or widget on a host registers
# competing LaunchServices and PlugInKit bundles. macOS widget cells are rendered by
# a SwiftPM tool that the executor builds itself from the verified source root.
# Pixels per point, the same as the simulator cells' in-process renderer.
HOST_RENDERER_SCALE = "2"
COMPANION_UI_TEST_PROFILES = frozenset({"ios", "ipados", "visionos"})
DEFAULT_SIMULATOR_PINS_PATH = REPO_ROOT / "Config" / "ContextPanelSharedViewSimulators.json"
SIMULATOR_PINS_KIND = "context-panel-shared-view-simulators"
# These apps draw the cell in its host frame and write the PNG to their temporary
# directory (SharedViewFrame.renderedCellFileName); a screenshot would show the
# gallery screen around it.
APP_RENDERED_SURFACES = frozenset({"watchos.complication", "tvos.top-shelf"})
RENDERED_CELL_FILE_NAME = "context-panel-shared-view-cell.png"
# Apps format dates with their process's locale and time zone. Pin both, as the
# in-process renderers do (Tools/ContextPanelSharedViewRenderer and the UI test).
SIMULATOR_LAUNCH_LOCALE_ARGUMENTS = ("-AppleLocale", "en_US_POSIX", "-AppleLanguages", "(en-US)")
SIMULATOR_LAUNCH_ENVIRONMENT = {"SIMCTL_CHILD_TZ": "UTC"}


@dataclass(frozen=True)
class SimulatorPin:
    runtime_identifier: str
    device_type_identifier: str
    masked_regions: dict[str, tuple[tuple[int, int, int, int], ...]]


@dataclass(frozen=True)
class SimulatorPins:
    xcode: str
    profiles: dict[str, SimulatorPin]


def load_simulator_pins(path: Path = DEFAULT_SIMULATOR_PINS_PATH) -> SimulatorPins:
    """The Xcode, runtime and device every simulator capture and reference uses."""
    payload = _load_json_object(path, "shared-view simulator pins")
    if (
        set(payload) != {"schemaVersion", "kind", "xcode", "profiles"}
        or payload["schemaVersion"] != 1
        or payload["kind"] != SIMULATOR_PINS_KIND
        or not isinstance(payload["profiles"], dict)
        or set(payload["profiles"]) != set(SUPPORTED_PROFILES)
    ):
        raise SharedViewCaptureError("shared-view simulator pins are invalid")
    xcode = _require_string(payload["xcode"], "pinned Xcode")
    if not xcode.startswith("/Applications/") or not xcode.endswith(".app"):
        raise SharedViewCaptureError("pinned Xcode is invalid")
    profiles: dict[str, SimulatorPin] = {}
    for name, raw in payload["profiles"].items():
        if not isinstance(raw, dict) or not {"runtimeIdentifier", "deviceTypeIdentifier"} <= set(raw) or not set(
            raw
        ) <= {"runtimeIdentifier", "deviceTypeIdentifier", "maskedRegions"}:
            raise SharedViewCaptureError("shared-view simulator pin is invalid")
        runtime = _require_string(raw["runtimeIdentifier"], "pinned runtime")
        device_type = _require_string(raw["deviceTypeIdentifier"], "pinned device type")
        if not RUNTIME_IDENTIFIER_PATTERN.fullmatch(runtime) or not DEVICE_TYPE_IDENTIFIER_PATTERN.fullmatch(
            device_type
        ):
            raise SharedViewCaptureError("shared-view simulator pin is invalid")
        regions: dict[str, list[tuple[int, int, int, int]]] = {}
        raw_regions = raw.get("maskedRegions", [])
        if not isinstance(raw_regions, list):
            raise SharedViewCaptureError("shared-view masked regions are invalid")
        for region in raw_regions:
            keys = {"surface", "x", "y", "width", "height", "reason"}
            if (
                not isinstance(region, dict)
                or set(region) != keys
                or not str(region["surface"]).startswith(SIMULATOR_CAPTURE_PROFILES[name].surface_prefix)
                or any(type(region[key]) is not int or region[key] < 0 for key in ("x", "y", "width", "height"))
                or not region["width"]
                or not region["height"]
                or not isinstance(region["reason"], str)
                or not region["reason"]
            ):
                raise SharedViewCaptureError("shared-view masked region is invalid")
            regions.setdefault(region["surface"], []).append(
                (region["x"], region["y"], region["width"], region["height"])
            )
        profiles[name] = SimulatorPin(
            runtime,
            device_type,
            {surface: tuple(items) for surface, items in regions.items()},
        )
    return SimulatorPins(xcode, profiles)


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
    template = _require_string(value, label)
    replacements = {"__TESTROOT__": str(test_root)}
    if test_host is not None:
        replacements["__TESTHOST__"] = str(test_host)
    # Validate the template before inserting literal paths, and never rescan them.
    marker_pattern = re.compile("|".join(re.escape(marker) for marker in replacements))
    if "__" in marker_pattern.sub("", template):
        raise SharedViewCaptureError("capture visionOS UI test run is invalid")
    path = Path(marker_pattern.sub(lambda match: replacements[match.group()], template))
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
    if not isinstance(raw_profiles, dict) or not set(raw_profiles).issubset(
        set(SUPPORTED_PROFILES)
    ):
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


def _profile_for_surface(surface: str) -> str | None:
    for profile_name, profile in SIMULATOR_CAPTURE_PROFILES.items():
        if surface.startswith(profile.surface_prefix):
            return profile_name
    return None


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
        elif requirement.surface in {"tvos.app", "tvos.top-shelf"}:
            families = {"topShelf"} if requirement.surface == "tvos.top-shelf" else {"runway", "provider"}
            if requirement.family not in families or requirement.presentation == "not-applicable":
                raise SharedViewCaptureError("capture TV selector is invalid")
            selectors = [
                "--context-panel-validation-surface", requirement.surface,
                "--context-panel-validation-fixture", requirement.fixture_id,
                "--context-panel-validation-family", requirement.family,
                "--context-panel-validation-presentation", requirement.presentation,
            ]
        else:
            raise SharedViewCaptureError("capture launch surface is invalid")
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
                *SIMULATOR_LAUNCH_LOCALE_ARGUMENTS,
            ],
            "simctl-launch",
            None,
        )
    raise SharedViewCaptureError("capture simulator profile route is invalid")


def _run(
    runner: Runner,
    args: list[str],
    timeout: int,
    environment: dict[str, str] | None = None,
) -> CommandResult:
    return runner.run(
        args,
        timeout=timeout,
        environment=None if environment is None else {**os.environ, **environment},
    )


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


def _rendered_cell_path(
    runner: Runner,
    simulator_id: str,
    profile: CaptureProfile,
) -> tuple[Path | None, str | None]:
    """Where the app writes its framed cell, inside its simulator data container."""
    result = _run(
        runner,
        ["xcrun", "simctl", "get_app_container", simulator_id, profile.bundle_identifier, "data"],
        SIMCTL_CONTAINER_TIMEOUT,
    )
    if result.returncode != 0 or result.timed_out:
        return None, _command_error_code(result, "simctl-data-container")
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1 or not Path(lines[0]).is_absolute():
        return None, "simctl-data-container-invalid"
    try:
        container = Path(lines[0]).resolve(strict=True)
    except (OSError, RuntimeError):
        return None, "simctl-data-container-invalid"
    temporary = container / "tmp"
    # The app owns its container. Refuse a symlinked or missing tmp directory so
    # neither the removal before launch nor the read after it can leave the container.
    if (
        not container.is_dir()
        or not temporary.is_dir()
        or temporary.is_symlink()
        or temporary.resolve(strict=True).parent != container
    ):
        return None, "simctl-data-container-invalid"
    return temporary / RENDERED_CELL_FILE_NAME, None


def _take_stable_rendered_cell(
    rendered_path: Path,
    artifact_directory: Path,
    prefix: str,
    sleeper: Callable[[float], None],
) -> tuple[PNGSnapshot | None, Path | None, str | None]:
    """Wait for the app's framed cell and copy it once two reads agree."""
    previous: PNGSnapshot | None = None
    for _ in range(MAX_STABILITY_SAMPLE_COUNT):
        sleeper(CAPTURE_SETTLE_SECONDS)
        if not rendered_path.is_file() or rendered_path.is_symlink():
            continue
        try:
            current, copied = _copy_private_png(rendered_path, artifact_directory, prefix)
        except (OSError, SharedViewCaptureError):
            return None, None, "rendered-cell-invalid"
        if previous is not None and previous.pixel_digest == current.pixel_digest:
            return current, copied, None
        copied.unlink(missing_ok=True)
        previous = current
    return None, None, "rendered-cell-missing" if previous is None else "capture-unstable"


def _mask_capture(
    path: Path,
    regions: tuple[tuple[int, int, int, int], ...],
    artifact_directory: Path,
    prefix: str,
) -> tuple[PNGSnapshot, Path]:
    """A copy of the capture with each pinned region painted out."""
    try:
        image = decode_png(_read_bounded_file(path, "captured image", MAX_PNG_FILE_BYTES))
    except ReferenceImageError as error:
        raise SharedViewCaptureError("captured image is invalid") from error
    descriptor, name = tempfile.mkstemp(prefix=prefix, suffix=".png", dir=artifact_directory)
    destination = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encode_png(fill_regions(image, regions)))
            stream.flush()
            os.fchmod(stream.fileno(), 0o600)
            os.fsync(stream.fileno())
        snapshot = _png_snapshot(destination)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    return snapshot, destination


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
    masked_regions: dict[str, tuple[tuple[int, int, int, int], ...]] | None = None,
) -> ProfileCaptureOutcome:
    masked_regions = masked_regions or {}
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
                if capture_profile.relaunch_needs_settle:
                    # tvOS relaunches an app in the background when it is
                    # started immediately after termination.
                    sleeper(CAPTURE_SETTLE_SECONDS)
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
                appearance_mechanism = "xcuitest-render-route"
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
                baseline_regions = masked_regions.get(requirement.surface)
                if baseline_regions:
                    # Mask the baseline like the capture, so the painted-out region
                    # alone can never make a capture differ from its baseline.
                    try:
                        route_baseline, masked_baseline_path = _mask_capture(
                            route_baseline_path,
                            baseline_regions,
                            artifact_directory,
                            f".{requirement.requirement_id}.baseline-masked.",
                        )
                        masked_baseline_path.unlink(missing_ok=True)
                    except (OSError, SharedViewCaptureError):
                        route_baseline_path.unlink(missing_ok=True)
                        results[requirement.requirement_id] = _result(
                            requirement,
                            status="unknown",
                            captured_at=now(),
                            host_mechanism=host_mechanism,
                            appearance_mechanism=appearance_mechanism,
                            error_code="simulator-baseline-image-invalid",
                        )
                        continue
                route_baseline_path.unlink(missing_ok=True)
                rendered_path: Path | None = None
                if requirement.surface in APP_RENDERED_SURFACES:
                    rendered_path, container_error = _rendered_cell_path(
                        runner, simulator_id, profile
                    )
                    if rendered_path is not None:
                        try:
                            rendered_path.unlink(missing_ok=True)
                        except OSError:
                            container_error = "rendered-cell-not-removable"
                    if container_error is not None or rendered_path is None:
                        results[requirement.requirement_id] = _result(
                            requirement,
                            status="unknown",
                            captured_at=now(),
                            host_mechanism=host_mechanism,
                            appearance_mechanism=appearance_mechanism,
                            error_code=container_error,
                        )
                        continue
                route_command, route_error_base, route_appearance_mechanism = _capture_route(
                    profile,
                    simulator_id,
                    requirement,
                )
                routed = _run(
                    runner, route_command, SIMCTL_LAUNCH_TIMEOUT, SIMULATOR_LAUNCH_ENVIRONMENT
                )
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
                if rendered_path is not None:
                    stable_snapshot, stable_path, capture_error = _take_stable_rendered_cell(
                        rendered_path,
                        artifact_directory,
                        f".{requirement.requirement_id}.capture.",
                        sleeper,
                    )
                else:
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
                regions = masked_regions.get(requirement.surface)
                if capture_error is None and stable_path is not None and regions:
                    try:
                        stable_snapshot, masked_path = _mask_capture(
                            stable_path,
                            regions,
                            artifact_directory,
                            f".{requirement.requirement_id}.masked.",
                        )
                    except (OSError, SharedViewCaptureError):
                        stable_snapshot, masked_path = None, None
                        capture_error = "captured-image-invalid"
                    stable_path.unlink(missing_ok=True)
                    stable_path = masked_path
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


class _TimedRunner:
    """Logs each command's verb, duration and outcome to stderr for CI diagnosis.

    Only the command's first words are printed; paths, identifiers and output are not.
    """

    def __init__(self, runner: Runner) -> None:
        self.runner = runner

    def run(
        self,
        args: list[str],
        *,
        timeout: int,
        environment: dict[str, str] | None = None,
    ) -> CommandResult:
        started = time.monotonic()
        result = self.runner.run(args, timeout=timeout, environment=environment)
        words = 2 if Path(args[0]).name == "xcodebuild" else 3
        verb = " ".join(Path(args[0]).name if index == 0 else part for index, part in enumerate(args[:words]))
        outcome = "timed out" if result.timed_out else f"exit {result.returncode}"
        print(
            f"{verb}: {time.monotonic() - started:.1f}s of {timeout}s, {outcome}",
            file=sys.stderr,
            flush=True,
        )
        return result


def capture_reference_cells(
    config_path: Path,
    output_root: Path,
    *,
    runner: Runner | None = None,
    sleeper: Callable[[float], None] = time.sleep,
    now: Callable[[], datetime] = utc_now,
    matrix_path: Path = DEFAULT_MATRIX_PATH,
    surface_policy_path: Path = DEFAULT_SURFACE_POLICY_PATH,
    simulator_pins_path: Path = DEFAULT_SIMULATOR_PINS_PATH,
) -> dict[str, dict[str, object]]:
    """Capture every simulator cell of the matrix the way the release capture does.

    Each captured cell is written to ``<output_root>/<surface>/<cell>.png`` for
    comparison with its committed reference. A profile whose runtime or device is
    not the pinned one is blocked rather than captured on another simulator.
    Cells that fail in a profile that captured others get one retry in a fresh
    simulator. visionOS cells share their simulator like the other XCUITest
    cells; only the release capture erases it between cells.
    """
    surface_policy = load_surface_policy(surface_policy_path)
    matrix = load_shared_view_matrix(matrix_path, surface_policy)
    profiles = load_capture_config(config_path)
    pins = load_simulator_pins(simulator_pins_path)
    groups: dict[str, list[CaptureRequirement]] = {name: [] for name in SUPPORTED_PROFILES}
    for surface in matrix.surfaces:
        profile_name = _profile_for_surface(surface.id)
        if profile_name is None:
            continue  # macOS cells are drawn on the host.
        for cell in surface.cells:
            groups[profile_name].append(
                CaptureRequirement(
                    requirement_id=shared_view_requirement_id(surface.id, cell.id),
                    surface=surface.id,
                    cell_id=cell.id,
                    fixture_id=cell.fixture_id,
                    family=cell.family,
                    appearance=cell.appearance,
                    presentation=cell.presentation,
                    accessibility=cell.accessibility,
                )
            )
    active_runner = runner or _TimedRunner(SubprocessRunner())
    capture_run_id = uuid.uuid4().hex[:12]
    results: dict[str, dict[str, object]] = {}
    seen_digests: dict[str, str | None] = {}
    published: dict[str, Path] = {}
    output_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="shared-view-references-") as staging:
        staging_directory = Path(staging)
        for profile_name, requirements in groups.items():
            if not requirements:
                continue
            profile = profiles.get(profile_name)
            pin = pins.profiles[profile_name]
            if profile is None:
                results.update(_blocked_results(tuple(requirements), "profile-not-configured", now))
                continue
            if (profile.runtime_identifier, profile.device_type_identifier) != (
                pin.runtime_identifier,
                pin.device_type_identifier,
            ):
                results.update(
                    _blocked_results(
                        tuple(requirements),
                        "simctl-profile-not-pinned",
                        now,
                        host_mechanism="simctl-profile-validation",
                    )
                )
                continue
            digests_before = set(seen_digests)
            outcome = _capture_profile(
                profile,
                tuple(requirements),
                staging_directory,
                capture_run_id,
                active_runner,
                sleeper,
                now,
                seen_digests,
                results,
                published,
                masked_regions=pin.masked_regions,
            )
            results.update(outcome.results)
            # A profile that captured some cells works, so a cell that failed is
            # most likely a simulator flake: give it one more try in a fresh
            # simulator instead of failing the whole job.
            failed = tuple(
                requirement
                for requirement in requirements
                if results[requirement.requirement_id]["status"] != "captured"
            )
            if failed and len(failed) < len(requirements):
                # A digest this attempt left without an owner belongs to a failed
                # cell; keeping it would mark that cell's retry a duplicate.
                for digest in set(seen_digests) - digests_before:
                    if seen_digests[digest] is None:
                        del seen_digests[digest]
                retried = _capture_profile(
                    profile,
                    failed,
                    staging_directory,
                    f"{capture_run_id}-retry",
                    active_runner,
                    sleeper,
                    now,
                    seen_digests,
                    results,
                    published,
                    masked_regions=pin.masked_regions,
                    )
                results.update(retried.results)
        for requirement_id, artifact_path in published.items():
            result = results[requirement_id]
            if result["status"] != "captured":
                continue
            destination = output_root / str(result["surface"]) / f"{result['cellID']}.png"
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(artifact_path, destination)
    return results
