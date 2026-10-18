import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cloudkit_schema_gate", REPO_ROOT / "scripts/cloudkit-schema-gate.py")
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = gate
SPEC.loader.exec_module(gate)


class CloudKitSchemaGateTests(unittest.TestCase):
    """A fake validator stands in for the live Production export."""

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name) / "repo"
        self.marker = Path(directory.name) / "validator-ran"
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        (self.repo / "CloudKit").mkdir(parents=True)
        (self.repo / "scripts").mkdir()
        (self.repo / "CloudKit/companion-sync.schema.json").write_text("{}\n")
        self.write_validator(exit_code=0)
        (self.repo / "README.md").write_text("product\n")
        self.git("init", "--quiet", "--initial-branch", "main")
        self.commit("first release")

    def write_validator(self, *, exit_code: int) -> None:
        validator = self.repo / "scripts/validate-cloudkit-companion-schema.sh"
        validator.write_text(f'printf \'%s\\n\' "$*" > "{self.marker}"\nexit {exit_code}\n')

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", *arguments], cwd=self.repo, env=self.environment,
            text=True, capture_output=True, check=True,
        ).stdout

    def commit(self, message: str) -> None:
        self.git("add", "--all")
        self.git(
            "-c", "user.name=Gate fixture", "-c", "user.email=fixture@context-panel.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "--quiet", "--message", message,
        )

    def edit(self, relative: str, text: str) -> None:
        path = self.repo / relative
        path.write_text(path.read_text() + text)
        self.commit(f"edit {relative}")

    def run_gate(self) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            mock.patch.dict(os.environ, self.environment, clear=True),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            code = gate.main(["check", "--repo", str(self.repo)])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_unchanged_contract_since_release_skips_the_live_check(self) -> None:
        self.git("tag", "v1.0.0")
        self.edit("README.md", "more product\n")

        code, stdout, _ = self.run_gate()

        self.assertEqual(code, 0)
        self.assertIn("unchanged since v1.0.0", stdout)
        self.assertFalse(self.marker.exists())

    def test_changed_contract_runs_the_live_production_check(self) -> None:
        self.git("tag", "v1.0.0")
        self.edit("CloudKit/companion-sync.schema.json", "\n")

        code, stdout, _ = self.run_gate()

        self.assertEqual(code, 0)
        self.assertIn("changed since v1.0.0", stdout)
        self.assertEqual(self.marker.read_text().split(), ["--live", "--environment", "production"])

    def test_failed_live_check_refuses(self) -> None:
        self.git("tag", "v1.0.0")
        self.write_validator(exit_code=77)
        self.edit("CloudKit/companion-sync.schema.json", "\n")

        code, _, stderr = self.run_gate()

        self.assertEqual(code, 1)
        self.assertIn("refused", stderr)
        self.assertTrue(self.marker.exists())

    def test_no_reachable_release_requires_the_live_check(self) -> None:
        self.git("checkout", "--quiet", "-b", "side")
        self.edit("README.md", "side\n")
        self.git("tag", "v9.0.0")
        self.git("tag", "v2026.06.06-2dfe1b3", "main")
        self.git("checkout", "--quiet", "main")
        self.write_validator(exit_code=1)

        code, stdout, _ = self.run_gate()

        self.assertEqual(code, 1)
        self.assertIn("no release tag is reachable", stdout)

    def test_newest_release_by_version_is_the_baseline(self) -> None:
        self.git("tag", "v1.0.9")
        self.edit("CloudKit/companion-sync.schema.json", "\n")
        self.git("tag", "v1.0.10")
        self.edit("README.md", "later product\n")

        code, stdout, _ = self.run_gate()

        self.assertEqual(code, 0)
        self.assertIn("unchanged since v1.0.10", stdout)
        self.assertFalse(self.marker.exists())

    def test_unreadable_history_refuses_without_a_live_check(self) -> None:
        (self.repo / ".git").rename(self.repo / "not-git")

        code, _, stderr = self.run_gate()

        self.assertEqual(code, 1)
        self.assertIn("release history is unavailable", stderr)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
