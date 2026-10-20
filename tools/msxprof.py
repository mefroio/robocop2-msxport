#!/usr/bin/env python3
"""Sampling profile of the MSX prototype (tools/openmsx_rc2.tcl rc2_sample: "pc bank" lines).

Each sample's PC is given to the routine whose label precedes it: fixed code (4000h-7FFFh) from
the labels of build/msx/rc2.labels; the 8000h window by the bank it held (the logic modules
objects.asm / mapobj.asm, whose labels overlap, are told apart by their source files); the
A000h window as the level's logic. Only labels that start a line of the sources count (local
labels inside a routine are folded into it when --top is given).

usage: msxprof.py SAMPLES [--top] [--labels build/msx/rc2.labels]
"""
from __future__ import annotations

import argparse
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def labels(path: Path) -> dict[str, int]:
    out = {}
    for line in path.read_text().splitlines():
        m = re.match(r"(\S+):\s+equ\s+\$([0-9a-fA-F]+)", line)
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out


def file_labels(name: str, top: bool) -> set[str]:
    src = (ROOT / "msx" / name).read_text()
    names = re.findall(r"^([A-Za-z_][A-Za-z0-9_]*):(?!\s*equ)", src, re.M)
    if top:
        # a "top" routine: a label with a comment block or a blank line right above it
        lines = src.splitlines()
        tops = set()
        for i, l in enumerate(lines):
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):(?!\s*equ)", l)
            if m and (i == 0 or lines[i - 1].startswith(";") or not lines[i - 1].strip()):
                tops.add(m.group(1))
        return tops
    return set(names)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("samples", type=Path)
    ap.add_argument("--labels", type=Path, default=ROOT / "build" / "msx" / "rc2.labels")
    ap.add_argument("--top", action="store_true", help="routines only (local labels folded)")
    ap.add_argument("-n", type=int, default=40)
    a = ap.parse_args()
    lab = labels(a.labels)
    banks = {k: v for k, v in lab.items() if k.startswith("BANK_")}
    sets = {}
    for f in sorted((ROOT / "msx").glob("*.asm")):
        for n in file_labels(f.name, a.top):
            if n in lab:
                sets.setdefault(f.name, []).append((lab[n], n))
    fixed = sorted(v for k, l in sets.items() for v in l if 0x4000 <= v[0] < 0x8000)
    mod = {banks.get("BANK_LC1"): sorted(sets.get("objects.asm", [])),
           banks.get("BANK_LC2"): sorted(sets.get("mapobj.asm", []))}
    lvl = sorted(v for v in sets.get("level1.asm", []))

    def find(table, pc):
        best = None
        for addr, n in table:
            if addr <= pc:
                best = n
            else:
                break
        return best or f"{pc:04x}"

    cnt = Counter()
    total = 0
    for line in a.samples.read_text().split():
        pass
    rows = [l.split() for l in a.samples.read_text().splitlines() if l.strip()]
    for pc, bank in rows:
        pc, bank = int(pc), int(bank)
        total += 1
        if pc < 0x4000:
            name = "(page 0)"
        elif pc < 0x8000:
            name = find(fixed, pc)
        elif pc < 0xA000:
            name = find(mod[bank], pc) if bank in mod else f"(bank {bank} at 8000h)"
        elif pc < 0xC000:
            name = "L1:" + find(lvl, pc)
        else:
            name = "(page 3)"
        cnt[name] += 1
    for n, c in cnt.most_common(a.n):
        print(f"{c / total * 100:6.2f}%  {n}")
    print(f"{total} samples")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
