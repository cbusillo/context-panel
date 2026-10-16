from __future__ import annotations

from typing import Any

from context_panel_comparison_schema import (
    V5_COMPARISON_SCHEMA_VERSION,
    ComparisonSchemaError,
    EVIDENCE_CLASSES,
    artifact_runtime_escalation_surfaces,
    derive_artifact_comparison,
    derive_runtime_decision,
    derive_risk_fields,
    toolchain_changed,
    validate_comparison_v5,
)
from context_panel_expected_build import ExpectedBuildSchemaError


def compare_manifests(
    previous: dict[str, Any],
    current: dict[str, Any],
    train: str,
    previous_expected_build_manifests: list[dict[str, Any]] | None = None,
    current_expected_build_manifests: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    # Frozen v5 derivation. New semantics need a new version, leaving this path
    # available for retained v6 platform comparisons and historical reconstruction.
    from .core import (
        SurfacePolicyError,
        SHA256_PATTERN,
        TRAIN_NAMES,
        validate_evidence_policy,
        manifest_surface_map,
        ordered_intersection,
    )

    if previous.get("schemaVersion") != 1 or current.get("schemaVersion") != 1:
        raise SurfacePolicyError("surface manifest schema is unsupported")
    evidence_policy = validate_evidence_policy(current.get("evidencePolicy"))
    class_order = list(EVIDENCE_CLASSES)
    train_minimums = evidence_policy["trainMinimumEvidence"]
    if train not in TRAIN_NAMES:
        raise SurfacePolicyError(f"unknown release train: {train}")
    change_requirements = evidence_policy["changeRequirements"]
    previous_surfaces = manifest_surface_map(previous, "previous")
    current_surfaces = manifest_surface_map(current, "current")
    previous_contract_fingerprint = str(previous.get("contractFingerprint") or "")
    current_contract_fingerprint = str(current.get("contractFingerprint") or "")
    if not SHA256_PATTERN.fullmatch(
        previous_contract_fingerprint
    ) or not SHA256_PATTERN.fullmatch(current_contract_fingerprint):
        raise SurfacePolicyError("surface manifest contract fingerprint is invalid")
    contract_changed = previous_contract_fingerprint != current_contract_fingerprint
    previous_source = previous.get("source") or {}
    current_source = current.get("source") or {}
    manifest_toolchain_changed = toolchain_changed(previous, current)
    exact_build_same = all(
        previous_source.get(key) == current_source.get(key)
        for key in (
            "marketingVersion",
            "buildNumber",
            "commit",
            "configuration",
            "xcodeBuild",
            "treeState",
        )
    )

    results = []
    for surface_id in sorted(current_surfaces):
        surface = current_surfaces[surface_id]
        capabilities = set(surface.get("evidenceCapabilities") or [])
        previous_surface = previous_surfaces.get(surface_id)
        minimum = ordered_intersection(train_minimums[train], capabilities, class_order)
        render_changed = True
        runtime_changed = True
        placement_changed = True
        reason_codes: list[str] = []
        if previous_surface is None:
            reason_codes.append("new-surface")
        else:
            previous_fingerprints = previous_surface.get("fingerprints") or {}
            current_fingerprints = surface.get("fingerprints") or {}
            render_changed = previous_fingerprints.get(
                "render"
            ) != current_fingerprints.get("render")
            runtime_changed = previous_fingerprints.get(
                "runtime"
            ) != current_fingerprints.get("runtime")
            placement_changed = previous_fingerprints.get(
                "placement"
            ) != current_fingerprints.get("placement")
            if render_changed:
                reason_codes.append("render-fingerprint-changed")
            if runtime_changed:
                reason_codes.append("runtime-fingerprint-changed")
            if placement_changed:
                reason_codes.append("placement-fingerprint-changed")
            if contract_changed:
                reason_codes.append("contract-fingerprint-changed")
            if not exact_build_same:
                reason_codes.append("exact-build-changed")
            if not reason_codes:
                reason_codes.append("unchanged")

        fresh: set[str] = set()
        if previous_surface is None or contract_changed:
            fresh.update(change_requirements["unknown"])
        else:
            if render_changed:
                fresh.update(change_requirements["render"])
            if runtime_changed:
                fresh.update(change_requirements["runtime"])
            if placement_changed:
                fresh.update(change_requirements["placement"])
            if (
                not exact_build_same
                and "actual-runtime" in capabilities
                and "actual-runtime" in train_minimums[train]
            ):
                fresh.add("actual-runtime")
        if (
            manifest_toolchain_changed
            and train in {"rc", "release"}
            and "actual-runtime" in capabilities
        ):
            fresh.add("actual-runtime")
        fresh_evidence = ordered_intersection(fresh, capabilities, class_order)
        required_evidence = ordered_intersection(
            (*minimum, *fresh_evidence),
            capabilities,
            class_order,
        )

        carry_forward: dict[str, dict[str, Any]] = {}
        for evidence_class in ordered_intersection(
            class_order, capabilities, class_order
        ):
            eligible = False
            conditions: list[str] = []
            if previous_surface is not None:
                if evidence_class == "shared-view":
                    eligible = not render_changed and not contract_changed
                elif evidence_class == "actual-runtime":
                    eligible = (
                        not runtime_changed
                        and exact_build_same
                        and not contract_changed
                    )
                elif evidence_class == "os-composited-placement":
                    eligible = not placement_changed and not contract_changed
                    if eligible:
                        conditions = [
                            "matching-host-os",
                            "matching-current-runtime-receipt",
                        ]
            if evidence_class in fresh_evidence:
                eligible = False
                conditions = []
            carry_forward[evidence_class] = {
                "eligible": eligible,
                "conditions": conditions,
            }

        results.append(
            {
                "surfaceId": surface_id,
                "artifactId": surface.get("artifactId"),
                "reasonCodes": reason_codes,
                "changes": {
                    "render": render_changed,
                    "runtime": runtime_changed,
                    "placement": placement_changed,
                    "contract": contract_changed,
                    "exactBuild": not exact_build_same,
                },
                "minimumEvidence": minimum,
                "freshEvidence": fresh_evidence,
                "requiredEvidence": required_evidence,
                "carryForward": carry_forward,
            }
        )

    removed_surfaces = sorted(set(previous_surfaces) - set(current_surfaces))
    runtime_capable_surface_ids = {
        surface_id
        for surface_id, surface in current_surfaces.items()
        if "actual-runtime" in set(surface.get("evidenceCapabilities") or [])
    }
    try:
        artifact_fields = derive_artifact_comparison(
            previous_expected_build_manifests,
            current_expected_build_manifests,
            previous_manifest_id=str(previous.get("manifestId") or ""),
            current_manifest_id=str(current.get("manifestId") or ""),
            previous_contract_fingerprint=previous_contract_fingerprint,
            current_contract_fingerprint=current_contract_fingerprint,
            previous_target=(
                str(previous_source.get("marketingVersion") or ""),
                str(previous_source.get("buildNumber") or ""),
            ),
            current_target=(
                str(current_source.get("marketingVersion") or ""),
                str(current_source.get("buildNumber") or ""),
            ),
            previous_surfaces=previous_surfaces,
            current_surfaces=current_surfaces,
            runtime_capable_surface_ids=runtime_capable_surface_ids,
            train=train,
            toolchain_changed=manifest_toolchain_changed,
            exact_build_same=exact_build_same,
        )
    except ExpectedBuildSchemaError as error:
        raise SurfacePolicyError("expected signed build manifest is invalid") from error
    artifact_runtime_surfaces = artifact_runtime_escalation_surfaces(
        train=train,
        artifact_risk_surfaces=artifact_fields["artifactRiskSurfaces"],
        runtime_capable_surface_ids=runtime_capable_surface_ids,
    )
    if artifact_runtime_surfaces:
        for surface in results:
            if (
                surface["surfaceId"] in artifact_runtime_surfaces
                and "actual-runtime" not in surface["freshEvidence"]
            ):
                surface["freshEvidence"] = [
                    evidence_class
                    for evidence_class in class_order
                    if evidence_class in {*surface["freshEvidence"], "actual-runtime"}
                ]
                surface["requiredEvidence"] = [
                    evidence_class
                    for evidence_class in class_order
                    if evidence_class
                    in {*surface["requiredEvidence"], "actual-runtime"}
                ]
                surface["carryForward"]["actual-runtime"] = {
                    "eligible": False,
                    "conditions": [],
                }
    runtime_state, runtime_state_reasons = derive_runtime_decision(results)
    required_surfaces = {
        evidence_class: [
            surface["surfaceId"]
            for surface in results
            if evidence_class in surface["requiredEvidence"]
        ]
        for evidence_class in class_order
    }
    risk_codes, risk_surfaces, observation_risk_codes = derive_risk_fields(
        results,
        toolchain_delta=manifest_toolchain_changed,
        runtime_capable_surface_ids=runtime_capable_surface_ids,
        requires_placement_review=bool(required_surfaces["os-composited-placement"]),
    )
    comparison = {
        "kind": "context-panel-surface-comparison",
        "schemaVersion": V5_COMPARISON_SCHEMA_VERSION,
        "train": train,
        "previousManifestId": previous.get("manifestId"),
        "currentManifestId": current.get("manifestId"),
        "contractChanged": contract_changed,
        "exactBuildSame": exact_build_same,
        "removedSurfaces": removed_surfaces,
        "requiredSurfaces": required_surfaces,
        "requiresRuntimeSession": bool(required_surfaces["actual-runtime"]),
        "requiresPlacementReview": bool(required_surfaces["os-composited-placement"]),
        "runtimeState": runtime_state,
        "runtimeStateReasons": runtime_state_reasons,
        "toolchainChanged": manifest_toolchain_changed,
        "riskCodes": risk_codes,
        "riskSurfaces": risk_surfaces,
        "observationRiskCodes": observation_risk_codes,
        **artifact_fields,
        "surfaces": results,
        "releaseRequiresApprovedRCTarget": bool(
            evidence_policy.get("releaseRequiresApprovedRCTarget")
        ),
    }
    try:
        return validate_comparison_v5(
            comparison,
            runtime_capable_surface_ids=runtime_capable_surface_ids,
        )
    except ComparisonSchemaError as error:
        raise SurfacePolicyError("generated surface comparison is invalid") from error
