from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, Iterator
import uuid

from .models import (
    EXIT_BLOCKED,
    EXIT_OK,
    EXIT_UNKNOWN,
    Target,
    ValidationReport,
    install_counts,
    iso8601,
)


APP_GROUP_ID = "MM5YXC7T6E.group.com.shinycomputers.contextpanel"
DEFAULT_STATE_ROOT = (
    Path.home()
    / "Library"
    / "Group Containers"
    / APP_GROUP_ID
    / "Context Panel"
    / "Validation"
    / "Coordinator"
)
LEGACY_STATE_ROOT = Path("~/Library/Application Support/Context Panel Validation").expanduser()
SESSION_SCHEMA_VERSION = 1
DEFAULT_DURATION_HOURS = 72
MAXIMUM_DURATION_HOURS = 168
DEFAULT_RETENTION_DAYS = 30
MAXIMUM_RETENTION_DAYS = 90
MAXIMUM_EVENT_COUNT = 128

RUNTIME_SURFACES = (
    "ios.app",
    "ios.widget",
    "ipados.app",
    "ipados.widget",
    "macos.app",
    "macos.refresh-agent",
    "macos.widget",
    "tvos.app",
    "tvos.top-shelf",
    "visionos.app",
    "visionos.widget",
    "watchos.app",
    "watchos.complication",
)
SESSION_LIFECYCLES = {
    "active",
    "paused",
    "stopped",
    "expired",
    "blocked",
    "superseded",
    "completed",
}
ACTIVE_SESSION_LIFECYCLES = {"active", "paused"}
TERMINAL_SESSION_LIFECYCLES = SESSION_LIFECYCLES - ACTIVE_SESSION_LIFECYCLES
SESSION_EVENT_KINDS = {
    "started",
    "paused",
    "resumed",
    "stopped",
    "expired",
    "blocked",
    "superseded",
    "completed",
    "watch-restart-recorded",
}
PAUSE_REASONS = {
    "blocked-decision",
    "external-wait",
    "hardware-unavailable",
    "operator-unavailable",
}
SESSION_REASON_CODES = PAUSE_REASONS | {
    "deadline-expired",
    "evidence-complete",
    "explicit-block",
    "newer-build-observed",
    "operator-stopped",
}
EVENT_REASON_CODES = {
    "started": {None},
    "paused": PAUSE_REASONS,
    "resumed": {None},
    "stopped": {"operator-stopped"},
    "expired": {"deadline-expired"},
    "blocked": {"explicit-block"},
    "superseded": {"newer-build-observed"},
    "completed": {"evidence-complete"},
    "watch-restart-recorded": {None},
}
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")
BUILD_PATTERN = re.compile(r"^[0-9]+$")


class CoordinatorSessionError(RuntimeError):
    pass


class CoordinatorSessionConflictError(CoordinatorSessionError):
    pass


class CoordinatorSessionStateError(CoordinatorSessionError):
    pass


class CoordinatorSessionTransitionError(CoordinatorSessionError):
    pass


