#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["PyYAML>=6", "Pillow>=11"]
# ///
"""Build disposable fixture-only apps and capture owned headless simulators.

No installed Mac app, desktop, browser, accounts, or App Store APIs are used.
See Resources/AppStore/Screenshots/horizon-capture/README.md for operator steps.
"""
from __future__ import annotations

import argparse
import copy
import fcntl
import os
import hashlib
import json
import math
import plistlib
from pathlib import Path
import struct
import subprocess
import sys
import uuid
import time

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build/app-store-capture"
PROJECT = BUILD / "project/ContextPanel.xcodeproj"
TARGETS = {"ios": "ContextPanelCompanion", "visionos": "ContextPanelCompanion", "watchos": "ContextPanelWatch", "tvos": "ContextPanelTV"}
SDKS = {"ios": "iphonesimulator", "visionos": "xrsimulator", "watchos": "watchsimulator", "tvos": "appletvsimulator"}
PROFILES = {
    "iphone": ("ios", "iPhone-17-Pro", (1206, 2622)),
    "iphone65": ("ios", "iPhone-14-Plus", (1284, 2778)),
    "ipad": ("ios", "iPad-Pro-12-9-inch-6th-generation-8GB", (2048, 2732)),
    "visionpro": ("visionos", "Apple-Vision-Pro-4K", (3840, 2160)),
    "watch": ("watchos", "Apple-Watch-Ultra-2-49mm", (410, 502)),
    "tvos": ("tvos", "Apple-TV-4K-3rd-generation-1080p", (1920, 1080)),
}
PROFILES.update({name + "-detail": PROFILES[name] for name in ("iphone", "iphone65", "ipad", "visionpro")})
PROFILES["watch-accounts"] = PROFILES["watch"]
PROFILES.update({name + "-widget": PROFILES[name] for name in ("iphone", "iphone65", "ipad", "visionpro")})
RUNTIMES = {"ios": "iOS-27-0", "visionos": "xrOS-27-0", "watchos": "watchOS-27-0", "tvos": "tvOS-27-0"}
CAPTURE_VERSION = {"MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "1"}


def run(*args: str, timeout: int = 180, env: dict[str, str] | None = None) -> str:
    print("+ " + " ".join(map(str, args)), flush=True)
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, env=env)
    print(result.stdout, end="", flush=True)
    print(result.stderr, end="", flush=True)
    result.check_returncode()
    return result.stdout.strip()


def staged_png(prefix: tuple[str, ...], udid: str, destination: Path, size: tuple[int, int],
               parent: Path | None = None) -> bool:
    # Q605: normal system temp first; container staging only after a save refusal.
    arguments = (str(parent / "cp744.XXXXXX"),) if parent else ()
    directory = Path(run("mktemp", "-d", *arguments))
    if not directory.is_absolute() or not directory.is_dir():
        raise RuntimeError("mktemp did not return a temporary directory")
    image = directory / "capture.png"
    primary_error = None
    try:
        try:
            run(*prefix, "io", udid, "screenshot", "--type=png", "--mask=ignored", str(image))
        except subprocess.CalledProcessError as error:
            primary_error = error
            if parent is None and "NSCocoaErrorDomain, code=513" in (error.stderr or ""):
                return False
            raise
        data = image.read_bytes()
        if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit("simctl did not produce a PNG")
        dimensions = struct.unpack(">II", data[16:24])
        if dimensions != size:
            raise SystemExit(f"Unexpected capture size {dimensions}; expected {size}")
        with destination.open("xb") as output:
            output.write(data)
        return True
    except BaseException as error:
        primary_error = error
        raise
    finally:
        try:
            image.unlink(missing_ok=True)
            directory.rmdir()
        except Exception as cleanup_error:
            if primary_error is not None:
                primary_error.add_note(f"Temporary staging cleanup incomplete: {cleanup_error!r}")
                raise primary_error
            raise


def capture_png(prefix: tuple[str, ...], udid: str, identifier: str,
                destination: Path, size: tuple[int, int]) -> str:
    saved = staged_png(prefix, udid, destination, size)
    staging = "system temporary directory"
    if not saved:
        container = Path(run(*prefix, "get_app_container", udid, identifier, "data"))
        if not container.is_absolute() or not container.is_dir():
            raise RuntimeError("Owned fixture-app data container unavailable")
        staged_png(prefix, udid, destination, size, container / "tmp")
        staging = "owned fixture-app temporary directory after system-temp save refusal"
    return staging


def unsigned_settings(settings: dict) -> dict:
    base = {key: value for key, value in settings.get("base", {}).items()
            if not key.startswith(("CODE_SIGN", "PROVISIONING_PROFILE")) and key != "DEVELOPMENT_TEAM"}
    return {"base": {**base, "CODE_SIGNING_ALLOWED": "NO"}}


