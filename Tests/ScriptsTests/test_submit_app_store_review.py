import importlib.util
import io
import json
import tempfile
import time
import unittest
import urllib.error
import sys
from unittest.mock import patch
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from typing import Any


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "submit-app-store-review.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("submit_app_store_review", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
submit_app_store_review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(submit_app_store_review)


def assert_review_submission_submit_body(test_case, patch_body):
    test_case.assertEqual(patch_body["data"]["attributes"], {"submitted": True})
    test_case.assertNotIn("relationships", patch_body["data"])


def valid_build(
    build_id="build-1",
    state="VALID",
    uses_non_exempt_encryption=None,
    platform="MAC_OS",
    marketing_version="1.0.39",
):
    return {
        "data": [
            {
                "id": build_id,
                "attributes": {
                    "processingState": state,
                    "usesNonExemptEncryption": uses_non_exempt_encryption,
                },
                "relationships": {
                    "preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "prerelease-1"}}
                },
            }
        ],
        "included": [
            {
                "id": "prerelease-1",
                "type": "preReleaseVersions",
                "attributes": {"platform": platform, "version": marketing_version},
            }
        ],
    }


def build_payload(builds):
    data = []
    included = []
    for build in builds:
        build_id = build.get("build_id", f"build-{len(data) + 1}")
        pre_release_id = build.get("pre_release_id", f"prerelease-{len(included) + 1}")
        data.append(
            {
                "id": build_id,
                "attributes": {
                    "processingState": build.get("state", "VALID"),
                    "usesNonExemptEncryption": build.get("uses_non_exempt_encryption"),
                },
                "relationships": {
                    "preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": pre_release_id}}
                },
            }
        )
        included.append(
            {
                "id": pre_release_id,
                "type": "preReleaseVersions",
                "attributes": {
                    "platform": build.get("platform", "MAC_OS"),
                    "version": build.get("marketing_version", "1.0.39"),
                },
            }
        )
    return {"data": data, "included": included}


def exact_build_validation_report(platform="MAC_OS"):
    required_surfaces = sorted(
        submit_app_store_review.REQUIRED_RUNTIME_SURFACES_BY_PLATFORM[platform]
    )
    return {
        "schemaVersion": 1,
        "target": {"version": "1.0.39", "buildNumber": "202608050001"},
        "summary": {
            "state": "complete_for_slice",
            "stage": "exact-build runtime proven",
            "headline": "fixture",
            "exitCode": 0,
        },
        "session": {
            "lifecycle": "active",
            "revision": 2,
            "requestedSurfaces": required_surfaces,
        },
        "requiredEvidenceClasses": [],
        "obtainedEvidenceClasses": {
            "appStoreConnect": "available",
            "canonicalMacProductionRuntime": "proven",
            "exactBuildRuntimeReceipts": {
                "state": "proven",
                "proven": len(required_surfaces),
                "required": len(required_surfaces),
                "runtimeSessionResult": "healthy",
                "diagnostics": [],
            },
            "watchRestartAttestation": "recorded" if platform == "IOS" else "not-required",
            "visualApproval": "not-evaluated-by-coordinator",
        },
        "runtimeSurfaces": [
            {
                "surface": surface,
                "state": "proven",
                "reason": "exact-build-runtime-receipt",
            }
            for surface in required_surfaces
        ],
        "operatorFlow": {
            "schemaVersion": 1,
            "state": "complete",
            "readyActionCount": 0,
            "deferredActionCount": 0,
            "groups": [],
            "notificationDecisions": [],
            "deferrals": [],
            "activeDeferrals": [],
            "residualRisks": [],
            "runtimeDiagnostics": [],
        },
        "blockers": [],
        "residualRisks": ["review-pending"],
        "limitations": ["Visual approval is not evaluated by this coordinator slice."],
    }


