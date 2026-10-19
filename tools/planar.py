#!/usr/bin/env python3
"""Renders Amiga planar bitmaps to PNG (pure Python).

Layouts:
  planes      : whole plane 0, then plane 1... (each plane = rows x bytes_per_row)
  interleaved : for each row, plane 0, plane 1, ... (blitter/ILBM style)

Palette: --pal-offset N reads 2^planes (or 16 in HAM6) 12-bit OCS colours from
the file itself; --pal "000,fff,..." gives the colours; without a palette, greys.

usage:
  planar.py FILE OUT.png --width 320 --height 200 --planes 4 [--offset 32]
            [--layout planes|interleaved] [--pal-offset 0] [--ham] [--scale 2]
"""
from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amigahw import rgb12_to_rgb24  # noqa: E402


def write_png(path: Path, width: int, height: int, rgb_rows: list[bytes]) -> None:
    def chunk(tag: bytes, payload: bytes) -> bytes:
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + r for r in rgb_rows)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def decode_indices(data: bytes, offset: int, width: int, height: int, planes: int, layout: str,
                   row_bytes: int | None = None) -> list[list[int]]:
    """Returns a [row][pixel] matrix of colour indices."""
    bpr = row_bytes or (width + 15) // 16 * 2
    plane_size = bpr * height
    rows = []
    for y in range(height):
        row = [0] * width
        for p in range(planes):
            if layout == "interleaved":
                base = offset + (y * planes + p) * bpr
            else:
                base = offset + p * plane_size + y * bpr
            line = data[base:base + bpr]
            if len(line) < bpr:
                line = line + bytes(bpr - len(line))
            bit = 1 << p
            for x in range(width):
                if line[x >> 3] & (0x80 >> (x & 7)):
                    row[x] |= bit
        rows.append(row)
    return rows


def render(indices: list[list[int]], palette: list[tuple[int, int, int]], ham: bool, scale: int) -> list[bytes]:
    out = []
    for row in indices:
        px = bytearray()
        r, g, b = palette[0]
        for v in row:
            if ham:
                ctl, val = v >> 4, v & 15
                if ctl == 0:
                    r, g, b = palette[val]
                elif ctl == 1:
                    b = val * 17
                elif ctl == 2:
                    r = val * 17
                else:
                    g = val * 17
                c = (r, g, b)
            else:
                c = palette[v % len(palette)]
            px.extend(bytes(c) * scale)
        line = bytes(px)
        out.extend([line] * scale)
    return out


def parse_palette(args, data: bytes, ncolors: int) -> list[tuple[int, int, int]]:
    if args.pal:
        return [rgb12_to_rgb24(int(c, 16)) for c in args.pal.split(",")]
    if args.pal_offset is not None:
        return [rgb12_to_rgb24(struct.unpack_from(">H", data, args.pal_offset + 2 * i)[0]) for i in range(ncolors)]
    return [(i * 255 // (ncolors - 1),) * 3 for i in range(ncolors)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--width", type=int, default=320)
    ap.add_argument("--height", type=int, default=200)
    ap.add_argument("--planes", type=int, default=4)
    ap.add_argument("--offset", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--row-bytes", type=int, help="bytes per row of one plane (default: width/8)")
    ap.add_argument("--layout", choices=("planes", "interleaved"), default="planes")
    ap.add_argument("--pal-offset", type=lambda s: int(s, 0))
    ap.add_argument("--pal")
    ap.add_argument("--ham", action="store_true")
    ap.add_argument("--scale", type=int, default=1)
    a = ap.parse_args()
    data = a.input.read_bytes()
    ncolors = 16 if a.ham else 1 << a.planes
    pal = parse_palette(a, data, ncolors)
    idx = decode_indices(data, a.offset, a.width, a.height, a.planes, a.layout, a.row_bytes)
    write_png(a.output, a.width * a.scale, a.height * a.scale, render(idx, pal, a.ham, a.scale))
    print(f"{a.output}: {a.width}x{a.height}x{a.planes} {a.layout}{' HAM' if a.ham else ''}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
