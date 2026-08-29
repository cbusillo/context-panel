import ast
import copy
import hashlib
import importlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

cli_module = importlib.import_module("context_panel_surface_manifest.cli")
core_module = importlib.import_module("context_panel_surface_manifest.core")
artifact_module = importlib.import_module("context_panel_surface_manifest.artifact")
comparison_schema_module = importlib.import_module("context_panel_comparison_schema")

evidence_template = cli_module.evidence_template
SurfacePolicyError = core_module.SurfacePolicyError
compare_manifests = core_module.compare_manifests
collect_archive_evidence = artifact_module.collect_archive_evidence
embedded_manifest = core_module.embedded_manifest
generate_manifest = core_module.generate_manifest
resolve_policy = core_module.resolve_policy
seal_expected_build = core_module.seal_expected_build
validation_summary = core_module.validation_summary
ComparisonSchemaError = comparison_schema_module.ComparisonSchemaError
derive_risk_fields = comparison_schema_module.derive_risk_fields
validate_current_comparison = comparison_schema_module.validate_current_comparison


class SurfaceManifestTests(unittest.TestCase):
    def setUp(self):
        self.baseline = self.manifest(REPO_ROOT)

    def copy_fixture(self, destination: Path) -> Path:
        for filename in ("project.yml", "Package.swift"):
            shutil.copy2(REPO_ROOT / filename, destination / filename)
        for directory in ("Sources", "Resources", "Config", "CloudKit"):
            shutil.copytree(REPO_ROOT / directory, destination / directory)
        scripts = destination / "scripts"
        scripts.mkdir()
        for filename in (
            "context-panel-build-fingerprint.sh",
            "context-panel-project-spec-json.rb",
            "context-panel-surface-manifest.py",
            "stamp-context-panel-build.sh",
            "context-panel-write-expected-build.sh",
            "context_panel_comparison_schema.py",
        ):
            shutil.copy2(REPO_ROOT / "scripts" / filename, scripts / filename)
        shutil.copytree(
            REPO_ROOT / "scripts/context_panel_surface_manifest",
            scripts / "context_panel_surface_manifest",
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        return destination

    def fixture(self, temporary_directory: str) -> Path:
        return self.copy_fixture(Path(temporary_directory))

    def manifest(
        self,
        root: Path,
        *,
        version: str = "1.0.53",
        build: str = "2026073001",
        commit: str = "0123456789abcdef",
        configuration: str = "Release",
        xcode_build: str = "17A000",
        tree_state: str = "clean",
    ):
        return generate_manifest(
            resolve_policy(root),
            marketing_version=version,
            build_number=build,
            source_commit=commit,
            configuration=configuration,
            xcode_build=xcode_build,
            tree_state=tree_state,
        )

    @staticmethod
    def surfaces(manifest):
        return {surface["id"]: surface for surface in manifest["surfaces"]}

    @staticmethod
    def append(path: Path, text: str = "\n// fingerprint mutation\n") -> None:
        path.write_text(path.read_text() + text)

    def test_policy_covers_all_shipping_surfaces_and_governed_inputs(self):
        resolved = resolve_policy(REPO_ROOT)
        summary = validation_summary(resolved)
        self.assertEqual(summary["surfaceCount"], 13)
        self.assertEqual(summary["artifactCount"], 11)
        self.assertEqual(summary["governedInputCount"], summary["mappedInputCount"] + 6)
        self.assertEqual(
            summary["surfaceIds"],
            [
                "ios.app",
                "ios.widget",
                "ipados.app",
                "ipados.widget",
                "macos.app",
                "macos.refresh-agent",
                "macos.widget",
                "tvos.app",
                "tvos.top-shelf",
                "visionos.app",
                "visionos.widget",
                "watchos.app",
                "watchos.complication",
            ],
        )
        ignored_patterns = {
            entry["pattern"] for entry in resolved.policy["inventory"]["ignoredInputs"]
        }
        self.assertEqual(
            ignored_patterns,
            {
                "Sources/CodexRateLimitProbe/**/*.swift",
                "Sources/OpenAILimitProbe/**/*.swift",
                "Sources/PromptCacheTelemetryMirror/**/*.swift",
                "Sources/PromptCacheTelemetryProbe/**/*.swift",
                "Sources/SnapshotStoreProbe/**/*.swift",
                "Package.swift",
            },
        )

    def test_manifest_is_deterministic_and_contains_no_checkout_path(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            relocated_root = self.fixture(temporary_directory)
            relocated = self.manifest(relocated_root)
        self.assertEqual(relocated, self.baseline)
        encoded = json.dumps(relocated, sort_keys=True)
        self.assertNotIn(str(REPO_ROOT), encoded)
        self.assertNotIn(temporary_directory, encoded)

    def test_shared_artifact_surfaces_remain_distinct(self):
        surfaces = self.surfaces(self.baseline)
        self.assertEqual(surfaces["ios.app"]["artifactId"], surfaces["ipados.app"]["artifactId"])
        self.assertNotEqual(
            surfaces["ios.app"]["fingerprints"]["combined"],
            surfaces["ipados.app"]["fingerprints"]["combined"],
        )
        self.assertEqual(
            surfaces["ios.app"]["expectedArtifact"],
            surfaces["ipados.app"]["expectedArtifact"],
        )

    def test_unmapped_source_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            source = root / "Sources/UnmappedShippingCode/NewSurface.swift"
            source.parent.mkdir()
            source.write_text("struct NewSurface {}\n")
            with self.assertRaisesRegex(SurfacePolicyError, "governed inputs are unmapped"):
                resolve_policy(root)

    def test_synthetic_shipping_source_mutations_affect_owning_surfaces(self):
        mutations = {
            "Sources/ContextPanelApp": {"macos.app"},
            "Sources/ContextPanelWidget": {"macos.widget"},
            "Sources/ContextPanelRefreshAgent": {"macos.refresh-agent"},
            "Sources/ContextPanelCompanion": {"ios.app", "ipados.app", "visionos.app"},
            "Sources/ContextPanelCompanionWidget": {
                "ios.widget",
                "ipados.widget",
                "visionos.widget",
            },
            "Sources/ContextPanelWatch": {"watchos.app"},
            "Sources/ContextPanelWatchWidget": {"watchos.complication"},
            "Sources/ContextPanelTV": {"tvos.app"},
            "Sources/ContextPanelTVTopShelf": {"tvos.top-shelf"},
        }
        baseline_surfaces = self.surfaces(self.baseline)
        for directory, expected_surfaces in mutations.items():
            with self.subTest(directory=directory), tempfile.TemporaryDirectory() as temporary_directory:
                root = self.fixture(temporary_directory)
                (root / directory / "SyntheticFingerprintInput.swift").write_text(
                    "struct SyntheticFingerprintInput {}\n"
                )
                mutated_surfaces = self.surfaces(self.manifest(root))
                for surface_id in expected_surfaces:
                    self.assertNotEqual(
                        baseline_surfaces[surface_id]["fingerprints"]["combined"],
                        mutated_surfaces[surface_id]["fingerprints"]["combined"],
                    )

    def test_provider_transport_change_is_runtime_only(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelCloudKitSync/CompanionCloudKitSyncStore.swift")
            mutated = self.surfaces(self.manifest(root))
        baseline = self.surfaces(self.baseline)
        for surface_id in ("macos.app", "ios.app", "watchos.complication", "tvos.app"):
            self.assertEqual(
                baseline[surface_id]["fingerprints"]["render"],
                mutated[surface_id]["fingerprints"]["render"],
            )
            self.assertNotEqual(
                baseline[surface_id]["fingerprints"]["runtime"],
                mutated[surface_id]["fingerprints"]["runtime"],
            )
        for surface_id in ("macos.widget", "tvos.top-shelf"):
            self.assertEqual(
                baseline[surface_id]["fingerprints"], mutated[surface_id]["fingerprints"]
            )

    def test_shared_swiftui_change_moves_render_and_embedding_fingerprints(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelWidgetUI/ContextPanelWidgetViews.swift")
            mutated = self.surfaces(self.manifest(root))
        baseline = self.surfaces(self.baseline)
        for surface_id in ("macos.app", "macos.widget", "ios.app", "visionos.widget"):
            self.assertNotEqual(
                baseline[surface_id]["fingerprints"]["render"],
                mutated[surface_id]["fingerprints"]["render"],
            )
            self.assertEqual(
                baseline[surface_id]["fingerprints"]["runtime"],
                mutated[surface_id]["fingerprints"]["runtime"],
            )
        self.assertNotEqual(
            baseline["macos.app"]["fingerprints"]["combined"],
            mutated["macos.app"]["fingerprints"]["combined"],
        )

    def test_validation_gallery_change_moves_only_host_app_render_fingerprints(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(
                root
                / "Sources/ContextPanelValidationFixtures/ValidationFixtureCatalog.swift"
            )
            mutated = self.surfaces(self.manifest(root))
        baseline = self.surfaces(self.baseline)
        for surface_id in (
            "macos.app",
            "ios.app",
            "ipados.app",
            "visionos.app",
            "watchos.app",
            "tvos.app",
        ):
            self.assertNotEqual(
                baseline[surface_id]["fingerprints"]["render"],
                mutated[surface_id]["fingerprints"]["render"],
            )
            self.assertEqual(
                baseline[surface_id]["fingerprints"]["runtime"],
                mutated[surface_id]["fingerprints"]["runtime"],
            )
        for surface_id in (
            "macos.widget",
            "ios.widget",
            "ipados.widget",
            "visionos.widget",
            "watchos.complication",
            "tvos.top-shelf",
        ):
            self.assertEqual(
                baseline[surface_id]["fingerprints"],
                mutated[surface_id]["fingerprints"],
            )

    def test_top_shelf_renderer_change_moves_tv_app_and_top_shelf_render_fingerprints(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(
                root
                / "Sources/ContextPanelTVTopShelf/ContextPanelTVTopShelfProvider.swift"
            )
            mutated = self.surfaces(self.manifest(root))
        baseline = self.surfaces(self.baseline)
        self.assertNotEqual(
            baseline["tvos.app"]["fingerprints"]["render"],
            mutated["tvos.app"]["fingerprints"]["render"],
        )
        self.assertEqual(
            baseline["tvos.app"]["fingerprints"]["runtime"],
            mutated["tvos.app"]["fingerprints"]["runtime"],
        )
        for fingerprint in ("render", "runtime"):
            self.assertNotEqual(
                baseline["tvos.top-shelf"]["fingerprints"][fingerprint],
                mutated["tvos.top-shelf"]["fingerprints"][fingerprint],
            )

        for surface_id in (
            "macos.app",
            "macos.widget",
            "ios.app",
            "ios.widget",
            "ipados.app",
            "ipados.widget",
            "visionos.app",
            "visionos.widget",
            "watchos.app",
            "watchos.complication",
        ):
            self.assertEqual(
                baseline[surface_id]["fingerprints"],
                mutated[surface_id]["fingerprints"],
            )

    def test_extension_host_change_invalidates_extension_runtime(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelApp/ContextPanelApp.swift")
            mutated = self.surfaces(self.manifest(root))
        baseline = self.surfaces(self.baseline)
        self.assertEqual(
            baseline["macos.widget"]["fingerprints"]["render"],
            mutated["macos.widget"]["fingerprints"]["render"],
        )
        self.assertNotEqual(
            baseline["macos.widget"]["fingerprints"]["runtime"],
            mutated["macos.widget"]["fingerprints"]["runtime"],
        )

    def test_entitlement_change_invalidates_runtime_and_parent_embedding(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Config/ContextPanelWidget.entitlements", "\n<!-- mutation -->\n")
            mutated = self.surfaces(self.manifest(root))
        baseline = self.surfaces(self.baseline)
        self.assertEqual(
            baseline["macos.widget"]["fingerprints"]["render"],
            mutated["macos.widget"]["fingerprints"]["render"],
        )
        self.assertNotEqual(
            baseline["macos.widget"]["fingerprints"]["runtime"],
            mutated["macos.widget"]["fingerprints"]["runtime"],
        )
        self.assertEqual(
            baseline["macos.app"]["fingerprints"]["runtime"],
            mutated["macos.app"]["fingerprints"]["runtime"],
        )
        self.assertNotEqual(
            baseline["macos.app"]["fingerprints"]["combined"],
            mutated["macos.app"]["fingerprints"]["combined"],
        )

    def test_cloudkit_contract_change_only_hits_syncing_surfaces(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            schema = root / "CloudKit/companion-sync.schema.json"
            payload = json.loads(schema.read_text())
            payload["fingerprintFixture"] = True
            schema.write_text(json.dumps(payload, indent=2) + "\n")
            mutated = self.surfaces(self.manifest(root))
        baseline = self.surfaces(self.baseline)
        for surface_id in ("macos.app", "macos.refresh-agent", "ios.widget", "watchos.app"):
            self.assertNotEqual(
                baseline[surface_id]["fingerprints"]["runtime"],
                mutated[surface_id]["fingerprints"]["runtime"],
            )
        for surface_id in ("macos.widget", "tvos.top-shelf"):
            self.assertEqual(
                baseline[surface_id]["fingerprints"], mutated[surface_id]["fingerprints"]
            )

    def test_target_project_setting_is_scoped_to_own_surface(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            project = root / "project.yml"
            project.write_text(
                project.read_text().replace(
                    "PRODUCT_NAME: ContextPanelWidgetExtension",
                    "PRODUCT_NAME: ContextPanelWidgetExtensionFingerprintFixture",
                    1,
                )
            )
            mutated = self.surfaces(self.manifest(root))
        baseline = self.surfaces(self.baseline)
        self.assertNotEqual(
            baseline["macos.widget"]["fingerprints"]["runtime"],
            mutated["macos.widget"]["fingerprints"]["runtime"],
        )
        self.assertEqual(
            baseline["macos.app"]["fingerprints"]["runtime"],
            mutated["macos.app"]["fingerprints"]["runtime"],
        )
        self.assertNotEqual(
            baseline["macos.app"]["fingerprints"]["combined"],
            mutated["macos.app"]["fingerprints"]["combined"],
        )
        self.assertEqual(
            baseline["ios.app"]["fingerprints"], mutated["ios.app"]["fingerprints"]
        )

    def test_toolchain_policy_change_invalidates_every_surface(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            policy_path = root / "Config/ContextPanelSurfacePolicy.json"
            policy = json.loads(policy_path.read_text())
            policy["toolchain"]["releaseXcodeMajor"] = "27"
            policy_path.write_text(json.dumps(policy, indent=2, sort_keys=True) + "\n")
            mutated = self.surfaces(self.manifest(root))
        baseline = self.surfaces(self.baseline)
        for surface_id in baseline:
            self.assertNotEqual(
                baseline[surface_id]["fingerprints"], mutated[surface_id]["fingerprints"]
            )

    def test_surface_policy_requires_toolchain_identity(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            policy_path = root / "Config/ContextPanelSurfacePolicy.json"
            policy = json.loads(policy_path.read_text())
            policy.pop("toolchain")
            policy_path.write_text(json.dumps(policy, indent=2, sort_keys=True) + "\n")
            with self.assertRaisesRegex(SurfacePolicyError, "toolchain is missing"):
                resolve_policy(root)

    def test_swiftpm_manifest_is_explicitly_non_shipping(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Package.swift")
            mutated = self.manifest(root)
        self.assertEqual(mutated, self.baseline)

    def test_contract_tooling_change_invalidates_carry_forward_without_relabeling_ui(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "scripts/context_panel_surface_manifest/cli.py")
            mutated = self.manifest(root)
        baseline_surfaces = self.surfaces(self.baseline)
        mutated_surfaces = self.surfaces(mutated)
        for surface_id in baseline_surfaces:
            self.assertEqual(
                baseline_surfaces[surface_id]["fingerprints"],
                mutated_surfaces[surface_id]["fingerprints"],
            )
        self.assertNotEqual(
            self.baseline["contractFingerprint"], mutated["contractFingerprint"]
        )
        comparison = compare_manifests(self.baseline, mutated, "release")
        widget = {surface["surfaceId"]: surface for surface in comparison["surfaces"]}[
            "macos.widget"
        ]
        self.assertIn("contract-fingerprint-changed", widget["reasonCodes"])
        self.assertEqual(
            widget["freshEvidence"],
            ["shared-view", "actual-runtime", "os-composited-placement"],
        )
        self.assertTrue(comparison["contractChanged"])

    def test_placement_host_change_requires_fresh_runtime_and_placement(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelTV/TVSystemSurfaces.swift")
            mutated = self.manifest(root)
        baseline_surface = self.surfaces(self.baseline)["tvos.top-shelf"]
        mutated_surface = self.surfaces(mutated)["tvos.top-shelf"]
        self.assertEqual(
            baseline_surface["fingerprints"]["render"],
            mutated_surface["fingerprints"]["render"],
        )
        self.assertNotEqual(
            baseline_surface["fingerprints"]["runtime"],
            mutated_surface["fingerprints"]["runtime"],
        )
        self.assertNotEqual(
            baseline_surface["fingerprints"]["placement"],
            mutated_surface["fingerprints"]["placement"],
        )
        comparison = compare_manifests(self.baseline, mutated, "release")
        surface = {item["surfaceId"]: item for item in comparison["surfaces"]}[
            "tvos.top-shelf"
        ]
        self.assertEqual(
            surface["freshEvidence"],
            ["actual-runtime", "os-composited-placement"],
        )
        self.assertFalse(
            surface["carryForward"]["os-composited-placement"]["eligible"]
        )

    def test_evidence_policy_typos_fail_closed(self):
        malformed = json.loads(json.dumps(self.baseline))
        malformed["evidencePolicy"]["changeRequirements"].pop("placement")
        with self.assertRaisesRegex(SurfacePolicyError, "changeRequirements is invalid"):
            compare_manifests(self.baseline, malformed, "release")

        malformed = json.loads(json.dumps(self.baseline))
        malformed["evidencePolicy"]["classes"].reverse()
        with self.assertRaisesRegex(SurfacePolicyError, "evidence classes are invalid"):
            compare_manifests(self.baseline, malformed, "release")

    def test_manifest_surface_capabilities_fail_closed(self):
        malformed = json.loads(json.dumps(self.baseline))
        malformed["surfaces"][0].pop("evidenceCapabilities")
        with self.assertRaisesRegex(SurfacePolicyError, "evidence capabilities are invalid"):
            compare_manifests(self.baseline, malformed, "release")

    def test_policy_rejects_nonstring_artifact_identifier_at_producer_boundary(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            policy_path = root / "Config/ContextPanelSurfacePolicy.json"
            policy = json.loads(policy_path.read_text())
            policy["surfaces"][0]["artifactId"] = 42
            policy_path.write_text(json.dumps(policy))
            with self.assertRaisesRegex(
                SurfacePolicyError,
                "surface artifact id is invalid: macos.app",
            ):
                resolve_policy(root)

    def test_unsupported_project_top_level_key_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            project = root / "project.yml"
            project.write_text(project.read_text() + "\nconfigs: {}\n")
            with self.assertRaisesRegex(SurfacePolicyError, "unsupported top-level keys"):
                resolve_policy(root)

    def test_runtime_only_group_rejects_presentation_imports(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(
                root / "Sources/ContextPanelCloudKitSync/CompanionCloudKitSyncStore.swift",
                "\nimport SwiftUI\n",
            )
            with self.assertRaisesRegex(SurfacePolicyError, "imports a presentation framework"):
                resolve_policy(root)

    def test_version_only_change_preserves_source_fingerprints_but_requires_runtime(self):
        next_build = self.manifest(REPO_ROOT, version="1.0.54", build="2026073002")
        baseline_surfaces = self.surfaces(self.baseline)
        next_surfaces = self.surfaces(next_build)
        for surface_id in baseline_surfaces:
            self.assertEqual(
                baseline_surfaces[surface_id]["fingerprints"],
                next_surfaces[surface_id]["fingerprints"],
            )
        comparison = compare_manifests(self.baseline, next_build, "release")
        mac_widget = {surface["surfaceId"]: surface for surface in comparison["surfaces"]}[
            "macos.widget"
        ]
        self.assertEqual(mac_widget["reasonCodes"], ["exact-build-changed"])
        self.assertEqual(mac_widget["freshEvidence"], ["actual-runtime"])
        self.assertTrue(mac_widget["carryForward"]["shared-view"]["eligible"])
        self.assertFalse(mac_widget["carryForward"]["actual-runtime"]["eligible"])
        self.assertTrue(
            mac_widget["carryForward"]["os-composited-placement"]["eligible"]
        )
        self.assertEqual(
            mac_widget["carryForward"]["os-composited-placement"]["conditions"],
            ["matching-host-os", "matching-current-runtime-receipt"],
        )

    def test_render_and_runtime_changes_select_distinct_evidence(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelWidgetUI/ContextPanelWidgetViews.swift")
            render_comparison = compare_manifests(
                self.baseline, self.manifest(root), "release"
            )
        render_surface = {
            surface["surfaceId"]: surface for surface in render_comparison["surfaces"]
        }["macos.widget"]
        self.assertEqual(
            render_surface["freshEvidence"],
            ["shared-view"],
        )
        self.assertFalse(render_surface["carryForward"]["shared-view"]["eligible"])
        self.assertTrue(render_surface["carryForward"]["actual-runtime"]["eligible"])
        self.assertTrue(
            render_surface["carryForward"]["os-composited-placement"]["eligible"]
        )
        self.assertEqual(
            render_surface["carryForward"]["os-composited-placement"]["conditions"],
            ["matching-host-os", "matching-current-runtime-receipt"],
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelCloudKitSync/CompanionCloudKitSyncStore.swift")
            runtime_comparison = compare_manifests(
                self.baseline, self.manifest(root), "release"
            )
        runtime_surface = {
            surface["surfaceId"]: surface for surface in runtime_comparison["surfaces"]
        }["macos.app"]
        self.assertEqual(runtime_surface["freshEvidence"], ["actual-runtime"])
        self.assertTrue(runtime_surface["carryForward"]["shared-view"]["eligible"])
        self.assertFalse(runtime_surface["carryForward"]["actual-runtime"]["eligible"])

    def test_beta_render_change_uses_shared_view_without_device_session(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelWidgetUI/ContextPanelWidgetViews.swift")
            comparison = compare_manifests(self.baseline, self.manifest(root), "beta")

        widget = {surface["surfaceId"]: surface for surface in comparison["surfaces"]}[
            "macos.widget"
        ]
        self.assertEqual(widget["requiredEvidence"], ["shared-view"])
        self.assertEqual(widget["freshEvidence"], ["shared-view"])
        self.assertFalse(comparison["requiresRuntimeSession"])
        self.assertFalse(comparison["requiresPlacementReview"])
        self.assertEqual(comparison["requiredSurfaces"]["actual-runtime"], [])
        self.assertEqual(comparison["requiredSurfaces"]["os-composited-placement"], [])
        self.assertEqual(comparison["runtimeState"], "not-required-no-session")
        self.assertEqual(comparison["runtimeStateReasons"], [])

    def test_comparison_v4_rejects_hand_trimmed_or_noncanonical_payloads(self):
        comparison = compare_manifests(self.baseline, self.manifest(REPO_ROOT), "beta")
        self.assertEqual(comparison["kind"], "context-panel-surface-comparison")
        self.assertEqual(comparison["schemaVersion"], 4)
        mutations = (
            lambda value: value.__setitem__("unexpected", True),
            lambda value: value["surfaces"][0].pop("artifactId"),
            lambda value: value["surfaces"][0]["changes"].__setitem__("extra", False),
            lambda value: value["surfaces"][0]["carryForward"].__setitem__("extra", {}),
            lambda value: value["surfaces"][0]["carryForward"].pop(
                value["surfaces"][0]["requiredEvidence"][0]
            ),
            lambda value: value.__setitem__("surfaces", list(reversed(value["surfaces"]))),
            lambda value: value["requiredSurfaces"]["shared-view"].reverse(),
            lambda value: value["requiredSurfaces"]["shared-view"].append(
                value["requiredSurfaces"]["shared-view"][0]
            ),
            lambda value: value.__setitem__("schemaVersion", 3.0),
            lambda value: value.__setitem__("runtimeState", "required-with-session"),
            lambda value: value.__setitem__(
                "runtimeStateReasons", ["train-minimum-required"]
            ),
            lambda value: value["surfaces"][0]["reasonCodes"].__setitem__(
                0,
                "render-fingerprint-changed",
            ),
            lambda value: value["surfaces"][0].__setitem__("reasonCodes", ["new-surface"]),
            lambda value: value["removedSurfaces"].append(value["surfaces"][0]["surfaceId"]),
            lambda value: value["surfaces"][0].__setitem__(
                "carryForward",
                dict(reversed(list(value["surfaces"][0]["carryForward"].items()))),
            ),
        )
        for mutate in mutations:
            candidate = copy.deepcopy(comparison)
            mutate(candidate)
            with self.assertRaises(ComparisonSchemaError):
                validate_current_comparison(candidate)

    def test_comparison_v3_rejects_inconsistent_fresh_and_placement_evidence(self):
        comparison = compare_manifests(self.baseline, self.manifest(REPO_ROOT), "beta")
        fresh_candidate = copy.deepcopy(comparison)
        fresh_surface = next(
            surface
            for surface in fresh_candidate["surfaces"]
            if "actual-runtime" in surface["carryForward"]
        )
        surface_id = fresh_surface["surfaceId"]
        fresh_surface["freshEvidence"] = ["actual-runtime"]
        fresh_surface["requiredEvidence"] = ["shared-view", "actual-runtime"]
        fresh_surface["carryForward"]["actual-runtime"]["eligible"] = True
        fresh_candidate["requiredSurfaces"]["actual-runtime"] = [surface_id]
        fresh_candidate["requiresRuntimeSession"] = True
        with self.assertRaisesRegex(ComparisonSchemaError, "fresh evidence cannot carry forward"):
            validate_current_comparison(fresh_candidate)

        placement_candidate = copy.deepcopy(comparison)
        placement_surface = next(
            surface
            for surface in placement_candidate["surfaces"]
            if "os-composited-placement" in surface["carryForward"]
        )
        placement_surface["freshEvidence"] = ["os-composited-placement"]
        placement_surface["requiredEvidence"] = ["shared-view", "os-composited-placement"]
        placement_surface["carryForward"]["os-composited-placement"] = {
            "eligible": False,
            "conditions": [],
        }
        placement_candidate["requiredSurfaces"]["os-composited-placement"] = [
            placement_surface["surfaceId"]
        ]
        runtime_surface = next(
            surface
            for surface in placement_candidate["surfaces"]
            if surface["surfaceId"] != placement_surface["surfaceId"]
            and "actual-runtime" in surface["carryForward"]
        )
        runtime_surface["freshEvidence"] = ["actual-runtime"]
        runtime_surface["requiredEvidence"] = ["shared-view", "actual-runtime"]
        runtime_surface["carryForward"]["actual-runtime"] = {
            "eligible": False,
            "conditions": [],
        }
        placement_candidate["requiredSurfaces"]["actual-runtime"] = [
            runtime_surface["surfaceId"]
        ]
        placement_candidate["requiresRuntimeSession"] = True
        placement_candidate["requiresPlacementReview"] = True
        with self.assertRaisesRegex(
            ComparisonSchemaError,
            "placement evidence requires runtime evidence",
        ):
            validate_current_comparison(placement_candidate)

    def test_comparison_v2_derives_carry_forward_eligibility_from_changes(self):
        def invalid_eligible(comparison, surface_id, evidence_class):
            candidate = copy.deepcopy(comparison)
            surface = {item["surfaceId"]: item for item in candidate["surfaces"]}[surface_id]
            surface["freshEvidence"] = [
                item for item in surface["freshEvidence"] if item != evidence_class
            ]
            surface["requiredEvidence"] = [
                item
                for item in ("shared-view", "actual-runtime", "os-composited-placement")
                if item in surface["minimumEvidence"] or item in surface["freshEvidence"]
            ]
            surface["carryForward"][evidence_class]["eligible"] = True
            if evidence_class == "os-composited-placement":
                surface["carryForward"][evidence_class]["conditions"] = [
                    "matching-host-os",
                    "matching-current-runtime-receipt",
                ]
            for required_class in ("shared-view", "actual-runtime", "os-composited-placement"):
                candidate["requiredSurfaces"][required_class] = [
                    item["surfaceId"]
                    for item in candidate["surfaces"]
                    if required_class in item["requiredEvidence"]
                ]
            candidate["requiresRuntimeSession"] = bool(
                candidate["requiredSurfaces"]["actual-runtime"]
            )
            candidate["requiresPlacementReview"] = bool(
                candidate["requiredSurfaces"]["os-composited-placement"]
            )
            return candidate

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelWidgetUI/ContextPanelWidgetViews.swift")
            render_comparison = compare_manifests(self.baseline, self.manifest(root), "release")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelCloudKitSync/CompanionCloudKitSyncStore.swift")
            runtime_comparison = compare_manifests(self.baseline, self.manifest(root), "release")
        exact_build_comparison = compare_manifests(
            self.baseline,
            self.manifest(REPO_ROOT, version="1.0.54", build="2026073002"),
            "release",
        )
        placement_manifest = copy.deepcopy(self.baseline)
        self.surfaces(placement_manifest)["macos.widget"]["fingerprints"]["placement"] = "f" * 64
        placement_comparison = compare_manifests(self.baseline, placement_manifest, "beta")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "scripts/context_panel_comparison_schema.py")
            contract_comparison = compare_manifests(self.baseline, self.manifest(root), "release")
        previous_without_widget = copy.deepcopy(self.baseline)
        previous_without_widget["surfaces"] = [
            surface for surface in previous_without_widget["surfaces"] if surface["id"] != "macos.widget"
        ]
        new_surface_comparison = compare_manifests(previous_without_widget, self.baseline, "release")

        candidates = (
            invalid_eligible(render_comparison, "macos.widget", "shared-view"),
            invalid_eligible(runtime_comparison, "macos.app", "actual-runtime"),
            invalid_eligible(exact_build_comparison, "macos.widget", "actual-runtime"),
            invalid_eligible(placement_comparison, "macos.widget", "os-composited-placement"),
            invalid_eligible(contract_comparison, "macos.widget", "shared-view"),
            invalid_eligible(new_surface_comparison, "macos.widget", "shared-view"),
        )
        for candidate in candidates:
            with self.assertRaisesRegex(
                ComparisonSchemaError,
                "carry-forward eligibility is inconsistent",
            ):
                validate_current_comparison(candidate)

    def test_runtime_state_is_derived_from_authoritative_evidence_scope(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift")
            runtime = compare_manifests(self.baseline, self.manifest(root), "beta")
        self.assertEqual(runtime["runtimeState"], "required-with-session")
        self.assertEqual(
            runtime["runtimeStateReasons"], ["runtime-fingerprint-changed"]
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift")
            release_runtime = compare_manifests(
                self.baseline,
                self.manifest(root),
                "release",
            )
        self.assertEqual(release_runtime["runtimeState"], "required-with-session")
        self.assertEqual(
            release_runtime["runtimeStateReasons"],
            ["train-minimum-required", "runtime-fingerprint-changed"],
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "scripts/context_panel_comparison_schema.py")
            unknown = compare_manifests(self.baseline, self.manifest(root), "beta")
        self.assertEqual(unknown["runtimeState"], "unknown-fail-closed")
        self.assertIn(
            "contract-fingerprint-changed", unknown["runtimeStateReasons"]
        )

    def test_comparison_schema_is_a_surface_tooling_contract_input(self):
        self.assertIn("scripts/context_panel_comparison_schema.py", self.baseline["files"])
        frozen_schema_path = (
            REPO_ROOT
            / "scripts/context_panel_surface_manifest/comparison_schema_v2.py"
        )
        self.assertIn(
            "scripts/context_panel_surface_manifest/comparison_schema_v2.py",
            self.baseline["files"],
        )
        self.assertEqual(
            hashlib.sha256(frozen_schema_path.read_bytes()).hexdigest(),
            "a0e7d39db68bc75c5a8d62df9e48fb138643542f0457268c3558947ebb1d18fb",
        )
        self.assertIs(
            sys.modules["context_panel_surface_manifest.comparison_schema_v2"],
            comparison_schema_module.comparison_schema_v2,
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "scripts/context_panel_comparison_schema.py")
            changed = self.manifest(root)
        self.assertNotEqual(
            self.baseline["contractFingerprint"],
            changed["contractFingerprint"],
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(
                root / "scripts/context_panel_surface_manifest/comparison_schema_v2.py"
            )
            changed = self.manifest(root)
        self.assertNotEqual(
            self.baseline["contractFingerprint"],
            changed["contractFingerprint"],
        )

    def test_production_comparison_imports_cannot_reach_replay(self):
        scripts_root = REPO_ROOT / "scripts"

        def module_path(module_name: str) -> Path | None:
            parts = module_name.split(".")
            module_file = scripts_root.joinpath(*parts).with_suffix(".py")
            package_file = scripts_root.joinpath(*parts) / "__init__.py"
            if module_file.is_file():
                return module_file
            if package_file.is_file():
                return package_file
            return None

        def local_imports(module_name: str, path: Path) -> set[str]:
            imports: set[str] = set()
            package_parts = module_name.split(".")
            if path.name != "__init__.py":
                package_parts.pop()
            for node in ast.walk(ast.parse(path.read_text())):
                if isinstance(node, ast.Import):
                    imports.update(alias.name for alias in node.names if alias.name.startswith("context_panel_"))
                elif isinstance(node, ast.ImportFrom):
                    if node.level:
                        base = package_parts[: len(package_parts) - node.level + 1]
                        prefix = ".".join((*base, *(node.module or "").split("."))).strip(".")
                        if prefix.startswith("context_panel_"):
                            imports.add(prefix)
                    elif node.module and node.module.startswith("context_panel_"):
                        imports.add(node.module)
            return imports

        pending = [
            "context_panel_comparison_schema",
            "context_panel_surface_manifest",
            "context_panel_surface_manifest.comparison_schema_v2",
            "context_panel_surface_manifest.core",
            "context_panel_surface_manifest.cli",
            "context_panel_validation",
            "context_panel_validation.visual_approvals",
            "context_panel_validation.cli",
            "context_panel_release_gate",
            "context_panel_release_gate.core",
            "context_panel_release_gate.cli",
        ]
        entrypoint_paths = (
            scripts_root / "context-panel-surface-manifest.py",
            scripts_root / "context-panel-validation.py",
            scripts_root / "context-panel-release-gate.py",
            scripts_root / "validate-release-evidence-report.py",
            scripts_root / "submit-app-store-review.py",
        )
        visited: set[str] = set()
        for path in entrypoint_paths:
            self.assertTrue(path.is_file(), path)
            pending.extend(local_imports(path.stem, path))
        while pending:
            module_name = pending.pop()
            if module_name in visited:
                continue
            visited.add(module_name)
            self.assertFalse(module_name.startswith("context_panel_replay"))
            path = module_path(module_name)
            self.assertIsNotNone(path, module_name)
            assert path is not None
            pending.extend(local_imports(module_name, path) - visited)
    def test_beta_runtime_change_scopes_runtime_session_to_affected_surfaces(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(
                root / "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift"
            )
            comparison = compare_manifests(self.baseline, self.manifest(root), "beta")

        self.assertTrue(comparison["requiresRuntimeSession"])
        self.assertEqual(
            comparison["requiredSurfaces"]["actual-runtime"],
            ["macos.refresh-agent"],
        )
        self.assertFalse(comparison["requiresPlacementReview"])

    def test_new_beta_build_does_not_require_all_device_runtime_proof(self):
        next_build = self.manifest(REPO_ROOT, version="1.0.54", build="2026073002")
        comparison = compare_manifests(self.baseline, next_build, "beta")
        expected_shared = sorted(
            surface_id
            for surface_id, surface in self.surfaces(next_build).items()
            if "shared-view" in surface["evidenceCapabilities"]
        )

        self.assertFalse(comparison["requiresRuntimeSession"])
        self.assertEqual(comparison["requiredSurfaces"]["actual-runtime"], [])
        self.assertEqual(comparison["requiredSurfaces"]["shared-view"], expected_shared)
        for surface in comparison["surfaces"]:
            self.assertNotIn("actual-runtime", surface["freshEvidence"])
            if surface["surfaceId"] in expected_shared:
                self.assertIn("shared-view", surface["requiredEvidence"])
                self.assertTrue(
                    surface["carryForward"]["shared-view"]["eligible"]
                )

    def test_v4_roots_record_only_active_risks_and_observations(self):
        comparison = compare_manifests(self.baseline, self.manifest(REPO_ROOT), "beta")
        self.assertEqual(set(comparison), comparison_schema_module.ROOT_KEYS)
        self.assertEqual(comparison["schemaVersion"], 4)
        self.assertEqual(comparison["riskCodes"], [])
        self.assertEqual(comparison["riskSurfaces"], {})
        self.assertEqual(comparison["observationRiskCodes"], [])

        placement = copy.deepcopy(self.baseline)
        placement_surface = self.surfaces(placement)["macos.widget"]
        placement_surface["fingerprints"]["placement"] = "f" * 64
        placement_comparison = compare_manifests(self.baseline, placement, "beta")
        self.assertEqual(
            placement_comparison["riskCodes"], ["placement-divergence"]
        )
        self.assertEqual(
            placement_comparison["riskSurfaces"],
            {"placement-divergence": ["macos.widget"]},
        )
        self.assertEqual(
            placement_comparison["observationRiskCodes"], ["host-os-divergence"]
        )

    def test_compare_cli_preserves_schema_canonical_map_order(self):
        current = copy.deepcopy(self.baseline)
        current["contractFingerprint"] = "f" * 64
        self.surfaces(current)["macos.app"]["fingerprints"]["render"] = "a" * 64
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            previous_path = root / "previous.json"
            current_path = root / "current.json"
            output_path = root / "comparison.json"
            previous_path.write_text(json.dumps(self.baseline))
            current_path.write_text(json.dumps(current))
            cli_module.run(
                SimpleNamespace(
                    command="compare",
                    previous=previous_path,
                    current=current_path,
                    train="beta",
                    output=output_path,
                )
            )
            comparison = json.loads(output_path.read_text())
        self.assertEqual(validate_current_comparison(comparison), comparison)
        self.assertEqual(
            list(comparison["riskSurfaces"]),
            ["render-divergence", "contract-divergence"],
        )

    def test_toolchain_divergence_records_on_beta_without_runtime_session(self):
        next_build = copy.deepcopy(self.baseline)
        next_build["source"]["xcodeBuild"] = "27A000"
        comparison = compare_manifests(self.baseline, next_build, "beta")
        runtime_capable = sorted(
            surface_id
            for surface_id, surface in self.surfaces(next_build).items()
            if "actual-runtime" in surface["evidenceCapabilities"]
        )
        self.assertTrue(comparison["toolchainChanged"])
        self.assertEqual(comparison["riskCodes"], ["toolchain-divergence"])
        self.assertEqual(
            comparison["riskSurfaces"], {"toolchain-divergence": runtime_capable}
        )
        self.assertEqual(comparison["requiredSurfaces"]["actual-runtime"], [])
        self.assertFalse(comparison["requiresRuntimeSession"])

    def test_rc_toolchain_divergence_forces_runtime_capable_surfaces(self):
        next_build = copy.deepcopy(self.baseline)
        next_build["toolchain"] = {
            **next_build["toolchain"],
            "swiftLanguageVersion": "6.1",
        }
        comparison = compare_manifests(self.baseline, next_build, "rc")
        runtime_capable = sorted(
            surface_id
            for surface_id, surface in self.surfaces(next_build).items()
            if "actual-runtime" in surface["evidenceCapabilities"]
        )
        self.assertTrue(comparison["toolchainChanged"])
        self.assertEqual(comparison["riskSurfaces"]["toolchain-divergence"], runtime_capable)
        self.assertEqual(comparison["requiredSurfaces"]["actual-runtime"], runtime_capable)
        self.assertTrue(comparison["requiresRuntimeSession"])
        for surface in comparison["surfaces"]:
            if surface["surfaceId"] in runtime_capable:
                self.assertIn("actual-runtime", surface["freshEvidence"])

    def test_toolchain_divergence_with_no_runtime_capable_surfaces_is_valid(self):
        previous = copy.deepcopy(self.baseline)
        current = copy.deepcopy(self.baseline)
        current["source"]["xcodeBuild"] = "27A000"
        for manifest in (previous, current):
            for surface in manifest["surfaces"]:
                surface["evidenceCapabilities"] = ["shared-view"]
        comparison = compare_manifests(previous, current, "beta")
        self.assertTrue(comparison["toolchainChanged"])
        self.assertEqual(comparison["riskCodes"], [])
        self.assertEqual(comparison["riskSurfaces"], {})
        self.assertEqual(validate_current_comparison(comparison), comparison)

    def test_build_number_only_change_is_not_toolchain_risk(self):
        next_build = copy.deepcopy(self.baseline)
        next_build["source"]["buildNumber"] = "2026073002"
        comparison = compare_manifests(self.baseline, next_build, "beta")
        self.assertFalse(comparison["toolchainChanged"])
        self.assertNotIn("toolchain-divergence", comparison["riskCodes"])
        self.assertEqual(comparison["riskSurfaces"], {})

    def test_v4_risk_maps_require_canonical_order_and_exact_surfaces(self):
        candidate = copy.deepcopy(self.baseline)
        surfaces = self.surfaces(candidate)
        surfaces["macos.app"]["fingerprints"]["render"] = "a" * 64
        surfaces["macos.app"]["fingerprints"]["runtime"] = "b" * 64
        comparison = compare_manifests(self.baseline, candidate, "beta")
        self.assertEqual(
            comparison["riskCodes"], ["render-divergence", "runtime-divergence"]
        )
        reversed_codes = copy.deepcopy(comparison)
        reversed_codes["riskCodes"].reverse()
        with self.assertRaises(ComparisonSchemaError):
            validate_current_comparison(reversed_codes)
        wrong_surface = copy.deepcopy(comparison)
        wrong_surface["riskSurfaces"]["render-divergence"] = ["macos.widget"]
        with self.assertRaises(ComparisonSchemaError):
            validate_current_comparison(wrong_surface)
        reversed_map = copy.deepcopy(comparison)
        reversed_map["riskSurfaces"] = dict(
            reversed(list(reversed_map["riskSurfaces"].items()))
        )
        with self.assertRaises(ComparisonSchemaError):
            validate_current_comparison(reversed_map)
        missing_risks = copy.deepcopy(comparison)
        missing_risks["riskCodes"] = []
        missing_risks["riskSurfaces"] = {}
        with self.assertRaises(ComparisonSchemaError):
            validate_current_comparison(missing_risks)
        empty_extra_risk = copy.deepcopy(comparison)
        empty_extra_risk["riskCodes"].append("placement-divergence")
        empty_extra_risk["riskSurfaces"]["placement-divergence"] = []
        with self.assertRaises(ComparisonSchemaError):
            validate_current_comparison(empty_extra_risk)

    def test_new_surface_reports_every_changed_fingerprint_risk(self):
        previous = copy.deepcopy(self.baseline)
        previous["surfaces"] = [
            surface
            for surface in previous["surfaces"]
            if surface["id"] != "macos.app"
        ]
        current = copy.deepcopy(self.baseline)
        current["contractFingerprint"] = "f" * 64
        comparison = compare_manifests(previous, current, "beta")
        self.assertEqual(
            comparison["riskCodes"],
            [
                "unmapped-surface",
                "render-divergence",
                "runtime-divergence",
                "placement-divergence",
                "contract-divergence",
            ],
        )
        for risk_code in (
            "unmapped-surface",
            "render-divergence",
            "runtime-divergence",
            "placement-divergence",
        ):
            self.assertIn("macos.app", comparison["riskSurfaces"][risk_code])
        self.assertEqual(
            comparison["riskSurfaces"]["contract-divergence"],
            sorted(surface["id"] for surface in current["surfaces"]),
        )

    def test_risk_derivation_rejects_malformed_surface_inputs(self):
        with self.assertRaises(ComparisonSchemaError):
            derive_risk_fields(
                [{"surfaceId": "macos.app"}],
                toolchain_delta=False,
                runtime_capable_surface_ids=set(),
                requires_placement_review=False,
            )

    def test_legacy_v3_comparison_reconstructs_without_v4_roots(self):
        current = compare_manifests(self.baseline, self.manifest(REPO_ROOT), "beta")
        legacy = {
            key: copy.deepcopy(current[key])
            for key in comparison_schema_module.V3_ROOT_KEYS
        }
        legacy["schemaVersion"] = 3
        self.assertEqual(
            comparison_schema_module.validate_legacy_v3_comparison_for_reconstruction(
                legacy
            ),
            legacy,
        )

    def test_beta_placement_only_change_requires_runtime_and_placement(self):
        mutated = json.loads(json.dumps(self.baseline))
        surface = self.surfaces(mutated)["macos.widget"]
        surface["fingerprints"]["placement"] = "f" * 64
        comparison = compare_manifests(self.baseline, mutated, "beta")
        result = {item["surfaceId"]: item for item in comparison["surfaces"]}[
            "macos.widget"
        ]

        self.assertEqual(
            result["freshEvidence"],
            ["actual-runtime", "os-composited-placement"],
        )
        self.assertEqual(
            result["requiredEvidence"],
            ["shared-view", "actual-runtime", "os-composited-placement"],
        )
        self.assertEqual(
            comparison["requiredSurfaces"]["actual-runtime"],
            ["macos.widget"],
        )
        self.assertEqual(
            comparison["requiredSurfaces"]["os-composited-placement"],
            ["macos.widget"],
        )
        self.assertTrue(comparison["requiresRuntimeSession"])
        self.assertTrue(comparison["requiresPlacementReview"])

    def test_extension_entry_points_are_placement_sensitive(self):
        cases = (
            (
                "Sources/ContextPanelWidget/ContextPanelWidget.swift",
                ("macos.widget",),
            ),
            (
                "Sources/ContextPanelCompanionWidget/ContextPanelCompanionWidget.swift",
                ("ios.widget", "ipados.widget", "visionos.widget"),
            ),
            (
                "Sources/ContextPanelWatchWidget/ContextPanelWatchWidget.swift",
                ("watchos.complication",),
            ),
            (
                "Sources/ContextPanelTVTopShelf/ContextPanelTVTopShelfProvider.swift",
                ("tvos.top-shelf",),
            ),
            (
                "Sources/ContextPanelCore/ContextPanelWidgetIdentity.swift",
                (
                    "macos.widget",
                    "ios.widget",
                    "ipados.widget",
                    "visionos.widget",
                    "watchos.complication",
                ),
            ),
        )

        for relative_path, surface_ids in cases:
            with self.subTest(relative_path=relative_path):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = self.fixture(temporary_directory)
                    self.append(root / relative_path)
                    mutated = self.manifest(root)
                baseline_surfaces = self.surfaces(self.baseline)
                mutated_surfaces = self.surfaces(mutated)
                comparison = compare_manifests(self.baseline, mutated, "beta")
                compared = {
                    surface["surfaceId"]: surface for surface in comparison["surfaces"]
                }

                for surface_id in surface_ids:
                    self.assertNotEqual(
                        baseline_surfaces[surface_id]["fingerprints"]["placement"],
                        mutated_surfaces[surface_id]["fingerprints"]["placement"],
                    )
                    self.assertIn(
                        "os-composited-placement",
                        compared[surface_id]["requiredEvidence"],
                    )
                    self.assertFalse(
                        compared[surface_id]["carryForward"][
                            "os-composited-placement"
                        ]["eligible"]
                    )

    def test_rc_exact_build_requires_runtime_for_every_capable_surface(self):
        next_build = self.manifest(REPO_ROOT, version="1.0.54", build="2026073002")
        comparison = compare_manifests(self.baseline, next_build, "rc")
        expected = sorted(
            surface_id
            for surface_id, surface in self.surfaces(next_build).items()
            if "actual-runtime" in surface["evidenceCapabilities"]
        )

        self.assertTrue(comparison["requiresRuntimeSession"])
        self.assertEqual(comparison["requiredSurfaces"]["actual-runtime"], expected)

    def test_release_exact_build_requires_runtime_for_every_capable_surface(self):
        next_build = self.manifest(REPO_ROOT, version="1.0.54", build="2026073002")
        comparison = compare_manifests(self.baseline, next_build, "release")
        expected = sorted(
            surface_id
            for surface_id, surface in self.surfaces(next_build).items()
            if "actual-runtime" in surface["evidenceCapabilities"]
        )

        self.assertTrue(comparison["requiresRuntimeSession"])
        self.assertEqual(comparison["requiredSurfaces"]["actual-runtime"], expected)

    def test_expected_build_seal_requires_complete_exact_artifact_evidence(self):
        template = evidence_template(self.baseline)
        for artifact in template["artifacts"]:
            seed = artifact["artifactId"].encode()
            artifact.update(
                {
                    "codeSignatureValid": True,
                    "executableSha256": hashlib.sha256(seed + b"binary").hexdigest(),
                    "executableUUIDs": ["01234567-89AB-CDEF-0123-456789ABCDEF"],
                    "entitlementsSha256": hashlib.sha256(seed + b"entitlements").hexdigest(),
                    "profileSha256": hashlib.sha256(seed + b"profile").hexdigest(),
                }
            )
        sealed = seal_expected_build(self.baseline, template)
        self.assertEqual(sealed["kind"], "context-panel-expected-signed-build")
        self.assertEqual(len(sealed["artifacts"]), 11)
        self.assertEqual(len(sealed["surfaces"]), 13)
        self.assertEqual(len(sealed["expectedBuildId"]), 64)

        incomplete = json.loads(json.dumps(template))
        incomplete["artifacts"].pop()
        with self.assertRaisesRegex(SurfacePolicyError, "artifact evidence is incomplete"):
            seal_expected_build(self.baseline, incomplete)

        mismatched = json.loads(json.dumps(template))
        mismatched["artifacts"][0]["buildNumber"] = "wrong"
        with self.assertRaisesRegex(SurfacePolicyError, "artifact evidence identity mismatch"):
            seal_expected_build(self.baseline, mismatched)

    def test_archive_fixture_binds_embedded_manifests_and_signed_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            archive = Path(temporary_directory) / "ContextPanel.xcarchive"
            source = self.baseline["source"]
            surfaces = self.surfaces(self.baseline)
            artifact_surfaces = {
                surface["artifactId"]: surface
                for surface in surfaces.values()
                if surface["artifactId"] in self.baseline["archiveLayouts"]["macos"]
            }
            for artifact_id, relative_path in self.baseline["archiveLayouts"]["macos"].items():
                bundle = archive / relative_path
                executable_name = artifact_id.replace(".", "-")
                info = {
                    "CFBundleIdentifier": artifact_surfaces[artifact_id]["bundleIdentifier"],
                    "CFBundleShortVersionString": source["marketingVersion"],
                    "CFBundleVersion": source["buildNumber"],
                    "CFBundleExecutable": executable_name,
                }
                (bundle / "Contents/MacOS").mkdir(parents=True)
                (bundle / "Contents/Resources").mkdir(parents=True)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                (bundle / "Contents/MacOS" / executable_name).write_bytes(
                    artifact_id.encode("utf-8")
                )
                (bundle / "Contents/embedded.provisionprofile").write_bytes(
                    f"profile-{artifact_id}".encode("utf-8")
                )
                embedded_payload = embedded_manifest(self.baseline)
                self.assertEqual(embedded_payload["schemaVersion"], 1)
                (bundle / "Contents/Resources/ContextPanelSurfaceManifest.json").write_text(
                    json.dumps(embedded_payload)
                )

            entitlements = plistlib.dumps(
                {"com.apple.security.application-groups": ["example.group"]}
            )
            profile_overrides = {}
            for artifact_id in self.baseline["archiveLayouts"]["macos"]:
                profile = Path(temporary_directory) / f"{artifact_id}.provisionprofile"
                profile.write_bytes(f"external-profile-{artifact_id}".encode("utf-8"))
                profile_overrides[artifact_id] = profile

            def runner(arguments):
                if "--verify" in arguments:
                    return subprocess.CompletedProcess(arguments, 0, b"", b"")
                if "--entitlements" in arguments:
                    return subprocess.CompletedProcess(arguments, 0, entitlements, b"")
                if "dwarfdump" in arguments:
                    return subprocess.CompletedProcess(
                        arguments,
                        0,
                        b"UUID: 01234567-89AB-CDEF-0123-456789ABCDEF (arm64) binary\n",
                        b"",
                    )
                return subprocess.CompletedProcess(arguments, 1, b"", b"unexpected command")

            evidence = collect_archive_evidence(
                self.baseline,
                archive,
                "macos",
                profile_paths=profile_overrides,
                runner=runner,
            )
            sealed = seal_expected_build(self.baseline, evidence)
            self.assertEqual(sealed["archive"]["layout"], "macos")
            self.assertEqual(sealed["archive"]["name"], "ContextPanel.xcarchive")
            self.assertEqual(len(sealed["artifacts"]), 3)
            self.assertEqual(len(sealed["surfaces"]), 3)

            app_manifest = (
                archive
                / self.baseline["archiveLayouts"]["macos"]["macos.app"]
                / "Contents/Resources/ContextPanelSurfaceManifest.json"
            )
            embedded = json.loads(app_manifest.read_text())
            embedded["manifestId"] = "0" * 64
            app_manifest.write_text(json.dumps(embedded))
            with self.assertRaisesRegex(SurfacePolicyError, "surface manifest mismatch"):
                collect_archive_evidence(
                    self.baseline,
                    archive,
                    "macos",
                    profile_paths=profile_overrides,
                    runner=runner,
                )

    def test_stamp_writes_exact_manifest_and_legacy_macos_fingerprint(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            bundle = Path(temporary_directory) / "Context Panel.app"
            executable = bundle / "Contents/MacOS/Context Panel"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture")
            environment = {
                **os.environ,
                "MARKETING_VERSION": "1.0.53",
                "CURRENT_PROJECT_VERSION": "2026073001",
                "CONFIGURATION": "Release",
                "XCODE_PRODUCT_BUILD_VERSION": "17A000",
            }
            result = subprocess.run(
                [str(REPO_ROOT / "scripts/stamp-context-panel-build.sh"), str(bundle)],
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            manifest = json.loads(
                (bundle / "Contents/Resources/ContextPanelSurfaceManifest.json").read_text()
            )
            self.assertNotIn("source", manifest)
            self.assertNotIn("files", manifest)
            self.assertNotIn("ignoredInputs", manifest)
            self.assertNotIn("Sources/", json.dumps(manifest, sort_keys=True))
            macos_app = self.surfaces(manifest)["macos.app"]
            legacy = (
                bundle / "Contents/Resources/ContextPanelBuildFingerprint.txt"
            ).read_text().strip()
            self.assertEqual(legacy, macos_app["fingerprints"]["combined"])

    def test_stamp_marks_unknown_without_blocking_an_ordinary_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            source = root / "Sources/UnmappedShippingCode/NewSurface.swift"
            source.parent.mkdir()
            source.write_text("struct NewSurface {}\n")
            bundle = root / "Fixture.app"
            bundle.mkdir()
            environment = {
                **os.environ,
                "MARKETING_VERSION": "1.0.53",
                "CURRENT_PROJECT_VERSION": "2026073001",
                "CONFIGURATION": "Debug",
                "XCODE_PRODUCT_BUILD_VERSION": "17A000",
            }
            result = subprocess.run(
                [str(root / "scripts/stamp-context-panel-build.sh"), str(bundle)],
                cwd=root,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            embedded = json.loads((bundle / "ContextPanelSurfaceManifest.json").read_text())
            self.assertEqual(embedded["state"], "unknown")
            self.assertEqual(embedded["reason"], "surface-policy-validation-failed")


if __name__ == "__main__":
    unittest.main()
