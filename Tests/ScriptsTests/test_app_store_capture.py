"""Capture lifecycle tests use inert bundles and a fake simctl, never host apps."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "app_store_capture", Path(__file__).resolve().parents[2] / "scripts/capture-app-store-screenshots.py")
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class AppStoreCaptureTests(unittest.TestCase):
    def test_existing_output_and_non_capture_bundle_never_launch_a_simulator(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / "existing"
            output.mkdir()
            with patch.object(capture, "run") as run:
                with self.assertRaises(SystemExit):
                    capture.capture("iphone", output)
                run.assert_not_called()
            build = root / "build"
            app = build / "ios/Build/Products/Debug-iphonesimulator/Context Panel.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "unrelated.app"}))
            with patch.object(capture, "BUILD", build), patch.object(capture, "run") as run:
                with self.assertRaises(SystemExit):
                    capture.capture("iphone", root / "new")
                run.assert_not_called()

    def test_failed_install_deletes_only_the_owned_simulator(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            build = root / "build"
            app = build / "ios/Build/Products/Debug-iphonesimulator/Context Panel.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": capture.bundle_id(capture.TARGETS["ios"])}))
            owned = "EBA287F0-39CB-4EE1-AD9B-5C987F5C3783"
            calls = []

            def fake_run(*args, **kwargs):
                calls.append(args)
                if "create" in args:
                    return owned
                if "install" in args:
                    raise subprocess.CalledProcessError(1, args)
                return ""

            with patch.object(capture, "BUILD", build), patch.object(capture, "run", side_effect=fake_run):
                with self.assertRaises(subprocess.CalledProcessError):
                    capture.capture("iphone", root / "output")
            cleanup = [args for args in calls if "delete" in args or "shutdown" in args]
            self.assertEqual([args[-2:] for args in cleanup], [("shutdown", owned), ("delete", owned)])
            self.assertTrue(all(args[:4] == ("xcrun", "simctl", "--set", str(build / "simulators")) for args in calls))
