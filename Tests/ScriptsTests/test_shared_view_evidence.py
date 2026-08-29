import contextlib
import copy
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, cast
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_comparison_schema import derive_risk_fields, derive_runtime_decision
from context_panel_validation import cli as cli_module
from context_panel_validation.shared_view_evidence import (
    DEFAULT_MATRIX_PATH,
    DEFAULT_SURFACE_POLICY_PATH,
    SharedViewEvidenceError,
    SharedViewMatrix,
    canonical_json,
    fixture_contract_id,
    load_shared_view_matrix,
    load_surface_policy,
    plan_shared_view_evidence,
    validate_shared_view_matrix,
)
from context_panel_validation.visual_approvals import MAXIMUM_REQUIREMENT_COUNT


MANIFEST_ID = "a" * 64


def comparison_for(surface_evidence: dict[str, list[str]]) -> dict[str, Any]:
    surfaces: list[dict[str, Any]] = []
    for surface_id, fresh_evidence in surface_evidence.items():
        carry_forward = {
            evidence_class: {"eligible": False, "conditions": []}
            for evidence_class in fresh_evidence
        }
        surfaces.append(
            {
                "surfaceId": surface_id,
                "artifactId": surface_id,
                "reasonCodes": ["exact-build-changed"],
                "changes": {
                    "render": False,
                    "runtime": False,
                    "placement": False,
                    "contract": False,
                    "exactBuild": True,
                },
                "minimumEvidence": [],
                "freshEvidence": fresh_evidence,
                "requiredEvidence": fresh_evidence,
                "carryForward": carry_forward,
            }
        )
    required_surfaces = {
        evidence_class: [
            surface_id
            for surface_id, evidence in surface_evidence.items()
            if evidence_class in evidence
        ]
        for evidence_class in (
            "shared-view",
            "actual-runtime",
            "os-composited-placement",
        )
    }
    comparison: dict[str, Any] = {
        "kind": "context-panel-surface-comparison",
        "schemaVersion": 5,
        "train": "beta",
        "previousManifestId": "b" * 64,
        "currentManifestId": MANIFEST_ID,
        "contractChanged": False,
        "exactBuildSame": False,
        "removedSurfaces": [],
        "requiredSurfaces": required_surfaces,
        "requiresRuntimeSession": bool(required_surfaces["actual-runtime"]),
        "requiresPlacementReview": bool(required_surfaces["os-composited-placement"]),
        "toolchainChanged": False,
        "artifactEvidence": {
            "previousState": "complete",
            "currentState": "complete",
            "previousExpectedBuildIds": ["b" * 64],
            "currentExpectedBuildIds": ["c" * 64],
        },
        "artifactRiskCodes": [],
        "artifactRiskSurfaces": {},
        "escalationState": "resolved",
        "surfaces": surfaces,
        "releaseRequiresApprovedRCTarget": True,
    }
    comparison["runtimeState"], comparison["runtimeStateReasons"] = derive_runtime_decision(surfaces)
    (
        comparison["riskCodes"],
        comparison["riskSurfaces"],
        comparison["observationRiskCodes"],
    ) = derive_risk_fields(
        surfaces,
        toolchain_delta=False,
        runtime_capable_surface_ids={
            surface["surfaceId"]
            for surface in surfaces
            if "actual-runtime" in surface["carryForward"]
        },
        requires_placement_review=comparison["requiresPlacementReview"],
    )
    return comparison


class SharedViewEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.surface_policy = load_surface_policy(DEFAULT_SURFACE_POLICY_PATH)
        self.matrix = load_shared_view_matrix(DEFAULT_MATRIX_PATH, self.surface_policy)

    def test_matrix_covers_exactly_the_twelve_shared_view_surfaces_in_policy_order(self) -> None:
        policy_shared = tuple(
            surface.id
            for surface in self.surface_policy
            if "shared-view" in surface.evidence_capabilities
        )

        self.assertEqual(len(policy_shared), 12)
        self.assertEqual(self.matrix.surface_order, policy_shared)
        self.assertEqual(tuple(surface.id for surface in self.matrix.surfaces), policy_shared)
        self.assertNotIn("macos.refresh-agent", policy_shared)

    def test_matrix_is_bounded_canonical_and_uses_two_justified_cells_per_surface(self) -> None:
        self.assertLessEqual(self.matrix.max_cell_count, MAXIMUM_REQUIREMENT_COUNT)
        self.assertEqual(self.matrix.max_cell_count, 24)
        self.assertEqual(self.matrix.cell_order, ("baseline", "stress"))
        self.assertEqual(sum(len(surface.cells) for surface in self.matrix.surfaces), 24)
        for surface in self.matrix.surfaces:
            self.assertEqual(tuple(cell.id for cell in surface.cells), self.matrix.cell_order)
            self.assertTrue(all(cell.justification for cell in surface.cells))
        self.assertEqual(self.matrix.pixel_diff_policy, "advisory-only")

    def test_matrix_hash_and_fixture_contract_ids_are_deterministic(self) -> None:
        matrix_again = SharedViewMatrix.from_dict(json.loads(DEFAULT_MATRIX_PATH.read_text()))
        self.assertEqual(self.matrix.digest(), matrix_again.digest())
        self.assertEqual(canonical_json(self.matrix.to_dict()), canonical_json(matrix_again.to_dict()))
        first_surface = self.surface_policy[0]
        first_cell = self.matrix.surfaces[0].cells[0]
        self.assertEqual(
            fixture_contract_id(self.matrix, first_surface, first_cell),
            fixture_contract_id(matrix_again, first_surface, first_cell),
        )

    def test_planner_binds_schema_v5_and_emits_fresh_shared_view_only(self) -> None:
        comparison = comparison_for(
            {
                "watchos.app": ["shared-view"],
                "watchos.complication": [
                    "shared-view",
                    "actual-runtime",
                    "os-composited-placement",
                ],
            }
        )

        payload = plan_shared_view_evidence(comparison, self.matrix, self.surface_policy)
        repeat_payload = plan_shared_view_evidence(comparison, self.matrix, self.surface_policy)
        requirements = cast(list[dict[str, object]], payload["requirements"])

        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["currentManifestID"], MANIFEST_ID)
        self.assertEqual(payload, repeat_payload)
        self.assertEqual(len(requirements), 4)
        self.assertEqual(
            [item["id"] for item in requirements],
            [
                "shared-view.watchos-app.baseline",
                "shared-view.watchos-app.stress",
                "shared-view.watchos-complication.baseline",
                "shared-view.watchos-complication.stress",
            ],
        )
        for requirement in requirements:
            self.assertEqual(requirement["evidenceClass"], "shared-view")
            self.assertIsNone(requirement["hostOS"])
            self.assertIsNone(requirement["presentationFamily"])
            self.assertIsNone(requirement["placementHost"])

    def test_shared_only_beta_plan_requires_no_runtime_surface(self) -> None:
        comparison = comparison_for({"watchos.app": ["shared-view"]})

        payload = plan_shared_view_evidence(comparison, self.matrix, self.surface_policy)
        requirements = cast(list[dict[str, object]], payload["requirements"])

        self.assertFalse(comparison["requiresRuntimeSession"])
        self.assertEqual([item["surface"] for item in requirements], ["watchos.app"] * 2)

    def test_planner_excludes_nonfresh_shared_runtime_and_placement_claims(self) -> None:
        comparison = comparison_for(
            {
                "watchos.app": [],
                "watchos.complication": ["actual-runtime", "os-composited-placement"],
            }
        )

        payload = plan_shared_view_evidence(comparison, self.matrix, self.surface_policy)

        self.assertEqual(payload["requirements"], [])

    def test_rejects_stale_unknown_and_tampered_comparisons(self) -> None:
        comparison = comparison_for({"watchos.app": ["shared-view"]})
        stale = copy.deepcopy(comparison)
        stale["schemaVersion"] = 4
        unknown = comparison_for({"macos.refresh-agent": ["shared-view"]})
        tampered = copy.deepcopy(comparison)
        tampered["currentManifestId"] = "not-a-manifest-id"

        for candidate in (stale, unknown, tampered):
            with self.assertRaises(SharedViewEvidenceError):
                plan_shared_view_evidence(candidate, self.matrix, self.surface_policy)

    def test_rejects_over_budget_and_missing_justification_matrix_cells(self) -> None:
        payload = json.loads(DEFAULT_MATRIX_PATH.read_text())
        over_budget = copy.deepcopy(payload)
        over_budget["maxCellCount"] = MAXIMUM_REQUIREMENT_COUNT + 1
        missing_justification = copy.deepcopy(payload)
        missing_justification["surfaces"][0]["cells"][0]["justification"] = ""

        for candidate in (over_budget, missing_justification):
            with self.assertRaises(SharedViewEvidenceError):
                SharedViewMatrix.from_dict(candidate)

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
                SharedViewMatrix.from_dict(candidate)

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

    def test_cli_writes_requirements_atomically_without_coordinator_state(self) -> None:
        comparison = comparison_for({"watchos.app": ["shared-view"]})
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            comparison_path = root / "comparison.json"
            output_path = root / "requirements.json"
            comparison_path.write_text(json.dumps(comparison))
            output_path.write_text("old output\n")
            stdout = io.StringIO()
            with (
                mock.patch.object(cli_module, "SessionStateStore", side_effect=AssertionError),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = cli_module.main(
                    [
                        "plan-shared-view-evidence",
                        "--surface-comparison",
                        str(comparison_path),
                        "--output",
                        str(output_path),
                        "--json",
                    ]
                )

            self.assertEqual(exit_code, 0)
            self.assertEqual(json.loads(stdout.getvalue()), json.loads(output_path.read_text()))
            self.assertFalse(list(root.glob(".requirements.json.*")))


if __name__ == "__main__":
    unittest.main()
