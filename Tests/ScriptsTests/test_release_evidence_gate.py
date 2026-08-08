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
    evaluate_release_evidence,
    release_evidence_report_blockers,
)
from context_panel_validation import ExpectedSurfaceIdentity


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


def identity(surface: str) -> ExpectedSurfaceIdentity:
    return ExpectedSurfaceIdentity(
        surface=surface,
        platform="watchOS",
        artifact_id=surface,
        bundle_identifier=f"com.example.{surface}",
        marketing_version="1.0.54",
        build_number="202608080418",
        manifest_id=MANIFEST,
        contract_fingerprint=CONTRACT,
        render_fingerprint=sha(f"{surface}:render"),
        runtime_fingerprint=sha(f"{surface}:runtime"),
        placement_fingerprint=sha(f"{surface}:placement"),
        combined_fingerprint=sha(f"{surface}:combined"),
        executable_uuids=("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",),
        expected_build_id=sha(f"{surface}:build"),
    )


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


def comparison(surface: str, evidence_class: str, *, eligible=False, train="beta"):
    required = {
        "shared-view": [],
        "actual-runtime": [],
        "os-composited-placement": [],
    }
    required[evidence_class] = [surface]
    return {
        "schemaVersion": 1,
        "train": train,
        "previousManifestId": PREVIOUS_MANIFEST,
        "currentManifestId": MANIFEST,
        "contractChanged": False,
        "exactBuildSame": evidence_class != "actual-runtime",
        "removedSurfaces": [],
        "requiredSurfaces": required,
        "requiresRuntimeSession": bool(required["actual-runtime"]),
        "requiresPlacementReview": bool(required["os-composited-placement"]),
        "surfaces": [
            {
                "surfaceId": surface,
                "artifactId": surface,
                "reasonCodes": ["unchanged"],
                "changes": {
                    "render": False,
                    "runtime": False,
                    "placement": False,
                    "contract": False,
                    "exactBuild": False,
                },
                "minimumEvidence": [evidence_class],
                "freshEvidence": [],
                "requiredEvidence": [evidence_class],
                "carryForward": {
                    name: {
                        "eligible": eligible if name == evidence_class else False,
                        "conditions": (
                            ["matching-host-os", "matching-current-runtime-receipt"]
                            if name == "os-composited-placement" and eligible
                            else []
                        ),
                    }
                    for name in (
                        "shared-view",
                        "actual-runtime",
                        "os-composited-placement",
                    )
                },
            }
        ],
        "releaseRequiresApprovedRCTarget": True,
    }


def report(surface: str, *, runtime=False, visual_class=None, host_os=None):
    requirements = []
    if visual_class is not None:
        requirements.append(
            {
                "id": f"{surface}.review",
                "evidenceClass": visual_class,
                "surface": surface,
                "device": "Apple Watch",
                "manifestID": MANIFEST,
                "expectedBuildID": sha(f"{surface}:build"),
                "contractFingerprint": CONTRACT,
                "identityDigest": identity(surface).identity_digest(),
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
                        sha(f"{surface}:receipt")
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
                "manifestID": MANIFEST,
                "expectedBuildID": sha(f"{surface}:build"),
                "identityDigest": identity(surface).identity_digest(),
                "runtimeFingerprint": sha(f"{surface}:runtime"),
                "receiptIDs": [sha(f"{surface}:runtime-receipt")] if runtime else [],
            }
        ],
        "visualApprovals": {
            "state": "approved" if requirements else "not-evaluated-by-coordinator",
            "requirements": requirements,
        },
        "blockers": [],
    }


def ledger(surface: str, evidence_class: str, expected: ExpectedSurfaceIdentity, *, host_os=None):
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
                        "decisionIDs": [],
                        "hostOS": host_os,
                        "runtimeReceiptIDs": [],
                    }
                },
            }
        ],
        "shadow": {
            "state": "pending",
            "requiredTrainCount": 2,
            "observedTrainCount": 0,
            "disagreements": [],
        },
        "blockers": [],
        "privacy": "safe",
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


