from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


POLICY_KIND = "context-panel-replay-inventory-policy"
INVENTORY_KIND = "context-panel-replay-input-inventory"
LINEAGE_KIND = "context-panel-release-evidence-lineage"
LEDGER_KIND = "context-panel-release-evidence"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")
BUILD_PATTERN = re.compile(r"^\d{12}$")
TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.-]{0,95}$")
SURFACE_PATTERN = re.compile(r"^[a-z0-9]+(?:[.-][a-z0-9]+)*$")
UNSAFE_STRING_PATTERNS = (
    re.compile(r"(?:^|\s)(?:/Users/|/Volumes/|/private/|~/|file://)"),
    re.compile(r"\b[A-Z0-9]{10}\.group\."),
    re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"),
    re.compile(r"-----BEGIN [^-]+-----"),
    re.compile(r"\b(?:AuthKey|Bearer|password|secret|credential)\b", re.IGNORECASE),
)
UNSAFE_KEY_PATTERN = re.compile(
    r"(?:authkey|bearer|password|secret|credential)", re.IGNORECASE
)
ENTRY_KEYS = {
    "category",
    "sourceClass",
    "sourceRoot",
    "sourcePath",
    "byteSize",
    "rawDigest",
    "canonicalDigest",
    "recoverability",
    "selectionRule",
    "versionControl",
}
TRAIN_INVENTORY_KEYS = {
    "trainId",
    "version",
    "buildNumber",
    "trainClass",
    "admissibleClaims",
    "notAdmissibleFor",
    "state",
    "previousManifestId",
    "currentManifestId",
    "contractFingerprint",
    "scope",
    "inputs",
    "missing",
    "residualRisks",
}
SELECTION_RULES = {
    "previous-source-manifest": "comparison.previousManifestId",
    "current-source-manifest": "comparison.currentManifestId",
    "archived-comparison": "ledger.comparisonDigest",
    "coordinator-final-report": "ledger.validationReportDigest",
    "expected-build-manifests": "lineage.generation.expectedBuildManifests",
    "release-evidence-ledger": "lineage.ledger",
    "release-evidence-lineage": "policy.required-ledger",
    "physical-runtime-receipts": "final-report.runtimeSurfaces.receiptIDs",
    "visual-approvals": {
        "final-report.requirement-and-decision-set",
        "final-report.visualApprovals",
    },
}
SCOPE_KEYS = {"actual-runtime", "os-composited-placement", "shared-view"}
SUMMARY_KEYS = {
    "trainCount",
    "inputCount",
    "missingCount",
    "residualRiskCount",
    "fragileInputCount",
    "referenceOnlyInputCount",
}
RECEIPT_RISK_KEYS = {
    "code",
    "category",
    "referencedCount",
    "retainedCount",
    "unsupportedClaims",
}


