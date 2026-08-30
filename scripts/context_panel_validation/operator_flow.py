from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, cast

from .automation import (
    AUTOMATION_KINDS,
    build_automation_report,
    macos_app_window_digest,
)
from .models import (
    EXIT_READY,
    EXIT_UNKNOWN,
    OperatorAction,
    Target,
    ValidationReport,
    device_is_in_scope,
    iso8601,
    report_scope,
)
from .session import (
    ACTIVE_SESSION_LIFECYCLES,
    CoordinatorSessionState,
    CoordinatorSessionStateError,
    SessionStateStore,
    normalize_utc,
    parse_iso8601,
    validate_target,
)


OPERATOR_FLOW_SCHEMA_VERSION = 1
MANUAL_ACCESS_ESCALATION = timedelta(minutes=15)
UNREACHABLE_ESCALATION = timedelta(minutes=30)
MAXIMUM_DEFERRAL_HOURS = 168
MAXIMUM_DEFERRAL_COUNT = 128
MAXIMUM_NOTIFICATION_COUNT = 128

NOTIFICATION_KINDS = (
    "readyForHumanReview",
    "restartRequired",
    "manualUnlockRequired",
    "blockedDecisionRequired",
)
DEFERRAL_REASONS = (
    "blocked-decision",
    "external-wait",
    "hardware-unavailable",
    "operator-unavailable",
)
RESIDUAL_RISKS = (
    "decision-pending",
    "device-access-required",
    "evidence-incomplete",
    "restart-unconfirmed",
    "review-pending",
    "runtime-unproven",
)
WAIT_CONDITIONS = {"locked", "asleep", "not_reachable", "unavailable"}
ACTION_KINDS = {
    "manual-recovery",
    "operator-decision",
    "status-follow-up",
    "visual-review",
}
REASON_CODES = {
    "automation-attempt-required",
    "device-access-required",
    "device-not-found",
    "mac-app-not-running",
    "runtime-session-diagnostic",
    "runtime-surface-diagnostic",
    "validation-blocked",
    "visual-review-required",
    "watch-restart-required",
}
SIMULATION_INSUFFICIENCY_CODES = {
    "operator-attestation-required",
    "physical-device-interaction-required",
    "signed-runtime-observation-required",
    "visual-presentation-review-required",
}
ACTION_ID_PATTERN = re.compile(r"^[a-z0-9]+(?:[.-][a-z0-9]+)*$")
OWNER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
DEVICE_PATTERN = re.compile(
    r"^(?:Mac|Coordinator|iPhone(?: [1-9][0-9]*)?|iPad(?: [1-9][0-9]*)?|"
    r"Vision Pro(?: [1-9][0-9]*)?|Apple Watch(?: [1-9][0-9]*)?|"
    r"Apple TV(?: [1-9][0-9]*)?)$"
)
PRIVATE_ACTION_TEXT_PATTERN = re.compile(
    r"(?:/Users/|/private/|/tmp/|\b(?:xcrun|devicectl)\b|"
    r"--device(?:=|\s)|\b(?:udid|serial|device-id)\s*=|"
    r"\b[0-9A-F]{8}-[0-9A-F-]{16,}\b|"
    r"\b(?=[A-Z0-9]{10,}\b)(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*\d)[A-Z0-9]+\b|"
    r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b)",
    re.IGNORECASE,
)
DEVICE_ORDER = {
    "Mac": 0,
    "iPhone": 1,
    "iPad": 2,
    "Vision Pro": 3,
    "Apple Watch": 4,
    "Apple TV": 5,
    "Coordinator": 6,
}
SURFACE_DEVICE = {
    "macos": "Mac",
    "ios": "iPhone",
    "ipados": "iPad",
    "visionos": "Vision Pro",
    "watchos": "Apple Watch",
    "tvos": "Apple TV",
}
class OperatorFlowError(CoordinatorSessionStateError):
    pass


def _sha256(*parts: str) -> str:
    digest = hashlib.sha256()
    for part in parts:
        digest.update(part.encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def _validate_action_id(value: object) -> str:
    if not isinstance(value, str) or not ACTION_ID_PATTERN.fullmatch(value):
        raise OperatorFlowError("operator action identifier is invalid")
    return value


def _validate_device(value: object) -> str:
    if not isinstance(value, str) or not DEVICE_PATTERN.fullmatch(value):
        raise OperatorFlowError("operator device label is invalid")
    return value


def _device_key(device: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", device.casefold()).strip("-")


def _device_sort_key(device: str) -> tuple[int, str]:
    base = next((name for name in DEVICE_ORDER if device == name or device.startswith(f"{name} ")), device)
    return DEVICE_ORDER.get(base, 99), device


def _is_public_action_text(value: object) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and PRIVATE_ACTION_TEXT_PATTERN.search(value) is None
    )


def _surfaces_for_device(
    requested_surfaces: tuple[str, ...],
    device: str,
) -> tuple[str, ...]:
    prefixes = {
        "Mac": {"macos"},
        "iPhone": {"ios"},
        "iPad": {"ipados"},
        "Vision Pro": {"visionos"},
        "Apple Watch": {"watchos"},
        "Apple TV": {"tvos"},
        "Coordinator": {surface.split(".", 1)[0] for surface in requested_surfaces},
    }
    base_device = next(
        (name for name in DEVICE_ORDER if device == name or device.startswith(f"{name} ")),
        device,
    )
    return tuple(
        surface
        for surface in requested_surfaces
        if surface.split(".", 1)[0] in prefixes.get(base_device, set())
    )


@dataclass(frozen=True)
class SimulationInsufficiency:
    code: str
    explanation: str


@dataclass(frozen=True)
class OperatorWaitObservation:
    action_id: str
    device: str
    condition: str
    first_seen_at: str
    last_seen_at: str

    def to_dict(self) -> dict[str, object]:
        return {
            "actionID": self.action_id,
            "device": self.device,
            "condition": self.condition,
            "firstSeenAt": self.first_seen_at,
            "lastSeenAt": self.last_seen_at,
        }

    @classmethod
    def from_dict(cls, payload: object) -> OperatorWaitObservation:
        if not isinstance(payload, dict) or set(payload) != {
            "actionID",
            "device",
            "condition",
            "firstSeenAt",
            "lastSeenAt",
        }:
            raise OperatorFlowError("operator wait observation is invalid")
        observation = cls(
            action_id=_validate_action_id(payload.get("actionID")),
            device=_validate_device(payload.get("device")),
            condition=payload.get("condition"),
            first_seen_at=payload.get("firstSeenAt"),
            last_seen_at=payload.get("lastSeenAt"),
        )
        first_seen = parse_iso8601(observation.first_seen_at)
        last_seen = parse_iso8601(observation.last_seen_at)
        if (
            not isinstance(observation.condition, str)
            or observation.condition not in WAIT_CONDITIONS
            or first_seen is None
            or last_seen is None
            or first_seen > last_seen
        ):
            raise OperatorFlowError("operator wait observation is invalid")
        return observation


@dataclass(frozen=True)
class OperatorDeferral:
    id: str
    action_id: str
    owner: str
    reason: str
    expires_at: str
    residual_risk: str
    created_at: str
    cleared_at: str | None

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "actionID": self.action_id,
            "owner": self.owner,
            "reason": self.reason,
            "expiresAt": self.expires_at,
            "residualRisk": self.residual_risk,
            "createdAt": self.created_at,
            "clearedAt": self.cleared_at,
        }

    @classmethod
    def from_dict(cls, payload: object) -> OperatorDeferral:
        if not isinstance(payload, dict) or set(payload) != {
            "id",
            "actionID",
            "owner",
            "reason",
            "expiresAt",
            "residualRisk",
            "createdAt",
            "clearedAt",
        }:
            raise OperatorFlowError("operator deferral is invalid")
        deferral = cls(
            id=payload.get("id"),
            action_id=_validate_action_id(payload.get("actionID")),
            owner=payload.get("owner"),
            reason=payload.get("reason"),
            expires_at=payload.get("expiresAt"),
            residual_risk=payload.get("residualRisk"),
            created_at=payload.get("createdAt"),
            cleared_at=payload.get("clearedAt"),
        )
        created = parse_iso8601(deferral.created_at)
        expires = parse_iso8601(deferral.expires_at)
        cleared = parse_iso8601(deferral.cleared_at) if deferral.cleared_at is not None else None
        if (
            not isinstance(deferral.id, str)
            or not re.fullmatch(r"[0-9a-f]{64}", deferral.id)
            or not isinstance(deferral.owner, str)
            or not OWNER_PATTERN.fullmatch(deferral.owner)
            or deferral.reason not in DEFERRAL_REASONS
            or deferral.residual_risk not in RESIDUAL_RISKS
            or created is None
            or expires is None
            or created >= expires
            or (deferral.cleared_at is not None and cleared is None)
            or (cleared is not None and cleared < created)
            or deferral.id
            != _sha256(
                "context-panel-operator-deferral-v1",
                deferral.action_id,
                deferral.owner,
                deferral.reason,
                deferral.expires_at,
                deferral.residual_risk,
                deferral.created_at,
            )
        ):
            raise OperatorFlowError("operator deferral is invalid")
        return deferral

    def active(self, now: datetime) -> bool:
        expires = parse_iso8601(self.expires_at)
        assert expires is not None
        return self.cleared_at is None and normalize_utc(now) < expires

    def status(self, now: datetime) -> str:
        if self.cleared_at is not None:
            return "cleared"
        return "active" if self.active(now) else "expired"


