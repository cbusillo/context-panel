from datetime import datetime, timedelta, timezone
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import app_store_submission_gate as gate

REPOSITORY = "owner/repo"
COMMIT = "a" * 40
OTHER = "b" * 40
PLATFORM = "IOS"
VERSION = "1.0.81"
BUILD = "202611090001"
UPLOADED = datetime(2026, 11, 9, 12, 0, tzinfo=timezone.utc)
AFTER_A_DAY = UPLOADED + timedelta(hours=25)


def ship_record_issue(number, *, commit=COMMIT, platform=PLATFORM, build=BUILD, uploaded=UPLOADED,
                      testflight="success"):
    """A release record shaped the way `app-store-release-status.py record-ship` writes it."""
    record = {
        "platform": platform, "version": VERSION, "buildNumber": build, "sourceCommit": commit,
        "uploadedAt": uploaded.isoformat(), "github": "published", "testflight": testflight,
        "appStore": "App Store submission pending", "runURL": "https://example.invalid/run",
    }
    body = gate.release_status.record_body(REPOSITORY, record)
    return {"number": number, "title": f"App Store submission pending: {platform}", "body": body}


def crash_text(submitted, *, platform=PLATFORM, build=BUILD, kind="crash submission"):
    """One submission as the TestFlight crash watcher files it."""
    return (
        f"An outside tester sent TestFlight {kind}, {platform}, build {build}.\n\n"
        f"Submission category: `betaFeedbackCrashSubmissions`. Submission ID: `s1`. Written feedback: no.\n\n"
        f"Submitted: {submitted}.\n\n[App Store Connect source](https://example.invalid).\n\n"
        "<!-- testflight-build:app:build -->\n<!-- testflight:app:s1 -->\n"
    )


class FakeGitHub:
    """Issues with comments, and CI runs by commit with jobs by name."""

    def __init__(self):
        self.issues = []
        self.comments = {}
        self.runs = []
        self.jobs = {}

    def add_issue(self, issue, comments=()):
        self.issues.append(issue)
        self.comments[issue["number"]] = [
            comment if isinstance(comment, dict) else {"body": comment} for comment in comments
        ]

    def add_crash_issue(self, number, *texts, platform=PLATFORM, build=BUILD):
        self.add_issue(
            {"number": number, "title": f"TestFlight feedback: {platform} build {build}", "body": texts[0]},
            texts[1:],
        )

    def add_run(self, commit, *, event="push", conclusion="success", repository=REPOSITORY,
                path=gate.WORKFLOW_PATH):
        run_id = len(self.runs) + 1
        self.runs.append({
            "id": run_id, "head_sha": commit, "event": event, "path": path,
            "head_repository": {"full_name": repository}, "html_url": f"https://example.invalid/runs/{run_id}",
        })
        self.jobs[run_id] = [
            {"name": "swift", "conclusion": "success"},
            {"name": gate.JOB_NAME, "conclusion": conclusion, "html_url": f"https://example.invalid/runs/{run_id}/job"},
        ]

    def __call__(self, path):
        if "/actions/workflows/" in path:
            commit = path.split("head_sha=")[1].split("&")[0]
            return {"workflow_runs": [run for run in self.runs if run["head_sha"] == commit]}
        if "/actions/runs/" in path:
            run_id = int(path.split("/actions/runs/")[1].split("/")[0])
            attempts = self.jobs[run_id] if isinstance(self.jobs[run_id][0], list) else [self.jobs[run_id]]
            # GitHub lists only the latest attempt unless asked for all of them.
            if "filter=all" in path:
                return {"jobs": [job for attempt in attempts for job in attempt]}
            return {"jobs": attempts[-1]}
        page = int(path.rsplit("page=", 1)[1])
        if "/comments" in path:
            number = int(path.split("/issues/")[1].split("/")[0])
            items = self.comments[number]
        else:
            items = self.issues
        return json.loads(json.dumps(items[(page - 1) * 100:page * 100]))


def ready_github():
    github = FakeGitHub()
    github.add_issue(ship_record_issue(1))
    github.add_run(COMMIT)
    return github


def check(github, *, now=AFTER_A_DAY, override=""):
    return gate.check(PLATFORM, VERSION, BUILD, now=now, repository=REPOSITORY, fetch_json=github,
                      override_reason=override)


