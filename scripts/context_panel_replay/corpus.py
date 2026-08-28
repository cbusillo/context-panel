from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from pathlib import Path, PurePosixPath
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
SUPPORTED_SCHEMA_VERSION = 2
EVIDENCE_CLASSES = {
    "shared-view",
    "actual-runtime",
    "os-composited-placement",
}
SOURCE_CONSTRAINTS = {
    "physical-exact-build",
    "os-composited-physical",
    "deterministic-gallery",
}
POSITIVE_CAUSAL_CONFIDENCE = "confirmed-by-public-record"
RESIDUAL_RISK_CLASSES = {
    "historical-evidence-loss",
    "over-triggered-policy",
    "unrepresented-surface",
    "unsupported-evidence-class",
    "toolchain-dependency",
}
TOKEN_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
GIT_VERSION_PATTERN = re.compile(r"git version ([0-9]+(?:\.[0-9]+){2,3})\n?")
UUID_PATTERN = re.compile(
    r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"
)
ABSOLUTE_PATH_PATTERN = re.compile(r"(?:^|[^\w/])/(?!/)")
FILE_URL_ABSOLUTE_PATH_PATTERN = re.compile(r"(?i)\bfile://\S+")
PRIVATE_HOST_PATTERN = re.compile(r"(?i)\b(?:localhost|private|127\.0\.0\.1)\b")
PRIVATE_NETWORK_PATTERN = re.compile(
    r"(?i)(?:"
    r"\b10(?:\.\d{1,3}){3}\b|"
    r"\b127(?:\.\d{1,3}){3}\b|"
    r"\b169\.254(?:\.\d{1,3}){2}\b|"
    r"\b172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}\b|"
    r"\b192\.168(?:\.\d{1,3}){2}\b|"
    r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])(?:\.\d{1,3}){2}\b|"
    r"\b198\.(?:18|19)(?:\.\d{1,3}){2}\b|"
    r"\b(?:22[4-9]|23\d)(?:\.\d{1,3}){3}\b|"
    r"\b[a-z0-9.-]+\.(?:home\.arpa|internal|lan|local)\b|"
    r"(?<![0-9a-f:])::1(?![0-9a-f:])|"
    r"\b(?:fc|fd)[0-9a-f]{2}:|"
    r"\bfe[89ab][0-9a-f]:"
    r")"
)
SECRET_PATTERN = re.compile(
    r"(?i)(?:\b(?:aws[_ -]?secret[_ -]?access[_ -]?key|account[_ -]?id|client[_ -]?id|"
    r"(?:access|app|auth|client|consumer|encryption|private|refresh|session|signing)[_ -]?"
    r"(?:key|secret|token)|api[_ -]?key|authorization|credential|password|secret|token|x-api-key)"
    r"\s*[:=]|\b(?:bearer|basic)\s+\S+)"
)
STANDALONE_SECRET_PATTERN = re.compile(
    r"(?:\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bAIza[0-9A-Za-z_-]{30,}\b|"
    r"\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}\b|"
    r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b)"
)
EMAIL_PATTERN = re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")
ACCOUNT_IDENTIFIER_PATTERN = re.compile(r"(?i)\b(?:acct|account|org|user)[_-][A-Za-z0-9]{12,}\b")
URI_USERINFO_PATTERN = re.compile(
    r"(?i)(?:(?:\b[a-z][a-z0-9+.-]*:)?//[^\s/@]+(?::[^\s/@]*)?@|"
    r"(?<![\w@])[^:\s/@]+:[^@\s/]+@[a-z0-9.-]+(?::\d+)?\b)"
)
DEVICE_PATTERN = re.compile(r"(?i)\b(?:device[-_ ]?(?:id|name)|udid|serial(?:[-_ ]?number)?)\b")
UNSAFE_FIELD_NAMES = {
    "accountid",
    "authorization",
    "clientid",
    "credential",
    "device",
    "deviceid",
    "devicename",
    "password",
    "rawreceipt",
    "receiptbody",
    "secret",
    "serialnumber",
    "sessionid",
    "token",
    "udid",
}