@dataclass(frozen=True)
class NotificationDecision:
    id: str
    action_id: str
    kind: str
    decided_at: str

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "actionID": self.action_id,
            "kind": self.kind,
            "decidedAt": self.decided_at,
        }

    @classmethod
    def from_dict(cls, payload: object) -> NotificationDecision:
        if not isinstance(payload, dict) or set(payload) != {
            "id",
            "actionID",
            "kind",
            "decidedAt",
        }:
            raise OperatorFlowError("notification decision is invalid")
        decision = cls(
            id=payload.get("id"),
            action_id=_validate_action_id(payload.get("actionID")),
            kind=payload.get("kind"),
            decided_at=payload.get("decidedAt"),
        )
        if (
            not isinstance(decision.id, str)
            or not re.fullmatch(r"[0-9a-f]{64}", decision.id)
            or decision.kind not in NOTIFICATION_KINDS
            or parse_iso8601(decision.decided_at) is None
        ):
            raise OperatorFlowError("notification decision is invalid")
        return decision


@dataclass(frozen=True)
class OperatorFlowState:
    schema_version: int
    coordinator_session_id: str
    target: Target
    requested_surfaces: tuple[str, ...]
    created_at: str
    updated_at: str
    revision: int
    waits: tuple[OperatorWaitObservation, ...]
    deferrals: tuple[OperatorDeferral, ...]
    notification_decisions: tuple[NotificationDecision, ...]
    last_action_ids: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "schemaVersion": self.schema_version,
            "coordinatorSessionID": self.coordinator_session_id,
            "target": {
                "version": self.target.version,
                "buildNumber": self.target.build_number,
            },
            "requestedSurfaces": list(self.requested_surfaces),
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
            "revision": self.revision,
            "waits": [item.to_dict() for item in self.waits],
            "deferrals": [item.to_dict() for item in self.deferrals],
            "notificationDecisions": [
                item.to_dict() for item in self.notification_decisions
            ],
            "lastActionIDs": list(self.last_action_ids),
        }

    @classmethod
    def from_dict(cls, payload: object) -> OperatorFlowState:
        if not isinstance(payload, dict) or set(payload) != {
            "schemaVersion",
            "coordinatorSessionID",
            "target",
            "requestedSurfaces",
            "createdAt",
            "updatedAt",
            "revision",
            "waits",
            "deferrals",
            "notificationDecisions",
            "lastActionIDs",
        }:
            raise OperatorFlowError("operator flow state is invalid")
        target_payload = payload.get("target")
        if not isinstance(target_payload, dict) or set(target_payload) != {
            "version",
            "buildNumber",
        }:
            raise OperatorFlowError("operator flow state is invalid")
        requested_surfaces = payload.get("requestedSurfaces")
        waits = payload.get("waits")
        deferrals = payload.get("deferrals")
        notifications = payload.get("notificationDecisions")
        last_action_ids = payload.get("lastActionIDs")
        if not all(
            isinstance(value, list)
            for value in (requested_surfaces, waits, deferrals, notifications, last_action_ids)
        ):
            raise OperatorFlowError("operator flow state is invalid")
        state = cls(
            schema_version=payload.get("schemaVersion"),
            coordinator_session_id=payload.get("coordinatorSessionID"),
            target=Target(
                target_payload.get("version"),
                target_payload.get("buildNumber"),
            ),
            requested_surfaces=tuple(requested_surfaces),
            created_at=payload.get("createdAt"),
            updated_at=payload.get("updatedAt"),
            revision=payload.get("revision"),
            waits=tuple(OperatorWaitObservation.from_dict(item) for item in waits),
            deferrals=tuple(OperatorDeferral.from_dict(item) for item in deferrals),
            notification_decisions=tuple(
                NotificationDecision.from_dict(item) for item in notifications
            ),
            last_action_ids=tuple(_validate_action_id(item) for item in last_action_ids),
        )
        validate_operator_flow_state(state)
        return state


def validate_operator_flow_state(state: OperatorFlowState) -> None:
    validate_target(state.target)
    try:
        import uuid

        uuid.UUID(state.coordinator_session_id)
    except (AttributeError, TypeError, ValueError) as error:
        raise OperatorFlowError("operator flow state is invalid") from error
    created = parse_iso8601(state.created_at)
    updated = parse_iso8601(state.updated_at)
    if (
        state.schema_version != OPERATOR_FLOW_SCHEMA_VERSION
        or created is None
        or updated is None
        or created > updated
        or not isinstance(state.revision, int)
        or isinstance(state.revision, bool)
        or state.revision < 1
        or state.requested_surfaces != tuple(sorted(set(state.requested_surfaces)))
        or state.last_action_ids != tuple(sorted(set(state.last_action_ids)))
        or len(state.deferrals) > MAXIMUM_DEFERRAL_COUNT
        or len(state.notification_decisions) > MAXIMUM_NOTIFICATION_COUNT
        or tuple(item.action_id for item in state.waits)
        != tuple(sorted({item.action_id for item in state.waits}))
        or len({item.id for item in state.deferrals}) != len(state.deferrals)
        or len({item.id for item in state.notification_decisions})
        != len(state.notification_decisions)
        or any(
            item.id
            != _sha256(
                "context-panel-operator-notification-v1",
                state.coordinator_session_id,
                item.action_id,
                item.kind,
            )
            for item in state.notification_decisions
        )
    ):
        raise OperatorFlowError("operator flow state is invalid")


@dataclass(frozen=True)
class OperatorActionCandidate:
    action_id: str
    device: str
    surfaces: tuple[str, ...]
    reason_code: str
    action_kind: str
    estimate_minutes: int
    instruction: str
    notification_kind: str | None
    recovery_steps: tuple[str, ...]
    simulation_insufficiency: SimulationInsufficiency


def _validate_candidate(
    candidate: OperatorActionCandidate,
    requested_surfaces: tuple[str, ...],
) -> None:
    _validate_action_id(candidate.action_id)
    _validate_device(candidate.device)
    if (
        candidate.surfaces != tuple(sorted(set(candidate.surfaces)))
        or not candidate.surfaces
        or any(surface not in requested_surfaces for surface in candidate.surfaces)
        or candidate.reason_code not in REASON_CODES
        or candidate.action_kind not in ACTION_KINDS
        or not isinstance(candidate.estimate_minutes, int)
        or isinstance(candidate.estimate_minutes, bool)
        or not 1 <= candidate.estimate_minutes <= 60
        or not _is_public_action_text(candidate.instruction)
        or not candidate.recovery_steps
        or any(not _is_public_action_text(step) for step in candidate.recovery_steps)
        or candidate.simulation_insufficiency.code not in SIMULATION_INSUFFICIENCY_CODES
        or not _is_public_action_text(candidate.simulation_insufficiency.explanation)
    ):
        raise OperatorFlowError("operator action contract is invalid")
    if (
        candidate.notification_kind is not None
        and candidate.notification_kind not in NOTIFICATION_KINDS
    ):
        raise OperatorFlowError("operator action contract is invalid")


