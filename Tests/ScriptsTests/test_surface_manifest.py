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
from typing import Any
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

cli_module = importlib.import_module("context_panel_surface_manifest.cli")
core_module = importlib.import_module("context_panel_surface_manifest.core")
artifact_module = importlib.import_module("context_panel_surface_manifest.artifact")
comparison_schema_module = importlib.import_module("context_panel_comparison_schema")
release_gate_module = importlib.import_module("context_panel_release_gate.core")

evidence_template = cli_module.evidence_template
SurfacePolicyError = core_module.SurfacePolicyError
compare_manifests = core_module.compare_manifests
collect_archive_evidence = artifact_module.collect_archive_evidence
canonical_entitlements = artifact_module.canonical_entitlements
canonical_json_hash = artifact_module.canonical_json_hash
entitlement_contract_hash = artifact_module.entitlement_contract_hash
embedded_manifest = core_module.embedded_manifest
generate_manifest = core_module.generate_manifest
profile_capability_hash = artifact_module.profile_capability_hash
resolve_policy = core_module.resolve_policy
seal_expected_build = core_module.seal_expected_build
signing_class = artifact_module.signing_class
validation_summary = core_module.validation_summary
ComparisonSchemaError = comparison_schema_module.ComparisonSchemaError
derive_risk_fields = comparison_schema_module.derive_risk_fields
validate_current_comparison = comparison_schema_module.validate_current_comparison
ReleaseEvidenceError = release_gate_module.ReleaseEvidenceError
validate_release_comparison = release_gate_module._validate_comparison
validate_artifact_comparison_inputs = (
    release_gate_module._validate_artifact_comparison_inputs
)


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
    def expected_build(manifest, mutate=None, layout=None):
        template = evidence_template(manifest, layout)
        for artifact in template["artifacts"]:
            artifact.update(v2_artifact_contract(artifact["artifactId"].encode()))
        if mutate is not None:
            mutate(template)
        return seal_expected_build(manifest, template)

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

    def platform_release(self, current=None, *, all_submitted=False):
        previous = copy.deepcopy(self.baseline)
        current = copy.deepcopy(current or previous)
        current["source"]["buildNumber"] = "202608080418"
        current["manifestId"] = core_module.hash_parts(
            f"{current['digestDomain']}/manifest",
            [
                core_module.canonical_json(
                    {k: v for k, v in current.items() if k != "manifestId"}
                )
            ],
        )
        previous_builds = [
            self.expected_build(previous, layout=layout)
            for layout in previous["archiveLayouts"]
        ]
        record = {"schemaVersion": 1, "platforms": {}}
        for layout in current["archiveLayouts"]:
            submitted = all_submitted or layout == "macos"
            source = current if submitted else previous
            entry = {
                "state": "submitted" if submitted else "carried",
                "expectedBuildManifest": self.expected_build(source, layout=layout),
            }
            if not submitted:
                entry.update(sourceManifest=source, shippedLineage={})
            record["platforms"][layout] = entry
        return previous, current, previous_builds, record

    @staticmethod
    def signed_report(source, builds):
        from Tests.ScriptsTests.test_release_evidence_gate import report
        from context_panel_validation.runtime_evidence import (
            expected_surface_identities_from_payloads,
        )
        from context_panel_validation import RUNTIME_SURFACES, Target

        target = Target(
            source["source"]["marketingVersion"], source["source"]["buildNumber"]
        )
        identities = expected_surface_identities_from_payloads(
            builds, target, tuple(RUNTIME_SURFACES)
        )
        result = report(
            "macos.app",
            runtime=True,
            visual_class="shared-view",
            manifest_id=source["manifestId"],
        )
        result["target"] = {
            "version": target.version,
            "buildNumber": target.build_number,
        }
        result["session"]["requestedSurfaces"] = list(RUNTIME_SURFACES)
        result["runtimeSurfaces"], result["visualApprovals"]["requirements"] = [], []
        for item in identities:
            piece = report(
                item.surface,
                runtime=True,
                visual_class="shared-view",
                manifest_id=item.manifest_id,
            )
            runtime = piece["runtimeSurfaces"][0]
            runtime.update(
                expectedBuildID=item.expected_build_id,
                identityDigest=item.identity_digest(),
                runtimeFingerprint=item.runtime_fingerprint,
            )
            result["runtimeSurfaces"].append(runtime)
            if item.surface != "macos.refresh-agent":
                visual = piece["visualApprovals"]["requirements"][0]
                visual.update(
                    expectedBuildID=item.expected_build_id,
                    identityDigest=item.identity_digest(),
                    contractFingerprint=item.contract_fingerprint,
                    renderFingerprint=item.render_fingerprint,
                )
                result["visualApprovals"]["requirements"].append(visual)
            capabilities = next(
                surface["evidenceCapabilities"]
                for surface in source["surfaces"]
                if surface["id"] == item.surface
            )
            if "os-composited-placement" in capabilities:
                placement = report(
                    item.surface,
                    runtime=True,
                    visual_class="os-composited-placement",
                    host_os=f"{item.platform} 27.0",
                    manifest_id=item.manifest_id,
                )["visualApprovals"]["requirements"][0]
                placement["id"] = f"{item.surface}.placement-review"
                placement.update(
                    expectedBuildID=item.expected_build_id,
                    identityDigest=item.identity_digest(),
                    contractFingerprint=item.contract_fingerprint,
                    renderFingerprint=item.render_fingerprint,
                    placementFingerprint=item.placement_fingerprint,
                )
                result["visualApprovals"]["requirements"].append(placement)
        return result, identities

    def approved_shipped_lineage(self, source, builds):
        from Tests.ScriptsTests.test_release_evidence_gate import NOW, policy
        from context_panel_release_gate import (
            evaluate_release_evidence,
            build_release_evidence_lineage,
        )

        configured = json.loads(
            (REPO_ROOT / "Config/ContextPanelSurfacePolicy.json").read_text()
        )
        report, identities = self.signed_report(source, builds)
        runs = []
        for train in ("beta", "rc"):
            comparison = compare_manifests(source, source, train, [], builds)
            ledger = evaluate_release_evidence(
                train=train,
                mode="shadow",
                comparison=comparison,
                validation_report=report,
                identities=identities,
                expected_build_manifests=tuple(builds),
                policy=policy(),
                surface_policy=configured,
                now=NOW,
            )
            self.assertEqual(ledger["blockers"], [])
            lineage = build_release_evidence_lineage(
                ledger,
                comparison=comparison,
                validation_report=report,
                expected_build_manifests=tuple(builds),
            )
            runs.append(
                {
                    "train": train,
                    "target": ledger["target"],
                    "manifestID": source["manifestId"],
                    "expectedBuildIdentityDigest": ledger[
                        "expectedBuildIdentityDigest"
                    ],
                    "ledgerID": ledger["ledgerID"],
                    "observedAt": ledger["generatedAt"],
                    "runbookState": "approved",
                    "ledgerState": "approved",
                    "disagreements": [],
                    "ledger": ledger,
                    "generation": lineage["generation"],
                }
            )
        shadow = {
            "schemaVersion": 1,
            "kind": "context-panel-shadow-comparison",
            "runs": runs,
        }
        comparison = compare_manifests(source, source, "rc", [], builds)
        ledger = evaluate_release_evidence(
            train="rc",
            mode="enforce",
            comparison=comparison,
            validation_report=report,
            identities=identities,
            expected_build_manifests=tuple(builds),
            policy=policy(),
            surface_policy=configured,
            shadow_evidence=shadow,
            now=NOW,
        )
        self.assertEqual(ledger["state"], "approved")
        return build_release_evidence_lineage(
            ledger,
            comparison=comparison,
            validation_report=report,
            expected_build_manifests=tuple(builds),
            shadow_evidence=shadow,
        ), shadow

    def test_platform_release_evaluator_lineage_and_report_reconstruct_real_builds(
        self,
    ):
        from Tests.ScriptsTests.test_release_evidence_gate import NOW, policy
        from context_panel_validation import Target
        from context_panel_release_gate import (
            evaluate_release_evidence,
            build_release_evidence_lineage,
            release_evidence_report_blockers,
        )
        from context_panel_release_gate.core import (
            release_comparison_identities,
            _verified_lineage_ledger,
            HistoricalPolicyArchive,
        )
        from context_panel_replay.comparison_adapters import adapt_comparison_for_replay

        previous, current, builds, record = self.platform_release()
        lineage, shadow = self.approved_shipped_lineage(previous, builds)
        for entry in record["platforms"].values():
            if entry["state"] == "carried":
                entry["shippedLineage"] = lineage
        expected = tuple(
            entry["expectedBuildManifest"] for entry in record["platforms"].values()
        )
        report, _ = self.signed_report(
            current, [record["platforms"]["macos"]["expectedBuildManifest"]]
        )
        report["session"]["requestedSurfaces"] = [
            s["surface"] for s in report["runtimeSurfaces"]
        ]
        configured = json.loads(
            (REPO_ROOT / "Config/ContextPanelSurfacePolicy.json").read_text()
        )
        comparison = compare_manifests(
            previous, current, "rc", builds, release_record=record
        )
        identities = release_comparison_identities(
            expected,
            Target(report["target"]["version"], report["target"]["buildNumber"]),
            comparison,
        )
        arguments = dict(
            train="rc",
            mode="enforce",
            comparison=comparison,
            validation_report=report,
            identities=identities,
            expected_build_manifests=expected,
            policy=policy(),
            surface_policy=configured,
            shadow_evidence=shadow,
            previous_ledger=lineage,
            now=NOW,
        )
        ledger = evaluate_release_evidence(**arguments)
        self.assertEqual(ledger["blockers"], [])
        self.assertEqual(ledger["state"], "approved")
        self.assertLessEqual(ledger["expiresAt"], lineage["ledger"]["expiresAt"])
        for surface in ledger["surfaces"]:
            if not surface["surface"].startswith("macos."):
                self.assertTrue(
                    all(
                        e["source"] == "carry-forward"
                        for e in surface["evidence"].values()
                    )
                )
        blockers = release_evidence_report_blockers(
            ledger,
            version=report["target"]["version"],
            build_number=report["target"]["buildNumber"],
            train="rc",
            enforce=True,
            **{k: v for k, v in arguments.items() if k not in {"train", "mode"}},
        )
        self.assertEqual(blockers, [])
        mixed_lineage = build_release_evidence_lineage(
            ledger,
            comparison=comparison,
            validation_report=report,
            expected_build_manifests=expected,
            shadow_evidence=shadow,
            previous_ledger=lineage,
        )
        restored = json.loads(json.dumps(mixed_lineage))
        self.assertEqual(
            _verified_lineage_ledger(
                restored,
                label="mixed release",
                policy=policy(),
                surface_policy=configured,
                historical_policy_archive=HistoricalPolicyArchive(),
                lineage_depth=0,
                lineage_seen=frozenset(),
            ),
            ledger,
        )
        self.assertEqual(adapt_comparison_for_replay(comparison), comparison)
        # Seal and reconstruct a real mixed train through the inventory consumer.
        from Tests.ScriptsTests.test_replay_inventory import ReplayInventoryTests
        from context_panel_replay.inventory import (
            seal_inventory,
            render_json,
            verify_inventory,
        )
        from context_panel_replay.replay import reconstruct_bundle

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inventory_policy, roots = ReplayInventoryTests().fixture(root)
            train_root = roots["archive"] / "train"
            for name, payload in {
                "current": current,
                "comparison": comparison,
                "report": report,
                "ledger": ledger,
                "lineage": mixed_lineage,
                "visual": report["visualApprovals"],
            }.items():
                (train_root / f"{name}.json").write_text(json.dumps(payload))
            (roots["archive"] / "previous.json").write_text(json.dumps(previous))
            for platform, entry in record["platforms"].items():
                (
                    train_root / "expected" / f"ExpectedBuildManifest-{platform}.json"
                ).write_text(json.dumps(entry["expectedBuildManifest"]))
            inventory_config = json.loads(inventory_policy.read_text())
            train = inventory_config["trains"][0]
            train.update(
                trainId=f"{report['target']['version']}-{report['target']['buildNumber']}",
                version=report["target"]["version"],
                buildNumber=report["target"]["buildNumber"],
            )
            train["sealedMetadataDigest"] = (
                release_gate_module.canonical_payload_digest(
                    {
                        "previousManifestId": previous["manifestId"],
                        "currentManifestId": current["manifestId"],
                        "contractFingerprint": current["contractFingerprint"],
                        "scope": {
                            k: sorted(v)
                            for k, v in comparison["requiredSurfaces"].items()
                        },
                    }
                )
            )
            inventory_policy.write_text(json.dumps(inventory_config))
            inventory = seal_inventory(inventory_policy, roots)
            inventory_path = root / "inventory.json"
            inventory_path.write_bytes(render_json(inventory))
            self.assertEqual(
                verify_inventory(inventory_policy, inventory_path, roots), inventory
            )
            release_policy_path = root / "release-policy.json"
            release_policy_path.write_text(json.dumps(policy()))
            bundle = reconstruct_bundle(
                inventory_policy_path=inventory_policy,
                inventory_path=inventory_path,
                release_policy_path=release_policy_path,
                surface_policy_path=REPO_ROOT / "Config/ContextPanelSurfacePolicy.json",
                root_bindings=roots,
            )
            self.assertEqual(
                len(bundle["trains"][0]["runtimeSurfaces"]), len(comparison["surfaces"])
            )
        damaged_lineage = copy.deepcopy(restored)
        damaged_lineage["generation"]["comparison"]["releaseSafety"]["state"] = (
            "tampered"
        )
        with self.assertRaises(ReleaseEvidenceError):
            _verified_lineage_ledger(
                damaged_lineage,
                label="damaged mixed release",
                policy=policy(),
                surface_policy=configured,
                historical_policy_archive=HistoricalPolicyArchive(),
                lineage_depth=0,
                lineage_seen=frozenset(),
            )
        release_comparison = compare_manifests(
            previous, current, "release", builds, release_record=record
        )
        release = evaluate_release_evidence(
            **{
                **arguments,
                "train": "release",
                "comparison": release_comparison,
                "selected_rc_ledger": mixed_lineage,
            }
        )
        self.assertEqual(release["state"], "approved")
        # Next release: submit the formerly carried iOS build, then all platforms.
        # Each prior artifact keeps its own source instead of borrowing the last
        # globally coordinated release's source identity.
        next_source = copy.deepcopy(current)
        next_source["source"]["buildNumber"] = "202608080419"
        next_source["manifestId"] = core_module.hash_parts(
            f"{next_source['digestDomain']}/manifest",
            [
                core_module.canonical_json(
                    {k: v for k, v in next_source.items() if k != "manifestId"}
                )
            ],
        )
        for all_submitted in (False, True):
            next_record = {
                "schemaVersion": 1,
                "platforms": {},
                "previousSourceManifests": {},
            }
            for platform, prior_entry in record["platforms"].items():
                prior_source = (
                    prior_entry["sourceManifest"]
                    if prior_entry["state"] == "carried"
                    else current
                )
                next_record["previousSourceManifests"][platform] = prior_source
                if all_submitted or platform == "ios":
                    entry = {
                        "state": "submitted",
                        "expectedBuildManifest": self.expected_build(
                            next_source, layout=platform
                        ),
                    }
                else:
                    entry = {
                        "state": "carried",
                        "sourceManifest": prior_source,
                        "expectedBuildManifest": prior_entry["expectedBuildManifest"],
                        "shippedLineage": mixed_lineage
                        if platform == "macos"
                        else lineage,
                    }
                next_record["platforms"][platform] = entry
            next_comparison = compare_manifests(
                current, next_source, "rc", list(expected), release_record=next_record
            )
            next_builds = tuple(
                entry["expectedBuildManifest"]
                for entry in next_record["platforms"].values()
            )
            submitted_builds = [
                entry["expectedBuildManifest"]
                for entry in next_record["platforms"].values()
                if entry["state"] == "submitted"
            ]
            next_report, _ = self.signed_report(next_source, submitted_builds)
            next_identities = release_comparison_identities(
                next_builds,
                Target(
                    next_report["target"]["version"],
                    next_report["target"]["buildNumber"],
                ),
                next_comparison,
            )
            next_ledger = evaluate_release_evidence(
                **{
                    **arguments,
                    "comparison": next_comparison,
                    "validation_report": next_report,
                    "identities": next_identities,
                    "expected_build_manifests": next_builds,
                    "previous_ledger": mixed_lineage,
                }
            )
            self.assertEqual(next_ledger["state"], "approved", next_ledger["blockers"])
        from Tests.ScriptsTests.test_release_evidence_gate import watchlist_entry

        watched_policy = policy(watchlist_entries=(watchlist_entry("ios.app"),))
        archive = HistoricalPolicyArchive(
            release_policies={
                release_gate_module.canonical_payload_digest(policy()): policy()
            }
        )
        watched = evaluate_release_evidence(
            **{
                **arguments,
                "policy": watched_policy,
                "historical_policy_archive": archive,
            }
        )
        self.assertEqual(watched["state"], "blocked")
        self.assertTrue(
            any(blocker.startswith("ios.app:") for blocker in watched["blockers"])
        )
        with self.assertRaises(ReleaseEvidenceError):
            evaluate_release_evidence(**{**arguments, "previous_ledger": None})
        tampered = copy.deepcopy(ledger)
        tampered["surfaces"] = [
            item
            for item in tampered["surfaces"]
            if item["surface"].startswith("macos.")
        ]
        self.assertTrue(
            release_evidence_report_blockers(
                tampered,
                version=report["target"]["version"],
                build_number=report["target"]["buildNumber"],
                train="rc",
                enforce=True,
                **{k: v for k, v in arguments.items() if k not in {"train", "mode"}},
            )
        )
        from context_panel_release_gate.cli import run as run_gate
        from context_panel_validation.visual_approvals import load_visual_review_plan
        from context_panel_validation.runtime_evidence import (
            expected_surface_identities_from_payloads,
        )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {
                "comparison": comparison,
                "validation-report": report,
                "policy": policy(),
                "surface-policy": configured,
                "previous-ledger": lineage,
                "shadow-evidence": shadow,
            }
            argv = [
                "enforce",
                "--train",
                "rc",
                "--now",
                NOW.isoformat(),
                "--output",
                str(root / "ledger.json"),
            ]
            for name, payload in files.items():
                path = root / f"{name}.json"
                path.write_text(json.dumps(payload))
                argv.extend([f"--{name}", str(path)])
            for index, manifest in enumerate(expected):
                path = root / f"build-{index}.json"
                path.write_text(json.dumps(manifest))
                argv.extend(["--expected-build-manifest", str(path)])
            self.assertEqual(run_gate(argv), 0)
            self.assertEqual(json.loads((root / "ledger.json").read_text()), ledger)
            requirements = root / "requirements.json"
            from Tests.ScriptsTests.test_shared_view_capture_workflow import workflow

            requirements.write_text(
                json.dumps(
                    workflow.combined_visual_plan(root / "comparison.json", REPO_ROOT)
                )
            )
            submitted = expected_surface_identities_from_payloads(
                [record["platforms"]["macos"]["expectedBuildManifest"]],
                Target(report["target"]["version"], report["target"]["buildNumber"]),
                tuple(s["surface"] for s in report["runtimeSurfaces"]),
            )
            requested, _, _ = load_visual_review_plan(
                root / "comparison.json", requirements, submitted
            )
            self.assertEqual(list(requested), comparison["runtimeSessionSurfaces"])
        record["platforms"]["ios"]["shippedLineage"] = {}
        damaged = compare_manifests(
            previous, current, "rc", builds, release_record=record
        )
        with self.assertRaises(ReleaseEvidenceError):
            evaluate_release_evidence(**{**arguments, "comparison": damaged})

    def test_platform_release_compares_shipped_companions_without_new_runtime(self):
        previous, current, builds, record = self.platform_release()
        result = compare_manifests(
            previous, current, "release", builds, release_record=record
        )
        self.assertEqual(result["releaseSafety"]["state"], "resolved")
        self.assertEqual(
            {s["surfaceId"] for s in result["surfaces"]}, set(self.surfaces(current))
        )
        self.assertTrue(
            all(s.startswith("macos.") for s in result["runtimeSessionSurfaces"])
        )
        self.assertEqual(
            validate_current_comparison(json.loads(json.dumps(result))), result
        )
        validate_release_comparison(
            result,
            "release",
            json.loads(
                (REPO_ROOT / "Config/ContextPanelSurfacePolicy.json").read_text()
            ),
        )

    def test_platform_release_shared_dependencies_fail_closed(self):
        mutations = (
            ("CloudKit/ContextPanelCompanionSchema.json", "schema"),
            (
                "Sources/ContextPanelCloudKitSync/CompanionCloudKitStore.swift",
                "cloudkit",
            ),
            ("Config/ContextPanel.entitlements", "app-group"),
            ("Sources/ContextPanelApp/ContextPanelApp.swift", "mac-producer"),
        )
        for path, label in mutations:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                candidates = list(root.glob(path))
                if not candidates:
                    pattern = {
                        "schema": "CloudKit/**/*.json",
                        "cloudkit": "Sources/ContextPanelCloudKitSync/*.swift",
                        "app-group": "Config/*.entitlements",
                        "mac-producer": "Sources/ContextPanelApp/*.swift",
                    }[label]
                    candidates = list(root.glob(pattern))
                target = candidates[0]
                if target.suffix == ".json":
                    payload = json.loads(target.read_text())
                    payload["releaseTest"] = True
                    target.write_text(json.dumps(payload))
                elif target.suffix == ".entitlements":
                    payload = plistlib.loads(target.read_bytes())
                    payload["com.apple.security.application-groups"] = [
                        "group.example.changed"
                    ]
                    target.write_bytes(plistlib.dumps(payload))
                else:
                    self.append(target, "\n// shared contract change\n")
                previous, current, builds, record = self.platform_release(
                    self.manifest(root)
                )
                result = compare_manifests(
                    previous, current, "release", builds, release_record=record
                )
                self.assertEqual(
                    result["releaseSafety"]["state"], "unknown-fail-closed"
                )
                self.assertTrue(result["releaseSafety"]["blockers"])

    def test_platform_release_carried_dependency_check_is_independent_of_producer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(temporary)
            self.append(next((root / "Sources/ContextPanelCompanion").glob("*.swift")))
            previous, current, builds, record = self.platform_release(
                self.manifest(root)
            )
        result = compare_manifests(
            previous, current, "release", builds, release_record=record
        )
        self.assertEqual(result["releaseSafety"]["state"], "unknown-fail-closed")
        self.assertTrue(
            any(
                blocker.startswith("ios:")
                for blocker in result["releaseSafety"]["blockers"]
            )
        )
        self.assertFalse(
            any(
                blocker.startswith("macos:")
                for blocker in result["releaseSafety"]["blockers"]
            )
        )

    def test_platform_release_tooling_changes_preserve_binary_contract_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(temporary)
            self.append(
                root / "scripts/context_panel_comparison_schema.py",
                "\n# tooling-only change\n",
            )
            previous, current, builds, record = self.platform_release(
                self.manifest(root)
            )
        self.assertNotEqual(
            previous["contractFingerprint"], current["contractFingerprint"]
        )
        result = compare_manifests(
            previous, current, "rc", builds, release_record=record
        )
        self.assertEqual(result["releaseSafety"]["state"], "resolved")
        validate_current_comparison(result)
        from Tests.ScriptsTests.test_release_evidence_gate import NOW, policy
        from context_panel_release_gate import evaluate_release_evidence
        from context_panel_release_gate.core import release_comparison_identities
        from context_panel_validation import Target

        lineage, shadow = self.approved_shipped_lineage(previous, builds)
        for entry in record["platforms"].values():
            if entry["state"] == "carried":
                entry["shippedLineage"] = lineage
        result = compare_manifests(
            previous, current, "rc", builds, release_record=record
        )
        expected = tuple(
            entry["expectedBuildManifest"] for entry in record["platforms"].values()
        )
        report, _ = self.signed_report(
            current, [record["platforms"]["macos"]["expectedBuildManifest"]]
        )
        identities = release_comparison_identities(
            expected,
            Target(report["target"]["version"], report["target"]["buildNumber"]),
            result,
        )
        self.assertGreater(
            len({identity.contract_fingerprint for identity in identities}), 1
        )
        ledger = evaluate_release_evidence(
            train="rc",
            mode="enforce",
            comparison=result,
            validation_report=report,
            identities=identities,
            expected_build_manifests=expected,
            previous_ledger=lineage,
            shadow_evidence=shadow,
            policy=policy(),
            surface_policy=json.loads(
                (REPO_ROOT / "Config/ContextPanelSurfacePolicy.json").read_text()
            ),
            now=NOW,
        )
        self.assertEqual(ledger["state"], "approved", ledger["blockers"])
        from Tests.ScriptsTests.test_shared_view_capture_workflow import workflow

        with tempfile.TemporaryDirectory() as temporary:
            comparison_path = Path(temporary) / "comparison.json"
            comparison_path.write_text(json.dumps(result))
            plan = workflow.combined_visual_plan(comparison_path, REPO_ROOT)
            self.assertTrue(plan["requirements"])
            self.assertTrue(
                all(
                    item["surface"].startswith("macos.")
                    for item in plan["requirements"]
                )
            )

    def test_platform_release_missing_or_relabelled_shipped_build_is_rejected(self):
        for mutation in ("missing", "relabelled", "omitted-platform"):
            previous, current, builds, record = self.platform_release()
            if mutation == "missing":
                record["platforms"]["ios"]["expectedBuildManifest"] = None
            elif mutation == "relabelled":
                record["platforms"]["ios"]["expectedBuildManifest"]["source"] = current[
                    "source"
                ]
            else:
                del record["platforms"]["ios"]
            with self.subTest(mutation=mutation), self.assertRaises(SurfacePolicyError):
                compare_manifests(
                    previous, current, "release", builds, release_record=record
                )

    def test_platform_release_all_submitted_preserves_full_fleet_requirements(self):
        previous, current, builds, record = self.platform_release(all_submitted=True)
        expected = compare_manifests(
            previous,
            current,
            "release",
            builds,
            [entry["expectedBuildManifest"] for entry in record["platforms"].values()],
        )
        result = compare_manifests(
            previous, current, "release", builds, release_record=record
        )
        for field in (
            "surfaces",
            "requiredSurfaces",
            "runtimeState",
            "artifactRiskCodes",
            "artifactRiskSurfaces",
        ):
            self.assertEqual(result[field], expected[field], field)

    def test_platform_release_cannot_edit_carried_scope_or_contract_result(self):
        previous, current, builds, record = self.platform_release()
        result = compare_manifests(
            previous, current, "release", builds, release_record=record
        )
        result["surfaces"] = [
            s for s in result["surfaces"] if s["surfaceId"].startswith("macos.")
        ]
        with self.assertRaises(ComparisonSchemaError):
            validate_current_comparison(result)

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
        self.assertEqual(
            comparison["schemaVersion"],
            comparison_schema_module.CURRENT_COMPARISON_SCHEMA_VERSION,
        )
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
        self.assertEqual(
            comparison["schemaVersion"],
            comparison_schema_module.CURRENT_COMPARISON_SCHEMA_VERSION,
        )
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

    def test_rc_and_release_toolchain_divergence_force_runtime_capable_surfaces(self):
        next_build = copy.deepcopy(self.baseline)
        next_build["toolchain"] = {
            **next_build["toolchain"],
            "swiftLanguageVersion": "6.1",
        }
        runtime_capable = sorted(
            surface_id
            for surface_id, surface in self.surfaces(next_build).items()
            if "actual-runtime" in surface["evidenceCapabilities"]
        )
        for train in ("rc", "release"):
            with self.subTest(train=train):
                comparison = compare_manifests(self.baseline, next_build, train)
                self.assertTrue(comparison["toolchainChanged"])
                self.assertEqual(
                    comparison["riskSurfaces"]["toolchain-divergence"],
                    runtime_capable,
                )
                self.assertEqual(
                    comparison["requiredSurfaces"]["actual-runtime"],
                    runtime_capable,
                )
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

    def test_artifact_semantic_risks_fan_out_without_escalating_beta(self):
        surfaces = self.surfaces(self.baseline)
        shared_artifact = surfaces["ios.app"]["artifactId"]
        self.assertEqual(shared_artifact, surfaces["ipados.app"]["artifactId"])
        previous = self.expected_build(self.baseline)

        def change_entitlement_contract(template):
            artifact = next(
                item for item in template["artifacts"]
                if item["artifactId"] == shared_artifact
            )
            artifact["entitlementContractSha256"] = "f" * 64

        current = self.expected_build(self.baseline, change_entitlement_contract)
        beta = compare_manifests(
            self.baseline,
            self.baseline,
            "beta",
            [previous],
            [current],
        )
        self.assertEqual(beta["artifactEvidence"]["previousState"], "complete")
        self.assertEqual(beta["artifactEvidence"]["currentState"], "complete")
        self.assertEqual(beta["artifactRiskCodes"], ["entitlement-contract-changed"])
        self.assertEqual(
            beta["artifactRiskSurfaces"]["entitlement-contract-changed"],
            ["ios.app", "ipados.app"],
        )
        self.assertNotIn("ios.app", beta["requiredSurfaces"]["actual-runtime"])
        self.assertFalse(beta["requiresRuntimeSession"])

        rc = compare_manifests(
            self.baseline,
            self.baseline,
            "rc",
            [previous],
            [current],
        )
        by_surface = {item["surfaceId"]: item for item in rc["surfaces"]}
        for surface_id in ("ios.app", "ipados.app"):
            self.assertIn("actual-runtime", by_surface[surface_id]["freshEvidence"])

    def test_artifact_escalation_round_trips_through_release_policy(self):
        surfaces = self.surfaces(self.baseline)
        shared_artifact = surfaces["ios.app"]["artifactId"]
        previous = self.expected_build(self.baseline)

        def change_signing_contract(template):
            next(
                item for item in template["artifacts"]
                if item["artifactId"] == shared_artifact
            )["signingContractSha256"] = "f" * 64

        current = self.expected_build(self.baseline, change_signing_contract)
        comparison = compare_manifests(
            self.baseline,
            self.baseline,
            "rc",
            [previous],
            [current],
        )
        surface_policy = json.loads(
            (REPO_ROOT / "Config/ContextPanelSurfacePolicy.json").read_text()
        )
        validated = validate_release_comparison(comparison, "rc", surface_policy)
        self.assertIn("ios.app", validated)

        stripped = copy.deepcopy(comparison)
        ios_surface = next(
            item for item in stripped["surfaces"]
            if item["surfaceId"] == "ios.app"
        )
        ios_surface["freshEvidence"].remove("actual-runtime")
        ios_surface["carryForward"]["actual-runtime"] = {
            "eligible": True,
            "conditions": [],
        }
        with self.assertRaisesRegex(
            ReleaseEvidenceError,
            "surface comparison is invalid",
        ):
            validate_release_comparison(stripped, "rc", surface_policy)

    def test_artifact_risk_vocabulary_ignores_raw_provenance_noise(self):
        previous = self.expected_build(self.baseline)
        semantic_cases = (
            ("bundleContractSha256", "bundle-contract-changed", "e" * 64),
            ("signingContractSha256", "signing-contract-changed", "d" * 64),
            ("entitlementContractSha256", "entitlement-contract-changed", "c" * 64),
            ("profileCapabilitySha256", "profile-capability-changed", "b" * 64),
        )
        artifact_id = previous["artifacts"][0]["artifactId"]
        expected_surfaces = sorted(
            surface_id
            for surface_id, surface in self.surfaces(self.baseline).items()
            if surface["artifactId"] == artifact_id
        )
        for field, risk_code, replacement in semantic_cases:
            with self.subTest(field=field):
                def mutate(
                    template,
                    semantic_field=field,
                    semantic_replacement=replacement,
                ):
                    next(
                        item for item in template["artifacts"]
                        if item["artifactId"] == artifact_id
                    )[semantic_field] = semantic_replacement

                current = self.expected_build(self.baseline, mutate)
                comparison = compare_manifests(
                    self.baseline,
                    self.baseline,
                    "beta",
                    [previous],
                    [current],
                )
                self.assertEqual(comparison["artifactRiskCodes"], [risk_code])
                self.assertEqual(
                    comparison["artifactRiskSurfaces"][risk_code],
                    expected_surfaces,
                )

        def mutate_raw_provenance(template):
            artifact = next(
                item for item in template["artifacts"]
                if item["artifactId"] == artifact_id
            )
            artifact["executableUUIDs"] = ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]
            artifact["entitlementsSha256"] = "a" * 64
            artifact["profileSha256"] = "9" * 64

        noisy = self.expected_build(self.baseline, mutate_raw_provenance)
        comparison = compare_manifests(
            self.baseline,
            self.baseline,
            "beta",
            [previous],
            [noisy],
        )
        self.assertEqual(comparison["artifactRiskCodes"], [])
        self.assertEqual(comparison["artifactRiskSurfaces"], {})

    def test_semantic_artifact_risk_scope_matrix_is_exact_across_trains(self):
        surfaces = self.surfaces(self.baseline)
        artifact_id = surfaces["ios.app"]["artifactId"]
        affected_surfaces = sorted(
            surface_id
            for surface_id, surface in surfaces.items()
            if surface["artifactId"] == artifact_id
        )
        runtime_capable = sorted(
            surface_id
            for surface_id, surface in surfaces.items()
            if "actual-runtime" in surface["evidenceCapabilities"]
        )
        previous = self.expected_build(self.baseline)
        cases = (
            ("bundle", "bundleContractSha256", "bundle-contract-changed"),
            ("signing", "signingContractSha256", "signing-contract-changed"),
            (
                "app-group-entitlement",
                "entitlementContractSha256",
                "entitlement-contract-changed",
            ),
            (
                "cloudkit-profile-capability",
                "profileCapabilitySha256",
                "profile-capability-changed",
            ),
        )
        for label, field, risk_code in cases:
            def mutate(template, semantic_field=field):
                next(
                    artifact
                    for artifact in template["artifacts"]
                    if artifact["artifactId"] == artifact_id
                )[semantic_field] = "f" * 64

            current = self.expected_build(self.baseline, mutate)
            for train in ("beta", "rc", "release"):
                with self.subTest(label=label, train=train):
                    control = compare_manifests(
                        self.baseline,
                        self.baseline,
                        train,
                        [previous],
                        [previous],
                    )
                    comparison = compare_manifests(
                        self.baseline,
                        self.baseline,
                        train,
                        [previous],
                        [current],
                    )
                    expected_runtime = [] if train == "beta" else runtime_capable
                    self.assertEqual(comparison["artifactRiskCodes"], [risk_code])
                    self.assertEqual(
                        comparison["artifactRiskSurfaces"],
                        {risk_code: affected_surfaces},
                    )
                    self.assertEqual(
                        comparison["requiredSurfaces"]["actual-runtime"],
                        expected_runtime,
                    )
                    self.assertEqual(
                        comparison["requiredSurfaces"]["os-composited-placement"],
                        [],
                    )
                    self.assertEqual(
                        comparison["requiresRuntimeSession"],
                        bool(expected_runtime),
                    )
                    self.assertFalse(comparison["requiresPlacementReview"])
                    if train != "beta":
                        control_surfaces = {
                            surface["surfaceId"]: surface
                            for surface in control["surfaces"]
                        }
                        risk_surfaces = {
                            surface["surfaceId"]: surface
                            for surface in comparison["surfaces"]
                        }
                        for surface_id in runtime_capable:
                            self.assertTrue(
                                control_surfaces[surface_id]["carryForward"][
                                    "actual-runtime"
                                ]["eligible"]
                            )
                            self.assertEqual(
                                risk_surfaces[surface_id]["carryForward"][
                                    "actual-runtime"
                                ]["eligible"],
                                surface_id not in affected_surfaces,
                            )

    def test_artifact_architecture_addition_is_safe_but_loss_escalates(self):
        previous = self.expected_build(self.baseline)
        artifact_id = self.surfaces(self.baseline)["macos.widget"]["artifactId"]

        def architectures(template, values):
            next(
                item for item in template["artifacts"]
                if item["artifactId"] == artifact_id
            )["architectures"] = values

        universal = self.expected_build(
            self.baseline,
            lambda template: architectures(template, ["arm64", "x86_64"]),
        )
        addition = compare_manifests(
            self.baseline,
            self.baseline,
            "beta",
            [previous],
            [universal],
        )
        self.assertEqual(addition["artifactRiskCodes"], [])

        loss = compare_manifests(
            self.baseline,
            self.baseline,
            "beta",
            [universal],
            [previous],
        )
        self.assertEqual(loss["artifactRiskCodes"], ["architecture-loss"])

    def test_missing_artifact_evidence_is_surface_scoped_and_fail_closed(self):
        current = self.expected_build(self.baseline)
        comparison = compare_manifests(
            self.baseline,
            self.baseline,
            "rc",
            [],
            [current],
        )
        runtime_surfaces = sorted(
            surface_id
            for surface_id, surface in self.surfaces(self.baseline).items()
            if "actual-runtime" in surface["evidenceCapabilities"]
        )
        self.assertEqual(comparison["artifactEvidence"]["previousState"], "missing")
        self.assertEqual(comparison["artifactRiskCodes"], ["artifact-evidence-unknown"])
        self.assertEqual(
            comparison["artifactRiskSurfaces"]["artifact-evidence-unknown"],
            runtime_surfaces,
        )
        self.assertEqual(comparison["escalationState"], "unknown-fail-closed")
        self.assertTrue(
            set(runtime_surfaces) <= set(comparison["requiredSurfaces"]["actual-runtime"])
        )
        tampered = copy.deepcopy(comparison)
        tampered["artifactRiskCodes"] = []
        tampered["artifactRiskSurfaces"] = {}
        tampered["escalationState"] = "resolved"
        with self.assertRaisesRegex(
            ComparisonSchemaError,
            "incomplete artifact evidence is not fail-closed",
        ):
            validate_current_comparison(tampered)

        for key, malformed in (
            ("previousExpectedBuildIds", ["a" * 64, 1]),
            ("currentExpectedBuildIds", ["a" * 64, None]),
        ):
            with self.subTest(key=key):
                malformed_comparison = copy.deepcopy(comparison)
                malformed_comparison["artifactEvidence"][key] = malformed
                with self.assertRaisesRegex(
                    ComparisonSchemaError,
                    "artifact evidence is not canonical",
                ):
                    validate_current_comparison(malformed_comparison)

        malformed_surfaces = copy.deepcopy(comparison)
        malformed_surfaces["artifactRiskSurfaces"][
            "artifact-evidence-unknown"
        ] = [runtime_surfaces[0], 1]
        with self.assertRaisesRegex(
            ComparisonSchemaError,
            "artifact risk surface map is not canonical",
        ):
            validate_current_comparison(malformed_surfaces)

    def test_partial_layout_evidence_is_missing_without_crashing(self):
        partial = self.expected_build(self.baseline, layout="ios")
        comparison = compare_manifests(
            self.baseline,
            self.baseline,
            "rc",
            [partial],
            [partial],
        )
        self.assertEqual(comparison["artifactEvidence"]["previousState"], "missing")
        self.assertEqual(comparison["artifactEvidence"]["currentState"], "missing")
        self.assertEqual(
            comparison["artifactEvidence"]["previousExpectedBuildIds"],
            [partial["expectedBuildId"]],
        )
        self.assertEqual(comparison["artifactRiskCodes"], ["artifact-evidence-unknown"])
        with self.assertRaisesRegex(
            ReleaseEvidenceError,
            "previous expected-build coverage is incomplete",
        ):
            validate_artifact_comparison_inputs(
                comparison,
                current_manifests=(partial,),
                previous_lineage=None,
            )

    def test_legacy_and_mixed_artifact_evidence_fail_closed(self):
        current = self.expected_build(self.baseline)
        legacy = copy.deepcopy(current)
        legacy["schemaVersion"] = 1
        for artifact in legacy["artifacts"]:
            for key in (
                "bundleContractSha256",
                "signingClass",
                "signingContractSha256",
                "entitlementContractSha256",
                "profileCapabilitySha256",
                "architectures",
            ):
                artifact.pop(key)
        unsigned = {key: value for key, value in legacy.items() if key != "expectedBuildId"}
        legacy["expectedBuildId"] = core_module.hash_parts(
            f"{legacy['digestDomain']}/expected-build",
            [core_module.canonical_json(unsigned)],
        )

        legacy_comparison = compare_manifests(
            self.baseline,
            self.baseline,
            "rc",
            [legacy],
            [current],
        )
        self.assertEqual(
            legacy_comparison["artifactEvidence"]["previousState"],
            "legacy-incomplete",
        )
        self.assertEqual(
            legacy_comparison["artifactRiskCodes"],
            ["artifact-evidence-unknown"],
        )

        mixed = compare_manifests(
            self.baseline,
            self.baseline,
            "beta",
            None,
            [current],
        )
        self.assertEqual(mixed["artifactEvidence"]["previousState"], "not-evaluated")
        self.assertEqual(mixed["artifactEvidence"]["currentState"], "complete")
        self.assertEqual(mixed["artifactRiskCodes"], ["artifact-evidence-unknown"])
        self.assertFalse(mixed["requiresRuntimeSession"])

    def test_artifact_mapping_change_fans_out_by_current_artifact(self):
        previous = self.expected_build(self.baseline)
        current_manifest = copy.deepcopy(self.baseline)
        current_surfaces = self.surfaces(current_manifest)
        remapped_artifact = "companion.ios.remapped"
        current_surfaces["ios.app"]["artifactId"] = remapped_artifact
        current_surfaces["ipados.app"]["artifactId"] = remapped_artifact
        current = self.expected_build(current_manifest)
        comparison = compare_manifests(
            self.baseline,
            current_manifest,
            "beta",
            [previous],
            [current],
        )
        self.assertEqual(comparison["artifactRiskCodes"], ["artifact-mapping-changed"])
        self.assertEqual(
            comparison["artifactRiskSurfaces"]["artifact-mapping-changed"],
            ["ios.app", "ipados.app"],
        )

    def test_unexplained_executable_drift_requires_stable_source_context(self):
        previous = self.expected_build(self.baseline)
        artifact_id = previous["artifacts"][0]["artifactId"]

        def change_executable(template):
            next(
                item for item in template["artifacts"]
                if item["artifactId"] == artifact_id
            )["executableSha256"] = "8" * 64

        drifted = self.expected_build(self.baseline, change_executable)
        unexplained = compare_manifests(
            self.baseline,
            self.baseline,
            "beta",
            [previous],
            [drifted],
        )
        self.assertEqual(
            unexplained["artifactRiskCodes"],
            ["unexplained-executable-drift"],
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.fixture(temporary_directory)
            self.append(root / "Sources/ContextPanelWidgetUI/ContextPanelWidgetViews.swift")
            changed_manifest = self.manifest(root)
        explained_build = self.expected_build(changed_manifest, change_executable)
        explained = compare_manifests(
            self.baseline,
            changed_manifest,
            "beta",
            [previous],
            [explained_build],
        )
        self.assertNotIn(
            "unexplained-executable-drift",
            explained["artifactRiskCodes"],
        )

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
        signing_a = canonical_json_hash(
            {
                "identifierMatchesBundleIdentifier": True,
                "signingClass": "Apple Distribution",
                "teamIdentitySha256": hashlib.sha256(b"TEAM-A").hexdigest(),
            }
        )
        signing_b = canonical_json_hash(
            {
                "identifierMatchesBundleIdentifier": True,
                "signingClass": "Apple Development",
                "teamIdentitySha256": hashlib.sha256(b"TEAM-A").hexdigest(),
            }
        )
        signing_c = canonical_json_hash(
            {
                "identifierMatchesBundleIdentifier": True,
                "signingClass": "Apple Distribution",
                "teamIdentitySha256": hashlib.sha256(b"TEAM-B").hexdigest(),
            }
        )
        self.assertNotEqual(signing_a, signing_b)
        self.assertNotEqual(signing_a, signing_c)

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

    def test_expected_build_id_binds_raw_and_semantic_v2_fields(self):
        template = evidence_template(self.baseline, "macos")
        for artifact in template["artifacts"]:
            artifact.update(v2_artifact_contract(artifact["artifactId"].encode()))
        sealed = seal_expected_build(self.baseline, template)
        for key in (
            "executableSha256",
            "executableUUIDs",
            "entitlementsSha256",
            "profileSha256",
            "bundleContractSha256",
            "signingContractSha256",
            "entitlementContractSha256",
            "profileCapabilitySha256",
            "architectures",
        ):
            tampered = json.loads(json.dumps(sealed))
            if isinstance(tampered["artifacts"][0][key], list):
                tampered["artifacts"][0][key] = ["tampered"]
            else:
                tampered["artifacts"][0][key] = "f" * 64
            self.assertNotEqual(
                tampered["expectedBuildId"],
                core_module.hash_parts(
                    f"{tampered['digestDomain']}/expected-build",
                    [
                        core_module.canonical_json(
                            {name: value for name, value in tampered.items() if name != "expectedBuildId"}
                        )
                    ],
                ),
                key,
            )

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
