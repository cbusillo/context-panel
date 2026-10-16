# Frozen comparison-v6 derivation. Introduce a new schema/module for semantic
# changes; retained lineages must keep using this version and compare_manifests_v5.
"""Explicit mixed-build releases; retained artifacts never become candidate artifacts."""

from __future__ import annotations

import copy
from typing import Any

from context_panel_comparison_schema import (
    EVIDENCE_CLASSES,
    V6_COMPARISON_SCHEMA_VERSION,
    derive_risk_fields,
    derive_runtime_decision,
)
from context_panel_expected_build import validate_expected_build_manifest
from .artifact_comparison import semantic_artifact_risk_codes

CARRIED_CONTRACT_CHANGED = "carried-platform-contract-changed"
SHARED_ENTITLEMENTS_CHANGED = "shared-entitlements-changed"
PRODUCER_CONTRACT_CHANGED = "submitted-producer-contract-changed"


def platform_blocker(platform: str, reason: str) -> str:
    return f"{platform}:{reason}"


def producer_artifacts_changed(
    entry: dict[str, Any], platforms: dict[str, Any]
) -> bool:
    """Use the signed writers co-validated with this shipped consumer."""
    lineage = entry.get("shippedLineage")
    generation = lineage.get("generation") if isinstance(lineage, dict) else None
    builds = (
        generation.get("expectedBuildManifests")
        if isinstance(generation, dict)
        else None
    )
    if not isinstance(builds, list) or not builds:
        return True
    try:
        artifacts = {}
        for build in builds:
            validated = validate_expected_build_manifest(
                build,
                version=build["source"]["marketingVersion"],
                build_number=build["source"]["buildNumber"],
            )
            if artifacts.keys() & validated.artifacts.keys():
                return True
            artifacts.update(validated.artifacts)
        for platform in platforms.values():
            if platform["state"] != "submitted":
                continue
            for current in platform["expectedBuildManifest"]["artifacts"]:
                before = artifacts.get(current["artifactId"], {})
                if semantic_artifact_risk_codes(before, current):
                    return True
    except (KeyError, TypeError, ValueError):
        return True
    return False


