#!/usr/bin/env python3
"""Run-time HUD data for msx/hud.asm: everything the Amiga panel routines draw, already in HUD
colours and cut into whole bytes of the MSX HUD (SCREEN 5, 2 pixels per byte).

Every patch is the HUD (tools/msxhud.py's 1:1 re-layout) of the panel after the Amiga
operation (tools/hudmodel.py), limited to the bytes that operation can change. Pixels that
share a byte with a neighbour are covered by one owner only, which is possible because the
neighbour's pixel never depends on the neighbour's state: the digit glyphs' columns 0, 1, 14
and 15 are the same for all ten digits and the colour bank under every cell is 0, so in a
byte shared by two cells the left cell's last column (variable) goes with the right cell's
first column (constant) and the left cell owns it. A random check builds HUD states from
the patches and compares them with the model.

FORMAT (hud_rt.bin, little-endian; pointers are CPU addresses with the blob in two
consecutive banks mapped at 8000h-BFFFh; VRAM addresses are the low 16 bits, bit 16 set):
  cells:    14 x (dw VRAM address of the first byte on the first line, db bytes per line,
            db 0, 10 x dw patch): timer MM MM SS SS (red), ammo x3, score x7; 16 lines each
  patches:  unique blocks of 16 lines x n bytes
  font:     42 glyphs x 8 lines x 9 bytes, HUD colours (0 = transparent), packed 2 pixels
            per byte for a cell starting on a byte (p0p1 p2p3 p4p5 p6p7) and for one starting
            in the middle of a byte (0p0 p1p2 p3p4 p5p6 p70)
  frame:    8 bytes: the pixel after the last text cell (the box frame), per text line
  can:      40 lines x 14 bytes (HUD x 0-27 of lines 2-41: the full can), then the 3 empty
            tops, 8 x 14 bytes each
  heads:    6 graphics x (slot 0: 32 lines x 16 bytes, slot 1: 32 lines x 15 bytes)
  icons:    8 icons x 16 lines x 8 bytes
  messages: 9 x dw pointer, then the game's messages ($FF-terminated, its character codes)
  weapons:  4 x (dw ammo in BCD as the game stores it, db icon, db 0), from set_weapon's
            tables $FD52 / $FD5A
hud_rt.inc gives the addresses of the tables and the HUD positions.

usage: msxhudrt.py PERMA.bin MAIN_8000.bin OUT   (writes OUT.bin and OUT.inc)
"""
from __future__ import annotations

import random
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hudmodel  # noqa: E402
import msxhud  # noqa: E402

BASE = 0x8000
VRAM_HUD = 0x18000 + 208 * 128
CELL_LINES = 16
CAN_BYTES, CAN_LINE = 14, 3 - msxhud.FIRST_LINE
HEAD_LINES = msxhud.PANEL_LINES - 14                    # panel lines 14..45 are shown
# the game's messages (lea targets in its calls to message_queue $FD76, via REA xrefs; the
# pickups' from the table at $FC12); hud_rt.inc numbers them HUD_MSG_<address>
MESSAGES = [0xC222, 0xDC76, 0xC238, 0xC24B, 0xD46C, 0xED11, 0x865A, 0xF837, 0xF82C,
            0xDC8A, 0xED04, 0xFC3E, 0xFC4B, 0xFC57, 0xFC62, 0xFC6D, 0xFC7E, 0xFC86, 0xFC8E, 0xFC9D,
            0xFCAD]


def pack(px: list[int]) -> bytes:
    return bytes((px[i] << 4) | px[i + 1] for i in range(0, len(px), 2))


