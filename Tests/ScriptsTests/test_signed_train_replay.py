import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_release_gate.core import LEDGER_KEYS, _ledger_id
from context_panel_replay.comparison_adapters import adapt_comparison_for_replay
from context_panel_replay.inventory import InventoryError, canonical_digest, seal_inventory, write_inventory
from context_panel_replay.replay import (
    ReplayError,
    build_report,
    check_replay,
    reconstruct_bundle,
    render_artifact,
    validate_bundle,
    validate_release_gate_diagnostics,
    validate_report,
    verify_replay,
    write_json,
)
from context_panel_replay.replay_cli import run as replay_cli_run


INVENTORY_POLICY = REPO_ROOT / "Config/ContextPanelReplayInventoryPolicy.json"
INVENTORY = REPO_ROOT / "scripts/context_panel_replay/inventory/signed-trains.json"
RELEASE_POLICY = REPO_ROOT / "Config/ContextPanelReleaseEvidencePolicy.json"
SURFACE_POLICY = REPO_ROOT / "Config/ContextPanelSurfacePolicy.json"
BUNDLE = REPO_ROOT / "scripts/context_panel_replay/replay/signed-trains-bundle.json"
REPORT = REPO_ROOT / "scripts/context_panel_replay/replay/signed-trains-report.json"


