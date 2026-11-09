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
from typing import Any
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

core_module = importlib.import_module("context_panel_surface_manifest.core")
artifact_module = importlib.import_module("context_panel_surface_manifest.artifact")
SurfacePolicyError = core_module.SurfacePolicyError
collect_archive_evidence = artifact_module.collect_archive_evidence
canonical_entitlements = artifact_module.canonical_entitlements
entitlement_contract_hash = artifact_module.entitlement_contract_hash
embedded_manifest = core_module.embedded_manifest
generate_manifest = core_module.generate_manifest
profile_capability_hash = artifact_module.profile_capability_hash
resolve_policy = core_module.resolve_policy
seal_expected_build = core_module.seal_expected_build
signing_class = artifact_module.signing_class
validation_summary = core_module.validation_summary
from Tests.ScriptsTests.test_ci_change_scope import imported_scripts  # noqa: E402
manifest_surface_map = core_module.manifest_surface_map


def evidence_template(
    manifest: dict[str, Any], layout_name: str | None = None
) -> dict[str, Any]:
    source = manifest.get("source")
    if not isinstance(source, dict):
        raise SurfacePolicyError("source manifest identity is missing")
    surfaces = manifest_surface_map(manifest, "source")
    layout_artifacts: set[str] | None = None
    if layout_name is not None:
        archive_layouts = manifest.get("archiveLayouts")
        layout = archive_layouts.get(layout_name) if isinstance(archive_layouts, dict) else None
        if not isinstance(layout, dict) or not layout:
            raise SurfacePolicyError(f"unknown archive layout: {layout_name}")
        layout_artifacts = {str(artifact_id) for artifact_id in layout}
    artifacts: dict[str, dict[str, Any]] = {}
    for surface in surfaces.values():
        artifact_id = str(surface.get("artifactId") or "")
        if layout_artifacts is not None and artifact_id not in layout_artifacts:
            continue
        artifact: dict[str, Any] = {
            "artifactId": artifact_id,
            "bundleIdentifier": surface.get("bundleIdentifier"),
            "marketingVersion": source.get("marketingVersion"),
            "buildNumber": source.get("buildNumber"),
            "sourceCommit": source.get("commit"),
            "configuration": source.get("configuration"),
            "xcodeBuild": source.get("xcodeBuild"),
            "treeState": source.get("treeState"),
            "codeSignatureValid": None,
            "executableSha256": None,
            "executableUUIDs": [],
            "entitlementsSha256": None,
            "profileSha256": None,
            "bundleContractSha256": None,
            "signingClass": None,
            "signingContractSha256": None,
            "entitlementContractSha256": None,
            "profileCapabilitySha256": None,
            "architectures": [],
        }
        previous = artifacts.get(artifact_id)
        if previous is not None and previous != artifact:
            raise SurfacePolicyError(f"source manifest artifact contract drifted: {artifact_id}")
        artifacts[artifact_id] = artifact
    return {
        "schemaVersion": 2,
        "sourceManifestId": manifest.get("manifestId"),
        "layout": layout_name,
        "artifacts": [artifacts[artifact_id] for artifact_id in sorted(artifacts)],
    }




def v2_artifact_contract(seed: bytes, architectures: list[str] | None = None) -> dict[str, object]:
    return {
        "codeSignatureValid": True,
        "executableSha256": hashlib.sha256(seed + b"binary").hexdigest(),
        "executableUUIDs": ["01234567-89AB-CDEF-0123-456789ABCDEF"],
        "entitlementsSha256": hashlib.sha256(seed + b"entitlements").hexdigest(),
        "profileSha256": hashlib.sha256(seed + b"profile").hexdigest(),
        "bundleContractSha256": hashlib.sha256(seed + b"bundle-contract").hexdigest(),
        "signingClass": "Apple Distribution",
        "signingContractSha256": hashlib.sha256(seed + b"signing-contract").hexdigest(),
        "entitlementContractSha256": hashlib.sha256(seed + b"entitlement-contract").hexdigest(),
        "profileCapabilitySha256": hashlib.sha256(seed + b"profile-capability").hexdigest(),
        "architectures": architectures or ["arm64"],
    }


