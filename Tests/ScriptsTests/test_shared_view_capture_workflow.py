from __future__ import annotations

import contextlib
import importlib.util
import io
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
        event: str = "workflow_dispatch",
    ) -> dict[str, Any]:
        return {
            "id": 123,
            "head_sha": SHA,
            "status": "completed",
            "conclusion": conclusion,
            "event": event,
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

    def test_accepts_reusable_workflow_run_with_ref_qualified_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest = root / "ExpectedBuildManifest-ios.json"
            manifest.write_text(json.dumps(self.expected_manifest()))
            run_metadata = root / "run.json"
            run_metadata.write_text(json.dumps(self.run_metadata(
                workflow_path=(
                    ".github/workflows/app-store-connect-companion-upload.yml"
                    "@refs/heads/main"
                ),
                event="workflow_call",
            )))
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

    def test_allows_completed_upload_run_after_late_workflow_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest = root / "ExpectedBuildManifest-ios.json"
            manifest.write_text(json.dumps(self.expected_manifest()))
            run_metadata = root / "run.json"
            run_metadata.write_text(json.dumps(self.run_metadata(conclusion="failure")))
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
                {
                    "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-0",
                    "platform": "tvOS",
                    "version": "26.0",
                    "isAvailable": True,
                    "supportedDeviceTypes": [
                        {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K"},
                    ],
                },
            ],
            "devicetypes": [
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "productFamily": "iPhone"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16", "productFamily": "iPhone"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5", "productFamily": "iPad"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro", "productFamily": "Apple Vision"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm", "productFamily": "Apple Watch"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-TV-1080p", "productFamily": "Apple TV"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K", "productFamily": "Apple TV"},
            ],
        }
        config = workflow.capture_config(
            catalog,
            {
                "ios": "/tmp/i.app",
                "ipados": "/tmp/i.app",
                "visionos": "/tmp/v.app",
                "watchos": "/tmp/w.app",
                "tvos": "/tmp/t.app",
            },
            "/tmp/ios.xctestrun",
            "/tmp/visionos.xctestrun",
            macos_source_root="/tmp/current-source",
        )
        self.assertEqual(
            set(config["profiles"]), {*workflow.SUPPORTED_CAPTURE_SURFACES, "macos"}
        )
        self.assertEqual(config["profiles"]["macos"], {"sourceRoot": "/tmp/current-source"})
        self.assertEqual(
            config["profiles"]["tvos"]["deviceTypeIdentifier"],
            "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K",
        )
        self.assertNotIn("uiTestRun", config["profiles"]["tvos"])
        self.assertEqual(
            config["profiles"]["ios"]["runtimeIdentifier"],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
        )
        self.assertEqual(
            config["profiles"]["ios"]["deviceTypeIdentifier"],
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
        )
        self.assertEqual(
            config["profiles"]["ios"]["uiTestRun"],
            "/tmp/ios.xctestrun",
        )
        self.assertEqual(
            config["profiles"]["ipados"]["uiTestRun"],
            "/tmp/ios.xctestrun",
        )
        self.assertEqual(
            config["profiles"]["visionos"]["uiTestRun"],
            "/tmp/visionos.xctestrun",
        )

    def test_capture_config_fails_without_a_required_device_family(self) -> None:
        with self.assertRaises(workflow.WorkflowEvidenceError):
            workflow.capture_config(
                {"runtimes": [], "devicetypes": []},
                {
                    "ios": "/tmp/i.app",
                    "ipados": "/tmp/i.app",
                    "visionos": "/tmp/v.app",
                    "watchos": "/tmp/w.app",
                },
                "/tmp/ios.xctestrun",
                "/tmp/visionos.xctestrun",
            )

    @staticmethod
    def capture_receipt_fixture() -> tuple[dict[str, Any], dict[str, Any]]:
        requirements = {
            "currentManifestID": "a" * 64,
            "requirements": [
                {"id": "shared-view.ios-app.baseline", "surface": "ios.app", "evidenceClass": "shared-view"},
                {"id": "shared-view.watchos-app.baseline", "surface": "watchos.app", "evidenceClass": "shared-view"},
                {"id": "shared-view.macos-app.baseline", "surface": "macos.app", "evidenceClass": "shared-view"},
                {"id": "shared-view.tvos-app.baseline", "surface": "tvos.app", "evidenceClass": "shared-view"},
                {"id": "shared-view.macos-widget.baseline", "surface": "macos.widget", "evidenceClass": "shared-view"},
            ]
        }
        receipt: dict[str, Any] = {
            "schemaVersion": 1,
            "kind": "context-panel-shared-view-capture-receipt",
            "pixelDiffPolicy": "advisory-only",
            "currentManifestID": "a" * 64,
            "profiles": [
                {"profile": "ios", "appBundleSHA256": "b" * 64},
                {
                    "profile": workflow.HOST_RENDERER_PROFILE,
                    "hostMechanism": workflow.HOST_RENDERER_MECHANISM,
                    "rendererExecutableSHA256": "c" * 64,
                    "rendererSourceSHA256": "d" * 64,
                    "rendererSourceManifestID": "a" * 64,
                },
            ],
            "captures": [
                {
                    "requirementID": "shared-view.ios-app.baseline",
                    "status": "captured",
                    "hostMechanism": "xcuitest-shared-view-renderer",
                    "appearanceMechanism": "xcuitest-render-route",
                    "errorCode": None,
                },
                {
                    "requirementID": "shared-view.watchos-app.baseline",
                    "status": "captured",
                    "hostMechanism": "simctl-gallery",
                    "appearanceMechanism": None,
                    "errorCode": None,
                },
                {
                    "requirementID": "shared-view.macos-app.baseline",
                    "status": "blocked",
                    "hostMechanism": "unsupported-host-mechanism",
                    "appearanceMechanism": None,
                    "errorCode": "unsupported-host-mechanism",
                },
                {
                    "requirementID": "shared-view.tvos-app.baseline",
                    "status": "captured",
                    "hostMechanism": "simctl-gallery",
                    "appearanceMechanism": None,
                    "errorCode": None,
                },
                {
                    "requirementID": "shared-view.macos-widget.baseline",
                    "status": "captured",
                    "hostMechanism": workflow.HOST_RENDERER_MECHANISM,
                    "appearanceMechanism": workflow.HOST_RENDERER_APPEARANCE_MECHANISM,
                    "errorCode": None,
                },
            ],
        }
        return requirements, receipt

    def test_receipt_qualification_accepts_only_supported_captures_and_explicit_unsupported_hosts(self) -> None:
        requirements, receipt = self.capture_receipt_fixture()
        workflow.qualify_capture_receipt(receipt, requirements)
        receipt["captures"][0]["hostMechanism"] = "simctl-gallery"
        with self.assertRaises(workflow.WorkflowEvidenceError):
            workflow.qualify_capture_receipt(receipt, requirements)
        receipt["captures"][0]["hostMechanism"] = "xcuitest-shared-view-renderer"
        receipt["captures"][2]["errorCode"] = "profile-not-configured"
        with self.assertRaises(workflow.WorkflowEvidenceError):
            workflow.qualify_capture_receipt(receipt, requirements)
        receipt["captures"][2]["errorCode"] = "unsupported-host-mechanism"
        receipt["evidenceClass"] = "actual-runtime"
        with self.assertRaises(workflow.WorkflowEvidenceError):
            workflow.qualify_capture_receipt(receipt, requirements)

    def test_mac_widget_must_be_rendered_by_the_host_renderer_to_qualify(self) -> None:
        requirements, valid = self.capture_receipt_fixture()
        workflow.qualify_capture_receipt(valid, requirements)
        substitutions = (
            {"status": "blocked", "hostMechanism": "unsupported-host-mechanism",
             "appearanceMechanism": None, "errorCode": "unsupported-host-mechanism"},
            {"hostMechanism": "simctl-gallery", "appearanceMechanism": None},
            {"status": "unknown", "errorCode": "host-renderer-failed"},
        )
        for substitution in substitutions:
            with self.subTest(substitution=substitution):
                _, receipt = self.capture_receipt_fixture()
                widget = next(
                    item for item in receipt["captures"]
                    if item["requirementID"] == "shared-view.macos-widget.baseline"
                )
                widget.update(substitution)
                with self.assertRaisesRegex(workflow.WorkflowEvidenceError, "macOS widget"):
                    workflow.qualify_capture_receipt(receipt, requirements)

    def test_rendered_mac_widget_cells_need_a_matching_renderer_identity_in_the_receipt(self) -> None:
        requirements, _ = self.capture_receipt_fixture()

        def renderer(receipt: dict[str, Any]) -> dict[str, Any]:
            return next(
                item for item in receipt["profiles"]
                if item["profile"] == workflow.HOST_RENDERER_PROFILE
            )

        mutations = {
            "no renderer profile": lambda receipt: receipt["profiles"].remove(renderer(receipt)),
            "two renderer profiles": lambda receipt: receipt["profiles"].append(dict(renderer(receipt))),
            "no executable hash": lambda receipt: renderer(receipt).update(rendererExecutableSHA256=None),
            "no source hash": lambda receipt: renderer(receipt).update(rendererSourceSHA256="not-a-hash"),
            "another manifest": lambda receipt: renderer(receipt).update(rendererSourceManifestID="e" * 64),
            "wrong mechanism": lambda receipt: renderer(receipt).update(hostMechanism="simctl-gallery"),
            "profiles missing": lambda receipt: receipt.pop("profiles"),
            "null manifest id on both sides": lambda receipt: (
                renderer(receipt).update(rendererSourceManifestID=None),
                receipt.pop("currentManifestID"),
            ),
            "receipt for another plan": lambda receipt: (
                renderer(receipt).update(rendererSourceManifestID="e" * 64),
                receipt.update(currentManifestID="e" * 64),
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name):
                _, receipt = self.capture_receipt_fixture()
                mutate(receipt)
                with self.assertRaisesRegex(workflow.WorkflowEvidenceError, "renderer identity"):
                    workflow.qualify_capture_receipt(receipt, requirements)

    def test_a_plan_without_mac_widget_cells_needs_no_renderer_identity(self) -> None:
        requirements, receipt = self.capture_receipt_fixture()
        requirements["requirements"] = [
            item for item in requirements["requirements"] if item["surface"] != "macos.widget"
        ]
        receipt["captures"] = [
            item for item in receipt["captures"]
            if item["requirementID"] != "shared-view.macos-widget.baseline"
        ]
        receipt["profiles"] = []

        workflow.qualify_capture_receipt(receipt, requirements)

    def run_capture_and_qualify(self, capture_status: int, receipt: dict[str, Any] | None) -> int:
        requirements, _ = self.capture_receipt_fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt_path = root / "receipt.json"
            requirements_path = root / "requirements.json"
            requirements_path.write_text(json.dumps(requirements))
            capture = (
                "import pathlib, sys; "
                + (f"pathlib.Path(sys.argv[1]).write_text({json.dumps(receipt)!r}); " if receipt is not None else "")
                + f"sys.exit({capture_status})"
            )
            return workflow.main(
                [
                    "capture-and-qualify",
                    "--receipt",
                    str(receipt_path),
                    "--requirements",
                    str(requirements_path),
                    "--",
                    sys.executable,
                    "-c",
                    capture,
                    str(receipt_path),
                ]
            )

    def test_blocked_capture_still_qualifies_when_only_unsupported_hosts_are_blocked(self) -> None:
        _, receipt = self.capture_receipt_fixture()

        self.assertEqual(self.run_capture_and_qualify(0, receipt), 0)
        self.assertEqual(self.run_capture_and_qualify(20, receipt), 0)

    def test_blocked_capture_fails_when_a_supported_surface_was_not_captured(self) -> None:
        _, receipt = self.capture_receipt_fixture()
        receipt["captures"][0]["status"] = "blocked"

        with self.assertRaises(SystemExit) as context, contextlib.redirect_stderr(io.StringIO()):
            self.run_capture_and_qualify(20, receipt)
        self.assertNotEqual(context.exception.code, 0)

    def test_other_capture_failures_propagate_without_qualification(self) -> None:
        for capture_status in (1, 30):
            with self.subTest(capture_status=capture_status):
                self.assertEqual(self.run_capture_and_qualify(capture_status, None), capture_status)


if __name__ == "__main__":
    unittest.main()
