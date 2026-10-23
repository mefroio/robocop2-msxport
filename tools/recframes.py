#!/usr/bin/env python3
"""Renders and checks the pictures tools/openmsx_rc2.tcl rc2_jumprec recorded after RoboCop's jumps.

Each record (jJJJ_fFFFF.bin) holds the state the VDP drew the play area with (taken at the HUD
split): R#0-R#63, the palette, the page shown (with the V9958 engine's SP2: its pair of pages,
the 512 px ring), VRAM 1D800h-1FFFFh (sprite tables, HUD), RAM
C000h-CFFFh (the register list applied and its camera: msx/isr.asm list_tail) and page-0 RAM
0A00h-0FFFh (the map patches: msx/tiles.asm get_tile). The play area is rendered with
tools/msxscreen.py's model of openMSX's renderer and every pixel no sprite covers is compared
with the map at the recorded camera (patched cells as the game changed them): a bad page, a
row of the ring not drawn yet, a wrong scroll or palette shows as background pixels that
differ. RoboCop's sprites (his run in the SAT: msx/sprites.asm disp record of object 0) are
checked line by line as the VDP takes them: none may come after the 8th sprite of a line (it
would not be drawn), and a B sprite (CC = 1) must follow an A sprite of his (else its colour ORs
into another sprite and his own pixels lose it): either makes him look holed or transparent.
With --sprites (records of an EXTJOY build, whose register lists carry what their SAT shows:
msx/isr.asm list_tail, pub_spr) every object shown is also compared, pixel by pixel as the VDP
drew it, with its full look (every OR layer, as tools/msxsprites.py converts its composition;
its silhouette while it flashes): an OR layer the budget dropped, a wrong pattern or colour
row, a sprite the VDP left out show as differing pixels; across the records it counts, per
object, the changes of the OR layers shown and the pictures it vanished for (needs numpy).
Writes a PNG per record (2x, differing pixels in magenta on the right) and a contact sheet per
jump, and prints the records with differences.

usage: recframes.py DIR LEVEL_PREFIX [--sheets] [--sprites]
       (e.g. recframes.py build/rec build/msx/level1)
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from msxscreen import render, sprite_line  # noqa: E402
from planar import write_png  # noqa: E402

VIEW = 162                                      # play-area lines (msx/msx.inc VIEW_LINES)
COLS = 160                                      # map columns
RAM_BASE = 0xC000
APP_SEQ = 0xC006
LISTS = (0xC080, 0xC0A0)                        # msx/msx.inc vbl_list_a, vbl_list_b
MP_ROW, MP_COL, MP_TILEL, MP_TILEH, MP_NEXT = 0x0A00, 0x0B00, 0x0C00, 0x0D00, 0x0F00
REC = 64 + 32 + 0x8000 + 0x2800 + 0x1000 + 0x600


def camera(ram: bytes) -> tuple[int, int]:
    """The camera the register list on screen records (its tail: msx/isr.asm list_tail)."""
    for base in LISTS:
        off = base - RAM_BASE
        if ram[off] == ram[APP_SEQ - RAM_BASE]:
            n = ram[off + 1]
            tail = off + 2 + n
            return struct.unpack_from("<hh", ram, tail)
    raise ValueError("no register list matches app_seq")


def tile_at(mp: bytes, patches: bytes, row: int, col: int) -> int:
    p = patches[MP_ROW - MP_ROW + row]
    while p != 0xFF:
        if patches[MP_COL - MP_ROW + p] == col:
            return patches[MP_TILEL - MP_ROW + p] | patches[MP_TILEH - MP_ROW + p] << 8
        p = patches[MP_NEXT - MP_ROW + p]
    return mp[2 * (row * COLS + col)] | mp[2 * (row * COLS + col) + 1] << 8


DISP = 0xC800                                  # msx/msx.inc: the version each object shows
RC_RUN = 2                                      # msx/sprites.asm: RoboCop's first SAT entry


def robocop_lines(vram: bytes, regs: list[int], ram: bytes) -> tuple[int, int]:
    """Lines of the play area where one of RoboCop's sprites is not drawn (after the 8th
    sprite of the line) or one of his B sprites does not follow an A sprite of his."""
    if not ram[DISP - RAM_BASE]:
        return 0, 0
    n = ram[DISP - RAM_BASE + 7]
    mine = range(RC_RUN, RC_RUN + n)
    base = ((regs[11] << 15) | (regs[5] << 7)) & 0x1FC00
    pat_base = (regs[6] << 11) & 0x1F800
    hidden = paired = 0
    for line in range(VIEW):
        vis, over = [], []
        for i in range(32):
            y = vram[base + 512 + 4 * i]
            if y == 216:
                break
            sl = (line - 1 + regs[23] - y) & 0xFF
            if sl >= 16:
                continue
            n = vram[base + 512 + 4 * i + 2] & 0xFC
            bits = vram[pat_base + 8 * n + sl] | vram[pat_base + 8 * n + sl + 16]
            (vis if len(vis) < 8 else over).append((i, vram[base + 16 * i + sl], bits))
        if any(i in mine and bits for i, _, bits in over):
            hidden += 1                         # (a sprite of his with pixels there, not drawn)
        for k, (i, attr, bits) in enumerate(vis):
            if i in mine and attr & 0x40 and bits and (k == 0 or vis[k - 1][0] not in mine):
                paired += 1                     # (a B row with pixels, not after one of his)
                break
    return hidden, paired


def sprite_look(rows: list[bytes], regs: list[int], pal: list[int], ram: bytes, vram: bytes,
                joint_pal: bytes) -> tuple[list[dict], dict[int, list[int]]]:
    """The objects the applied list shows (pub_spr) and, per object, [pixels, pixels that differ
    from its full look, of them on lines the VDP cut (more than 8 sprites)]."""
    import msxframe
    _, cam_x, _, objs = msxframe.applied_list(ram)
    rgb = [((pal[2 * i] >> 4) * 255 // 7, (pal[2 * i + 1] & 7) * 255 // 7, (pal[2 * i] & 7) * 255 // 7)
           for i in range(16)]
    sil_colour = msxframe.silhouette_colours(joint_pal)
    want: dict[tuple[int, int], tuple[int, int]] = {}
    for k in reversed(msxframe.SAT_ORDER):           # (the first in the SAT drawn last: in front)
        obj = objs[k]
        if not obj["shown"]:
            continue
        sil = sil_colour[obj.get("sil", 0)]
        for y0, boxes in msxframe.converted(obj, joint_pal):
            for c in reversed(boxes):                # (the first box of a band in front)
                im = c["fallback"] if sil else c["full"]
                for y in range(16):
                    for i in range(16):
                        if im[y, i]:
                            want[(obj["x"] + c["x"] + i, obj["y"] + y0 + y)] = (sil or int(im[y, i]), k)
    over = msxframe.over_lines(vram, regs)
    right = 256 - max(0, (cam_x & 15) - 8)
    stats: dict[int, list[int]] = {}
    for (x, y), (colour, k) in want.items():
        if not (8 <= x < right and 0 <= y < VIEW):
            continue
        st = stats.setdefault(k, [0, 0, 0])
        st[0] += 1
        if rows[y][3 * x:3 * x + 3] != bytes(rgb[colour]):
            st[1] += 1
            st[2] += y in over
    return objs, stats


def check(path: Path, mp: bytes, til: bytes, prev: bytes | None = None) -> tuple[int, list[bytes], list[bytes]]:
    """The record's background against the map; 'prev': the map patches of the record before it,
    whose tick may be the one the picture shows (the record's RAM can be a tick ahead)."""
    d = path.read_bytes()
    if len(d) not in (REC, REC + 0x8000):
        raise ValueError(f"{path}: {len(d)} bytes, not a record")
    sp2 = len(d) == REC + 0x8000                # (the V9958 engine: SP2, a pair of pages)
    regs = list(d[:64])
    pal = list(d[64:96])
    pos = 96
    page = (regs[2] >> 5) & 3
    vram = bytearray(0x20000)
    base, size = ((page & 2) * 0x8000, 0x10000) if sp2 else (page * 0x8000, 0x8000)
    vram[base:base + size] = d[pos:pos + size]
    pos += size
    vram[0x1D800:0x20000] = d[pos:pos + 0x2800]
    pos += 0x2800
    ram = d[pos:pos + 0x1000]
    pos += 0x1000
    patches = d[pos:pos + 0x600]
    cam_x, cam_y = camera(ram)
    _, _, rows = render(bytes(vram), regs, pal)
    rgb = [((pal[2 * i] >> 4) * 255 // 7, (pal[2 * i + 1] & 7) * 255 // 7, (pal[2 * i] & 7) * 255 // 7)
           for i in range(16)]
    adj = ((regs[18] & 15) ^ 7) - 7
    right = 256 if sp2 else 256 - max(0, (cam_x & 15) - 8)  # (the V9938 engine's set-adjust
                                                # shows border there)
    rows_map = len(mp) // (COLS * 2)
    bad = 0
    diff = []
    for y in range(VIEW):
        row = rows[y]
        spr = sprite_line(bytes(vram), regs, y)
        drow = bytearray(row)
        for x in range(8, right):
            if 0 <= x - adj < 256 and spr[x - adj] is not None:
                continue
            wx, wy = cam_x + x - 8, cam_y + y
            if wy < 0 or wx < 0 or wy // 16 >= rows_map or wx // 16 >= COLS:
                continue
            t = tile_at(mp, patches, wy // 16, wx // 16)
            b = til[t * 128 + (wy % 16) * 8 + (wx % 16) // 2]
            want = bytes(rgb[(b >> 4) if wx % 2 == 0 else b & 15])
            if row[3 * x:3 * x + 3] != want:
                if prev is not None:
                    t = tile_at(mp, prev, wy // 16, wx // 16)
                    b = til[t * 128 + (wy % 16) * 8 + (wx % 16) // 2]
                    if row[3 * x:3 * x + 3] == bytes(rgb[(b >> 4) if wx % 2 == 0 else b & 15]):
                        continue                # (the tick the picture shows)
                bad += 1
                drow[3 * x:3 * x + 3] = b"\xff\x00\xff"
        diff.append(bytes(drow))
    check.patches = patches
    check.robocop = robocop_lines(bytes(vram), regs, ram)
    check.state = (rows, regs, pal, ram, bytes(vram))
    return bad, rows[:VIEW], diff


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", type=Path)
    ap.add_argument("level", type=Path)
    ap.add_argument("--sheets", action="store_true", help="a contact sheet per jump (every frame, 1x)")
    ap.add_argument("--sprites", action="store_true", help="every object against its full look (EXTJOY records)")
    a = ap.parse_args()
    joint_pal = a.level.with_suffix(".pal").read_bytes()
    looks: dict[int, dict] = {}                 # per object: pictures, differing, OR changes, vanished
    mp = a.level.with_suffix(".map").read_bytes()
    til = a.level.with_suffix(".til").read_bytes()
    out = a.dir / "png"
    out.mkdir(exist_ok=True)
    jumps: dict[str, list[tuple[str, list[bytes]]]] = {}
    flagged = 0
    files = sorted(a.dir.glob("j*_f*.bin"))
    rc_flagged = 0
    prev = None
    for path in files:
        if prev is not None and prev[0] != path.stem.split("_")[0]:
            prev = None                         # (another jump: no record before it)
        bad, rows, diff = check(path, mp, til, prev[1] if prev else None)
        prev = (path.stem.split("_")[0], check.patches)
        hidden, paired = check.robocop
        if hidden or paired:
            rc_flagged += 1
            print(f"{path.stem}: RoboCop: {hidden} lines with a sprite of his not drawn, {paired} with a B "
                  f"sprite away from his A")
        if a.sprites:
            objs, stats = sprite_look(*check.state, joint_pal)
            jump = path.stem.split("_")[0]
            ram = check.state[3]
            for k, obj in enumerate(objs):
                tier = ram[0xCC00 - RAM_BASE + 32 * k + 25]           # msx/sprites.asm O_TIER
                lk = looks.setdefault(k, {"pictures": 0, "differ": 0, "cut": 0, "pixels": 0, "dropped": 0,
                                          "changes": 0, "vanished": 0, "last": None, "gap": 0, "worst": (0, ""),
                                          "ids": set(), "tiers": set()})
                if lk["last"] is not None and lk["last"][0] != jump:
                    lk["last"], lk["gap"] = None, 0
                if not obj["shown"]:
                    if lk["last"] is not None:
                        lk["gap"] += 1
                    continue
                if lk["last"] is not None and 0 < lk["gap"] <= 2:
                    lk["vanished"] += 1          # (gone for a picture or two, then back)
                if lk["last"] is not None and lk["gap"] == 0 and lk["last"][1] == obj["id"] \
                        and lk["last"][2] != obj["drop"]:
                    lk["changes"] += 1           # (the same frame, other OR layers)
                lk["last"], lk["gap"] = (jump, obj["id"], obj["drop"]), 0
                st = stats.get(k, [0, 0, 0])
                lk["ids"].add(obj["id"])
                lk["tiers"].add(tier)
                lk["pictures"] += 1
                lk["pixels"] += st[0]
                lk["dropped"] += obj["drop"] != 0
                if st[1]:
                    lk["differ"] += 1
                    lk["cut"] += st[2] == st[1]
                    if st[1] > lk["worst"][0]:
                        lk["worst"] = (st[1], f"{path.stem} {'BOB' if obj['bob'] else 'RoboCop'} {obj['id']}"
                                              f" drop {obj['drop']:#04x}: {st[1]}/{st[0]} pixels")
        if bad or hidden or paired:
            flagged += bad > 0
            if bad:
                print(f"{path.stem}: {bad} background pixels differ")
            write_png(out / f"{path.stem}.png", 512, 2 * VIEW,
                      [b"".join(r[i:i + 3] * 2 for i in range(0, 768, 3)) + b"" for r in rows for _ in (0, 1)])
            write_png(out / f"{path.stem}_diff.png", 256, VIEW, diff)
        jumps.setdefault(path.stem.split("_")[0], []).append((path.stem, rows))
    if a.sheets:
        for j, frames in jumps.items():
            per = 6
            n_rows = (len(frames) + per - 1) // per
            sheet = []
            for r in range(n_rows):
                group = frames[r * per:(r + 1) * per]
                for y in range(VIEW):
                    line = b"".join(f[1][y] + b"\x20\x20\x20" * 4 for f in group)
                    sheet.append(line + b"\x20" * (per * (256 + 4) * 3 - len(line)))
                for _ in range(4):
                    sheet.append(b"\x20" * (per * (256 + 4) * 3))
            write_png(out / f"{j}_sheet.png", per * (256 + 4), len(sheet), sheet)
    if a.sprites:
        for k, lk in sorted(looks.items()):
            if not lk["pictures"]:
                continue
            kinds = {0: "characters", 1: "shots/bullets/pickups", 2: "explosions", 3: "RoboCop"}
            name = "RoboCop" if k == 0 else ("spark" if k == 15 else
                                             f"object {k} ({'/'.join(kinds.get(t, '?') for t in sorted(lk['tiers']))}, "
                                             f"BOB frames {sorted(lk['ids'])[:6]}{'...' if len(lk['ids']) > 6 else ''})")
            print(f"{name}: {lk['pictures']} pictures, {lk['dropped']} with OR layers dropped, "
                  f"{lk['changes']} changes of its OR layers within a frame of animation, vanished "
                  f"{lk['vanished']} times; {lk['differ']} pictures differ from its full look "
                  f"({lk['cut']} only on lines the VDP cut)" + (f"; worst {lk['worst'][1]}" if lk["differ"] else ""))
    print(f"{len(files)} pictures of {len(jumps)} jumps checked: {flagged} with background differences, "
          f"{rc_flagged} with RoboCop not drawn whole")
    return 1 if flagged or rc_flagged else 0


if __name__ == "__main__":
    raise SystemExit(main())
