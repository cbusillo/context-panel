#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from context_panel_replay.corpus import CorpusError, check_compiled, compile_corpus, write_compiled


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPUS = REPO_ROOT / "Config/ContextPanelPhysicalDefectCorpus.json"
DEFAULT_SURFACE_POLICY = REPO_ROOT / "Config/ContextPanelSurfacePolicy.json"
DEFAULT_COMPILED = REPO_ROOT / "scripts/context_panel_replay/corpus/compiled.json"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Compile the public-safe physical device defect corpus.")
    parser.add_argument("command", choices=("generate", "check"))
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--surface-policy", type=Path, default=DEFAULT_SURFACE_POLICY)
    parser.add_argument("--compiled", type=Path, default=DEFAULT_COMPILED)
    parser.add_argument("--json", action="store_true")
    return parser


def _summary(payload: dict[str, object]) -> dict[str, object]:
    return {
        "corpusDigest": payload["corpusDigest"],
        "corpusVersion": payload["corpusVersion"],
        "state": "OK",
        "summary": payload["summary"],
    }


def run(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    if arguments.command == "generate":
        payload = compile_corpus(arguments.corpus, arguments.surface_policy)
        write_compiled(payload, arguments.compiled)
    else:
        payload = check_compiled(arguments.corpus, arguments.surface_policy, arguments.compiled)
    summary = _summary(payload)
    if arguments.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        counts = payload["summary"]
        print(
            "physical defect corpus OK: "
            f"{counts['positiveCount']} positives, "
            f"{counts['negativeNearMissCount']} negative near-misses, "
            f"{counts['residualRiskCount']} residual risks"
        )
    return 0


def main() -> int:
    try:
        return run()
    except CorpusError as error:
        print(f"error: {error}", file=sys.stderr)
        return 20


if __name__ == "__main__":
    raise SystemExit(main())
