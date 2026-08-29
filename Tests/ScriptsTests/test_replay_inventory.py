import copy
import importlib
import json
import re
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

inventory_module = importlib.import_module("context_panel_replay.inventory")
adapter_v1_module = importlib.import_module("context_panel_replay.comparison_adapter_v1")
adapters_module = importlib.import_module("context_panel_replay.comparison_adapters")
current_schema_module = importlib.import_module("context_panel_comparison_schema")
InventoryError = inventory_module.InventoryError
canonical_digest = inventory_module.canonical_digest
canonical_json = inventory_module.canonical_json
check_inventory = inventory_module.check_inventory
render_json = inventory_module.render_json
seal_inventory = inventory_module.seal_inventory
verify_inventory = inventory_module.verify_inventory
write_inventory = inventory_module.write_inventory
scan_public = inventory_module._scan_public
hash_parts = inventory_module._hash_parts
expected_build_identity_digest = inventory_module._expected_build_identity_digest
expected_surface_identities = inventory_module._expected_surface_identities
adapt_v1_comparison = adapter_v1_module.adapt_v1_comparison
adapter_contract_digest = adapter_v1_module.adapter_contract_digest
adapter_dependency_digest = adapter_v1_module.adapter_dependency_digest
adapter_implementation_digest = adapter_v1_module.adapter_implementation_digest
adapt_comparison_for_replay = adapters_module.adapt_comparison_for_replay
ComparisonAdapterError = adapters_module.ComparisonAdapterError