def validate_operator_candidates(
    candidates: tuple[OperatorActionCandidate, ...],
    requested_surfaces: tuple[str, ...],
) -> None:
    if len({candidate.action_id for candidate in candidates}) != len(candidates):
        raise OperatorFlowError("operator action contract is invalid")
    for candidate in candidates:
        _validate_candidate(candidate, requested_surfaces)


def validate_operator_flow_actions(
    operator_flow: object,
    allowed_surfaces: object,
) -> None:
    if not isinstance(operator_flow, dict) or not isinstance(allowed_surfaces, list):
        raise OperatorFlowError("operator action contract is invalid")
    groups = operator_flow.get("groups")
    total_duration_minutes = operator_flow.get("totalDurationMinutes")
    if (
        operator_flow.get("schemaVersion") != 1
        or any(not isinstance(surface, str) for surface in allowed_surfaces)
        or allowed_surfaces != sorted(set(allowed_surfaces))
        or not isinstance(groups, list)
        or not isinstance(total_duration_minutes, int)
        or isinstance(total_duration_minutes, bool)
    ):
        raise OperatorFlowError("operator action contract is invalid")
    normalized_allowed_surfaces = tuple(cast(list[str], allowed_surfaces))
    normalized_groups = cast(list[object], groups)
    candidates: list[OperatorActionCandidate] = []
    total_duration = 0
    for group in normalized_groups:
        if (
            not isinstance(group, dict)
            or not isinstance(group.get("actions"), list)
            or not isinstance(group.get("durationMinutes"), int)
            or isinstance(group.get("durationMinutes"), bool)
        ):
            raise OperatorFlowError("operator action contract is invalid")
        device = group.get("device")
        group_duration = 0
        for action in group["actions"]:
            if not isinstance(action, dict):
                raise OperatorFlowError("operator action contract is invalid")
            insufficiency = action.get("simulationInsufficiency")
            if not isinstance(insufficiency, dict) or set(insufficiency) != {
                "code",
                "explanation",
            }:
                raise OperatorFlowError("operator action contract is invalid")
            surfaces = action.get("surfaces")
            recovery_steps = action.get("recoverySteps")
            duration_minutes = action.get("durationMinutes")
            if (
                not isinstance(surfaces, list)
                or not isinstance(recovery_steps, list)
                or not isinstance(duration_minutes, int)
                or isinstance(duration_minutes, bool)
            ):
                raise OperatorFlowError("operator action contract is invalid")
            candidates.append(
                OperatorActionCandidate(
                    action_id=action.get("id"),
                    device=device,
                    surfaces=tuple(surfaces),
                    reason_code=action.get("reasonCode"),
                    action_kind=action.get("actionKind"),
                    estimate_minutes=duration_minutes,
                    instruction=action.get("instruction"),
                    notification_kind=action.get("notificationKind"),
                    recovery_steps=tuple(recovery_steps),
                    simulation_insufficiency=SimulationInsufficiency(
                        code=insufficiency.get("code"),
                        explanation=insufficiency.get("explanation"),
                    ),
                )
            )
            group_duration += duration_minutes
        if group["durationMinutes"] != group_duration:
            raise OperatorFlowError("operator action contract is invalid")
        total_duration += group_duration
    if total_duration_minutes != total_duration:
        raise OperatorFlowError("operator action contract is invalid")
    validate_operator_candidates(tuple(candidates), normalized_allowed_surfaces)


def _new_state(session: CoordinatorSessionState, now: datetime) -> OperatorFlowState:
    timestamp = iso8601(normalize_utc(now))
    state = OperatorFlowState(
        schema_version=OPERATOR_FLOW_SCHEMA_VERSION,
        coordinator_session_id=session.id,
        target=session.target,
        requested_surfaces=session.requested_surfaces,
        created_at=timestamp,
        updated_at=timestamp,
        revision=1,
        waits=(),
        deferrals=(),
        notification_decisions=(),
        last_action_ids=(),
    )
    validate_operator_flow_state(state)
    return state


class OperatorFlowStore:
    def __init__(self, session_store: SessionStateStore):
        self.session_store = session_store

    def load(self, session: CoordinatorSessionState) -> OperatorFlowState | None:
        path = self.session_store.operator_flow_path(session.id)
        if path.is_symlink() or path.parent.is_symlink():
            raise OperatorFlowError("operator flow path is invalid")
        if not path.is_file():
            return None
        state = self._load_path(path)
        self._validate_session_binding(state, session)
        return state

    def reconcile(
        self,
        session: CoordinatorSessionState,
        report: ValidationReport,
        runtime_evidence: dict[str, Any] | None,
        now: datetime,
    ) -> tuple[OperatorFlowState, dict[str, Any]]:
        with self.session_store.lock():
            current_session = self.session_store._load_path(
                self.session_store.path(session.target),
                session.target,
            )
            if current_session is None or current_session.id != session.id:
                raise OperatorFlowError("coordinator session changed during operator reconciliation")
            path = self.session_store.operator_flow_path(session.id)
            created = not path.is_file()
            state = _new_state(current_session, now) if created else self._load_path(path)
            self._validate_session_binding(state, current_session)
            waits = (
                _updated_waits(state.waits, report, current_session, now)
                if current_session.lifecycle in ACTIVE_SESSION_LIFECYCLES
                else state.waits
            )
            provisional = replace(state, waits=waits)
            candidates = build_operator_candidates(
                report,
                current_session,
                runtime_evidence,
                provisional,
                now,
            )
            ready_candidates = tuple(
                candidate
                for candidate in candidates
                if _active_deferral(state.deferrals, candidate.action_id, now) is None
            )
            notifications = list(state.notification_decisions)
            existing_notification_keys = {
                (item.action_id, item.kind) for item in notifications
            }
            for candidate in ready_candidates:
                if candidate.notification_kind is None:
                    continue
                if candidate.notification_kind not in NOTIFICATION_KINDS:
                    raise OperatorFlowError("notification decision kind is not allowed")
                key = (candidate.action_id, candidate.notification_kind)
                if key in existing_notification_keys:
                    continue
                decided_at = iso8601(normalize_utc(now))
                notifications.append(
                    NotificationDecision(
                        id=_sha256(
                            "context-panel-operator-notification-v1",
                            current_session.id,
                            candidate.action_id,
                            candidate.notification_kind,
                        ),
                        action_id=candidate.action_id,
                        kind=candidate.notification_kind,
                        decided_at=decided_at,
                    )
                )
                existing_notification_keys.add(key)
            notifications = notifications[-MAXIMUM_NOTIFICATION_COUNT:]
            next_state = replace(
                state,
                waits=waits,
                notification_decisions=tuple(notifications),
                last_action_ids=tuple(sorted(candidate.action_id for candidate in candidates)),
            )
            if next_state != state:
                next_state = replace(
                    next_state,
                    updated_at=iso8601(normalize_utc(now)),
                    revision=state.revision if created else state.revision + 1,
                )
                validate_operator_flow_state(next_state)
                self._write_path(path, next_state)
            return next_state, build_operator_flow_report(
                report,
                current_session,
                runtime_evidence,
                next_state,
                now,
            )

    def defer_action(
        self,
        session: CoordinatorSessionState,
        action_id: str,
        owner: str,
        reason: str,
        residual_risk: str,
        now: datetime,
        duration: timedelta,
    ) -> tuple[OperatorFlowState, OperatorDeferral]:
        action_id = _validate_action_id(action_id)
        if not OWNER_PATTERN.fullmatch(owner):
            raise OperatorFlowError("deferral owner must be a public-safe label")
        if reason not in DEFERRAL_REASONS:
            raise OperatorFlowError("deferral reason is not allowed")
        if residual_risk not in RESIDUAL_RISKS:
            raise OperatorFlowError("deferral residual risk is not allowed")
        if duration <= timedelta(0) or duration > timedelta(hours=MAXIMUM_DEFERRAL_HOURS):
            raise OperatorFlowError(
                f"deferral duration must be between 1 second and {MAXIMUM_DEFERRAL_HOURS} hours"
            )
        if session.lifecycle not in ACTIVE_SESSION_LIFECYCLES:
            raise OperatorFlowError("actions cannot be deferred for a closed session")
        with self.session_store.lock():
            current_session = self.session_store._load_path(
                self.session_store.path(session.target),
                session.target,
            )
            if current_session is None or current_session.id != session.id:
                raise OperatorFlowError("coordinator session changed before deferral")
            path = self.session_store.operator_flow_path(session.id)
            if not path.is_file():
                raise OperatorFlowError("operator status must be evaluated before deferring an action")
            state = self._load_path(path)
            self._validate_session_binding(state, current_session)
            if action_id not in state.last_action_ids:
                raise OperatorFlowError("operator action is not currently outstanding")
            if _active_deferral(state.deferrals, action_id, now) is not None:
                raise OperatorFlowError("operator action already has an active deferral")
            created_at = iso8601(normalize_utc(now))
            expires_at = iso8601(normalize_utc(now) + duration)
            deferral = OperatorDeferral(
                id=_sha256(
                    "context-panel-operator-deferral-v1",
                    action_id,
                    owner,
                    reason,
                    expires_at,
                    residual_risk,
                    created_at,
                ),
                action_id=action_id,
                owner=owner,
                reason=reason,
                expires_at=expires_at,
                residual_risk=residual_risk,
                created_at=created_at,
                cleared_at=None,
            )
            OperatorDeferral.from_dict(deferral.to_dict())
            next_state = replace(
                state,
                updated_at=created_at,
                revision=state.revision + 1,
                deferrals=(*state.deferrals, deferral)[-MAXIMUM_DEFERRAL_COUNT:],
            )
            validate_operator_flow_state(next_state)
            self._write_path(path, next_state)
            return next_state, deferral

    def clear_deferral(
        self,
        session: CoordinatorSessionState,
        action_id: str,
        now: datetime,
    ) -> tuple[OperatorFlowState, OperatorDeferral]:
        action_id = _validate_action_id(action_id)
        if session.lifecycle not in ACTIVE_SESSION_LIFECYCLES:
            raise OperatorFlowError("deferrals cannot change for a closed session")
        with self.session_store.lock():
            current_session = self.session_store._load_path(
                self.session_store.path(session.target),
                session.target,
            )
            if current_session is None or current_session.id != session.id:
                raise OperatorFlowError("coordinator session changed before clearing deferral")
            path = self.session_store.operator_flow_path(session.id)
            if not path.is_file():
                raise OperatorFlowError("operator action has no active deferral")
            state = self._load_path(path)
            self._validate_session_binding(state, current_session)
            active = _active_deferral(state.deferrals, action_id, now)
            if active is None:
                raise OperatorFlowError("operator action has no active deferral")
            cleared_at = iso8601(normalize_utc(now))
            cleared = replace(active, cleared_at=cleared_at)
            deferrals = tuple(cleared if item.id == active.id else item for item in state.deferrals)
            next_state = replace(
                state,
                updated_at=cleared_at,
                revision=state.revision + 1,
                deferrals=deferrals,
            )
            validate_operator_flow_state(next_state)
            self._write_path(path, next_state)
            return next_state, cleared

    @staticmethod
    def _validate_session_binding(
        state: OperatorFlowState,
        session: CoordinatorSessionState,
    ) -> None:
        if (
            state.coordinator_session_id != session.id
            or state.target != session.target
            or state.requested_surfaces != session.requested_surfaces
        ):
            raise OperatorFlowError("operator flow does not match its coordinator session")

    @staticmethod
    def _load_path(path: Path) -> OperatorFlowState:
        if path.is_symlink() or path.parent.is_symlink():
            raise OperatorFlowError("operator flow path is invalid")
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise OperatorFlowError("operator flow state is unreadable") from error
        return OperatorFlowState.from_dict(payload)

    @staticmethod
    def _write_path(path: Path, state: OperatorFlowState) -> None:
        validate_operator_flow_state(state)
        if path.is_symlink() or path.parent.is_symlink():
            raise OperatorFlowError("operator flow path is invalid")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path.parent, 0o700)
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary_path = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(state.to_dict(), stream, indent=2, sort_keys=True)
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


