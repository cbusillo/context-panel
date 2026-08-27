from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from .inventory import (
    InventoryError,
    check_inventory,
    parse_root_bindings,
    seal_inventory,
    verify_inventory,
    write_inventory,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_POLICY = REPO_ROOT / "Config/ContextPanelReplayInventoryPolicy.json"
DEFAULT_INVENTORY = Path(__file__).resolve().parent / "inventory/signed-trains.json"


def _add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--json", action="store_true")


def _add_roots(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--root",
        action="append",
        default=[],
        metavar="ROOT_ID=ABSOLUTE_PATH",
        help="Bind one symbolic policy root to an explicit private absolute path.",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Seal public-safe signed-train replay input inventory.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    seal = subparsers.add_parser("seal", help="Derive and write the inventory from retained roots.")
    _add_common(seal)
    _add_roots(seal)
    verify = subparsers.add_parser("verify", help="Require retained roots to reproduce the committed inventory.")
    _add_common(verify)
    _add_roots(verify)
    check = subparsers.add_parser("check", help="Validate the committed inventory offline.")
    _add_common(check)
    return parser


def _summary(payload: dict[str, object]) -> dict[str, object]:
    return {
        "state": payload.get("state"),
        "inventoryId": payload.get("inventoryId"),
        "summary": payload.get("summary"),
    }


def run(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    if arguments.command == "seal":
        payload = seal_inventory(arguments.policy, parse_root_bindings(arguments.root))
        write_inventory(payload, arguments.inventory)
    elif arguments.command == "verify":
        payload = verify_inventory(
            arguments.policy,
            arguments.inventory,
            parse_root_bindings(arguments.root),
        )
    else:
        payload = check_inventory(arguments.policy, arguments.inventory)
    result = _summary(payload)
    if arguments.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        summary = result.get("summary") or {}
        print(
            "replay inventory OK: "
            f"{summary.get('trainCount', 0)} trains, "
            f"{summary.get('inputCount', 0)} inputs, "
            f"{summary.get('residualRiskCount', 0)} residual risks"
        )
    return 0


def main() -> int:
    try:
        return run()
    except InventoryError as error:
        print(f"error: {error}", file=sys.stderr)
        return 20
