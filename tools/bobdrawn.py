#!/usr/bin/env python3
"""BOB frames the original draws, collected on the execution bench (tools/amigaemu.py).

Plays a level from its RAM image with joystick scripts and records every BOB draw_bob ($AB08)
actually drew (it returned through $AC40): graphics address A2 and BLTSIZE D4 -> width
((D4 & 63) - 1) * 16, height D4 >> 6, with the call site and the number of times. Merged into
the BOB frames tools/msxsprites.py converts (--drawn), next to the static catalogue
(tools/bobcatalog.py) and the frames the ported code's tables give.

usage: bobdrawn.py --ram build/ram/level1_full.bin --frames 900 [--script F:C:KEYS,... ...] OUT.json
       (several --script runs are played one after the other from the level start; OUT gets
       the union, merged with what OUT already holds)
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import amigaemu  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DRAW, DRAWN = 0xAB08, 0xAC40


def play(ram: Path, frames: int, script: list[tuple[int, int, str]]) -> dict:
    b = amigaemu.GameBench(ROOT / "build" / "extracted", ram)
    b.start_level()
    cur: dict = {}
    seen: dict = defaultdict(lambda: {"count": 0, "sites": set()})

    def on_draw(uc, address, size, user_data):
        cur["a2"] = uc.reg_read(amigaemu.a_reg(2)) & 0xFFFFFF
        cur["d4"] = uc.reg_read(amigaemu.d_reg(4)) & 0xFFFF
        cur["site"] = b.read_long(uc.reg_read(amigaemu.UC_M68K_REG_A7))

    def on_drawn(uc, address, size, user_data):
        e = seen[(cur["a2"], cur["d4"])]
        e["count"] += 1
        e["sites"].add(cur["site"])

    b.uc.hook_add(amigaemu.UC_HOOK_CODE, on_draw, None, DRAW, DRAW + 1)
    b.uc.hook_add(amigaemu.UC_HOOK_CODE, on_drawn, None, DRAWN, DRAWN + 1)
    b.play(frames, script)
    return seen


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ram", type=Path, required=True)
    ap.add_argument("--frames", type=int, default=900)
    ap.add_argument("--script", action="append", default=[""], help="F:C:KEYS,... (one run per option)")
    ap.add_argument("out", type=Path)
    a = ap.parse_args()
    total: dict = {}
    if a.out.exists():
        for f in json.loads(a.out.read_text())["frames"]:
            total[(f["addr"], f["bltsize"])] = {"count": f["count"], "sites": set(f["sites"])}
    for s in a.script:
        script = []
        for item in filter(None, s.split(",")):
            f, c, k = item.split(":")
            script.append((int(f), int(c), k))
        for key, e in play(a.ram, a.frames, script).items():
            t = total.setdefault(key, {"count": 0, "sites": set()})
            t["count"] += e["count"]
            t["sites"] |= e["sites"]
    frames = [{"addr": a2, "bltsize": d4, "w": ((d4 & 63) - 1) * 16, "h": d4 >> 6, "count": e["count"],
               "sites": sorted(e["sites"])} for (a2, d4), e in sorted(total.items())]
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps({"ram": str(a.ram), "frames": frames}, indent=1))
    print(f"{a.out}: {len(frames)} distinct BOB frames drawn")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
