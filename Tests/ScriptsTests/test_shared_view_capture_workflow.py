from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from typing import Any
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
    @staticmethod
    def expected_manifest(layout: str = "ios") -> dict[str, Any]:
        return {
            "schemaVersion": 2,
            "kind": "context-panel-expected-signed-build",
            "layout": layout,
            "expectedBuildId": "b" * 64,
            "sourceManifestId": "c" * 64,
            "source": {
                "commit": SHA,
                "marketingVersion": "2.4.6",
                "buildNumber": "42",
                "configuration": "Release",
                "treeState": "clean",
                "xcodeBuild": "17F113",
            },
        }

    @staticmethod
    def run_metadata(
        *,
        workflow_path: str = ".github/workflows/app-store-connect-companion-upload.yml",
        conclusion: str = "success",
    ) -> dict[str, Any]:
        return {
            "id": 123,
            "head_sha": SHA,
            "status": "completed",
            "conclusion": conclusion,
            "event": "workflow_dispatch",
            "path": workflow_path,
        }

    @staticmethod
    def artifact_metadata(*, expired: bool = False) -> dict[str, Any]:
        return {
            "total_count": 1,
            "artifacts": [
                {
                    "name": "candidate",
                    "expired": expired,
                    "workflow_run": {"id": 123, "head_sha": SHA},
                }
            ],
        }

    def test_validates_exact_artifact_run_and_source_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest = root / "ExpectedBuildManifest-ios.json"
            manifest.write_text(json.dumps(self.expected_manifest()))
            run_metadata = root / "run.json"
            run_metadata.write_text(json.dumps(self.run_metadata()))
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps(self.artifact_metadata()))

            selected = workflow.validate_artifact_manifest(
                root,
                layout="ios",
                requested_source_commit=SHA,
                requested_version="2.4.6",
                requested_build="42",
                run_id="123",
                run_metadata=run_metadata,
                artifacts_metadata=metadata,
                artifact_name="candidate",
                expected_workflows=(
                    ".github/workflows/app-store-connect-companion-upload.yml",
                ),
            )

            self.assertEqual(selected, manifest)

    def test_rejects_duplicate_artifact_manifests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            for name in ("ExpectedBuildManifest-ios.json", "nested/ExpectedBuildManifest-ios.json"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(self.expected_manifest()))
            run_metadata = root / "run.json"
            run_metadata.write_text(json.dumps(self.run_metadata()))
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps(self.artifact_metadata()))
            with self.assertRaises(workflow.WorkflowEvidenceError):
                workflow.validate_artifact_manifest(
                    root,
                    layout="ios",
                    requested_source_commit=SHA,
                    requested_version="2.4.6",
                    requested_build="42",
                    run_id="123",
                    run_metadata=run_metadata,
                    artifacts_metadata=metadata,
                    artifact_name="candidate",
                    expected_workflows=(
                        ".github/workflows/app-store-connect-companion-upload.yml",
                    ),
                )

    def test_rejects_expired_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "ExpectedBuildManifest-ios.json").write_text(json.dumps(self.expected_manifest()))
            run_metadata = root / "run.json"
            run_metadata.write_text(json.dumps(self.run_metadata()))
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps(self.artifact_metadata(expired=True)))
            with self.assertRaises(workflow.WorkflowEvidenceError):
                workflow.validate_artifact_manifest(
                    root,
                    layout="ios",
                    requested_source_commit=SHA,
                    requested_version="2.4.6",
                    requested_build="42",
                    run_id="123",
                    run_metadata=run_metadata,
                    artifacts_metadata=metadata,
                    artifact_name="candidate",
                    expected_workflows=(
                        ".github/workflows/app-store-connect-companion-upload.yml",
                    ),
                )

    def test_rejects_artifact_run_with_a_different_source_or_producer(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "ExpectedBuildManifest-ios.json").write_text(json.dumps(self.expected_manifest()))
            run_metadata = root / "run.json"
            run = self.run_metadata(workflow_path=".github/workflows/untrusted.yml")
            run["head_sha"] = "b" * 40
            run_metadata.write_text(json.dumps(run))
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps(self.artifact_metadata()))
            with self.assertRaises(workflow.WorkflowEvidenceError):
                workflow.validate_artifact_manifest(
                    root,
                    layout="ios",
                    requested_source_commit=SHA,
                    requested_version="2.4.6",
                    requested_build="42",
                    run_id="123",
                    run_metadata=run_metadata,
                    artifacts_metadata=metadata,
                    artifact_name="candidate",
                    expected_workflows=(
                        ".github/workflows/app-store-connect-companion-upload.yml",
                    ),
                )

    def test_allows_completed_ship_run_after_late_workflow_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest = root / "ExpectedBuildManifest-macos.json"
            manifest.write_text(json.dumps(self.expected_manifest("macos")))
            run_metadata = root / "run.json"
            run_metadata.write_text(
                json.dumps(
                    self.run_metadata(
                        workflow_path=".github/workflows/ship.yml",
                        conclusion="failure",
                    )
                )
            )
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps(self.artifact_metadata()))
            selected = workflow.validate_artifact_manifest(
                root,
                layout="macos",
                requested_source_commit=SHA,
                requested_version="2.4.6",
                requested_build="42",
                run_id="123",
                run_metadata=run_metadata,
                artifacts_metadata=metadata,
                artifact_name="candidate",
                expected_workflows=(".github/workflows/ship.yml",),
            )
            self.assertEqual(selected, manifest)

    def test_rejects_cancelled_ship_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "ExpectedBuildManifest-macos.json").write_text(
                json.dumps(self.expected_manifest("macos"))
            )
            run_metadata = root / "run.json"
            run_metadata.write_text(
                json.dumps(
                    self.run_metadata(
                        workflow_path=".github/workflows/ship.yml",
                        conclusion="cancelled",
                    )
                )
            )
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps(self.artifact_metadata()))
            with self.assertRaises(workflow.WorkflowEvidenceError):
                workflow.validate_artifact_manifest(
                    root,
                    layout="macos",
                    requested_source_commit=SHA,
                    requested_version="2.4.6",
                    requested_build="42",
                    run_id="123",
                    run_metadata=run_metadata,
                    artifacts_metadata=metadata,
                    artifact_name="candidate",
                    expected_workflows=(".github/workflows/ship.yml",),
                )

    def test_source_identity_requires_all_layouts_to_agree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifests = []
            for layout in ("macos", "ios", "visionos", "tvos"):
                path = root / f"ExpectedBuildManifest-{layout}.json"
                path.write_text(json.dumps(self.expected_manifest(layout)))
                manifests.append(path)
            identity = workflow.source_identity(
                manifests,
                requested_source_commit=SHA,
                requested_version="2.4.6",
                requested_build="42",
            )
            self.assertEqual(identity["sourceManifestId"], "c" * 64)
            changed = self.expected_manifest("tvos")
            changed["sourceManifestId"] = "d" * 64
            manifests[-1].write_text(json.dumps(changed))
            with self.assertRaises(workflow.WorkflowEvidenceError):
                workflow.source_identity(
                    manifests,
                    requested_source_commit=SHA,
                    requested_version="2.4.6",
                    requested_build="42",
                )

    def test_generated_source_manifest_must_match_sealed_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest = root / "source.json"
            identity = root / "identity.json"
            expected = self.expected_manifest()
            manifest.write_text(
                json.dumps(
                    {
                        "manifestId": expected["sourceManifestId"],
                        "source": expected["source"],
                    }
                )
            )
            identity.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "kind": workflow.SOURCE_IDENTITY_KIND,
                        "sourceManifestId": expected["sourceManifestId"],
                        "source": expected["source"],
                    }
                )
            )
            workflow.validate_generated_source_manifest(manifest, identity)
            generated = json.loads(manifest.read_text())
            generated["manifestId"] = "d" * 64
            manifest.write_text(json.dumps(generated))
            with self.assertRaises(workflow.WorkflowEvidenceError):
                workflow.validate_generated_source_manifest(manifest, identity)

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
            plan = workflow.combined_visual_plan(path, REPO_ROOT)
        self.assertIn("ios.widget", {item["surface"] for item in plan["requirements"]})
        self.assertIn("ios.app", {item["surface"] for item in plan["requirements"]})

    def test_capture_config_selects_available_runtime_and_device_type(self) -> None:
        catalog = {
            "runtimes": [
                {
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-25-0",
                    "platform": "iOS",
                    "version": "25.0",
                    "isAvailable": True,
                    "supportedDeviceTypes": [
                        {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16"},
                    ],
                },
                {
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
                    "platform": "iOS",
                    "version": "26.0",
                    "isAvailable": True,
                    "supportedDeviceTypes": [
                        {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
                        {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5"},
                    ],
                },
                {
                    "identifier": "com.apple.CoreSimulator.SimRuntime.xrOS-26-0",
                    "platform": "xrOS",
                    "version": "26.0",
                    "isAvailable": True,
                    "supportedDeviceTypes": [
                        {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro"},
                    ],
                },
                {
                    "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-0",
                    "platform": "watchOS",
                    "version": "26.0",
                    "isAvailable": True,
                    "supportedDeviceTypes": [
                        {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm"},
                    ],
                },
            ],
            "devicetypes": [
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "productFamily": "iPhone"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16", "productFamily": "iPhone"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5", "productFamily": "iPad"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro", "productFamily": "Apple Vision"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm", "productFamily": "Apple Watch"},
            ],
        }
        config = workflow.capture_config(catalog, {"ios": "/tmp/i.app", "ipados": "/tmp/i.app", "visionos": "/tmp/v.app", "watchos": "/tmp/w.app"})
        self.assertEqual(set(config["profiles"]), {"ios", "ipados", "visionos", "watchos"})
        self.assertEqual(
            config["profiles"]["ios"]["runtimeIdentifier"],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
        )
        self.assertEqual(
            config["profiles"]["ios"]["deviceTypeIdentifier"],
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
        )

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
        receipt: dict[str, Any] = {
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

    def test_workflow_preserves_expected_blocked_exit_for_qualification(self) -> None:
        text = (REPO_ROOT / ".github" / "workflows" / "shared-view-capture.yml").read_text()
        self.assertIn("actions: read", text)
        self.assertIn('capture_status=$?', text)
        self.assertIn('"${capture_status}" -ne 20', text)
        self.assertIn("ref: ${{ github.sha }}", text)
        self.assertIn("/Applications/Xcode_26.6.app", text)
        self.assertIn("git worktree add --detach .build/current-source", text)
        self.assertIn("if-no-files-found: warn", text)
        self.assertNotIn('-sdk "${sdk}"', text)


if __name__ == "__main__":
    unittest.main()
