#!/usr/bin/env python3
"""Rebuilds a whole frame of the prototype (play area with sprites + HUD) and checks it.

Inputs (saved from openMSX, see tools/openmsx_rc2.tcl): VRAM (128 KiB), RAM C000h-C7FFh and
the 48 VDP registers. The play-area registers come from the register list the
ISR applied last (seq == app_seq, msx/isr.asm), whose tail also records the camera and the
sprite state that list shows; the HUD registers come from split_list (sprites off; on the
V9958 the border mask off). The main loop writes the SAT of a list right after the VBLANK that
applies it (msx/sprites.asm, sprites_vblank): a snapshot taken in between (spr_vblank still 1
with the list already applied) has the previous SAT, so its sprites are not checked. The split itself (display off on lines VIEW..VIEW+3, HUD from
VIEW+4) was verified separately with the VDP probes. The frame is rendered with
tools/msxscreen.py's model (sprite mode 2 included) and compared with the expected picture:
  - the map at the recorded camera;
  - the HUD as the Amiga panel would be after drawing what msx/hud.asm records as shown
    (digits, energy level, heads, weapon icon; tools/hudmodel.py) plus the message line
    (MSX 7 px rule); while a HUD job (head, icon, full can) is half written the HUD is not
    checked;
  - every sprite object the list shows (pub_spr: RoboCop and BOBs, msx/sprites.asm) as
    tools/msxsprites.py converts its composition (full OR version, or the single-layer
    fallback for the bands the budget dropped), in SAT order (the hit spark's object, then
    object 0 and the others: the first in front): exact. Objects that
    alternate between frames are recorded as not shown on the frames they are off. Lines where
    the SAT shown puts more than 8 sprites (the budget's layout for new positions still on its
    way: the VDP drops the last ones) are reported apart and their sprite pixels not checked;
  - the tile area of VRAM (page 2 and page 3 lines 0-175) against the level's VRAM image:
    nothing may write there at run time.
Needs numpy for the sprites (tools/msxsprites.py).

usage: msxframe.py SNAPDIR LEVEL_PREFIX HUD_PREFIX OUT.png
       (e.g. build/snap build/msx/level1 build/msx/hud build/png/frame.png)
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from msxscreen import render  # noqa: E402
from planar import write_png  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RAM_BASE = 0xC000
PUB_SEQ, APP_SEQ, VDP_ID = 0xC005, 0xC006, 0xC000
SPR_VBLANK = 0xC0E5
HUD_SHOWN, EN_SHOWN, HUD_CHARS, HEADS_G, ICON_SHOWN = 0xC608, 0xC618, 0xC626, 0xC63B, 0xC63D
JOB_LINES, JOBQ_N = 0xC63E, 0xC646
LISTS = (0xC080, 0xC0A0)
MAX_OBJ = 16
SPARK_OBJ = MAX_OBJ - 1                         # msx/sprites.asm: first in the SAT
SAT_ORDER = [SPARK_OBJ] + list(range(SPARK_OBJ))
PUB_SPR = {0xC080: 0xC700, 0xC0A0: 0xC780}     # what each list's SAT shows (MAX_OBJ objects x 8 bytes)
SPLIT_LIST = 0xC0C0
VIEW, HUD_TOP = 163, 167
TILE_AREA = (0x10000, 0x18000 + 176 * 128)       # page 2 and page 3 lines 0-175: tiles only
HUD_MSK = 0xC02B
COLS = 160


def applied_list(ram: bytes) -> tuple[dict[int, int], int, int, list[dict]]:
    seq = ram[APP_SEQ - RAM_BASE]
    for base in LISTS:
        o = base - RAM_BASE
        if ram[o] == seq:
            n = ram[o + 1]
            pairs = ram[o + 2:o + 2 + n]
            regs = {pairs[i + 1] & 0x7F: pairs[i] for i in range(0, n, 2)}
            cam_x, cam_y = struct.unpack_from("<HH", ram, o + 2 + n)    # (then the game frame)
            objs = []
            for k in range(MAX_OBJ):
                flags, ident, drop, x, y = struct.unpack_from("<BHBhh", ram, PUB_SPR[base] - RAM_BASE + 8 * k)
                objs.append({"shown": bool(flags & 0x80), "bob": bool(flags & 1), "id": ident, "drop": drop,
                             "x": x, "y": y, "sil": (flags >> 1) & 3})
            return regs, cam_x, cam_y, objs
    raise ValueError(f"no register list with seq {seq}")


def split_regs(ram: bytes) -> dict[int, int]:
    o = SPLIT_LIST - RAM_BASE
    n = ram[o]
    pairs = ram[o + 1:o + 1 + n]
    return {pairs[i + 1] & 0x7F: pairs[i] for i in range(0, n, 2)}


def rgb9(pal: bytes) -> list[tuple[int, int, int]]:
    return [((pal[2 * i] >> 4) * 255 // 7, (pal[2 * i + 1] & 7) * 255 // 7, (pal[2 * i] & 7) * 255 // 7)
            for i in range(16)]


_conv_cache: dict = {}


def converted(obj: dict, joint_pal: bytes) -> list:
    """The bands of an object's composition, as tools/msxsprites.py cuts them."""
    key = (obj["bob"], obj["id"])
    if key in _conv_cache:
        return _conv_cache[key]
    import json
    import numpy as np
    import msxsprites
    import player
    main = (ROOT / "build/extracted/boot/main_8000.bin").read_bytes()
    pal = np.array([[joint_pal[2 * i] >> 4, joint_pal[2 * i + 1] & 7, joint_pal[2 * i] & 7] for i in range(16)]) / 7
    pal12 = [struct.unpack_from(">H", main, 0xFFF6 - 0x8000 + 2 * i)[0] for i in range(31)]
    sppal = np.array([[0, 0, 0]] + [msxsprites.amiga_rgb(c) for c in pal12[16:31]])
    if obj["bob"]:
        bobs = json.loads((ROOT / "build/msx/robocop.json").read_text())["bobs"]
        fr = bobs[obj["id"]]
        if fr.get("repeat"):                        # a frame removed: another one, moved
            k2, dy, dx = fr["repeat"]
            cols = msxsprites.move_layout(converted({"bob": 1, "id": k2}, joint_pal), dy, dx)
            _conv_cache[key] = cols
            return cols
        if fr.get("mirror"):                        # an earlier frame's layout, mirrored
            m, dy, dx = fr["mirror"]
            cols = msxsprites.mirror_layout(converted({"bob": 1, "id": m}, joint_pal), bobs[m]["w"], dy, dx)
            _conv_cache[key] = cols
            return cols
        ram = (ROOT / "build/ram/level1_full.bin").read_bytes()
        src = msxsprites.bob_image(ram, fr["addr"], fr["w"], fr["h"])
        if fr.get("spark"):                         # the hit spark: RoboCop's colours and pairs
            tgt = np.where(src > 0, msxsprites.nearest(sppal[np.clip(src, 0, 15)], pal, 1), 0)
            cols = msxsprites.Converter(pal, cap=msxsprites.RC_CAP).composition(tgt)
        else:
            bgpal = np.array([[0, 0, 0]] + [msxsprites.amiga_rgb(c) for c in pal12[:15]])
            near = msxsprites.nearest(bgpal, pal, 1)
            tgt = np.where(src >= 0, near[np.clip(src, 0, 15)], 0)
            conv = msxsprites.Converter(pal, msxsprites.PAIRS_ALL, cap=msxsprites.BOB_CAP, align="bottom")
            conv.prefer = {(b, n): order for b, n, *order in fr.get("prefer", [])}
            cols = conv.composition(tgt)
    else:
        # RoboCop: the compositions as tools/msxsprites.py built them (robocop.json: the entries'
        # compositions, those that mirror or move another one)
        if "rc" not in _conv_cache:
            perma = (ROOT / "build/extracted/files/PERMA_05.bin").read_bytes()
            comps, _ = msxsprites.rc_compositions(player.Game(main, perma))
            meta = json.loads((ROOT / "build/msx/robocop.json").read_text())
            _conv_cache["rc"] = (comps, meta["rc_index"],
                                 {int(c): tuple(v) for c, v in meta["rc_mirrors"].items()},
                                 {int(c): tuple(v) for c, v in meta["rc_moves"].items()}, {},
                                 meta.get("rc_start"))
        comps, index, pairs, moves, lays, start = _conv_cache["rc"]
        conv = msxsprites.Converter(pal, cap=msxsprites.RC_CAP)

        def target(c: int) -> np.ndarray:
            return np.where(comps[c] > 0, msxsprites.nearest(sppal[comps[c]], pal, 1), 0)

        def layout(c: int) -> list:
            if c not in lays:
                if c in moves:
                    src, dy, dx = moves[c]
                    lays[c] = msxsprites.move_layout(layout(src), dy, dx)
                elif c in pairs:
                    cr, dy, dx = pairs[c]
                    lays[c] = msxsprites.mirror_layout(layout(cr), player.BUF_W, dy, dx)
                else:
                    lays[c] = conv.composition(target(c))
            return lays[c]

        if start and start["arms"][0] not in lays:  # (the start-of-level arm poses: converted together)
            tg = {c: target(c) for c in set(start["arms"]) | {start["after"]}}
            lays.update(msxsprites.start_layouts(conv, comps, [tg.get(c) for c in range(len(comps))],
                                                 start["arms"], start["after"], sppal, layout))

        cols = layout(index[obj["id"]])
    _conv_cache[key] = cols
    return cols