def _updated_waits(
    existing: tuple[OperatorWaitObservation, ...],
    report: ValidationReport,
    session: CoordinatorSessionState,
    now: datetime,
) -> tuple[OperatorWaitObservation, ...]:
    _, _, device_labels = report_scope(session.requested_surfaces)
    existing_by_action = {item.action_id: item for item in existing}
    timestamp = iso8601(normalize_utc(now))
    updated: list[OperatorWaitObservation] = []
    for device in report.devices:
        if not device_is_in_scope(device, device_labels) or device.condition not in WAIT_CONDITIONS:
            continue
        action_id = f"device.{_device_key(device.label)}.access"
        prior = existing_by_action.get(action_id)
        first_seen_at = (
            prior.first_seen_at
            if prior is not None and prior.condition == device.condition
            else timestamp
        )
        updated.append(
            OperatorWaitObservation(
                action_id=action_id,
                device=device.label,
                condition=device.condition,
                first_seen_at=first_seen_at,
                last_seen_at=timestamp,
            )
        )
    return tuple(sorted(updated, key=lambda item: item.action_id))


def _active_deferral(
    deferrals: tuple[OperatorDeferral, ...],
    action_id: str,
    now: datetime,
) -> OperatorDeferral | None:
    matching = [item for item in deferrals if item.action_id == action_id and item.active(now)]
    return matching[-1] if matching else None


def _base_action_candidate(action: OperatorAction) -> OperatorActionCandidate:
    insufficiency = action.simulation_insufficiency
    if not isinstance(insufficiency, dict) or set(insufficiency) != {"code", "explanation"}:
        raise OperatorFlowError("operator action contract is invalid")
    action_id = action.id or f"device.{_device_key(action.device)}.action"
    notification_kind = action.notification_kind
    recovery_steps = (
        "Complete the requested non-destructive action, then rerun status.",
    )
    if action.device == "Apple Watch" and "Restart the Watch" in action.instruction:
        action_id = "watchos.restart"
        notification_kind = "restartRequired"
        recovery_steps = (
            "Confirm the exact Watch build is still installed.",
            "Restart once with the existing complication placements intact.",
            "Record the restart attestation, then resume receipt collection.",
        )
    elif action.device == "Mac" and "Open the canonical Mac app" in action.instruction:
        action_id = "macos.app.open"
        recovery_steps = (
            "Open the canonical signed app once.",
            "Preserve the installed app, local data, and widget placements.",
            "Rerun coordinator status.",
        )
    return OperatorActionCandidate(
        action_id=action_id,
        device=action.device,
        surfaces=action.surfaces,
        reason_code=action.reason_code,
        action_kind=action.action_kind,
        estimate_minutes=action.duration_minutes,
        instruction=action.instruction,
        notification_kind=notification_kind,
        recovery_steps=recovery_steps,
        simulation_insufficiency=SimulationInsufficiency(**insufficiency),
    )


