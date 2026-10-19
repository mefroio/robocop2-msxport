#!/usr/bin/env python3
"""Amiga (OCS) copper list decoder.

usage: copper.py BIN --base 0x8000 ADDRESS [ADDRESS ...] [--max 200]
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amigahw import CUSTOM  # noqa: E402


def decode(data: bytes, base: int, addr: int, max_ins: int = 400) -> list[str]:
    out = []
    a = addr
    for _ in range(max_ins):
        off = a - base
        if off < 0 or off + 4 > len(data):
            out.append(f"  {a:06x}  (outside the binary)")
            break
        w1, w2 = struct.unpack_from(">HH", data, off)
        if w1 == 0xFFFF and w2 == 0xFFFE:
            out.append(f"  {a:06x}  {w1:04x} {w2:04x}  END")
            break
        if w1 & 1 == 0:
            reg = w1 & 0x1FE
            name = CUSTOM.get(reg, f"${reg:03x}")
            extra = ""
            if name == "BPLCON0":
                planes = (w2 >> 12) & 7
                flags = [f for bit, f in ((11, "HAM"), (15, "HIRES"), (10, "DBLPF"), (9, "COLOR"), (2, "LACE"))
                         if w2 >> bit & 1]
                extra = f"   ; {planes} planes {' '.join(flags)}"
            elif name.startswith("COLOR"):
                extra = f"   ; RGB {w2 >> 8 & 15:x}{w2 >> 4 & 15:x}{w2 & 15:x}"
            elif name in ("DIWSTRT", "DIWSTOP"):
                extra = f"   ; V={w2 >> 8:#x} H={w2 & 0xff:#x}"
            out.append(f"  {a:06x}  {w1:04x} {w2:04x}  MOVE {name:<8} <- ${w2:04x}{extra}")
        else:
            vp, hp = w1 >> 8, w1 & 0xFE
            kind = "SKIP" if w2 & 1 else "WAIT"
            out.append(f"  {a:06x}  {w1:04x} {w2:04x}  {kind} v={vp:#04x} h={hp:#04x} mask={w2:#06x}")
        a += 4
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("bin", type=Path)
    ap.add_argument("--base", type=lambda s: int(s, 0), required=True)
    ap.add_argument("addr", type=lambda s: int(s, 0), nargs="+")
    ap.add_argument("--max", type=int, default=400)
    a = ap.parse_args()
    data = a.bin.read_bytes()
    for addr in a.addr:
        print(f"copper list @ ${addr:x}")
        print("\n".join(decode(data, a.base, addr, a.max)))
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