def expected_sprites(objs: list[dict], joint_pal: bytes) -> dict[tuple[int, int], int]:
    """Screen pixel -> joint palette index of the sprite objects shown (SAT order: the first in
    front)."""
    out: dict[tuple[int, int], int] = {}
    for obj in [objs[k] for k in reversed(SAT_ORDER)]:
        if not obj["shown"]:
            continue
        sil = silhouette_colours(joint_pal)[obj.get("sil", 0)]
        lay = converted(obj, joint_pal)
        for j, (y0, boxes) in enumerate(lay):
            dropped = obj["drop"] >> (len(lay) - 1 - j) & 1      # (bands numbered from the bottom)
            for c in reversed(boxes):                           # (the first box of a band in front)
                im = c["fallback"] if sil or dropped else c["full"]
                for y in range(16):
                    for i in range(16):
                        if im[y, i]:
                            out[(obj["x"] + c["x"] + i, obj["y"] + y0 + y)] = sil or int(im[y, i])
    return out


def silhouette_colours(joint_pal: bytes) -> list[int]:
    """Per silhouette mode (msx/bob.asm BM_...) the joint palette entry it is shown in (0: none):
    tools/msxsprites.py's colour rows SPR_SIL_FLASH (the nearest to the background's colour 15)
    and SPR_SIL_BLACK (the palette's black after entry 0)."""
    import numpy as np
    import msxsprites
    main = (ROOT / "build/extracted/boot/main_8000.bin").read_bytes()
    pal = np.array([[joint_pal[2 * i] >> 4, joint_pal[2 * i + 1] & 7, joint_pal[2 * i] & 7] for i in range(16)]) / 7
    c15 = np.array([msxsprites.amiga_rgb(struct.unpack_from(">H", main, 0xFFF6 - 0x8000 + 2 * 14)[0])])
    white = int(msxsprites.nearest(c15, pal, 1)[0])
    black = next(i for i in range(1, 16) if (pal[i] == 0).all())
    return [0, white, black, 0]


