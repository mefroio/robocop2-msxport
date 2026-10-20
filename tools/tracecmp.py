#!/usr/bin/env python3
"""Compares the game logic of the MSX port with the original, game frame by game frame.

The reference is tools/amigaemu.py game --trace (JSON lines: the Amiga variables at each game
frame's start); the port's trace comes from tools/openmsx_rc2.tcl rc2_trace (the same values at
each tick's start, msx/msx.inc). Both must play the same joystick script (amigaemu --joy and
tools/mkrom.py JOY=...).

usage: tracecmp.py AMIGA.jsonl MSX.txt [--show N]
       tracecmp.py --ram AMIGA.jsonl MSX_RAM.txt [--show N]
       (--ram: the full game state, amigaemu.py game --trace-ram against openmsx_rc2.tcl
       rc2_trace_ram, field by field as analysis/amiga_ram.tsv lists them: the MSX mirror keeps
       words and longs little-endian)
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

# MSX trace columns (rc2_trace_hit) and the Amiga trace's name for each
MSX_COLS = ["game_frame", "player_x", "player_y", "state", "anim", "aim", "vy", "camera_x", "camera_y",
            "airborne", "joy", "record"]
SIGNED = {"player_x", "player_y", "vy", "camera_x", "camera_y"}
COMPARED = ["game_frame", "player_x", "player_y", "state", "anim", "aim", "vy", "airborne", "camera_x",
            "camera_y", "joy"]


def msx_rows(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text().split("\n"):
        if not line.strip():
            continue
        vals = [int(v) for v in line.split()]
        r = dict(zip(MSX_COLS, vals))
        for k in SIGNED:
            if r[k] >= 0x8000:
                r[k] -= 0x10000
        rows.append(r)
    return rows


FIELDS = Path(__file__).resolve().parents[1] / "analysis" / "amiga_ram.tsv"
LABELS = Path(__file__).resolve().parents[1] / "build" / "msx" / "rc2.labels"
RAM0, GLOB0 = 0x0B00, 0x8000
MSX_DUMPS = (0xD000, 0xDC00, 0xDD00, 0xEE00)     # openmsx_rc2.tcl rc2_trace_ram: one hex field each


def fields() -> list[dict]:
    """analysis/amiga_ram.tsv: ADDRESS SIZE NAME [msx=ADDRESS] [ptr=AMIGA_BASE:LABEL] [comment].
    SIZE 1, 2 or 4 (a long: two little-endian words, the high one first, on the MSX), or
    rec:PATTERN:COUNT (COUNT records of b/w fields). Without msx= the MSX address is the mirror's
    (AM/AG, msx/msx.inc). The MSX dumps are read swapped back (swapped()), so msx= addresses
    follow the mirror's rule too: a byte the port keeps at M is given as M ^ 1. ptr= compares
    pointers as offsets from AMIGA_BASE and from the MSX label."""
    out = []
    for line in FIELDS.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split()
        a, size, name = int(parts[0], 16), parts[1], parts[2]
        opt = {k: v for k, _, v in (x.partition("=") for x in parts[3:] if "=" in x and not x.startswith(";"))}
        msx = int(opt["msx"], 16) if "msx" in opt else None
        if size.startswith("rec:"):
            _, pat, count = size.split(":")
            rsize = sum(2 if c == "w" else 1 for c in pat)
            for k in range(int(count)):
                o = 0
                for j, c in enumerate(pat):
                    n = 2 if c == "w" else 1
                    out.append({"addr": a + k * rsize + o, "size": n, "name": f"{name}[{k}].{j}",
                                "msx": None if msx is None else msx + k * rsize + o})
                    o += n
            continue
        f = {"addr": a, "size": int(size), "name": name, "msx": msx}
        if "ptr" in opt:
            base, label = opt["ptr"].split(":")
            f["ptr"] = (int(base, 16), label)
        out.append(f)
    return out


def labels() -> dict[str, int]:
    out = {}
    if LABELS.exists():
        for line in LABELS.read_text().splitlines():
            if ":" in line and "equ" in line:
                k, v = line.split(":", 1)
                v = v.split("equ", 1)[1].strip().lstrip("$")
                try:
                    out[k.strip()] = int(v, 16)
                except ValueError:
                    pass
    return out


def amiga_value(row: dict, addr: int, size: int) -> int:
    if RAM0 <= addr < RAM0 + 0xBEC:
        b = bytes.fromhex(row["ram"])[addr - RAM0:addr - RAM0 + size]
    elif GLOB0 <= addr < GLOB0 + 0x100:
        b = bytes.fromhex(row["glob"])[addr - GLOB0:addr - GLOB0 + size]
    else:
        for lo, hexs in row.get("code", {}).items():
            lo = int(lo, 16)
            blk = bytes.fromhex(hexs)
            if lo <= addr < lo + len(blk):
                b = blk[addr - lo:addr - lo + size]
                break
        else:
            raise KeyError(f"${addr:x} is in no block of the Amiga trace")
    return int.from_bytes(b, "big")


def swapped(blk: bytes) -> bytes:
    """The MSX mirror keeps the Amiga's memory with every word's two bytes swapped (words
    little-endian, the byte at A at A ^ 1): swapped back it reads as the Amiga's."""
    b = bytearray(blk + b"\0" * (len(blk) & 1))
    b[0::2], b[1::2] = b[1::2], b[0::2]
    return bytes(b)


