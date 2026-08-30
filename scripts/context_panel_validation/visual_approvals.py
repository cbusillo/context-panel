from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any
import uuid

from context_panel_comparison_schema import (
    ComparisonSchemaError,
    EVIDENCE_CLASSES,
    validate_current_comparison,
)

from .models import EXIT_BLOCKED, EXIT_OK, EXIT_UNKNOWN, Target, ValidationReport
from .runtime_evidence import (
    ExpectedSurfaceIdentity,
    RuntimeEvidenceState,
    RuntimeReceiptEvidence,
)
from .session import (
    ACTIVE_SESSION_LIFECYCLES,
    CoordinatorSessionState,
    CoordinatorSessionStateError,
    SessionStateStore,
    iso8601,
    normalize_utc,
    parse_iso8601,
    validate_target,
)


VISUAL_APPROVAL_SCHEMA_VERSION = 1
VISUAL_REVIEW_CLASSES = ("shared-view", "os-composited-placement")
VISUAL_DECISIONS = ("approved", "rejected")
MAXIMUM_REQUIREMENT_COUNT = 128
MAXIMUM_REQUIREMENTS_PER_REVIEW_BATCH = 30
MAXIMUM_DECISION_COUNT = 512
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
REQUIREMENT_ID_PATTERN = re.compile(r"^[a-z0-9]+(?:[.-][a-z0-9]+)*$")
CONTEXT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,95}$")
SURFACE_DEVICES = {
    "macos": "Mac",
    "ios": "iPhone",
    "ipados": "iPad",
    "visionos": "Vision Pro",
    "watchos": "Apple Watch",
    "tvos": "Apple TV",
}
SURFACE_NAMES = {
    "macos.app": "Mac app",
    "macos.widget": "Mac widget",
    "macos.refresh-agent": "Mac refresh agent",
    "ios.app": "iPhone app",
    "ipados.app": "iPad app",
    "ios.widget": "iPhone widget",
    "ipados.widget": "iPad widget",
    "visionos.app": "Vision Pro app",
    "visionos.widget": "Vision Pro widget",
    "watchos.app": "Watch app",
    "watchos.complication": "Watch complication",
    "tvos.app": "Apple TV app",
    "tvos.top-shelf": "Apple TV Top Shelf",
}


class VisualApprovalError(CoordinatorSessionStateError):
    pass


def _sha256(*parts: str) -> str:
    digest = hashlib.sha256()
    for part in parts:
        encoded = part.encode("utf-8")
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
    return digest.hexdigest()


def _is_sha256(value: object) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def _validated_context(value: object, label: str) -> str:
    if not isinstance(value, str) or CONTEXT_PATTERN.fullmatch(value) is None:
        raise VisualApprovalError(f"visual review {label} is invalid")
    return value


def _validated_requirement_id(value: object) -> str:
    if (
        not isinstance(value, str)
        or len(value) > 128
        or REQUIREMENT_ID_PATTERN.fullmatch(value) is None
    ):
        raise VisualApprovalError("visual review requirement identifier is invalid")
    return value


