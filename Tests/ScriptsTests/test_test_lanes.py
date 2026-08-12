import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "context-panel-test-lanes.py"
SPEC = importlib.util.spec_from_file_location("context_panel_test_lanes", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class TestLaneTests(unittest.TestCase):
    def manifest(self):
        return module.load_manifest()

    def test_current_manifest_maps_every_test_file_exactly_once(self):
        normalized = module.validate_manifest(self.manifest())

        self.assertEqual(
            {path for paths in normalized.values() for path in paths},
            module.discovered_test_files(),
        )

    def test_safe_python_lanes_select_every_python_test_once(self):
        fast = set(module.files_for_lane(self.manifest(), "fast-local-python", require_safe=True))
        routine = set(module.files_for_lane(self.manifest(), "routine-ci-python", require_safe=True))
        expected = {
            path.relative_to(REPO_ROOT).as_posix()
            for path in (REPO_ROOT / "Tests" / "ScriptsTests").glob("test_*.py")
        }

        self.assertFalse(fast & routine)
        self.assertEqual(fast | routine, expected)

    def test_support_files_are_not_selected_for_execution(self):
        payload = self.manifest()
        executable = {
            path
            for lane_name, lane in payload["lanes"].items()
            if lane["role"] == "test"
            for path in module.files_for_lane(payload, lane_name)
        }

        self.assertNotIn(
            "Tests/ContextPanelCoreTests/GoogleAntigravityTestFixtures.swift",
            executable,
        )
        self.assertFalse(any("/fixtures/" in path for path in executable))

    def test_missing_file_mapping_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["routine-ci-swift"] = payload["filesByLane"]["routine-ci-swift"][1:]

        with self.assertRaisesRegex(module.TestLaneError, "unmapped files"):
            module.validate_manifest(payload)

    def test_duplicate_file_mapping_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["fast-local-python"].append(
            payload["filesByLane"]["routine-ci-swift"][0]
        )

        with self.assertRaisesRegex(module.TestLaneError, "duplicate test lane path"):
            module.validate_manifest(payload)

    def test_missing_manifest_path_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["fast-local-python"].append("Tests/missing.py")

        with self.assertRaisesRegex(module.TestLaneError, "manifest paths do not exist"):
            module.validate_manifest(payload)

    def test_unknown_lane_list_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["unknown"] = []

        with self.assertRaisesRegex(module.TestLaneError, "unknown lane lists"):
            module.validate_manifest(payload)

    def test_path_outside_tests_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["fast-local-python"].append("../secret.txt")

        with self.assertRaisesRegex(module.TestLaneError, "remain under Tests"):
            module.validate_manifest(payload)

    def test_manual_lane_requires_justification(self):
        payload = self.manifest()
        path = payload["filesByLane"]["routine-ci-python"].pop()
        payload["filesByLane"]["release-only"].append(path)

        with self.assertRaisesRegex(module.TestLaneError, "requires a justification"):
            module.validate_manifest(payload)

    def test_manual_lane_accepts_documented_special_requirement(self):
        payload = self.manifest()
        path = payload["filesByLane"]["routine-ci-python"].pop()
        payload["filesByLane"]["release-only"].append(path)
        payload["manualLaneJustifications"][path] = "Requires a signed release artifact."

        module.validate_manifest(payload)

    def test_protected_lane_cannot_be_selected_as_safe(self):
        with self.assertRaisesRegex(module.TestLaneError, "not safe for routine CI"):
            module.files_for_lane(self.manifest(), "release-only", require_safe=True)

    def test_time_command_requires_a_swiftpm_lane(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(module.TestLaneError, "does not use the SwiftPM runner"):
                module.time_command(
                    self.manifest(),
                    "fast-local-python",
                    Path(directory) / "report.json",
                    ["true"],
                )

    def test_python_lane_propagates_a_failing_test_exit_code(self):
        completed = module.subprocess.CompletedProcess(
            args=["python3", "-m", "unittest"],
            returncode=7,
        )
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            with (
                mock.patch.object(module, "files_for_lane", return_value=["Tests/failing.py"]),
                mock.patch.object(module.subprocess, "run", return_value=completed),
                mock.patch.object(module, "source_commit", return_value="abc"),
                mock.patch.object(module, "append_summary"),
            ):
                exit_code = module.run_python_lane(
                    self.manifest(),
                    "routine-ci-python",
                    report_path,
                )
                report = json.loads(report_path.read_text())

        self.assertEqual(exit_code, 7)
        self.assertEqual(report["exitCode"], 7)

    def test_report_contains_only_relative_test_paths(self):
        report = {
            "schemaVersion": 1,
            "lane": "routine-ci-python",
            "sourceCommit": "abc",
            "startedAt": "2026-08-12T00:00:00+00:00",
            "runner": {"name": "fixture", "os": "macOS", "arch": "arm64"},
            "files": ["Tests/ScriptsTests/test_test_lanes.py"],
            "durationMs": 1,
            "exitCode": 0,
            "results": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            module.write_report(path, report)
            loaded = json.loads(path.read_text())

        self.assertEqual(loaded["files"], ["Tests/ScriptsTests/test_test_lanes.py"])
        self.assertNotIn(str(REPO_ROOT), json.dumps(loaded))


if __name__ == "__main__":
    unittest.main()