class SignedTrainReplayTests(unittest.TestCase):
    def load(self, path: Path) -> dict:
        return json.loads(path.read_text())

    def sign(self, payload: dict, field: str) -> None:
        payload[field] = canonical_digest(
            {key: value for key, value in payload.items() if key != field}
        )

    def validate_bundle(self, payload: dict) -> None:
        validate_bundle(
            payload,
            inventory_policy_path=INVENTORY_POLICY,
            inventory_path=INVENTORY,
            release_policy_path=RELEASE_POLICY,
            surface_policy_path=SURFACE_POLICY,
        )

    def ledger(self) -> dict:
        payload = {key: None for key in LEDGER_KEYS}
        payload.update(schemaVersion=1, kind="context-panel-release-evidence", mode="shadow",
                       train="rc", state="approved", target={}, requiredEvidence={}, surfaces=[],
                       shadow={}, blockers=[], privacy="context-panel-release-evidence-public-v1")
        payload["ledgerID"] = _ledger_id(payload)
        return payload

    def test_committed_tier_a_artifacts_are_current(self):
        report = check_replay(
            inventory_policy_path=INVENTORY_POLICY,
            inventory_path=INVENTORY,
            release_policy_path=RELEASE_POLICY,
            surface_policy_path=SURFACE_POLICY,
            bundle_path=BUNDLE,
            report_path=REPORT,
        )
        self.assertEqual(report["summary"]["trainCount"], 3)
        self.assertEqual(report["summary"]["surfaceCount"], 39)

    def test_raw_source_verification_failure_blocks_reconstruction(self):
        with patch(
            "context_panel_replay.replay.verify_inventory",
            side_effect=InventoryError("raw source changed"),
        ):
            with self.assertRaisesRegex(ReplayError, "raw source changed"):
                reconstruct_bundle(
                    inventory_policy_path=INVENTORY_POLICY,
                    inventory_path=INVENTORY,
                    release_policy_path=RELEASE_POLICY,
                    surface_policy_path=SURFACE_POLICY,
                    root_bindings={},
                )
        with patch("context_panel_replay.inventory.raw_digest", side_effect=OSError("unreadable")):
            with self.assertRaises(ReplayError):
                self.validate_bundle(self.load(BUNDLE))

    def test_synthetic_tier_b_round_trip_and_source_fence(self):
        from Tests.ScriptsTests.test_replay_inventory import ReplayInventoryTests

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = ReplayInventoryTests()
            policy, roots = fixture.fixture(root, retain_receipt=True)
            comparison_path = root / "archive/train/comparison.json"
            comparison = adapt_comparison_for_replay(self.load(comparison_path))
            comparison["surfaces"][0]["carryForward"].update({
                "actual-runtime": {"eligible": True, "conditions": []},
                "os-composited-placement": {
                    "eligible": True,
                    "conditions": ["matching-host-os", "matching-current-runtime-receipt"],
                },
            })
            comparison_path.write_text(json.dumps(comparison) + "\n")
            ledger_path = root / "archive/train/ledger.json"
            ledger = self.load(ledger_path)
            ledger["comparisonDigest"] = canonical_digest(comparison)
            ledger["ledgerID"] = _ledger_id(ledger)
            fixture.write_json(ledger_path, ledger)
            lineage_path = root / "archive/train/lineage.json"
            lineage = self.load(lineage_path)
            lineage["ledger"], lineage["generation"]["comparison"] = ledger, comparison
            fixture.write_json(lineage_path, lineage)
            inventory = seal_inventory(policy, roots)
            inventory_path = root / "inventory.json"
            write_inventory(inventory, inventory_path)
            surface_policy = root / "surfaces.json"
            fixture.write_json(
                surface_policy,
                {
                    "schemaVersion": 1,
                    "surfaces": [{
                        "id": "macos.app",
                        "artifactId": "Context Panel.app",
                        "deviceClass": "Mac",
                        "evidenceCapabilities": ["shared-view", "actual-runtime"],
                    }],
                },
            )
            arguments = dict(
                inventory_policy_path=policy,
                inventory_path=inventory_path,
                release_policy_path=RELEASE_POLICY,
                surface_policy_path=surface_policy,
                root_bindings=roots,
            )
            bundle = reconstruct_bundle(**arguments)
            self.assertEqual(bundle["trains"][0]["comparisonAdapter"], [2, 2])
            report = build_report(bundle)
            bundle_path, report_path = root / "bundle.json", root / "report-out.json"
            write_json(bundle, bundle_path)
            write_json(report, report_path)
            self.assertEqual(
                verify_replay(**arguments, bundle_path=bundle_path, report_path=report_path), report
            )
            retained_report = root / "archive/train/report.json"
            payload = self.load(retained_report)
            payload["runtimeSurfaces"][0]["state"] = "not-reported"
            fixture.write_json(retained_report, payload)
            with patch("context_panel_replay.replay.verify_inventory", return_value=inventory):
                with self.assertRaisesRegex(ReplayError, "changed after"):
                    reconstruct_bundle(**arguments)

    def test_bundle_rejects_unbounded_states_actions_receipts_and_claims(self):
        train = lambda bundle: bundle["trains"][0]
        surface = lambda bundle: train(bundle)["runtimeSurfaces"][0]
        mutations = (
            lambda bundle: surface(bundle)[5].__setitem__(
                2, "skipped:operator-judgment"
            ),
            lambda bundle: surface(bundle).__setitem__(8, "not-referenced"),
            lambda bundle: train(bundle)["blockedClaims"].append(
                train(bundle)["admissibleClaims"][0]
            ),
            lambda bundle: train(bundle).__setitem__("trainName", "beta"),
            lambda bundle: surface(bundle).__setitem__(6, "not-reported"),
            lambda bundle: train(bundle)["artifactObservations"][0][2][0].__setitem__(
                1, "0" * 64
            ),
            lambda bundle: train(bundle)["sourceVerification"][0].__setitem__(0, "other-category"),
            lambda bundle: train(bundle).__setitem__("unexpected", True),
            lambda bundle: bundle.__setitem__("schemaVersion", True),
        )
        for mutate in mutations:
            bundle = self.load(BUNDLE)
            mutate(bundle)
            bundle["trains"][0]["blockedClaims"].sort()
            self.sign(bundle, "bundleId")
            with self.assertRaises(ReplayError):
                self.validate_bundle(bundle)

    def test_bundle_binds_scope_lineage_comparison_and_artifacts(self):
        def new_surface(bundle):
            row = next(row for row in bundle["trains"][0]["runtimeSurfaces"] if row[4] == "00001")
            row[3] = ["new-surface"]

        mutations = (
            lambda bundle: bundle["trains"][0]["runtimeSurfaces"][0][5].__setitem__(
                0, "skipped:comparison-not-required"
            ),
            lambda bundle: bundle["trains"][0].__setitem__("previousManifestId", "0" * 64),
            lambda bundle: bundle["trains"][1].__setitem__(
                "currentManifestId", bundle["trains"][0]["currentManifestId"]
            ),
            lambda bundle: bundle["trains"][0].__setitem__("comparisonDigest", "0" * 64),
            lambda bundle: bundle["trains"][0].__setitem__("comparisonAdapter", [99, 2]),
            lambda bundle: bundle["trains"][0].__setitem__("artifactObservations", []),
            new_surface,
        )
        for mutate in mutations:
            bundle = self.load(BUNDLE)
            mutate(bundle)
            self.sign(bundle, "bundleId")
            with self.assertRaises(ReplayError):
                self.validate_bundle(bundle)

    def test_diagnostics_command_binds_canonical_replay_and_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ledger = root / "ledger.json"
            output = root / "diagnostics.json"
            ledger.write_text(json.dumps(self.ledger()))
            self.assertEqual(
                replay_cli_run(
                    [
                        "diagnostics",
                        "--release-evidence",
                        str(ledger),
                        "--output",
                        str(output),
                        "--bundle",
                        str(BUNDLE),
                        "--report",
                        str(REPORT),
                    ]
                ),
                0,
            )
            diagnostics = self.load(output)
            self.assertEqual(len(diagnostics["residualRisks"]), 3)
            diagnostics["sourceState"] = "verified"
            self.sign(diagnostics, "diagnosticsId")
            with self.assertRaises(ReplayError):
                validate_release_gate_diagnostics(diagnostics)
            forged_ledger = self.ledger()
            forged_ledger["ledgerID"] = "0" * 64
            ledger.write_text(json.dumps(forged_ledger))
            with self.assertRaises(ReplayError):
                replay_cli_run(
                    ["diagnostics", "--release-evidence", str(ledger), "--output", str(output)]
                )
            ledger.write_text(json.dumps(self.ledger()))

            forged = self.load(REPORT)
            forged["trains"] = []
            forged["summary"] = {key: 0 for key in forged["summary"]}
            forged["sourceState"] = "verified"
            self.sign(forged, "reportId")
            forged_path = root / "forged.json"
            forged_path.write_bytes(render_artifact(forged))
            with self.assertRaises(ReplayError):
                replay_cli_run(
                    [
                        "diagnostics",
                        "--release-evidence",
                        str(ledger),
                        "--output",
                        str(output),
                        "--bundle",
                        str(BUNDLE),
                        "--report",
                        str(forged_path),
                    ]
                )
            with self.assertRaisesRegex(ReplayError, "distinct paths"):
                replay_cli_run(
                    [
                        "diagnostics",
                        "--release-evidence",
                        str(ledger),
                        "--output",
                        str(root / "child" / ".." / "ledger.json"),
                    ]
                )
            with self.assertRaisesRegex(ReplayError, "outside retained"):
                replay_cli_run(
                    [
                        "reconstruct",
                        "--root",
                        f"shadow-trains={root}",
                        "--root",
                        f"build-release-evidence={root}",
                        "--root",
                        f"code-evidence={root}",
                        "--bundle",
                        str(root / "raw.json"),
                        "--report",
                        str(root.parent / "report.json"),
                    ]
                )


if __name__ == "__main__":
    unittest.main()