class InventoryError(ValueError):
    pass


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def raw_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def render_json(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InventoryError("JSON contains duplicate object keys")
        result[key] = value
    return result


def load_json(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink():
        raise InventoryError(f"{label} must not be a symlink")
    try:
        value = json.loads(path.read_text(), object_pairs_hook=_reject_duplicate_keys)
    except InventoryError:
        raise
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError(f"{label} is unavailable or invalid JSON") from error
    if not isinstance(value, dict):
        raise InventoryError(f"{label} must be a JSON object")
    return value


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise InventoryError(f"{label} has an invalid shape")


def _token(value: Any, label: str) -> str:
    if not isinstance(value, str) or TOKEN_PATTERN.fullmatch(value) is None:
        raise InventoryError(f"{label} is invalid")
    return value


def _relative_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise InventoryError(f"{label} is invalid")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or ".." in path.parts
        or "." in path.parts
        or value != str(path)
    ):
        raise InventoryError(f"{label} must be a normalized relative path")
    if any(pattern.search(value) for pattern in UNSAFE_STRING_PATTERNS):
        raise InventoryError(f"{label} is not public-safe")
    return value


def load_policy(path: Path) -> dict[str, Any]:
    policy = load_json(path, "replay inventory policy")
    _exact_keys(
        policy,
        {
            "schemaVersion",
            "kind",
            "algorithm",
            "digestDomain",
            "requiredCategories",
            "recoverabilityClasses",
            "sourceRoots",
            "inadmissibleSourceClasses",
            "trains",
        },
        "replay inventory policy",
    )
    if (
        policy.get("schemaVersion") != 1
        or policy.get("kind") != POLICY_KIND
        or policy.get("algorithm") != "sha256"
        or policy.get("digestDomain") != "context-panel.replay-inventory.v1"
    ):
        raise InventoryError("replay inventory policy identity is invalid")
    required = policy.get("requiredCategories")
    recoverability = policy.get("recoverabilityClasses")
    roots = policy.get("sourceRoots")
    trains = policy.get("trains")
    if (
        not isinstance(required, list)
        or len(required) != len(set(required))
        or not isinstance(recoverability, list)
        or set(recoverability) != {"durable", "single-copy", "fragile", "reference-only"}
        or not isinstance(roots, dict)
        or not roots
        or not isinstance(trains, list)
        or not trains
    ):
        raise InventoryError("replay inventory policy collections are invalid")
    for root_id, definition in roots.items():
        _token(root_id, "source root id")
        if not isinstance(definition, dict):
            raise InventoryError("source root definition is invalid")
        _exact_keys(
            definition,
            {"sourceClass", "defaultRecoverability", "versionControl"},
            "source root",
        )
        _token(definition.get("sourceClass"), "source class")
        if definition.get("defaultRecoverability") not in recoverability:
            raise InventoryError("source root recoverability is invalid")
        if definition.get("versionControl") not in {"absent", "committed"}:
            raise InventoryError("source root version-control state is invalid")
        if definition["sourceClass"] in policy.get("inadmissibleSourceClasses", []):
            raise InventoryError("policy source root is inadmissible")
    train_ids: set[str] = set()
    for train in trains:
        _validate_train_policy(train, roots)
        if train["trainId"] in train_ids:
            raise InventoryError("train ids must be unique")
        train_ids.add(train["trainId"])
    return policy


def _validate_train_policy(train: Any, roots: dict[str, Any]) -> None:
    if not isinstance(train, dict):
        raise InventoryError("train policy is invalid")
    required = {
        "trainId",
        "version",
        "buildNumber",
        "trainClass",
        "admissibleClaims",
        "trainRoot",
        "trainPath",
        "previousManifest",
        "currentManifestPath",
        "comparisonPath",
        "finalReportPath",
        "lineagePath",
        "ledgerPath",
        "expectedBuildManifests",
        "runtimeReceiptDirs",
        "visualApprovals",
        "sealedMetadataDigest",
    }
    optional = {"notAdmissibleFor"}
    if not required <= set(train) or set(train) - required - optional:
        raise InventoryError("train policy shape is invalid")
    if (
        not isinstance(train.get("version"), str)
        or VERSION_PATTERN.fullmatch(train["version"]) is None
        or not isinstance(train.get("buildNumber"), str)
        or BUILD_PATTERN.fullmatch(train["buildNumber"]) is None
        or train.get("trainId") != f"{train['version']}-{train['buildNumber']}"
    ):
        raise InventoryError("train target is invalid")
    _token(train.get("trainClass"), "train class")
    if train.get("trainRoot") not in roots:
        raise InventoryError("train source root is invalid")
    for key in (
        "trainPath",
        "currentManifestPath",
        "comparisonPath",
        "finalReportPath",
        "lineagePath",
        "ledgerPath",
    ):
        _relative_path(train.get(key), key)
    previous = train.get("previousManifest")
    if not isinstance(previous, dict) or set(previous) != {"root", "path"}:
        raise InventoryError("previous manifest locator is invalid")
    if previous.get("root") not in roots:
        raise InventoryError("previous manifest root is invalid")
    _relative_path(previous.get("path"), "previous manifest path")
    expected = train.get("expectedBuildManifests")
    if not isinstance(expected, dict) or set(expected) != {"ios", "macos", "tvos", "visionos"}:
        raise InventoryError("expected-build manifest map is invalid")
    for value in expected.values():
        _relative_path(value, "expected-build manifest path")
    receipt_dirs = train.get("runtimeReceiptDirs")
    if not isinstance(receipt_dirs, list) or len(receipt_dirs) != len(set(receipt_dirs)):
        raise InventoryError("runtime receipt directories are invalid")
    for value in receipt_dirs:
        _relative_path(value, "runtime receipt directory")
    visual = train.get("visualApprovals")
    if not isinstance(visual, dict) or visual.get("mode") not in {"file", "embedded"}:
        raise InventoryError("visual approval locator is invalid")
    if visual["mode"] == "file":
        if set(visual) != {"mode", "path"}:
            raise InventoryError("visual approval file locator is invalid")
        _relative_path(visual.get("path"), "visual approval path")
    elif set(visual) != {"mode", "pointer"} or visual.get("pointer") != "visualApprovals":
        raise InventoryError("visual approval embedded locator is invalid")
    for key in ("admissibleClaims", "notAdmissibleFor"):
        values = train.get(key, [])
        if not isinstance(values, list) or values != sorted(set(values)):
            raise InventoryError(f"{key} is invalid")
        for value in values:
            _token(value, key)
    _validate_digest(train.get("sealedMetadataDigest"), "sealed metadata digest")


def parse_root_bindings(values: list[str]) -> dict[str, Path]:
    roots: dict[str, Path] = {}
    for value in values:
        root_id, separator, raw_path = value.partition("=")
        if not separator or not root_id or not raw_path or root_id in roots:
            raise InventoryError("root bindings must use unique ROOT_ID=ABSOLUTE_PATH values")
        path = Path(raw_path)
        if not path.is_absolute() or path.is_symlink() or not path.is_dir():
            raise InventoryError(f"source root is unavailable: {root_id}")
        roots[_token(root_id, "root binding id")] = path.resolve()
    return roots


def _normalize_root_bindings(root_bindings: dict[str, Path]) -> dict[str, Path]:
    normalized: dict[str, Path] = {}
    for root_id, path in root_bindings.items():
        if not isinstance(path, Path):
            path = Path(path)
        if not path.is_absolute() or path.is_symlink() or not path.is_dir():
            raise InventoryError(f"source root is unavailable: {root_id}")
        normalized[root_id] = path.resolve()
    return normalized


def _assert_contained(root: Path, candidate: Path, label: str) -> None:
    try:
        relative = candidate.relative_to(root)
    except ValueError as error:
        raise InventoryError(f"{label} escapes its source root") from error
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise InventoryError(f"{label} must not traverse a symlink")
    try:
        candidate.resolve().relative_to(root)
    except (OSError, ValueError) as error:
        raise InventoryError(f"{label} escapes its source root") from error


def _resolve(roots: dict[str, Path], root_id: str, relative: str, label: str) -> Path:
    root = roots.get(root_id)
    if root is None:
        raise InventoryError(f"missing source root binding: {root_id}")
    candidate = root / _relative_path(relative, label)
    _assert_contained(root, candidate, label)
    if not candidate.is_file():
        raise InventoryError(f"{label} is missing")
    return candidate


def _resolve_directory(
    roots: dict[str, Path],
    root_id: str,
    relative: str,
    label: str,
) -> Path:
    root = roots.get(root_id)
    if root is None:
        raise InventoryError(f"missing source root binding: {root_id}")
    candidate = root / _relative_path(relative, label)
    _assert_contained(root, candidate, label)
    if not candidate.is_dir():
        raise InventoryError(f"{label} is missing")
    return candidate


def _train_relative(train_path: str, path: str) -> str:
    return str(PurePosixPath(train_path) / PurePosixPath(path))


def _json_entry(
    *,
    category: str,
    root_id: str,
    relative_path: str,
    roots: dict[str, Path],
    root_policy: dict[str, Any],
    selection_rule: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    path = _resolve(roots, root_id, relative_path, category)
    payload = load_json(path, category)
    entry = {
        "category": category,
        "sourceClass": root_policy[root_id]["sourceClass"],
        "sourceRoot": root_id,
        "sourcePath": relative_path,
        "byteSize": path.stat().st_size,
        "rawDigest": raw_digest(path),
        "canonicalDigest": canonical_digest(payload),
        "recoverability": root_policy[root_id]["defaultRecoverability"],
        "selectionRule": selection_rule,
        "versionControl": root_policy[root_id]["versionControl"],
    }
    return entry, payload


def _set_entry(
    *,
    category: str,
    root_id: str,
    members: dict[str, str],
    train_path: str,
    roots: dict[str, Path],
    root_policy: dict[str, Any],
    selection_rule: str,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payloads: list[dict[str, Any]] = []
    digests: list[dict[str, str]] = []
    total_size = 0
    for member, member_path in sorted(members.items()):
        relative_path = _train_relative(train_path, member_path)
        path = _resolve(roots, root_id, relative_path, f"{category}:{member}")
        payload = load_json(path, f"{category}:{member}")
        payloads.append(payload)
        digests.append({"member": member, "rawDigest": raw_digest(path), "canonicalDigest": canonical_digest(payload)})
        total_size += path.stat().st_size
    return (
        {
            "category": category,
            "sourceClass": root_policy[root_id]["sourceClass"],
            "sourceRoot": root_id,
            "sourcePath": train_path,
            "byteSize": total_size,
            "rawDigest": canonical_digest(digests),
            "canonicalDigest": canonical_digest([canonical_digest(payload) for payload in payloads]),
            "recoverability": root_policy[root_id]["defaultRecoverability"],
            "selectionRule": selection_rule,
            "versionControl": root_policy[root_id]["versionControl"],
            "memberCount": len(payloads),
        },
        payloads,
    )


def _decision_set(payload: dict[str, Any]) -> set[tuple[str, str]]:
    requirements = payload.get("requirements")
    if not isinstance(requirements, list):
        raise InventoryError("visual approvals requirements are invalid")
    result: set[tuple[str, str]] = set()
    for item in requirements:
        decision = item.get("decision") if isinstance(item, dict) else None
        if not isinstance(item, dict) or not isinstance(decision, dict):
            raise InventoryError("visual approval requirement is invalid")
        requirement_id = item.get("id")
        decision_id = decision.get("id")
        if not isinstance(requirement_id, str) or not SHA256_PATTERN.fullmatch(str(decision_id)):
            raise InventoryError("visual approval identity is invalid")
        result.add((requirement_id, str(decision_id)))
    return result


def _receipt_ids(
    report: dict[str, Any],
    required_surfaces: set[str],
) -> set[str]:
    runtime_surfaces = report.get("runtimeSurfaces")
    if not isinstance(runtime_surfaces, list):
        raise InventoryError("runtime surfaces are invalid")
    result: set[str] = set()
    observed: set[str] = set()
    for surface in runtime_surfaces:
        values = surface.get("receiptIDs") if isinstance(surface, dict) else None
        surface_id = surface.get("surface") if isinstance(surface, dict) else None
        if (
            not isinstance(surface_id, str)
            or SURFACE_PATTERN.fullmatch(surface_id) is None
            or surface_id in observed
            or not isinstance(values, list)
            or any(
                not isinstance(value, str)
                or SHA256_PATTERN.fullmatch(value) is None
                for value in values
            )
        ):
            raise InventoryError("runtime receipt identities are invalid")
        observed.add(surface_id)
        if surface_id in required_surfaces and (
            surface.get("state") != "proven" or not values
        ):
            raise InventoryError(
                f"required runtime surface is not proven: {surface_id}"
            )
        if surface_id in required_surfaces:
            result.update(values)
    missing_surfaces = sorted(required_surfaces - observed)
    if missing_surfaces:
        raise InventoryError(
            "required runtime surfaces are missing: " + ", ".join(missing_surfaces)
        )
    return result


def _receipt_entry(
    train: dict[str, Any],
    roots: dict[str, Path],
    root_policy: dict[str, Any],
    report: dict[str, Any],
    comparison: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    required = comparison.get("requiredSurfaces")
    actual_runtime = required.get("actual-runtime") if isinstance(required, dict) else None
    if not isinstance(actual_runtime, list) or any(
        not isinstance(value, str) or SURFACE_PATTERN.fullmatch(value) is None
        for value in actual_runtime
    ):
        raise InventoryError("comparison actual-runtime scope is invalid")
    referenced = _receipt_ids(report, set(actual_runtime))
    retained: dict[str, str] = {}
    total_size = 0
    for directory in train["runtimeReceiptDirs"]:
        root_id = train["trainRoot"]
        relative_dir = _train_relative(train["trainPath"], directory)
        root = roots[root_id]
        path = _resolve_directory(
            roots,
            root_id,
            relative_dir,
            "runtime receipt directory",
        )
        for receipt_path in sorted(path.glob("*.json")):
            _assert_contained(root, receipt_path, "runtime receipt")
            payload = load_json(receipt_path, "runtime receipt")
            receipt_id = payload.get("id")
            if not isinstance(receipt_id, str) or SHA256_PATTERN.fullmatch(receipt_id) is None:
                raise InventoryError("runtime receipt id is invalid")
            if receipt_id in retained:
                raise InventoryError("runtime receipt id is duplicated")
            retained[receipt_id] = raw_digest(receipt_path)
            total_size += receipt_path.stat().st_size
    retained_ids = set(retained)
    if not retained_ids <= referenced:
        raise InventoryError("retained runtime receipts are outside the final report")
    root_id = train["trainRoot"]
    recoverability = root_policy[root_id]["defaultRecoverability"] if retained else "reference-only"
    entry = {
        "category": "physical-runtime-receipts",
        "sourceClass": root_policy[root_id]["sourceClass"] if retained else "signed-ledger-reference",
        "sourceRoot": root_id if retained else None,
        "sourcePath": train["trainPath"] if retained else None,
        "byteSize": total_size,
        "rawDigest": canonical_digest([retained[key] for key in sorted(retained)]),
        "canonicalDigest": canonical_digest(sorted(referenced)),
        "recoverability": recoverability,
        "selectionRule": "final-report.runtimeSurfaces.receiptIDs",
        "versionControl": root_policy[root_id]["versionControl"] if retained else "absent",
        "referencedCount": len(referenced),
        "retainedCount": len(retained),
    }
    risk = None
    if retained_ids != referenced:
        risk = {
            "code": "receipt-bodies-not-retained",
            "category": "physical-runtime-receipts",
            "referencedCount": len(referenced),
            "retainedCount": len(retained),
            "unsupportedClaims": ["receipt-body-replay"],
        }
    return entry, risk


def _visual_entry(
    train: dict[str, Any],
    roots: dict[str, Path],
    root_policy: dict[str, Any],
    report: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    report_visual = report.get("visualApprovals")
    if not isinstance(report_visual, dict):
        raise InventoryError("final report visual approvals are missing")
    visual = train["visualApprovals"]
    if visual["mode"] == "embedded":
        entry = {
            "category": "visual-approvals",
            "sourceClass": "signed-report-embedded",
            "sourceRoot": train["trainRoot"],
            "sourcePath": _train_relative(train["trainPath"], train["finalReportPath"]),
            "byteSize": len(canonical_json(report_visual)),
            "rawDigest": canonical_digest(report_visual),
            "canonicalDigest": canonical_digest(report_visual),
            "recoverability": root_policy[train["trainRoot"]]["defaultRecoverability"],
            "selectionRule": "final-report.visualApprovals",
            "versionControl": root_policy[train["trainRoot"]]["versionControl"],
            "requirementCount": len(_decision_set(report_visual)),
        }
        return entry, None
    relative_path = _train_relative(train["trainPath"], visual["path"])
    entry, payload = _json_entry(
        category="visual-approvals",
        root_id=train["trainRoot"],
        relative_path=relative_path,
        roots=roots,
        root_policy=root_policy,
        selection_rule="final-report.requirement-and-decision-set",
    )
    if _decision_set(payload) != _decision_set(report_visual):
        raise InventoryError("visual approval export does not match the final report")
    entry["requirementCount"] = len(_decision_set(payload))
    return entry, None


def _validate_chain(
    train: dict[str, Any],
    previous: dict[str, Any],
    current: dict[str, Any],
    comparison: dict[str, Any],
    report: dict[str, Any],
    ledger: dict[str, Any],
    lineage: dict[str, Any],
    expected_builds: list[dict[str, Any]],
) -> None:
    if lineage.get("schemaVersion") != 1 or lineage.get("kind") != LINEAGE_KIND:
        raise InventoryError("release evidence lineage identity is invalid")
    if ledger.get("schemaVersion") != 1 or ledger.get("kind") != LEDGER_KIND:
        raise InventoryError("release evidence ledger identity is invalid")
    if lineage.get("ledger") != ledger:
        raise InventoryError("lineage ledger does not match the retained ledger")
    unsigned_ledger = {key: value for key, value in ledger.items() if key != "ledgerID"}
    if ledger.get("ledgerID") != canonical_digest(unsigned_ledger):
        raise InventoryError("release evidence ledger self-digest is invalid")
    target = {"version": train["version"], "buildNumber": train["buildNumber"]}
    if ledger.get("target") != target or report.get("target") != target:
        raise InventoryError("train target does not match retained evidence")
    generation = lineage.get("generation")
    if not isinstance(generation, dict):
        raise InventoryError("lineage generation inputs are missing")
    if generation.get("comparison") != comparison or generation.get("validationReport") != report:
        raise InventoryError("lineage generation inputs diverge from retained files")
    if ledger.get("comparisonDigest") != canonical_digest(comparison):
        raise InventoryError("comparison digest does not match the ledger")
    if ledger.get("validationReportDigest") != canonical_digest(report):
        raise InventoryError("validation report digest does not match the ledger")
    if comparison.get("previousManifestId") != previous.get("manifestId"):
        raise InventoryError("previous source manifest does not match the comparison")
    current_manifest_id = current.get("manifestId")
    if comparison.get("currentManifestId") != current_manifest_id:
        raise InventoryError("current source manifest does not match the comparison")
    source = current.get("source")
    if not isinstance(source, dict) or source.get("marketingVersion") != train["version"] or source.get("buildNumber") != train["buildNumber"]:
        raise InventoryError("current source manifest target is invalid")
    embedded_expected = generation.get("expectedBuildManifests")
    if not isinstance(embedded_expected, list):
        raise InventoryError("lineage expected-build manifests are missing")
    if sorted(canonical_digest(item) for item in embedded_expected) != sorted(canonical_digest(item) for item in expected_builds):
        raise InventoryError("expected-build manifests diverge from lineage")
    for expected in expected_builds:
        expected_source = expected.get("source")
        if (
            expected.get("sourceManifestId") != current_manifest_id
            or not isinstance(expected_source, dict)
            or expected_source.get("marketingVersion") != train["version"]
            or expected_source.get("buildNumber") != train["buildNumber"]
        ):
            raise InventoryError("expected-build manifest target is invalid")


def _seal_train(train: dict[str, Any], policy: dict[str, Any], roots: dict[str, Path]) -> dict[str, Any]:
    root_id = train["trainRoot"]
    train_path = train["trainPath"]
    root_policy = policy["sourceRoots"]
    previous_entry, previous = _json_entry(
        category="previous-source-manifest",
        root_id=train["previousManifest"]["root"],
        relative_path=train["previousManifest"]["path"],
        roots=roots,
        root_policy=root_policy,
        selection_rule="comparison.previousManifestId",
    )
    entries: list[dict[str, Any]] = [previous_entry]

    def train_entry(category: str, key: str, selection_rule: str) -> tuple[dict[str, Any], dict[str, Any]]:
        return _json_entry(
            category=category,
            root_id=root_id,
            relative_path=_train_relative(train_path, train[key]),
            roots=roots,
            root_policy=root_policy,
            selection_rule=selection_rule,
        )

    current_entry, current = train_entry("current-source-manifest", "currentManifestPath", "comparison.currentManifestId")
    comparison_entry, comparison = train_entry("archived-comparison", "comparisonPath", "ledger.comparisonDigest")
    report_entry, report = train_entry("coordinator-final-report", "finalReportPath", "ledger.validationReportDigest")
    ledger_entry, ledger = train_entry("release-evidence-ledger", "ledgerPath", "lineage.ledger")
    lineage_entry, lineage = train_entry("release-evidence-lineage", "lineagePath", "policy.required-ledger")
    entries.extend((current_entry, comparison_entry, report_entry, ledger_entry, lineage_entry))
    expected_entry, expected_builds = _set_entry(
        category="expected-build-manifests",
        root_id=root_id,
        members=train["expectedBuildManifests"],
        train_path=train_path,
        roots=roots,
        root_policy=root_policy,
        selection_rule="lineage.generation.expectedBuildManifests",
    )
    entries.append(expected_entry)
    _validate_chain(train, previous, current, comparison, report, ledger, lineage, expected_builds)
    receipt_entry, receipt_risk = _receipt_entry(
        train,
        roots,
        root_policy,
        report,
        comparison,
    )
    visual_entry, visual_risk = _visual_entry(train, roots, root_policy, report)
    entries.extend((receipt_entry, visual_entry))
    entries.sort(key=lambda item: item["category"])
    categories = {item["category"] for item in entries}
    if categories != set(policy["requiredCategories"]):
        raise InventoryError(f"required evidence categories are incomplete for {train['trainId']}")
    residual_risks = [risk for risk in (receipt_risk, visual_risk) if risk is not None]
    state = "complete-with-reference-only" if residual_risks else "complete"
    scope = comparison.get("requiredSurfaces")
    if not isinstance(scope, dict):
        raise InventoryError("comparison required surface scope is invalid")
    normalized_scope: dict[str, list[str]] = {}
    for evidence_class in ("actual-runtime", "os-composited-placement", "shared-view"):
        values = scope.get(evidence_class)
        if not isinstance(values, list) or any(not isinstance(value, str) or SURFACE_PATTERN.fullmatch(value) is None for value in values):
            raise InventoryError("comparison required surface scope is invalid")
        if len(values) != len(set(values)):
            raise InventoryError("comparison required surface scope is invalid")
        normalized_scope[evidence_class] = sorted(values)
    result = {
        "trainId": train["trainId"],
        "version": train["version"],
        "buildNumber": train["buildNumber"],
        "trainClass": train["trainClass"],
        "admissibleClaims": train["admissibleClaims"],
        "notAdmissibleFor": train.get("notAdmissibleFor", []),
        "state": state,
        "previousManifestId": previous["manifestId"],
        "currentManifestId": current["manifestId"],
        "contractFingerprint": current.get("contractFingerprint"),
        "scope": normalized_scope,
        "inputs": entries,
        "missing": [],
        "residualRisks": residual_risks,
    }
    _validate_sealed_metadata(result, train)
    return result


def _scan_public(value: Any, path: str = "root") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                raise InventoryError(f"inventory key is invalid: {path}")
            if UNSAFE_KEY_PATTERN.search(key) or any(
                pattern.search(key) for pattern in UNSAFE_STRING_PATTERNS
            ):
                raise InventoryError(f"inventory contains a private key: {path}.{key}")
            _scan_public(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _scan_public(child, f"{path}[{index}]")
    elif isinstance(value, str):
        if any(pattern.search(value) for pattern in UNSAFE_STRING_PATTERNS):
            raise InventoryError(f"inventory contains a private value: {path}")


def _nonnegative_integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise InventoryError(f"{label} is invalid")
    return value


def _validate_digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise InventoryError(f"{label} is invalid")
    return value


def _expected_entry_shape(category: str) -> set[str]:
    if category == "expected-build-manifests":
        return ENTRY_KEYS | {"memberCount"}
    if category == "physical-runtime-receipts":
        return ENTRY_KEYS | {"referencedCount", "retainedCount"}
    if category == "visual-approvals":
        return ENTRY_KEYS | {"requirementCount"}
    return ENTRY_KEYS


def _expected_entry_locator(
    train: dict[str, Any],
    category: str,
    retained_count: int | None,
    policy: dict[str, Any],
) -> tuple[str | None, str | None, str, str, str]:
    train_root = train["trainRoot"]
    train_path = train["trainPath"]
    if category == "previous-source-manifest":
        source_root = train["previousManifest"]["root"]
        source_path = train["previousManifest"]["path"]
    elif category == "expected-build-manifests":
        source_root = train_root
        source_path = train_path
    elif category == "physical-runtime-receipts":
        if retained_count == 0:
            return None, None, "signed-ledger-reference", "reference-only", "absent"
        source_root = train_root
        source_path = train_path
    elif category == "visual-approvals" and train["visualApprovals"]["mode"] == "embedded":
        source_root = train_root
        source_path = _train_relative(train_path, train["finalReportPath"])
        root_definition = policy["sourceRoots"][train_root]
        return (
            source_root,
            source_path,
            "signed-report-embedded",
            root_definition["defaultRecoverability"],
            root_definition["versionControl"],
        )
    else:
        path_keys = {
            "current-source-manifest": "currentManifestPath",
            "archived-comparison": "comparisonPath",
            "coordinator-final-report": "finalReportPath",
            "release-evidence-ledger": "ledgerPath",
            "release-evidence-lineage": "lineagePath",
            "visual-approvals": "visualApprovals",
        }
        key = path_keys[category]
        relative = (
            train[key]["path"]
            if category == "visual-approvals"
            else train[key]
        )
        source_root = train_root
        source_path = _train_relative(train_path, relative)
    root_definition = policy["sourceRoots"][source_root]
    return (
        source_root,
        source_path,
        root_definition["sourceClass"],
        root_definition["defaultRecoverability"],
        root_definition["versionControl"],
    )


def _validate_entry(
    entry: Any,
    train: dict[str, Any],
    policy: dict[str, Any],
) -> None:
    if not isinstance(entry, dict):
        raise InventoryError("replay input inventory entry is invalid")
    category = entry.get("category")
    if category not in policy["requiredCategories"]:
        raise InventoryError("replay input inventory category is invalid")
    _exact_keys(entry, _expected_entry_shape(category), f"{category} inventory entry")
    selection_rule = entry.get("selectionRule")
    expected_selection = SELECTION_RULES[category]
    if category == "visual-approvals":
        expected_selection = (
            "final-report.visualApprovals"
            if train["visualApprovals"]["mode"] == "embedded"
            else "final-report.requirement-and-decision-set"
        )
    if selection_rule != expected_selection:
        raise InventoryError(f"{category} selection rule is invalid")
    _nonnegative_integer(entry.get("byteSize"), f"{category} byte size")
    _validate_digest(entry.get("rawDigest"), f"{category} raw digest")
    _validate_digest(entry.get("canonicalDigest"), f"{category} canonical digest")
    if entry.get("recoverability") not in policy["recoverabilityClasses"]:
        raise InventoryError("replay input recoverability is invalid")
    retained_count = None
    if category == "physical-runtime-receipts":
        referenced_count = _nonnegative_integer(
            entry.get("referencedCount"), "runtime receipt reference count"
        )
        retained_count = _nonnegative_integer(
            entry.get("retainedCount"), "runtime receipt retained count"
        )
        if retained_count > referenced_count:
            raise InventoryError("runtime receipt counts are invalid")
    elif category == "expected-build-manifests":
        if _nonnegative_integer(entry.get("memberCount"), "expected-build member count") != len(
            train["expectedBuildManifests"]
        ):
            raise InventoryError("expected-build member count is invalid")
    elif category == "visual-approvals":
        _nonnegative_integer(entry.get("requirementCount"), "visual requirement count")
    (
        source_root,
        source_path,
        expected_class,
        expected_recoverability,
        expected_version_control,
    ) = (
        _expected_entry_locator(train, category, retained_count, policy)
    )
    if entry.get("sourceRoot") != source_root or entry.get("sourcePath") != source_path:
        raise InventoryError(f"{category} source locator is invalid")
    if source_path is not None:
        _relative_path(source_path, f"{category} source path")
    if (
        entry.get("sourceClass") != expected_class
        or entry.get("recoverability") != expected_recoverability
        or entry.get("versionControl") != expected_version_control
    ):
        raise InventoryError(f"{category} source metadata is invalid")


def _expected_receipt_risks(inputs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    receipt = next(
        entry for entry in inputs if entry["category"] == "physical-runtime-receipts"
    )
    if receipt["retainedCount"] == receipt["referencedCount"]:
        return []
    return [
        {
            "code": "receipt-bodies-not-retained",
            "category": "physical-runtime-receipts",
            "referencedCount": receipt["referencedCount"],
            "retainedCount": receipt["retainedCount"],
            "unsupportedClaims": ["receipt-body-replay"],
        }
    ]


def _validate_train_inventory(
    inventory_train: Any,
    policy_train: dict[str, Any],
    policy: dict[str, Any],
) -> None:
    if not isinstance(inventory_train, dict):
        raise InventoryError("replay input inventory train is invalid")
    _exact_keys(inventory_train, TRAIN_INVENTORY_KEYS, "replay input inventory train")
    expected_metadata = {
        "trainId": policy_train["trainId"],
        "version": policy_train["version"],
        "buildNumber": policy_train["buildNumber"],
        "trainClass": policy_train["trainClass"],
        "admissibleClaims": policy_train["admissibleClaims"],
        "notAdmissibleFor": policy_train.get("notAdmissibleFor", []),
    }
    for key, expected in expected_metadata.items():
        if inventory_train.get(key) != expected:
            raise InventoryError(f"replay input inventory {key} does not match policy")
    for key in ("previousManifestId", "currentManifestId", "contractFingerprint"):
        _validate_digest(inventory_train.get(key), f"replay input inventory {key}")
    scope = inventory_train.get("scope")
    if not isinstance(scope, dict):
        raise InventoryError("replay input inventory scope is invalid")
    _exact_keys(scope, SCOPE_KEYS, "replay input inventory scope")
    for evidence_class, surfaces in scope.items():
        if (
            not isinstance(surfaces, list)
            or surfaces != sorted(set(surfaces))
            or any(
                not isinstance(surface, str)
                or SURFACE_PATTERN.fullmatch(surface) is None
                for surface in surfaces
            )
        ):
            raise InventoryError(
                f"replay input inventory {evidence_class} scope is invalid"
            )
    _validate_sealed_metadata(inventory_train, policy_train)
    inputs = inventory_train.get("inputs")
    if not isinstance(inputs, list):
        raise InventoryError("replay input inventory inputs are invalid")
    categories = [
        entry.get("category") if isinstance(entry, dict) else None for entry in inputs
    ]
    if categories != sorted(policy["requiredCategories"]):
        raise InventoryError("replay input inventory categories are invalid")
    for entry in inputs:
        _validate_entry(entry, policy_train, policy)
    if inventory_train.get("missing") != []:
        raise InventoryError("replay input inventory is incomplete")
    risks = inventory_train.get("residualRisks")
    if not isinstance(risks, list):
        raise InventoryError("replay input inventory residual risks are invalid")
    for risk in risks:
        if not isinstance(risk, dict):
            raise InventoryError("replay input inventory residual risk is invalid")
        _exact_keys(risk, RECEIPT_RISK_KEYS, "replay input inventory residual risk")
    expected_risks = _expected_receipt_risks(inputs)
    if risks != expected_risks:
        raise InventoryError("replay input inventory residual risks are inconsistent")
    expected_state = "complete-with-reference-only" if expected_risks else "complete"
    if inventory_train.get("state") != expected_state:
        raise InventoryError("replay input inventory train state is inconsistent")


def _expected_summary(trains: list[dict[str, Any]]) -> dict[str, int]:
    return {
        "trainCount": len(trains),
        "inputCount": sum(len(train["inputs"]) for train in trains),
        "missingCount": sum(len(train["missing"]) for train in trains),
        "residualRiskCount": sum(len(train["residualRisks"]) for train in trains),
        "fragileInputCount": sum(
            entry["recoverability"] == "fragile"
            for train in trains
            for entry in train["inputs"]
        ),
        "referenceOnlyInputCount": sum(
            entry["recoverability"] == "reference-only"
            for train in trains
            for entry in train["inputs"]
        ),
    }


def _sealed_metadata(train: dict[str, Any]) -> dict[str, Any]:
    return {
        "previousManifestId": train["previousManifestId"],
        "currentManifestId": train["currentManifestId"],
        "contractFingerprint": train["contractFingerprint"],
        "scope": train["scope"],
    }


def _validate_sealed_metadata(
    inventory_train: dict[str, Any],
    policy_train: dict[str, Any],
) -> None:
    if canonical_digest(_sealed_metadata(inventory_train)) != policy_train["sealedMetadataDigest"]:
        raise InventoryError("replay input inventory sealed metadata does not match policy")


def _missing_inputs(
    policy: dict[str, Any],
    roots: dict[str, Path],
) -> list[str]:
    missing: list[str] = []
    for train in policy["trains"]:
        train_id = train["trainId"]
        train_root = roots[train["trainRoot"]]
        train_path = train["trainPath"]
        files = {
            "current-source-manifest": train["currentManifestPath"],
            "archived-comparison": train["comparisonPath"],
            "coordinator-final-report": train["finalReportPath"],
            "release-evidence-lineage": train["lineagePath"],
            "release-evidence-ledger": train["ledgerPath"],
        }
        for category, relative in files.items():
            if not (train_root / _train_relative(train_path, relative)).is_file():
                missing.append(f"{train_id}/{category}")
        previous = train["previousManifest"]
        if not (roots[previous["root"]] / previous["path"]).is_file():
            missing.append(f"{train_id}/previous-source-manifest")
        for platform, relative in train["expectedBuildManifests"].items():
            if not (train_root / _train_relative(train_path, relative)).is_file():
                missing.append(f"{train_id}/expected-build-manifests:{platform}")
        visual = train["visualApprovals"]
        if visual["mode"] == "file" and not (
            train_root / _train_relative(train_path, visual["path"])
        ).is_file():
            missing.append(f"{train_id}/visual-approvals")
        for relative in train["runtimeReceiptDirs"]:
            if not (train_root / _train_relative(train_path, relative)).is_dir():
                missing.append(f"{train_id}/physical-runtime-receipts")
    return sorted(set(missing))


def seal_inventory(policy_path: Path, root_bindings: dict[str, Path]) -> dict[str, Any]:
    policy = load_policy(policy_path)
    root_bindings = _normalize_root_bindings(root_bindings)
    configured_roots = set(policy["sourceRoots"])
    if set(root_bindings) != configured_roots:
        missing = sorted(configured_roots - set(root_bindings))
        extra = sorted(set(root_bindings) - configured_roots)
        raise InventoryError(f"source root bindings do not match policy: missing={missing}, extra={extra}")
    missing_inputs = _missing_inputs(policy, root_bindings)
    if missing_inputs:
        raise InventoryError("missing replay inputs: " + ", ".join(missing_inputs))
    trains = [_seal_train(train, policy, root_bindings) for train in policy["trains"]]
    risk_count = sum(len(train["residualRisks"]) for train in trains)
    fragile_count = sum(
        1
        for train in trains
        for item in train["inputs"]
        if item["recoverability"] == "fragile"
    )
    reference_count = sum(
        1
        for train in trains
        for item in train["inputs"]
        if item["recoverability"] == "reference-only"
    )
    payload = {
        "schemaVersion": 1,
        "kind": INVENTORY_KIND,
        "algorithm": "sha256",
        "digestDomain": policy["digestDomain"],
        "policyDigest": raw_digest(policy_path),
        "state": "complete-with-reference-only" if risk_count else "complete",
        "trains": trains,
        "summary": {
            "trainCount": len(trains),
            "inputCount": sum(len(train["inputs"]) for train in trains),
            "missingCount": 0,
            "residualRiskCount": risk_count,
            "fragileInputCount": fragile_count,
            "referenceOnlyInputCount": reference_count,
        },
    }
    _scan_public(payload)
    payload["inventoryId"] = canonical_digest(payload)
    return payload


def check_inventory(policy_path: Path, inventory_path: Path) -> dict[str, Any]:
    policy = load_policy(policy_path)
    inventory = load_json(inventory_path, "replay input inventory")
    _exact_keys(
        inventory,
        {
            "schemaVersion",
            "kind",
            "algorithm",
            "digestDomain",
            "policyDigest",
            "state",
            "trains",
            "summary",
            "inventoryId",
        },
        "replay input inventory",
    )
    if (
        inventory.get("schemaVersion") != 1
        or inventory.get("kind") != INVENTORY_KIND
        or inventory.get("algorithm") != "sha256"
        or inventory.get("digestDomain") != policy["digestDomain"]
        or inventory.get("policyDigest") != raw_digest(policy_path)
    ):
        raise InventoryError("replay input inventory identity is invalid")
    unsigned = {key: value for key, value in inventory.items() if key != "inventoryId"}
    if inventory.get("inventoryId") != canonical_digest(unsigned):
        raise InventoryError("replay input inventory self-digest is invalid")
    trains = inventory.get("trains")
    if not isinstance(trains, list) or len(trains) != len(policy["trains"]):
        raise InventoryError("replay input inventory train set is invalid")
    for inventory_train, policy_train in zip(trains, policy["trains"], strict=True):
        _validate_train_inventory(inventory_train, policy_train, policy)
    summary = inventory.get("summary")
    if not isinstance(summary, dict):
        raise InventoryError("replay input inventory summary is invalid")
    _exact_keys(summary, SUMMARY_KEYS, "replay input inventory summary")
    for key, value in summary.items():
        _nonnegative_integer(value, f"replay input inventory summary {key}")
    expected_summary = _expected_summary(trains)
    if summary != expected_summary:
        raise InventoryError("replay input inventory summary is inconsistent")
    expected_state = (
        "complete-with-reference-only"
        if expected_summary["residualRiskCount"]
        else "complete"
    )
    if inventory.get("state") != expected_state:
        raise InventoryError("replay input inventory state is inconsistent")
    _scan_public(inventory)
    return inventory


def verify_inventory(policy_path: Path, inventory_path: Path, root_bindings: dict[str, Path]) -> dict[str, Any]:
    expected = seal_inventory(policy_path, root_bindings)
    check_inventory(policy_path, inventory_path)
    try:
        actual = inventory_path.read_bytes()
    except OSError as error:
        raise InventoryError("replay input inventory is unavailable") from error
    if actual != render_json(expected):
        raise InventoryError("replay input inventory does not match retained sources")
    return expected


def write_inventory(payload: dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("wb", dir=output.parent, prefix=f".{output.name}.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(render_json(payload))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, output)