def capture_spec(original: dict, roots: set[str] | None = None) -> dict:
    roots = roots if roots is not None else set(TARGETS.values())
    selected = set()

    def select(name: str) -> None:
        if name in selected:
            return
        target = original["targets"][name]
        if name not in roots and target["type"] != "library.static":
            raise ValueError(f"Unexpected non-library capture dependency: {name}")
        selected.add(name)
        for dependency in target.get("dependencies", []):
            if "target" in dependency and not dependency.get("embed"):
                select(dependency["target"])

    for name in roots:
        select(name)
    spec = {"name": original["name"], "options": copy.deepcopy(original["options"]),
            "settings": unsigned_settings(original.get("settings", {})), "targets": {}, "schemes": {}}
    for name, original_target in original["targets"].items():
        if name not in selected:
            continue
        target = copy.deepcopy(original_target)
        target.pop("postBuildScripts", None)
        target["dependencies"] = [dependency for dependency in target.get("dependencies", [])
                                  if not dependency.get("embed")]
        target["settings"] = unsigned_settings(target.get("settings", {}))
        settings = target["settings"]["base"]
        if "INFOPLIST_FILE" in settings:
            settings["INFOPLIST_FILE"] = str(ROOT / settings["INFOPLIST_FILE"])
        if name in roots:
            target["sources"] += [{"path": "Tools/ContextPanelAppStoreCapture/ScreenshotFixture.swift"},
                                   {"path": "Tools/ContextPanelAppStoreCapture/SimulatorContent.swift"}]
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) CONTEXT_PANEL_SCREENSHOTS"
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id(name)
            spec["schemes"][name] = {"build": {"targets": {name: "all"}}}
        spec["targets"][name] = target
    return spec


