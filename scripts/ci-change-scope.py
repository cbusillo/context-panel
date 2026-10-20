#!/usr/bin/env python3
"""Decide which CI jobs a change needs, from the base it lands on.

The base depends on the event:

- pull request: the pull request's base commit;
- push to the default branch: the previous tip (`github.event.before`);
- push to a merge-train candidate branch: the default branch, so the diff is
  the candidate's batch;
- anything else, or a missing or all-zero base: run everything.

The simulator reference job takes about an hour, so it stays off the pull
request and merge-train path: it runs on pushes to the default branch and on
manual runs, which are also the only runs App Store submission accepts
(scripts/shared_view_reference_gate.py).

The decision fails open: an unknown path, an empty diff, or a Git error runs
everything. CodeQL is deliberately not gated here. The ruleset on main requires
CodeQL results for every pull request, so a skipped analysis would block the
merge.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
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
# Read only by scripts/context-panel-test-lanes.py, whose validation and Python
# lanes always run. Every new Python test edits it.
PRODUCT_IRRELEVANT_PATHS = ("Config/ContextPanelTestLanes.json",)
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

# Inputs of the shared-view reference image jobs beyond the product build: the
# references, the pins, the capture scripts and everything they import (a test
# checks this list against their real import closure).
REFERENCE_INPUTS = (
    "Config/ContextPanelSharedViewSimulators.json",
    "Tests/SharedViewReferences/",
    "scripts/context-panel-shared-view-capture-workflow.py",
    "scripts/context-panel-shared-view-references.py",
    "scripts/context_panel_shared_view_references.py",
    "scripts/context_panel_validation/",
)
TRAIN_BRANCH_PREFIX = "launchplane/train/"
ZERO_SHA = "0" * 40


@dataclass(frozen=True)
class Scope:
    product: bool
    reason: str
    references: bool
    # A pull request or merge-train candidate, which the simulator reference
    # job stays off.
    merge_path: bool = False

    @property
    def simulator_references(self) -> bool:
        return self.references and not self.merge_path


def _matches(path: str, entries: tuple[str, ...]) -> bool:
    return any(path == entry or (entry.endswith("/") and path.startswith(entry)) for entry in entries)


def _is_product_relevant_python(path: str) -> bool:
    return _matches(path, PRODUCT_RELEVANT_PYTHON)


def is_product_irrelevant(path: str) -> bool:
    if path in PRODUCT_IRRELEVANT_PATHS:
        return True
    if path.startswith(BUILD_INPUT_PREFIXES):
        return False
    if path.startswith(PRODUCT_IRRELEVANT_PREFIXES):
        return True
    if path.endswith(PRODUCT_IRRELEVANT_SUFFIXES):
        return True
    if path.startswith("scripts/") and PurePosixPath(path).suffix == ".py":
        return not _is_product_relevant_python(path)
    return False


def classify(paths: list[str] | None) -> Scope:
    """Classify changed paths; `None` or an empty list means "unknown"."""
    if not paths:
        return Scope(True, "changed paths are unknown", references=True)

    product_path = next((p for p in paths if not is_product_irrelevant(p)), None)
    if product_path is not None:
        return Scope(True, f"{product_path} can affect the product build", references=True)
    reference_path = next((p for p in paths if _matches(p, REFERENCE_INPUTS)), None)
    if reference_path is not None:
        return Scope(False, f"{reference_path} is a reference image job input", references=True)
    return Scope(False, "every changed path is documentation or validation tooling", references=False)


def select_base(event: str, ref: str, *, pr_base: str, before: str, default_branch: str) -> str | None:
    """The commit or ref the change lands on, or `None` to run everything."""
    if event == "pull_request":
        base = pr_base
    elif event == "push" and ref == f"refs/heads/{default_branch}":
        base = before
    elif event == "push" and ref.startswith(f"refs/heads/{TRAIN_BRANCH_PREFIX}"):
        base = f"origin/{default_branch}"
    else:
        return None
    base = base.strip()
    if not base or base == ZERO_SHA:
        return None
    return base


def decide(
    event: str,
    ref: str,
    *,
    pr_base: str,
    before: str,
    default_branch: str,
    head: str = "HEAD",
    cwd: Path | None = None,
) -> Scope:
    merge_path = event == "pull_request" or (
        event == "push" and ref.startswith(f"refs/heads/{TRAIN_BRANCH_PREFIX}")
    )
    base = select_base(event, ref, pr_base=pr_base, before=before, default_branch=default_branch)
    if base is None:
        reason = f"no base to compare for {event} on {ref or 'an unknown ref'}"
        return Scope(True, reason, references=True, merge_path=merge_path)
    return replace(classify(changed_paths(base, head, cwd=cwd)), merge_path=merge_path)


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
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", required=True, help="github.event_name")
    parser.add_argument("--ref", default="", help="github.ref")
    parser.add_argument("--pr-base", default="", help="pull request base commit")
    parser.add_argument("--before", default="", help="previous tip of a pushed branch")
    parser.add_argument("--default-branch", default="main")
    parser.add_argument("--head", default="HEAD", help="head commit (default: HEAD)")
    args = parser.parse_args(argv)

    scope = decide(
        args.event,
        args.ref,
        pr_base=args.pr_base,
        before=args.before,
        default_branch=args.default_branch,
        head=args.head,
    )
    lines = [
        f"product={'true' if scope.product else 'false'}",
        f"references={'true' if scope.references else 'false'}",
        f"simulator_references={'true' if scope.simulator_references else 'false'}",
    ]
    print(f"change scope: {', '.join(lines)} ({scope.reason})")

    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
