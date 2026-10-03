import copy
import importlib.util
from pathlib import Path
import unittest
import os
import subprocess
from typing import Any

spec = importlib.util.spec_from_file_location(
    "release_approvals", Path(__file__).resolve().parents[2] / "scripts/check-release-approvals.py"
)
if spec is None or spec.loader is None:
    raise RuntimeError("release approval policy module could not be loaded")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def guard() -> dict[str, Any]:
    return {"steps": [
        {"uses": "actions/checkout@v7", "with": {"fetch-depth": 0}},
        {"run": 'scripts/release-workflow-guard.sh --version "${INPUT_VERSION}" --build-number "${INPUT_BUILD_NUMBER}"'},
        {"run": "scripts/release-approval-config.sh",
         "env": {"RELEASE_APPROVALS_CONFIGURED": "${{ vars.RELEASE_APPROVALS_CONFIGURED }}"}},
    ]}


def fixture() -> dict[str, Any]:
    approval = {"environment": "release-approval", "needs": "guard"}
    ship = {"guard": guard(), "approve": copy.deepcopy(approval),
            "validate": {"environment": "release", "needs": "approve"}}
    documents = {"ship.yml": {"jobs": ship}}
    for channel, filename in policy.CHANNELS.items():
        ship[channel] = {"uses": f"./.github/workflows/{filename}", "needs": "validate"}
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
    def test_full_ship_plan_requires_one_approval(self) -> None:
        plan = policy.check(fixture())
        self.assertEqual(plan["ship"]["approval_count"], 1)
        self.assertTrue(all(path["secret_environment"] == "release" and path["approval_count"] == 1
                            for path in plan["standalone"].values()))
        self.assertEqual(plan["secret_names_by_environment"]["release-approval"], [])

    def test_approval_bypasses_and_extra_prompts_fail(self) -> None:
        mutations = [
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
