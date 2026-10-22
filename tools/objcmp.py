#!/usr/bin/env python3
"""Compares the BOB sprite objects the MSX shows with the BOBs the original draws.

Inputs: the bench's draw_bob calls (tools/amigaemu.py game --drive D --bobs AMI.jsonl) and, from
the EXTJOY build driven with the same file, what every new register list shows
(tools/openmsx_rc2.tcl rc2_objs_rom: "seq cam_x cam_y game_frame pub_spr"). A list published
with game frame g shows the tick that started at g - 1: the BOBs the bench drew in that frame,
each as the frame id the level's table gives its A2 and D4 (build/msx/robocop.json, as
tools/mkrom.py's BOBHASH) at screen x = x - 135 - camera x, y = y - camera y (msx/bob.asm
bf_show). Per list, every drawn BOB is
  - exact: an object shows that frame there (or 1-2 lines off: an entry would have had SAT y
    216, which ends the table, so sprites.asm sb_hit moved the whole object);
  - late: an object at that place shows another frame (an older one whose new frame is still
    on its way to VRAM: harmless when it is the same BOB; "late, other size" when the frame
    shown has another size, most likely another BOB's: legs for a torso);
  - missing: nothing there; with the builds that record why (sprites.asm sb_want), "missing,
    loading" when an object wants that frame there but no version of it is on screen yet,
    "missing, left out" when the sprite budget left that object out of the tick; "missing, no
    frame" when the sprite data has no such frame at all (bob_flush hides it: the ride's pickups
    until 2026-10-21), the hit spark's frames and the play-field BOBs apart;
BOBs wholly outside the MSX play area (256 x 163, the left 8 columns masked) are not counted;
and objects showing something the bench did not draw there are extra (wrong places: the worst).
Objects alternating between frames (budget) count as shown.

usage: objcmp.py AMI.jsonl MSX_OBJS.txt [-v]
"""
from __future__ import annotations

import argparse
import json
import struct
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_OBJ = 16
VIEW = 163


def frame_table() -> tuple[dict[tuple[int, int], int], dict[int, tuple[int, int]], set[tuple[int, int]]]:
    """(A2, D4) -> frame id, frame id -> size, and the (A2, D4) that are no sprite object by design
    (the hit spark's frames, the BOBs drawn into the play field)."""
    meta = json.loads((ROOT / "build/msx/robocop.json").read_text())
    key = lambda f: (f["addr"], (f["h"] << 6) | (f["w"] // 16 + 1))   # noqa: E731
    bobs = meta["bobs"]
    other = {key(f) for f in bobs if f.get("spark")} | {key(f) for f in meta.get("field", [])}
    return ({key(f): f["id"] for f in bobs if not f.get("spark")}, {f["id"]: (f["w"], f["h"]) for f in bobs},
            other)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bench", type=Path)
    ap.add_argument("msx", type=Path)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    table, size, other = frame_table()
    ami = {}
    for line in a.bench.read_text().splitlines():
        row = json.loads(line)
        ami[row["game_frame"]] = [b for b in row["bobs"] if b[5]]
    tot = Counter()
    shown_lists = 0
    for line in a.msx.read_text().splitlines():
        seq, cam_x, cam_y, gf, hexobjs = line.split()
        cam_x, cam_y, gf = int(cam_x), int(cam_y), int(gf)
        if gf - 1 not in ami:
            continue
        shown_lists += 1
        raw = bytes.fromhex(hexobjs)
        objs = []
        wanted = {}
        for k in range(1, MAX_OBJ - 1):
            flags, ident, drop, x, y = struct.unpack_from("<BHBhh", raw, 8 * k)
            if flags & 0x80 and flags & 1:
                objs.append((ident, x, y))
            elif flags & 0x20 and flags & 1:
                wanted[(ident, x, y)] = "missing, left out" if flags & 0x10 else "missing, loading"
        want = []
        res = Counter()
        problems = []
        for a2, d4, x, y, minterm, drawn in ami[gf - 1]:
            fid = table.get((a2, d4))
            sx, sy = x - 135 - cam_x, y - cam_y
            if fid is None:
                w, h = ((d4 & 63) - 1) * 16, d4 >> 6
                if (a2, d4) not in other and not (sx + w <= 8 or sx >= 256 or sy + h <= 0 or sy >= VIEW):
                    res["missing, no frame"] += 1           # (a frame the sprite data lacks: never
                    problems.append(f"NO FRAME {a2:x}:{w}x{h} at ({sx},{sy})")   # shown at all)
                continue
            w, h = size[fid]
            if sx + w <= 8 or sx >= 256 or sy + h <= 0 or sy >= VIEW:
                continue                                    # (outside the MSX play area)
            want.append((fid, sx, sy))
        left = list(objs)
        rest = []
        for fid, x, y in want:                              # (BOBs drawn at one place, as the
            if (fid, x, y) in left:                         # parts of an explosion: exact ones
                left.remove((fid, x, y))                    # first, then the same size, then
                res["exact"] += 1                           # any other)
            else:
                rest.append((fid, x, y))
        todo, rest = rest, []
        for fid, x, y in todo:                              # (moved off SAT y 216)
            at = [o for o in left if o[0] == fid and o[1] == x and abs(o[2] - y) <= 2]
            if at:
                left.remove(at[0])
                res["exact"] += 1
            else:
                rest.append((fid, x, y))
        for same in (True, False):
            todo, rest = rest, []
            for fid, x, y in todo:
                at = [o for o in left if (o[1], o[2]) == (x, y)
                      and (size.get(o[0]) == size.get(fid)) == same]
                if not at:
                    rest.append((fid, x, y))
                    continue
                left.remove(at[0])
                kind = "late" if same else "late, other size"
                res[kind] += 1
                problems.append(f"{kind} {at[0][0]}->{fid} at ({x},{y})")
        for fid, x, y in rest:
            kind = wanted.get((fid, x, y), "missing")
            res[kind] += 1
            problems.append(f"{kind} {fid} at ({x},{y})")
        for o in left:
            w, h = size[o[0]]
            if o[1] + w <= 8 or o[1] >= 256 or o[2] + h <= 0 or o[2] >= VIEW:
                continue                                    # (outside the play area: not seen)
            res["extra"] += 1
            problems.append(f"EXTRA {o[0]} at ({o[1]},{o[2]})")
        tot.update(res)
        if a.verbose or res["extra"] or res["late, other size"] or res["missing, no frame"]:
            print(f"list {seq} frame {gf - 1}: {dict(res)} {'; '.join(problems)}")
    print(f"{shown_lists} lists: {dict(tot)}")
    return 1 if tot["extra"] or tot["late, other size"] or tot["missing, no frame"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
