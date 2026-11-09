#!/usr/bin/env python3
"""Render shared-view cells and compare them with their committed reference images.

  pinned-xcode      print the Xcode every simulator capture uses
  capture-config    select each profile's pinned simulator for fresh Release builds
  render-host       draw the macOS cells with the SwiftPM shared-view renderer
  render-simulator  capture the simulator cells from a capture config
  compare           compare rendered cells with Tests/SharedViewReferences; with
                    --update, copy changed or missing cells over their references

See docs/validation-authority.md#reference-images.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from context_panel_shared_view_references import (  # noqa: E402
    DEFAULT_MATRIX_PATH,
    DEFAULT_REFERENCE_ROOT,
    ReferenceImageError,
    compare,
    matrix_cells,
)
from context_panel_shared_view_capture import (  # noqa: E402
    CAPTURE_CONFIG_KIND,
    CAPTURE_CONFIG_SCHEMA_VERSION,
    COMPANION_UI_TEST_PROFILES,
    HOST_RENDERER_SCALE,
    SIMULATOR_CAPTURE_PROFILES,
    SimulatorPins,
    capture_reference_cells,
    load_simulator_pins,
)
from context_panel_shared_view_matrix import SharedViewEvidenceError  # noqa: E402

HOST_SURFACES = ("macos.app", "macos.widget")
MAX_CATALOG_BYTES = 2 * 1024 * 1024


def capture_config(
    catalog: dict[str, Any],
    bundles: dict[str, str],
    ios_ui_test_run: str,
    visionos_ui_test_run: str,
    pins: SimulatorPins | None = None,
) -> dict[str, Any]:
    """Select each profile's pinned simulator, failing when the runner lacks it.

    References are only valid for the pinned runtime and device, so a runner image
    without them stops here instead of capturing on another simulator.
    """
    pins = pins or load_simulator_pins()
    runtimes = catalog.get("runtimes")
    device_types = catalog.get("devicetypes")
    if not isinstance(runtimes, list) or not isinstance(device_types, list):
        raise ReferenceImageError("simulator catalog is invalid")
    output: dict[str, Any] = {}
    for name, profile in SIMULATOR_CAPTURE_PROFILES.items():
        bundle = bundles.get(name)
        if not isinstance(bundle, str) or not Path(bundle).is_absolute():
            raise ReferenceImageError("capture profile input is invalid")
        pin = pins.profiles[name]
        runtime = next(
            (
                item
                for item in runtimes
                if isinstance(item, dict)
                and item.get("identifier") == pin.runtime_identifier
                and item.get("isAvailable") is True
                and item.get("platform") in profile.runtime_platforms
            ),
            None,
        )
        device_known = any(
            isinstance(item, dict)
            and item.get("identifier") == pin.device_type_identifier
            and item.get("productFamily") == profile.product_family
            for item in device_types
        )
        supported = runtime.get("supportedDeviceTypes") if runtime is not None else None
        if (
            runtime is None
            or not device_known
            or not isinstance(supported, list)
            or not any(
                isinstance(item, dict) and item.get("identifier") == pin.device_type_identifier
                for item in supported
            )
        ):
            raise ReferenceImageError(
                f"pinned {name} simulator ({pin.runtime_identifier}, {pin.device_type_identifier}) "
                "is not available; see docs/validation-authority.md#reference-images"
            )
        output[name] = {
            "runtimeIdentifier": pin.runtime_identifier,
            "deviceTypeIdentifier": pin.device_type_identifier,
            "appBundle": bundle,
        }
        if name in COMPANION_UI_TEST_PROFILES:
            ui_test_run = visionos_ui_test_run if name == "visionos" else ios_ui_test_run
            if not Path(ui_test_run).is_absolute():
                raise ReferenceImageError("capture companion UI test run is invalid")
            output[name]["uiTestRun"] = ui_test_run
    return {"schemaVersion": CAPTURE_CONFIG_SCHEMA_VERSION, "kind": CAPTURE_CONFIG_KIND, "profiles": output}


def _pinned_xcode(_arguments: argparse.Namespace) -> int:
    print(load_simulator_pins().xcode)
    return 0


def _capture_config(arguments: argparse.Namespace) -> int:
    catalog_path = Path(arguments.catalog)
    if catalog_path.stat().st_size > MAX_CATALOG_BYTES:
        raise ReferenceImageError("simulator catalog is too large")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    if not isinstance(catalog, dict):
        raise ReferenceImageError("simulator catalog is invalid")
    config = capture_config(
        catalog,
        {
            "ios": arguments.ios_app,
            "ipados": arguments.ios_app,
            "visionos": arguments.visionos_app,
            "watchos": arguments.watchos_app,
            "tvos": arguments.tvos_app,
        },
        arguments.ios_ui_test_run,
        arguments.visionos_ui_test_run,
    )
    Path(arguments.output).write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


def _render_host(arguments: argparse.Namespace) -> int:
    matrix = json.loads(Path(arguments.matrix).read_text(encoding="utf-8"))
    output = Path(arguments.output)
    for surface in matrix["surfaces"]:
        if surface["id"] not in HOST_SURFACES:
            continue
        for cell in surface["cells"]:
            destination = output / surface["id"] / f"{cell['id']}.png"
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.unlink(missing_ok=True)
            subprocess.run(
                [
                    arguments.renderer,
                    "--fixture", cell["fixtureID"],
                    "--family", cell["family"],
                    "--appearance", cell["appearance"],
                    "--presentation", cell["presentation"],
                    "--scale", HOST_RENDERER_SCALE,
                    "--output", str(destination),
                ],
                check=True,
            )
    return 0


def _render_simulator(arguments: argparse.Namespace) -> int:
    results = capture_reference_cells(
        Path(arguments.config),
        Path(arguments.output),
        matrix_path=Path(arguments.matrix),
    )
    for result in sorted(results.values(), key=lambda item: str(item["requirementID"])):
        error = f" {result['errorCode']}" if result["errorCode"] else ""
        print(f"{result['status']}: {result['surface']}/{result['cellID']}.png{error}")
    return 0 if all(result["status"] == "captured" for result in results.values()) else 1


def _compare(arguments: argparse.Namespace) -> int:
    all_cells = matrix_cells(Path(arguments.matrix))
    surfaces = set(arguments.surface or ())
    if arguments.simulator:
        surfaces |= {cell.surface for cell in all_cells if cell.surface not in HOST_SURFACES}
    cells = tuple(cell for cell in all_cells if cell.surface in surfaces)
    if not cells:
        print("no matrix cells for the requested surfaces", file=sys.stderr)
        return 2
    rendered_root = Path(arguments.rendered)
    reference_root = Path(arguments.references)
    results = compare(cells, rendered_root, reference_root)
    for result in results:
        changed = "" if result.changed_pixels is None else f" ({result.changed_pixels} pixels differ)"
        detail = f" {result.detail}" if result.detail else ""
        print(f"{result.state}: {result.cell.relative_path}{changed}{detail}")
    if arguments.report:
        Path(arguments.report).write_text(
            json.dumps({"cells": [result.to_dict() for result in results]}, indent=2) + "\n",
            encoding="utf-8",
        )
    pending = [result for result in results if result.state != "matched"]
    if arguments.update:
        for result in pending:
            target = reference_root / result.cell.relative_path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(rendered_root / result.cell.relative_path, target)
            print(f"updated: {result.cell.relative_path}")
        return 0
    return 1 if pending else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("pinned-xcode", help="print the pinned Xcode").set_defaults(handler=_pinned_xcode)

    config = commands.add_parser("capture-config", help="select each profile's pinned simulator")
    config.add_argument("--catalog", required=True, help="xcrun simctl list --json output")
    config.add_argument("--ios-app", required=True)
    config.add_argument("--ios-ui-test-run", required=True)
    config.add_argument("--visionos-app", required=True)
    config.add_argument("--visionos-ui-test-run", required=True)
    config.add_argument("--watchos-app", required=True)
    config.add_argument("--tvos-app", required=True)
    config.add_argument("--output", required=True)
    config.set_defaults(handler=_capture_config)

    render = commands.add_parser("render-host", help="draw the macOS cells")
    render.add_argument("--renderer", required=True, help="built ContextPanelSharedViewRenderer executable")
    render.add_argument("--output", required=True, help="directory for <surface>/<cell>.png")
    render.add_argument("--matrix", default=str(DEFAULT_MATRIX_PATH))
    render.set_defaults(handler=_render_host)

    simulator = commands.add_parser("render-simulator", help="capture the simulator cells")
    simulator.add_argument("--config", required=True, help="capture config from capture-config")
    simulator.add_argument("--output", required=True, help="directory for <surface>/<cell>.png")
    simulator.add_argument("--matrix", default=str(DEFAULT_MATRIX_PATH))
    simulator.set_defaults(handler=_render_simulator)

    check = commands.add_parser("compare", help="compare rendered cells with their references")
    check.add_argument("--rendered", required=True, help="directory holding <surface>/<cell>.png")
    check.add_argument("--surface", action="append", help="surface to compare; repeat")
    check.add_argument("--simulator", action="store_true", help="compare every simulator surface")
    check.add_argument("--references", default=str(DEFAULT_REFERENCE_ROOT))
    check.add_argument("--matrix", default=str(DEFAULT_MATRIX_PATH))
    check.add_argument("--report", help="write a JSON report here")
    check.add_argument("--update", action="store_true", help="copy changed or missing cells over their references")
    check.set_defaults(handler=_compare)

    arguments = parser.parse_args(argv)
    try:
        return arguments.handler(arguments)
    except (
        ReferenceImageError,
        SharedViewEvidenceError,
        OSError,
        ValueError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"shared-view references: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
