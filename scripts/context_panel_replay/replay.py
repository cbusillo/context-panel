from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Any

from context_panel_comparison_schema import REASON_CODES, _expected_reason_codes
from context_panel_release_gate.core import (
    LEDGER_KEYS,
    MODES,
    RELEASE_EVIDENCE_KIND,
    RELEASE_EVIDENCE_SCHEMA_VERSION,
    TRAINS,
    ReleaseEvidenceError,
    _ledger_id,
    _validate_policy,
)

from .comparison_adapters import ComparisonAdapterError, adapt_comparison_for_replay
from .inventory import (
    InventoryError,
    _normalize_root_bindings,
    _resolve,
    _scan_public,
    canonical_digest,
    check_inventory,
    load_json,
    load_policy,
    raw_digest,
    verify_inventory,
)


BUNDLE_KIND = "context-panel-signed-train-replay-bundle"
REPORT_KIND = "context-panel-signed-train-replay-report"
DIAGNOSTICS_KIND = "context-panel-release-gate-replay-diagnostics"
BUNDLE_DOMAIN = "context-panel.signed-train-replay.bundle.v1"
REPORT_DOMAIN = "context-panel.signed-train-replay.report.v1"
DIAGNOSTICS_DOMAIN = "context-panel.release-gate.replay-diagnostics.v1"
EVIDENCE_CLASSES = ("shared-view", "actual-runtime", "os-composited-placement")
SOURCE_STATES = {"verified", "sources-unverified"}
RUNTIME_STATES = {"proven", "not-reported"}
RECEIPT_STATES = {"verified", "sources-unverified", "not-referenced"}
ACTION_CODES = {
    "required:fresh-evidence-required",
    "required:train-minimum-required",
    "skipped:surface-not-capable",
    "skipped:carry-forward-eligible",
    "skipped:comparison-not-required",
}
SKIPPED_REPORT_CODES = {
    f"{evidence_class}:{action.split(':', 1)[1]}"
    for evidence_class in EVIDENCE_CLASSES
    for action in ACTION_CODES
    if action.startswith("skipped:")
}
CHANGE_FIELDS = ("render", "runtime", "placement", "contract", "exactBuild")
ARTIFACT_FIELDS = (
    "executableSha256",
    "executableUUIDs",
    "entitlementsSha256",
    "profileSha256",
    "xcodeBuild",
)
BUNDLE_KEYS = {
    "schemaVersion",
    "kind",
    "algorithm",
    "digestDomain",
    "inventoryId",
    "inventoryDigest",
    "inventoryPolicyDigest",
    "releasePolicyDigest",
    "surfacePolicyDigest",
    "sourceState",
    "summary",
    "trains",
    "bundleId",
}
BUNDLE_SUMMARY_KEYS = {
    "trainCount",
    "surfaceCount",
    "sourceVerifiedInputCount",
    "sourceUnverifiedInputCount",
    "residualRiskCount",
}
BUNDLE_TRAIN_KEYS = {
    "trainId",
    "version",
    "buildNumber",
    "trainClass",
    "trainName",
    "previousManifestId",
    "currentManifestId",
    "comparisonAdapter",
    "comparisonDigest",
    "sourceState",
    "sourceVerification",
    "admissibleClaims",
    "notAdmissibleFor",
    "blockedClaims",
    "residualRisks",
    "runtimeSurfaces",
    "artifactObservations",
}
REPORT_KEYS = {
    "schemaVersion",
    "kind",
    "algorithm",
    "digestDomain",
    "inventoryId",
    "inventoryDigest",
    "inventoryPolicyDigest",
    "releasePolicyDigest",
    "surfacePolicyDigest",
    "bundleId",
    "sourceState",
    "summary",
    "trains",
    "reportId",
}
REPORT_SUMMARY_KEYS = {
    "trainCount",
    "surfaceCount",
    "sourceUnverifiedTrainCount",
    "admissibleClaimCount",
    "blockedClaimCount",
    "residualRiskCount",
    "potentialFalsePositiveCount",
}
REPORT_TRAIN_KEYS = {
    "trainId",
    "version",
    "buildNumber",
    "trainClass",
    "sourceState",
    "sourceVerification",
    "deviceClasses",
    "runtimeSurfaces",
    "placementActions",
    "artifactFieldAnalysis",
    "admissibleClaims",
    "blockedClaims",
    "residualRisks",
}
DIAGNOSTICS_KEYS = {
    "schemaVersion",
    "kind",
    "algorithm",
    "digestDomain",
    "releaseEvidenceLedgerId",
    "releaseEvidenceState",
    "replayReportId",
    "sourceState",
    "sourcesUnverifiedTrains",
    "residualRisks",
    "diagnosticsId",
}
DIAGNOSTIC_RISK_KEYS = {
    "trainId",
    "code",
    "category",
    "referencedCount",
    "retainedCount",
    "unsupportedClaims",
}
RISK_KEYS = DIAGNOSTIC_RISK_KEYS - {"trainId"}
LEDGER_STATES = {"approved", "blocked", "shadow-approved"}
SOURCE_PROJECTION_DIGESTS = {
    "1.0.57-202608090510": "6795278f6e599ecf420bdb1e4ec90e108bf0c47b8bbd28145ae0229e1022831e",
    "1.0.60-202608101107": "d641dc367015f896c583d6acb66dbf6534986043954ced72781070408a7f6a75",
    "1.0.61-202608270330": "1d4387d2cc63b4640b63b7621cea31215d059fc518ec5b2ec390106eb1c60833",
}


class ReplayError(ValueError):
    pass


def render_artifact(payload: dict[str, Any]) -> bytes:
    from .inventory import canonical_json

    return canonical_json(payload) + b"\n"


