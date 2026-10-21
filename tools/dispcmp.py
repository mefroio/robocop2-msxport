#!/usr/bin/env python3
"""Compares two exact display records of LOCKSTEP test builds (tools/openmsx_rc2.tcl
rc2_disp_rom: "seq game_frame park_y mux SATs colour_table pattern_table pub_spr cam_x cam_y" per
new list).

Builds whose sprite engines decide alike show the same thing at the same game frames: per list,
the SAT (its first half; the second too while objects alternate, mux), and for every entry not
parked (y != park_y) its colour row and the pattern its pattern number points at (16x16: 32
bytes), and what the list records as shown (pub_spr). Slots and rows no shown entry uses may
differ (uploads of later versions under way). The scroll engines move the displayed camera in
their idle time, which LOCKSTEP does not pin down: the comparison stops at the first list whose
cameras differ (everything after it follows from that). Prints the lists that differ and how;
exit 1 when any does.

usage: dispcmp.py A.txt B.txt [-n N]
"""
from __future__ import annotations

import argparse
from pathlib import Path


def load(path: Path) -> dict[int, list[str]]:
    out = {}
    for line in path.read_text().splitlines()[1:]:          # (the first: the state the run started in)
        f = line.split()
        if len(f) >= 8:
            out.setdefault(int(f[1]), f)
    return out


def shown(rec: list[str]) -> dict:
    park, mux = int(rec[2]), int(rec[3])
    sat = bytes.fromhex(rec[4])
    col = bytes.fromhex(rec[5])
    pat = bytes.fromhex(rec[6])
    halves = (0, 128) if mux else (0,)
    ents = {}
    for h in halves:
        for e in range(32):
            y, x, p = sat[h + 4 * e:h + 4 * e + 3]
            if y == 216:
                break
            if y == park:
                continue
            slot = p // 4
            ents[(h, e)] = (y, x, p, col[16 * e:16 * e + 16].hex(), pat[32 * slot:32 * slot + 32].hex())
    return {"mux": mux, "ents": ents, "pub": rec[7]}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", type=Path)
    ap.add_argument("b", type=Path)
    ap.add_argument("-n", type=int, default=12, help="lists to detail")
    a = ap.parse_args()
    A, B = load(a.a), load(a.b)
    common = sorted(set(A) & set(B))
    bad = 0
    stop = None
    for gf in common:
        if A[gf][8:] != B[gf][8:]:
            stop = gf
            break
        x, y = shown(A[gf]), shown(B[gf])
        why = []
        if x["mux"] != y["mux"]:
            why.append(f"mux {x['mux']}/{y['mux']}")
        for k in sorted(set(x["ents"]) | set(y["ents"])):
            ea, eb = x["ents"].get(k), y["ents"].get(k)
            if ea != eb:
                if ea is None or eb is None:
                    why.append(f"entry {k}: only in {'B' if ea is None else 'A'}")
                else:
                    what = [n for n, u, v in zip(("y", "x", "pattern#", "colour", "pattern"), ea, eb) if u != v]
                    why.append(f"entry {k}: {','.join(what)}")
        if x["pub"] != y["pub"]:
            why.append("pub_spr")
        if why:
            bad += 1
            if bad <= a.n:
                print(f"game frame {gf}: {'; '.join(why[:6])}{' ...' if len(why) > 6 else ''}")
    n = len([g for g in common if stop is None or g < stop])
    if stop is not None:
        print(f"stopped at game frame {stop}: the displayed cameras differ ({'/'.join(A[stop][8:])} vs "
              f"{'/'.join(B[stop][8:])}; scroll engine timing)")
    print(f"{n} lists compared ({len(A)} / {len(B)}): {bad} differ")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
