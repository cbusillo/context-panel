import contextlib
from concurrent.futures import ThreadPoolExecutor
import copy
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
from typing import Any, cast
import unittest
from unittest import mock
import zlib


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_comparison_schema import derive_risk_fields, derive_runtime_decision
import context_panel_validation.cli as cli_module
from context_panel_validation.models import CommandResult, EXIT_BLOCKED, EXIT_OK, EXIT_UNKNOWN
from context_panel_validation.shared_view_capture import (
    CAPTURE_CONFIG_KIND,
    CAPTURE_RECEIPT_KIND,
    REQUIREMENTS_DIGEST_DOMAIN,
    SharedViewCaptureError,
    execute_shared_view_capture,
)
from context_panel_validation.shared_view_evidence import (
    canonical_json_hash,
    load_shared_view_matrix,
    load_surface_policy,
    plan_shared_view_evidence,
)


MANIFEST_ID = "a" * 64
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


def png_bytes(
    width: int = 320,
    height: int = 180,
    color: tuple[int, int, int, int] = (0x22, 0x66, 0xAA, 0xFF),
) -> bytes:
    ihdr = (
        width.to_bytes(4, "big")
        + height.to_bytes(4, "big")
        + b"\x08\x06\x00\x00\x00"
    )
    row = b"\x00" + bytes(color) * width
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(row * height))
        + png_chunk(b"IEND", b"")
    )


def invalid_idat_png_bytes(width: int = 320, height: int = 180) -> bytes:
    ihdr = (
        width.to_bytes(4, "big")
        + height.to_bytes(4, "big")
        + b"\x08\x06\x00\x00\x00"
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", b"not-zlib-data")
        + png_chunk(b"IEND", b"")
    )


