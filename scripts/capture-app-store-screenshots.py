#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["PyYAML>=6"]
# ///
"""Build disposable fixture-only apps and capture owned headless simulators.

No installed Mac app, desktop, browser, accounts, or App Store APIs are used.
See Resources/AppStore/Screenshots/horizon-capture/README.md for operator steps.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import plistlib
from pathlib import Path
import struct
import subprocess
import sys
import uuid
import time

import yaml

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
RUNTIMES = {"ios": "iOS-27-0", "visionos": "xrOS-27-0", "watchos": "watchOS-27-0", "tvos": "tvOS-27-0"}


def run(*args: str, timeout: int = 180) -> str:
    print("+ " + " ".join(map(str, args)), flush=True)
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    print(result.stdout, end="", flush=True)
    print(result.stderr, end="", flush=True)
    result.check_returncode()
    return result.stdout.strip()


def unsigned_settings(settings: dict) -> dict:
    base = {key: value for key, value in settings.get("base", {}).items()
            if not key.startswith(("CODE_SIGN", "PROVISIONING_PROFILE")) and key != "DEVELOPMENT_TEAM"}
    return {"base": {**base, "CODE_SIGNING_ALLOWED": "NO"}}


def capture_spec(original: dict) -> dict:
    roots = set(TARGETS.values())
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


def validate_capture_spec(spec: dict) -> None:
    for settings in [spec["settings"], *(target["settings"] for target in spec["targets"].values())]:
        if settings.get("configs"):
            raise ValueError("Capture projects cannot inherit shipping configuration overrides")
        for key, value in settings["base"].items():
            if key == "CODE_SIGNING_ALLOWED" and value == "NO":
                continue
            if key.startswith(("CODE_SIGN", "PROVISIONING_PROFILE")) or key == "DEVELOPMENT_TEAM":
                raise ValueError("Capture projects cannot carry signing or provisioning settings")
    for name, target in spec["targets"].items():
        settings = target["settings"]["base"]
        if target.get("postBuildScripts") or target.get("info"):
            raise ValueError("Capture targets cannot stamp builds or generate source-tree plists")
        if any(dependency.get("embed") for dependency in target.get("dependencies", [])):
            raise ValueError("Capture targets cannot embed extensions")
        if name in TARGETS.values():
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
    validate_capture_spec(spec)
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


def build(platform: str) -> None:
    source = clean_commit()
    if not PROJECT.exists() or json.loads((BUILD / "prepared.json").read_text())["sourceCommit"] != source:
        raise SystemExit("Run prepare at the current source commit first")
    build_receipt(platform).unlink(missing_ok=True)
    run("xcodebuild", "-quiet", "-project", str(PROJECT), "-scheme", TARGETS[platform],
        "-configuration", "Debug", "-sdk", SDKS[platform],
        "-destination", f"generic/platform={dict(ios='iOS Simulator', visionos='visionOS Simulator', watchos='watchOS Simulator', tvos='tvOS Simulator')[platform]}",
        "-derivedDataPath", str(BUILD / platform), "CODE_SIGNING_ALLOWED=NO", "build", timeout=1800)
    if clean_commit() != source:
        raise SystemExit("Source changed during the build")
    build_receipt(platform).write_text(json.dumps({"sourceCommit": source,
        "bundleSHA256": bundle_digest(app_path(platform))}) + "\n")


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


def capture(profile: str, output: Path, device_set: Path | None = None) -> None:
    platform, device, expected_size = PROFILES[profile]
    if output.exists():
        raise SystemExit(f"Refusing to overwrite {output}")
    if device_set is not None and not device_set.is_absolute():
        raise SystemExit("--device-set must be absolute")
    source = clean_commit()
    receipt_path = build_receipt(platform)
    if not receipt_path.is_file():
        raise SystemExit(f"Build {platform} at this source commit first")
    receipt = json.loads(receipt_path.read_text())
    app = app_path(platform)
    if not app.is_dir():
        raise SystemExit(f"Build {platform} first")
    if receipt["sourceCommit"] != source or receipt["bundleSHA256"] != bundle_digest(app):
        raise SystemExit("Capture build does not match the current committed source and bundle")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != bundle_id(TARGETS[platform]):
        raise SystemExit("Refusing a bundle without the capture-only identifier")
    output.mkdir(parents=True)
    # Q599 authorizes CoreSimulator's normal private storage. Leave --set out
    # for that supported default; explicit sets remain useful for inert tests.
    if device_set is not None:
        device_set.mkdir(parents=True, exist_ok=True)
    prefix = ("xcrun", "simctl") + (("--set", str(device_set)) if device_set else ())
    name = "CP744-C2-" + uuid.uuid4().hex
    inventory = device_inventory(prefix)
    before = {entry["udid"] for entries in inventory.values() for entry in entries}
    if any(entry["name"] == name for entries in inventory.values() for entry in entries):
        raise SystemExit("Simulator name collision; no device was created")
    # A failed create can allocate a device. Reconcile only a newly observed exact
    # name/type/runtime match and delete by UDID; never retry the refused action.
    try:
        udid = run(*prefix, "create", name, "com.apple.CoreSimulator.SimDeviceType." + device,
                   "com.apple.CoreSimulator.SimRuntime." + RUNTIMES[platform])
        uuid.UUID(udid)
        run(*prefix, "boot", udid)
        run(*prefix, "bootstatus", udid, "-b", timeout=240)
        run(*prefix, "install", udid, str(app))
        files = []
        for appearance in (["dark"] if platform in {"watchos", "tvos"} else ["light", "dark"]):
            if platform not in {"watchos", "tvos"}:
                run(*prefix, "ui", udid, "appearance", appearance)
            if platform == "ios":
                run(*prefix, "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi",
                    "--wifiMode", "active", "--wifiBars", "3", "--batteryState", "charged", "--batteryLevel", "100")
            run(*prefix, "launch", "--terminate-running-process", udid, bundle_id(TARGETS[platform]))
            # simctl screenshot is a framebuffer capture, not a Mac desktop capture.
            # A short settle is only for SwiftUI layout/transition; images need visual review.
            time.sleep(6)
            path = output / f"{profile}-app-{appearance}.png"
            run(*prefix, "io", udid, "screenshot", "--type=png", "--mask=ignored", str(path))
            data = path.read_bytes()
            if data[:8] != b"\x89PNG\r\n\x1a\n":
                raise SystemExit("simctl did not produce a PNG")
            width, height = struct.unpack(">II", data[16:24])
            if (width, height) != expected_size:
                raise SystemExit(f"Unexpected capture size {(width, height)}; expected {expected_size}")
            files.append({"file": path.name, "width": width, "height": height,
                          "sha256": hashlib.sha256(data).hexdigest(), "appearance": appearance})
        capture_record = {
            "sourceCommit": receipt["sourceCommit"], "bundleSHA256": receipt["bundleSHA256"],
            "xcode": run("xcodebuild", "-version"), "profile": profile,
            "runtime": RUNTIMES[platform], "deviceType": device,
            "simulatorUDID": udid,
            "deviceSet": str(device_set) if device_set else "CoreSimulator default private storage",
            "mechanism": "simctl framebuffer, fixture-only capture build",
            "images": files,
        }
    finally:
        primary_error = sys.exception()
        try:
            owned = new_owned_device(device_inventory(prefix), before, name, platform, device)
            if owned:
                owned_id = owned["udid"]
                uuid.UUID(owned_id)
                if owned.get("state") == "Booted":
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare")
    builder = commands.add_parser("build")
    builder.add_argument("platform", choices=TARGETS)
    capturer = commands.add_parser("capture")
    capturer.add_argument("profile", choices=PROFILES)
    capturer.add_argument("--output", required=True, type=Path)
    capturer.add_argument("--device-set", type=Path, help="Absolute device set; use only an approved storage route")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
    elif args.command == "build":
        build(args.platform)
    else:
        capture(args.profile, args.output.resolve(), args.device_set)


if __name__ == "__main__":
    main()
