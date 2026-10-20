#!/usr/bin/env python3
"""Rebuilds the Amiga in-game status panel as the MSX HUD (SCREEN 5, own palette).

Amiga panel (copper list $10332, verified): 320x48, 5 sequential planes at $6DA20, i.e. the
last 9600 bytes of PERMA (file offset $151D0); palette COLOR01..31 from the copper MOVEs at
$103FA..$10472 of the main code; lines 0-45 are shown, line 0 is black. The elements and the
routines that update them are described in tools/panel.py and docs/AMIGA_ANALYSIS.md.

The MSX has 256 px where the Amiga panel has 320, so the panel is re-laid out instead of
scaled: every piece of art keeps its pixels 1:1 (energy can, heads, weapon icon and the
seven-segment digits), only the empty space shrinks:
  - digit cells go from 16 to 13 px (1 px of background + the 12 px of segments);
  - the 21 message characters go from 8 to 7 px apart (drawn with colour 0 transparent, so
    the right shadow of a letter shows wherever the next letter leaves it);
  - box frames are rebuilt from their own columns at the new lengths;
  - the heads are copied with the frame pieces they carry, exactly as the game draws them
    (head 0 without its last 4 columns, head 1 whole, its last 3 columns being the left
    frame of the score box), so both faces are identical to the original.
Lines are kept 1:1: HUD = --black blank lines (the line interrupt switches page, scroll and
palette there) followed by panel lines 1..45. The HUD uses the full 256 px, so on MSX2+ the
split turns the left-border mask (MSK) off for it.

Outputs: <out>.sc5 (panel lines 1..45, 128 bytes per line), <out>.pal (16 colours, V9938
format), <out>.png (preview with the black lines), <out>_layout.json (positions of the
dynamic elements in HUD coordinates and the palette mapping, for the run-time drawing).
With --screen LEVEL_PREVIEW.png also <out>_screen.png: a 256x212 frame (play area + HUD).

usage: msxhud.py PERMA.bin MAIN_8000.bin OUT [--black 4] [--screen PNG --at X,Y]
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from planar import decode_indices, write_png  # noqa: E402

PANEL_OFFSET = 0x151D0
PANEL_W, PANEL_LINES = 320, 46          # lines $D0..$FD are displayed
FIRST_LINE = 1                          # panel line 0 is black: the blank lines replace it
COPPER_COLORS = 0x103FA
HUD_W, SCREEN_LINES = 256, 212


def cell(x: int) -> list[int]:
    """A 16 px digit cell at panel x, condensed to 13 px: 1 background column + 12 segment columns."""
    return list(range(x + 1, x + 14))


# Each element: (panel columns in drawing order, first panel line, last panel line).
# The HUD x of an element is where the previous element in its band ended (+ gaps below).
MESSAGE_TEXT = 147                      # 21 characters x 7 px
ELEMENTS = {
    "can": ([*range(2, 29)], 1, 45),
    "message": ([35, 36, 37, 38] + [60] * MESSAGE_TEXT + [210, 211, 212], 1, 16),
    "timer": ([220, 221, 222, 223] + sum((cell(x) for x in (224, 240, 256, 272, 288)), [])
              + [302, 305, 306, 307], 1, 23),
    "weapon": ([39, 40, 41, 42, 43] + sum((cell(x) for x in (48, 64, 80)), []) + [94, 95]
               + [*range(96, 112)] + [112, 118, 119, 120], 16, 44),
    "heads": ([*range(128, 160)] + [*range(160, 189)], 14, 45),
    "score": ([189, 190, 191] + sum((cell(x) for x in range(192, 304, 16)), []) + [302, 308, 309, 310, 311],
              24, 45),
}
# Bands, left to right, with the gap (in px) before each element.
TOP = [("can", 0), ("message", 1), ("timer", 1)]
BOTTOM = [("can", 0), ("weapon", 1), ("heads", 2), ("score", 0)]
DRAW_ORDER = ["message", "timer", "weapon", "score", "heads", "can"]


def layout() -> dict[str, int]:
    """HUD x of every element; both bands must fill exactly 256 px."""
    xs = {}
    for band in (TOP, BOTTOM):
        x = 0
        for name, gap in band:
            x += gap
            if name in xs and xs[name] != x:
                raise ValueError(f"{name} placed at {xs[name]} and {x}")
            xs[name] = x
            x += len(ELEMENTS[name][0])
        if x != HUD_W:
            raise ValueError(f"band {[n for n, _ in band]} is {x} px wide, not {HUD_W}")
    return xs


def compose(panel: list[list[int]]) -> tuple[list[list[int]], dict]:
    xs = layout()
    hud = [[0] * HUD_W for _ in range(PANEL_LINES - FIRST_LINE)]
    for name in DRAW_ORDER:
        cols, y0, y1 = ELEMENTS[name]
        for i, sx in enumerate(cols):
            for y in range(y0, y1 + 1):
                hud[y - FIRST_LINE][xs[name] + i] = panel[y][sx]
    # dynamic elements in HUD coordinates (line 0 = panel line 1)
    timer_x = xs["timer"] + 4
    dyn = {
        "timer_cells": [[timer_x + 13 * k, 6 - FIRST_LINE] for k in (0, 1, 3, 4)],
        "ammo_cells": [[xs["weapon"] + 5 + 13 * k, 23 - FIRST_LINE] for k in range(3)],
        "score_cells": [[xs["score"] + 3 + 13 * k, 29 - FIRST_LINE] for k in range(7)],
        "cell": [13, 16, "panel digit glyph columns 1..13"],
        "message": [xs["message"] + 4, 5 - FIRST_LINE, 7, 21],
        "weapon_icon": [xs["weapon"] + 5 + 39 + 2, 25 - FIRST_LINE],
        "heads": [[xs["heads"], 14 - FIRST_LINE], [xs["heads"] + 32, 14 - FIRST_LINE]],
        "can": [xs["can"] - 2, 3 - FIRST_LINE],
    }
    return hud, dyn


def panel_palette(main: bytes) -> list[int]:
    pal = [0x000]
    for i in range(31):
        reg, val = struct.unpack_from(">HH", main, COPPER_COLORS - 0x8000 + 4 * i)
        if reg != 0x182 + 2 * i:
            raise ValueError(f"unexpected copper MOVE at ${COPPER_COLORS + 4 * i:x}: {reg:#x}")
        pal.append(val)
    return pal


def to_msx(c12: int) -> tuple[int, int, int]:
    return tuple(round(((c12 >> s) & 15) * 7 / 15) for s in (8, 4, 0))  # type: ignore[return-value]


def lab(c: tuple) -> tuple[float, float, float]:
    """3-bit RGB -> CIELAB (D65)."""
    def lin(v):
        v /= 7
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(v) for v in c)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = [t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116 for t in (x, y, z)]
    return 116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])


# HUD palette (MSX 9-bit). The panel uses 25 distinct 9-bit colours; these 16 keep what each
# element needs: the digits' greens and reds, the can's white, two frame greys and, for the
# faces, four helmet blues (down to the near-white highlight) and two skin tones. Panel colours
# map to the nearest entry in CIELAB, except two (HUD_OVERRIDES): the frames' dark inner line
# (COLOR10, 9-bit 111), which would land on the dark helmet blue and is drawn with the frame's
# middle grey instead, and the green digit boxes' background (COLOR03, see below).
HUD_PALETTE = [(0, 0, 0), (0, 1, 0), (0, 2, 0), (0, 3, 0), (1, 0, 0), (2, 0, 0), (5, 0, 0),
               (2, 2, 2), (4, 4, 4), (7, 7, 7), (0, 1, 1), (1, 2, 3), (3, 5, 5), (5, 7, 7),
               (3, 2, 1), (4, 3, 2)]
HUD_OVERRIDES = {10: (2, 2, 2), 3: (0, 0, 0)}
# COLOR03 ($020) is the background of the green digit boxes (and of the weapon icons, which sit
# in one of them). In 9 bits it would be 010, the same as the digits' unlit segments ($030),
# which would vanish; one step up for the unlit segments is too close to the lit ones (030) and
# every digit reads as an 8. The boxes go black instead, so the green digits keep the
# original's order of tones: background 000, unlit segments 010, edges 020, lit 030.


def map_to_palette(img: list[list[int]], pal12: list[int], fixed: list[tuple]) -> list[list[int]]:
    labs = [lab(c) for c in fixed]
    slot = {}
    for v in {v for row in img for v in row}:
        if v in HUD_OVERRIDES:
            slot[v] = fixed.index(HUD_OVERRIDES[v])
            continue
        c = to_msx(pal12[v]) if v else (0, 0, 0)
        L = lab(c)
        slot[v] = min(range(len(fixed)), key=lambda i: sum((p - q) ** 2 for p, q in zip(L, labs[i])))
    return [[slot[v] for v in row] for row in img]


def hud_colours(panel: list[list[int]], pal12: list[int]) -> tuple[list[list[int]], dict]:
    """The HUD of a panel state in HUD palette indices (compose, then map_to_palette)."""
    idx, dyn = compose(panel)
    return map_to_palette(idx, pal12, HUD_PALETTE), dyn


def reduce_colours(img: list[list[int]], pal12: list[int], n: int = 16) -> tuple[list[list[int]], list[tuple]]:
    """Maps panel indices to at most n MSX colours (index 0 = black), merging the closest pairs
    in CIELAB; pixel counts are damped (square root) so that small, distinct details such as
    the heads keep their colours against the large flat areas."""
    count: dict[tuple, int] = {}
    for row in img:
        for v in row:
            c = to_msx(pal12[v]) if v else (0, 0, 0)
            count[c] = count.get(c, 0) + 1
    count.setdefault((0, 0, 0), 0)
    groups = {c: [c] for c in count}
    weight = {c: k ** 0.5 for c, k in count.items()}
    centre = {c: c for c in count}
    while len(groups) > n:
        keys = list(groups)
        best = None
        for i, a in enumerate(keys):
            for b in keys[i + 1:]:
                if (0, 0, 0) in (a, b):
                    continue                    # black stays exact
                d = sum((p - q) ** 2 for p, q in zip(lab(centre[a]), lab(centre[b])))
                cost = d * weight[a] * weight[b] / (weight[a] + weight[b])
                if best is None or cost < best[0]:
                    best = (cost, a, b)
        _, a, b = best
        wa, wb = weight[a], weight[b]
        merged = centre[a] if wa >= wb else centre[b]     # keep an existing colour of the art
        groups[a] += groups.pop(b)
        weight[a] = wa + wb
        centre[a] = merged
    order = [(0, 0, 0)] + sorted((k for k in groups if k != (0, 0, 0)), key=lambda k: -weight[k])
    slot = {}
    for i, k in enumerate(order):
        for member in groups[k]:
            slot[member] = i
    out = [[slot[to_msx(pal12[v]) if v else (0, 0, 0)] for v in row] for row in img]
    return out, [centre[k] for k in order] + [(0, 0, 0)] * (n - len(order))


def read_png_rgb(path: Path) -> tuple[int, int, list[bytes]]:
    """Minimal reader for 8-bit RGB, non-interlaced PNGs (as planar.write_png writes them)."""
    data = path.read_bytes()
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(data):
        ln, tag = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack_from(">IIBB", body)
            if (depth, ctype) != (8, 2):
                raise ValueError(f"{path}: only 8-bit RGB PNGs are supported")
        elif tag == b"IDAT":
            idat += body
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = 3 * w
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - 3] if i >= 3 else 0
            b, c = prev[i], prev[i - 3] if i >= 3 else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("perma", type=Path)
    ap.add_argument("main", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--black", type=int, default=4, help="blank lines before the HUD")
    ap.add_argument("--screen", type=Path, help="level preview PNG (tools/msxconv.py) for a whole-frame mockup")
    ap.add_argument("--at", default="0,600", help="top-left of the play area in the level preview")
    a = ap.parse_args()
    panel = decode_indices(a.perma.read_bytes(), PANEL_OFFSET, PANEL_W, 48, 5, "planes")[:PANEL_LINES]
    idx, dyn = hud_colours(panel, panel_palette(a.main.read_bytes()))
    pal = HUD_PALETTE
    sc5 = bytes((row[x] << 4) | row[x + 1] for row in idx for x in range(0, HUD_W, 2))
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.with_suffix(".sc5").write_bytes(sc5)
    a.out.with_suffix(".pal").write_bytes(bytes(b for r, g, bl in pal for b in ((r << 4) | bl, g)))
    rgb = [tuple(v * 255 // 7 for v in c) for c in pal]
    shown = [[0] * HUD_W for _ in range(a.black)] + idx
    s = 3
    write_png(a.out.with_suffix(".png"), HUD_W * s, len(shown) * s,
              [b"".join(bytes(rgb[v]) * s for v in row) for row in shown for _ in range(s)])
    dyn["palette"] = ["%d%d%d" % c for c in pal]
    dyn["lines"] = len(idx)
    dyn["black"] = a.black
    a.out.with_name(a.out.name + "_layout.json").write_text(json.dumps(dyn, indent=1))
    play = SCREEN_LINES - len(shown)
    print(f"{a.out.with_suffix('.sc5')}: {HUD_W}x{len(idx)} (+{a.black} blank lines); play area {play} lines; "
          "palette " + " ".join(f"{r}{g}{b}" for r, g, b in pal))
    if a.screen:
        w, h, lv = read_png_rgb(a.screen)
        x0, y0 = (int(v) for v in a.at.split(","))
        frame = [lv[y0 + y][3 * x0:3 * (x0 + HUD_W)] for y in range(play)]
        frame += [b"".join(bytes(rgb[v]) for v in row) for row in shown]
        s = 2
        write_png(a.out.with_name(a.out.name + "_screen.png"), HUD_W * s, SCREEN_LINES * s,
                  [b"".join(r[i:i + 3] * s for i in range(0, 3 * HUD_W, 3)) for r in frame for _ in range(s)])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