def _runtime_recovery_candidate(
    surface: dict[str, Any],
    requested_surfaces: tuple[str, ...],
) -> OperatorActionCandidate | None:
    surface_name = str(surface.get("surface") or "")
    if surface_name not in requested_surfaces:
        return None
    reason = str(surface.get("reason") or "")
    prefix = surface_name.split(".", 1)[0]
    device = SURFACE_DEVICE.get(prefix, "Coordinator")
    if reason == "app-current-extension-stale-or-silent":
        host_instruction = {
            "watchos": "Open the signed Watch app once, return to the existing face, and rerun receipt sync.",
            "tvos": "Open the signed Apple TV app once, return to Home, and rerun receipt sync.",
        }.get(
            prefix,
            f"Open the signed {device} host app once and rerun receipt sync.",
        )
        return OperatorActionCandidate(
            action_id=f"{surface_name}.recover",
            device=device,
            surfaces=(surface_name,),
            reason_code="runtime-surface-diagnostic",
            action_kind="manual-recovery",
            estimate_minutes=5 if prefix in {"watchos", "visionos"} else 3,
            instruction=host_instruction,
            notification_kind="blockedDecisionRequired",
            recovery_steps=(
                "Preserve the installed app and current surface placement.",
                "Open the signed host app once and allow the normal extension refresh path to run.",
                "Start a fresh bounded receipt window only if the prior window expired.",
            ),
            simulation_insufficiency=SimulationInsufficiency(
                "signed-runtime-observation-required",
                "The signed host must refresh the affected surface before runtime evidence can be collected.",
            ),
        )
    if reason in {
        "expected-build-identity-missing",
        "receipt-silence",
        "runtime-session-manifest-mismatch",
        "runtime-session-missing",
        "surface-not-enabled",
    }:
        instruction = {
            "expected-build-identity-missing": "Attach the sealed expected-build manifest for the missing surface, then rerun status.",
            "receipt-silence": "Start a fresh bounded runtime receipt window and rerun signed-host sync.",
            "runtime-session-manifest-mismatch": "Stop and reconcile the runtime session manifest with the sealed target before continuing.",
            "runtime-session-missing": "Start the bounded runtime receipt session for this exact build, then rerun sync.",
            "surface-not-enabled": "Start a runtime receipt session that includes the requested surface.",
        }[reason]
        return OperatorActionCandidate(
            action_id=f"{surface_name}.diagnose",
            device=device,
            surfaces=(surface_name,),
            reason_code="runtime-surface-diagnostic",
            action_kind="operator-decision",
            estimate_minutes=5,
            instruction=instruction,
            notification_kind="blockedDecisionRequired",
            recovery_steps=(
                "Keep the exact signed target installed.",
                "Preserve app data and existing surface placements.",
                "Re-establish only the bounded receipt session or expected manifest contract.",
            ),
            simulation_insufficiency=SimulationInsufficiency(
                "signed-runtime-observation-required",
                "The exact signed runtime and its bounded receipt contract cannot be reproduced by a simulation.",
            ),
        )
    return None


def _apply_macos_launch_automation(
    candidates: dict[str, OperatorActionCandidate],
    report: ValidationReport,
) -> None:
    mac_action = candidates.get("macos.app.open")
    if mac_action is None or report.automation is None:
        return
    automation = report.automation or {}
    kind_reports = automation.get("kindReports")
    launch_report = (
        kind_reports.get("macos.app.launch")
        if isinstance(kind_reports, dict)
        else None
    )
    last_attempt = (
        launch_report.get("lastAttempt")
        if isinstance(launch_report, dict)
        else None
    )
    current_window = (
        isinstance(last_attempt, dict)
        and last_attempt.get("receiptWindowDigest") == macos_app_window_digest(report.mac)
    )
    terminal = (
        isinstance(last_attempt, dict)
        and last_attempt.get("result")
        in {"succeeded", "failed", "unsupported", "skipped-precondition"}
    )
    exhausted = (
        isinstance(launch_report, dict)
        and launch_report.get("remainingAttemptCount") == 0
    ) or automation.get("remainingTotalAttemptCount") == 0
    if current_window and terminal:
        return
    if exhausted:
        return

    candidates.pop("macos.app.open", None)
    candidates["coordinator.macos-app-launch-automation"] = OperatorActionCandidate(
        action_id="coordinator.macos-app-launch-automation",
        device="Coordinator",
        surfaces=mac_action.surfaces,
        reason_code="automation-attempt-required",
        action_kind="status-follow-up",
        estimate_minutes=1,
        instruction="Run the bounded coordinator automation once, then rerun status.",
        notification_kind=None,
        recovery_steps=(
            "Keep the canonical installed app and current placements unchanged.",
            "Run one bounded automation advancement.",
            "Rerun status to collect the re-observed runtime state.",
        ),
        simulation_insufficiency=SimulationInsufficiency(
            "signed-runtime-observation-required",
            "The canonical signed Mac runtime must be observed after the bounded launch attempt.",
        ),
    )