def cell_bytes(x0: int) -> tuple[int, int]:
    """First byte and byte count of a 13 px digit cell at HUD x0 (see the module docstring)."""
    return (x0 // 2, 7) if x0 % 2 == 0 else ((x0 + 1) // 2, 6)


def block(hud: list[list[int]], y0: int, lines: int, b0: int, n: int) -> bytes:
    return b"".join(pack(hud[y0 + y][2 * b0:2 * (b0 + n)]) for y in range(lines))


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    perma, mainb = Path(argv[1]).read_bytes(), Path(argv[2]).read_bytes()
    out = Path(argv[3])
    base = hudmodel.Panel(perma, mainb)
    _, dyn = msxhud.compose(base.px)
    cells = dyn["timer_cells"] + dyn["ammo_cells"] + dyn["score_cells"]

    # digit patches
    cell_info, patches, index = [], [], {}
    for k, (x0, y0) in enumerate(cells):
        b0, n = cell_bytes(x0)
        ptrs = []
        for v in range(10):
            p = base.copy()
            p.digit(k, v)
            blk = block(p.hud(), y0, CELL_LINES, b0, n)
            if blk not in index:
                index[blk] = len(patches)
                patches.append(blk)
            ptrs.append(index[blk])
        cell_info.append((VRAM_HUD + y0 * 128 + b0, n, ptrs))

    # font and the frame pixel after the text
    glyphs = base.glyph_colours()
    for g, gc in zip(base.font, glyphs):
        for row, rc in zip(g, gc):
            if any((v == 0) != (c == 0) for v, c in zip(row, rc)):
                raise SystemExit("a font colour maps to HUD colour 0 (it would turn transparent)")
    tx, ty = hudmodel.text_x(), hudmodel.TEXT_PANEL_Y - msxhud.FIRST_LINE
    hud0 = base.hud()
    frame = bytes(hud0[ty + y][tx + hudmodel.TEXT_CELLS * hudmodel.TEXT_PITCH] for y in range(hudmodel.TEXT_LINES))
    font = b""
    for g in glyphs:
        for row in g:
            font += pack(row) + pack([0] + row + [0])

    # can: the full can and the three empty tops (the can element is a plain column copy, so
    # a row's HUD bytes do not depend on its line)
    full = block(hud0, CAN_LINE, 40, 0, CAN_BYTES)
    tops = b""
    for t in range(3):
        p = base.copy()
        p.blit(p.tops[t], 0, 5)
        tops += block(p.hud(), 5 - msxhud.FIRST_LINE, 8, 0, CAN_BYTES)

    # heads and icons
    heads = b""
    hx = [x for x, _ in dyn["heads"]]
    hy = dyn["heads"][0][1]
    for g in range(6):
        for s in (0, 1):
            p = base.copy()
            p.head(g, s)
            heads += block(p.hud(), hy, HEAD_LINES, hx[s] // 2, 16 if s == 0 else 15)
    ix, iy = dyn["weapon_icon"]
    icons = b""
    for i in range(8):
        p = base.copy()
        p.icon(i)
        icons += block(p.hud(), iy, 16, ix // 2, 8)
    msgs = []
    for a in MESSAGES:
        o = a - 0x8000
        s = bytearray()
        while True:
            s.append(mainb[o])
            o += 1
            if s[-1] == 0xFF:
                break
        msgs.append(bytes(s))

    # random check: HUD states built from the patches against the model
    rng = random.Random(1)
    for _ in range(60):
        p = base.copy()
        hud = [row[:] for row in hud0]
        vals = [rng.randrange(10) for _ in cells]
        for k, v in enumerate(vals):
            p.digit(k, v)
        level = rng.randrange(33)
        p.can_level(level)
        hg = [rng.randrange(6), rng.randrange(6)]
        for s in (0, 1):
            p.head(hg[s], s)
        icon = rng.randrange(8)
        p.icon(icon)
        want = p.hud()

        def put(blk: bytes, y0: int, lines: int, b0: int, n: int):
            for y in range(lines):
                for b in range(n):
                    v = blk[y * n + b]
                    hud[y0 + y][2 * (b0 + b)] = v >> 4
                    hud[y0 + y][2 * (b0 + b) + 1] = v & 15

        for k, v in enumerate(vals):
            addr, n, ptrs = cell_info[k]
            put(patches[ptrs[v]], (addr - VRAM_HUD) // 128, CELL_LINES, (addr - VRAM_HUD) % 128, n)
        # can: full, then the game's steps down to the level (as msx/hud.asm draws them)
        put(full, CAN_LINE, 40, 0, CAN_BYTES)
        for old in range(32, level, -1):
            if old >= 2:
                t = 0 if old > 23 else (1 if old > 12 else 2)
                put(tops[t * 8 * CAN_BYTES:(t + 1) * 8 * CAN_BYTES], 33 - old - msxhud.FIRST_LINE, 8, 0, CAN_BYTES)
                put(full[(39 - old) * CAN_BYTES:(40 - old) * CAN_BYTES], 42 - old - msxhud.FIRST_LINE, 1, 0, CAN_BYTES)
        for s in (0, 1):
            n = 16 if s == 0 else 15
            start = HEAD_LINES * 31 * hg[s] + (HEAD_LINES * 16 if s else 0)
            put(heads[start:start + HEAD_LINES * n], hy, HEAD_LINES, hx[s] // 2, n)
        put(icons[icon * 128:(icon + 1) * 128], iy, 16, ix // 2, 8)
        if hud != want:
            bad = [(x, y) for y in range(len(hud)) for x in range(256) if hud[y][x] != want[y][x]]
            raise SystemExit(f"run-time patches differ from the model at {len(bad)} pixels, e.g. {bad[:8]}")

    # blob
    blob = bytearray()
    sections = {}

    def section(name: str, data: bytes):
        sections[name] = BASE + len(blob)
        blob.extend(data)

    cell_tab_size = len(cells) * (4 + 20)
    patch_base = BASE + cell_tab_size
    patch_addr, pos = [], patch_base
    for blk in patches:
        patch_addr.append(pos)
        pos += len(blk)
    tab = b""
    for addr, n, ptrs in cell_info:
        tab += struct.pack("<HBB", addr & 0xFFFF, n, 0) + b"".join(struct.pack("<H", patch_addr[i]) for i in ptrs)
    section("HUD_CELLS", tab)
    section("HUD_PATCHES", b"".join(patches))
    section("HUD_FONT", font)
    section("HUD_FRAME", frame)
    section("HUD_CAN", full)
    section("HUD_TOPS", tops)
    section("HUD_HEADS", heads)
    section("HUD_ICONS", icons)
    mtab = b""
    pos = BASE + len(blob) + 2 * len(msgs)
    for m in msgs:
        mtab += struct.pack("<H", pos)
        pos += len(m)
    section("HUD_MSGS", mtab + b"".join(msgs))
    section("HUD_WEAPONS", b"".join(struct.pack(">H", base.weapon_ammo(w)) + bytes([base.weapon_icon(w), 0])
                                    for w in range(4)))
    if len(blob) > 0x4000:
        raise SystemExit(f"HUD data is {len(blob)} bytes: more than the two banks of the 8000h-BFFFh window")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.with_suffix(".bin").write_bytes(bytes(blob) + b"\xff" * (-len(blob) % 0x2000))
    inc = ["; generated by tools/msxhudrt.py (HUD data mapped at 8000h-BFFFh)"]
    inc += [f"{k}:{' ' * max(1, 12 - len(k))}equ 0x{v:04X}" for k, v in sections.items()]
    inc += [f"HUD_MSG_{a:04X}: equ {i}" for i, a in enumerate(MESSAGES)]
    inc += [f"HUD_NMSGS:   equ {len(msgs)}",
            f"HUD_TEXT:    equ 0x{(VRAM_HUD + ty * 128) & 0xFFFF:04X}   ; VRAM of text line 0, byte 0",
            f"HUD_TEXT_X:  equ {tx}                ; HUD x of text cell 0 (even)",
            f"HUD_CAN_V:   equ 0x{(VRAM_HUD + CAN_LINE * 128) & 0xFFFF:04X}   ; VRAM of the can's first line (panel line 3)",
            f"HUD_HEAD0_V: equ 0x{(VRAM_HUD + hy * 128 + hx[0] // 2) & 0xFFFF:04X}",
            f"HUD_HEAD1_V: equ 0x{(VRAM_HUD + hy * 128 + hx[1] // 2) & 0xFFFF:04X}",
            f"HUD_HEAD_LINES: equ {HEAD_LINES}",
            f"HUD_ICON_V:  equ 0x{(VRAM_HUD + iy * 128 + ix // 2) & 0xFFFF:04X}"]
    out.with_suffix(".inc").write_text("\n".join(inc) + "\n")
    assert tx % 2 == 0, "text x must be even"
    print(f"{out.with_suffix('.bin')}: {len(blob)} bytes ({len(patches)} digit patches, font, can, "
          f"{6 * 2} heads, 8 icons, {len(msgs)} messages); random check of the patches against the model passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
