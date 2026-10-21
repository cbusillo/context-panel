"""Capture lifecycle tests use inert bundles and a fake simctl, never host apps."""
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
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

    def test_staging_copies_valid_png_and_falls_back_only_on_temp_save_refusal(self):
        for outcome in ("success", "temp-refused", "other-error", "container-refused", "invalid-png", "wrong-size"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                container = root / "owned-container"
                (container / "tmp").mkdir(parents=True)
                data = b"\x89PNG\r\n\x1a\n" + bytes(8) + struct.pack(">II", 7, 9)
                stages = []
                saves = 0

                def fake_run(*args, **kwargs):
                    nonlocal saves
                    if args[0] == "mktemp":
                        stage = (Path(args[2]).parent if len(args) > 2 else root) / f"stage-{len(stages)}"
                        stage.mkdir(mode=0o700)
                        stages.append(stage)
                        return str(stage)
                    if "get_app_container" in args:
                        self.assertEqual(args[-3:-1], ("owned", "fixture-app"))
                        return str(container)
                    if "screenshot" in args:
                        saves += 1
                        if outcome in {"temp-refused", "container-refused"} and (saves == 1 or outcome == "container-refused"):
                            raise subprocess.CalledProcessError(1, args, stderr="domain=NSCocoaErrorDomain, code=513")
                        if outcome == "other-error":
                            raise subprocess.CalledProcessError(1, args, stderr="unrelated failure")
                        self.assertEqual(args[args.index("io") + 1], "owned")
                        payload = data[:16] + struct.pack(">II", 8, 9) if outcome == "wrong-size" else data
                        Path(args[-1]).write_bytes(b"invalid" if outcome == "invalid-png" else payload)
                    return ""

                output = root / "external.png"
                with patch.object(capture, "run", side_effect=fake_run):
                    if outcome in {"other-error", "container-refused"}:
                        with self.assertRaises(subprocess.CalledProcessError):
                            capture.capture_png(("xcrun", "simctl"), "owned", "fixture-app", output, (7, 9))
                    elif outcome in {"invalid-png", "wrong-size"}:
                        with self.assertRaises(SystemExit):
                            capture.capture_png(("xcrun", "simctl"), "owned", "fixture-app", output, (7, 9))
                    else:
                        capture.capture_png(("xcrun", "simctl"), "owned", "fixture-app", output, (7, 9))
                        self.assertEqual(output.read_bytes(), data)
                self.assertEqual(saves, 2 if outcome in {"temp-refused", "container-refused"} else 1)
                if len(stages) > 1:
                    self.assertTrue(stages[1].is_relative_to(container / "tmp"))
                self.assertTrue(all(not stage.exists() for stage in stages))
                self.assertEqual(output.exists(), outcome in {"success", "temp-refused"})

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
                with self.assertRaises(RuntimeError):
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
                    if args[0] == "mktemp":
                        stage = root / f"stage-{len(calls)}"
                        stage.mkdir()
                        return str(stage)
                    if "spawn" in args:
                        return "active fixture scene: " + args[-1].split('"')[-2]
                    if "screenshot" in args:
                        Path(args[-1]).write_bytes(b"\x89PNG\r\n\x1a\n" + bytes(8) + struct.pack(">II", *size))
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

    def test_temporary_cleanup_failure_preserves_the_original_save_error(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            stage = root / "stage"
            stage.mkdir()
            (stage / "unexpected-sidecar").write_text("preserve")
            refusal = subprocess.CalledProcessError(1, "screenshot", stderr="permission denied")
            with patch.object(capture, "run", side_effect=[str(stage), refusal]):
                with self.assertRaises(subprocess.CalledProcessError) as failure:
                    capture.staged_png(("fake",), "owned", (7, 9))
            self.assertIs(failure.exception, refusal)
            self.assertTrue(failure.exception.__notes__)
            self.assertTrue((stage / "unexpected-sidecar").exists())

    def test_scene_readiness_requires_the_current_launch_and_keeps_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "scene.log"
            with patch.object(capture, "run", side_effect=["active fixture scene: older", "active fixture scene: current"]), \
                 patch.object(capture.time, "sleep"):
                capture.wait_for_scene(("fake",), "owned", "current", log)
            self.assertIn("older", log.read_text())
            self.assertIn("current", log.read_text())
            with patch.object(capture, "run", return_value="active fixture scene: older"), \
                 patch.object(capture.time, "monotonic", side_effect=[0, 181]):
                with self.assertRaises(RuntimeError):
                    capture.wait_for_scene(("fake",), "owned", "current", log)
            with patch.object(capture, "run", side_effect=subprocess.CalledProcessError(1, "log", stderr="permission denied")):
                with self.assertRaises(subprocess.CalledProcessError):
                    capture.wait_for_scene(("fake",), "owned", "current", log)

    def test_native_mac_capture_refuses_local_ui_before_any_command(self):
        with patch.dict(capture.os.environ, {}, clear=True), patch.object(capture, "run") as run:
            with self.assertRaises(SystemExit):
                capture.hosted_macos_capture(Path("unused-output"))
            run.assert_not_called()

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
