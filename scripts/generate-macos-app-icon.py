#!/usr/bin/env python3
"""Generate the native macOS app icon from the checked-in vector source.

The source of truth is ``apps/macos/Resources/AppIcon.svg``. The generated
``AppIcon.icns`` is committed so normal macOS builds do not need an SVG
rasterizer. Regenerate it after changing the vector source:

    python3 scripts/generate-macos-app-icon.py

Rasterization uses ``rsvg-convert`` when available and falls back to ImageMagick
``magick``. The ICNS container is assembled with the Python standard library, so
the script adds no package or build dependency.
"""

from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SVG = ROOT / "apps/macos/Resources/AppIcon.svg"
DEFAULT_ICNS = ROOT / "apps/macos/Resources/AppIcon.icns"

# ICNS element types and the pixel size each one carries. The modern PNG-based
# types cover 16pt through 512pt at both 1x and 2x.
ICNS_ENTRIES = (
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512),
)


def rasterizers() -> list[str]:
    available = [tool for tool in ("rsvg-convert", "magick") if shutil.which(tool)]
    if not available:
        sys.exit(
            "error: an SVG rasterizer is required: install rsvg-convert (librsvg) or ImageMagick"
        )
    return available


def render(svg: Path, size: int, output: Path, tool: str) -> None:
    if tool == "rsvg-convert":
        command = [
            tool,
            "-w",
            str(size),
            "-h",
            str(size),
            "-o",
            str(output),
            str(svg),
        ]
    else:
        command = [
            tool,
            "-background",
            "none",
            str(svg),
            "-resize",
            f"{size}x{size}",
            str(output),
        ]
    subprocess.run(command, check=True)


def pack_icns(entries: list[tuple[str, bytes]]) -> bytes:
    body = bytearray()
    for kind, data in entries:
        body += kind.encode("ascii")
        body += struct.pack(">I", len(data) + 8)
        body += data
    return b"icns" + struct.pack(">I", len(body) + 8) + bytes(body)


def verify_icns(path: Path, expected_types: set[str]) -> None:
    data = path.read_bytes()
    if len(data) < 8 or data[:4] != b"icns":
        sys.exit(f"error: {path} is not an ICNS file")
    declared = struct.unpack(">I", data[4:8])[0]
    if declared != len(data):
        sys.exit(f"error: {path} declares {declared} bytes but contains {len(data)}")
    offset = 8
    found: set[str] = set()
    while offset < len(data):
        if offset + 8 > len(data):
            sys.exit(f"error: {path} has a truncated ICNS element")
        kind = data[offset : offset + 4].decode("ascii", "replace")
        length = struct.unpack(">I", data[offset + 4 : offset + 8])[0]
        if length < 8 or offset + length > len(data):
            sys.exit(f"error: {path} has an invalid ICNS element length")
        found.add(kind)
        offset += length
    missing = expected_types - found
    if missing:
        sys.exit(f"error: {path} is missing ICNS element(s): {', '.join(sorted(missing))}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--svg", type=Path, default=DEFAULT_SVG, help="vector icon source")
    parser.add_argument("--out", type=Path, default=DEFAULT_ICNS, help="ICNS output path")
    args = parser.parse_args()

    if not args.svg.is_file():
        sys.exit(f"error: missing vector icon source: {args.svg}")
    tools = rasterizers()
    tool = tools[0]
    args.out.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="highlite-icon-") as temporary:
        temporary_path = Path(temporary)
        entries: list[tuple[str, bytes]] = []
        rendered: dict[int, Path] = {}
        for kind, size in ICNS_ENTRIES:
            if size not in rendered:
                png = temporary_path / f"{size}.png"
                render(args.svg, size, png, tool)
                rendered[size] = png
            entries.append((kind, rendered[size].read_bytes()))

        args.out.write_bytes(pack_icns(entries))

    verify_icns(args.out, {kind for kind, _ in ICNS_ENTRIES})
    print(f"Wrote {args.out} ({args.out.stat().st_size} bytes) from {args.svg}")


if __name__ == "__main__":
    main()
