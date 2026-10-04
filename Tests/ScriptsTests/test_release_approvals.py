import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from typing import Any
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release_approvals", Path(__file__).resolve().parents[2] / "scripts/check-release-approvals.py"
)
if spec is None or spec.loader is None:
    raise RuntimeError("release approval policy module could not be loaded")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def guard() -> dict[str, Any]:
    return {"permissions": {"actions": "read"}, "steps": [
        {"uses": "actions/checkout@v7", "with": {"fetch-depth": 0}},
        {"run": 'scripts/release-workflow-guard.sh --version "${INPUT_VERSION}" --build-number "${INPUT_BUILD_NUMBER}"'},
        {"run": "scripts/release-approval-config.sh",
         "env": {"RELEASE_APPROVALS_CONFIGURED": "${{ vars.RELEASE_APPROVALS_CONFIGURED }}"}},
        {"run": "python3 scripts/check-release-approval-environment.py",
         "env": {"GH_TOKEN": "${{ github.token }}"}},
    ]}


def fixture() -> dict[str, Any]:
    approval = {"environment": "release-approval", "needs": "guard"}
    ship = {"guard": guard(), "approve": copy.deepcopy(approval),
            "validate": {"environment": "release", "needs": "approve"}}
    documents = {"ship.yml": {"jobs": ship}}
    for channel, filename in policy.CHANNELS.items():
        ship[channel] = {"uses": f"./.github/workflows/{filename}", "needs": "validate",
                         "permissions": {"contents": "read", "actions": "read"}}
        documents[filename] = {
            "on": {"workflow_dispatch": {}, "workflow_call": {}},
            "jobs": {"guard": guard(), "approve": dict(approval, **{"if": policy.STANDALONE_APPROVAL}),
                     "channel": {
                "needs": ["guard", "approve"], "environment": "release", "if": policy.CHANNEL_READY,
                "env": {"SIGNING_KEY": "${{ secrets.SIGNING_KEY }}"},
            }},
        }
    for filename in policy.STANDALONE_ONLY:
        documents[filename] = {"jobs": {"guard": guard(), "approve": copy.deepcopy(approval), "submit": {
            "environment": "release", "needs": ["guard", "approve"], "env": {"KEY": "${{ secrets.KEY }}"},
        }}}
    return documents


