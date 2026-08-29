from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any

from context_panel_comparison_schema import ComparisonSchemaError, validate_current_comparison

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MATRIX_PATH = REPO_ROOT / "Config" / "ContextPanelSharedViewMatrix.json"
DEFAULT_SURFACE_POLICY_PATH = REPO_ROOT / "Config" / "ContextPanelSurfacePolicy.json"

MATRIX_SCHEMA_VERSION = 1
MATRIX_KIND = "context-panel-shared-view-matrix"
FIXTURE_CONTRACT_DOMAIN = "context-panel-shared-view-fixture-contract/v1"
PIXEL_DIFF_POLICY = "advisory-only"
CANONICAL_CELL_ORDER = ("baseline", "stress")
FIXTURE_IDS = (
    "healthy",
    "reset-visible",
    "cache-visible",
    "stale",
    "loading",
    "missing",
    "failed",
    "dense-accounts",
    "fit-fallback",
)
GALLERY_FAMILIES = ("systemSmall", "systemMedium", "systemLarge")
GALLERY_APPEARANCES = ("adaptive", "light", "dark")
GALLERY_PRESENTATIONS = (
    "overview",
    "detail",
    "reconnect",
    "diagnostics",
    "settings",
    "widget",
)
MAC_GALLERY_PRESENTATIONS = ("overview", "detail", "reconnect", "diagnostics", "widget")
COMPANION_GALLERY_PRESENTATIONS = ("overview", "settings", "diagnostics", "widget")
NO_SELECTOR = "not-applicable"
URL_GALLERY_SURFACES = (
    "macos.app",
    "macos.widget",
    "ios.app",
    "ipados.app",
    "ios.widget",
    "ipados.widget",
    "visionos.app",
    "visionos.widget",
)
WATCH_APP_FIXTURE_IDS = (
    "healthy",
    "missing",
    "stale",
    "loading",
    "failed",
    "dense-accounts",
    "fit-fallback",
)
WATCH_COMPLICATION_FIXTURE_IDS = ("healthy", "reset-visible", "missing")
WATCH_COMPLICATION_FAMILIES = ("circular", "rectangular", "inline", "corner")
TV_FIXTURE_IDS = (
    "healthy",
    "reset-visible",
    "stale",
    "loading",
    "missing",
    "failed",
    "dense-accounts",
    "fit-fallback",
)
TV_GALLERY_SURFACES = ("runway", "provider", "topShelf")
TV_PRESENTATIONS = ("fullDetail", "projectOnly", "countsOnly")
ACCESSIBILITY_CONTEXTS = ("default",)
VISUAL_MAXIMUM_REQUIREMENT_COUNT = 128

_CELL_ID_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
_JUSTIFICATION_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 .,'()/+-]{0,159}$")


class SharedViewEvidenceError(ValueError):
    pass


def canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def canonical_json_hash(domain: str, value: object) -> str:
    encoded_domain = domain.encode("utf-8")
    return hashlib.sha256(
        len(encoded_domain).to_bytes(8, "big")
        + encoded_domain
        + canonical_json(value).encode("utf-8")
    ).hexdigest()


def _load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.expanduser().read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SharedViewEvidenceError(f"{label} is unavailable or invalid") from error
    if not isinstance(payload, dict):
        raise SharedViewEvidenceError(f"{label} is invalid")
    return payload


