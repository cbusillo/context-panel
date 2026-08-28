import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

corpus_module = importlib.import_module("context_panel_replay.corpus")
CorpusError = corpus_module.CorpusError
check_compiled = corpus_module.check_compiled
compile_corpus = corpus_module.compile_corpus
evaluate_candidate_policy = corpus_module.evaluate_candidate_policy
render_json = corpus_module.render_json
write_compiled = corpus_module.write_compiled

CORPUS_PATH = REPO_ROOT / "Config/ContextPanelPhysicalDefectCorpus.json"
SURFACE_POLICY_PATH = REPO_ROOT / "Config/ContextPanelSurfacePolicy.json"
COMPILED_PATH = REPO_ROOT / "scripts/context_panel_replay/corpus/compiled.json"
CLI_PATH = REPO_ROOT / "scripts/context-panel-defect-corpus.py"
EARLY_CUTOFF_COMMIT = "46ceb002aa5fab7dfdeaa647a99763480fbff98d"
SIBLING_COMMIT = "87c2db78a3e680d742ac663fcd3cf7c773bfe380"


class PhysicalDefectCorpusTests(unittest.TestCase):
    def source(self) -> dict:
        return json.loads(CORPUS_PATH.read_text())

    def compile_mutated(self, source: dict) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "corpus.json"
            path.write_text(json.dumps(source, indent=2) + "\n")
            return compile_corpus(path, SURFACE_POLICY_PATH)

    def assert_invalid(self, mutate) -> None:
        source = self.source()
        mutate(source)
        with self.assertRaises(CorpusError):
            self.compile_mutated(source)

    def test_compiled_artifact_is_current_and_byte_identical(self):
        payload = check_compiled(CORPUS_PATH, SURFACE_POLICY_PATH, COMPILED_PATH)
        self.assertEqual(COMPILED_PATH.read_bytes(), render_json(payload))
        with tempfile.TemporaryDirectory() as directory:
            regenerated = Path(directory) / "compiled.json"
            write_compiled(compile_corpus(CORPUS_PATH, SURFACE_POLICY_PATH), regenerated)
            self.assertEqual(regenerated.read_bytes(), COMPILED_PATH.read_bytes())

    def test_actual_positive_diffs_match_and_near_misses_do_not(self):
        source = self.source()
        for incident in source["incidents"]:
            positive = corpus_module._combine_commit_changes(
                [citation["implementationCommit"] for citation in incident["citations"]],
                base_commits=[
                    corpus_module._git_output(
                        ["show", "-s", "--format=%P", citation["mergeCommit"]]
                    ).split()[0]
                    for citation in incident["citations"]
                ],
            )
            negative = corpus_module._commit_change(incident["negativeNearMiss"]["commit"])
            self.assertTrue(evaluate_candidate_policy(incident["candidatePolicy"], positive)["matches"])
            self.assertFalse(evaluate_candidate_policy(incident["candidatePolicy"], negative)["matches"])
            self.assertNotEqual(positive["patchDigest"], negative["patchDigest"])

    def test_git_version_and_scrubbed_lazy_fetch_are_enforced(self):
        source = self.source()
        source["gitVersion"] = "2.54.0"
        with self.assertRaisesRegex(
            CorpusError,
            "installed Git version 2.55.0 does not match corpus-required version 2.54.0",
        ):
            self.compile_mutated(source)
        completed = subprocess.CompletedProcess(["git", "--version"], 0, "git version 2.55.0\n", "")
        with mock.patch.object(corpus_module.subprocess, "run", return_value=completed) as run:
            corpus_module._git_output(["--version"])
        self.assertEqual(run.call_args.kwargs["env"]["GIT_NO_LAZY_FETCH"], "1")

    def test_compiled_changes_are_derived_and_patch_free(self):
        payload = compile_corpus(CORPUS_PATH, SURFACE_POLICY_PATH)
        positives = [case for case in payload["cases"] if case["caseKind"] == "positive"]
        negatives = [case for case in payload["cases"] if case["caseKind"] == "negative-near-miss"]
        self.assertEqual(len(positives), 4)
        self.assertEqual(len(negatives), 4)
        for case in payload["cases"]:
            self.assertNotIn("patch", case["change"])
            self.assertTrue(case["change"]["paths"])
            self.assertIn("patchDigest", case["change"])
        for incident in self.source()["incidents"]:
            self.assertNotIn("positive", incident)
            self.assertNotIn("riskSignals", incident["candidatePolicy"])

    def test_added_patch_lines_keep_source_content_starting_with_plus(self):
        self.assertEqual(
            corpus_module._added_patch_lines(
                "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+++ value\n"
                "diff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -0,0 +1 @@\n+normal\n"
            ),
            ["+++ value", "+normal"],
        )

    def test_matcher_mutations_and_unsupported_paths_are_rejected(self):
        self.assert_invalid(
            lambda source: source["incidents"][0]["candidatePolicy"]["pathMatchers"].__setitem__(
                0, "AGENTS.md"
            )
        )
        self.assert_invalid(
            lambda source: source["incidents"][0]["candidatePolicy"].__setitem__(
                "pathMatchers", "Sources/ContextPanelTV/ContextPanelTVApp.swift"
            )
        )
        self.assert_invalid(
            lambda source: source["incidents"][0]["candidatePolicy"]["diffContentMatchers"].__setitem__(
                0, "never-matches-this-historical-diff"
            )
        )
        self.assert_invalid(
            lambda source: source["incidents"][0]["candidatePolicy"]["diffContentMatchers"].__setitem__(
                0, r"^\+{3} b/Sources/ContextPanelTV/TVPreviewFixtures\.swift$"
            )
        )
        self.assert_invalid(
            lambda source: source["incidents"][0]["candidatePolicy"]["diffContentMatchers"].__setitem__(
                0,
                r"^\+(?:        let localCacheLocations = TVLocalCacheLocations\.live\(\)|\+{2} b/public/path\.swift)$",
            )
        )
        self.assert_invalid(
            lambda source: source["incidents"][0].__setitem__(
                "positive", {"paths": ["AGENTS.md"]}
            )
        )

    def test_rejects_identical_negative_commit_and_ancestry_breaks(self):
        self.assert_invalid(
            lambda source: source["incidents"][0]["negativeNearMiss"].__setitem__(
                "commit", source["incidents"][0]["citations"][0]["implementationCommit"]
            )
        )
        self.assert_invalid(
            lambda source: source.__setitem__("curatedThroughCommit", EARLY_CUTOFF_COMMIT)
        )
        self.assert_invalid(
            lambda source: source["incidents"][0]["negativeNearMiss"].__setitem__(
                "commit", SIBLING_COMMIT
            )
        )

    def test_repository_anchors_are_checked_at_the_curation_cutoff(self):
        self.assert_invalid(
            lambda source: source["residualRisks"][2]["citations"][0].update(
                path="Config/ContextPanelPhysicalDefectCorpus.json", anchor="pathMatchers"
            )
        )

    def test_compilation_is_independent_of_head_and_ambient_git_config(self):
        baseline = compile_corpus(CORPUS_PATH, SURFACE_POLICY_PATH)
        with tempfile.TemporaryDirectory() as directory:
            clone = Path(directory) / "repository.git"
            subprocess.run(
                ["git", "clone", "--shared", "--no-checkout", str(REPO_ROOT), str(clone)],
                capture_output=True,
                check=True,
                text=True,
            )
            for key, value in (
                ("color.ui", "always"),
                ("core.abbrev", "20"),
                ("diff.algorithm", "histogram"),
                ("diff.context", "7"),
                ("diff.indentHeuristic", "false"),
                ("diff.interHunkContext", "6"),
                ("diff.noprefix", "true"),
                ("log.showSignature", "true"),
            ):
                subprocess.run(
                    ["git", "-C", str(clone), "config", key, value],
                    capture_output=True,
                    check=True,
                    text=True,
                )
            positive_commit = self.source()["incidents"][0]["citations"][0][
                "implementationCommit"
            ]
            replacement_commit = self.source()["incidents"][0]["negativeNearMiss"]["commit"]
            subprocess.run(
                ["git", "-C", str(clone), "replace", positive_commit, replacement_commit],
                capture_output=True,
                check=True,
                text=True,
            )
            inherited = {
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "diff.indentHeuristic",
                "GIT_CONFIG_VALUE_0": "false",
                "GIT_DIR": str(Path(directory) / "wrong.git"),
                "GIT_WORK_TREE": str(Path(directory) / "wrong-worktree"),
            }
            originals = {key: os.environ.get(key) for key in inherited}
            os.environ.update(inherited)
            try:
                with mock.patch.object(corpus_module, "REPO_ROOT", clone):
                    self.assertEqual(
                        compile_corpus(CORPUS_PATH, clone / "Config/ContextPanelSurfacePolicy.json"),
                        baseline,
                    )
                    info_attributes = clone / ".git/info/attributes"
                    info_attributes.parent.mkdir(parents=True, exist_ok=True)
                    info_attributes.write_text("*.swift -diff\n")
                    with self.assertRaisesRegex(
                        CorpusError,
                        "repository-local Git attributes",
                    ):
                        compile_corpus(
                            CORPUS_PATH,
                            clone / "Config/ContextPanelSurfacePolicy.json",
                        )
                    info_attributes.unlink()
                    grafts = clone / ".git/info/grafts"
                    grafts.write_text(f"{positive_commit} {replacement_commit}\n")
                    with self.assertRaisesRegex(
                        CorpusError,
                        "repository-local Git grafts",
                    ):
                        compile_corpus(
                            CORPUS_PATH,
                            clone / "Config/ContextPanelSurfacePolicy.json",
                        )
            finally:
                for key, value in originals.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value

    def test_multi_commit_pull_request_change_includes_the_full_pr_diff(self):
        citation = {
            "implementationCommit": "75ece4dfa2d283204a9852b69398fea9215b8a83",
            "kind": "pull-request",
            "mergeCommit": "a93ab1fb94bb56fe6600ca68810841610d7e5702",
            "number": 618,
        }
        parents = corpus_module._git_output(
            ["show", "-s", "--format=%P", citation["mergeCommit"]]
        ).split()
        self.assertEqual(parents[1], citation["implementationCommit"])
        change = corpus_module._combine_citation_changes([citation])
        expected_paths = corpus_module._git_output(
            ["diff", "--name-only", "--no-renames", parents[0], parents[1]]
        ).splitlines()
        self.assertEqual(change["paths"], sorted(expected_paths))
        last_commit_only = corpus_module._commit_change(citation["implementationCommit"])
        self.assertGreater(set(change["paths"]), set(last_commit_only["paths"]))

    def test_near_misses_share_candidate_paths_and_use_distinct_commits(self):
        source = self.source()
        commits = []
        for incident in source["incidents"]:
            near_miss = corpus_module._commit_change(incident["negativeNearMiss"]["commit"])
            self.assertTrue(
                any(
                    path in near_miss["paths"]
                    for path in incident["candidatePolicy"]["pathMatchers"]
                )
            )
            self.assertLessEqual(
                set(incident["negativeNearMiss"]["surfaces"]),
                set(incident["affectedSurfaces"]),
            )
            commits.append(incident["negativeNearMiss"]["commit"])
        self.assertEqual(len(commits), len(set(commits)))

    def test_surface_policy_oracles_and_summary_remain_exact(self):
        payload = compile_corpus(CORPUS_PATH, SURFACE_POLICY_PATH)
        positives = {case["id"]: case for case in payload["cases"] if case["caseKind"] == "positive"}
        negatives = [case for case in payload["cases"] if case["caseKind"] == "negative-near-miss"]
        self.assertIn(
            {
                "evidenceClass": "os-composited-placement",
                "sourceConstraint": "os-composited-physical",
                "surface": "tvos.top-shelf",
            },
            positives["tvos-top-shelf-shared-storage-domain"]["expectedEvidence"],
        )
        self.assertIn(
            {
                "evidenceClass": "actual-runtime",
                "sourceConstraint": "physical-exact-build",
                "surface": "watchos.complication",
            },
            positives["watch-complication-cache-convergence"]["expectedEvidence"],
        )
        for negative in negatives:
            positive = positives[negative["positiveID"]]
            self.assertTrue(negative["expectedEvidence"])
            self.assertLess(
                sum(item["sourceConstraint"] != "deterministic-gallery" for item in negative["expectedEvidence"]),
                sum(item["sourceConstraint"] != "deterministic-gallery" for item in positive["expectedEvidence"]),
            )
            self.assertTrue(negative["rationale"])
            self.assertIn(negative["rejectionStage"], {"path-match", "content-match"})
        rejection_stages = {case["id"]: case["rejectionStage"] for case in negatives}
        self.assertEqual(
            rejection_stages["tvos-runway-safe-area-focus-status-polish"],
            "content-match",
        )
        self.assertEqual(list(rejection_stages.values()).count("path-match"), 3)
        self.assertEqual(
            payload["summary"],
            {"caseCount": 8, "negativeNearMissCount": 4, "positiveCount": 4, "residualRiskCount": 8},
        )
        self.assertIn(
            "surface-policy-cutoff-drift",
            {risk["id"] for risk in payload["residualRisks"]},
        )

    def test_rejects_private_or_device_specific_corpus_content(self):
        unsafe_values = (
            "(/Users/example/public.swift)",
            "See file:///Users/example/public-receipt.json",
            "Authorization: Bearer public-value",
            "Bearer public-value",
            "Basic public-value",
            "client_secret=public-value",
            "access_token=public-value",
            "private_key=public-value",
            "refresh-token: public-value",
            "x-api-key: public-value",
            "aws_secret_access_key=public-value",
            "session_token=public-value",
            "auth_token=public-value",
            "consumer_secret=public-value",
            "signing_key=public-value",
            "account_id=public-account",
            "client_id=public-client",
            "openai_api_key=public-value",
            "anthropic_api_key=public-value",
            "google_api_key=public-value",
            "aws_access_key_id=public-value",
            "provider_account_id=public-account",
            "openaiApiKey=public-value",
            "anthropicApiKey: public-value",
            "vendorApiKey: public-value",
            "{\"provider_account_id\":\"public-account\"}",
            "https://example.com/?openaiApiKey=public-value",
            "(openaiApiKey=public-value)",
            "[anthropicApiKey: public-value]",
            "trace(userDeviceName=studio)",
            "config[\"openaiApiKey\"] = public-value",
            "{\"_openai_api_key\":\"public-value\"}",
            "`openaiApiKey`=public-value",
            "openai/api/key=public-value",
            "positive raw receipt=public-value",
            "user/device/name=public-value",
            "secret1=public-value",
            "apiKey1=public-value",
            "token0: public-value",
            "tokens[0]: public-value",
            "openaiSigningKey=public-value",
            "openaiOrganizationId=public-value",
            "openaiApiKey" + (" " * 120) + "=public-value",
            "ghp_AAAAAAAAAAAAAAAAAAAAAAAA",
            "x_ghp_AAAAAAAAAAAAAAAAAAAAAAAA",
            "_AKIAAAAAAAAAAAAAAAAA",
            "x_AKIAAAAAAAAAAAAAAAAA",
            "_AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "_ya29.AAAAAAAAAAAAAAAAAAAAAAAA",
            "_GOCSPX-AAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "_eyJAAAAAAAA.BBBBBBBB.CCCCCCCC",
            "github_pat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA",
            "sk-ant-AAAAAAAAAAAAAAAAAAAAAAAA",
            "AKIAAAAAAAAAAAAAAAAA",
            "AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "eyJAAAAAAAA.BBBBBBBB.CCCCCCCC",
            "owner@example.com",
            "acct_AAAAAAAAAAAAAAAAAAAAAAAA",
            "project_AAAAAAAAAAAAAAAAAAAAAAAA",
            "ya29.AAAAAAAAAAAAAAAAAAAAAAAA",
            "GOCSPX-AAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "1//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "4/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "GOCSPX-AAAAAAAAAAAAAAAAAAA-",
            "1//AAAAAAAAAAAAAAAAAAA-",
            "4/AAAAAAAAAAAAAAAAAAA-",
            "https://user:password@example.com/public-record",
            "https://user@example.com/public-record",
            "ssh://user:password@example.com/repository",
            "ftp://user:password@example.com/archive",
            "sftp://user:password@example.com/archive",
            "smb://user:password@example.com/share",
            "s3://user:password@example.com/bucket",
            "//user:password@example.com/share",
            "user:password@example.com",
            "localhost",
            "https://10.0.0.5/internal",
            "https://172.16.0.5/internal",
            "https://192.168.1.10/internal",
            "https://169.254.1.5/internal",
            "https://build-host.local/internal",
            "https://build-host.internal/status",
            "https://100.64.0.1/internal",
            "https://198.18.0.1/internal",
            "https://224.0.0.1/internal",
            "https://host.home.arpa/internal",
            "https://[::1]/internal",
            "https://[fe80::1]/internal",
            "https://[fc00::1]/internal",
            "device-id: public-device",
            "123e4567-e89b-12d3-a456-426614174000",
            "-----BEGIN OPENSSH KEY-----",
        )
        for unsafe in unsafe_values:
            with self.subTest(unsafe=unsafe):
                self.assert_invalid(lambda source: source["incidents"][0].__setitem__("observation", unsafe))
        self.assert_invalid(lambda source: source["incidents"][0].__setitem__("rawReceipt", "body"))

    def test_rejects_qualified_private_fields_and_compiled_payload_values(self):
        for key in (
            "openaiApiKey",
            "awsAccessKeyId",
            "providerAccountId",
            "positiveRawReceipt",
            "negativeReceiptBody",
            "userDeviceName",
            "openaiSecretKey",
            "googleProjectId",
        ):
            with self.subTest(key=key), self.assertRaises(CorpusError):
                corpus_module._public_safe({key: "public-value"})
        payload = compile_corpus(CORPUS_PATH, SURFACE_POLICY_PATH)
        for value in (
            "openai_api_key=public-value",
            "openaiApiKey=public-value",
            "{\"provider_account_id\":\"public-account\"}",
            "github_pat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "config[\"openaiApiKey\"] = public-value",
            "GOCSPX-AAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "1//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "`openaiApiKey`=public-value",
            "positive raw receipt=public-value",
            "GOCSPX-AAAAAAAAAAAAAAAAAAA-",
        ):
            with self.subTest(value=value), self.assertRaises(CorpusError):
                payload["cases"][0]["observation"] = value
                corpus_module._public_safe(payload, "compiled physical defect corpus")

    def test_allows_public_app_group_identifiers(self):
        source = self.source()
        source["incidents"][0]["observation"] = (
            "The public app-group identifier MM5YXC7T6E.group.com.shinycomputers.contextpanel "
            "keeps the app and widget on one shared state domain."
        )
        self.compile_mutated(source)

    def test_rejects_invalid_citations_and_stale_compiled_output(self):
        self.assert_invalid(
            lambda source: source["incidents"][0]["citations"][0].__setitem__("mergeCommit", "b1d8e0c")
        )
        self.assert_invalid(
            lambda source: source["incidents"][0]["citations"][0].__setitem__("number", 386)
        )
        self.assert_invalid(
            lambda source: source["residualRisks"][1]["citations"][1].__setitem__(
                "anchor", "missing public anchor"
            )
        )
        with tempfile.TemporaryDirectory() as directory:
            stale = Path(directory) / "compiled.json"
            stale.write_text("{}\n")
            with self.assertRaises(CorpusError):
                check_compiled(CORPUS_PATH, SURFACE_POLICY_PATH, stale)

    def test_shared_view_accepts_gallery_or_physical_provenance_only(self):
        source = self.source()
        shared_view = next(
            item
            for item in source["incidents"][3]["candidatePolicy"]["evidenceOracle"]
            if item["evidenceClass"] == "shared-view"
        )
        shared_view["sourceConstraint"] = "deterministic-gallery"
        self.compile_mutated(source)
        shared_view["evidenceClass"] = "actual-runtime"
        with self.assertRaises(CorpusError):
            self.compile_mutated(source)

    def test_cli_check_outputs_the_compiled_summary(self):
        completed = subprocess.run(
            [sys.executable, str(CLI_PATH), "check", "--json"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        summary = json.loads(completed.stdout)
        self.assertEqual(summary["state"], "OK")
        self.assertEqual(summary["summary"]["positiveCount"], 4)

    def test_production_policy_and_release_gate_modules_do_not_import_corpus(self):
        production_paths = [
            REPO_ROOT / "scripts/context_panel_surface_manifest",
            REPO_ROOT / "scripts/context_panel_release_gate",
            REPO_ROOT / "scripts/context-panel-surface-manifest.py",
            REPO_ROOT / "scripts/context-panel-release-gate.py",
        ]
        forbidden = ("context_panel_replay.corpus", "context-panel-defect-corpus")
        for path in production_paths:
            files = [path] if path.is_file() else sorted(path.rglob("*.py"))
            for file in files:
                self.assertFalse(any(value in file.read_text() for value in forbidden), file)


if __name__ == "__main__":
    unittest.main()
