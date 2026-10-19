#!/usr/bin/env python3
"""RoboCop (player) frames from the animation table at $B4E2 (main) and PERMA.

Format (routine $B94A, via REA/Ghidra):
  state s: 8 bytes at $B4E2+8s = [steps-1][list offset][height?][0]
  frame:   16 bytes = [PERMA offset][BLTSIZE][destination modulo][...][x.b @12][y.b @13][hx @14][hy @15]
  graphic: 4 consecutive planes of (2*w bytes x h lines), no mask; colour 0 = transparent;
           on the Amiga it becomes 16-colour attached sprites (COLOR16..31).
usage: player.py OUT.png
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amigahw import rgb12_to_rgb24  # noqa: E402
from planar import write_png  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TABLE, NSTATES, PERMA_LOAD = 0xB4E2, 17, 0x58850


def frames(main: bytes):
    uw = lambda a: struct.unpack_from(">H", main, a - 0x8000)[0]  # noqa: E731
    out = []
    for s in range(NSTATES):
        e = TABLE + 8 * s
        steps, lst = uw(e) + 1, TABLE + uw(e + 2)
        for i in range(0, steps, 2):
            r = lst + 8 * i
            off, bltsize = uw(r), uw(r + 2)
            x = struct.unpack_from(">b", main, r + 12 - 0x8000)[0]
            y = main[r + 13 - 0x8000]
            out.append({"state": s, "index": i // 2, "perma_offset": off, "w": (bltsize & 63) * 16,
                        "h": bltsize >> 6, "x": x, "y": y})
    return out


def main() -> int:
    mainb = (ROOT / "build/extracted/boot/main_8000.bin").read_bytes()
    perma = (ROOT / "build/extracted/files/PERMA_05.bin").read_bytes()
    pal12 = [struct.unpack_from(">H", mainb, 0xFFF6 - 0x8000 + 2 * i)[0] for i in range(31)]
    pal = [(255, 0, 255)] + [rgb12_to_rgb24(c) for c in pal12[16:31]]  # COLOR17..31
    fr = frames(mainb)
    seen, uniq = set(), []
    for f in fr:
        k = (f["perma_offset"], f["w"], f["h"])
        if k not in seen:
            seen.add(k)
            uniq.append(f)
    cw = max(f["w"] for f in uniq) + 4
    ch = max(f["h"] for f in uniq) + 4
    cols = 12
    rows = (len(uniq) + cols - 1) // cols
    W, H = cols * cw, rows * ch
    canvas = [[(60, 60, 60)] * W for _ in range(H)]
    for n, f in enumerate(uniq):
        wb, h = f["w"] // 8, f["h"]
        base = f["perma_offset"]
        ox, oy = (n % cols) * cw + 2, (n // cols) * ch + 2
        for y in range(h):
            for x in range(f["w"]):
                v = 0
                for p in range(4):
                    o = base + p * wb * h + y * wb + (x >> 3)
                    if o < len(perma) and perma[o] & (0x80 >> (x & 7)):
                        v |= 1 << p
                canvas[oy + y][ox + x] = pal[v]
    S = 2
    rows_px = [b"".join(bytes(c) * S for c in row) for row in canvas for _ in range(S)]
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/sprites/robocop.png")
    write_png(out, W * S, H * S, rows_px)
    print(f"{out}: {len(fr)} frames ({len(uniq)} distinct graphics); sizes:",
          sorted({(f['w'], f['h']) for f in uniq}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