def over_lines(vram: bytes, regs: list[int]) -> set[int]:
    """Play-area lines on which the SAT the registers show puts more than 8 sprites."""
    base = ((regs[11] << 15) | (regs[5] << 7)) & 0x1FC00
    count = [0] * 256
    for i in range(32):
        y = vram[base + 512 + 4 * i]
        if y == 216:
            break
        for k in range(16):
            count[(y + 1 + k - regs[23]) & 0xFF] += 1
    return {line for line in range(VIEW) if count[line] > 8}


def hud_expected(ram: bytes) -> list[list[int]] | None:
    """HUD colour indices for the state msx/hud.asm records (None while a job is pending)."""
    if ram[JOB_LINES - RAM_BASE] or ram[JOBQ_N - RAM_BASE]:
        return None
    import hudmodel
    p = hudmodel.Panel((ROOT / "build/extracted/files/PERMA_05.bin").read_bytes(),
                       (ROOT / "build/extracted/boot/main_8000.bin").read_bytes())
    for k in range(len(hudmodel.DIGIT_CELLS)):
        p.digit(k, ram[HUD_SHOWN - RAM_BASE + k])
    shown = struct.unpack_from("<h", ram, EN_SHOWN - RAM_BASE)[0]
    p.can_level(max(0, min(32, shown >> 3)))
    for s in (0, 1):
        p.head(ram[HEADS_G - RAM_BASE + s], s)
    p.icon(ram[ICON_SHOWN - RAM_BASE])
    hud = p.hud()
    hudmodel.text_line(p.glyph_colours(), list(ram[HUD_CHARS - RAM_BASE:HUD_CHARS - RAM_BASE + 21]), hud)
    return hud


