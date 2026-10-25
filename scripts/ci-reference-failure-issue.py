#!/usr/bin/env python3
"""Open, update or close the plan issue for a simulator reference run on main.

Nothing waits for the simulator reference job, so on main this issue is the
only signal: a failed run opens it, or comments on the open one, naming the
changed cells, and the next passing run closes it. The workflow passes the job
status; `gh` reads GH_TOKEN and GH_REPO from the environment.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable, Sequence
import json
from pathlib import Path
import subprocess

TITLE = "Simulator reference images fail on main"
NO_COMPARISON = "- No comparison ran: the build or capture failed. The run log names the failed step and cells."

RunGh = Callable[[Sequence[str]], str]


def run_gh(arguments: Sequence[str]) -> str:
    return subprocess.run(["gh", *arguments], check=True, capture_output=True, text=True).stdout


def changed_cells(report_path: Path) -> str:
    if not report_path.is_file():
        return NO_COMPARISON
    report = json.loads(report_path.read_text(encoding="utf-8"))
    lines = []
    for cell in report.get("cells", []):
        if cell.get("state") == "matched":
            continue
        line = f"- `{cell['surface']}/{cell['cell']}.png`: {cell['state']}"
        if cell.get("changedPixels"):
            line += f" ({cell['changedPixels']} pixels differ)"
        lines.append(line)
    return "\n".join(lines) or NO_COMPARISON


def issue_body(failure: str) -> str:
    return f"""## Why

{failure}

Nothing waits for this job, so this issue is the only signal. App Store submission refuses a commit without a passing run.

## Finish line

- The simulator reference job passes on main; that run closes this issue.

## Current Status

Next action: Next agent: download the run's `shared-view-simulator-rendered-*` artifact, then fix the cause or re-record the changed cells (docs/validation-authority.md#reference-images).

<!-- github-plan:wait {{"evidence": "Opened by CI for a failed reference run; no person or event hold.", "state": "clear", "version": 1, "waits": []}} -->
"""


def open_issue_number(gh: RunGh) -> str | None:
    issues = json.loads(gh(["issue", "list", "--state", "open", "--search", f'"{TITLE}" in:title', "--json", "number,title"]))
    return next((str(issue["number"]) for issue in issues if issue["title"] == TITLE), None)


def report(status: str, *, sha: str, run_url: str, report_path: Path, gh: RunGh = run_gh) -> str:
    """Apply the run's outcome to the issue and say what was done."""
    number = open_issue_number(gh)
    if status == "success":
        if number is None:
            return "passing; no open issue"
        gh(["issue", "close", number, "--comment", f"Passing again on {sha}: {run_url}"])
        return f"closed #{number}"
    failure = f"The simulator reference job failed on {sha}: {run_url}\n\n{changed_cells(report_path)}"
    if number is not None:
        gh(["issue", "comment", number, "--body", failure])
        return f"commented on #{number}"
    gh(["issue", "create", "--title", TITLE, "--label", "plan", "--label", "plan:active", "--body", issue_body(failure)])
    return "opened an issue"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--status", required=True, help="the job status, for example success or failure")
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--report", type=Path, required=True, help="the comparison's report.json")
    args = parser.parse_args(argv)
    print(report(args.status, sha=args.sha, run_url=args.run_url, report_path=args.report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
