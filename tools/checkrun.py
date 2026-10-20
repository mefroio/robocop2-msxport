#!/usr/bin/env python3
"""Checks every snapshot of a run (tools/openmsx_rc2.tcl rc2_snaps) with tools/msxframe.py and
prints one line per snapshot plus the main-loop counters (RAM C000h-C0FFh, msx/msx.inc).

usage: checkrun.py RUNDIR LEVEL_PREFIX HUD_PREFIX   (e.g. build/snap/msx2_run build/msx/level1 build/msx/hud)
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    run, level, hud = (Path(a) for a in sys.argv[1:4])
    bad = 0
    for snap in sorted(p for p in run.iterdir() if (p / "vram.bin").exists()):
        out = run / f"{snap.name}.png"
        r = subprocess.run([sys.executable, "-I", str(ROOT / "tools/msxframe.py"), str(snap), str(level), str(hud), str(out)],
                           capture_output=True, text=True)
        ram = (snap / "ram.bin").read_bytes()
        w = lambda o: ram[o] | ram[o + 1] << 8  # noqa: E731
        lines = [ln.strip() for ln in r.stdout.splitlines()]
        print(f"{snap.name}: frame {w(0x08)} late {w(0x0A)} stall {w(0x26)} vstall {w(0x28)} tiles {w(0x0C)} | "
              + " | ".join(lines[1:]))
        if r.returncode != 0:
            bad += 1
            if r.stderr:
                print(r.stderr.strip())
    print(f"{bad} snapshot(s) with differences")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
