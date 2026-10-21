"""Capture lifecycle tests use inert bundles and a fake simctl, never host apps."""
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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

    def test_stdout_transport_preserves_binary_bytes_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "image.png"
            payload = b"\x89PNG\r\n\x1a\n\xff\x00"
            capture.run(sys.executable, "-c", "import sys; sys.stdout.buffer.write(bytes.fromhex(sys.argv[1]))",
                        payload.hex(), stdout_path=output)
            self.assertEqual(output.read_bytes(), payload)
            with self.assertRaises(FileExistsError):
                capture.run(sys.executable, "-c", "raise SystemExit(1)", stdout_path=output)
            self.assertEqual(output.read_bytes(), payload)

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
        for failure in ("create", "install"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as folder:
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
                        devices[:] = [entry for entry in devices if entry["udid"] != args[-1]]
                    return ""

                with patch.object(capture, "BUILD", root / "build"), \
                     patch.object(capture, "clean_commit", return_value=self.source), \
                     patch.object(capture, "run", side_effect=fake_run):
                    self.make_bundle()
                    with self.assertRaises(subprocess.CalledProcessError):
                        capture.capture("iphone", root / "output")
                cleanup = [args[-2:] for args in calls if "delete" in args or "shutdown" in args]
                expected = [("shutdown", owned), ("delete", owned)]
                self.assertEqual(cleanup, expected)
                self.assertEqual(len(devices), 1)
                self.assertTrue(all(args[:2] == ("xcrun", "simctl") for args in calls))
                self.assertTrue(all("--set" not in args for args in calls))

    def test_create_cannot_adopt_or_delete_a_preexisting_device(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            foreign = "EBA287F0-39CB-4EE1-AD9B-5C987F5C3783"
            calls = []

            def fake_run(*args, **kwargs):
                calls.append(args)
                if "list" in args:
                    return json.dumps({"devices": {"runtime": [{"udid": foreign, "name": "another session"}]}})
                if "create" in args:
                    return foreign
                self.fail(f"Pre-existing device was acted on: {args}")

            with patch.object(capture, "BUILD", root / "build"), \
                 patch.object(capture, "clean_commit", return_value=self.source), \
                 patch.object(capture, "run", side_effect=fake_run):
                self.make_bundle()
                with self.assertRaisesRegex(RuntimeError, "pre-existing simulator"):
                    capture.capture("iphone", root / "output")
            self.assertFalse((root / "output/capture.json").exists())

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

    def test_success_receipts_require_verified_owned_cleanup(self):
        for fault in ("clean", "missing-identity", "cleanup-error-in-outer-except"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                owned = "EBA287F0-39CB-4EE1-AD9B-5C987F5C3783"
                platform, device, size = capture.PROFILES["iphone"]
                runtime = "com.apple.CoreSimulator.SimRuntime." + capture.RUNTIMES[platform]
                foreign = {"udid": "foreign-device", "name": "another session"}
                devices = [foreign]
                calls = []
                reads = 0

                def fake_run(*args, **kwargs):
                    nonlocal reads
                    calls.append(args)
                    if "list" in args:
                        reads += 1
                        if reads > 1 and fault == "cleanup-error-in-outer-except":
                            raise RuntimeError("cleanup inventory unavailable")
                        return json.dumps({"devices": {runtime: devices}})
                    if "create" in args:
                        devices.append({"udid": owned, "name": args[args.index("create") + 1],
                            "state": "Booted", "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + device})
                        if fault == "missing-identity":
                            devices[-1].pop("deviceTypeIdentifier")
                        return owned
                    if "delete" in args:
                        devices[:] = [entry for entry in devices if entry["udid"] != args[-1]]
                    if "screenshot" in args:
                        self.assertEqual(args[-1], "-")
                        kwargs["stdout_path"].write_bytes(b"\x89PNG\r\n\x1a\n" + bytes(8) + struct.pack(">II", *size))
                    return "fixture"

                with patch.object(capture, "BUILD", root / "build"), \
                     patch.object(capture, "clean_commit", return_value=self.source), \
                     patch.object(capture, "run", side_effect=fake_run), \
                     patch.object(capture.time, "sleep"):
                    self.make_bundle()
                    try:
                        raise ValueError("unrelated caller exception")
                    except ValueError:
                        if fault == "cleanup-error-in-outer-except":
                            with self.assertRaises(RuntimeError):
                                capture.capture("iphone", root / "output")
                        else:
                            capture.capture("iphone", root / "output")
                    receipt = root / "output/capture.json"
                    self.assertEqual(receipt.exists(), fault != "cleanup-error-in-outer-except")
                    if receipt.exists():
                        record = json.loads(receipt.read_text())
                        self.assertEqual(record["simulatorUDID"], owned)
                        self.assertTrue(record["cleanup"])
                    self.assertEqual(devices, [foreign])
                    self.assertEqual([args[-1] for args in calls if "delete" in args], [owned])

    def test_generated_capture_model_is_enforced_before_xcodegen(self):
        original = {"name": "Fixture", "options": {}, "targets": {
            name: {"type": "application", "sources": [], "settings": {"base": {}}}
            for name in set(capture.TARGETS.values())
        }}
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
