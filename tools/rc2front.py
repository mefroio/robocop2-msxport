#!/usr/bin/env python3
"""Front end of Robocop 2 (Amiga): text scripts, particle texts, high scores, fonts and the
title logo, decoded from the composite RAM image as the game code reads them (routines read
with REA/Ghidra; see docs/AMIGA_ANALYSIS.md, "Front end: title, text screens, high scores").

Text script (interpreter $116CA, pointer $10F2C, one element per call = per VBL):
  00 x y     cursor to column x ($16C9), row y (signed; $16CA = 8y)
  01..7F     one character of the 8x8 font ($118D6) at bitplane (16 + 8x, 67 + 8y), x + 1
  80..FF c   command c through the BRA table $11746 (the prefix byte's value is ignored):
             0 halt with the blinking cursor  1 diagonal wipe of rows 0-12 (38 calls)
             2 n wait max(1, 4n) calls       3 run the particle writer until it is done
             4 p particle set-up: entry p/12 of $11804 (colour set, text, origin)
             5 restart the attract script $11237   6 halt   7 set "done" ($16D1) and halt
Particle text ($10F40; 24 particles of $56 bytes at $DB4, stroke font $109C6):
  0D new line (x = 0, y + 16)   20 x + 16   other < 80: glyph code - 'A' at (x, y), x + 16
  FE i v byte $10F38 + i = v (nothing reads it)   FF 00 end   FF n colour set $10F04 + 6(n - 1)

Outputs (OUTDIR, default build/front):
  scripts.json     every script and particle text, decoded, with call counts
  hiscores.json    the default high-score table ($11FF6), its format and the name-entry keys
  font.json        8x8 bitmap font ($65DB0, PERMA) and stroke font ($109C6)
  font.png         bitmap font sheet (x4); font_strokes.png stroke font sheet (x4)
  title.json       logo fly-in ($106E2): RB1 letters, countdown and positions per frame
  screens/*.png    each screen as the code leaves it (304 x 176 bitplane area, text palette)

usage: rc2front.py [RAM_IMAGE] [OUTDIR]
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amigahw import rgb12_to_rgb24  # noqa: E402
from planar import write_png  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]

# --- addresses (Amiga RAM; all read in the code with REA/Ghidra) -------------------------
ATTRACT = 0x11237          # attract script (title loop $10884, command 5 target)
CMD_TABLE = 0x11746        # 8 BRA entries, 4 bytes each
PARTICLE_SETUPS = 0x11804  # command 4: 8 x [colour set.l][text.l][x.w][y.w]
COLOUR_SETS = 0x10EF8      # 3 words: head, final (11th position back), middle (6th back)
COLOUR_SET_FF = 0x10F04    # particle text FF n -> COLOUR_SET_FF + 6 (n - 1)
STROKE_FONT = 0x109C6      # 36 glyphs x 16 (x, y) byte points; 'A' overlaps COLOR16-31
STROKE_GLYPHS = 36
BITMAP_FONT = 0x65DB0      # 44 glyphs x 24 bytes (3 planes x 8 lines), PERMA
BITMAP_GLYPHS = 44
TEXT_PALETTE = 0x109A8     # COLOR01-15 of the title and the text screens ($F8C6 immediate)
HISCORE_TEXT = 0x11FF6     # particle text: header line + 6 entries of 19 bytes + FF 00
HISCORE_FIRST = 0x12006
HISCORE_ENTRY = 19
HISCORE_COUNT = 6
KEY_CHARS = 0x12296        # name entry: character per key (50 bytes)
KEY_CODES = 0x122C8        # name entry: raw key codes, FF-terminated
CHEATS = 0x11F36           # [sequence.l][handler.l] ... FFFFFFFF
LOGO = 0x10682             # 8 x [x off.w][y off.w], 8 x [x0.w][BLTSIZE.w], 8 x [graphics.l]
LOGO_TM = 0x1254E          # 5 words ORed into plane 2 at byte $1F50 of the front buffer
GUN_TABLES = 0xC716        # 4 x 8 bytes: enemy hit points per class ($8060), SHARP..POOR
RATING_TEXT = 0x1140D      # 4 x 8 characters: POOR, FAIR, GOOD, SHARP

LINE = 0x98                # 152 bytes per line: 4 interleaved planes of 38 bytes
PLANE = 0x26
LINES = 192                # one display buffer ($7200 bytes)
TEXT_BASE = 2 + 64 * LINE  # $109A2 = front buffer + 2 + $2600
VISIBLE = (176, 304)       # buffer lines 0-175 shown (display lines $1E-$CD), 38 bytes fetched

GLYPH_NAMES = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,?\"! ©%"
COMMANDS = {0: "halt_cursor", 1: "wipe", 2: "wait", 3: "particles_run", 4: "particles_setup",
            5: "restart_attract", 6: "halt", 7: "done"}
HALTS = (0, 5, 6, 7)

# start, name, how the screen is entered (code addresses), notes
SCRIPTS = [
    (ATTRACT, "attract", "title loop $10884 (after the logo fly-in), one element per frame",
     "loops through command 5"),
    (0x11108, "briefing_level1", "load_level0 $82EC and restart_level0 $8352 (lives = 2) "
     "through the curtain entry $1079A", "then PIC1"),
    (0x110F0, "briefing_level2", "load_level1 $8582 through $10762", "then PIC4"),
    (0x110B4, "briefing_level3", "load_level2 $8524 through $10762", "then PIC7"),
    (0x1132F, "level_statistics", "show_level_stats $85D8 through $10762",
     "numbers patched at $1135A/$11379/$11398 from $16C2/$16C0/$16BE"),
    (0x114AA, "brainstorm_intro", "$8382 through $10762", "then PIC3 (after level 1) or PIC5"),
    (0x1162F, "brainstorm_success", "$8382, result 0 (table $840A)", "$805E + 1 (a continue)"),
    (0x11667, "brainstorm_failed", "$8382, result 1 (table $840A)", ""),
    (0x11698, "out_of_time", "$8382 result 2 (table $840A); $8420 when $804C (time out)", ""),
    (0x1142D, "shooting_range_intro", "$8420 through $10762", "then PIC2 (after level 1) or PIC6"),
    (0x113A5, "gun_calibration", "$8420 through $10762",
     "numbers patched at $113CA/$113E4, rating text copied to $11400"),
    (0x112C5, "game_completed", "level_load_3 $86DE through $10762", "then PICF + CMP ($11C54)"),
    (0x1151B, "cheat_mode", "cheat handler $11F60 through $10772", "CH1 tune 1 plays"),
    (0x11590, "continue", "$11FD2 through $10768", "fire at its end = continue"),
    (0x115C9, "high_score", "$1215C through $10768", "the name is drawn by $12218"),
    (0x116C2, "disk_prompt", "$11BD2 through $10762", "no caller in the image (dead code)"),
]

# fields written into the scripts at run time (8 characters unless noted)
PATCHED = [
    (0x1135A, 8, "show_level_stats $85D8: $16C2 henchmen obliterated ($11DC6)"),
    (0x11379, 8, "show_level_stats $85D8: $16C0 nukes collected ($11DC6)"),
    (0x11398, 8, "show_level_stats $85D8: $16BE hostages rescued ($11DC6)"),
    (0x113CA, 8, "$8420: D1 returned by FRNG = correct targets ($11DC6)"),
    (0x113E4, 8, "$8420: D0 returned by FRNG = dummy targets ($11DC6)"),
    (0x11400, 8, "$8420: rating text from $1140D + 8 x rating"),
    (0x11211, 1, "$11BD2: '[' + disk number (the 'Z' of DISK Z)"),
    (0x12066, 9, "high_score_entry $12082: name of the 6th entry (spaces, then typed)"),
    (0x12070, 7, "high_score_entry $12082: score of the 6th entry (new score)"),
]


def hexa(a: int) -> str:
    return f"${a:X}"


def u16(ram: bytes, a: int) -> int:
    return struct.unpack_from(">H", ram, a)[0]


def s16(ram: bytes, a: int) -> int:
    return struct.unpack_from(">h", ram, a)[0]


def u32(ram: bytes, a: int) -> int:
    return struct.unpack_from(">I", ram, a)[0]


def bitmap_glyph(code: int) -> int:
    """$118D6 / $10620: ' ' -> 41, codes >= '@' -> code - 'A', others -> code - $16."""
    code &= 0x7F
    if code == 0x20:
        return 41
    return code - 0x41 if code >= 0x40 else code - 0x16


def bitmap_char(code: int) -> str:
    g = bitmap_glyph(code)
    return GLYPH_NAMES[g] if 0 <= g < BITMAP_GLYPHS else "�"


def stroke_char(code: int) -> str:
    g = code - 0x41
    if 0 <= g < 26:
        return chr(code)
    if 26 <= g < STROKE_GLYPHS:
        return chr(0x30 + g - 26)
    return "�"


def text_palette(ram: bytes) -> list[tuple[int, int, int]]:
    """COLOR00 (0) + COLOR01-15, each component at most E (fade level $1F/$1D: $F8C4)."""
    pal = [(0, 0, 0)]
    for i in range(15):
        c = u16(ram, TEXT_PALETTE + 2 * i)
        c = min(c >> 8 & 15, 14) << 8 | min(c >> 4 & 15, 14) << 4 | min(c & 15, 14)
        pal.append(rgb12_to_rgb24(c))
    return pal


# --- display buffer model ----------------------------------------------------------------
class Screen:
    """One interleaved 4-plane buffer (152 bytes per line) with margins for stray writes."""

    MARGIN = 64 * LINE

    def __init__(self) -> None:
        self.mem = bytearray(self.MARGIN * 2 + LINES * LINE)

    def poke(self, off: int, value: int) -> None:
        self.mem[self.MARGIN + off] = value & 0xFF

    def peek(self, off: int) -> int:
        return self.mem[self.MARGIN + off]

    def draw_char(self, ram: bytes, base: int, off: int, code: int) -> None:
        """$118D6: 3 planes x 8 lines of glyph bytes (move.b, planes 0-2 only)."""
        g = BITMAP_FONT + 24 * bitmap_glyph(code)
        a = base + off
        for p in range(3):
            for y in range(8):
                self.poke(a + y * LINE, ram[g + 8 * p + y])
            a += PLANE

    def plot(self, x: int, y: int, colour: int) -> None:
        """$11062 with the origin already added: 4 planes, pixel set to the colour."""
        if ((y - 0xA0) & 0xFFFF) < 0x8000:     # cmpi.w #$A0 / bpl: y >= 160 skipped
            return
        line = ((y & 0xFFFF) * LINE) & 0xFFFF
        line = line - 0x10000 if line & 0x8000 else line
        a = TEXT_BASE + line + ((x & 0xFFFF) >> 3)
        bit = 0x80 >> (x & 7)
        for p in range(4):
            v = self.peek(a) & ~bit
            if colour >> p & 1:
                v |= bit
            self.poke(a, v)
            a += PLANE

    def pixel(self, x: int, y: int) -> int:
        a = y * LINE + (x >> 3)
        return sum(1 << p for p in range(4) if self.peek(a + p * PLANE) & (0x80 >> (x & 7)))

    def png(self, path: Path, pal: list[tuple[int, int, int]], scale: int = 2) -> None:
        h, w = VISIBLE
        rows = []
        for y in range(h):
            row = bytearray()
            for x in range(w):
                row += bytes(pal[self.pixel(x, y)]) * scale
            rows += [bytes(row)] * scale
        write_png(path, w * scale, h * scale, rows)


# --- particle writer model ($11870, $10FC8, $10F40, $10E46, $10E84) ----------------------
class Particles:
    def __init__(self, ram: bytes, scr: Screen) -> None:
        self.ram, self.scr = ram, scr
        self.colours, self.text, self.x, self.y, self.count = 0, 0, 0, 0, 0
        self.p: list[dict] = []
        self.pokes: list[tuple[int, int]] = []

    def setup(self, entry: int) -> dict:
        """Command 4: clears the 24 particles and loads entry p/12 of $11804."""
        a = PARTICLE_SETUPS + entry
        self.colours, self.text = u32(self.ram, a), u32(self.ram, a + 4)
        self.x, self.y = s16(self.ram, a + 8), s16(self.ram, a + 10)
        self.p = [dict(state=0, cptr=0, ox=0, oy=0, pts=0, idx=0, x=0, y=0, vx=0, vy=0,
                       tx=0, ty=0, hist=[(0, 0)] * 12) for _ in range(24)]
        return dict(colour_set=hexa(self.colours), text=hexa(self.text), x=self.x, y=self.y)

    def colour(self, cptr: int, k: int) -> int:
        return u16(self.ram, cptr + 2 * k)

    def step(self) -> bool:
        """One call of command 3; True when it advances (all 24 particles idle at the end)."""
        if self.count == 24:
            self.count = 0
            return True
        self.count = 0
        for p in self.p:
            self.update(p)
        return False

    def update(self, p: dict) -> None:
        a4 = p["cptr"]                          # loaded before a spawn changes it
        if p["state"] == 0:
            if not self.spawn(p):
                return
        elif p["state"] & 0x80:
            x, y = p["x"] >> 16, p["y"] >> 16
            p["hist"][11] = (x & 0xFF, y & 0xFF)
            self.scr.plot(x + p["ox"], y + p["oy"], self.colour(a4, 0))
            if (x & 0xFFFF, y & 0xFFFF) == (p["tx"], p["ty"]):
                self.arrived(p)
            else:
                p["x"], p["y"] = self.wrap(p["x"] + p["vx"]), self.wrap(p["y"] + p["vy"])
        else:
            p["state"] -= 1
        h = p["hist"]
        h[0:11] = h[1:12]
        self.scr.plot(h[5][0] + p["ox"], h[5][1] + p["oy"], self.colour(a4, 2))
        self.scr.plot(h[0][0] + p["ox"], h[0][1] + p["oy"], self.colour(a4, 1))

    @staticmethod
    def wrap(v: int) -> int:
        v &= 0xFFFFFFFF
        return v - (1 << 32) if v & 0x80000000 else v

    def spawn(self, p: dict) -> bool:
        a = self.text
        while True:
            ox, oy = self.x, self.y
            b = self.ram[a]
            a += 1
            if b < 0x80:
                if b == 0x0D:
                    self.x, self.y = 0, self.y + 16
                    continue
                self.text = a
                self.x += 16
                if b == 0x20:
                    return False
                off = ((b - 0x41) * 32) & 0xFFFF
                off = off - 0x10000 if off & 0x8000 else off
                p.update(state=0xFF, cptr=self.colours, ox=ox, oy=oy, pts=STROKE_FONT + off)
                p["hist"] = [(self.ram[p["pts"]], self.ram[p["pts"] + 1])] * 12
                p["idx"] = 0
                self.arrived(p)
                return True
            if (-b) & 0xFF == 2:
                self.pokes.append((0x10F38 + self.ram[a], self.ram[a + 1]))
                a += 2
                continue
            n = self.ram[a]
            a += 1
            if n == 0:
                self.count += 1
                return False
            self.colours = COLOUR_SET_FF + 6 * (n - 1)

    def arrived(self, p: dict) -> None:
        i, pts = p["idx"], p["pts"]
        if i >= 30:
            p["state"] = 10
            return
        x0, y0 = self.ram[pts + i], self.ram[pts + i + 1]
        i += 2
        p["idx"] = i
        p["tx"], p["ty"] = self.ram[pts + i], self.ram[pts + i + 1]
        p["x"], p["y"] = x0 << 16, y0 << 16
        dx, dy = (p["tx"] << 16) - p["x"], (p["ty"] << 16) - p["y"]
        while True:
            dx >>= 1
            dy >>= 1
            if abs(dx) < 0x10000 and abs(dy) < 0x10000:
                break
        p["vx"], p["vy"] = dx, dy


# --- text script interpreter model ($116CA) ----------------------------------------------
class Interpreter:
    def __init__(self, ram: bytes, scr: Screen | None = None) -> None:
        self.ram = ram
        self.scr = scr or Screen()
        self.parts = Particles(ram, self.scr)
        self.col = self.row = self.counter = 0

    def run(self, start: int, stop_at: int | None = None) -> tuple[list[dict], int]:
        """Decodes the script from start up to its halting command (inclusive), executing it on
        the screen; returns the elements (with call counts) and the address after the halt."""
        a, out = start, []
        while True:
            if stop_at is not None and a == stop_at:
                return out, a
            b = self.ram[a]
            if b == 0:
                self.col, self.row = self.ram[a + 1], struct.unpack_from("b", self.ram, a + 2)[0]
                out.append(dict(address=hexa(a), op="position", col=self.col, row=self.row,
                                x=16 + 8 * self.col, y=67 + 8 * self.row, calls=1))
                a += 3
            elif b < 0x80:
                s = a
                while 0 < self.ram[a] < 0x80:
                    off = (3 + 8 * self.row) * LINE + self.col
                    self.scr.draw_char(self.ram, TEXT_BASE, off, self.ram[a])
                    self.col += 1
                    a += 1
                raw = self.ram[s:a]
                out.append(dict(address=hexa(s), op="text", raw=raw.decode("latin-1"),
                                text="".join(bitmap_char(c) for c in raw),
                                glyphs=[bitmap_glyph(c) for c in raw], calls=len(raw)))
            else:
                c = self.ram[a + 1]
                e = dict(address=hexa(a), op="command", prefix=b, cmd=c,
                         name=COMMANDS.get(c, "undefined"))
                if c in (2, 4):
                    e["param"] = self.ram[a + 2]
                size = 3 if c in (2, 4) else 2
                if c == 1:
                    for t in range(37):
                        for r in range(12, -1, -1):
                            off = r * 0x4C0 + 0x1C8 + r + t - 4
                            self.scr.draw_char(self.ram, TEXT_BASE, off, 0x20)
                    self.col = self.row = 0
                    e["calls"] = 38
                elif c == 2:
                    e["calls"] = max(1, 4 * e["param"])
                elif c == 4:
                    e.update(self.parts.setup(e["param"]), entry=e["param"] // 12, calls=1)
                    self.col = self.row = 0
                elif c == 3:
                    n = 1
                    while not self.parts.step():
                        n += 1
                    e["calls"] = n
                else:
                    e["calls"] = 0
                out.append(e)
                a += size
                if c in HALTS:
                    return out, a


def decode_particle_text(ram: bytes, a: int) -> tuple[list[dict], int]:
    out, s = [], a
    while True:
        b = ram[a]
        if b >= 0x80:
            if (-b) & 0xFF == 2:
                out.append(dict(address=hexa(a), op="poke", target=hexa(0x10F38 + ram[a + 1]),
                                value=ram[a + 2], note="no reader of $10F38-$10F3F"))
                a += 3
                continue
            n = ram[a + 1]
            if n == 0:
                out.append(dict(address=hexa(a), op="end"))
                return out, a + 2 - s
            out.append(dict(address=hexa(a), op="colour_set", set=n,
                            colours=hexa(COLOUR_SET_FF + 6 * (n - 1))))
            a += 2
            continue
        ln = a
        while ram[a] < 0x80 and ram[a] != 0x0D:
            a += 1
        if a > ln:
            raw = ram[ln:a]
            out.append(dict(address=hexa(ln), op="line", raw=raw.decode("latin-1"),
                            text="".join(stroke_char(c) if c != 0x20 else " " for c in raw)))
        if ram[a] == 0x0D:
            out.append(dict(address=hexa(a), op="newline"))
            a += 1


# --- outputs -------------------------------------------------------------------------------
def scripts_json(ram: bytes, out: Path, pal: list) -> dict:
    scripts = []
    shots = out / "screens"
    for start, name, entered, note in SCRIPTS:
        it = Interpreter(ram)
        if name == "attract":
            draw_logo(ram, it.scr)
            first, a = it.run(start, stop_at=0x112B4)     # credits typed (before FF 02 30)
            it.scr.png(shots / "attract_credits.png", pal)
            second, a2 = it.run(a, stop_at=0x112BE)       # wipe, high-score table drawn
            it.scr.png(shots / "attract_hiscores.png", pal)
            third, end = it.run(a2)                       # table erased, command 5
            elements = first + second + third
        else:
            elements, end = it.run(start)
            if name == "high_score":                      # $1215C/$12218: empty name field
                for i in range(9):
                    it.scr.draw_char(ram, 0, 10 * 0x4C0 + 16 + i, 0x67 if i == 1 else 0x20)
            it.scr.png(shots / f"{name}.png", pal)
        calls = sum(e.get("calls", 0) for e in elements)
        d = dict(address=hexa(start), end=hexa(end), name=name, entered_by=entered, note=note,
                 calls=calls)
        if name != "attract":   # $1084C loop: ends when (fire or done) and 50 VBLs have passed
            d["vbls_without_fire"] = max(calls + 1, 50) + (16 if "curtain" in entered else 0)
        d["elements"] = elements
        scripts.append(d)
    gun = [dict(address=hexa(GUN_TABLES + 8 * k), rating=["SHARP", "GOOD", "FAIR", "POOR"][k],
                hit_points=list(ram[GUN_TABLES + 8 * k:GUN_TABLES + 8 * k + 8])) for k in range(4)]
    particles = []
    for k in range(8):
        a = PARTICLE_SETUPS + 12 * k
        cs, tx = u32(ram, a), u32(ram, a + 4)
        elements, size = decode_particle_text(ram, tx)
        it = Interpreter(ram)
        it.parts.setup(12 * k)
        n = 1
        while not it.parts.step():
            n += 1
        particles.append(dict(entry=k, param=12 * k, table=hexa(a), colour_set=hexa(cs),
                              colours=dict(zip(("head", "final", "middle"),
                                               (u16(ram, cs + 2 * i) for i in range(3)))),
                              text=hexa(tx), size=size, origin=[s16(ram, a + 8), s16(ram, a + 10)],
                              bitplane_origin=[16 + s16(ram, a + 8), 64 + s16(ram, a + 10)],
                              calls=n, elements=elements))
    sets = [dict(address=hexa(COLOUR_SETS + 6 * k), ff_n=k - 1 if k >= 2 else None,
                 head=u16(ram, COLOUR_SETS + 6 * k), final=u16(ram, COLOUR_SETS + 6 * k + 2),
                 middle=u16(ram, COLOUR_SETS + 6 * k + 4)) for k in range(8)]
    cmds = []
    for c in range(8):
        a = CMD_TABLE + 4 * c
        w = u16(ram, a)
        tgt = a + 2 + (s16(ram, a + 2) if w == 0x6000 else ((w & 0xFF) ^ 0x80) - 0x80)
        cmds.append(dict(cmd=c, name=COMMANDS[c], entry=hexa(a),
                         handler=hexa(tgt) if w >> 8 == 0x60 else hexa(a) + " (inline)"))
    return dict(
        source="build/ram/level1_full.bin",
        interpreter=dict(routine="$116CA", pointer="$10F2C", table=hexa(CMD_TABLE), commands=cmds,
                         text_origin="bitplane (16 + 8 col, 67 + 8 row), front buffer + 2 + $2600",
                         cursor="$118B4: lines 6-7 of the next cell, plane 0 $7F, plane 1 $63; "
                                "drawn when bit 2 of $B01 is set, erased every call"),
        particle_writer=dict(routines=["$11870", "$10FC8", "$10F40", "$10E46", "$10E84",
                                       "$11062"],
                             particles=24, record=86, array="$DB4-$15C3",
                             colour_sets=sets, setups=particles),
        patched_fields=[dict(address=hexa(a), length=n, writer=w) for a, n, w in PATCHED],
        gun_calibration=dict(variable="$8060", read_at=["$C512", "$C706"],
                             meaning="hit points (+$21 of the slot) of a spawned enemy, indexed by "
                                     "the word at +4 of its type descriptor ($BEB4 + 16 type)",
                             level1="$C716 (load_level0)", time_out="$C72E", tables=gun,
                             rating="max(0, min(3, (6 correct - dummy - 50 - 12 [minutes = 0]) "
                                    "div 14)); table $C716 + 24 - 8 rating"),
        scripts=scripts)


def hiscores_json(ram: bytes) -> dict:
    entries = []
    for i in range(HISCORE_COUNT):
        a = HISCORE_FIRST + HISCORE_ENTRY * i
        name = ram[a + 1:a + 10].decode("latin-1")
        score = ram[a + 11:a + 18]
        digits = "".join(str(c - 0x5B) for c in score)
        entries.append(dict(rank=i + 1, address=hexa(a), name=name.rstrip(), name_field=name,
                            score=int(digits), score_digits=digits,
                            score_raw=score.decode("latin-1")))
    codes = []
    a = KEY_CODES
    while ram[a] != 0xFF:
        ch = ram[KEY_CHARS + a - KEY_CODES]
        codes.append(dict(raw_key=f"${ram[a]:02X}", char=f"${ch:02X}",
                          meaning={0x20: "space", 0x7F: "delete", 0x0D: "return"}.get(
                              ch, stroke_char(ch) if ch >= 0x5B else chr(ch))))
        a += 1
    cheats = []
    a = CHEATS
    while not u32(ram, a) & 0x80000000:
        seq, handler = u32(ram, a), u32(ram, a + 4)
        n = ram[seq + 1]
        cheats.append(dict(sequence=hexa(seq), handler=hexa(handler),
                           raw_keys=[f"${k:02X}" for k in ram[seq + 2:seq + 2 + n]],
                           keys="".join(next((c["meaning"] for c in codes if int(c["raw_key"][1:], 16) == k),
                                             "?") for k in ram[seq + 2:seq + 2 + n])))
        a += 8
    return dict(
        table=hexa(HISCORE_TEXT),
        header=ram[HISCORE_TEXT:HISCORE_FIRST - 1].decode("latin-1"),
        entry_format="19 bytes: ' ', name (9, A-Z, space, digits '['-'d'), ' ', score (7 digits "
                     "as '['-'d' = 0-9), CR; the table ends with FF 00 at $12078",
        entries=entries,
        display="particle text 0 (colours 7/4/8), 16 x 16 px per character: the header line from "
                "bitplane (32, 64), each entry line from x 16 (CR: x = 0, y + 16); drawn by the "
                "attract script, then erased by particle text 1 (colours 8/0/7)",
        insertion="high_score_entry $12082: the score $8046 as 8 digits '['-'d' at $1207A; the low "
                  "7 must be greater than entry 6 ($12070); then entry 6 = new score and 9 spaces, "
                  "HI1 loaded ($12300, tune 1, stopped again by $FE14), name typed ($1215C), 24 "
                  "bubble passes over the 6 entries (swap 18 bytes when the upper score is lower)",
        name_entry=dict(screen="script $115C9 (high_score)", field="$12066, 9 characters",
                        drawn_at="bitplane x 128 + 8i, lines 80-87 ($12218: front buffer, $118CE)",
                        cursor="'g' = glyph 38 '?', first shown under the 2nd character",
                        keys=codes, effects="key: sound effect 3, return: effect 4 ($18014)"),
        cheats=cheats,
    )


def font_json(ram: bytes) -> dict:
    glyphs = []
    for g in range(BITMAP_GLYPHS):
        o = BITMAP_FONT + 24 * g
        rows = ["".join(str(sum(1 << p for p in range(3) if ram[o + 8 * p + y] & (0x80 >> x)))
                        for x in range(8)) for y in range(8)]
        glyphs.append(dict(index=g, char=GLYPH_NAMES[g], address=hexa(o),
                           codes=[f"${c:02X}" for c in range(0x20, 0x80) if bitmap_glyph(c) == g],
                           rows=rows))
    strokes = []
    for g in range(STROKE_GLYPHS):
        o = STROKE_FONT + 32 * g
        code = 0x41 + g
        strokes.append(dict(index=g, char=stroke_char(code), code=f"${code:02X}", address=hexa(o),
                            points=[[ram[o + 2 * i], ram[o + 2 * i + 1]] for i in range(16)]))
    return dict(
        bitmap=dict(address=hexa(BITMAP_FONT), glyphs=BITMAP_GLYPHS, cell=[8, 8], planes=3,
                    format="24 bytes per glyph: plane 0 lines 0-7, plane 1, plane 2 (1 bit per "
                           "pixel, MSB left); drawn with move.b into planes 0-2 (plane 3 kept)",
                    mapping="' ' -> 41; codes >= '@' -> code - 'A'; other codes -> code - $16 "
                            "(so '0'-'9' and '['-'d' are digits, 'e'-'l' and ':'-'?' punctuation; "
                            "'@' reads the 24 $FF bytes before the font: a colour-7 block)",
                    used_by=["text scripts $118D6", "panel messages $10620", "name entry $12218"],
                    glyph_rows=glyphs),
        stroke=dict(address=hexa(STROKE_FONT), glyphs=STROKE_GLYPHS, points=16, grid=[14, 14],
                    cell=[16, 16],
                    format="32 bytes per glyph: 16 (x, y) byte points, a polyline of 15 segments "
                           "traced by one particle; glyph = code - 'A' ('A'-'Z', '['-'d' = 0-9)",
                    note="glyph 'A' occupies $109C6-$109E5, i.e. COLOR16-31 of the text palette",
                    glyphs_points=strokes))


def font_pngs(ram: bytes, out: Path, pal: list) -> None:
    s, cols = 4, 11
    rows_n = (BITMAP_GLYPHS + cols - 1) // cols
    w, h = cols * 9 + 1, rows_n * 9 + 1
    img = [[(40, 40, 60)] * w for _ in range(h)]
    for g in range(BITMAP_GLYPHS):
        o = BITMAP_FONT + 24 * g
        bx, by = 1 + 9 * (g % cols), 1 + 9 * (g // cols)
        for y in range(8):
            for x in range(8):
                c = sum(1 << p for p in range(3) if ram[o + 8 * p + y] & (0x80 >> x))
                img[by + y][bx + x] = pal[c]
    write_png(out / "font.png", w * s, h * s,
              [b"".join(bytes(px) * s for px in row) for row in img for _ in range(s)])
    cols, cell = 12, 17
    rows_n = (STROKE_GLYPHS + cols - 1) // cols
    w, h = cols * cell + 1, rows_n * cell + 1
    img = [[(40, 40, 60)] * w for _ in range(h)]
    for g in range(STROKE_GLYPHS):
        o = STROKE_FONT + 32 * g
        bx, by = 1 + cell * (g % cols), 1 + cell * (g // cols)
        for y in range(16):
            for x in range(16):
                img[by + y][bx + x] = (0, 0, 0)
        pts = [(ram[o + 2 * i], ram[o + 2 * i + 1]) for i in range(16)]
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            n = max(abs(x1 - x0), abs(y1 - y0), 1)
            for t in range(n + 1):
                x, y = x0 + (x1 - x0) * t // n, y0 + (y1 - y0) * t // n
                if 0 <= x < 16 and 0 <= y < 16:
                    img[by + y][bx + x] = pal[4]
    write_png(out / "font_strokes.png", w * s, h * s,
              [b"".join(bytes(px) * s for px in row) for row in img for _ in range(s)])


def logo_frames(ram: bytes) -> list[int]:
    """$106E2 countdown: L = $880000; per frame L -= L >> 4 (1.0 when that is 0), t = L >> 16;
    the loop ($10884) stops at t = 0, which is not drawn."""
    L, ts = 0x880000, []
    while True:
        d = L >> 4
        L -= d if d else 0x10000
        t = L >> 16
        ts.append(t)
        if t == 0:
            return ts


def logo_letters(ram: bytes) -> list[dict]:
    out = []
    for i in range(8):
        xo, yo = s16(ram, LOGO + 4 * i), s16(ram, LOGO + 4 * i + 2)
        x0, bs = s16(ram, LOGO + 0x20 + 4 * i), u16(ram, LOGO + 0x22 + 4 * i)
        out.append(dict(index=i, x0=x0, x_off=xo, y_off=yo, bltsize=f"${bs:04X}",
                        width=((bs & 63) - 1) * 16, height=bs >> 6,
                        graphics=hexa(u32(ram, LOGO + 0x40 + 4 * i))))
    return out


def logo_pos(letter: dict, t: int) -> tuple[int, int]:
    x0 = letter["x0"]
    d = ((0x118 - x0) * t) >> 5
    return x0 - d + letter["x_off"] - 128, t + letter["y_off"]


def draw_logo(ram: bytes, scr: Screen, t: int | None = None) -> None:
    """The logo as the title shows it after the fly-in (last drawn countdown) and the TM mark."""
    if t is None:
        t = logo_frames(ram)[-2]
    for L in logo_letters(ram):
        x, y = logo_pos(L, t)
        wb, h = L["width"] // 8, L["height"]
        g = int(L["graphics"][1:], 16)
        for yy in range(h):
            for xx in range(L["width"]):
                if not ram[g + yy * wb + (xx >> 3)] & (0x80 >> (xx & 7)):
                    continue
                c = sum(1 << p for p in range(4)
                        if ram[g + (p + 1) * wb * h + yy * wb + (xx >> 3)] & (0x80 >> (xx & 7)))
                px, py = x + xx, y + yy
                if 14 <= px < 304 and 0 <= py < 177:
                    a = py * LINE + (px >> 3)
                    bit = 0x80 >> (px & 7)
                    for p in range(4):
                        v = scr.peek(a + p * PLANE) & ~bit
                        scr.poke(a + p * PLANE, v | (bit if c >> p & 1 else 0))
    for k in range(5):
        w = u16(ram, LOGO_TM + 2 * k)
        a = 0x1F50 + k * LINE
        scr.poke(a, scr.peek(a) | w >> 8)
        scr.poke(a + 1, scr.peek(a + 1) | (w & 0xFF))


def title_json(ram: bytes) -> dict:
    ts = logo_frames(ram)
    letters = logo_letters(ram)
    frames = [dict(frame=i + 1, t=t, letters=[list(logo_pos(L, t)) for L in letters] if t else None)
              for i, t in enumerate(ts)]
    return dict(
        routine="$106E2 (per frame from the title loop $10884), drawing $10720 -> draw_bob $AB08",
        letters=letters,
        coordinates="bitplane x = BOB x - 128 (draw_bob), y = line; x(t) = x0 - ((280 - x0) t >> 5)"
                    " + x_off, y(t) = t + y_off",
        erase="before drawing, the letters of two frames ago are cleared as rectangles (the "
              "BLTCON0 immediate $AC16 patched from $0FCA to $0100)",
        countdown=dict(variable="$1067A (16.16)", start="$880000 (136.0)",
                       step="L -= L >> 4 (arithmetic; 1.0 when that is 0)",
                       frames=len(ts), final_t=ts[-2]),
        tm_mark=dict(address=hexa(LOGO_TM), at="front buffer byte $1F50: plane 2, x 288-303, "
                                               "lines 52-56", rows=[f"{u16(ram, LOGO_TM + 2 * k):016b}"
                                                                   for k in range(5)]),
        palette=dict(address=hexa(TEXT_PALETTE),
                     colours=[f"${u16(ram, TEXT_PALETTE + 2 * i):03X}" for i in range(15)],
                     note="COLOR01-15; components clamped to E by $F8C4 at fade level $1D/$1F"),
        frames=frames)


def main(argv: list[str]) -> int:
    img = Path(argv[1]) if len(argv) > 1 else ROOT / "build/ram/level1_full.bin"
    out = Path(argv[2]) if len(argv) > 2 else ROOT / "build/front"
    ram = img.read_bytes()
    if len(ram) < 0x80000 or ram[0x8000:0x8002] != b"\x60\x62":
        print(f"{img}: not a composite RAM image (expected BRA at $8000)", file=sys.stderr)
        return 2
    out.mkdir(parents=True, exist_ok=True)
    pal = text_palette(ram)
    docs = dict(scripts=scripts_json(ram, out, pal), hiscores=hiscores_json(ram),
                font=font_json(ram), title=title_json(ram))
    for name, d in docs.items():
        (out / f"{name}.json").write_text(json.dumps(d, indent=1, ensure_ascii=False) + "\n")
    font_pngs(ram, out, pal)
    scr = Screen()
    draw_logo(ram, scr)
    scr.png(out / "screens" / "title_logo.png", pal)
    n = len(docs["scripts"]["scripts"])
    print(f"{out}: {n} scripts, 8 particle texts, {HISCORE_COUNT} high scores, "
          f"{BITMAP_GLYPHS} + {STROKE_GLYPHS} glyphs, logo in {docs['title']['countdown']['frames']} "
          "frames")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