def _require_string(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise SharedViewEvidenceError(f"{label} is invalid")
    return value


def _require_string_list(value: object, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise SharedViewEvidenceError(f"{label} is invalid")
    values = tuple(value)
    if len(values) != len(set(values)):
        raise SharedViewEvidenceError(f"{label} contains duplicates")
    return values


@dataclass(frozen=True)
class SharedViewCell:
    id: str
    fixture_id: str
    family: str
    appearance: str
    presentation: str
    accessibility: str
    justification: str

    @classmethod
    def from_dict(cls, payload: object) -> SharedViewCell:
        expected_keys = {
            "id",
            "fixtureID",
            "family",
            "appearance",
            "presentation",
            "accessibility",
            "justification",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise SharedViewEvidenceError("shared-view matrix cell is invalid")
        cell = cls(
            id=_require_string(payload["id"], "shared-view matrix cell identifier"),
            fixture_id=_require_string(payload["fixtureID"], "shared-view matrix fixture"),
            family=_require_string(payload["family"], "shared-view matrix family"),
            appearance=_require_string(payload["appearance"], "shared-view matrix appearance"),
            presentation=_require_string(
                payload["presentation"], "shared-view matrix presentation"
            ),
            accessibility=_require_string(
                payload["accessibility"], "shared-view matrix accessibility"
            ),
            justification=_require_string(
                payload["justification"], "shared-view matrix justification"
            ),
        )
        if _CELL_ID_PATTERN.fullmatch(cell.id) is None:
            raise SharedViewEvidenceError("shared-view matrix cell identifier is invalid")
        if cell.fixture_id not in FIXTURE_IDS:
            raise SharedViewEvidenceError("shared-view matrix fixture is not allowlisted")
        if cell.accessibility not in ACCESSIBILITY_CONTEXTS:
            raise SharedViewEvidenceError("shared-view matrix accessibility is not allowlisted")
        if _JUSTIFICATION_PATTERN.fullmatch(cell.justification) is None:
            raise SharedViewEvidenceError("shared-view matrix justification is invalid")
        return cell

    def to_contract_dict(self) -> dict[str, str]:
        return {
            "id": self.id,
            "fixtureID": self.fixture_id,
            "family": self.family,
            "appearance": self.appearance,
            "presentation": self.presentation,
            "accessibility": self.accessibility,
            "justification": self.justification,
        }


@dataclass(frozen=True)
class SharedViewSurface:
    id: str
    cells: tuple[SharedViewCell, ...]

    @classmethod
    def from_dict(cls, payload: object) -> SharedViewSurface:
        if not isinstance(payload, dict) or set(payload) != {"id", "cells"}:
            raise SharedViewEvidenceError("shared-view matrix surface is invalid")
        surface_id = _require_string(payload["id"], "shared-view matrix surface identifier")
        raw_cells = payload["cells"]
        if not isinstance(raw_cells, list):
            raise SharedViewEvidenceError("shared-view matrix cells are invalid")
        return cls(surface_id, tuple(SharedViewCell.from_dict(item) for item in raw_cells))


@dataclass(frozen=True)
class SurfacePolicySurface:
    id: str
    platform: str
    device_class: str
    evidence_capabilities: tuple[str, ...]


@dataclass(frozen=True)
class SharedViewMatrix:
    schema_version: int
    kind: str
    fixture_contract_domain: str
    pixel_diff_policy: str
    max_cell_count: int
    surface_order: tuple[str, ...]
    cell_order: tuple[str, ...]
    surfaces: tuple[SharedViewSurface, ...]

    @classmethod
    def from_dict(cls, payload: object) -> SharedViewMatrix:
        expected_keys = {
            "schemaVersion",
            "kind",
            "fixtureContractDomain",
            "pixelDiffPolicy",
            "maxCellCount",
            "surfaceOrder",
            "cellOrder",
            "surfaces",
        }
        if not isinstance(payload, dict) or set(payload) != expected_keys:
            raise SharedViewEvidenceError("shared-view matrix root keys are invalid")
        raw_surfaces = payload["surfaces"]
        if not isinstance(raw_surfaces, list):
            raise SharedViewEvidenceError("shared-view matrix surfaces are invalid")
        max_cell_count = payload["maxCellCount"]
        if (
            type(payload["schemaVersion"]) is not int
            or payload["schemaVersion"] != MATRIX_SCHEMA_VERSION
            or payload["kind"] != MATRIX_KIND
            or payload["fixtureContractDomain"] != FIXTURE_CONTRACT_DOMAIN
            or payload["pixelDiffPolicy"] != PIXEL_DIFF_POLICY
            or type(max_cell_count) is not int
            or not 1 <= max_cell_count <= VISUAL_MAXIMUM_REQUIREMENT_COUNT
        ):
            raise SharedViewEvidenceError("shared-view matrix identity is invalid")
        return cls(
            schema_version=payload["schemaVersion"],
            kind=payload["kind"],
            fixture_contract_domain=payload["fixtureContractDomain"],
            pixel_diff_policy=payload["pixelDiffPolicy"],
            max_cell_count=max_cell_count,
            surface_order=_require_string_list(payload["surfaceOrder"], "shared-view matrix surface order"),
            cell_order=_require_string_list(payload["cellOrder"], "shared-view matrix cell order"),
            surfaces=tuple(SharedViewSurface.from_dict(item) for item in raw_surfaces),
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "schemaVersion": self.schema_version,
            "kind": self.kind,
            "fixtureContractDomain": self.fixture_contract_domain,
            "pixelDiffPolicy": self.pixel_diff_policy,
            "maxCellCount": self.max_cell_count,
            "surfaceOrder": list(self.surface_order),
            "cellOrder": list(self.cell_order),
            "surfaces": [
                {
                    "id": surface.id,
                    "cells": [cell.to_contract_dict() for cell in surface.cells],
                }
                for surface in self.surfaces
            ],
        }

    def digest(self) -> str:
        return canonical_json_hash("context-panel-shared-view-matrix/v1", self.to_dict())


def load_surface_policy(path: Path = DEFAULT_SURFACE_POLICY_PATH) -> tuple[SurfacePolicySurface, ...]:
    payload = _load_json_object(path, "surface policy")
    raw_surfaces = payload.get("surfaces")
    if (
        type(payload.get("schemaVersion")) is not int
        or payload.get("schemaVersion") != 1
        or not isinstance(raw_surfaces, list)
    ):
        raise SharedViewEvidenceError("surface policy is invalid")
    surfaces: list[SurfacePolicySurface] = []
    for raw_surface in raw_surfaces:
        if not isinstance(raw_surface, dict):
            raise SharedViewEvidenceError("surface policy is invalid")
        surface = SurfacePolicySurface(
            id=_require_string(raw_surface.get("id"), "surface policy surface identifier"),
            platform=_require_string(raw_surface.get("platform"), "surface policy platform"),
            device_class=_require_string(raw_surface.get("deviceClass"), "surface policy device class"),
            evidence_capabilities=_require_string_list(
                raw_surface.get("evidenceCapabilities"), "surface policy evidence capabilities"
            ),
        )
        surfaces.append(surface)
    if len({surface.id for surface in surfaces}) != len(surfaces):
        raise SharedViewEvidenceError("surface policy contains duplicate surfaces")
    return tuple(surfaces)


def validate_shared_view_matrix(
    matrix: SharedViewMatrix,
    surface_policy: tuple[SurfacePolicySurface, ...],
) -> SharedViewMatrix:
    shared_surfaces = tuple(
        surface for surface in surface_policy if "shared-view" in surface.evidence_capabilities
    )
    expected_surface_order = tuple(surface.id for surface in shared_surfaces)
    matrix_surface_order = tuple(surface.id for surface in matrix.surfaces)
    if matrix.surface_order != expected_surface_order or matrix_surface_order != expected_surface_order:
        raise SharedViewEvidenceError("shared-view matrix surface coverage or order is invalid")
    if matrix.cell_order != CANONICAL_CELL_ORDER:
        raise SharedViewEvidenceError("shared-view matrix cell order is invalid")
    cell_count = 0
    for surface in matrix.surfaces:
        cell_ids = tuple(cell.id for cell in surface.cells)
        if cell_ids != matrix.cell_order:
            raise SharedViewEvidenceError("shared-view matrix cells are missing, duplicate, or uncanonical")
        for cell in surface.cells:
            _validate_cell_coordinates(surface.id, cell)
        cell_count += len(surface.cells)
    if cell_count != matrix.max_cell_count:
        raise SharedViewEvidenceError("shared-view matrix cell budget is not exact")
    return matrix


def _validate_cell_coordinates(surface_id: str, cell: SharedViewCell) -> None:
    if surface_id in URL_GALLERY_SURFACES:
        fixture_ids = FIXTURE_IDS
        families = GALLERY_FAMILIES
        appearances = GALLERY_APPEARANCES
        if surface_id.endswith(".widget"):
            presentations = ("widget",)
        else:
            presentations = (
                MAC_GALLERY_PRESENTATIONS
                if surface_id.startswith("macos.")
                else COMPANION_GALLERY_PRESENTATIONS
            )
    elif surface_id == "watchos.app":
        fixture_ids = WATCH_APP_FIXTURE_IDS
        families = (NO_SELECTOR,)
        appearances = (NO_SELECTOR,)
        presentations = (NO_SELECTOR,)
    elif surface_id == "watchos.complication":
        fixture_ids = WATCH_COMPLICATION_FIXTURE_IDS
        families = WATCH_COMPLICATION_FAMILIES
        appearances = (NO_SELECTOR,)
        presentations = (NO_SELECTOR,)
    elif surface_id == "tvos.app":
        fixture_ids = TV_FIXTURE_IDS
        families = tuple(value for value in TV_GALLERY_SURFACES if value != "topShelf")
        appearances = (NO_SELECTOR,)
        presentations = TV_PRESENTATIONS
    elif surface_id == "tvos.top-shelf":
        fixture_ids = TV_FIXTURE_IDS
        families = ("topShelf",)
        appearances = (NO_SELECTOR,)
        presentations = TV_PRESENTATIONS
    else:
        raise SharedViewEvidenceError("shared-view matrix surface has no gallery vocabulary")
    if cell.fixture_id not in fixture_ids:
        raise SharedViewEvidenceError("shared-view matrix fixture is not selectable for its surface")
    if cell.family not in families:
        raise SharedViewEvidenceError("shared-view matrix family is not selectable for its surface")
    if cell.appearance not in appearances:
        raise SharedViewEvidenceError("shared-view matrix appearance is not selectable for its surface")
    if cell.presentation not in presentations:
        raise SharedViewEvidenceError("shared-view matrix presentation is not selectable for its surface")


def load_shared_view_matrix(
    path: Path = DEFAULT_MATRIX_PATH,
    surface_policy: tuple[SurfacePolicySurface, ...] | None = None,
) -> SharedViewMatrix:
    matrix = SharedViewMatrix.from_dict(_load_json_object(path, "shared-view matrix"))
    return validate_shared_view_matrix(matrix, surface_policy or load_surface_policy())


def fixture_contract_id(
    matrix: SharedViewMatrix,
    surface: SurfacePolicySurface,
    cell: SharedViewCell,
) -> str:
    return canonical_json_hash(
        matrix.fixture_contract_domain,
        {
            "matrixSchemaVersion": matrix.schema_version,
            "matrixDigest": matrix.digest(),
            "surface": surface.id,
            "platform": surface.platform,
            "device": surface.device_class,
            "evidenceCapabilities": list(surface.evidence_capabilities),
            "cell": cell.to_contract_dict(),
        },
    )


def shared_view_requirement_id(surface_id: str, cell_id: str) -> str:
    return f"shared-view.{surface_id.replace('.', '-')}.{cell_id}"


def plan_shared_view_evidence(
    comparison: object,
    matrix: SharedViewMatrix,
    surface_policy: tuple[SurfacePolicySurface, ...],
) -> dict[str, object]:
    try:
        validated_comparison = validate_current_comparison(comparison)
    except ComparisonSchemaError as error:
        raise SharedViewEvidenceError("surface comparison is invalid or stale") from error
    if validated_comparison["schemaVersion"] != 5:
        raise SharedViewEvidenceError("surface comparison is invalid or stale")
    validate_shared_view_matrix(matrix, surface_policy)
    policy_by_id = {surface.id: surface for surface in surface_policy}
    shared_surface_ids = {surface.id for surface in surface_policy if "shared-view" in surface.evidence_capabilities}
    fresh_shared_surfaces: set[str] = set()
    for surface in validated_comparison["surfaces"]:
        surface_id = surface["surfaceId"]
        if "os-composited-placement" in surface["freshEvidence"]:
            raise SharedViewEvidenceError(
                "surface comparison requires placement requirements outside the shared-view planner"
            )
        if "shared-view" in surface["freshEvidence"]:
            if surface_id not in shared_surface_ids:
                raise SharedViewEvidenceError("surface comparison claims shared-view for an uncovered surface")
            fresh_shared_surfaces.add(surface_id)
    requirements: list[dict[str, object]] = []
    for matrix_surface in matrix.surfaces:
        if matrix_surface.id not in fresh_shared_surfaces:
            continue
        policy_surface = policy_by_id[matrix_surface.id]
        for cell in matrix_surface.cells:
            requirements.append(
                {
                    "id": shared_view_requirement_id(policy_surface.id, cell.id),
                    "evidenceClass": "shared-view",
                    "surface": policy_surface.id,
                    "fixtureContractID": fixture_contract_id(matrix, policy_surface, cell),
                    "presentation": cell.presentation,
                    "appearance": cell.appearance,
                    "accessibility": cell.accessibility,
                    "hostOS": None,
                    "presentationFamily": None,
                    "placementHost": None,
                }
            )
    if len(requirements) > VISUAL_MAXIMUM_REQUIREMENT_COUNT:
        raise SharedViewEvidenceError("shared-view requirements exceed the visual review budget")
    return {
        "schemaVersion": 1,
        "kind": "context-panel-visual-review-requirements",
        "currentManifestID": validated_comparison["currentManifestId"],
        "requirements": requirements,
    }


def write_requirements_payload(path: Path, payload: dict[str, object]) -> None:
    if path.is_symlink() or path.parent.is_symlink():
        raise SharedViewEvidenceError("shared-view requirements output path is invalid")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, path)
        try:
            directory_descriptor = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        except OSError:
            pass
    except OSError as error:
        raise SharedViewEvidenceError("shared-view requirements output is unavailable") from error
    finally:
        temporary_path.unlink(missing_ok=True)
