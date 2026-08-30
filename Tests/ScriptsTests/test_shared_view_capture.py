import contextlib
from concurrent.futures import ThreadPoolExecutor
import copy
from dataclasses import replace
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import sys
import tempfile
from typing import Any, cast
import unittest
from unittest import mock
import zlib


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import context_panel_validation.cli as cli_module
import context_panel_validation.shared_view_capture as capture_module
from context_panel_validation.models import CommandResult, EXIT_BLOCKED, EXIT_OK, EXIT_UNKNOWN
from context_panel_validation.shared_view_capture import (
    CAPTURE_CONFIG_KIND,
    CAPTURE_RECEIPT_KIND,
    REQUIREMENTS_DIGEST_DOMAIN,
    SharedViewCaptureError,
    _verify_created_simulator,
    execute_shared_view_capture,
    load_capture_config,
    load_capture_requirements,
)
from context_panel_validation.shared_view_evidence import (
    canonical_json_hash,
    load_shared_view_matrix,
    load_surface_policy,
    plan_shared_view_evidence,
)
from context_panel_surface_manifest.core import canonical_json as manifest_canonical_json
from context_panel_surface_manifest.core import hash_parts as manifest_hash_parts
from Tests.ScriptsTests.test_shared_view_evidence import comparison_for


SIMULATOR_ID = "00000000-0000-0000-0000-000000000001"
SECOND_SIMULATOR_ID = "00000000-0000-0000-0000-000000000002"
FIXED_NOW = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
RUNTIME_IDENTIFIERS = {
    "ios": "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
    "ipados": "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
    "visionos": "com.apple.CoreSimulator.SimRuntime.xrOS-26-0",
}
DEVICE_TYPE_IDENTIFIERS = {
    "ios": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
    "ipados": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5",
    "visionos": "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro",
}


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
) -> bytes:
    row = b"\x00" + bytes(color) * width
    return png_document(
        (b"IHDR", png_ihdr(width, height)),
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
        create_result: CommandResult | None = None,
        corrupt_png: str | None = None,
        unstable: bool = False,
        baseline_unstable: bool = False,
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
    ) -> None:
        self.calls: list[tuple[list[str], int]] = []
        self.catalog = catalog or simulator_catalog()
        self.fail_at = fail_at
        self.timeout_at = timeout_at
        self.create_result = create_result
        self.corrupt_png = corrupt_png
        self.unstable = unstable
        self.baseline_unstable = baseline_unstable
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
        self.device_list_calls = 0
        self.active_route: dict[str, str | None] = {}
        self.route_screenshot_counts: dict[str, int] = {}
        self.baseline_screenshot_count = 0
        self.screenshot_destinations_absent: list[bool] = []
        self.created_simulator_id: str | None = None
        self.created_simulator_name: str | None = None
        self.created_device_type: str | None = None
        self.created_runtime: str | None = None
        self.installed_app_bundle: str | None = None
        self.private_stderr = f"private /tmp/capture-secret {SIMULATOR_ID}"

    def run(self, args, *, timeout, environment=None) -> CommandResult:
        del environment
        self.calls.append((args, timeout))
        verb = args[2] if len(args) > 2 else ""
        if self.timeout_at == verb:
            return CommandResult(124, "", self.private_stderr, timed_out=True)
        if self.fail_at == verb:
            return CommandResult(1, "", self.private_stderr)
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
                self.created_simulator_name = args[3]
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
        if args[:3] == ["xcrun", "simctl", "get_app_container"]:
            output = self.container_output or str(self.container_path or self.installed_app_bundle)
            return CommandResult(0, f"{output}\n", "")
        if args[:3] == ["xcrun", "simctl", "terminate"]:
            self.active_route[args[3]] = None
        if args[:3] == ["xcrun", "simctl", "delete"] and not self.persist_after_delete:
            self.created_simulator_id = None
        elif args[:3] == ["xcrun", "simctl", "delete"]:
            self.created_simulator_name = "renamed-after-delete"
        if args[:3] == ["xcrun", "simctl", "openurl"]:
            self.active_route[args[3]] = args[-1]
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

    def _image_for(self, route: str | None) -> bytes:
        baseline_color = (0x11, 0x22, 0x33, 0xFF)
        if route is None:
            count = self.baseline_screenshot_count
            self.baseline_screenshot_count += 1
            if self.baseline_unstable and count % 2 == 1:
                baseline_color = (0x12, 0x22, 0x33, 0xFF)
            return png_bytes(color=baseline_color)
        if self.baseline_equal:
            return png_bytes(color=baseline_color)
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
        return png_bytes(color=color)


class SharedViewCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.directory.name)
        self.app = self.root / "Context Panel.app"
        self.app.mkdir()
        self.current_manifest_path = self.root / "current-manifest.json"
        (self.app / "ContextPanel").write_bytes(b"signed companion executable")
        self.write_info_plist("ContextPanel")
        self.write_surface_manifest()
        self.matrix = load_shared_view_matrix()
        self.policy = load_surface_policy()
        self.comparison_path = self.root / "comparison.json"
        self.requirements_path = self.root / "requirements.json"
        self.config_path = self.root / "capture-config.json"
        self.artifact_root = self.root / "private-artifacts"
        self.receipt_path = self.root / "capture-receipt.json"
        self.sleeps: list[float] = []

    def tearDown(self) -> None:
        self.directory.cleanup()

    def write_info_plist(self, executable: str) -> None:
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.shinycomputers.contextpanel",
                    "CFBundleExecutable": executable,
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "456",
                    "CFBundleSupportedPlatforms": ["iPhoneSimulator", "XRSimulator"],
                    "UIDeviceFamily": [1, 2, 7],
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

    def write_plan(
        self,
        surfaces: list[str],
        *,
        matrix_path: Path | None = None,
        evidence: str = "shared-view",
    ) -> dict[str, Any]:
        selected_surfaces = set(surfaces)
        ordered_surfaces = sorted(selected_surfaces)
        comparison = comparison_for(
            {surface: [evidence] if evidence else [] for surface in ordered_surfaces}
        )
        comparison["currentManifestId"] = self.manifest_id
        matrix = self.matrix if matrix_path is None else load_shared_view_matrix(matrix_path, self.policy)
        payload = plan_shared_view_evidence(comparison, matrix, self.policy)
        self.comparison_path.write_text(json.dumps(comparison))
        self.requirements_path.write_text(json.dumps(payload))
        return payload

    def write_config(self, profile_names: tuple[str, ...] = ("ios",)) -> None:
        profiles = {
            name: {
                "runtimeIdentifier": RUNTIME_IDENTIFIERS[name],
                "deviceTypeIdentifier": DEVICE_TYPE_IDENTIFIERS[name],
                "appBundle": str(self.app),
            }
            for name in profile_names
        }
        self.config_path.write_text(
            json.dumps({"schemaVersion": 1, "kind": CAPTURE_CONFIG_KIND, "profiles": profiles})
        )

    def execute(
        self,
        runner: FakeRunner,
        *,
        run_id: str = "run-fixed",
        matrix_path: Path | None = None,
        receipt_path: Path | None = None,
        surface_policy_path: Path | None = None,
    ) -> tuple[int, dict[str, Any]]:
        return cast(
            tuple[int, dict[str, Any]],
            execute_shared_view_capture(
                self.comparison_path,
                self.current_manifest_path,
                self.requirements_path,
            self.config_path,
            self.artifact_root,
            receipt_path or self.receipt_path,
            runner=runner,
            sleeper=self.sleeps.append,
            now=lambda: FIXED_NOW,
            run_id_factory=lambda: run_id,
            matrix_path=matrix_path or REPO_ROOT / "Config/ContextPanelSharedViewMatrix.json",
            surface_policy_path=surface_policy_path
            or REPO_ROOT / "Config/ContextPanelSurfacePolicy.json",
            ),
        )

    def assert_capture_errors(self, receipt: dict[str, Any], *errors: str) -> None:
        self.assertEqual(list(errors), [item["errorCode"] for item in receipt["captures"]])

    def test_exact_terminate_route_and_stability_command_sequence(self) -> None:
        payload = self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual([1.0] * 8, self.sleeps)
        commands = [args for args, _ in runner.calls]
        requirements = payload["requirements"]
        self.assertEqual(
            [
                "list", "list", "create", "list", "boot", "bootstatus", "install", "get_app_container",
                "ui", "io", "io", "openurl", "io", "io", "terminate",
                "ui", "io", "io", "openurl", "io", "io", "shutdown", "delete", "list", "list",
            ],
            [args[2] for args in commands],
        )
        simulator_name = "ContextPanelSharedView-ios-run-fixed"
        self.assertEqual(
            ["xcrun", "simctl", "create", simulator_name, DEVICE_TYPE_IDENTIFIERS["ios"], RUNTIME_IDENTIFIERS["ios"]],
            commands[2],
        )
        self.assertEqual(["xcrun", "simctl", "list", "-j", "devices", simulator_name], commands[1])
        self.assertEqual(
            [
                ["xcrun", "simctl", "ui", SIMULATOR_ID, "appearance", "light"],
                ["xcrun", "simctl", "ui", SIMULATOR_ID, "appearance", "dark"],
            ],
            [args for args in commands if args[2] == "ui"],
        )
        self.assertEqual(
            [
                "contextpanelcompanion://validation-gallery?fixture=healthy&family=systemMedium&appearance=light&presentation=overview",
                "contextpanelcompanion://validation-gallery?fixture=dense-accounts&family=systemMedium&appearance=dark&presentation=overview",
            ],
            [args[-1] for args in commands if args[2] == "openurl"],
        )
        self.assertEqual([True] * 8, runner.screenshot_destinations_absent)
        self.assertEqual(["captured", "captured"], [item["status"] for item in receipt["captures"]])
        self.assertEqual(
            ["simctl-ui-appearance+gallery-route"] * 2,
            [item["appearanceMechanism"] for item in receipt["captures"]],
        )
        self.assertEqual(
            canonical_json_hash(REQUIREMENTS_DIGEST_DOMAIN, payload),
            receipt["requirementsDigest"],
        )
        self.assertEqual(
            [item["id"] for item in requirements],
            [item["requirementID"] for item in receipt["captures"]],
        )

    def test_run_scoped_artifacts_are_isolated_and_complete(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        first_receipt_path = self.root / "first-receipt.json"
        second_receipt_path = self.root / "second-receipt.json"

        with ThreadPoolExecutor(max_workers=2) as executor:
            first_future = executor.submit(
                self.execute,
                FakeRunner(),
                run_id="run-one",
                receipt_path=first_receipt_path,
            )
            second_future = executor.submit(
                self.execute,
                FakeRunner(),
                run_id="run-two",
                receipt_path=second_receipt_path,
            )
            _, first = first_future.result()
            _, second = second_future.result()

        self.assertEqual("run-one", first["captureRunID"])
        self.assertEqual("run-two", second["captureRunID"])
        first_directory = self.artifact_root / self.manifest_id / "run-one"
        second_directory = self.artifact_root / self.manifest_id / "run-two"
        self.assertTrue((first_directory / "index.json").is_file())
        self.assertTrue((second_directory / "index.json").is_file())
        self.assertFalse((self.artifact_root / self.manifest_id / ".run-one.staging").exists())
        self.assertFalse((self.artifact_root / self.manifest_id / ".run-two.staging").exists())
        self.assertFalse((self.artifact_root / self.manifest_id / "index.json").exists())
        self.assertEqual(first, json.loads((first_directory / "index.json").read_text()))
        self.assertEqual(second, json.loads((second_directory / "index.json").read_text()))
        self.assertEqual(0o700, stat.S_IMODE(self.artifact_root.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(first_directory.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE((first_directory / "index.json").stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE((first_directory / ".capture-owner").stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE(next(first_directory.glob("*.png")).stat().st_mode))
        self.assertEqual(0o644, stat.S_IMODE(first_receipt_path.stat().st_mode))

    def test_catalog_metadata_multi_profile_order_and_public_privacy(self) -> None:
        self.write_plan(["visionos.app", "ipados.app", "ios.app"])
        self.write_config(("visionos", "ios", "ipados"))
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(["ios", "ipados", "visionos"], [item["profile"] for item in receipt["profiles"]])
        self.assertEqual(
            ["ios.app", "ios.app", "ipados.app", "ipados.app", "visionos.app", "visionos.app"],
            [item["surface"] for item in receipt["captures"]],
        )
        ios_profile = receipt["profiles"][0]
        self.assertEqual("iOS 26.0", ios_profile["runtimeName"])
        self.assertEqual("iOS", ios_profile["runtimePlatform"])
        self.assertEqual("iPhone 17", ios_profile["deviceTypeName"])
        self.assertEqual("iPhone", ios_profile["productFamily"])
        self.assertEqual(self.manifest_id, ios_profile["appManifestID"])
        self.assertEqual("deleted", ios_profile["cleanupStatus"])
        self.assertEqual(1, sum(args == ["xcrun", "simctl", "list", "-j"] for args, _ in runner.calls))
        self.assertEqual(12, sum(args[:5] == ["xcrun", "simctl", "list", "-j", "devices"] for args, _ in runner.calls))
        serialized = json.dumps(receipt)
        self.assertNotIn(str(self.app), serialized)
        self.assertNotIn(SIMULATOR_ID, serialized)
        self.assertNotIn(SECOND_SIMULATOR_ID, serialized)
        self.assertNotIn("bundlePath", serialized)
        self.assertNotIn("/private/catalog", serialized)
        self.assertEqual("advisory-only", receipt["pixelDiffPolicy"])

    def test_catalog_profile_mismatch_is_blocked_without_create(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        catalog = simulator_catalog()
        catalog["runtimes"][0]["platform"] = "tvOS"
        runner = FakeRunner(catalog=catalog)

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_BLOCKED, exit_code)
        self.assertEqual(["blocked", "blocked"], [item["status"] for item in receipt["captures"]])
        self.assert_capture_errors(receipt, *("simctl-profile-mismatch",) * 2)
        self.assertEqual(
            ["simctl-profile-validation"] * 2,
            [item["hostMechanism"] for item in receipt["captures"]],
        )
        self.assertEqual("tvOS", receipt["profiles"][0]["runtimePlatform"])
        self.assertEqual("not-started", receipt["profiles"][0]["cleanupStatus"])
        self.assertEqual([["xcrun", "simctl", "list", "-j"]], [args for args, _ in runner.calls])

    def test_catalog_transport_and_parse_failures_are_unknown(self) -> None:
        scenarios = (
            (FakeRunner(fail_at="list"), "simctl-catalog-failed"),
            (FakeRunner(catalog={"not": "a catalog"}), "simctl-catalog-invalid"),
        )
        for index, (runner, error_code) in enumerate(scenarios):
            with self.subTest(error_code=error_code):
                self.write_plan(["ios.app"])
                self.write_config()
                exit_code, receipt = self.execute(
                    runner,
                    run_id=f"catalog-{index}",
                    receipt_path=self.root / f"catalog-{index}.json",
                )
                self.assertEqual(EXIT_UNKNOWN, exit_code)
                self.assertEqual(["unknown", "unknown"], [item["status"] for item in receipt["captures"]])
                self.assert_capture_errors(receipt, error_code, error_code)

    def test_adaptive_appearance_resets_simulator_to_automatic(self) -> None:
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
        ui_commands = [args for args, _ in runner.calls if args[:3] == ["xcrun", "simctl", "ui"]]
        self.assertEqual(
            [
                ["xcrun", "simctl", "ui", SIMULATOR_ID, "appearance", "automatic"],
                ["xcrun", "simctl", "ui", SIMULATOR_ID, "appearance", "dark"],
            ],
            ui_commands,
        )
        self.assertEqual(
            ["simctl-ui-appearance+gallery-route"] * 2,
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

    def test_ambiguous_create_cleanup(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(
            create_result=CommandResult(
                0,
                f"diagnostic\n{SIMULATOR_ID}\nignored\n{SECOND_SIMULATOR_ID}\n",
                "",
            )
        )

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-create-invalid-udid",) * 2)
        self.assertEqual("identity-unverified", receipt["profiles"][0]["cleanupStatus"])
        self.assertFalse(any(args[2] in {"shutdown", "delete"} for args, _ in runner.calls))

    def test_identity_mismatch_cleanup(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(created_device_mismatch=True)

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-created-device-mismatch",) * 2)
        self.assertFalse(any(args[2] == "boot" for args, _ in runner.calls))
        self.assertFalse(any(args[2] in {"shutdown", "delete"} for args, _ in runner.calls))

    def test_identity_validation(self) -> None:
        self.write_config()
        profile = load_capture_config(self.config_path)["ios"]
        name = "ContextPanelSharedView-ios-run-fixed"
        device = {
            "udid": SIMULATOR_ID,
            "name": name,
            "deviceTypeIdentifier": profile.device_type_identifier,
            "isAvailable": True,
        }
        def payload(value, runtime=profile.runtime_identifier):
            return json.dumps({"devices": {runtime: value}})
        cases = (
            (CommandResult(1, "", ""), "simctl-created-device-failed"),
            (CommandResult(124, "", "", timed_out=True), "simctl-created-device-timeout"),
            (CommandResult(0, "not-json", ""), "simctl-created-device-invalid"),
            (CommandResult(0, json.dumps({"devices": []}), ""), "simctl-created-device-invalid"),
            (CommandResult(0, payload({}), ""), "simctl-created-device-invalid"),
            (CommandResult(0, payload([None]), ""), "simctl-created-device-invalid"),
            (CommandResult(0, payload([{**device, "udid": SECOND_SIMULATOR_ID}]), ""), "simctl-created-device-mismatch"),
            (CommandResult(0, payload([device, device]), ""), "simctl-created-device-mismatch"),
            (CommandResult(0, payload([device], RUNTIME_IDENTIFIERS["visionos"]), ""), "simctl-created-device-mismatch"),
            (CommandResult(0, payload([{**device, "deviceTypeIdentifier": DEVICE_TYPE_IDENTIFIERS["ipados"]}]), ""), "simctl-created-device-mismatch"),
            (CommandResult(0, payload([{**device, "isAvailable": False}]), ""), "simctl-created-device-mismatch"),
        )
        for result, expected in cases:
            runner = mock.Mock()
            runner.run.return_value = result
            with self.subTest(expected=expected, stdout=result.stdout):
                self.assertEqual(expected, _verify_created_simulator(runner, profile, name, SIMULATOR_ID))

    def test_invalid_create_cleanup(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(create_result=CommandResult(0, "not-a-udid\n", ""))

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-create-invalid-udid",) * 2)
        self.assertFalse(any(args[2] in {"shutdown", "delete"} for args, _ in runner.calls))

    def test_failed_create_without_device_preserves_error_and_skips_cleanup(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(create_result=CommandResult(1, "", "private create failure"))

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-create-failed",) * 2)
        self.assertEqual("identity-unverified", receipt["profiles"][0]["cleanupStatus"])
        self.assertFalse(any(args[2] in {"shutdown", "delete"} for args, _ in runner.calls))

    def test_failed_create_cleanup(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(
            create_result=CommandResult(1, "", "private create failure"),
            created_on_failed_create=True,
            created_device_available=False,
        )
        exit_code, receipt = self.execute(runner)
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-create-failed",) * 2)
        self.assertEqual("deleted", receipt["profiles"][0]["cleanupStatus"])
        self.assertIn(["xcrun", "simctl", "delete", SIMULATOR_ID], [args for args, _ in runner.calls])

    def test_precreate_inventory(self) -> None:
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
            receipt_path=self.root / "invalid-inventory.json",
        )
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-device-inventory-invalid",) * 2)

    def test_inventory_statuses(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        collision = FakeRunner()
        collision.created_simulator_id = SIMULATOR_ID
        collision.created_simulator_name = "ContextPanelSharedView-ios-collision"
        collision.created_device_type = DEVICE_TYPE_IDENTIFIERS["ios"]
        collision.created_runtime = RUNTIME_IDENTIFIERS["ios"]
        exit_code, receipt = self.execute(
            collision,
            run_id="collision",
            receipt_path=self.root / "collision.json",
        )
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-create-name-collision",) * 2)

        unknown = FakeRunner(
            create_result=CommandResult(1, "", "private failure"),
            device_list_failure=CommandResult(1, "", "private inventory failure"),
            device_list_failure_after=2,
        )
        _, receipt = self.execute(
            unknown,
            run_id="inventory",
            receipt_path=self.root / "inventory.json",
        )
        self.assertEqual("inventory-unknown", receipt["profiles"][0]["cleanupStatus"])

        exit_code, receipt = self.execute(
            FakeRunner(persist_after_delete=True),
            run_id="persisted",
            receipt_path=self.root / "persisted.json",
        )
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual("delete-persisted", receipt["profiles"][0]["cleanupStatus"])
        self.assert_capture_errors(receipt, *("simctl-delete-persisted",) * 2)

    def test_create_timeout_cleanup(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(timeout_at="create")

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-create-timeout",) * 2)
        self.assertEqual("identity-unverified", receipt["profiles"][0]["cleanupStatus"])
        self.assertFalse(any(args[2] in {"shutdown", "delete"} for args, _ in runner.calls))

    def test_cleanup_failure_preserves_the_capture_root_cause(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        exit_code, receipt = self.execute(FakeRunner(timeout_at="boot", fail_at="delete"))
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-boot-timeout",) * 2)
        self.assertEqual("delete-failed", receipt["profiles"][0]["cleanupStatus"])

    def test_duplicate_cleanup_failure(self) -> None:
        self.write_plan(["ios.app", "ipados.app"])
        self.write_config(("ios", "ipados"))
        runner = FakeRunner(cross_profile_duplicates=True)
        original_run = runner.run
        failed_delete = False

        def fail_first_delete(args, *, timeout, environment=None):
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

    def test_delete_failure_removes_artifacts_and_marks_profile_unknown(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(fail_at="delete")

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual(["unknown", "unknown"], [item["status"] for item in receipt["captures"]])
        self.assert_capture_errors(receipt, *("simctl-delete-failed",) * 2)
        self.assertEqual("delete-failed", receipt["profiles"][0]["cleanupStatus"])
        run_directory = self.artifact_root / self.manifest_id / "run-fixed"
        self.assertFalse(list(run_directory.glob("*.png")))
        self.assertTrue((run_directory / "index.json").is_file())

    def test_terminate_failure_is_best_effort_and_later_cell_still_captures(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(fail_at="terminate")

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(["captured", "captured"], [item["status"] for item in receipt["captures"]])
        self.assertTrue(any(args[2] == "terminate" for args, _ in runner.calls))

    def test_comparison_truncation_and_empty_no_work_are_rejected_before_side_effects(self) -> None:
        payload = self.write_plan(["ios.app"])
        self.write_config()
        truncated = copy.deepcopy(payload)
        truncated["requirements"].pop()
        self.requirements_path.write_text(json.dumps(truncated))
        runner = FakeRunner()

        with self.assertRaisesRegex(SharedViewCaptureError, "exactly match"):
            self.execute(runner)

        self.assertEqual([], runner.calls)
        self.assertFalse(self.artifact_root.exists())
        self.assertFalse(self.receipt_path.exists())

        empty_comparison = comparison_for({"ios.app": []})
        empty_payload = plan_shared_view_evidence(empty_comparison, self.matrix, self.policy)
        self.comparison_path.write_text(json.dumps(empty_comparison))
        self.requirements_path.write_text(json.dumps(empty_payload))
        with self.assertRaisesRegex(SharedViewCaptureError, "no planned work"):
            self.execute(runner)
        self.assertEqual([], runner.calls)
        self.assertFalse(self.artifact_root.exists())

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
                receipt_path = self.root / f"scenario-{index}.json"
                self.sleeps.clear()
                exit_code, receipt = self.execute(
                    runner,
                    run_id=f"scenario-{index}",
                    receipt_path=receipt_path,
                )
                self.assertEqual(EXIT_UNKNOWN, exit_code)
                self.assertEqual(["unknown", "unknown"], [item["status"] for item in receipt["captures"]])
                self.assert_capture_errors(receipt, error_code, error_code)
                self.assertFalse(list((self.artifact_root / self.manifest_id / f"scenario-{index}").glob("*.png")))

    def test_cross_duplicates(self) -> None:
        self.write_plan(["ios.app", "ipados.app"])
        self.write_config(("ios", "ipados"))

        exit_code, receipt = self.execute(
            FakeRunner(cross_profile_duplicates=True),
            run_id="cross-dupe",
            receipt_path=self.root / "cross-dupe.json",
        )

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual(
            ["duplicate-artifact-digest"] * 4,
            [item["errorCode"] for item in receipt["captures"]],
        )
        run_directory = self.artifact_root / self.manifest_id / "cross-dupe"
        self.assertFalse(list(run_directory.glob("*.png")))

    def test_durable_publication(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        events: list[str] = []
        fsync_file = capture_module._fsync_file
        fsync_directory = capture_module._fsync_directory
        replace_file = os.replace
        rename_run = capture_module._rename_exclusive

        def record_file(path: Path) -> None:
            events.append("png-fsync")
            fsync_file(path)

        def record_replace(source, destination) -> None:
            if Path(destination).suffix == ".png":
                events.append("png-replace")
            replace_file(source, destination)

        def record_directory(path: Path) -> None:
            if path.name.endswith(".staging") or path == self.artifact_root / self.manifest_id:
                events.append(f"dir-fsync:{path.name}")
            fsync_directory(path)

        def record_rename(source: Path, destination: Path) -> None:
            if source.name.endswith(".staging"):
                events.append("run-rename")
            rename_run(source, destination)

        with mock.patch.object(capture_module, "_fsync_file", side_effect=record_file), mock.patch.object(
            os, "replace", side_effect=record_replace
        ), mock.patch.object(capture_module, "_fsync_directory", side_effect=record_directory), mock.patch.object(
            capture_module, "_rename_exclusive", side_effect=record_rename
        ):
            self.assertEqual(EXIT_OK, self.execute(FakeRunner(), run_id="durable")[0])
        self.assertEqual(
            ["png-fsync", "png-replace"] * 2,
            [event for event in events if event.startswith("png-")],
        )
        rename_index = events.index("run-rename")
        self.assertIn("dir-fsync:.durable.staging", events[4:rename_index])
        self.assertIn(f"dir-fsync:{self.manifest_id}", events[rename_index + 1 :])

    def test_atomic_run_publication_failure_preserves_foreign_run(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        original_replace = os.replace

        def fail_run_publication(source: Path | str, destination: Path | str) -> None:
            if Path(source).name == ".run-fixed.staging":
                Path(destination).mkdir()
                (Path(destination) / "foreign-marker").write_text("owned elsewhere")
                raise OSError("publication failed")
            original_replace(source, destination)

        with mock.patch.object(capture_module, "_rename_exclusive", side_effect=fail_run_publication):
            with self.assertRaisesRegex(SharedViewCaptureError, "publication failed"):
                self.execute(FakeRunner())

        manifest_directory = self.artifact_root / self.manifest_id
        self.assertFalse((manifest_directory / ".run-fixed.staging").exists())
        self.assertTrue((manifest_directory / "run-fixed" / "foreign-marker").is_file())
        self.assertFalse(self.receipt_path.exists())

    def test_receipt_collision(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        self.receipt_path.write_text("foreign")
        with self.assertRaisesRegex(SharedViewCaptureError, "output is unavailable"):
            self.execute(FakeRunner())
        self.assertEqual("foreign", self.receipt_path.read_text())
        self.assertTrue((self.artifact_root / self.manifest_id / "run-fixed").is_dir())

    def test_receipt_rollback(self) -> None:
        with mock.patch.object(capture_module, "_fsync_directory", side_effect=[OSError(), None]) as fsync:
            with self.assertRaisesRegex(SharedViewCaptureError, "output is unavailable"):
                capture_module._atomic_write_json(self.receipt_path, {}, 0o600)
        self.assertFalse(self.receipt_path.exists())
        self.assertEqual(2, fsync.call_count)

    def test_receipt_failure(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        original_atomic_write = capture_module._atomic_write_json

        def fail_public_receipt(path, payload, mode):
            if path == self.receipt_path:
                raise SharedViewCaptureError("public receipt failed")
            original_atomic_write(path, payload, mode)

        with mock.patch.object(capture_module, "_atomic_write_json", side_effect=fail_public_receipt):
            with self.assertRaisesRegex(SharedViewCaptureError, "public receipt failed"):
                self.execute(FakeRunner(), run_id="receipt-fail")
        self.assertTrue((self.artifact_root / self.manifest_id / "receipt-fail").exists())

        manifest_directory = self.artifact_root / self.manifest_id
        original_fsync = capture_module._fsync_directory

        def fail_manifest_fsync(path):
            if path == manifest_directory and (manifest_directory / "fsync-fail").exists():
                raise OSError("manifest fsync failed")
            original_fsync(path)

        with mock.patch.object(capture_module, "_fsync_directory", side_effect=fail_manifest_fsync):
            with self.assertRaisesRegex(SharedViewCaptureError, "publication failed"):
                self.execute(
                    FakeRunner(),
                    run_id="fsync-fail",
                    receipt_path=self.root / "fsync-fail.json",
                )
        self.assertFalse((manifest_directory / "fsync-fail").exists())

    def test_artifact_cleanup(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        original_replace = os.replace

        def fail_png_publish(source, destination):
            if Path(destination).suffix == ".png":
                raise OSError("png publish failed")
            original_replace(source, destination)

        with mock.patch.object(os, "replace", side_effect=fail_png_publish):
            exit_code, receipt = self.execute(
                FakeRunner(), run_id="png-publish", receipt_path=self.root / "png-publish.json"
            )
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("artifact-publish-failed",) * 2)

        original_unlink = Path.unlink

        def fail_final_artifact(path, *args, **kwargs):
            if path.suffix == ".png" and not path.name.startswith("."):
                raise OSError("artifact cleanup failed")
            return original_unlink(path, *args, **kwargs)

        with mock.patch.object(Path, "unlink", fail_final_artifact):
            exit_code, receipt = self.execute(
                FakeRunner(fail_at="delete"),
                run_id="cleanup-fail",
                receipt_path=self.root / "cleanup-fail.json",
            )
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        composite = "delete-failed-and-artifact-cleanup-failed"
        self.assertEqual(composite, receipt["profiles"][0]["cleanupStatus"])
        self.assert_capture_errors(receipt, *(f"simctl-{composite}",) * 2)

        with self.assertRaisesRegex(SharedViewCaptureError, "identifier is invalid"):
            self.execute(FakeRunner(), run_id="invalid/id")
        manifest_directory = self.artifact_root / self.manifest_id
        collision = manifest_directory / "collision"
        collision.mkdir(mode=0o700)
        with self.assertRaisesRegex(SharedViewCaptureError, "not unique"):
            self.execute(
                FakeRunner(), run_id="collision", receipt_path=self.root / "collision.json"
            )

    def test_run_setup_rollback(self) -> None:
        manifest_directory = self.artifact_root / self.manifest_id
        manifest_directory.mkdir(parents=True)
        with mock.patch.object(
            capture_module, "_fsync_directory", side_effect=OSError()
        ), self.assertRaisesRegex(SharedViewCaptureError, "run directory is unavailable"):
            capture_module._create_run_directories(manifest_directory, lambda: "setup-fsync")
        self.assertFalse((manifest_directory / ".setup-fsync.staging").exists())
        shutil.rmtree(self.artifact_root)

        self.write_plan(["ios.app"])
        self.write_config()
        original_open = os.open
        remove_tree = shutil.rmtree

        def fail_owner_open(path, flags, mode=0o777, **kwargs):
            if Path(path).name == ".capture-owner":
                raise OSError()
            return original_open(path, flags, mode, **kwargs)

        def fail_staging_remove(path, *args, **kwargs):
            if Path(path).name == ".setup-rollback.staging":
                raise OSError()
            return remove_tree(path, *args, **kwargs)

        for run_id, message, remove in (
            ("setup-owner", "ownership marker is unavailable", remove_tree),
            ("setup-rollback", "run rollback failed", fail_staging_remove),
        ):
            with mock.patch.object(os, "open", side_effect=fail_owner_open), mock.patch.object(
                shutil, "rmtree", side_effect=remove
            ), self.assertRaisesRegex(SharedViewCaptureError, message):
                self.execute(FakeRunner(), run_id=run_id, receipt_path=self.root / f"{run_id}.json")
        self.assertFalse((manifest_directory / ".setup-owner.staging").exists())

    def test_private_artifact_directories_are_created_securely_without_rewriting_existing_root(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        self.artifact_root = self.root / "new-parent" / "private-artifacts"
        receipt_parent = self.root / "receipt-parent"
        with mock.patch.object(
            capture_module, "_fsync_directory", wraps=capture_module._fsync_directory
        ) as fsync:
            exit_code, _ = self.execute(
                FakeRunner(), receipt_path=receipt_parent / "receipt.json"
            )
        fsynced = {call.args[0] for call in fsync.call_args_list}
        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(0o700, stat.S_IMODE((self.root / "new-parent").stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(self.artifact_root.stat().st_mode))
        self.assertIn(self.root / "new-parent", fsynced)
        self.assertIn(receipt_parent, fsynced)

        existing_root = self.root / "existing-shared-root"
        existing_root.mkdir(mode=0o755)
        os.chmod(existing_root, 0o755)
        self.artifact_root = existing_root
        runner = FakeRunner()
        with self.assertRaisesRegex(SharedViewCaptureError, "permissions are invalid"):
            self.execute(
                runner,
                run_id="permissions-fail",
                receipt_path=self.root / "permissions-fail.json",
            )
        self.assertEqual(0o755, stat.S_IMODE(existing_root.stat().st_mode))
        self.assertEqual([], runner.calls)

        unsafe_parent = self.root / "unsafe-parent"
        unsafe_parent.mkdir(mode=0o777)
        os.chmod(unsafe_parent, 0o777)
        self.artifact_root = unsafe_parent / "private"
        with self.assertRaisesRegex(SharedViewCaptureError, "ancestry is unsafe"):
            self.execute(FakeRunner(), run_id="unsafe-ancestor", receipt_path=self.root / "unsafe.json")

        self.artifact_root = self.root / "wrong-owner-root"
        with mock.patch.object(os, "geteuid", return_value=os.geteuid() + 1):
            with self.assertRaisesRegex(SharedViewCaptureError, "permissions are invalid"):
                self.execute(FakeRunner(), run_id="owner-fail", receipt_path=self.root / "owner.json")
    def test_path_overlap(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner()
        self.artifact_root = self.app / "capture-artifacts"
        with self.assertRaisesRegex(SharedViewCaptureError, "overlap an app bundle"):
            self.execute(runner, run_id="artifact-overlap")
        self.assertEqual([], runner.calls)

        self.artifact_root = self.root / "private-artifacts-overlap"
        with self.assertRaisesRegex(SharedViewCaptureError, "overlap an app bundle"):
            self.execute(
                runner,
                run_id="output-overlap",
                receipt_path=self.app / "capture-receipt.json",
            )
        self.assertEqual([], runner.calls)

        with self.assertRaisesRegex(SharedViewCaptureError, "overlap a capture input"):
            self.execute(
                runner,
                run_id="input-overwrite",
                receipt_path=self.current_manifest_path,
            )
        self.assertEqual([], runner.calls)

    def test_bundle_symlink_escape(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        outside = self.root / "outside-resource"
        outside.write_text("mutable external content")
        (self.app / "ExternalResource").symlink_to(outside)

        with self.assertRaisesRegex(SharedViewCaptureError, "app bundle is invalid"):
            self.execute(FakeRunner(), run_id="escaping-symlink")

    def test_noncanonical_policy(self) -> None:
        policy_path = self.root / "custom-surface-policy.json"
        policy_path.write_bytes(
            (REPO_ROOT / "Config/ContextPanelSurfacePolicy.json").read_bytes()
        )
        self.write_plan(["ios.app"])
        self.write_config()

        with self.assertRaisesRegex(SharedViewCaptureError, "canonical surface policy"):
            self.execute(
                FakeRunner(),
                run_id="custom-policy",
                surface_policy_path=policy_path,
            )

    def test_app_identity(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner()

        def mutate_manifest(key, value):
            self.write_surface_manifest()
            source = json.loads(self.current_manifest_path.read_text())
            source[key] = value
            source["manifestId"] = manifest_hash_parts(
                f"{source['digestDomain']}/manifest",
                [manifest_canonical_json({k: v for k, v in source.items() if k != "manifestId"})],
            )
            self.current_manifest_path.write_text(json.dumps(source))

        for key, value, run_id in (
            ("digestDomain", "attacker-controlled/v1", "manifest-domain"),
            ("schemaVersion", True, "manifest-schema-bool"),
        ):
            mutate_manifest(key, value)
            with self.assertRaisesRegex(SharedViewCaptureError, "current surface manifest is invalid"):
                self.execute(runner, run_id=run_id)

        self.write_surface_manifest()
        for key, value, message, run_id in (
            ("CFBundleShortVersionString", "1.2.4", "version does not match", "version-mismatch"),
            ("CFBundleSupportedPlatforms", ["XRSimulator"], "platform metadata is invalid", "platform-mismatch"),
        ):
            self.write_info_plist("ContextPanel")
            with (self.app / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            info[key] = value
            with (self.app / "Info.plist").open("wb") as stream:
                plistlib.dump(info, stream)
            with self.assertRaisesRegex(SharedViewCaptureError, message):
                self.execute(runner, run_id=run_id)
        self.assertEqual([], runner.calls)

    def test_capture_app_manifest_must_match_current_comparison(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner()

        manifest_path = self.app / "ContextPanelSurfaceManifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest.pop("contractFingerprint")
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(SharedViewCaptureError, "surface manifest is invalid"):
            self.execute(runner)

        self.write_surface_manifest()
        manifest = json.loads(manifest_path.read_text())
        manifest["surfaces"][0]["fingerprints"]["render"] = "9" * 64
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(SharedViewCaptureError, "surface manifest does not match"):
            self.execute(runner)

        self.write_surface_manifest("f" * 64)
        with self.assertRaisesRegex(SharedViewCaptureError, "manifest identity is invalid"):
            self.execute(runner)

        self.assertEqual([], runner.calls)
        self.assertFalse(self.artifact_root.exists())
        self.assertFalse(self.receipt_path.exists())

    def test_json_inputs_are_bounded(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        with self.current_manifest_path.open("wb") as stream:
            stream.truncate(capture_module.MAX_JSON_FILE_BYTES + 1)
        with self.assertRaisesRegex(SharedViewCaptureError, "unavailable or invalid"):
            self.execute(FakeRunner(), run_id="oversized-json")

    def test_bundle_change_after_install_and_private_simulator_identifiers_fail_closed(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner()
        original_run = runner.run

        def mutate_after_install(args, *, timeout, environment=None):
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
    def test_snapshot_failures(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        with mock.patch.object(shutil, "copytree", side_effect=OSError("copy failed")):
            with self.assertRaisesRegex(SharedViewCaptureError, "snapshot failed"):
                self.execute(FakeRunner(), run_id="copy-fail")

        app_metadata = capture_module._app_metadata
        calls = 0

        def drift_snapshot(path, profile_name):
            nonlocal calls
            calls += 1
            identity = app_metadata(path, profile_name)
            return (*identity[:2], "f" * 64, *identity[3:]) if calls == 2 else identity

        with mock.patch.object(
            capture_module, "_app_metadata", side_effect=drift_snapshot
        ), self.assertRaisesRegex(SharedViewCaptureError, "snapshot identity changed"):
            self.execute(FakeRunner(), run_id="drift")

        remove_tree = shutil.rmtree

        def retain_snapshot(path, *args, **kwargs):
            if Path(path).name == ".ios-install.app":
                return None
            return remove_tree(path, *args, **kwargs)

        with mock.patch.object(
            shutil, "rmtree", side_effect=retain_snapshot
        ), self.assertRaisesRegex(SharedViewCaptureError, "snapshot cleanup failed"):
            self.execute(FakeRunner(), run_id="cleanup")

    def test_exception_cleanup(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner()
        original_run = runner.run

        def remove_manifest_after_install(args, *, timeout, environment=None):
            result = original_run(args, timeout=timeout, environment=environment)
            if args[2] == "install":
                (Path(args[-1]) / "ContextPanelSurfaceManifest.json").unlink()
            return result

        runner.run = remove_manifest_after_install
        with self.assertRaisesRegex(SharedViewCaptureError, "surface manifest is invalid"):
            self.execute(runner, run_id="exception-cleanup")
        self.assertIn(["xcrun", "simctl", "delete", SIMULATOR_ID], [args for args, _ in runner.calls])

    def test_cleanup_failure(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner()
        original_run = runner.run

        def fail_after_create_and_delete(args, *, timeout, environment=None):
            result = original_run(args, timeout=timeout, environment=environment)
            if args[2] == "install":
                (Path(args[-1]) / "ContextPanelSurfaceManifest.json").unlink()
            if args[2] == "delete":
                runner.created_simulator_id = SIMULATOR_ID
                return CommandResult(1, "", "private cleanup failure")
            return result

        runner.run = fail_after_create_and_delete
        with self.assertRaisesRegex(
            SharedViewCaptureError,
            "emergency simulator cleanup did not complete: simctl-delete-failed",
        ):
            self.execute(runner, run_id="exception-cleanup-failure")

    def test_installed_identity(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        installed = self.root / "installed-copy.app"
        shutil.copytree(self.app, installed)
        os.chmod(installed / "ContextPanel", 0o755)
        exit_code, _ = self.execute(
            FakeRunner(container_path=installed),
            run_id="mode-only",
            receipt_path=self.root / "mode-only.json",
        )
        self.assertEqual(EXIT_OK, exit_code)

        (installed / "unexpected-file").write_text("drift")
        exit_code, receipt = self.execute(
            FakeRunner(container_path=installed),
            run_id="drifted",
            receipt_path=self.root / "drifted.json",
        )
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assert_capture_errors(receipt, *("simctl-app-container-mismatch",) * 2)

        profile = load_capture_config(self.config_path)["ios"]
        cases = [(FakeRunner(container_output=output), "simctl-app-container-invalid") for output in (
            "relative", f"{installed}\n{installed}", str(installed / "missing")
        )]
        for result in (CommandResult(1, "", ""), CommandResult(124, "", "", timed_out=True)):
            runner = mock.Mock(run=mock.Mock(return_value=result))
            cases.append((runner, capture_module._command_error_code(result, "simctl-app-container")))
        for runner, expected in cases:
            self.assertEqual(expected, capture_module._installed_app_error(runner, SIMULATOR_ID, profile))
        with mock.patch.object(capture_module, "_app_metadata", side_effect=SharedViewCaptureError("read")):
            self.assertEqual(
                "simctl-app-container-invalid",
                capture_module._installed_app_error(FakeRunner(container_path=installed), SIMULATOR_ID, profile),
            )

    def test_nondefault_accessibility_fails_closed_before_capture(self) -> None:
        ios = next(surface for surface in self.matrix.surfaces if surface.id == "ios.app")
        modified = replace(ios, cells=(replace(ios.cells[0], accessibility="xxxl"), *ios.cells[1:]))
        modified_matrix = replace(
            self.matrix,
            surfaces=tuple(modified if surface.id == "ios.app" else surface for surface in self.matrix.surfaces),
        )
        comparison = comparison_for({"ios.app": ["shared-view"]})
        payload = plan_shared_view_evidence(comparison, modified_matrix, self.policy)
        self.requirements_path.write_text(json.dumps(payload))

        with self.assertRaisesRegex(SharedViewCaptureError, "accessibility context is unsupported"):
            load_capture_requirements(self.requirements_path, payload, modified_matrix, self.policy)

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

    def test_public_bundle_version_metadata_is_bounded_and_numeric(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.shinycomputers.contextpanel",
                    "CFBundleExecutable": "ContextPanel",
                    "CFBundleShortVersionString": "/private/secret",
                    "CFBundleVersion": "456",
                },
                stream,
            )
        runner = FakeRunner()

        with self.assertRaisesRegex(SharedViewCaptureError, "version metadata"):
            self.execute(runner)

        self.assertEqual([], runner.calls)
        self.assertFalse(self.receipt_path.exists())

    def test_bool_schema_versions_are_rejected(self) -> None:
        payload = self.write_plan(["ios.app"])
        self.write_config()
        config = json.loads(self.config_path.read_text())
        config["schemaVersion"] = True
        self.config_path.write_text(json.dumps(config))
        with self.assertRaisesRegex(SharedViewCaptureError, "config identity"):
            self.execute(FakeRunner())

        self.write_config()
        payload["schemaVersion"] = True
        self.requirements_path.write_text(json.dumps(payload))
        with self.assertRaisesRegex(SharedViewCaptureError, "requirements identity"):
            self.execute(FakeRunner())

    def test_unsupported_and_unconfigured_requirements_are_blocked_without_simctl(self) -> None:
        self.write_plan(["macos.app", "watchos.app", "tvos.app", "ios.app"])
        self.write_config(())
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_BLOCKED, exit_code)
        self.assertEqual([], runner.calls)
        self.assertEqual(8, len(receipt["captures"]))
        summary = [
            (item["surface"], item["errorCode"], item["hostMechanism"])
            for item in receipt["captures"]
        ]
        unsupported = "unsupported-host-mechanism"
        self.assertEqual(2, summary.count(("ios.app", "profile-not-configured", "unconfigured-profile")))
        for surface in ("macos.app", "tvos.app", "watchos.app"):
            self.assertEqual(2, summary.count((surface, unsupported, unsupported)))

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

    def test_cli_requires_comparison_and_never_touches_coordinator_state(self) -> None:
        receipt = {
            "schemaVersion": 1,
            "kind": CAPTURE_RECEIPT_KIND,
            "captureRunID": "run-fixed",
            "currentManifestID": self.manifest_id,
            "requirementsDigest": "c" * 64,
            "matrixDigest": "b" * 64,
            "pixelDiffPolicy": "advisory-only",
            "profiles": [],
            "captures": [],
        }
        arguments = [
            "capture-shared-view-evidence",
            "--surface-comparison",
            str(self.comparison_path),
            "--current-manifest",
            str(self.current_manifest_path),
            "--requirements",
            str(self.requirements_path),
            "--capture-config",
            str(self.config_path),
            "--artifact-root",
            str(self.artifact_root),
            "--output",
            str(self.receipt_path),
            "--json",
        ]
        coordinator = mock.Mock(side_effect=AssertionError("coordinator state must not be touched"))
        with (
            mock.patch.object(cli_module, "execute_shared_view_capture", return_value=(EXIT_OK, receipt)) as execute,
            mock.patch.object(cli_module, "SessionStateStore", coordinator),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            self.assertEqual(EXIT_OK, cli_module.main(arguments))
        execute.assert_called_once_with(
            self.comparison_path,
            self.current_manifest_path,
            self.requirements_path,
            self.config_path,
            self.artifact_root,
            self.receipt_path,
            matrix_path=cli_module.DEFAULT_MATRIX_PATH,
            surface_policy_path=cli_module.DEFAULT_SURFACE_POLICY_PATH,
        )
        self.assertIn(CAPTURE_RECEIPT_KIND, output.getvalue())
        coordinator.assert_not_called()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                cli_module.parse_args([item for item in arguments if item not in {"--surface-comparison", str(self.comparison_path)}])

    def test_cli_forwards_custom_matrix_and_surface_policy(self) -> None:
        matrix_path = self.root / "matrix.json"
        policy_path = self.root / "policy.json"
        receipt = {"kind": CAPTURE_RECEIPT_KIND}
        arguments = [
            "capture-shared-view-evidence",
            "--surface-comparison",
            str(self.comparison_path),
            "--current-manifest",
            str(self.current_manifest_path),
            "--requirements",
            str(self.requirements_path),
            "--capture-config",
            str(self.config_path),
            "--artifact-root",
            str(self.artifact_root),
            "--output",
            str(self.receipt_path),
            "--matrix",
            str(matrix_path),
            "--surface-policy",
            str(policy_path),
            "--json",
        ]
        with (
            mock.patch.object(cli_module, "execute_shared_view_capture", return_value=(EXIT_OK, receipt)) as execute,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(EXIT_OK, cli_module.main(arguments))
        execute.assert_called_once_with(
            self.comparison_path,
            self.current_manifest_path,
            self.requirements_path,
            self.config_path,
            self.artifact_root,
            self.receipt_path,
            matrix_path=matrix_path,
            surface_policy_path=policy_path,
        )

if __name__ == "__main__":
    unittest.main()
