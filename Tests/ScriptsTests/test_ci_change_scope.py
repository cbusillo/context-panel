import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "ci-change-scope.py"
SPEC = importlib.util.spec_from_file_location("ci_change_scope", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


# Variables that would point Git at the enclosing repository instead of a fixture.
GIT_LOCATION_VARIABLES = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_NAMESPACE",
    "GIT_PREFIX",
)


def fixture_environment() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if key not in GIT_LOCATION_VARIABLES}


def git(root: Path, *args: str) -> str:
    environment = {
        **fixture_environment(),
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.invalid",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.invalid",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_SYSTEM": os.devnull,
    }
    return subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        capture_output=True,
        text=True,
        env=environment,
    ).stdout.strip()


def imported_scripts(entry_point: str) -> list[str]:
    """Repository scripts the entry point really imports when it runs."""
    listing = subprocess.run(
        [
            sys.executable,
            "-c",
            "import runpy, sys\n"
            "sys.argv = [sys.argv[1], '--help']\n"
            "sys.path.insert(0, sys.argv[0].rsplit('/', 1)[0])\n"
            "try:\n"
            "    runpy.run_path(sys.argv[0], run_name='__main__')\n"
            "except SystemExit:\n"
            "    pass\n"
            "for loaded in list(sys.modules.values()):\n"
            "    print('loaded:' + (getattr(loaded, '__file__', None) or ''))\n",
            str(REPO_ROOT / entry_point),
        ],
        check=True,
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
        env={**fixture_environment(), "PYTHONDONTWRITEBYTECODE": "1"},
    ).stdout.splitlines()
    scripts_root = (REPO_ROOT / "scripts").resolve()
    return sorted(
        {
            Path(line).resolve().relative_to(REPO_ROOT.resolve()).as_posix()
            for line in (entry.removeprefix("loaded:") for entry in listing if entry.startswith("loaded:"))
            if line and Path(line).resolve().is_relative_to(scripts_root)
        }
    )


def commit(root: Path, files: dict[str, str], message: str) -> None:
    for name, content in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    git(root, "add", "--all")
    git(root, "commit", "--quiet", "--message", message)


class ClassifyTests(unittest.TestCase):
    def test_unknown_changes_run_everything(self):
        for paths in (None, []):
            scope = module.classify(paths)
            self.assertTrue(scope.product)

    def test_documentation_and_validation_tooling_skip_the_product_lane(self):
        scope = module.classify(
            [
                "docs/release.md",
                "AGENTS.md",
                "Tests/ScriptsTests/test_shared_view_capture.py",
                "Tests/ScriptsTests/fixtures/runtime-preflight/app-entitlements.plist",
                "scripts/context_panel_validation/shared_view_capture.py",
                "scripts/publish-github-release.py",
                "Config/ContextPanelTestLanes.json",
            ]
        )
        self.assertFalse(scope.product)

    def test_one_product_path_among_documentation_runs_the_product_lane(self):
        scope = module.classify(["docs/release.md", "Config/ContextPanel.entitlements"])
        self.assertTrue(scope.product)
        self.assertIn("Config/ContextPanel.entitlements", scope.reason)

    def test_product_inputs_run_the_product_lane(self):
        for path in (
            "Sources/ContextPanelCore/Usage.swift",
            "Tests/ContextPanelCoreTests/UsageTests.swift",
            "Package.swift",
            "project.yml",
            "Config/ContextPanelSurfacePolicy.json",
            "scripts/validate-companion-builds.sh",
            "scripts/stamp-context-panel-build.sh",
            ".github/workflows/ci.yml",
            "a-new-top-level-file",
        ):
            with self.subTest(path=path):
                self.assertTrue(module.classify([path]).product)

    def test_everything_the_xcode_stamp_phase_imports_runs_the_product_lane(self):
        # scripts/stamp-context-panel-build.sh runs the surface manifest in every
        # Xcode target, so whatever that entry point really imports is a build input.
        entry_point = "scripts/context-panel-surface-manifest.py"
        imported = imported_scripts(entry_point)

        self.assertIn("scripts/context_panel_surface_manifest/cli.py", imported)
        for path in [entry_point, *imported]:
            with self.subTest(path=path):
                self.assertTrue(module.classify([path]).product)

    def test_everything_the_reference_jobs_run_runs_the_reference_jobs(self):
        for entry_point in (
            "scripts/context-panel-shared-view-references.py",
            "scripts/context-panel-shared-view-capture-workflow.py",
        ):
            for path in [entry_point, *imported_scripts(entry_point)]:
                with self.subTest(entry_point=entry_point, path=path):
                    self.assertTrue(module.classify([path]).references)

    def test_the_gate_and_the_lane_runner_run_the_product_lane(self):
        for path in ("scripts/ci-change-scope.py", "scripts/context-panel-test-lanes.py"):
            with self.subTest(path=path):
                self.assertTrue(module.classify([path]).product)

    def test_markdown_inside_a_build_input_directory_runs_the_product_lane(self):
        scope = module.classify(["Sources/ContextPanelCore/README.md"])
        self.assertTrue(scope.product)


class ChangedPathsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        git(self.root, "init", "--quiet", "--initial-branch=main")
        self.commit({"docs/a.md": "a\n", "Sources/A.swift": "a\n"}, "base")
        self.base = git(self.root, "rev-parse", "HEAD")

    def commit(self, files: dict[str, str], message: str) -> None:
        for name, content in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        git(self.root, "add", "--all")
        git(self.root, "commit", "--quiet", "--message", message)

    def changed(self, base: str, head: str = "HEAD"):
        with mock.patch.dict(os.environ, fixture_environment(), clear=True):
            return module.changed_paths(base, head, cwd=self.root)

    def test_reports_only_the_branch_side_of_a_diverged_base(self):
        git(self.root, "switch", "--quiet", "--create", "work")
        self.commit({"docs/a.md": "changed\n", "docs/spaced name.md": "new\n"}, "work")
        git(self.root, "switch", "--quiet", "main")
        self.commit({"Sources/A.swift": "main moved\n"}, "main moved")
        moved_base = git(self.root, "rev-parse", "HEAD")
        git(self.root, "switch", "--quiet", "work")

        self.assertEqual(sorted(self.changed(moved_base)), ["docs/a.md", "docs/spaced name.md"])

    def test_a_deleted_swift_file_is_reported(self):
        (self.root / "Sources/A.swift").unlink()
        self.commit({}, "delete")

        self.assertEqual(self.changed(self.base), ["Sources/A.swift"])

    def test_an_unknown_base_is_unknown_rather_than_empty(self):
        self.assertIsNone(self.changed("0" * 40))


