import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "ci-reference-failure-issue.py"
SPEC = importlib.util.spec_from_file_location("ci_reference_failure_issue", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class FakeGh:
    """Records gh calls and answers the open-issue search."""

    def __init__(self, open_issues=()):
        self.open_issues = list(open_issues)
        self.calls = []

    def __call__(self, arguments):
        self.calls.append(list(arguments))
        if arguments[:2] == ["issue", "list"]:
            return json.dumps(self.open_issues)
        return ""

    def writes(self):
        return [call for call in self.calls if call[:2] != ["issue", "list"]]


class ReferenceFailureIssueTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.report_path = Path(temporary.name) / "report.json"

    def write_report(self, cells):
        self.report_path.write_text(json.dumps({"cells": cells}), encoding="utf-8")

    def report(self, status, gh):
        return module.report(status, sha="abc123", run_url="https://example.test/run/1", report_path=self.report_path, gh=gh)

    def test_a_failure_with_no_open_issue_opens_one_naming_the_changed_cells(self):
        self.write_report([
            {"surface": "ipados.app", "cell": "stress", "state": "changed", "changedPixels": 12937},
            {"surface": "ios.app", "cell": "baseline", "state": "matched", "changedPixels": 0},
            {"surface": "tvos.app", "cell": "stress", "state": "missing-reference"},
        ])
        gh = FakeGh()
        self.report("failure", gh)
        [create] = gh.writes()
        self.assertEqual(create[:3], ["issue", "create", "--title"])
        self.assertEqual(create[create.index("--title") + 1], module.TITLE)
        body = create[create.index("--body") + 1]
        self.assertIn("- `ipados.app/stress.png`: changed (12937 pixels differ)", body)
        self.assertIn("- `tvos.app/stress.png`: missing-reference", body)
        self.assertNotIn("ios.app/baseline", body)
        self.assertIn("https://example.test/run/1", body)

    def test_the_new_issue_is_a_plan_with_a_clear_wait_record(self):
        self.write_report([{"surface": "ipados.app", "cell": "stress", "state": "changed", "changedPixels": 1}])
        gh = FakeGh()
        self.report("failure", gh)
        [create] = gh.writes()
        self.assertEqual([create[i + 1] for i, value in enumerate(create) if value == "--label"], ["plan", "plan:active"])
        body = create[create.index("--body") + 1]
        marker = body.split("<!-- github-plan:wait ", 1)[1].split(" -->", 1)[0]
        self.assertEqual(json.loads(marker)["state"], "clear")

    def test_a_failure_with_an_open_issue_comments_on_it(self):
        self.write_report([{"surface": "visionos.widget", "cell": "stress", "state": "changed", "changedPixels": 5}])
        gh = FakeGh([{"number": 41, "title": "Something else"}, {"number": 42, "title": module.TITLE}])
        self.report("failure", gh)
        [comment] = gh.writes()
        self.assertEqual(comment[:3], ["issue", "comment", "42"])
        self.assertIn("visionos.widget/stress.png", comment[comment.index("--body") + 1])

    def test_a_failure_without_a_report_says_no_comparison_ran(self):
        gh = FakeGh()
        self.report("failure", gh)
        [create] = gh.writes()
        self.assertIn(module.NO_COMPARISON, create[create.index("--body") + 1])

    def test_a_pass_closes_the_open_issue(self):
        gh = FakeGh([{"number": 42, "title": module.TITLE}])
        self.report("success", gh)
        [close] = gh.writes()
        self.assertEqual(close[:3], ["issue", "close", "42"])
        self.assertIn("abc123", close[close.index("--comment") + 1])

    def test_a_pass_with_no_open_issue_writes_nothing(self):
        gh = FakeGh([{"number": 41, "title": "Something else"}])
        self.report("success", gh)
        self.assertEqual(gh.writes(), [])


if __name__ == "__main__":
    unittest.main()
