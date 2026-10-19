import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import shared_view_reference_gate as gate

REPOSITORY = "owner/repo"
COMMIT = "a" * 40
OTHER = "b" * 40


def manifest(*commits):
    return {"artifacts": [{"artifactId": f"app-{index}", "sourceCommit": c} for index, c in enumerate(commits)]}


class FakeGitHub:
    """CI runs by commit; each run has jobs by name with a conclusion."""

    def __init__(self):
        self.runs = []
        self.jobs = {}

    def add_run(self, commit, *, event="push", conclusion="success", repository=REPOSITORY,
                path=gate.WORKFLOW_PATH):
        run_id = len(self.runs) + 1
        self.runs.append(
            {
                "id": run_id,
                "head_sha": commit,
                "event": event,
                "path": path,
                "head_repository": {"full_name": repository},
                "html_url": f"https://example.invalid/runs/{run_id}",
            }
        )
        self.jobs[run_id] = [
            {"name": "swift", "conclusion": "success"},
            {
                "name": gate.JOB_NAME,
                "conclusion": conclusion,
                "html_url": f"https://example.invalid/runs/{run_id}/job",
            },
        ]

    def __call__(self, path):
        if "/actions/workflows/" in path:
            commit = path.split("head_sha=")[1].split("&")[0]
            return {"workflow_runs": [run for run in self.runs if run["head_sha"] == commit]}
        run_id = int(path.split("/actions/runs/")[1].split("/")[0])
        attempts = self.jobs[run_id] if isinstance(self.jobs[run_id][0], list) else [self.jobs[run_id]]
        # GitHub lists only the latest attempt unless asked for all of them.
        if "filter=all" in path:
            return {"jobs": [job for attempt in attempts for job in attempt]}
        return {"jobs": attempts[-1]}


class RequireReferenceRunsTests(unittest.TestCase):
    @staticmethod
    def require(github, *manifests):
        return gate.require_reference_runs(manifests or (manifest(COMMIT),), repository=REPOSITORY,
                                           fetch_json=github)

    def test_a_passing_job_on_the_exact_commit_is_accepted(self):
        for event in ("push", "workflow_dispatch", "schedule"):
            with self.subTest(event=event):
                github = FakeGitHub()
                github.add_run(COMMIT, event=event)
                self.assertEqual(self.require(github), [(COMMIT, "https://example.invalid/runs/1/job")])

    def test_a_pass_in_an_earlier_attempt_counts_after_rerunning_other_jobs(self):
        github = FakeGitHub()
        github.add_run(COMMIT)
        first_attempt = github.jobs[1]
        github.jobs[1] = [first_attempt, [{"name": "swift-tests", "conclusion": "success"}]]
        self.assertEqual(self.require(github), [(COMMIT, "https://example.invalid/runs/1/job")])

    def test_no_run_refuses_and_says_how_to_get_one(self):
        github = FakeGitHub()
        github.add_run(OTHER)
        with self.assertRaises(gate.ReferenceRunError) as raised:
            self.require(github)
        message = str(raised.exception)
        self.assertIn(COMMIT, message)
        self.assertIn(f"git push origin {COMMIT}:refs/heads/reference-check/", message)
        self.assertIn("gh workflow run ci.yml --ref reference-check/", message)

    def test_a_skipped_failed_or_cancelled_job_does_not_count(self):
        for conclusion in ("skipped", "failure", "cancelled"):
            with self.subTest(conclusion=conclusion):
                github = FakeGitHub()
                github.add_run(COMMIT, conclusion=conclusion)
                with self.assertRaises(gate.ReferenceRunError):
                    self.require(github)

    def test_a_pull_request_run_does_not_prove_the_commit(self):
        github = FakeGitHub()
        github.add_run(COMMIT, event="pull_request")
        with self.assertRaises(gate.ReferenceRunError):
            self.require(github)

    def test_a_run_from_a_fork_or_another_workflow_does_not_count(self):
        for options in ({"repository": "someone/fork"}, {"path": ".github/workflows/other.yml"}):
            with self.subTest(options=options):
                github = FakeGitHub()
                github.add_run(COMMIT, **options)
                with self.assertRaises(gate.ReferenceRunError):
                    self.require(github)

    def test_every_source_commit_needs_its_own_run(self):
        github = FakeGitHub()
        github.add_run(COMMIT)
        with self.assertRaises(gate.ReferenceRunError) as raised:
            self.require(github, manifest(COMMIT), manifest(OTHER))
        self.assertIn(OTHER, str(raised.exception))
        self.assertNotIn(f"- {COMMIT}", str(raised.exception))

        github.add_run(OTHER)
        self.assertEqual([commit for commit, _ in self.require(github, manifest(COMMIT), manifest(OTHER))],
                         [COMMIT, OTHER])

    def test_a_manifest_without_a_full_source_commit_refuses(self):
        github = FakeGitHub()
        for bad in ({"artifacts": []}, manifest("abc123"), {"artifacts": [{}]}):
            with self.subTest(bad=bad), self.assertRaises(gate.ReferenceRunError):
                self.require(github, bad)


if __name__ == "__main__":
    unittest.main()