class DecideTests(unittest.TestCase):
    """The base each event lands on, against a real fixture repository."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        git(self.root, "init", "--quiet", "--initial-branch=main")
        commit(self.root, {"docs/a.md": "a\n", "Sources/ContextPanelCore/A.swift": "a\n"}, "base")
        self.base = git(self.root, "rev-parse", "HEAD")

    def decide(self, event, ref="refs/heads/main", *, pr_base="", before=""):
        with mock.patch.dict(os.environ, fixture_environment(), clear=True):
            return module.decide(
                event, ref, pr_base=pr_base, before=before, default_branch="main", cwd=self.root
            )

    def push_to_main(self, files):
        commit(self.root, files, "change")
        return self.decide("push", before=self.base)

    def test_a_docs_only_push_skips_product_and_reference_jobs(self):
        scope = self.push_to_main({"docs/a.md": "changed\n", "README.md": "new\n"})
        self.assertEqual((scope.product, scope.references), (False, False))

    def test_an_app_or_core_change_runs_everything(self):
        for path in ("Sources/ContextPanelCore/A.swift", "Sources/ContextPanelApp/App.swift"):
            with self.subTest(path=path):
                scope = self.push_to_main({path: f"{path}\n"})
                self.assertTrue(scope.product)
                self.assertTrue(scope.references)

    def test_simulator_pins_references_and_capture_scripts_run_the_reference_jobs(self):
        for path in (
            "Config/ContextPanelSharedViewSimulators.json",
            "Tests/SharedViewReferences/visionos.app/cell.png",
            "Tests/SharedViewReferences/README.md",
            "scripts/context-panel-shared-view-references.py",
            "scripts/context_panel_validation/shared_view_capture.py",
        ):
            with self.subTest(path=path):
                scope = self.push_to_main({path: f"{path}\n"})
                self.assertTrue(scope.references)

    def test_a_zero_or_missing_before_runs_everything(self):
        commit(self.root, {"docs/a.md": "changed\n"}, "docs")
        for before in ("0" * 40, "", "   "):
            with self.subTest(before=before):
                scope = self.decide("push", before=before)
                self.assertEqual((scope.product, scope.references), (True, True))

    def test_an_unknown_before_runs_everything(self):
        commit(self.root, {"docs/a.md": "changed\n"}, "docs")
        scope = self.decide("push", before="1" * 40)
        self.assertEqual((scope.product, scope.references), (True, True))

    def test_a_train_candidate_compares_with_the_default_branch(self):
        git(self.root, "update-ref", "refs/remotes/origin/main", self.base)
        git(self.root, "switch", "--quiet", "--create", "launchplane/train/batch")
        commit(self.root, {"docs/a.md": "changed\n"}, "first PR")
        commit(self.root, {"docs/b.md": "new\n"}, "second PR")
        ref = "refs/heads/launchplane/train/batch"

        # A new branch has no previous tip; the candidate's whole batch decides.
        self.assertFalse(self.decide("push", ref, before="0" * 40).references)
        commit(self.root, {"Sources/ContextPanelCore/A.swift": "changed\n"}, "third PR")
        self.assertTrue(self.decide("push", ref, before="0" * 40).product)

    def test_a_pull_request_compares_with_its_base(self):
        commit(self.root, {"docs/a.md": "changed\n"}, "docs")
        self.assertFalse(self.decide("pull_request", "refs/pull/1/merge", pr_base=self.base).references)
        self.assertTrue(self.decide("pull_request", "refs/pull/1/merge").product)

    def test_a_manual_run_or_another_branch_runs_everything(self):
        commit(self.root, {"docs/a.md": "changed\n"}, "docs")
        for event, ref in (("workflow_dispatch", "refs/heads/main"), ("push", "refs/heads/other")):
            with self.subTest(event=event, ref=ref):
                scope = self.decide(event, ref, before=self.base)
                self.assertEqual((scope.product, scope.references), (True, True))

    def test_the_nightly_schedule_runs_only_the_reference_jobs(self):
        scope = self.decide("schedule")
        self.assertEqual((scope.product, scope.references), (False, True))
        self.assertTrue(scope.simulator_references)

    def test_pull_requests_and_train_candidates_skip_the_simulator_reference_job(self):
        git(self.root, "update-ref", "refs/remotes/origin/main", self.base)
        commit(self.root, {"Sources/ContextPanelCore/A.swift": "changed\n"}, "product")
        for event, ref, pr_base in (
            ("pull_request", "refs/pull/1/merge", self.base),
            ("pull_request", "refs/pull/1/merge", ""),
            ("push", "refs/heads/launchplane/train/batch", ""),
        ):
            with self.subTest(event=event, ref=ref, pr_base=pr_base):
                scope = self.decide(event, ref, pr_base=pr_base, before="0" * 40)
                self.assertTrue(scope.references)
                self.assertFalse(scope.simulator_references)

    def test_main_pushes_and_manual_runs_keep_the_simulator_reference_job(self):
        commit(self.root, {"Sources/ContextPanelCore/A.swift": "changed\n"}, "product")
        for event, ref in (("push", "refs/heads/main"), ("workflow_dispatch", "refs/heads/reference-check/abc")):
            with self.subTest(event=event, ref=ref):
                self.assertTrue(self.decide(event, ref, before=self.base).simulator_references)


class MainTests(unittest.TestCase):
    def run_main(self, scope):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with (
                mock.patch.object(module, "decide", return_value=scope),
                mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}),
                mock.patch("builtins.print"),
            ):
                self.assertEqual(module.main(["--event", "push", "--ref", "refs/heads/main"]), 0)
            return output.read_text(encoding="utf-8").splitlines()

    def test_writes_the_decision_as_step_outputs(self):
        self.assertEqual(
            self.run_main(module.Scope(False, "docs", references=False)),
            ["product=false", "references=false", "simulator_references=false"],
        )
        self.assertEqual(
            self.run_main(module.Scope(False, "pins", references=True)),
            ["product=false", "references=true", "simulator_references=true"],
        )
        self.assertEqual(
            self.run_main(module.Scope(True, "pull request", references=True, merge_path=True)),
            ["product=true", "references=true", "simulator_references=false"],
        )
        self.assertEqual(
            self.run_main(module.Scope(True, "app", references=True)),
            ["product=true", "references=true", "simulator_references=true"],
        )


if __name__ == "__main__":
    unittest.main()
