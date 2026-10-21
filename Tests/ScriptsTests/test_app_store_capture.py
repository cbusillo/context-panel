"""Capture lifecycle tests use inert bundles and a fake simctl, never host apps."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

SPEC = importlib.util.spec_from_file_location(
    "app_store_capture", Path(__file__).resolve().parents[2] / "scripts/capture-app-store-screenshots.py")
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class AppStoreCaptureTests(unittest.TestCase):
    source = "fixture-source"

    def make_bundle(self, identifier=None):
        app = capture.app_path("ios")
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":
            identifier or capture.bundle_id(capture.TARGETS["ios"])}))
        capture.build_receipt("ios").write_text(json.dumps({
            "sourceCommit": self.source, "bundleSHA256": capture.bundle_digest(app)}))
        return app

    def test_existing_output_and_non_capture_bundle_never_launch_a_simulator(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / "existing"
            output.mkdir()
            with patch.object(capture, "run") as run:
                with self.assertRaises(SystemExit):
                    capture.capture("iphone", output)
                run.assert_not_called()
            with patch.object(capture, "BUILD", root / "build"), \
                 patch.object(capture, "clean_commit", return_value=self.source), \
                 patch.object(capture, "run") as run:
                self.make_bundle(identifier="unrelated.app")
                with self.assertRaises(SystemExit):
                    capture.capture("iphone", root / "new")
                run.assert_not_called()

    def test_failed_create_and_install_delete_only_newly_observed_owned_device(self):
        for failure, private_default in (("create", False), ("install", False), ("create", True), ("install", True)):
            with self.subTest(failure=failure, private_default=private_default), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                owned = "EBA287F0-39CB-4EE1-AD9B-5C987F5C3783"
                calls = []
                platform, device, _ = capture.PROFILES["iphone"]
                runtime = "com.apple.CoreSimulator.SimRuntime." + capture.RUNTIMES[platform]
                devices = [{"udid": "foreign-device", "name": "another session"}]

                def fake_run(*args, **kwargs):
                    calls.append(args)
                    if "list" in args:
                        return json.dumps({"devices": {runtime: devices}})
                    if "create" in args:
                        devices.append({"udid": owned, "name": args[args.index("create") + 1], "state": "Creating",
                            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + device})
                    if failure in args:
                        raise subprocess.CalledProcessError(1, args)
                    if "create" in args:
                        return owned
                    if "boot" in args:
                        devices[-1]["state"] = "Booted"
                    if "delete" in args:
                        devices.pop()
                    return ""

                device_set = None if private_default else root / "owned-set"
                with patch.object(capture, "BUILD", root / "build"), \
                     patch.object(capture, "clean_commit", return_value=self.source), \
                     patch.object(capture, "run", side_effect=fake_run):
                    self.make_bundle()
                    with self.assertRaises(subprocess.CalledProcessError):
                        capture.capture("iphone", root / "output", device_set)
                cleanup = [args[-2:] for args in calls if "delete" in args or "shutdown" in args]
                expected = [("delete", owned)] if failure == "create" else [("shutdown", owned), ("delete", owned)]
                self.assertEqual(cleanup, expected)
                self.assertEqual(len(devices), 1)
                prefix = ("xcrun", "simctl") if private_default else ("xcrun", "simctl", "--set", str(device_set))
                self.assertTrue(all(args[:len(prefix)] == prefix for args in calls))
                if private_default:
                    self.assertTrue(all("--set" not in args for args in calls))

    def test_changed_source_or_bundle_cannot_be_captured_under_an_old_build_receipt(self):
        for change in ("source", "bundle"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                with patch.object(capture, "BUILD", root / "build"), \
                     patch.object(capture, "clean_commit", return_value=self.source if change == "bundle" else "different-source"), \
                     patch.object(capture, "run") as run:
                    app = self.make_bundle()
                    if change == "bundle":
                        (app / "changed-artifact").write_bytes(b"changed after build")
                    with self.assertRaises(SystemExit):
                        capture.capture("iphone", root / "output")
                    run.assert_not_called()

    def test_relative_device_set_has_no_side_effects(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(capture, "run") as run:
            output = Path(folder) / "output"
            with self.assertRaises(SystemExit):
                capture.capture("iphone", output, Path("relative-device-set"))
            self.assertFalse(output.exists())
            run.assert_not_called()

    def test_cleanup_failure_keeps_the_original_create_error(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            reads = 0

            def fake_run(*args, **kwargs):
                nonlocal reads
                if "list" in args:
                    reads += 1
                    if reads > 1:
                        raise RuntimeError("cleanup inventory unavailable")
                    return json.dumps({"devices": {}})
                raise subprocess.CalledProcessError(13, args)

            with patch.object(capture, "BUILD", root / "build"), \
                 patch.object(capture, "clean_commit", return_value=self.source), \
                 patch.object(capture, "run", side_effect=fake_run):
                self.make_bundle()
                with self.assertRaises(subprocess.CalledProcessError) as failure:
                    capture.capture("iphone", root / "output")
                self.assertTrue(failure.exception.__notes__)

    def test_generated_capture_model_is_enforced_before_xcodegen(self):
        original = yaml.safe_load((capture.ROOT / "project.yml").read_text())
        for fault in ("embed", "signing", "configuration", "source-plist"):
            with self.subTest(fault=fault):
                model = capture.capture_spec(original)
                capture.validate_capture_spec(model)
                target = next(iter(model["targets"].values()))
                if fault == "embed":
                    target["dependencies"].append({"target": "unexpected-extension", "embed": True})
                elif fault == "signing":
                    target["settings"]["base"]["CODE_SIGN_ENTITLEMENTS"] = "unexpected.entitlements"
                elif fault == "configuration":
                    target["settings"]["configs"] = {"Release": {"CODE_SIGN_ENTITLEMENTS": "unexpected.entitlements"}}
                else:
                    target["info"] = {"path": "Config/source.plist"}
                with self.assertRaises(ValueError):
                    capture.validate_capture_spec(model)