def parse_iso8601(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def normalize_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise CoordinatorSessionStateError("coordinator session timestamp must include a timezone")
    return value.astimezone(timezone.utc)


def validate_target(target: Target) -> None:
    if (
        not isinstance(target.version, str)
        or not VERSION_PATTERN.fullmatch(target.version)
        or not isinstance(target.build_number, str)
        or not BUILD_PATTERN.fullmatch(target.build_number)
    ):
        raise CoordinatorSessionStateError("coordinator session target is invalid")


@dataclass(frozen=True)
class CoordinatorSessionEvent:
    kind: str
    occurred_at: str
    reason: str | None = None

    def to_dict(self) -> dict[str, object]:
        return {
            "kind": self.kind,
            "occurredAt": self.occurred_at,
            "reason": self.reason,
        }

    @classmethod
    def from_dict(cls, payload: object) -> CoordinatorSessionEvent:
        if not isinstance(payload, dict) or set(payload) != {"kind", "occurredAt", "reason"}:
            raise CoordinatorSessionStateError("coordinator session event is invalid")
        event = cls(
            kind=payload.get("kind"),
            occurred_at=payload.get("occurredAt"),
            reason=payload.get("reason"),
        )
        if (
            event.kind not in SESSION_EVENT_KINDS
            or parse_iso8601(event.occurred_at) is None
            or event.reason not in EVENT_REASON_CODES[event.kind]
        ):
            raise CoordinatorSessionStateError("coordinator session event is invalid")
        return event


@dataclass(frozen=True)
class CoordinatorSessionState:
    schema_version: int
    id: str
    target: Target
    lifecycle: str
    created_at: str
    updated_at: str
    expires_at: str
    retention_expires_at: str
    paused_at: str | None
    ended_at: str | None
    lifecycle_reason: str | None
    accumulated_pause_seconds: int
    requested_surfaces: tuple[str, ...]
    watch_restart_recorded_at: str | None
    revision: int
    events: tuple[CoordinatorSessionEvent, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "schemaVersion": self.schema_version,
            "id": self.id,
            "target": {
                "version": self.target.version,
                "buildNumber": self.target.build_number,
            },
            "lifecycle": self.lifecycle,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
            "expiresAt": self.expires_at,
            "retentionExpiresAt": self.retention_expires_at,
            "pausedAt": self.paused_at,
            "endedAt": self.ended_at,
            "lifecycleReason": self.lifecycle_reason,
            "accumulatedPauseSeconds": self.accumulated_pause_seconds,
            "requestedSurfaces": list(self.requested_surfaces),
            "watchRestartRecordedAt": self.watch_restart_recorded_at,
            "revision": self.revision,
            "events": [event.to_dict() for event in self.events],
        }

    def public_dict(self) -> dict[str, object]:
        return {
            "schemaVersion": self.schema_version,
            "id": self.id,
            "target": {
                "version": self.target.version,
                "buildNumber": self.target.build_number,
            },
            "lifecycle": self.lifecycle,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
            "expiresAt": self.expires_at,
            "retentionExpiresAt": self.retention_expires_at,
            "pausedAt": self.paused_at,
            "endedAt": self.ended_at,
            "lifecycleReason": self.lifecycle_reason,
            "accumulatedPauseSeconds": self.accumulated_pause_seconds,
            "requestedSurfaces": list(self.requested_surfaces),
            "watchRestartRecordedAt": self.watch_restart_recorded_at,
            "revision": self.revision,
            "eventCount": len(self.events),
        }

    @classmethod
    def from_dict(cls, payload: object) -> CoordinatorSessionState:
        expected_keys = {
            "schemaVersion",
            "id",
            "target",
            "lifecycle",
            "createdAt",
            "updatedAt",
            "expiresAt",
            "retentionExpiresAt",
            "pausedAt",
            "endedAt",
            "lifecycleReason",
            "accumulatedPauseSeconds",
            "requestedSurfaces",
            "watchRestartRecordedAt",
            "revision",
            "events",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise CoordinatorSessionStateError("coordinator session state is invalid")
        target_payload = payload.get("target")
        if not isinstance(target_payload, dict) or set(target_payload) != {
            "version",
            "buildNumber",
        }:
            raise CoordinatorSessionStateError("coordinator session state is invalid")
        events_payload = payload.get("events")
        requested_surfaces = payload.get("requestedSurfaces")
        if not isinstance(events_payload, list) or not isinstance(requested_surfaces, list):
            raise CoordinatorSessionStateError("coordinator session state is invalid")
        state = cls(
            schema_version=payload.get("schemaVersion"),
            id=payload.get("id"),
            target=Target(
                version=target_payload.get("version"),
                build_number=target_payload.get("buildNumber"),
            ),
            lifecycle=payload.get("lifecycle"),
            created_at=payload.get("createdAt"),
            updated_at=payload.get("updatedAt"),
            expires_at=payload.get("expiresAt"),
            retention_expires_at=payload.get("retentionExpiresAt"),
            paused_at=payload.get("pausedAt"),
            ended_at=payload.get("endedAt"),
            lifecycle_reason=payload.get("lifecycleReason"),
            accumulated_pause_seconds=payload.get("accumulatedPauseSeconds"),
            requested_surfaces=tuple(requested_surfaces),
            watch_restart_recorded_at=payload.get("watchRestartRecordedAt"),
            revision=payload.get("revision"),
            events=tuple(CoordinatorSessionEvent.from_dict(event) for event in events_payload),
        )
        validate_session_state(state)
        return state


def validate_session_state(state: CoordinatorSessionState) -> None:
    validate_target(state.target)
    timestamps = {
        "created": parse_iso8601(state.created_at),
        "updated": parse_iso8601(state.updated_at),
        "expires": parse_iso8601(state.expires_at),
        "retention": parse_iso8601(state.retention_expires_at),
        "paused": parse_iso8601(state.paused_at) if state.paused_at is not None else None,
        "ended": parse_iso8601(state.ended_at) if state.ended_at is not None else None,
        "watch": (
            parse_iso8601(state.watch_restart_recorded_at)
            if state.watch_restart_recorded_at is not None
            else None
        ),
    }
    try:
        uuid.UUID(state.id)
    except (AttributeError, TypeError, ValueError) as error:
        raise CoordinatorSessionStateError("coordinator session state is invalid") from error
    if (
        state.schema_version != SESSION_SCHEMA_VERSION
        or state.lifecycle not in SESSION_LIFECYCLES
        or any(timestamps[key] is None for key in ("created", "updated", "expires", "retention"))
        or timestamps["created"] > timestamps["updated"]
        or timestamps["created"] >= timestamps["expires"]
        or timestamps["expires"] > timestamps["retention"]
        or timestamps["updated"] > timestamps["retention"]
        or not isinstance(state.accumulated_pause_seconds, int)
        or isinstance(state.accumulated_pause_seconds, bool)
        or state.accumulated_pause_seconds < 0
        or not isinstance(state.revision, int)
        or isinstance(state.revision, bool)
        or state.revision < 1
        or any(not isinstance(surface, str) for surface in state.requested_surfaces)
        or state.requested_surfaces != tuple(sorted(set(state.requested_surfaces)))
        or any(surface not in RUNTIME_SURFACES for surface in state.requested_surfaces)
        or not state.events
        or len(state.events) > MAXIMUM_EVENT_COUNT
        or state.events[0].kind != "started"
        or (state.lifecycle_reason is not None and state.lifecycle_reason not in SESSION_REASON_CODES)
        or (state.watch_restart_recorded_at is not None and timestamps["watch"] is None)
    ):
        raise CoordinatorSessionStateError("coordinator session state is invalid")
    event_times = [parse_iso8601(event.occurred_at) for event in state.events]
    if (
        event_times != sorted(event_times)
        or event_times[0] != timestamps["created"]
        or event_times[-1] > timestamps["updated"]
    ):
        raise CoordinatorSessionStateError("coordinator session state is invalid")
    if (
        (timestamps["paused"] is not None and timestamps["paused"] > timestamps["updated"])
        or (timestamps["ended"] is not None and timestamps["ended"] > timestamps["updated"])
        or (timestamps["watch"] is not None and timestamps["watch"] > timestamps["updated"])
    ):
        raise CoordinatorSessionStateError("coordinator session state is invalid")
    if state.lifecycle == "active" and (
        state.paused_at is not None or state.ended_at is not None or state.lifecycle_reason is not None
    ):
        raise CoordinatorSessionStateError("coordinator session state is invalid")
    if state.lifecycle == "active" and timestamps["updated"] > timestamps["expires"]:
        raise CoordinatorSessionStateError("coordinator session state is invalid")
    if state.lifecycle == "paused" and (
        timestamps["paused"] is None or state.ended_at is not None or state.lifecycle_reason not in PAUSE_REASONS
    ):
        raise CoordinatorSessionStateError("coordinator session state is invalid")
    if state.lifecycle in TERMINAL_SESSION_LIFECYCLES and (
        state.paused_at is not None
        or timestamps["ended"] is None
        or timestamps["ended"] != timestamps["updated"]
    ):
        raise CoordinatorSessionStateError("coordinator session state is invalid")
    expected_terminal_reason = {
        "stopped": "operator-stopped",
        "expired": "deadline-expired",
        "blocked": "explicit-block",
        "superseded": "newer-build-observed",
        "completed": "evidence-complete",
    }.get(state.lifecycle)
    if expected_terminal_reason is not None and state.lifecycle_reason != expected_terminal_reason:
        raise CoordinatorSessionStateError("coordinator session state is invalid")


def create_session_state(
    target: Target,
    requested_surfaces: tuple[str, ...],
    now: datetime,
    duration: timedelta,
    retention: timedelta,
    watch_restart_recorded_at: str | None = None,
) -> CoordinatorSessionState:
    validate_target(target)
    created_at = normalize_utc(now)
    expires_at = created_at + duration
    state = CoordinatorSessionState(
        schema_version=SESSION_SCHEMA_VERSION,
        id=str(uuid.uuid4()).upper(),
        target=target,
        lifecycle="active",
        created_at=iso8601(created_at),
        updated_at=iso8601(created_at),
        expires_at=iso8601(expires_at),
        retention_expires_at=iso8601(expires_at + retention),
        paused_at=None,
        ended_at=None,
        lifecycle_reason=None,
        accumulated_pause_seconds=0,
        requested_surfaces=tuple(sorted(set(requested_surfaces))),
        watch_restart_recorded_at=watch_restart_recorded_at,
        revision=1,
        events=(
            CoordinatorSessionEvent("started", iso8601(created_at)),
            *(
                (CoordinatorSessionEvent("watch-restart-recorded", iso8601(created_at)),)
                if watch_restart_recorded_at is not None
                else ()
            ),
        ),
    )
    validate_session_state(state)
    return state


def transition_session_state(
    state: CoordinatorSessionState,
    event_kind: str,
    now: datetime,
    reason: str | None = None,
) -> CoordinatorSessionState:
    validate_session_state(state)
    if event_kind not in SESSION_EVENT_KINDS:
        raise CoordinatorSessionTransitionError("coordinator session transition is unsupported")
    updated_at = parse_iso8601(state.updated_at)
    assert updated_at is not None
    effective_now = max(normalize_utc(now), updated_at)
    timestamp = iso8601(effective_now)
    if event_kind == "paused":
        if state.lifecycle == "paused":
            return state
        if state.lifecycle != "active" or reason not in PAUSE_REASONS:
            raise CoordinatorSessionTransitionError("coordinator session cannot be paused")
        changes: dict[str, object] = {
            "lifecycle": "paused",
            "paused_at": timestamp,
            "lifecycle_reason": reason,
        }
    elif event_kind == "resumed":
        if state.lifecycle == "active":
            return state
        if state.lifecycle != "paused":
            raise CoordinatorSessionTransitionError("coordinator session cannot be resumed")
        paused_at = parse_iso8601(state.paused_at)
        expires_at = parse_iso8601(state.expires_at)
        retention_expires_at = parse_iso8601(state.retention_expires_at)
        assert paused_at is not None and expires_at is not None and retention_expires_at is not None
        pause_seconds = max(0, int((effective_now - paused_at).total_seconds()))
        changes = {
            "lifecycle": "active",
            "paused_at": None,
            "lifecycle_reason": None,
            "accumulated_pause_seconds": state.accumulated_pause_seconds + pause_seconds,
            "expires_at": iso8601(expires_at + timedelta(seconds=pause_seconds)),
            "retention_expires_at": iso8601(
                retention_expires_at + timedelta(seconds=pause_seconds)
            ),
        }
    elif event_kind == "watch-restart-recorded":
        if state.lifecycle not in ACTIVE_SESSION_LIFECYCLES:
            raise CoordinatorSessionTransitionError("Watch restart cannot be recorded for a closed session")
        if not any(surface.startswith("watchos.") for surface in state.requested_surfaces):
            raise CoordinatorSessionTransitionError(
                "Watch restart cannot be recorded outside the requested session surfaces"
            )
        if state.watch_restart_recorded_at is not None:
            return state
        changes = {"watch_restart_recorded_at": timestamp}
    else:
        target_lifecycle = {
            "stopped": "stopped",
            "expired": "expired",
            "blocked": "blocked",
            "superseded": "superseded",
            "completed": "completed",
        }.get(event_kind)
        required_reason = {
            "stopped": "operator-stopped",
            "expired": "deadline-expired",
            "blocked": "explicit-block",
            "superseded": "newer-build-observed",
            "completed": "evidence-complete",
        }.get(event_kind)
        if target_lifecycle is None or reason != required_reason:
            raise CoordinatorSessionTransitionError("coordinator session transition is invalid")
        if state.lifecycle == target_lifecycle:
            return state
        if state.lifecycle not in ACTIVE_SESSION_LIFECYCLES:
            raise CoordinatorSessionTransitionError("coordinator session is already closed")
        changes = {
            "lifecycle": target_lifecycle,
            "paused_at": None,
            "ended_at": timestamp,
            "lifecycle_reason": reason,
        }
    if event_kind in {"stopped", "blocked", "superseded", "completed"} and state.lifecycle == "paused":
        paused_at = parse_iso8601(state.paused_at)
        assert paused_at is not None
        pause_seconds = max(0, int((effective_now - paused_at).total_seconds()))
        retention_expires_at = parse_iso8601(state.retention_expires_at)
        assert retention_expires_at is not None
        changes["accumulated_pause_seconds"] = state.accumulated_pause_seconds + pause_seconds
        changes["retention_expires_at"] = iso8601(
            retention_expires_at + timedelta(seconds=pause_seconds)
        )
    events = (*state.events, CoordinatorSessionEvent(event_kind, timestamp, reason))
    if len(events) > MAXIMUM_EVENT_COUNT:
        events = (events[0], *events[-(MAXIMUM_EVENT_COUNT - 1) :])
    next_state = replace(
        state,
        updated_at=timestamp,
        revision=state.revision + 1,
        events=events,
        **changes,
    )
    validate_session_state(next_state)
    return next_state


def refresh_session_state(state: CoordinatorSessionState, now: datetime) -> CoordinatorSessionState:
    expires_at = parse_iso8601(state.expires_at)
    assert expires_at is not None
    if state.lifecycle == "active" and normalize_utc(now) >= expires_at:
        return transition_session_state(state, "expired", expires_at, "deadline-expired")
    return state


def apply_session_state_to_report(
    report: ValidationReport,
    session: CoordinatorSessionState | None,
) -> ValidationReport:
    if session is None:
        return report
    session_payload = session.public_dict()
    if session.lifecycle == "active":
        return replace(report, session=session_payload)
    if session.lifecycle == "paused" and report.state in {"blocked", "unknown"}:
        return replace(report, actions=(), session=session_payload)
    state, stage, exit_code, closing = {
        "paused": ("waiting", "paused", EXIT_OK, "nothing needs you right now"),
        "stopped": ("unknown", "session stopped", EXIT_UNKNOWN, "session is stopped"),
        "expired": ("unknown", "session expired", EXIT_UNKNOWN, "session expired"),
        "blocked": ("blocked", "blocked", EXIT_BLOCKED, "blocked: coordinator session"),
        "superseded": ("blocked", "superseded", EXIT_BLOCKED, "blocked: target superseded"),
        "completed": (
            "complete_for_slice",
            "session complete",
            EXIT_OK,
            "nothing needs you right now",
        ),
    }[session.lifecycle]
    if report.runtime_evidence is not None:
        evidence_summary = (
            f"{report.runtime_evidence['provenSurfaceCount']} of "
            f"{report.runtime_evidence['requestedSurfaceCount']} surfaces proven"
        )
    else:
        current_count, known_count, unknown_count = install_counts(
            report.mac,
            report.devices,
            session.requested_surfaces,
        )
        evidence_summary = (
            f"{current_count} of {known_count} known installs current"
            if known_count
            else "no install versions known"
        )
        if unknown_count:
            evidence_summary += (
                f" · {unknown_count} install{'s' if unknown_count != 1 else ''} unknown"
            )
    headline = (
        f"{report.target.version} ({report.target.build_number}) — {stage} · "
        f"{evidence_summary} · {closing}"
    )
    return replace(
        report,
        state=state,
        stage=stage,
        headline=headline,
        exit_code=exit_code,
        actions=(),
        session=session_payload,
    )


class SessionStateStore:
    def __init__(self, root: Path | None = None, legacy_root: Path | None = None):
        configured = os.environ.get("CONTEXT_PANEL_VALIDATION_STATE_ROOT", "").strip()
        self.root = root or (Path(configured).expanduser() if configured else DEFAULT_STATE_ROOT)
        if legacy_root is not None:
            self.legacy_root = legacy_root
        elif root is None and not configured:
            self.legacy_root = LEGACY_STATE_ROOT
        else:
            self.legacy_root = self.root / "Legacy"

    @property
    def sessions_directory(self) -> Path:
        return self.root / "Sessions"

    @property
    def archive_directory(self) -> Path:
        return self.root / "Archive"

    @property
    def runtime_evidence_directory(self) -> Path:
        return self.root / "Runtime Evidence"

    @property
    def operator_flow_directory(self) -> Path:
        return self.root / "Operator Flow"

    @property
    def visual_approval_directory(self) -> Path:
        return self.root / "Visual Approvals"

    def path(self, target: Target) -> Path:
        validate_target(target)
        return self.sessions_directory / f"{target.version}-{target.build_number}.json"

    def legacy_path(self, target: Target) -> Path:
        validate_target(target)
        return self.legacy_root / f"{target.version}-{target.build_number}.json"

    def runtime_evidence_path(self, session_id: str) -> Path:
        try:
            normalized_id = str(uuid.UUID(session_id)).lower()
        except (AttributeError, TypeError, ValueError) as error:
            raise CoordinatorSessionStateError("coordinator session identifier is invalid") from error
        return self.runtime_evidence_directory / f"{normalized_id}.json"

    def operator_flow_path(self, session_id: str) -> Path:
        try:
            normalized_id = str(uuid.UUID(session_id)).lower()
        except (AttributeError, TypeError, ValueError) as error:
            raise CoordinatorSessionStateError("coordinator session identifier is invalid") from error
        return self.operator_flow_directory / f"{normalized_id}.json"

    def visual_approval_path(self, session_id: str) -> Path:
        try:
            normalized_id = str(uuid.UUID(session_id)).lower()
        except (AttributeError, TypeError, ValueError) as error:
            raise CoordinatorSessionStateError("coordinator session identifier is invalid") from error
        return self.visual_approval_directory / f"{normalized_id}.json"

    @contextmanager
    def lock(self) -> Iterator[None]:
        if (
            self.root.is_symlink()
            or (self.root.exists() and not self.root.is_dir())
            or self.sessions_directory.is_symlink()
            or (
                self.sessions_directory.exists()
                and not self.sessions_directory.is_dir()
            )
            or self.archive_directory.is_symlink()
            or (
                self.archive_directory.exists()
                and not self.archive_directory.is_dir()
            )
            or self.runtime_evidence_directory.is_symlink()
            or (
                self.runtime_evidence_directory.exists()
                and not self.runtime_evidence_directory.is_dir()
            )
            or self.operator_flow_directory.is_symlink()
            or (
                self.operator_flow_directory.exists()
                and not self.operator_flow_directory.is_dir()
            )
            or self.visual_approval_directory.is_symlink()
            or (
                self.visual_approval_directory.exists()
                and not self.visual_approval_directory.is_dir()
            )
        ):
            raise CoordinatorSessionStateError("coordinator session root is invalid")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(self.root / ".write.lock", flags, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def load(self, target: Target, now: datetime | None = None) -> CoordinatorSessionState | None:
        path = self.path(target)
        if self.root.is_symlink() or path.is_symlink() or path.parent.is_symlink():
            raise CoordinatorSessionStateError("coordinator session state path is invalid")
        if not self.root.exists():
            return None
        if now is not None:
            self._validated_legacy_path(target)
        with self.lock():
            if now is None:
                return self._load_path(path, target)
            self._prune_locked(now)
            states = self._load_all_locked(now)
            self._require_compatible_active_target(states, target)
            return next((state for state in states if state.target == target), None)

    def start_session(
        self,
        target: Target,
        requested_surfaces: tuple[str, ...],
        now: datetime,
        duration: timedelta,
        retention: timedelta,
        replace_existing: bool = False,
    ) -> tuple[CoordinatorSessionState, bool]:
        self._validated_legacy_path(target)
        with self.lock():
            self._prune_locked(now)
            states = self._load_all_locked(now)
            existing = next((state for state in states if state.target == target), None)
            self._require_compatible_active_target(states, target)
            if existing is not None and not replace_existing:
                legacy_watch_restart = self._legacy_watch_restart_recorded_at(target)
                if (
                    existing.lifecycle in ACTIVE_SESSION_LIFECYCLES
                    and existing.watch_restart_recorded_at is None
                    and legacy_watch_restart is not None
                ):
                    migrated_at = iso8601(
                        max(normalize_utc(now), parse_iso8601(existing.updated_at))
                    )
                    events = (
                        *existing.events,
                        CoordinatorSessionEvent("watch-restart-recorded", migrated_at),
                    )
                    if len(events) > MAXIMUM_EVENT_COUNT:
                        events = (events[0], *events[-(MAXIMUM_EVENT_COUNT - 1) :])
                    existing = replace(
                        existing,
                        watch_restart_recorded_at=legacy_watch_restart,
                        updated_at=migrated_at,
                        revision=existing.revision + 1,
                        events=events,
                    )
                    validate_session_state(existing)
                    self._write_state(self.path(target), existing)
                    self._validated_legacy_path(target).unlink(missing_ok=True)
                return existing, False
            existing_watch_restart = existing.watch_restart_recorded_at if existing is not None else None
            if existing is not None:
                archived = existing
                if archived.lifecycle in ACTIVE_SESSION_LIFECYCLES:
                    archived = transition_session_state(
                        archived,
                        "stopped",
                        now,
                        "operator-stopped",
                    )
                self._write_state(self.archive_directory / f"{existing.id.lower()}.json", archived)
            legacy_watch_restart = self._legacy_watch_restart_recorded_at(target)
            state = create_session_state(
                target,
                requested_surfaces,
                now,
                duration,
                retention,
                existing_watch_restart or legacy_watch_restart,
            )
            self._write_state(self.path(target), state)
            if legacy_watch_restart is not None:
                self._validated_legacy_path(target).unlink(missing_ok=True)
            return state, True

    def transition(
        self,
        target: Target,
        event_kind: str,
        now: datetime,
        reason: str | None = None,
    ) -> CoordinatorSessionState:
        with self.lock():
            self._prune_locked(now)
            states = self._load_all_locked(now)
            self._require_compatible_active_target(states, target)
            state = next((candidate for candidate in states if candidate.target == target), None)
            if state is None:
                raise CoordinatorSessionStateError("signed validation session does not exist")
            next_state = transition_session_state(state, event_kind, now, reason)
            if next_state != state:
                self._write_state(self.path(target), next_state)
            return next_state

    def watch_restart_recorded_at(
        self,
        target: Target,
        now: datetime | None = None,
    ) -> str | None:
        session_path = self.path(target)
        legacy_path = self._validated_legacy_path(target)
        if self.root.is_symlink() or session_path.is_symlink():
            raise CoordinatorSessionStateError("coordinator session state path is invalid")
        if not self.root.exists() and not legacy_path.is_file():
            return None
        with self.lock():
            if now is None:
                state = self._load_path(session_path, target)
            else:
                self._prune_locked(now)
                states = self._load_all_locked(now)
                self._require_compatible_active_target(states, target)
                state = next(
                    (candidate for candidate in states if candidate.target == target),
                    None,
                )
            if state is not None and state.watch_restart_recorded_at is not None:
                return state.watch_restart_recorded_at
            return self._legacy_watch_restart_recorded_at(target)

    def watch_restart_recorded(self, target: Target) -> bool:
        return self.watch_restart_recorded_at(target) is not None

    def record_watch_restart(self, target: Target, recorded_at: datetime) -> None:
        legacy_path = self._validated_legacy_path(target)
        with self.lock():
            self._prune_locked(recorded_at)
            states = self._load_all_locked(recorded_at)
            self._require_compatible_active_target(states, target)
            state = next((candidate for candidate in states if candidate.target == target), None)
            if state is not None and state.lifecycle in ACTIVE_SESSION_LIFECYCLES:
                next_state = transition_session_state(
                    state,
                    "watch-restart-recorded",
                    recorded_at,
                )
                if next_state != state:
                    self._write_state(self.path(target), next_state)
                legacy_path.unlink(missing_ok=True)
                return
            if state is not None:
                raise CoordinatorSessionTransitionError(
                    "Watch restart cannot be recorded for a closed session"
                )
            self._write_legacy_watch_restart(target, recorded_at)

    @staticmethod
    def _require_compatible_active_target(
        states: list[CoordinatorSessionState],
        target: Target,
    ) -> None:
        active = [state for state in states if state.lifecycle in ACTIVE_SESSION_LIFECYCLES]
        if len(active) > 1 or (active and active[0].target != target):
            raise CoordinatorSessionConflictError("another signed validation session is active")

    def prune(self, now: datetime) -> None:
        with self.lock():
            self._prune_locked(now)

    def _load_all_locked(self, now: datetime) -> list[CoordinatorSessionState]:
        if not self.sessions_directory.is_dir():
            return []
        states: list[CoordinatorSessionState] = []
        for path in sorted(self.sessions_directory.glob("*.json")):
            state = self._load_path(path)
            if state is None:
                continue
            if path != self.path(state.target):
                raise CoordinatorSessionStateError("coordinator session target does not match its path")
            refreshed = refresh_session_state(state, now)
            if refreshed != state:
                self._write_state(path, refreshed)
            states.append(refreshed)
        return states

    def _prune_locked(self, now: datetime) -> None:
        for directory in (self.sessions_directory, self.archive_directory):
            if not directory.is_dir():
                continue
            for path in sorted(directory.glob("*.json")):
                state = self._load_path(path)
                if state is None:
                    continue
                if directory == self.sessions_directory and path != self.path(state.target):
                    raise CoordinatorSessionStateError(
                        "coordinator session target does not match its path"
                    )
                refreshed = refresh_session_state(state, now)
                if refreshed != state:
                    self._write_state(path, refreshed)
                retention_expires_at = parse_iso8601(refreshed.retention_expires_at)
                assert retention_expires_at is not None
                if (
                    refreshed.lifecycle in TERMINAL_SESSION_LIFECYCLES
                    and normalize_utc(now) >= retention_expires_at
                ):
                    path.unlink(missing_ok=True)
                    self.runtime_evidence_path(refreshed.id).unlink(missing_ok=True)
                    self.operator_flow_path(refreshed.id).unlink(missing_ok=True)
                    self.visual_approval_path(refreshed.id).unlink(missing_ok=True)

    def _load_path(
        self,
        path: Path,
        expected_target: Target | None = None,
    ) -> CoordinatorSessionState | None:
        if path.is_symlink() or path.parent.is_symlink():
            raise CoordinatorSessionStateError("coordinator session state path is invalid")
        if not path.is_file():
            return None
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise CoordinatorSessionStateError("coordinator session state is unreadable") from error
        state = CoordinatorSessionState.from_dict(payload)
        if expected_target is not None and state.target != expected_target:
            raise CoordinatorSessionStateError("coordinator session target does not match its path")
        return state

    def _write_state(self, path: Path, state: CoordinatorSessionState) -> None:
        validate_session_state(state)
        self._atomic_write(path, state.to_dict())

    def _legacy_watch_restart_recorded_at(self, target: Target) -> str | None:
        path = self._validated_legacy_path(target)
        if not path.is_file():
            return None
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise CoordinatorSessionStateError("legacy coordinator state is unreadable") from error
        if not isinstance(payload, dict):
            raise CoordinatorSessionStateError("legacy coordinator state is invalid")
        recorded_at = payload.get("watchRestartRecordedAt")
        if (
            payload.get("schemaVersion") != 1
            or payload.get("version") != target.version
            or payload.get("buildNumber") != target.build_number
            or parse_iso8601(recorded_at) is None
        ):
            raise CoordinatorSessionStateError("legacy coordinator state is invalid")
        return recorded_at

    def _write_legacy_watch_restart(self, target: Target, recorded_at: datetime) -> None:
        payload = {
            "schemaVersion": 1,
            "version": target.version,
            "buildNumber": target.build_number,
            "watchRestartRecordedAt": iso8601(normalize_utc(recorded_at)),
        }
        self._atomic_write(self._validated_legacy_path(target), payload)

    def _validated_legacy_path(self, target: Target) -> Path:
        path = self.legacy_path(target)
        if (
            self.legacy_root.is_symlink()
            or (self.legacy_root.exists() and not self.legacy_root.is_dir())
            or path.is_symlink()
        ):
            raise CoordinatorSessionStateError("legacy coordinator state path is invalid")
        return path

    @staticmethod
    def _atomic_write(path: Path, payload: dict[str, object]) -> None:
        if path.is_symlink() or path.parent.is_symlink():
            raise CoordinatorSessionStateError("coordinator session state path is invalid")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path.parent, 0o700)
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary_path = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(payload, stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temporary_path, 0o600)
            os.replace(temporary_path, path)
            try:
                directory_descriptor = os.open(path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory_descriptor)
                finally:
                    os.close(directory_descriptor)
            except OSError:
                pass
        finally:
            temporary_path.unlink(missing_ok=True)
