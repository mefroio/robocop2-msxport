#!/usr/bin/env python3
"""Mockup 4 (accepted): RoboCop in hardware sprites as close as possible to the software version.

Starts from the SAME 16-colour palette as the software mockup (tools/msxmock.py) and exploits:
  - the colour of each layer is chosen PER LINE (mode 2 sprite colour table);
  - the order of the palette indices is free (the background tiles are remapped).
The 7 colours RoboCop uses most go to indices 1..7, an OR-closed set (any pair p,q in 1..7
has p|q in 1..7). An optimiser picks the permutation of those 7 indices that minimises the
error and, for each line of each 16 px column, the best pair (p, q) -> colours {p, q, p|q}
(or a single colour).
Output: build/mock/robocop_sw_vs_hw_opt.png (software | optimised hardware).
"""
from __future__ import annotations

import itertools
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import msxmock  # noqa: E402
import player  # noqa: E402

LUMW = np.array([0.30, 0.59, 0.11])


def perceptual(rgb: np.ndarray) -> np.ndarray:
    """sRGB [0,1] -> CIELAB (D65)."""
    c = np.where(rgb > 0.04045, ((rgb + 0.055) / 1.055) ** 2.4, rgb / 12.92)
    xyz = c @ np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]).T
    xyz /= np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def main() -> int:
    mainb = (ROOT / "build/extracted/boot/main_8000.bin").read_bytes()
    perma = (ROOT / "build/extracted/files/PERMA_05.bin").read_bytes()
    datal = (ROOT / "build/extracted/files/DATAL1_10.bin").read_bytes()
    pal31 = [struct.unpack_from(">H", mainb, 0xFFF6 - 0x8000 + 2 * i)[0] for i in range(31)]
    bgpal = np.array([[0, 0, 0]] + [msxmock.amiga_rgb(c) for c in pal31[:15]])
    sppal = np.array([[0, 0, 0]] + [msxmock.amiga_rgb(c) for c in pal31[16:31]])
    win = np.zeros((13 * 16, 256), int)
    for r in range(13):
        for c in range(16):
            w = struct.unpack_from(">H", datal, 0x10000 + ((38 + r) * 160 + c) * 2)[0] & ~0x7F
            for y in range(16):
                for x in range(16):
                    win[r * 16 + y, c * 16 + x] = sum(
                        1 << p for p in range(4) if datal[w + (y * 4 + p) * 2 + (x >> 3)] & (0x80 >> (x & 7)))
    frs = player.frames(mainb)

    def frame_img(f):
        wb, h = f["w"] // 8, f["h"]
        a = np.zeros((h, f["w"]), int)
        for y in range(h):
            for x in range(f["w"]):
                a[y, x] = sum(1 << p for p in range(4)
                              if perma[f["perma_offset"] + p * wb * h + y * wb + (x >> 3)] & (0x80 >> (x & 7)))
        return a
    imgs = [frame_img(frs[i]) for i in (0, 2, 20, 21, 30)]

    # 1) the same palette as the software mockup
    bg_cols = bgpal[win.ravel()]
    sp_cols = np.concatenate([sppal[a[a > 0]] for a in imgs])
    pal = msxmock.kmeans9(np.concatenate([bg_cols, sp_cols]),
                          np.concatenate([np.ones(len(bg_cols)), np.full(len(sp_cols), 4.0)]))
    # 2) "software" quantisation of RoboCop in that palette (the target to imitate)
    sw_idx = [msxmock.nearest(sppal[a], pal) for a in imgs]
    # duplicated palette colours become free slots; the first one gets black (index 0 is transparent in sprites)
    q9 = [tuple(int(round(v * 7)) for v in c) for c in pal]
    for i in range(1, 16):
        if q9[i] in q9[:i]:
            pal[i] = 0.0
            q9[i] = (0, 0, 0)
            break
    sw_idx = [msxmock.nearest(sppal[a], pal) for a in imgs]  # requantise with black available
    usage = np.bincount(np.concatenate([q[a > 0] for q, a in zip(sw_idx, imgs)]), minlength=16)
    usage[0] = 0
    # segments: each line of each 16 px column -> histogram over the 16 "software" colours
    segs = []
    for q, a in zip(sw_idx, imgs):
        for y in range(a.shape[0]):
            for s0 in range(0, a.shape[1], 16):
                m = a[y, s0:s0 + 16] > 0
                if m.any():
                    segs.append(np.bincount(q[y, s0:s0 + 16][m], minlength=16))
    H = np.array(segs, float)                      # S x 16
    P = perceptual(pal)
    D = ((P[:, None, :] - P[None, :, :]) ** 2).sum(-1)  # 16 x 16 colour distance

    def evaluate(perm, others):
        newpal = np.zeros(16, int)
        for slot, col in zip(range(1, 8), perm):
            newpal[slot] = col
        for slot, col in zip(range(8, 16), others):
            newpal[slot] = col
        cands = [(p, p) for p in range(1, 8)] + [(p, q) for p in range(1, 8) for q in range(p + 1, 8)]
        M = np.array([np.minimum(np.minimum(D[:, newpal[p]], D[:, newpal[q]]), D[:, newpal[p | q]])
                      for p, q in cands])
        err = H @ M.T
        return err.min(1).sum(), newpal, cands, err.argmin(1)

    def best_perm(robo):
        others = [i for i in range(1, 16) if i not in robo]
        best = None
        for perm in itertools.permutations(robo):
            r = evaluate(perm, others)
            if best is None or r[0] < best[0]:
                best = r
        return best

    pool = [i for i in range(1, 16) if usage[i] > 0]
    robo = sorted(pool, key=lambda i: -usage[i])[:7]
    best = best_perm(robo)
    improved = True
    while improved:
        improved = False
        for out_c in list(robo):
            for in_c in pool:
                if in_c in robo:
                    continue
                trial = [in_c if c == out_c else c for c in robo]
                r = best_perm(trial)
                if r[0] < best[0] - 1e-9:
                    best, robo, improved = r, trial, True
                    break
            if improved:
                break
    e, newpal, cands, choice = best
    print(f"error (optimised hardware) = {e:.2f}; indices 1..7 = " +
          " ".join(''.join(str(int(round(v * 7))) for v in pal[newpal[i]]) for i in range(1, 8)))

    rgb = (pal * 255).astype(np.uint8)
    base = rgb[msxmock.nearest(bgpal[win], pal)]
    soft, hard = base.copy(), base.copy()
    k = 0
    for n, (q, a) in enumerate(zip(sw_idx, imgs)):
        ox, oy = 24 + n * 46, 208 - a.shape[0] - 8
        mask = a > 0
        rs = soft[oy:oy + a.shape[0], ox:ox + a.shape[1]]
        rs[mask] = rgb[q[mask]]
        rh = hard[oy:oy + a.shape[0], ox:ox + a.shape[1]]
        for y in range(a.shape[0]):
            for s0 in range(0, a.shape[1], 16):
                m = a[y, s0:s0 + 16] > 0
                if not m.any():
                    continue
                p_, q_ = cands[choice[k]]
                k += 1
                allowed = [newpal[p_], newpal[q_], newpal[p_ | q_]]
                for x in range(s0, min(s0 + 16, a.shape[1])):
                    if a[y, x]:
                        c = q[y, x]
                        rh[y, x] = rgb[min(allowed, key=lambda t: D[c, t])]
    sep = np.full((208, 6, 3), 40, np.uint8)
    comb = np.concatenate([soft, sep, hard], axis=1)
    Image.fromarray(comb).resize((comb.shape[1] * 2, comb.shape[0] * 2), Image.NEAREST).save(
        ROOT / "build/mock/robocop_sw_vs_hw_opt.png")
    crop = np.concatenate([soft[120:208, 0:256], np.full((88, 6, 3), 40, np.uint8), hard[120:208, 0:256]], axis=1)
    Image.fromarray(crop).resize((crop.shape[1] * 4, crop.shape[0] * 4), Image.NEAREST).save(
        ROOT / "build/mock/robocop_sw_vs_hw_opt_zoom.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
