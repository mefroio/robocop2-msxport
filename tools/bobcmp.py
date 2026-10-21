#!/usr/bin/env python3
"""Compares the BOBs the MSX port records with the ones the original draws.

Inputs: the bench's draw_bob calls (tools/amigaemu.py game --drive D --bobs AMI.jsonl: per game
frame [A2, D4, D0, D1, minterm, drawn]) and the MSX's records at every bob_flush (EXTJOY build
driven with the same file, tools/openmsx_rc2.tcl rc2_bobs_rom: "ticks n hexrecords", the
records of msx/bob.asm bob_list). The records an MSX flush shows are those of the last tick it
ran (bob_skip: the ticks run before it in the same frame record nothing); that tick is matched
with the bench's game frame of the same number. A record is (A2, D4, x, y, mode) with mode 0
cookie-cut ($FCA), 1 colour-15 silhouette ($BFA), 2 colour-0 silhouette; both sides are
compared as multisets (the MSX keeps them per category).

usage: bobcmp.py AMI.jsonl MSX.txt [--offset K] [-v]
"""
from __future__ import annotations

import argparse
import json
import struct
from collections import Counter
from pathlib import Path

MODES = {0x0FCA: 0, 0x0BFA: 1}


def bench_frames(path: Path) -> dict[int, Counter]:
    out = {}
    for line in path.read_text().splitlines():
        row = json.loads(line)
        out[row["frame"]] = Counter((a2, d4, x, y, MODES.get(m, 2)) for a2, d4, x, y, m, drawn in row["bobs"]
                                    if drawn)
    return out


def msx_flushes(path: Path) -> list[tuple[int, Counter]]:
    out = []
    for line in path.read_text().splitlines():
        parts = line.split()
        ticks, n = int(parts[0]), int(parts[1])
        raw = bytes.fromhex(parts[2]) if n else b""
        recs = Counter()
        for k in range(n):
            r = raw[12 * k:12 * k + 12]
            a2 = r[0] | r[1] << 8 | r[2] << 16
            d4, x, y = struct.unpack_from("<Hhh", r, 3)
            recs[(a2, d4, x, y, r[9] & 15)] += 1
        out.append((ticks, recs))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bench", type=Path)
    ap.add_argument("msx", type=Path)
    ap.add_argument("--offset", type=int, default=-1, help="bench frame = MSX tick count + offset")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    ami = bench_frames(a.bench)
    bad = checked = 0
    for ticks, recs in msx_flushes(a.msx):
        f = ticks + a.offset
        if f not in ami:
            continue
        checked += 1
        want = ami[f]
        if recs != want:
            bad += 1
            if a.verbose or bad <= 12:
                print(f"tick {ticks} (bench frame {f}): MSX only {sorted((recs - want).elements())}")
                print(f"{'':>24}bench only {sorted((want - recs).elements())}")
    print(f"{checked} flushes compared, {bad} differ")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
