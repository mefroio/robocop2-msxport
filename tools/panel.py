#!/usr/bin/env python3
"""Assets of the in-game status panel (Amiga), as the panel routines use them (via REA/Ghidra).

The panel bitmap is 320 x 48, 5 planes of 40 bytes per line at $6DA20 (planes $780 apart), the
last 9600 bytes of PERMA; its palette is COLOR01..31 of copper list $10332 (MOVEs at $103FA).
All assets live in PERMA (loaded at $58850):

  digits   $654B0 + n*$60   16x16, 3 planes; 0-9 green, 12-21 red   ($105D2, called by $F6B8)
  font     $65DB0 + n*24    8x8, 3 planes, FONT_GLYPHS of them; A-Z = 0-25, '0'.. = c-$16,
           space = 41, 42 '©', 43 '%' (code 'l': "10%" in the NUKE / HOST message, $F855) ($10620)
  heads    $666D0 + n*$2A8  32x34, 5 planes (lives; n = 0 normal)    ($88DE)
  icons    $676C0 + n*$A0   16x16, 5 planes (weapon, 8 entries)      ($896A, offsets $AF76)
  can      $661D0           32x40, 5 planes, modulo $24 in the panel: full energy can
           $664F0 (+$A0, +$140) 32x8 "empty" tops, $661F0 one line per level ($89BE)

Panel layout (top-left of each element in panel pixels): timer digits MM at x 224/240 and
SS at x 272/288, y 6 (BCD $804A/$804B; odd byte offsets aligned by the blitter); weapon ammo digits at x 48/64/80, y 23 (BCD
$8030/$8031) and weapon icon at (96, 25) ($805C = weapon, tables $FD52/$FD5A); score digits
at x 192..288 step 16, y 29 (BCD $8046-$8049); heads at x 128 + 32n, y 14 ($8034 = lives);
message text 8x8 at x 40 + 8c, y 5 ($FDA2 ticker); energy can at x 0, y 3 ($169A target,
$169C shown, 0..$100).

usage: panel.py OUTDIR -> panel_assets.png (enlarged sheet of every asset)
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amigahw import rgb12_to_rgb24  # noqa: E402
from planar import write_png  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PERMA_LOAD = 0x58850
COPPER_COLORS = 0x103FA
DIGITS, FONT, HEADS, ICONS, CAN = 0x654B0, 0x65DB0, 0x666D0, 0x676C0, 0x661D0
CAN_EMPTY = 0x664F0


def panel_palette(main: bytes) -> list[tuple[int, int, int]]:
    pal = [(0, 0, 0)]
    for i in range(31):
        reg, val = struct.unpack_from(">HH", main, COPPER_COLORS - 0x8000 + 4 * i)
        assert reg == 0x182 + 2 * i
        pal.append(rgb12_to_rgb24(val))
    return pal


def planes(perma: bytes, addr: int, w: int, h: int, n: int, row_bytes: int | None = None,
           plane_bytes: int | None = None) -> list[list[int]]:
    """Sequential planes: n planes of (w/8 bytes or row_bytes) x h lines."""
    rb = row_bytes or w // 8
    pb = plane_bytes or rb * h
    o = addr - PERMA_LOAD
    return [[sum(1 << p for p in range(n) if perma[o + p * pb + y * rb + (x >> 3)] & (0x80 >> (x & 7)))
             for x in range(w)] for y in range(h)]


FONT_GLYPHS = 44                    # (all of them: 42 left out '%', drawn as the bytes after the
                                    #   font in the MSX's HUD: the user saw it garbled, 2026-10-22)


def font_char(perma: bytes, n: int) -> list[list[int]]:
    """8x8 glyph: 24 bytes = for each plane, 8 lines of one byte (as $10620 copies them)."""
    o = FONT + 24 * n - PERMA_LOAD
    return [[sum(1 << p for p in range(3) if perma[o + 8 * p + y] & (0x80 >> x)) for x in range(8)]
            for y in range(8)]


def assets(perma: bytes) -> dict[str, list]:
    return {
        "digits": [planes(perma, DIGITS + 0x60 * n, 16, 16, 3) for n in range(22)],
        "font": [font_char(perma, n) for n in range(FONT_GLYPHS)],
        "heads": [planes(perma, HEADS + 0x2A8 * n, 32, 34, 5) for n in range(2)],
        "icons": [planes(perma, ICONS + 0xA0 * n, 16, 16, 5) for n in range(8)],
        "can": [planes(perma, CAN, 32, 40, 5)],
        "can_empty": [planes(perma, CAN_EMPTY + 0xA0 * n, 32, 8, 5) for n in range(3)],
    }


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/png")
    mainb = (ROOT / "build/extracted/boot/main_8000.bin").read_bytes()
    perma = (ROOT / "build/extracted/files/PERMA_05.bin").read_bytes()
    pal = panel_palette(mainb)
    a = assets(perma)
    S, gap = 3, 4
    rows = []
    for name in ("digits", "font", "heads", "icons", "can", "can_empty"):
        items = a[name]
        h = max(len(i) for i in items)
        line = [[(60, 60, 60)] * gap for _ in range(h + 2 * gap)]
        for img in items:
            for y in range(h + 2 * gap):
                for x in range(len(img[0]) + gap):
                    yy, xx = y - gap, x
                    line[y].append(pal[img[yy][xx]] if 0 <= yy < len(img) and xx < len(img[0]) else (60, 60, 60))
        rows.append(line)
    W = max(len(r[0]) for r in rows)
    canvas = []
    for r in rows:
        for line in r:
            canvas.append(line + [(60, 60, 60)] * (W - len(line)))
    write_png(out / "panel_assets.png", W * S, len(canvas) * S,
              [b"".join(bytes(c) * S for c in row) for row in canvas for _ in range(S)])
    print(f"{out / 'panel_assets.png'}: " + ", ".join(f"{k} {len(v)}" for k, v in a.items()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
