from dataclasses import replace
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
from types import SimpleNamespace
from typing import Any
import unittest
from unittest import mock
import weakref
import uuid
import zlib


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import context_panel_shared_view_capture as capture_module  # noqa: E402
from context_panel_shared_view_capture import (  # noqa: E402
    CAPTURE_CONFIG_KIND,
    CAPTURE_CONFIG_SCHEMA_VERSION,
    CommandResult,
    Runner,
    SharedViewCaptureError,
    _png_snapshot,
    _verify_created_simulator,
    capture_reference_cells,
    load_capture_config,
)
from context_panel_shared_view_matrix import (  # noqa: E402
    load_shared_view_matrix,
    load_surface_policy,
    shared_view_requirement_id,
)
from context_panel_shared_view_references import decode_png  # noqa: E402
from context_panel_surface_manifest.core import canonical_json as manifest_canonical_json  # noqa: E402
from context_panel_surface_manifest.core import hash_parts as manifest_hash_parts  # noqa: E402

EXIT_OK, EXIT_BLOCKED, EXIT_UNKNOWN = 0, 20, 30

SIMULATOR_ID = "00000000-0000-0000-0000-000000000001"
SECOND_SIMULATOR_ID = "00000000-0000-0000-0000-000000000002"
FIXED_NOW = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
RUNTIME_IDENTIFIERS = {
    "ios": "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
    "ipados": "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
    "visionos": "com.apple.CoreSimulator.SimRuntime.xrOS-26-0",
    "watchos": "com.apple.CoreSimulator.SimRuntime.watchOS-26-0",
    "tvos": "com.apple.CoreSimulator.SimRuntime.tvOS-26-0",
}
DEVICE_TYPE_IDENTIFIERS = {
    "ios": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
    "ipados": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5",
    "visionos": "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro",
    "watchos": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm",
    "tvos": "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K",
}
PROFILE_BUNDLE_IDENTIFIERS = {
    "ios": "com.shinycomputers.contextpanel",
    "ipados": "com.shinycomputers.contextpanel",
    "visionos": "com.shinycomputers.contextpanel",
    "watchos": "com.shinycomputers.contextpanel.watch",
    "tvos": "com.shinycomputers.contextpanel",
}
PROFILE_BUNDLE_PLATFORMS = {
    "ios": "iPhoneSimulator",
    "ipados": "iPhoneSimulator",
    "visionos": "XRSimulator",
    "watchos": "WatchSimulator",
    "tvos": "AppleTVSimulator",
}
PROFILE_DEVICE_FAMILIES = {"ios": 1, "ipados": 2, "visionos": 7, "watchos": 4, "tvos": 3}


def png_chunk(chunk_type: bytes, content: bytes) -> bytes:
    crc = zlib.crc32(content, zlib.crc32(chunk_type)) & 0xFFFFFFFF
    return len(content).to_bytes(4, "big") + chunk_type + content + crc.to_bytes(4, "big")


def png_document(*chunks: tuple[bytes, bytes]) -> bytes:
    return b"\x89PNG\r\n\x1a\n" + b"".join(png_chunk(*chunk) for chunk in chunks)


def png_ihdr(
    width: int = 320,
    height: int = 180,
    bit_depth: int = 8,
    color_type: int = 6,
    methods: bytes = b"\x00\x00\x00",
) -> bytes:
    return width.to_bytes(4, "big") + height.to_bytes(4, "big") + bytes((bit_depth, color_type)) + methods


def png_bytes(
    width: int = 320,
    height: int = 180,
    color: tuple[int, int, int, int] = (0x22, 0x66, 0xAA, 0xFF),
    bit_depth: int = 8,
) -> bytes:
    if bit_depth == 8:
        pixel = bytes(color)
    elif bit_depth == 16:
        pixel = b"".join((component * 257).to_bytes(2, "big") for component in color)
    else:
        raise ValueError("unsupported test PNG bit depth")
    row = b"\x00" + pixel * width
    return png_document(
        (b"IHDR", png_ihdr(width, height, bit_depth=bit_depth)),
        (b"IDAT", zlib.compress(row * height)),
        (b"IEND", b""),
    )


def invalid_idat_png_bytes(width: int = 320, height: int = 180) -> bytes:
    return png_document(
        (b"IHDR", png_ihdr(width, height)),
        (b"IDAT", b"not-zlib-data"),
        (b"IEND", b""),
    )


def simulator_catalog() -> dict[str, Any]:
    return {
        "runtimes": [
            {
                "identifier": RUNTIME_IDENTIFIERS["ios"],
                "name": "iOS 26.0",
                "platform": "iOS",
                "isAvailable": True,
                "bundlePath": "/private/catalog/runtime",
            },
            {
                "identifier": RUNTIME_IDENTIFIERS["visionos"],
                "name": "visionOS 26.0",
                "platform": "xrOS",
                "isAvailable": True,
                "bundlePath": "/private/catalog/vision-runtime",
            },
            {
                "identifier": RUNTIME_IDENTIFIERS["watchos"],
                "name": "watchOS 26.0",
                "platform": "watchOS",
                "isAvailable": True,
                "bundlePath": "/private/catalog/watch-runtime",
            },
            {
                "identifier": RUNTIME_IDENTIFIERS["tvos"],
                "name": "tvOS 26.0",
                "platform": "tvOS",
                "isAvailable": True,
                "bundlePath": "/private/catalog/tv-runtime",
            },
        ],
        "devicetypes": [
            {
                "identifier": DEVICE_TYPE_IDENTIFIERS["ios"],
                "name": "iPhone 17",
                "productFamily": "iPhone",
                "bundlePath": "/private/catalog/iphone",
            },
            {
                "identifier": DEVICE_TYPE_IDENTIFIERS["ipados"],
                "name": "iPad Pro 13-inch (M5)",
                "productFamily": "iPad",
                "bundlePath": "/private/catalog/ipad",
            },
            {
                "identifier": DEVICE_TYPE_IDENTIFIERS["visionos"],
                "name": "Apple Vision Pro",
                "productFamily": "Apple Vision",
                "bundlePath": "/private/catalog/vision",
            },
            {
                "identifier": DEVICE_TYPE_IDENTIFIERS["watchos"],
                "name": "Apple Watch Series 11 (46mm)",
                "productFamily": "Apple Watch",
                "bundlePath": "/private/catalog/watch",
            },
            {
                "identifier": DEVICE_TYPE_IDENTIFIERS["tvos"],
                "name": "Apple TV 4K (3rd generation)",
                "productFamily": "Apple TV",
                "bundlePath": "/private/catalog/tv",
            },
        ],
        "devices": {"private": [{"udid": SECOND_SIMULATOR_ID}]},
    }


