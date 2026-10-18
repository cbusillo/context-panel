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
        self.shared_identity = plans.identity("watchos.app", "watchOS")
        self.placement_identity = plans.identity("watchos.complication", "watchOS")
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

    def configure_session(self) -> None:
        comparison_path, requirements_path = plans.VisualApprovalTests.write_plan_files(self)
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
        self.comparison_path = comparison_path

    def write_inputs(self, previous_commit: str, current_commit: str, captured: dict[str, bytes]) -> SimpleNamespace:
        current = self.root / "current.json"
        previous = self.root / "previous.json"
        current.write_text(json.dumps({"manifestId": plans.MANIFEST_ID, "source": {"commit": current_commit}}))
        previous.write_text(json.dumps({"manifestId": "c" * 64, "source": {"commit": previous_commit}}))
        records = []
        for requirement_id, data in captured.items():
            (self.captures / f"{requirement_id}.png").write_bytes(data)
            records.append({
                "requirementID": requirement_id,
                "status": "captured",
                "artifactDigest": hashlib.sha256(data).hexdigest(),
            })
        receipt = self.root / "receipt.json"
        receipt.write_text(json.dumps({"currentManifestID": plans.MANIFEST_ID, "captures": records}))
        return SimpleNamespace(
            version=plans.TARGET.version,
            build_number=plans.TARGET.build_number,
            json=True,
            surface_comparison=self.comparison_path,
            current_manifest=current,
            previous_manifest=previous,
            capture_receipt=receipt,
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
        self.configure_session()
        previous = self.commit({"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY})
        current = self.commit({"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY})

        result = self.run_command(self.write_inputs(previous, current, {APP: GRAY, COMPLICATION: RED}))

        self.assertEqual(result["approved"], [APP])
        self.assertEqual(result["needsReview"], {COMPLICATION: "image-changed"})
        self.assertEqual(self.decisions(), {APP: "approved"})

    def test_a_changed_new_or_missing_reference_goes_to_review(self) -> None:
        self.configure_session()
        previous = self.commit({"watchos.app/baseline.png": GRAY})
        current = self.commit({"watchos.app/baseline.png": RED})

        result = self.run_command(self.write_inputs(previous, current, {APP: RED, COMPLICATION: GRAY}))
        self.assertEqual(result["needsReview"], {APP: "reference-changed", COMPLICATION: "missing-reference"})

        current = self.commit({"watchos.app/baseline.png": RED, "watchos.complication/baseline.png": GRAY})
        result = self.run_command(self.write_inputs(previous, current, {APP: RED, COMPLICATION: GRAY}))
        self.assertEqual(result["needsReview"], {APP: "reference-changed", COMPLICATION: "new-reference"})
        self.assertEqual(self.decisions(), {})

    def test_a_capture_that_does_not_match_the_receipt_goes_to_review(self) -> None:
        self.configure_session()
        commit = self.commit({"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY})
        args = self.write_inputs(commit, commit, {APP: GRAY, COMPLICATION: GRAY})
        (self.captures / f"{APP}.png").write_bytes(RED)
        (self.captures / f"{COMPLICATION}.png").unlink()

        result = self.run_command(args)

        self.assertEqual(result["needsReview"], {APP: "capture-unavailable", COMPLICATION: "capture-unavailable"})

    def test_a_recorded_human_decision_is_never_replaced(self) -> None:
        self.configure_session()
        VisualApprovalStore(self.store).record(self.session, APP, "rejected", plans.NOW, None)
        commit = self.commit({"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY})

        result = self.run_command(self.write_inputs(commit, commit, {APP: GRAY, COMPLICATION: GRAY}))

        self.assertEqual(result["approved"], [COMPLICATION])
        self.assertEqual(result["needsReview"], {APP: "already-decided"})
        self.assertEqual(self.decisions(), {APP: "rejected", COMPLICATION: "approved"})

    def test_placement_requirements_are_never_touched(self) -> None:
        self.configure_session()
        commit = self.commit({"watchos.app/baseline.png": GRAY, "watchos.complication/baseline.png": GRAY})

        result = self.run_command(self.write_inputs(commit, commit, {APP: GRAY, COMPLICATION: GRAY}))

        self.assertNotIn(PLACEMENT, result["approved"])
        self.assertNotIn(PLACEMENT, result["needsReview"])
        self.assertNotIn(PLACEMENT, self.decisions())

    def test_sources_must_belong_to_the_session_comparison(self) -> None:
        self.configure_session()
        commit = self.commit({})
        args = self.write_inputs(commit, commit, {})
        args.previous_manifest.write_text(json.dumps({"manifestId": "d" * 64, "source": {"commit": commit}}))

        with (
            mock.patch.dict(os.environ, {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": str(self.root)}),
            mock.patch.object(cli_module, "utc_now", return_value=plans.NOW + timedelta(minutes=1)),
            self.assertRaisesRegex(cli_module.VisualApprovalError, "comparison"),
        ):
            cli_module.run_record_reference_approvals(args)


if __name__ == "__main__":
    unittest.main()
