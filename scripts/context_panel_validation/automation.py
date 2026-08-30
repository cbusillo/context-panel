from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import datetime, timedelta
import fcntl
import hashlib
import json
import os
from typing import Iterator

from .models import Target, iso8601
from .session import (
    CoordinatorSessionState,
    CoordinatorSessionStateError,
    RUNTIME_SURFACES,
    SessionStateStore,
    normalize_utc,
    parse_iso8601,
)


AUTOMATION_SCHEMA_VERSION = 1
MAXIMUM_AUTOMATION_ATTEMPT_COUNT = 64
AUTOMATION_COOLDOWN = timedelta(minutes=5)
AUTOMATION_KINDS = {"runtime.receipt.sync"}
AUTOMATION_RESULTS = {"succeeded", "failed", "unsupported", "skipped-precondition"}
ATTEMPT_REASONS = {
    "succeeded": {"runtime-receipts-reconciled"},
    "failed": {
        "runtime-evidence-superseded",
        "runtime-reconciliation-failed",
        "runtime-sync-degraded",
    },
    "unsupported": {"runtime-sync-unavailable"},
    "skipped-precondition": {
        "runtime-evidence-complete",
        "runtime-evidence-unavailable",
    },
}
RUNTIME_REPORT_STATES = {"unavailable", "unknown", "waiting", "proven", "superseded"}
SHA256_HEX_LENGTH = 64


class AutomationError(CoordinatorSessionStateError):
    pass


def canonical_json(payload: object) -> bytes:
    return json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")


def sha256_digest(domain: str, payload: object) -> str:
    return hashlib.sha256(domain.encode("utf-8") + b"\0" + canonical_json(payload)).hexdigest()


def automation_attempt_id(
    coordinator_session_digest: str,
    *,
    kind: str,
    started_at: str,
    finished_at: str,
    receipt_window_digest: str,
    result: str,
    reason_code: str,
) -> str:
    return sha256_digest(
        "context-panel-validation/automation/attempt/v1",
        {
            "coordinatorSessionDigest": coordinator_session_digest,
            "kind": kind,
            "startedAt": started_at,
            "finishedAt": finished_at,
            "receiptWindowDigest": receipt_window_digest,
            "result": result,
            "reasonCode": reason_code,
        },
    )


def is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == SHA256_HEX_LENGTH
        and all(character in "0123456789abcdef" for character in value)
    )


def session_digest(session: CoordinatorSessionState) -> str:
    return sha256_digest("context-panel-validation/automation/session/v1", session.id.lower())


def target_digest(target: Target) -> str:
    return sha256_digest(
        "context-panel-validation/automation/target/v1",
        {"buildNumber": target.build_number, "version": target.version},
    )


def requested_surfaces_digest(session: CoordinatorSessionState) -> str:
    return sha256_digest(
        "context-panel-validation/automation/requested-surfaces/v1",
        list(session.requested_surfaces),
    )


