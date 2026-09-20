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


def git(root: Path, *args: str) -> str:
    environment = {
        **os.environ,
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


class ClassifyTests(unittest.TestCase):
    def test_unknown_changes_run_everything(self):
        for paths in (None, []):
            scope = module.classify(paths)
            self.assertTrue(scope.product)
            self.assertTrue(scope.codeql)

    def test_documentation_and_validation_tooling_skip_both(self):
        scope = module.classify(
            [
                "docs/release.md",
                "AGENTS.md",
                "Tests/ScriptsTests/test_shared_view_capture.py",
                "Tests/ScriptsTests/fixtures/runtime-preflight/app-entitlements.plist",
                "scripts/context_panel_validation/shared_view_capture.py",
                "scripts/publish-github-release.py",
            ]
        )
        self.assertFalse(scope.product)
        self.assertFalse(scope.codeql)

    def test_one_product_path_among_documentation_runs_the_product_lane(self):
        scope = module.classify(["docs/release.md", "Config/ContextPanel.entitlements"])
        self.assertTrue(scope.product)
        self.assertIn("Config/ContextPanel.entitlements", scope.product_reason)
        self.assertFalse(scope.codeql)

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

    def test_python_the_build_or_the_gate_executes_runs_the_product_lane(self):
        for path in (
            "scripts/ci-change-scope.py",
            "scripts/context-panel-surface-manifest.py",
            "scripts/context_panel_surface_manifest/core.py",
            "scripts/context-panel-test-lanes.py",
        ):
            with self.subTest(path=path):
                self.assertTrue(module.classify([path]).product)

    def test_swift_and_analysis_configuration_run_codeql(self):
        for path in (
            "Sources/ContextPanelCore/Usage.swift",
            "Tools/ContextPanelSharedViewRenderer/main.swift",
            "Tests/ContextPanelCoreTests/UsageTests.swift",
            "Package.swift",
            "Package.resolved",
            ".github/workflows/codeql.yml",
            "scripts/ci-change-scope.py",
        ):
            with self.subTest(path=path):
                self.assertTrue(module.classify([path]).codeql)

    def test_product_changes_without_swift_skip_only_codeql(self):
        scope = module.classify(["project.yml", "scripts/validate-companion-builds.sh"])
        self.assertTrue(scope.product)
        self.assertFalse(scope.codeql)

    def test_markdown_inside_a_build_input_directory_runs_everything(self):
        scope = module.classify(["Sources/ContextPanelCore/README.md"])
        self.assertTrue(scope.product)
        self.assertTrue(scope.codeql)


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
        previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        return module.changed_paths(base, head)

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


class MainTests(unittest.TestCase):
    def run_main(self, paths):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with (
                mock.patch.object(module, "changed_paths", return_value=paths),
                mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}),
                mock.patch("builtins.print"),
            ):
                self.assertEqual(module.main(["--base", "abc"]), 0)
            return output.read_text(encoding="utf-8").splitlines()

    def test_writes_both_decisions_as_step_outputs(self):
        self.assertEqual(self.run_main(["docs/a.md"]), ["product=false", "codeql=false"])
        self.assertEqual(self.run_main(["project.yml"]), ["product=true", "codeql=false"])
        self.assertEqual(self.run_main(None), ["product=true", "codeql=true"])


if __name__ == "__main__":
    unittest.main()