def build_release_comparison(
    previous: dict[str, Any],
    current: dict[str, Any],
    train: str,
    previous_builds: list[dict[str, Any]] | None,
    record: dict[str, Any],
) -> dict[str, Any]:
    from .core import compare_manifests_v5 as compare_manifests
    from .core import (
        SurfacePolicyError,
        canonical_json,
        hash_parts,
        manifest_surface_map,
    )

    def fail(message):
        raise SurfacePolicyError(message)

    def source_map(manifest):
        if not isinstance(manifest, dict):
            fail("release record source manifest is missing")
        unsigned = {k: v for k, v in manifest.items() if k != "manifestId"}
        if manifest.get("manifestId") != hash_parts(
            f"{manifest.get('digestDomain')}/manifest", [canonical_json(unsigned)]
        ):
            fail("release record source manifest digest is invalid")
        return manifest_surface_map(manifest, "release record")

    if train not in {"rc", "release"}:
        fail("platform release records require an RC or release comparison")
    previous_surfaces, current_surfaces = source_map(previous), source_map(current)
    layouts = current.get("archiveLayouts")
    if (
        not isinstance(record, dict)
        or set(record)
        not in (
            {"schemaVersion", "platforms"},
            {"schemaVersion", "platforms", "previousSourceManifests"},
        )
        or type(record["schemaVersion"]) is not int
        or record["schemaVersion"] != 1
        or not isinstance(layouts, dict)
        or not layouts
        or not isinstance(record["platforms"], dict)
        or set(record["platforms"]) != set(layouts)
        or any(not isinstance(entry, dict) for entry in record["platforms"].values())
        or not isinstance(previous_builds, list)
    ):
        fail("release record must name every archive platform exactly once")
    previous_sources = record.get("previousSourceManifests", {})
    if not isinstance(previous_sources, dict) or (
        previous_sources and set(previous_sources) != set(layouts)
    ):
        fail("previous platform sources must cover every archive layout")
    comparisons, blockers, current_ids = {}, [], []
    covered = set()
    for platform in sorted(layouts):
        entry = record["platforms"][platform]
        if not isinstance(entry, dict) or entry.get("state") not in {
            "submitted",
            "carried",
        }:
            fail("release record platform state is invalid")
        carried = entry["state"] == "carried"
        keys = {"state", "expectedBuildManifest"}
        if carried:
            keys |= {"sourceManifest", "shippedLineage"}
        if set(entry) != keys:
            fail("release record platform fields are incomplete")
        source = entry["sourceManifest"] if carried else current
        surfaces = source_map(source)
        layout = layouts[platform]
        if not isinstance(layout, dict) or not layout:
            fail("release record archive layout is invalid")
        scope = {
            s for s, value in current_surfaces.items() if value["artifactId"] in layout
        }
        if not scope or covered & scope:
            fail("release record archive platforms overlap or are empty")
        covered |= scope
        expected = entry["expectedBuildManifest"]
        if not isinstance(expected, dict) or not isinstance(source.get("source"), dict):
            fail("release record shipped or submitted manifest is missing")
        validated = validate_expected_build_manifest(
            expected,
            version=source["source"]["marketingVersion"],
            build_number=source["source"]["buildNumber"],
            current_manifest_id=source["manifestId"],
            contract_fingerprint=source["contractFingerprint"],
            valid_surfaces=scope,
            error=SurfacePolicyError,
        )
        if {s["id"] for s in validated.surfaces} != scope or set(
            validated.artifacts
        ) != set(layout):
            fail("release record manifest does not cover its archive platform")
        if (
            expected["layout"] != platform
            or source.get("archiveLayouts", {}).get(platform) != layout
        ):
            fail("release record manifest archive layout does not bind source")
        if carried:
            # These fingerprints include shared inputs and project/entitlement contracts.
            # Comparing the candidate source against the shipped source is deliberately
            # conservative: no inference that a changed dependency is compatible.
            if any(
                s not in surfaces
                or any(
                    surfaces[s].get(k) != current_surfaces[s].get(k)
                    for k in (
                        "artifactId",
                        "bundleIdentifier",
                        "fingerprints",
                        "evidenceCapabilities",
                    )
                )
                for s in scope
            ):
                blockers.append(platform_blocker(platform, CARRIED_CONTRACT_CHANGED))
            # A newer approval need not be what this consumer shipped with.
            submitted_artifacts = {
                artifact
                for layout_name, value in record["platforms"].items()
                if value.get("state") == "submitted"
                for artifact in layouts[layout_name]
            }
            if any(
                s not in surfaces
                or surfaces[s]["fingerprints"]["runtime"]
                != value["fingerprints"]["runtime"]
                for s, value in current_surfaces.items()
                if value["artifactId"] in submitted_artifacts
            ) or producer_artifacts_changed(entry, record["platforms"]):
                blockers.append(platform_blocker(platform, PRODUCER_CONTRACT_CHANGED))
            source_files, current_files = (
                source.get("files", {}),
                current.get("files", {}),
            )
            if any(
                source_files.get(path) != current_files.get(path)
                for path in set(source_files) | set(current_files)
                if path.endswith(".entitlements")
            ):
                blockers.append(platform_blocker(platform, SHARED_ENTITLEMENTS_CHANGED))
            before, before_builds = source, [expected]
        else:
            before = previous_sources.get(platform, previous)
            source_map(before)
            before_builds = [
                build
                for build in previous_builds
                if isinstance(build, dict)
                and any(
                    s.get("id") in scope
                    for s in build.get("surfaces", [])
                    if isinstance(s, dict)
                )
            ]

        # A layout is the artifact boundary, including iPhone/iPad and embedded Watch.
        def scoped(manifest):
            result = copy.deepcopy(manifest)
            result["surfaces"] = [s for s in manifest["surfaces"] if s["id"] in scope]
            return result

        comparison = compare_manifests(
            scoped(before), scoped(source), train, before_builds, [expected]
        )
        comparisons[platform] = comparison
        current_ids.append(expected["expectedBuildId"])
    if covered != set(current_surfaces) or set(previous_surfaces) != set(
        current_surfaces
    ):
        fail("release record must cover every shipping surface without removals")
    if not any(e["state"] == "submitted" for e in record["platforms"].values()):
        fail("release record has no submitted platform")
    if any(e["state"] == "carried" for e in record["platforms"].values()):
        for platform, comparison in comparisons.items():
            if comparison["escalationState"] != "resolved":
                blockers.append(f"{platform}:artifact-evidence-unknown")
            if (
                record["platforms"][platform]["state"] == "submitted"
                and comparison["artifactRiskCodes"]
            ):
                blockers.append(platform_blocker(platform, PRODUCER_CONTRACT_CHANGED))
    result = copy.deepcopy(next(iter(comparisons.values())))
    result.update(
        {
            "schemaVersion": V6_COMPARISON_SCHEMA_VERSION,
            "previousManifestId": previous["manifestId"],
            "currentManifestId": current["manifestId"],
            "contractChanged": any(c["contractChanged"] for c in comparisons.values()),
            "exactBuildSame": all(c["exactBuildSame"] for c in comparisons.values()),
            "toolchainChanged": any(
                c["toolchainChanged"] for c in comparisons.values()
            ),
            "surfaces": sorted(
                [s for c in comparisons.values() for s in c["surfaces"]],
                key=lambda s: s["surfaceId"],
            ),
            "removedSurfaces": [],
            "platformComparisons": comparisons,
            "releaseContext": {
                "previousManifest": previous,
                "currentManifest": current,
                "previousExpectedBuildManifests": previous_builds,
                "releaseRecord": record,
            },
            "releaseSafety": {
                "state": "unknown-fail-closed" if blockers else "resolved",
                "blockers": sorted(set(blockers)),
            },
        }
    )
    result["requiredSurfaces"] = {
        cls: [
            s["surfaceId"] for s in result["surfaces"] if cls in s["requiredEvidence"]
        ]
        for cls in EVIDENCE_CLASSES
    }
    result["runtimeSessionSurfaces"] = sorted(
        surface
        for platform, comparison in comparisons.items()
        if record["platforms"][platform]["state"] == "submitted"
        for surface in comparison["requiredSurfaces"]["actual-runtime"]
    )
    for flag, cls in (
        ("requiresRuntimeSession", "actual-runtime"),
        ("requiresPlacementReview", "os-composited-placement"),
    ):
        result[flag] = bool(result["requiredSurfaces"][cls])
    result["runtimeState"], result["runtimeStateReasons"] = derive_runtime_decision(
        result["surfaces"]
    )
    runtime = {
        s["surfaceId"]
        for s in result["surfaces"]
        if "actual-runtime" in s["carryForward"]
    }
    result["riskCodes"], result["riskSurfaces"], result["observationRiskCodes"] = (
        derive_risk_fields(
            result["surfaces"],
            toolchain_delta=result["toolchainChanged"],
            runtime_capable_surface_ids=runtime,
            requires_placement_review=result["requiresPlacementReview"],
        )
    )
    result["artifactEvidence"] = {
        **{
            key: (
                "complete"
                if all(
                    c["artifactEvidence"][key] == "complete"
                    for c in comparisons.values()
                )
                else "missing"
            )
            for key in ("previousState", "currentState")
        },
        "previousExpectedBuildIds": sorted(
            {
                i
                for c in comparisons.values()
                for i in c["artifactEvidence"]["previousExpectedBuildIds"]
            }
        ),
        "currentExpectedBuildIds": sorted(current_ids),
    }
    risks = {}
    for comparison in comparisons.values():
        for code, surfaces in comparison["artifactRiskSurfaces"].items():
            risks.setdefault(code, []).extend(surfaces)
    from .artifact_comparison import ARTIFACT_RISK_CODES

    result["artifactRiskCodes"] = [c for c in ARTIFACT_RISK_CODES if c in risks]
    result["artifactRiskSurfaces"] = {
        c: sorted(set(risks[c])) for c in result["artifactRiskCodes"]
    }
    result["escalationState"] = (
        "unknown-fail-closed"
        if blockers or "artifact-evidence-unknown" in risks
        else "resolved"
    )
    if blockers:
        result["runtimeState"] = "unknown-fail-closed"
        result["runtimeStateReasons"] = ["carried-platform-contract-unknown"]
    return result


def validate_platform_comparison(comparison: dict[str, Any]) -> dict[str, Any]:
    from .core import SurfacePolicyError
    from context_panel_comparison_schema import ComparisonSchemaError

    try:
        if type(comparison["schemaVersion"]) is not int:
            raise ComparisonSchemaError("platform comparison schema is invalid")
        if not isinstance(comparison["platformComparisons"], dict):
            raise ComparisonSchemaError("platform comparisons are invalid")
        from context_panel_comparison_schema import validate_comparison_v5

        for platform in comparison["platformComparisons"].values():
            validate_comparison_v5(platform)
        context = comparison["releaseContext"]
        expected = build_release_comparison(
            context["previousManifest"],
            context["currentManifest"],
            comparison["train"],
            context["previousExpectedBuildManifests"],
            context["releaseRecord"],
        )
        if comparison != expected:
            raise ComparisonSchemaError(
                "platform comparison does not match its release record"
            )
    except (KeyError, TypeError, ValueError, SurfacePolicyError) as error:
        raise ComparisonSchemaError(
            "platform comparison release record is invalid"
        ) from error
    return comparison
