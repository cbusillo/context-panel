#!/usr/bin/env python3
"""Decide which expensive CI work a pull request's changed paths require.

Both decisions fail open: an unknown path, an empty diff, or a Git error runs
everything. Pushes to main, schedules, and manual runs never consult this
script, so every commit on main is still built, tested, and analysed in full.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys

# Paths that cannot change the SwiftPM build, the Swift tests, or the companion
# Xcode builds. Anything not listed here is treated as product-affecting.
PRODUCT_IRRELEVANT_PREFIXES = (
    "docs/",
    "Tests/ScriptsTests/",
)
PRODUCT_IRRELEVANT_SUFFIXES = (".md",)
# Markdown inside a build input directory could be a bundled resource.
BUILD_INPUT_PREFIXES = ("Config/", "Sources/", "Tools/")

# Python tooling is product-irrelevant except for the pieces the build or this
# gate executes: the Xcode stamp phase runs the surface manifest and everything
# it imports, the commit gate times `swift test` through the lane runner, and
# this script decides what runs at all. A test checks this list against the
# surface manifest's real import closure.
PRODUCT_RELEVANT_PYTHON = (
    "scripts/ci-change-scope.py",
    "scripts/context-panel-surface-manifest.py",
    "scripts/context-panel-test-lanes.py",
    "scripts/context_panel_comparison_schema.py",
    "scripts/context_panel_expected_build.py",
    "scripts/context_panel_surface_manifest/",
)

# CodeQL extracts the Swift it sees compiled by `swift build`, so only Swift
# sources, the package definition, and the analysis configuration matter.
CODEQL_RELEVANT_PREFIXES = (
    ".github/codeql/",
    "Sources/",
    "Tools/",
)
CODEQL_RELEVANT_PATHS = (
    ".github/workflows/codeql.yml",
    "Package.resolved",
    "Package.swift",
    "scripts/ci-change-scope.py",
)
CODEQL_RELEVANT_SUFFIXES = (".swift",)


@dataclass(frozen=True)
class Scope:
    product: bool
    codeql: bool
    product_reason: str
    codeql_reason: str


def _is_product_relevant_python(path: str) -> bool:
    return any(
        path == entry or (entry.endswith("/") and path.startswith(entry))
        for entry in PRODUCT_RELEVANT_PYTHON
    )


def is_product_irrelevant(path: str) -> bool:
    if path.startswith(BUILD_INPUT_PREFIXES):
        return False
    if path.startswith(PRODUCT_IRRELEVANT_PREFIXES):
        return True
    if path.endswith(PRODUCT_IRRELEVANT_SUFFIXES):
        return True
    if path.startswith("scripts/") and PurePosixPath(path).suffix == ".py":
        return not _is_product_relevant_python(path)
    return False


def is_codeql_relevant(path: str) -> bool:
    return (
        path in CODEQL_RELEVANT_PATHS
        or path.startswith(CODEQL_RELEVANT_PREFIXES)
        or path.endswith(CODEQL_RELEVANT_SUFFIXES)
    )


def classify(paths: list[str] | None) -> Scope:
    """Classify changed paths; `None` or an empty list means "unknown"."""
    if not paths:
        reason = "changed paths are unknown"
        return Scope(True, True, reason, reason)

    product_path = next((p for p in paths if not is_product_irrelevant(p)), None)
    codeql_path = next((p for p in paths if is_codeql_relevant(p)), None)
    return Scope(
        product=product_path is not None,
        codeql=codeql_path is not None,
        product_reason=(
            f"{product_path} can affect the product build"
            if product_path is not None
            else "every changed path is documentation or validation tooling"
        ),
        codeql_reason=(
            f"{codeql_path} can affect the Swift analysis"
            if codeql_path is not None
            else "no changed path is compiled Swift or analysis configuration"
        ),
    )


def changed_paths(base: str, head: str, *, cwd: Path | None = None) -> list[str] | None:
    """Paths changed between the merge base of `base` and `head`, and `head`."""
    try:
        completed = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "-z", f"{base}...{head}"],
            check=True,
            capture_output=True,
            cwd=cwd,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"ci-change-scope: git diff failed, running everything: {error}", file=sys.stderr)
        return None
    return [entry.decode("utf-8", "surrogateescape") for entry in completed.stdout.split(b"\0") if entry]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="base commit of the pull request")
    parser.add_argument("--head", default="HEAD", help="head commit (default: HEAD)")
    args = parser.parse_args(argv)

    scope = classify(changed_paths(args.base, args.head))
    lines = [
        f"product={'true' if scope.product else 'false'}",
        f"codeql={'true' if scope.codeql else 'false'}",
    ]
    print(f"product build and Swift tests: {'run' if scope.product else 'skip'} ({scope.product_reason})")
    print(f"CodeQL Swift analysis: {'run' if scope.codeql else 'skip'} ({scope.codeql_reason})")

    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
