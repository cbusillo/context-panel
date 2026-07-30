from __future__ import annotations

import json
import os
import plistlib
import re
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

from .models import (
    APP_BUNDLE_ID,
    WATCH_BUNDLE_ID,
    CommandResult,
    DeviceEvidence,
    MacEvidence,
    Runner,
    Target,
    classify_install,
    iso8601,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
CANONICAL_APP = Path("/Applications/Context Panel.app")
CANONICAL_INFO_PLIST = CANONICAL_APP / "Contents/Info.plist"
DEFAULT_STATE_ROOT = Path("~/Library/Application Support/Context Panel Validation").expanduser()


class SubprocessRunner:
    def run(
        self,
        args: list[str],
        *,
        timeout: int,
        environment: dict[str, str] | None = None,
    ) -> CommandResult:
        try:
            completed = subprocess.run(
                args,
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=timeout,
            )
            return CommandResult(completed.returncode, completed.stdout, completed.stderr)
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout if isinstance(error.stdout, str) else ""
            stderr = error.stderr if isinstance(error.stderr, str) else ""
            return CommandResult(124, stdout, stderr, timed_out=True)
        except OSError as error:
            return CommandResult(127, "", str(error))


def parse_key_values(output: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in output.splitlines():
        key, separator, value = line.strip().partition("=")
        if separator and key in {
            "baseline",
            "distribution",
            "app-cloudkit",
            "refresh-agent-cloudkit",
        }:
            parts = value.split()
            result[key] = parts[0] if parts else "unknown"
    return result


def collect_mac_evidence(runner: Runner, target: Target) -> MacEvidence:
    observed_version: str | None = None
    observed_build: str | None = None
    info_plist_exists = CANONICAL_INFO_PLIST.is_file()
    if info_plist_exists:
        try:
            with CANONICAL_INFO_PLIST.open("rb") as handle:
                info = plistlib.load(handle)
            observed_version = str(info.get("CFBundleShortVersionString") or "") or None
            observed_build = str(info.get("CFBundleVersion") or "") or None
        except (OSError, plistlib.InvalidFileException):
            pass
    install_state = (
        classify_install(observed_version, observed_build, target)
        if info_plist_exists
        else "not_installed"
    )
    result = runner.run(
        [
            str(REPO_ROOT / "scripts/context-panel-runtime-baseline.sh"),
            "check",
            "--require-production-runtime",
        ],
        timeout=180,
        environment=os.environ.copy(),
    )
    combined_output = result.stdout + "\n" + result.stderr
    parsed = parse_key_values(combined_output)
    baseline_result = parsed.get("baseline")
    if "OK: app process is running from installed runtime app" in combined_output:
        app_process_state = "running"
    elif (
        baseline_result == "OK"
        or "OK: no Context Panel processes are running" in combined_output
    ):
        app_process_state = "not_running"
    else:
        app_process_state = "unknown"
    app_cloudkit = parsed.get("app-cloudkit", "unknown")
    refresh_agent_cloudkit = parsed.get("refresh-agent-cloudkit", "unknown")
    identity_verified = (
        app_cloudkit == "Production" and refresh_agent_cloudkit == "Production"
    )
    identity_failed = install_state != "not_installed" and (
        app_cloudkit in {"Development", "absent"}
        or refresh_agent_cloudkit in {"Development", "absent"}
    )
    if result.timed_out:
        baseline_state = "unknown"
        reason = "canonical Production baseline timed out"
    elif baseline_result not in {"OK", "FAIL"}:
        baseline_state = "unknown"
        reason = "canonical Production baseline result is unavailable"
    elif (baseline_result == "OK") != (result.returncode == 0):
        baseline_state = "unknown"
        reason = "canonical Production baseline result is inconsistent"
    elif install_state == "not_installed":
        baseline_state = "install_missing"
        reason = "canonical app is not installed"
    elif identity_failed:
        baseline_state = "failed"
        reason = "canonical app or refresh agent is not a Production runtime"
    elif not identity_verified:
        baseline_state = "unknown"
        reason = "canonical Production identity could not be verified"
    elif install_state != "current":
        baseline_state = "identity_verified_install_mismatch"
        reason = "canonical Production identity verified; target build is not installed"
    elif baseline_result == "FAIL":
        baseline_state = "runtime_unverified"
        reason = "canonical target Production runtime receipt could not be verified"
    elif app_process_state == "running":
        baseline_state = "proven"
        reason = None
    elif app_process_state == "not_running":
        baseline_state = "identity_verified_app_not_running"
        reason = "canonical target Production identity verified; app is not running"
    else:
        baseline_state = "identity_verified"
        reason = "canonical target Production identity verified; app process state is unknown"
    return MacEvidence(
        observed_version,
        observed_build,
        install_state,
        baseline_state,
        app_process_state,
        parsed.get("distribution", "unknown"),
        app_cloudkit,
        refresh_agent_cloudkit,
        reason,
    )


def run_json_command(
    runner: Runner,
    args: list[str],
    *,
    timeout: int,
) -> tuple[CommandResult, dict[str, Any] | None, str]:
    with tempfile.TemporaryDirectory(prefix="context-panel-validation-") as temp_directory:
        output_path = Path(temp_directory) / "result.json"
        log_path = Path(temp_directory) / "command.log"
        result = runner.run(
            [*args, "--json-output", str(output_path), "--log-output", str(log_path)],
            timeout=timeout,
            environment=os.environ.copy(),
        )
        payload: dict[str, Any] | None = None
        if output_path.is_file():
            try:
                payload = json.loads(output_path.read_text())
            except (OSError, json.JSONDecodeError):
                payload = None
        diagnostics = result.stdout + "\n" + result.stderr
        if log_path.is_file():
            try:
                diagnostics += "\n" + log_path.read_text()
            except OSError:
                pass
        return result, payload, diagnostics


DEVICE_SPECS = {
    "iPhone": ("iOS", "iPhone", APP_BUNDLE_ID),
    "iPad": ("iOS", "iPad", APP_BUNDLE_ID),
    "Vision Pro": ("visionOS", "realityDevice", APP_BUNDLE_ID),
    "Apple Watch": ("watchOS", "appleWatch", WATCH_BUNDLE_ID),
    "Apple TV": ("tvOS", "appleTV", APP_BUNDLE_ID),
}


def descriptor_label(platform: str, device_type: str) -> str | None:
    for label, (expected_platform, expected_type, _) in DEVICE_SPECS.items():
        if platform == expected_platform and device_type == expected_type:
            return label
    return None


def parse_installed_app(
    payload: dict[str, Any] | None,
    expected_bundle_id: str,
) -> tuple[str | None, str | None]:
    apps = (payload or {}).get("result", {}).get("apps") or []
    matching_apps = [
        app for app in apps if app.get("bundleIdentifier") == expected_bundle_id
    ]
    if not matching_apps:
        return None, None
    app = matching_apps[0]
    version = str(app.get("version") or "") or None
    build = str(app.get("bundleVersion") or "") or None
    return version, build


def collect_device_evidence(runner: Runner, target: Target) -> tuple[DeviceEvidence, ...]:
    result, payload, _ = run_json_command(
        runner,
        ["xcrun", "devicectl", "list", "devices", "--timeout", "8"],
        timeout=12,
    )
    if result.returncode != 0 or payload is None:
        return tuple(
            DeviceEvidence(label, platform, None, None, "unknown", "unavailable", "CoreDevice unavailable")
            for label, (platform, _, _) in DEVICE_SPECS.items()
        )

    descriptors: list[dict[str, Any]] = []
    for raw in payload.get("result", {}).get("devices") or []:
        hardware = raw.get("hardwareProperties", {})
        if hardware.get("reality") != "physical":
            continue
        label = descriptor_label(str(hardware.get("platform")), str(hardware.get("deviceType")))
        if label is not None:
            descriptors.append(raw)

    evidence: list[DeviceEvidence] = []
    for label, (platform, device_type, bundle_id) in DEVICE_SPECS.items():
        matches = [
            descriptor
            for descriptor in descriptors
            if descriptor.get("hardwareProperties", {}).get("platform") == platform
            and descriptor.get("hardwareProperties", {}).get("deviceType") == device_type
        ]
        if not matches:
            evidence.append(
                DeviceEvidence(label, platform, None, None, "unknown", "not_found", "no physical device known")
            )
            continue
        matches.sort(key=lambda item: str(item.get("identifier", "")))
        for index, descriptor in enumerate(matches, start=1):
            display_label = label if len(matches) == 1 else f"{label} {index}"
            identifier = str(descriptor.get("identifier") or "")
            connection = descriptor.get("connectionProperties", {})
            device_properties = descriptor.get("deviceProperties", {})
            booted = device_properties.get("bootState") == "booted"
            connected = connection.get("tunnelState") == "connected"
            if not booted:
                evidence.append(
                    DeviceEvidence(
                        display_label,
                        platform,
                        None,
                        None,
                        "unknown",
                        "asleep",
                        "will check when awake",
                    )
                )
                continue
            if not connected:
                evidence.append(
                    DeviceEvidence(
                        display_label,
                        platform,
                        None,
                        None,
                        "unknown",
                        "not_reachable",
                        "will check when reachable",
                    )
                )
                continue
            app_result, app_payload, diagnostics = run_json_command(
                runner,
                [
                    "xcrun",
                    "devicectl",
                    "device",
                    "info",
                    "apps",
                    "--device",
                    identifier,
                    "--bundle-id",
                    bundle_id,
                    "--include-default-apps",
                    "--timeout",
                    "5",
                ],
                timeout=8,
            )
            if app_result.returncode != 0 or app_payload is None:
                condition = (
                    "locked"
                    if re.search(r"\blocked\b", diagnostics.casefold())
                    else "not_reachable"
                )
                note = "will check when unlocked" if condition == "locked" else "will check when reachable"
                evidence.append(
                    DeviceEvidence(display_label, platform, None, None, "unknown", condition, note)
                )
                continue
            observed_version, observed_build = parse_installed_app(app_payload, bundle_id)
            install_state = (
                "not_installed"
                if observed_version is None and observed_build is None
                else classify_install(observed_version, observed_build, target)
            )
            note = {
                "current": "target build installed",
                "old": "target build not installed yet",
                "superseded": "newer build installed; target evidence superseded",
                "different": "different build installed",
                "not_installed": "Context Panel is not installed",
            }.get(install_state, "install evidence unavailable")
            evidence.append(
                DeviceEvidence(
                    display_label,
                    platform,
                    observed_version,
                    observed_build,
                    install_state,
                    "reachable",
                    note,
                )
            )
    return tuple(evidence)


class SessionStateStore:
    def __init__(self, root: Path | None = None):
        configured = os.environ.get("CONTEXT_PANEL_VALIDATION_STATE_ROOT", "").strip()
        self.root = root or (Path(configured).expanduser() if configured else DEFAULT_STATE_ROOT)

    def path(self, target: Target) -> Path:
        return self.root / f"{target.version}-{target.build_number}.json"

    def watch_restart_recorded_at(self, target: Target) -> str | None:
        path = self.path(target)
        if not path.is_file():
            return None
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            return None
        recorded_at = payload.get("watchRestartRecordedAt")
        return recorded_at if isinstance(recorded_at, str) else None

    def watch_restart_recorded(self, target: Target) -> bool:
        return self.watch_restart_recorded_at(target) is not None

    def record_watch_restart(self, target: Target, recorded_at: datetime) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        payload = {
            "schemaVersion": 1,
            "version": target.version,
            "buildNumber": target.build_number,
            "watchRestartRecordedAt": iso8601(recorded_at),
        }
        destination = self.path(target)
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        temporary.replace(destination)