class ReplayInventoryTests(unittest.TestCase):
    def write_json(self, path: Path, payload: dict) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    def write_mutated_inventory(self, path: Path, payload: dict) -> None:
        payload["inventoryId"] = canonical_digest(
            {key: value for key, value in payload.items() if key != "inventoryId"}
        )
        self.write_json(path, payload)

    def rewrite_report_chain(self, root: Path, mutate) -> None:
        report_path = root / "archive/train/report.json"
        report = json.loads(report_path.read_text())
        mutate(report)
        self.write_json(report_path, report)
        ledger_path = root / "archive/train/ledger.json"
        ledger = json.loads(ledger_path.read_text())
        ledger["validationReportDigest"] = canonical_digest(report)
        ledger.pop("ledgerID")
        ledger["ledgerID"] = canonical_digest(ledger)
        self.write_json(ledger_path, ledger)
        lineage_path = root / "archive/train/lineage.json"
        lineage = json.loads(lineage_path.read_text())
        lineage["ledger"] = ledger
        lineage["generation"]["validationReport"] = report
        self.write_json(lineage_path, lineage)

    def receipt_payload(
        self,
        surface: str = "macos.app",
        *,
        platform: str = "macOS",
        artifact_id: str = "Context Panel.app",
        bundle_identifier: str = "com.shinycomputers.contextpanel",
        session_expires_at: str = "2026-08-27T12:30:00Z",
        observed_at: str = "2026-08-27T12:05:00Z",
        retention_expires_at: str = "2026-08-28T12:05:00Z",
        executable_uuids: list[str] | None = None,
        fingerprints: dict[str, str] | None = None,
        manifest_id: str = "b" * 64,
        marketing_version: str = "1.0.1",
        build_number: str = "202608270001",
        contract_fingerprint: str = "c" * 64,
    ) -> dict[str, Any]:
        session_id = "11111111-1111-1111-1111-111111111111"
        session_created_at = "2026-08-27T12:00:00Z"
        process_instance_id = "22222222-2222-2222-2222-222222222222"
        executable_uuids = executable_uuids or [
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ]
        fingerprints = fingerprints or self.surface_fingerprints()
        build = {
            "marketingVersion": marketing_version,
            "buildNumber": build_number,
            "manifestID": manifest_id,
            "contractFingerprint": contract_fingerprint,
        }
        payload = {
            "schemaVersion": 1,
            "evidenceClass": "actual-runtime",
            "id": "",
            "sessionID": session_id,
            "sessionCreatedAt": session_created_at,
            "sessionExpiresAt": session_expires_at,
            "observedAt": observed_at,
            "retentionExpiresAt": retention_expires_at,
            "processInstanceID": process_instance_id,
            "processSequence": 1,
            "buildIdentity": {
                "surface": surface,
                "platform": platform,
                "artifactID": artifact_id,
                "bundleIdentifier": bundle_identifier,
                "build": build,
                "fingerprints": fingerprints,
                "executableUUIDs": executable_uuids,
            },
            "trigger": "app-snapshot-load",
            "presentationMode": "app-overview",
            "selectedSource": "app-group-snapshot",
            "presentationDigest": "5" * 64,
            "stateBranch": "ready",
            "outcome": "success",
        }
        payload["id"] = hash_parts(
            "context-panel/runtime-receipt/id/v1",
            [
                session_id,
                str(self.timestamp_seconds(session_created_at)),
                str(self.timestamp_seconds(session_expires_at)),
                str(self.timestamp_seconds(observed_at)),
                str(self.timestamp_seconds(retention_expires_at)),
                surface,
                platform,
                artifact_id,
                bundle_identifier,
                build["marketingVersion"],
                build["buildNumber"],
                build["manifestID"],
                build["contractFingerprint"],
                fingerprints["render"],
                fingerprints["runtime"],
                fingerprints["placement"],
                fingerprints["combined"],
                ",".join(executable_uuids),
                process_instance_id,
                "1",
                payload["trigger"],
                payload["presentationMode"],
                payload["selectedSource"],
                payload["presentationDigest"],
                payload["stateBranch"],
                payload["outcome"],
            ],
        )
        return payload

    def surface_fingerprints(self) -> dict[str, str]:
        return {
            "render": "1" * 64,
            "runtime": "2" * 64,
            "placement": "3" * 64,
            "combined": "4" * 64,
        }

    def expected_build_manifest(
        self,
        platform: str,
        current: dict[str, Any],
        *,
        schema_version: int = 1,
    ) -> dict[str, Any]:
        artifacts: list[dict[str, Any]] = []
        surfaces: list[dict[str, Any]] = []
        if platform == "macos":
            artifacts.append(
                {
                    "artifactId": "Context Panel.app",
                    "bundleIdentifier": "com.shinycomputers.contextpanel",
                    "marketingVersion": "1.0.1",
                    "buildNumber": "202608270001",
                    "sourceCommit": "0" * 40,
                    "configuration": "Release",
                    "xcodeBuild": "27A000",
                    "treeState": "clean",
                    "codeSignatureValid": True,
                    "executableSha256": "6" * 64,
                    "executableUUIDs": [
                        "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                        "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF",
                    ],
                    "entitlementsSha256": "7" * 64,
                    "profileSha256": "8" * 64,
                }
            )
            if schema_version == 2:
                artifacts[-1].update(
                    {
                        "bundleContractSha256": "9" * 64,
                        "signingClass": "Apple Distribution",
                        "signingContractSha256": "a" * 64,
                        "entitlementContractSha256": "b" * 64,
                        "profileCapabilitySha256": "c" * 64,
                        "architectures": ["arm64", "x86_64"],
                    }
                )
            surfaces.append(
                {
                    "id": "macos.app",
                    "artifactId": "Context Panel.app",
                    "bundleIdentifier": "com.shinycomputers.contextpanel",
                    "fingerprints": self.surface_fingerprints(),
                }
            )
        payload = {
            "schemaVersion": schema_version,
            "kind": "context-panel-expected-signed-build",
            "algorithm": "sha256",
            "digestDomain": "context-panel-surface/v1",
            "sourceManifestId": current["manifestId"],
            "contractFingerprint": current["contractFingerprint"],
            "layout": f"{platform}-archive",
            "archive": {"layout": f"{platform}-archive", "name": f"ContextPanel-{platform}.zip"},
            "source": {
                "marketingVersion": "1.0.1",
                "buildNumber": "202608270001",
            },
            "artifacts": artifacts,
            "surfaces": surfaces,
        }
        payload["expectedBuildId"] = hash_parts(
            "context-panel-surface/v1/expected-build",
            [canonical_json(payload)],
        )
        return payload

    def replace_receipt(self, root: Path, payload: dict[str, Any]) -> None:
        receipt_dir = root / "archive/train/receipts"
        for path in receipt_dir.glob("*.json"):
            path.unlink()
        self.write_json(receipt_dir / f"{payload['id']}.json", payload)
        self.rewrite_report_chain(
            root,
            lambda report: report["runtimeSurfaces"][0].update(
                {"receiptIDs": [payload["id"]]}
            ),
        )

    def timestamp_seconds(self, value: str) -> int:
        return int(
            datetime.fromisoformat(value.replace("Z", "+00:00"))
            .astimezone(timezone.utc)
            .timestamp()
        )

    def fixture(self, root: Path, *, retain_receipt: bool = False) -> tuple[Path, dict[str, Path]]:
        archive = root / "archive"
        train_root = archive / "train"
        previous = {
            "schemaVersion": 1,
            "manifestId": "a" * 64,
            "contractFingerprint": "c" * 64,
            "source": {
                "marketingVersion": "1.0.0",
                "buildNumber": "202608260001",
            },
            "surfaces": [],
        }
        current = {
            "schemaVersion": 1,
            "manifestId": "b" * 64,
            "contractFingerprint": "c" * 64,
            "source": {
                "marketingVersion": "1.0.1",
                "buildNumber": "202608270001",
            },
            "surfaces": [],
        }
        comparison = {
            "schemaVersion": 1,
            "train": "rc",
            "previousManifestId": previous["manifestId"],
            "currentManifestId": current["manifestId"],
            "contractChanged": False,
            "exactBuildSame": True,
            "removedSurfaces": [],
            "requiredSurfaces": {
                "shared-view": ["macos.app"],
                "actual-runtime": ["macos.app"],
                "os-composited-placement": [],
            },
            "requiresRuntimeSession": True,
            "requiresPlacementReview": False,
            "surfaces": [
                {
                    "surfaceId": "macos.app",
                    "artifactId": "Context Panel.app",
                    "reasonCodes": ["unchanged"],
                    "changes": {
                        "render": False,
                        "runtime": False,
                        "placement": False,
                        "contract": False,
                        "exactBuild": False,
                    },
                    "minimumEvidence": ["shared-view", "actual-runtime"],
                    "freshEvidence": [],
                    "requiredEvidence": ["shared-view", "actual-runtime"],
                    "carryForward": {
                        "shared-view": {"eligible": True, "conditions": []},
                    },
                }
            ],
            "releaseRequiresApprovedRCTarget": True,
        }
        required_surfaces = comparison["requiredSurfaces"]
        assert isinstance(required_surfaces, dict)
        receipt = self.receipt_payload()
        receipt_id = receipt["id"]
        visual = {
            "state": "approved",
            "requirements": [
                {
                    "id": "macos.app.shared.default",
                    "decision": {"id": "e" * 64, "value": "approved"},
                }
            ],
        }
        report = {
            "schemaVersion": 1,
            "target": {"version": "1.0.1", "buildNumber": "202608270001"},
            "session": {"requestedSurfaces": ["macos.app"]},
            "runtimeSurfaces": [
                {
                    "surface": "macos.app",
                    "state": "proven",
                    "receiptIDs": [receipt_id],
                }
            ],
            "visualApprovals": visual,
        }
        expected_builds = []
        expected_paths = {}
        for platform in ("ios", "macos", "tvos", "visionos"):
            payload = self.expected_build_manifest(platform, current)
            relative = f"expected/ExpectedBuildManifest-{platform}.json"
            expected_paths[platform] = relative
            expected_builds.append(payload)
            self.write_json(train_root / relative, payload)
        ledger = {
            "schemaVersion": 1,
            "kind": "context-panel-release-evidence",
            "train": "rc",
            "mode": "shadow",
            "state": "shadow-approved",
            "target": {"version": "1.0.1", "buildNumber": "202608270001"},
            "comparisonDigest": canonical_digest(comparison),
            "validationReportDigest": canonical_digest(report),
            "expectedBuildIdentityDigest": expected_build_identity_digest(
                expected_surface_identities(
                    expected_builds,
                    {"version": "1.0.1", "buildNumber": "202608270001"},
                    current,
                )
            ),
        }
        ledger["ledgerID"] = canonical_digest(ledger)
        lineage = {
            "schemaVersion": 1,
            "kind": "context-panel-release-evidence-lineage",
            "ledger": ledger,
            "generation": {
                "comparison": comparison,
                "validationReport": report,
                "expectedBuildManifests": expected_builds,
            },
        }
        self.write_json(archive / "previous.json", previous)
        self.write_json(train_root / "current.json", current)
        self.write_json(train_root / "comparison.json", comparison)
        self.write_json(train_root / "report.json", report)
        self.write_json(train_root / "ledger.json", ledger)
        self.write_json(train_root / "lineage.json", lineage)
        self.write_json(train_root / "visual.json", visual)
        receipt_dirs = []
        if retain_receipt:
            receipt_dirs = ["receipts"]
            self.write_json(
                train_root / "runtime-session.json",
                {
                    "schemaVersion": 1,
                    "id": receipt["sessionID"],
                    "createdAt": receipt["sessionCreatedAt"],
                    "expiresAt": receipt["sessionExpiresAt"],
                    "expectedManifestID": current["manifestId"],
                    "enabledSurfaces": ["macos.app"],
                    "minimumWriteIntervalSeconds": 30,
                    "receiptTTLSeconds": 24 * 60 * 60,
                    "maximumReceiptCount": 128,
                },
            )
            self.write_json(
                train_root / "receipts" / f"{receipt_id}.json",
                receipt,
            )
        policy = {
            "schemaVersion": 1,
            "kind": "context-panel-replay-inventory-policy",
            "algorithm": "sha256",
            "digestDomain": "context-panel.replay-inventory.v1",
            "requiredCategories": [
                "previous-source-manifest",
                "current-source-manifest",
                "archived-comparison",
                "coordinator-final-report",
                "expected-build-manifests",
                "release-evidence-ledger",
                "release-evidence-lineage",
                "physical-runtime-receipts",
                "visual-approvals",
            ],
            "recoverabilityClasses": [
                "durable",
                "single-copy",
                "fragile",
                "reference-only",
            ],
            "sourceRoots": {
                "archive": {
                    "sourceClass": "signed-train-export",
                    "defaultRecoverability": "single-copy",
                    "versionControl": "absent",
                }
            },
            "inadmissibleSourceClasses": ["live-coordinator-container", "working-tree"],
            "trains": [
                {
                    "trainId": "1.0.1-202608270001",
                    "version": "1.0.1",
                    "buildNumber": "202608270001",
                    "trainClass": "rc-shadow",
                    "admissibleClaims": ["rc-shadow-agreement"],
                    "trainRoot": "archive",
                    "trainPath": "train",
                    "previousManifest": {"root": "archive", "path": "previous.json"},
                    "currentManifestPath": "current.json",
                    "comparisonPath": "comparison.json",
                    "finalReportPath": "report.json",
                    "lineagePath": "lineage.json",
                    "ledgerPath": "ledger.json",
                    "expectedBuildManifests": expected_paths,
                    "runtimeReceiptDirs": receipt_dirs,
                    "runtimeSessionPath": (
                        "runtime-session.json" if retain_receipt else None
                    ),
                    "visualApprovals": {"mode": "file", "path": "visual.json"},
                    "sealedMetadataDigest": canonical_digest(
                        {
                            "previousManifestId": previous["manifestId"],
                            "currentManifestId": current["manifestId"],
                            "contractFingerprint": current["contractFingerprint"],
                            "scope": {
                                key: sorted(value)
                                for key, value in required_surfaces.items()
                            },
                        }
                    ),
                }
            ],
        }
        policy_path = root / "policy.json"
        self.write_json(policy_path, policy)
        return policy_path, {"archive": archive}

    def test_seal_is_deterministic_and_root_independent(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            first_path = Path(first)
            policy, roots = self.fixture(first_path)
            first_inventory = seal_inventory(policy, roots)
            copied = Path(second) / "copy"
            shutil.copytree(first_path, copied)
            second_inventory = seal_inventory(
                copied / "policy.json",
                {"archive": copied / "archive"},
            )
            self.assertEqual(first_inventory, second_inventory)

    def test_v1_adapter_is_frozen_and_preserves_its_input(self):
        raw = {
            "schemaVersion": 1,
            "train": "beta",
            "previousManifestId": "a" * 64,
            "currentManifestId": "b" * 64,
            "contractChanged": False,
            "exactBuildSame": True,
            "removedSurfaces": [],
            "requiredSurfaces": {
                "shared-view": ["macos.app"],
                "actual-runtime": [],
                "os-composited-placement": [],
            },
            "requiresRuntimeSession": False,
            "requiresPlacementReview": False,
            "surfaces": [
                {
                    "surfaceId": "macos.app",
                    "artifactId": "Context Panel.app",
                    "reasonCodes": ["unchanged"],
                    "changes": {
                        "render": False,
                        "runtime": False,
                        "placement": False,
                        "contract": False,
                        "exactBuild": False,
                    },
                    "minimumEvidence": ["shared-view"],
                    "freshEvidence": [],
                    "requiredEvidence": ["shared-view"],
                    "carryForward": {
                        "shared-view": {"eligible": True, "conditions": []},
                    },
                }
            ],
            "releaseRequiresApprovedRCTarget": True,
        }
        original = copy.deepcopy(raw)
        adapted = adapt_v1_comparison(raw)
        expected = copy.deepcopy(raw)
        expected["kind"] = "context-panel-surface-comparison"
        expected["schemaVersion"] = 2
        self.assertEqual(adapted, expected)
        self.assertEqual(raw, original)
        self.assertEqual(
            adapter_contract_digest(),
            "b75a0eb0f30eac298f95c7b267c797427641612f3ae729c6a2e3e08345f2761e",
        )
        self.assertEqual(
            adapter_implementation_digest(),
            "27a8bd159bdb0763a54ac96a96eeb30dfcd332a821729b22405589b260228b42",
        )
        self.assertEqual(
            adapter_dependency_digest(),
            "520ad05b6654f9c112d60ceb638b89ff2a0f53c38dde84647a87dcc469db4032",
        )
        self.assertEqual(
            canonical_digest(adapted),
            "790c22083857109e73190acc4cfd7b905d1fca511f9cb6bd58c04b499b72cffe",
        )
        self.assertIs(adapt_comparison_for_replay(adapted), adapted)
        incomplete_v2 = copy.deepcopy(adapted)
        incomplete_v2["surfaces"][0]["carryForward"] = {}
        with self.assertRaisesRegex(ComparisonAdapterError, "v2 comparison is invalid"):
            adapt_comparison_for_replay(incomplete_v2)
        current = copy.deepcopy(adapted)
        current["schemaVersion"] = 3
        current["runtimeState"], current["runtimeStateReasons"] = (
            current_schema_module.derive_runtime_decision(current["surfaces"])
        )
        self.assertIs(adapt_comparison_for_replay(current), current)
        current_v4 = copy.deepcopy(current)
        current_v4["schemaVersion"] = 4
        current_v4.update(
            toolchainChanged=False,
            riskCodes=[],
            riskSurfaces={},
            observationRiskCodes=[],
        )
        self.assertIs(adapt_comparison_for_replay(current_v4), current_v4)
        legacy_ordered = copy.deepcopy(original)
        legacy_ordered["surfaces"][0]["carryForward"] = {
            "actual-runtime": {"eligible": True, "conditions": []},
            "shared-view": {"eligible": True, "conditions": []},
        }
        adapted_legacy_ordered = adapt_v1_comparison(legacy_ordered)
        self.assertEqual(
            list(adapted_legacy_ordered["surfaces"][0]["carryForward"]),
            ["actual-runtime", "shared-view"],
        )
        for unsupported_version in (1.0, 5):
            unsupported = copy.deepcopy(adapted)
            unsupported["schemaVersion"] = unsupported_version
            with self.assertRaisesRegex(ComparisonAdapterError, "schema is unsupported"):
                adapt_comparison_for_replay(unsupported)
        operation = adapter_v1_module.ADAPTER_CONTRACT["operation"]
        adapter_v1_module.ADAPTER_CONTRACT["operation"] = "tampered"
        try:
            with self.assertRaisesRegex(
                adapter_v1_module.ComparisonAdapterV1Error,
                "contract digest is invalid",
            ):
                adapt_v1_comparison(original)
        finally:
            adapter_v1_module.ADAPTER_CONTRACT["operation"] = operation
        validator = adapter_v1_module.comparison_schema.validate_comparison_v2
        adapter_v1_module.comparison_schema.validate_comparison_v2 = lambda comparison, **_: comparison
        try:
            with self.assertRaisesRegex(
                adapter_v1_module.ComparisonAdapterV1Error,
                "dependency digest is invalid",
            ):
                adapt_v1_comparison(original)
        finally:
            adapter_v1_module.comparison_schema.validate_comparison_v2 = validator
        constant_mutations = (
            ("COMPARISON_KIND", "tampered-kind"),
            ("CURRENT_COMPARISON_SCHEMA_VERSION", 3),
            ("EVIDENCE_CLASSES", (*adapter_v1_module.comparison_schema.EVIDENCE_CLASSES, "tampered")),
            ("TRAIN_NAMES", (*adapter_v1_module.comparison_schema.TRAIN_NAMES, "tampered")),
            ("ROOT_KEYS", adapter_v1_module.comparison_schema.ROOT_KEYS | {"tampered"}),
            ("SURFACE_KEYS", adapter_v1_module.comparison_schema.SURFACE_KEYS | {"tampered"}),
            ("CHANGE_KEYS", adapter_v1_module.comparison_schema.CHANGE_KEYS | {"tampered"}),
            ("CARRY_RULE_KEYS", adapter_v1_module.comparison_schema.CARRY_RULE_KEYS | {"tampered"}),
            ("REASON_CODES", (*adapter_v1_module.comparison_schema.REASON_CODES, "tampered")),
            (
                "PLACEMENT_CARRY_CONDITIONS",
                (*adapter_v1_module.comparison_schema.PLACEMENT_CARRY_CONDITIONS, "tampered"),
            ),
            ("SHA256_PATTERN", re.compile(r"^[0-9a-f]{63}$")),
            (
                "SHA256_PATTERN",
                re.compile(
                    adapter_v1_module.comparison_schema.SHA256_PATTERN.pattern,
                    re.IGNORECASE,
                ),
            ),
        )
        for name, mutated in constant_mutations:
            original_constant = getattr(adapter_v1_module.comparison_schema, name)
            setattr(adapter_v1_module.comparison_schema, name, mutated)
            try:
                self.assertNotEqual(
                    adapter_dependency_digest(),
                    adapter_v1_module.ADAPTER_DEPENDENCY_DIGEST,
                    name,
                )
            finally:
                setattr(adapter_v1_module.comparison_schema, name, original_constant)
        helper_replacements = (
            "_error",
            "_is_sha256",
            "_canonical_subset",
            "_expected_reason_codes",
            "validate_comparison_v2",
            "validate_legacy_v1_comparison_for_reconstruction",
        )
        for name in helper_replacements:
            original_helper = getattr(adapter_v1_module.comparison_schema, name)
            setattr(
                adapter_v1_module.comparison_schema,
                name,
                adapter_v1_module.comparison_schema.validate_current_comparison,
            )
            try:
                self.assertNotEqual(
                    adapter_dependency_digest(),
                    adapter_v1_module.ADAPTER_DEPENDENCY_DIGEST,
                    name,
                )
            finally:
                setattr(adapter_v1_module.comparison_schema, name, original_helper)
        original_error = adapter_v1_module.comparison_schema.ComparisonSchemaError
        adapter_v1_module.comparison_schema.ComparisonSchemaError = (
            adapter_v1_module.ComparisonAdapterV1Error
        )
        try:
            self.assertNotEqual(
                adapter_dependency_digest(),
                adapter_v1_module.ADAPTER_DEPENDENCY_DIGEST,
            )
        finally:
            adapter_v1_module.comparison_schema.ComparisonSchemaError = original_error
        raw["unexpected"] = True
        with self.assertRaises(ComparisonAdapterError):
            adapt_comparison_for_replay(raw)

    def test_replay_verifies_raw_lineage_before_adapter_conversion(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root)
            comparison_path = root / "archive/train/comparison.json"
            comparison = json.loads(comparison_path.read_text())
            comparison["unexpected"] = True
            self.write_json(comparison_path, comparison)
            with self.assertRaisesRegex(InventoryError, "lineage generation inputs diverge"):
                seal_inventory(policy, roots)

    def test_missing_required_file_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root)
            (root / "archive/train/comparison.json").unlink()
            with self.assertRaisesRegex(InventoryError, "archived-comparison"):
                seal_inventory(policy, roots)

    def test_manifest_linkage_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root)
            current_path = root / "archive/train/current.json"
            current = json.loads(current_path.read_text())
            current["manifestId"] = "f" * 64
            self.write_json(current_path, current)
            with self.assertRaisesRegex(
                InventoryError,
                "current source manifest|expected signed build manifest",
            ):
                seal_inventory(policy, roots)

    def test_ledger_tamper_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root)
            ledger_path = root / "archive/train/ledger.json"
            ledger = json.loads(ledger_path.read_text())
            ledger["state"] = "blocked"
            self.write_json(ledger_path, ledger)
            with self.assertRaisesRegex(InventoryError, "lineage ledger"):
                seal_inventory(policy, roots)

    def test_expected_build_reconstruction_accepts_v1_and_v2(self):
        current = {"manifestId": "1" * 64, "contractFingerprint": "2" * 64}
        train = {"version": "1.0.1", "buildNumber": "202608270001"}
        for schema_version in (1, 2):
            with self.subTest(schema_version=schema_version):
                identities = expected_surface_identities(
                    [self.expected_build_manifest("macos", current, schema_version=schema_version)],
                    train,
                    current,
                )
                self.assertEqual(sorted(identities), ["macos.app"])

    def test_expected_build_reconstruction_rejects_v2_tamper_and_missing_fields(self):
        current = {"manifestId": "1" * 64, "contractFingerprint": "2" * 64}
        train = {"version": "1.0.1", "buildNumber": "202608270001"}
        tampered = self.expected_build_manifest("macos", current, schema_version=2)
        tampered["artifacts"][0]["signingContractSha256"] = "f" * 64
        with self.assertRaisesRegex(InventoryError, "expected signed build manifest is invalid"):
            expected_surface_identities([tampered], train, current)

        missing = self.expected_build_manifest("macos", current, schema_version=2)
        missing["artifacts"][0].pop("architectures")
        missing.pop("expectedBuildId")
        missing["expectedBuildId"] = hash_parts(
            "context-panel-surface/v1/expected-build",
            [canonical_json(missing)],
        )
        with self.assertRaisesRegex(InventoryError, "expected signed build artifact is invalid"):
            expected_surface_identities([missing], train, current)

    def test_expected_build_identity_must_match_signed_ledger(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root, retain_receipt=True)
            policy = json.loads(policy_path.read_text())
            train = policy["trains"][0]
            manifest_path = (
                root
                / "archive/train"
                / train["expectedBuildManifests"]["macos"]
            )
            manifest = json.loads(manifest_path.read_text())
            manifest["artifacts"][0]["executableSha256"] = "f" * 64
            manifest.pop("expectedBuildId")
            manifest["expectedBuildId"] = hash_parts(
                "context-panel-surface/v1/expected-build",
                [canonical_json(manifest)],
            )
            self.write_json(manifest_path, manifest)
            lineage_path = root / "archive/train/lineage.json"
            lineage = json.loads(lineage_path.read_text())
            lineage["generation"]["expectedBuildManifests"] = [
                json.loads(
                    (
                        root
                        / "archive/train"
                        / train["expectedBuildManifests"][platform]
                    ).read_text()
                )
                for platform in ("ios", "macos", "tvos", "visionos")
            ]
            self.write_json(lineage_path, lineage)
            with self.assertRaisesRegex(InventoryError, "identity digest"):
                seal_inventory(policy_path, roots)

    def test_missing_receipt_bodies_are_reference_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            policy, roots = self.fixture(Path(temporary))
            inventory = seal_inventory(policy, roots)
            train = inventory["trains"][0]
            receipts = next(
                item for item in train["inputs"] if item["category"] == "physical-runtime-receipts"
            )
            self.assertEqual(receipts["recoverability"], "reference-only")
            self.assertEqual(receipts["referencedCount"], 1)
            self.assertEqual(receipts["retainedCount"], 0)
            self.assertEqual(train["state"], "complete-with-reference-only")

    def test_receipt_bodies_are_hashed_without_serializing_private_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            policy, roots = self.fixture(Path(temporary), retain_receipt=True)
            inventory = seal_inventory(policy, roots)
            encoded = render_json(inventory)
            self.assertNotIn(b"sessionID", encoded)
            self.assertNotIn(b"/Users/", encoded)
            receipts = next(
                item
                for item in inventory["trains"][0]["inputs"]
                if item["category"] == "physical-runtime-receipts"
            )
            self.assertEqual(receipts["retainedCount"], 1)
            self.assertEqual(receipts["recoverability"], "single-copy")

    def test_truncated_retained_receipt_body_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            receipt_path = next((root / "archive/train/receipts").glob("*.json"))
            receipt_id = json.loads(receipt_path.read_text())["id"]
            self.write_json(receipt_path, {"id": receipt_id})
            with self.assertRaisesRegex(InventoryError, "runtime receipt body"):
                seal_inventory(policy, roots)

    def test_retained_receipt_rejects_boolean_schema_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            receipt_path = next((root / "archive/train/receipts").glob("*.json"))
            receipt = json.loads(receipt_path.read_text())
            receipt["schemaVersion"] = True
            self.write_json(receipt_path, receipt)
            with self.assertRaisesRegex(InventoryError, "runtime receipt body"):
                seal_inventory(policy, roots)

    def test_retained_receipt_id_must_match_body(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            receipt_path = next((root / "archive/train/receipts").glob("*.json"))
            receipt = json.loads(receipt_path.read_text())
            receipt["outcome"] = "degraded"
            self.write_json(receipt_path, receipt)
            with self.assertRaisesRegex(InventoryError, "id does not match body"):
                seal_inventory(policy, roots)

    def test_retained_receipt_allows_runtime_clock_skew_window(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            skewed = self.receipt_payload(
                observed_at="2026-08-27T11:57:00Z",
                retention_expires_at="2026-08-28T11:57:00Z",
            )
            receipt_path = next((root / "archive/train/receipts").glob("*.json"))
            receipt_path.unlink()
            self.write_json(
                root / "archive/train/receipts" / f"{skewed['id']}.json",
                skewed,
            )
            self.rewrite_report_chain(
                root,
                lambda report: report["runtimeSurfaces"][0].update(
                    {"receiptIDs": [skewed["id"]]}
                ),
            )
            receipts = next(
                item
                for item in seal_inventory(policy, roots)["trains"][0]["inputs"]
                if item["category"] == "physical-runtime-receipts"
            )
            self.assertEqual(receipts["retainedCount"], 1)

    def test_retained_receipt_surface_must_match_final_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            receipt_path = next((root / "archive/train/receipts").glob("*.json"))
            receipt = json.loads(receipt_path.read_text())
            wrong_surface = self.receipt_payload("macos.widget")
            wrong_surface["id"] = receipt["id"]
            self.write_json(receipt_path, wrong_surface)
            with self.assertRaisesRegex(InventoryError, "surface does not match"):
                seal_inventory(policy, roots)

    def test_retained_receipt_platform_must_match_surface(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            self.replace_receipt(root, self.receipt_payload(platform="iOS"))
            with self.assertRaisesRegex(InventoryError, "platform does not match"):
                seal_inventory(policy, roots)

    def test_retained_receipt_session_and_ttl_are_bounded(self):
        cases = (
            (
                self.receipt_payload(
                    session_expires_at="2026-08-27T18:00:01Z",
                ),
                "session",
            ),
            (
                self.receipt_payload(
                    retention_expires_at="2026-09-03T12:05:01Z",
                ),
                "ttl-maximum",
            ),
        )
        for receipt, label in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, roots = self.fixture(root, retain_receipt=True)
                self.replace_receipt(root, receipt)
                with self.assertRaisesRegex(InventoryError, "timestamps"):
                    seal_inventory(policy, roots)

    def test_retained_receipt_ttl_must_match_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            self.replace_receipt(
                root,
                self.receipt_payload(
                    retention_expires_at="2026-08-29T12:05:00Z"
                ),
            )
            with self.assertRaisesRegex(InventoryError, "retained session"):
                seal_inventory(policy, roots)

    def test_retained_session_is_validated_without_receipt_bodies(self):
        cases = (
            ("schemaVersion", True, "runtime session is invalid"),
            ("minimumWriteIntervalSeconds", 301, "minimum write interval"),
            ("receiptTTLSeconds", 59, "receipt TTL"),
            ("maximumReceiptCount", 513, "maximum receipt count"),
            ("maximumReceiptCount", 128.0, "maximum receipt count"),
            ("expectedManifestID", "f" * 64, "runtime session is invalid"),
        )
        for field, value, error in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, roots = self.fixture(root, retain_receipt=True)
                for receipt_path in (root / "archive/train/receipts").glob("*.json"):
                    receipt_path.unlink()
                session_path = root / "archive/train/runtime-session.json"
                session = json.loads(session_path.read_text())
                session[field] = value
                self.write_json(session_path, session)
                with self.assertRaisesRegex(InventoryError, error):
                    seal_inventory(policy, roots)

    def test_retained_session_without_receipt_bodies_seals_and_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            for receipt_path in (root / "archive/train/receipts").glob("*.json"):
                receipt_path.unlink()
            inventory_path = root / "inventory.json"
            inventory = seal_inventory(policy, roots)
            receipts = next(
                item
                for item in inventory["trains"][0]["inputs"]
                if item["category"] == "physical-runtime-receipts"
            )
            self.assertEqual(receipts["retainedCount"], 0)
            self.assertEqual(receipts["recoverability"], "single-copy")
            self.assertEqual(receipts["sourceRoot"], "archive")
            write_inventory(inventory, inventory_path)
            check_inventory(policy, inventory_path)

    def test_retained_receipt_executable_uuids_must_be_canonical(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            self.replace_receipt(
                root,
                self.receipt_payload(
                    executable_uuids=["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]
                ),
            )
            with self.assertRaisesRegex(InventoryError, "executable UUIDs"):
                seal_inventory(policy, roots)

    def test_retained_receipt_allows_loaded_uuid_subset_for_multiarch_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root, retain_receipt=True)
            receipt = self.receipt_payload(
                executable_uuids=["BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"]
            )
            self.replace_receipt(root, receipt)

            receipts = next(
                item
                for item in seal_inventory(policy, roots)["trains"][0]["inputs"]
                if item["category"] == "physical-runtime-receipts"
            )

            self.assertEqual(receipts["retainedCount"], 1)

    def test_retained_receipt_build_must_match_train_manifest(self):
        cases = (
            ("manifest", self.receipt_payload(manifest_id="f" * 64)),
            ("marketing-version", self.receipt_payload(marketing_version="1.0.2")),
            ("build-number", self.receipt_payload(build_number="202608270002")),
            ("contract", self.receipt_payload(contract_fingerprint="f" * 64)),
        )
        for label, receipt in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, roots = self.fixture(root, retain_receipt=True)
                self.replace_receipt(root, receipt)
                with self.assertRaisesRegex(InventoryError, "build identity"):
                    seal_inventory(policy, roots)

    def test_retained_receipt_must_match_expected_surface_identity(self):
        cases = (
            ("artifact", self.receipt_payload(artifact_id="Other.app")),
            (
                "bundle",
                self.receipt_payload(bundle_identifier="com.shinycomputers.other"),
            ),
            (
                "fingerprints",
                self.receipt_payload(
                    fingerprints={**self.surface_fingerprints(), "render": "9" * 64}
                ),
            ),
            (
                "executable-uuids",
                self.receipt_payload(
                    executable_uuids=["CCCCCCCC-DDDD-EEEE-FFFF-000000000000"]
                ),
            ),
        )
        for label, receipt in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, roots = self.fixture(root, retain_receipt=True)
                self.replace_receipt(root, receipt)
                with self.assertRaisesRegex(InventoryError, "expected signed build surface"):
                    seal_inventory(policy, roots)

    def test_check_and_verify_reject_stale_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, roots = self.fixture(root)
            inventory_path = root / "inventory.json"
            write_inventory(seal_inventory(policy, roots), inventory_path)
            check_inventory(policy, inventory_path)
            verify_inventory(policy, inventory_path, roots)
            inventory = json.loads(inventory_path.read_text())
            inventory["summary"]["trainCount"] = 2
            self.write_json(inventory_path, inventory)
            with self.assertRaisesRegex(InventoryError, "self-digest"):
                check_inventory(policy, inventory_path)

    def test_check_rejects_policy_metadata_tamper_with_valid_self_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root)
            policy = json.loads(policy_path.read_text())
            policy["trains"][0]["notAdmissibleFor"] = [
                "rc-qualification",
                "release-qualification",
            ]
            self.write_json(policy_path, policy)
            inventory_path = root / "inventory.json"
            inventory = seal_inventory(policy_path, roots)
            inventory["trains"][0]["notAdmissibleFor"] = []
            self.write_mutated_inventory(inventory_path, inventory)
            with self.assertRaisesRegex(InventoryError, "notAdmissibleFor"):
                check_inventory(policy_path, inventory_path)

    def test_check_rejects_unknown_entry_field_with_valid_self_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root)
            inventory_path = root / "inventory.json"
            inventory = seal_inventory(policy_path, roots)
            inventory["trains"][0]["inputs"][0]["unexpected"] = "safe"
            self.write_mutated_inventory(inventory_path, inventory)
            with self.assertRaisesRegex(InventoryError, "invalid shape"):
                check_inventory(policy_path, inventory_path)

    def test_check_rejects_summary_tamper_with_valid_self_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root)
            inventory_path = root / "inventory.json"
            inventory = seal_inventory(policy_path, roots)
            inventory["summary"]["inputCount"] += 1
            self.write_mutated_inventory(inventory_path, inventory)
            with self.assertRaisesRegex(InventoryError, "summary is inconsistent"):
                check_inventory(policy_path, inventory_path)

    def test_check_rejects_state_and_risk_tamper_with_valid_self_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root)
            inventory_path = root / "inventory.json"
            inventory = seal_inventory(policy_path, roots)
            inventory["trains"][0]["residualRisks"] = []
            inventory["trains"][0]["state"] = "complete"
            inventory["summary"]["residualRiskCount"] = 0
            inventory["state"] = "complete"
            self.write_mutated_inventory(inventory_path, inventory)
            with self.assertRaisesRegex(InventoryError, "residual risks are inconsistent"):
                check_inventory(policy_path, inventory_path)

    def test_check_rejects_non_normalized_source_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root)
            inventory_path = root / "inventory.json"
            inventory = seal_inventory(policy_path, roots)
            inventory["trains"][0]["inputs"][0]["sourcePath"] = (
                "train//comparison.json"
            )
            self.write_mutated_inventory(inventory_path, inventory)
            with self.assertRaisesRegex(InventoryError, "source locator is invalid"):
                check_inventory(policy_path, inventory_path)

    def test_check_rejects_scope_tamper_with_valid_self_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root)
            inventory_path = root / "inventory.json"
            inventory = seal_inventory(policy_path, roots)
            inventory["trains"][0]["scope"]["actual-runtime"] = []
            self.write_mutated_inventory(inventory_path, inventory)
            with self.assertRaisesRegex(InventoryError, "sealed metadata"):
                check_inventory(policy_path, inventory_path)

    def test_check_rejects_manifest_identity_tamper_with_valid_self_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root)
            inventory_path = root / "inventory.json"
            inventory = seal_inventory(policy_path, roots)
            inventory["trains"][0]["currentManifestId"] = "f" * 64
            self.write_mutated_inventory(inventory_path, inventory)
            with self.assertRaisesRegex(InventoryError, "sealed metadata"):
                check_inventory(policy_path, inventory_path)

    def test_public_scan_rejects_private_dictionary_keys(self):
        with self.assertRaisesRegex(InventoryError, "private key"):
            scan_public({"secretCredential": "redacted"})

    def test_symlink_escape_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root)
            comparison = root / "archive/train/comparison.json"
            outside = root / "outside-comparison.json"
            comparison.replace(outside)
            comparison.symlink_to(outside)
            with self.assertRaisesRegex(InventoryError, "symlink"):
                seal_inventory(policy_path, roots)

    def test_receipts_outside_actual_runtime_scope_are_not_referenced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root, retain_receipt=True)
            extra_receipt = "f" * 64
            self.rewrite_report_chain(
                root,
                lambda report: report["runtimeSurfaces"].append(
                    {
                        "surface": "ios.app",
                        "state": "proven",
                        "receiptIDs": [extra_receipt],
                    }
                ),
            )
            inventory = seal_inventory(policy_path, roots)
            receipts = next(
                item
                for item in inventory["trains"][0]["inputs"]
                if item["category"] == "physical-runtime-receipts"
            )
            self.assertEqual(receipts["referencedCount"], 1)
            self.write_json(
                root / "archive/train/receipts" / f"{extra_receipt}.json",
                {"schemaVersion": 1, "id": extra_receipt},
            )
            with self.assertRaisesRegex(InventoryError, "outside the final report"):
                seal_inventory(policy_path, roots)

    def test_policy_rejects_absolute_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path, roots = self.fixture(root)
            policy = json.loads(policy_path.read_text())
            policy["trains"][0]["comparisonPath"] = "/Users/example/comparison.json"
            self.write_json(policy_path, policy)
            with self.assertRaisesRegex(InventoryError, "normalized relative path"):
                seal_inventory(policy_path, roots)

    def test_policy_rejects_non_normalized_paths(self):
        for path in ("nested//comparison.json", "nested/./comparison.json"):
            with self.subTest(path=path), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy_path, roots = self.fixture(root)
                policy = json.loads(policy_path.read_text())
                policy["trains"][0]["comparisonPath"] = path
                self.write_json(policy_path, policy)
                with self.assertRaisesRegex(InventoryError, "normalized relative path"):
                    seal_inventory(policy_path, roots)

    def test_committed_inventory_passes_offline_check(self):
        inventory_path = REPO_ROOT / "scripts/context_panel_replay/inventory/signed-trains.json"
        policy_path = REPO_ROOT / "Config/ContextPanelReplayInventoryPolicy.json"
        inventory = check_inventory(policy_path, inventory_path)
        self.assertEqual(inventory["summary"]["trainCount"], 3)
        self.assertEqual(inventory["summary"]["missingCount"], 0)
        self.assertEqual(inventory["state"], "complete-with-reference-only")


if __name__ == "__main__":
    unittest.main()
