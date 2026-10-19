"""Compare rendered shared-view cells with their committed reference images.

Every cell in the shared-view matrix has one reference PNG at
``Tests/SharedViewReferences/<surface>/<cell>.png``. A rendered cell matches when
its size is the same and at most ``MAX_CHANGED_PIXELS`` pixels differ by more than
``CHANNEL_TOLERANCE`` in any channel. The tolerance absorbs anti-aliasing noise on
the pinned CI toolchain; a changed word or number moves far more pixels than that.

A missing reference never matches. Only the standard library is used, so the
same code runs in CI, on an operator machine, and in the release tooling.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import struct
import subprocess
import zlib

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MATRIX_PATH = REPO_ROOT / "Config" / "ContextPanelSharedViewMatrix.json"
DEFAULT_REFERENCE_ROOT = REPO_ROOT / "Tests" / "SharedViewReferences"

CHANNEL_TOLERANCE = 8
MAX_CHANGED_PIXELS = 16

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
CHANNELS_BY_COLOR_TYPE = {0: 1, 2: 3, 4: 2, 6: 4}


class ReferenceImageError(Exception):
    """A PNG or matrix input this module cannot read."""


@dataclass(frozen=True)
class Image:
    width: int
    height: int
    rgba: bytes


@dataclass(frozen=True)
class Cell:
    surface: str
    cell: str

    @property
    def relative_path(self) -> str:
        return f"{self.surface}/{self.cell}.png"


@dataclass(frozen=True)
class CellResult:
    cell: Cell
    state: str  # "matched", "changed", or "missing-reference"
    changed_pixels: int | None = None
    detail: str | None = None

    def to_dict(self) -> dict[str, object]:
        return {
            "surface": self.cell.surface,
            "cell": self.cell.cell,
            "state": self.state,
            "changedPixels": self.changed_pixels,
            "detail": self.detail,
        }


def decode_png(data: bytes) -> Image:
    """Decode a non-interlaced 8- or 16-bit grayscale/RGB(A) PNG to 8-bit RGBA."""
    if not data.startswith(PNG_SIGNATURE):
        raise ReferenceImageError("not a PNG")
    offset = len(PNG_SIGNATURE)
    header: tuple[int, ...] | None = None
    compressed = bytearray()
    while offset + 8 <= len(data):
        (length,) = struct.unpack(">I", data[offset : offset + 4])
        kind = data[offset + 4 : offset + 8]
        body = data[offset + 8 : offset + 8 + length]
        if len(body) != length:
            raise ReferenceImageError("truncated PNG chunk")
        offset += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            compressed.extend(body)
        elif kind in (b"tRNS", b"PLTE"):
            # Colour-key transparency and palettes would change pixels this decoder does not model.
            raise ReferenceImageError("unsupported PNG format")
        elif kind == b"IEND":
            break
    if header is None:
        raise ReferenceImageError("PNG has no header")
    width, height, depth, color_type, _, _, interlace = header
    channels = CHANNELS_BY_COLOR_TYPE.get(color_type)
    if channels is None or depth not in (8, 16) or interlace != 0 or width == 0 or height == 0:
        raise ReferenceImageError("unsupported PNG format")
    try:
        raw = zlib.decompress(bytes(compressed))
    except zlib.error as error:
        raise ReferenceImageError("PNG data is corrupt") from error
    sample_bytes = depth // 8
    pixel_bytes = channels * sample_bytes
    stride = width * pixel_bytes
    if len(raw) != height * (stride + 1):
        raise ReferenceImageError("PNG data has the wrong length")

    rgba = bytearray(width * height * 4)
    previous = bytearray(stride)
    for row in range(height):
        start = row * (stride + 1)
        line = bytearray(raw[start + 1 : start + 1 + stride])
        _unfilter(raw[start], line, previous, pixel_bytes)
        previous = line
        samples = line[::sample_bytes] if sample_bytes == 2 else line  # keep the high byte
        out = rgba[row * width * 4 : (row + 1) * width * 4]
        if channels == 4:
            out[:] = samples
        else:
            gray = channels <= 2
            for target in range(3):
                out[target::4] = samples[(0 if gray else target) :: channels]
            out[3::4] = samples[channels - 1 :: channels] if channels in (2, 4) else b"\xff" * width
        rgba[row * width * 4 : (row + 1) * width * 4] = out
    return Image(width, height, bytes(rgba))


def encode_png(image: Image) -> bytes:
    """Encode 8-bit RGBA pixels as a PNG that `decode_png` reads back unchanged."""
    stride = image.width * 4
    if len(image.rgba) != stride * image.height:
        raise ReferenceImageError("image data has the wrong length")
    raw = b"".join(
        b"\x00" + image.rgba[row * stride : (row + 1) * stride] for row in range(image.height)
    )

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    return (
        PNG_SIGNATURE
        + chunk(b"IHDR", struct.pack(">IIBBBBB", image.width, image.height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def fill_regions(image: Image, regions: tuple[tuple[int, int, int, int], ...]) -> Image:
    """Paint each (x, y, width, height) region opaque black, clipped to the image.

    Used for content the simulator draws and nothing can pin, such as the Watch clock.
    """
    rgba = bytearray(image.rgba)
    for x, y, width, height in regions:
        left, right = max(0, x), min(image.width, x + width)
        if left >= right:
            continue
        for row in range(max(0, y), min(image.height, y + height)):
            start = (row * image.width + left) * 4
            rgba[start : start + (right - left) * 4] = b"\x00\x00\x00\xff" * (right - left)
    return Image(image.width, image.height, bytes(rgba))


def _unfilter(kind: int, line: bytearray, previous: bytearray, pixel_bytes: int) -> None:
    if kind == 0:
        return
    for index in range(len(line)):
        left = line[index - pixel_bytes] if index >= pixel_bytes else 0
        up = previous[index]
        if kind == 1:
            predictor = left
        elif kind == 2:
            predictor = up
        elif kind == 3:
            predictor = (left + up) // 2
        elif kind == 4:
            upper_left = previous[index - pixel_bytes] if index >= pixel_bytes else 0
            estimate = left + up - upper_left
            distances = (abs(estimate - left), abs(estimate - up), abs(estimate - upper_left))
            predictor = (left, up, upper_left)[distances.index(min(distances))]
        else:
            raise ReferenceImageError("PNG uses an unknown row filter")
        line[index] = (line[index] + predictor) & 0xFF


def changed_pixel_count(reference: Image, rendered: Image) -> int | None:
    """Pixels that differ beyond the channel tolerance, or None when the sizes differ."""
    if (reference.width, reference.height) != (rendered.width, rendered.height):
        return None
    changed = 0
    left, right = reference.rgba, rendered.rgba
    stride = reference.width * 4
    for row_start in range(0, len(left), stride):
        if left[row_start : row_start + stride] == right[row_start : row_start + stride]:
            continue
        for start in range(row_start, row_start + stride, 4):
            if any(abs(left[start + channel] - right[start + channel]) > CHANNEL_TOLERANCE for channel in range(4)):
                changed += 1
    return changed


def matrix_cells(matrix_path: Path = DEFAULT_MATRIX_PATH) -> tuple[Cell, ...]:
    try:
        matrix = json.loads(matrix_path.read_text(encoding="utf-8"))
        return tuple(
            Cell(str(surface["id"]), str(cell["id"]))
            for surface in matrix["surfaces"]
            for cell in surface["cells"]
        )
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ReferenceImageError("shared-view matrix is unreadable") from error


def compare_cell(cell: Cell, rendered_root: Path, reference_root: Path) -> CellResult:
    reference_path = reference_root / cell.relative_path
    if not reference_path.is_file():
        return CellResult(cell, "missing-reference", detail="no committed reference image")
    try:
        rendered = decode_png((rendered_root / cell.relative_path).read_bytes())
    except (OSError, ReferenceImageError) as error:
        raise ReferenceImageError(f"{cell.relative_path}: rendered image is unreadable") from error
    try:
        reference = decode_png(reference_path.read_bytes())
    except (OSError, ReferenceImageError) as error:
        raise ReferenceImageError(f"{cell.relative_path}: reference image is unreadable") from error
    changed = changed_pixel_count(reference, rendered)
    if changed is None:
        return CellResult(
            cell,
            "changed",
            detail=f"size {rendered.width}x{rendered.height}, reference {reference.width}x{reference.height}",
        )
    return CellResult(cell, "matched" if changed <= MAX_CHANGED_PIXELS else "changed", changed_pixels=changed)


def compare(
    cells: tuple[Cell, ...],
    rendered_root: Path,
    reference_root: Path = DEFAULT_REFERENCE_ROOT,
) -> tuple[CellResult, ...]:
    return tuple(compare_cell(cell, rendered_root, reference_root) for cell in cells)


def reference_path(cell: Cell) -> str:
    """Repository path of a cell's committed reference image."""
    return f"{DEFAULT_REFERENCE_ROOT.relative_to(REPO_ROOT).as_posix()}/{cell.relative_path}"


def images_match(reference: bytes, candidate: bytes) -> bool:
    """True when two PNGs are the same size and differ only within the tolerance."""
    changed = changed_pixel_count(decode_png(reference), decode_png(candidate))
    return changed is not None and changed <= MAX_CHANGED_PIXELS


def committed_reference(repository: Path, commit: str, cell: Cell) -> bytes | None:
    """The reference image committed at `commit`, read from Git rather than a working tree."""
    object_name = f"{commit}:{reference_path(cell)}"
    exists = subprocess.run(
        ["git", "-C", str(repository), "cat-file", "-e", object_name],
        capture_output=True,
        check=False,
    )
    if exists.returncode != 0:
        return None
    blob = subprocess.run(
        ["git", "-C", str(repository), "cat-file", "blob", object_name],
        capture_output=True,
        check=False,
    )
    if blob.returncode != 0:
        raise ReferenceImageError(f"{reference_path(cell)} at {commit} is unreadable")
    return blob.stdout