class CorpusError(ValueError):
    pass


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def render_json(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CorpusError("JSON contains duplicate object keys")
        result[key] = value
    return result


def load_json(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink():
        raise CorpusError(f"{label} must not be a symlink")
    try:
        value = json.loads(path.read_text(), object_pairs_hook=_reject_duplicate_keys)
    except CorpusError:
        raise
    except (OSError, json.JSONDecodeError) as error:
        raise CorpusError(f"{label} is unavailable or invalid JSON") from error
    if not isinstance(value, dict):
        raise CorpusError(f"{label} must be a JSON object")
    return value


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise CorpusError(f"{label} has an invalid shape")


def _token(value: Any, label: str) -> str:
    if not isinstance(value, str) or TOKEN_PATTERN.fullmatch(value) is None:
        raise CorpusError(f"{label} is invalid")
    return value


def _unique_tokens(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise CorpusError(f"{label} must be a non-empty list")
    tokens = [_token(item, f"{label} entry") for item in value]
    if len(tokens) != len(set(tokens)):
        raise CorpusError(f"{label} contains duplicates")
    return tokens


def _relative_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise CorpusError(f"{label} is invalid")
    path = PurePosixPath(value)
    if path.is_absolute() or "." in path.parts or ".." in path.parts or str(path) != value:
        raise CorpusError(f"{label} must be a normalized relative path")
    return value


def _public_safe(value: Any, label: str = "corpus") -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = key.lower().replace("_", "").replace("-", "")
            if normalized in UNSAFE_FIELD_NAMES:
                raise CorpusError(f"{label} contains a private field")
            _public_safe(item, f"{label}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _public_safe(item, f"{label}[{index}]")
    elif isinstance(value, str):
        if (
            UUID_PATTERN.search(value)
            or ABSOLUTE_PATH_PATTERN.search(value)
            or FILE_URL_ABSOLUTE_PATH_PATTERN.search(value)
            or PRIVATE_HOST_PATTERN.search(value)
            or PRIVATE_NETWORK_PATTERN.search(value)
            or SECRET_PATTERN.search(value)
            or STANDALONE_SECRET_PATTERN.search(value)
            or EMAIL_PATTERN.search(value)
            or ACCOUNT_IDENTIFIER_PATTERN.search(value)
            or URI_USERINFO_PATTERN.search(value)
            or "-----BEGIN" in value
            or DEVICE_PATTERN.search(value)
        ):
            raise CorpusError(f"{label} is not public-safe")


def _load_surface_policy(path: Path, *, revision: str) -> tuple[dict[str, Any], str]:
    try:
        relative_path = path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError as error:
        raise CorpusError("surface policy must be inside the repository") from error
    try:
        policy = json.loads(
            _git_output(["show", f"{revision}:{relative_path}"]),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except CorpusError:
        raise
    except json.JSONDecodeError as error:
        raise CorpusError("surface policy is unavailable or invalid JSON") from error
    if not isinstance(policy, dict):
        raise CorpusError("surface policy must be a JSON object")
    evidence_policy = policy.get("evidencePolicy")
    surfaces = policy.get("surfaces")
    if not isinstance(evidence_policy, dict) or not isinstance(surfaces, list):
        raise CorpusError("surface policy has an invalid shape")
    policy_classes = evidence_policy.get("classes")
    change_requirements = evidence_policy.get("changeRequirements")
    if not isinstance(policy_classes, list) or set(policy_classes) != EVIDENCE_CLASSES:
        raise CorpusError("surface policy evidence classes are unsupported")
    if not isinstance(change_requirements, dict) or not change_requirements:
        raise CorpusError("surface policy change requirements are unavailable")
    change_kinds = set(change_requirements)
    if change_kinds != {"render", "runtime", "placement", "unknown"}:
        raise CorpusError("surface policy change-kind vocabulary is unsupported")
    normalized_requirements: dict[str, set[str]] = {}
    for change_kind, required_classes in change_requirements.items():
        if not isinstance(required_classes, list) or not required_classes:
            raise CorpusError("surface policy change requirements are invalid")
        if len(required_classes) != len(set(required_classes)) or not set(required_classes).issubset(EVIDENCE_CLASSES):
            raise CorpusError("surface policy change requirements are invalid")
        normalized_requirements[change_kind] = set(required_classes)
    capabilities: dict[str, set[str]] = {}
    for surface in surfaces:
        if not isinstance(surface, dict):
            raise CorpusError("surface policy contains an invalid surface")
        surface_id = surface.get("id")
        evidence_capabilities = surface.get("evidenceCapabilities")
        if not isinstance(surface_id, str) or not isinstance(evidence_capabilities, list):
            raise CorpusError("surface policy contains an invalid surface")
        if surface_id in capabilities:
            raise CorpusError("surface policy contains duplicate surface IDs")
        if not set(evidence_capabilities).issubset(EVIDENCE_CLASSES):
            raise CorpusError("surface policy contains an unsupported evidence capability")
        capabilities[surface_id] = set(evidence_capabilities)
    return {
        "capabilities": capabilities,
        "changeKinds": change_kinds,
        "changeRequirements": normalized_requirements,
    }, canonical_digest(policy)


def _require_known_surfaces(value: Any, capabilities: dict[str, set[str]], label: str) -> list[str]:
    if not isinstance(value, list) or not value or any(not isinstance(item, str) for item in value):
        raise CorpusError(f"{label} must be a non-empty list")
    surfaces = list(value)
    if len(surfaces) != len(set(surfaces)):
        raise CorpusError(f"{label} contains duplicates")
    unknown = sorted(set(surfaces) - set(capabilities))
    if unknown:
        raise CorpusError(f"{label} contains unknown surfaces: {', '.join(unknown)}")
    return sorted(surfaces)


def _git_output(arguments: list[str]) -> str:
    environment = {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_NO_LAZY_FETCH": "1",
        "HOME": os.environ.get("HOME", "/tmp"),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    }
    completed = subprocess.run(
        [
            "git",
            "-c",
            "color.ui=false",
            "-c",
            "core.quotePath=true",
            "-c",
            "core.attributesFile=/dev/null",
            "-c",
            "diff.algorithm=myers",
            "-c",
            "diff.context=3",
            "-c",
            "diff.noprefix=false",
            "-c",
            "diff.renames=false",
            "-c",
            "diff.indentHeuristic=true",
            "-c",
            "diff.orderFile=/dev/null",
            "-c",
            "diff.suppressBlankEmpty=false",
            "-c",
            "log.showSignature=false",
            *arguments,
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        env=environment,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise CorpusError("offline repository citation validation failed")
    return completed.stdout


def _git_succeeds(arguments: list[str]) -> bool:
    try:
        _git_output(arguments)
    except CorpusError:
        return False
    return True


def _commit_change(
    commit: str,
    *,
    base_commit: str | None = None,
    attr_source: str | None = None,
) -> dict[str, Any]:
    _git_output(["cat-file", "-e", f"{commit}^{{commit}}"])
    base = base_commit or f"{commit}^"
    _git_output(["cat-file", "-e", f"{base}^{{commit}}"])
    paths = sorted(
        filter(
            None,
            _git_output(["diff", "--name-only", "--no-renames", base, commit]).splitlines(),
        )
    )
    immutable_attr_source = attr_source or commit
    patch = _git_output(
        [
            f"--attr-source={immutable_attr_source}",
            "diff",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--full-index",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            "--unified=3",
            base,
            commit,
        ]
    )
    added_lines_by_path = {
        path: [
            line
            for line in _git_output(
                [
                    f"--attr-source={immutable_attr_source}",
                    "diff",
                    "--no-color",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--no-renames",
                    "--unified=0",
                    base,
                    commit,
                    "--",
                    path,
                ]
            ).splitlines()
            if line.startswith("+") and not line.startswith("+++")
        ]
        for path in paths
    }
    return {
        "addedLinesByPath": added_lines_by_path,
        "commit": commit,
        "patch": patch,
        "patchDigest": hashlib.sha256(patch.encode("utf-8")).hexdigest(),
        "paths": paths,
    }


def _combine_commit_changes(
    commits: list[str],
    *,
    base_commits: list[str] | None = None,
    attr_source: str | None = None,
) -> dict[str, Any]:
    if base_commits is not None and len(base_commits) != len(commits):
        raise CorpusError("citation change bases are invalid")
    changes = [
        _commit_change(
            commit,
            base_commit=None if base_commits is None else base_commits[index],
            attr_source=attr_source,
        )
        for index, commit in enumerate(commits)
    ]
    return {
        "commits": [
            {"commit": change["commit"], "patchDigest": change["patchDigest"], "paths": change["paths"]}
            for change in changes
        ],
        "patch": "\n".join(change["patch"] for change in changes),
        "addedLinesByPath": {
            path: [
                line
                for change in changes
                for line in change["addedLinesByPath"].get(path, [])
            ]
            for path in sorted({path for change in changes for path in change["paths"]})
        },
        "patchDigest": canonical_digest(
            [{"commit": change["commit"], "patchDigest": change["patchDigest"]} for change in changes]
        ),
        "paths": sorted({path for change in changes for path in change["paths"]}),
    }


def _combine_citation_changes(
    citations: list[dict[str, Any]],
    *,
    attr_source: str | None = None,
) -> dict[str, Any]:
    commits = [citation["implementationCommit"] for citation in citations]
    base_commits = [
        _git_output(
            ["show", "--no-show-signature", "-s", "--format=%P", citation["mergeCommit"]]
        ).split()[0]
        for citation in citations
    ]
    return _combine_commit_changes(
        commits,
        base_commits=base_commits,
        attr_source=attr_source,
    )


def _compiled_change(change: dict[str, Any]) -> dict[str, Any]:
    result = {
        "patchDigest": change["patchDigest"],
        "paths": change["paths"],
    }
    if "commits" in change:
        result["commits"] = change["commits"]
    else:
        result["commit"] = change["commit"]
    return result


def _validate_citation(
    citation: Any,
    label: str,
    *,
    curated_through_commit: str,
) -> dict[str, Any]:
    if not isinstance(citation, dict):
        raise CorpusError(f"{label} must be an object")
    kind = citation.get("kind")
    if kind == "pull-request":
        _exact_keys(citation, {"implementationCommit", "kind", "mergeCommit", "number"}, label)
        number = citation["number"]
        merge_commit = citation["mergeCommit"]
        implementation_commit = citation["implementationCommit"]
        if not isinstance(number, int) or isinstance(number, bool) or number < 1:
            raise CorpusError(f"{label}.number is invalid")
        if not isinstance(merge_commit, str) or SHA_PATTERN.fullmatch(merge_commit) is None:
            raise CorpusError(f"{label}.mergeCommit must be a full SHA")
        if not isinstance(implementation_commit, str) or SHA_PATTERN.fullmatch(implementation_commit) is None:
            raise CorpusError(f"{label}.implementationCommit must be a full SHA")
        _git_output(["cat-file", "-e", f"{merge_commit}^{{commit}}"])
        _git_output(["cat-file", "-e", f"{implementation_commit}^{{commit}}"])
        parents = _git_output(["show", "--no-show-signature", "-s", "--format=%P", merge_commit]).split()
        if len(parents) != 2:
            raise CorpusError(f"{label}.mergeCommit must be a two-parent merge")
        subject = _git_output(["show", "--no-show-signature", "-s", "--format=%s", merge_commit]).rstrip("\n")
        if re.fullmatch(rf"Merge pull request #{number} from .+", subject) is None:
            raise CorpusError(f"{label}.mergeCommit does not match its pull request number")
        if implementation_commit != parents[1]:
            raise CorpusError(f"{label}.implementationCommit must equal merge second parent")
        if _git_output(["merge-base", parents[0], parents[1]]).strip() != parents[0]:
            raise CorpusError(f"{label}.mergeCommit first parent must be the pull request base")
        if not _git_succeeds(["merge-base", "--is-ancestor", merge_commit, curated_through_commit]):
            raise CorpusError(f"{label}.mergeCommit is outside curated history")
        if not _git_succeeds(["merge-base", "--is-ancestor", implementation_commit, curated_through_commit]):
            raise CorpusError(f"{label}.implementationCommit is outside curated history")
        return {
            "implementationCommit": implementation_commit,
            "kind": kind,
            "mergeCommit": merge_commit,
            "number": number,
        }
    if kind == "repository-anchor":
        _exact_keys(citation, {"anchor", "kind", "path"}, label)
        path = _relative_path(citation["path"], f"{label}.path")
        anchor = citation["anchor"]
        if not isinstance(anchor, str) or not anchor or "\n" in anchor:
            raise CorpusError(f"{label}.anchor is invalid")
        try:
            contents = _git_output(["show", f"{curated_through_commit}:{path}"])
        except CorpusError as error:
            raise CorpusError(f"{label} path is unavailable") from error
        if anchor not in contents:
            raise CorpusError(f"{label} anchor is unavailable")
        return {"kind": kind, "path": path, "anchor": anchor}
    raise CorpusError(f"{label} has an unknown citation kind")


def _validate_citations(
    value: Any,
    label: str,
    *,
    incident: bool,
    curated_through_commit: str,
) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise CorpusError(f"{label} must be a non-empty list")
    citations = [
        _validate_citation(
            item,
            f"{label} entry",
            curated_through_commit=curated_through_commit,
        )
        for item in value
    ]
    rendered = [canonical_json(item) for item in citations]
    if len(rendered) != len(set(rendered)):
        raise CorpusError(f"{label} contains duplicates")
    kinds = {citation["kind"] for citation in citations}
    if incident and kinds != {"pull-request"}:
        raise CorpusError(f"{label} must contain exact pull request citations only")
    return sorted(citations, key=canonical_json)


def _default_source_constraint(evidence_class: str) -> str:
    if evidence_class == "shared-view":
        return "deterministic-gallery"
    if evidence_class == "os-composited-placement":
        return "os-composited-physical"
    return "physical-exact-build"


def _allowed_source_constraints(evidence_class: str) -> set[str]:
    if evidence_class == "shared-view":
        return {"deterministic-gallery", "physical-exact-build"}
    return {_default_source_constraint(evidence_class)}


def _validate_evidence_oracle(
    value: Any,
    affected_surfaces: list[str],
    capabilities: dict[str, set[str]],
    label: str,
) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise CorpusError(f"{label} must be a list")
    if not value:
        raise CorpusError(f"{label} must not be empty")
    normalized: list[dict[str, str]] = []
    for evidence in value:
        if not isinstance(evidence, dict):
            raise CorpusError(f"{label} contains an invalid entry")
        _exact_keys(evidence, {"evidenceClass", "sourceConstraint", "surface"}, f"{label} entry")
        surface = evidence["surface"]
        evidence_class = evidence["evidenceClass"]
        source_constraint = evidence["sourceConstraint"]
        if surface not in affected_surfaces:
            raise CorpusError(f"{label} references a surface outside the incident")
        if evidence_class not in EVIDENCE_CLASSES:
            raise CorpusError(f"{label} has an unknown evidence class")
        if evidence_class not in capabilities[surface]:
            raise CorpusError(f"{label} requests an unsupported capability combination")
        if source_constraint not in SOURCE_CONSTRAINTS:
            raise CorpusError(f"{label} has an unknown source constraint")
        if source_constraint not in _allowed_source_constraints(evidence_class):
            raise CorpusError(f"{label} has an unsupported evidence/provenance combination")
        normalized.append(
            {
                "evidenceClass": evidence_class,
                "sourceConstraint": source_constraint,
                "surface": surface,
            }
        )
    rendered = [canonical_json(item) for item in normalized]
    if len(rendered) != len(set(rendered)):
        raise CorpusError(f"{label} contains duplicates")
    return sorted(normalized, key=canonical_json)


def evaluate_candidate_policy(candidate_policy: dict[str, Any], change: dict[str, Any]) -> dict[str, Any]:
    added_content = "\n".join(
        line
        for path in candidate_policy["pathMatchers"]
        for line in change["addedLinesByPath"].get(path, [])
    )
    paths_match = all(path in change["paths"] for path in candidate_policy["pathMatchers"])
    content_matches = all(
        re.search(pattern, added_content, re.MULTILINE) is not None
        for pattern in candidate_policy["diffContentMatchers"]
    )
    matches = paths_match and content_matches
    return {
        "expectedEvidence": candidate_policy["evidenceOracle"] if matches else [],
        "matches": matches,
        "rejectionStage": None if matches else ("path-match" if not paths_match else "content-match"),
    }


def _validate_candidate_policy(
    value: Any,
    affected_surfaces: list[str],
    surface_policy: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CorpusError(f"{label} must be an object")
    _exact_keys(value, {"diffContentMatchers", "evidenceOracle", "inputBoundaries", "pathMatchers"}, label)
    input_boundaries = sorted(_unique_tokens(value["inputBoundaries"], f"{label}.inputBoundaries"))
    if not set(input_boundaries).issubset(surface_policy["changeKinds"]):
        raise CorpusError(f"{label}.inputBoundaries contains unsupported change kinds")
    if not isinstance(value["pathMatchers"], list):
        raise CorpusError(f"{label}.pathMatchers must be a list")
    path_matchers = sorted(_relative_path(path, f"{label}.pathMatchers entry") for path in value["pathMatchers"])
    if not path_matchers or len(path_matchers) != len(set(path_matchers)):
        raise CorpusError(f"{label}.pathMatchers must be a non-empty unique list")
    if not isinstance(value["diffContentMatchers"], list) or not value["diffContentMatchers"]:
        raise CorpusError(f"{label}.diffContentMatchers must be a non-empty list")
    diff_content_matchers: list[str] = []
    for pattern in value["diffContentMatchers"]:
        if not isinstance(pattern, str) or not pattern:
            raise CorpusError(f"{label}.diffContentMatchers entry is invalid")
        try:
            compiled_pattern = re.compile(pattern, re.MULTILINE)
        except re.error as error:
            raise CorpusError(f"{label}.diffContentMatchers entry is invalid") from error
        if any(
            compiled_pattern.search(header) is not None
            for header in ("+++ b/public/path.swift", "+++ /dev/null")
        ):
            raise CorpusError(f"{label}.diffContentMatchers must not match diff headers")
        diff_content_matchers.append(pattern)
        if not pattern.startswith(r"^\+"):
            raise CorpusError(f"{label}.diffContentMatchers must match added lines")
        if pattern.startswith(r"^\+\+\+"):
            raise CorpusError(f"{label}.diffContentMatchers must not match diff headers")
    if len(diff_content_matchers) != len(set(diff_content_matchers)):
        raise CorpusError(f"{label}.diffContentMatchers contains duplicates")
    evidence_oracle = _validate_evidence_oracle(
        value["evidenceOracle"],
        affected_surfaces,
        surface_policy["capabilities"],
        f"{label}.evidenceOracle",
    )
    unavailable = {
        f"{surface}:{evidence_class}"
        for change_kind in input_boundaries
        for surface in affected_surfaces
        for evidence_class in surface_policy["changeRequirements"][change_kind]
        if evidence_class not in surface_policy["capabilities"][surface]
    }
    if unavailable:
        raise CorpusError(f"{label} policy evidence is unavailable on affected surfaces")
    required_evidence = {
        (surface, evidence_class)
        for change_kind in input_boundaries
        for surface in affected_surfaces
        for evidence_class in surface_policy["changeRequirements"][change_kind]
    }
    actual_evidence = {
        (evidence["surface"], evidence["evidenceClass"])
        for evidence in evidence_oracle
    }
    if not required_evidence.issubset(actual_evidence):
        raise CorpusError(f"{label}.evidenceOracle omits required policy evidence")
    return {
        "evidenceOracle": evidence_oracle,
        "diffContentMatchers": sorted(diff_content_matchers),
        "inputBoundaries": input_boundaries,
        "pathMatchers": path_matchers,
    }


def _validate_near_miss(
    value: Any,
    affected_surfaces: list[str],
    surface_policy: dict[str, Any],
    curated_through_commit: str,
    label: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CorpusError(f"{label} must be an object")
    _exact_keys(value, {"commit", "id", "inputBoundaries", "rationale", "surfaces"}, label)
    near_miss_id = _token(value["id"], f"{label}.id")
    surfaces = _require_known_surfaces(value["surfaces"], surface_policy["capabilities"], f"{label}.surfaces")
    if not set(surfaces).issubset(affected_surfaces):
        raise CorpusError(f"{label} must stay within its positive surfaces")
    input_boundaries = sorted(_unique_tokens(value["inputBoundaries"], f"{label}.inputBoundaries"))
    if not set(input_boundaries).issubset(surface_policy["changeKinds"]):
        raise CorpusError(f"{label}.inputBoundaries contains unsupported change kinds")
    rationale = value["rationale"]
    if not isinstance(rationale, str) or not rationale.strip():
        raise CorpusError(f"{label}.rationale is invalid")
    expected_evidence = sorted(
        [
            {
                "evidenceClass": evidence_class,
                "sourceConstraint": _default_source_constraint(evidence_class),
                "surface": surface,
            }
            for change_kind in input_boundaries
            for surface in surfaces
            for evidence_class in surface_policy["changeRequirements"][change_kind]
            if evidence_class in surface_policy["capabilities"][surface]
        ],
        key=canonical_json,
    )
    if not expected_evidence:
        raise CorpusError(f"{label} has no supported baseline evidence")
    commit = value["commit"]
    if not isinstance(commit, str) or SHA_PATTERN.fullmatch(commit) is None:
        raise CorpusError(f"{label}.commit must be a full SHA")
    if not _git_succeeds(["merge-base", "--is-ancestor", commit, curated_through_commit]):
        raise CorpusError(f"{label}.commit is outside curated history")
    if len(_git_output(["show", "--no-show-signature", "-s", "--format=%P", commit]).split()) != 1:
        raise CorpusError(f"{label}.commit must be a single-parent commit")
    return {
        "change": _commit_change(commit, attr_source=curated_through_commit),
        "commit": commit,
        "expectedEvidence": expected_evidence,
        "id": near_miss_id,
        "inputBoundaries": input_boundaries,
        "rationale": rationale.strip(),
        "surfaces": surfaces,
    }


def _validate_incident(
    value: Any,
    surface_policy: dict[str, Any],
    curated_through_commit: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CorpusError("incident must be an object")
    _exact_keys(
        value,
        {
            "affectedSurfaces",
            "candidatePolicy",
            "causalConfidence",
            "citations",
            "id",
            "negativeNearMiss",
            "observation",
        },
        "incident",
    )
    incident_id = _token(value["id"], "incident.id")
    observation = value["observation"]
    if not isinstance(observation, str) or not observation.strip():
        raise CorpusError("incident.observation is invalid")
    if value["causalConfidence"] != POSITIVE_CAUSAL_CONFIDENCE:
        raise CorpusError("incident.causalConfidence must be confirmed by public record")
    affected_surfaces = _require_known_surfaces(
        value["affectedSurfaces"], surface_policy["capabilities"], "incident.affectedSurfaces"
    )
    candidate_policy = _validate_candidate_policy(
        value["candidatePolicy"], affected_surfaces, surface_policy, "incident.candidatePolicy"
    )
    citations = _validate_citations(
        value["citations"],
        "incident.citations",
        incident=True,
        curated_through_commit=curated_through_commit,
    )
    positive_change = _combine_citation_changes(
        citations,
        attr_source=curated_through_commit,
    )
    positive_decision = evaluate_candidate_policy(candidate_policy, positive_change)
    if not positive_decision["matches"] or positive_decision["expectedEvidence"] != candidate_policy["evidenceOracle"]:
        raise CorpusError("incident cited implementation diffs do not match its candidate policy")
    near_miss = _validate_near_miss(
        value["negativeNearMiss"],
        affected_surfaces,
        surface_policy,
        curated_through_commit,
        "incident.negativeNearMiss",
    )
    if near_miss["id"] == incident_id:
        raise CorpusError("incident negative near-miss ID duplicates its positive ID")
    if near_miss["commit"] in {citation["implementationCommit"] for citation in citations}:
        raise CorpusError("incident positive and negative near-miss commits must differ")
    negative_decision = evaluate_candidate_policy(candidate_policy, near_miss["change"])
    if not any(path in near_miss["change"]["paths"] for path in candidate_policy["pathMatchers"]):
        raise CorpusError("incident negative near-miss must overlap a candidate path")
    if negative_decision["matches"] or negative_decision["expectedEvidence"]:
        raise CorpusError("incident negative near-miss matches its candidate policy")
    positive_physical_burden = sum(
        evidence["sourceConstraint"] != "deterministic-gallery"
        for evidence in candidate_policy["evidenceOracle"]
    )
    negative_physical_burden = sum(
        evidence["sourceConstraint"] != "deterministic-gallery"
        for evidence in near_miss["expectedEvidence"]
    )
    if negative_physical_burden >= positive_physical_burden:
        raise CorpusError("incident negative near-miss does not reduce physical evidence burden")
    return {
        "affectedSurfaces": affected_surfaces,
        "candidatePolicy": candidate_policy,
        "causalConfidence": POSITIVE_CAUSAL_CONFIDENCE,
        "citations": citations,
        "id": incident_id,
        "negativeNearMiss": near_miss,
        "observation": observation.strip(),
        "positive": {"change": positive_change},
    }


def _validate_residual_risk(
    value: Any,
    capabilities: dict[str, set[str]],
    curated_through_commit: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CorpusError("residual risk must be an object")
    _exact_keys(
        value,
        {"affectedSurfaces", "citations", "consequence", "evidenceGap", "id", "mitigation", "riskClass"},
        "residual risk",
    )
    risk_class = value["riskClass"]
    if risk_class not in RESIDUAL_RISK_CLASSES:
        raise CorpusError("residual risk has an unknown risk class")
    fields = {name: value[name] for name in {"consequence", "evidenceGap", "mitigation"}}
    if any(not isinstance(field, str) or not field.strip() for field in fields.values()):
        raise CorpusError("residual risk has an invalid description")
    return {
        "affectedSurfaces": _require_known_surfaces(
            value["affectedSurfaces"], capabilities, "residual risk.affectedSurfaces"
        ),
        "citations": _validate_citations(
            value["citations"],
            "residual risk.citations",
            incident=False,
            curated_through_commit=curated_through_commit,
        ),
        "consequence": fields["consequence"].strip(),
        "evidenceGap": fields["evidenceGap"].strip(),
        "id": _token(value["id"], "residual risk.id"),
        "mitigation": fields["mitigation"].strip(),
        "riskClass": risk_class,
    }


def normalize_corpus(source: dict[str, Any], surface_policy_path: Path) -> dict[str, Any]:
    _public_safe(source)
    _exact_keys(
        source,
        {
            "corpusVersion",
            "curatedThroughCommit",
            "gitVersion",
            "incidents",
            "residualRisks",
            "schemaVersion",
        },
        "corpus",
    )
    if source["schemaVersion"] != SUPPORTED_SCHEMA_VERSION:
        raise CorpusError("corpus schema version is unsupported")
    corpus_version = source["corpusVersion"]
    if not isinstance(corpus_version, int) or isinstance(corpus_version, bool) or corpus_version < 1:
        raise CorpusError("corpus version must be a positive integer")
    curated_through_commit = source["curatedThroughCommit"]
    if not isinstance(curated_through_commit, str) or SHA_PATTERN.fullmatch(curated_through_commit) is None:
        raise CorpusError("curated through commit must be a full SHA")
    _git_output(["cat-file", "-e", f"{curated_through_commit}^{{commit}}"])
    info_attributes_path = Path(
        _git_output(["rev-parse", "--git-path", "info/attributes"]).strip()
    )
    if not info_attributes_path.is_absolute():
        info_attributes_path = REPO_ROOT / info_attributes_path
    if info_attributes_path.is_file() and info_attributes_path.read_text().strip():
        raise CorpusError("repository-local Git attributes must be empty")
    grafts_path = Path(_git_output(["rev-parse", "--git-path", "info/grafts"]).strip())
    if not grafts_path.is_absolute():
        grafts_path = REPO_ROOT / grafts_path
    if grafts_path.is_file() and grafts_path.read_text().strip():
        raise CorpusError("repository-local Git grafts must be empty")
    git_version = source["gitVersion"]
    actual_git_version = _git_output(["--version"])
    match = GIT_VERSION_PATTERN.fullmatch(actual_git_version)
    if not isinstance(git_version, str) or match is None or match.group(1) != git_version:
        actual = match.group(1) if match is not None else actual_git_version.strip()
        raise CorpusError(
            f"installed Git version {actual} does not match corpus-required version {git_version}"
        )
    surface_policy, policy_digest = _load_surface_policy(
        surface_policy_path,
        revision=curated_through_commit,
    )
    incidents = source["incidents"]
    if not isinstance(incidents, list) or not incidents:
        raise CorpusError("corpus incidents must be a non-empty list")
    normalized_incidents = [
        _validate_incident(incident, surface_policy, curated_through_commit) for incident in incidents
    ]
    incident_ids = [incident["id"] for incident in normalized_incidents]
    near_miss_ids = [incident["negativeNearMiss"]["id"] for incident in normalized_incidents]
    near_miss_commits = [
        incident["negativeNearMiss"]["commit"] for incident in normalized_incidents
    ]
    if len(incident_ids) != len(set(incident_ids)) or len(near_miss_ids) != len(set(near_miss_ids)):
        raise CorpusError("corpus contains duplicate case IDs")
    if len(near_miss_commits) != len(set(near_miss_commits)):
        raise CorpusError("corpus contains duplicate negative near-miss commits")
    if set(incident_ids) & set(near_miss_ids):
        raise CorpusError("corpus positive and negative IDs overlap")
    residual_risks = source["residualRisks"]
    if not isinstance(residual_risks, list) or not residual_risks:
        raise CorpusError("corpus residual risks must be a non-empty list")
    normalized_risks = [
        _validate_residual_risk(risk, surface_policy["capabilities"], curated_through_commit)
        for risk in residual_risks
    ]
    risk_ids = [risk["id"] for risk in normalized_risks]
    if len(risk_ids) != len(set(risk_ids)) or set(risk_ids) & (set(incident_ids) | set(near_miss_ids)):
        raise CorpusError("corpus contains duplicate IDs")
    return {
        "schemaVersion": SUPPORTED_SCHEMA_VERSION,
        "corpusVersion": corpus_version,
        "curatedThroughCommit": curated_through_commit,
        "gitVersion": git_version,
        "incidents": sorted(normalized_incidents, key=lambda incident: incident["id"]),
        "residualRisks": sorted(normalized_risks, key=lambda risk: risk["id"]),
        "surfacePolicyDigest": policy_digest,
    }


def compile_corpus(source_path: Path, surface_policy_path: Path) -> dict[str, Any]:
    source = load_json(source_path, "physical defect corpus")
    normalized = normalize_corpus(source, surface_policy_path)
    cases: list[dict[str, Any]] = []
    for incident in normalized["incidents"]:
        positive_decision = evaluate_candidate_policy(incident["candidatePolicy"], incident["positive"]["change"])
        negative_decision = evaluate_candidate_policy(
            incident["candidatePolicy"], incident["negativeNearMiss"]["change"]
        )
        cases.append(
            {
                "candidateMatched": positive_decision["matches"],
                "caseKind": "positive",
                "change": _compiled_change(incident["positive"]["change"]),
                "citations": incident["citations"],
                "expectedEvidence": positive_decision["expectedEvidence"],
                "id": incident["id"],
                "observation": incident["observation"],
                "surfaces": incident["affectedSurfaces"],
            }
        )
        cases.append(
            {
                "candidateMatched": negative_decision["matches"],
                "caseKind": "negative-near-miss",
                "change": _compiled_change(incident["negativeNearMiss"]["change"]),
                "expectedEvidence": incident["negativeNearMiss"]["expectedEvidence"],
                "id": incident["negativeNearMiss"]["id"],
                "inputBoundaries": incident["negativeNearMiss"]["inputBoundaries"],
                "positiveID": incident["id"],
                "rationale": incident["negativeNearMiss"]["rationale"],
                "rejectionStage": negative_decision["rejectionStage"],
                "surfaces": incident["negativeNearMiss"]["surfaces"],
            }
        )
    cases.sort(key=lambda case: case["id"])
    payload = {
        "cases": cases,
        "corpusDigest": canonical_digest(
            {
                "corpusVersion": normalized["corpusVersion"],
                "curatedThroughCommit": normalized["curatedThroughCommit"],
                "gitVersion": normalized["gitVersion"],
                "incidents": normalized["incidents"],
                "residualRisks": normalized["residualRisks"],
                "schemaVersion": normalized["schemaVersion"],
            }
        ),
        "corpusVersion": normalized["corpusVersion"],
        "curatedThroughCommit": normalized["curatedThroughCommit"],
        "gitVersion": normalized["gitVersion"],
        "residualRisks": normalized["residualRisks"],
        "schemaVersion": SUPPORTED_SCHEMA_VERSION,
        "summary": {
            "caseCount": len(cases),
            "negativeNearMissCount": len([case for case in cases if case["caseKind"] == "negative-near-miss"]),
            "positiveCount": len([case for case in cases if case["caseKind"] == "positive"]),
            "residualRiskCount": len(normalized["residualRisks"]),
        },
        "surfacePolicyDigest": normalized["surfacePolicyDigest"],
    }
    _public_safe(payload, "compiled physical defect corpus")
    return payload


def write_compiled(payload: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(render_json(payload))


def check_compiled(source_path: Path, surface_policy_path: Path, compiled_path: Path) -> dict[str, Any]:
    payload = compile_corpus(source_path, surface_policy_path)
    if not compiled_path.is_file() or compiled_path.is_symlink():
        raise CorpusError("compiled physical defect corpus is unavailable")
    try:
        committed = compiled_path.read_bytes()
    except OSError as error:
        raise CorpusError("compiled physical defect corpus is unavailable") from error
    if committed != render_json(payload):
        raise CorpusError("compiled physical defect corpus is stale")
    return payload
