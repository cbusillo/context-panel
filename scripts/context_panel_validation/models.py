from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Protocol


ASC_PLATFORMS = ("MAC_OS", "IOS", "VISION_OS", "TV_OS")
APP_BUNDLE_ID = "com.shinycomputers.contextpanel"
WATCH_BUNDLE_ID = "com.shinycomputers.contextpanel.watch"

EXIT_OK = 0
EXIT_INTERNAL = 1
EXIT_READY = 10
EXIT_BLOCKED = 20
EXIT_UNKNOWN = 30


@dataclass(frozen=True)
class Target:
    version: str
    build_number: str


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool = False


class Runner(Protocol):
    def run(
        self,
        args: list[str],
        *,
        timeout: int,
        environment: dict[str, str] | None = None,
    ) -> CommandResult: ...


@dataclass(frozen=True)
class ASCPlatformEvidence:
    platform: str
    build_state: str
    testflight_state: str
    processing_state: str | None = None
    reason: str | None = None


@dataclass(frozen=True)
class ASCEvidence:
    status: str
    source: str
    platforms: tuple[ASCPlatformEvidence, ...]
    reason: str | None = None


@dataclass(frozen=True)
class MacEvidence:
    observed_version: str | None
    observed_build: str | None
    install_state: str
    baseline_state: str
    app_process_state: str
    distribution: str
    app_cloudkit: str
    refresh_agent_cloudkit: str
    reason: str | None = None


@dataclass(frozen=True)
class DeviceEvidence:
    label: str
    platform: str
    observed_version: str | None
    observed_build: str | None
    install_state: str
    condition: str
    note: str

    def public_dict(self) -> dict[str, Any]:
        return {
            "label": self.label,
            "platform": self.platform,
            "observedVersion": self.observed_version,
            "observedBuild": self.observed_build,
            "installState": self.install_state,
            "condition": self.condition,
            "note": self.note,
        }


@dataclass(frozen=True)
class OperatorAction:
    device: str
    estimate: str
    instruction: str