@dataclass(frozen=True)
class VisualReviewRequirement:
    id: str
    evidence_class: str
    surface: str
    device: str
    platform: str
    expected_build_id: str
    manifest_id: str
    contract_fingerprint: str
    identity_digest: str
    render_fingerprint: str
    placement_fingerprint: str | None
    fixture_contract_id: str | None
    presentation: str | None
    appearance: str
    accessibility: str
    host_os: str | None
    presentation_family: str | None
    placement_host: str | None

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "evidenceClass": self.evidence_class,
            "surface": self.surface,
            "device": self.device,
            "platform": self.platform,
            "expectedBuildID": self.expected_build_id,
            "manifestID": self.manifest_id,
            "contractFingerprint": self.contract_fingerprint,
            "identityDigest": self.identity_digest,
            "renderFingerprint": self.render_fingerprint,
            "placementFingerprint": self.placement_fingerprint,
            "fixtureContractID": self.fixture_contract_id,
            "presentation": self.presentation,
            "appearance": self.appearance,
            "accessibility": self.accessibility,
            "hostOS": self.host_os,
            "presentationFamily": self.presentation_family,
            "placementHost": self.placement_host,
        }

    @classmethod
    def from_dict(cls, payload: object) -> VisualReviewRequirement:
        expected_keys = {
            "id",
            "evidenceClass",
            "surface",
            "device",
            "platform",
            "expectedBuildID",
            "manifestID",
            "contractFingerprint",
            "identityDigest",
            "renderFingerprint",
            "placementFingerprint",
            "fixtureContractID",
            "presentation",
            "appearance",
            "accessibility",
            "hostOS",
            "presentationFamily",
            "placementHost",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise VisualApprovalError("visual review requirement is invalid")
        requirement = cls(
            id=_validated_requirement_id(payload.get("id")),
            evidence_class=payload.get("evidenceClass"),
            surface=payload.get("surface"),
            device=payload.get("device"),
            platform=payload.get("platform"),
            expected_build_id=payload.get("expectedBuildID"),
            manifest_id=payload.get("manifestID"),
            contract_fingerprint=payload.get("contractFingerprint"),
            identity_digest=payload.get("identityDigest"),
            render_fingerprint=payload.get("renderFingerprint"),
            placement_fingerprint=payload.get("placementFingerprint"),
            fixture_contract_id=payload.get("fixtureContractID"),
            presentation=payload.get("presentation"),
            appearance=payload.get("appearance"),
            accessibility=payload.get("accessibility"),
            host_os=payload.get("hostOS"),
            presentation_family=payload.get("presentationFamily"),
            placement_host=payload.get("placementHost"),
        )
        validate_visual_requirement(requirement)
        return requirement


def validate_visual_requirement(requirement: VisualReviewRequirement) -> None:
    prefix = requirement.surface.split(".", 1)[0] if isinstance(requirement.surface, str) else ""
    if (
        requirement.evidence_class not in VISUAL_REVIEW_CLASSES
        or requirement.surface not in SURFACE_NAMES
        or requirement.device != SURFACE_DEVICES.get(prefix)
        or not isinstance(requirement.platform, str)
        or not requirement.platform
        or any(
            not _is_sha256(value)
            for value in (
                requirement.expected_build_id,
                requirement.manifest_id,
                requirement.contract_fingerprint,
                requirement.identity_digest,
                requirement.render_fingerprint,
            )
        )
    ):
        raise VisualApprovalError("visual review requirement is invalid")
    _validated_context(requirement.appearance, "appearance")
    _validated_context(requirement.accessibility, "accessibility")
    if requirement.evidence_class == "shared-view":
        if (
            not _is_sha256(requirement.fixture_contract_id)
            or requirement.presentation is None
            or requirement.placement_fingerprint is not None
            or requirement.host_os is not None
            or requirement.presentation_family is not None
            or requirement.placement_host is not None
        ):
            raise VisualApprovalError("shared-view requirement is invalid")
        _validated_context(requirement.presentation, "presentation")
        return
    if (
        not _is_sha256(requirement.placement_fingerprint)
        or requirement.fixture_contract_id is not None
        or requirement.presentation is not None
        or requirement.host_os is None
        or requirement.presentation_family is None
        or requirement.placement_host is None
    ):
        raise VisualApprovalError("placement requirement is invalid")
    _validated_context(requirement.host_os, "host OS")
    _validated_context(requirement.presentation_family, "presentation family")
    _validated_context(requirement.placement_host, "placement host")


@dataclass(frozen=True)
class VisualReviewDecision:
    id: str
    sequence: int
    requirement_id: str
    decision: str
    observed_at: str
    artifact_digest: str | None
    host_os: str | None
    runtime_receipt_id: str | None
    runtime_observed_at: str | None
    supersedes_decision_id: str | None

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "sequence": self.sequence,
            "requirementID": self.requirement_id,
            "decision": self.decision,
            "observedAt": self.observed_at,
            "artifactDigest": self.artifact_digest,
            "hostOS": self.host_os,
            "runtimeReceiptID": self.runtime_receipt_id,
            "runtimeObservedAt": self.runtime_observed_at,
            "supersedesDecisionID": self.supersedes_decision_id,
        }

    @classmethod
    def from_dict(cls, payload: object) -> VisualReviewDecision:
        expected_keys = {
            "id",
            "sequence",
            "requirementID",
            "decision",
            "observedAt",
            "artifactDigest",
            "hostOS",
            "runtimeReceiptID",
            "runtimeObservedAt",
            "supersedesDecisionID",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise VisualApprovalError("visual review decision is invalid")
        decision = cls(
            id=payload.get("id"),
            sequence=payload.get("sequence"),
            requirement_id=_validated_requirement_id(payload.get("requirementID")),
            decision=payload.get("decision"),
            observed_at=payload.get("observedAt"),
            artifact_digest=payload.get("artifactDigest"),
            host_os=payload.get("hostOS"),
            runtime_receipt_id=payload.get("runtimeReceiptID"),
            runtime_observed_at=payload.get("runtimeObservedAt"),
            supersedes_decision_id=payload.get("supersedesDecisionID"),
        )
        if (
            not _is_sha256(decision.id)
            or not isinstance(decision.sequence, int)
            or isinstance(decision.sequence, bool)
            or decision.sequence < 1
            or decision.decision not in VISUAL_DECISIONS
            or parse_iso8601(decision.observed_at) is None
            or (decision.artifact_digest is not None and not _is_sha256(decision.artifact_digest))
            or (decision.runtime_receipt_id is not None and not _is_sha256(decision.runtime_receipt_id))
            or (
                decision.runtime_observed_at is not None
                and parse_iso8601(decision.runtime_observed_at) is None
            )
            or (
                decision.supersedes_decision_id is not None
                and not _is_sha256(decision.supersedes_decision_id)
            )
        ):
            raise VisualApprovalError("visual review decision is invalid")
        if decision.host_os is not None:
            _validated_context(decision.host_os, "host OS")
        return decision


@dataclass(frozen=True)
class VisualApprovalState:
    schema_version: int
    coordinator_session_id: str
    target: Target
    plan_id: str
    current_manifest_id: str
    created_at: str
    updated_at: str
    revision: int
    requirements: tuple[VisualReviewRequirement, ...]
    decisions: tuple[VisualReviewDecision, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "schemaVersion": self.schema_version,
            "coordinatorSessionID": self.coordinator_session_id,
            "target": {
                "version": self.target.version,
                "buildNumber": self.target.build_number,
            },
            "planID": self.plan_id,
            "currentManifestID": self.current_manifest_id,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
            "revision": self.revision,
            "requirements": [item.to_dict() for item in self.requirements],
            "decisions": [item.to_dict() for item in self.decisions],
        }

    @classmethod
    def from_dict(cls, payload: object) -> VisualApprovalState:
        expected_keys = {
            "schemaVersion",
            "coordinatorSessionID",
            "target",
            "planID",
            "currentManifestID",
            "createdAt",
            "updatedAt",
            "revision",
            "requirements",
            "decisions",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise VisualApprovalError("visual approval state is invalid")
        target_payload = payload.get("target")
        requirements = payload.get("requirements")
        decisions = payload.get("decisions")
        if (
            not isinstance(target_payload, dict)
            or set(target_payload) != {"version", "buildNumber"}
            or not isinstance(requirements, list)
            or not isinstance(decisions, list)
        ):
            raise VisualApprovalError("visual approval state is invalid")
        state = cls(
            schema_version=payload.get("schemaVersion"),
            coordinator_session_id=payload.get("coordinatorSessionID"),
            target=Target(target_payload.get("version"), target_payload.get("buildNumber")),
            plan_id=payload.get("planID"),
            current_manifest_id=payload.get("currentManifestID"),
            created_at=payload.get("createdAt"),
            updated_at=payload.get("updatedAt"),
            revision=payload.get("revision"),
            requirements=tuple(VisualReviewRequirement.from_dict(item) for item in requirements),
            decisions=tuple(VisualReviewDecision.from_dict(item) for item in decisions),
        )
        validate_visual_approval_state(state)
        return state

    def public_dict(self, runtime_state: RuntimeEvidenceState | None) -> dict[str, Any]:
        return build_visual_approval_report(self, runtime_state)


def validate_visual_approval_state(state: VisualApprovalState) -> None:
    validate_target(state.target)
    created = parse_iso8601(state.created_at)
    updated = parse_iso8601(state.updated_at)
    requirement_ids = tuple(item.id for item in state.requirements)
    decision_ids = tuple(item.id for item in state.decisions)
    try:
        normalized_session_id = str(uuid.UUID(state.coordinator_session_id)).upper()
    except (AttributeError, TypeError, ValueError) as error:
        raise VisualApprovalError("visual approval state is invalid") from error
    if (
        state.schema_version != VISUAL_APPROVAL_SCHEMA_VERSION
        or normalized_session_id != state.coordinator_session_id
        or not _is_sha256(state.plan_id)
        or state.plan_id != _plan_id(state.current_manifest_id, state.requirements)
        or not _is_sha256(state.current_manifest_id)
        or created is None
        or updated is None
        or created > updated
        or not isinstance(state.revision, int)
        or isinstance(state.revision, bool)
        or state.revision < 1
        or len(state.requirements) > MAXIMUM_REQUIREMENT_COUNT
        or requirement_ids != tuple(sorted(set(requirement_ids)))
        or any(item.manifest_id != state.current_manifest_id for item in state.requirements)
        or len(state.decisions) > MAXIMUM_DECISION_COUNT
        or tuple(item.sequence for item in state.decisions) != tuple(range(1, len(state.decisions) + 1))
        or len(set(decision_ids)) != len(decision_ids)
        or any(item.requirement_id not in requirement_ids for item in state.decisions)
    ):
        raise VisualApprovalError("visual approval state is invalid")
    decision_times = [parse_iso8601(item.observed_at) for item in state.decisions]
    if (
        any(item is None for item in decision_times)
        or decision_times != sorted(decision_times)
        or (decision_times and decision_times[-1] != updated)
        or (not decision_times and updated != created)
    ):
        raise VisualApprovalError("visual approval decision ordering is invalid")
    requirements_by_id = {item.id: item for item in state.requirements}
    previous_by_requirement: dict[str, str] = {}
    for decision in state.decisions:
        requirement = requirements_by_id[decision.requirement_id]
        if requirement.evidence_class == "shared-view":
            if any(
                value is not None
                for value in (
                    decision.host_os,
                    decision.runtime_receipt_id,
                    decision.runtime_observed_at,
                )
            ):
                raise VisualApprovalError("shared-view decision is invalid")
        elif (
            decision.host_os != requirement.host_os
            or decision.runtime_receipt_id is None
            or decision.runtime_observed_at is None
        ):
            raise VisualApprovalError("placement decision is invalid")
        expected_supersedes = previous_by_requirement.get(decision.requirement_id)
        expected_id = _sha256(
            "context-panel-visual-review-decision-v1",
            state.plan_id,
            decision.requirement_id,
            str(decision.sequence),
            decision.decision,
            decision.observed_at,
            decision.artifact_digest or "",
            decision.host_os or "",
            decision.runtime_receipt_id or "",
            expected_supersedes or "",
        )
        if (
            decision.supersedes_decision_id != expected_supersedes
            or decision.id != expected_id
        ):
            raise VisualApprovalError("visual approval decision ordering is invalid")
        previous_by_requirement[decision.requirement_id] = decision.id


def _load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.expanduser().read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise VisualApprovalError(f"{label} is unavailable or invalid") from error
    if not isinstance(payload, dict):
        raise VisualApprovalError(f"{label} is invalid")
    return payload


def load_visual_review_plan(
    comparison_path: Path,
    requirements_path: Path,
    identities: tuple[ExpectedSurfaceIdentity, ...],
) -> tuple[tuple[str, ...], tuple[VisualReviewRequirement, ...], str]:
    comparison = _load_json_object(comparison_path, "surface comparison")
    try:
        validate_current_comparison(comparison)
    except ComparisonSchemaError as error:
        raise VisualApprovalError("surface comparison is invalid") from error
    current_manifest_id = comparison.get("currentManifestId")
    required_surfaces = comparison.get("requiredSurfaces")
    if not _is_sha256(current_manifest_id) or not isinstance(required_surfaces, dict):
        raise VisualApprovalError("surface comparison is invalid")
    identity_by_surface = {item.surface: item for item in identities}
    if not identity_by_surface or any(item.manifest_id != current_manifest_id for item in identities):
        raise VisualApprovalError("visual review build identity does not match the surface comparison")
    allowed_surfaces = set(identity_by_surface)
    full_required_by_class = {
        evidence_class: tuple(required_surfaces[evidence_class])
        for evidence_class in EVIDENCE_CLASSES
    }
    if any(
        surface not in allowed_surfaces
        for surfaces in full_required_by_class.values()
        for surface in surfaces
    ):
        raise VisualApprovalError("surface comparison requires an unknown build surface")
    comparison_surfaces = comparison.get("surfaces")
    fresh_by_class = {evidence_class: [] for evidence_class in VISUAL_REVIEW_CLASSES}
    for surface in comparison_surfaces:
        surface_id = surface["surfaceId"]
        if surface_id not in SURFACE_NAMES:
            raise VisualApprovalError("surface comparison is invalid")
        for evidence_class in surface["freshEvidence"]:
            if surface_id not in full_required_by_class[evidence_class]:
                raise VisualApprovalError("surface comparison fresh evidence is inconsistent")
            if evidence_class in VISUAL_REVIEW_CLASSES:
                fresh_by_class[evidence_class].append(surface_id)
    required_by_class = {
        "actual-runtime": full_required_by_class["actual-runtime"],
        "shared-view": tuple(fresh_by_class["shared-view"]),
        "os-composited-placement": tuple(fresh_by_class["os-composited-placement"]),
    }
    if bool(full_required_by_class["actual-runtime"]) != comparison.get("requiresRuntimeSession"):
        raise VisualApprovalError("surface comparison runtime requirement is inconsistent")
    if bool(full_required_by_class["os-composited-placement"]) != comparison.get(
        "requiresPlacementReview"
    ):
        raise VisualApprovalError("surface comparison placement requirement is inconsistent")
    if any(
        surface not in full_required_by_class["actual-runtime"]
        for surface in full_required_by_class["os-composited-placement"]
    ):
        raise VisualApprovalError("placement review requires matching actual-runtime evidence")

    payload = _load_json_object(requirements_path, "visual review requirements")
    if set(payload) != {"schemaVersion", "kind", "currentManifestID", "requirements"}:
        raise VisualApprovalError("visual review requirements are invalid")
    raw_requirements = payload.get("requirements")
    if (
        payload.get("schemaVersion") != 1
        or payload.get("kind") != "context-panel-visual-review-requirements"
        or payload.get("currentManifestID") != current_manifest_id
        or not isinstance(raw_requirements, list)
        or len(raw_requirements) > MAXIMUM_REQUIREMENT_COUNT
    ):
        raise VisualApprovalError("visual review requirements are invalid")
    normalized: list[VisualReviewRequirement] = []
    for raw in raw_requirements:
        if not isinstance(raw, dict) or set(raw) != {
            "id",
            "evidenceClass",
            "surface",
            "fixtureContractID",
            "presentation",
            "appearance",
            "accessibility",
            "hostOS",
            "presentationFamily",
            "placementHost",
        }:
            raise VisualApprovalError("visual review requirement is invalid")
        evidence_class = raw.get("evidenceClass")
        surface = raw.get("surface")
        if (
            evidence_class not in VISUAL_REVIEW_CLASSES
            or surface not in full_required_by_class[evidence_class]
        ):
            raise VisualApprovalError("visual review requirement is outside the required comparison scope")
        identity = identity_by_surface[str(surface)]
        prefix = identity.surface.split(".", 1)[0]
        requirement = VisualReviewRequirement(
            id=_validated_requirement_id(raw.get("id")),
            evidence_class=str(evidence_class),
            surface=identity.surface,
            device=SURFACE_DEVICES[prefix],
            platform=identity.platform,
            expected_build_id=identity.expected_build_id,
            manifest_id=identity.manifest_id,
            contract_fingerprint=identity.contract_fingerprint,
            identity_digest=identity.identity_digest(),
            render_fingerprint=identity.render_fingerprint,
            placement_fingerprint=(
                identity.placement_fingerprint
                if evidence_class == "os-composited-placement"
                else None
            ),
            fixture_contract_id=raw.get("fixtureContractID"),
            presentation=raw.get("presentation"),
            appearance=raw.get("appearance"),
            accessibility=raw.get("accessibility"),
            host_os=raw.get("hostOS"),
            presentation_family=raw.get("presentationFamily"),
            placement_host=raw.get("placementHost"),
        )
        validate_visual_requirement(requirement)
        normalized.append(requirement)
    normalized.sort(key=lambda item: item.id)
    if len({item.id for item in normalized}) != len(normalized):
        raise VisualApprovalError("visual review requirement identifier is duplicated")
    for evidence_class in VISUAL_REVIEW_CLASSES:
        covered = {item.surface for item in normalized if item.evidence_class == evidence_class}
        if not set(required_by_class[evidence_class]).issubset(covered):
            raise VisualApprovalError("visual review requirements do not cover fresh evidence")
    return required_by_class["actual-runtime"], tuple(normalized), str(current_manifest_id)


def _plan_id(current_manifest_id: str, requirements: tuple[VisualReviewRequirement, ...]) -> str:
    return _sha256(
        "context-panel-visual-review-plan-v1",
        current_manifest_id,
        json.dumps([item.to_dict() for item in requirements], sort_keys=True, separators=(",", ":")),
    )


def _latest_receipt(
    runtime_state: RuntimeEvidenceState | None,
    requirement: VisualReviewRequirement,
) -> RuntimeReceiptEvidence | None:
    if runtime_state is None:
        return None
    observation = runtime_state.last_observation
    if observation is not None and (
        observation.result != "healthy"
        or observation.diagnostics
        or dict(observation.surface_diagnostics).get(requirement.surface) is not None
    ):
        return None
    expected = next(
        (item for item in runtime_state.expected_surfaces if item.surface == requirement.surface),
        None,
    )
    if (
        expected is None
        or expected.identity_digest() != requirement.identity_digest
        or expected.expected_build_id != requirement.expected_build_id
        or expected.render_fingerprint != requirement.render_fingerprint
        or expected.placement_fingerprint != requirement.placement_fingerprint
    ):
        return None
    receipts = [item for item in runtime_state.receipts if item.surface == requirement.surface]
    return receipts[-1] if receipts else None


class VisualApprovalStore:
    def __init__(self, session_store: SessionStateStore):
        self.session_store = session_store

    def load(self, session: CoordinatorSessionState) -> VisualApprovalState | None:
        path = self.session_store.visual_approval_path(session.id)
        if path.is_symlink() or path.parent.is_symlink():
            raise VisualApprovalError("visual approval path is invalid")
        if not path.is_file():
            return None
        state = self._load_path(path)
        self._validate_session_binding(state, session)
        return state

    def configure(
        self,
        session: CoordinatorSessionState,
        current_manifest_id: str,
        requirements: tuple[VisualReviewRequirement, ...],
        now: datetime,
    ) -> VisualApprovalState:
        if session.lifecycle not in ACTIVE_SESSION_LIFECYCLES:
            raise VisualApprovalError("visual review requirements cannot change for a closed session")
        plan_id = _plan_id(current_manifest_id, requirements)
        with self.session_store.lock():
            current_session = self.session_store._load_path(
                self.session_store.path(session.target),
                session.target,
            )
            if current_session is None or current_session.id != session.id:
                raise VisualApprovalError("coordinator session changed during visual review setup")
            path = self.session_store.visual_approval_path(session.id)
            if path.is_file():
                state = self._load_path(path)
                self._validate_session_binding(state, current_session)
                if state.plan_id != plan_id:
                    raise VisualApprovalError("visual review requirements conflict with the active session")
                return state
            timestamp = iso8601(normalize_utc(now))
            state = VisualApprovalState(
                schema_version=VISUAL_APPROVAL_SCHEMA_VERSION,
                coordinator_session_id=session.id,
                target=session.target,
                plan_id=plan_id,
                current_manifest_id=current_manifest_id,
                created_at=timestamp,
                updated_at=timestamp,
                revision=1,
                requirements=requirements,
                decisions=(),
            )
            validate_visual_approval_state(state)
            self._write_path(path, state)
            return state

    def record(
        self,
        session: CoordinatorSessionState,
        requirement_id: str,
        decision_value: str,
        now: datetime,
        runtime_state: RuntimeEvidenceState | None,
        artifact_digest: str | None = None,
        host_os: str | None = None,
    ) -> tuple[VisualApprovalState, VisualReviewDecision]:
        requirement_id = _validated_requirement_id(requirement_id)
        if decision_value not in VISUAL_DECISIONS:
            raise VisualApprovalError("visual review decision is invalid")
        if artifact_digest is not None and not _is_sha256(artifact_digest):
            raise VisualApprovalError("private artifact digest is invalid")
        with self.session_store.lock():
            current_session = self.session_store._load_path(
                self.session_store.path(session.target),
                session.target,
            )
            if current_session is None or current_session.id != session.id:
                raise VisualApprovalError("coordinator session changed before visual review recording")
            if current_session.lifecycle != "active":
                raise VisualApprovalError("visual review can be recorded only while the session is active")
            path = self.session_store.visual_approval_path(session.id)
            if not path.is_file():
                raise VisualApprovalError("visual review requirements are not configured")
            state = self._load_path(path)
            self._validate_session_binding(state, current_session)
            requirement = next(
                (item for item in state.requirements if item.id == requirement_id),
                None,
            )
            if requirement is None:
                raise VisualApprovalError("visual review requirement is not part of the active session")
            runtime_receipt = None
            if requirement.evidence_class == "os-composited-placement":
                if host_os != requirement.host_os:
                    raise VisualApprovalError("placement review host OS does not match the requirement")
                runtime_receipt = _latest_receipt(runtime_state, requirement)
                if runtime_receipt is None:
                    raise VisualApprovalError("placement review requires matching current runtime evidence")
            elif host_os is not None:
                raise VisualApprovalError("shared-view review does not accept a host OS")
            prior = next(
                (
                    item
                    for item in reversed(state.decisions)
                    if item.requirement_id == requirement_id
                ),
                None,
            )
            runtime_receipt_id = runtime_receipt.receipt_id if runtime_receipt else None
            runtime_observed_at = runtime_receipt.observed_at if runtime_receipt else None
            if prior is not None and (
                prior.decision == decision_value
                and prior.artifact_digest == artifact_digest
                and prior.host_os == host_os
                and prior.runtime_receipt_id == runtime_receipt_id
            ):
                return state, prior
            if len(state.decisions) >= MAXIMUM_DECISION_COUNT:
                raise VisualApprovalError("visual review decision history is full")
            observed_at = iso8601(max(normalize_utc(now), parse_iso8601(state.updated_at)))
            sequence = len(state.decisions) + 1
            decision_id = _sha256(
                "context-panel-visual-review-decision-v1",
                state.plan_id,
                requirement_id,
                str(sequence),
                decision_value,
                observed_at,
                artifact_digest or "",
                host_os or "",
                runtime_receipt_id or "",
                prior.id if prior else "",
            )
            decision = VisualReviewDecision(
                id=decision_id,
                sequence=sequence,
                requirement_id=requirement_id,
                decision=decision_value,
                observed_at=observed_at,
                artifact_digest=artifact_digest,
                host_os=host_os,
                runtime_receipt_id=runtime_receipt_id,
                runtime_observed_at=runtime_observed_at,
                supersedes_decision_id=prior.id if prior else None,
            )
            VisualReviewDecision.from_dict(decision.to_dict())
            next_state = replace(
                state,
                updated_at=observed_at,
                revision=state.revision + 1,
                decisions=(*state.decisions, decision),
            )
            validate_visual_approval_state(next_state)
            self._write_path(path, next_state)
            return next_state, decision

    @staticmethod
    def _validate_session_binding(
        state: VisualApprovalState,
        session: CoordinatorSessionState,
    ) -> None:
        if state.coordinator_session_id != session.id or state.target != session.target:
            raise VisualApprovalError("visual approvals do not match the coordinator session")

    @staticmethod
    def _load_path(path: Path) -> VisualApprovalState:
        if path.is_symlink() or path.parent.is_symlink():
            raise VisualApprovalError("visual approval path is invalid")
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise VisualApprovalError("visual approval state is unreadable") from error
        return VisualApprovalState.from_dict(payload)

    @staticmethod
    def _write_path(path: Path, state: VisualApprovalState) -> None:
        validate_visual_approval_state(state)
        if path.is_symlink() or path.parent.is_symlink():
            raise VisualApprovalError("visual approval path is invalid")
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


def _requirement_instruction(requirement: VisualReviewRequirement) -> str:
    surface_name = SURFACE_NAMES[requirement.surface]
    if requirement.evidence_class == "shared-view":
        return (
            f"Review the {surface_name} shared view for {requirement.presentation}, "
            f"{requirement.appearance}, {requirement.accessibility}."
        )
    if requirement.surface == "watchos.complication":
        return (
            f"Glance at the placed Watch complication ({requirement.presentation_family}) "
            f"on {requirement.placement_host} using {requirement.host_os}."
        )
    if requirement.surface == "tvos.top-shelf":
        return (
            f"Review the TVServices-composited Top Shelf ({requirement.presentation_family}) "
            f"on {requirement.placement_host} using {requirement.host_os}."
        )
    return (
        f"Review the placed {surface_name} ({requirement.presentation_family}) "
        f"in {requirement.placement_host} using {requirement.host_os}."
    )


def _device_key(device: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", device.casefold()).strip("-")


def build_visual_approval_report(
    state: VisualApprovalState,
    runtime_state: RuntimeEvidenceState | None,
) -> dict[str, Any]:
    latest_decisions: dict[str, VisualReviewDecision] = {}
    for decision in state.decisions:
        latest_decisions[decision.requirement_id] = decision
    runtime_receipt_ids = {
        item.receipt_id for item in runtime_state.receipts
    } if runtime_state is not None else set()
    requirements: list[dict[str, Any]] = []
    for requirement in state.requirements:
        latest = latest_decisions.get(requirement.id)
        machine_ready = True
        reason = "ready-for-human-review"
        if requirement.evidence_class == "os-composited-placement":
            machine_ready = _latest_receipt(runtime_state, requirement) is not None
            reason = (
                "matching-runtime-evidence-ready"
                if machine_ready
                else "matching-runtime-evidence-pending"
            )
        active_decision = latest
        if (
            latest is not None
            and requirement.evidence_class == "os-composited-placement"
            and (
                not machine_ready
                or latest.runtime_receipt_id not in runtime_receipt_ids
            )
        ):
            active_decision = None
            machine_ready = False
            reason = "approved-runtime-evidence-is-no-longer-current"
        if active_decision is not None:
            requirement_state = active_decision.decision
            reason = f"review-{active_decision.decision}"
        else:
            requirement_state = "ready" if machine_ready else "waiting"
        requirements.append(
            {
                "id": requirement.id,
                "evidenceClass": requirement.evidence_class,
                "surface": requirement.surface,
                "device": requirement.device,
                "platform": requirement.platform,
                "manifestID": requirement.manifest_id,
                "expectedBuildID": requirement.expected_build_id,
                "contractFingerprint": requirement.contract_fingerprint,
                "identityDigest": requirement.identity_digest,
                "state": requirement_state,
                "reason": reason,
                "instruction": _requirement_instruction(requirement),
                "appearance": requirement.appearance,
                "accessibility": requirement.accessibility,
                "presentation": requirement.presentation,
                "presentationFamily": requirement.presentation_family,
                "placementHost": requirement.placement_host,
                "hostOS": requirement.host_os,
                "renderFingerprint": requirement.render_fingerprint,
                "placementFingerprint": requirement.placement_fingerprint,
                "fixtureContractID": requirement.fixture_contract_id,
                "decision": (
                    {
                        "id": active_decision.id,
                        "sequence": active_decision.sequence,
                        "value": active_decision.decision,
                        "observedAt": active_decision.observed_at,
                        "artifactDigest": active_decision.artifact_digest,
                        "runtimeReceiptID": active_decision.runtime_receipt_id,
                        "supersedesDecisionID": active_decision.supersedes_decision_id,
                    }
                    if active_decision is not None
                    else None
                ),
            }
        )
    waiting_devices = {
        item["device"] for item in requirements if item["state"] == "waiting"
    }
    ready_by_device: dict[str, list[dict[str, Any]]] = {}
    for item in requirements:
        if item["state"] == "ready" and item["device"] not in waiting_devices:
            ready_by_device.setdefault(str(item["device"]), []).append(item)
    review_batches = []
    for device in sorted(ready_by_device):
        items = ready_by_device[device]
        chunks = [
            items[index : index + MAXIMUM_REQUIREMENTS_PER_REVIEW_BATCH]
            for index in range(0, len(items), MAXIMUM_REQUIREMENTS_PER_REVIEW_BATCH)
        ]
        for index, chunk in enumerate(chunks, start=1):
            shared_count = sum(item["evidenceClass"] == "shared-view" for item in chunk)
            placement_count = sum(
                item["evidenceClass"] == "os-composited-placement" for item in chunk
            )
            parts = []
            if shared_count:
                parts.append(
                    f"{shared_count} shared-view check{'s' if shared_count != 1 else ''}"
                )
            if placement_count:
                parts.append(
                    f"{placement_count} placement glance{'s' if placement_count != 1 else ''}"
                )
            action_id = f"review.{_device_key(device)}"
            if len(chunks) > 1:
                action_id = f"{action_id}.part-{index}"
            review_batches.append(
                {
                    "actionID": action_id,
                    "device": device,
                    "requirementIDs": [item["id"] for item in chunk],
                    "surfaces": sorted({str(item["surface"]) for item in chunk}),
                    "requiresRuntime": bool(placement_count),
                    "instruction": (
                        f"Review {', '.join(parts)} on {device}, then record each decision by requirement ID."
                    ),
                    "estimateMinutes": max(2, len(chunk) * 2),
                }
            )
    states = {str(item["state"]) for item in requirements}
    if not requirements:
        overall_state = "not-required"
    elif "rejected" in states:
        overall_state = "rejected"
    elif states == {"approved"}:
        overall_state = "approved"
    elif review_batches:
        overall_state = "pending"
    elif "waiting" in states:
        overall_state = "waiting"
    else:
        overall_state = "unknown"
    return {
        "schemaVersion": 1,
        "state": overall_state,
        "planID": state.plan_id,
        "currentManifestID": state.current_manifest_id,
        "revision": state.revision,
        "requirementCount": len(requirements),
        "approvedCount": sum(item["state"] == "approved" for item in requirements),
        "rejectedCount": sum(item["state"] == "rejected" for item in requirements),
        "readyReviewCount": sum(item["state"] == "ready" for item in requirements),
        "machineWaitingCount": sum(item["state"] == "waiting" for item in requirements),
        "reviewBatches": review_batches,
        "requirements": requirements,
    }


def apply_visual_approvals_to_report(
    report: ValidationReport,
    visual_approvals: dict[str, Any] | None,
) -> ValidationReport:
    if visual_approvals is None:
        return report
    state = report.state
    stage = report.stage
    exit_code = report.exit_code
    actions = report.actions
    closing = report.headline.rsplit(" · ", 1)[-1]
    approval_state = visual_approvals["state"]
    if approval_state == "rejected":
        state, stage, exit_code = "blocked", "visual review rejected", EXIT_BLOCKED
        actions = ()
        closing = "blocked: visual review rejected"
    elif approval_state == "waiting" and report.state not in {"blocked", "unknown", "waiting"}:
        state, stage, exit_code = "waiting", "waiting on review prerequisites", EXIT_OK
        closing = "nothing needs you right now"
    elif approval_state == "unknown" and report.state not in {"blocked", "unknown"}:
        state, stage, exit_code = "unknown", "visual review diagnostic", EXIT_UNKNOWN
        actions = ()
        closing = "not enough evidence: visual review diagnostics required"
    limitations = report.limitations
    if approval_state == "approved":
        limitations = tuple(
            item
            for item in limitations
            if item != "Visual approval is not proven by this slice."
        )
    prefix = report.headline.rsplit(" · ", 1)[0]
    return replace(
        report,
        state=state,
        stage=stage,
        exit_code=exit_code,
        headline=f"{prefix} · {closing}",
        actions=actions,
        limitations=limitations,
        visual_approvals=visual_approvals,
    )
