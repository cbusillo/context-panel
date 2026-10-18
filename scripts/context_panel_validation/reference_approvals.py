"""Approve captured shared-view cells that match unchanged committed reference images.

Director decision, October 18, 2026: Chris reviews only shared-view cells whose
image changed. A cell needs no review when all of these hold:

- its capture in the qualified receipt is present and its PNG has the recorded digest;
- the candidate's source commit has a reference image for the cell;
- that reference matches the previous release's reference for the cell;
- the captured PNG matches the candidate's reference.

Everything else, including a missing reference, stays in Chris's review batch.
References are read from Git at the exact source commits the comparison binds,
never from a working tree. Actual-runtime and OS-composited placement
requirements are never touched.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import partial
import hashlib
from pathlib import Path
import re
from typing import Any

from context_panel_shared_view_references import (
    Cell,
    ReferenceImageError,
    committed_reference,
    images_match,
)

from .shared_view_evidence import shared_view_requirement_id
from .visual_approvals import VisualApprovalError, VisualReviewDecision, VisualReviewRequirement

COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")


@dataclass(frozen=True)
class ReferenceOutcome:
    requirement_id: str
    approved: bool
    reason: str
    artifact_digest: str | None = None


@dataclass(frozen=True)
class ReferenceSources:
    repository: Path
    current_commit: str
    previous_commit: str


def reference_sources(
    comparison: dict[str, Any],
    current_manifest: dict[str, Any],
    previous_manifest: dict[str, Any],
    current_manifest_id: str,
    repository: Path,
) -> ReferenceSources:
    """Bind the source commits to the session's comparison through their manifests."""
    if (
        comparison.get("currentManifestId") != current_manifest_id
        or current_manifest.get("manifestId") != current_manifest_id
        or previous_manifest.get("manifestId") != comparison.get("previousManifestId")
    ):
        raise VisualApprovalError("reference sources do not match the session's comparison")
    commits = []
    for manifest in (current_manifest, previous_manifest):
        source = manifest.get("source")
        commit = source.get("commit") if isinstance(source, dict) else None
        if not isinstance(commit, str) or not COMMIT_PATTERN.fullmatch(commit):
            raise VisualApprovalError("reference source commit is invalid")
        commits.append(commit)
    return ReferenceSources(repository, commits[0], commits[1])


def _cell(requirement: VisualReviewRequirement) -> Cell | None:
    cell_id = requirement.id.rsplit(".", 1)[-1]
    if requirement.id != shared_view_requirement_id(requirement.surface, cell_id):
        return None
    return Cell(requirement.surface, cell_id)


def _file_digest(path: Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def review_against_references(
    requirements: tuple[VisualReviewRequirement, ...],
    decisions: tuple[VisualReviewDecision, ...],
    receipt: dict[str, Any],
    captures_directory: Path,
    sources: ReferenceSources,
    current_manifest_id: str,
) -> list[ReferenceOutcome]:
    if receipt.get("currentManifestID") != current_manifest_id or not isinstance(receipt.get("captures"), list):
        raise VisualApprovalError("capture receipt does not match the session")
    captures = {
        item.get("requirementID"): item for item in receipt["captures"] if isinstance(item, dict)
    }
    decided = {decision.requirement_id for decision in decisions}
    outcomes = []
    for requirement in requirements:
        if requirement.evidence_class != "shared-view":
            continue
        review = partial(ReferenceOutcome, requirement.id, False)
        if requirement.id in decided:
            outcomes.append(review("already-decided"))
            continue
        cell = _cell(requirement)
        if cell is None:
            outcomes.append(review("not-a-matrix-cell"))
            continue
        capture = captures.get(requirement.id) or {}
        image_path = captures_directory / f"{requirement.id}.png"
        digest = _file_digest(image_path)
        if capture.get("status") != "captured" or digest is None or digest != capture.get("artifactDigest"):
            outcomes.append(review("capture-unavailable"))
            continue
        try:
            current = committed_reference(sources.repository, sources.current_commit, cell)
            previous = committed_reference(sources.repository, sources.previous_commit, cell)
            if current is None:
                outcomes.append(review("missing-reference"))
            elif previous is None:
                outcomes.append(review("new-reference"))
            elif not images_match(previous, current):
                outcomes.append(review("reference-changed"))
            elif not images_match(current, image_path.read_bytes()):
                outcomes.append(review("image-changed"))
            else:
                outcomes.append(ReferenceOutcome(requirement.id, True, "matches-unchanged-reference", digest))
        except (OSError, ReferenceImageError):
            outcomes.append(review("image-unreadable"))
    return outcomes