class FakeRunner:
    def __init__(
        self,
        *,
        catalog: dict[str, Any] | None = None,
        fail_at: str | None = None,
        timeout_at: str | None = None,
        fail_at_call: tuple[str, int] | None = None,
        timeout_at_call: tuple[str, int] | None = None,
        create_result: CommandResult | None = None,
        corrupt_png: str | None = None,
        unstable: bool = False,
        baseline_unstable: bool = False,
        settles_after_first: bool = False,
        settles_after_samples: int = 0,
        baseline_equal: bool = False,
        duplicate_routes: bool = False,
        cross_profile_duplicates: bool = False,
        created_device_mismatch: bool = False,
        created_device_available: bool = True,
        container_path: Path | None = None,
        container_output: str | None = None,
        created_on_failed_create: bool = False,
        device_list_failure: CommandResult | None = None,
        device_list_failure_after: int = 1,
        persist_after_delete: bool = False,
        sticky_route_until_erase: bool = False,
        xcuitest_manifest_error: str | None = None,
        png_bit_depth: int = 8,
        rendered_cell: str = "written",
    ) -> None:
        self.calls: list[tuple[list[str], int]] = []
        # "written", or "missing" when the app never writes its framed cell.
        self.rendered_cell = rendered_cell
        self.data_container = Path(tempfile.mkdtemp()).resolve()
        (self.data_container / "tmp").mkdir()
        weakref.finalize(self, shutil.rmtree, self.data_container, True)
        self.launch_environments: list[dict[str, str] | None] = []
        self.catalog = catalog or simulator_catalog()
        self.fail_at = fail_at
        self.timeout_at = timeout_at
        self.fail_at_call = fail_at_call
        self.timeout_at_call = timeout_at_call
        self.create_result = create_result
        self.corrupt_png = corrupt_png
        self.unstable = unstable
        self.baseline_unstable = baseline_unstable
        self.settles_after_first = settles_after_first
        self.settles_after_samples = settles_after_samples
        self.baseline_equal = baseline_equal
        self.duplicate_routes = duplicate_routes
        self.cross_profile_duplicates = cross_profile_duplicates
        self.created_device_mismatch = created_device_mismatch
        self.created_device_available = created_device_available
        self.container_path = container_path
        self.container_output = container_output
        self.created_on_failed_create = created_on_failed_create
        self.device_list_failure = device_list_failure
        self.device_list_failure_after = device_list_failure_after
        self.persist_after_delete = persist_after_delete
        self.sticky_route_until_erase = sticky_route_until_erase
        self.xcuitest_manifest_error = xcuitest_manifest_error
        self.png_bit_depth = png_bit_depth
        self.device_list_calls = 0
        self.verb_call_counts: dict[str, int] = {}
        self.active_route: dict[str, str | None] = {}
        self.route_screenshot_counts: dict[str, int] = {}
        self.baseline_screenshot_count = 0
        self.screenshot_destinations_absent: list[bool] = []
        self.xcuitest_environments: list[dict[str, str]] = []
        self.created_simulator_id: str | None = None
        self.created_simulator_name: str | None = None
        self.created_device_type: str | None = None
        self.created_runtime: str | None = None
        self.installed_app_bundle: str | None = None
        self.private_stderr = f"private /tmp/capture-secret {SIMULATOR_ID}"

    def run(
        self, args: list[str], *, timeout: int, environment: dict[str, str] | None = None
    ) -> CommandResult:
        if args[:3] == ["xcrun", "simctl", "launch"]:
            self.launch_environments.append(environment)
        self.calls.append((args, timeout))
        if args and args[0] == "xcodebuild":
            verb = "xcodebuild"
        elif args[:3] == ["xcrun", "xcresulttool", "export"]:
            verb = "xcresulttool"
        else:
            verb = args[2] if len(args) > 2 else ""
        self.verb_call_counts[verb] = self.verb_call_counts.get(verb, 0) + 1
        verb_call = (verb, self.verb_call_counts[verb])
        if self.timeout_at_call == verb_call:
            return CommandResult(124, "", self.private_stderr, timed_out=True)
        if self.fail_at_call == verb_call:
            return CommandResult(1, "", self.private_stderr)
        if self.timeout_at == verb:
            return CommandResult(124, "", self.private_stderr, timed_out=True)
        if self.fail_at == verb:
            return CommandResult(1, "", self.private_stderr)
        if args and args[0] == "xcodebuild":
            xctestrun_path = Path(args[args.index("-xctestrun") + 1])
            with xctestrun_path.open("rb") as stream:
                payload = plistlib.load(stream)
            environment = payload[capture_module.VISIONOS_UI_TEST_TARGET][
                "EnvironmentVariables"
            ]
            self.xcuitest_environments.append(dict(environment))
            simulator_id = args[args.index("-destination") + 1].removeprefix("id=")
            self.active_route[simulator_id] = environment[
                capture_module.VISIONOS_UI_TEST_ENVIRONMENT["url"]
            ]
            Path(args[args.index("-resultBundlePath") + 1]).mkdir()
            return CommandResult(0, "", "")
        if args[:3] == ["xcrun", "xcresulttool", "export"]:
            output_directory = Path(args[args.index("--output-path") + 1])
            output_directory.mkdir()
            route = self.active_route.get(self.created_simulator_id or SIMULATOR_ID)
            attachments = []
            for prefix in ("baseline", "routed"):
                sample_count = (
                    capture_module.MAX_STABILITY_SAMPLE_COUNT
                    if self.unstable
                    or self.baseline_unstable
                    or self.settles_after_first
                    or self.settles_after_samples
                    else 2
                )
                for sample_index in range(1, sample_count + 1):
                    image = self._image_for(None if prefix == "baseline" else route)
                    if prefix == "baseline" and self.corrupt_png == "baseline":
                        image = invalid_idat_png_bytes()
                    elif prefix == "routed" and self.corrupt_png == "crc":
                        corrupted = bytearray(image)
                        corrupted[-1] ^= 0xFF
                        image = bytes(corrupted)
                    elif prefix == "routed" and self.corrupt_png == "truncated":
                        image = image[:-5]
                    elif prefix == "routed" and self.corrupt_png == "idat":
                        image = invalid_idat_png_bytes()
                    elif prefix == "routed" and self.corrupt_png == "placeholder":
                        image = png_bytes(width=1, height=1)
                    exported_name = f"{str(uuid.uuid4()).upper()}.png"
                    (output_directory / exported_name).write_bytes(image)
                    attachments.append(
                        {
                            "exportedFileName": exported_name,
                            "suggestedHumanReadableName": (
                                f"{prefix}-{sample_index}_0_{str(uuid.uuid4()).upper()}.png"
                            ),
                            "isAssociatedWithFailure": (
                                self.xcuitest_manifest_error == "failed-attachment"
                            ),
                        }
                    )
            test_identifier = (
                "wrong/test()"
                if self.xcuitest_manifest_error == "wrong-test"
                else (
                    f"{capture_module.VISIONOS_UI_TEST_TARGET}/"
                    f"{capture_module.VISIONOS_UI_TEST_METHOD}()"
                )
            )
            if self.xcuitest_manifest_error == "missing-sample":
                attachments.pop()
            (output_directory / "manifest.json").write_text(
                json.dumps(
                    [
                        {
                            "testIdentifier": test_identifier,
                            "testIdentifierURL": "test://context-panel/shared-view",
                            "attachments": attachments,
                        }
                    ]
                )
            )
            return CommandResult(0, "", "")
        if args[:5] == ["xcrun", "simctl", "list", "-j", "devices"]:
            self.device_list_calls += 1
            if (
                self.device_list_failure is not None
                and self.device_list_calls >= self.device_list_failure_after
            ):
                return self.device_list_failure
            device = {
                "udid": SECOND_SIMULATOR_ID if self.created_device_mismatch else self.created_simulator_id,
                "name": self.created_simulator_name,
                "deviceTypeIdentifier": self.created_device_type,
                "isAvailable": self.created_device_available,
            }
            return CommandResult(
                0,
                json.dumps({"devices": {self.created_runtime: [device]}}),
                "",
            )
        if args == ["xcrun", "simctl", "list", "-j"]:
            return CommandResult(0, json.dumps(self.catalog), "")
        if args[:3] == ["xcrun", "simctl", "create"]:
            if self.create_result is not None:
                valid_ids = [
                    line.strip()
                    for line in self.create_result.stdout.splitlines()
                    if line.strip() in {SIMULATOR_ID, SECOND_SIMULATOR_ID}
                ]
                self.created_simulator_id = (
                    SIMULATOR_ID
                    if self.created_on_failed_create
                    else valid_ids[0] if len(valid_ids) == 1 else None
                )
                self.created_simulator_name = args[3] if self.created_simulator_id else None
                self.created_device_type = args[4]
                self.created_runtime = args[5]
                return self.create_result
            self.active_route[SIMULATOR_ID] = None
            self.created_simulator_id = SIMULATOR_ID
            self.created_simulator_name = args[3]
            self.created_device_type = args[4]
            self.created_runtime = args[5]
            return CommandResult(0, SIMULATOR_ID + "\n", "")
        if args[:3] == ["xcrun", "simctl", "install"]:
            self.installed_app_bundle = args[-1]
        if args[:3] == ["xcrun", "simctl", "get_app_container"] and args[-1] == "data":
            return CommandResult(0, f"{self.data_container}\n", "")
        if args[:3] == ["xcrun", "simctl", "get_app_container"]:
            output = self.container_output or str(self.container_path or self.installed_app_bundle)
            return CommandResult(0, f"{output}\n", "")
        if args[:3] == ["xcrun", "simctl", "terminate"]:
            self.active_route[args[3]] = None
        if args[:3] == ["xcrun", "simctl", "erase"]:
            self.active_route[args[3]] = None
            self.installed_app_bundle = None
        if args[:3] == ["xcrun", "simctl", "delete"] and not self.persist_after_delete:
            self.created_simulator_id = None
            self.created_simulator_name = None
        elif args[:3] == ["xcrun", "simctl", "delete"]:
            self.created_simulator_name = "renamed-after-delete"
        if args[:3] == ["xcrun", "simctl", "openurl"]:
            if not self.sticky_route_until_erase or self.active_route.get(args[3]) is None:
                self.active_route[args[3]] = args[-1]
        if args[:3] == ["xcrun", "simctl", "launch"]:
            simulator_id = args[4]
            route_arguments = args[6:]
            if route_arguments:
                self.active_route[simulator_id] = "&".join(route_arguments)
                surface = route_arguments[route_arguments.index("--context-panel-validation-surface") + 1]
                if surface in capture_module.APP_RENDERED_SURFACES and self.rendered_cell != "missing":
                    self._write_rendered_cell(self.active_route[simulator_id])
            elif not self.sticky_route_until_erase:
                self.active_route[simulator_id] = None
        if args[:4] == ["xcrun", "simctl", "io", args[3] if len(args) > 3 else ""]:
            route = self.active_route.get(args[3])
            image = self._image_for(route)
            if route is None and self.corrupt_png == "baseline":
                image = invalid_idat_png_bytes()
            elif route is not None and self.corrupt_png == "crc":
                corrupted = bytearray(image)
                corrupted[-1] ^= 0xFF
                image = bytes(corrupted)
            elif route is not None and self.corrupt_png == "truncated":
                image = image[:-5]
            elif route is not None and self.corrupt_png == "idat":
                image = invalid_idat_png_bytes()
            self.screenshot_destinations_absent.append(not Path(args[-1]).exists())
            Path(args[-1]).write_bytes(image)
        return CommandResult(0, "", "")

    def _write_rendered_cell(self, route: str) -> None:
        cell = self.data_container / "tmp" / capture_module.RENDERED_CELL_FILE_NAME
        cell.write_bytes(self._image_for("rendered:" + route))

    def _image_for(self, route: str | None) -> bytes:
        baseline_color = (0x11, 0x22, 0x33, 0xFF)
        if route is None:
            count = self.baseline_screenshot_count
            self.baseline_screenshot_count += 1
            if self.baseline_unstable and count % 2 == 1:
                baseline_color = (0x12, 0x22, 0x33, 0xFF)
            elif count < self.settles_after_samples:
                baseline_color = ((0x12 + count) % 256, 0x22, 0x33, 0xFF)
            elif self.settles_after_first and count == 0:
                baseline_color = (0x12, 0x22, 0x33, 0xFF)
            return png_bytes(color=baseline_color, bit_depth=self.png_bit_depth)
        if self.baseline_equal:
            return png_bytes(color=baseline_color, bit_depth=self.png_bit_depth)
        if self.cross_profile_duplicates:
            color = (
                (0x44, 0x55, 0x66, 0xFF)
                if "appearance=light" in route
                else (0x77, 0x88, 0x99, 0xFF)
            )
        elif self.duplicate_routes:
            color = (0x44, 0x55, 0x66, 0xFF)
        else:
            route_identity = route + f"|{self.created_device_type}"
            digest = hashlib.sha256(route_identity.encode()).digest()
            color = (digest[0], digest[1], digest[2], 0xFF)
        count = self.route_screenshot_counts.get(route, 0)
        self.route_screenshot_counts[route] = count + 1
        if self.unstable and count % 2 == 1:
            color = ((color[0] + 1) % 256, color[1], color[2], color[3])
        elif count < self.settles_after_samples:
            color = ((color[0] + count + 1) % 256, color[1], color[2], color[3])
        elif self.settles_after_first and count == 0:
            color = ((color[0] + 1) % 256, color[1], color[2], color[3])
        return png_bytes(color=color, bit_depth=self.png_bit_depth)




class SharedViewCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.directory.name)
        self.companion_test_root = self.root / "companion-test-products"
        self.companion_products = self.companion_test_root / "Release-companionsimulator"
        self.app = self.companion_products / "Context Panel.app"
        self.app.mkdir(parents=True)
        self.watch_app = self.root / "Context Panel Watch.app"
        self.watch_app.mkdir()
        self.tv_app = self.root / "Context Panel TV.app"
        self.tv_app.mkdir()
        self.current_manifest_path = self.root / "current-manifest.json"
        (self.app / "ContextPanel").write_bytes(b"signed companion executable")
        (self.watch_app / "ContextPanelWatch").write_bytes(b"signed watch executable")
        (self.tv_app / "ContextPanelTV").write_bytes(
            b"signed tv executable --context-panel-validation-presentation"
        )
        self.write_info_plist("ContextPanel", app_bundle=self.app)
        self.write_info_plist("ContextPanelTV", profile_names=("tvos",), app_bundle=self.tv_app)
        self.write_info_plist(
            "ContextPanelWatch",
            profile_names=("watchos",),
            app_bundle=self.watch_app,
        )
        self.write_surface_manifest()
        for companion_bundle in (self.watch_app, self.tv_app):
            shutil.copyfile(
                self.app / "ContextPanelSurfaceManifest.json",
                companion_bundle / "ContextPanelSurfaceManifest.json",
            )
        self.matrix = load_shared_view_matrix()
        self.policy = load_surface_policy()
        self.config_path = self.root / "capture-config.json"
        self.companion_test_run = (
            self.companion_test_root
            / "ContextPanelCompanionSharedViewCaptureUITests.xctestrun"
        )
        self.output_root = self.root / "rendered"
        self.selected_requirements: list[str] = []
        self.sleeps: list[float] = []

    def tearDown(self) -> None:
        self.directory.cleanup()

    def write_info_plist(
        self,
        executable: str,
        *,
        profile_names: tuple[str, ...] = ("ios", "ipados", "visionos"),
        app_bundle: Path | None = None,
    ) -> None:
        if not profile_names:
            raise AssertionError("test profile bundle identifiers are inconsistent")
        bundle_identifier = PROFILE_BUNDLE_IDENTIFIERS[profile_names[0]]
        if any(PROFILE_BUNDLE_IDENTIFIERS[name] != bundle_identifier for name in profile_names):
            raise AssertionError("test profile bundle identifiers are inconsistent")
        target_bundle = app_bundle or self.app
        with (target_bundle / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle_identifier,
                    "CFBundleExecutable": executable,
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "456",
                    "CFBundleSupportedPlatforms": list(
                        dict.fromkeys(PROFILE_BUNDLE_PLATFORMS[name] for name in profile_names)
                    ),
                    "UIDeviceFamily": [PROFILE_DEVICE_FAMILIES[name] for name in profile_names],
                },
                stream,
            )

    def write_surface_manifest(self, manifest_id: str | None = None) -> None:
        surface_ids = [
            surface["id"]
            for surface in json.loads(
                (REPO_ROOT / "Config/ContextPanelSharedViewMatrix.json").read_text()
            )["surfaces"]
        ]
        surfaces = [
            {
                "id": surface_id,
                "artifactId": surface_id,
                "bundleIdentifier": f"com.example.{surface_id}",
                "evidenceCapabilities": ["shared-view"],
                "expectedArtifact": {
                    "artifactId": surface_id,
                    "bundleIdentifier": f"com.example.{surface_id}",
                    "marketingVersion": "1.2.3",
                    "buildNumber": "456",
                    "sourceCommit": "a" * 40,
                    "configuration": "Debug",
                    "xcodeBuild": "17A1",
                    "treeState": "clean",
                },
                "fingerprints": {
                    "render": "1" * 64,
                    "runtime": "2" * 64,
                    "placement": "3" * 64,
                    "combined": "4" * 64,
                },
            }
            for surface_id in surface_ids
        ]
        policy_path = REPO_ROOT / "Config/ContextPanelSurfacePolicy.json"
        policy = json.loads(policy_path.read_text())
        source = {
            "schemaVersion": 1,
            "algorithm": policy["algorithm"],
            "digestDomain": policy["digestDomain"],
            "contractFingerprint": "c" * 64,
            "source": {
                "marketingVersion": "1.2.3",
                "buildNumber": "456",
                "commit": "a" * 40,
                "configuration": "Debug",
                "xcodeBuild": "17A1",
                "treeState": "clean",
                "policySha256": hashlib.sha256(policy_path.read_bytes()).hexdigest(),
                "projectSourceSha256": "d" * 64,
            },
            "toolchain": policy["toolchain"],
            "archiveLayouts": policy["archiveLayouts"],
            "evidencePolicy": policy["evidencePolicy"],
            "artifactEvidenceContract": {
                "schemaVersion": 2,
                "integrity": "test-contract",
                "requiredFields": ["bundleIdentifier"],
            },
            "files": {"project.yml": "e" * 64},
            "ignoredInputs": policy["inventory"].get("ignoredInputs", []),
            "surfaces": surfaces,
        }
        source["manifestId"] = manifest_id or manifest_hash_parts(
            f"{source['digestDomain']}/manifest",
            [manifest_canonical_json(source)],
        )
        self.manifest_id = source["manifestId"]
        self.current_manifest_path.write_text(json.dumps(source))
        embedded = {
            "schemaVersion": 1,
            "kind": "context-panel-surface-build-intent",
            "manifestId": self.manifest_id,
            "contractFingerprint": source["contractFingerprint"],
            "surfaces": [
                {
                    key: value
                    for key, value in surface.items()
                    if key not in {"evidenceCapabilities", "expectedArtifact"}
                }
                for surface in sorted(surfaces, key=lambda item: item["id"])
            ],
        }
        (self.app / "ContextPanelSurfaceManifest.json").write_text(json.dumps(embedded))

    def write_plan(self, surfaces: list[str], *, matrix_path: Path | None = None) -> list[str]:
        """Select which surfaces' results `execute` reports, in matrix order."""
        selected = set(surfaces)
        matrix = self.matrix if matrix_path is None else load_shared_view_matrix(matrix_path, self.policy)
        self.selected_requirements = [
            shared_view_requirement_id(surface.id, cell.id)
            for surface in matrix.surfaces
            if surface.id in selected
            for cell in surface.cells
        ]
        return self.selected_requirements

    def write_config(self, profile_names: tuple[str, ...] = ("ios",)) -> None:
        if any(name in {"ios", "ipados", "visionos"} for name in profile_names):
            products = self.companion_products
            runner_app = products / "ContextPanelCompanionSharedViewCaptureUITests-Runner.app"
            test_bundle = (
                runner_app
                / "PlugIns"
                / "ContextPanelCompanionSharedViewCaptureUITests.xctest"
            )
            test_bundle.mkdir(parents=True, exist_ok=True)
            (runner_app / "Runner").write_bytes(b"ui test runner")
            (test_bundle / "Tests").write_bytes(b"ui tests")
            widget = products / "ContextPanelCompanionWidgetExtension.appex"
            widget.mkdir(exist_ok=True)
            (widget / "Widget").write_bytes(b"widget extension")
            target_name = "ContextPanelCompanionSharedViewCaptureUITests"
            with self.companion_test_run.open("wb") as stream:
                plistlib.dump(
                    {
                        "__xctestrun_metadata__": {
                            "FormatVersion": 1,
                            "ContainerInfo": {
                                "ContainerName": "ContextPanel",
                                "SchemeName": target_name,
                            },
                        },
                        target_name: {
                            "BlueprintName": target_name,
                            "ProductModuleName": target_name,
                            "IsUITestBundle": True,
                            "IsXCTRunnerHostedTestBundle": True,
                            "EnvironmentVariables": {},
                            "UITargetAppEnvironmentVariables": {},
                            "UITargetAppPath": "__TESTROOT__/Release-companionsimulator/Context Panel.app",
                            "TestHostPath": (
                                "__TESTROOT__/Release-companionsimulator/"
                                "ContextPanelCompanionSharedViewCaptureUITests-Runner.app"
                            ),
                            "TestBundlePath": (
                                "__TESTHOST__/PlugIns/"
                                "ContextPanelCompanionSharedViewCaptureUITests.xctest"
                            ),
                            "DependentProductPaths": [
                                "__TESTROOT__/Release-companionsimulator/Context Panel.app",
                                (
                                    "__TESTROOT__/Release-companionsimulator/"
                                    "ContextPanelCompanionSharedViewCaptureUITests-Runner.app"
                                ),
                                (
                                    "__TESTROOT__/Release-companionsimulator/"
                                    "ContextPanelCompanionSharedViewCaptureUITests-Runner.app/"
                                    "PlugIns/ContextPanelCompanionSharedViewCaptureUITests.xctest"
                                ),
                                (
                                    "__TESTROOT__/Release-companionsimulator/"
                                    "ContextPanelCompanionWidgetExtension.appex"
                                ),
                            ],
                        },
                    },
                    stream,
                )
        profiles = {
            name: {
                "runtimeIdentifier": RUNTIME_IDENTIFIERS[name],
                "deviceTypeIdentifier": DEVICE_TYPE_IDENTIFIERS[name],
                "appBundle": str(
                    {"watchos": self.watch_app, "tvos": self.tv_app}.get(name, self.app)
                ),
                **(
                    {"uiTestRun": str(self.companion_test_run)}
                    if name in {"ios", "ipados", "visionos"}
                    else {}
                ),
            }
            for name in profile_names
        }
        self.config_path.write_text(
            json.dumps(
                {
                    "schemaVersion": CAPTURE_CONFIG_SCHEMA_VERSION,
                    "kind": CAPTURE_CONFIG_KIND,
                    "profiles": profiles,
                }
            )
        )

    def execute(
        self,
        runner: "FakeRunner",
        *,
        run_id: str = "run-fixed",
        matrix_path: Path | None = None,
        surface_policy_path: Path | None = None,
        simulator_pins_path: Path | None = None,
    ) -> tuple[int, dict[str, Any]]:
        """Run the CI capture and report the selected surfaces' results in matrix order."""
        selected = {requirement.split(".")[1] for requirement in self.selected_requirements}
        real_loader = capture_module.load_shared_view_matrix

        def selected_matrix(*args: Any, **kwargs: Any) -> Any:
            matrix = real_loader(*args, **kwargs)
            surfaces = tuple(s for s in matrix.surfaces if s.id.replace(".", "-") in selected)
            return replace(matrix, surfaces=surfaces)

        with (
            mock.patch.object(capture_module, "uuid", SimpleNamespace(uuid4=lambda: SimpleNamespace(hex=run_id))),
            mock.patch.object(capture_module, "load_shared_view_matrix", selected_matrix),
        ):
            results = capture_reference_cells(
                self.config_path,
                self.output_root,
                runner=runner,
                sleeper=self.sleeps.append,
                now=lambda: FIXED_NOW,
                matrix_path=matrix_path or REPO_ROOT / "Config/ContextPanelSharedViewMatrix.json",
                surface_policy_path=surface_policy_path or REPO_ROOT / "Config/ContextPanelSurfacePolicy.json",
                simulator_pins_path=simulator_pins_path or self.write_pins(),
            )
        captures = [results[requirement_id] for requirement_id in self.selected_requirements]
        statuses = {capture["status"] for capture in captures}
        code = EXIT_OK if statuses == {"captured"} else EXIT_UNKNOWN if "unknown" in statuses else EXIT_BLOCKED
        return code, {"captures": captures}

    def write_pins(
        self,
        *,
        masked_regions: list[dict[str, Any]] | None = None,
        device_types: dict[str, str] | None = None,
    ) -> Path:
        """Pins matching this test's simulator catalog."""
        path = self.root / "simulator-pins.json"
        path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "kind": capture_module.SIMULATOR_PINS_KIND,
                    "xcode": "/Applications/Xcode.app",
                    "profiles": {
                        name: {
                            "runtimeIdentifier": RUNTIME_IDENTIFIERS[name],
                            "deviceTypeIdentifier": (device_types or DEVICE_TYPE_IDENTIFIERS)[name],
                            **(
                                {"maskedRegions": masked_regions}
                                if name == "watchos" and masked_regions is not None
                                else {}
                            ),
                        }
                        for name in RUNTIME_IDENTIFIERS
                    },
                }
            )
        )
        return path

    def assert_capture_errors(self, receipt: dict[str, Any], *errors: str) -> None:
        self.assertEqual(list(errors), [item["errorCode"] for item in receipt["captures"]])

    def test_ios_and_ipados_use_associated_ui_test_capture_for_each_route(self) -> None:
        for profile_name, surface, family, stress_fixture, stress_presentation in (
            ("ios", "ios.app", "systemMedium", "dense-accounts", "overview"),
            ("ipados", "ipados.app", "systemLarge", "fit-fallback", "settings"),
        ):
            with self.subTest(profile=profile_name):
                self.write_plan([surface])
                self.write_config((profile_name,))
                runner = FakeRunner()
                self.sleeps.clear()

                exit_code, receipt = self.execute(
                    runner,
                    run_id=f"{profile_name}-xcuitest",
                )

                self.assertEqual(EXIT_OK, exit_code)
                self.assertEqual([], self.sleeps)
                commands = [args for args, _ in runner.calls]
                self.assertEqual(2, sum(args[0] == "xcodebuild" for args in commands))
                self.assertEqual(2, sum(args[1:3] == ["xcresulttool", "export"] for args in commands))
                self.assertEqual(1, sum(args[2] == "terminate" for args in commands))
                self.assertFalse(any(args[2] in {"ui", "launch", "io", "openurl"} for args in commands))
                self.assertFalse(any(args[2] == "erase" for args in commands))
                self.assertEqual(
                    [
                        (
                            "contextpanelcompanion://validation-gallery?fixture=healthy&"
                            f"family={family}&appearance=light&presentation=overview"
                        ),
                        (
                            "contextpanelcompanion://validation-gallery?"
                            f"fixture={stress_fixture}&family={family}&appearance=dark&"
                            f"presentation={stress_presentation}"
                        ),
                    ],
                    [
                        environment[capture_module.VISIONOS_UI_TEST_ENVIRONMENT["url"]]
                        for environment in runner.xcuitest_environments
                    ],
                )
                self.assertEqual(["captured", "captured"], [
                    item["status"] for item in receipt["captures"]
                ])
                self.assertEqual(["xcuitest-shared-view-renderer"] * 2, [
                    item["hostMechanism"] for item in receipt["captures"]
                ])
                self.assertEqual(["xcuitest-render-route"] * 2, [
                    item["appearanceMechanism"] for item in receipt["captures"]
                ])

    def test_visionos_install_uses_cold_runtime_timeout(self) -> None:
        self.write_plan(["visionos.app"])
        self.write_config(("visionos",))
        runner = FakeRunner()

        exit_code, _ = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        install_calls = [
            (args, timeout) for args, timeout in runner.calls if args[2] == "install"
        ]
        self.assertEqual([300], [timeout for _, timeout in install_calls])
        self.assertEqual([300], [
            timeout for args, timeout in runner.calls if args[2] == "bootstatus"
        ])
        self.assertEqual([capture_module.SIMCTL_CONTAINER_TIMEOUT] * 3, [
            timeout for args, timeout in runner.calls if args[2] == "get_app_container"
        ])

    def test_visionos_uses_associated_ui_test_capture_for_each_route(self) -> None:
        self.write_plan(["visionos.app"])
        self.write_config(("visionos",))
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        commands = [args for args, _ in runner.calls]
        self.assertEqual(2, sum(args[0] == "xcodebuild" for args in commands))
        self.assertEqual(2, sum(args[1:3] == ["xcresulttool", "export"] for args in commands))
        self.assertEqual([600, 600], [
            timeout for args, timeout in runner.calls if args[0] == "xcodebuild"
        ])
        self.assertEqual([60, 60], [
            timeout
            for args, timeout in runner.calls
            if args[1:3] == ["xcresulttool", "export"]
        ])
        self.assertEqual([], self.sleeps)
        # The cells share one simulator; the app is terminated between them.
        self.assertEqual(1, sum(args[2] == "terminate" for args in commands))
        self.assertFalse(any(args[2] in {"ui", "launch", "io", "openurl", "erase"} for args in commands))
        self.assertEqual(
            [
                (
                    "contextpanelcompanion://validation-gallery?fixture=healthy&"
                    "family=systemLarge&appearance=light&presentation=overview"
                ),
                (
                    "contextpanelcompanion://validation-gallery?fixture=dense-accounts&"
                    "family=systemLarge&appearance=dark&presentation=overview"
                ),
            ],
            [
                environment[capture_module.VISIONOS_UI_TEST_ENVIRONMENT["url"]]
                for environment in runner.xcuitest_environments
            ],
        )
        self.assertEqual(["captured", "captured"], [
            item["status"] for item in receipt["captures"]
        ])
        self.assertEqual(["xcuitest-shared-view-renderer"] * 2, [
            item["hostMechanism"] for item in receipt["captures"]
        ])
        self.assertEqual(["xcuitest-render-route"] * 2, [
            item["appearanceMechanism"] for item in receipt["captures"]
        ])

    def test_visionos_xcui_capture_accepts_16_bit_png_attachments(self) -> None:
        self.write_plan(["visionos.app"])
        self.write_config(("visionos",))

        exit_code, receipt = self.execute(FakeRunner(png_bit_depth=16))

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(["captured", "captured"], [
            item["status"] for item in receipt["captures"]
        ])

    def test_visionos_ui_test_and_attachment_export_failures_are_unknown(self) -> None:
        scenarios = (
            (FakeRunner(fail_at="xcodebuild"), "xcuitest-capture-failed"),
            (FakeRunner(timeout_at="xcodebuild"), "xcuitest-capture-timeout"),
            (FakeRunner(fail_at="xcresulttool"), "xcresult-attachment-export-failed"),
            (FakeRunner(timeout_at="xcresulttool"), "xcresult-attachment-export-timeout"),
        )
        for index, (runner, error_code) in enumerate(scenarios):
            with self.subTest(error_code=error_code):
                self.write_plan(["visionos.app"])
                self.write_config(("visionos",))

                exit_code, receipt = self.execute(
                    runner,
                    run_id=f"visionos-export-{index}",
                )

                self.assertEqual(EXIT_UNKNOWN, exit_code)
                self.assert_capture_errors(receipt, error_code, error_code)
                self.assertEqual(["xcuitest-render-route"] * 2, [
                    item["appearanceMechanism"] for item in receipt["captures"]
                ])

    def test_visionos_attachment_manifest_fails_closed(self) -> None:
        for index, manifest_error in enumerate(
            ("wrong-test", "missing-sample", "failed-attachment")
        ):
            with self.subTest(manifest_error=manifest_error):
                self.write_plan(["visionos.app"])
                self.write_config(("visionos",))

                exit_code, receipt = self.execute(
                    FakeRunner(xcuitest_manifest_error=manifest_error),
                    run_id=f"visionos-manifest-{index}",
                )

                self.assertEqual(EXIT_UNKNOWN, exit_code)
                self.assert_capture_errors(
                    receipt,
                    "xcuitest-attachments-invalid",
                    "xcuitest-attachments-invalid",
                )

    def test_visionos_attachment_stability_can_converge(self) -> None:
        self.write_plan(["visionos.app"])
        self.write_config(("visionos",))

        exit_code, receipt = self.execute(FakeRunner(settles_after_samples=4))

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(["captured", "captured"], [
            item["status"] for item in receipt["captures"]
        ])

    def test_tv_profile_launches_each_matrix_cell_and_settles_before_relaunching(self) -> None:
        self.write_plan(["tvos.app", "tvos.top-shelf"])
        self.write_config(("tvos",))
        runner = FakeRunner()
        calls_seen_at_each_sleep: list[int] = []

        class SleepLog(list):
            def append(log, seconds):  # noqa: N805
                calls_seen_at_each_sleep.append(len(runner.calls))
                super().append(seconds)

        self.sleeps = SleepLog()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        commands = [args for args, _ in runner.calls]
        self.assertFalse(any(args[2] in {"erase", "ui"} for args in commands))
        cells = [
            (surface.id, cell)
            for surface in self.matrix.surfaces
            if surface.id in {"tvos.app", "tvos.top-shelf"}
            for cell in surface.cells
        ]
        self.assertTrue(cells)
        self.assertEqual(
            [
                [
                    "xcrun", "simctl", "launch", "--terminate-running-process", SIMULATOR_ID,
                    PROFILE_BUNDLE_IDENTIFIERS["tvos"], "--context-panel-validation-gallery",
                    "--context-panel-validation-surface", surface_id,
                    "--context-panel-validation-fixture", cell.fixture_id,
                    "--context-panel-validation-family", cell.family,
                    "--context-panel-validation-presentation", cell.presentation,
                    *capture_module.SIMULATOR_LAUNCH_LOCALE_ARGUMENTS,
                ]
                for surface_id, cell in cells
            ],
            [args for args in commands if args[2] == "launch"],
        )
        # tvOS relaunches an app in the background when it is started right after
        # termination, so every terminate must be followed by a settle before the
        # next simctl command.
        terminate_positions = [index for index, args in enumerate(commands) if args[2] == "terminate"]
        self.assertEqual(len(cells) - 1, len(terminate_positions))
        for position in terminate_positions:
            self.assertIn(position + 1, calls_seen_at_each_sleep)
        self.assertEqual(["captured"] * len(cells), [item["status"] for item in receipt["captures"]])
        self.assertEqual(
            {("simctl-gallery", None)},
            {(item["hostMechanism"], item["appearanceMechanism"]) for item in receipt["captures"]},
        )

    def test_tv_profile_rejects_a_family_that_does_not_belong_to_the_surface(self) -> None:
        profile = SimpleNamespace(name="tvos", bundle_identifier=PROFILE_BUNDLE_IDENTIFIERS["tvos"])
        mismatches = (
            ("tvos.top-shelf", "runway", "fullDetail"),
            ("tvos.app", "topShelf", "fullDetail"),
            ("tvos.app", "runway", "not-applicable"),
        )
        for surface, family, presentation in mismatches:
            with self.subTest(surface=surface, family=family, presentation=presentation):
                requirement = SimpleNamespace(
                    surface=surface,
                    fixture_id="healthy",
                    family=family,
                    presentation=presentation,
                )
                with self.assertRaisesRegex(
                    capture_module.SharedViewCaptureError, "capture TV selector is invalid"
                ):
                    capture_module._capture_route(profile, SIMULATOR_ID, requirement)

    def test_watch_profile_uses_direct_launch_without_appearance_mutation(self) -> None:
        self.write_plan(["watchos.app", "watchos.complication"])
        self.write_config(("watchos",))
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual([3.0] * 14, self.sleeps)
        commands = [args for args, _ in runner.calls]
        self.assertFalse(any(args[2] == "erase" for args in commands))
        self.assertEqual(
            {"UTC"},
            {environment["SIMCTL_CHILD_TZ"] for environment in runner.launch_environments},
        )
        self.assertEqual(
            [
                "list", "create", "list", "boot", "bootstatus", "install", "get_app_container",
                "io", "io", "launch", "io", "io", "terminate", "io", "io", "launch", "io", "io",
                # The complications draw their own framed cell; it is read from the data
                # container instead of a screenshot.
                "terminate", "io", "io", "get_app_container", "launch", "terminate", "io", "io",
                "get_app_container", "launch", "shutdown", "delete", "list", "list",
            ],
            [args[2] for args in commands],
        )
        self.assertFalse(any(args[2] == "ui" for args in commands))
        launch_commands = [args for args in commands if args[2] == "launch"]
        self.assertEqual(
            [
                [
                    "xcrun", "simctl", "launch", "--terminate-running-process", SIMULATOR_ID,
                    PROFILE_BUNDLE_IDENTIFIERS["watchos"], "--context-panel-validation-gallery",
                    "--context-panel-validation-surface", surface,
                    "--context-panel-validation-fixture", fixture,
                    *([] if family == "not-applicable" else [
                        "--context-panel-validation-family", family,
                    ]),
                    *capture_module.SIMULATOR_LAUNCH_LOCALE_ARGUMENTS,
                ]
                for surface, fixture, family in (
                    ("watchos.app", "healthy", "not-applicable"),
                    ("watchos.app", "dense-accounts", "not-applicable"),
                    ("watchos.complication", "healthy", "circular"),
                    ("watchos.complication", "reset-visible", "rectangular"),
                )
            ],
            launch_commands,
        )
        self.assertEqual([True] * 12, runner.screenshot_destinations_absent)
        self.assertEqual(["captured"] * 4, [item["status"] for item in receipt["captures"]])
        self.assertEqual(
            ["simctl-gallery"] * 4,
            [item["hostMechanism"] for item in receipt["captures"]],
        )
        self.assertEqual(
            [None] * 4,
            [item["appearanceMechanism"] for item in receipt["captures"]],
        )

    def test_watch_complication_is_unknown_when_the_app_writes_no_framed_cell(self) -> None:
        self.write_plan(["watchos.complication"])
        self.write_config(("watchos",))

        exit_code, receipt = self.execute(FakeRunner(rendered_cell="missing"))

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, "rendered-cell-missing", "rendered-cell-missing")

    def test_watch_app_capture_paints_out_the_pinned_clock_region(self) -> None:
        self.write_plan(["watchos.app"])
        self.write_config(("watchos",))
        pins = self.write_pins(
            masked_regions=[
                {"surface": "watchos.app", "x": 300, "y": 0, "width": 40, "height": 20, "reason": "clock"}
            ]
        )

        exit_code, receipt = self.execute(FakeRunner(), simulator_pins_path=pins)

        self.assertEqual(EXIT_OK, exit_code)
        artifact = self.output_root / "watchos.app" / "baseline.png"
        image = decode_png(artifact.read_bytes())

        def pixel(x: int, y: int) -> bytes:
            start = (y * image.width + x) * 4
            return image.rgba[start : start + 4]

        self.assertEqual(b"\x00\x00\x00\xff", pixel(319, 19))
        self.assertNotEqual(b"\x00\x00\x00\xff", pixel(299, 19))
        self.assertNotEqual(b"\x00\x00\x00\xff", pixel(319, 20))
        self.assertEqual(hashlib.sha256(artifact.read_bytes()).hexdigest(), receipt["captures"][0]["artifactDigest"])

    def test_a_masked_watch_capture_still_must_differ_from_its_masked_baseline(self) -> None:
        self.write_plan(["watchos.app"])
        self.write_config(("watchos",))
        pins = self.write_pins(
            masked_regions=[
                {"surface": "watchos.app", "x": 0, "y": 0, "width": 40, "height": 20, "reason": "clock"}
            ]
        )

        exit_code, receipt = self.execute(FakeRunner(baseline_equal=True), simulator_pins_path=pins)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, "route-baseline-unchanged", "route-baseline-unchanged")

    def test_a_symlinked_container_tmp_directory_is_refused(self) -> None:
        self.write_plan(["watchos.complication"])
        self.write_config(("watchos",))
        runner = FakeRunner()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / capture_module.RENDERED_CELL_FILE_NAME).write_bytes(png_bytes())
        (runner.data_container / "tmp").rmdir()
        (runner.data_container / "tmp").symlink_to(outside)

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, "simctl-data-container-invalid", "simctl-data-container-invalid")
        self.assertTrue((outside / capture_module.RENDERED_CELL_FILE_NAME).exists())

    def test_reference_cells_are_written_as_surface_and_cell_images(self) -> None:
        self.write_config(("watchos", "tvos"))
        output = self.root / "rendered"

        results = capture_reference_cells(
            self.config_path,
            output,
            runner=FakeRunner(),
            sleeper=self.sleeps.append,
            now=lambda: FIXED_NOW,
            simulator_pins_path=self.write_pins(),
        )

        captured = sorted(
            f"{item['surface']}/{item['cellID']}.png" for item in results.values() if item["status"] == "captured"
        )
        self.assertEqual(
            [f"{surface}/{cell}.png" for surface in ("tvos.app", "tvos.top-shelf", "watchos.app", "watchos.complication")
             for cell in ("baseline", "stress")],
            captured,
        )
        self.assertEqual(sorted(captured), sorted(path.relative_to(output).as_posix() for path in output.rglob("*.png")))
        self.assertEqual(
            {"profile-not-configured"},
            {item["errorCode"] for item in results.values() if item["status"] != "captured"},
        )

    def capture_watch_references(self, runner: FakeRunner) -> dict[str, dict[str, object]]:
        self.write_config(("watchos",))
        results = capture_reference_cells(
            self.config_path,
            self.root / "rendered",
            runner=runner,
            sleeper=self.sleeps.append,
            now=lambda: FIXED_NOW,
            simulator_pins_path=self.write_pins(),
        )
        return {key: item for key, item in results.items() if str(item["surface"]).startswith("watchos.")}

    def test_reference_visionos_cells_share_one_simulator_without_erasing_it(self) -> None:
        self.write_config(("visionos",))
        runner = FakeRunner()

        results = capture_reference_cells(
            self.config_path,
            self.root / "rendered",
            runner=runner,
            sleeper=self.sleeps.append,
            now=lambda: FIXED_NOW,
            simulator_pins_path=self.write_pins(),
        )

        vision = [item for item in results.values() if str(item["surface"]).startswith("visionos.")]
        self.assertEqual({"captured"}, {item["status"] for item in vision})
        self.assertEqual(4, len(vision))
        self.assertEqual(0, sum(args[2] == "erase" for args, _ in runner.calls))
        self.assertEqual(1, sum(args[:3] == ["xcrun", "simctl", "create"] for args, _ in runner.calls))

    def test_a_reference_cell_that_fails_once_is_retried_in_a_fresh_simulator(self) -> None:
        runner = FakeRunner(fail_at_call=("launch", 2))

        watch = self.capture_watch_references(runner)

        self.assertEqual({"captured"}, {item["status"] for item in watch.values()})
        self.assertEqual(2, sum(args[:3] == ["xcrun", "simctl", "create"] for args, _ in runner.calls))
        self.assertEqual(
            sorted(f"{item['surface']}/{item['cellID']}.png" for item in watch.values()),
            sorted(path.relative_to(self.root / "rendered").as_posix() for path in (self.root / "rendered").rglob("*.png")),
        )

    def test_a_cell_whose_image_failed_to_publish_is_captured_on_retry(self) -> None:
        real_replace = os.replace
        failures: list[str] = []

        def fail_first_publish(source, destination):
            if not failures:
                failures.append(str(destination))
                raise OSError("publish failed")
            return real_replace(source, destination)

        with mock.patch.object(capture_module.os, "replace", side_effect=fail_first_publish):
            watch = self.capture_watch_references(FakeRunner())

        self.assertEqual(1, len(failures))
        self.assertEqual({"captured"}, {item["status"] for item in watch.values()})

    def test_a_profile_where_every_cell_fails_is_not_retried(self) -> None:
        runner = FakeRunner(fail_at="boot")

        watch = self.capture_watch_references(runner)

        self.assertEqual({"unknown"}, {item["status"] for item in watch.values()})
        self.assertEqual(1, sum(args[:3] == ["xcrun", "simctl", "create"] for args, _ in runner.calls))

    def test_reference_cells_refuse_a_simulator_other_than_the_pinned_one(self) -> None:
        self.write_config(("watchos",))
        runner = FakeRunner()

        results = capture_reference_cells(
            self.config_path,
            self.root / "rendered",
            runner=runner,
            sleeper=self.sleeps.append,
            now=lambda: FIXED_NOW,
            simulator_pins_path=self.write_pins(
                device_types={**DEVICE_TYPE_IDENTIFIERS, "watchos": "com.apple.CoreSimulator.SimDeviceType.Other"}
            ),
        )

        watch = [item for item in results.values() if str(item["surface"]).startswith("watchos.")]
        self.assertEqual({("blocked", "simctl-profile-not-pinned")}, {(item["status"], item["errorCode"]) for item in watch})
        self.assertEqual([], runner.calls)

    def test_simulator_pins_reject_a_masked_region_for_another_platform(self) -> None:
        pins = self.write_pins(
            masked_regions=[{"surface": "tvos.app", "x": 0, "y": 0, "width": 1, "height": 1, "reason": "clock"}]
        )
        with self.assertRaisesRegex(SharedViewCaptureError, "masked region is invalid"):
            capture_module.load_simulator_pins(pins)

    def test_watch_profile_rejects_invalid_bundle_metadata_and_selectors(self) -> None:
        self.write_plan(["watchos.app"])
        self.write_config(("watchos",))

        for key, value in (
            ("CFBundleIdentifier", "com.shinycomputers.contextpanel"),
            ("CFBundleSupportedPlatforms", ["iPhoneSimulator"]),
            ("UIDeviceFamily", [1]),
        ):
            self.write_info_plist(
                "ContextPanelWatch",
                profile_names=("watchos",),
                app_bundle=self.watch_app,
            )
            with (self.watch_app / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            info[key] = value
            with (self.watch_app / "Info.plist").open("wb") as stream:
                plistlib.dump(info, stream)
            with self.subTest(key=key), self.assertRaisesRegex(
                SharedViewCaptureError,
                "bundle identifier is invalid" if key == "CFBundleIdentifier" else "platform metadata is invalid",
            ):
                self.execute(FakeRunner(), run_id=f"watch-metadata-{key}")

        self.write_info_plist(
            "ContextPanelWatch",
            profile_names=("watchos",),
            app_bundle=self.watch_app,
        )
        for key, value in (
            ("runtimeIdentifier", "/private/watch-runtime"),
            ("deviceTypeIdentifier", "not-a-simulator-device"),
        ):
            self.write_config(("watchos",))
            config = json.loads(self.config_path.read_text())
            config["profiles"]["watchos"][key] = value
            self.config_path.write_text(json.dumps(config))
            with self.subTest(key=key), self.assertRaisesRegex(
                SharedViewCaptureError,
                "simulator identifier is invalid",
            ):
                self.execute(FakeRunner(), run_id=f"watch-selector-{key}")

    def test_companion_ui_test_applies_route_appearance_without_simulator_mutation(self) -> None:
        matrix_payload = json.loads((REPO_ROOT / "Config/ContextPanelSharedViewMatrix.json").read_text())
        ios_surface = next(surface for surface in matrix_payload["surfaces"] if surface["id"] == "ios.app")
        ios_surface["cells"][0]["appearance"] = "adaptive"
        matrix_path = self.root / "adaptive-matrix.json"
        matrix_path.write_text(json.dumps(matrix_payload))
        self.write_plan(["ios.app"], matrix_path=matrix_path)
        self.write_config()
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner, matrix_path=matrix_path)

        self.assertEqual(EXIT_OK, exit_code)
        self.assertFalse(any(
            args[:3] == ["xcrun", "simctl", "ui"] for args, _ in runner.calls
        ))
        self.assertEqual(
            ["adaptive", "dark"],
            [
                environment[capture_module.VISIONOS_UI_TEST_ENVIRONMENT["appearance"]]
                for environment in runner.xcuitest_environments
            ],
        )
        self.assertEqual(
            ["xcuitest-render-route"] * 2,
            [item["appearanceMechanism"] for item in receipt["captures"]],
        )

    def test_timeout_codes_are_distinct_and_appearance_is_null_before_application(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(timeout_at="boot")

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-boot-timeout",) * 2)
        self.assertEqual([None, None], [item["appearanceMechanism"] for item in receipt["captures"]])
        self.assertIn(["xcrun", "simctl", "delete", SIMULATOR_ID], [args for args, _ in runner.calls])

    def test_mid_cell_failures_preserve_exact_mechanism_progress(self) -> None:
        cases = (
            ({"fail_at": "bootstatus"}, "simctl-bootstatus-failed", None),
            ({"fail_at": "install"}, "simctl-install-failed", None),
            ({"fail_at": "get_app_container"}, "simctl-app-container-failed", None),
            ({"container_output": "relative/path"}, "simctl-app-container-invalid", None),
        )
        self.write_plan(["ios.app"])
        self.write_config()
        for index, (runner_options, error_code, mechanism) in enumerate(cases):
            with self.subTest(error_code=error_code):
                exit_code, receipt = self.execute(
                    FakeRunner(**runner_options),
                    run_id=f"command-failure-{index}",
                )
                self.assertEqual(EXIT_UNKNOWN, exit_code)
                self.assertEqual(error_code, receipt["captures"][0]["errorCode"])
                self.assertEqual(mechanism, receipt["captures"][0]["appearanceMechanism"])

    def test_identity_mismatch(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(created_device_mismatch=True)

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-created-device-mismatch",) * 2)
        self.assertFalse(any(args[2] == "boot" for args, _ in runner.calls))
        self.assertFalse(any(args[2] in {"shutdown", "delete"} for args, _ in runner.calls))

    def test_ids(self) -> None:
        self.write_config()
        profile = load_capture_config(self.config_path)["ios"]
        name = "ContextPanelSharedView-ios-run-fixed"
        device = {
            "udid": SIMULATOR_ID,
            "name": name,
            "deviceTypeIdentifier": profile.device_type_identifier,
            "isAvailable": True,
        }
        def payload(value: object, runtime: str = profile.runtime_identifier) -> str:
            return json.dumps({"devices": {runtime: value}})
        cases = (
            (CommandResult(1, "", ""), "simctl-created-device-failed"),
            (CommandResult(124, "", "", timed_out=True), "simctl-created-device-timeout"),
            (CommandResult(0, "not-json", ""), "simctl-created-device-invalid"),
            (CommandResult(0, json.dumps({"devices": []}), ""), "simctl-created-device-invalid"),
            (CommandResult(0, payload({}), ""), "simctl-created-device-invalid"),
            (CommandResult(0, payload([device] * 257), ""), "simctl-created-device-invalid"),
            (CommandResult(0, payload([{**device, "udid": "bad"}]), ""), "simctl-created-device-invalid"),
            (CommandResult(0, payload([{**device, "udid": SECOND_SIMULATOR_ID}]), ""), "simctl-created-device-mismatch"),
            (CommandResult(0, payload([device, device]), ""), "simctl-created-device-mismatch"),
            (CommandResult(0, payload([device], RUNTIME_IDENTIFIERS["visionos"]), ""), "simctl-created-device-mismatch"),
            (CommandResult(0, payload([{**device, "deviceTypeIdentifier": DEVICE_TYPE_IDENTIFIERS["ipados"]}]), ""), "simctl-created-device-mismatch"),
            (CommandResult(0, payload([{**device, "isAvailable": False}]), ""), "simctl-created-device-mismatch"),
        )
        for result, expected in cases:
            runner = FakeRunner()
            runner.run = mock.Mock(return_value=result)
            with self.subTest(expected=expected, stdout=result.stdout):
                self.assertEqual(expected, _verify_created_simulator(runner, profile, name, SIMULATOR_ID))

    def test_pre(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(device_list_failure=CommandResult(1, "", "private inventory failure"))
        exit_code, receipt = self.execute(runner)
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-device-inventory-failed",) * 2)
        self.assertFalse(any(args[2] == "create" for args, _ in runner.calls))

        runner = FakeRunner(device_list_failure=CommandResult(0, "not-json", ""))
        exit_code, receipt = self.execute(
            runner,
            run_id="invalid-inventory",
        )
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-device-inventory-invalid",) * 2)

    def test_duplicate_cleanup(self) -> None:
        self.write_plan(["ios.app", "ipados.app"])
        self.write_config(("ios", "ipados"))
        runner = FakeRunner(cross_profile_duplicates=True)
        original_run = runner.run
        failed_delete = False

        def fail_first_delete(
            args: list[str], *, timeout: int, environment: dict[str, str] | None = None
        ) -> CommandResult:
            nonlocal failed_delete
            result = original_run(args, timeout=timeout, environment=environment)
            if args[2] == "delete" and not failed_delete:
                failed_delete = True
                runner.created_simulator_id = SIMULATOR_ID
                return CommandResult(1, "", "private delete failure")
            return result

        runner.run = fail_first_delete
        exit_code, receipt = self.execute(runner, run_id="cleanup-then-duplicate")
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual(
            ["simctl-delete-failed", "simctl-delete-failed"],
            [item["errorCode"] for item in receipt["captures"][:2]],
        )

    def test_terminate_failure_is_best_effort_and_later_cell_still_captures(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(fail_at="terminate")

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(["captured", "captured"], [item["status"] for item in receipt["captures"]])
        self.assertTrue(any(args[2] == "terminate" for args, _ in runner.calls))

    def test_unstable_baseline_and_duplicate_digests_are_unknown(self) -> None:
        scenarios = (
            (FakeRunner(unstable=True), "capture-unstable"),
            (FakeRunner(baseline_unstable=True), "baseline-unstable"),
            (FakeRunner(baseline_equal=True), "route-baseline-unchanged"),
            (FakeRunner(duplicate_routes=True), "duplicate-artifact-digest"),
        )
        for index, (runner, error_code) in enumerate(scenarios):
            with self.subTest(error_code=error_code):
                self.write_plan(["ios.app"])
                self.write_config()
                self.sleeps.clear()
                exit_code, receipt = self.execute(
                    runner,
                    run_id=f"scenario-{index}",
                )
                self.assertEqual(EXIT_UNKNOWN, exit_code)
                self.assertEqual(["unknown", "unknown"], [item["status"] for item in receipt["captures"]])
                self.assert_capture_errors(receipt, error_code, error_code)
                self.assertFalse(list(self.output_root.rglob("*.png")))

    def test_transient_frames_converge_before_capture(self) -> None:
        self.write_plan(["watchos.app"])
        self.write_config(("watchos",))

        exit_code, receipt = self.execute(FakeRunner(settles_after_first=True))

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(["captured", "captured"], [item["status"] for item in receipt["captures"]])
        self.assertEqual([3.0] * 9, self.sleeps)

    def test_late_transient_frames_converge_at_bounded_sample_limit(self) -> None:
        self.write_plan(["watchos.app"])
        self.write_config(("watchos",))
        runner = FakeRunner(settles_after_samples=4)

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(["captured", "captured"], [
            item["status"] for item in receipt["captures"]
        ])
        self.assertEqual(8, runner.baseline_screenshot_count)
        self.assertEqual([6, 6], sorted(runner.route_screenshot_counts.values()))

    def test_complete_png_crc_truncation_and_idat_validation(self) -> None:
        for index, corruption in enumerate(("crc", "truncated", "idat")):
            with self.subTest(corruption=corruption):
                self.write_plan(["ios.app"])
                self.write_config()
                exit_code, receipt = self.execute(
                    FakeRunner(corrupt_png=corruption),
                    run_id=f"corrupt-{index}",
                )
                self.assertEqual(EXIT_UNKNOWN, exit_code)
                self.assertEqual("captured-image-invalid", receipt["captures"][0]["errorCode"])

    def test_png_validator_rejects_structural_and_bomb_inputs(self) -> None:
        valid_row = b"\x00" + (b"\x22\x66\xaa\xff" * 320)
        valid_idat = zlib.compress(valid_row * 180)
        document = png_document
        header = png_ihdr
        realistic = self.root / "realistic.png"
        realistic.write_bytes(document(
            (b"IHDR", header()), (b"sRGB", b"\0"), (b"pHYs", b"\0" * 9),
            (b"IDAT", valid_idat[:8]), (b"IDAT", valid_idat[8:]), (b"IEND", b""),
        ))
        minimal = self.root / "minimal.png"
        minimal.write_bytes(png_bytes())
        realistic_snapshot = _png_snapshot(realistic)
        minimal_snapshot = _png_snapshot(minimal)
        self.assertEqual(minimal_snapshot.pixel_digest, realistic_snapshot.pixel_digest)
        self.assertNotEqual(minimal_snapshot.artifact_digest, realistic_snapshot.artifact_digest)
        rgb = self.root / "rgb.png"
        rgb.write_bytes(document(
            (b"IHDR", header(color_type=2)),
            (b"IDAT", zlib.compress((b"\0" + b"\x22\x66\xaa" * 320) * 180)),
            (b"IEND", b""),
        ))
        self.assertEqual(minimal_snapshot.pixel_digest, _png_snapshot(rgb).pixel_digest)

        format_digests = []
        for bit_depth, rows, bytes_per_pixel in (
            (8, (bytes(range(8)), bytes(range(8, 16))), 4),
            (16, (bytes(range(16)), bytes(range(16, 32))), 8),
        ):
            filter_digests = set()
            for filter_type in range(5):
                previous = bytes(len(rows[0]))
                filtered_rows = []
                for row in rows:
                    encoded = bytearray()
                    for index, value in enumerate(row):
                        left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
                        above = previous[index]
                        upper_left = (
                            previous[index - bytes_per_pixel]
                            if index >= bytes_per_pixel
                            else 0
                        )
                        if filter_type == 1:
                            predictor = left
                        elif filter_type == 2:
                            predictor = above
                        elif filter_type == 3:
                            predictor = (left + above) // 2
                        elif filter_type == 4:
                            estimate = left + above - upper_left
                            choices = (left, above, upper_left)
                            predictor = min(
                                choices,
                                key=lambda choice: (
                                    abs(estimate - choice),
                                    choices.index(choice),
                                ),
                            )
                        else:
                            predictor = 0
                        encoded.append((value - predictor) & 0xFF)
                    filtered_rows.append(bytes((filter_type,)) + encoded)
                    previous = row
                path = self.root / f"filter-{bit_depth}-{filter_type}.png"
                path.write_bytes(document(
                    (b"IHDR", header(width=2, height=2, bit_depth=bit_depth)),
                    (b"IDAT", zlib.compress(b"".join(filtered_rows))),
                    (b"IEND", b""),
                ))
                filter_digests.add(_png_snapshot(path).pixel_digest)
            self.assertEqual(1, len(filter_digests))
            format_digests.append(next(iter(filter_digests)))
        self.assertNotEqual(format_digests[0], format_digests[1])

        rgb16 = self.root / "rgb-16.png"
        rgb16_pixel = b"\x12\x34\x56\x78\x9a\xbc"
        rgb16.write_bytes(document(
            (b"IHDR", header(width=1, height=1, bit_depth=16, color_type=2)),
            (b"IDAT", zlib.compress(b"\0" + rgb16_pixel)),
            (b"IEND", b""),
        ))
        rgba16 = self.root / "rgba-16.png"
        rgba16.write_bytes(document(
            (b"IHDR", header(width=1, height=1, bit_depth=16)),
            (b"IDAT", zlib.compress(b"\0" + rgb16_pixel + b"\xff\xff")),
            (b"IEND", b""),
        ))
        rgba16_changed = self.root / "rgba-16-changed.png"
        rgba16_changed.write_bytes(document(
            (b"IHDR", header(width=1, height=1, bit_depth=16)),
            (b"IDAT", zlib.compress(b"\0" + rgb16_pixel[:-1] + b"\xbd\xff\xff")),
            (b"IEND", b""),
        ))
        self.assertEqual(
            _png_snapshot(rgb16).pixel_digest,
            _png_snapshot(rgba16).pixel_digest,
        )
        self.assertNotEqual(
            _png_snapshot(rgba16).pixel_digest,
            _png_snapshot(rgba16_changed).pixel_digest,
        )
        cases = {
            "bit-depth": document((b"IHDR", header(bit_depth=4)), (b"IDAT", valid_idat), (b"IEND", b"")),
            "huge-dimension": document((b"IHDR", header(width=16_385)), (b"IDAT", zlib.compress(b"\x00")), (b"IEND", b"")),
            "huge-pixels": document((b"IHDR", header(width=8_192, height=4_097)), (b"IDAT", zlib.compress(b"\x00")), (b"IEND", b"")),
            "palette": document((b"IHDR", header(color_type=3)), (b"IDAT", valid_idat), (b"IEND", b"")),
            "interlaced": document((b"IHDR", header(methods=b"\x00\x00\x01")), (b"IDAT", valid_idat), (b"IEND", b"")),
            "wrong-first": document((b"IDAT", valid_idat), (b"IEND", b"")),
            "duplicate-ihdr": document((b"IHDR", header()), (b"IHDR", header()), (b"IDAT", valid_idat), (b"IEND", b"")),
            "unknown-critical": document((b"IHDR", header()), (b"ABCD", b""), (b"IDAT", valid_idat), (b"IEND", b"")),
            "nonalphabetic-chunk": document((b"IHDR", header()), (b"ab1D", b""), (b"IDAT", valid_idat), (b"IEND", b"")),
            "reserved-bit": document((b"IHDR", header()), (b"abct", b""), (b"IDAT", valid_idat), (b"IEND", b"")),
            "transparency": document((b"IHDR", header(color_type=2)), (b"tRNS", b"\0" * 6), (b"IDAT", zlib.compress((b"\0" + b"\x22\x66\xaa" * 320) * 180)), (b"IEND", b"")),
            "empty-plte": document((b"IHDR", header()), (b"PLTE", b""), (b"IDAT", valid_idat), (b"IEND", b"")),
            "large-plte": document((b"IHDR", header()), (b"PLTE", b"x" * 771), (b"IDAT", valid_idat), (b"IEND", b"")),
            "duplicate-plte": document((b"IHDR", header()), (b"PLTE", b"\0\0\0"), (b"PLTE", b"\0\0\0"), (b"IDAT", valid_idat), (b"IEND", b"")),
            "late-plte": document((b"IHDR", header()), (b"IDAT", valid_idat), (b"PLTE", b"\0\0\0"), (b"IEND", b"")),
            "noncontiguous-idat": document((b"IHDR", header()), (b"IDAT", valid_idat[:8]), (b"tEXt", b"x"), (b"IDAT", valid_idat[8:]), (b"IEND", b"")),
            "nonempty-iend": document((b"IHDR", header()), (b"IDAT", valid_idat), (b"IEND", b"x")),
            "trailing": document((b"IHDR", header()), (b"IDAT", valid_idat), (b"IEND", b""), (b"tEXt", b"x")),
            "missing-idat": document((b"IHDR", header()), (b"IEND", b"")),
            "wrong-size": document((b"IHDR", header()), (b"IDAT", zlib.compress(b"\x00")), (b"IEND", b"")),
            "truncated-zlib": document((b"IHDR", header()), (b"IDAT", valid_idat[:-1]), (b"IEND", b"")),
            "unused-zlib": document((b"IHDR", header()), (b"IDAT", valid_idat + zlib.compress(b"x")), (b"IEND", b"")),
            "declared-small-expansion": document((b"IHDR", header(width=1, height=1)), (b"IDAT", zlib.compress(b"x" * 1_000_000)), (b"IEND", b"")),
            "bad-filter": document((b"IHDR", header()), (b"IDAT", zlib.compress((b"\x05" + valid_row[1:]) * 180)), (b"IEND", b"")),
            "too-many-chunks": document((b"IHDR", header()), *((b"tEXt", b"") for _ in range(capture_module.MAX_PNG_CHUNKS)), (b"IDAT", valid_idat), (b"IEND", b"")),
        }
        for name, content in cases.items():
            path = self.root / f"invalid-{name}.png"
            path.write_bytes(content)
            with self.subTest(name=name), self.assertRaisesRegex(SharedViewCaptureError, "captured image is invalid"):
                _png_snapshot(path)

        oversized = self.root / "oversized.png"
        with oversized.open("wb") as stream:
            stream.truncate(capture_module.MAX_PNG_FILE_BYTES + 1)
        target = self.root / "target.png"
        target.write_bytes(png_bytes())
        symlink = self.root / "symlink.png"
        symlink.symlink_to(target)
        fifo = self.root / "fifo.png"
        os.mkfifo(fifo)
        for path in (oversized, self.root, symlink, fifo):
            with self.subTest(path=path), self.assertRaisesRegex(SharedViewCaptureError, "captured image is invalid"):
                _png_snapshot(path)

    def test_symlink(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        outside = self.root / "outside-resource"
        outside.write_text("mutable external content")
        (self.app / "ExternalResource").symlink_to(outside)

        with self.assertRaisesRegex(SharedViewCaptureError, "app bundle is invalid"):
            self.execute(FakeRunner(), run_id="escaping-symlink")

    def test_bundle_change_after_install_and_private_simulator_identifiers_fail_closed(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner()
        original_run = runner.run

        def mutate_after_install(
            args: list[str], *, timeout: int, environment: dict[str, str] | None = None
        ) -> CommandResult:
            result = original_run(args, timeout=timeout, environment=environment)
            if args[2] == "install":
                (Path(args[-1]) / "ContextPanel").write_bytes(b"changed during install")
            return result

        runner.run = mutate_after_install
        exit_code, receipt = self.execute(runner)
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("capture-app-bundle-changed",) * 2)

        self.write_info_plist("ContextPanel")
        self.write_surface_manifest()
        self.write_config()
        config = json.loads(self.config_path.read_text())
        config["profiles"]["ios"]["runtimeIdentifier"] = "/private/runtime"
        self.config_path.write_text(json.dumps(config))
        with self.assertRaisesRegex(SharedViewCaptureError, "simulator identifier is invalid"):
            self.execute(FakeRunner(), run_id="private-identifier")

    def test_bundle_bounds(self) -> None:
        self.write_config()
        for constant in ("MAX_PLIST_FILE_BYTES", "MAX_BUNDLE_FILE_BYTES", "MAX_BUNDLE_TOTAL_BYTES", "MAX_BUNDLE_ENTRIES"):
            with self.subTest(constant=constant), mock.patch.object(
                capture_module, constant, 1
            ), self.assertRaises(SharedViewCaptureError):
                load_capture_config(self.config_path)

    def test_visionos_config_requires_associated_ui_test_products(self) -> None:
        self.write_config(("visionos",))
        profile = load_capture_config(self.config_path)["visionos"]
        self.assertEqual(self.companion_test_run, profile.ui_test_run)
        self.assertIsNotNone(profile.ui_test_products_sha256)

        config = json.loads(self.config_path.read_text())
        config["profiles"]["visionos"].pop("uiTestRun")
        self.config_path.write_text(json.dumps(config))
        with self.assertRaisesRegex(SharedViewCaptureError, "profile keys"):
            load_capture_config(self.config_path)

        self.write_config(("visionos",))
        config = json.loads(self.config_path.read_text())
        outside_app = self.root / "outside.app"
        shutil.copytree(self.app, outside_app)
        config["profiles"]["visionos"]["appBundle"] = str(outside_app)
        self.config_path.write_text(json.dumps(config))
        with self.assertRaisesRegex(SharedViewCaptureError, "do not contain app bundle"):
            load_capture_config(self.config_path)

        self.write_config(("visionos",))
        self.companion_test_run.write_text("not a plist")
        with self.assertRaisesRegex(SharedViewCaptureError, "UI test run is invalid"):
            load_capture_config(self.config_path)

    def test_ui_test_products_accept_literal_marker_ancestors(self) -> None:
        self.write_config(("visionos",))
        products_root = self.root / "capture__products" / "__TESTHOST__"
        shutil.copytree(self.companion_test_root, products_root)
        config = json.loads(self.config_path.read_text())
        config["profiles"]["visionos"].update(
            appBundle=str(products_root / self.app.relative_to(self.companion_test_root)),
            uiTestRun=str(products_root / self.companion_test_run.name),
        )
        self.config_path.write_text(json.dumps(config))

        profile = load_capture_config(self.config_path)["visionos"]

        self.assertEqual(products_root / self.companion_test_run.name, profile.ui_test_run)
        self.assertIsNotNone(profile.ui_test_products_sha256)

    def test_ui_test_products_reject_unsupported_template_markers(self) -> None:
        self.write_config(("visionos",))
        payload = plistlib.loads(self.companion_test_run.read_bytes())
        payload[capture_module.VISIONOS_UI_TEST_TARGET]["DependentProductPaths"].append(
            "__TESTROOT__/__PLATFORMS__/Existing.app"
        )
        (self.companion_test_root / "__PLATFORMS__" / "Existing.app").mkdir(parents=True)
        self.companion_test_run.write_bytes(plistlib.dumps(payload))

        with self.assertRaisesRegex(SharedViewCaptureError, "UI test run is invalid"):
            load_capture_config(self.config_path)

    def test_ui_test_product_path_checks_remain_enforced(self) -> None:
        products_root = self.root / "bounded-products"
        products_root.mkdir()
        product = products_root / "Existing.app"
        product.mkdir()
        (products_root / "literal__product.app").mkdir()
        outside = self.root / "Outside.app"
        outside.mkdir()
        (products_root / "Link.app").symlink_to(product)
        (products_root / "escaping-ancestor").symlink_to(self.root)
        for template in (
            "__UNKNOWN__/Existing.app",
            "__TESTHOST__/Existing.app",
            "__TESTROOT/Existing.app",
            "__TESTH__TESTROOT__OST__/Existing.app",
            "__TESTROOT__/literal__product.app",
            "Existing.app",
            "__TESTROOT__/Missing.app",
            "__TESTROOT__/../Outside.app",
            "__TESTROOT__/Link.app",
            "__TESTROOT__/escaping-ancestor/Outside.app",
        ):
            with self.subTest(template=template), self.assertRaisesRegex(
                SharedViewCaptureError, "UI test run is invalid"
            ):
                capture_module._resolved_test_product_path(
                    template, products_root, "test product"
                )

    def test_installed(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        installed = self.root / "installed-copy.app"
        shutil.copytree(self.app, installed)
        os.chmod(installed / "ContextPanel", 0o755)
        exit_code, _ = self.execute(
            FakeRunner(container_path=installed),
            run_id="mode-only",
        )
        self.assertEqual(EXIT_OK, exit_code)

        (installed / "unexpected-file").write_text("drift")
        exit_code, receipt = self.execute(
            FakeRunner(container_path=installed),
            run_id="drifted",
        )
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-app-container-mismatch",) * 2)

        profile = load_capture_config(self.config_path)["ios"]
        cases: list[tuple[Runner, str]] = [
            (FakeRunner(container_output=output), "simctl-app-container-invalid")
            for output in (
                "relative", "/tmp/\0bad", f"{installed}\n{installed}", str(installed / "missing")
            )
        ]
        for result in (CommandResult(1, "", ""), CommandResult(124, "", "", timed_out=True)):
            runner = FakeRunner()
            runner.run = mock.Mock(return_value=result)
            cases.append((runner, capture_module._command_error_code(result, "simctl-app-container")))
        for runner, expected in cases:
            self.assertEqual(expected, capture_module._installed_app_error(runner, SIMULATOR_ID, profile))
        with mock.patch.object(capture_module, "_app_metadata", side_effect=SharedViewCaptureError("read")):
            self.assertEqual(
                "simctl-app-container-invalid",
                capture_module._installed_app_error(FakeRunner(container_path=installed), SIMULATOR_ID, profile),
            )

    def test_executable_escape_symlink_and_read_errors_fail_before_catalog(self) -> None:
        self.write_plan(["ios.app"])
        outside = self.root / "outside-executable"
        outside.write_bytes(b"outside")
        self.write_info_plist("../outside-executable")
        self.write_config()
        runner = FakeRunner()
        with self.assertRaisesRegex(SharedViewCaptureError, "executable is invalid"):
            self.execute(runner)
        self.assertEqual([], runner.calls)

        self.write_info_plist("ContextPanelLink")
        (self.app / "ContextPanelLink").symlink_to(self.app / "ContextPanel")
        with self.assertRaisesRegex(SharedViewCaptureError, "executable is invalid"):
            self.execute(runner)
        self.assertEqual([], runner.calls)

        (self.app / "ContextPanelLink").unlink()
        self.write_info_plist("ContextPanel")
        executable = self.app / "ContextPanel"
        os.chmod(executable, 0)
        try:
            with self.assertRaisesRegex(SharedViewCaptureError, "bundle is unreadable"):
                self.execute(runner)
        finally:
            os.chmod(executable, 0o644)
        self.assertEqual([], runner.calls)

    def test_command_stderr_privacy_assertion_is_non_vacuous(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(fail_at="boot")

        _, receipt = self.execute(runner)

        self.assertTrue(runner.private_stderr)
        self.assertTrue(any(result_args[2] == "boot" for result_args, _ in runner.calls))
        serialized = json.dumps(receipt)
        self.assertNotIn(runner.private_stderr, serialized)
        self.assertNotIn("/tmp/capture-secret", serialized)
        self.assertNotIn(SIMULATOR_ID, serialized)

if __name__ == "__main__":
    unittest.main()
