from __future__ import annotations

from typing import Any

from context_panel_expected_build import (
    EXPECTED_BUILD_SCHEMA_V2,
    ExpectedBuildSchemaError,
    ValidatedExpectedBuild,
    validate_expected_build_manifest,
)


ARTIFACT_RISK_CODES = (
    "artifact-mapping-changed",
    "bundle-contract-changed",
    "signing-contract-changed",
    "entitlement-contract-changed",
    "profile-capability-changed",
    "architecture-loss",
    "unexplained-executable-drift",
    "artifact-evidence-unknown",
)


def artifact_runtime_escalation_surfaces(
    *,
    train: str,
    artifact_risk_surfaces: dict[str, list[str]],
    runtime_capable_surface_ids: set[str],
) -> set[str]:
    if train not in {"rc", "release"}:
        return set()
    return {
        surface_id
        for surface_ids in artifact_risk_surfaces.values()
        for surface_id in surface_ids
        if surface_id in runtime_capable_surface_ids
    }


def derive_artifact_comparison(
    previous_payloads: list[dict[str, Any]] | None,
    current_payloads: list[dict[str, Any]] | None,
    *,
    previous_manifest_id: str,
    current_manifest_id: str,
    previous_contract_fingerprint: str,
    current_contract_fingerprint: str,
    previous_target: tuple[str, str],
    current_target: tuple[str, str],
    previous_surfaces: dict[str, dict[str, Any]],
    current_surfaces: dict[str, dict[str, Any]],
    runtime_capable_surface_ids: set[str],
    train: str,
    toolchain_changed: bool,
    exact_build_same: bool,
    validate_surface_binding: bool = True,
) -> dict[str, Any]:
    def collect(
        payloads: list[dict[str, Any]] | None,
        *,
        manifest_id: str,
        contract_fingerprint: str,
        target: tuple[str, str],
        source_surfaces: dict[str, dict[str, Any]],
    ) -> tuple[str, list[str], dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
        if payloads is None:
            return "not-evaluated", [], {}, {}
        if not payloads:
            return "missing", [], {}, {}
        validated: list[ValidatedExpectedBuild] = []
        for payload in payloads:
            validated.append(
                validate_expected_build_manifest(
                    payload,
                    version=target[0],
                    build_number=target[1],
                    current_manifest_id=manifest_id,
                    contract_fingerprint=contract_fingerprint,
                    valid_surfaces=set(source_surfaces),
                )
            )
        ids = sorted(item.payload["expectedBuildId"] for item in validated)
        artifacts: dict[str, dict[str, Any]] = {}
        surfaces: dict[str, dict[str, Any]] = {}
        legacy = any(
            item.payload["schemaVersion"] != EXPECTED_BUILD_SCHEMA_V2
            for item in validated
        )
        for item in validated:
            for artifact_id, artifact in item.artifacts.items():
                if artifact_id in artifacts:
                    raise ExpectedBuildSchemaError(
                        "expected signed build artifact is duplicated"
                    )
                artifacts[artifact_id] = artifact
            for surface in item.surfaces:
                surface_id = surface["id"]
                if surface_id in surfaces:
                    raise ExpectedBuildSchemaError(
                        "expected signed build surface is duplicated"
                    )
                if validate_surface_binding:
                    source_surface = source_surfaces[surface_id]
                    if (
                        surface["artifactId"] != source_surface.get("artifactId")
                        or surface["bundleIdentifier"]
                        != source_surface.get("bundleIdentifier")
                        or surface["fingerprints"]
                        != source_surface.get("fingerprints")
                    ):
                        raise ExpectedBuildSchemaError(
                            "expected signed build surface does not bind source"
                        )
                surfaces[surface_id] = surface
        expected_artifacts = {
            str(surface.get("artifactId")) for surface in source_surfaces.values()
        }
        complete = set(surfaces) == set(source_surfaces) and set(artifacts) == expected_artifacts
        if legacy:
            return "legacy-incomplete", ids, artifacts, surfaces
        return ("complete" if complete else "missing"), ids, artifacts, surfaces

    previous_state, previous_ids, previous_artifacts, _ = collect(
        previous_payloads,
        manifest_id=previous_manifest_id,
        contract_fingerprint=previous_contract_fingerprint,
        target=previous_target,
        source_surfaces=previous_surfaces,
    )
    current_state, current_ids, current_artifacts, _ = collect(
        current_payloads,
        manifest_id=current_manifest_id,
        contract_fingerprint=current_contract_fingerprint,
        target=current_target,
        source_surfaces=current_surfaces,
    )
    evidence = {
        "previousState": previous_state,
        "currentState": current_state,
        "previousExpectedBuildIds": previous_ids,
        "currentExpectedBuildIds": current_ids,
    }
    if previous_state == current_state == "not-evaluated":
        return {
            "artifactEvidence": evidence,
            "artifactRiskCodes": [],
            "artifactRiskSurfaces": {},
            "escalationState": "resolved",
        }
    current_by_artifact = {
        artifact_id: sorted(
            surface_id
            for surface_id, surface in current_surfaces.items()
            if surface.get("artifactId") == artifact_id
        )
        for artifact_id in current_artifacts
    }
    risks: dict[str, list[str]] = {}
    complete = previous_state == current_state == "complete"
    if complete:
        mapping = sorted(
            surface_id
            for surface_id, surface in current_surfaces.items()
            if surface_id in previous_surfaces
            and previous_surfaces[surface_id].get("artifactId")
            != surface.get("artifactId")
        )
        if mapping:
            risks["artifact-mapping-changed"] = sorted(
                {
                    affected_surface
                    for surface_id in mapping
                    for affected_surface in current_by_artifact.get(
                        str(current_surfaces[surface_id].get("artifactId")),
                        [surface_id],
                    )
                }
            )
        for artifact_id in sorted(set(previous_artifacts) & set(current_artifacts)):
            previous_artifact = previous_artifacts[artifact_id]
            current_artifact = current_artifacts[artifact_id]
            affected = current_by_artifact.get(artifact_id, [])
            if not affected:
                continue
            comparable_surfaces = [
                surface_id for surface_id in affected if surface_id in previous_surfaces
            ]
            for key, code in (
                ("bundleContractSha256", "bundle-contract-changed"),
                ("signingContractSha256", "signing-contract-changed"),
                ("entitlementContractSha256", "entitlement-contract-changed"),
                ("profileCapabilitySha256", "profile-capability-changed"),
            ):
                if previous_artifact[key] != current_artifact[key]:
                    risks.setdefault(code, []).extend(affected)
            if set(previous_artifact["architectures"]) - set(
                current_artifact["architectures"]
            ):
                risks.setdefault("architecture-loss", []).extend(affected)
            if (
                previous_artifact["executableSha256"]
                != current_artifact["executableSha256"]
                and exact_build_same
                and not toolchain_changed
                and comparable_surfaces
                and all(
                    previous_surfaces[surface_id]["fingerprints"]
                    == current_surfaces[surface_id]["fingerprints"]
                    for surface_id in comparable_surfaces
                )
            ):
                risks.setdefault("unexplained-executable-drift", []).extend(affected)
    else:
        artifact_intersection = set(previous_artifacts) & set(current_artifacts)
        unknown = sorted(
            surface_id
            for surface_id in runtime_capable_surface_ids
            if current_surfaces.get(surface_id, {}).get("artifactId")
            not in artifact_intersection
            or previous_state != "complete"
            or current_state != "complete"
        )
        if unknown:
            risks["artifact-evidence-unknown"] = unknown
    codes = [code for code in ARTIFACT_RISK_CODES if code in risks]
    normalized = {code: sorted(set(risks[code])) for code in codes}
    return {
        "artifactEvidence": evidence,
        "artifactRiskCodes": codes,
        "artifactRiskSurfaces": normalized,
        "escalationState": (
            "unknown-fail-closed"
            if "artifact-evidence-unknown" in codes
            else "resolved"
        ),
    }