def _exact(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ReplayError(f"{label} has an invalid shape")
    return value


def _row(value: Any, length: int, label: str) -> list[Any]:
    if not isinstance(value, list) or len(value) != length:
        raise ReplayError(f"{label} has an invalid shape")
    return value


def _string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ReplayError(f"{label} is invalid")
    return value


def _integer(value: Any, label: str) -> int:
    if type(value) is not int or value < 0:
        raise ReplayError(f"{label} is invalid")
    return value


def _digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(
        character not in "0123456789abcdef" for character in value
    ):
        raise ReplayError(f"{label} is invalid")
    return value


def _strings(value: Any, label: str, *, sorted_unique: bool = True) -> list[str]:
    if not isinstance(value, list) or any(
        not isinstance(item, str) or not item for item in value
    ):
        raise ReplayError(f"{label} is invalid")
    if len(value) != len(set(value)) or (sorted_unique and value != sorted(value)):
        raise ReplayError(f"{label} is invalid")
    return value


def _risks(value: Any, label: str) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise ReplayError(f"{label} is invalid")
    for risk in value:
        risk = _exact(risk, RISK_KEYS, label)
        _string(risk["code"], label)
        _string(risk["category"], label)
        _integer(risk["referencedCount"], label)
        _integer(risk["retainedCount"], label)
        _strings(risk["unsupportedClaims"], label)
    return value


def _load(path: Path, label: str) -> dict[str, Any]:
    try:
        return load_json(path, label)
    except InventoryError as error:
        raise ReplayError(str(error)) from error


def _raw_digest(path: Path, label: str) -> str:
    try:
        return raw_digest(path)
    except OSError as error:
        raise ReplayError(f"{label} is unavailable or invalid") from error


def _public(value: Any) -> None:
    try:
        _scan_public(value)
    except InventoryError as error:
        raise ReplayError(str(error)) from error


def _policy_digests(
    inventory_policy_path: Path,
    release_policy_path: Path,
    surface_policy_path: Path,
) -> dict[str, str]:
    try:
        _validate_policy(_load(release_policy_path, "release evidence policy"))
    except ReleaseEvidenceError as error:
        raise ReplayError(str(error)) from error
    surface_policy = _load(surface_policy_path, "surface evidence policy")
    if type(surface_policy.get("schemaVersion")) is not int or surface_policy.get(
        "schemaVersion"
    ) != 1 or not isinstance(
        surface_policy.get("surfaces"), list
    ):
        raise ReplayError("surface evidence policy is invalid")
    return {
        "inventoryPolicyDigest": _raw_digest(inventory_policy_path, "replay inventory policy"),
        "releasePolicyDigest": _raw_digest(release_policy_path, "release evidence policy"),
        "surfacePolicyDigest": _raw_digest(surface_policy_path, "surface evidence policy"),
    }


def _root_file(root_bindings: dict[str, Path], root_id: str, relative: str) -> Path:
    try:
        return _resolve(root_bindings, root_id, relative, "replay input")
    except (InventoryError, OSError) as error:
        raise ReplayError(str(error)) from error


def _surface_policy_map(surface_policy: dict[str, Any]) -> dict[str, tuple[str, str, list[str]]]:
    if (
        not isinstance(surface_policy, dict)
        or type(surface_policy.get("schemaVersion")) is not int
        or surface_policy.get("schemaVersion") != 1
        or not isinstance(surface_policy.get("surfaces"), list)
    ):
        raise ReplayError("surface evidence policy is invalid")
    result: dict[str, tuple[str, str, list[str]]] = {}
    for item in surface_policy["surfaces"]:
        if not isinstance(item, dict):
            raise ReplayError("surface evidence policy is invalid")
        surface = item.get("id")
        artifact = item.get("artifactId")
        device = item.get("deviceClass")
        capabilities = item.get("evidenceCapabilities")
        if (
            not isinstance(surface, str)
            or surface in result
            or not isinstance(artifact, str)
            or not isinstance(device, str)
            or not isinstance(capabilities, list)
            or any(value not in EVIDENCE_CLASSES for value in capabilities)
        ):
            raise ReplayError("surface evidence policy is invalid")
        result[surface] = (artifact, device, capabilities)
    return result


def _source_rows(train: dict[str, Any]) -> list[list[Any]]:
    unverified_categories = {
        risk["category"]
        for risk in train["residualRisks"]
        if risk["retainedCount"] < risk["referencedCount"]
    }
    return [
        [
            item["category"],
            (
                "sources-unverified"
                if item["recoverability"] == "reference-only"
                or item["category"] in unverified_categories
                else "verified"
            ),
        ]
        for item in train["inputs"]
    ]


def _source_state(rows: list[list[Any]]) -> str:
    return "sources-unverified" if any(row[1] == "sources-unverified" for row in rows) else "verified"


def _source_projection(train: dict[str, Any]) -> list[Any]:
    return [train[key] for key in ("trainName", "comparisonAdapter", "runtimeSurfaces", "artifactObservations")]


def _observation(values: list[Any]) -> list[Any]:
    return [len(values), canonical_digest(values) if values else None]


def _action_codes(comparison_surface: dict[str, Any], capabilities: list[str]) -> list[str]:
    required = set(comparison_surface["requiredEvidence"])
    fresh = set(comparison_surface["freshEvidence"])
    carry = comparison_surface["carryForward"]
    result = []
    for evidence_class in EVIDENCE_CLASSES:
        if evidence_class in fresh:
            action, reason = "required", "fresh-evidence-required"
        elif evidence_class in required:
            action, reason = "required", "train-minimum-required"
        elif evidence_class not in capabilities:
            action, reason = "skipped", "surface-not-capable"
        elif carry.get(evidence_class, {}).get("eligible") is True:
            action, reason = "skipped", "carry-forward-eligible"
        else:
            action, reason = "skipped", "comparison-not-required"
        result.append(f"{action}:{reason}")
    return result


def _surface_rows(
    comparison: dict[str, Any],
    report: dict[str, Any],
    surface_policy: dict[str, tuple[str, str, list[str]]],
    receipt_body_state: str,
) -> list[list[Any]]:
    reported = {
        item.get("surface"): item
        for item in report.get("runtimeSurfaces", [])
        if isinstance(item, dict) and isinstance(item.get("surface"), str)
    }
    approvals = report.get("visualApprovals")
    requirements = approvals.get("requirements", []) if isinstance(approvals, dict) else []
    host_os: dict[str, set[str]] = {}
    for item in requirements:
        if isinstance(item, dict) and isinstance(item.get("surface"), str) and isinstance(
            item.get("hostOS"), str
        ):
            host_os.setdefault(item["surface"], set()).add(item["hostOS"])
    rows = []
    for item in comparison["surfaces"]:
        surface = item["surfaceId"]
        if surface not in surface_policy:
            raise ReplayError(f"surface policy is missing {surface}")
        artifact, device, capabilities = surface_policy[surface]
        if artifact != item["artifactId"]:
            raise ReplayError("comparison artifact does not match surface policy")
        reported_surface = reported.get(surface, {})
        receipts = reported_surface.get("receiptIDs", [])
        if not isinstance(receipts, list) or any(not isinstance(value, str) for value in receipts):
            raise ReplayError("retained runtime receipt references are invalid")
        hosts = sorted(host_os.get(surface, set()))
        rows.append(
            [
                surface,
                artifact,
                device,
                item["reasonCodes"],
                "".join("1" if item["changes"][field] else "0" for field in CHANGE_FIELDS),
                _action_codes(item, capabilities),
                reported_surface.get("state", "not-reported"),
                len(receipts),
                "not-referenced" if not receipts else receipt_body_state,
                len(hosts),
                canonical_digest(hosts) if hosts else None,
            ]
        )
    return rows


def _artifact_rows(expected_builds: list[dict[str, Any]]) -> list[list[Any]]:
    artifacts: dict[str, dict[str, Any]] = {}
    surfaces: dict[str, set[str]] = {}
    for manifest in expected_builds:
        for artifact in manifest["artifacts"]:
            artifact_id = artifact["artifactId"]
            if artifact_id in artifacts and artifacts[artifact_id] != artifact:
                raise ReplayError("expected build artifact identity is inconsistent")
            artifacts[artifact_id] = artifact
        for surface in manifest["surfaces"]:
            surfaces.setdefault(surface["artifactId"], set()).add(surface["id"])
    rows = []
    for artifact_id, artifact in sorted(artifacts.items()):
        observations = []
        for field in ARTIFACT_FIELDS:
            raw = artifact.get(field)
            values = raw if isinstance(raw, list) else [raw]
            observations.append(_observation([value for value in values if value is not None]))
        rows.append([artifact_id, sorted(surfaces.get(artifact_id, set())), observations])
    return rows


def _policy_train_files(
    train: dict[str, Any], root_bindings: dict[str, Path]
) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
    root = train["trainRoot"]
    prefix = train["trainPath"]
    comparison = _load(
        _root_file(root_bindings, root, f"{prefix}/{train['comparisonPath']}"),
        "retained comparison",
    )
    report = _load(
        _root_file(root_bindings, root, f"{prefix}/{train['finalReportPath']}"),
        "retained final report",
    )
    expected = [
        _load(
            _root_file(root_bindings, root, f"{prefix}/{path}"),
            f"retained expected build manifest {platform}",
        )
        for platform, path in sorted(train["expectedBuildManifests"].items())
    ]
    return comparison, report, expected


def reconstruct_bundle(
    *,
    inventory_policy_path: Path,
    inventory_path: Path,
    release_policy_path: Path,
    surface_policy_path: Path,
    root_bindings: dict[str, Path],
) -> dict[str, Any]:
    try:
        roots = _normalize_root_bindings(root_bindings)
        inventory = verify_inventory(inventory_policy_path, inventory_path, roots)
        policy = load_policy(inventory_policy_path)
    except (InventoryError, OSError) as error:
        raise ReplayError(str(error)) from error
    if type(policy.get("schemaVersion")) is not int:
        raise ReplayError("replay inventory policy schema version is invalid")
    surface_policy = _surface_policy_map(_load(surface_policy_path, "surface evidence policy"))
    policy_trains = {train["trainId"]: train for train in policy["trains"]}
    trains = []
    projection_digests: dict[str, str] = {}
    for inventory_train in inventory["trains"]:
        raw_comparison, report, expected = _policy_train_files(
            policy_trains[inventory_train["trainId"]], roots
        )
        inputs = {item["category"]: item for item in inventory_train["inputs"]}
        source_digests = {
            "archived-comparison": canonical_digest(raw_comparison),
            "coordinator-final-report": canonical_digest(report),
            "expected-build-manifests": canonical_digest(
                [canonical_digest(payload) for payload in expected]
            ),
        }
        if any(source_digests[key] != inputs[key]["canonicalDigest"] for key in source_digests):
            raise ReplayError("retained replay source changed after inventory verification")
        try:
            comparison = adapt_comparison_for_replay(raw_comparison)
        except ComparisonAdapterError as error:
            raise ReplayError("retained comparison adapter rejected the comparison") from error
        sources = _source_rows(inventory_train)
        receipt_source = next((row for row in sources if row[0] == "physical-runtime-receipts"), None)
        if receipt_source is None:
            raise ReplayError("replay inventory is missing physical runtime receipts")
        blocked = set(inventory_train["notAdmissibleFor"])
        for risk in inventory_train["residualRisks"]:
            blocked.update(risk["unsupportedClaims"])
        train = {
                "trainId": inventory_train["trainId"],
                "version": inventory_train["version"],
                "buildNumber": inventory_train["buildNumber"],
                "trainClass": inventory_train["trainClass"],
                "trainName": comparison["train"],
                "previousManifestId": comparison["previousManifestId"],
                "currentManifestId": comparison["currentManifestId"],
                "comparisonAdapter": [
                    raw_comparison["schemaVersion"],
                    comparison["schemaVersion"],
                ],
                "comparisonDigest": canonical_digest(raw_comparison),
                "sourceState": _source_state(sources),
                "sourceVerification": sources,
                "admissibleClaims": inventory_train["admissibleClaims"],
                "notAdmissibleFor": inventory_train["notAdmissibleFor"],
                "blockedClaims": sorted(blocked),
                "residualRisks": inventory_train["residualRisks"],
                "runtimeSurfaces": _surface_rows(
                    comparison, report, surface_policy, receipt_source[1]
                ),
                "artifactObservations": _artifact_rows(expected),
            }
        trains.append(train)
        projection_digests[train["trainId"]] = canonical_digest(_source_projection(train))
    verified = sum(row[1] == "verified" for train in trains for row in train["sourceVerification"])
    unverified = sum(
        row[1] == "sources-unverified" for train in trains for row in train["sourceVerification"]
    )
    payload = {
        "schemaVersion": 1,
        "kind": BUNDLE_KIND,
        "algorithm": "sha256",
        "digestDomain": BUNDLE_DOMAIN,
        "inventoryId": inventory["inventoryId"],
        "inventoryDigest": _raw_digest(inventory_path, "replay inventory"),
        **_policy_digests(inventory_policy_path, release_policy_path, surface_policy_path),
        "sourceState": "sources-unverified" if unverified else "verified",
        "summary": {
            "trainCount": len(trains),
            "surfaceCount": sum(len(train["runtimeSurfaces"]) for train in trains),
            "sourceVerifiedInputCount": verified,
            "sourceUnverifiedInputCount": unverified,
            "residualRiskCount": sum(len(train["residualRisks"]) for train in trains),
        },
        "trains": trains,
    }
    _public(payload)
    payload["bundleId"] = canonical_digest(payload)
    validate_bundle(
        payload,
        inventory_policy_path=inventory_policy_path,
        inventory_path=inventory_path,
        release_policy_path=release_policy_path,
        surface_policy_path=surface_policy_path,
        projection_digests=projection_digests,
    )
    return payload


def _validate_observation(value: Any, label: str) -> list[Any]:
    observation = _row(value, 2, label)
    count = _integer(observation[0], f"{label} count")
    if count == 0:
        if observation[1] is not None:
            raise ReplayError(f"{label} is inconsistent")
    else:
        _digest(observation[1], f"{label} digest")
    return observation


def _validate_source_rows(rows: Any, inventory_train: dict[str, Any]) -> list[list[Any]]:
    if not isinstance(rows, list) or len(rows) != len(inventory_train["inputs"]):
        raise ReplayError("replay source verification is invalid")
    for row, expected in zip(rows, inventory_train["inputs"], strict=True):
        row = _row(row, 2, "replay source verification row")
        if row[0] != expected["category"]:
            raise ReplayError("replay source verification metadata is stale")
        incomplete = any(
            risk["category"] == expected["category"]
            and risk["retainedCount"] < risk["referencedCount"]
            for risk in inventory_train["residualRisks"]
        )
        expected_state = (
            "sources-unverified"
            if expected["recoverability"] == "reference-only" or incomplete
            else "verified"
        )
        if row[1] != expected_state:
            raise ReplayError("replay source verification state is invalid")
    return rows


def _validate_surface_rows(
    rows: Any,
    surface_policy: dict[str, tuple[str, str, list[str]]],
    receipt_source_state: str,
    referenced_receipt_count: int,
    scope: dict[str, list[str]],
) -> list[list[Any]]:
    if not isinstance(rows, list) or len(rows) != len(surface_policy):
        raise ReplayError("replay runtime surfaces are invalid")
    seen = set()
    for row in rows:
        row = _row(row, 11, "replay runtime surface row")
        surface = _string(row[0], "replay runtime surface")
        if surface in seen or surface not in surface_policy:
            raise ReplayError("replay runtime surface set is invalid")
        seen.add(surface)
        artifact, device, _ = surface_policy[surface]
        if row[1] != artifact or row[2] != device:
            raise ReplayError("replay runtime surface policy binding is stale")
        reasons = _strings(row[3], "replay reason codes", sorted_unique=False)
        if any(reason not in REASON_CODES for reason in reasons):
            raise ReplayError("replay reason codes are invalid")
        if not isinstance(row[4], str) or len(row[4]) != len(CHANGE_FIELDS) or set(row[4]) - {"0", "1"}:
            raise ReplayError("replay surface change mask is invalid")
        changes = {field: row[4][index] == "1" for index, field in enumerate(CHANGE_FIELDS)}
        new_surface = "new-surface" in reasons
        if new_surface and not all(changes[field] for field in ("render", "runtime", "placement")):
            raise ReplayError("replay new-surface reason contradicts surface changes")
        if reasons != _expected_reason_codes(changes, new_surface=new_surface):
            raise ReplayError("replay reason codes do not match surface changes")
        actions = _row(row[5], len(EVIDENCE_CLASSES), "replay action row")
        if any(not isinstance(action, str) or action not in ACTION_CODES for action in actions):
            raise ReplayError("replay surface actions are invalid")
        if any(
            (surface in scope[evidence_class]) != action.startswith("required:")
            for evidence_class, action in zip(EVIDENCE_CLASSES, actions, strict=True)
        ):
            raise ReplayError("replay surface actions contradict sealed scope")
        if not isinstance(row[6], str) or row[6] not in RUNTIME_STATES:
            raise ReplayError("replay runtime report state is invalid")
        receipts = _integer(row[7], "replay receipt count")
        if not isinstance(row[8], str) or row[8] not in RECEIPT_STATES or (receipts == 0) != (row[8] == "not-referenced"):
            raise ReplayError("replay receipt body state is invalid")
        if receipts and row[8] != receipt_source_state:
            raise ReplayError("replay receipt body state contradicts source verification")
        hosts = _integer(row[9], "replay host OS count")
        if (hosts == 0 and row[10] is not None) or (hosts > 0 and not isinstance(row[10], str)):
            raise ReplayError("replay host OS observation is invalid")
        if hosts:
            _digest(row[10], "replay host OS digest")
    if sum(row[7] for row in rows if row[0] in scope["actual-runtime"]) != referenced_receipt_count:
        raise ReplayError("replay receipt references contradict sealed inventory")
    return rows


def _validate_artifact_rows(rows: Any, expected: dict[str, set[str]]) -> list[list[Any]]:
    if not isinstance(rows, list) or len(rows) != len(expected):
        raise ReplayError("replay artifact observations are invalid")
    seen = set()
    for row in rows:
        row = _row(row, 3, "replay artifact row")
        artifact = _string(row[0], "replay artifact")
        if artifact in seen or artifact not in expected:
            raise ReplayError("replay artifact observations contain duplicates")
        seen.add(artifact)
        surfaces = _strings(row[1], "replay artifact surfaces")
        if set(surfaces) != expected[artifact]:
            raise ReplayError("replay artifact surface binding is invalid")
        fields = _row(row[2], len(ARTIFACT_FIELDS), "replay artifact fields")
        for field in fields:
            _validate_observation(field, "replay artifact field")
    if seen != set(expected):
        raise ReplayError("replay artifact set is incomplete")
    return rows


def validate_bundle(
    bundle: Any,
    *,
    inventory_policy_path: Path,
    inventory_path: Path,
    release_policy_path: Path,
    surface_policy_path: Path,
    projection_digests: dict[str, str] | None = None,
) -> dict[str, Any]:
    bundle = _exact(bundle, BUNDLE_KEYS, "replay bundle")
    if (
        type(bundle["schemaVersion"]) is not int
        or bundle["schemaVersion"] != 1
        or bundle["kind"] != BUNDLE_KIND
        or bundle["algorithm"] != "sha256"
        or bundle["digestDomain"] != BUNDLE_DOMAIN
    ):
        raise ReplayError("replay bundle identity is invalid")
    try:
        inventory = check_inventory(inventory_policy_path, inventory_path)
    except (InventoryError, OSError) as error:
        raise ReplayError(str(error)) from error
    expected_bindings = {
        "inventoryId": inventory["inventoryId"],
        "inventoryDigest": _raw_digest(inventory_path, "replay inventory"),
        **_policy_digests(inventory_policy_path, release_policy_path, surface_policy_path),
    }
    if any(bundle[key] != value for key, value in expected_bindings.items()):
        raise ReplayError("replay bundle policy or inventory binding is stale")
    if bundle["bundleId"] != canonical_digest(
        {key: value for key, value in bundle.items() if key != "bundleId"}
    ):
        raise ReplayError("replay bundle self-digest is invalid")
    surface_policy = _surface_policy_map(_load(surface_policy_path, "surface evidence policy"))
    expected_artifacts: dict[str, set[str]] = {}
    for surface, (artifact, _, _) in surface_policy.items():
        expected_artifacts.setdefault(artifact, set()).add(surface)
    trains = bundle["trains"]
    if not isinstance(trains, list) or len(trains) != len(inventory["trains"]):
        raise ReplayError("replay bundle train set is invalid")
    current_manifest_ids: set[str] = set()
    for train, inventory_train in zip(trains, inventory["trains"], strict=True):
        train = _exact(train, BUNDLE_TRAIN_KEYS, "replay bundle train")
        for key in ("trainId", "version", "buildNumber", "trainClass"):
            if train[key] != inventory_train[key]:
                raise ReplayError("replay bundle train identity is stale")
        if train["admissibleClaims"] != inventory_train["admissibleClaims"] or train[
            "notAdmissibleFor"
        ] != inventory_train["notAdmissibleFor"] or train["residualRisks"] != inventory_train[
            "residualRisks"
        ]:
            raise ReplayError("replay bundle inventory classification is stale")
        blocked = sorted(
            set(inventory_train["notAdmissibleFor"])
            | {
                claim
                for risk in inventory_train["residualRisks"]
                for claim in risk["unsupportedClaims"]
            }
        )
        if train["blockedClaims"] != blocked:
            raise ReplayError("replay bundle blocked claims are inconsistent")
        if set(train["admissibleClaims"]).intersection(blocked):
            raise ReplayError("replay bundle claims cannot be both admissible and blocked")
        _string(train["trainName"], "replay train name")
        if train["previousManifestId"] != inventory_train["previousManifestId"] or train[
            "currentManifestId"
        ] != inventory_train["currentManifestId"]:
            raise ReplayError("replay manifest lineage is stale")
        if train["currentManifestId"] in current_manifest_ids:
            raise ReplayError("replay current manifest IDs must be unique")
        current_manifest_ids.add(train["currentManifestId"])
        comparison = next(
            item for item in inventory_train["inputs"] if item["category"] == "archived-comparison"
        )
        if train["comparisonDigest"] != comparison["canonicalDigest"]:
            raise ReplayError("replay comparison digest is stale")
        adapter = _row(train["comparisonAdapter"], 2, "replay comparison adapter")
        if (
            any(type(version) is not int for version in adapter)
            or tuple(adapter) not in {(1, 2), (2, 2), (3, 3)}
        ):
            raise ReplayError("replay comparison adapter is invalid")
        sources = _validate_source_rows(train["sourceVerification"], inventory_train)
        source_state = _source_state(sources)
        if not isinstance(train["sourceState"], str) or train["sourceState"] != source_state:
            raise ReplayError("replay train source state is inconsistent")
        receipt_state = next(
            (row[1] for row in sources if row[0] == "physical-runtime-receipts"), None
        )
        receipt_input = next(
            (item for item in inventory_train["inputs"] if item["category"] == "physical-runtime-receipts"),
            None,
        )
        if receipt_state is None or receipt_input is None:
            raise ReplayError("replay inventory is missing physical runtime receipts")
        surface_rows = _validate_surface_rows(
            train["runtimeSurfaces"],
            surface_policy,
            receipt_state,
            receipt_input["referencedCount"],
            inventory_train["scope"],
        )
        _validate_artifact_rows(train["artifactObservations"], expected_artifacts)
        expected_projection = SOURCE_PROJECTION_DIGESTS.get(train["trainId"])
        if expected_projection is None and projection_digests is not None:
            expected_projection = projection_digests.get(train["trainId"])
        if expected_projection != canonical_digest(_source_projection(train)):
            raise ReplayError("replay source projection is stale")
    summary = _exact(bundle["summary"], BUNDLE_SUMMARY_KEYS, "replay bundle summary")
    expected_summary = {
        "trainCount": len(trains),
        "surfaceCount": sum(len(train["runtimeSurfaces"]) for train in trains),
        "sourceVerifiedInputCount": sum(
            row[1] == "verified" for train in trains for row in train["sourceVerification"]
        ),
        "sourceUnverifiedInputCount": sum(
            row[1] == "sources-unverified"
            for train in trains
            for row in train["sourceVerification"]
        ),
        "residualRiskCount": sum(len(train["residualRisks"]) for train in trains),
    }
    if summary != expected_summary:
        raise ReplayError("replay bundle summary is inconsistent")
    state = "sources-unverified" if summary["sourceUnverifiedInputCount"] else "verified"
    if bundle["sourceState"] != state:
        raise ReplayError("replay bundle source state is inconsistent")
    _public(bundle)
    return bundle


def _surface_dict(row: list[Any]) -> dict[str, Any]:
    return {
        "surface": row[0],
        "artifact": row[1],
        "device": row[2],
        "changes": {field: row[4][index] == "1" for index, field in enumerate(CHANGE_FIELDS)},
        "actions": row[5],
        "runtime": row[6:9],
        "hostOS": row[9:11],
    }


def _field_analysis(train: dict[str, Any], predecessor: dict[str, Any] | None) -> list[list[Any]]:
    previous_artifacts = {row[0]: row for row in predecessor["artifactObservations"]} if predecessor else {}
    surfaces = {_surface_dict(row)["surface"]: _surface_dict(row) for row in train["runtimeSurfaces"]}
    counts = {field: [0, 0, 0, 0, 0] for field in (*ARTIFACT_FIELDS, "hostOS")}

    def record(field: str, current: list[Any], previous: list[Any] | None, semantic: bool) -> None:
        observed, stable, changed, unavailable, potential = counts[field]
        observed += 1
        if current[0] == 0 or previous is None or previous[0] == 0:
            unavailable += 1
        elif current[1] == previous[1]:
            stable += 1
        else:
            changed += 1
            potential += int(not semantic)
        counts[field] = [observed, stable, changed, unavailable, potential]

    for artifact in train["artifactObservations"]:
        previous = previous_artifacts.get(artifact[0])
        semantic = any(
            surfaces[surface]["changes"][change]
            for surface in artifact[1]
            for change in ("render", "runtime", "placement", "contract")
        )
        for index, field in enumerate(ARTIFACT_FIELDS):
            record(field, artifact[2][index], previous[2][index] if previous else None, semantic)
    previous_surfaces = {
        row[0]: _surface_dict(row) for row in predecessor["runtimeSurfaces"]
    } if predecessor else {}
    for surface, current in surfaces.items():
        previous = previous_surfaces.get(surface)
        record(
            "hostOS",
            current["hostOS"],
            previous["hostOS"] if previous else None,
            current["changes"]["placement"] or current["changes"]["contract"],
        )
    return [[field, *counts[field]] for field in (*ARTIFACT_FIELDS, "hostOS")]


def build_report(bundle: dict[str, Any]) -> dict[str, Any]:
    by_manifest = {train["currentManifestId"]: train for train in bundle["trains"]}
    trains = []
    for train in bundle["trains"]:
        surfaces = [_surface_dict(row) for row in train["runtimeSurfaces"]]
        runtime_rows = []
        placement_rows = []
        for surface in surfaces:
            required = [
                evidence_class
                for evidence_class, action in zip(EVIDENCE_CLASSES, surface["actions"], strict=True)
                if action.startswith("required:")
            ]
            skipped = [
                f"{evidence_class}:{action.split(':', 1)[1]}"
                for evidence_class, action in zip(EVIDENCE_CLASSES, surface["actions"], strict=True)
                if action.startswith("skipped:")
            ]
            placement_action, placement_reason = surface["actions"][2].split(":", 1)
            runtime_rows.append(
                [
                    surface["surface"],
                    surface["artifact"],
                    surface["device"],
                    required,
                    *surface["runtime"],
                    skipped,
                ]
            )
            placement_rows.append(
                [surface["surface"], surface["device"], placement_action, placement_reason]
            )
        trains.append(
            {
                "trainId": train["trainId"],
                "version": train["version"],
                "buildNumber": train["buildNumber"],
                "trainClass": train["trainClass"],
                "sourceState": train["sourceState"],
                "sourceVerification": train["sourceVerification"],
                "deviceClasses": sorted({surface["device"] for surface in surfaces}),
                "runtimeSurfaces": runtime_rows,
                "placementActions": placement_rows,
                "artifactFieldAnalysis": _field_analysis(
                    train, by_manifest.get(train["previousManifestId"])
                ),
                "admissibleClaims": train["admissibleClaims"],
                "blockedClaims": train["blockedClaims"],
                "residualRisks": train["residualRisks"],
            }
        )
    payload = {
        "schemaVersion": 1,
        "kind": REPORT_KIND,
        "algorithm": "sha256",
        "digestDomain": REPORT_DOMAIN,
        "inventoryId": bundle["inventoryId"],
        "inventoryDigest": bundle["inventoryDigest"],
        "inventoryPolicyDigest": bundle["inventoryPolicyDigest"],
        "releasePolicyDigest": bundle["releasePolicyDigest"],
        "surfacePolicyDigest": bundle["surfacePolicyDigest"],
        "bundleId": bundle["bundleId"],
        "sourceState": bundle["sourceState"],
        "summary": {
            "trainCount": len(trains),
            "surfaceCount": sum(len(train["runtimeSurfaces"]) for train in trains),
            "sourceUnverifiedTrainCount": sum(
                train["sourceState"] == "sources-unverified" for train in trains
            ),
            "admissibleClaimCount": sum(len(train["admissibleClaims"]) for train in trains),
            "blockedClaimCount": sum(len(train["blockedClaims"]) for train in trains),
            "residualRiskCount": sum(len(train["residualRisks"]) for train in trains),
            "potentialFalsePositiveCount": sum(
                row[5] for train in trains for row in train["artifactFieldAnalysis"]
            ),
        },
        "trains": trains,
    }
    _public(payload)
    payload["reportId"] = canonical_digest(payload)
    validate_report(payload, expected_bundle=bundle)
    return payload


def validate_report(
    report: Any, *, expected_bundle: dict[str, Any] | None = None
) -> dict[str, Any]:
    report = _exact(report, REPORT_KEYS, "replay report")
    if (
        type(report["schemaVersion"]) is not int
        or report["schemaVersion"] != 1
        or report["kind"] != REPORT_KIND
        or report["algorithm"] != "sha256"
        or report["digestDomain"] != REPORT_DOMAIN
    ):
        raise ReplayError("replay report identity is invalid")
    if report["reportId"] != canonical_digest(
        {key: value for key, value in report.items() if key != "reportId"}
    ):
        raise ReplayError("replay report self-digest is invalid")
    for key in (
        "inventoryId",
        "inventoryDigest",
        "inventoryPolicyDigest",
        "releasePolicyDigest",
        "surfacePolicyDigest",
        "bundleId",
    ):
        _digest(report[key], f"replay report {key}")
    if not isinstance(report["sourceState"], str) or report["sourceState"] not in SOURCE_STATES:
        raise ReplayError("replay report source state is invalid")
    if expected_bundle is not None:
        for key in (
            "inventoryId",
            "inventoryDigest",
            "inventoryPolicyDigest",
            "releasePolicyDigest",
            "surfacePolicyDigest",
            "bundleId",
            "sourceState",
        ):
            if report[key] != expected_bundle[key]:
                raise ReplayError("replay report bundle binding is stale")
    trains = report["trains"]
    if not isinstance(trains, list):
        raise ReplayError("replay report trains are invalid")
    train_ids: set[str] = set()
    for train in trains:
        train = _exact(train, REPORT_TRAIN_KEYS, "replay report train")
        for key in ("trainId", "version", "buildNumber", "trainClass"):
            _string(train[key], f"replay report {key}")
        if (
            train["trainId"] in train_ids
            or not isinstance(train["sourceState"], str)
            or train["sourceState"] not in SOURCE_STATES
        ):
            raise ReplayError("replay report train identity or source state is invalid")
        train_ids.add(train["trainId"])
        _strings(train["deviceClasses"], "replay report device classes")
        _strings(train["admissibleClaims"], "replay report admissible claims")
        _strings(train["blockedClaims"], "replay report blocked claims")
        if set(train["admissibleClaims"]).intersection(train["blockedClaims"]):
            raise ReplayError("replay report claims cannot be both admissible and blocked")
        _risks(train["residualRisks"], "replay report residual risks")
        if not isinstance(train["sourceVerification"], list):
            raise ReplayError("replay report source verification is invalid")
        for row in train["sourceVerification"]:
            row = _row(row, 2, "replay report source row")
            _string(row[0], "replay report source category")
            if not isinstance(row[1], str) or row[1] not in SOURCE_STATES:
                raise ReplayError("replay report source verification state is invalid")
        if not isinstance(train["runtimeSurfaces"], list):
            raise ReplayError("replay report runtime surfaces are invalid")
        for row in train["runtimeSurfaces"]:
            row = _row(row, 8, "replay report runtime surface row")
            for value in row[:3]:
                _string(value, "replay report runtime surface value")
            if not isinstance(row[3], list) or any(
                not isinstance(value, str) or value not in EVIDENCE_CLASSES for value in row[3]
            ):
                raise ReplayError("replay report required evidence is invalid")
            if not isinstance(row[4], str) or row[4] not in RUNTIME_STATES:
                raise ReplayError("replay report runtime state is invalid")
            receipt_count = _integer(row[5], "replay report receipt count")
            if not isinstance(row[6], str) or row[6] not in RECEIPT_STATES or (receipt_count == 0) != (
                row[6] == "not-referenced"
            ):
                raise ReplayError("replay report receipt body state is invalid")
            if not isinstance(row[7], list) or any(
                not isinstance(value, str) or value not in SKIPPED_REPORT_CODES for value in row[7]
            ):
                raise ReplayError("replay report skipped reasons are invalid")
        if not isinstance(train["placementActions"], list):
            raise ReplayError("replay report placement actions are invalid")
        for row in train["placementActions"]:
            row = _row(row, 4, "replay report placement row")
            for value in row:
                _string(value, "replay report placement value")
            if f"{row[2]}:{row[3]}" not in ACTION_CODES:
                raise ReplayError("replay report placement action is invalid")
        fields = train["artifactFieldAnalysis"]
        if not isinstance(fields, list) or any(
            not isinstance(row, list) or len(row) != 6 for row in fields
        ):
            raise ReplayError("replay report artifact field analysis is invalid")
        if [row[0] for row in fields] != [*ARTIFACT_FIELDS, "hostOS"]:
            raise ReplayError("replay report artifact field analysis is invalid")
        for row in fields:
            row = _row(row, 6, "replay report artifact field row")
            _string(row[0], "replay report artifact field")
            for value in row[1:]:
                _integer(value, "replay report artifact field count")
            if row[2] + row[3] + row[4] != row[1] or row[5] > row[3]:
                raise ReplayError("replay report artifact field counts are inconsistent")
    summary = _exact(report["summary"], REPORT_SUMMARY_KEYS, "replay report summary")
    for key, value in summary.items():
        _integer(value, f"replay report summary {key}")
    expected_summary = {
        "trainCount": len(trains),
        "surfaceCount": sum(len(train["runtimeSurfaces"]) for train in trains),
        "sourceUnverifiedTrainCount": sum(
            train["sourceState"] == "sources-unverified" for train in trains
        ),
        "admissibleClaimCount": sum(len(train["admissibleClaims"]) for train in trains),
        "blockedClaimCount": sum(len(train["blockedClaims"]) for train in trains),
        "residualRiskCount": sum(len(train["residualRisks"]) for train in trains),
        "potentialFalsePositiveCount": sum(
            row[5] for train in trains for row in train["artifactFieldAnalysis"]
        ),
    }
    if summary != expected_summary:
        raise ReplayError("replay report summary is inconsistent")
    _public(report)
    return report


def check_replay(
    *,
    inventory_policy_path: Path,
    inventory_path: Path,
    release_policy_path: Path,
    surface_policy_path: Path,
    bundle_path: Path,
    report_path: Path,
) -> dict[str, Any]:
    bundle = validate_bundle(
        _load(bundle_path, "replay bundle"),
        inventory_policy_path=inventory_policy_path,
        inventory_path=inventory_path,
        release_policy_path=release_policy_path,
        surface_policy_path=surface_policy_path,
    )
    if _read_bytes(bundle_path, "replay bundle") != render_artifact(bundle):
        raise ReplayError("replay bundle is not byte-identical to its canonical form")
    expected_report = build_report(bundle)
    report = validate_report(_load(report_path, "replay report"), expected_bundle=bundle)
    if report != expected_report or _read_bytes(report_path, "replay report") != render_artifact(expected_report):
        raise ReplayError("replay report is stale")
    return report


def verify_replay(
    *,
    inventory_policy_path: Path,
    inventory_path: Path,
    release_policy_path: Path,
    surface_policy_path: Path,
    bundle_path: Path,
    report_path: Path,
    root_bindings: dict[str, Path],
) -> dict[str, Any]:
    bundle = reconstruct_bundle(
        inventory_policy_path=inventory_policy_path,
        inventory_path=inventory_path,
        release_policy_path=release_policy_path,
        surface_policy_path=surface_policy_path,
        root_bindings=root_bindings,
    )
    if _read_bytes(bundle_path, "replay bundle") != render_artifact(bundle):
        raise ReplayError("replay bundle does not match retained sources")
    report = build_report(bundle)
    if _read_bytes(report_path, "replay report") != render_artifact(report):
        raise ReplayError("replay report does not match retained sources")
    return report


def release_gate_diagnostics(
    replay_report: dict[str, Any], release_evidence: dict[str, Any]
) -> dict[str, Any]:
    validate_report(replay_report)
    ledger_id = release_evidence.get("ledgerID") if isinstance(release_evidence, dict) else None
    state = release_evidence.get("state") if isinstance(release_evidence, dict) else None
    if (
        not isinstance(release_evidence, dict)
        or set(release_evidence) != LEDGER_KEYS
        or type(release_evidence.get("schemaVersion")) is not int
        or release_evidence.get("schemaVersion") != RELEASE_EVIDENCE_SCHEMA_VERSION
        or release_evidence.get("kind") != RELEASE_EVIDENCE_KIND
        or not isinstance(release_evidence.get("mode"), str)
        or release_evidence.get("mode") not in MODES
        or not isinstance(release_evidence.get("train"), str)
        or release_evidence.get("train") not in TRAINS
        or not isinstance(state, str)
        or state not in LEDGER_STATES
        or ledger_id != _ledger_id(release_evidence)
    ):
        raise ReplayError("release evidence is invalid for replay diagnostics")
    _digest(ledger_id, "release evidence ledger ID")
    risks = [
        {"trainId": train["trainId"], **risk}
        for train in replay_report["trains"]
        for risk in train["residualRisks"]
    ]
    payload = {
        "schemaVersion": 1,
        "kind": DIAGNOSTICS_KIND,
        "algorithm": "sha256",
        "digestDomain": DIAGNOSTICS_DOMAIN,
        "releaseEvidenceLedgerId": ledger_id,
        "releaseEvidenceState": state,
        "replayReportId": replay_report["reportId"],
        "sourceState": replay_report["sourceState"],
        "sourcesUnverifiedTrains": sorted([
            train["trainId"]
            for train in replay_report["trains"]
            if train["sourceState"] == "sources-unverified"
        ]),
        "residualRisks": risks,
    }
    _public(payload)
    payload["diagnosticsId"] = canonical_digest(payload)
    return validate_release_gate_diagnostics(payload)


def validate_release_gate_diagnostics(payload: Any) -> dict[str, Any]:
    payload = _exact(payload, DIAGNOSTICS_KEYS, "release gate replay diagnostics")
    if (
        type(payload["schemaVersion"]) is not int
        or payload["schemaVersion"] != 1
        or payload["kind"] != DIAGNOSTICS_KIND
        or payload["algorithm"] != "sha256"
        or payload["digestDomain"] != DIAGNOSTICS_DOMAIN
    ):
        raise ReplayError("release gate replay diagnostics identity is invalid")
    if payload["diagnosticsId"] != canonical_digest(
        {key: value for key, value in payload.items() if key != "diagnosticsId"}
    ):
        raise ReplayError("release gate replay diagnostics self-digest is invalid")
    _digest(payload["releaseEvidenceLedgerId"], "release gate replay ledger ID")
    _digest(payload["replayReportId"], "release gate replay report ID")
    if not isinstance(payload["releaseEvidenceState"], str) or payload["releaseEvidenceState"] not in LEDGER_STATES:
        raise ReplayError("release gate replay ledger state is invalid")
    if not isinstance(payload["sourceState"], str) or payload["sourceState"] not in SOURCE_STATES:
        raise ReplayError("release gate replay source state is invalid")
    unverified = _strings(payload["sourcesUnverifiedTrains"], "release gate replay source trains")
    if (payload["sourceState"] == "sources-unverified") != bool(unverified):
        raise ReplayError("release gate replay source claims are inconsistent")
    if not isinstance(payload["residualRisks"], list):
        raise ReplayError("release gate replay diagnostics risks are invalid")
    for risk in payload["residualRisks"]:
        risk = _exact(risk, DIAGNOSTIC_RISK_KEYS, "release gate replay risk")
        for key in ("trainId", "code", "category"):
            _string(risk[key], f"release gate replay risk {key}")
        _integer(risk["referencedCount"], "release gate replay referenced count")
        _integer(risk["retainedCount"], "release gate replay retained count")
        _strings(risk["unsupportedClaims"], "release gate replay unsupported claims")
    _public(payload)
    return payload


def write_json(payload: dict[str, Any], path: Path) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "wb", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as handle:
            temporary = Path(handle.name)
            handle.write(render_artifact(payload))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except OSError as error:
        raise ReplayError("replay output is unavailable") from error


def _read_bytes(path: Path, label: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as error:
        raise ReplayError(f"{label} is unavailable or invalid") from error