class ReferenceJobTests(unittest.TestCase):
    def test_a_passing_job_on_the_release_commit_is_required(self):
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                github = FakeGitHub()
                github.add_issue(ship_record_issue(1))
                github.add_run(COMMIT, event=event)
                readiness = check(github)
                self.assertEqual(readiness.blockers, ())
                self.assertEqual(readiness.reference_runs, ((COMMIT, "https://example.invalid/runs/1/job"),))

    def test_a_pass_in_an_earlier_attempt_counts_after_rerunning_other_jobs(self):
        github = ready_github()
        github.jobs[1] = [github.jobs[1], [{"name": "swift-tests", "conclusion": "success"}]]
        self.assertEqual(check(github).blockers, ())

    def test_runs_that_do_not_prove_the_commit_block_and_say_how_to_get_one(self):
        cases = (
            {"conclusion": "skipped"}, {"conclusion": "failure"}, {"event": "pull_request"},
            {"repository": "someone/fork"}, {"path": ".github/workflows/other.yml"},
        )
        for options in cases:
            with self.subTest(options=options):
                github = FakeGitHub()
                github.add_issue(ship_record_issue(1))
                github.add_run(COMMIT, **options)
                github.add_run(OTHER)
                (blocker,) = check(github).blockers
                self.assertIn(COMMIT, blocker)
                self.assertIn(f"git push origin {COMMIT}:refs/heads/reference-check/", blocker)

    def test_the_override_never_skips_the_reference_job(self):
        github = FakeGitHub()
        github.add_issue(ship_record_issue(1))
        self.assertEqual(len(check(github, override="ship it").blockers), 1)

    def test_every_recorded_source_commit_needs_its_own_run(self):
        github = ready_github()
        github.add_issue(ship_record_issue(2, commit=OTHER))
        (blocker,) = check(github).blockers
        self.assertIn(OTHER, blocker)

    def test_a_build_without_a_ship_record_is_unknown(self):
        github = FakeGitHub()
        github.add_issue(ship_record_issue(1, platform="TV_OS"))
        github.add_run(COMMIT)
        with self.assertRaises(gate.SubmissionGateError):
            check(github)


class TestFlightDayTests(unittest.TestCase):
    def test_a_build_on_testflight_for_less_than_a_day_waits(self):
        (blocker,) = check(ready_github(), now=UPLOADED + timedelta(hours=23)).blockers
        self.assertIn("first day ends", blocker)

    def test_a_crash_submission_in_the_first_day_blocks(self):
        github = ready_github()
        github.add_crash_issue(5, crash_text("2026-11-09T18:30:00.123Z"))
        (blocker,) = check(github).blockers
        self.assertIn("crash submission", blocker)

    def test_a_crash_reported_in_a_comment_on_the_build_issue_blocks(self):
        github = ready_github()
        github.add_crash_issue(5, crash_text("2026-11-09T18:30:00Z", kind="screenshot feedback"),
                               crash_text("2026-11-09T19:00:00Z"))
        self.assertEqual(len(check(github).blockers), 1)

    def test_an_unreadable_crash_time_blocks(self):
        github = ready_github()
        github.add_crash_issue(5, crash_text("UNKNOWN"))
        self.assertEqual(len(check(github).blockers), 1)

    def test_feedback_and_crashes_for_other_builds_do_not_block(self):
        github = ready_github()
        github.add_crash_issue(5, crash_text("2026-11-09T18:30:00Z", kind="screenshot feedback"))
        github.add_crash_issue(6, crash_text("2026-11-09T18:30:00Z", build="202611080001"), build="202611080001")
        github.add_crash_issue(7, crash_text("2026-11-09T18:30:00Z", platform="TV_OS"), platform="TV_OS")
        self.assertEqual(check(github).blockers, ())

    def test_a_crash_after_the_first_day_is_noted_not_blocking(self):
        github = ready_github()
        github.add_crash_issue(5, crash_text("2026-11-10T13:00:00Z"))
        readiness = check(github, now=UPLOADED + timedelta(hours=30))
        self.assertEqual(readiness.blockers, ())
        self.assertEqual(len(readiness.notes), 1)

    def test_a_build_ship_never_put_on_testflight_waits(self):
        for testflight in ("failure", "not selected"):
            with self.subTest(testflight=testflight):
                github = FakeGitHub()
                github.add_issue(ship_record_issue(1, testflight=testflight))
                github.add_run(COMMIT)
                (blocker,) = check(github, now=UPLOADED + timedelta(days=3)).blockers
                self.assertIn("has not started", blocker)
                self.assertEqual(check(github, override="Chris installed it").blockers, ())

    def test_a_retried_testflight_distribution_starts_the_day_when_it_succeeds(self):
        retried = UPLOADED + timedelta(hours=5)
        comment = {
            "created_at": retried.isoformat(),
            "body": gate.release_status.marker(
                gate.release_status.CHANNELS, {"github": "published", "testflight": "success", "upload": "success"}
            ),
        }
        github = FakeGitHub()
        github.add_issue(ship_record_issue(1, testflight="failure"), [comment])
        github.add_run(COMMIT)
        self.assertEqual(len(check(github, now=UPLOADED + timedelta(hours=26)).blockers), 1)
        self.assertEqual(check(github, now=retried + timedelta(hours=25)).blockers, ())

    def test_a_retitled_watcher_issue_still_blocks(self):
        github = ready_github()
        github.add_issue({"number": 5, "title": "Watch app crashes on launch", "body": crash_text("2026-11-09T18:30:00Z")})
        self.assertEqual(len(check(github).blockers), 1)

    def test_the_override_skips_the_wait_and_a_crash_and_records_what_it_skipped(self):
        github = ready_github()
        github.add_crash_issue(5, crash_text("2026-11-09T13:00:00Z"))
        readiness = check(github, now=UPLOADED + timedelta(hours=2), override="Chris tested it")
        self.assertEqual(readiness.blockers, ())
        self.assertEqual(len(readiness.waived), 2)


if __name__ == "__main__":
    unittest.main()