def build_operator_candidates(
    report: ValidationReport,
    session: CoordinatorSessionState,
    runtime_evidence: dict[str, Any] | None,
    state: OperatorFlowState,
    now: datetime,
) -> tuple[OperatorActionCandidate, ...]:
    if session.lifecycle != "active":
        return ()
    visual_approvals = report.visual_approvals or {}
    allowed_surfaces = tuple(
        sorted(
            {
                *session.requested_surfaces,
                *(
                    item.get("surface")
                    for item in visual_approvals.get("requirements") or []
                    if isinstance(item, dict) and isinstance(item.get("surface"), str)
                ),
            }
        )
    )
    candidates: dict[str, OperatorActionCandidate] = {
        candidate.action_id: candidate
        for candidate in (_base_action_candidate(action) for action in report.actions)
    }
    _apply_macos_launch_automation(candidates, report)
    _, _, scoped_device_labels = report_scope(session.requested_surfaces)
    for device in report.devices:
        if not device_is_in_scope(device, scoped_device_labels) or device.condition != "not_found":
            continue
        action_id = f"device.{_device_key(device.label)}.connect"
        candidates[action_id] = OperatorActionCandidate(
            action_id=action_id,
            device=device.label,
            surfaces=_surfaces_for_device(session.requested_surfaces, device.label),
            reason_code="device-not-found",
            action_kind="manual-recovery",
            estimate_minutes=3,
            instruction=f"Make a physical {device.label} available for this scoped validation session.",
            notification_kind="blockedDecisionRequired",
            recovery_steps=(
                "Use the existing signed installation when the device is available.",
                "Preserve app data and current placements.",
                "Rerun status after the physical device appears in CoreDevice.",
            ),
            simulation_insufficiency=SimulationInsufficiency(
                "physical-device-interaction-required",
                "A physical device is required for this scoped validation session.",
            ),
        )
    for wait in state.waits:
        first_seen = parse_iso8601(wait.first_seen_at)
        assert first_seen is not None
        elapsed = normalize_utc(now) - first_seen
        if wait.condition in {"locked", "asleep"} and elapsed >= MANUAL_ACCESS_ESCALATION:
            candidates[wait.action_id] = OperatorActionCandidate(
                action_id=wait.action_id,
                device=wait.device,
                surfaces=_surfaces_for_device(session.requested_surfaces, wait.device),
                reason_code="device-access-required",
                action_kind="manual-recovery",
                estimate_minutes=2,
                instruction=(
                    f"Unlock or wake {wait.device} once, then rerun status. "
                    "No extended awake period is required."
                ),
                notification_kind="manualUnlockRequired",
                recovery_steps=(
                    "Unlock or wake the device once.",
                    "Preserve the installed app and current placements.",
                    "Rerun status; normal waiting resumes automatically if evidence is still propagating.",
                ),
                simulation_insufficiency=SimulationInsufficiency(
                    "physical-device-interaction-required",
                    "Only an operator can unlock or wake the physical device once.",
                ),
            )
        elif wait.condition in {"not_reachable", "unavailable"} and elapsed >= UNREACHABLE_ESCALATION:
            candidates[wait.action_id] = OperatorActionCandidate(
                action_id=wait.action_id,
                device=wait.device,
                surfaces=_surfaces_for_device(session.requested_surfaces, wait.device),
                reason_code="device-access-required",
                action_kind="manual-recovery",
                estimate_minutes=3,
                instruction=f"Restore normal reachability for {wait.device}, then rerun status.",
                notification_kind="blockedDecisionRequired",
                recovery_steps=(
                    "Check normal power, pairing, and network reachability.",
                    "Preserve the installed app, data, and current placements.",
                    "Rerun status after the device is reachable.",
                ),
                simulation_insufficiency=SimulationInsufficiency(
                    "physical-device-interaction-required",
                    "Only the physical device can establish its normal reachability state.",
                ),
            )
    if runtime_evidence is not None:
        for surface in runtime_evidence.get("surfaces") or []:
            if not isinstance(surface, dict) or surface.get("state") not in {
                "diagnostic",
                "unknown",
            }:
                continue
            candidate = _runtime_recovery_candidate(surface, session.requested_surfaces)
            if candidate is not None:
                candidates[candidate.action_id] = candidate
        runtime_diagnostics = {
            str(item) for item in runtime_evidence.get("diagnostics") or [] if item
        }
        runtime_session = runtime_evidence.get("runtimeSession")
        if isinstance(runtime_session, dict):
            result = runtime_session.get("result")
            if isinstance(result, str) and result not in {"healthy", "waiting"}:
                runtime_diagnostics.add(f"runtime-session-{result}")
        if runtime_diagnostics:
            candidates["coordinator.runtime-diagnostic"] = OperatorActionCandidate(
                action_id="coordinator.runtime-diagnostic",
                device="Coordinator",
                surfaces=allowed_surfaces,
                reason_code="runtime-session-diagnostic",
                action_kind="operator-decision",
                estimate_minutes=5,
                instruction="Review the bounded runtime-session diagnostic before relying on the latest status.",
                notification_kind="blockedDecisionRequired",
                recovery_steps=(
                    "Preserve all previously proven exact-build receipts.",
                    "Rerun read-only status or the existing signed-host sync contract.",
                    "Escalate only the reported session, export, or relay diagnostic.",
                ),
                simulation_insufficiency=SimulationInsufficiency(
                    "signed-runtime-observation-required",
                    "The bounded signed runtime session is required to resolve its diagnostic.",
                ),
            )
    requirements_by_id = {
        item.get("id"): item
        for item in visual_approvals.get("requirements") or []
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    for batch in visual_approvals.get("reviewBatches") or []:
        if not isinstance(batch, dict):
            raise OperatorFlowError("visual review batch is invalid")
        action_id = _validate_action_id(batch.get("actionID"))
        device = _validate_device(batch.get("device"))
        estimate_minutes = batch.get("estimateMinutes")
        instruction = batch.get("instruction")
        evidence_class = batch.get("evidenceClass")
        requirement_ids = batch.get("requirementIDs")
        surfaces = batch.get("surfaces")
        runtime_surfaces = batch.get("runtimeSurfaces")
        requires_runtime = batch.get("requiresRuntime")
        if (
            not isinstance(estimate_minutes, int)
            or isinstance(estimate_minutes, bool)
            or not 1 <= estimate_minutes <= 60
            or not isinstance(instruction, str)
            or not instruction
            or not isinstance(requirement_ids, list)
            or not requirement_ids
            or any(not isinstance(item, str) for item in requirement_ids)
            or len(requirement_ids) != len(set(requirement_ids))
            or not isinstance(surfaces, list)
            or not surfaces
            or any(not isinstance(surface, str) for surface in surfaces)
            or not isinstance(runtime_surfaces, list)
            or any(not isinstance(surface, str) for surface in runtime_surfaces)
            or not isinstance(requires_runtime, bool)
            or evidence_class not in {"shared-view", "os-composited-placement"}
        ):
            raise OperatorFlowError("visual review batch is invalid")
        requirements = [requirements_by_id.get(requirement_id) for requirement_id in requirement_ids]
        if any(
            not isinstance(item, dict)
            or not isinstance(item.get("surface"), str)
            or item.get("evidenceClass") != evidence_class
            for item in requirements
        ):
            raise OperatorFlowError("visual review batch is invalid")
        expected_surfaces = tuple(sorted({item["surface"] for item in requirements}))
        expected_runtime_surfaces = (
            expected_surfaces if evidence_class == "os-composited-placement" else ()
        )
        if (
            any(item.get("device") != device for item in requirements)
            or tuple(surfaces) != expected_surfaces
            or tuple(runtime_surfaces) != expected_runtime_surfaces
            or requires_runtime != (evidence_class == "os-composited-placement")
        ):
            raise OperatorFlowError("visual review batch is invalid")
        proven_runtime_surfaces = {
            item.get("surface")
            for item in (runtime_evidence or {}).get("surfaces") or []
            if isinstance(item, dict)
            and isinstance(item.get("surface"), str)
            and item.get("state") == "proven"
        }
        if requires_runtime and (
            (runtime_evidence or {}).get("state") == "superseded"
            or not set(expected_runtime_surfaces).issubset(proven_runtime_surfaces)
        ):
            continue
        candidates[action_id] = OperatorActionCandidate(
            action_id=action_id,
            device=device,
            surfaces=expected_surfaces,
            reason_code="visual-review-required",
            action_kind="visual-review",
            estimate_minutes=estimate_minutes,
            instruction=instruction,
            notification_kind="readyForHumanReview",
            recovery_steps=(
                "Open the signed validation gallery or real placed surface named by status.",
                "Preserve the exact installed build and existing placements.",
                "Record approve or reject for every listed requirement ID.",
            ),
            simulation_insufficiency=SimulationInsufficiency(
                "visual-presentation-review-required",
                "The signed surface must be reviewed in its actual presentation context.",
            ),
        )
    if report.state == "blocked" and not any(
        candidate.notification_kind == "blockedDecisionRequired"
        for candidate in candidates.values()
    ):
        candidates["coordinator.blocked-decision"] = OperatorActionCandidate(
            action_id="coordinator.blocked-decision",
            device="Coordinator",
            surfaces=allowed_surfaces,
            reason_code="validation-blocked",
            action_kind="operator-decision",
            estimate_minutes=5,
            instruction="Review the exact-build blocker before deciding whether to stop or replace the session.",
            notification_kind="blockedDecisionRequired",
            recovery_steps=(
                "Compare the observed build with the coordinator target.",
                "Preserve all collected evidence and signed runtimes.",
                "Replace the session only when the newer target is intentional.",
            ),
            simulation_insufficiency=SimulationInsufficiency(
                "operator-attestation-required",
                "The exact-build blocker requires an operator decision about the active session.",
            ),
        )
    result = tuple(
        sorted(
            candidates.values(),
            key=lambda item: (*_device_sort_key(item.device), item.action_id),
        )
    )
    validate_operator_candidates(result, allowed_surfaces)
    return result


def build_operator_flow_report(
    report: ValidationReport,
    session: CoordinatorSessionState,
    runtime_evidence: dict[str, Any] | None,
    state: OperatorFlowState,
    now: datetime,
) -> dict[str, Any]:
    candidates = build_operator_candidates(report, session, runtime_evidence, state, now)
    groups_by_device: dict[str, list[dict[str, Any]]] = {}
    ready_ids: set[str] = set()
    deferred_ids: set[str] = set()
    for candidate in candidates:
        deferral = _active_deferral(state.deferrals, candidate.action_id, now)
        action_state = "deferred" if deferral is not None else "ready"
        if deferral is None:
            ready_ids.add(candidate.action_id)
        else:
            deferred_ids.add(candidate.action_id)
        groups_by_device.setdefault(candidate.device, []).append(
            {
                "id": candidate.action_id,
                "state": action_state,
                "estimate": _estimate(candidate.estimate_minutes),
                "instruction": candidate.instruction,
                "notificationKind": candidate.notification_kind,
                "surfaces": list(candidate.surfaces),
                "reasonCode": candidate.reason_code,
                "actionKind": candidate.action_kind,
                "durationMinutes": candidate.estimate_minutes,
                "simulationInsufficiency": {
                    "code": candidate.simulation_insufficiency.code,
                    "explanation": candidate.simulation_insufficiency.explanation,
                },
                "recoverySteps": list(candidate.recovery_steps),
                "deferral": (
                    {
                        "owner": deferral.owner,
                        "reason": deferral.reason,
                        "expiresAt": deferral.expires_at,
                        "residualRisk": deferral.residual_risk,
                    }
                    if deferral is not None
                    else None
                ),
            }
        )
    groups = []
    for device in sorted(groups_by_device, key=_device_sort_key):
        actions = groups_by_device[device]
        total_minutes = sum(
            next(
                candidate.estimate_minutes
                for candidate in candidates
                if candidate.action_id == action["id"]
            )
            for action in actions
        )
        groups.append(
            {
                "device": device,
                "estimate": _estimate(total_minutes),
                "durationMinutes": total_minutes,
                "actions": actions,
            }
        )
    current_decisions = [
        item.to_dict()
        for item in state.notification_decisions
        if item.action_id in ready_ids
    ]
    deferrals = [
        {
            **item.to_dict(),
            "status": item.status(now),
        }
        for item in state.deferrals
    ]
    active_deferrals = [item for item in deferrals if item["status"] == "active"]
    residual_risks = sorted(
        {
            item["residualRisk"]
            for item in deferrals
            if item["status"] in {"active", "expired"}
        }
    )
    runtime_diagnostics = sorted(
        {
            str(item)
            for item in (runtime_evidence or {}).get("diagnostics") or []
            if item
        }
    )
    runtime_session = (runtime_evidence or {}).get("runtimeSession")
    if isinstance(runtime_session, dict):
        result = runtime_session.get("result")
        if isinstance(result, str) and result not in {"healthy", "waiting"}:
            runtime_diagnostics.append(f"runtime-session-{result}")
            runtime_diagnostics = sorted(set(runtime_diagnostics))
    if session.lifecycle == "paused":
        flow_state = "paused"
    elif ready_ids:
        flow_state = "ready"
    elif deferred_ids:
        flow_state = "deferred"
    elif report.state == "waiting":
        flow_state = "waiting"
    elif report.state in {"blocked", "unknown"}:
        flow_state = report.state
    else:
        flow_state = "complete"
    return {
        "schemaVersion": 1,
        "state": flow_state,
        "machineWaiting": flow_state == "waiting",
        "readyActionCount": len(ready_ids),
        "deferredActionCount": len(deferred_ids),
        "totalDurationMinutes": sum(group["durationMinutes"] for group in groups),
        "groups": groups,
        "notificationDecisions": current_decisions,
        "deferrals": deferrals,
        "activeDeferrals": active_deferrals,
        "residualRisks": residual_risks,
        "runtimeDiagnostics": runtime_diagnostics,
        "sidecarRevision": state.revision,
    }


def _estimate(minutes: int) -> str:
    return f"about {minutes} minute{'s' if minutes != 1 else ''}"


def apply_operator_flow_to_report(
    report: ValidationReport,
    operator_flow: dict[str, Any],
) -> ValidationReport:
    ready_actions: list[OperatorAction] = []
    for group in operator_flow["groups"]:
        for action in group["actions"]:
            if action["state"] != "ready":
                continue
            ready_actions.append(
                OperatorAction(
                    device=group["device"],
                    estimate=action["estimate"],
                    instruction=action["instruction"],
                    id=action["id"],
                    notification_kind=action["notificationKind"],
                    surfaces=tuple(action["surfaces"]),
                    reason_code=action["reasonCode"],
                    action_kind=action["actionKind"],
                    duration_minutes=action["durationMinutes"],
                    simulation_insufficiency=action["simulationInsufficiency"],
                )
            )
    state = report.state
    stage = report.stage
    exit_code = report.exit_code
    closing = report.headline.rsplit(" · ", 1)[-1]
    if operator_flow["runtimeDiagnostics"] and report.state != "blocked":
        state, stage, exit_code = "unknown", "runtime evidence diagnostic", EXIT_UNKNOWN
        closing = "not enough evidence: runtime session diagnostics require attention"
    elif ready_actions and report.state not in {"blocked", "unknown"}:
        state, stage, exit_code = "ready_for_you", "ready for you", EXIT_READY
        closing = f"{len(ready_actions)} action{'s' if len(ready_actions) != 1 else ''} ready for you"
    elif (
        not ready_actions
        and operator_flow["deferredActionCount"]
        and report.state not in {"blocked", "unknown"}
    ):
        state, stage, exit_code = "ready_for_you", "deferred", EXIT_READY
        closing = "requirements deferred; residual risk remains"
    limitations = report.limitations
    if operator_flow["deferredActionCount"]:
        limitation = "Deferrals preserve residual risk and never satisfy evidence."
        if limitation not in limitations:
            limitations = (*limitations, limitation)
    prefix = report.headline.rsplit(" · ", 1)[0]
    return replace(
        report,
        state=state,
        stage=stage,
        headline=f"{prefix} · {closing}",
        exit_code=exit_code,
        actions=tuple(ready_actions),
        limitations=limitations,
        operator_flow=operator_flow,
    )


def project_automation_report(automation: object) -> dict[str, Any]:
    if not isinstance(automation, dict):
        raise OperatorFlowError("automation report is invalid")

    def project_attempt(attempt: object) -> dict[str, Any] | None:
        if attempt is None:
            return None
        if not isinstance(attempt, dict) or not isinstance(attempt.get("summary"), dict):
            raise OperatorFlowError("automation report is invalid")
        summary = attempt["summary"]
        return {
            "id": attempt["id"],
            "kind": attempt["kind"],
            "result": attempt["result"],
            "reasonCode": attempt["reasonCode"],
            "startedAt": attempt["startedAt"],
            "finishedAt": attempt["finishedAt"],
            "receiptWindowDigest": attempt["receiptWindowDigest"],
            "summary": {
                "runtimeEvidenceState": summary["runtimeEvidenceState"],
                "requestedSurfaceCount": summary["requestedSurfaceCount"],
                "provenSurfaceCount": summary["provenSurfaceCount"],
                "receiptCount": summary["receiptCount"],
                "diagnosticCount": summary["diagnosticCount"],
                "evidenceSatisfied": summary["evidenceSatisfied"],
            },
        }

    try:
        kind_reports = automation["kindReports"]
        if not isinstance(kind_reports, dict) or set(kind_reports) != AUTOMATION_KINDS:
            raise OperatorFlowError("automation report is invalid")
        projected_kind_reports = {}
        for kind in sorted(AUTOMATION_KINDS):
            report = kind_reports[kind]
            if not isinstance(report, dict):
                raise OperatorFlowError("automation report is invalid")
            projected_kind_reports[kind] = {
                "kind": report["kind"],
                "state": report["state"],
                "attemptCount": report["attemptCount"],
                "remainingAttemptCount": report["remainingAttemptCount"],
                "evidenceSatisfied": report["evidenceSatisfied"],
                "lastAttempt": project_attempt(report["lastAttempt"]),
            }
        projected = {
            "schemaVersion": automation["schemaVersion"],
            "state": automation["state"],
            "attemptCount": automation["attemptCount"],
            "remainingAttemptCount": automation["remainingAttemptCount"],
            "evidenceSatisfied": automation["evidenceSatisfied"],
            "lastAttempt": project_attempt(automation["lastAttempt"]),
            "totalAttemptCount": automation["totalAttemptCount"],
            "remainingTotalAttemptCount": automation["remainingTotalAttemptCount"],
            "kindReports": projected_kind_reports,
        }
        runtime = projected_kind_reports["runtime.receipt.sync"]
        if any(
            projected[key] != runtime[key]
            for key in (
                "state",
                "attemptCount",
                "remainingAttemptCount",
                "evidenceSatisfied",
                "lastAttempt",
            )
        ):
            raise OperatorFlowError("automation report is invalid")
        return projected
    except (KeyError, TypeError) as error:
        raise OperatorFlowError("automation report is invalid") from error


def build_final_report_payload(report: ValidationReport) -> dict[str, Any]:
    session = report.session or {}
    requested_surfaces = list(session.get("requestedSurfaces", []))
    runtime = report.runtime_evidence or {
        "state": "not-collected",
        "provenSurfaceCount": 0,
        "requestedSurfaceCount": len(requested_surfaces),
        "runtimeSession": None,
        "diagnostics": [],
        "surfaces": [
            {
                "surface": surface,
                "state": "unknown",
                "reason": "runtime-evidence-not-attached",
            }
            for surface in requested_surfaces
        ],
    }
    operator_flow = report.operator_flow or {
        "schemaVersion": 1,
        "state": "not-collected",
        "totalDurationMinutes": 0,
        "groups": [],
        "notificationDecisions": [],
        "deferrals": [],
        "residualRisks": [],
        "runtimeDiagnostics": [],
    }
    visual_approvals = report.visual_approvals or {
        "state": "not-evaluated-by-coordinator",
        "requirementCount": 0,
        "approvedCount": 0,
        "rejectedCount": 0,
        "readyReviewCount": 0,
        "machineWaitingCount": 0,
        "requirements": [],
    }
    automation = project_automation_report(
        report.automation or build_automation_report(None)
    )
    if any(not isinstance(surface, str) for surface in requested_surfaces):
        raise OperatorFlowError("operator action contract is invalid")
    allowed_action_surfaces = sorted(
        {
            *requested_surfaces,
            *(
                item.get("surface")
                for item in visual_approvals.get("requirements") or []
                if isinstance(item, dict) and isinstance(item.get("surface"), str)
            ),
        }
    )
    validate_operator_flow_actions(operator_flow, allowed_action_surfaces)
    watch_required = any(
        str(surface).startswith("watchos.")
        for surface in session.get("requestedSurfaces", [])
    )
    obtained_classes = {
        "appStoreConnect": report.asc.status,
        "canonicalMacProductionRuntime": report.mac.baseline_state,
        "exactBuildRuntimeReceipts": {
            "state": runtime["state"],
            "proven": runtime["provenSurfaceCount"],
            "required": runtime["requestedSurfaceCount"],
            "runtimeSessionResult": (
                runtime.get("runtimeSession", {}).get("result")
                if isinstance(runtime.get("runtimeSession"), dict)
                else None
            ),
            "diagnostics": list(runtime.get("diagnostics") or []),
        },
        "watchRestartAttestation": (
            "recorded"
            if report.watch_restart_recorded_at
            else "missing" if watch_required else "not-required"
        ),
        "visualApproval": visual_approvals["state"],
    }
    blockers = []
    if report.state == "blocked":
        blockers.append("coordinator-state-blocked")
    blockers.extend(
        action["id"]
        for group in operator_flow["groups"]
        for action in group["actions"]
        if action["notificationKind"] == "blockedDecisionRequired"
    )
    unproven_surfaces = [
        surface["surface"]
        for surface in runtime["surfaces"]
        if surface["state"] != "proven"
    ]
    residual_risks = sorted(
        {
            *operator_flow["residualRisks"],
            *("runtime-unproven" for _ in unproven_surfaces),
            *("review-pending" for _ in [0] if obtained_classes["visualApproval"] != "approved"),
        }
    )
    return {
        "schemaVersion": 1,
        "target": {
            "version": report.target.version,
            "buildNumber": report.target.build_number,
        },
        "summary": {
            "state": report.state,
            "stage": report.stage,
            "headline": report.headline,
            "exitCode": report.exit_code,
        },
        "session": {
            "lifecycle": session.get("lifecycle"),
            "revision": session.get("revision"),
            "createdAt": session.get("createdAt"),
            "updatedAt": session.get("updatedAt"),
            "requestedSurfaces": session.get("requestedSurfaces", []),
        },
        "requiredEvidenceClasses": [
            "appStoreConnect",
            "canonicalMacProductionRuntime",
            "exactBuildRuntimeReceipts",
            "watchRestartAttestation",
            "visualApproval",
        ],
        "obtainedEvidenceClasses": obtained_classes,
        "runtimeSurfaces": [
            {
                "surface": surface["surface"],
                "state": surface["state"],
                "reason": surface["reason"],
                "manifestID": surface.get("manifestID"),
                "expectedBuildID": surface.get("expectedBuildID"),
                "identityDigest": surface.get("identityDigest"),
                "runtimeFingerprint": surface.get("runtimeFingerprint"),
                "observedAt": surface.get("lastObservedAt"),
                "receiptIDs": list(surface.get("receiptIDs") or []),
            }
            for surface in runtime["surfaces"]
        ],
        "visualApprovals": {
            "state": visual_approvals["state"],
            "requirementCount": visual_approvals["requirementCount"],
            "approvedCount": visual_approvals["approvedCount"],
            "rejectedCount": visual_approvals["rejectedCount"],
            "readyReviewCount": visual_approvals["readyReviewCount"],
            "machineWaitingCount": visual_approvals["machineWaitingCount"],
            "requirements": [
                {
                    "id": item["id"],
                    "evidenceClass": item["evidenceClass"],
                    "surface": item["surface"],
                    "device": item["device"],
                    "state": item["state"],
                    "reason": item["reason"],
                    "manifestID": item.get("manifestID"),
                    "expectedBuildID": item.get("expectedBuildID"),
                    "contractFingerprint": item.get("contractFingerprint"),
                    "identityDigest": item.get("identityDigest"),
                    "hostOS": item.get("hostOS"),
                    "renderFingerprint": item.get("renderFingerprint"),
                    "placementFingerprint": item.get("placementFingerprint"),
                    "decision": item.get("decision"),
                }
                for item in visual_approvals.get("requirements") or []
            ],
        },
        "automation": automation,
        "operatorFlow": operator_flow,
        "carryForwardLineage": {
            "state": "not-evaluated",
            "entries": [],
            "reason": "release-gate carry-forward is outside the coordinator slice",
        },
        "blockers": sorted(set(blockers)),
        "residualRisks": residual_risks,
        "limitations": list(report.limitations),
        "privacy": (
            "Contains no device identifiers, account data, credentials, private paths, "
            "raw provider responses, raw receipt documents, private artifact contents, "
            "or App Store Connect object IDs."
        ),
    }


def render_final_report(report: ValidationReport) -> str:
    payload = build_final_report_payload(report)
    target = payload["target"]
    summary = payload["summary"]
    session = payload["session"]
    obtained = payload["obtainedEvidenceClasses"]
    lines = [
        f"# Signed Validation Report — {target['version']} ({target['buildNumber']})",
        "",
        f"**State:** `{summary['state']}` — {summary['stage']}",
        f"**Session:** `{session['lifecycle'] or 'none'}` · revision {session['revision'] or 0}",
        "",
        "## Evidence",
        "",
        f"- App Store Connect: `{obtained['appStoreConnect']}`",
        f"- Canonical Mac Production runtime: `{obtained['canonicalMacProductionRuntime']}`",
        (
            "- Exact-build runtime receipts: "
            f"`{obtained['exactBuildRuntimeReceipts']['proven']}/"
            f"{obtained['exactBuildRuntimeReceipts']['required']}` proven"
        ),
        f"- Watch restart attestation: `{obtained['watchRestartAttestation']}`",
        f"- Visual approval: `{obtained['visualApproval']}`",
        (
            "- Receipt-sync automation: "
            f"`{payload['automation']['state']}` · "
            f"`{payload['automation']['attemptCount']}` attempts"
        ),
    ]
    runtime_diagnostics = obtained["exactBuildRuntimeReceipts"]["diagnostics"]
    if runtime_diagnostics:
        lines.append(
            "- Runtime diagnostics: "
            + ", ".join(f"`{item}`" for item in runtime_diagnostics)
        )
    lines.extend(["", "## Operator Queue", ""])
    groups = payload["operatorFlow"]["groups"]
    if groups:
        for group in groups:
            lines.append(f"### {group['device']} — {group['estimate']}")
            lines.append("")
            for action in group["actions"]:
                lines.append(
                    f"- `{action['id']}` — {action['state']}: {action['instruction']}"
                )
                if action["deferral"] is not None:
                    deferral = action["deferral"]
                    lines.append(
                        "  - Deferred until "
                        f"`{deferral['expiresAt']}` by `{deferral['owner']}`; "
                        f"residual risk `{deferral['residualRisk']}`."
                    )
            lines.append("")
    else:
        lines.extend(["No operator actions are currently queued.", ""])
    lines.extend(["## Runtime Surfaces", ""])
    if payload["runtimeSurfaces"]:
        lines.extend(
            f"- `{surface['surface']}`: `{surface['state']}` — {surface['reason']}"
            for surface in payload["runtimeSurfaces"]
        )
    else:
        lines.append("No runtime surface evidence is attached.")
    visual = payload["visualApprovals"]
    lines.extend(["", "## Visual Reviews", ""])
    if visual["requirements"]:
        lines.append(
            f"`{visual['approvedCount']}/{visual['requirementCount']}` approved · "
            f"`{visual['rejectedCount']}` rejected · "
            f"`{visual['machineWaitingCount']}` waiting on machine evidence"
        )
        lines.append("")
        lines.extend(
            f"- `{item['id']}` · `{item['surface']}` · `{item['state']}` — {item['reason']}"
            for item in visual["requirements"]
        )
    else:
        lines.append("No visual review requirements are attached.")
    lines.extend(["", "## Blockers And Residual Risk", ""])
    if payload["blockers"]:
        lines.extend(f"- Blocker: `{item}`" for item in payload["blockers"])
    if payload["residualRisks"]:
        lines.extend(f"- Residual risk: `{item}`" for item in payload["residualRisks"])
    if not payload["blockers"] and not payload["residualRisks"]:
        lines.append("No blocker or residual risk is recorded by this coordinator slice.")
    lines.extend(
        [
            "",
            "## Carry-Forward",
            "",
            "Not evaluated in this coordinator slice; release-gate carry-forward belongs to #523.",
            "",
            "## Privacy",
            "",
            payload["privacy"],
        ]
    )
    return "\n".join(lines)