def fixture_widget_spec(host: str, mac: bool = False) -> dict:
    return {
        "type": "app-extension",
        **({"platform": "macOS", "deploymentTarget": "14.0"} if mac else {
            "platform": "auto", "supportedDestinations": ["iOS", "visionOS"],
            "deploymentTarget": {"iOS": "17.0", "visionOS": "26.0"}}),
        "sources": [{"path": "Tools/ContextPanelAppStoreCapture/CaptureWidget.swift"},
                    {"path": "Tools/ContextPanelAppStoreCapture/ScreenshotFixture.swift"}],
        "dependencies": [{"target": "ContextPanelCore" if mac else "ContextPanelCoreCompanion"},
                         {"target": "ContextPanelWidgetUI" if mac else "ContextPanelWidgetUICompanion"}],
        "info": {"path": str(BUILD / (host + "-Widget-Info.plist")), "properties": {
            "CFBundleDisplayName": "Context Panel", "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)", "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}}},
        "settings": {"base": {**fixture_signing(mac, extension=mac), **CAPTURE_VERSION, "PRODUCT_NAME": "CaptureWidget",
            "PRODUCT_BUNDLE_IDENTIFIER": bundle_id(host) + ".widget", "SKIP_INSTALL": True,
            "APPLICATION_EXTENSION_API_ONLY": True, **({} if mac else {"TARGETED_DEVICE_FAMILY": "1,2,7"})}}}


def fixture_signing(mac: bool, extension: bool = False) -> dict:
    if not mac:
        return {"CODE_SIGNING_ALLOWED": "NO"}
    return {"CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-",
            **({"CODE_SIGN_ENTITLEMENTS": str(BUILD / "CaptureWidget.entitlements")} if extension else {})}


def add_fixture_widget(spec: dict, host: str, mac: bool = False) -> None:
    spec["targets"]["CaptureWidget"] = fixture_widget_spec(host, mac)
    spec["targets"][host]["dependencies"].append({"target": "CaptureWidget", "embed": True})


def validate_capture_spec(spec: dict, roots: set[str] | None = None, widget_host: str | None = None) -> None:
    roots = roots if roots is not None else set(TARGETS.values())
    if widget_host is not None:
        if widget_host not in roots or "CaptureWidget" not in spec["targets"]:
            raise ValueError("Fixture widget requires its isolated capture host")
        embeds = [d for d in spec["targets"][widget_host]["dependencies"] if d.get("embed")]
        if embeds != [{"target": "CaptureWidget", "embed": True}]:
            raise ValueError("Fixture host must embed exactly its fixture widget")
    mac_widgets = widget_host == "MacCaptureApp"
    for name, settings in [(None, spec["settings"]), *((name, target["settings"]) for name, target in spec["targets"].items())]:
        if settings.get("configs"):
            raise ValueError("Capture projects cannot inherit shipping configuration overrides")
        signing = {key: value for key, value in settings["base"].items()
                   if key.startswith(("CODE_SIGN", "PROVISIONING_PROFILE")) or key == "DEVELOPMENT_TEAM"}
        expected = fixture_signing(mac_widgets and name in {widget_host, "CaptureWidget"}, extension=name == "CaptureWidget" and mac_widgets)
        if signing != expected:
            raise ValueError("Capture projects permit only unsigned simulators or exact hosted fixture ad-hoc signing")
    for name, target in spec["targets"].items():
        if name == "CaptureWidget" and widget_host in roots:
            if target != fixture_widget_spec(widget_host, spec["targets"][widget_host]["platform"] == "macOS"):
                raise ValueError("Only the exact fixture-only widget extension is allowed")
            continue
        settings = target["settings"]["base"]
        if target.get("postBuildScripts") or target.get("info"):
            raise ValueError("Capture targets cannot stamp builds or generate source-tree plists")
        if any(dependency.get("embed") and (name != widget_host or dependency != {"target": "CaptureWidget", "embed": True})
               for dependency in target.get("dependencies", [])):
            raise ValueError("Capture targets cannot embed extensions")
        if name in roots:
            if settings["PRODUCT_BUNDLE_IDENTIFIER"] != bundle_id(name):
                raise ValueError("Capture bundle identifier was not isolated")
            if "CONTEXT_PANEL_SCREENSHOTS" not in settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].split():
                raise ValueError("Capture condition was not enabled")
        elif target["type"] != "library.static":
            raise ValueError("Capture project retained an unrelated target")


def clean_commit() -> str:
    if run("git", "-C", str(ROOT), "status", "--porcelain"):
        raise SystemExit("Commit source changes before preparing, building or capturing")
    return run("git", "-C", str(ROOT), "rev-parse", "HEAD")


def prepare() -> None:
    import yaml

    source = clean_commit()
    PROJECT.parent.mkdir(parents=True, exist_ok=True)
    spec = capture_spec(yaml.safe_load((ROOT / "project.yml").read_text()))
    watch = spec["targets"][TARGETS["watchos"]]["settings"]["base"]
    info = plistlib.loads(Path(watch["INFOPLIST_FILE"]).read_bytes())
    info.pop("WKCompanionAppBundleIdentifier", None)
    info["WKWatchOnly"] = True
    watch_plist = BUILD / "CaptureWatch-Info.plist"
    watch_plist.write_bytes(plistlib.dumps(info))
    watch["INFOPLIST_FILE"] = str(watch_plist)
    add_fixture_widget(spec, TARGETS["ios"])
    validate_capture_spec(spec, widget_host=TARGETS["ios"])
    tests = "CompanionCaptureUITests"
    spec["targets"][tests] = {
        "type": "bundle.ui-testing", "platform": "auto", "supportedDestinations": ["iOS", "visionOS"],
        "deploymentTarget": {"iOS": "17.0", "visionOS": "26.0"},
        "sources": [{"path": "Tools/ContextPanelAppStoreCapture/CompanionCaptureUITests.swift"},
                    {"path": "Tools/ContextPanelAppStoreCapture/ScreenshotFixture.swift"}],
        "dependencies": [{"target": TARGETS["ios"]}, {"target": "ContextPanelCoreCompanion"}],
        "settings": {"base": {"CODE_SIGNING_ALLOWED": "NO", "GENERATE_INFOPLIST_FILE": True,
            "PRODUCT_BUNDLE_IDENTIFIER": bundle_id(tests), "TEST_TARGET_NAME": TARGETS["ios"], "TARGETED_DEVICE_FAMILY": "1,2,7"}}}
    spec["schemes"]["CompanionCapture"] = {"build": {"targets": {TARGETS["ios"]: "all", tests: ["test"]}},
        "test": {"targets": [tests]}}
    path = BUILD / "project.yml"
    path.write_text(yaml.safe_dump(spec, sort_keys=False))
    run("xcodegen", "generate", "--spec", str(path), "--project", str(PROJECT.parent),
        "--project-root", str(ROOT))
    if clean_commit() != source:
        raise SystemExit("Project generation changed source; preserve it for review")
    (BUILD / "prepared.json").write_text(json.dumps({"sourceCommit": source}) + "\n")


def bundle_id(target: str) -> str:
    return "com.shinycomputers.contextpanel.screenshots." + target.lower()


def app_path(platform: str) -> Path:
    return BUILD / platform / "Build/Products" / f"Debug-{SDKS[platform]}" / "Context Panel.app"


def bundle_digest(app: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        if path.is_file():
            digest.update(path.relative_to(app).as_posix().encode() + b"\0")
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def build_receipt(platform: str) -> Path:
    return BUILD / platform / "capture-build.json"


def companion_testing_identity(platform: str = "ios") -> dict:
    products = BUILD / platform / "Build/Products"
    runs = list(products.glob("CompanionCapture_*.xctestrun"))
    if len(runs) != 1:
        raise RuntimeError(f"Expected one built fixture UI test configuration; found {runs}")
    runner = products / ("Debug-" + SDKS[platform]) / "CompanionCaptureUITests-Runner.app"
    if not runner.is_dir():
        raise RuntimeError("Fixture UI test runner is missing")
    return {"xctestrunFile": runs[0].name, "xctestrunSHA256": hashlib.sha256(runs[0].read_bytes()).hexdigest(),
            "runnerSHA256": bundle_digest(runner)}


def verified_build(platform: str, receipt: dict) -> bool:
    return (receipt["bundleSHA256"] == bundle_digest(app_path(platform))
            and (platform not in {"ios", "visionos"} or receipt.get("uiTesting") == companion_testing_identity(platform)))


def build(platform: str) -> None:
    source = clean_commit()
    if not PROJECT.exists() or json.loads((BUILD / "prepared.json").read_text())["sourceCommit"] != source:
        raise SystemExit("Run prepare at the current source commit first")
    build_receipt(platform).unlink(missing_ok=True)
    run("xcodebuild", "-quiet", "-project", str(PROJECT), "-scheme", "CompanionCapture" if platform in {"ios", "visionos"} else TARGETS[platform],
        "-configuration", "Debug", "-sdk", SDKS[platform],
        "-destination", f"generic/platform={dict(ios='iOS Simulator', visionos='visionOS Simulator', watchos='watchOS Simulator', tvos='tvOS Simulator')[platform]}",
        "-derivedDataPath", str(BUILD / platform), "CODE_SIGNING_ALLOWED=NO", "build-for-testing" if platform in {"ios", "visionos"} else "build", timeout=1800)
    if clean_commit() != source:
        raise SystemExit("Source changed during the build")
    receipt = {"sourceCommit": source, "bundleSHA256": bundle_digest(app_path(platform))}
    if platform in {"ios", "visionos"}:
        receipt["uiTesting"] = companion_testing_identity(platform)
    build_receipt(platform).write_text(json.dumps(receipt) + "\n")


def device_inventory(prefix: tuple[str, ...]) -> dict:
    return json.loads(run(*prefix, "list", "devices", "--json"))["devices"]


def new_owned_device(inventory: dict, before: set[str], name: str, platform: str, device: str) -> dict | None:
    runtime = "com.apple.CoreSimulator.SimRuntime." + RUNTIMES[platform]
    matches = [entry for entry in inventory.get(runtime, [])
               if entry["udid"] not in before and entry["name"] == name
               and entry.get("deviceTypeIdentifier") == "com.apple.CoreSimulator.SimDeviceType." + device]
    if len(matches) > 1:
        raise RuntimeError("Ambiguous simulator create outcome; preserving every candidate")
    return matches[0] if matches else None


def capture(profile: str, output: Path) -> None:
    platform, device, expected_size = PROFILES[profile]
    if output.exists():
        raise SystemExit(f"Refusing to overwrite {output}")
    source = clean_commit()
    receipt_path = build_receipt(platform)
    if not receipt_path.is_file():
        raise SystemExit(f"Build {platform} at this source commit first")
    receipt = json.loads(receipt_path.read_text())
    app = app_path(platform)
    if not app.is_dir():
        raise SystemExit(f"Build {platform} first")
    if receipt["sourceCommit"] != source or not verified_build(platform, receipt):
        raise SystemExit("Capture build does not match the current committed source and bundle")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != bundle_id(TARGETS[platform]):
        raise SystemExit("Refusing a bundle without the capture-only identifier")
    output.mkdir(parents=True)
    # Q599 authorizes CoreSimulator's normal private storage.
    prefix = ("xcrun", "simctl")
    name = "CP744-C2-" + uuid.uuid4().hex
    inventory = device_inventory(prefix)
    before = {entry["udid"] for entries in inventory.values() for entry in entries}
    if any(entry["name"] == name for entries in inventory.values() for entry in entries):
        raise SystemExit("Simulator name collision; no device was created")
    # A failed create can allocate a device. Reconcile only a newly observed exact
    # name/type/runtime match and delete by UDID; never retry the refused action.
    created_id = None
    primary_error = None
    try:
        udid = run(*prefix, "create", name, "com.apple.CoreSimulator.SimDeviceType." + device,
                   "com.apple.CoreSimulator.SimRuntime." + RUNTIMES[platform])
        uuid.UUID(udid)
        if udid in before:
            raise RuntimeError("Create returned a pre-existing simulator; preserving it")
        created_id = udid
        run(*prefix, "boot", udid)
        run(*prefix, "bootstatus", udid, "-b", timeout=240)
        if platform not in {"ios", "visionos"}:
            run(*prefix, "install", udid, str(app))
        files = []
        launch_arguments = ["--screenshot-detail"] if profile.endswith("-detail") else []
        if profile == "watch-accounts":
            launch_arguments = ["--screenshot-accounts"]
        for appearance in (["dark"] if platform in {"watchos", "tvos", "visionos"} else ["light", "dark"]):
            if platform not in {"watchos", "tvos"}:
                run(*prefix, "ui", udid, "appearance", appearance)
            if platform == "ios":
                run(*prefix, "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi",
                    "--wifiMode", "active", "--wifiBars", "3", "--batteryState", "charged", "--batteryLevel", "100")
            path = output / f"{profile}-app-{appearance}.png"
            if platform in {"ios", "visionos"}:
                staging = native_companion_capture(udid, profile.endswith("-detail"), output / appearance, path, expected_size,
                                   widget=("place" if not files else "present") if profile.endswith("-widget") else None,
                                   platform=platform)
            else:
                run(*prefix, "launch", "--terminate-running-process", udid, bundle_id(TARGETS[platform]), *launch_arguments)
                time.sleep(6)  # Native layout transition; visual acceptance remains required.
                staging = capture_png(prefix, udid, bundle_id(TARGETS[platform]), path, expected_size)
            data = path.read_bytes()
            width, height = expected_size
            files.append({"file": path.name, "width": width, "height": height,
                          "sha256": hashlib.sha256(data).hexdigest(), "appearance": appearance, "staging": staging})
        if not verified_build(platform, receipt):
            raise RuntimeError("Capture products changed while the simulator was running")
        capture_record = {
            "sourceCommit": receipt["sourceCommit"], "bundleSHA256": receipt["bundleSHA256"],
            "uiTesting": receipt.get("uiTesting"),
            "xcode": run("xcodebuild", "-version"), "profile": profile,
            "runtime": RUNTIMES[platform], "deviceType": device,
            "simulatorUDID": udid,
            "deviceSet": "CoreSimulator default private storage",
            "mechanism": ("native XCTest simulator framebuffer" if platform == "ios" else
                          "native XCTest scene placement/navigation; simctl framebuffer via temporary PNG staging" if platform == "visionos" else
                          "simctl framebuffer via temporary PNG staging; fixture-only capture build"),
            "images": files,
        }
    except BaseException as error:
        primary_error = error
        if profile.endswith("-widget") and created_id is not None:
            try:
                events = run(*prefix, "spawn", created_id, "log", "show", "--style", "ndjson", "--last", "15m",
                             "--predicate", 'process IN {"chronod", "RealityWidgets", "CaptureWidget"} OR subsystem BEGINSWITH "com.apple.chrono" OR subsystem == "com.apple.WidgetKit"',
                             timeout=60)
                (output / "widget-events.ndjson").write_text(events)
            except BaseException as diagnostic_error:
                error.add_note(f"Owned widget event log collection failed: {diagnostic_error}")
        raise
    finally:
        try:
            owned_id = created_id
            if owned_id is None:
                owned = new_owned_device(device_inventory(prefix), before, name, platform, device)
                owned_id = owned["udid"] if owned else None
            if owned_id:
                uuid.UUID(owned_id)
                try:
                    run(*prefix, "shutdown", owned_id)
                except subprocess.CalledProcessError:
                    pass  # Deletion can still finish cleanup of our exact owned device.
                run(*prefix, "delete", owned_id)
                if any(entry["udid"] == owned_id for entries in device_inventory(prefix).values() for entry in entries):
                    raise RuntimeError("Owned simulator still exists after delete")
        except Exception as cleanup_error:
            if primary_error is None:
                raise
            primary_error.add_note(f"Simulator cleanup incomplete: {cleanup_error!r}")
    capture_record["cleanup"] = "owned simulator deleted; absence verified"
    (output / "capture.json").write_text(json.dumps(capture_record, indent=2) + "\n")


def select_attachments(manifest: list, expected: set[str]) -> dict[str, str]:
    found = {}
    for case in manifest:
        for item in case["attachments"]:
            name = item["suggestedHumanReadableName"].removesuffix(".png")
            matches = [wanted for wanted in expected if name == wanted or name.startswith(wanted + "_")]
            for wanted in matches:
                if wanted in found:
                    raise RuntimeError(f"Duplicate native attachment: {wanted}")
                found[wanted] = item["exportedFileName"]
    if set(found) != expected:
        names = [item["suggestedHumanReadableName"] for case in manifest for item in case["attachments"]]
        raise RuntimeError(f"Missing native attachments: {expected - set(found)}; observed {names}")
    return found


def configure_companion_test_run(configuration: dict, detail: bool, widget: str | None = None, platform: str = "ios") -> None:
    if widget not in {None, "place", "present"} or (detail and widget is not None):
        raise ValueError("Select one fixture screen: overview, detail or widget placement")
    if "TestConfigurations" in configuration:
        targets = [target for entry in configuration["TestConfigurations"] for target in entry["TestTargets"]]
    else:
        targets = [value for value in configuration.values() if isinstance(value, dict)]
    selected = [target for target in targets if target.get("BlueprintName") == "CompanionCaptureUITests"]
    if len(selected) != 1:
        raise RuntimeError("Expected one fixture-only UI test target")
    target = selected[0]
    expected_app = "__TESTROOT__/" + app_path(platform).relative_to(BUILD / platform / "Build/Products").as_posix()
    if target.get("UITargetAppPath") != expected_app or target.get("IsUITestBundle") is not True:
        raise RuntimeError("UI test is not associated with the fixture app")
    target.setdefault("EnvironmentVariables", {})["CP_CAPTURE_DETAIL"] = "true" if detail else "false"
    target["EnvironmentVariables"]["CP_CAPTURE_WIDGET"] = widget or ""


def native_companion_capture(udid: str, detail: bool, directory: Path, destination: Path, size: tuple[int, int], widget: str | None = None, platform: str = "ios") -> str:
    products = BUILD / platform / "Build/Products"
    identity = companion_testing_identity(platform)
    configuration = plistlib.loads((products / identity["xctestrunFile"]).read_bytes())
    configure_companion_test_run(configuration, detail, widget, platform)
    # Keep relative __TESTROOT__ product paths bound to the verified build tree.
    configured = products / ("capture-" + uuid.uuid4().hex + ".xctestrun")
    directory.mkdir()
    result = directory / "capture.xcresult"
    try:
        configured.write_bytes(plistlib.dumps(configuration))
        destination_platform = "visionOS" if platform == "visionos" else "iOS"
        run("xcodebuild", "-quiet", "-derivedDataPath", str(BUILD / (platform + "-test")), "-xctestrun", str(configured), "-destination", f"platform={destination_platform} Simulator,id={udid}",
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-resultBundlePath", str(result), "test-without-building", timeout=600)
    finally:
        configured.unlink(missing_ok=True)
    exported = directory / "attachments"
    run("xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported))
    if platform == "visionos":
        # xrOS XCTest exports a 1x1 screen attachment. Use the Q605 framebuffer
        # transport after successful native scene placement, without rescaling.
        # XCTest teardown exposes Home. Reactivate only our fixture app; the
        # placed WidgetKit scene persists independently of its gallery.
        run("xcrun", "simctl", "launch", udid, bundle_id(TARGETS[platform]),
            *(["--screenshot-detail"] if detail else []))
        time.sleep(6)
        return capture_png(("xcrun", "simctl"), udid, bundle_id(TARGETS[platform]), destination, size)
    found = select_attachments(json.loads((exported / "manifest.json").read_text()), {"native-fixture"})
    data = (exported / found["native-fixture"]).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != size:
        raise RuntimeError("Unexpected native simulator screenshot dimensions or format")
    with destination.open("xb") as stream:
        stream.write(data)
    return "native XCTest simulator screen attachment"


def rgb_image(source: Path, destination: Path, crop: tuple[int, int, int, int] | None = None) -> None:
    from PIL import Image
    import io
    with Image.open(source) as image:
        rgba = image.convert("RGBA")
        if rgba.getchannel("A").getextrema() != (255, 255):
            raise SystemExit("Refusing to flatten a transparent capture")
        if crop is not None:
            left, top, right, bottom = crop
            if not (0 <= left < right <= rgba.width and 0 <= top < bottom <= rgba.height):
                raise SystemExit("Native capture does not contain the requested crop")
            rgba = rgba.crop(crop)
        output = io.BytesIO()
        rgba.convert("RGB").save(output, format="PNG", icc_profile=image.info.get("icc_profile"))
    with destination.open("xb") as stream:
        stream.write(output.getvalue())


def native_mac_crop(geometry: dict, data: bytes) -> tuple[int, int, int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
        raise ValueError("Native desktop screenshot is not a PNG")
    pixels = struct.unpack(">II", data[16:24])
    if tuple(geometry["screenPixels"]) != pixels:
        raise ValueError("Native screenshot does not match the recorded display pixels")
    width, height = geometry["screenPoints"]
    boxes = geometry["widgetsPoints"]
    if not boxes or not all(math.isfinite(value) for value in (width, height)) or width <= 0 or height <= 0:
        raise ValueError("Invalid native desktop geometry")
    scale = pixels[0] / width
    if not math.isclose(scale, pixels[1] / height, rel_tol=1e-6):
        raise ValueError("Native display point-to-pixel scales disagree")
    if not any(math.isclose(scale, supported) for supported in (1, 2)):
        raise ValueError("Native desktop scale has no supported App Store crop")
    crop = (0, 0, round(1280 * scale), round(800 * scale))
    if pixels[0] < crop[2] or pixels[1] < crop[3]:
        raise ValueError("Native desktop is smaller than the complete screenshot region")
    for box in boxes:
        if len(box) != 4 or not all(math.isfinite(value) for value in box):
            raise ValueError("Invalid native widget geometry")
        left, top, right, bottom = (value * scale for value in box)
        if not (0 <= left < right <= crop[2] and 0 <= top < bottom <= crop[3]):
            raise ValueError("A complete native widget is outside the screenshot crop")
    return crop


def require_hosted_mac() -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise SystemExit("Native Mac UI capture requires an isolated GitHub-hosted runner")


def prepare_hosted_widget_service(output: Path, definition: Path = Path(
        "/System/Library/LaunchAgents/com.apple.notificationcenterui.plist")) -> None:
    require_hosted_mac()
    label = "com.apple.notificationcenterui.agent"
    if plistlib.loads(definition.read_bytes()).get("Label") != label:
        raise RuntimeError("The runner's existing Notification Center agent definition does not match")
    domain = f"gui/{os.getuid()}"
    service = f"{domain}/{label}"
    journal = []

    def command(*arguments: str) -> str:
        try:
            result = run("launchctl", *arguments)
            journal.append({"arguments": arguments, "stdout": result, "returncode": 0})
            return result
        except subprocess.CalledProcessError as error:
            journal.append({"arguments": arguments, "stdout": error.stdout,
                            "stderr": error.stderr, "returncode": error.returncode})
            raise
        finally:
            (output / "notification-center-setup.json").write_text(json.dumps(journal, indent=2) + "\n")

    command("print-disabled", domain)
    try:
        state = command("print", service)
        loaded = True
    except subprocess.CalledProcessError as error:
        if "Could not find service" not in ((error.stdout or "") + (error.stderr or "")):
            raise
        state, loaded = "", False
    command("enable", service)
    if not loaded:
        command("bootstrap", domain, str(definition))
    elif "state = running" not in state:
        command("kickstart", "-p", service)
    deadline = time.monotonic() + 30
    while True:
        state = command("print", service)
        if "state = running" in state:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError("The hosted Notification Center agent did not reach running state")
        time.sleep(1)


def hosted_macos_capture(output: Path) -> None:
    require_hosted_mac()
    import yaml
    if output.exists():
        raise SystemExit("Refusing to overwrite Mac capture output")
    source = clean_commit()
    original = yaml.safe_load((ROOT / "project.yml").read_text())
    shipping = original["targets"]["ContextPanel"]
    libraries = [d for d in shipping["dependencies"] if not d.get("embed")]
    original["targets"]["MacFixtureViews"] = {
        "type": "library.static", "platform": "macOS", "deploymentTarget": "14.0",
        "sources": [{"path": "Sources/ContextPanelApp", "excludes": ["Main"]}],
        "dependencies": libraries,
        "settings": {"base": {"PRODUCT_NAME": "ContextPanelApp", "PRODUCT_MODULE_NAME": "ContextPanelApp", "SKIP_INSTALL": True}}}
    app = "MacCaptureApp"
    tests = "MacCaptureUITests"
    original["targets"][app] = {
        "type": "application", "platform": "macOS", "deploymentTarget": "14.0",
        "sources": [{"path": "Tools/ContextPanelAppStoreCapture/MacCaptureMain.swift"},
                    {"path": "Resources/Assets.xcassets"}],
        "dependencies": [{"target": "MacFixtureViews"}, *libraries],
        "settings": {"base": {"PRODUCT_NAME": "Context Panel", "GENERATE_INFOPLIST_FILE": True,
            "INFOPLIST_KEY_CFBundleDisplayName": "Context Panel", **CAPTURE_VERSION}}}
    spec = capture_spec(original, {app})
    spec["targets"][app]["settings"]["base"].update(fixture_signing(True))
    add_fixture_widget(spec, app, mac=True)
    validate_capture_spec(spec, {app}, widget_host=app)
    spec["targets"][tests] = {
        "type": "bundle.ui-testing", "platform": "macOS", "deploymentTarget": "14.0",
        "sources": [{"path": "Tools/ContextPanelAppStoreCapture/MacCaptureUITests.swift"},
                    {"path": "Tools/ContextPanelAppStoreCapture/ScreenshotFixture.swift"}],
        "dependencies": [{"target": app}, {"target": "ContextPanelCore"}],
        "settings": {"base": {"CODE_SIGNING_ALLOWED": "NO", "GENERATE_INFOPLIST_FILE": True,
                               "PRODUCT_BUNDLE_IDENTIFIER": bundle_id(tests), "TEST_TARGET_NAME": app}}}
    spec["schemes"][app] = {"build": {"targets": {app: "all", tests: ["test"]}},
        "test": {"targets": [tests]}}
    directory = BUILD / "macos-project"
    directory.mkdir(parents=True, exist_ok=True)
    (BUILD / "CaptureWidget.entitlements").write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
    path = directory / "project.yml"
    path.write_text(yaml.safe_dump(spec, sort_keys=False))
    run("xcodegen", "generate", "--spec", str(path), "--project", str(directory), "--project-root", str(ROOT))
    output.mkdir(parents=True)
    result = output / "capture.xcresult"
    prepare_hosted_widget_service(output)
    try:
        run("xcodebuild", "-quiet", "-project", str(directory / "ContextPanel.xcodeproj"),
            "-scheme", app, "-configuration", "Debug", "-destination", "platform=macOS",
            "-derivedDataPath", str(BUILD / "macos-ci"), "-resultBundlePath", str(result),
            "-collect-test-diagnostics", "never", "test", timeout=1200,
            env={**os.environ, "TEST_RUNNER_GITHUB_ACTIONS": os.environ["GITHUB_ACTIONS"],
                 "TEST_RUNNER_RUNNER_ENVIRONMENT": os.environ["RUNNER_ENVIRONMENT"]})
    except BaseException as error:
        try:
            events = run("log", "show", "--style", "ndjson", "--last", "10m", "--predicate",
                         'process IN {"WindowManager", "NotificationCenter", "chronod", "CaptureWidget"} OR subsystem BEGINSWITH "com.apple.chrono" OR eventMessage CONTAINS[c] "com.apple.notificationcenterui"', timeout=60)
            (output / "widget-events.ndjson").write_text(events)
            disabled = run("launchctl", "print-disabled", f"gui/{os.getuid()}")
            (output / "disabled-services.txt").write_text(disabled)
        except BaseException as diagnostic_error:
            error.add_note(f"Isolated hosted widget log collection failed: {diagnostic_error}")
        raise
    exported = output / "attachments"
    run("xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(exported))
    expected = {f"mac-{mode}-{appearance}" for mode in ("overview", "detail") for appearance in ("light", "dark")}
    expected.add("mac-widget-desktop")
    images = []
    found = select_attachments(json.loads((exported / "manifest.json").read_text()), expected | {"mac-widget-geometry"})
    geometry = json.loads((exported / found.pop("mac-widget-geometry")).read_text())
    for name, filename in found.items():
        destination = output / (name + ".png")
        raw = exported / filename
        crop = native_mac_crop(geometry, raw.read_bytes()) if name == "mac-widget-desktop" else None
        rgb_image(raw, destination, crop=crop)
        data = destination.read_bytes()
        width, height = struct.unpack(">II", data[16:24])
        if (width, height) not in {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)}:
            raise SystemExit(f"Unexpected native Mac window size: {width}x{height}")
        images.append({"file": destination.name, "width": width, "height": height,
                       "sha256": hashlib.sha256(data).hexdigest(), "rawSHA256": hashlib.sha256(raw.read_bytes()).hexdigest(),
                       "crop": list(crop) if crop else None, "geometry": geometry if crop else None})
    expected -= set(found)
    if expected or clean_commit() != source:
        raise SystemExit(f"Missing native captures or changed source: {expected}")
    (output / "capture.json").write_text(json.dumps({"sourceCommit": source,
        "mechanism": "XCTest native window screenshot on isolated GitHub-hosted runner",
        "xcode": run("xcodebuild", "-version"), "os": run("sw_vers"), "images": images}, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare")
    builder = commands.add_parser("build")
    builder.add_argument("platform", choices=TARGETS)
    capturer = commands.add_parser("capture")
    capturer.add_argument("profile", choices=PROFILES)
    capturer.add_argument("--output", required=True, type=Path)
    mac = commands.add_parser("ci-macos")
    mac.add_argument("--output", required=True, type=Path)
    rgb = commands.add_parser("rgb")
    rgb.add_argument("source", type=Path)
    rgb.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.command == "rgb":
        rgb_image(args.source, args.destination)
        return
    BUILD.mkdir(parents=True, exist_ok=True)
    with (BUILD / "capture.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Another fixture prepare/build/capture is running; wait for its cleanup")
        if args.command == "prepare":
            prepare()
        elif args.command == "build":
            build(args.platform)
        elif args.command == "ci-macos":
            hosted_macos_capture(args.output.resolve())
        else:
            capture(args.profile, args.output.resolve())


if __name__ == "__main__":
    main()
