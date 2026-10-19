#!/usr/bin/env python3
"""Rebuilds the SCREEN 5 display from a VRAM dump and the VDP registers.

Complements the MSX-AI capture, which does not model the V9958 SP2 or R#27. The logic
follows the openMSX rasterizer (SDLRasterizer/PixelRenderer):
  - R#2 bit 5 = displayed page; with R#25 bit 0 (SP2) and an odd page, the visible line is
    [page p1 from 8*(R#26 & 31)][page p1^1], p1 = R#26 >> 5;
  - R#27 shifts the image 0..7 px right; R#25 bit 1 (MSK) covers the left 8 px;
  - R#23 = first line (256-line ring); R#9 bit 7 = 212/192 lines;
  - R#18 (set-adjust) shifts image and sprites by s = ((R#18 & 15) ^ 7) - 7 px (-7..+8);
    whatever leaves the 256 px area becomes border.
usage: msxscreen.py VRAM.bin "regs..." "palette..." OUT.png   (lists as printed by openMSX Tcl)
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from planar import write_png  # noqa: E402


def render(vram: bytes, regs: list[int], pal: list[int]) -> tuple[int, int, list[bytes]]:
    rgb = [((pal[2 * i] >> 4) * 255 // 7, (pal[2 * i + 1] & 7) * 255 // 7, (pal[2 * i] & 7) * 255 // 7)
           for i in range(16)]
    lines = 212 if regs[9] & 0x80 else 192
    page = (regs[2] >> 5) & 3
    sp2 = bool(regs[25] & 1) and bool(page & 1)
    msk = bool(regs[25] & 2)
    hs = 8 * (regs[26] & 0x1F)
    p1 = (regs[26] >> 5) & 1
    border = rgb[regs[7] & 15]
    adj = ((regs[18] & 15) ^ 7) - 7
    out = []
    for y in range(lines):
        ly = (regs[23] + y) & 0xFF
        row = bytearray()
        for x in range(256):
            sx = x - adj - (regs[27] & 7)
            if sx >= 256:
                row += bytes(border)
                continue
            if (msk and x < 8) or sx < 0:
                row += bytes(border)
                continue
            pos = hs + sx
            if sp2:
                pg = (page & 2) | (p1 if pos < 256 else p1 ^ 1)
                px = pos & 0xFF
            else:
                pg, px = page, pos & 0xFF
            b = vram[pg * 0x8000 + ly * 128 + px // 2]
            v = (b >> 4) if px % 2 == 0 else (b & 15)
            row += bytes(rgb[v])
        out.append(bytes(row))
    return 256, lines, out


def main() -> int:
    vram = Path(sys.argv[1]).read_bytes()
    regs = [int(v) for v in sys.argv[2].split()]
    pal = [int(v) for v in sys.argv[3].split()]
    w, h, rows = render(vram, regs, pal)
    write_png(Path(sys.argv[4]), w, h, rows)
    print(f"{sys.argv[4]}: {w}x{h}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
