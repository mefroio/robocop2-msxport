#!/usr/bin/env python3
"""Builds images of the Amiga RAM during a level, to open in REA/Ghidra.

Each file goes to its destination from the loader name table. Outputs:
  <out>_full.bin : RAM from $0 to $7FFFF; $0 holds JMP $8000 (REA entry = 0x0)
  <out>_8000.bin : RAM from $8000 to $7FFFF (REA entry = 0x8000)

usage: ramimage.py build/extracted build/ram/level1 MU1 DATAL1 SPERMA PERMA RB1
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

CHIP = 0x80000


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    x, out = Path(argv[1]), Path(argv[2])
    files = {}
    for f in json.loads((x / "manifest.json").read_text())["files"]:
        files.setdefault(f["name"], f)  # first entry (PUZL of disk 1)
    ram = bytearray(CHIP)
    ram[0:6] = bytes.fromhex("4ef900008000")  # JMP $8000
    for path, addr in (("boot/loader_100.bin", 0x100), ("boot/loader_300.bin", 0x300), ("boot/main_8000.bin", 0x8000)):
        d = (x / path).read_bytes()
        ram[addr:addr + len(d)] = d
    struct.pack_into(">I", ram, 0xC0, 0x100)
    for name in argv[3:]:
        f = files[name]
        d = (x / f["file"]).read_bytes()
        a = f["load_address"]
        ram[a:a + len(d)] = d
        print(f"  {name:7} ${a:05x}-${a + len(d):05x}")
    out.parent.mkdir(parents=True, exist_ok=True)
    Path(f"{out}_full.bin").write_bytes(ram)
    Path(f"{out}_8000.bin").write_bytes(ram[0x8000:])
    print(f"{out}_full.bin, {out}_8000.bin")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
