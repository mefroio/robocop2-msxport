#!/usr/bin/env python3
"""Mockup: level 1 enemies (Amiga BOBs, tools/bobcatalog.py) as MSX hardware sprites.

Enemies are drawn into the playfield on the Amiga, so they use the level's background
palette; on the MSX their opaque pixels take the nearest joint palette entry among 1..15
(tools/msxsprites.py; 0 is transparent for sprites, the palette keeps a black there). Each frame is cut into 16 px columns (best grid offset) and 16-line spans, as
RoboCop is, in two versions:
  - one layer: one colour per line of a column (the best for its pixels; every pixel set);
  - OR pairs: per line either one colour or a pair p, q (CC = 1) giving p, q and p|q, over
    all of the palette (not only RoboCop's OR-closed 1..7).
Prints the sprites each version needs (total and per line) and writes
build/mock/enemies_sprites.png: per frame the Amiga BOB, the OR version and the one-layer
version (magenta = transparent), with RoboCop's own counts for comparison.

usage: msxmock_enemies.py
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import msxsprites  # noqa: E402
from amigahw import rgb12_to_rgb24  # noqa: E402
from planar import write_png  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PROCS = ["obj25_update", "obj26_update", "obj27_update", "obj28_update", "obj24_update", "obj29_update",
         "obj31_update", "special_vehicle_l0", "obj12_update", "obj13_update", "obj04_update"]
PAIRS = [(p, q) for p in range(1, 16) for q in range(p + 1, 16)]


def bob(ram: bytes, addr: int, wb: int, h: int) -> np.ndarray:
    """BOB [mask][p0..p3] -> background indices, -1 where the mask is clear."""
    ps = wb * h
    out = np.full((h, wb * 8), -1, int)
    for y in range(h):
        for x in range(wb * 8):
            byte, bit = y * wb + (x >> 3), 0x80 >> (x & 7)
            if ram[addr + byte] & bit:
                out[y, x] = sum(1 << p for p in range(4) if ram[addr + ps * (p + 1) + byte] & bit)
    return out


def convert(tgt: np.ndarray, D: np.ndarray, use_or: bool) -> tuple[np.ndarray, int, int]:
    """tgt = joint indices (0 = transparent). Returns (image, sprites, max per line)."""
    h, w = tgt.shape
    xs = np.nonzero((tgt > 0).any(0))[0]
    best = None
    for off in range(16):
        gx = int(xs[0]) - off
        ncol = (int(xs[-1]) - gx) // 16 + 1
        img = np.zeros_like(tgt)
        count = np.zeros(h + 16, int)
        sprites = 0
        for k in range(ncol):
            x0 = gx + 16 * k
            la, lb = [], []
            for y in range(h):
                row = np.array([tgt[y, x] if 0 <= x < w else 0 for x in range(x0, x0 + 16)])
                m = row > 0
                if not m.any():
                    continue
                la.append(y)
                t = row[m]
                one = D[t][:, 1:].sum(0)
                c = int(one.argmin()) + 1
                e1 = float(one[c - 1])
                out = np.where(m, c, 0)
                if use_or and len(set(t.tolist())) > 1:
                    pe = None
                    for p, q in PAIRS:
                        e = float(np.minimum(np.minimum(D[t, p], D[t, q]), D[t, p | q]).sum())
                        if pe is None or e < pe[0]:
                            pe = (e, p, q)
                    if pe[0] < e1:
                        _, p, q = pe
                        lb.append(y)
                        out = np.zeros(16, int)
                        for i in np.nonzero(m)[0]:
                            out[i] = min((p, q, p | q), key=lambda kk: D[row[i], kk])
                for i in range(16):
                    if 0 <= x0 + i < w and out[i]:
                        img[y, x0 + i] = out[i]
            for spans in (msxsprites.spans(la), msxsprites.spans(lb)):
                for y in spans:
                    count[y:y + 16] += 1
                sprites += len(spans)
        cost = (sprites, int(count.max()))
        if best is None or cost < best[0]:
            best = (cost, img)
    (sprites, per_line), img = best
    return img, sprites, per_line


def main() -> int:
    main_b = (ROOT / "build/extracted/boot/main_8000.bin").read_bytes()
    ram = (ROOT / "build/ram/level1_full.bin").read_bytes()
    cat = json.loads((ROOT / "build/sprites/catalog.json").read_text())
    pal_b = (ROOT / "build/msx/level1.pal").read_bytes()
    joint = np.array([[pal_b[2 * i] >> 4, pal_b[2 * i + 1] & 7, pal_b[2 * i] & 7] for i in range(16)]) / 7
    amiga = [(0, 0, 0)] + [rgb12_to_rgb24(struct.unpack_from(">H", main_b, 0xFFF6 - 0x8000 + 2 * i)[0]) for i in range(15)]
    P = msxsprites.lab(joint)
    D = ((P[:, None, :] - P[None, :, :]) ** 2).sum(-1)
    frames = []
    for r in cat["refs"]:
        if r["proc_name"] in PROCS and r["level"] in ("level1", "common", "level1+common"):
            for f in r["frames"]:
                key = (f, r["width"], r["height"])
                if key not in [k for k, _ in frames]:
                    frames.append((key, r["proc_name"]))
    rows = []
    print(f"{'routine':20s} {'size':>7s}  one layer: sprites / per line   OR pairs: sprites / per line")
    tot1 = totor = 0
    for (f, w, h), name in frames:
        src = bob(ram, f, w // 8, h)
        if (src >= 0).sum() < 8:
            continue
        # opaque pixels take the nearest of entries 1..15 (0 is transparent for sprites; the
        # joint palette keeps a black among them)
        near = msxsprites.nearest(np.array(amiga, float) / 255, joint, 1)
        tgt = np.where(src >= 0, near[np.clip(src, 0, 15)], 0)
        one, n1, l1 = convert(tgt, D, False)
        orr, n2, l2 = convert(tgt, D, True)
        tot1 += n1
        totor += n2
        print(f"{name:20s} {w:3d}x{h:<3d}  {n1:9d} / {l1:<8d}           {n2:6d} / {l2}")
        rows.append((src, one, orr, f"{name} {w}x{h}: 1 layer {n1} spr ({l1}/line), OR {n2} spr ({l2}/line)"))
    print(f"total over {len(rows)} frames: one layer {tot1}, OR {totor} sprites")
    # sheet
    S, gap = 3, 6
    rgbj = (np.round(joint * 7) * 255 / 7).astype(int)
    width = max(3 * (a.shape[1] + gap) for a, _, _, _ in rows)
    canvas = []
    for src, one, orr, label in rows:
        h = src.shape[0]
        for y in range(h):
            line = []
            for img, kind in ((src, "amiga"), (orr, "msx"), (one, "msx")):
                for x in range(img.shape[1]):
                    v = img[y, x]
                    if kind == "amiga":
                        line.append(amiga[v] if v >= 0 else (255, 0, 255))
                    else:
                        line.append(tuple(rgbj[v]) if v > 0 else (255, 0, 255))
                line += [(40, 40, 40)] * gap
            line += [(40, 40, 40)] * (width - len(line))
            canvas.append(line)
        canvas += [[(40, 40, 40)] * width for _ in range(gap)]
    out = ROOT / "build/mock/enemies_sprites.png"
    write_png(out, width * S, len(canvas) * S, [b"".join(bytes(c) * S for c in row) for row in canvas for _ in range(S)])
    print(f"{out}: per frame Amiga | OR pairs | one layer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
