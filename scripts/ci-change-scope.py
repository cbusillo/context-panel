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
(scripts/app_store_submission_gate.py). One exception: a pull request that
changes a committed reference image changes how a cell looks, so it also runs
the simulator job and must re-record every surface before it merges. Its body
must also carry a `## Reference images` section: the old and new images and the
author's statement of what the screen should show and that the new image does.

The decision fails open: an unknown path, an empty diff, or a Git error runs
everything. CodeQL is deliberately not gated here. The ruleset on main requires
CodeQL results for every pull request, so a skipped analysis would block the
merge.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import urllib.request

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

PRODUCT_RELEVANT_PYTHON = (
    "scripts/ci-change-scope.py",
    "scripts/context-panel-surface-manifest.py",
    "scripts/context-panel-test-lanes.py",
    "scripts/context_panel_expected_build.py",
    "scripts/context_panel_surface_manifest/",
)

# Inputs of the shared-view reference image jobs beyond the product build: the
# references, the pins, the capture scripts and everything they import (a test
# checks this list against their real import closure).
REFERENCE_INPUTS = (
    "Config/ContextPanelSharedViewSimulators.json",
    "Tests/SharedViewReferences/",
    "scripts/context-panel-shared-view-references.py",
    "scripts/context_panel_shared_view_capture.py",
    "scripts/context_panel_shared_view_matrix.py",
    "scripts/context_panel_shared_view_references.py",
)
REFERENCE_IMAGES_PREFIX = "Tests/SharedViewReferences/"
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
    # A pull request that changes a committed reference image, which runs the
    # simulator reference job anyway.
    reference_images: bool = False

    @property
    def simulator_references(self) -> bool:
        return self.references and (not self.merge_path or self.reference_images)


def _is_reference_image(path: str) -> bool:
    return path.startswith(REFERENCE_IMAGES_PREFIX) and PurePosixPath(path).suffix == ".png"


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

    reference_images = any(_is_reference_image(p) for p in paths)
    product_path = next((p for p in paths if not is_product_irrelevant(p)), None)
    if product_path is not None:
        reason = f"{product_path} can affect the product build"
        return Scope(True, reason, references=True, reference_images=reference_images)
    reference_path = next((p for p in paths if _matches(p, REFERENCE_INPUTS)), None)
    if reference_path is not None:
        reason = f"{reference_path} is a reference image job input"
        return Scope(False, reason, references=True, reference_images=reference_images)
    return Scope(False, "every changed path is documentation or validation tooling", references=False)


REFERENCE_STATEMENT_HEADING = re.compile(r"^##\s+Reference images\s*$", re.IGNORECASE | re.MULTILINE)
IMAGE = re.compile(r"!\[[^]]*]\([^)\s]+\)|<img\s[^>]*>", re.IGNORECASE)


def reference_statement_problem(body: str | None) -> str | None:
    """Why a pull request body that changes a reference image is not enough, or `None`.

    The `## Reference images` section must show at least the old and the new image
    and say, in the author's words, what the screen should show and that it does.
    """
    match = REFERENCE_STATEMENT_HEADING.search(body or "")
    if match is None:
        return "the pull request body has no '## Reference images' section"
    section = re.split(r"^#{1,2}\s", (body or "")[match.end():], maxsplit=1, flags=re.MULTILINE)[0]
    if len(IMAGE.findall(section)) < 2:
        return "the '## Reference images' section must show the old and the new image"
    statement = IMAGE.sub("", section)
    if len(re.findall(r"[A-Za-z]{2,}", statement)) < 8:
        return "the '## Reference images' section must say what the screen should show and that the new image does"
    return None


def pull_request_body(repository: str, number: str) -> str:
    """The current body, so editing it and re-running the job is enough."""
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/pulls/{number}",
        headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"},
    )
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response).get("body") or ""


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
    scope = classify(changed_paths(base, head, cwd=cwd))
    # The pull request already ran the simulator job, so a train candidate
    # carrying its reference images does not run it again.
    return replace(
        scope,
        merge_path=merge_path,
        reference_images=scope.reference_images and event == "pull_request",
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
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", required=True, help="github.event_name")
    parser.add_argument("--ref", default="", help="github.ref")
    parser.add_argument("--pr-base", default="", help="pull request base commit")
    parser.add_argument("--before", default="", help="previous tip of a pushed branch")
    parser.add_argument("--default-branch", default="main")
    parser.add_argument("--head", default="HEAD", help="head commit (default: HEAD)")
    parser.add_argument("--pr-number", default="", help="pull request number, to check its reference image statement")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
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
    if scope.reference_images and args.event == "pull_request" and args.pr_number:
        problem = reference_statement_problem(pull_request_body(args.repository, args.pr_number))
        if problem is not None:
            print(
                f"::error::This pull request changes a reference image, so {problem}. "
                "See docs/validation-authority.md#reference-images, edit the body, then re-run this job.",
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
