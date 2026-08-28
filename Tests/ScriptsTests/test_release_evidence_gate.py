import hashlib
import json
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_release_gate import (
    ReleaseEvidenceError,
    build_release_evidence_lineage,
    evaluate_release_evidence,
    release_evidence_report_blockers,
)
from context_panel_validation import ExpectedSurfaceIdentity, RUNTIME_SURFACES
from context_panel_validation.runtime_evidence import canonical_json, hash_parts


NOW = datetime(2026, 8, 8, 12, 0, tzinfo=timezone.utc)
MANIFEST = "a" * 64
PREVIOUS_MANIFEST = "b" * 64
CONTRACT = "c" * 64


def sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def ledger_id(payload):
    encoded = json.dumps(
        {key: value for key, value in payload.items() if key != "ledgerID"},
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def expected_manifest(surface: str, *, manifest_id: str = MANIFEST):
    unsigned = {
        "schemaVersion": 1,
        "kind": "context-panel-expected-signed-build",
        "algorithm": "sha256",
        "digestDomain": "context-panel-surface/v1",
        "sourceManifestId": manifest_id,
        "contractFingerprint": CONTRACT,
        "layout": {},
        "archive": {},
        "source": {
            "marketingVersion": "1.0.54",
            "buildNumber": "202608080418",
        },
        "artifacts": [
            {
                "artifactId": surface,
                "bundleIdentifier": f"com.example.{surface}",
                "marketingVersion": "1.0.54",
                "buildNumber": "202608080418",
                "sourceCommit": "a" * 40,
                "configuration": "Release",
                "xcodeBuild": "17A1",
                "treeState": "clean",
                "codeSignatureValid": True,
                "executableSha256": sha(f"{surface}:executable"),
                "executableUUIDs": ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"],
                "entitlementsSha256": sha(f"{surface}:entitlements"),
                "profileSha256": sha(f"{surface}:profile"),
            }
        ],
        "surfaces": [
            {
                "id": surface,
                "artifactId": surface,
                "bundleIdentifier": f"com.example.{surface}",
                "fingerprints": {
                    "render": sha(f"{surface}:render"),
                    "runtime": sha(f"{surface}:runtime"),
                    "placement": sha(f"{surface}:placement"),
                    "combined": sha(f"{surface}:combined"),
                },
            }
        ],
    }
    return {
        **unsigned,
        "expectedBuildId": hash_parts(
            "context-panel-surface/v1/expected-build",
            [canonical_json(unsigned)],
        ),
    }


def all_expected_manifests(*, manifest_id: str = MANIFEST):
    return tuple(
        expected_manifest(surface, manifest_id=manifest_id)
        for surface in RUNTIME_SURFACES
    )


def identity(
    surface: str,
    *,
    manifest_id: str = MANIFEST,
) -> ExpectedSurfaceIdentity:
    platform = {
        "macos": "macOS",
        "ios": "iOS",
        "ipados": "iPadOS",
        "visionos": "visionOS",
        "watchos": "watchOS",
        "tvos": "tvOS",
    }[surface.split(".", 1)[0]]
    return ExpectedSurfaceIdentity(
        surface=surface,
        platform=platform,
        artifact_id=surface,
        bundle_identifier=f"com.example.{surface}",
        marketing_version="1.0.54",
        build_number="202608080418",
        manifest_id=manifest_id,
        contract_fingerprint=CONTRACT,
        render_fingerprint=sha(f"{surface}:render"),
        runtime_fingerprint=sha(f"{surface}:runtime"),
        placement_fingerprint=sha(f"{surface}:placement"),
        combined_fingerprint=sha(f"{surface}:combined"),
        executable_uuids=("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",),
        expected_build_id=str(
            expected_manifest(surface, manifest_id=manifest_id)["expectedBuildId"]
        ),
    )


def all_identities(
    *,
    manifest_id: str = MANIFEST,
) -> tuple[ExpectedSurfaceIdentity, ...]:
    return tuple(identity(surface, manifest_id=manifest_id) for surface in RUNTIME_SURFACES)


def expected_identity_set_digest(*identities: ExpectedSurfaceIdentity) -> str:
    payload = [
        {
            "surface": item.surface,
            "manifestID": item.manifest_id,
            "contractFingerprint": item.contract_fingerprint,
            "expectedBuildID": item.expected_build_id,
            "identityDigest": item.identity_digest(),
            "renderFingerprint": item.render_fingerprint,
            "runtimeFingerprint": item.runtime_fingerprint,
            "placementFingerprint": item.placement_fingerprint,
        }
        for item in sorted(identities, key=lambda value: value.surface)
    ]
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def policy(*, patch_sensitive=()):
    return {
        "schemaVersion": 1,
        "maximumEvidenceAgeDays": 90,
        "requiredShadowTrainCount": 2,
        "hostOSCompatibility": {
            "invalidateMajorMinorChanges": True,
            "patchSensitiveSurfaces": list(patch_sensitive),
        },
    }


def surface_policy(surface: str, evidence_class: str):
    selected_evidence = (
        ["actual-runtime", "os-composited-placement"]
        if evidence_class == "os-composited-placement"
        else [evidence_class]
    )
    return {
        "schemaVersion": 1,
        "evidencePolicy": {
            "classes": [
                "shared-view",
                "actual-runtime",
                "os-composited-placement",
            ],
            "trainMinimumEvidence": {
                train: selected_evidence
                for train in ("beta", "rc", "release")
            },
            "changeRequirements": {
                "render": ["shared-view"],
                "runtime": ["actual-runtime"],
                "unknown": [
                    "shared-view",
                    "actual-runtime",
                    "os-composited-placement",
                ],
                "placement": ["actual-runtime", "os-composited-placement"],
            },
            "releaseRequiresApprovedRCTarget": True,
        },
        "surfaces": [
            {
                "id": surface_id,
                "artifactId": surface_id,
                "evidenceCapabilities": (
                    selected_evidence if surface_id == surface else []
                ),
            }
            for surface_id in RUNTIME_SURFACES
        ],
    }


def comparison(
    surface: str,
    evidence_class: str,
    *,
    eligible=False,
    train="beta",
    previous_manifest_id=PREVIOUS_MANIFEST,
    current_manifest_id=MANIFEST,
):
    selected_evidence = (
        ["actual-runtime", "os-composited-placement"]
        if evidence_class == "os-composited-placement"
        else [evidence_class]
    )
    required = {
        "shared-view": [],
        "actual-runtime": [],
        "os-composited-placement": [],
    }
    for selected_class in selected_evidence:
        required[selected_class] = [surface]

    def changes_for(surface_id: str) -> dict[str, bool]:
        return {
            "render": surface_id == surface and evidence_class == "shared-view" and not eligible,
            "runtime": surface_id == surface and evidence_class == "actual-runtime" and not eligible,
            "placement": (
                surface_id == surface
                and evidence_class == "os-composited-placement"
                and not eligible
            ),
            "contract": False,
            "exactBuild": evidence_class == "actual-runtime" and not eligible,
        }

    def reason_codes_for(changes: dict[str, bool]) -> list[str]:
        reason_codes = [
            reason_code
            for change_key, reason_code in (
                ("render", "render-fingerprint-changed"),
                ("runtime", "runtime-fingerprint-changed"),
                ("placement", "placement-fingerprint-changed"),
                ("contract", "contract-fingerprint-changed"),
                ("exactBuild", "exact-build-changed"),
            )
            if changes[change_key]
        ]
        return reason_codes or ["unchanged"]

    def carry_forward_for(surface_id: str) -> dict[str, dict[str, object]]:
        if surface_id != surface:
            return {}
        result: dict[str, dict[str, object]] = {}
        for selected_class in selected_evidence:
            is_fresh = not eligible
            carry_eligible = eligible
            conditions = (
                ["matching-host-os", "matching-current-runtime-receipt"]
                if selected_class == "os-composited-placement" and carry_eligible
                else []
            )
            result[selected_class] = {
                "eligible": carry_eligible and not is_fresh,
                "conditions": conditions if not is_fresh else [],
            }
        return result

    return {
        "kind": "context-panel-surface-comparison",
        "schemaVersion": 2,
        "train": train,
        "previousManifestId": previous_manifest_id,
        "currentManifestId": current_manifest_id,
        "contractChanged": False,
        "exactBuildSame": not (evidence_class == "actual-runtime" and not eligible),
        "removedSurfaces": [],
        "requiredSurfaces": required,
        "requiresRuntimeSession": bool(required["actual-runtime"]),
        "requiresPlacementReview": bool(required["os-composited-placement"]),
        "surfaces": [
            {
                "surfaceId": surface_id,
                "artifactId": surface_id,
                "reasonCodes": reason_codes_for(changes_for(surface_id)),
                "changes": changes_for(surface_id),
                "minimumEvidence": selected_evidence if surface_id == surface else [],
                "freshEvidence": selected_evidence if surface_id == surface and not eligible else [],
                "requiredEvidence": selected_evidence if surface_id == surface else [],
                "carryForward": carry_forward_for(surface_id),
            }
            for surface_id in RUNTIME_SURFACES
        ],
        "releaseRequiresApprovedRCTarget": True,
    }


def report(
    surface: str,
    *,
    runtime=False,
    visual_class=None,
    host_os=None,
    manifest_id=MANIFEST,
):
    requirements = []
    if visual_class is not None:
        requirements.append(
            {
                "id": f"{surface}.review",
                "evidenceClass": visual_class,
                "surface": surface,
                "device": "Apple Watch",
                "manifestID": manifest_id,
                "expectedBuildID": identity(
                    surface,
                    manifest_id=manifest_id,
                ).expected_build_id,
                "contractFingerprint": CONTRACT,
                "identityDigest": identity(surface, manifest_id=manifest_id).identity_digest(),
                "state": "approved",
                "reason": "review-approved",
                "hostOS": host_os,
                "renderFingerprint": sha(f"{surface}:render"),
                "placementFingerprint": (
                    sha(f"{surface}:placement")
                    if visual_class == "os-composited-placement"
                    else None
                ),
                "decision": {
                    "id": sha(f"{surface}:decision"),
                    "sequence": 1,
                    "value": "approved",
                    "observedAt": "2026-08-08T11:55:00Z",
                    "artifactDigest": None,
                    "runtimeReceiptID": (
                        sha(f"{surface}:runtime-receipt")
                        if visual_class == "os-composited-placement"
                        else None
                    ),
                    "supersedesDecisionID": None,
                },
            }
        )
    return {
        "schemaVersion": 1,
        "target": {"version": "1.0.54", "buildNumber": "202608080418"},
        "summary": {"state": "complete_for_slice", "exitCode": 0},
        "session": {
            "requestedSurfaces": [surface],
            "updatedAt": "2026-08-08T11:59:00Z",
        },
        "runtimeSurfaces": [
            {
                "surface": surface,
                "state": "proven" if runtime else "unknown",
                "reason": "exact-build-runtime-receipt" if runtime else "not-collected",
                "manifestID": manifest_id,
                "expectedBuildID": identity(
                    surface,
                    manifest_id=manifest_id,
                ).expected_build_id,
                "identityDigest": identity(surface, manifest_id=manifest_id).identity_digest(),
                "runtimeFingerprint": sha(f"{surface}:runtime"),
                "observedAt": "2026-08-08T11:54:00Z" if runtime else None,
                "receiptIDs": [sha(f"{surface}:runtime-receipt")] if runtime else [],
            }
        ],
        "visualApprovals": {
            "state": "approved" if requirements else "not-evaluated-by-coordinator",
            "requirements": requirements,
        },
        "blockers": [],
    }


def ledger(
    surface: str,
    evidence_class: str,
    expected: ExpectedSurfaceIdentity,
    *,
    host_os=None,
    policy_payload=None,
    surface_policy_payload=None,
):
    state = "proven" if evidence_class == "actual-runtime" else "approved"
    payload = {
        "schemaVersion": 1,
        "kind": "context-panel-release-evidence",
        "mode": "shadow",
        "train": "beta",
        "state": "approved",
        "target": {"version": "1.0.53", "buildNumber": "1"},
        "previousManifestID": "d" * 64,
        "currentManifestID": PREVIOUS_MANIFEST,
        "contractFingerprint": CONTRACT,
        "comparisonDigest": sha("previous-comparison"),
        "surfacePolicyDigest": hashlib.sha256(
            json.dumps(
                surface_policy_payload or surface_policy(surface, evidence_class),
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest(),
        "policyDigest": hashlib.sha256(
            json.dumps(
                policy_payload or policy(),
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest(),
        "expectedBuildIdentityDigest": sha("previous-expected-build-identities"),
        "validationReportDigest": sha("previous-validation-report"),
        "generatedAt": "2026-08-01T00:00:00Z",
        "expiresAt": "2026-08-20T00:00:00Z",
        "requiredEvidence": {
            name: [surface] if name == evidence_class else []
            for name in (
                "shared-view",
                "actual-runtime",
                "os-composited-placement",
            )
        },
        "surfaces": [
            {
                "surface": surface,
                "identityDigest": sha("previous-identity"),
                "evidence": {
                    evidence_class: {
                        "state": state,
                        "source": "fresh",
                        "fingerprint": (
                            expected.render_fingerprint
                            if evidence_class == "shared-view"
                            else expected.runtime_fingerprint
                            if evidence_class == "actual-runtime"
                            else expected.placement_fingerprint
                        ),
                        "observedAt": "2026-08-01T00:00:00Z",
                        "decisionIDs": (
                            []
                            if evidence_class == "actual-runtime"
                            else [sha(f"{surface}:previous-decision")]
                        ),
                        "hostOS": host_os,
                        "runtimeReceiptIDs": (
                            []
                            if evidence_class == "shared-view"
                            else [sha(f"{surface}:previous-runtime-receipt")]
                        ),
                    }
                },
            }
        ],
        "shadow": {
            "state": "passed",
            "requiredTrainCount": 2,
            "observedTrainCount": 2,
            "qualifiedTrainCount": 2,
            "disagreements": [],
            "blockers": [],
        },
        "blockers": [],
        "privacy": "context-panel-release-evidence-public-v1",
    }
    payload["ledgerID"] = ledger_id(payload)
    return payload


def host_evidence(surface: str, host_os: str, *, observed_at="2026-08-08T11:59:00Z"):
    return {
        "schemaVersion": 1,
        "kind": "context-panel-host-os-evidence",
        "target": {"version": "1.0.54", "buildNumber": "202608080418"},
        "currentManifestID": MANIFEST,
        "observedAt": observed_at,
        "surfaces": {
            surface: {
                "hostOS": host_os,
                "runtimeReceiptID": sha(f"{surface}:runtime-receipt"),
            }
        },
    }


def shadow_evidence(
    *,
    duplicate=False,
    runbook_state="approved",
    ledger_state="approved",
    disagreements=None,
    surface="watchos.app",
    evidence_class="actual-runtime",
    policy_payload=None,
):
    release_policy = policy_payload or policy()
    runs = []
    for index in range(2):
        train = "beta" if duplicate or index == 0 else "rc"
        embedded_ledger = None
        generation = None
        if ledger_state == "approved":
            validation_report = report(
                surface,
                runtime=evidence_class != "shared-view",
                visual_class=(
                    evidence_class
                    if evidence_class != "actual-runtime"
                    else None
                ),
                host_os=(
                    "watchOS 27.0"
                    if evidence_class == "os-composited-placement"
                    else None
                ),
            )
            comparison_payload = comparison(
                surface,
                evidence_class,
                train=train,
            )
            identities = all_identities()
            embedded_ledger = evaluate_release_evidence(
                train=train,
                mode="shadow",
                comparison=comparison_payload,
                validation_report=validation_report,
                identities=identities,
                policy=release_policy,
                surface_policy=surface_policy(surface, evidence_class),
                now=NOW,
            )
            generation = {
                "comparison": comparison_payload,
                "validationReport": validation_report,
                "expectedBuildManifests": list(all_expected_manifests()),
                "previousLedger": None,
                "selectedRCLedger": None,
                "hostOSEvidence": None,
                "shadowEvidence": None,
            }
        runs.append(
            {
                "train": train,
                "target": (
                    embedded_ledger["target"]
                    if embedded_ledger is not None
                    else {"version": "1.0.54", "buildNumber": "202608080418"}
                ),
                "manifestID": (
                    embedded_ledger["currentManifestID"]
                    if embedded_ledger is not None
                    else MANIFEST
                ),
                "expectedBuildIdentityDigest": (
                    embedded_ledger["expectedBuildIdentityDigest"]
                    if embedded_ledger is not None
                    else expected_identity_set_digest(*all_identities())
                ),
                "ledgerID": (
                    embedded_ledger["ledgerID"]
                    if embedded_ledger is not None
                    else sha(f"blocked-shadow-ledger-{index}")
                ),
                "observedAt": "2026-08-08T12:00:00Z",
                "runbookState": runbook_state,
                "ledgerState": ledger_state,
                "disagreements": list(disagreements or []),
                "ledger": embedded_ledger,
                "generation": generation,
            }
        )
    return {
        "schemaVersion": 1,
        "kind": "context-panel-shadow-comparison",
        "runs": runs,
    }


def previous_lineage(
    surface: str,
    evidence_class: str,
    *,
    host_os=None,
    policy_payload=None,
    legacy_comparison=False,
):
    release_policy = policy_payload or policy()
    comparison_payload = comparison(
        surface,
        evidence_class,
        train="beta",
        previous_manifest_id="d" * 64,
        current_manifest_id=PREVIOUS_MANIFEST,
    )
    if legacy_comparison:
        comparison_payload.pop("kind")
        comparison_payload["schemaVersion"] = 1
    validation_report = report(
        surface,
        runtime=evidence_class != "shared-view",
        visual_class=(
            evidence_class if evidence_class != "actual-runtime" else None
        ),
        host_os=host_os,
        manifest_id=PREVIOUS_MANIFEST,
    )
    identities = all_identities(manifest_id=PREVIOUS_MANIFEST)
    expected_manifests = all_expected_manifests(manifest_id=PREVIOUS_MANIFEST)
    shadow_payload = shadow_evidence(
        surface=surface,
        evidence_class=evidence_class,
        policy_payload=release_policy,
    )
    payload = evaluate_release_evidence(
        train="beta",
        mode="enforce",
        comparison=comparison_payload,
        validation_report=validation_report,
        identities=identities,
        policy=release_policy,
        surface_policy=surface_policy(surface, evidence_class),
        shadow_evidence=shadow_payload,
        now=NOW,
        _allow_legacy_comparison=legacy_comparison,
    )
    return build_release_evidence_lineage(
        payload,
        comparison=comparison_payload,
        validation_report=validation_report,
        expected_build_manifests=expected_manifests,
        shadow_evidence=shadow_payload,
    )


def selected_rc_ledger(surface: str):
    comparison_payload = comparison(surface, "actual-runtime", train="rc")
    validation_report = report(surface, runtime=True)
    identities = all_identities()
    expected_manifests = all_expected_manifests()
    shadow_payload = shadow_evidence()
    payload = evaluate_release_evidence(
        train="rc",
        mode="enforce",
        comparison=comparison_payload,
        validation_report=validation_report,
        identities=identities,
        policy=policy(),
        surface_policy=surface_policy(surface, "actual-runtime"),
        shadow_evidence=shadow_payload,
        now=NOW,
    )
    return build_release_evidence_lineage(
        payload,
        comparison=comparison_payload,
        validation_report=validation_report,
        expected_build_manifests=expected_manifests,
        shadow_evidence=shadow_payload,
    )


class ReleaseEvidenceGateTests(unittest.TestCase):
    def evaluate(self, surface, evidence_class, **kwargs):
        expected = identity(surface)
        return evaluate_release_evidence(
            train=kwargs.pop("train", "beta"),
            mode=kwargs.pop("mode", "shadow"),
            comparison=kwargs.pop(
                "comparison_payload",
                comparison(surface, evidence_class, eligible=kwargs.pop("eligible", False)),
            ),
            validation_report=kwargs.pop("validation_report", report(surface)),
            identities=all_identities(),
            policy=kwargs.pop("policy_payload", policy()),
            surface_policy=kwargs.pop(
                "surface_policy_payload",
                surface_policy(surface, evidence_class),
            ),
            now=kwargs.pop("now", NOW),
            **kwargs,
        )

    def report_blockers(
        self,
        payload,
        surface,
        evidence_class,
        *,
        enforce,
        validation_report=None,
        comparison_payload=None,
        policy_payload=None,
    ):
        return release_evidence_report_blockers(
            payload,
            version="1.0.54",
            build_number="202608080418",
            train="beta",
            enforce=enforce,
            validation_report=validation_report or report(surface),
            comparison=comparison_payload or comparison(surface, evidence_class),
            identities=all_identities(),
            policy=policy_payload or policy(),
            surface_policy=surface_policy(surface, evidence_class),
            now=NOW,
        )

    def test_fresh_shared_view_is_approved_in_shadow_mode(self):
        surface = "watchos.app"
        payload = self.evaluate(
            surface,
            "shared-view",
            validation_report=report(surface, visual_class="shared-view"),
        )
        self.assertEqual(payload["state"], "shadow-approved")
        self.assertEqual(
            payload["surfaces"][0]["evidence"]["shared-view"]["source"],
            "fresh",
        )

    def test_missing_runtime_blocks(self):
        payload = self.evaluate("watchos.app", "actual-runtime")
        self.assertEqual(payload["state"], "blocked")
        self.assertEqual(payload["blockers"], ["watchos.app:actual-runtime:missing"])

    def test_shared_view_carries_forward_only_with_matching_fingerprint(self):
        surface = "watchos.app"
        payload = self.evaluate(
            surface,
            "shared-view",
            eligible=True,
            previous_ledger=previous_lineage(surface, "shared-view"),
        )
        evidence = payload["surfaces"][0]["evidence"]["shared-view"]
        self.assertEqual(evidence["source"], "carry-forward")

    def test_placement_carry_forward_requires_current_runtime_and_host_os(self):
        surface = "watchos.complication"
        host = host_evidence(surface, "watchOS 27.0")
        payload = self.evaluate(
            surface,
            "os-composited-placement",
            eligible=True,
            validation_report=report(surface, runtime=True),
            previous_ledger=previous_lineage(
                surface,
                "os-composited-placement",
                host_os="watchOS 27.0",
            ),
            host_os_evidence=host,
        )
        evidence = payload["surfaces"][0]["evidence"]["os-composited-placement"]
        self.assertEqual(evidence["source"], "carry-forward")

    def test_major_minor_host_os_change_invalidates_placement(self):
        surface = "watchos.complication"
        host = host_evidence(surface, "watchOS 28.0")
        payload = self.evaluate(
            surface,
            "os-composited-placement",
            eligible=True,
            validation_report=report(surface, runtime=True),
            previous_ledger=previous_lineage(
                surface,
                "os-composited-placement",
                host_os="watchOS 27.0",
            ),
            host_os_evidence=host,
        )
        self.assertEqual(payload["state"], "blocked")

    def test_patch_sensitive_surface_invalidates_patch_change(self):
        surface = "watchos.complication"
        patch_policy = policy(patch_sensitive=(surface,))
        host = host_evidence(surface, "watchOS 27.0.1")
        payload = self.evaluate(
            surface,
            "os-composited-placement",
            eligible=True,
            validation_report=report(surface, runtime=True),
            previous_ledger=previous_lineage(
                surface,
                "os-composited-placement",
                host_os="watchOS 27.0.0",
                policy_payload=patch_policy,
            ),
            host_os_evidence=host,
            policy_payload=patch_policy,
        )
        self.assertEqual(payload["state"], "blocked")

    def test_expired_previous_ledger_fails_closed(self):
        surface = "watchos.app"
        short_policy = policy()
        short_policy["maximumEvidenceAgeDays"] = 1
        previous = previous_lineage(
            surface,
            "shared-view",
            policy_payload=short_policy,
        )
        with self.assertRaisesRegex(ReleaseEvidenceError, "expired"):
            self.evaluate(
                surface,
                "shared-view",
                eligible=True,
                previous_ledger=previous,
                policy_payload=short_policy,
                now=NOW + timedelta(days=2),
            )

    def test_release_requires_exact_selected_rc(self):
        surface = "watchos.app"
        release_comparison = comparison(surface, "actual-runtime", train="release")
        with self.assertRaisesRegex(ReleaseEvidenceError, "selected exact approved RC"):
            self.evaluate(
                surface,
                "actual-runtime",
                train="release",
                mode="enforce",
                comparison_payload=release_comparison,
                validation_report=report(surface, runtime=True),
                shadow_evidence=shadow_evidence(),
            )

    def test_release_reuses_exact_enforced_selected_rc(self):
        surface = "watchos.app"
        selected_rc = selected_rc_ledger(surface)
        payload = self.evaluate(
            surface,
            "actual-runtime",
            train="release",
            comparison_payload=comparison(surface, "actual-runtime", train="release"),
            selected_rc_ledger=selected_rc,
        )
        evidence = payload["surfaces"][0]["evidence"]["actual-runtime"]
        self.assertEqual(evidence["source"], "selected-rc")

    def test_tampered_ledger_identity_fails_closed(self):
        surface = "watchos.app"
        previous = previous_lineage(surface, "shared-view")
        previous["ledger"]["surfaces"][0]["evidence"]["shared-view"][
            "fingerprint"
        ] = "f" * 64
        previous["ledger"]["ledgerID"] = ledger_id(previous["ledger"])
        with self.assertRaisesRegex(ReleaseEvidenceError, "generation context"):
            self.evaluate(
                surface,
                "shared-view",
                eligible=True,
                previous_ledger=previous,
            )

    def test_enforcement_requires_two_resolved_shadow_runs(self):
        surface = "watchos.app"
        payload = self.evaluate(
            surface,
            "actual-runtime",
            mode="enforce",
            validation_report=report(surface, runtime=True),
        )
        self.assertEqual(payload["state"], "blocked")
        self.assertIn("shadow-comparison:pending", payload["blockers"])

    def test_comparison_required_surfaces_cannot_omit_surface_requirements(self):
        surface = "watchos.app"
        comparison_payload = comparison(surface, "shared-view")
        comparison_payload["requiredSurfaces"]["shared-view"] = []
        with self.assertRaisesRegex(ReleaseEvidenceError, "surface comparison is invalid"):
            self.evaluate(
                surface,
                "shared-view",
                comparison_payload=comparison_payload,
            )

    def test_release_gate_rejects_legacy_v1_comparison(self):
        surface = "watchos.app"
        comparison_payload = comparison(surface, "shared-view")
        comparison_payload.pop("kind")
        comparison_payload["schemaVersion"] = 1
        with self.assertRaisesRegex(ReleaseEvidenceError, "surface comparison is invalid"):
            self.evaluate(
                surface,
                "shared-view",
                comparison_payload=comparison_payload,
            )

    def test_signed_lineage_reconstruction_preserves_legacy_v1_comparison_digest(self):
        surface = "watchos.app"
        previous = previous_lineage(
            surface,
            "shared-view",
            legacy_comparison=True,
        )
        raw_comparison = previous["generation"]["comparison"]
        self.assertEqual(
            previous["ledger"]["comparisonDigest"],
            hashlib.sha256(
                json.dumps(
                    raw_comparison,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8")
            ).hexdigest(),
        )
        payload = self.evaluate(
            surface,
            "shared-view",
            eligible=True,
            previous_ledger=previous,
        )
        self.assertNotIn("previous-ledger", " ".join(payload["blockers"]))

    def test_release_rc_requirement_cannot_be_removed(self):
        surface = "watchos.app"
        comparison_payload = comparison(surface, "actual-runtime", train="release")
        comparison_payload.pop("releaseRequiresApprovedRCTarget")
        with self.assertRaisesRegex(ReleaseEvidenceError, "surface comparison is invalid"):
            self.evaluate(
                surface,
                "actual-runtime",
                train="release",
                comparison_payload=comparison_payload,
                validation_report=report(surface, runtime=True),
            )

    def test_release_rc_requirement_cannot_be_disabled(self):
        surface = "watchos.app"
        comparison_payload = comparison(surface, "actual-runtime", train="release")
        comparison_payload["releaseRequiresApprovedRCTarget"] = False
        with self.assertRaisesRegex(ReleaseEvidenceError, "release RC requirement"):
            self.evaluate(
                surface,
                "actual-runtime",
                train="release",
                comparison_payload=comparison_payload,
                validation_report=report(surface, runtime=True),
            )

    def test_comparison_artifact_must_match_policy_and_expected_identity(self):
        surface = "watchos.app"
        comparison_payload = comparison(surface, "actual-runtime")
        target = next(
            item for item in comparison_payload["surfaces"] if item["surfaceId"] == surface
        )
        target["artifactId"] = "wrong-artifact"
        with self.assertRaisesRegex(ReleaseEvidenceError, "artifact does not match policy"):
            self.evaluate(
                surface,
                "actual-runtime",
                comparison_payload=comparison_payload,
                validation_report=report(surface, runtime=True),
            )

        identities = list(all_identities())
        index = next(index for index, item in enumerate(identities) if item.surface == surface)
        original = identities[index]
        identities[index] = ExpectedSurfaceIdentity(
            **{**original.__dict__, "artifact_id": "wrong-artifact"}
        )
        with self.assertRaisesRegex(ReleaseEvidenceError, "signed-build artifact"):
            evaluate_release_evidence(
                train="beta",
                mode="shadow",
                comparison=comparison(surface, "actual-runtime"),
                validation_report=report(surface, runtime=True),
                identities=tuple(identities),
                policy=policy(),
                surface_policy=surface_policy(surface, "actual-runtime"),
                now=NOW,
            )

    def test_carry_forward_does_not_renew_source_expiry(self):
        surface = "watchos.app"
        short_policy = policy()
        short_policy["maximumEvidenceAgeDays"] = 1
        previous = previous_lineage(
            surface,
            "shared-view",
            policy_payload=short_policy,
        )
        payload = self.evaluate(
            surface,
            "shared-view",
            eligible=True,
            previous_ledger=previous,
            policy_payload=short_policy,
            now=NOW + timedelta(hours=12),
        )
        self.assertEqual(payload["expiresAt"], "2026-08-09T12:00:00Z")

    def test_blocked_validation_report_fails_closed(self):
        surface = "watchos.app"
        validation_report = report(surface, runtime=True)
        validation_report["summary"]["exitCode"] = 30
        validation_report["blockers"] = ["coordinator-state-blocked"]
        with self.assertRaisesRegex(ReleaseEvidenceError, "blocked"):
            self.evaluate(
                surface,
                "actual-runtime",
                validation_report=validation_report,
            )

    def test_rejected_visual_decision_is_not_fresh_evidence(self):
        surface = "watchos.app"
        validation_report = report(surface, visual_class="shared-view")
        validation_report["visualApprovals"]["requirements"][0]["decision"]["value"] = "rejected"
        payload = self.evaluate(
            surface,
            "shared-view",
            validation_report=validation_report,
        )
        self.assertEqual(payload["state"], "blocked")

    def test_future_host_os_observation_fails_closed(self):
        surface = "watchos.complication"
        with self.assertRaisesRegex(ReleaseEvidenceError, "host OS evidence is invalid"):
            self.evaluate(
                surface,
                "os-composited-placement",
                eligible=True,
                validation_report=report(surface, runtime=True),
                previous_ledger=previous_lineage(
                    surface,
                    "os-composited-placement",
                    host_os="watchOS 27.0",
                ),
                host_os_evidence=host_evidence(
                    surface,
                    "watchOS 27.0",
                    observed_at="2099-01-01T00:00:00Z",
                ),
            )

    def test_duplicate_shadow_train_fails_closed(self):
        surface = "watchos.app"
        with self.assertRaisesRegex(ReleaseEvidenceError, "duplicates a signed train"):
            self.evaluate(
                surface,
                "actual-runtime",
                mode="enforce",
                validation_report=report(surface, runtime=True),
                shadow_evidence=shadow_evidence(duplicate=True),
            )

    def test_shadow_state_mismatch_blocks_qualification(self):
        surface = "watchos.app"
        payload = self.evaluate(
            surface,
            "actual-runtime",
            mode="enforce",
            validation_report=report(surface, runtime=True),
            shadow_evidence=shadow_evidence(ledger_state="blocked"),
        )
        self.assertEqual(payload["shadow"]["state"], "pending")
        self.assertIn("runbook-ledger-state-mismatch", payload["shadow"]["blockers"])

    def test_blocked_shadow_runs_never_qualify(self):
        surface = "watchos.app"
        payload = self.evaluate(
            surface,
            "actual-runtime",
            mode="enforce",
            validation_report=report(surface, runtime=True),
            shadow_evidence=shadow_evidence(
                runbook_state="blocked",
                ledger_state="blocked",
            ),
        )
        self.assertEqual(payload["shadow"]["state"], "pending")
        self.assertEqual(payload["shadow"]["qualifiedTrainCount"], 0)
        self.assertIn("shadow-run-not-approved", payload["shadow"]["blockers"])
        self.assertEqual(payload["state"], "blocked")

    def test_unresolved_and_runbook_correct_disagreements_block_qualification(self):
        surface = "watchos.app"
        for classification in ("unresolved", "runbook-correct"):
            with self.subTest(classification=classification):
                payload = self.evaluate(
                    surface,
                    "actual-runtime",
                    mode="enforce",
                    validation_report=report(surface, runtime=True),
                    shadow_evidence=shadow_evidence(
                        disagreements=[
                            {
                                "surface": surface,
                                "evidenceClass": "actual-runtime",
                                "classification": classification,
                                "resolution": "pending-reverification",
                            }
                        ]
                    ),
                )
                self.assertEqual(payload["shadow"]["state"], "pending")
                self.assertIn(
                    "shadow-disagreement-not-ledger-safe",
                    payload["shadow"]["blockers"],
                )

    def test_runtime_carry_forward_requires_exact_current_build_identity(self):
        surface = "watchos.app"
        payload = self.evaluate(
            surface,
            "actual-runtime",
            eligible=True,
            previous_ledger=previous_lineage(surface, "actual-runtime"),
        )
        self.assertEqual(payload["state"], "blocked")
        self.assertEqual(
            payload["surfaces"][0]["evidence"]["actual-runtime"]["source"],
            "none",
        )

    def test_runtime_evidence_requires_current_receipts(self):
        surface = "watchos.app"
        validation_report = report(surface, runtime=True)
        validation_report["runtimeSurfaces"][0]["receiptIDs"] = []
        payload = self.evaluate(
            surface,
            "actual-runtime",
            validation_report=validation_report,
        )
        self.assertEqual(payload["state"], "blocked")

    def test_runtime_evidence_rejects_stale_observation(self):
        surface = "watchos.app"
        tightened_policy = policy()
        tightened_policy["maximumEvidenceAgeDays"] = 7
        payload = evaluate_release_evidence(
            train="beta",
            mode="shadow",
            comparison=comparison(surface, "actual-runtime"),
            validation_report=report(surface, runtime=True),
            identities=all_identities(),
            policy=tightened_policy,
            surface_policy=surface_policy(surface, "actual-runtime"),
            now=NOW + timedelta(days=8),
        )
        self.assertEqual(payload["state"], "blocked")
        self.assertIn("watchos.app:actual-runtime:missing", payload["blockers"])

    def test_wrong_build_runtime_cannot_unlock_carry_forward(self):
        surface = "watchos.app"
        previous = previous_lineage(surface, "actual-runtime")
        validation_report = report(surface, runtime=True)
        validation_report["runtimeSurfaces"][0]["expectedBuildID"] = "f" * 64
        payload = self.evaluate(
            surface,
            "actual-runtime",
            eligible=True,
            validation_report=validation_report,
            previous_ledger=previous,
        )
        self.assertEqual(payload["state"], "blocked")

    def test_selected_rc_mismatches_fail_closed(self):
        surface = "watchos.app"
        mutations = {
            "target": lambda value: value["target"].update(buildNumber="different"),
            "train": lambda value: value.update(train="beta"),
            "mode": lambda value: value.update(mode="shadow"),
            "shadow": lambda value: value["shadow"].update(
                state="pending",
                qualifiedTrainCount=0,
                blockers=["insufficient-shadow-trains"],
            ),
            "identity": lambda value: value.update(expectedBuildIdentityDigest="f" * 64),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                selected = selected_rc_ledger(surface)
                mutate(selected["ledger"])
                selected["ledger"]["ledgerID"] = ledger_id(selected["ledger"])
                with self.assertRaises(ReleaseEvidenceError):
                    self.evaluate(
                        surface,
                        "actual-runtime",
                        train="release",
                        comparison_payload=comparison(
                            surface,
                            "actual-runtime",
                            train="release",
                        ),
                        selected_rc_ledger=selected,
                    )

    def test_shipped_release_policy_is_valid(self):
        shipped_policy = json.loads(
            (REPO_ROOT / "Config/ContextPanelReleaseEvidencePolicy.json").read_text()
        )
        payload = self.evaluate(
            "watchos.app",
            "actual-runtime",
            validation_report=report("watchos.app", runtime=True),
            policy_payload=shipped_policy,
        )
        self.assertEqual(payload["policyDigest"], hashlib.sha256(
            json.dumps(shipped_policy, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest())

    def test_report_validation_honors_tightened_policy_age(self):
        surface = "watchos.app"
        tightened_policy = policy()
        tightened_policy["maximumEvidenceAgeDays"] = 7
        validation_report = report(surface, runtime=True)
        payload = self.evaluate(
            surface,
            "actual-runtime",
            validation_report=validation_report,
            policy_payload=tightened_policy,
        )
        blockers = release_evidence_report_blockers(
            payload,
            version="1.0.54",
            build_number="202608080418",
            train="beta",
            enforce=False,
            validation_report=validation_report,
            comparison=comparison(surface, "actual-runtime"),
            identities=all_identities(),
            policy=tightened_policy,
            now=NOW + timedelta(days=8),
        )
        self.assertTrue(any("expired" in blocker for blocker in blockers))

    def test_authoritative_scope_mismatch_fails_closed(self):
        surface = "watchos.app"
        validation_report = report(surface, visual_class="shared-view")
        payload = self.evaluate(
            surface,
            "shared-view",
            validation_report=validation_report,
        )
        payload["requiredEvidence"]["shared-view"] = []
        payload["surfaces"] = []
        payload["ledgerID"] = ledger_id(payload)
        blockers = self.report_blockers(
            payload,
            surface,
            "shared-view",
            enforce=False,
            validation_report=validation_report,
        )
        self.assertIn(
            "release evidence required scope does not match the comparison",
            blockers,
        )

    def test_comparison_cannot_omit_a_shipping_surface(self):
        surface = "watchos.app"
        comparison_payload = comparison(surface, "actual-runtime")
        comparison_payload["surfaces"] = comparison_payload["surfaces"][:-1]
        with self.assertRaisesRegex(ReleaseEvidenceError, "every shipping surface"):
            self.evaluate(
                surface,
                "actual-runtime",
                comparison_payload=comparison_payload,
                validation_report=report(surface, runtime=True),
            )

    def test_comparison_cannot_lower_canonical_evidence_floor(self):
        surface = "watchos.app"
        comparison_payload = comparison(surface, "actual-runtime")
        target_surface = next(
            item
            for item in comparison_payload["surfaces"]
            if item["surfaceId"] == surface
        )
        target_surface["minimumEvidence"] = []
        target_surface["freshEvidence"] = []
        target_surface["requiredEvidence"] = []
        comparison_payload["requiredSurfaces"]["actual-runtime"] = []
        comparison_payload["requiresRuntimeSession"] = False
        with self.assertRaisesRegex(ReleaseEvidenceError, "violates evidence policy"):
            self.evaluate(
                surface,
                "actual-runtime",
                comparison_payload=comparison_payload,
                validation_report=report(surface, runtime=True),
            )

    def test_enforced_empty_authoritative_scope_is_rejected(self):
        surface = "watchos.app"
        validation_report = report(surface, runtime=True)
        payload = self.evaluate(
            surface,
            "actual-runtime",
            mode="enforce",
            validation_report=validation_report,
            shadow_evidence=shadow_evidence(),
        )
        empty_comparison = comparison(surface, "actual-runtime")
        empty_comparison["requiredSurfaces"] = {
            evidence_class: []
            for evidence_class in (
                "shared-view",
                "actual-runtime",
                "os-composited-placement",
            )
        }
        empty_comparison["surfaces"][0]["requiredEvidence"] = []
        empty_comparison["surfaces"][0]["minimumEvidence"] = []
        empty_comparison["surfaces"][0]["carryForward"] = {
            evidence_class: {"eligible": False, "conditions": []}
            for evidence_class in (
                "shared-view",
                "actual-runtime",
                "os-composited-placement",
            )
        }
        payload["requiredEvidence"] = empty_comparison["requiredSurfaces"]
        payload["surfaces"] = []
        payload["comparisonDigest"] = hashlib.sha256(
            json.dumps(empty_comparison, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        payload["expectedBuildIdentityDigest"] = expected_identity_set_digest(
            *all_identities()
        )
        payload["ledgerID"] = ledger_id(payload)
        blockers = release_evidence_report_blockers(
            payload,
            version="1.0.54",
            build_number="202608080418",
            train="beta",
            enforce=True,
            validation_report=validation_report,
            comparison=empty_comparison,
            identities=all_identities(),
            policy=policy(),
            surface_policy=surface_policy(surface, "actual-runtime"),
            now=NOW,
        )
        self.assertIn(
            "enforced release evidence requires a non-empty authoritative scope",
            blockers,
        )

    def test_enforce_happy_path_validates_end_to_end(self):
        surface = "watchos.app"
        validation_report = report(surface, runtime=True)
        comparison_payload = comparison(surface, "actual-runtime")
        payload = self.evaluate(
            surface,
            "actual-runtime",
            mode="enforce",
            validation_report=validation_report,
            comparison_payload=comparison_payload,
            shadow_evidence=shadow_evidence(),
        )
        self.assertEqual(payload["state"], "approved")
        self.assertEqual(
            release_evidence_report_blockers(
                payload,
                version="1.0.54",
                build_number="202608080418",
                train="beta",
                enforce=True,
                validation_report=validation_report,
                comparison=comparison_payload,
                identities=all_identities(),
                policy=policy(),
                surface_policy=surface_policy(surface, "actual-runtime"),
                shadow_evidence=shadow_evidence(),
                now=NOW,
            ),
            [],
        )

    def test_report_validator_rejects_receipt_not_present_in_exact_report(self):
        surface = "watchos.app"
        validation_report = report(surface, runtime=True)
        comparison_payload = comparison(surface, "actual-runtime")
        payload = self.evaluate(
            surface,
            "actual-runtime",
            mode="enforce",
            validation_report=validation_report,
            comparison_payload=comparison_payload,
            shadow_evidence=shadow_evidence(),
        )
        payload["surfaces"][0]["evidence"]["actual-runtime"]["runtimeReceiptIDs"] = [
            "f" * 64
        ]
        payload["ledgerID"] = ledger_id(payload)
        blockers = release_evidence_report_blockers(
            payload,
            version="1.0.54",
            build_number="202608080418",
            train="beta",
            enforce=True,
            validation_report=validation_report,
            comparison=comparison_payload,
            identities=all_identities(),
            policy=policy(),
            surface_policy=surface_policy(surface, "actual-runtime"),
            now=NOW,
        )
        self.assertIn(
            "watchos.app:actual-runtime:validation-report-lineage-mismatch",
            blockers,
        )

    def test_report_validator_rejects_source_relabel_without_lineage(self):
        surface = "watchos.app"
        validation_report = report(surface, visual_class="shared-view")
        comparison_payload = comparison(surface, "shared-view")
        shadow_payload = shadow_evidence(
            surface=surface,
            evidence_class="shared-view",
        )
        payload = self.evaluate(
            surface,
            "shared-view",
            mode="enforce",
            validation_report=validation_report,
            comparison_payload=comparison_payload,
            shadow_evidence=shadow_payload,
        )
        payload["surfaces"][0]["evidence"]["shared-view"]["source"] = "carry-forward"
        payload["ledgerID"] = ledger_id(payload)
        blockers = release_evidence_report_blockers(
            payload,
            version="1.0.54",
            build_number="202608080418",
            train="beta",
            enforce=True,
            validation_report=validation_report,
            comparison=comparison_payload,
            identities=all_identities(),
            policy=policy(),
            surface_policy=surface_policy(surface, "shared-view"),
            shadow_evidence=shadow_payload,
            now=NOW,
        )
        self.assertIn(
            "release evidence does not match reconstructed authoritative evaluation",
            blockers,
        )

    def test_release_report_validation_requires_exact_selected_rc(self):
        surface = "watchos.app"
        validation_report = report(surface, runtime=True)
        comparison_payload = comparison(surface, "actual-runtime", train="release")
        selected_rc = selected_rc_ledger(surface)
        shadow_payload = shadow_evidence()
        payload = self.evaluate(
            surface,
            "actual-runtime",
            train="release",
            mode="enforce",
            validation_report=validation_report,
            comparison_payload=comparison_payload,
            selected_rc_ledger=selected_rc,
            shadow_evidence=shadow_payload,
        )
        common = {
            "version": "1.0.54",
            "build_number": "202608080418",
            "train": "release",
            "enforce": True,
            "validation_report": validation_report,
            "comparison": comparison_payload,
            "identities": all_identities(),
            "policy": policy(),
            "surface_policy": surface_policy(surface, "actual-runtime"),
            "shadow_evidence": shadow_payload,
            "now": NOW,
        }
        blockers = release_evidence_report_blockers(payload, **common)
        self.assertTrue(any("selected exact approved RC" in item for item in blockers))
        self.assertEqual(
            release_evidence_report_blockers(
                payload,
                selected_rc_ledger=selected_rc,
                **common,
            ),
            [],
        )

    def test_same_signed_target_with_conflicting_artifact_digest_is_duplicate(self):
        surface = "watchos.app"
        evidence = shadow_evidence()
        evidence["runs"][1]["train"] = evidence["runs"][0]["train"]
        evidence["runs"][1]["target"] = dict(evidence["runs"][0]["target"])
        evidence["runs"][1]["expectedBuildIdentityDigest"] = "f" * 64
        with self.assertRaisesRegex(ReleaseEvidenceError, "duplicates a signed train"):
            self.evaluate(
                surface,
                "actual-runtime",
                mode="enforce",
                validation_report=report(surface, runtime=True),
                shadow_evidence=evidence,
            )

    def test_shadow_comparison_reconstructs_each_embedded_ledger(self):
        surface = "watchos.app"
        evidence = shadow_evidence()
        embedded_ledger = evidence["runs"][0]["ledger"]
        embedded_ledger["surfaces"][0]["evidence"]["actual-runtime"][
            "source"
        ] = "selected-rc"
        embedded_ledger["ledgerID"] = ledger_id(embedded_ledger)
        evidence["runs"][0]["ledgerID"] = embedded_ledger["ledgerID"]

        with self.assertRaisesRegex(
            ReleaseEvidenceError,
            "does not match its generation context",
        ):
            self.evaluate(
                surface,
                "actual-runtime",
                mode="enforce",
                validation_report=report(surface, runtime=True),
                shadow_evidence=evidence,
            )

    def test_previous_and_selected_rc_roots_require_lineage_bundles(self):
        surface = "watchos.app"
        with self.assertRaisesRegex(ReleaseEvidenceError, "lineage is invalid"):
            self.evaluate(
                surface,
                "shared-view",
                eligible=True,
                previous_ledger=ledger(surface, "shared-view", identity(surface)),
            )
        with self.assertRaisesRegex(ReleaseEvidenceError, "lineage is invalid"):
            self.evaluate(
                surface,
                "actual-runtime",
                train="release",
                comparison_payload=comparison(
                    surface,
                    "actual-runtime",
                    train="release",
                ),
                selected_rc_ledger=ledger(
                    surface,
                    "actual-runtime",
                    identity(surface),
                ),
            )

    def test_lineage_revalidates_complete_expected_build_manifests(self):
        surface = "watchos.app"
        selected = selected_rc_ledger(surface)
        selected["generation"]["expectedBuildManifests"][0]["artifacts"][0][
            "executableSha256"
        ] = "f" * 64
        with self.assertRaisesRegex(
            ReleaseEvidenceError,
            "expected-build identities are invalid",
        ):
            self.evaluate(
                surface,
                "actual-runtime",
                train="release",
                comparison_payload=comparison(
                    surface,
                    "actual-runtime",
                    train="release",
                ),
                selected_rc_ledger=selected,
            )

    def test_shadow_generation_context_must_be_leaf_and_bounded(self):
        surface = "watchos.app"
        nested = shadow_evidence()
        nested["runs"][0]["generation"]["shadowEvidence"] = {
            "schemaVersion": 1,
            "kind": "context-panel-shadow-comparison",
            "runs": [],
        }
        with self.assertRaisesRegex(ReleaseEvidenceError, "leaf evaluation"):
            self.evaluate(
                surface,
                "actual-runtime",
                mode="enforce",
                validation_report=report(surface, runtime=True),
                shadow_evidence=nested,
            )

        oversized = shadow_evidence()
        oversized["runs"].append(
            json.loads(json.dumps(oversized["runs"][0]))
        )
        with self.assertRaisesRegex(
            ReleaseEvidenceError,
            "shadow comparison evidence is invalid",
        ):
            self.evaluate(
                surface,
                "actual-runtime",
                mode="enforce",
                validation_report=report(surface, runtime=True),
                shadow_evidence=oversized,
            )

    def test_shadow_comparison_cannot_reuse_one_ledger_for_two_targets(self):
        surface = "watchos.app"
        evidence = shadow_evidence()
        evidence["runs"][1]["ledgerID"] = evidence["runs"][0]["ledgerID"]
        with self.assertRaisesRegex(ReleaseEvidenceError, "reuses a release evidence ledger"):
            self.evaluate(
                surface,
                "actual-runtime",
                mode="enforce",
                validation_report=report(surface, runtime=True),
                shadow_evidence=evidence,
            )

    def test_privacy_fields_reject_paths_and_unbounded_host_text(self):
        surface = "watchos.complication"
        with self.assertRaisesRegex(ReleaseEvidenceError, "host OS evidence is invalid"):
            self.evaluate(
                surface,
                "os-composited-placement",
                eligible=True,
                validation_report=report(surface, runtime=True),
                previous_ledger=previous_lineage(
                    surface,
                    "os-composited-placement",
                    host_os="watchOS 27.0.0",
                ),
                host_os_evidence=host_evidence(
                    surface,
                    "watchOS 27.0.0 /private/device",
                ),
            )
        invalid_shadow = shadow_evidence(
            surface=surface,
            evidence_class="actual-runtime",
            disagreements=[
                {
                    "surface": surface,
                    "evidenceClass": "os-composited-placement",
                    "classification": "unresolved",
                    "resolution": "/private/device",
                }
            ]
        )
        with self.assertRaisesRegex(ReleaseEvidenceError, "shadow disagreement is invalid"):
            self.evaluate(
                surface,
                "actual-runtime",
                validation_report=report(surface, runtime=True),
                shadow_evidence=invalid_shadow,
            )

    def test_policy_digest_mismatch_fails_closed(self):
        surface = "watchos.app"
        validation_report = report(surface, runtime=True)
        comparison_payload = comparison(surface, "actual-runtime")
        payload = self.evaluate(
            surface,
            "actual-runtime",
            validation_report=validation_report,
            comparison_payload=comparison_payload,
        )
        payload["policyDigest"] = "f" * 64
        payload["ledgerID"] = ledger_id(payload)
        blockers = release_evidence_report_blockers(
            payload,
            version="1.0.54",
            build_number="202608080418",
            train="beta",
            enforce=False,
            validation_report=validation_report,
            comparison=comparison_payload,
            identities=all_identities(),
            policy=policy(),
            surface_policy=surface_policy(surface, "actual-runtime"),
            now=NOW,
        )
        self.assertIn("release evidence policy binding is invalid", blockers)

    def test_private_evidence_fields_fail_closed(self):
        surface = "watchos.app"
        previous = previous_lineage(surface, "shared-view")
        previous["ledger"]["surfaces"][0]["evidence"]["shared-view"][
            "privatePath"
        ] = "/private/path"
        previous["ledger"]["ledgerID"] = ledger_id(previous["ledger"])
        with self.assertRaisesRegex(ReleaseEvidenceError, "generation context"):
            self.evaluate(
                surface,
                "shared-view",
                eligible=True,
                previous_ledger=previous,
            )

    def test_report_validator_rejects_evidence_free_payload(self):
        payload = {
            "schemaVersion": 1,
            "kind": "context-panel-release-evidence",
            "mode": "enforce",
            "train": "beta",
            "state": "approved",
            "target": {"version": "1.0.54", "buildNumber": "202608080418"},
            "generatedAt": "2026-08-08T11:00:00Z",
            "expiresAt": "2026-08-09T11:00:00Z",
            "blockers": [],
            "shadow": {"state": "passed"},
        }
        payload["ledgerID"] = ledger_id(payload)
        blockers = self.report_blockers(
            payload,
            "watchos.app",
            "actual-runtime",
            enforce=True,
        )
        self.assertTrue(blockers)

    def test_report_validator_binds_exact_validation_report(self):
        surface = "watchos.app"
        validation_report = report(surface, visual_class="shared-view")
        payload = self.evaluate(
            surface,
            "shared-view",
            validation_report=validation_report,
        )
        different_report = report(surface, visual_class="shared-view")
        different_report["session"]["updatedAt"] = "2026-08-08T11:58:59Z"
        blockers = self.report_blockers(
            payload,
            surface,
            "shared-view",
            enforce=False,
            validation_report=different_report,
        )
        self.assertIn("release evidence does not match the exact validation report", blockers)

    def test_report_validator_rejects_shadow_report_in_enforcement(self):
        surface = "watchos.app"
        payload = self.evaluate(
            surface,
            "shared-view",
            validation_report=report(surface, visual_class="shared-view"),
        )
        blockers = self.report_blockers(
            payload,
            surface,
            "shared-view",
            enforce=True,
            validation_report=report(surface, visual_class="shared-view"),
        )
        self.assertIn("release evidence mode must be enforce", blockers)
        self.assertIn("shadow comparison evidence must be passed", blockers)

    def test_report_validator_accepts_structural_shadow_report(self):
        surface = "watchos.app"
        payload = self.evaluate(
            surface,
            "shared-view",
            validation_report=report(surface, visual_class="shared-view"),
        )
        self.assertEqual(
            self.report_blockers(
                payload,
                surface,
                "shared-view",
                enforce=False,
                validation_report=report(surface, visual_class="shared-view"),
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