def shadow_evidence(*, duplicate=False):
    runs = []
    for index in range(2):
        run_index = 0 if duplicate else index
        runs.append(
            {
                "train": "beta",
                "target": {
                    "version": f"1.0.{52 + run_index}",
                    "buildNumber": f"2026080{6 + run_index}0001",
                },
                "manifestID": sha(f"shadow-manifest-{run_index}"),
                "ledgerID": sha(f"shadow-ledger-{run_index}"),
                "observedAt": f"2026-08-0{6 + run_index}T12:00:00Z",
                "runbookState": "approved",
                "ledgerState": "approved",
                "disagreements": [],
            }
        )
    return {
        "schemaVersion": 1,
        "kind": "context-panel-shadow-comparison",
        "runs": runs,
    }


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
            identities=(expected,),
            policy=kwargs.pop("policy_payload", policy()),
            now=NOW,
            **kwargs,
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
        expected = identity(surface)
        payload = self.evaluate(
            surface,
            "shared-view",
            eligible=True,
            previous_ledger=ledger(surface, "shared-view", expected),
        )
        evidence = payload["surfaces"][0]["evidence"]["shared-view"]
        self.assertEqual(evidence["source"], "carry-forward")

    def test_placement_carry_forward_requires_current_runtime_and_host_os(self):
        surface = "watchos.complication"
        expected = identity(surface)
        host = host_evidence(surface, "watchOS 27.0")
        payload = self.evaluate(
            surface,
            "os-composited-placement",
            eligible=True,
            validation_report=report(surface, runtime=True),
            previous_ledger=ledger(
                surface,
                "os-composited-placement",
                expected,
                host_os="watchOS 27.0",
            ),
            host_os_evidence=host,
        )
        evidence = payload["surfaces"][0]["evidence"]["os-composited-placement"]
        self.assertEqual(evidence["source"], "carry-forward")

    def test_major_minor_host_os_change_invalidates_placement(self):
        surface = "watchos.complication"
        expected = identity(surface)
        host = host_evidence(surface, "watchOS 28.0")
        payload = self.evaluate(
            surface,
            "os-composited-placement",
            eligible=True,
            validation_report=report(surface, runtime=True),
            previous_ledger=ledger(
                surface,
                "os-composited-placement",
                expected,
                host_os="watchOS 27.0",
            ),
            host_os_evidence=host,
        )
        self.assertEqual(payload["state"], "blocked")

    def test_patch_sensitive_surface_invalidates_patch_change(self):
        surface = "watchos.complication"
        expected = identity(surface)
        host = host_evidence(surface, "watchOS 27.0.1")
        payload = self.evaluate(
            surface,
            "os-composited-placement",
            eligible=True,
            validation_report=report(surface, runtime=True),
            previous_ledger=ledger(
                surface,
                "os-composited-placement",
                expected,
                host_os="watchOS 27.0.0",
            ),
            host_os_evidence=host,
            policy_payload=policy(patch_sensitive=(surface,)),
        )
        self.assertEqual(payload["state"], "blocked")

    def test_expired_previous_ledger_fails_closed(self):
        surface = "watchos.app"
        previous = ledger(surface, "shared-view", identity(surface))
        previous["expiresAt"] = "2026-08-07T00:00:00Z"
        previous["ledgerID"] = ledger_id(previous)
        with self.assertRaisesRegex(ReleaseEvidenceError, "expired"):
            self.evaluate(
                surface,
                "shared-view",
                eligible=True,
                previous_ledger=previous,
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
        expected = identity(surface)
        selected_rc = ledger(surface, "actual-runtime", expected)
        selected_rc.update(
            {
                "train": "rc",
                "mode": "enforce",
                "target": {
                    "version": "1.0.54",
                    "buildNumber": "202608080418",
                },
                "currentManifestID": MANIFEST,
                "shadow": {
                    "state": "passed",
                    "requiredTrainCount": 2,
                    "observedTrainCount": 2,
                    "disagreements": [],
                },
            }
        )
        selected_rc["surfaces"][0]["identityDigest"] = expected.identity_digest()
        selected_rc["ledgerID"] = ledger_id(selected_rc)
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
        previous = ledger(surface, "shared-view", identity(surface))
        previous["surfaces"][0]["evidence"]["shared-view"]["fingerprint"] = "f" * 64
        with self.assertRaisesRegex(ReleaseEvidenceError, "approved release evidence ledger"):
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
        with self.assertRaisesRegex(ReleaseEvidenceError, "do not match"):
            self.evaluate(
                surface,
                "shared-view",
                comparison_payload=comparison_payload,
            )

    def test_release_rc_requirement_cannot_be_removed(self):
        surface = "watchos.app"
        comparison_payload = comparison(surface, "actual-runtime", train="release")
        comparison_payload.pop("releaseRequiresApprovedRCTarget")
        with self.assertRaisesRegex(ReleaseEvidenceError, "RC requirement"):
            self.evaluate(
                surface,
                "actual-runtime",
                train="release",
                comparison_payload=comparison_payload,
                validation_report=report(surface, runtime=True),
            )

    def test_carry_forward_does_not_renew_source_expiry(self):
        surface = "watchos.app"
        previous = ledger(surface, "shared-view", identity(surface))
        previous["expiresAt"] = "2026-08-08T13:00:00Z"
        previous["ledgerID"] = ledger_id(previous)
        payload = self.evaluate(
            surface,
            "shared-view",
            eligible=True,
            previous_ledger=previous,
        )
        self.assertEqual(payload["expiresAt"], "2026-08-08T13:00:00Z")

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
                previous_ledger=ledger(
                    surface,
                    "os-composited-placement",
                    identity(surface),
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

    def test_private_evidence_fields_fail_closed(self):
        surface = "watchos.app"
        previous = ledger(surface, "shared-view", identity(surface))
        previous["surfaces"][0]["evidence"]["shared-view"]["privatePath"] = "/private/path"
        previous["ledgerID"] = ledger_id(previous)
        with self.assertRaisesRegex(ReleaseEvidenceError, "invalid evidence"):
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
        blockers = release_evidence_report_blockers(
            payload,
            version="1.0.54",
            build_number="202608080418",
            train="beta",
            enforce=True,
            now=NOW,
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
        blockers = release_evidence_report_blockers(
            payload,
            version="1.0.54",
            build_number="202608080418",
            train="beta",
            enforce=False,
            validation_report_digest=sha("different-report"),
            now=NOW,
        )
        self.assertIn("release evidence does not match the exact validation report", blockers)

    def test_report_validator_rejects_shadow_report_in_enforcement(self):
        surface = "watchos.app"
        payload = self.evaluate(
            surface,
            "shared-view",
            validation_report=report(surface, visual_class="shared-view"),
        )
        blockers = release_evidence_report_blockers(
            payload,
            version="1.0.54",
            build_number="202608080418",
            train="beta",
            enforce=True,
            now=NOW,
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
            release_evidence_report_blockers(
                payload,
                version="1.0.54",
                build_number="202608080418",
                train="beta",
                enforce=False,
                now=NOW,
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
