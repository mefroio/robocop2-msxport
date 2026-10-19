#!/usr/bin/env python3
"""Renders Robocop 2 BOBs (format: mask + 4 planes, sequential planes).

Each frame takes 5 * (width_bytes * height) bytes:
    [mask][plane 0][plane 1][plane 2][plane 3]
The width comes from the BLTSIZE used by the game: words = (BLTSIZE & 63) - 1
(the blit uses one extra word for the shift), height = BLTSIZE >> 6.

Addresses can be given as Amiga RAM addresses: --load is the address where
the file is loaded (e.g. DATAL* at $28000, PERMA at $58850).

usage:
  bobs.py FILE OUT.png --load 0x28000 --addr 0x3e810 --bltsize 0x5c3 --count 16
          [--stride 0x1cc] [--pal 000,222,...] [--pal-file main.bin --pal-load 0x8000 --pal-addr 0xfff6]
          [--scale 3] [--cols 8] [--mask]
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amigahw import rgb12_to_rgb24  # noqa: E402
from planar import write_png  # noqa: E402

BG = (255, 0, 255)  # transparent
CHECK = (60, 60, 60)


def frame_pixels(data: bytes, off: int, wbytes: int, h: int, planes: int = 4) -> list[list[int | None]]:
    ps = wbytes * h
    rows = []
    for y in range(h):
        row = []
        for x in range(wbytes * 8):
            byte, bit = y * wbytes + (x >> 3), 0x80 >> (x & 7)
            if not data[off + byte] & bit:
                row.append(None)
                continue
            v = 0
            for p in range(planes):
                if data[off + ps * (p + 1) + byte] & bit:
                    v |= 1 << p
            row.append(v)
        rows.append(row)
    return rows


def mask_consistency(data: bytes, off: int, wbytes: int, h: int, planes: int = 4) -> float:
    """Fraction of bytes where every plane is contained in the mask (1.0 = consistent)."""
    ps = wbytes * h
    ok = 0
    for i in range(ps):
        m = data[off + i]
        orp = 0
        for p in range(planes):
            orp |= data[off + ps * (p + 1) + i]
        ok += (orp & ~m & 0xFF) == 0
    return ok / ps if ps else 0.0


def load_palette(a) -> list[tuple[int, int, int]]:
    if a.pal:
        return [rgb12_to_rgb24(int(c, 16)) for c in a.pal.split(",")]
    if a.pal_file:
        pdata = Path(a.pal_file).read_bytes()
        o = a.pal_addr - a.pal_load
        # game palette: COLOR01..COLOR31 (COLOR00 is always 0)
        return [(0, 0, 0)] + [rgb12_to_rgb24(struct.unpack_from(">H", pdata, o + 2 * i)[0]) for i in range(15)]
    return [(i * 17,) * 3 for i in range(16)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    num = lambda s: int(s, 0)  # noqa: E731
    ap.add_argument("--load", type=num, default=0)
    ap.add_argument("--addr", type=num, required=True)
    ap.add_argument("--bltsize", type=num, required=True)
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--stride", type=num, help="bytes between frames (default: frame size)")
    ap.add_argument("--pal")
    ap.add_argument("--pal-file")
    ap.add_argument("--pal-load", type=num, default=0x8000)
    ap.add_argument("--pal-addr", type=num, default=0xFFF6)
    ap.add_argument("--scale", type=int, default=3)
    ap.add_argument("--cols", type=int, default=8)
    a = ap.parse_args()

    data = a.input.read_bytes()
    words = (a.bltsize & 63) - 1
    h = a.bltsize >> 6
    wb = words * 2
    fsize = 5 * wb * h
    stride = a.stride or fsize
    pal = load_palette(a)
    frames = []
    for i in range(a.count):
        off = a.addr - a.load + i * stride
        if off + fsize > len(data):
            break
        c = mask_consistency(data, off, wb, h)
        frames.append(frame_pixels(data, off, wb, h))
        print(f"frame {i:3d} @ ${a.addr + i * stride:06x} (file +${off:05x}): {wb * 8}x{h}  mask>=planes={c:.2f}")
    cols = min(a.cols, len(frames)) or 1
    rows_n = (len(frames) + cols - 1) // cols
    cw, ch = wb * 8 + 2, h + 2
    W, H = cols * cw, rows_n * ch
    canvas = [[CHECK] * W for _ in range(H)]
    for i, fr in enumerate(frames):
        ox, oy = (i % cols) * cw + 1, (i // cols) * ch + 1
        for y, row in enumerate(fr):
            for x, v in enumerate(row):
                canvas[oy + y][ox + x] = BG if v is None else pal[v]
    s = a.scale
    rows = []
    for row in canvas:
        line = b"".join(bytes(c) * s for c in row)
        rows.extend([line] * s)
    write_png(a.output, W * s, H * s, rows)
    print(f"{a.output}: {len(frames)} frames")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
