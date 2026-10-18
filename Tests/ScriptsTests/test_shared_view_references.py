import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))
import context_panel_shared_view_references as references  # noqa: E402

CLI_PATH = REPO_ROOT / "scripts" / "context-panel-shared-view-references.py"
SPEC = importlib.util.spec_from_file_location("shared_view_references_cli", CLI_PATH)
assert SPEC is not None and SPEC.loader is not None
cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli)


def encode_png(
    width: int,
    height: int,
    pixels: list[tuple[int, int, int, int]],
    *,
    color_type: int = 6,
    depth: int = 8,
    row_filter: int = 0,
) -> bytes:
    """Encode RGBA tuples with one row filter so the decoder sees each filter type."""
    channels = references.CHANNELS_BY_COLOR_TYPE[color_type]
    sample_bytes = depth // 8
    pixel_bytes = channels * sample_bytes
    raw = bytearray()
    previous = bytearray(width * pixel_bytes)
    for row in range(height):
        line = bytearray()
        for column in range(width):
            red, green, blue, alpha = pixels[row * width + column]
            samples = {1: (red,), 2: (red, alpha), 3: (red, green, blue), 4: (red, green, blue, alpha)}[channels]
            for sample in samples:
                line.extend(bytes((sample,)) * sample_bytes)
        filtered = bytearray(len(line))
        for index, value in enumerate(line):
            left = line[index - pixel_bytes] if index >= pixel_bytes else 0
            up = previous[index]
            upper_left = previous[index - pixel_bytes] if index >= pixel_bytes else 0
            if row_filter == 0:
                predictor = 0
            elif row_filter == 1:
                predictor = left
            elif row_filter == 2:
                predictor = up
            elif row_filter == 3:
                predictor = (left + up) // 2
            else:
                estimate = left + up - upper_left
                distances = (abs(estimate - left), abs(estimate - up), abs(estimate - upper_left))
                predictor = (left, up, upper_left)[distances.index(min(distances))]
            filtered[index] = (value - predictor) & 0xFF
        raw.append(row_filter)
        raw.extend(filtered)
        previous = line

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    header = struct.pack(">IIBBBBB", width, height, depth, color_type, 0, 0, 0)
    return references.PNG_SIGNATURE + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


def gradient(width: int = 12, height: int = 8) -> list[tuple[int, int, int, int]]:
    return [((x * 20) % 256, (y * 30) % 256, (x * y) % 256, 255) for y in range(height) for x in range(width)]


class DecodeTests(unittest.TestCase):
    def test_every_row_filter_decodes_to_the_same_pixels(self) -> None:
        pixels = gradient()
        expected = bytes(channel for pixel in pixels for channel in pixel)
        for row_filter in range(5):
            image = references.decode_png(encode_png(12, 8, pixels, row_filter=row_filter))
            self.assertEqual((image.width, image.height, image.rgba), (12, 8, expected), row_filter)

    def test_rgb_gray_and_sixteen_bit_images_expand_to_rgba(self) -> None:
        pixels = [(10, 20, 30, 255), (40, 50, 60, 255)]
        rgb = references.decode_png(encode_png(2, 1, pixels, color_type=2, depth=16, row_filter=1))
        self.assertEqual(rgb.rgba, bytes((10, 20, 30, 255, 40, 50, 60, 255)))
        gray = references.decode_png(encode_png(2, 1, [(7, 0, 0, 90), (9, 0, 0, 255)], color_type=4))
        self.assertEqual(gray.rgba, bytes((7, 7, 7, 90, 9, 9, 9, 255)))

    def test_unreadable_images_are_errors(self) -> None:
        with self.assertRaises(references.ReferenceImageError):
            references.decode_png(b"not a png")
        palette = bytearray(encode_png(1, 1, [(0, 0, 0, 255)], color_type=2))
        palette[len(references.PNG_SIGNATURE) + 8 + 9] = 3  # IHDR color type: palette
        with self.assertRaises(references.ReferenceImageError):
            references.decode_png(bytes(palette))


class CompareTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.rendered = self.root / "rendered"
        self.reference = self.root / "reference"
        self.cell = references.Cell("macos.widget", "baseline")

    def write(self, root: Path, pixels: list[tuple[int, int, int, int]], width: int = 12, height: int = 8) -> None:
        path = root / self.cell.relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(encode_png(width, height, pixels))

    def result(self) -> "references.CellResult":
        return references.compare_cell(self.cell, self.rendered, self.reference)

    def test_small_noise_matches(self) -> None:
        pixels = gradient()
        self.write(self.reference, pixels)
        noisy = list(pixels)
        noisy[5] = tuple(min(255, channel + references.CHANNEL_TOLERANCE) for channel in noisy[5])
        for index in range(20, 20 + references.MAX_CHANGED_PIXELS):
            noisy[index] = (255, 255, 255, 255)
        self.write(self.rendered, noisy)
        result = self.result()
        self.assertEqual(result.state, "matched")
        self.assertEqual(result.changed_pixels, references.MAX_CHANGED_PIXELS)

    def test_a_visible_change_does_not_match(self) -> None:
        pixels = gradient()
        self.write(self.reference, pixels)
        changed = list(pixels)
        for index in range(references.MAX_CHANGED_PIXELS + 1):
            changed[index] = (255, 0, 255, 255)
        self.write(self.rendered, changed)
        self.assertEqual(self.result().state, "changed")

    def test_a_different_size_does_not_match(self) -> None:
        self.write(self.reference, gradient())
        self.write(self.rendered, gradient(height=9), height=9)
        result = self.result()
        self.assertEqual(result.state, "changed")
        self.assertIsNone(result.changed_pixels)

    def test_a_missing_reference_never_matches(self) -> None:
        self.write(self.rendered, gradient())
        self.assertEqual(self.result().state, "missing-reference")

    def test_a_missing_rendered_cell_is_an_error(self) -> None:
        self.write(self.reference, gradient())
        with self.assertRaises(references.ReferenceImageError):
            self.result()


class CommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.matrix = self.root / "matrix.json"
        self.matrix.write_text(json.dumps({"surfaces": [
            {"id": "macos.widget", "cells": [{"id": "baseline"}, {"id": "stress"}]},
            {"id": "ios.app", "cells": [{"id": "baseline"}]},
        ]}))
        for cell in ("baseline", "stress"):
            path = self.root / "rendered" / "macos.widget" / f"{cell}.png"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(encode_png(12, 8, gradient()))

    def run_compare(self, *extra: str) -> int:
        return cli.main([
            "compare", "--rendered", str(self.root / "rendered"), "--references", str(self.root / "references"),
            "--matrix", str(self.matrix), "--surface", "macos.widget", "--report", str(self.root / "report.json"),
            *extra,
        ])

    def test_missing_references_fail_until_recorded_then_match(self) -> None:
        self.assertEqual(self.run_compare(), 1)
        report = json.loads((self.root / "report.json").read_text())
        self.assertEqual([cell["state"] for cell in report["cells"]], ["missing-reference", "missing-reference"])

        self.assertEqual(self.run_compare("--update"), 0)
        self.assertEqual(self.run_compare(), 0)

    def test_an_unknown_surface_is_refused(self) -> None:
        exit_code = cli.main([
            "compare", "--rendered", str(self.root / "rendered"), "--matrix", str(self.matrix), "--surface", "macos.nothing",
        ])
        self.assertEqual(exit_code, 2)


if __name__ == "__main__":
    unittest.main()
