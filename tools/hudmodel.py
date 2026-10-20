#!/usr/bin/env python3
"""Model of the Amiga status panel operations and of the MSX HUD built from the panel.

The panel routines (via REA/Ghidra, docs/AMIGA_ANALYSIS.md) all blit into the 5-plane panel
bitmap (320 x 48, PERMA $6DA20):
  - panel_draw_digit ($105D2): a 16x16 digit into planes 0-2 only (planes 3-4, the colour
    bank, stay); timer digits are the red glyphs 12-21, ammo and score the green 0-9;
  - update_energy_can ($89BE): one step of 8 units per call; a full can when the target
    reaches $100; otherwise, from an old level L >= 2 (L = old shown >> 3), an "empty top"
    (32x8, variant by L) at y = 33 - L and the can's own line 39 - L at y = 42 - L;
  - panel_draw_head ($88DE): a 32x34 head at x = 128 + 32 * slot, y 14 (slot 0 without its
    last 4 columns, except for its first 4 lines);
  - panel_draw_icon ($896A): a 16x16 icon at (96, 25), all planes.
The MSX HUD is tools/msxhud.py's 1:1 re-layout of the panel, so any panel state maps to the
HUD with msxhud.compose + map_to_palette. The message line is the exception: on the MSX the
21 characters are 7 px apart instead of 8, drawn with colour 0 transparent (a letter's
column 7, its shadow, shows where the next letter leaves it); text_line() implements that.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import msxhud  # noqa: E402
import panel as panelassets  # noqa: E402
from planar import decode_indices  # noqa: E402

PERMA_LOAD = 0x58850
HEADS, ICONS, ICON_OFFSETS = 0x666D0, 0x676C0, 0xAF76
CAN, CAN_TOPS = 0x661D0, 0x664F0
WEAPON_AMMO, WEAPON_ICON = 0xFD52, 0xFD5A
TIMER_CELLS = [(224, 6), (240, 6), (272, 6), (288, 6)]          # MM tens, MM units, SS tens, SS units
AMMO_CELLS = [(48, 23), (64, 23), (80, 23)]
SCORE_CELLS = [(192 + 16 * k, 29) for k in range(7)]
DIGIT_CELLS = TIMER_CELLS + AMMO_CELLS + SCORE_CELLS            # the 14 cells, red ones first
RED_CELLS = len(TIMER_CELLS)
TEXT_CELLS, TEXT_PITCH, TEXT_LINES = 21, 7, 8
TEXT_PANEL_Y = 5                                                # panel line of the text
SPACE = 41                                                      # font glyph of ' '


def font_index(code: int) -> int:
    """Character code -> font glyph, as panel_draw_char ($10620) maps it."""
    code &= 0x7F
    if code == 0x20:
        return SPACE
    return code - (0x41 if code >= 0x40 else 0x16)


class Panel:
    """The Amiga panel (indices 0..31) plus the operations the game applies to it."""

    def __init__(self, perma: bytes, main: bytes):
        self.main = main
        self.px = decode_indices(perma, msxhud.PANEL_OFFSET, msxhud.PANEL_W, 48, 5, "planes")
        a = panelassets.assets(perma)
        self.digits = a["digits"]
        self.font = a["font"]
        self.can = panelassets.planes(perma, CAN, 32, 40, 5)
        self.tops = [panelassets.planes(perma, CAN_TOPS + 0xA0 * n, 32, 8, 5) for n in range(3)]
        self.heads = [panelassets.planes(perma, HEADS + 0x2A8 * g, 32, 34, 5) for g in range(6)]
        offs = [struct.unpack_from(">H", main, ICON_OFFSETS - 0x8000 + 2 * i)[0] for i in range(8)]
        self.icons = [panelassets.planes(perma, ICONS + o, 16, 16, 5) for o in offs]
        self.pal12 = msxhud.panel_palette(main)

    def copy(self) -> "Panel":
        p = Panel.__new__(Panel)
        p.__dict__.update(self.__dict__)
        p.px = [row[:] for row in self.px]
        return p

    def blit(self, src: list[list[int]], x: int, y: int, cols: range | None = None):
        for j, row in enumerate(src):
            if 0 <= y + j < len(self.px):
                for i in cols if cols is not None else range(len(row)):
                    self.px[y + j][x + i] = row[i]

    def digit(self, cell: int, value: int):
        x, y = DIGIT_CELLS[cell]
        g = self.digits[value + (12 if cell < RED_CELLS else 0)]
        for j in range(16):
            for i in range(16):
                self.px[y + j][x + i] = (self.px[y + j][x + i] & 0x18) | g[j][i]

    def can_full(self):
        self.blit(self.can, 0, 3)

    def can_step(self, old_shown: int):
        """Drawing of one update_energy_can step from the old shown level (target < $100)."""
        if old_shown < 0x10:
            return
        level = old_shown >> 3
        top = 0 if level > 23 else (1 if level > 12 else 2)
        self.blit(self.tops[top], 0, 33 - level)
        self.blit([self.can[39 - level]], 0, 42 - level)

    def can_level(self, level: int):
        """The can as the game leaves it at a level reached by going down from full (the energy
        only drops step by step or refills to full)."""
        self.can_full()
        for old in range(32, level, -1):
            self.can_step(old << 3)

    def head(self, graphic: int, slot: int):
        x = 128 + 32 * slot
        g = self.heads[graphic]
        self.blit(g, x, 14, range(28) if slot == 0 else None)
        if slot == 0:
            self.blit(g[:4], x, 14)

    def icon(self, index: int):
        self.blit(self.icons[index], 96, 25)

    def weapon_icon(self, weapon: int) -> int:
        return struct.unpack_from(">H", self.main, WEAPON_ICON - 0x8000 + 2 * weapon)[0]

    def weapon_ammo(self, weapon: int) -> int:
        return struct.unpack_from(">H", self.main, WEAPON_AMMO - 0x8000 + 2 * weapon)[0]

    def hud(self) -> list[list[int]]:
        """MSX HUD colour indices (45 lines x 256) of the current panel."""
        return msxhud.hud_colours(self.px, self.pal12)[0]

    def glyph_colours(self) -> list[list[list[int]]]:
        """Font glyphs in HUD colour indices (0 = background, i.e. transparent)."""
        m = msxhud.map_to_palette([[v for g in self.font for row in g for v in row]], self.pal12,
                                  msxhud.HUD_PALETTE)[0]
        n = 0
        out = []
        for g in self.font:
            rows = []
            for row in g:
                rows.append(m[n:n + len(row)])
                n += len(row)
            out.append(rows)
        return out


def text_x() -> int:
    return msxhud.compose([[0] * msxhud.PANEL_W] * msxhud.PANEL_LINES)[1]["message"][0]


def text_line(glyphs: list[list[list[int]]], cells: list[int], hud: list[list[int]]):
    """Draws the 21 message cells (font glyph indices) into the HUD (MSX rule, see the module
    docstring): pixel i (0..6) of cell c is the glyph's own pixel unless it is 0; pixel 0 then
    shows the previous cell's column 7. The last cell's column 7 would fall on the frame."""
    x0, y0 = text_x(), TEXT_PANEL_Y - msxhud.FIRST_LINE
    for y in range(TEXT_LINES):
        for c in range(TEXT_CELLS):
            g = glyphs[cells[c]][y]
            for i in range(TEXT_PITCH):
                v = g[i]
                if v == 0 and i == 0 and c > 0:
                    v = glyphs[cells[c - 1]][y][7]
                hud[y0 + y][x0 + TEXT_PITCH * c + i] = v