def msx_value(dumps: list[tuple[int, bytes]], addr: int, size: int) -> int:
    for base, blk in dumps:
        if base <= addr < base + len(blk):
            return int.from_bytes(blk[addr - base:addr - base + size], "big")
    raise KeyError(f"{addr:04X}h is in no block of the MSX trace")


def compare_ram(amiga: Path, msx: Path, show: int) -> int:
    ref = [json.loads(line) for line in amiga.read_text().splitlines() if line.strip()]
    got = [line.split() for line in msx.read_text().splitlines() if line.strip()]
    fl = fields()
    lab = labels()
    n = min(len(ref), len(got))
    bad = 0
    shown = 0
    for i in range(n):
        dumps = [(base, swapped(bytes.fromhex(h))) for base, h in zip(MSX_DUMPS, got[i])]
        diff = []
        for f in fl:
            a, size = f["addr"], f["size"]
            try:
                va = amiga_value(ref[i], a, size)
            except KeyError:
                continue
            m = f["msx"]
            if m is None:
                m = 0xD000 + a - RAM0 if a < GLOB0 else 0xDC00 + a - GLOB0
            vm = msx_value(dumps, m, 2 if "ptr" in f else size)   # (MSX pointers are 16-bit)
            if "ptr" in f:
                base, label = f["ptr"]
                va, vm = (va - base) & 0xFFFF, (vm - lab.get(label, 0)) & 0xFFFF
            if va != vm:
                diff.append(f"{f['name']} {va:#x}/{vm:#x}")
        if diff:
            bad += 1
            if shown < show:
                shown += 1
                print(f"game frame {i} ({ref[i]['keys'] or '-'}): " + ", ".join(diff[:12]))
    print(f"{n} game frames compared ({len(ref)} Amiga, {len(got)} MSX), {len(fl)} fields: {bad} differ")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("amiga", type=Path)
    ap.add_argument("msx", type=Path)
    ap.add_argument("--show", type=int, default=10, help="differing frames to print")
    ap.add_argument("--ram", action="store_true", help="compare the full game state (field map)")
    a = ap.parse_args()
    if a.ram:
        return compare_ram(a.amiga, a.msx, a.show)
    ref = [json.loads(line) for line in a.amiga.read_text().splitlines() if line.strip()]
    got = msx_rows(a.msx)
    n = min(len(ref), len(got))
    bad = []
    for i in range(n):
        diff = [k for k in COMPARED if ref[i][k] != got[i][k]]
        if diff:
            bad.append((i, diff))
    for i, diff in bad[:a.show]:
        print(f"game frame {i} ({ref[i]['keys'] or '-'}): " + ", ".join(f"{k} {ref[i][k]} / {got[i][k]}" for k in diff))
    print(f"{n} game frames compared ({len(ref)} Amiga, {len(got)} MSX): {len(bad)} differ"
          + (f", first at {bad[0][0]}" if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
