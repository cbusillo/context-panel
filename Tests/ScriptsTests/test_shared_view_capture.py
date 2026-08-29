import contextlib
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
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_validation import cli as cli_module
from context_panel_validation.models import CommandResult, EXIT_BLOCKED, EXIT_OK, EXIT_UNKNOWN
from context_panel_validation.shared_view_capture import (
    CAPTURE_CONFIG_KIND,
    CAPTURE_RECEIPT_KIND,
    PNG_SIGNATURE,
    SharedViewCaptureError,
    execute_shared_view_capture,
    shared_view_requirement_id,
)
from context_panel_validation.shared_view_evidence import (
    fixture_contract_id,
    load_shared_view_matrix,
    load_surface_policy,
)


MANIFEST_ID = "a" * 64
SIMULATOR_ID = "00000000-0000-0000-0000-000000000001"
FIXED_NOW = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)


def png_bytes(width: int = 320, height: int = 180) -> bytes:
    return (
        PNG_SIGNATURE
        + (13).to_bytes(4, "big")
        + b"IHDR"
        + width.to_bytes(4, "big")
        + height.to_bytes(4, "big")
        + b"\x08\x06\x00\x00\x00"
    )


class FakeRunner:
    def __init__(self, *, fail_at: str | None = None, invalid_png: bool = False) -> None:
        self.calls: list[tuple[list[str], int]] = []
        self.fail_at = fail_at
        self.invalid_png = invalid_png

    def run(self, args, *, timeout, environment=None):
        self.calls.append((args, timeout))
        verb = args[2] if len(args) > 2 else ""
        if self.fail_at == verb:
            return CommandResult(1, "", "private command failure")
        if args[:3] == ["xcrun", "simctl", "create"]:
            return CommandResult(0, SIMULATOR_ID, "")
        if args[:4] == ["xcrun", "simctl", "io", SIMULATOR_ID]:
            Path(args[-1]).write_bytes(b"invalid" if self.invalid_png else png_bytes())
        return CommandResult(0, "", "")


class SharedViewCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.directory.name)
        self.app = self.root / "Context Panel.app"
        self.app.mkdir()
        (self.app / "ContextPanel").write_bytes(b"signed companion executable")
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.shinycomputers.contextpanel",
                    "CFBundleExecutable": "ContextPanel",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "456",
                },
                stream,
            )
        self.matrix = load_shared_view_matrix()
        self.policy = load_surface_policy()
        self.cells = {
            surface.id: {cell.id: cell for cell in surface.cells}
            for surface in self.matrix.surfaces
        }
        self.policy_by_id = {surface.id: surface for surface in self.policy}
        self.requirements_path = self.root / "requirements.json"
        self.config_path = self.root / "capture-config.json"
        self.artifact_root = self.root / "private-artifacts"
        self.receipt_path = self.root / "capture-receipt.json"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def requirement(self, surface: str, cell_id: str = "baseline") -> dict:
        cell = self.cells[surface][cell_id]
        policy_surface = self.policy_by_id[surface]
        return {
            "id": shared_view_requirement_id(surface, cell_id),
            "evidenceClass": "shared-view",
            "surface": surface,
            "fixtureContractID": fixture_contract_id(self.matrix, policy_surface, cell),
            "presentation": cell.presentation,
            "appearance": cell.appearance,
            "accessibility": cell.accessibility,
            "hostOS": None,
            "presentationFamily": None,
            "placementHost": None,
        }

    def write_requirements(self, surfaces: list[str]) -> None:
        requirements = [self.requirement(surface) for surface in surfaces]
        self.requirements_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "kind": "context-panel-visual-review-requirements",
                    "currentManifestID": MANIFEST_ID,
                    "requirements": requirements,
                }
            )
        )

    def write_config(self, profiles: dict | None = None) -> None:
        if profiles is None:
            profiles = {
                "ios": {
                    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                    "appBundle": str(self.app),
                }
            }
        self.config_path.write_text(
            json.dumps({"schemaVersion": 1, "kind": CAPTURE_CONFIG_KIND, "profiles": profiles})
        )

    def execute(self, runner: FakeRunner):
        return execute_shared_view_capture(
            self.requirements_path,
            self.config_path,
            self.artifact_root,
            self.receipt_path,
            runner=runner,
            sleeper=self.sleeps.append,
            now=lambda: FIXED_NOW,
        )

    @property
    def sleeps(self) -> list[float]:
        if not hasattr(self, "_sleeps"):
            self._sleeps: list[float] = []
        return self._sleeps

    def test_supported_profiles_capture_in_exact_command_and_url_order(self) -> None:
        self.write_requirements(["ios.app", "ios.widget"])
        self.write_config()
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_OK, exit_code)
        self.assertEqual(CAPTURE_RECEIPT_KIND, receipt["kind"])
        self.assertEqual("advisory-only", receipt["pixelDiffPolicy"])
        self.assertEqual([1.0, 1.0], self.sleeps)
        commands = [args for args, _ in runner.calls]
        self.assertEqual(
            [
                [
                    "xcrun",
                    "simctl",
                    "create",
                    "ContextPanelSharedView-ios",
                    "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                    "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
                ],
                ["xcrun", "simctl", "boot", SIMULATOR_ID],
                ["xcrun", "simctl", "bootstatus", SIMULATOR_ID, "-b"],
                ["xcrun", "simctl", "install", SIMULATOR_ID, str(self.app)],
                ["xcrun", "simctl", "ui", SIMULATOR_ID, "appearance", "light"],
                [
                    "xcrun",
                    "simctl",
                    "openurl",
                    SIMULATOR_ID,
                    "contextpanelcompanion://validation-gallery?fixture=healthy&family=systemMedium&appearance=light&presentation=overview",
                ],
            ],
            commands[:6],
        )
        self.assertEqual(["xcrun", "simctl", "io", SIMULATOR_ID, "screenshot"], commands[6][:5])
        self.assertEqual(
            ["xcrun", "simctl", "ui", SIMULATOR_ID, "appearance", "light"], commands[7]
        )
        self.assertEqual(
            "contextpanelcompanion://validation-gallery?fixture=healthy&family=systemSmall&appearance=light&presentation=widget",
            commands[8][-1],
        )
        self.assertEqual(["xcrun", "simctl", "io", SIMULATOR_ID, "screenshot"], commands[9][:5])
        self.assertEqual(["xcrun", "simctl", "shutdown", SIMULATOR_ID], commands[10])
        self.assertEqual(["xcrun", "simctl", "delete", SIMULATOR_ID], commands[11])
        self.assertTrue(all(command[:2] == ["xcrun", "simctl"] for command in commands))
        self.assertFalse(any("devicectl" in command for command in commands))
        self.assertEqual(["captured", "captured"], [item["status"] for item in receipt["captures"]])
        self.assertEqual(320, receipt["captures"][0]["pixelWidth"])
        self.assertEqual(180, receipt["captures"][0]["pixelHeight"])
        self.assertEqual(0o700, stat.S_IMODE(self.artifact_root.stat().st_mode))
        manifest_directory = self.artifact_root / MANIFEST_ID
        self.assertEqual(0o700, stat.S_IMODE(manifest_directory.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE((manifest_directory / "index.json").stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE((manifest_directory / "shared-view.ios-app.baseline.png").stat().st_mode))
        self.assertEqual(0o644, stat.S_IMODE(self.receipt_path.stat().st_mode))

    def test_receipt_is_public_and_binds_app_metadata_without_paths_or_udids(self) -> None:
        self.write_requirements(["ios.app"])
        self.write_config()
        _, receipt = self.execute(FakeRunner())

        profile = receipt["profiles"][0]
        self.assertEqual("ios", profile["profile"])
        self.assertEqual("com.shinycomputers.contextpanel", profile["appBundleIdentifier"])
        self.assertEqual(hashlib.sha256((self.app / "ContextPanel").read_bytes()).hexdigest(), profile["appExecutableSHA256"])
        self.assertEqual("1.2.3", profile["appVersion"])
        self.assertEqual("456", profile["appBuild"])
        serialized = json.dumps(receipt)
        self.assertNotIn(str(self.app), serialized)
        self.assertNotIn(SIMULATOR_ID, serialized)
        self.assertNotIn("DEVELOPER_DIR", serialized)
        self.assertNotIn("private command failure", serialized)

    def test_contract_mismatch_aborts_before_commands_artifacts_or_receipt(self) -> None:
        self.write_requirements(["ios.app"])
        payload = json.loads(self.requirements_path.read_text())
        payload["requirements"][0]["fixtureContractID"] = "b" * 64
        self.requirements_path.write_text(json.dumps(payload))
        self.write_config()
        runner = FakeRunner()

        with self.assertRaisesRegex(SharedViewCaptureError, "contract"):
            self.execute(runner)

        self.assertEqual([], runner.calls)
        self.assertFalse(self.artifact_root.exists())
        self.assertFalse(self.receipt_path.exists())

    def test_unsupported_hosts_are_explicit_and_nonzero_without_commands(self) -> None:
        self.write_requirements(["macos.app", "watchos.app", "tvos.app"])
        self.write_config({})
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_BLOCKED, exit_code)
        self.assertEqual([], runner.calls)
        self.assertEqual(
            ["unsupported-host-mechanism"] * 3,
            [capture["hostMechanism"] for capture in receipt["captures"]],
        )
        self.assertEqual(["blocked"] * 3, [capture["status"] for capture in receipt["captures"]])

    def test_unconfigured_supported_profile_is_explicit_and_nonzero(self) -> None:
        self.write_requirements(["ios.app"])
        self.write_config({})
        runner = FakeRunner()

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_BLOCKED, exit_code)
        self.assertEqual([], runner.calls)
        self.assertEqual("profile-not-configured", receipt["captures"][0]["errorCode"])

    def test_invalid_png_is_unknown_and_deletes_throwaway_simulator(self) -> None:
        self.write_requirements(["ios.app"])
        self.write_config()
        runner = FakeRunner(invalid_png=True)

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual("captured-image-invalid", receipt["captures"][0]["errorCode"])
        commands = [args for args, _ in runner.calls]
        self.assertIn(["xcrun", "simctl", "shutdown", SIMULATOR_ID], commands)
        self.assertIn(["xcrun", "simctl", "delete", SIMULATOR_ID], commands)
        self.assertFalse(list((self.artifact_root / MANIFEST_ID).glob("*.png")))

    def test_boot_failure_deletes_throwaway_simulator(self) -> None:
        self.write_requirements(["ios.app"])
        self.write_config()
        runner = FakeRunner(fail_at="boot")

        exit_code, receipt = self.execute(runner)

        self.assertEqual(EXIT_UNKNOWN, exit_code)
        self.assertEqual("simctl-boot-failed", receipt["captures"][0]["errorCode"])
        self.assertEqual(
            ["xcrun", "simctl", "delete", SIMULATOR_ID], [args for args, _ in runner.calls][-1]
        )

    def test_invalid_config_and_private_root_rejections_write_nothing(self) -> None:
        self.write_requirements(["ios.app"])
        self.config_path.write_text(json.dumps({"schemaVersion": 1, "kind": CAPTURE_CONFIG_KIND, "profiles": {}, "extra": True}))
        runner = FakeRunner()

        with self.assertRaises(SharedViewCaptureError):
            self.execute(runner)

        self.assertEqual([], runner.calls)
        self.assertFalse(self.artifact_root.exists())
        self.assertFalse(self.receipt_path.exists())
        self.write_config()
        with self.assertRaisesRegex(SharedViewCaptureError, "outside the repository"):
            execute_shared_view_capture(
                self.requirements_path,
                self.config_path,
                REPO_ROOT / "private-artifacts",
                self.receipt_path,
                runner=runner,
                sleeper=lambda _: None,
                now=lambda: FIXED_NOW,
            )
        symlink_root = self.root / "artifact-link"
        symlink_root.symlink_to(self.root / "target", target_is_directory=True)
        with self.assertRaisesRegex(SharedViewCaptureError, "symlinks"):
            execute_shared_view_capture(
                self.requirements_path,
                self.config_path,
                symlink_root,
                self.receipt_path,
                runner=runner,
                sleeper=lambda _: None,
                now=lambda: FIXED_NOW,
            )

    def test_cli_success_failure_and_no_coordinator_state(self) -> None:
        receipt = {
            "schemaVersion": 1,
            "kind": CAPTURE_RECEIPT_KIND,
            "currentManifestID": MANIFEST_ID,
            "matrixDigest": "b" * 64,
            "pixelDiffPolicy": "advisory-only",
            "profiles": [],
            "captures": [],
        }
        arguments = [
            "capture-shared-view-evidence",
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
            mock.patch.object(cli_module, "execute_shared_view_capture", return_value=(EXIT_OK, receipt)),
            mock.patch.object(cli_module, "SessionStateStore", coordinator),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            self.assertEqual(EXIT_OK, cli_module.main(arguments))
        self.assertIn(CAPTURE_RECEIPT_KIND, output.getvalue())
        coordinator.assert_not_called()
        with mock.patch.object(cli_module, "execute_shared_view_capture", return_value=(EXIT_BLOCKED, receipt)):
            self.assertEqual(EXIT_BLOCKED, cli_module.main(arguments))


if __name__ == "__main__":
    unittest.main()