@dataclass(frozen=True)
class ValidationReport:
    generated_at: str
    target: Target
    state: str
    stage: str
    headline: str
    exit_code: int
    asc: ASCEvidence
    mac: MacEvidence
    devices: tuple[DeviceEvidence, ...]
    actions: tuple[OperatorAction, ...]
    watch_restart_recorded_at: str | None
    limitations: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "generatedAt": self.generated_at,
            "target": {
                "version": self.target.version,
                "buildNumber": self.target.build_number,
            },
            "summary": {
                "state": self.state,
                "stage": self.stage,
                "headline": self.headline,
                "exitCode": self.exit_code,
                "needsHumanAction": bool(self.actions),
            },
            "evidence": {
                "appStoreConnect": {
                    "status": self.asc.status,
                    "source": self.asc.source,
                    "reason": self.asc.reason,
                    "platforms": [
                        {
                            "platform": item.platform,
                            "buildState": item.build_state,
                            "testFlightState": item.testflight_state,
                            "processingState": item.processing_state,
                            "reason": item.reason,
                        }
                        for item in self.asc.platforms
                    ],
                },
                "canonicalMacProductionRuntime": {
                    "observedVersion": self.mac.observed_version,
                    "observedBuild": self.mac.observed_build,
                    "installState": self.mac.install_state,
                    "baselineState": self.mac.baseline_state,
                    "appProcessState": self.mac.app_process_state,
                    "distribution": self.mac.distribution,
                    "appCloudKit": self.mac.app_cloudkit,
                    "refreshAgentCloudKit": self.mac.refresh_agent_cloudkit,
                    "reason": self.mac.reason,
                },
                "devices": [item.public_dict() for item in self.devices],
                "watchRestartAttestation": {
                    "recordedAt": self.watch_restart_recorded_at,
                    "proof": "operator_attestation" if self.watch_restart_recorded_at else "none",
                },
            },
            "actions": [
                {
                    "device": item.device,
                    "estimate": item.estimate,
                    "instruction": item.instruction,
                }
                for item in self.actions
            ],
            "limitations": list(self.limitations),
        }


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso8601(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def numeric_version(value: str) -> tuple[int, ...] | None:
    try:
        return tuple(int(component) for component in value.split("."))
    except ValueError:
        return None


def classify_install(
    observed_version: str | None,
    observed_build: str | None,
    target: Target,
) -> str:
    if not observed_version or not observed_build:
        return "unknown"
    if observed_version == target.version and observed_build == target.build_number:
        return "current"
    observed_version_key = numeric_version(observed_version)
    target_version_key = numeric_version(target.version)
    if observed_version_key is None or target_version_key is None:
        return "different"
    if observed_version_key > target_version_key:
        return "superseded"
    if observed_version_key < target_version_key:
        return "old"
    if observed_build.isdigit() and target.build_number.isdigit():
        if int(observed_build) > int(target.build_number):
            return "superseded"
        if int(observed_build) < int(target.build_number):
            return "old"
    return "different"


def install_counts(
    mac: MacEvidence,
    devices: tuple[DeviceEvidence, ...],
) -> tuple[int, int, int]:
    states = [
        mac.install_state,
        *(device.install_state for device in devices if device.condition != "not_found"),
    ]
    known_states = [state for state in states if state != "unknown"]
    return (
        sum(1 for state in known_states if state == "current"),
        len(known_states),
        len(states) - len(known_states),
    )


def build_report(
    target: Target,
    asc: ASCEvidence,
    mac: MacEvidence,
    devices: tuple[DeviceEvidence, ...],
    watch_restart_recorded_at: str | None,
    generated_at: datetime,
) -> ValidationReport:
    blocked_reasons: list[str] = []
    if mac.baseline_state == "failed":
        blocked_reasons.append("Mac publisher is not a verified Production runtime")
    if mac.install_state == "superseded":
        blocked_reasons.append("Mac moved to a newer build")
    blocked_platform = next(
        (
            item
            for item in asc.platforms
            if item.build_state in {"failed", "invalid", "expired"}
        ),
        None,
    )
    if blocked_platform is not None:
        blocked_reasons.append(f"{blocked_platform.platform} build is {blocked_platform.build_state}")
    superseded = next((item for item in devices if item.install_state == "superseded"), None)
    if superseded is not None:
        blocked_reasons.append(f"{superseded.label} moved to a newer build")

    asc_build_states = {item.build_state for item in asc.platforms}
    testflight_states = {item.testflight_state for item in asc.platforms}
    install_states = {mac.install_state, *(item.install_state for item in devices)}
    device_conditions = {item.condition for item in devices}
    no_tool_evidence = (
        bool(devices)
        and asc.status == "unavailable"
        and mac.baseline_state == "unknown"
        and mac.install_state == "unknown"
        and all(item.condition == "unavailable" for item in devices)
    )
    asc_unknown = (
        asc.status == "unavailable"
        or "unknown" in asc_build_states
        or "unknown" in testflight_states
    )
    mac_unknown = (
        mac.baseline_state in {"unknown", "identity_verified", "runtime_unverified"}
        or mac.install_state == "unknown"
    )
    device_install_unknown = any(
        item.install_state == "unknown" and item.condition == "reachable"
        for item in devices
    )
    upstream_unknown = asc_unknown or mac_unknown or device_install_unknown
    waiting_on_processing = "processing" in asc_build_states or "missing" in asc_build_states
    waiting_on_testflight = "waiting_for_assignment" in testflight_states
    waiting_on_install = bool(install_states & {"old", "different", "not_installed"})
    waiting_on_device = bool(
        device_conditions & {"locked", "asleep", "not_reachable", "unavailable"}
    )
    machine_waiting = (
        waiting_on_processing
        or waiting_on_testflight
        or waiting_on_install
        or waiting_on_device
    )

    actions: list[OperatorAction] = []
    if (
        mac.baseline_state == "identity_verified_app_not_running"
        and mac.install_state == "current"
        and not blocked_reasons
        and not upstream_unknown
        and not machine_waiting
    ):
        actions.append(
            OperatorAction("Mac", "about 1 minute", "Open the canonical Mac app once, then rerun status.")
        )
    watch_current = any(
        item.platform == "watchOS" and item.install_state == "current" for item in devices
    )
    if (
        watch_current
        and watch_restart_recorded_at is None
        and not blocked_reasons
        and not upstream_unknown
        and not machine_waiting
    ):
        actions.append(
            OperatorAction(
                "Apple Watch",
                "about 3 minutes",
                (
                    "Restart the Watch once with placements intact, then record it with "
                    f"scripts/context-panel-validation.py record-watch-restart "
                    f"--version {target.version} --build-number {target.build_number}."
                ),
            )
        )

    if blocked_reasons:
        state, stage, exit_code = "blocked", "blocked", EXIT_BLOCKED
        closing = f"blocked: {blocked_reasons[0]}"
    elif no_tool_evidence:
        state, stage, exit_code = "unknown", "not enough evidence", EXIT_UNKNOWN
        closing = "not enough evidence: local status tools are unavailable"
    elif upstream_unknown:
        state, stage, exit_code = "unknown", "not enough evidence", EXIT_UNKNOWN
        if asc_unknown:
            closing = "not enough evidence: App Store Connect state is unknown"
        elif mac_unknown:
            closing = "not enough evidence: canonical Mac state is unknown"
        else:
            closing = "not enough evidence: a device install state is unknown"
    elif waiting_on_processing:
        state, stage, exit_code = "waiting", "waiting on Apple processing", EXIT_OK
        closing = "nothing needs you right now"
    elif waiting_on_testflight:
        state, stage, exit_code = "waiting", "waiting on TestFlight availability", EXIT_OK
        closing = "nothing needs you right now"
    elif waiting_on_install:
        state, stage, exit_code = "waiting", "waiting on install", EXIT_OK
        closing = "nothing needs you right now"
    elif waiting_on_device:
        state, stage, exit_code = "waiting", "waiting on device", EXIT_OK
        closing = "nothing needs you right now"
    elif actions:
        state, stage, exit_code = "ready_for_you", "ready for you", EXIT_READY
        closing = f"{len(actions)} action{'s' if len(actions) != 1 else ''} ready for you"
    else:
        state, stage, exit_code = "complete_for_slice", "available evidence collected", EXIT_OK
        closing = "nothing needs you right now"

    current_count, known_count, unknown_count = install_counts(mac, devices)
    if known_count:
        install_summary = f"{current_count} of {known_count} known installs current"
    else:
        install_summary = "no install versions known"
    if unknown_count:
        install_summary += f" · {unknown_count} install{'s' if unknown_count != 1 else ''} unknown"
    headline = (
        f"{target.version} ({target.build_number}) — {stage} · "
        f"{install_summary} · {closing}"
    )
    return ValidationReport(
        iso8601(generated_at),
        target,
        state,
        stage,
        headline,
        exit_code,
        asc,
        mac,
        devices,
        tuple(actions),
        watch_restart_recorded_at,
        (
            "Extension runtime receipts are not proven by this slice.",
            "Companion CloudKit reads are not proven by this slice.",
            "Visual approval is not proven by this slice.",
        ),
    )


def observed_build(version: str | None, build: str | None) -> str:
    return f"{version} ({build})" if version and build else "—"


def asc_summary(asc: ASCEvidence) -> str:
    available = sum(
        1
        for item in asc.platforms
        if item.build_state == "valid" and item.testflight_state == "available"
    )
    return "ASC unknown" if asc.status == "unavailable" else f"ASC {available}/{len(asc.platforms)} available"


def render_text(report: ValidationReport) -> str:
    lines = [report.headline]
    mac_summary = {
        "proven": "Mac target Production runtime proven",
        "identity_verified_app_not_running": "Mac target Production identity verified; app not running",
        "identity_verified": "Mac target Production identity verified; app state unknown",
        "identity_verified_install_mismatch": "Mac Production identity verified; target build not installed",
        "install_missing": "Mac target build not installed",
        "runtime_unverified": "Mac target Production runtime receipt unknown",
        "failed": "Mac Production identity blocked",
        "unknown": "Mac Production runtime unknown",
    }.get(report.mac.baseline_state, "Mac Production runtime unknown")
    lines.append(f"{asc_summary(report.asc)} · {mac_summary} · extension runtime not proven by this slice")
    lines.extend(["", "DEVICE         OBSERVED BUILD                 APP          CONDITION       NOTE"])
    lines.append(
        f"{'Mac':14} {observed_build(report.mac.observed_version, report.mac.observed_build)[:30]:30} "
        f"{report.mac.install_state:12} {'canonical':15} {report.mac.reason or 'Production baseline checked'}"
    )
    for item in report.devices:
        lines.append(
            f"{item.label[:14]:14} {observed_build(item.observed_version, item.observed_build)[:30]:30} "
            f"{item.install_state[:12]:12} {item.condition[:15]:15} {item.note}"
        )
    if report.actions:
        lines.extend(["", "Ready for you"])
        for action in report.actions:
            lines.extend(["", f"  {action.device} — {action.estimate}", f"    · {action.instruction}"])
    if report.watch_restart_recorded_at:
        lines.extend(
            [
                "",
                f"Watch restart attestation: recorded {report.watch_restart_recorded_at}",
                "This does not prove complication runtime.",
            ]
        )
    lines.extend(["", "Not proven by this slice:"])
    lines.extend(f"  · {item}" for item in report.limitations)
    return "\n".join(lines)