class SurfaceManifestTests(unittest.TestCase):
    baseline_fixture: dict[str, Any]
    project_payloads: dict[tuple[str, bytes, bytes], dict[str, Any]]

    @classmethod
    def setUpClass(cls) -> None:
        # Generate the unchanged input once; each test owns its mutable copy.
        cls.baseline_fixture = cls().manifest(REPO_ROOT)
        cls.project_payloads = {}

    def setUp(self):
        self.baseline = copy.deepcopy(self.baseline_fixture)
        reader = core_module.load_project_payload

        def read_project(root: Path, policy: dict[str, Any]) -> dict[str, Any]:
            configuration = policy.get("project")
            if not isinstance(configuration, dict) or not all(
                isinstance(configuration.get(field), str) and configuration[field]
                for field in ("path", "reader")
            ):
                return reader(root, policy)
            project = root / configuration["path"]
            script = root / configuration["reader"]
            # Run the real parser for every distinct input, including mutations.
            # Its JSON contains the basename and bytes digest, never the root.
            if not project.is_file() or not script.is_file():
                return reader(root, policy)
            key = (project.name, project.read_bytes(), script.read_bytes())
            if key not in self.project_payloads:
                self.project_payloads[key] = reader(root, policy)
            return copy.deepcopy(self.project_payloads[key])

        patcher = mock.patch.object(core_module, "load_project_payload", new=read_project)
        patcher.start()
        self.addCleanup(patcher.stop)

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
            "context_panel_expected_build.py",
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
        targets = resolved.project_payload["project"]["targets"]
        shipping_targets = {
            name
            for name, target in targets.items()
            if target["type"] in {"application", "app-extension"}
        }
        policy_surfaces = json.loads(resolved.policy_path.read_text())["surfaces"]

        self.assertEqual({surface["projectTarget"] for surface in policy_surfaces}, shipping_targets)
        self.assertEqual(summary["surfaceIds"], sorted(surface["id"] for surface in policy_surfaces))
        self.assertEqual(summary["surfaceCount"], len(policy_surfaces))
        self.assertEqual(
            set(resolved.governed_files),
            set(resolved.file_hashes) | set(resolved.ignored_files),
        )

    def test_policy_governs_every_script_the_manifest_imports(self):
        # A script the manifest imports changes what every fingerprint means, so
        # it must move the contract fingerprint too.
        policy_json = json.loads((REPO_ROOT / "Config/ContextPanelSurfacePolicy.json").read_text())
        pattern_lists = {
            "governedPatterns": policy_json["inventory"]["governedPatterns"],
            "surface-tooling": policy_json["inputGroups"]["surface-tooling"]["include"],
        }
        entry_point = "scripts/context-panel-surface-manifest.py"
        for name, patterns in pattern_lists.items():
            governed = set(core_module.expand_patterns(REPO_ROOT, patterns))
            for path in [entry_point, *imported_scripts(entry_point)]:
                with self.subTest(policy_list=name, path=path):
                    self.assertIn(path, governed)

    def test_ignored_inputs_are_never_compiled_into_a_project_target(self):
        resolved = resolve_policy(REPO_ROOT)
        compiled_roots = {
            source["path"] if isinstance(source, dict) else source
            for target in resolved.project_payload["project"]["targets"].values()
            for source in target.get("sources", [])
        }

        self.assertTrue(resolved.ignored_files)
        for ignored in resolved.ignored_files:
            for compiled_root in compiled_roots:
                self.assertFalse(
                    ignored == compiled_root or ignored.startswith(compiled_root.rstrip("/") + "/"),
                    f"{ignored} is ignored by the surface policy but compiled from {compiled_root}",
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
        self.assertEqual(
            surfaces["ios.app"]["artifactId"], surfaces["ipados.app"]["artifactId"]
        )
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
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            for directory, expected_surfaces in mutations.items():
                synthetic = root / directory / "SyntheticFingerprintInput.swift"
                with self.subTest(directory=directory):
                    synthetic.write_text("struct SyntheticFingerprintInput {}\n")
                    mutated_surfaces = self.surfaces(self.manifest(root))
                    synthetic.unlink()
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

    def test_expected_build_seal_requires_complete_exact_artifact_evidence(self):
        template = evidence_template(self.baseline)
        for artifact in template["artifacts"]:
            seed = artifact["artifactId"].encode()
            artifact.update(v2_artifact_contract(seed))
        sealed = seal_expected_build(self.baseline, template)
        self.assertEqual(sealed["schemaVersion"], 2)
        self.assertEqual(sealed["kind"], "context-panel-expected-signed-build")
        self.assertEqual(
            {artifact["artifactId"] for artifact in sealed["artifacts"]},
            {surface["artifactId"] for surface in self.baseline["surfaces"]},
        )
        self.assertEqual(
            [surface["id"] for surface in sealed["surfaces"]],
            [surface["id"] for surface in self.baseline["surfaces"]],
        )
        self.assertEqual(len(sealed["expectedBuildId"]), 64)
        self.assertIn("bundleContractSha256", sealed["artifacts"][0])
        self.assertIn("architectures", sealed["artifacts"][0])

        incomplete = json.loads(json.dumps(template))
        incomplete["artifacts"].pop()
        with self.assertRaisesRegex(SurfacePolicyError, "artifact evidence is incomplete"):
            seal_expected_build(self.baseline, incomplete)

        mismatched = json.loads(json.dumps(template))
        mismatched["artifacts"][0]["buildNumber"] = "wrong"
        with self.assertRaisesRegex(SurfacePolicyError, "artifact evidence identity mismatch"):
            seal_expected_build(self.baseline, mismatched)

        missing_v2 = json.loads(json.dumps(template))
        missing_v2["artifacts"][0].pop("profileCapabilitySha256")
        with self.assertRaisesRegex(SurfacePolicyError, "artifact evidence hash is invalid"):
            seal_expected_build(self.baseline, missing_v2)

        invalid_signing_class = json.loads(json.dumps(template))
        invalid_signing_class["artifacts"][0]["signingClass"] = "Other"
        with self.assertRaisesRegex(SurfacePolicyError, "signing class is invalid"):
            seal_expected_build(self.baseline, invalid_signing_class)

        ad_hoc_signing_class = json.loads(json.dumps(template))
        ad_hoc_signing_class["artifacts"][0]["signingClass"] = "ad-hoc"
        with self.assertRaisesRegex(SurfacePolicyError, "signing class is invalid"):
            seal_expected_build(self.baseline, ad_hoc_signing_class)

        invalid_architecture = json.loads(json.dumps(template))
        invalid_architecture["artifacts"][0]["architectures"] = ["../../arm64"]
        with self.assertRaisesRegex(SurfacePolicyError, "architectures are missing"):
            seal_expected_build(self.baseline, invalid_architecture)

    def test_semantic_entitlement_key_and_list_order_is_canonical(self):
        first = plistlib.dumps(
            {
                "com.apple.developer.icloud-container-identifiers": ["iCloud.beta", "iCloud.alpha"],
                "com.apple.security.application-groups": ["group.two", "group.one", "group.one"],
            }
        )
        second = plistlib.dumps(
            {
                "com.apple.security.application-groups": ["group.one", "group.two"],
                "com.apple.developer.icloud-container-identifiers": ["iCloud.alpha", "iCloud.beta"],
            }
        )
        self.assertEqual(canonical_entitlements(first), canonical_entitlements(second))
        self.assertEqual(
            entitlement_contract_hash(canonical_entitlements(first)),
            entitlement_contract_hash(canonical_entitlements(second)),
        )

    def test_keychain_access_group_order_remains_semantic(self):
        first = canonical_entitlements(
            plistlib.dumps(
                {"keychain-access-groups": ["TEAM.primary", "TEAM.secondary"]}
            )
        )
        second = canonical_entitlements(
            plistlib.dumps(
                {"keychain-access-groups": ["TEAM.secondary", "TEAM.primary"]}
            )
        )
        self.assertNotEqual(
            entitlement_contract_hash(first),
            entitlement_contract_hash(second),
        )

    def test_profile_renewal_metadata_and_certificates_do_not_change_capability_hash(self):
        base = {
            "UUID": "11111111-1111-1111-1111-111111111111",
            "Name": "Old profile",
            "CreationDate": "2026-01-01T00:00:00Z",
            "ExpirationDate": "2026-02-01T00:00:00Z",
            "DeveloperCertificates": [b"old certificate"],
            "ProvisionedDevices": ["device-a"],
            "TeamIdentifier": ["TEAMID1234"],
            "ApplicationIdentifierPrefix": ["TEAMID1234"],
            "Platform": ["OSX"],
            "ProvisionsAllDevices": True,
            "Entitlements": {
                "com.apple.security.application-groups": ["group.two", "group.one"],
                "com.apple.developer.icloud-container-identifiers": ["iCloud.context"],
            },
        }
        renewed = {
            **base,
            "UUID": "22222222-2222-2222-2222-222222222222",
            "Name": "Renewed profile",
            "CreationDate": "2026-03-01T00:00:00Z",
            "ExpirationDate": "2027-03-01T00:00:00Z",
            "DeveloperCertificates": [b"new certificate"],
            "ProvisionedDevices": ["device-b"],
        }
        self.assertEqual(profile_capability_hash(base), profile_capability_hash(renewed))

    def test_semantic_contract_drift_changes_expected_hashes(self):
        entitlements_a = canonical_entitlements(
            plistlib.dumps({"com.apple.security.application-groups": ["group.one"]})
        )
        entitlements_b = canonical_entitlements(
            plistlib.dumps({"com.apple.security.application-groups": ["group.two"]})
        )
        self.assertNotEqual(
            entitlement_contract_hash(entitlements_a),
            entitlement_contract_hash(entitlements_b),
        )
        profile_a = {
            "TeamIdentifier": ["TEAMID1234"],
            "ApplicationIdentifierPrefix": ["TEAMID1234"],
            "Platform": ["OSX"],
            "Entitlements": {
                "com.apple.developer.icloud-container-identifiers": ["iCloud.one"]
            },
        }
        profile_b = {
            **profile_a,
            "Entitlements": {
                "com.apple.developer.icloud-container-identifiers": ["iCloud.two"]
            },
        }
        self.assertNotEqual(profile_capability_hash(profile_a), profile_capability_hash(profile_b))

    def test_signing_class_normalization_uses_public_class_only(self):
        self.assertEqual(signing_class(["Apple Distribution: Example Corp (TEAMID1234)"]), "Apple Distribution")
        self.assertEqual(signing_class(["Developer ID Application: Example Corp (TEAMID1234)"]), "Developer ID Application")
        self.assertEqual(
            signing_class(["TestFlight Beta Distribution"]),
            "TestFlight Beta Distribution",
        )
        self.assertEqual(signing_class([], "adhoc"), "ad-hoc")
        with self.assertRaisesRegex(SurfacePolicyError, "authority is unavailable"):
            signing_class([])
        with self.assertRaisesRegex(SurfacePolicyError, "class is unsupported"):
            signing_class(["Unknown Signing Authority"])

    def test_empty_or_invalid_entitlements_fail_closed(self):
        for payload in (b"", plistlib.dumps({}), b"not-a-plist"):
            with self.subTest(payload=payload[:12]):
                with self.assertRaisesRegex(SurfacePolicyError, "entitlements"):
                    canonical_entitlements(payload)

    def test_undecodable_or_empty_profile_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            profile = Path(temporary_directory) / "embedded.provisionprofile"
            profile.write_bytes(b"profile")

            def undecodable_runner(arguments):
                return subprocess.CompletedProcess(arguments, 1, b"", b"bad profile")

            with self.assertRaisesRegex(SurfacePolicyError, "provisioning profile is undecodable"):
                artifact_module.profile_payload(profile, undecodable_runner)

            with self.assertRaisesRegex(SurfacePolicyError, "profile entitlements are invalid"):
                profile_capability_hash({"TeamIdentifier": ["TEAMID1234"]})

    def test_architecture_slice_loss_changes_expected_build_id(self):
        template = evidence_template(self.baseline, "macos")
        for artifact in template["artifacts"]:
            artifact.update(v2_artifact_contract(artifact["artifactId"].encode(), ["arm64", "x86_64"]))
        universal = seal_expected_build(self.baseline, template)
        thin_template = json.loads(json.dumps(template))
        thin_template["artifacts"][0]["architectures"] = ["arm64"]
        thin = seal_expected_build(self.baseline, thin_template)
        self.assertNotEqual(universal["artifacts"][0]["architectures"], thin["artifacts"][0]["architectures"])
        self.assertNotEqual(universal["expectedBuildId"], thin["expectedBuildId"])

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
            profile_payload = plistlib.dumps(
                {
                    "TeamIdentifier": ["TEAMID1234"],
                    "ApplicationIdentifierPrefix": ["TEAMID1234"],
                    "Platform": ["OSX"],
                    "ProvisionsAllDevices": True,
                    "Entitlements": {
                        "com.apple.security.application-groups": ["example.group"]
                    },
                }
            )
            profile_overrides = {}
            commands: list[list[str]] = []
            for artifact_id in self.baseline["archiveLayouts"]["macos"]:
                profile = Path(temporary_directory) / f"{artifact_id}.provisionprofile"
                profile.write_bytes(f"external-profile-{artifact_id}".encode("utf-8"))
                profile_overrides[artifact_id] = profile

            def runner(arguments):
                commands.append(list(arguments))
                if "--verify" in arguments:
                    return subprocess.CompletedProcess(arguments, 0, b"", b"")
                if "--verbose=4" in arguments:
                    bundle_path = Path(arguments[-1])
                    info = plistlib.loads((bundle_path / "Contents/Info.plist").read_bytes())
                    return subprocess.CompletedProcess(
                        arguments,
                        0,
                        b"",
                        (
                            f"Identifier={info['CFBundleIdentifier']}\n"
                            "TeamIdentifier=TEAMID1234\n"
                            "Authority=Apple Distribution: Example Corp (TEAMID1234)\n"
                        ).encode(),
                    )
                if "--entitlements" in arguments:
                    return subprocess.CompletedProcess(arguments, 0, entitlements, b"")
                if arguments[:4] == ["/usr/bin/security", "cms", "-D", "-i"]:
                    return subprocess.CompletedProcess(arguments, 0, profile_payload, b"")
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
            self.assertEqual(sealed["artifacts"][0]["architectures"], ["arm64"])
            self.assertEqual(sealed["artifacts"][0]["signingClass"], "Apple Distribution")
            self.assertTrue(
                any(
                    command[1:5] == ["-d", "--entitlements", "-", "--xml"]
                    for command in commands
                    if command and command[0] == "/usr/bin/codesign"
                )
            )

            mismatched_profile_payload = plistlib.dumps(
                {
                    "TeamIdentifier": ["OTHERTEAM1"],
                    "ApplicationIdentifierPrefix": ["OTHERTEAM1"],
                    "Platform": ["OSX"],
                    "ProvisionsAllDevices": True,
                    "Entitlements": {
                        "com.apple.security.application-groups": ["example.group"]
                    },
                }
            )

            def mismatched_profile_runner(arguments):
                if arguments[:4] == ["/usr/bin/security", "cms", "-D", "-i"]:
                    return subprocess.CompletedProcess(
                        arguments,
                        0,
                        mismatched_profile_payload,
                        b"",
                    )
                return runner(arguments)

            with self.assertRaisesRegex(
                SurfacePolicyError,
                "signing team does not match",
            ):
                collect_archive_evidence(
                    self.baseline,
                    archive,
                    "macos",
                    profile_paths=profile_overrides,
                    runner=mismatched_profile_runner,
                )

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
