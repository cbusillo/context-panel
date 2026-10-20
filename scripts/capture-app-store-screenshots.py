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
import hashlib
import json
import plistlib
from pathlib import Path
import struct
import subprocess
import uuid
import time

import yaml

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build/app-store-capture"
PROJECT = BUILD / "project/ContextPanel.xcodeproj"
TARGETS = {"ios": "ContextPanelCompanion", "visionos": "ContextPanelCompanion", "watchos": "ContextPanelWatch", "tvos": "ContextPanelTV"}
SDKS = {"ios": "iphonesimulator", "visionos": "xrsimulator", "watchos": "watchsimulator", "tvos": "appletvsimulator"}
PROFILES = {
    "iphone": ("ios", "iPhone-17-Pro"),
    "iphone65": ("ios", "iPhone-16-Plus"),
    "ipad": ("ios", "iPad-Pro-13-inch-M4-8GB"),
    "visionpro": ("visionos", "Apple-Vision-Pro-4K"),
    "watch": ("watchos", "Apple-Watch-Ultra-2-49mm"),
    "tvos": ("tvos", "Apple-TV-4K-3rd-generation-1080p"),
}
RUNTIMES = {"ios": "iOS-27-0", "visionos": "xrOS-27-0", "watchos": "watchOS-27-0", "tvos": "tvOS-27-0"}


def run(*args: str, timeout: int = 180) -> str:
    print("+ " + " ".join(map(str, args)), flush=True)
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    print(result.stdout, end="", flush=True)
    result.check_returncode()
    return result.stdout.strip()


def prepare() -> None:
    PROJECT.parent.mkdir(parents=True, exist_ok=True)
    spec = yaml.safe_load((ROOT / "project.yml").read_text())
    for name, target in spec["targets"].items():
        target.pop("postBuildScripts", None)
        target["dependencies"] = [dependency for dependency in target.get("dependencies", [])
                                  if not dependency.get("embed")]
        settings = target.setdefault("settings", {}).setdefault("base", {})
        settings["CODE_SIGN_ENTITLEMENTS"] = ""
        if "INFOPLIST_FILE" in settings:
            settings["INFOPLIST_FILE"] = str(ROOT / settings["INFOPLIST_FILE"])
        if name in set(TARGETS.values()):
            target["sources"] += [{"path": "Tools/ContextPanelAppStoreCapture/ScreenshotFixture.swift"},
                                   {"path": "Tools/ContextPanelAppStoreCapture/SimulatorContent.swift"}]
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) CONTEXT_PANEL_SCREENSHOTS"
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id(name)
    for name, scheme in spec["schemes"].items():
        if name in set(TARGETS.values()):
            scheme["build"]["targets"] = {name: "all"}
    path = BUILD / "project.yml"
    path.write_text(yaml.safe_dump(spec, sort_keys=False))
    run("xcodegen", "generate", "--spec", str(path), "--project", str(PROJECT.parent),
        "--project-root", str(ROOT))


def bundle_id(target: str) -> str:
    return "com.shinycomputers.contextpanel.screenshots." + target.lower()


def build(platform: str) -> None:
    if not PROJECT.exists():
        raise SystemExit("Run prepare first")
    run("xcodebuild", "-quiet", "-project", str(PROJECT), "-scheme", TARGETS[platform],
        "-configuration", "Debug", "-sdk", SDKS[platform],
        "-destination", f"generic/platform={dict(ios='iOS Simulator', visionos='visionOS Simulator', watchos='watchOS Simulator', tvos='tvOS Simulator')[platform]}",
        "-derivedDataPath", str(BUILD / platform), "CODE_SIGNING_ALLOWED=NO", "build", timeout=1800)


def capture(profile: str, output: Path) -> None:
    platform, device = PROFILES[profile]
    if output.exists():
        raise SystemExit(f"Refusing to overwrite {output}")
    app = BUILD / platform / "Build/Products" / f"Debug-{SDKS[platform]}" / "Context Panel.app"
    if not app.is_dir():
        raise SystemExit(f"Build {platform} first")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != bundle_id(TARGETS[platform]):
        raise SystemExit("Refusing a bundle without the capture-only identifier")
    output.mkdir(parents=True)
    device_set = BUILD / "simulators"
    device_set.mkdir(exist_ok=True)
    prefix = ("xcrun", "simctl", "--set", str(device_set))
    name = "CP744-C2-" + uuid.uuid4().hex
    udid = run(*prefix, "create", name, "com.apple.CoreSimulator.SimDeviceType." + device,
               "com.apple.CoreSimulator.SimRuntime." + RUNTIMES[platform])
    uuid.UUID(udid)
    # Cleanup always addresses only this newly created simulator, never a name or 'booted'.
    try:
        run(*prefix, "boot", udid)
        run(*prefix, "bootstatus", udid, "-b", timeout=240)
        run(*prefix, "install", udid, str(app))
        files = []
        for appearance in (["dark"] if platform in {"watchos", "tvos"} else ["light", "dark"]):
            run(*prefix, "ui", udid, "appearance", appearance)
            if platform == "ios":
                run(*prefix, "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi",
                    "--wifiMode", "active", "--wifiBars", "3", "--batteryState", "charged", "--batteryLevel", "100")
            run(*prefix, "launch", "--terminate-running-process", udid, bundle_id(TARGETS[platform]),
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", appearance.capitalize())
            # simctl screenshot is a framebuffer capture, not a Mac desktop capture.
            # A short settle is only for SwiftUI layout/transition; images need visual review.
            time.sleep(6)
            path = output / f"{profile}-app-{appearance}.png"
            run(*prefix, "io", udid, "screenshot", "--type=png", "--mask=ignored", str(path))
            data = path.read_bytes()
            if data[:8] != b"\x89PNG\r\n\x1a\n":
                raise SystemExit("simctl did not produce a PNG")
            width, height = struct.unpack(">II", data[16:24])
            files.append({"file": path.name, "width": width, "height": height,
                          "sha256": hashlib.sha256(data).hexdigest(), "appearance": appearance})
        (output / "capture.json").write_text(json.dumps({
            "sourceCommit": run("git", "-C", str(ROOT), "rev-parse", "HEAD"),
            "xcode": run("xcodebuild", "-version"), "profile": profile,
            "runtime": RUNTIMES[platform], "deviceType": device,
            "fixtureDate": "2026-10-01T14:07:00Z", "mechanism": "simctl framebuffer, fixture-only capture build",
            "images": files,
        }, indent=2) + "\n")
    finally:
        try:
            run(*prefix, "shutdown", udid)
        finally:
            run(*prefix, "delete", udid)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare")
    builder = commands.add_parser("build")
    builder.add_argument("platform", choices=TARGETS)
    capturer = commands.add_parser("capture")
    capturer.add_argument("profile", choices=PROFILES)
    capturer.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
    elif args.command == "build":
        build(args.platform)
    else:
        capture(args.profile, args.output.resolve())


if __name__ == "__main__":
    main()
