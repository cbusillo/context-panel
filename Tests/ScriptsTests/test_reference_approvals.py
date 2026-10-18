import contextlib
from datetime import timedelta
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from context_panel_surface_manifest.core import canonical_json, hash_parts  # noqa: E402
from context_panel_validation import SessionStateStore, VisualApprovalStore, load_visual_review_plan  # noqa: E402
from context_panel_validation import cli as cli_module  # noqa: E402
import test_shared_view_references as images  # noqa: E402
import test_visual_approvals as plans  # noqa: E402

APP = "shared-view.watchos-app.baseline"
COMPLICATION = "shared-view.watchos-complication.baseline"
PLACEMENT = "watch.complication.placement.corner"
GIT_ENVIRONMENT = {
    "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.invalid",
    "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.invalid",
}


def png(color: tuple[int, int, int, int]) -> bytes:
    return images.encode_png(12, 8, [color] * 96)


GRAY = png((120, 120, 120, 255))
RED = png((255, 0, 0, 255))
DIGEST_DOMAIN = json.loads((REPO_ROOT / "Config" / "ContextPanelSurfacePolicy.json").read_text())["digestDomain"]


def manifest(commit: str, build: str) -> dict:
    body = {"schemaVersion": 1, "digestDomain": DIGEST_DOMAIN, "source": {"commit": commit, "buildNumber": build}}
    return {**body, "manifestId": hash_parts(f"{DIGEST_DOMAIN}/manifest", [canonical_json(body)])}


