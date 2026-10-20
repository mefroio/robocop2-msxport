#!/usr/bin/env python3
"""Code and state coverage of the original game on the execution bench (tools/amigaemu.py).

Plays a level from its RAM image (one or more runs) and records:
- every basic block executed in the main code ($8000-$125FF): the code a level really runs, i.e.
  what the MSX port must carry (to be read in REA/Ghidra; executed code Ghidra did not decode
  becomes a seed, see --seeds);
- every CPU write into the main code's area (variables and tables kept inside the code: state
  the port must mirror besides $B00-$16EB and $8000-$80FF);
- every CPU write elsewhere in RAM, by writing instruction (address range and count), outside
  the variables already mirrored and the stack;
- every BOB draw_bob ($AB08) drew (it returned through $AC40): graphics address A2 and BLTSIZE
  D4, with how many times (the level's BOB frames for tools/msxsprites.py --drawn).

Runs: --run "SCRIPT[;tele=F:X:Y][;god]" (SCRIPT = the joystick script of amigaemu.py game,
F:C:KEYS,...; tele moves RoboCop and the camera to world X, Y at game frame F; god keeps the
energy and the lives full and never lets the level end, so a long run survives). Teleports and
god mode change the game's state: they are for coverage only, never for the reference traces.

usage: amigacov.py --ram build/ram/level1_full.bin --gframes 2000 --run "..." [--run ...] OUT.json
       amigacov.py --report OUT.json [--rea build/rea/lin.json] [--seeds]
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import amigaemu  # noqa: E402
from unicorn import UC_HOOK_BLOCK, UC_HOOK_MEM_WRITE  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CODE = (0x8000, 0x12600)
MIRRORED = ((0x0B00, 0x16EC), (0x8000, 0x8100))
STACK = (0x7F000, 0x80000)


def parse_run(spec: str) -> dict:
    run = {"script": [], "tele": [], "god": False}
    for part in spec.split(";"):
        part = part.strip()
        if not part:
            continue
        if part == "god":
            run["god"] = True
        elif part.startswith("tele="):
            for t in part[5:].split(","):
                f, x, y = (int(v, 0) for v in t.split(":"))
                run["tele"].append((f, x, y))
        else:
            for item in filter(None, part.split(",")):
                f, c, k = item.split(":")
                run["script"].append((int(f), int(c), k))
    return run


def play(ram: Path, frames: int, run: dict, cov: dict) -> None:
    b = amigaemu.GameBench(ROOT / "build" / "extracted", ram)
    b.start_level()
    blocks = cov["blocks"]
    code_w = cov["code_writes"]
    ram_w = cov["ram_writes"]
    state = {"gf": 0}

    def on_block(uc, address, size, user_data):
        k = (address, size)
        if k not in blocks:
            blocks[k] = state["gf"]

    def on_write(uc, access, address, size, value, user_data):
        pc = uc.reg_read(amigaemu.UC_M68K_REG_PC)
        if CODE[0] <= address < CODE[1]:
            e = code_w.setdefault(address, [0, set(), state["gf"]])
            e[0] += 1
            e[1].add(pc)
            return
        for lo, hi in MIRRORED:
            if lo <= address < hi:
                return
        if STACK[0] <= address < STACK[1]:
            return
        e = ram_w.setdefault(pc, [address, address + size, 0])
        e[0] = min(e[0], address)
        e[1] = max(e[1], address + size)
        e[2] += 1

    def on_frame(uc, address, size, user_data):
        gf = state["gf"]
        for f, x, y in run["tele"]:
            if f == gf:
                uc.mem_write(0x15D0, struct.pack(">h", x))
                uc.mem_write(0x15D4, struct.pack(">h", y))
                uc.mem_write(0x0B04, struct.pack(">h", max(0, min(0x8E0, x - 0x108))))
                uc.mem_write(0x0B06, struct.pack(">h", max(0, y - 0x70)))
        if run["god"]:
            uc.mem_write(0x169A, struct.pack(">h", 0x100))
            uc.mem_write(0x8034, struct.pack(">h", 2))
            uc.mem_write(0x16C4, struct.pack(">h", 0x100))     # the level's end never comes
        state["gf"] = gf + 1

    bobs = cov["bobs"]
    cur = {}

    def on_draw(uc, address, size, user_data):          # draw_bob ($AB08): A2, D4
        cur["k"] = (uc.reg_read(amigaemu.a_reg(2)) & 0xFFFFFF, uc.reg_read(amigaemu.d_reg(4)) & 0xFFFF)

    def on_drawn(uc, address, size, user_data):         # its drawn exit ($AC40)
        bobs[cur["k"]] = bobs.get(cur["k"], 0) + 1

    b.uc.hook_add(amigaemu.UC_HOOK_CODE, on_draw, None, 0xAB08, 0xAB09)
    b.uc.hook_add(amigaemu.UC_HOOK_CODE, on_drawn, None, 0xAC40, 0xAC41)
    b.uc.hook_add(UC_HOOK_BLOCK, on_block, None, CODE[0], CODE[1] - 1)
    b.uc.hook_add(UC_HOOK_MEM_WRITE, on_write, None, 0, 0x7FFFF)
    b.uc.hook_add(amigaemu.UC_HOOK_CODE, on_frame, None, amigaemu.GAME_FRAME_START,
                  amigaemu.GAME_FRAME_START + 1)
    try:
        b.play(frames, run["script"])
    except RuntimeError as e:                               # (the bench lacks some hardware)
        print(f"run stopped at game frame {state['gf']}: {str(e).splitlines()[0]}")
    cov["runs"].append({"frames": state["gf"], "level": b.read_word(0x8050), "player": [
        struct.unpack(">h", b.uc.mem_read(0x15D0, 2))[0], struct.unpack(">h", b.uc.mem_read(0x15D4, 2))[0]]})


def merge_ranges(blocks) -> list[list[int]]:
    rs = sorted([a, a + s] for a, s in blocks)
    out: list[list[int]] = []
    for lo, hi in rs:
        if out and lo <= out[-1][1]:
            out[-1][1] = max(out[-1][1], hi)
        else:
            out.append([lo, hi])
    return out


def collect(a) -> int:
    cov = {"blocks": {}, "code_writes": {}, "ram_writes": {}, "runs": [], "bobs": {}}
    for spec in a.run or [""]:
        play(a.ram, a.gframes, parse_run(spec), cov)
    out = {
        "ram": str(a.ram), "runs": cov["runs"],
        "executed": merge_ranges(cov["blocks"]),
        "blocks": sorted([a_, s, f] for (a_, s), f in cov["blocks"].items()),
        "code_writes": {f"{k:x}": [v[0], sorted(f"{p:x}" for p in v[1]), v[2]]
                        for k, v in sorted(cov["code_writes"].items())},
        "ram_writes": {f"{k:x}": [f"{v[0]:x}", f"{v[1]:x}", v[2]] for k, v in sorted(cov["ram_writes"].items())},
        "bobs": [{"addr": a2, "bltsize": d4, "w": ((d4 & 63) - 1) * 16, "h": d4 >> 6, "count": n}
                 for (a2, d4), n in sorted(cov["bobs"].items())],
    }
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(out, indent=0))
    n = sum(hi - lo for lo, hi in out["executed"])
    print(f"{a.out}: {len(out['blocks'])} blocks, {len(out['executed'])} ranges, {n} bytes of code executed; "
          f"{len(out['code_writes'])} code-area addresses written; {len(out['ram_writes'])} other writers; "
          f"{len(out['bobs'])} BOB frames drawn")
    return 0


def report(a) -> int:
    cov = json.loads(a.report.read_text())
    rea = set()
    if a.rea and a.rea.exists():
        rea = {int(k) for k in json.loads(a.rea.read_text())}
    gaps = []
    for lo, hi in cov["executed"]:
        if rea and not any(x in rea for x in range(lo, hi, 2)):
            gaps.append((lo, hi))
        elif rea and lo not in rea:
            gaps.append((lo, hi))
    print(f"executed ranges: {len(cov['executed'])}; not decoded by Ghidra (start missing): {len(gaps)}")
    for lo, hi in gaps:
        print(f"  {lo:05x}-{hi:05x}")
    if a.seeds:
        for lo, _hi in gaps:
            print(f"+code {lo:x}")
    print("code-area writes (address: count, writers):")
    rows = sorted(cov["code_writes"].items(), key=lambda kv: int(kv[0], 16))
    for k, (n, pcs, f0) in rows:
        print(f"  {k}: {n:6d}  {' '.join(pcs[:6])}{' ...' if len(pcs) > 6 else ''}  (first gf {f0})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ram", type=Path, default=ROOT / "build" / "ram" / "level1_full.bin")
    ap.add_argument("--gframes", type=int, default=1000)
    ap.add_argument("--run", action="append", help="SCRIPT[;tele=F:X:Y,...][;god]")
    ap.add_argument("--report", type=Path, help="prints a coverage file")
    ap.add_argument("--rea", type=Path, help="instruction addresses Ghidra decoded (JSON object keyed by address)")
    ap.add_argument("--seeds", action="store_true", help="with --report: seed lines for the gaps")
    ap.add_argument("out", type=Path, nargs="?")
    a = ap.parse_args()
    if a.report:
        return report(a)
    if not a.out:
        ap.error("OUT.json is required")
    return collect(a)


if __name__ == "__main__":
    raise SystemExit(main())
