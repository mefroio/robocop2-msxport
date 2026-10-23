#!/usr/bin/env python3
"""Timeline of the HUD split from an openMSX probe/watchpoint log (rc2_log in
tools/openmsx_rc2.tcl).

Lines are labelled from the line interrupt, which openMSX raises at the right border of
display line VIEW-4: RB = 1282 + 4*s VDP ticks into the line, s = ((R#18 & 15) ^ 7) - 7.
R#1/R#8/R#18 writes take effect at the next line start (tick ~144); R#2, R#23, R#26, R#27
and the palette immediately. The checks below assert the expected schedule for a play area
of VIEW lines: display off written during line VIEW-1, display on during line VIEW+3.

usage: splitlog.py LOG [--view 162] [--show N]
"""
from __future__ import annotations

import argparse
import sys

F = 21477270.0                          # VDP ticks per second
LINE = 1368


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--view", type=int, default=162, help="play-area lines (VIEW_LINES)")
    ap.add_argument("--show", type=int, default=1, help="splits to print in full")
    a = ap.parse_args()
    ev = []
    for line in open(a.log):
        p = line.split()
        ev.append((float(p[1]), p[0], [int(x) for x in p[2:]]))
    ev.sort()
    hs = [(t, x[1]) for t, k, x in ev if k == "H" and x[0] == 1]
    vs = [t for t, k, x in ev if k == "V" and x[0] == 1]
    ws = [(t, x[0]) for t, k, x in ev if k == "W"]
    print(f"{len(hs)} line interrupts, {len(vs)} VBLANK interrupts")
    ok = True
    for n, (th, r18) in enumerate(hs):
        s = ((r18 & 15) ^ 7) - 7
        rb = 1282 + 4 * s

        def where(t: float) -> tuple[int, float]:
            ticks = rb + (t - th) * F
            return a.view - 4 + int(ticks // LINE), ticks % LINE

        seq = [(t, v) for t, v in ws if th <= t <= th + 700e-6]
        blank = [where(seq[i + 1][0]) for i in range(len(seq) - 1) if seq[i][1] == 0x22 and seq[i + 1][1] == 0x81]
        show = [where(seq[i + 1][0]) for i in range(len(seq) - 1) if seq[i][1] == 0x62 and seq[i + 1][1] == 0x81]
        if n < a.show:
            print(f"line interrupt at {th:.9f} s, R#18={r18:02x} (s={s}, RB={rb})")
            for t, k, x in ev:
                if th <= t <= th + 700e-6 and k in "WR":
                    ln, tk = where(t)
                    if k == "W":
                        print(f"   W line {ln} tick {tk:5.0f}  {x[0]:02x}")
                    else:
                        print(f"   R line {ln} tick {tk:5.0f}  R#15={x[1]} HR={(x[0] >> 5) & 1}")
        good = len(blank) == 1 and blank[0][0] == a.view - 1 and len(show) == 1 and show[0][0] == a.view + 3
        ok &= good
        print(f"split {n}: display off written at line {blank[0][0] if blank else '?'} "
              f"tick {blank[0][1] if blank else 0:.0f}, display on at line {show[0][0] if show else '?'} "
              f"tick {show[0][1] if show else 0:.0f} -> {'ok' if good else 'UNEXPECTED'}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
