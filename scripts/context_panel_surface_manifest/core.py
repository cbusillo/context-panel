from __future__ import annotations

import copy
import fnmatch
import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


DEFAULT_POLICY_PATH = Path("Config/ContextPanelSurfacePolicy.json")
BASE_INPUT_CLASSES = ("shared", "render", "runtime")
INPUT_CLASSES = (*BASE_INPUT_CLASSES, "placement")
EVIDENCE_CLASSES = (
    "shared-view",
    "actual-runtime",
    "os-composited-placement",
)
TRAIN_NAMES = ("beta", "rc", "release")
CHANGE_KINDS = ("render", "runtime", "placement", "unknown")
SUPPORTED_PROJECT_KEYS = {"name", "options", "settings", "packages", "targets", "schemes"}
PRESENTATION_IMPORT_PATTERN = re.compile(
    r"^\s*import\s+(?:SwiftUI|WidgetKit|AppKit|UIKit)\b",
    re.MULTILINE,
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
UUID_PATTERN = re.compile(
    r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
)


class SurfacePolicyError(RuntimeError):
    pass


@dataclass(frozen=True)
class ResolvedSurface:
    definition: dict[str, Any]
    files: dict[str, tuple[str, ...]]
    project_targets: tuple[str, ...]
    project_projection: dict[str, Any]
    project_fingerprint: str


@dataclass(frozen=True)
class ResolvedPolicy:
    root: Path
    policy_path: Path
    policy: dict[str, Any]
    project_payload: dict[str, Any]
    groups: dict[str, tuple[str, ...]]
    surfaces: tuple[ResolvedSurface, ...]
    governed_files: tuple[str, ...]
    ignored_files: tuple[str, ...]
    contract_files: tuple[str, ...]
    contract_fingerprint: str
    file_hashes: dict[str, str]


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def hash_parts(domain: str, parts: Iterable[bytes | str]) -> str:
    digest = hashlib.sha256()
    for part in (domain, *parts):
        data = part.encode("utf-8") if isinstance(part, str) else part
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except OSError as error:
        raise SurfacePolicyError(f"unable to read {label}") from error
    except json.JSONDecodeError as error:
        raise SurfacePolicyError(f"{label} is not valid JSON") from error
    if not isinstance(value, dict):
        raise SurfacePolicyError(f"{label} must be a JSON object")
    return value


def load_project_payload(root: Path, policy: dict[str, Any]) -> dict[str, Any]:
    project_config = policy.get("project")
    if not isinstance(project_config, dict):
        raise SurfacePolicyError("policy project configuration is missing")
    project_path = root / str(project_config.get("path") or "")
    reader_path = root / str(project_config.get("reader") or "")
    if not project_path.is_file() or not reader_path.is_file():
        raise SurfacePolicyError("project specification or reader is unavailable")
    try:
        completed = subprocess.run(
            ["/usr/bin/ruby", str(reader_path), "--project", str(project_path)],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise SurfacePolicyError("project specification reader is unavailable") from error
    if completed.returncode != 0:
        raise SurfacePolicyError("project specification reader failed")
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise SurfacePolicyError("project specification reader returned invalid JSON") from error
    if not isinstance(payload, dict) or not isinstance(payload.get("project"), dict):
        raise SurfacePolicyError("project specification reader returned an invalid payload")
    return payload


def path_is_excluded(relative_path: str, patterns: Iterable[str]) -> bool:
    return any(fnmatch.fnmatchcase(relative_path, pattern) for pattern in patterns)


def expand_patterns(
    root: Path,
    patterns: Iterable[str],
    *,
    excludes: Iterable[str] = (),
    excluded_basenames: Iterable[str] = (),
    require_each: bool = True,
) -> tuple[str, ...]:
    resolved: set[str] = set()
    excluded_names = set(excluded_basenames)
    exclude_patterns = tuple(excludes)
    for pattern in patterns:
        matches: list[str] = []
        for candidate in root.glob(pattern):
            if not candidate.is_file():
                continue
            relative = candidate.relative_to(root).as_posix()
            if candidate.name in excluded_names or path_is_excluded(relative, exclude_patterns):
                continue
            matches.append(relative)
        if require_each and not matches:
            raise SurfacePolicyError(f"input pattern matched no files: {pattern}")
        resolved.update(matches)
    return tuple(sorted(resolved, key=lambda value: value.encode("utf-8")))


def validate_paths(root: Path, paths: Iterable[str]) -> None:
    casefolded: dict[str, str] = {}
    for relative in paths:
        if not relative.isascii() or any(ord(character) < 32 for character in relative):
            raise SurfacePolicyError(f"input path is not portable ASCII: {relative}")
        if relative.startswith("/") or "\\" in relative or ".." in Path(relative).parts:
            raise SurfacePolicyError(f"input path is not repository-relative: {relative}")
        folded = relative.casefold()
        existing = casefolded.get(folded)
        if existing is not None and existing != relative:
            raise SurfacePolicyError(f"input paths collide by case: {existing}, {relative}")
        casefolded[folded] = relative
        if (root / relative).is_symlink():
            raise SurfacePolicyError(f"symlinked fingerprint input is not allowed: {relative}")


def dependency_applies(dependency: dict[str, Any], destination: str) -> bool:
    filters = dependency.get("destinationFilters") or dependency.get("platformFilters")
    if filters is None:
        return True
    return destination in filters


def normalized_dependency(value: Any) -> dict[str, Any]:
    if isinstance(value, str):
        return {"target": value}
    if isinstance(value, dict):
        return value
    raise SurfacePolicyError("project target dependency must be a string or object")


def compile_target_closure(
    targets: dict[str, Any],
    root_target: str,
    destination: str,
) -> tuple[str, ...]:
    pending = [root_target]
    resolved: set[str] = set()
    while pending:
        target_name = pending.pop()
        if target_name in resolved:
            continue
        target = targets.get(target_name)
        if not isinstance(target, dict):
            raise SurfacePolicyError(f"project target is missing: {target_name}")
        resolved.add(target_name)
        for raw_dependency in target.get("dependencies") or []:
            dependency = normalized_dependency(raw_dependency)
            dependency_target = dependency.get("target")
            if not dependency_target or dependency.get("embed") is True:
                continue
            if dependency_applies(dependency, destination):
                pending.append(str(dependency_target))
    return tuple(sorted(resolved))


def target_source_files(root: Path, target: dict[str, Any]) -> tuple[str, ...]:
    files: set[str] = set()
    for raw_source in target.get("sources") or []:
        source = {"path": raw_source} if isinstance(raw_source, str) else raw_source
        if not isinstance(source, dict) or not source.get("path"):
            raise SurfacePolicyError("project target source must contain a path")
        source_path = root / str(source["path"])
        if not source_path.exists():
            raise SurfacePolicyError(f"project target source is missing: {source['path']}")
        candidates = [source_path] if source_path.is_file() else source_path.rglob("*")
        excludes = tuple(str(value) for value in source.get("excludes") or [])
        for candidate in candidates:
            if not candidate.is_file() or candidate.name == ".DS_Store":
                continue
            within_source = candidate.relative_to(source_path).as_posix() if source_path.is_dir() else candidate.name
            if any(fnmatch.fnmatchcase(within_source, pattern) for pattern in excludes):
                continue
            files.add(candidate.relative_to(root).as_posix())
    return tuple(sorted(files, key=lambda value: value.encode("utf-8")))


def filtered_target(target: dict[str, Any], destination: str) -> dict[str, Any]:
    result = copy.deepcopy(target)
    dependencies = []
    for raw_dependency in result.get("dependencies") or []:
        dependency = normalized_dependency(raw_dependency)
        if dependency_applies(dependency, destination):
            dependencies.append(dependency)
    if "dependencies" in result:
        result["dependencies"] = dependencies
    return result


def surface_project_projection(
    project: dict[str, Any],
    surface: dict[str, Any],
    closure: tuple[str, ...],
) -> dict[str, Any]:
    destination = str(surface["projectDestination"])
    targets = project.get("targets") or {}
    schemes = project.get("schemes") or {}
    scheme_name = str(surface["scheme"])
    return {
        "global": {
            key: copy.deepcopy(value)
            for key, value in project.items()
            if key not in {"targets", "schemes"}
        },
        "destination": destination,
        "scheme": schemes.get(scheme_name),
        "targets": {
            target_name: filtered_target(targets[target_name], destination)
            for target_name in closure
        },
    }


def validate_evidence_policy(evidence_policy: Any) -> dict[str, Any]:
    if not isinstance(evidence_policy, dict):
        raise SurfacePolicyError("surface evidence policy is missing")
    classes = evidence_policy.get("classes")
    if (
        not isinstance(classes, list)
        or any(not isinstance(value, str) for value in classes)
        or len(classes) != len(set(classes))
        or set(classes) != set(EVIDENCE_CLASSES)
    ):
        raise SurfacePolicyError("surface evidence classes are invalid")

    def validate_mapping(key: str, expected_keys: tuple[str, ...]) -> dict[str, list[str]]:
        mapping = evidence_policy.get(key)
        if not isinstance(mapping, dict) or set(mapping) != set(expected_keys):
            raise SurfacePolicyError(f"surface evidence policy {key} is invalid")
        normalized: dict[str, list[str]] = {}
        for mapping_key in expected_keys:
            raw_values = mapping.get(mapping_key)
            if (
                not isinstance(raw_values, list)
                or any(not isinstance(value, str) for value in raw_values)
                or len(raw_values) != len(set(raw_values))
            ):
                raise SurfacePolicyError(
                    f"surface evidence policy {key}.{mapping_key} is invalid"
                )
            values = [str(value) for value in raw_values]
            if not set(values) <= set(EVIDENCE_CLASSES):
                raise SurfacePolicyError(
                    f"surface evidence policy {key}.{mapping_key} is invalid"
                )
            normalized[mapping_key] = values
        return normalized

    train_minimums = validate_mapping("trainMinimumEvidence", TRAIN_NAMES)
    change_requirements = validate_mapping("changeRequirements", CHANGE_KINDS)
    required_change_evidence = {
        "render": {"shared-view", "actual-runtime", "os-composited-placement"},
        "runtime": {"actual-runtime"},
        "placement": {"actual-runtime", "os-composited-placement"},
        "unknown": set(EVIDENCE_CLASSES),
    }
    for change_kind, required in required_change_evidence.items():
        if not required <= set(change_requirements[change_kind]):
            raise SurfacePolicyError(
                f"surface evidence policy changeRequirements.{change_kind} is unsafe"
            )
    if evidence_policy.get("releaseRequiresApprovedRCTarget") is not True:
        raise SurfacePolicyError("release evidence policy must require an approved RC target")
    return {
        **evidence_policy,
        "classes": [str(value) for value in classes],
        "trainMinimumEvidence": train_minimums,
        "changeRequirements": change_requirements,
    }


def target_runtime_paths(target: dict[str, Any]) -> tuple[str, ...]:
    paths: set[str] = set()
    info = target.get("info")
    if isinstance(info, dict) and info.get("path"):
        paths.add(str(info["path"]))
    settings = target.get("settings") or {}
    settings_values = [settings.get("base") or {}]
    settings_values.extend((settings.get("configs") or {}).values())
    for values in settings_values:
        if not isinstance(values, dict):
            continue
        for key in ("INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS"):
            value = values.get(key)
            if isinstance(value, str) and value:
                paths.add(value)
    return tuple(sorted(paths))


def embedded_targets(target: dict[str, Any], destination: str) -> tuple[str, ...]:
    values = []
    for raw_dependency in target.get("dependencies") or []:
        dependency = normalized_dependency(raw_dependency)
        if dependency.get("embed") is not True or not dependency_applies(dependency, destination):
            continue
        target_name = dependency.get("target")
        if target_name:
            values.append(str(target_name))
    return tuple(sorted(values))


def validate_surface_project_contract(
    root: Path,
    project: dict[str, Any],
    surface: dict[str, Any],
    surface_files: dict[str, tuple[str, ...]],
    surfaces_by_id: dict[str, dict[str, Any]],
) -> tuple[tuple[str, ...], dict[str, Any]]:
    targets = project.get("targets")
    schemes = project.get("schemes")
    if not isinstance(targets, dict) or not isinstance(schemes, dict):
        raise SurfacePolicyError("project targets or schemes are missing")
    root_target_name = str(surface["projectTarget"])
    destination = str(surface["projectDestination"])
    target = targets.get(root_target_name)
    if not isinstance(target, dict):
        raise SurfacePolicyError(f"surface project target is missing: {root_target_name}")
    if target.get("type") != surface.get("productType"):
        raise SurfacePolicyError(f"surface product type drifted: {surface['id']}")
    target_platform = target.get("platform")
    supported_destinations = target.get("supportedDestinations") or []
    if target_platform == "auto":
        if destination not in supported_destinations:
            raise SurfacePolicyError(f"surface destination is not supported: {surface['id']}")
    elif target_platform != destination:
        raise SurfacePolicyError(f"surface platform drifted: {surface['id']}")
    settings = target.get("settings") or {}
    bundle_identifier = (settings.get("base") or {}).get("PRODUCT_BUNDLE_IDENTIFIER")
    if bundle_identifier != surface.get("bundleIdentifier"):
        raise SurfacePolicyError(f"surface bundle identifier drifted: {surface['id']}")
    scheme = schemes.get(surface.get("scheme"))
    scheme_targets = ((scheme or {}).get("build") or {}).get("targets") or {}
    if root_target_name not in scheme_targets:
        raise SurfacePolicyError(f"surface target is missing from its scheme: {surface['id']}")

    closure = compile_target_closure(targets, root_target_name, destination)
    compiled_files: set[str] = set()
    for target_name in closure:
        compiled_files.update(target_source_files(root, targets[target_name]))
    mapped_files = set().union(
        *(set(surface_files[class_name]) for class_name in BASE_INPUT_CLASSES)
    )
    missing_compiled = sorted(compiled_files - mapped_files)
    if missing_compiled:
        raise SurfacePolicyError(
            f"surface omits compiled inputs: {surface['id']}: {', '.join(missing_compiled[:5])}"
        )
    runtime_files = set(surface_files["runtime"])
    missing_runtime = sorted(set(target_runtime_paths(target)) - runtime_files)
    if missing_runtime:
        raise SurfacePolicyError(
            f"surface omits Info.plist or entitlement inputs: {surface['id']}: "
            f"{', '.join(missing_runtime)}"
        )

    expected_embed_targets = {
        str(surfaces_by_id[child_id]["projectTarget"])
        for child_id in surface.get("embeds") or []
    }
    actual_embed_targets = set(embedded_targets(target, destination))
    if actual_embed_targets != expected_embed_targets:
        raise SurfacePolicyError(f"surface embedded-target contract drifted: {surface['id']}")

    projection = surface_project_projection(project, surface, closure)
    return closure, projection


def validate_archive_layouts(
    archive_layouts: Any,
    artifact_ids: set[str],
) -> dict[str, dict[str, str]]:
    if not isinstance(archive_layouts, dict) or not archive_layouts:
        raise SurfacePolicyError("surface policy archive layouts are missing")
    normalized: dict[str, dict[str, str]] = {}
    covered_artifacts: set[str] = set()
    for raw_layout_name, raw_layout in archive_layouts.items():
        layout_name = str(raw_layout_name)
        if not layout_name or not isinstance(raw_layout, dict) or not raw_layout:
            raise SurfacePolicyError(f"archive layout is invalid: {layout_name}")
        paths: set[str] = set()
        normalized_layout: dict[str, str] = {}
        for raw_artifact_id, raw_relative_path in raw_layout.items():
            artifact_id = str(raw_artifact_id)
            relative_path = str(raw_relative_path)
            if artifact_id not in artifact_ids:
                raise SurfacePolicyError(
                    f"archive layout references an unknown artifact: {layout_name}: {artifact_id}"
                )
            path = Path(relative_path)
            if (
                not relative_path
                or path.is_absolute()
                or "\\" in relative_path
                or ".." in path.parts
            ):
                raise SurfacePolicyError(
                    f"archive layout path is not relative: {layout_name}: {artifact_id}"
                )
            if relative_path in paths:
                raise SurfacePolicyError(
                    f"archive layout path is duplicated: {layout_name}: {relative_path}"
                )
            paths.add(relative_path)
            covered_artifacts.add(artifact_id)
            normalized_layout[artifact_id] = relative_path
        normalized[layout_name] = dict(sorted(normalized_layout.items()))
    missing_artifacts = sorted(artifact_ids - covered_artifacts)
    if missing_artifacts:
        raise SurfacePolicyError(
            f"artifacts are missing from archive layouts: {', '.join(missing_artifacts)}"
        )
    return dict(sorted(normalized.items()))


def resolve_policy(root: Path, policy_path: Path = DEFAULT_POLICY_PATH) -> ResolvedPolicy:
    root = root.resolve()
    absolute_policy_path = policy_path if policy_path.is_absolute() else root / policy_path
    policy = load_json_object(absolute_policy_path, "surface policy")
    if policy.get("schemaVersion") != 1:
        raise SurfacePolicyError("unsupported surface policy schema")
    if policy.get("algorithm") != "sha256" or not policy.get("digestDomain"):
        raise SurfacePolicyError("surface policy digest configuration is invalid")

    inventory = policy.get("inventory")
    groups_definition = policy.get("inputGroups")
    contract_group_names = policy.get("contractInputs")
    surfaces_definition = policy.get("surfaces")
    if (
        not isinstance(inventory, dict)
        or not isinstance(groups_definition, dict)
        or not isinstance(contract_group_names, list)
        or not contract_group_names
        or len(contract_group_names) != len(set(contract_group_names))
    ):
        raise SurfacePolicyError("surface policy inventory or input groups are missing")
    if not isinstance(surfaces_definition, list) or not surfaces_definition:
        raise SurfacePolicyError("surface policy contains no surfaces")
    evidence_policy = validate_evidence_policy(policy.get("evidencePolicy"))
    policy["evidencePolicy"] = evidence_policy

    excluded_basenames = tuple(str(value) for value in inventory.get("excludedBasenames") or [])
    governed_files = expand_patterns(
        root,
        (str(value) for value in inventory.get("governedPatterns") or []),
        excluded_basenames=excluded_basenames,
    )

    ignored_files: set[str] = set()
    ignored_definitions = inventory.get("ignoredInputs") or []
    for ignored in ignored_definitions:
        if not isinstance(ignored, dict) or not ignored.get("pattern") or not ignored.get("reason"):
            raise SurfacePolicyError("ignored input entries require a pattern and reason")
        ignored_files.update(
            expand_patterns(
                root,
                [str(ignored["pattern"])],
                excluded_basenames=excluded_basenames,
            )
        )

    groups: dict[str, tuple[str, ...]] = {}
    for group_name, group in groups_definition.items():
        if not isinstance(group, dict):
            raise SurfacePolicyError(f"input group must be an object: {group_name}")
        group_files = expand_patterns(
            root,
            (str(value) for value in group.get("include") or []),
            excludes=(str(value) for value in group.get("exclude") or []),
            excluded_basenames=excluded_basenames,
        )
        if group.get("forbidPresentationImports") is True:
            for relative_path in group_files:
                if relative_path.endswith(".swift") and PRESENTATION_IMPORT_PATTERN.search(
                    (root / relative_path).read_text()
                ):
                    raise SurfacePolicyError(
                        f"runtime-only input imports a presentation framework: {relative_path}"
                    )
        elif group.get("forbidPresentationImports") not in (None, False):
            raise SurfacePolicyError(
                f"input group presentation-import policy is invalid: {group_name}"
            )
        groups[str(group_name)] = group_files

    surface_ids: set[str] = set()
    surfaces_by_id: dict[str, dict[str, Any]] = {}
    artifact_contracts: dict[str, tuple[str, str, str]] = {}
    evidence_classes = set(evidence_policy.get("classes") or [])
    used_groups: set[str] = set()
    contract_files: set[str] = set()
    for raw_group_name in contract_group_names:
        group_name = str(raw_group_name)
        if group_name not in groups:
            raise SurfacePolicyError(f"contract references an unknown group: {group_name}")
        used_groups.add(group_name)
        contract_files.update(groups[group_name])
    resolved_files: dict[str, dict[str, tuple[str, ...]]] = {}
    for raw_surface in surfaces_definition:
        if not isinstance(raw_surface, dict):
            raise SurfacePolicyError("surface definitions must be objects")
        surface = raw_surface
        surface_id = str(surface.get("id") or "")
        if not surface_id or surface_id in surface_ids:
            raise SurfacePolicyError(f"surface id is missing or duplicated: {surface_id}")
        surface_ids.add(surface_id)
        surfaces_by_id[surface_id] = surface
        artifact_id = str(surface.get("artifactId") or "")
        if not artifact_id:
            raise SurfacePolicyError(f"surface artifact id is missing: {surface_id}")
        artifact_contract = (
            str(surface.get("bundleIdentifier") or ""),
            str(surface.get("projectTarget") or ""),
            str(surface.get("productType") or ""),
        )
        if not all(artifact_contract):
            raise SurfacePolicyError(f"surface artifact contract is incomplete: {surface_id}")
        previous_artifact_contract = artifact_contracts.get(artifact_id)
        if previous_artifact_contract is not None and previous_artifact_contract != artifact_contract:
            raise SurfacePolicyError(f"shared artifact contract drifted: {artifact_id}")
        artifact_contracts[artifact_id] = artifact_contract
        raw_capabilities = surface.get("evidenceCapabilities") or []
        capabilities = set(raw_capabilities)
        if (
            not isinstance(raw_capabilities, list)
            or not capabilities
            or len(raw_capabilities) != len(capabilities)
            or not capabilities <= evidence_classes
        ):
            raise SurfacePolicyError(f"surface evidence capabilities are invalid: {surface_id}")
        inputs = surface.get("inputs")
        if not isinstance(inputs, dict) or set(inputs) != set(INPUT_CLASSES):
            raise SurfacePolicyError(f"surface inputs are missing: {surface_id}")
        class_files: dict[str, tuple[str, ...]] = {}
        class_membership: dict[str, str] = {}
        for class_name in INPUT_CLASSES:
            files: set[str] = set()
            group_names = inputs.get(class_name)
            if not isinstance(group_names, list):
                raise SurfacePolicyError(
                    f"surface input class is invalid: {surface_id}: {class_name}"
                )
            for group_name in group_names:
                group_key = str(group_name)
                if group_key not in groups:
                    raise SurfacePolicyError(f"surface references an unknown group: {group_key}")
                used_groups.add(group_key)
                files.update(groups[group_key])
            class_files[class_name] = tuple(sorted(files, key=lambda value: value.encode("utf-8")))
            if class_name in BASE_INPUT_CLASSES:
                for file_path in class_files[class_name]:
                    previous_class = class_membership.get(file_path)
                    if previous_class is not None and previous_class != class_name:
                        raise SurfacePolicyError(
                            f"surface input is assigned to multiple classes: {surface_id}: {file_path}"
                        )
                    class_membership[file_path] = class_name
        if "shared-view" in capabilities and not (class_files["shared"] or class_files["render"]):
            raise SurfacePolicyError(f"visual surface has no render inputs: {surface_id}")
        if "actual-runtime" in capabilities and not (class_files["shared"] or class_files["runtime"]):
            raise SurfacePolicyError(f"runtime surface has no runtime inputs: {surface_id}")
        if "os-composited-placement" in capabilities and not class_files["placement"]:
            raise SurfacePolicyError(f"placement surface has no placement inputs: {surface_id}")
        if "os-composited-placement" not in capabilities and class_files["placement"]:
            raise SurfacePolicyError(f"non-placement surface has placement inputs: {surface_id}")
        resolved_files[surface_id] = class_files

    unused_groups = sorted(set(groups) - used_groups)
    if unused_groups:
        raise SurfacePolicyError(f"surface policy contains unused input groups: {', '.join(unused_groups)}")

    for surface in surfaces_definition:
        for child_id in surface.get("embeds") or []:
            if child_id not in surfaces_by_id:
                raise SurfacePolicyError(f"surface embeds an unknown surface: {child_id}")

    def visit(surface_id: str, active: set[str], finished: set[str]) -> None:
        if surface_id in finished:
            return
        if surface_id in active:
            raise SurfacePolicyError(f"surface embed graph contains a cycle at {surface_id}")
        active.add(surface_id)
        for child_id in surfaces_by_id[surface_id].get("embeds") or []:
            visit(str(child_id), active, finished)
        active.remove(surface_id)
        finished.add(surface_id)

    finished: set[str] = set()
    for surface_id in sorted(surface_ids):
        visit(surface_id, set(), finished)

    archive_layouts = validate_archive_layouts(
        policy.get("archiveLayouts"), set(artifact_contracts)
    )
    policy["archiveLayouts"] = archive_layouts

    mapped_files: set[str] = set()
    for class_files in resolved_files.values():
        mapped_files.update(*class_files.values())
    mapped_files.update(contract_files)
    ignored_and_mapped = sorted(ignored_files & mapped_files)
    if ignored_and_mapped:
        raise SurfacePolicyError(f"ignored inputs are also mapped: {', '.join(ignored_and_mapped)}")
    unmapped_files = sorted(set(governed_files) - ignored_files - mapped_files)
    if unmapped_files:
        raise SurfacePolicyError(f"governed inputs are unmapped: {', '.join(unmapped_files[:10])}")

    all_paths = set(governed_files) | ignored_files | mapped_files
    validate_paths(root, all_paths)
    file_hashes = {path: file_sha256(root / path) for path in sorted(mapped_files)}

    project_payload = load_project_payload(root, policy)
    project = project_payload["project"]
    unsupported_project_keys = sorted(set(project) - SUPPORTED_PROJECT_KEYS)
    if unsupported_project_keys:
        raise SurfacePolicyError(
            f"project specification uses unsupported top-level keys: {', '.join(unsupported_project_keys)}"
        )
    resolved_surfaces: list[ResolvedSurface] = []
    digest_domain = str(policy["digestDomain"])
    for surface in surfaces_definition:
        surface_id = str(surface["id"])
        closure, projection = validate_surface_project_contract(
            root,
            project,
            surface,
            resolved_files[surface_id],
            surfaces_by_id,
        )
        project_fingerprint = hash_parts(
            f"{digest_domain}/project",
            [canonical_json(projection)],
        )
        resolved_surfaces.append(
            ResolvedSurface(
                surface,
                resolved_files[surface_id],
                closure,
                projection,
                project_fingerprint,
            )
        )

    contract_parts: list[bytes | str] = []
    for relative_path in sorted(contract_files, key=lambda value: value.encode("utf-8")):
        contract_parts.extend((relative_path, file_hashes[relative_path]))
    contract_fingerprint = hash_parts(f"{digest_domain}/contract", contract_parts)

    return ResolvedPolicy(
        root,
        absolute_policy_path,
        policy,
        project_payload,
        groups,
        tuple(resolved_surfaces),
        governed_files,
        tuple(sorted(ignored_files)),
        tuple(sorted(contract_files)),
        contract_fingerprint,
        file_hashes,
    )


def surface_metadata(surface: dict[str, Any]) -> dict[str, Any]:
    return {
        key: surface.get(key)
        for key in (
            "id",
            "artifactId",
            "displayName",
            "platform",
            "deviceClass",
            "projectTarget",
            "projectDestination",
            "scheme",
            "productType",
            "bundleIdentifier",
            "evidenceCapabilities",
        )
    }


def fingerprint_input_parts(
    resolved: ResolvedPolicy,
    paths: Iterable[str],
) -> list[bytes | str]:
    parts: list[bytes | str] = []
    for path in sorted(set(paths), key=lambda value: value.encode("utf-8")):
        parts.extend((path, resolved.file_hashes[path]))
    return parts


def generate_manifest(
    resolved: ResolvedPolicy,
    *,
    marketing_version: str,
    build_number: str,
    source_commit: str,
    configuration: str,
    xcode_build: str,
    tree_state: str,
) -> dict[str, Any]:
    for label, value in (
        ("marketing version", marketing_version),
        ("build number", build_number),
        ("source commit", source_commit),
        ("configuration", configuration),
        ("Xcode build", xcode_build),
    ):
        if not value or any(ord(character) < 32 for character in value):
            raise SurfacePolicyError(f"{label} is missing or contains control characters")
    if tree_state not in {"clean", "dirty", "unknown"}:
        raise SurfacePolicyError("source tree state is invalid")
    policy = resolved.policy
    digest_domain = str(policy["digestDomain"])
    toolchain = policy.get("toolchain") or {}
    evidence_policy = policy.get("evidencePolicy") or {}
    policy_sha256 = file_sha256(resolved.policy_path)
    project_source_sha256 = str(resolved.project_payload.get("sourceSha256") or "")

    fingerprint_entries: dict[str, dict[str, str]] = {}
    surface_entries: dict[str, dict[str, Any]] = {}
    for resolved_surface in resolved.surfaces:
        surface = resolved_surface.definition
        surface_id = str(surface["id"])
        metadata = surface_metadata(surface)
        shared_files = resolved_surface.files["shared"]
        render_files = resolved_surface.files["render"]
        runtime_files = resolved_surface.files["runtime"]
        placement_files = resolved_surface.files["placement"]
        common_parts: list[bytes | str] = [
            canonical_json(metadata),
            canonical_json(toolchain),
            resolved_surface.project_fingerprint,
        ]
        render_fingerprint = hash_parts(
            f"{digest_domain}/render",
            [
                *common_parts,
                *fingerprint_input_parts(resolved, (*shared_files, *render_files)),
            ],
        )
        runtime_fingerprint = hash_parts(
            f"{digest_domain}/runtime",
            [
                *common_parts,
                *fingerprint_input_parts(resolved, (*shared_files, *runtime_files)),
            ],
        )
        placement_fingerprint = hash_parts(
            f"{digest_domain}/placement",
            [
                *common_parts,
                *fingerprint_input_parts(resolved, placement_files),
            ],
        )
        fingerprint_entries[surface_id] = {
            "render": render_fingerprint,
            "runtime": runtime_fingerprint,
            "placement": placement_fingerprint,
        }
        surface_entries[surface_id] = {
            **metadata,
            "embeds": list(surface.get("embeds") or []),
            "projectTargets": list(resolved_surface.project_targets),
            "projectFingerprint": resolved_surface.project_fingerprint,
            "inputs": {
                class_name: list(resolved_surface.files[class_name])
                for class_name in INPUT_CLASSES
            },
            "expectedArtifact": {
                "artifactId": surface["artifactId"],
                "bundleIdentifier": surface["bundleIdentifier"],
                "marketingVersion": marketing_version,
                "buildNumber": build_number,
                "sourceCommit": source_commit,
                "configuration": configuration,
                "xcodeBuild": xcode_build,
                "treeState": tree_state,
            },
        }

    surfaces_by_id = {surface.definition["id"]: surface.definition for surface in resolved.surfaces}

    def combined_fingerprint(surface_id: str, cache: dict[str, str]) -> str:
        cached = cache.get(surface_id)
        if cached is not None:
            return cached
        child_parts: list[bytes | str] = []
        for child_id in sorted(surfaces_by_id[surface_id].get("embeds") or []):
            child_parts.extend((child_id, combined_fingerprint(str(child_id), cache)))
        fingerprints = fingerprint_entries[surface_id]
        value = hash_parts(
            f"{digest_domain}/combined",
            [
                surface_id,
                fingerprints["render"],
                fingerprints["runtime"],
                fingerprints["placement"],
                *child_parts,
            ],
        )
        cache[surface_id] = value
        return value

    combined_cache: dict[str, str] = {}
    for surface_id in sorted(surface_entries):
        surface_entries[surface_id]["fingerprints"] = {
            **fingerprint_entries[surface_id],
            "combined": combined_fingerprint(surface_id, combined_cache),
        }

    payload: dict[str, Any] = {
        "schemaVersion": 1,
        "algorithm": policy["algorithm"],
        "digestDomain": digest_domain,
        "contractFingerprint": resolved.contract_fingerprint,
        "source": {
            "marketingVersion": marketing_version,
            "buildNumber": build_number,
            "commit": source_commit,
            "configuration": configuration,
            "xcodeBuild": xcode_build,
            "treeState": tree_state,
            "policySha256": policy_sha256,
            "projectSourceSha256": project_source_sha256,
        },
        "toolchain": toolchain,
        "archiveLayouts": policy["archiveLayouts"],
        "evidencePolicy": evidence_policy,
        "artifactEvidenceContract": {
            "schemaVersion": 1,
            "integrity": "code-signature-plus-manifest-match",
            "requiredFields": [
                "bundleIdentifier",
                "marketingVersion",
                "buildNumber",
                "sourceCommit",
                "executableSha256",
                "executableUUIDs",
                "entitlementsSha256",
                "profileSha256",
            ],
        },
        "files": {path: resolved.file_hashes[path] for path in sorted(resolved.file_hashes)},
        "ignoredInputs": resolved.policy["inventory"].get("ignoredInputs") or [],
        "surfaces": [surface_entries[surface_id] for surface_id in sorted(surface_entries)],
    }
    payload["manifestId"] = hash_parts(
        f"{digest_domain}/manifest",
        [canonical_json(payload)],
    )
    return payload


def embedded_manifest(source_manifest: dict[str, Any]) -> dict[str, Any]:
    if source_manifest.get("schemaVersion") != 1:
        raise SurfacePolicyError("source manifest schema is unsupported")
    manifest_id = str(source_manifest.get("manifestId") or "")
    contract_fingerprint = str(source_manifest.get("contractFingerprint") or "")
    if not SHA256_PATTERN.fullmatch(manifest_id) or not SHA256_PATTERN.fullmatch(
        contract_fingerprint
    ):
        raise SurfacePolicyError("source manifest identity is invalid")
    surfaces = manifest_surface_map(source_manifest, "source")
    return {
        "schemaVersion": 1,
        "kind": "context-panel-surface-build-intent",
        "manifestId": manifest_id,
        "contractFingerprint": contract_fingerprint,
        "surfaces": [
            {
                "id": surface_id,
                "artifactId": surfaces[surface_id].get("artifactId"),
                "bundleIdentifier": surfaces[surface_id].get("bundleIdentifier"),
                "fingerprints": surfaces[surface_id].get("fingerprints"),
            }
            for surface_id in sorted(surfaces)
        ],
    }


def manifest_surface_map(manifest: dict[str, Any], label: str) -> dict[str, dict[str, Any]]:
    raw_surfaces = manifest.get("surfaces")
    if not isinstance(raw_surfaces, list) or not raw_surfaces:
        raise SurfacePolicyError(f"{label} manifest contains no surfaces")
    surfaces: dict[str, dict[str, Any]] = {}
    for raw_surface in raw_surfaces:
        if not isinstance(raw_surface, dict):
            raise SurfacePolicyError(f"{label} manifest surface is invalid")
        surface_id = str(raw_surface.get("id") or "")
        if not surface_id or surface_id in surfaces:
            raise SurfacePolicyError(f"{label} manifest surface id is missing or duplicated")
        fingerprints = raw_surface.get("fingerprints")
        if not isinstance(fingerprints, dict) or any(
            not SHA256_PATTERN.fullmatch(str(fingerprints.get(kind) or ""))
            for kind in ("render", "runtime", "placement", "combined")
        ):
            raise SurfacePolicyError(f"{label} manifest surface fingerprints are invalid: {surface_id}")
        surfaces[surface_id] = raw_surface
    return surfaces


def seal_expected_build(
    source_manifest: dict[str, Any],
    artifact_evidence: dict[str, Any],
) -> dict[str, Any]:
    if source_manifest.get("schemaVersion") != 1:
        raise SurfacePolicyError("source manifest schema is unsupported")
    if artifact_evidence.get("schemaVersion") != 1:
        raise SurfacePolicyError("artifact evidence schema is unsupported")
    if artifact_evidence.get("sourceManifestId") != source_manifest.get("manifestId"):
        raise SurfacePolicyError("artifact evidence source manifest does not match")
    source = source_manifest.get("source")
    if not isinstance(source, dict):
        raise SurfacePolicyError("source manifest identity is missing")
    surfaces = manifest_surface_map(source_manifest, "source")
    expected_artifacts: dict[str, dict[str, str]] = {}
    for surface in surfaces.values():
        artifact_id = str(surface.get("artifactId") or "")
        contract = {
            "bundleIdentifier": str(surface.get("bundleIdentifier") or ""),
            "marketingVersion": str(source.get("marketingVersion") or ""),
            "buildNumber": str(source.get("buildNumber") or ""),
            "sourceCommit": str(source.get("commit") or ""),
            "configuration": str(source.get("configuration") or ""),
            "xcodeBuild": str(source.get("xcodeBuild") or ""),
            "treeState": str(source.get("treeState") or ""),
        }
        previous_contract = expected_artifacts.get(artifact_id)
        if previous_contract is not None and previous_contract != contract:
            raise SurfacePolicyError(f"source manifest artifact contract drifted: {artifact_id}")
        expected_artifacts[artifact_id] = contract

    layout_name = artifact_evidence.get("layout")
    archive_layouts = source_manifest.get("archiveLayouts")
    if layout_name is not None:
        if not isinstance(layout_name, str) or not isinstance(archive_layouts, dict):
            raise SurfacePolicyError("artifact evidence archive layout is invalid")
        layout = archive_layouts.get(layout_name)
        if not isinstance(layout, dict) or not layout:
            raise SurfacePolicyError(f"unknown archive layout: {layout_name}")
        layout_artifacts = set(str(artifact_id) for artifact_id in layout)
        expected_artifacts = {
            artifact_id: contract
            for artifact_id, contract in expected_artifacts.items()
            if artifact_id in layout_artifacts
        }

    raw_artifacts = artifact_evidence.get("artifacts")
    if not isinstance(raw_artifacts, list):
        raise SurfacePolicyError("artifact evidence contains no artifacts")
    artifacts: dict[str, dict[str, Any]] = {}
    for raw_artifact in raw_artifacts:
        if not isinstance(raw_artifact, dict):
            raise SurfacePolicyError("artifact evidence entry is invalid")
        artifact_id = str(raw_artifact.get("artifactId") or "")
        if not artifact_id or artifact_id in artifacts:
            raise SurfacePolicyError("artifact evidence id is missing or duplicated")
        expected = expected_artifacts.get(artifact_id)
        if expected is None:
            raise SurfacePolicyError(f"artifact evidence references an unknown artifact: {artifact_id}")
        for key, expected_value in expected.items():
            if str(raw_artifact.get(key) or "") != expected_value:
                raise SurfacePolicyError(f"artifact evidence identity mismatch: {artifact_id}: {key}")
        if raw_artifact.get("codeSignatureValid") is not True:
            raise SurfacePolicyError(f"artifact code signature is not valid: {artifact_id}")
        for key in ("executableSha256", "entitlementsSha256", "profileSha256"):
            if not SHA256_PATTERN.fullmatch(str(raw_artifact.get(key) or "")):
                raise SurfacePolicyError(f"artifact evidence hash is invalid: {artifact_id}: {key}")
        raw_uuids = raw_artifact.get("executableUUIDs")
        if not isinstance(raw_uuids, list) or not raw_uuids:
            raise SurfacePolicyError(f"artifact executable UUIDs are missing: {artifact_id}")
        uuids = sorted({str(value).upper() for value in raw_uuids})
        if len(uuids) != len(raw_uuids) or any(not UUID_PATTERN.fullmatch(value) for value in uuids):
            raise SurfacePolicyError(f"artifact executable UUIDs are invalid: {artifact_id}")
        artifacts[artifact_id] = {
            **expected,
            "artifactId": artifact_id,
            "codeSignatureValid": True,
            "executableSha256": str(raw_artifact["executableSha256"]),
            "executableUUIDs": uuids,
            "entitlementsSha256": str(raw_artifact["entitlementsSha256"]),
            "profileSha256": str(raw_artifact["profileSha256"]),
        }

    missing_artifacts = sorted(set(expected_artifacts) - set(artifacts))
    if missing_artifacts:
        raise SurfacePolicyError(
            f"artifact evidence is incomplete: {', '.join(missing_artifacts)}"
        )

    payload: dict[str, Any] = {
        "schemaVersion": 1,
        "kind": "context-panel-expected-signed-build",
        "algorithm": source_manifest.get("algorithm"),
        "digestDomain": source_manifest.get("digestDomain"),
        "sourceManifestId": source_manifest.get("manifestId"),
        "contractFingerprint": source_manifest.get("contractFingerprint"),
        "layout": layout_name,
        "archive": {
            "layout": layout_name,
            "name": artifact_evidence.get("archiveName"),
        },
        "source": source,
        "artifacts": [artifacts[artifact_id] for artifact_id in sorted(artifacts)],
        "surfaces": [
            {
                "id": surface_id,
                "artifactId": surfaces[surface_id].get("artifactId"),
                "bundleIdentifier": surfaces[surface_id].get("bundleIdentifier"),
                "fingerprints": surfaces[surface_id].get("fingerprints"),
            }
            for surface_id in sorted(surfaces)
            if surfaces[surface_id].get("artifactId") in expected_artifacts
        ],
    }
    payload["expectedBuildId"] = hash_parts(
        f"{source_manifest.get('digestDomain')}/expected-build",
        [canonical_json(payload)],
    )
    return payload


def ordered_intersection(values: Iterable[str], allowed: set[str], order: list[str]) -> list[str]:
    selected = set(values) & allowed
    return [value for value in order if value in selected]


def compare_manifests(
    previous: dict[str, Any],
    current: dict[str, Any],
    train: str,
) -> dict[str, Any]:
    if previous.get("schemaVersion") != 1 or current.get("schemaVersion") != 1:
        raise SurfacePolicyError("surface manifest schema is unsupported")
    evidence_policy = validate_evidence_policy(current.get("evidencePolicy"))
    class_order = [str(value) for value in evidence_policy["classes"]]
    train_minimums = evidence_policy["trainMinimumEvidence"]
    if train not in TRAIN_NAMES:
        raise SurfacePolicyError(f"unknown release train: {train}")
    change_requirements = evidence_policy["changeRequirements"]
    previous_surfaces = manifest_surface_map(previous, "previous")
    current_surfaces = manifest_surface_map(current, "current")
    previous_contract_fingerprint = str(previous.get("contractFingerprint") or "")
    current_contract_fingerprint = str(current.get("contractFingerprint") or "")
    if not SHA256_PATTERN.fullmatch(previous_contract_fingerprint) or not SHA256_PATTERN.fullmatch(
        current_contract_fingerprint
    ):
        raise SurfacePolicyError("surface manifest contract fingerprint is invalid")
    contract_changed = previous_contract_fingerprint != current_contract_fingerprint
    previous_source = previous.get("source") or {}
    current_source = current.get("source") or {}
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
            render_changed = previous_fingerprints.get("render") != current_fingerprints.get("render")
            runtime_changed = previous_fingerprints.get("runtime") != current_fingerprints.get("runtime")
            placement_changed = (
                previous_fingerprints.get("placement")
                != current_fingerprints.get("placement")
            )
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
            if not exact_build_same and "actual-runtime" in capabilities:
                fresh.add("actual-runtime")
        fresh_evidence = ordered_intersection(fresh, capabilities, class_order)

        carry_forward: dict[str, dict[str, Any]] = {}
        for evidence_class in ordered_intersection(class_order, capabilities, class_order):
            eligible = False
            conditions: list[str] = []
            if previous_surface is not None:
                if evidence_class == "shared-view":
                    eligible = not render_changed and not contract_changed
                elif evidence_class == "actual-runtime":
                    eligible = not runtime_changed and exact_build_same and not contract_changed
                elif evidence_class == "os-composited-placement":
                    eligible = (
                        not render_changed
                        and not placement_changed
                        and not contract_changed
                    )
                    if eligible:
                        conditions = ["matching-host-os", "matching-current-runtime-receipt"]
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
                "carryForward": carry_forward,
            }
        )

    removed_surfaces = sorted(set(previous_surfaces) - set(current_surfaces))
    return {
        "schemaVersion": 1,
        "train": train,
        "previousManifestId": previous.get("manifestId"),
        "currentManifestId": current.get("manifestId"),
        "contractChanged": contract_changed,
        "exactBuildSame": exact_build_same,
        "removedSurfaces": removed_surfaces,
        "surfaces": results,
        "releaseRequiresApprovedRCTarget": bool(
            evidence_policy.get("releaseRequiresApprovedRCTarget")
        ),
    }


def validation_summary(resolved: ResolvedPolicy) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "surfaceCount": len(resolved.surfaces),
        "artifactCount": len(
            {str(surface.definition["artifactId"]) for surface in resolved.surfaces}
        ),
        "governedInputCount": len(resolved.governed_files),
        "mappedInputCount": len(resolved.file_hashes),
        "ignoredInputCount": len(resolved.ignored_files),
        "surfaceIds": sorted(str(surface.definition["id"]) for surface in resolved.surfaces),
    }
