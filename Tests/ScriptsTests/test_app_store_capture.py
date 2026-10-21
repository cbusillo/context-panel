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

    def make_bundle(self, identifier=None, platform="ios"):
        app = capture.app_path(platform)
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":
            identifier or capture.bundle_id(capture.TARGETS["ios"])}))
        products = capture.BUILD / platform / "Build/Products"
        runner = products / ("Debug-" + capture.SDKS[platform]) / "CompanionCaptureUITests-Runner.app"
        runner.mkdir()
        (runner / "fixture").write_text("fixture runner")
        (products / "CompanionCapture_fixture.xctestrun").write_bytes(plistlib.dumps({"CompanionCaptureUITests": {
            "BlueprintName": "CompanionCaptureUITests", "IsUITestBundle": True,
            "UITargetAppPath": "__TESTROOT__/" + app.relative_to(products).as_posix()}}))
        capture.build_receipt(platform).write_text(json.dumps({
            "sourceCommit": self.source, "bundleSHA256": capture.bundle_digest(app), "uiTesting": capture.companion_testing_identity(platform)}))
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
        for failure in ("create", "boot"):
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
                    if "screenshot" in args:
                        Path(args[-1]).write_bytes(b"\x89PNG\r\n\x1a\n" + bytes(8) + struct.pack(">II", *size))
                    return "fixture"

                with patch.object(capture, "BUILD", root / "build"), \
                     patch.object(capture, "clean_commit", return_value=self.source), \
                     patch.object(capture, "run", side_effect=fake_run), \
                     patch.object(capture.time, "sleep"), \
                     patch.object(capture, "native_companion_capture", side_effect=lambda udid, detail, directory, path, size, **kwargs: path.write_bytes(b"\x89PNG\r\n\x1a\n" + bytes(8) + struct.pack(">II", *size))):
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

    def test_native_ui_run_configuration_supports_both_xcode_formats_and_refuses_other_apps(self):
        for version in (1, 2):
            for other_app in (False, True):
                with self.subTest(version=version, other_app=other_app):
                    target = {"BlueprintName": "CompanionCaptureUITests", "IsUITestBundle": True,
                              "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/" + ("Other.app" if other_app else "Context Panel.app")}
                    configuration = {"CompanionCaptureUITests": target} if version == 1 else {"TestConfigurations": [{"TestTargets": [target]}]}
                    if other_app:
                        with self.assertRaises(RuntimeError):
                            capture.configure_companion_test_run(configuration, True)
                    else:
                        capture.configure_companion_test_run(configuration, True)
                        self.assertEqual(target["EnvironmentVariables"]["CP_CAPTURE_DETAIL"], "true")
                        capture.configure_companion_test_run(configuration, False)
                        self.assertEqual(target["EnvironmentVariables"]["CP_CAPTURE_DETAIL"], "false")
                        for mode in ("place", "present"):
                            capture.configure_companion_test_run(configuration, False, mode)
                            self.assertEqual(target["EnvironmentVariables"]["CP_CAPTURE_WIDGET"], mode)
                            with self.assertRaises(ValueError):
                                capture.configure_companion_test_run(configuration, True, mode)
                        with self.assertRaises(ValueError):
                            capture.configure_companion_test_run(configuration, False, "unrelated")

    def test_native_ui_capture_removes_temporary_configuration_and_rejects_wrong_dimensions(self):
        for outcome in ("success", "test-failure", "wrong-size"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                with patch.object(capture, "BUILD", root / "build"):
                    self.make_bundle()
                    products = capture.BUILD / "ios/Build/Products"
                    (products / "capture-stale.xctestrun").write_text("unrelated incomplete run")
                    temporary = []
                    def fake_run(*args, **kwargs):
                        if args[0] == "xcodebuild":
                            configured = Path(args[args.index("-xctestrun") + 1])
                            temporary.append(configured)
                            target = plistlib.loads(configured.read_bytes())["CompanionCaptureUITests"]
                            self.assertEqual(target["EnvironmentVariables"]["CP_CAPTURE_DETAIL"], "true")
                            if outcome == "test-failure":
                                raise subprocess.CalledProcessError(65, args)
                        else:
                            exported = Path(args[-1]);exported.mkdir()
                            (exported / "manifest.json").write_text(json.dumps([{"attachments": [{
                                "suggestedHumanReadableName": "native-fixture_0_UUID.png", "exportedFileName": "screen.png"}]}]))
                            (exported / "screen.png").write_bytes(b"\x89PNG\r\n\x1a\n" + bytes(8) + struct.pack(">II", 8 if outcome == "wrong-size" else 7, 9))
                        return ""
                    destination = root / "native.png"
                    with patch.object(capture, "run", side_effect=fake_run):
                        if outcome == "success":
                            capture.native_companion_capture("owned", True, root / "result", destination, (7, 9))
                        else:
                            with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                                capture.native_companion_capture("owned", True, root / "result", destination, (7, 9))
                    self.assertTrue(temporary)
                    self.assertTrue(all(not path.exists() for path in temporary))
                    self.assertEqual(destination.exists(), outcome == "success")
                    self.assertNotIn("EnvironmentVariables", plistlib.loads((products / "CompanionCapture_fixture.xctestrun").read_bytes())["CompanionCaptureUITests"])

    def test_test_runner_or_test_configuration_changes_invalidate_capture_identity(self):
        for changed in ("runner", "configuration"):
            with tempfile.TemporaryDirectory() as folder:
                with patch.object(capture, "BUILD", Path(folder) / "build"):
                    self.make_bundle()
                    receipt = json.loads(capture.build_receipt("ios").read_text())
                    products = capture.BUILD / "ios/Build/Products"
                    path = products / ("Debug-iphonesimulator/CompanionCaptureUITests-Runner.app/fixture" if changed == "runner" else "CompanionCapture_fixture.xctestrun")
                    path.write_text("changed after build")
                    self.assertFalse(capture.verified_build("ios", receipt))

    def test_native_attachment_selection_accepts_export_suffixes_and_rejects_missing_duplicates(self):
        def manifest(*names):
            return [{"attachments": [{"suggestedHumanReadableName": name, "exportedFileName": str(index)+".png"}
                                     for index, name in enumerate(names)]}]
        self.assertEqual(capture.select_attachments(manifest("wanted_1_UUID.png", "other"), {"wanted"}), {"wanted": "0.png"})
        for value in (manifest("other"), manifest("wanted.png", "wanted_2_UUID.png")):
            with self.assertRaises(RuntimeError):
                capture.select_attachments(value, {"wanted"})

    def test_native_mac_capture_refuses_local_ui_before_any_command(self):
        with patch.dict(capture.os.environ, {}, clear=True), patch.object(capture, "run") as run:
            with self.assertRaises(SystemExit):
                capture.hosted_macos_capture(Path("unused-output"))
            run.assert_not_called()

    def test_hosted_widget_service_starts_only_existing_definition_and_preserves_refusals(self):
        for outcome in ("absent", "stopped", "running", "refused", "wrong-definition"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                definition = root / "agent.plist"
                definition.write_bytes(plistlib.dumps({"Label": "unrelated" if outcome == "wrong-definition"
                    else "com.apple.notificationcenterui.agent"}))
                running = outcome == "running"
                loaded = outcome != "absent"
                mutation_count = 0
                refusal = subprocess.CalledProcessError(1, (), stderr="Operation not permitted")

                def fake_run(*args, **kwargs):
                    nonlocal running, loaded, mutation_count
                    action = args[1]
                    if action == "print-disabled":
                        return "disabled services = {}"
                    if action == "print":
                        if not loaded:
                            raise subprocess.CalledProcessError(113, args, stderr="Could not find service")
                        return "state = running" if running else "state = waiting"
                    mutation_count += 1
                    if outcome == "refused":
                        raise refusal
                    if action in {"bootstrap", "kickstart"}:
                        loaded = running = True
                    return ""

                with patch.dict(capture.os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}), patch.object(capture, "run", side_effect=fake_run):
                    if outcome == "wrong-definition":
                        with self.assertRaises(RuntimeError):
                            capture.prepare_hosted_widget_service(root, definition)
                        self.assertEqual(mutation_count, 0)
                    elif outcome == "refused":
                        with self.assertRaises(subprocess.CalledProcessError) as caught:
                            capture.prepare_hosted_widget_service(root, definition)
                        self.assertIs(caught.exception, refusal)
                        self.assertEqual(mutation_count, 1)
                        self.assertEqual(json.loads((root / "notification-center-setup.json").read_text())[-1]["stderr"], refusal.stderr)
                    else:
                        capture.prepare_hosted_widget_service(root, definition)
                        self.assertTrue(running)

    def test_widget_service_cannot_touch_local_launchd(self):
        with patch.dict(capture.os.environ, {}, clear=True), patch.object(capture, "run") as run:
            with self.assertRaises(SystemExit):
                capture.prepare_hosted_widget_service(Path("unused-output"))
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

    def test_only_fixture_widget_can_be_embedded_in_its_capture_host(self):
        host = capture.TARGETS["ios"]
        original = {"name": "Fixture", "options": {}, "targets": {
            name: {"type": "application", "platform": "auto", "sources": [], "settings": {"base": {}}}
            for name in set(capture.TARGETS.values())}}
        for fault in (None, "shipping-source", "credential-entitlement", "other-embed", "missing-extension"):
            with self.subTest(fault=fault):
                model = capture.capture_spec(original)
                capture.add_fixture_widget(model, host)
                if fault == "shipping-source":
                    model["targets"]["CaptureWidget"]["sources"].append({"path": "Sources/ContextPanelWidget"})
                elif fault == "credential-entitlement":
                    model["targets"]["CaptureWidget"]["settings"]["base"]["CODE_SIGN_ENTITLEMENTS"] = "production.entitlements"
                elif fault == "other-embed":
                    model["targets"][host]["dependencies"].append({"target": "production-widget", "embed": True})
                elif fault == "missing-extension":
                    del model["targets"]["CaptureWidget"]
                if fault is None:
                    capture.validate_capture_spec(model, widget_host=host)
                else:
                    with self.assertRaises(ValueError):
                        capture.validate_capture_spec(model, widget_host=host)

    def test_hosted_widget_signing_cannot_use_a_team_profile_or_shipping_entitlements(self):
        host = "MacCaptureApp"
        original = {"name": "Fixture", "options": {}, "targets": {
            host: {"type": "application", "platform": "macOS", "sources": [], "settings": {"base": {}}}}}
        for fault in (None, "team", "identity", "entitlements"):
            with self.subTest(fault=fault):
                model = capture.capture_spec(original, {host})
                model["targets"][host]["settings"]["base"].update(capture.fixture_signing(True))
                capture.add_fixture_widget(model, host, mac=True)
                if fault == "team":
                    model["targets"][host]["settings"]["base"]["DEVELOPMENT_TEAM"] = "production-team"
                elif fault == "identity":
                    model["targets"][host]["settings"]["base"]["CODE_SIGN_IDENTITY"] = "Apple Distribution"
                elif fault == "entitlements":
                    model["targets"]["CaptureWidget"]["settings"]["base"]["CODE_SIGN_ENTITLEMENTS"] = "production.entitlements"
                if fault is None:
                    capture.validate_capture_spec(model, {host}, widget_host=host)
                else:
                    with self.assertRaises(ValueError):
                        capture.validate_capture_spec(model, {host}, widget_host=host)

    def test_native_desktop_crop_checks_real_pixels_and_complete_widget_in_points(self):
        data = b"\x89PNG\r\n\x1a\n" + bytes(8) + struct.pack(">II", 1600, 900)
        for scale in (1, 2):
            geometry = {"screenPixels": [1600, 900], "screenPoints": [1600 / scale, 900 / scale],
                        "widgetPoints": [20, 20, 200, 200]}
            crop = capture.native_mac_crop(geometry, data)
            self.assertLessEqual(crop[2], 1600)
            self.assertLessEqual(crop[3], 900)
            for fault in ("pixels", "clipped", "nonuniform"):
                changed = dict(geometry)
                if fault == "pixels":
                    changed["screenPixels"] = [3200, 1800]
                elif fault == "clipped":
                    changed["widgetPoints"] = [0, 0, 1600 / scale, 900 / scale]
                else:
                    changed["screenPoints"] = [1600, 450]
                with self.assertRaises(ValueError):
                    capture.native_mac_crop(changed, data)

    def test_vision_test_products_and_configuration_are_bound_to_their_fixture_app(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(capture, "BUILD", Path(folder) / "build"):
            app = self.make_bundle(platform="visionos")
            receipt = json.loads(capture.build_receipt("visionos").read_text())
            products = capture.BUILD / "visionos/Build/Products"
            path = products / capture.companion_testing_identity("visionos")["xctestrunFile"]
            configuration = plistlib.loads(path.read_bytes())
            capture.configure_companion_test_run(configuration, False, "place", platform="visionos")
            self.assertTrue(capture.verified_build("visionos", receipt))
            self.assertEqual(configuration["CompanionCaptureUITests"]["EnvironmentVariables"]["CP_CAPTURE_WIDGET"], "place")
            runner = products / ("Debug-" + capture.SDKS["visionos"]) / "CompanionCaptureUITests-Runner.app/fixture"
            runner.write_text("changed runner")
            self.assertFalse(capture.verified_build("visionos", receipt))