def comparison_for(surface_evidence: dict[str, list[str]]) -> dict[str, Any]:
    surfaces: list[dict[str, Any]] = []
    for surface_id, fresh_evidence in surface_evidence.items():
        surfaces.append(
            {
                "surfaceId": surface_id,
                "artifactId": surface_id,
                "reasonCodes": ["exact-build-changed"],
                "changes": {
                    "render": False,
                    "runtime": False,
                    "placement": False,
                    "contract": False,
                    "exactBuild": True,
                },
                "minimumEvidence": [],
                "freshEvidence": fresh_evidence,
                "requiredEvidence": fresh_evidence,
                "carryForward": {
                    evidence_class: {"eligible": False, "conditions": []}
                    for evidence_class in fresh_evidence
                },
            }
        )
    required_surfaces = {
        evidence_class: [
            surface_id
            for surface_id, evidence in surface_evidence.items()
            if evidence_class in evidence
        ]
        for evidence_class in (
            "shared-view",
            "actual-runtime",
            "os-composited-placement",
        )
    }
    runtime_state, runtime_state_reasons = derive_runtime_decision(surfaces)
    risk_codes, risk_surfaces, observation_risk_codes = derive_risk_fields(
        surfaces,
        toolchain_delta=False,
        runtime_capable_surface_ids={
            surface["surfaceId"]
            for surface in surfaces
            if "actual-runtime" in surface["carryForward"]
        },
        requires_placement_review=bool(required_surfaces["os-composited-placement"]),
    )
    return {
        "kind": "context-panel-surface-comparison",
        "schemaVersion": 5,
        "train": "beta",
        "previousManifestId": "b" * 64,
        "currentManifestId": MANIFEST_ID,
        "contractChanged": False,
        "exactBuildSame": False,
        "removedSurfaces": [],
        "requiredSurfaces": required_surfaces,
        "requiresRuntimeSession": bool(required_surfaces["actual-runtime"]),
        "requiresPlacementReview": bool(required_surfaces["os-composited-placement"]),
        "toolchainChanged": False,
        "artifactEvidence": {
            "previousState": "complete",
            "currentState": "complete",
            "previousExpectedBuildIds": ["b" * 64],
            "currentExpectedBuildIds": ["c" * 64],
        },
        "artifactRiskCodes": [],
        "artifactRiskSurfaces": {},
        "escalationState": "resolved",
        "surfaces": surfaces,
        "releaseRequiresApprovedRCTarget": True,
        "runtimeState": runtime_state,
        "runtimeStateReasons": runtime_state_reasons,
        "riskCodes": risk_codes,
        "riskSurfaces": risk_surfaces,
        "observationRiskCodes": observation_risk_codes,
    }


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
        baseline_equal: bool = False,
        duplicate_routes: bool = False,
    ) -> None:
        self.calls: list[tuple[list[str], int]] = []
        self.catalog = catalog or simulator_catalog()
        self.fail_at = fail_at
        self.timeout_at = timeout_at
        self.create_result = create_result
        self.corrupt_png = corrupt_png
        self.unstable = unstable
        self.baseline_equal = baseline_equal
        self.duplicate_routes = duplicate_routes
        self.active_route: dict[str, str | None] = {}
        self.route_screenshot_counts: dict[str, int] = {}
        self.screenshot_destinations_absent: list[bool] = []
        self.private_stderr = f"private /tmp/capture-secret {SIMULATOR_ID}"

    def run(self, args, *, timeout, environment=None) -> CommandResult:
        del environment
        self.calls.append((args, timeout))
        verb = args[2] if len(args) > 2 else ""
        if self.timeout_at == verb:
            return CommandResult(124, "", self.private_stderr, timed_out=True)
        if self.fail_at == verb:
            return CommandResult(1, "", self.private_stderr)
        if args[:4] == ["xcrun", "simctl", "list", "-j"]:
            return CommandResult(0, json.dumps(self.catalog), "")
        if args[:3] == ["xcrun", "simctl", "create"]:
            if self.create_result is not None:
                return self.create_result
            self.active_route[SIMULATOR_ID] = None
            return CommandResult(0, SIMULATOR_ID + "\n", "")
        if args[:3] == ["xcrun", "simctl", "terminate"]:
            self.active_route[args[3]] = None
        if args[:3] == ["xcrun", "simctl", "openurl"]:
            self.active_route[args[3]] = args[-1]
        if args[:4] == ["xcrun", "simctl", "io", args[3] if len(args) > 3 else ""]:
            route = self.active_route.get(args[3])
            image = self._image_for(route)
            if route is not None and self.corrupt_png == "crc":
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
        if route is None or self.baseline_equal:
            return png_bytes(color=baseline_color)
        if self.duplicate_routes:
            color = (0x44, 0x55, 0x66, 0xFF)
        else:
            digest = hashlib.sha256(route.encode()).digest()
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
        (self.app / "ContextPanel").write_bytes(b"signed companion executable")
        self.write_info_plist("ContextPanel")
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
                },
                stream,
            )

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
    ) -> tuple[int, dict[str, Any]]:
        return cast(
            tuple[int, dict[str, Any]],
            execute_shared_view_capture(
            self.comparison_path,
            self.requirements_path,
            self.config_path,
            self.artifact_root,
            receipt_path or self.receipt_path,
            runner=runner,
            sleeper=self.sleeps.append,
            now=lambda: FIXED_NOW,
            run_id_factory=lambda: run_id,
            matrix_path=matrix_path or REPO_ROOT / "Config/ContextPanelSharedViewMatrix.json",
            ),
        )

    def test_exact_terminate_route_and_stability_command_sequence(self) -> None:
        payload = self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual([1.0, 1.0, 1.0, 1.0], self.sleeps)
        commands = [args for args, _ in runner.calls]
        normalized = [
            args[:5] + ["<temporary-png>"]
            if args[:3] == ["xcrun", "simctl", "io"]
            else args
            for args in commands
        ]
        requirements = payload["requirements"]
        self.assertEqual(
            [
                ["xcrun", "simctl", "list", "-j"],
                [
                    "xcrun",
                    "simctl",
                    "create",
                    "ContextPanelSharedView-ios-run-fixed",
                    DEVICE_TYPE_IDENTIFIERS["ios"],
                    RUNTIME_IDENTIFIERS["ios"],
                ],
                ["xcrun", "simctl", "boot", SIMULATOR_ID],
                ["xcrun", "simctl", "bootstatus", SIMULATOR_ID, "-b"],
                ["xcrun", "simctl", "install", SIMULATOR_ID, str(self.app)],
                ["xcrun", "simctl", "ui", SIMULATOR_ID, "appearance", "light"],
                ["xcrun", "simctl", "io", SIMULATOR_ID, "screenshot", "<temporary-png>"],
                [
                    "xcrun",
                    "simctl",
                    "openurl",
                    SIMULATOR_ID,
                    "contextpanelcompanion://validation-gallery?fixture=healthy&family=systemMedium&appearance=light&presentation=overview",
                ],
                ["xcrun", "simctl", "io", SIMULATOR_ID, "screenshot", "<temporary-png>"],
                ["xcrun", "simctl", "io", SIMULATOR_ID, "screenshot", "<temporary-png>"],
                ["xcrun", "simctl", "terminate", SIMULATOR_ID, "com.shinycomputers.contextpanel"],
                ["xcrun", "simctl", "ui", SIMULATOR_ID, "appearance", "dark"],
                ["xcrun", "simctl", "io", SIMULATOR_ID, "screenshot", "<temporary-png>"],
                [
                    "xcrun",
                    "simctl",
                    "openurl",
                    SIMULATOR_ID,
                    "contextpanelcompanion://validation-gallery?fixture=dense-accounts&family=systemMedium&appearance=dark&presentation=overview",
                ],
                ["xcrun", "simctl", "io", SIMULATOR_ID, "screenshot", "<temporary-png>"],
                ["xcrun", "simctl", "io", SIMULATOR_ID, "screenshot", "<temporary-png>"],
                ["xcrun", "simctl", "shutdown", SIMULATOR_ID],
                ["xcrun", "simctl", "delete", SIMULATOR_ID],
            ],
            normalized,
        )
        self.assertEqual([True] * 6, runner.screenshot_destinations_absent)
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
        first_directory = self.artifact_root / MANIFEST_ID / "run-one"
        second_directory = self.artifact_root / MANIFEST_ID / "run-two"
        self.assertTrue((first_directory / "index.json").is_file())
        self.assertTrue((second_directory / "index.json").is_file())
        self.assertFalse((self.artifact_root / MANIFEST_ID / ".run-one.staging").exists())
        self.assertFalse((self.artifact_root / MANIFEST_ID / ".run-two.staging").exists())
        self.assertFalse((self.artifact_root / MANIFEST_ID / "index.json").exists())
        self.assertEqual(first, json.loads((first_directory / "index.json").read_text()))
        self.assertEqual(second, json.loads((second_directory / "index.json").read_text()))
        self.assertEqual(0o700, stat.S_IMODE(self.artifact_root.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(first_directory.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE((first_directory / "index.json").stat().st_mode))
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
        self.assertEqual("deleted", ios_profile["cleanupStatus"])
        self.assertEqual(1, sum(args[:4] == ["xcrun", "simctl", "list", "-j"] for args, _ in runner.calls))
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
        self.assertEqual(["simctl-profile-mismatch"] * 2, [item["errorCode"] for item in receipt["captures"]])
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
                self.assertEqual([error_code, error_code], [item["errorCode"] for item in receipt["captures"]])

    def test_adaptive_appearance_uses_route_without_simctl_ui(self) -> None:
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
        self.assertEqual([["xcrun", "simctl", "ui", SIMULATOR_ID, "appearance", "dark"]], ui_commands)
        self.assertEqual("gallery-route", receipt["captures"][0]["appearanceMechanism"])
        self.assertEqual("simctl-ui-appearance+gallery-route", receipt["captures"][1]["appearanceMechanism"])

    def test_timeout_codes_are_distinct_and_appearance_is_null_before_application(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(timeout_at="boot")

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual(["simctl-boot-timeout"] * 2, [item["errorCode"] for item in receipt["captures"]])
        self.assertEqual([None, None], [item["appearanceMechanism"] for item in receipt["captures"]])
        self.assertIn(["xcrun", "simctl", "delete", SIMULATOR_ID], [args for args, _ in runner.calls])

    def test_successful_multiline_create_uses_last_valid_udid_for_cleanup(self) -> None:
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

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(["captured", "captured"], [item["status"] for item in receipt["captures"]])
        self.assertEqual(
            ["xcrun", "simctl", "delete", SECOND_SIMULATOR_ID],
            [args for args, _ in runner.calls][-1],
        )

    def test_invalid_create_output_cleans_up_by_unique_name(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(create_result=CommandResult(0, "not-a-udid\n", ""))

        exit_code, receipt = self.execute(runner)

        simulator_name = "ContextPanelSharedView-ios-run-fixed"
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual(["simctl-create-invalid-udid"] * 2, [item["errorCode"] for item in receipt["captures"]])
        self.assertEqual(["xcrun", "simctl", "shutdown", simulator_name], [args for args, _ in runner.calls][-2])
        self.assertEqual(["xcrun", "simctl", "delete", simulator_name], [args for args, _ in runner.calls][-1])

    def test_failed_create_without_device_preserves_error_and_skips_cleanup(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(create_result=CommandResult(1, "", "private create failure"))

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual(["simctl-create-failed"] * 2, [item["errorCode"] for item in receipt["captures"]])
        self.assertEqual("not-created", receipt["profiles"][0]["cleanupStatus"])
        self.assertFalse(any(args[2] in {"shutdown", "delete"} for args, _ in runner.calls))

    def test_create_timeout_cleans_up_by_unique_name(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(timeout_at="create")

        exit_code, receipt = self.execute(runner)

        simulator_name = "ContextPanelSharedView-ios-run-fixed"
        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual(["simctl-create-timeout"] * 2, [item["errorCode"] for item in receipt["captures"]])
        self.assertEqual(["xcrun", "simctl", "shutdown", simulator_name], [args for args, _ in runner.calls][-2])
        self.assertEqual(["xcrun", "simctl", "delete", simulator_name], [args for args, _ in runner.calls][-1])

    def test_delete_failure_removes_artifacts_and_marks_profile_unknown(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        runner = FakeRunner(fail_at="delete")

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual(["unknown", "unknown"], [item["status"] for item in receipt["captures"]])
        self.assertEqual(["simctl-delete-failed"] * 2, [item["errorCode"] for item in receipt["captures"]])
        self.assertEqual("delete-failed", receipt["profiles"][0]["cleanupStatus"])
        run_directory = self.artifact_root / MANIFEST_ID / "run-fixed"
        self.assertFalse(list(run_directory.glob("*.png")))
        self.assertTrue((run_directory / "index.json").is_file())

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
                self.assertEqual([error_code, error_code], [item["errorCode"] for item in receipt["captures"]])
                self.assertFalse(list((self.artifact_root / MANIFEST_ID / f"scenario-{index}").glob("*.png")))

    def test_complete_png_crc_truncation_and_idat_validation(self) -> None:
        for index, corruption in enumerate(("crc", "truncated", "idat")):
            with self.subTest(corruption=corruption):
                self.write_plan(["ios.app"])
                self.write_config()
                exit_code, receipt = self.execute(
                    FakeRunner(corrupt_png=corruption),
                    run_id=f"corrupt-{index}",
                    receipt_path=self.root / f"corrupt-{index}.json",
                )
                self.assertEqual(EXIT_UNKNOWN, exit_code)
                self.assertEqual("captured-image-invalid", receipt["captures"][0]["errorCode"])

    def test_atomic_run_publication_failure_leaves_no_run_or_receipt(self) -> None:
        self.write_plan(["ios.app"])
        self.write_config()
        original_replace = os.replace

        def fail_run_publication(source: Path | str, destination: Path | str) -> None:
            if Path(source).name == ".run-fixed.staging":
                raise OSError("publication failed")
            original_replace(source, destination)

        with mock.patch.object(os, "replace", side_effect=fail_run_publication):
            with self.assertRaisesRegex(SharedViewCaptureError, "publication failed"):
                self.execute(FakeRunner())

        manifest_directory = self.artifact_root / MANIFEST_ID
        self.assertFalse((manifest_directory / ".run-fixed.staging").exists())
        self.assertFalse((manifest_directory / "run-fixed").exists())
        self.assertFalse(self.receipt_path.exists())

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
            with self.assertRaisesRegex(SharedViewCaptureError, "executable is unreadable"):
                self.execute(runner)
        finally:
            os.chmod(executable, 0o644)
        self.assertEqual([], runner.calls)

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
        self.assertEqual(["blocked"] * 8, [item["status"] for item in receipt["captures"]])
        self.assertEqual(2, sum(item["errorCode"] == "profile-not-configured" for item in receipt["captures"]))

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
            "currentManifestID": MANIFEST_ID,
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
            self.requirements_path,
            self.config_path,
            self.artifact_root,
            self.receipt_path,
            matrix_path=matrix_path,
            surface_policy_path=policy_path,
        )


if __name__ == "__main__":
    unittest.main()