@dataclass(frozen=True)
class AutomationSummary:
    runtime_evidence_state: str
    requested_surface_count: int
    proven_surface_count: int
    receipt_count: int
    diagnostic_count: int
    evidence_satisfied: bool

    def to_dict(self) -> dict[str, object]:
        return {
            "runtimeEvidenceState": self.runtime_evidence_state,
            "requestedSurfaceCount": self.requested_surface_count,
            "provenSurfaceCount": self.proven_surface_count,
            "receiptCount": self.receipt_count,
            "diagnosticCount": self.diagnostic_count,
            "evidenceSatisfied": self.evidence_satisfied,
        }

    @classmethod
    def from_dict(cls, payload: object) -> AutomationSummary:
        expected_keys = {
            "runtimeEvidenceState",
            "requestedSurfaceCount",
            "provenSurfaceCount",
            "receiptCount",
            "diagnosticCount",
            "evidenceSatisfied",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise AutomationError("automation attempt summary is invalid")
        summary = cls(
            runtime_evidence_state=payload.get("runtimeEvidenceState"),
            requested_surface_count=payload.get("requestedSurfaceCount"),
            proven_surface_count=payload.get("provenSurfaceCount"),
            receipt_count=payload.get("receiptCount"),
            diagnostic_count=payload.get("diagnosticCount"),
            evidence_satisfied=payload.get("evidenceSatisfied"),
        )
        if (
            summary.runtime_evidence_state not in RUNTIME_REPORT_STATES
            or any(
                not isinstance(value, int) or isinstance(value, bool) or value < 0
                for value in (
                    summary.requested_surface_count,
                    summary.proven_surface_count,
                    summary.receipt_count,
                    summary.diagnostic_count,
                )
            )
            or summary.proven_surface_count > summary.requested_surface_count
            or not isinstance(summary.evidence_satisfied, bool)
            or (
                summary.evidence_satisfied
                and not (
                    summary.runtime_evidence_state == "proven"
                    and summary.proven_surface_count == summary.requested_surface_count
                )
            )
        ):
            raise AutomationError("automation attempt summary is invalid")
        return summary

    def runtime_evidence_is_proven(self) -> bool:
        return (
            self.runtime_evidence_state == "proven"
            and self.proven_surface_count == self.requested_surface_count
        )


@dataclass(frozen=True)
class AutomationAttempt:
    id: str
    kind: str
    result: str
    reason_code: str
    started_at: str
    finished_at: str
    receipt_window_digest: str
    summary: AutomationSummary

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "kind": self.kind,
            "result": self.result,
            "reasonCode": self.reason_code,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "receiptWindowDigest": self.receipt_window_digest,
            "summary": self.summary.to_dict(),
        }

    @classmethod
    def from_dict(cls, payload: object) -> AutomationAttempt:
        expected_keys = {
            "id",
            "kind",
            "result",
            "reasonCode",
            "startedAt",
            "finishedAt",
            "receiptWindowDigest",
            "summary",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise AutomationError("automation attempt is invalid")
        attempt = cls(
            id=payload.get("id"),
            kind=payload.get("kind"),
            result=payload.get("result"),
            reason_code=payload.get("reasonCode"),
            started_at=payload.get("startedAt"),
            finished_at=payload.get("finishedAt"),
            receipt_window_digest=payload.get("receiptWindowDigest"),
            summary=AutomationSummary.from_dict(payload.get("summary")),
        )
        started_at = parse_iso8601(attempt.started_at)
        finished_at = parse_iso8601(attempt.finished_at)
        if (
            not is_sha256(attempt.id)
            or attempt.kind not in AUTOMATION_KINDS
            or attempt.result not in AUTOMATION_RESULTS
            or attempt.reason_code not in ATTEMPT_REASONS[attempt.result]
            or started_at is None
            or finished_at is None
            or started_at > finished_at
            or not is_sha256(attempt.receipt_window_digest)
            or attempt.summary.evidence_satisfied
            != (attempt.result == "succeeded" and attempt.summary.runtime_evidence_is_proven())
        ):
            raise AutomationError("automation attempt is invalid")
        return attempt


@dataclass(frozen=True)
class AutomationState:
    schema_version: int
    coordinator_session_digest: str
    target_digest: str
    requested_surfaces_digest: str
    requested_surface_count: int
    updated_at: str
    revision: int
    attempts: tuple[AutomationAttempt, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "schemaVersion": self.schema_version,
            "coordinatorSessionDigest": self.coordinator_session_digest,
            "targetDigest": self.target_digest,
            "requestedSurfacesDigest": self.requested_surfaces_digest,
            "requestedSurfaceCount": self.requested_surface_count,
            "updatedAt": self.updated_at,
            "revision": self.revision,
            "attempts": [attempt.to_dict() for attempt in self.attempts],
        }

    @classmethod
    def from_dict(cls, payload: object) -> AutomationState:
        expected_keys = {
            "schemaVersion",
            "coordinatorSessionDigest",
            "targetDigest",
            "requestedSurfacesDigest",
            "requestedSurfaceCount",
            "updatedAt",
            "revision",
            "attempts",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise AutomationError("automation state is invalid")
        attempts_payload = payload.get("attempts")
        if not isinstance(attempts_payload, list):
            raise AutomationError("automation state is invalid")
        state = cls(
            schema_version=payload.get("schemaVersion"),
            coordinator_session_digest=payload.get("coordinatorSessionDigest"),
            target_digest=payload.get("targetDigest"),
            requested_surfaces_digest=payload.get("requestedSurfacesDigest"),
            requested_surface_count=payload.get("requestedSurfaceCount"),
            updated_at=payload.get("updatedAt"),
            revision=payload.get("revision"),
            attempts=tuple(AutomationAttempt.from_dict(attempt) for attempt in attempts_payload),
        )
        updated_at = parse_iso8601(state.updated_at)
        if (
            state.schema_version != AUTOMATION_SCHEMA_VERSION
            or any(
                not is_sha256(value)
                for value in (
                    state.coordinator_session_digest,
                    state.target_digest,
                    state.requested_surfaces_digest,
                )
            )
            or not isinstance(state.requested_surface_count, int)
            or isinstance(state.requested_surface_count, bool)
            or not 0 <= state.requested_surface_count <= len(RUNTIME_SURFACES)
            or updated_at is None
            or not isinstance(state.revision, int)
            or isinstance(state.revision, bool)
            or state.revision < 1
            or len(state.attempts) > MAXIMUM_AUTOMATION_ATTEMPT_COUNT
            or state.revision != len(state.attempts) + 1
            or len({attempt.id for attempt in state.attempts}) != len(state.attempts)
        ):
            raise AutomationError("automation state is invalid")
        finished_times = []
        for attempt in state.attempts:
            attempt_finished_at = parse_iso8601(attempt.finished_at)
            assert attempt_finished_at is not None
            finished_times.append(attempt_finished_at)
            expected_id = automation_attempt_id(
                state.coordinator_session_digest,
                kind=attempt.kind,
                started_at=attempt.started_at,
                finished_at=attempt.finished_at,
                receipt_window_digest=attempt.receipt_window_digest,
                result=attempt.result,
                reason_code=attempt.reason_code,
            )
            if attempt.id != expected_id:
                raise AutomationError("automation state is invalid")
        if finished_times and (
            finished_times != sorted(finished_times)
            or updated_at != finished_times[-1]
        ):
            raise AutomationError("automation state is invalid")
        return state


def new_automation_state(session: CoordinatorSessionState, now: datetime) -> AutomationState:
    state = AutomationState(
        schema_version=AUTOMATION_SCHEMA_VERSION,
        coordinator_session_digest=session_digest(session),
        target_digest=target_digest(session.target),
        requested_surfaces_digest=requested_surfaces_digest(session),
        requested_surface_count=len(session.requested_surfaces),
        updated_at=iso8601(normalize_utc(now)),
        revision=1,
        attempts=(),
    )
    AutomationState.from_dict(state.to_dict())
    return state


def validate_session_binding(state: AutomationState, session: CoordinatorSessionState) -> None:
    if (
        state.coordinator_session_digest != session_digest(session)
        or state.target_digest != target_digest(session.target)
        or state.requested_surfaces_digest != requested_surfaces_digest(session)
        or state.requested_surface_count != len(session.requested_surfaces)
    ):
        raise AutomationError("automation state does not match its coordinator session")


def build_automation_summary(runtime_report: dict[str, object] | None) -> AutomationSummary:
    if runtime_report is None:
        return AutomationSummary("unavailable", 0, 0, 0, 0, False)
    state = runtime_report.get("state")
    surfaces = runtime_report.get("surfaces")
    diagnostics = runtime_report.get("diagnostics")
    if (
        not isinstance(state, str)
        or state not in RUNTIME_REPORT_STATES - {"unavailable"}
        or not isinstance(surfaces, list)
        or not isinstance(diagnostics, list)
    ):
        raise AutomationError("runtime evidence report is invalid")
    receipt_count = 0
    for surface in surfaces:
        if not isinstance(surface, dict) or not isinstance(surface.get("receiptCount"), int):
            raise AutomationError("runtime evidence report is invalid")
        receipt_count += int(surface["receiptCount"])
    requested_surface_count = runtime_report.get("requestedSurfaceCount")
    proven_surface_count = runtime_report.get("provenSurfaceCount")
    if (
        not isinstance(requested_surface_count, int)
        or isinstance(requested_surface_count, bool)
        or not isinstance(proven_surface_count, int)
        or isinstance(proven_surface_count, bool)
    ):
        raise AutomationError("runtime evidence report is invalid")
    return AutomationSummary(
        runtime_evidence_state=state,
        requested_surface_count=requested_surface_count,
        proven_surface_count=proven_surface_count,
        receipt_count=receipt_count,
        diagnostic_count=len(diagnostics),
        evidence_satisfied=(state == "proven" and proven_surface_count == requested_surface_count),
    )


def runtime_report_digest(runtime_report: dict[str, object] | None) -> str:
    summary = build_automation_summary(runtime_report).to_dict()
    runtime_session = runtime_report.get("runtimeSession") if runtime_report else None
    if runtime_session is not None and not isinstance(runtime_session, dict):
        raise AutomationError("runtime evidence report is invalid")
    public_window = {
        "summary": summary,
        "runtimeSession": (
            {
                "active": runtime_session.get("active"),
                "expiresAt": runtime_session.get("expiresAt"),
                "result": runtime_session.get("result"),
            }
            if runtime_session is not None
            else None
        ),
    }
    return sha256_digest("context-panel-validation/automation/receipt-window/v1", public_window)


def make_attempt(
    state: AutomationState,
    *,
    result: str,
    reason_code: str,
    started_at: datetime,
    finished_at: datetime,
    runtime_report: dict[str, object] | None,
) -> AutomationAttempt:
    if result not in AUTOMATION_RESULTS or reason_code not in ATTEMPT_REASONS[result]:
        raise AutomationError("automation attempt is invalid")
    started_at_text = iso8601(normalize_utc(started_at))
    finished_at_text = iso8601(max(normalize_utc(finished_at), normalize_utc(started_at)))
    window_digest = runtime_report_digest(runtime_report)
    attempt_id = automation_attempt_id(
        state.coordinator_session_digest,
        kind="runtime.receipt.sync",
        started_at=started_at_text,
        finished_at=finished_at_text,
        receipt_window_digest=window_digest,
        result=result,
        reason_code=reason_code,
    )
    summary = build_automation_summary(runtime_report)
    if result != "succeeded" and summary.evidence_satisfied:
        summary = replace(summary, evidence_satisfied=False)
    return AutomationAttempt(
        id=attempt_id,
        kind="runtime.receipt.sync",
        result=result,
        reason_code=reason_code,
        started_at=started_at_text,
        finished_at=finished_at_text,
        receipt_window_digest=window_digest,
        summary=summary,
    )


def build_automation_report(state: AutomationState | None) -> dict[str, object]:
    if state is None:
        return {
            "schemaVersion": 1,
            "state": "not-started",
            "attemptCount": 0,
            "remainingAttemptCount": MAXIMUM_AUTOMATION_ATTEMPT_COUNT,
            "evidenceSatisfied": False,
            "lastAttempt": None,
        }
    last_attempt = state.attempts[-1] if state.attempts else None
    report_state = last_attempt.result if last_attempt is not None else "not-started"
    return {
        "schemaVersion": 1,
        "state": report_state,
        "attemptCount": len(state.attempts),
        "remainingAttemptCount": MAXIMUM_AUTOMATION_ATTEMPT_COUNT - len(state.attempts),
        "evidenceSatisfied": last_attempt.summary.evidence_satisfied if last_attempt else False,
        "lastAttempt": last_attempt.to_dict() if last_attempt else None,
    }


class AutomationStore:
    def __init__(self, session_store: SessionStateStore):
        self.session_store = session_store

    def load(self, session: CoordinatorSessionState) -> AutomationState | None:
        path = self.session_store.automation_path(session.id)
        if path.is_symlink() or path.parent.is_symlink():
            raise AutomationError("automation state path is invalid")
        if not path.is_file():
            return None
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise AutomationError("automation state is unreadable") from error
        state = AutomationState.from_dict(payload)
        validate_session_binding(state, session)
        return state

    @contextmanager
    def advance_lock(self) -> Iterator[None]:
        lock_path = self.session_store.root / ".automation.lock"
        with self.session_store.lock():
            if lock_path.is_symlink():
                raise AutomationError("automation lock path is invalid")
            flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
            descriptor = None
            try:
                descriptor = os.open(lock_path, flags, 0o600)
                os.fchmod(descriptor, 0o600)
            except OSError as error:
                if descriptor is not None:
                    os.close(descriptor)
                raise AutomationError("automation lock path is invalid") from error
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def record(self, session: CoordinatorSessionState, attempt: AutomationAttempt, now: datetime) -> AutomationState:
        with self.session_store.lock():
            current = self.session_store._load_path(
                self.session_store.path(session.target), session.target
            )
            if current is None or current.id != session.id:
                raise AutomationError("coordinator session changed during automation")
            path = self.session_store.automation_path(session.id)
            state = self.load(current) if path.is_file() else new_automation_state(current, now)
            assert state is not None
            if len(state.attempts) >= MAXIMUM_AUTOMATION_ATTEMPT_COUNT:
                raise AutomationError("automation attempt limit was reached")
            AutomationAttempt.from_dict(attempt.to_dict())
            expected_attempt_id = automation_attempt_id(
                state.coordinator_session_digest,
                kind=attempt.kind,
                started_at=attempt.started_at,
                finished_at=attempt.finished_at,
                receipt_window_digest=attempt.receipt_window_digest,
                result=attempt.result,
                reason_code=attempt.reason_code,
            )
            if attempt.id != expected_attempt_id:
                raise AutomationError("automation attempt does not match its coordinator session")
            if any(existing.id == attempt.id for existing in state.attempts):
                return state
            started_at = parse_iso8601(attempt.started_at)
            finished_at = parse_iso8601(attempt.finished_at)
            state_updated_at = parse_iso8601(state.updated_at)
            assert started_at is not None and finished_at is not None and state_updated_at is not None
            effective_now = max(normalize_utc(now), finished_at, state_updated_at)
            effective_finished_at = iso8601(effective_now)
            if effective_finished_at != attempt.finished_at:
                attempt = replace(
                    attempt,
                    id=automation_attempt_id(
                        state.coordinator_session_digest,
                        kind=attempt.kind,
                        started_at=attempt.started_at,
                        finished_at=effective_finished_at,
                        receipt_window_digest=attempt.receipt_window_digest,
                        result=attempt.result,
                        reason_code=attempt.reason_code,
                    ),
                    finished_at=effective_finished_at,
                )
            if any(existing.id == attempt.id for existing in state.attempts):
                return state
            next_state = replace(
                state,
                updated_at=effective_finished_at,
                revision=state.revision + 1,
                attempts=(*state.attempts, attempt),
            )
            AutomationState.from_dict(next_state.to_dict())
            self.session_store._atomic_write(path, next_state.to_dict())
            return next_state