class ReleaseApprovalTests(unittest.TestCase):
    def test_cli_warns_about_remote_coverage_without_refusing_unrelated_call(self) -> None:
        documents = fixture()
        documents["extra.yml"] = {"jobs": {"external": {
            "uses": "example/repo/.github/workflows/check.yml@main",
        }}}
        with tempfile.TemporaryDirectory() as root:
            for filename, document in documents.items():
                (Path(root) / filename).write_text(json.dumps(document))
            for actions in ("false", "true"):
                with self.subTest(actions=actions):
                    output, warning = io.StringIO(), io.StringIO()
                    # JSON is YAML-compatible; isolate the optional CLI parser dependency.
                    with patch.dict(sys.modules, {"yaml": SimpleNamespace(
                        safe_load=json.loads, YAMLError=ValueError,
                    )}), patch.object(sys, "argv", ["check-release-approvals", "--workflows-root", root]), \
                            patch.object(sys, "stdout", output), patch.object(sys, "stderr", warning), \
                            patch.dict(os.environ, {"GITHUB_ACTIONS": actions}):
                        self.assertEqual(policy.main(), 0)
                    report = json.loads(output.getvalue())
                    self.assertFalse(report["reusable_workflow_coverage"]["complete"])
                    self.assertEqual(len(report["reusable_workflow_coverage"]["unclassified_calls"]), 1)
                    self.assertIn("coverage incomplete", warning.getvalue())
                    self.assertEqual(warning.getvalue().startswith("::warning::"), actions == "true")

    def test_unclassified_reusable_calls_are_visible_and_remain_supported(self) -> None:
        calls = [
            "example/repo/.github/workflows/publish.yml@main",
            "example/repo/.github/workflows/check.yml@" + "a" * 40,
            "./.github/workflows/check.yml",
            "$/.github/workflows/check.yml",
        ]
        for target in calls:
            for secrets in (None, "inherit", {"token": "${{ secrets.TEST_TOKEN }}"}):
                with self.subTest(target=target, secrets=secrets):
                    documents = fixture()
                    call = {"uses": target}
                    if secrets is not None:
                        call["secrets"] = secrets
                    documents["extra.yml"] = {"jobs": {"external": call, "ordinary": {
                        "steps": [{"uses": "actions/checkout@v7"}],
                    }}}
                    coverage = policy.check(documents)["reusable_workflow_coverage"]
                    self.assertFalse(coverage["complete"])
                    self.assertEqual(coverage["unclassified_calls"], [{
                        "workflow": "extra.yml", "job": "external", "uses": target,
                    }])

    def test_local_unclassified_callee_cannot_hide_release_environment(self) -> None:
        documents = fixture()
        documents["extra.yml"] = {"jobs": {"external": {
            "uses": "./.github/workflows/other.yml",
        }}}
        documents["other.yml"] = {"jobs": {"publish": {"environment": "release"}}}
        with self.assertRaisesRegex(ValueError, "cannot rule out a release environment"):
            policy.check(documents)

    def test_unclassified_computed_release_selectors_fail(self) -> None:
        names = [
            "${{ vars.CHANNEL_ENV }}", "${{ inputs.target }}",
            "${{ matrix.environment }}", "${{ needs.prepare.outputs.environment }}",
            "${{ inputs.target-channel }}", "${{ needs.build-preview.outputs.target }}",
            "${{ format('release-{0}', 'channels') }}",
            "${{ format('{0}{1}', 're', 'lease') }}",
            "${{ inputs.preview && 'preview' || 'release' }}",
            "re${{ vars.SUFFIX }}", "${{ vars.PREFIX }}-approval",
            "${{ vars.A }}${{ vars.B }}", "Release", " RELEASE-APPROVAL ",
            "${{ vars.TARGET || '}}preview' }}",
            "preview-${{ vars.TARGET || '}}' }}",
        ]
        for name in names:
            for object_form in (False, True):
                with self.subTest(name=name, object_form=object_form):
                    documents = fixture()
                    documents["rogue.yml"] = {"jobs": {"publish": {
                        "environment": {"name": name, "url": "https://example.com"}
                        if object_form else name,
                    }}}
                    with self.assertRaisesRegex(ValueError, "cannot rule out a release environment"):
                        policy.check(documents)

    def test_unrelated_environments_have_literal_and_computed_routes(self) -> None:
        names = ["staging", "release-notes", "preview-${{ inputs.target }}",
                 "preview-${{ vars.CHANNEL_ENV }}-${{ matrix.platform }}",
                 "${{ needs.prepare.outputs.target }}-preview", "PREVIEW-${{ github.ref_name }}",
                 "preview-${{ inputs.target-channel }}", "${{ needs.build-preview.outputs.target }}-preview"]
        for name in names:
            with self.subTest(name=name):
                documents = fixture()
                documents["preview.yml"] = {"jobs": {
                    "deploy": {"environment": {"name": name, "url": "${{ vars.URL }}"}},
                    "build": {},
                }}
                plan = policy.check(documents)
                self.assertEqual(plan["ship"]["approval_count"], 1)

    def test_full_ship_plan_requires_one_approval(self) -> None:
        plan = policy.check(fixture())
        self.assertTrue(plan["reusable_workflow_coverage"]["complete"])
        self.assertEqual(plan["reusable_workflow_coverage"]["unclassified_calls"], [])
        self.assertEqual(plan["ship"]["approval_count"], 1)
        self.assertTrue(all(path["secret_environment"] == "release" and path["approval_count"] == 1
                            for path in plan["standalone"].values()))
        self.assertEqual(plan["secret_names_by_environment"]["release-approval"], [])

    def test_approval_bypasses_and_extra_prompts_fail(self) -> None:
        mutations = [
            lambda d: d["ship.yml"]["jobs"]["github-release"]["permissions"].pop("actions"),
            lambda d: d["ship.yml"]["jobs"]["approve"].update(**{"if": "${{ false }}"}),
            lambda d: d["release.yml"]["jobs"]["guard"]["steps"][3].update(**{"if": "${{ false }}"}),
            lambda d: d["release.yml"]["jobs"]["guard"]["steps"][3]["env"].update(GH_TOKEN="${{ secrets.OPERATOR_TOKEN }}"),
            lambda d: d.update({"rogue.yml": {"jobs": {"gate": {"environment": "release-approval"}}}}),
            lambda d: d[policy.STANDALONE_ONLY[0]]["jobs"].update(extra={}),
            lambda d: d[policy.STANDALONE_ONLY[0]]["jobs"]["submit"].update(needs="guard"),
            lambda d: d["release.yml"]["jobs"]["approve"].update(**{"continue-on-error": True}),
            lambda d: d["release.yml"]["jobs"]["approve"].update(needs=[]),
            lambda d: d["release.yml"]["jobs"].pop("approve"),
            lambda d: d["release.yml"].update(env={"KEY": "${{ secrets.KEY }}"}),
            lambda d: d["release.yml"].update(defaults={"run": {"working-directory": "${{ secrets.KEY }}"}}),
            lambda d: d["ship.yml"]["jobs"]["github-release"].update(needs="guard"),
            lambda d: d["ship.yml"]["jobs"]["validate"].update(**{"continue-on-error": True}),
            lambda d: d["ship.yml"]["jobs"]["validate"].update(**{"if": "${{ false }}"}),
            lambda d: d["ship.yml"]["jobs"]["validate"].update(needs="guard"),
            lambda d: d["ship.yml"]["jobs"]["approve"].update(env={"KEY": "${{ secrets.KEY }}"}),
            lambda d: d["ship.yml"]["jobs"]["github-release"].update(secrets="inherit"),
            lambda d: d["release.yml"]["jobs"]["approve"].update(**{"if": "${{ inputs.skip_approval }}"}),
            lambda d: d["release.yml"]["jobs"]["channel"].update(**{"if": "${{ always() }}"}),
            lambda d: d["release.yml"]["jobs"]["guard"]["steps"][2].update(**{"if": "${{ false }}"}),
            lambda d: d["release.yml"]["jobs"]["guard"]["steps"][2]["env"].update(RELEASE_APPROVALS_CONFIGURED="true"),
            lambda d: d[policy.STANDALONE_ONLY[0]]["jobs"]["approve"].update(**{"if": "${{ false }}"}),
            lambda d: d["ship.yml"]["jobs"].update(extra={"environment": "release"}),
            lambda d: d["ship.yml"]["jobs"]["github-release"].update(**{"if": "${{ always() }}"}),
            lambda d: d["release.yml"]["jobs"]["channel"].update(environment="release-approval"),
            lambda d: d["release.yml"]["jobs"]["channel"].update(environment="release-channels"),
            lambda d: d["release.yml"]["jobs"]["channel"].update(environment="${{ inputs.environment }}"),
            lambda d: d["release.yml"]["jobs"]["channel"].update(needs=[]),
            lambda d: d["release.yml"]["jobs"]["guard"].update(**{"continue-on-error": True}),
            lambda d: d["release.yml"]["jobs"].update(leak={"env": {"KEY": "${{ secrets.KEY }}"}}),
            lambda d: d["release.yml"]["jobs"]["guard"]["steps"][1].update({"if": "${{ false }}"}),
            lambda d: d["release.yml"]["jobs"]["guard"]["steps"][1].update({"continue-on-error": True}),
            lambda d: d["release.yml"]["jobs"]["guard"]["steps"][1].update(run="echo scripts/release-workflow-guard.sh"),
            lambda d: d["release.yml"]["jobs"].update(leak={"env": {"KEY": "${{ secrets['KEY'] }}"}}),
            lambda d: d["release.yml"]["jobs"].update(leak={"env": {"KEY": "${{ toJSON(secrets) }}"}}),
            lambda d: d.update({"rogue.yml": {"jobs": {"publish": {"environment": "release-channels"}}}}),
            lambda d: d[policy.STANDALONE_ONLY[0]]["jobs"]["submit"].update(needs=[]),
            lambda d: d[policy.STANDALONE_ONLY[0]]["jobs"]["submit"].update({"if": "${{ always() }}"}),
            lambda d: d[policy.STANDALONE_ONLY[0]]["jobs"]["submit"].update(environment="release-channels"),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                documents = copy.deepcopy(fixture())
                mutate(documents)
                with self.assertRaises(ValueError):
                    policy.check(documents)

    def test_testflight_join_requires_success_even_when_upload_is_skipped(self) -> None:
        documents = fixture()
        call = documents["ship.yml"]["jobs"]["testflight-beta"]
        call["if"] = "${{ !cancelled() && inputs.testflight_beta && needs.validate.result == 'success' && (inputs.optional || needs.upload.result == 'success') }}"
        policy.check(documents)
        call["if"] += " trailing"
        with self.assertRaises(ValueError):
            policy.check(documents)
        call["if"] = call["if"].removesuffix(" trailing") + " || true"
        with self.assertRaises(ValueError):
            policy.check(documents)
        call["if"] = "${{ !cancelled() && inputs.testflight_beta && needs.validate.result != 'success' && inputs.optional }}"
        with self.assertRaises(ValueError):
            policy.check(documents)

    def test_setup_confirmation_fails_closed(self) -> None:
        script = Path(__file__).resolve().parents[2] / "scripts/release-approval-config.sh"
        for value, succeeds in [(None, False), ("false", False), ("TRUE", False), ("true", True)]:
            with self.subTest(value=value):
                env = {"PATH": os.defpath}
                if value is not None:
                    env["RELEASE_APPROVALS_CONFIGURED"] = value
                result = subprocess.run([str(script)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, succeeds)

    def test_live_review_metadata_refuses_missing_or_bypassed_review(self) -> None:
        metadata_spec = importlib.util.spec_from_file_location(
            "approval_environment", Path(__file__).resolve().parents[2]
            / "scripts/check-release-approval-environment.py"
        )
        if metadata_spec is None or metadata_spec.loader is None:
            raise RuntimeError("environment module could not be loaded")
        metadata = importlib.util.module_from_spec(metadata_spec)
        metadata_spec.loader.exec_module(metadata)
        good = {"name": "release-approval", "can_admins_bypass": False,
                "protection_rules": [{"type": "required_reviewers", "prevent_self_review": False,
                                      "reviewers": [{"type": "User", "reviewer": {"login": "owner"}}]}]}
        metadata.check(good, "owner")
        mutations = [
            lambda d: d.update(protection_rules=[]),
            lambda d: d.update(can_admins_bypass=True),
            lambda d: d.pop("can_admins_bypass"),
            lambda d: d["protection_rules"][0].update(reviewers=[]),
            lambda d: d["protection_rules"][0]["reviewers"][0]["reviewer"].update(login="someone_else"),
            lambda d: d["protection_rules"][0].update(prevent_self_review=True),
        ]
        for mutate in mutations:
            document = copy.deepcopy(good)
            mutate(document)
            with self.assertRaises(ValueError):
                metadata.check(document, "owner")
        secret_store = {"deployment_branch_policy": {"protected_branches": True,
                                                     "custom_branch_policies": False}}
        metadata.check_branches(secret_store, [{"name": "main"}])
        for branches in [[], [{"name": "main"}, {"name": "task"}]]:
            with self.assertRaises(ValueError):
                metadata.check_branches(secret_store, branches)
        with self.assertRaises(ValueError):
            metadata.check_branches({}, [{"name": "main"}])
        metadata.check_branches({"deployment_branch_policy": {"protected_branches": False,
                                                             "custom_branch_policies": True}},
                                [{"name": "main", "type": "branch"}])
        hidden_review = copy.deepcopy(good)
        hidden_review["protection_rules"][0]["reviewers"][0]["reviewer"] = None
        with self.assertRaises(ValueError):
            metadata.check_fields(hidden_review)
        with patch.object(subprocess, "run", return_value=SimpleNamespace(returncode=1)):
            with self.assertRaises(ValueError):
                metadata.fetch_metadata("repos/owner/repo/environments/release-approval")
