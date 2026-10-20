#!/usr/bin/env python3
"""Main-loop profile of the prototype from an rc2_prof log (tools/openmsx_rc2.tcl).

The log holds "name time" lines: the emulated time (seconds) at which the CPU reached each
profiled address. Times are turned into Z80 T-states (3.579545 MHz). For every main-loop
iteration (from one START label to the next) this prints how long each stage took, from
the first label of the stage to the next label in the log, and whether the iteration
published its list (list_tail) after the VBLANK it was aiming at (a late frame).

usage: proflog.py LOG [--from SECONDS]
       (profile labels: isr_vblank, camera_step, sprites_update, upload, up_patterns,
        up_colours, up_enemy, up_sat, do_publish, list_tail, mainloop)
"""
from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path

CPU_HZ = 3579545
START = "sprites_vblank"            # first label of a main-loop iteration after its VBLANK


def main() -> int:
    args = sys.argv[1:]
    start = 0.0
    if "--from" in args:
        i = args.index("--from")
        start = float(args[i + 1])
        del args[i:i + 2]
    events = []
    for line in Path(args[0]).read_text().split("\n"):
        if line.strip():
            name, t = line.split()
            events.append((float(t), name))
    events.sort()
    t0 = events[0][0] + start
    events = [e for e in events if e[0] >= t0]
    vbl = [t for t, n in events if n == "isr_vblank"]
    if len(vbl) < 2:
        print("not enough VBLANKs in the log")
        return 1
    frame = (vbl[-1] - vbl[0]) / (len(vbl) - 1)
    frame_t = frame * CPU_HZ
    print(f"{len(vbl)} VBLANKs, frame {frame * 1000:.3f} ms = {frame_t:.0f} T")

    stages = defaultdict(list)          # stage name -> durations (T)
    iters = []                          # (start after VBLANK, total, late)
    cur = None
    for k, (t, n) in enumerate(events):
        if n == "isr_vblank":
            continue
        if n == START:
            if cur is not None and "list_tail" in cur:
                iters.append(cur)
            prev_vbl = max((v for v in vbl if v <= t), default=None)
            cur = {"start": t, "vbl": prev_vbl}
        if cur is None:
            continue
        cur.setdefault(n, t)
        nxt = next((e for e in events[k + 1:] if e[1] != "isr_vblank"), None)
        if nxt is not None:
            stages[n].append((nxt[0] - t) * CPU_HZ)
    print(f"{len(iters)} iterations")
    late = 0
    starts, totals = [], []
    for it in iters:
        if it["vbl"] is None:
            continue
        target = it["vbl"] + frame          # the VBLANK that should apply this list
        if it["list_tail"] > target:
            late += 1
        starts.append((it["start"] - it["vbl"]) * CPU_HZ)
        totals.append((it["list_tail"] - it["start"]) * CPU_HZ)
    print(f"late (published after the next VBLANK): {late}/{len(starts)}")
    print(f"start after VBLANK: mean {sum(starts) / len(starts):.0f} T, max {max(starts):.0f} T")
    print(f"{START} -> list_tail: mean {sum(totals) / len(totals):.0f} T "
          f"({100 * sum(totals) / len(totals) / frame_t:.1f}% of a frame), max {max(totals):.0f} T "
          f"({100 * max(totals) / frame_t:.1f}%)")
    worst = sorted(iters, key=lambda it: it["list_tail"] - it["vbl"])[-5:] if iters else []
    print("latest publications (T after their VBLANK; stage T-states):")
    for it in reversed(worst):
        order = sorted((t, n) for n, t in it.items() if n not in ("start", "vbl"))
        parts = [f"{n} {round((order[i + 1][0] - t) * CPU_HZ)}" for i, (t, n) in enumerate(order[:-1])]
        print(f"  {round((it['list_tail'] - it['vbl']) * CPU_HZ)}: " + ", ".join(parts))
    print("stage (from the label to the next one): count, mean T, max T")
    for n, d in sorted(stages.items(), key=lambda kv: -sum(kv[1]) / max(1, len(kv[1]))):
        print(f"  {n:16s} {len(d):5d} {sum(d) / len(d):8.0f} {max(d):8.0f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
