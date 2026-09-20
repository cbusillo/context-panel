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


FIXTURE_FILES = {
    "Tests/ScriptsTests/test_fast.py",
    "Tests/ScriptsTests/test_routine.py",
    "Tests/CoreTests/FirstTests.swift",
    "Tests/CoreTests/SecondTests.swift",
    "Tests/CoreTests/TestFixtures.swift",
    "Tests/ScriptsTests/fixtures/profile.plist",
}


def lane(runner: str, ci_policy: str, role: str = "test") -> dict[str, str]:
    return {"runner": runner, "ciPolicy": ci_policy, "role": role}


class TestLaneTests(unittest.TestCase):
    def manifest(self):
        return {
            "schemaVersion": 1,
            "lanes": {
                "fast-local-python": lane("python-unittest", "safe"),
                "routine-ci-python": lane("python-unittest", "safe"),
                "routine-ci-swift": lane("swiftpm", "safe"),
                "release-only": lane("manual", "trusted-only"),
                "support-only": lane("none", "never", "support"),
            },
            "filesByLane": {
                "fast-local-python": ["Tests/ScriptsTests/test_fast.py"],
                "routine-ci-python": ["Tests/ScriptsTests/test_routine.py"],
                "routine-ci-swift": [
                    "Tests/CoreTests/FirstTests.swift",
                    "Tests/CoreTests/SecondTests.swift",
                ],
                "release-only": [],
                "support-only": [
                    "Tests/CoreTests/TestFixtures.swift",
                    "Tests/ScriptsTests/fixtures/profile.plist",
                ],
            },
            "manualLaneJustifications": {},
        }

    def validate(self, payload):
        return module.validate_manifest(payload, discovered=set(FIXTURE_FILES))

    def test_fixture_manifest_is_valid(self):
        normalized = self.validate(self.manifest())

        self.assertEqual(
            normalized["routine-ci-swift"],
            ["Tests/CoreTests/FirstTests.swift", "Tests/CoreTests/SecondTests.swift"],
        )

    def pattern_manifest(self):
        manifest = self.manifest()
        manifest["filesByLane"]["routine-ci-swift"] = []
        manifest["filesByLane"]["support-only"] = ["Tests/CoreTests/TestFixtures.swift"]
        manifest["patternsByLane"] = {
            "routine-ci-swift": ["Tests/CoreTests/*.swift"],
            "support-only": ["Tests/ScriptsTests/fixtures/**"],
        }
        return manifest

    def test_patterns_claim_unlisted_files_and_an_explicit_listing_wins(self):
        normalized = self.validate(self.pattern_manifest())

        self.assertEqual(
            normalized["routine-ci-swift"],
            ["Tests/CoreTests/FirstTests.swift", "Tests/CoreTests/SecondTests.swift"],
        )
        self.assertEqual(
            normalized["support-only"],
            ["Tests/CoreTests/TestFixtures.swift", "Tests/ScriptsTests/fixtures/profile.plist"],
        )

    def test_a_new_swift_test_or_nested_fixture_needs_no_manifest_edit(self):
        added = {"Tests/CoreTests/ThirdTests.swift", "Tests/ScriptsTests/fixtures/nested/deep/profile.plist"}

        normalized = module.validate_manifest(self.pattern_manifest(), discovered=FIXTURE_FILES | added)

        self.assertIn("Tests/CoreTests/ThirdTests.swift", normalized["routine-ci-swift"])
        self.assertIn("Tests/ScriptsTests/fixtures/nested/deep/profile.plist", normalized["support-only"])

    def test_a_new_python_test_still_fails_closed_under_patterns(self):
        for path in ("Tests/ScriptsTests/test_new.py", "Tests/ScriptsTests/fixtures/test_hidden.py"):
            with self.subTest(path=path), self.assertRaises(module.TestLaneError) as raised:
                module.validate_manifest(self.pattern_manifest(), discovered=FIXTURE_FILES | {path})
            self.assertIn(path, str(raised.exception))

    def test_a_star_does_not_cross_directories(self):
        manifest = self.pattern_manifest()
        manifest["patternsByLane"]["routine-ci-swift"] = ["Tests/*.swift"]

        with self.assertRaisesRegex(module.TestLaneError, "matches no unlisted file: Tests/\\*.swift"):
            self.validate(manifest)

    def test_python_and_manual_lanes_cannot_use_patterns(self):
        for lane_name in ("routine-ci-python", "release-only"):
            with self.subTest(lane=lane_name):
                manifest = self.pattern_manifest()
                manifest["patternsByLane"][lane_name] = ["Tests/ScriptsTests/test_*.py"]
                with self.assertRaisesRegex(module.TestLaneError, f"must list its files explicitly: {lane_name}"):
                    self.validate(manifest)

    def test_a_file_claimed_by_two_lanes_fails_closed(self):
        manifest = self.pattern_manifest()
        manifest["patternsByLane"]["support-only"].append("Tests/CoreTests/First*.swift")

        with self.assertRaisesRegex(module.TestLaneError, "more than one lane: Tests/CoreTests/FirstTests.swift"):
            self.validate(manifest)

    def test_a_pattern_outside_tests_or_for_an_unknown_lane_fails_closed(self):
        for lane_name, pattern, message in (
            ("routine-ci-swift", "Sources/**", "must remain under Tests/"),
            ("routine-ci-swift", "Tests/../Sources/**", "must remain under Tests/"),
            ("no-such-lane", "Tests/**", "unknown lane"),
        ):
            with self.subTest(pattern=pattern):
                manifest = self.pattern_manifest()
                manifest["patternsByLane"][lane_name] = [pattern]
                with self.assertRaisesRegex(module.TestLaneError, message):
                    self.validate(manifest)

    def test_unmapped_discovered_file_fails_closed(self):
        with self.assertRaisesRegex(module.TestLaneError, "unmapped files under Tests/: Tests/new_test.py"):
            module.validate_manifest(
                self.manifest(),
                discovered=FIXTURE_FILES | {"Tests/new_test.py"},
            )

    def test_python_test_parked_in_the_support_lane_fails_closed(self):
        payload = self.manifest()
        path = payload["filesByLane"]["routine-ci-python"].pop()
        payload["filesByLane"]["support-only"].append(path)

        with self.assertRaisesRegex(module.TestLaneError, "must run in a safe python-unittest lane"):
            self.validate(payload)

    def test_python_test_in_the_swift_lane_fails_closed(self):
        payload = self.manifest()
        path = payload["filesByLane"]["fast-local-python"].pop()
        payload["filesByLane"]["routine-ci-swift"].append(path)

        with self.assertRaisesRegex(module.TestLaneError, "must run in a safe python-unittest lane"):
            self.validate(payload)

    def test_support_files_are_not_selected_for_execution(self):
        payload = self.manifest()
        executable = {
            path
            for lane_name in payload["lanes"]
            for path in module.files_for_lane(payload, lane_name, discovered=set(FIXTURE_FILES))
        }

        self.assertEqual(executable, FIXTURE_FILES - set(payload["filesByLane"]["support-only"]))

    def test_missing_file_mapping_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["routine-ci-swift"] = payload["filesByLane"]["routine-ci-swift"][1:]

        with self.assertRaisesRegex(module.TestLaneError, "unmapped files"):
            self.validate(payload)

    def test_duplicate_file_mapping_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["fast-local-python"].append(
            payload["filesByLane"]["routine-ci-swift"][0]
        )

        with self.assertRaisesRegex(module.TestLaneError, "duplicate test lane path"):
            self.validate(payload)

    def test_missing_manifest_path_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["fast-local-python"].append("Tests/missing.py")

        with self.assertRaisesRegex(module.TestLaneError, "manifest paths do not exist"):
            self.validate(payload)

    def test_unknown_lane_list_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["unknown"] = []

        with self.assertRaisesRegex(module.TestLaneError, "unknown lane lists"):
            self.validate(payload)

    def test_path_outside_tests_fails_closed(self):
        payload = self.manifest()
        payload["filesByLane"]["fast-local-python"].append("../secret.txt")

        with self.assertRaisesRegex(module.TestLaneError, "remain under Tests"):
            self.validate(payload)

    def test_manual_lane_requires_justification(self):
        payload = self.manifest()
        path = payload["filesByLane"]["routine-ci-python"].pop()
        payload["filesByLane"]["release-only"].append(path)

        with self.assertRaisesRegex(module.TestLaneError, "requires a justification"):
            self.validate(payload)

    def test_manual_lane_accepts_documented_special_requirement(self):
        payload = self.manifest()
        path = payload["filesByLane"]["routine-ci-python"].pop()
        payload["filesByLane"]["release-only"].append(path)
        payload["manualLaneJustifications"][path] = "Requires a signed release artifact."

        self.validate(payload)

    def test_a_manifest_the_commit_gate_would_refuse_fails_validation(self):
        for field, value in (("ciPolicy", "trusted-only"), ("runner", "python-unittest")):
            with self.subTest(field=field):
                manifest = self.manifest()
                manifest["lanes"]["routine-ci-swift"][field] = value
                with self.assertRaisesRegex(module.TestLaneError, "commit gate's routine-ci-swift lane"):
                    self.validate(manifest)

    def test_protected_lane_cannot_be_selected_as_safe(self):
        with self.assertRaisesRegex(module.TestLaneError, "not safe for routine CI"):
            module.files_for_lane(
                self.manifest(),
                "release-only",
                require_safe=True,
                discovered=set(FIXTURE_FILES),
            )

    def test_time_command_requires_a_swiftpm_lane(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(module, "discovered_test_files", return_value=set(FIXTURE_FILES)),
        ):
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