class ValidationReportGateTests(unittest.TestCase):
    def live_args(self, **overrides):
        values = {
            "validate_report_only": False,
            "dry_run": False,
            "cancel_review_only": False,
            "prepare_only": False,
            "remove_active_review_version": None,
            "build_number": "202608050001",
            "whats_new": "Validation update",
            "platform": "MAC_OS",
            "tvos_demo_video_url": None,
            "validation_report": "final-report.json",
            "validation_train": "release",
            "release_evidence_mode": "shadow",
            "release_evidence_report": "release-evidence.json",
            "release_evidence_comparison": "comparison.json",
            "release_evidence_expected_build_manifests": ["expected.json"],
            "release_evidence_policy": "Config/ContextPanelReleaseEvidencePolicy.json",
            "release_evidence_surface_policy": "Config/ContextPanelSurfacePolicy.json",
            "release_evidence_previous_ledger": None,
            "release_evidence_selected_rc_ledger": "selected-rc.json",
            "release_evidence_host_os_evidence": None,
            "release_evidence_historical_policy_archives": None,
        }
        values.update(overrides)
        return SimpleNamespace(**values)

    def test_accepts_exact_runtime_evidence_for_every_app_store_platform(self):
        for platform in submit_app_store_review.REQUIRED_RUNTIME_SURFACES_BY_PLATFORM:
            with self.subTest(platform=platform):
                blockers = submit_app_store_review.validation_report_blockers(
                    exact_build_validation_report(platform),
                    version="1.0.39",
                    build_number="202608050001",
                    platform=platform,
                )

                self.assertEqual(blockers, [])

    def test_rejects_target_mismatch_and_unproven_runtime_surface(self):
        report = exact_build_validation_report("TV_OS")
        report["runtimeSurfaces"][0]["state"] = "waiting"

        blockers = submit_app_store_review.validation_report_blockers(
            report,
            version="1.0.40",
            build_number="202608050002",
            platform="TV_OS",
        )

        self.assertIn("target version must be 1.0.40", blockers)
        self.assertIn("target build number must be 202608050002", blockers)
        self.assertTrue(any("is not proven" in blocker for blocker in blockers))

    def test_rejects_report_for_another_platform(self):
        blockers = submit_app_store_review.validation_report_blockers(
            exact_build_validation_report("MAC_OS"),
            version="1.0.39",
            build_number="202608050001",
            platform="IOS",
        )

        self.assertTrue(any("IOS validation is missing required surfaces" in item for item in blockers))
        self.assertIn("the physical Watch restart attestation must be recorded", blockers)

    @staticmethod
    def scoped_report(platform: str, surfaces: set[str]) -> dict:
        report = exact_build_validation_report(platform)
        report["session"]["requestedSurfaces"] = sorted(surfaces)
        report["runtimeSurfaces"] = [
            {"surface": surface, "state": "proven", "reason": "exact-build-runtime-receipt"}
            for surface in sorted(surfaces)
        ]
        receipts = report["obtainedEvidenceClasses"]["exactBuildRuntimeReceipts"]
        receipts["proven"] = receipts["required"] = len(surfaces)
        if not surfaces:
            receipts["runtimeSessionResult"] = None
        if not any(surface.startswith("watchos.") for surface in surfaces):
            report["obtainedEvidenceClasses"]["watchRestartAttestation"] = "not-required"
        return report

    def test_comparison_limits_runtime_proof_to_changed_surfaces(self) -> None:
        changed = frozenset({"ios.app", "ipados.app", "macos.app"})
        blockers = submit_app_store_review.validation_report_blockers(
            self.scoped_report("IOS", {"ios.app", "ipados.app", "macos.app"}),
            version="1.0.39",
            build_number="202608050001",
            platform="IOS",
            comparison_runtime_surfaces=changed,
        )

        self.assertEqual(blockers, [])

    def test_comparison_scope_still_requires_every_changed_platform_surface(self) -> None:
        blockers = submit_app_store_review.validation_report_blockers(
            self.scoped_report("IOS", {"ios.app"}),
            version="1.0.39",
            build_number="202608050001",
            platform="IOS",
            comparison_runtime_surfaces=frozenset({"ios.app", "watchos.app"}),
        )

        self.assertTrue(any("missing required surfaces: watchos.app" in item for item in blockers))
        self.assertIn("the physical Watch restart attestation must be recorded", blockers)

    def test_platform_with_no_runtime_change_needs_no_runtime_session(self) -> None:
        blockers = submit_app_store_review.validation_report_blockers(
            self.scoped_report("TV_OS", set()),
            version="1.0.39",
            build_number="202608050001",
            platform="TV_OS",
            comparison_runtime_surfaces=frozenset(),
        )

        self.assertEqual(blockers, [])

    def test_validation_report_reads_runtime_scope_from_the_release_comparison(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            report_path.write_text(json.dumps(self.scoped_report("TV_OS", {"tvos.app"})))
            comparison_path = Path(directory) / "comparison.json"
            comparison_path.write_text(
                json.dumps({"requiredSurfaces": {"actual-runtime": ["tvos.app"]}})
            )
            args = SimpleNamespace(
                validation_report=str(report_path),
                release_evidence_comparison=str(comparison_path),
                version="1.0.39",
                build_number="202608050001",
                platform="TV_OS",
            )
            with patch.object(submit_app_store_review, "validate_current_comparison"):
                submit_app_store_review.validate_validation_report(args)
                args.release_evidence_comparison = None
                with self.assertRaisesRegex(
                    submit_app_store_review.AppStoreConnectError,
                    "missing required surfaces: tvos.top-shelf",
                ):
                    submit_app_store_review.validate_validation_report(args)

    def test_rejects_active_deferrals_even_when_runtime_receipts_are_proven(self):
        report = exact_build_validation_report("MAC_OS")
        report["operatorFlow"]["state"] = "deferred"
        report["operatorFlow"]["deferredActionCount"] = 1
        report["operatorFlow"]["activeDeferrals"] = [{"actionId": "macos.review"}]

        blockers = submit_app_store_review.validation_report_blockers(
            report,
            version="1.0.39",
            build_number="202608050001",
            platform="MAC_OS",
        )

        self.assertIn("operator flow state must be complete", blockers)
        self.assertIn("operator flow must have no deferred actions", blockers)
        self.assertIn("operator flow must have no active deferrals", blockers)

    def test_live_build_mutations_require_a_report_but_safe_operations_do_not(self):
        report_preflight = SimpleNamespace(
            validate_report_only=True,
            dry_run=False,
            cancel_review_only=False,
            prepare_only=False,
            build_number="202608050001",
        )
        live_submit = SimpleNamespace(
            validate_report_only=False,
            dry_run=False,
            cancel_review_only=False,
            prepare_only=False,
            build_number="202608050001",
        )
        live_prepare = SimpleNamespace(
            validate_report_only=False,
            dry_run=False,
            cancel_review_only=False,
            prepare_only=True,
            build_number="202608050001",
        )
        safe_operations = (
            SimpleNamespace(
                validate_report_only=False,
                dry_run=True,
                cancel_review_only=False,
                prepare_only=False,
                build_number="202608050001",
            ),
            SimpleNamespace(
                validate_report_only=False,
                dry_run=False,
                cancel_review_only=True,
                prepare_only=False,
                build_number=None,
            ),
            SimpleNamespace(
                validate_report_only=False,
                dry_run=False,
                cancel_review_only=False,
                prepare_only=True,
                build_number=None,
            ),
        )

        self.assertTrue(submit_app_store_review.validation_report_required(report_preflight))
        self.assertTrue(submit_app_store_review.validation_report_required(live_submit))
        self.assertTrue(submit_app_store_review.validation_report_required(live_prepare))
        for operation in safe_operations:
            self.assertFalse(submit_app_store_review.validation_report_required(operation))

    def test_validate_validation_report_fails_before_app_store_connect_use(self):
        report = exact_build_validation_report("MAC_OS")
        report["operatorFlow"]["activeDeferrals"] = [{"actionId": "macos.review"}]
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            report_path.write_text(json.dumps(report))
            args = SimpleNamespace(
                validation_report=str(report_path),
                version="1.0.39",
                build_number="202608050001",
                platform="MAC_OS",
            )

            with self.assertRaisesRegex(
                submit_app_store_review.AppStoreConnectError,
                "operator flow must have no active deferrals",
            ):
                submit_app_store_review.validate_validation_report(args)

    def test_validate_report_only_exits_before_credentials_or_app_store_connect(self):
        report = exact_build_validation_report("MAC_OS")
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            report_path.write_text(json.dumps(report))
            args = SimpleNamespace(
                validate_report_only=True,
                validation_report=str(report_path),
                version="1.0.39",
                build_number="202608050001",
                platform="MAC_OS",
                dry_run=False,
                cancel_review_only=False,
                prepare_only=False,
                release_evidence_mode="shadow",
            )

            with (
                patch.object(submit_app_store_review, "parse_args", return_value=args),
                redirect_stdout(io.StringIO()) as output,
            ):
                exit_code = submit_app_store_review.main()

        self.assertEqual(exit_code, 0)
        self.assertIn("no App Store Connect request was made", output.getvalue())

    @staticmethod
    def run_main_with_reference_runs(args, runs):
        """Run main() with evidence checks stubbed and CI runs served from `runs`."""
        source = "c" * 40

        def fetch(path):
            if "/actions/workflows/" in path:
                return {"workflow_runs": [run for run, _ in runs if run["head_sha"] in path]}
            run_id = int(path.split("/actions/runs/")[1].split("/")[0])
            return {"jobs": next(jobs for run, jobs in runs if run["id"] == run_id)}

        with tempfile.TemporaryDirectory() as directory:
            manifest_path = Path(directory) / "expected.json"
            manifest_path.write_text(json.dumps({"artifacts": [{"sourceCommit": source}]}))
            args.release_evidence_expected_build_manifests = [str(manifest_path)]
            args.api_key_id = None
            args.api_issuer_id = None
            with (
                patch.object(submit_app_store_review, "parse_args", return_value=args),
                patch.object(submit_app_store_review, "validate_validation_report"),
                patch.object(submit_app_store_review, "validate_release_evidence_report"),
                patch.object(submit_app_store_review, "fetch_ci_json", fetch),
                patch.dict("os.environ", {"GITHUB_REPOSITORY": "owner/repo"}),
                redirect_stdout(io.StringIO()) as output,
                redirect_stderr(io.StringIO()) as errors,
            ):
                exit_code = submit_app_store_review.main()
        return source, exit_code, output.getvalue(), errors.getvalue()

    @staticmethod
    def reference_run(commit, conclusion):
        run = {
            "id": 7,
            "head_sha": commit,
            "event": "push",
            "path": ".github/workflows/ci.yml",
            "head_repository": {"full_name": "owner/repo"},
        }
        return run, [{"name": "shared-view-simulator-references", "conclusion": conclusion, "html_url": "run-url"}]

    def test_live_submission_refuses_without_a_passing_reference_run_before_credentials(self):
        for runs in ([], [self.reference_run("c" * 40, "skipped")], [self.reference_run("d" * 40, "success")]):
            with self.subTest(runs=runs):
                source, exit_code, _, errors = self.run_main_with_reference_runs(self.live_args(), runs)
                self.assertEqual(exit_code, 1)
                self.assertIn("shared-view reference images are not proven", errors)
                self.assertIn(f"git push origin {source}:refs/heads/reference-check/", errors)
                self.assertNotIn("APP_STORE_CONNECT_KEY_ID", errors)

    def test_live_submission_continues_past_a_passing_reference_run(self):
        _, exit_code, output, errors = self.run_main_with_reference_runs(
            self.live_args(), [self.reference_run("c" * 40, "success")]
        )
        self.assertEqual(exit_code, 1)
        self.assertIn("Simulator reference images passed", output)
        self.assertIn("APP_STORE_CONNECT_KEY_ID", errors)

    def test_preflight_checks_the_same_reference_run(self):
        args = self.live_args(validate_report_only=True, release_evidence_mode="enforce")
        _, refused, _, errors = self.run_main_with_reference_runs(args, [])
        self.assertEqual(refused, 1)
        self.assertIn("shared-view reference images are not proven", errors)

        args = self.live_args(validate_report_only=True, release_evidence_mode="enforce")
        _, accepted, output, _ = self.run_main_with_reference_runs(args, [self.reference_run("c" * 40, "success")])
        self.assertEqual(accepted, 0)
        self.assertIn("no App Store Connect request was made", output)

    def test_live_shadow_and_enforce_require_release_evidence_report(self):
        for mode in ("shadow", "enforce"):
            with self.subTest(mode=mode):
                args = self.live_args(
                    release_evidence_mode=mode,
                    release_evidence_report=None,
                )
                with self.assertRaisesRegex(
                    submit_app_store_review.AppStoreConnectError,
                    "required for live shadow or enforce",
                ):
                    submit_app_store_review.validate_args(args)

    def test_release_evidence_report_requires_exact_validation_report(self):
        args = self.live_args(dry_run=True, validation_report=None)
        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "requires --validation-report",
        ):
            submit_app_store_review.validate_args(args)

    def test_release_evidence_report_requires_authoritative_binding_inputs(self):
        args = self.live_args(
            dry_run=True,
            release_evidence_comparison=None,
            release_evidence_expected_build_manifests=None,
        )
        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "requires --release-evidence-comparison",
        ):
            submit_app_store_review.validate_args(args)

    def test_live_shadow_argument_contract_is_accepted(self):
        submit_app_store_review.validate_args(self.live_args())

    def test_release_evidence_accepts_historical_policy_archive_input(self):
        with patch.object(
            sys,
            "argv",
            [
                "submit-app-store-review.py",
                "--version",
                "1.0.54",
                "--build-number",
                "202608100001",
                "--validation-report",
                "final-report.json",
                "--validation-train",
                "release",
                "--release-evidence-report",
                "release-evidence.json",
                "--release-evidence-comparison",
                "comparison.json",
                "--release-evidence-expected-build-manifest",
                "expected.json",
                "--release-evidence-selected-rc-ledger",
                "selected-rc.json",
                "--release-evidence-historical-policy-archive",
                "Config/ContextPanelHistoricalPolicyArchive.json",
                "--validate-report-only",
            ],
        ):
            parsed = submit_app_store_review.parse_args()

        self.assertEqual(
            parsed.release_evidence_historical_policy_archives,
            ["Config/ContextPanelHistoricalPolicyArchive.json"],
        )

    def test_live_submission_requires_release_evidence_train(self):
        for train in (None, "beta", "rc"):
            with self.subTest(train=train):
                args = self.live_args(validation_train=train)
                with self.assertRaisesRegex(
                    submit_app_store_review.AppStoreConnectError,
                    "requires --validation-train release",
                ):
                    submit_app_store_review.validate_args(args)

    def test_invalid_release_evidence_mode_casing_fails_in_parser(self):
        with patch.object(
            sys,
            "argv",
            [
                "submit-app-store-review.py",
                "--version",
                "1.0.54",
                "--release-evidence-mode",
                "SHADOW",
            ],
        ):
            with self.assertRaises(SystemExit):
                submit_app_store_review.parse_args()

    def test_release_evidence_mode_defaults_to_enforce(self):
        with patch.object(
            sys,
            "argv",
            [
                "submit-app-store-review.py",
                "--version",
                "1.0.54",
            ],
        ):
            self.assertEqual(
                submit_app_store_review.parse_args().release_evidence_mode,
                "enforce",
            )

    def test_validate_report_only_without_mode_requires_enforced_evidence(self):
        args = SimpleNamespace(
            validate_report_only=True,
            validation_report="final-report.json",
            release_evidence_report=None,
            version="1.0.54",
            build_number="202608100001",
            platform="MAC_OS",
            dry_run=False,
            cancel_review_only=False,
            prepare_only=False,
        )
        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "requires --release-evidence-report",
        ):
            submit_app_store_review.validate_args(args)

    def test_invalid_release_evidence_mode_fails_before_cancel_only_return(self):
        args = self.live_args(
            release_evidence_mode="SHADOW",
            cancel_review_only=True,
            remove_active_review_version="1.0.53",
            build_number=None,
            whats_new=None,
        )
        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "must be shadow or enforce",
        ):
            submit_app_store_review.validate_args(args)

    def test_release_evidence_validation_without_validation_report_fails_cleanly(self):
        args = self.live_args(validation_report=None)
        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "release evidence requires its report, exact validation report",
        ):
            submit_app_store_review.validate_release_evidence_report(args)

    def test_release_evidence_preflight_rejects_legacy_comparison_before_consuming_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release_report = root / "release-evidence.json"
            validation_report = root / "validation.json"
            comparison = root / "comparison.json"
            policy = root / "policy.json"
            surface_policy = root / "surface-policy.json"
            for path, payload in (
                (release_report, {}),
                (validation_report, {}),
                (comparison, {"schemaVersion": 1}),
                (policy, {}),
                (surface_policy, {}),
            ):
                path.write_text(json.dumps(payload))
            args = self.live_args(
                release_evidence_report=str(release_report),
                validation_report=str(validation_report),
                release_evidence_comparison=str(comparison),
                release_evidence_policy=str(policy),
                release_evidence_surface_policy=str(surface_policy),
                release_evidence_expected_build_manifests=[str(root / "missing.json")],
            )
            with self.assertRaisesRegex(
                submit_app_store_review.AppStoreConnectError,
                "release evidence binding is invalid",
            ):
                submit_app_store_review.validate_release_evidence_report(args)