def main() -> int:
    snap, level, hud, out = (Path(a) for a in sys.argv[1:5])
    vram = (snap / "vram.bin").read_bytes()
    ram = (snap / "ram.bin").read_bytes()
    base = [int(v) for v in (snap / "regs.txt").read_text().split()]
    play, cam_x, cam_y, objs = applied_list(ram)
    regs_play = list(base)
    for r, v in play.items():
        regs_play[r] = v
    regs_hud = list(base)
    for r, v in split_regs(ram).items():
        regs_hud[r] = v
    regs_hud[8] = 0x0A                      # sprites off in the HUD
    if ram[HUD_MSK - RAM_BASE]:
        regs_hud[25] = 0x01                 # V9958: SP2 kept, mask off
    pal_play = level.with_suffix(".pal").read_bytes()
    pal_hud = hud.with_suffix(".pal").read_bytes()
    _, _, rows_play = render(vram, regs_play, list(pal_play))
    _, _, rows_hud = render(vram, regs_hud, list(pal_hud))
    border = bytes(rgb9(pal_play)[regs_play[7] & 15]) * 256
    frame = rows_play[:VIEW] + [border] * (HUD_TOP - VIEW) + rows_hud[HUD_TOP:212]

    mp = level.with_suffix(".map").read_bytes()
    til = level.with_suffix(".til").read_bytes()
    rows_map = len(mp) // (COLS * 2)
    prgb, hrgb = rgb9(pal_play), rgb9(pal_hud)
    hud_want = hud_expected(ram)
    sat_pending = ram[SPR_VBLANK - RAM_BASE] and ram[PUB_SEQ - RAM_BASE] == ram[APP_SEQ - RAM_BASE]
    try:
        spr = {} if sat_pending else expected_sprites(objs, pal_play)
    except IndexError:                      # a product build records no pub_spr: render only
        print("no sprite record (product build): sprites not checked")
        spr, sat_pending = {}, True
    over = set() if sat_pending else over_lines(vram, regs_play)
    bad = border_px = checked = spr_ok = pending_px = 0
    diff_rows = []
    # V9938 engine: with f > 8 the set-adjust (s = 8 - f) shows the border on the right
    right_border = 256 if 26 in play else 256 - max(0, (cam_x & 15) - 8)
    border_rgb = bytes(prgb[regs_play[7] & 15])
    for y in range(212):
        row = frame[y]
        drow = bytearray(row)
        for x in range(8 if y < HUD_TOP else 0, 256):
            got = row[3 * x:3 * x + 3]
            if y < VIEW and x >= right_border and got == border_rgb:
                border_px += 1
                continue
            if y < VIEW:
                wx, wy = cam_x + x - 8, cam_y + y
                if wy // 16 >= rows_map or wx // 16 >= COLS:
                    continue
                t = mp[2 * ((wy // 16) * COLS + wx // 16)] | mp[2 * ((wy // 16) * COLS + wx // 16) + 1] << 8
                b = til[t * 128 + (wy % 16) * 8 + (wx % 16) // 2]
                want = bytes(prgb[(b >> 4) if wx % 2 == 0 else b & 15])
                if sat_pending:
                    pass                            # sprites not checked (see the docstring)
                elif (x, y) in spr:
                    if y in over:
                        continue                    # (the VDP dropped sprites on that line)
                    want = bytes(prgb[spr[(x, y)]])
            elif y < HUD_TOP:
                want = border[:3]
            elif hud_want is None:
                continue                            # a HUD job is half written
            else:
                want = bytes(hrgb[hud_want[y - HUD_TOP][x]])
            if sat_pending and y < VIEW and got != want:
                pending_px += 1                     # (a sprite pixel of the previous SAT)
                continue
            checked += 1
            if y < VIEW and (x, y) in spr and got == want:
                spr_ok += 1
            if got != want:
                bad += 1
                drow[3 * x:3 * x + 3] = b"\xff\x00\xff"
        diff_rows.append(bytes(drow))
    write_png(out, 256 * 2, 212 * 2, [b"".join(r[i:i + 3] * 2 for i in range(0, 768, 3)) for r in frame for _ in (0, 1)])
    write_png(out.with_name(out.stem + "_diff.png"), 256, 212, diff_rows)
    print(f"{out}: camera ({cam_x},{cam_y}), play regs {sorted(play.items())}")
    if sat_pending:
        print(f"  SAT of this list not written yet (snapshot right after the VBLANK): sprites not checked, "
              f"{pending_px} play-area pixels skipped")
    shown = [f"{'BOB' if o['bob'] else 'RoboCop'} {o['id']} at ({o['x']},{o['y']})"
             + (f" drop {o['drop']:#04x}" if o["drop"] else "") for o in objs if o["shown"]]
    n_spr = sum(1 for (x, y) in spr if 8 <= x < 256 and 0 <= y < VIEW and y not in over)
    print(f"  sprites: {'; '.join(shown) or 'none'}; {spr_ok}/{n_spr} sprite pixels exact")
    if hud_want is None:
        print("  HUD job pending: HUD not checked")
    if over:
        print(f"  {len(over)} lines with more than 8 sprites in the SAT shown (transient), their sprite pixels "
              f"not checked: {min(over)}..{max(over)}")
    print(f"  {checked} pixels checked, {bad} differ, {border_px} right-border pixels skipped")
    want_tiles = level.with_suffix(".vram").read_bytes()[TILE_AREA[0]:TILE_AREA[1]]
    got_tiles = vram[TILE_AREA[0]:TILE_AREA[1]]
    tile_bad = [a for a in range(len(got_tiles)) if got_tiles[a] != want_tiles[a]]
    if tile_bad:
        print(f"  tile VRAM changed: {len(tile_bad)} bytes, first at {TILE_AREA[0] + tile_bad[0]:05X}h")
    return 0 if bad == 0 and not tile_bad else 1


if __name__ == "__main__":
    raise SystemExit(main())
