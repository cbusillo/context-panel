import copy
import json
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_shared_view_matrix import (  # noqa: E402
    CANONICAL_CELL_ORDER,
    DEFAULT_MATRIX_PATH,
    DEFAULT_SURFACE_POLICY_PATH,
    SharedViewEvidenceError,
    SharedViewMatrix,
    VISUAL_MAXIMUM_REQUIREMENT_COUNT,
    load_shared_view_matrix,
    load_surface_policy,
    validate_shared_view_matrix,
)


class SharedViewMatrixTests(unittest.TestCase):
    """The matrix decides which cells CI captures and compares with reference images."""

    def setUp(self) -> None:
        self.surface_policy = load_surface_policy(DEFAULT_SURFACE_POLICY_PATH)
        self.matrix = load_shared_view_matrix(DEFAULT_MATRIX_PATH, self.surface_policy)

    def test_matrix_covers_exactly_the_shared_view_surfaces_in_policy_order(self) -> None:
        policy_shared = tuple(
            surface.id
            for surface in self.surface_policy
            if "shared-view" in surface.evidence_capabilities
        )

        self.assertEqual(self.matrix.surface_order, policy_shared)
        self.assertEqual(tuple(surface.id for surface in self.matrix.surfaces), policy_shared)
        self.assertNotIn("macos.refresh-agent", policy_shared)

    def test_matrix_is_bounded_canonical_and_uses_two_justified_cells_per_surface(self) -> None:
        self.assertLessEqual(self.matrix.max_cell_count, VISUAL_MAXIMUM_REQUIREMENT_COUNT)
        self.assertEqual(self.matrix.cell_order, CANONICAL_CELL_ORDER)
        self.assertEqual(
            sum(len(surface.cells) for surface in self.matrix.surfaces),
            len(self.matrix.surfaces) * len(self.matrix.cell_order),
        )
        self.assertEqual(
            self.matrix.max_cell_count,
            len(self.matrix.surfaces) * len(self.matrix.cell_order),
        )
        for surface in self.matrix.surfaces:
            self.assertEqual(tuple(cell.id for cell in surface.cells), self.matrix.cell_order)
            self.assertTrue(all(cell.justification for cell in surface.cells))

    def test_rejects_over_budget_and_missing_justification_matrix_cells(self) -> None:
        payload = json.loads(DEFAULT_MATRIX_PATH.read_text())
        over_budget = copy.deepcopy(payload)
        over_budget["maxCellCount"] = VISUAL_MAXIMUM_REQUIREMENT_COUNT + 1
        inexact_budget = copy.deepcopy(payload)
        inexact_budget["maxCellCount"] += 1
        missing_justification = copy.deepcopy(payload)
        missing_justification["surfaces"][0]["cells"][0]["justification"] = ""

        for candidate in (over_budget, missing_justification):
            with self.assertRaises(SharedViewEvidenceError):
                SharedViewMatrix.from_dict(candidate)
        with self.assertRaises(SharedViewEvidenceError):
            validate_shared_view_matrix(
                SharedViewMatrix.from_dict(inexact_budget),
                self.surface_policy,
            )

    def test_rejects_matrix_cells_outside_allowlisted_vocabularies(self) -> None:
        payload = json.loads(DEFAULT_MATRIX_PATH.read_text())
        candidates = []
        for key, value in (
            ("fixtureID", "production-account"),
            ("family", "accessoryCircular"),
            ("appearance", "high-contrast"),
            ("presentation", "complication"),
            ("accessibility", "voice-control"),
        ):
            candidate = copy.deepcopy(payload)
            candidate["surfaces"][0]["cells"][0][key] = value
            candidates.append(candidate)

        for candidate in candidates:
            with self.assertRaises(SharedViewEvidenceError):
                validate_shared_view_matrix(
                    SharedViewMatrix.from_dict(candidate),
                    self.surface_policy,
                )

    def test_rejects_presentations_unsupported_by_the_surface_host(self) -> None:
        payload = json.loads(DEFAULT_MATRIX_PATH.read_text())
        companion_detail = copy.deepcopy(payload)
        companion_detail["surfaces"][2]["cells"][1]["presentation"] = "detail"
        mac_settings = copy.deepcopy(payload)
        mac_settings["surfaces"][0]["cells"][1]["presentation"] = "settings"
        widget_overview = copy.deepcopy(payload)
        widget_overview["surfaces"][4]["cells"][1]["presentation"] = "overview"

        for candidate in (companion_detail, mac_settings, widget_overview):
            with self.assertRaises(SharedViewEvidenceError):
                validate_shared_view_matrix(
                    SharedViewMatrix.from_dict(candidate),
                    self.surface_policy,
                )

    def test_rejects_missing_extra_duplicate_and_uncanonical_matrix_cells(self) -> None:
        payload = json.loads(DEFAULT_MATRIX_PATH.read_text())
        candidates = []
        missing = copy.deepcopy(payload)
        missing["surfaces"][0]["cells"] = missing["surfaces"][0]["cells"][:1]
        candidates.append(missing)
        extra = copy.deepcopy(payload)
        extra["surfaces"].append(copy.deepcopy(extra["surfaces"][0]))
        candidates.append(extra)
        duplicate = copy.deepcopy(payload)
        duplicate["surfaces"][0]["cells"][1]["id"] = "baseline"
        candidates.append(duplicate)
        uncanonical = copy.deepcopy(payload)
        uncanonical["surfaces"][0]["cells"].reverse()
        candidates.append(uncanonical)

        for candidate in candidates:
            with self.assertRaises(SharedViewEvidenceError):
                matrix = SharedViewMatrix.from_dict(candidate)
                validate_shared_view_matrix(matrix, self.surface_policy)


if __name__ == "__main__":
    unittest.main()
