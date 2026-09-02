from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "context-panel-shared-view-capture-workflow.py"
sys.path.insert(0, str(REPO_ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("shared_view_capture_workflow", SCRIPT)
assert spec is not None and spec.loader is not None
workflow = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = workflow
spec.loader.exec_module(workflow)

from Tests.ScriptsTests.test_shared_view_evidence import comparison_for


SHA = "a" * 40


class SharedViewCaptureWorkflowTests(unittest.TestCase):
    def expected_manifest(self, layout: str = "ios") -> dict[str, object]:
        return {
            "schemaVersion": 2,
            "kind": "context-panel-expected-signed-build",
            "layout": layout,
            "expectedBuildId": "b" * 64,
            "source": {
                "commit": SHA,
                "marketingVersion": "2.4.6",
                "buildNumber": "42",
                "configuration": "Release",
                "treeState": "clean",
            },
        }

    def test_validates_exact_artifact_run_and_source_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest = root / "ExpectedBuildManifest-ios.json"
            manifest.write_text(json.dumps(self.expected_manifest()))
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps({"artifacts": [{"name": "candidate", "expired": False}]}))

            selected = workflow.validate_artifact_manifest(
                root,
                layout="ios",
                requested_source_commit=SHA,
                requested_version="2.4.6",
                requested_build="42",
                run_id="123",
                run_source_commit=SHA,
                artifacts_metadata=metadata,
                artifact_name="candidate",
            )

            self.assertEqual(selected, manifest)

    def test_rejects_duplicate_or_expired_artifact_manifests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            for name in ("ExpectedBuildManifest-ios.json", "nested/ExpectedBuildManifest-ios.json"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(self.expected_manifest()))
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps({"artifacts": [{"name": "candidate", "expired": True}]}))
            with self.assertRaises(workflow.WorkflowEvidenceError):
                workflow.validate_artifact_manifest(
                    root,
                    layout="ios",
                    requested_source_commit=SHA,
                    requested_version="2.4.6",
                    requested_build="42",
                    run_id="123",
                    run_source_commit=SHA,
                    artifacts_metadata=metadata,
                    artifact_name="candidate",
                )

    def test_rejects_artifact_run_with_a_different_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "ExpectedBuildManifest-ios.json").write_text(json.dumps(self.expected_manifest()))
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps({"artifacts": [{"name": "candidate", "expired": False}]}))
            with self.assertRaises(workflow.WorkflowEvidenceError):
                workflow.validate_artifact_manifest(
                    root,
                    layout="ios",
                    requested_source_commit=SHA,
                    requested_version="2.4.6",
                    requested_build="42",
                    run_id="123",
                    run_source_commit="b" * 40,
                    artifacts_metadata=metadata,
                    artifact_name="candidate",
                )

    def test_placement_base_retains_every_fresh_placement_surface(self) -> None:
        comparison = comparison_for(
            {
                "ios.widget": ["actual-runtime", "os-composited-placement"],
                "watchos.complication": ["actual-runtime", "os-composited-placement"],
            }
        )
        base = workflow.placement_base(comparison, REPO_ROOT / "Config" / "ContextPanelSurfacePolicy.json")
        self.assertEqual(
            {item["surface"] for item in base["requirements"]},
            {"ios.widget", "watchos.complication"},
        )

    def test_placement_base_fails_closed_for_ungoverned_surface(self) -> None:
        comparison = comparison_for({"ios.widget": ["actual-runtime", "os-composited-placement"]})
        comparison["surfaces"][0]["surfaceId"] = "unknown.surface"
        with self.assertRaises(workflow.WorkflowEvidenceError):
            workflow.placement_base(comparison, REPO_ROOT / "Config" / "ContextPanelSurfacePolicy.json")

    def test_combined_plan_preserves_placement_while_adding_shared_view_work(self) -> None:
        comparison = comparison_for(
            {
                "ios.app": ["shared-view"],
                "ios.widget": ["actual-runtime", "os-composited-placement"],
            }
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "comparison.json"
            path.write_text(json.dumps(comparison))
            plan = workflow.combined_visual_plan(path, REPO_ROOT / "Config" / "ContextPanelSurfacePolicy.json")
        self.assertIn("ios.widget", {item["surface"] for item in plan["requirements"]})
        self.assertIn("ios.app", {item["surface"] for item in plan["requirements"]})

    def test_capture_config_selects_available_runtime_and_device_type(self) -> None:
        catalog = {
            "runtimes": [
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "platform": "iOS", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.xrOS-26-0", "platform": "xrOS", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-0", "platform": "watchOS", "isAvailable": True},
            ],
            "devicetypes": [
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "productFamily": "iPhone"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5", "productFamily": "iPad"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro", "productFamily": "Apple Vision"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm", "productFamily": "Apple Watch"},
            ],
        }
        config = workflow.capture_config(catalog, {"ios": "/tmp/i.app", "ipados": "/tmp/i.app", "visionos": "/tmp/v.app", "watchos": "/tmp/w.app"})
        self.assertEqual(set(config["profiles"]), {"ios", "ipados", "visionos", "watchos"})

    def test_capture_config_fails_without_a_required_device_family(self) -> None:
        with self.assertRaises(workflow.WorkflowEvidenceError):
            workflow.capture_config({"runtimes": [], "devicetypes": []}, {"ios": "/tmp/i.app", "ipados": "/tmp/i.app", "visionos": "/tmp/v.app", "watchos": "/tmp/w.app"})

    def test_receipt_qualification_accepts_only_supported_captures_and_explicit_unsupported_hosts(self) -> None:
        requirements = {
            "requirements": [
                {"id": "shared-view.ios-app.baseline", "surface": "ios.app", "evidenceClass": "shared-view"},
                {"id": "shared-view.macos-app.baseline", "surface": "macos.app", "evidenceClass": "shared-view"},
                {"id": "shared-view.tvos-app.baseline", "surface": "tvos.app", "evidenceClass": "shared-view"},
            ]
        }
        receipt = {
            "schemaVersion": 1,
            "kind": "context-panel-shared-view-capture-receipt",
            "pixelDiffPolicy": "advisory-only",
            "captures": [
                {"requirementID": "shared-view.ios-app.baseline", "status": "captured"},
                {"requirementID": "shared-view.macos-app.baseline", "status": "blocked", "errorCode": "unsupported-host-mechanism"},
                {"requirementID": "shared-view.tvos-app.baseline", "status": "blocked", "errorCode": "unsupported-host-mechanism"},
            ],
        }
        workflow.qualify_capture_receipt(receipt, requirements)
        receipt["captures"][1]["errorCode"] = "profile-not-configured"
        with self.assertRaises(workflow.WorkflowEvidenceError):
            workflow.qualify_capture_receipt(receipt, requirements)
        receipt["captures"][1]["errorCode"] = "unsupported-host-mechanism"
        receipt["evidenceClass"] = "actual-runtime"
        with self.assertRaises(workflow.WorkflowEvidenceError):
            workflow.qualify_capture_receipt(receipt, requirements)


if __name__ == "__main__":
    unittest.main()
