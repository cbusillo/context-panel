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


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

cli_module = importlib.import_module("context_panel_surface_manifest.cli")
core_module = importlib.import_module("context_panel_surface_manifest.core")
artifact_module = importlib.import_module("context_panel_surface_manifest.artifact")

evidence_template = cli_module.evidence_template
SurfacePolicyError = core_module.SurfacePolicyError
compare_manifests = core_module.compare_manifests
collect_archive_evidence = artifact_module.collect_archive_evidence
embedded_manifest = core_module.embedded_manifest
generate_manifest = core_module.generate_manifest
resolve_policy = core_module.resolve_policy
seal_expected_build = core_module.seal_expected_build
validation_summary = core_module.validation_summary


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
        for surface_id in ("macos.widget", "ios.app", "visionos.widget"):
            self.assertNotEqual(
                baseline[surface_id]["fingerprints"]["render"],
                mutated[surface_id]["fingerprints"]["render"],
            )
            self.assertEqual(
                baseline[surface_id]["fingerprints"]["runtime"],
                mutated[surface_id]["fingerprints"]["runtime"],
            )
        self.assertEqual(
            baseline["macos.app"]["fingerprints"]["render"],
            mutated["macos.app"]["fingerprints"]["render"],
        )
        self.assertNotEqual(
            baseline["macos.app"]["fingerprints"]["combined"],
            mutated["macos.app"]["fingerprints"]["combined"],
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

    def test_manifest_surface_capabilities_fail_closed(self):
        malformed = json.loads(json.dumps(self.baseline))
        malformed["surfaces"][0].pop("evidenceCapabilities")
        with self.assertRaisesRegex(SurfacePolicyError, "evidence capabilities are invalid"):
            compare_manifests(self.baseline, malformed, "release")

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
            ["shared-view", "actual-runtime", "os-composited-placement"],
        )
        self.assertFalse(render_surface["carryForward"]["shared-view"]["eligible"])
        self.assertFalse(render_surface["carryForward"]["actual-runtime"]["eligible"])
        self.assertFalse(
            render_surface["carryForward"]["os-composited-placement"]["eligible"]
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
                (bundle / "Contents/Resources/ContextPanelSurfaceManifest.json").write_text(
                    json.dumps(embedded_manifest(self.baseline))
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