class FakeASCClient:
    def __init__(
        self,
        include_submission_version=True,
        include_item_version=True,
        app_store_state: str | None = "WAITING_FOR_REVIEW",
        app_version_state: str | None = None,
    ):
        self.deleted_paths: list[str] = []
        self.requests: list[tuple[Any, ...]] = []
        self.include_submission_version = include_submission_version
        self.include_item_version = include_item_version
        self.app_store_state = app_store_state
        self.app_version_state = app_version_state

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        self.requests.append((method, path, params, body, allowed))
        if method == "GET" and path == "/apps/app-id/appStoreVersions":
            attributes = {"versionString": "1.0.13"}
            if self.app_store_state is not None:
                attributes["appStoreState"] = self.app_store_state
            if self.app_version_state is not None:
                attributes["appVersionState"] = self.app_version_state
            return {
                "data": [
                    {
                        "id": "version-1-0-13",
                        "attributes": attributes,
                    }
                ]
            }
        if method == "GET" and path == "/reviewSubmissions":
            submission_relationships: dict[str, Any] = {
                "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]},
            }
            if self.include_submission_version:
                submission_relationships["appStoreVersionForReview"] = {
                    "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                }
            item_relationships: dict[str, Any] = {}
            if self.include_item_version:
                item_relationships["appStoreVersion"] = {
                    "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                }
            return {
                "data": [
                    {
                        "id": "submission-1",
                        "attributes": {"state": "WAITING_FOR_REVIEW"},
                        "relationships": submission_relationships,
                    }
                ],
                "included": [
                    {
                        "id": "item-1",
                        "type": "reviewSubmissionItems",
                        "relationships": item_relationships,
                    }
                ],
            }
        if method == "GET" and path == "/reviewSubmissions/submission-1/items":
            return {"data": [{
                "id": "item-1",
                "relationships": {"appStoreVersion": {"data": {
                    "type": "appStoreVersions", "id": "version-1-0-13",
                }}},
            }]}
        if method == "DELETE" and path == "/reviewSubmissionItems/item-1":
            self.deleted_paths.append(path)
            return {}
        raise AssertionError(f"unexpected request: {method} {path}")


class OrphanReadyForReviewClient:
    def __init__(self, app_store_state="READY_FOR_SALE"):
        self.app_store_state = app_store_state
        self.requests: list[tuple[Any, ...]] = []

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        self.requests.append((method, path, params, body, allowed))
        if method == "GET" and path == "/apps/app-id/appStoreVersions":
            return {
                "data": [{
                    "id": "version-1-0-13",
                    "attributes": {
                        "versionString": "1.0.13",
                        "appStoreState": self.app_store_state,
                    },
                }]
            }
        if method == "GET" and path == "/reviewSubmissions":
            version = {
                "id": "version-1-0-13",
                "type": "appStoreVersions",
                "attributes": {
                    "versionString": "1.0.13",
                    "appStoreState": self.app_store_state,
                    "platform": "IOS",
                },
            }
            return {
                "data": [{
                    "id": "orphan-submission",
                    "attributes": {
                        "state": "READY_FOR_REVIEW",
                        "platform": None,
                        "submittedDate": None,
                    },
                    "relationships": {
                        "items": {"data": []},
                        "appStoreVersionForReview": {
                            "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                        },
                    },
                }],
                "included": [version],
            }
        if method == "PATCH" and path == "/reviewSubmissions/orphan-submission":
            return {"data": {"id": "orphan-submission", "type": "reviewSubmissions"}}
        raise AssertionError(f"unexpected request: {method} {path}")


class SubmittedReviewItemClient(FakeASCClient):
    def request(self, method, path, params=None, body=None, allowed=(200,)):
        if method == "DELETE" and path == "/reviewSubmissionItems/item-1":
            self.requests.append((method, path, params, body, allowed))
            raise submit_app_store_review.AppStoreConnectError(
                "App Store Connect request failed: DELETE /reviewSubmissionItems/item-1",
                status=409,
                payload={"errors": [{"detail": "Item was already submitted"}]},
            )
        if method == "PATCH" and path == "/reviewSubmissionItems/item-1":
            self.requests.append((method, path, params, body, allowed))
            return {
                "data": {
                    "id": "item-1",
                    "type": "reviewSubmissionItems",
                    "attributes": {"state": "REMOVED"},
                }
            }
        return super().request(method, path, params, body, allowed)


class SubmittedReviewItemBlockedBySubmissionStateClient(SubmittedReviewItemClient):
    def __init__(self, items: list[dict[str, Any]] | None = None, cancel_state: str = "COMPLETE", withdrawn_state: str = "DEVELOPER_REJECTED", cancel_read_status: int = 200) -> None:
        super().__init__()
        self.items = items
        self.cancel_state = cancel_state
        self.withdrawn_state = withdrawn_state
        self.cancel_read_status = cancel_read_status

    def request(self, method, path, params=None, body=None, allowed=(200,)):
        if method == "PATCH" and path == "/reviewSubmissionItems/item-1":
            self.requests.append((method, path, params, body, allowed))
            raise submit_app_store_review.AppStoreConnectError(
                "App Store Connect request failed: PATCH /reviewSubmissionItems/item-1",
                status=409,
                payload={
                    "errors": [
                        {
                            "code": "STATE_ERROR.ENTITY_STATE_INVALID",
                            "detail": "Cannot remove item because of state of reviewSubmission.",
                        }
                    ]
                },
            )
        if method == "GET" and path == "/appStoreVersions/version-1-0-13":
            self.requests.append((method, path, params, body, allowed))
            return {"data": {"id": "version-1-0-13", "attributes": {"appStoreState": self.withdrawn_state}}}
        if path == "/reviewSubmissions/submission-1/items" and self.items is not None:
            self.requests.append((method, path, params, body, allowed))
            return {"data": self.items}
        if path == "/reviewSubmissions/submission-1":
            self.requests.append((method, path, params, body, allowed))
            if method == "GET" and self.cancel_read_status != 200:
                raise submit_app_store_review.AppStoreConnectError("cancel readback", status=self.cancel_read_status)
            return {"data": {"id": "submission-1", "attributes": {"state": self.cancel_state}}}
        return super().request(method, path, params, body, allowed)


class PlatformArgumentTests(unittest.TestCase):
    def parse(self, *arguments: str):
        with patch.object(
            sys,
            "argv",
            ["submit-app-store-review.py", "--version", "1.0.54", *arguments],
        ):
            return submit_app_store_review.parse_args()

    def assert_rejected(self, *arguments: str) -> str:
        error_output = io.StringIO()
        with redirect_stderr(error_output), self.assertRaises(SystemExit) as context:
            self.parse(*arguments)
        self.assertEqual(context.exception.code, 2)
        return error_output.getvalue()

    def test_platform_accepts_every_platform_with_runtime_requirements(self):
        for platform in submit_app_store_review.REQUIRED_RUNTIME_SURFACES_BY_PLATFORM:
            with self.subTest(platform=platform):
                self.assertEqual(self.parse("--platform", platform).platform, platform)

    def test_platform_defaults_to_mac_os(self):
        self.assertEqual(self.parse().platform, "MAC_OS")

    def test_platform_rejects_unsupported_miscased_and_empty_values(self):
        for platform in ("WATCH_OS", "ios", ""):
            with self.subTest(platform=platform):
                self.assertIn(
                    "argument --platform:",
                    self.assert_rejected("--platform", platform),
                )

    def test_copy_from_platform_defaults_to_none_and_accepts_supported_platforms(self):
        self.assertIsNone(self.parse().copy_from_platform)
        for platform in submit_app_store_review.REQUIRED_RUNTIME_SURFACES_BY_PLATFORM:
            with self.subTest(platform=platform):
                self.assertEqual(
                    self.parse("--copy-from-platform", platform).copy_from_platform,
                    platform,
                )

    def test_copy_from_platform_rejects_unsupported_platforms(self):
        self.assertIn(
            "argument --copy-from-platform:",
            self.assert_rejected("--copy-from-platform", "WATCH_OS"),
        )


class MetadataSourcePlatformTests(unittest.TestCase):
    def test_copy_from_platform_defaults_to_target_platform(self):
        args = SimpleNamespace(platform="TV_OS", copy_from_platform=None)

        self.assertEqual(submit_app_store_review.namespace_copy_from_platform(args), "TV_OS")

    def test_copy_from_platform_can_select_existing_cross_platform_metadata(self):
        args = SimpleNamespace(platform="TV_OS", copy_from_platform="MAC_OS")

        self.assertEqual(submit_app_store_review.namespace_copy_from_platform(args), "MAC_OS")


class PaginationTests(unittest.TestCase):
    def test_paginated_get_follows_next_link_query_parameters(self):
        class CursorClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if params and params.get("cursor") == "next-page":
                    return {
                        "data": [{"id": "second"}],
                        "included": [{"id": "included-second"}],
                    }
                return {
                    "data": [{"id": "first"}],
                    "included": [{"id": "included-first"}],
                    "links": {
                        "next": "https://api.appstoreconnect.apple.com/v1/other-things?cursor=next-page&limit=50"
                    },
                }

        client = CursorClient()

        payload = submit_app_store_review.paginated_get(client, "/things", {"filter[app]": "app-id"})

        self.assertEqual([item["id"] for item in payload["data"]], ["first", "second"])
        self.assertEqual([item["id"] for item in payload["included"]], ["included-first", "included-second"])
        self.assertEqual(client.requests[1][1], "/other-things")
        self.assertEqual(client.requests[0][2], {"filter[app]": "app-id", "limit": 50})
        self.assertEqual(client.requests[1][2], {"cursor": "next-page", "limit": "50"})

    def test_asc_client_wraps_url_error(self):
        client = submit_app_store_review.ASCClient("token")

        with patch.object(
            submit_app_store_review.urllib.request,
            "urlopen",
            side_effect=urllib.error.URLError("offline"),
        ):
            with self.assertRaisesRegex(
                submit_app_store_review.AppStoreConnectError,
                "App Store Connect request failed: GET /apps",
            ):
                client.request("GET", "/apps")


class RemoveActiveReviewVersionTests(unittest.TestCase):
    def test_validate_args_mode_and_tvos_demo_rules(self):
        cancel = {"cancel_review_only": True, "remove_active_review_version": "1.0.13", "build_number": None}
        prepare = {"cancel_review_only": False, "remove_active_review_version": None, "build_number": None,
                   "whats_new": "Fixes", "prepare_only": True}
        tvos = {"cancel_review_only": False, "remove_active_review_version": None, "build_number": "202607241933",
                "whats_new": "Adds the Apple TV companion.", "prepare_only": False, "platform": "TV_OS",
                "review_notes": "The app uses a Mac-published CloudKit snapshot."}
        demo_url = "https://example.com/physical-apple-tv-demo.mp4"
        # name: (arguments, refusal or None when accepted)
        cases = {
            "cancel-only without build metadata": (
                {**cancel, "whats_new": None, "prepare_only": False, "platform": "TV_OS", "review_notes": None,
                 "tvos_demo_video_url": None}, None,
            ),
            "cancel-only without target": (
                {**cancel, "remove_active_review_version": None, "whats_new": None, "prepare_only": False},
                "--remove-active-review-version",
            ),
            "normal review without build": ({**prepare, "prepare_only": False}, "--build-number"),
            "prepare-only without build": (prepare, None),
            "prepare-only without release notes": ({**prepare, "whats_new": None}, "--whats-new"),
            "prepare-only with cancel-only": ({**cancel, "whats_new": "Fixes", "prepare_only": True}, "mutually exclusive"),
            "prepare-only reusing a version": ({**prepare, "remove_active_review_version": "1.0.13"}, None),
            "tvOS without demo video": ({**tvos, "tvos_demo_video_url": None, "dry_run": True}, None),
            "tvOS demo video over HTTP": (
                {**tvos, "tvos_demo_video_url": "http://example.com/physical-apple-tv-demo.mp4"}, "valid HTTPS URL",
            ),
            "blank tvOS demo video": ({**tvos, "tvos_demo_video_url": "   "}, "valid HTTPS URL"),
            "demo video for another platform": (
                {**tvos, "platform": "IOS", "review_notes": "Physical iPhone demo.", "tvos_demo_video_url": demo_url},
                "only valid with --platform TV_OS",
            ),
            "structured tvOS demo video": ({**tvos, "tvos_demo_video_url": demo_url, "dry_run": True}, None),
        }
        for name, (arguments, refusal) in cases.items():
            with self.subTest(name):
                args = SimpleNamespace(**arguments)
                if refusal is None:
                    submit_app_store_review.validate_args(args)
                else:
                    with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
                        submit_app_store_review.validate_args(args)
                    self.assertIn(refusal, str(context.exception))

    def test_effective_review_notes_prepends_standardized_tvos_evidence(self):
        args = SimpleNamespace(
            platform="TV_OS",
            review_notes="No demo account or tvOS permission prompt is required.",
            tvos_demo_video_url="https://example.com/physical-apple-tv-demo.mp4",
        )

        self.assertEqual(
            submit_app_store_review.effective_review_notes(args),
            "Physical Apple TV demo (reviewer-accessible, no login required):\n"
            "https://example.com/physical-apple-tv-demo.mp4\n\n"
            "No demo account or tvOS permission prompt is required.",
        )

    def test_effective_review_notes_clears_copied_tvos_notes_without_current_override(self):
        args = SimpleNamespace(
            platform="TV_OS",
            review_notes=None,
            tvos_demo_video_url=None,
        )

        self.assertEqual(submit_app_store_review.effective_review_notes(args), "")

    def test_effective_review_notes_keeps_current_tvos_notes_without_demo_video(self):
        args = SimpleNamespace(
            platform="TV_OS",
            review_notes="No demo account or tvOS permission prompt is required.",
            tvos_demo_video_url=None,
        )

        self.assertEqual(
            submit_app_store_review.effective_review_notes(args),
            "No demo account or tvOS permission prompt is required.",
        )

    def test_deletes_matching_item(self):
        client = FakeASCClient()

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

        self.assertEqual(client.deleted_paths, ["/reviewSubmissionItems/item-1"])

    def test_removes_submitted_review_item_without_canceling_owner(self):
        client = SubmittedReviewItemClient()

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

        mutations = [(request[0], request[1]) for request in client.requests if request[0] in {"DELETE", "PATCH"}]
        self.assertEqual(
            mutations,
            [
                ("DELETE", "/reviewSubmissionItems/item-1"),
                ("PATCH", "/reviewSubmissionItems/item-1"),
            ],
        )
        patch_body = client.requests[-1][3]
        self.assertEqual(patch_body["data"]["attributes"], {"removed": True})

    def test_cancels_only_exact_sole_item_and_reads_back_before_returning(self) -> None:
        for platform in ("MAC_OS", "IOS", "VISION_OS", "TV_OS"):
            with self.subTest(platform=platform):
                client = SubmittedReviewItemBlockedBySubmissionStateClient()
                submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13", platform)
                operations = [(r[0], r[1]) for r in client.requests]
                self.assertEqual(operations[-4:], [
                    ("GET", "/reviewSubmissions/submission-1/items"),
                    ("PATCH", "/reviewSubmissions/submission-1"),
                    ("GET", "/reviewSubmissions/submission-1"),
                    ("GET", "/appStoreVersions/version-1-0-13"),
                ])
                self.assertEqual(client.requests[-3][3]["data"]["attributes"], {"canceled": True})
                for request in client.requests:
                    if request[1] in {"/reviewSubmissions", "/apps/app-id/appStoreVersions"}:
                        self.assertEqual(request[2]["filter[platform]"], platform)

    def test_refuses_owner_cancellation_for_any_other_item_mix(self) -> None:
        target = {"id": "item-1", "relationships": {"appStoreVersion": {
            "data": {"type": "appStoreVersions", "id": "version-1-0-13"},
        }}}
        other = {"id": "other", "relationships": {"appStoreVersion": {
            "data": {"type": "appStoreVersions", "id": "other-version"},
        }}}
        for items in ([], [other], [{"id": "item-1"}], [target, other], [target, {"id": "event"}], [target, target]):
            with self.subTest(items=items):
                client = SubmittedReviewItemBlockedBySubmissionStateClient(items=items)
                with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                    submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
                self.assertFalse(any(r[0] == "PATCH" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests))

    def test_unconfirmed_cancel_stops_after_one_write(self) -> None:
        client = SubmittedReviewItemBlockedBySubmissionStateClient(cancel_state="WAITING_FOR_REVIEW")
        with patch.object(time, "monotonic", side_effect=(0, submit_app_store_review.DEFAULT_VERSION_UNLOCK_WAIT_TIMEOUT_SECONDS + 1)):
            with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
        self.assertEqual(sum(r[0] == "PATCH" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests), 1)
        self.assertEqual(client.requests[-1][:2], ("GET", "/reviewSubmissions/submission-1"))

    def test_missing_canceled_submission_requires_exact_withdrawn_version(self) -> None:
        for status, state, accepted in (
            (404, "DEVELOPER_REJECTED", True),
            (404, "WAITING_FOR_REVIEW", False),
            (404, "READY_FOR_SALE", False),
            (403, "DEVELOPER_REJECTED", False),
            (500, "DEVELOPER_REJECTED", False),
        ):
            with self.subTest(status=status, state=state):
                client = SubmittedReviewItemBlockedBySubmissionStateClient(withdrawn_state=state, cancel_read_status=status)
                with patch.object(time, "monotonic", side_effect=(0, submit_app_store_review.DEFAULT_VERSION_UNLOCK_WAIT_TIMEOUT_SECONDS + 1)):
                    if accepted:
                        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
                    else:
                        with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                            submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
                self.assertEqual(sum(r[0] == "PATCH" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests), 1)
                if accepted:
                    self.assertEqual(client.requests[-1][:2], ("GET", "/appStoreVersions/version-1-0-13"))

    def test_completed_review_without_withdrawn_version_stops(self) -> None:
        for state in ("WAITING_FOR_REVIEW", "READY_FOR_SALE"):
            with self.subTest(state=state):
                client = SubmittedReviewItemBlockedBySubmissionStateClient(withdrawn_state=state)
                with patch.object(time, "monotonic", side_effect=(0, submit_app_store_review.DEFAULT_VERSION_UNLOCK_WAIT_TIMEOUT_SECONDS + 1)):
                    with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
                self.assertEqual(client.requests[-1][:2], ("GET", "/appStoreVersions/version-1-0-13"))

    def test_dry_run_reads_sole_item_scope_without_mutations(self) -> None:
        for items in (None, [{"id": "event"}]):
            with self.subTest(items=items):
                client = SubmittedReviewItemBlockedBySubmissionStateClient(items=items)
                output = io.StringIO()
                with redirect_stdout(output):
                    submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13", dry_run=True)
                self.assertIn(("GET", "/reviewSubmissions/submission-1/items"), [(r[0], r[1]) for r in client.requests])
                self.assertFalse(any(r[0] != "GET" for r in client.requests))

    def test_second_page_item_prevents_whole_submission_cancellation(self) -> None:
        client = SubmittedReviewItemBlockedBySubmissionStateClient()
        request = client.request

        def paged_request(method: str, path: str, params: dict[str, Any] | None = None,
                          body: dict[str, Any] | None = None, allowed: tuple[int, ...] = (200,)) -> dict[str, Any]:
            if path == "/reviewSubmissions/submission-1/items":
                if params and "cursor" in params:
                    return {"data": [{"id": "event"}]}
                page: dict[str, Any] = request(method, path, params, body, allowed)
                page["links"] = {"next": "https://api.appstoreconnect.apple.com/v1/reviewSubmissions/submission-1/items?cursor=next"}
                return page
            return request(method, path, params, body, allowed)

        with patch.object(client, "request", side_effect=paged_request):
            with self.assertRaises(submit_app_store_review.AppStoreConnectError):
                submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
        self.assertFalse(any(r[0] == "PATCH" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests))

    def test_cancellation_waits_for_complete_after_canceling(self) -> None:
        client = SubmittedReviewItemBlockedBySubmissionStateClient()
        request = client.request
        states = iter(("CANCELING", "COMPLETE", "COMPLETE"))
        version_states = iter(("WAITING_FOR_REVIEW", "DEVELOPER_REJECTED"))

        def cancellation_request(method: str, path: str, params: dict[str, Any] | None = None,
                                 body: dict[str, Any] | None = None, allowed: tuple[int, ...] = (200,)) -> dict[str, Any]:
            if method == "GET" and path == "/reviewSubmissions/submission-1":
                client.cancel_state = next(states)
            if method == "GET" and path == "/appStoreVersions/version-1-0-13":
                client.withdrawn_state = next(version_states)
            return request(method, path, params, body, allowed)

        with patch.object(client, "request", side_effect=cancellation_request), patch.object(time, "sleep"):
            submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")
        self.assertEqual(sum(r[0] == "GET" and r[1] == "/reviewSubmissions/submission-1" for r in client.requests), 3)

    def test_dry_run_does_not_delete(self):
        client = FakeASCClient()

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13", dry_run=True)

        self.assertEqual(client.deleted_paths, [])

    def test_dry_run_cancels_orphan_ready_for_sale_review_draft(self):
        client = OrphanReadyForReviewClient()
        output = io.StringIO()

        with redirect_stdout(output):
            submit_app_store_review.remove_active_review_version(
                client,
                "app-id",
                "1.0.13",
                platform="IOS",
                dry_run=True,
            )

        self.assertIn("would cancel App Store version 1.0.13 review submission", output.getvalue())
        self.assertFalse(any(request[0] in {"DELETE", "PATCH"} for request in client.requests))

    def test_apply_cancels_orphan_ready_for_sale_review_draft(self):
        client = OrphanReadyForReviewClient()

        submit_app_store_review.remove_active_review_version(
            client,
            "app-id",
            "1.0.13",
            platform="IOS",
        )

        mutations = [request for request in client.requests if request[0] in {"DELETE", "PATCH"}]
        self.assertEqual([(request[0], request[1]) for request in mutations], [
            ("PATCH", "/reviewSubmissions/orphan-submission"),
        ])
        self.assertEqual(mutations[0][3]["data"]["attributes"], {"canceled": True})

    def test_active_review_ids_ignore_orphan_ready_for_sale_review_draft(self):
        client = OrphanReadyForReviewClient()

        version_ids = submit_app_store_review.active_review_version_ids(client, "app-id", "TV_OS")

        self.assertEqual(version_ids, set())

    def test_active_review_ids_keep_direct_draft_for_non_live_version(self):
        client = OrphanReadyForReviewClient(app_store_state="WAITING_FOR_REVIEW")

        version_ids = submit_app_store_review.active_review_version_ids(client, "app-id", "TV_OS")

        self.assertEqual(version_ids, {"version-1-0-13"})

    def test_deletes_when_submission_version_relationship_is_missing(self):
        client = FakeASCClient(include_submission_version=False)

        submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

        self.assertEqual(client.deleted_paths, ["/reviewSubmissionItems/item-1"])

    def test_raises_when_blocking_version_has_no_matching_submission_item(self):
        for state, app_version_state in (
            ("WAITING_FOR_REVIEW", None), ("UNRESOLVED_ISSUES", None), (None, "WAITING_FOR_REVIEW"),
        ):
            with self.subTest(app_store_state=state, app_version_state=app_version_state):
                client = FakeASCClient(
                    include_submission_version=False,
                    include_item_version=False,
                    app_store_state=state,
                    app_version_state=app_version_state,
                )

                with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
                    submit_app_store_review.remove_active_review_version(client, "app-id", "1.0.13")

                self.assertIn(state or app_version_state, str(context.exception))

    def test_dry_run_build_check_does_not_patch_encryption(self):
        class BuildClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/builds":
                    return valid_build(uses_non_exempt_encryption=None)
                raise AssertionError(f"unexpected request: {method} {path}")

        client = BuildClient()
        args = SimpleNamespace(version="1.0.39", build_number="202606021931", non_exempt_encryption=False)

        submit_app_store_review.ensure_build(client, "app-id", args, allow_updates=False)

        self.assertEqual([request[0] for request in client.requests], ["GET"])

    def test_ensure_build_rejects_mismatched_marketing_version(self):
        class BuildClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/builds":
                    return valid_build(
                        uses_non_exempt_encryption=False,
                        platform="IOS",
                        marketing_version="1.0.36",
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.39", build_number="202606262249", non_exempt_encryption=False, platform="IOS")

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.ensure_build(BuildClient(), "app-id", args, allow_updates=False)

        self.assertIn("build 202606262249 belongs to marketing version 1.0.36", str(context.exception))
        self.assertIn("not 1.0.39", str(context.exception))

    def test_ensure_build_selects_matching_marketing_version_when_same_build_number_is_reused(self):
        class BuildClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/builds":
                    return build_payload(
                        [
                            {
                                "build_id": "stale-build",
                                "platform": "IOS",
                                "marketing_version": "1.0.36",
                                "uses_non_exempt_encryption": False,
                            },
                            {
                                "build_id": "target-build",
                                "platform": "IOS",
                                "marketing_version": "1.0.39",
                                "uses_non_exempt_encryption": False,
                            },
                        ]
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.39", build_number="202606262249", non_exempt_encryption=False, platform="IOS")

        build = submit_app_store_review.ensure_build(BuildClient(), "app-id", args, allow_updates=False)

        self.assertEqual(build["id"], "target-build")

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_ensure_build_polls_until_uploaded_build_is_valid(self, _sleep):
        class PollingBuildClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/builds":
                    call_count = len([request for request in self.requests if request[1] == "/builds"])
                    if call_count == 1:
                        return {"data": []}
                    if call_count == 2:
                        return valid_build(state="PROCESSING")
                    return valid_build(uses_non_exempt_encryption=False)
                raise AssertionError(f"unexpected request: {method} {path}")

        client = PollingBuildClient()
        args = SimpleNamespace(version="1.0.39", build_number="202606071340", non_exempt_encryption=False)

        build = submit_app_store_review.ensure_build(
            client,
            "app-id",
            args,
            wait_timeout_seconds=60,
            poll_seconds=1,
        )

        self.assertEqual(build["id"], "build-1")
        self.assertEqual(len([request for request in client.requests if request[1] == "/builds"]), 3)

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    @patch.object(submit_app_store_review.time, "monotonic", side_effect=[0, 0, 10])
    def test_ensure_build_times_out_when_uploaded_build_is_missing(self, _monotonic, _sleep):
        class MissingBuildClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/builds":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(build_number="202606071340", non_exempt_encryption=False)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.ensure_build(
                MissingBuildClient(),
                "app-id",
                args,
                wait_timeout_seconds=1,
                poll_seconds=1,
            )

        self.assertIn("missing MAC_OS build 202606071340", str(context.exception))

    def test_dry_run_version_path_reports_or_refuses_version_state(self):
        def version(version_string, state):
            return {
                "id": "version-" + version_string.replace(".", "-"),
                "attributes": {"versionString": version_string, "appStoreState": state},
            }

        class VersionPathClient:
            """Serves versions by versionString filter (None: the unfiltered list) and one optional review."""

            def __init__(self, versions, review):
                self.versions = versions
                self.review = review

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    return {"data": [version(*item) for item in self.versions.get(version_string, [])]}
                if method == "GET" and path == "/reviewSubmissions":
                    if self.review is None:
                        return {"data": []}
                    state, version_string = self.review
                    target = {"type": "appStoreVersions", "id": "version-" + version_string.replace(".", "-")}
                    return {"data": [{
                        "id": "submission-1",
                        "attributes": {"state": state},
                        "relationships": {"appStoreVersionForReview": {"data": target}, "items": {"data": []}},
                    }]}
                raise AssertionError(f"unexpected request: {method} {path}")

        target = {"version": "1.0.14", "remove_active_review_version": None}
        replace_13 = {"version": "1.0.14", "remove_active_review_version": "1.0.13"}
        removable = {"removable_review_version": "1.0.13"}
        waiting_13 = ("1.0.13", "WAITING_FOR_REVIEW")
        # name: (args, versions by filter, active review, call options, refused, expected text, absent text)
        cases = {
            "existing target": (
                target, {"1.0.14": [("1.0.14", "PREPARE_FOR_SUBMISSION")]}, None, {}, False,
                ("would use App Store version 1.0.14",), (),
            ),
            "missing target without active review": (
                target, {}, None, {}, False, ("would create App Store version 1.0.14",), (),
            ),
            "unrelated active review": (
                target, {}, ("WAITING_FOR_REVIEW", "1.0.13"), {}, True,
                ("another App Store version is already in review",), (),
            ),
            "ready-for-review submission": (
                target, {}, ("READY_FOR_REVIEW", "1.0.13"), {}, True,
                ("another App Store version is already in review",), (),
            ),
            "named blocking active review": (
                target, {None: [waiting_13]}, ("WAITING_FOR_REVIEW", "1.0.13"), {}, True,
                ("1.0.13 (WAITING_FOR_REVIEW)", "--remove-active-review-version"), (),
            ),
            "withdrawn source permits fresh target creation": (
                {**replace_13, "prepare_only": False}, {"1.0.13": [("1.0.13", "DEVELOPER_REJECTED")]}, None, {}, False, (), (),
            ),
            "withdrawn source still has an active owner": (
                {**replace_13, "prepare_only": False}, {"1.0.13": [("1.0.13", "DEVELOPER_REJECTED")]},
                ("WAITING_FOR_REVIEW", "1.0.13"), {}, True, (), (),
            ),
            "rejected replacement for review submission": (
                {**replace_13, "prepare_only": False}, {"1.0.13": [("1.0.13", "REJECTED")]}, None, {}, True,
                ("do not reuse it as 1.0.14 for review submission", "Run --prepare-only first"), (),
            ),
            "rejected replacement for prepare-only": (
                {**replace_13, "prepare_only": True}, {"1.0.13": [("1.0.13", "DEVELOPER_REJECTED")]}, None, {}, False,
                ("apply mode can reuse 1.0.13",), (),
            ),
            "fresh prepare-only beside rejected version": (
                {**target, "prepare_only": True}, {None: [("1.0.13", "REJECTED")]}, None, {}, False,
                ("would create App Store version 1.0.14",), (),
            ),
            "locked replacement": (
                replace_13, {"1.0.13": [waiting_13]}, None, {}, True, ("still WAITING_FOR_REVIEW",), (),
            ),
            "removable active replacement": (
                replace_13, {"1.0.13": [waiting_13]}, ("WAITING_FOR_REVIEW", "1.0.13"), removable, False,
                ("apply mode can reuse 1.0.13",), (),
            ),
            "ready-for-sale replacement": (
                replace_13, {"1.0.13": [("1.0.13", "READY_FOR_SALE")]}, None, removable, True,
                ("still READY_FOR_SALE",), (),
            ),
            "unrelated prepare-for-submission version": (
                target, {None: [("1.0.13", "PREPARE_FOR_SUBMISSION")]}, None, {}, True,
                ("1.0.13 is PREPARE_FOR_SUBMISSION", "--remove-active-review-version 1.0.13"), (),
            ),
            "unrelated pending release version": (
                target, {None: [("1.0.13", "PENDING_DEVELOPER_RELEASE")]}, None, {}, True,
                ("1.0.13 is PENDING_DEVELOPER_RELEASE", "release or reject that version"), (),
            ),
            "blocking rejected version": (
                {"version": "1.0.40", "remove_active_review_version": None},
                {None: [("1.0.39", "REJECTED")]}, None, {}, True,
                ("1.0.39 is REJECTED", "prepare the next marketing version"), ("reuse it as the replacement",),
            ),
            "locked target version": (
                {**target, "build_number": "202606062346"},
                {None: [("1.0.14", "WAITING_FOR_REVIEW")], "1.0.14": [("1.0.14", "WAITING_FOR_REVIEW")]},
                ("WAITING_FOR_REVIEW", "1.0.14"), {}, True, ("cannot attach build 202606062346",), (),
            ),
            "rejected target version": (
                {"version": "1.0.39", "build_number": "202606262249", "remove_active_review_version": None},
                {"1.0.39": [("1.0.39", "REJECTED")]}, None, {}, True,
                ("do not resubmit a rejected release candidate",), (),
            ),
        }
        for name, (args, versions, review, options, refused, expected, absent) in cases.items():
            with self.subTest(name):
                client = VersionPathClient(versions, review)
                output = io.StringIO()
                with redirect_stdout(output):
                    if refused:
                        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
                            submit_app_store_review.dry_run_version_path(
                                client, "app-id", SimpleNamespace(**args), **options,
                            )
                        message = str(context.exception)
                    else:
                        submit_app_store_review.dry_run_version_path(
                            client, "app-id", SimpleNamespace(**args), **options,
                        )
                        message = output.getvalue()
                for text in expected:
                    self.assertIn(text, message)
                for text in absent:
                    self.assertNotIn(text, message)

    def test_dry_run_version_path_rejects_blocking_version_on_second_page(self):
        class PagedBlockingVersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    offset = params.get("offset") if params else None
                    if version_string == "1.0.14":
                        return {"data": []}
                    if offset:
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-13",
                                    "attributes": {
                                        "versionString": "1.0.13",
                                        "appStoreState": "PREPARE_FOR_SUBMISSION",
                                    },
                                }
                            ]
                        }
                    return {
                        "data": [
                            {
                                "id": "version-1-0-12",
                                "attributes": {
                                    "versionString": "1.0.12",
                                    "appStoreState": "READY_FOR_SALE",
                                },
                            }
                        ],
                        "links": {"next": "https://api.appstoreconnect.apple.com/v1/apps/app-id/appStoreVersions?offset=1"},
                    }
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(version="1.0.14", remove_active_review_version=None)

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.dry_run_version_path(PagedBlockingVersionClient(), "app-id", args)

        self.assertIn("1.0.13 is PREPARE_FOR_SUBMISSION", str(context.exception))

    def test_ensure_version_rejects_rejected_target_version(self):
        class RejectedVersionClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    return {
                        "data": [
                            {
                                "id": "version-1-0-39",
                                "attributes": {"versionString": "1.0.39", "appStoreState": "REJECTED"},
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(
            version="1.0.39",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
        )

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.ensure_version(RejectedVersionClient(), "app-id", args)

        self.assertIn("Prepare the next marketing version", str(context.exception))

    def test_supersede_run_force_prepares_existing_replacement_version(self):
        class ExistingReplacementClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    return {
                        "data": [
                            {
                                "id": "version-1-0-14",
                                "attributes": {"versionString": "1.0.14", "appStoreState": "PREPARE_FOR_SUBMISSION"},
                            }
                        ]
                    }
                if method == "PATCH" and path == "/appStoreVersions/version-1-0-14":
                    return {"data": {"id": "version-1-0-14"}}
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(
            version="1.0.14",
            remove_active_review_version="1.0.13",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
        )

        version, force_prepare = submit_app_store_review.ensure_replacement_version(
            ExistingReplacementClient(),
            "app-id",
            args,
        )

        self.assertEqual(version["id"], "version-1-0-14")
        self.assertTrue(force_prepare)

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_prepare_only_can_reuse_rejected_version_without_review_removal(self, _sleep):
        class RejectedReuseClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if path.startswith("/reviewSubmission"):
                    raise AssertionError(f"prepare-only reuse should not touch review endpoint: {method} {path}")
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string == "1.0.38":
                        return {"data": []}
                    if version_string == "1.0.36":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-36",
                                    "attributes": {"versionString": "1.0.36", "appStoreState": "REJECTED"},
                                }
                            ]
                        }
                    raise AssertionError(f"unexpected version query: {params}")
                if method == "POST" and path == "/appStoreVersions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /appStoreVersions",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "code": "STATE_ERROR",
                                    "detail": "You cannot create a new version of the App in the current state.",
                                }
                            ]
                        },
                    )
                if method == "PATCH" and path == "/appStoreVersions/version-1-0-36":
                    assert body is not None
                    return {
                        "data": {
                            "id": "version-1-0-36",
                            "attributes": body["data"]["attributes"],
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = RejectedReuseClient()
        args = SimpleNamespace(
            version="1.0.38",
            remove_active_review_version="1.0.36",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
            prepare_only=True,
        )

        version, reused_removed_version = submit_app_store_review.ensure_replacement_version(client, "app-id", args)

        self.assertEqual(version["id"], "version-1-0-36")
        self.assertTrue(reused_removed_version)
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        self.assertEqual(patch_body["data"]["attributes"]["versionString"], "1.0.38")
        review_paths = [request[1] for request in client.requests if request[1].startswith("/reviewSubmission")]
        self.assertEqual(review_paths, [])

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_review_submission_cannot_reuse_rejected_version_without_prepare_only(self, _sleep):
        class RejectedReuseClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    version_string = params.get("filter[versionString]") if params else None
                    if version_string == "1.0.38":
                        return {"data": []}
                    if version_string == "1.0.36":
                        return {
                            "data": [
                                {
                                    "id": "version-1-0-36",
                                    "attributes": {"versionString": "1.0.36", "appStoreState": "REJECTED"},
                                }
                            ]
                        }
                    raise AssertionError(f"unexpected version query: {params}")
                if method == "POST" and path == "/appStoreVersions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /appStoreVersions",
                        status=409,
                        payload={"errors": [{"detail": "You cannot create a new version of the App in the current state."}]},
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        args = SimpleNamespace(
            version="1.0.38",
            remove_active_review_version="1.0.36",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
            prepare_only=False,
        )

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.ensure_replacement_version(RejectedReuseClient(), "app-id", args)

        self.assertIn("do not reuse it as 1.0.38 for review submission", str(context.exception))

    def test_ensure_review_submission_reuses_existing_matching_ready_submission(self):
        class ReviewSubmissionClient:
            def __init__(self, state="READY_FOR_REVIEW"):
                self.requests: list[tuple[Any, ...]] = []
                self.state = state

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "old-submission",
                                "attributes": {"state": self.state},
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    },
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "old-item"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "old-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "GET" and path == "/reviewSubmissions/old-submission/items":
                    return {
                        "data": [
                            {
                                "id": "old-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    }
                                },
                            }
                        ]
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "PATCH" and path == "/reviewSubmissions/old-submission":
                    return {"data": {"id": "old-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-13",
        )

        self.assertEqual(submission["id"], "old-submission")
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, [])
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/old-submission"])
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        assert_review_submission_submit_body(self, patch_body)

    def test_ensure_review_submission_returns_submitted_existing_submission(self):
        class ReviewSubmissionClient:
            def __init__(self, state="WAITING_FOR_REVIEW"):
                self.requests: list[tuple[Any, ...]] = []
                self.state = state

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "old-submission",
                                "attributes": {"state": self.state},
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    },
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "old-item"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "old-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    }
                                },
                            }
                        ],
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-13",
        )

        self.assertEqual(submission["id"], "old-submission")
        mutation_methods = [request[0] for request in client.requests if request[0] in {"POST", "PATCH"}]
        self.assertEqual(mutation_methods, [])

        client = ReviewSubmissionClient(state="UNRESOLVED_ISSUES")
        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-13",
        )

        self.assertEqual(submission["id"], "old-submission")
        mutation_methods = [request[0] for request in client.requests if request[0] in {"POST", "PATCH"}]
        self.assertEqual(mutation_methods, [])

    def test_dry_run_main_returns_before_version_or_submission_mutations(self):
        class MainClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/apps":
                    return {"data": [{"id": "app-id", "attributes": {"name": "Context Panel"}}]}
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    if params and params.get("filter[versionString]") == "1.0.14":
                        raise AssertionError("dry run should not create or query target version")
                    return {
                        "data": [
                            {
                                "id": "version-1-0-13",
                                "attributes": {"versionString": "1.0.13", "appStoreState": "READY_FOR_SALE"},
                                "relationships": {
                                    "appStoreVersionLocalizations": {
                                        "data": [{"type": "appStoreVersionLocalizations", "id": "loc-1"}]
                                    },
                                    "appStoreReviewDetail": {
                                        "data": {"type": "appStoreReviewDetails", "id": "detail-1"}
                                    },
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "loc-1",
                                "type": "appStoreVersionLocalizations",
                                "attributes": {"locale": "en-US", "description": "desc", "supportUrl": "https://example.com"},
                            },
                            {
                                "id": "detail-1",
                                "type": "appStoreReviewDetails",
                                "attributes": {"contactEmail": "review@example.com"},
                            },
                        ],
                    }
                if method == "GET" and path == "/builds":
                    return valid_build(marketing_version="1.0.14")
                raise AssertionError(f"unexpected request: {method} {path}")

        client = MainClient()
        args = SimpleNamespace(
            api_key_id="key-id",
            api_issuer_id="issuer-id",
            bundle_id="com.shinycomputers.contextpanel",
            copy_from_version="1.0.13",
            build_number="202606021931",
            non_exempt_encryption=False,
            remove_active_review_version=None,
            dry_run=True,
            version="1.0.14",
            whats_new="Fixes",
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
        )

        source_localization, source_review_detail = submit_app_store_review.latest_source_metadata(
            client, "app-id", args.copy_from_version
        )
        submit_app_store_review.ensure_build(client, "app-id", args, allow_updates=not args.dry_run)
        self.assertTrue(source_localization)
        self.assertTrue(source_review_detail)

        mutation_methods = [request[0] for request in client.requests if request[0] != "GET"]
        self.assertEqual(mutation_methods, [])

    def test_ensure_metadata_retries_without_locked_whats_new(self):
        class MetadataClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/appStoreVersions/version-1-0-35":
                    return {
                        "data": {
                            "id": "version-1-0-35",
                            "attributes": {"appStoreState": "PREPARE_FOR_SUBMISSION"},
                            "relationships": {
                                "appStoreVersionLocalizations": {
                                    "data": [{"type": "appStoreVersionLocalizations", "id": "loc-1"}]
                                },
                                "appStoreReviewDetail": {
                                    "data": {"type": "appStoreReviewDetails", "id": "detail-1"}
                                },
                            },
                        }
                    }
                if method == "PATCH" and path == "/appStoreVersionLocalizations/loc-1":
                    assert body is not None
                    attributes = body["data"]["attributes"]
                    if "whatsNew" in attributes:
                        raise submit_app_store_review.AppStoreConnectError(
                            "App Store Connect request failed: PATCH /appStoreVersionLocalizations/loc-1",
                            status=409,
                            payload={
                                "errors": [
                                    {
                                        "code": "STATE_ERROR",
                                        "detail": "Attribute 'whatsNew' cannot be edited at this time",
                                    }
                                ]
                            },
                        )
                    return {"data": {"id": "loc-1"}}
                if method == "PATCH" and path == "/appStoreReviewDetails/detail-1":
                    return {"data": {"id": "detail-1"}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = MetadataClient()
        args = SimpleNamespace(
            locale=None,
            support_url=None,
            whats_new="Adds CloudKit companion sync.",
            review_notes="Physical Apple TV demo: https://example.com/reviewer-demo.mp4",
        )

        submit_app_store_review.ensure_metadata(
            client,
            "version-1-0-35",
            {"locale": "en-US", "description": "desc", "keywords": "usage", "supportUrl": "https://example.com"},
            {"contactEmail": "review@example.com"},
            args,
        )

        localization_updates = []
        for request in client.requests:
            if request[0] != "PATCH" or request[1] != "/appStoreVersionLocalizations/loc-1":
                continue
            body = request[3]
            assert body is not None
            localization_updates.append(body["data"]["attributes"])
        self.assertIn("whatsNew", localization_updates[0])
        self.assertNotIn("whatsNew", localization_updates[1])
        self.assertEqual(localization_updates[1]["description"], "desc")
        review_detail_update = next(
            request[3]["data"]["attributes"]
            for request in client.requests
            if request[0] == "PATCH" and request[1] == "/appStoreReviewDetails/detail-1"
        )
        self.assertEqual(
            review_detail_update["notes"],
            "Physical Apple TV demo: https://example.com/reviewer-demo.mp4",
        )
        self.assertEqual(review_detail_update["contactEmail"], "review@example.com")

    def test_ensure_metadata_clears_copied_tvos_review_notes(self):
        class MetadataClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/appStoreVersions/version-1-0-50":
                    return {
                        "data": {
                            "id": "version-1-0-50",
                            "attributes": {"appStoreState": "PREPARE_FOR_SUBMISSION"},
                            "relationships": {
                                "appStoreVersionLocalizations": {
                                    "data": [{"type": "appStoreVersionLocalizations", "id": "loc-1"}]
                                },
                                "appStoreReviewDetail": {
                                    "data": {"type": "appStoreReviewDetails", "id": "detail-1"}
                                },
                            },
                        }
                    }
                if method == "PATCH" and path in {
                    "/appStoreVersionLocalizations/loc-1",
                    "/appStoreReviewDetails/detail-1",
                }:
                    return {"data": {"id": path.rsplit("/", maxsplit=1)[-1]}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = MetadataClient()
        args = SimpleNamespace(
            platform="TV_OS",
            tvos_demo_video_url=None,
            review_notes=None,
            locale=None,
            support_url=None,
            whats_new="Improves synced provider availability.",
        )

        submit_app_store_review.ensure_metadata(
            client,
            "version-1-0-50",
            {"locale": "en-US", "description": "desc", "supportUrl": "https://example.com"},
            {"contactEmail": "review@example.com", "notes": "Physical Apple TV demo:\nhttps://old.example/demo.mp4"},
            args,
        )

        review_detail_update = next(
            request[3]["data"]["attributes"]
            for request in client.requests
            if request[0] == "PATCH" and request[1] == "/appStoreReviewDetails/detail-1"
        )
        self.assertEqual(review_detail_update["notes"], "")
        self.assertEqual(review_detail_update["contactEmail"], "review@example.com")

    def test_prepare_only_path_does_not_create_or_submit_review(self):
        class PrepareOnlyClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if "/reviewSubmissions" in path or "/reviewSubmissionItems" in path:
                    raise AssertionError(f"prepare-only must not call review endpoint: {method} {path}")
                if method == "GET" and path == "/apps/app-id/appStoreVersions":
                    return {
                        "data": [
                            {
                                "id": "version-1-0-14",
                                "attributes": {
                                    "versionString": "1.0.14",
                                    "appStoreState": "PREPARE_FOR_SUBMISSION",
                                },
                            }
                        ]
                    }
                if method == "PATCH" and path == "/appStoreVersions/version-1-0-14":
                    return {"data": {"id": "version-1-0-14"}}
                if method == "GET" and path == "/appStoreVersions/version-1-0-14":
                    return {
                        "data": {
                            "id": "version-1-0-14",
                            "attributes": {"appStoreState": "PREPARE_FOR_SUBMISSION"},
                            "relationships": {
                                "appStoreVersionLocalizations": {
                                    "data": [{"type": "appStoreVersionLocalizations", "id": "loc-1"}]
                                },
                                "appStoreReviewDetail": {
                                    "data": {"type": "appStoreReviewDetails", "id": "detail-1"}
                                },
                            },
                        }
                    }
                if method == "PATCH" and path == "/appStoreVersionLocalizations/loc-1":
                    return {"data": {"id": "loc-1"}}
                if method == "PATCH" and path == "/appStoreReviewDetails/detail-1":
                    return {"data": {"id": "detail-1"}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = PrepareOnlyClient()
        args = SimpleNamespace(
            version="1.0.14",
            remove_active_review_version=None,
            release_type="AFTER_APPROVAL",
            copyright="2026 Shiny Computers Leasing LLC",
            uses_idfa=False,
            locale=None,
            support_url=None,
            whats_new="Fixes and improvements.",
        )

        version, _ = submit_app_store_review.ensure_replacement_version(client, "app-id", args)
        submit_app_store_review.ensure_metadata(
            client,
            version["id"],
            {"locale": "en-US", "description": "desc", "supportUrl": "https://example.com"},
            {"contactEmail": "review@example.com"},
            args,
        )

        review_paths = [
            request[1]
            for request in client.requests
            if "/reviewSubmissions" in request[1] or "/reviewSubmissionItems" in request[1]
        ]
        self.assertEqual(review_paths, [])

    def test_ensure_review_submission_does_not_reuse_empty_ready_submission(self):
        class EmptyReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "empty-submission",
                                "attributes": {"state": "READY_FOR_REVIEW", "platform": "MAC_OS"},
                                "relationships": {"items": {"data": []}},
                            }
                        ]
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    assert body is not None
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    assert body is not None
                    assert (
                        body["data"]["relationships"]["reviewSubmission"]["data"]["id"]
                        == "new-submission"
                    )
                    return {"data": {"id": "item-1"}}
                if method == "PATCH" and path == "/reviewSubmissions/new-submission":
                    return {"data": {"id": "new-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = EmptyReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-14",
            "MAC_OS",
        )

        self.assertEqual(submission["id"], "new-submission")
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, ["/reviewSubmissions", "/reviewSubmissionItems"])
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/new-submission"])
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        assert_review_submission_submit_body(self, patch_body)
        submission_post_body = next(
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissions"
        )
        self.assertEqual(submission_post_body["data"]["attributes"], {"platform": "MAC_OS"})

    def test_ensure_review_submission_does_not_reuse_cross_platform_ready_for_sale_orphan(self):
        class CrossPlatformOrphanReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    if params and "filter[platform]" in params:
                        return {"data": []}
                    return {
                        "data": [
                            {
                                "id": "cross-platform-orphan-submission",
                                "attributes": {
                                    "state": "READY_FOR_REVIEW",
                                    "platform": None,
                                    "submittedDate": None,
                                },
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "released-ios-version"}
                                    },
                                    "items": {"data": []},
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "released-ios-version",
                                "type": "appStoreVersions",
                                "attributes": {
                                    "platform": "IOS",
                                    "versionString": "1.0.48",
                                    "appStoreState": "READY_FOR_SALE",
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    assert body is not None
                    assert "appStoreVersionForReview" not in body["data"]["relationships"]
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    return {"data": {"id": "vision-item"}}
                if method == "PATCH" and path == "/reviewSubmissions/new-submission":
                    return {
                        "data": {
                            "id": "new-submission",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = CrossPlatformOrphanReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "vision-version",
        )

        self.assertEqual(submission["id"], "new-submission")
        get_params = next(request[2] for request in client.requests if request[0] == "GET")
        self.assertNotIn("filter[platform]", get_params)
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, ["/reviewSubmissions", "/reviewSubmissionItems"])

    @patch.object(submit_app_store_review, "wait_for_active_review_submission_for_version", return_value=None)
    def test_ensure_review_submission_reports_active_reviews_at_limit(self, _wait_for_owner):
        class LegitimateReviewSubmissionLimitClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "submitted-mac-review",
                                "attributes": {
                                    "state": "WAITING_FOR_REVIEW",
                                    "platform": "MAC_OS",
                                    "submittedDate": "2026-07-24T18:00:00Z",
                                },
                                "relationships": {
                                    "appStoreVersionForReview": {
                                        "data": {"type": "appStoreVersions", "id": "mac-version"}
                                    },
                                    "items": {"data": []},
                                },
                            }
                        ],
                        "included": [],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "review submission limit exceeded",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "code": "STATE_ERROR.CONCURRENT_REVIEW_SUBMISSION_LIMIT_EXCEEDED"
                                }
                            ]
                        },
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        client = LegitimateReviewSubmissionLimitClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "inspect the active submissions",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "vision-version",
            )

        canceled_requests = [
            request
            for request in client.requests
            if request[0] == "PATCH"
        ]
        self.assertEqual(canceled_requests, [])

    @patch.object(submit_app_store_review, "wait_for_active_review_submission_for_version", return_value=None)
    def test_ensure_review_submission_rejects_ambiguous_empty_submission_at_limit(self, _wait_for_owner):
        class AmbiguousReviewSubmissionLimitClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "ownerless-submission",
                                "attributes": {"state": "READY_FOR_REVIEW", "platform": "VISION_OS"},
                                "relationships": {"items": {"data": []}},
                            }
                        ]
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "review submission limit exceeded",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "code": "STATE_ERROR.CONCURRENT_REVIEW_SUBMISSION_LIMIT_EXCEEDED"
                                }
                            ]
                        },
                    )
                raise AssertionError(f"unexpected request: {method} {path}")

        client = AmbiguousReviewSubmissionLimitClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "itemless submissions are not reused",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
                "VISION_OS",
            )

        self.assertFalse(any(request[1] == "/reviewSubmissionItems" for request in client.requests))
        self.assertFalse(any(request[0] == "PATCH" for request in client.requests))

    def test_ensure_review_submission_recovers_exact_owner_when_creation_hits_limit(self):
        class ExactOwnerReviewSubmissionLimitClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count == 1:
                        return {"data": [], "included": []}
                    return {
                        "data": [
                            {
                                "id": "winning-submission",
                                "attributes": {"state": "READY_FOR_REVIEW", "platform": "IOS"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "target-version"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    raise submit_app_store_review.AppStoreConnectError(
                        "review submission limit exceeded",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "code": "STATE_ERROR.CONCURRENT_REVIEW_SUBMISSION_LIMIT_EXCEEDED"
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/winning-submission/items":
                    return {
                        "data": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "target-version"}
                                    }
                                },
                            }
                        ]
                    }
                if method == "PATCH" and path == "/reviewSubmissions/winning-submission":
                    return {
                        "data": {
                            "id": "winning-submission",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ExactOwnerReviewSubmissionLimitClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "target-version",
            "IOS",
        )

        self.assertEqual(submission["id"], "winning-submission")
        self.assertFalse(any(request[1] == "/reviewSubmissionItems" for request in client.requests))
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/winning-submission"])

    def test_ensure_review_submission_ignores_ready_submission_for_other_version(self):
        class StaleReadyReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "stale-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "stale-item"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "stale-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-13"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    return {"data": {"id": "new-item"}}
                if method == "PATCH" and path == "/reviewSubmissions/new-submission":
                    return {"data": {"id": "new-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = StaleReadyReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-14",
        )

        self.assertEqual(submission["id"], "new-submission")
        post_paths = [request[1] for request in client.requests if request[0] == "POST"]
        self.assertEqual(post_paths, ["/reviewSubmissions", "/reviewSubmissionItems"])
        submission_post_body = next(
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissions"
        )
        self.assertNotIn("appStoreVersionForReview", submission_post_body["data"]["relationships"])
        self.assertEqual(
            submission_post_body["data"]["relationships"]["app"],
            {"data": {"type": "apps", "id": "app-id"}},
        )

    def test_ensure_review_submission_creates_app_only_submission(self):
        class AppOnlyReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                if method == "POST" and path == "/reviewSubmissions":
                    assert body is not None
                    relationships = body["data"]["relationships"]
                    assert "appStoreVersionForReview" not in relationships
                    assert body["data"]["attributes"] == {"platform": "TV_OS"}
                    return {"data": {"id": "app-only-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    return {"data": {"id": "app-only-item"}}
                if method == "PATCH" and path == "/reviewSubmissions/app-only-submission":
                    return {"data": {"id": "app-only-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = AppOnlyReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-35",
            "TV_OS",
        )

        self.assertEqual(submission["id"], "app-only-submission")
        submission_posts = [
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissions"
        ]
        self.assertEqual(len(submission_posts), 1)
        assert submission_posts[0] is not None
        self.assertNotIn("appStoreVersionForReview", submission_posts[0]["data"]["relationships"])
        self.assertEqual(submission_posts[0]["data"]["attributes"], {"platform": "TV_OS"})
        review_item_posts = [
            request[3]
            for request in client.requests
            if request[0] == "POST" and request[1] == "/reviewSubmissionItems"
        ]
        self.assertEqual(
            review_item_posts[0]["data"]["relationships"]["appStoreVersion"]["data"]["id"],
            "version-1-0-35",
        )

    def test_ensure_review_submission_submits_matching_ready_submission(self):
        class ReadyReviewSubmissionClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {
                        "data": [
                            {
                                "id": "ready-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-14"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "GET" and path == "/reviewSubmissions/ready-submission/items":
                    return {
                        "data": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-14"}
                                    }
                                },
                            }
                        ]
                    }
                if method == "PATCH" and path == "/reviewSubmissions/ready-submission":
                    return {"data": {"id": "ready-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ReadyReviewSubmissionClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-14",
        )

        self.assertEqual(submission["id"], "ready-submission")
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/ready-submission"])
        patch_body = next(request[3] for request in client.requests if request[0] == "PATCH")
        assert_review_submission_submit_body(self, patch_body)

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_ensure_review_submission_retries_live_duplicate_item_conflict(self, _sleep):
        class ExistingItemDelayedVisibilityClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count < 3:
                        return {"data": [], "included": []}
                    return {
                        "data": [
                            {
                                "id": "winning-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "version-1-0-40"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "losing-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id version-1-0-40 was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/losing-submission/items":
                    return {"data": []}
                if method == "PATCH" and path == "/reviewSubmissions/losing-submission":
                    assert body is not None
                    assert body["data"]["attributes"] == {"canceled": True}
                    return {"data": {"id": "losing-submission", "attributes": {"state": "CANCELED"}}}
                if method == "PATCH" and path == "/reviewSubmissions/winning-submission":
                    return {"data": {"id": "winning-submission", "attributes": {"state": "WAITING_FOR_REVIEW"}}}
                raise AssertionError(f"unexpected request: {method} {path}")

        client = ExistingItemDelayedVisibilityClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "version-1-0-40",
        )

        self.assertEqual(submission["id"], "winning-submission")
        self.assertEqual(client.review_submissions_get_count, 3)
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(
            patch_paths,
            [
                "/reviewSubmissions/losing-submission",
                "/reviewSubmissions/winning-submission",
            ],
        )

    def test_ensure_review_submission_does_not_cancel_unresolved_item_owner(self):
        class UnresolvedItemOwnerClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": [], "included": []}
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id target-version was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/new-submission/items":
                    return {
                        "data": [
                            {
                                "id": "unresolved-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {},
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = UnresolvedItemOwnerClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "ownership is unavailable",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
                "IOS",
            )

        self.assertFalse(any(request[0] == "PATCH" for request in client.requests))

    @patch.object(submit_app_store_review.time, "sleep", return_value=None)
    def test_ensure_review_submission_continues_when_losing_draft_cleanup_fails(self, _sleep):
        class CleanupFailureClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count == 1:
                        return {"data": [], "included": []}
                    return {
                        "data": [
                            {
                                "id": "winning-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                                },
                            }
                        ],
                        "included": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "target-version"}
                                    }
                                },
                            }
                        ],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "losing-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id target-version was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/losing-submission/items":
                    return {"data": []}
                if method == "PATCH" and path == "/reviewSubmissions/losing-submission":
                    raise urllib.error.URLError("temporary cleanup failure")
                if method == "PATCH" and path == "/reviewSubmissions/winning-submission":
                    return {
                        "data": {
                            "id": "winning-submission",
                            "attributes": {"state": "WAITING_FOR_REVIEW"},
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = CleanupFailureClient()

        submission = submit_app_store_review.ensure_review_submission(
            client,
            "app-id",
            "target-version",
            "IOS",
        )

        self.assertEqual(submission["id"], "winning-submission")
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(
            patch_paths,
            [
                "/reviewSubmissions/losing-submission",
                "/reviewSubmissions/winning-submission",
            ],
        )

    def test_ensure_review_submission_revalidates_before_canceling_after_owner_error(self):
        class DelayedUnresolvedOwnerClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0
                self.item_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count == 1:
                        return {"data": [], "included": []}
                    return {
                        "data": [
                            {
                                "id": "created-submission",
                                "attributes": {"state": "READY_FOR_REVIEW"},
                                "relationships": {
                                    "items": {
                                        "data": [
                                            {
                                                "type": "reviewSubmissionItems",
                                                "id": "late-item",
                                            }
                                        ]
                                    }
                                },
                            }
                        ],
                        "included": [],
                    }
                if method == "POST" and path == "/reviewSubmissions":
                    return {
                        "data": {
                            "id": "created-submission",
                            "attributes": {"state": "READY_FOR_REVIEW"},
                        }
                    }
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id target-version was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/created-submission/items":
                    self.item_get_count += 1
                    if self.item_get_count == 1:
                        return {"data": []}
                    return {
                        "data": [
                            {
                                "id": "late-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {},
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = DelayedUnresolvedOwnerClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "ownership is unavailable",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
                "IOS",
            )

        self.assertGreaterEqual(client.item_get_count, 3)
        self.assertFalse(any(request[0] == "PATCH" for request in client.requests))

    def test_ensure_review_submission_cleans_empty_draft_when_owner_discovery_transport_fails(self):
        class OwnerDiscoveryTransportFailureClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []
                self.review_submissions_get_count = 0
                self.item_get_count = 0

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    self.review_submissions_get_count += 1
                    if self.review_submissions_get_count == 1:
                        return {"data": [], "included": []}
                    raise urllib.error.URLError("offline")
                if method == "POST" and path == "/reviewSubmissions":
                    return {
                        "data": {
                            "id": "created-submission",
                            "attributes": {"state": "READY_FOR_REVIEW"},
                        }
                    }
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {
                                    "title": (
                                        "appStoreVersion with id target-version was already added "
                                        "to this reviewSubmission."
                                    )
                                }
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/created-submission/items":
                    self.item_get_count += 1
                    return {"data": []}
                if method == "PATCH" and path == "/reviewSubmissions/created-submission":
                    assert body is not None
                    assert body["data"]["attributes"] == {"canceled": True}
                    return {
                        "data": {
                            "id": "created-submission",
                            "attributes": {"state": "CANCELED"},
                        }
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = OwnerDiscoveryTransportFailureClient()

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "owner discovery failed",
        ):
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
                "IOS",
            )

        self.assertEqual(client.item_get_count, 2)
        patch_paths = [request[1] for request in client.requests if request[0] == "PATCH"]
        self.assertEqual(patch_paths, ["/reviewSubmissions/created-submission"])

    def test_wait_for_active_review_submission_for_version_returns_none_after_timeout(self):
        class InvisibleOwnerClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": [], "included": []}
                raise AssertionError(f"unexpected request: {method} {path}")

        submission = submit_app_store_review.wait_for_active_review_submission_for_version(
            InvisibleOwnerClient(),
            "app-id",
            "version-1-0-40",
            timeout_seconds=0,
        )

        self.assertIsNone(submission)

    def test_active_review_submission_rejects_mixed_version_ownership(self):
        class NoRequestsClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                raise AssertionError(f"unexpected request: {method} {path}")

        submissions = {
            "data": [
                {
                    "id": "mixed-submission",
                    "attributes": {"state": "READY_FOR_REVIEW"},
                    "relationships": {
                        "appStoreVersionForReview": {
                            "data": {"type": "appStoreVersions", "id": "target-version"}
                        },
                        "items": {"data": [{"type": "reviewSubmissionItems", "id": "other-item"}]},
                    },
                }
            ],
            "included": [
                {
                    "id": "other-item",
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": "other-version"}
                        }
                    },
                }
            ],
        }

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "already contains another App Store version",
        ):
            submit_app_store_review.active_review_submission_for_version(
                NoRequestsClient(),
                submissions,
                "target-version",
            )

    def test_active_review_submission_rejects_multiple_exact_owners(self):
        class NoRequestsClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                raise AssertionError(f"unexpected request: {method} {path}")

        submissions = {
            "data": [
                {
                    "id": "submission-1",
                    "attributes": {"state": "READY_FOR_REVIEW"},
                    "relationships": {
                        "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                    },
                },
                {
                    "id": "submission-2",
                    "attributes": {"state": "READY_FOR_REVIEW"},
                    "relationships": {
                        "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-2"}]}
                    },
                },
            ],
            "included": [
                {
                    "id": "item-1",
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": "target-version"}
                        }
                    },
                },
                {
                    "id": "item-2",
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": "target-version"}
                        }
                    },
                },
            ],
        }

        with self.assertRaisesRegex(
            submit_app_store_review.AppStoreConnectError,
            "multiple active review submissions claim",
        ):
            submit_app_store_review.active_review_submission_for_version(
                NoRequestsClient(),
                submissions,
                "target-version",
            )

    def test_active_review_submission_resolves_missing_included_item_owner(self):
        class ItemOwnerClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions/submission-1/items":
                    return {
                        "data": [
                            {
                                "id": "item-1",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "target-version"}
                                    }
                                },
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        submissions = {
            "data": [
                {
                    "id": "submission-1",
                    "attributes": {"state": "READY_FOR_REVIEW"},
                    "relationships": {
                        "items": {"data": [{"type": "reviewSubmissionItems", "id": "item-1"}]}
                    },
                }
            ],
            "included": [],
        }
        client = ItemOwnerClient()

        submission = submit_app_store_review.active_review_submission_for_version(
            client,
            submissions,
            "target-version",
        )

        self.assertEqual(submission["id"], "submission-1")
        self.assertEqual(
            [request[1] for request in client.requests],
            ["/reviewSubmissions/submission-1/items"],
        )

    def test_active_review_submission_ignores_ready_for_sale_orphan(self):
        class NoRequestsClient:
            def request(self, method, path, params=None, body=None, allowed=(200,)):
                raise AssertionError(f"unexpected request: {method} {path}")

        submissions = {
            "data": [
                {
                    "id": "released-orphan",
                    "attributes": {
                        "state": "READY_FOR_REVIEW",
                        "platform": None,
                        "submittedDate": None,
                    },
                    "relationships": {
                        "appStoreVersionForReview": {
                            "data": {"type": "appStoreVersions", "id": "target-version"}
                        },
                        "items": {"data": []},
                    },
                }
            ],
            "included": [
                {
                    "id": "target-version",
                    "type": "appStoreVersions",
                    "attributes": {
                        "platform": "IOS",
                        "versionString": "1.0.50",
                        "appStoreState": "READY_FOR_SALE",
                    },
                }
            ],
        }

        submission = submit_app_store_review.active_review_submission_for_version(
            NoRequestsClient(),
            submissions,
            "target-version",
        )

        self.assertIsNone(submission)

    def test_ensure_review_submission_rejects_taken_version_slot(self):
        class TakenVersionSlotClient:
            def __init__(self):
                self.requests: list[tuple[Any, ...]] = []

            def request(self, method, path, params=None, body=None, allowed=(200,)):
                self.requests.append((method, path, params, body, allowed))
                if method == "GET" and path == "/reviewSubmissions":
                    return {"data": []}
                if method == "POST" and path == "/reviewSubmissions":
                    return {"data": {"id": "new-submission", "attributes": {"state": "READY_FOR_REVIEW"}}}
                if method == "POST" and path == "/reviewSubmissionItems":
                    raise submit_app_store_review.AppStoreConnectError(
                        "App Store Connect request failed: POST /reviewSubmissionItems",
                        status=409,
                        payload={
                            "errors": [
                                {"title": "Only one appStoreVersion can be present in reviewSubmissions."}
                            ]
                        },
                    )
                if method == "GET" and path == "/reviewSubmissions/new-submission/items":
                    return {
                        "data": [
                            {
                                "id": "other-item",
                                "type": "reviewSubmissionItems",
                                "relationships": {
                                    "appStoreVersion": {
                                        "data": {"type": "appStoreVersions", "id": "other-version"}
                                    }
                                },
                            }
                        ]
                    }
                raise AssertionError(f"unexpected request: {method} {path}")

        client = TakenVersionSlotClient()

        with self.assertRaises(submit_app_store_review.AppStoreConnectError) as context:
            submit_app_store_review.ensure_review_submission(
                client,
                "app-id",
                "target-version",
            )

        self.assertIn("separate review submission", str(context.exception))
        self.assertFalse(any(request[0] == "PATCH" for request in client.requests))


if __name__ == "__main__":
    unittest.main()