class ReferenceApprovalTests(unittest.TestCase):
    """Runs record-reference-approvals against a real coordinator session and Git history."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repository = self.root / "repository"
        self.captures = self.root / "captures"
        self.captures.mkdir()
        self.store = SessionStateStore(root=self.root, legacy_root=self.root / "Legacy")
        self.git("init", "-q", str(self.repository), cwd=self.root)

    def git(self, *arguments: str, cwd: Path | None = None) -> str:
        return subprocess.run(
            ["git", *arguments], cwd=cwd or self.repository, check=True, capture_output=True, text=True,
            env={**os.environ, **GIT_ENVIRONMENT},
        ).stdout.strip()

    def commit(self, references: dict[str, bytes]) -> str:
        root = self.repository / "Tests" / "SharedViewReferences"
        if root.exists():
            for path in root.rglob("*.png"):
                path.unlink()
        for relative, data in references.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "references")
        return self.git("rev-parse", "HEAD")

    def prepare(
        self,
        previous_references: dict[str, bytes],
        current_references: dict[str, bytes],
        captured: dict[str, bytes],
    ) -> SimpleNamespace:
        """Commit both releases' references, then open a session bound to their manifests."""
        previous_manifest = manifest(self.commit(previous_references), "1")
        current_manifest = manifest(self.commit(current_references), "2")
        manifest_patch = mock.patch.object(plans, "MANIFEST_ID", current_manifest["manifestId"])
        manifest_patch.start()
        self.addCleanup(manifest_patch.stop)
        self.shared_identity = plans.identity("watchos.app", "watchOS")
        self.placement_identity = plans.identity("watchos.complication", "watchOS")

        comparison_path, requirements_path = plans.VisualApprovalTests.write_plan_files(self)
        comparison = json.loads(comparison_path.read_text())
        comparison["previousManifestId"] = previous_manifest["manifestId"]
        comparison_path.write_text(json.dumps(comparison))
        requirements = json.loads(requirements_path.read_text())
        renamed = {"watch.app.shared.dark": APP, "watch.complication.shared.corner": COMPLICATION}
        for requirement in requirements["requirements"]:
            requirement["id"] = renamed.get(requirement["id"], requirement["id"])
        requirements_path.write_text(json.dumps(requirements))
        runtime_surfaces, requirements, manifest_id = load_visual_review_plan(
            comparison_path, requirements_path, (self.shared_identity, self.placement_identity)
        )
        self.session, _ = self.store.start_session(
            plans.TARGET, runtime_surfaces, plans.NOW, timedelta(hours=2), timedelta(days=1)
        )
        VisualApprovalStore(self.store).configure(self.session, manifest_id, requirements, plans.NOW)
        fixtures = {item.id: item.fixture_contract_id for item in requirements}

        records = []
        for requirement_id, surface in ((APP, "watchos.app"), (COMPLICATION, "watchos.complication")):
            data = captured.get(requirement_id, GRAY)
            (self.captures / f"{requirement_id}.png").write_bytes(data)
            records.append({
                "requirementID": requirement_id,
                "surface": surface,
                "cellID": "baseline",
                "fixtureContractID": fixtures[requirement_id],
                "status": "captured",
                "artifactDigest": hashlib.sha256(data).hexdigest(),
                "hostMechanism": "simctl-gallery",
                "appearanceMechanism": None,
                "errorCode": None,
            })
        paths = {name: self.root / f"{name}.json" for name in ("current", "previous", "receipt")}
        paths["current"].write_text(json.dumps(current_manifest))
        paths["previous"].write_text(json.dumps(previous_manifest))
        paths["receipt"].write_text(json.dumps({
            "schemaVersion": 1,
            "kind": "context-panel-shared-view-capture-receipt",
            "pixelDiffPolicy": "advisory-only",
            "currentManifestID": manifest_id,
            "profiles": [],
            "captures": records,
        }))
        return SimpleNamespace(
            version=plans.TARGET.version,
            build_number=plans.TARGET.build_number,
            json=True,
            surface_comparison=comparison_path,
            current_manifest=paths["current"],
            previous_manifest=paths["previous"],
            capture_receipt=paths["receipt"],
            captures=self.captures,
            repository=self.repository,
        )

    def run_command(self, args: SimpleNamespace) -> dict:
        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(self.root)}),
            mock.patch.object(cli_module, "utc_now", return_value=plans.NOW + timedelta(minutes=1)),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            self.assertEqual(cli_module.run_record_reference_approvals(args), 0)
        return json.loads(output.getvalue())

    def decisions(self) -> dict[str, str]:
        state = VisualApprovalStore(self.store).load(self.session)
        return {decision.requirement_id: decision.decision for decision in state.decisions}

    def test_only_cells_matching_an_unchanged_reference_are_approved(self) -> None:
        both = {"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY}
        args = self.prepare(both, both, {APP: GRAY, COMPLICATION: RED})

        result = self.run_command(args)

        self.assertEqual(result["approved"], [APP])
        self.assertEqual(result["needsReview"], {COMPLICATION: "image-changed"})
        self.assertEqual(self.decisions(), {APP: "approved"})

    def test_a_changed_or_missing_reference_goes_to_review(self) -> None:
        args = self.prepare({"watchos.app/baseline.png": GRAY}, {"watchos.app/baseline.png": RED}, {APP: RED})

        result = self.run_command(args)

        self.assertEqual(result["needsReview"], {APP: "reference-changed", COMPLICATION: "missing-reference"})
        self.assertEqual(self.decisions(), {})

    def test_a_reference_new_since_the_previous_release_goes_to_review(self) -> None:
        args = self.prepare({}, {"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY}, {})

        result = self.run_command(args)

        self.assertEqual(result["needsReview"], {APP: "new-reference", COMPLICATION: "new-reference"})

    def test_a_capture_that_does_not_match_the_receipt_goes_to_review(self) -> None:
        both = {"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY}
        args = self.prepare(both, both, {})
        (self.captures / f"{APP}.png").write_bytes(RED)
        (self.captures / f"{COMPLICATION}.png").unlink()

        result = self.run_command(args)

        self.assertEqual(result["needsReview"], {APP: "capture-unavailable", COMPLICATION: "capture-unavailable"})

    def test_a_recorded_human_decision_is_never_replaced(self) -> None:
        both = {"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY}
        args = self.prepare(both, both, {})
        VisualApprovalStore(self.store).record(self.session, APP, "rejected", plans.NOW, None)

        result = self.run_command(args)

        self.assertEqual(result["approved"], [COMPLICATION])
        self.assertEqual(result["needsReview"], {APP: "already-decided"})
        self.assertEqual(self.decisions(), {APP: "rejected", COMPLICATION: "approved"})

    def test_placement_requirements_are_never_touched(self) -> None:
        both = {"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY}
        result = self.run_command(self.prepare(both, both, {}))

        self.assertNotIn(PLACEMENT, result["approved"])
        self.assertNotIn(PLACEMENT, result["needsReview"])
        self.assertNotIn(PLACEMENT, self.decisions())

    def test_untrusted_sources_or_an_unqualified_receipt_approve_nothing(self) -> None:
        both = {"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY}

        def forged_previous(args: SimpleNamespace) -> None:
            # Keeps the previous release's ID but points at the candidate commit.
            forged = json.loads(args.previous_manifest.read_text())
            forged["source"]["commit"] = json.loads(args.current_manifest.read_text())["source"]["commit"]
            args.previous_manifest.write_text(json.dumps(forged))

        def unrelated_previous(args: SimpleNamespace) -> None:
            args.previous_manifest.write_text(json.dumps(manifest(self.git("rev-parse", "HEAD"), "9")))

        def incomplete_receipt(args: SimpleNamespace) -> None:
            receipt = json.loads(args.capture_receipt.read_text())
            receipt["captures"].pop()
            args.capture_receipt.write_text(json.dumps(receipt))

        for mutate in (forged_previous, unrelated_previous, incomplete_receipt):
            with self.subTest(mutate.__name__):
                self.setUp()  # a fresh repository and coordinator state for each case
                args = self.prepare(both, both, {})
                mutate(args)
                with (
                    mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(self.root)}),
                    mock.patch.object(cli_module, "utc_now", return_value=plans.NOW + timedelta(minutes=1)),
                    self.assertRaises(cli_module.VisualApprovalError),
                ):
                    cli_module.run_record_reference_approvals(args)
                self.assertEqual(self.decisions(), {})

if __name__ == "__main__":
    unittest.main()
