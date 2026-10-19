#!/usr/bin/env python3
"""Decision mockups: RoboCop in SCREEN 5 as a software sprite vs a hardware sprite.

- Single 16-colour palette (background and sprites share the palette in SCREEN 5): 9-bit
  k-means over the pixels of the map tiles (by frequency) and of RoboCop (higher weight).
- Background: the starting window of level 1 requantised to that palette.
- Software: RoboCop frames quantised to the same palette (16 colours, transparency).
- Hardware (mode 2): per line and per 16 px column, two layers (colours a and b) and the
  OR overlap (index a|b) - 3 colours per line/column; the rest maps to the nearest one.

Requires numpy and Pillow (only for this mockup). Output: build/mock/*.png
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import player  # noqa: E402


def amiga_rgb(c):
    return np.array([(c >> 8) & 15, (c >> 4) & 15, c & 15], float) / 15.0


def kmeans9(samples: np.ndarray, weights: np.ndarray, k: int = 16, iters: int = 40) -> np.ndarray:
    """Weighted k-means over unique colours, k-means++ init; colour 0 fixed to black; 3-bit result."""
    uniq, inv = np.unique(np.round(samples * 15).astype(int), axis=0, return_inverse=True)
    w = np.bincount(inv.ravel(), weights=weights)
    pts = uniq / 15.0
    rng = np.random.default_rng(1)
    cent = [np.zeros(3)]
    while len(cent) < k:
        d = np.min([((pts - c) ** 2).sum(1) for c in cent], axis=0) * w
        cent.append(pts[rng.choice(len(pts), p=d / d.sum())] if d.sum() > 0 else pts[rng.integers(len(pts))])
    cent = np.array(cent)
    for _ in range(iters):
        lab = ((pts[:, None] - cent[None]) ** 2).sum(-1).argmin(1)
        for j in range(1, k):
            m = lab == j
            if m.any():
                cent[j] = (pts[m] * w[m, None]).sum(0) / w[m].sum()
            else:
                far = (((pts[:, None] - cent[None]) ** 2).sum(-1).min(1) * w).argmax()
                cent[j] = pts[far]
        cent[0] = 0.0
    return np.round(cent * 7) / 7
def nearest(cols: np.ndarray, pal: np.ndarray) -> np.ndarray:
    return ((cols[..., None, :] - pal) ** 2).sum(-1).argmin(-1)


def main() -> int:
    out = ROOT / "build/mock"
    out.mkdir(parents=True, exist_ok=True)
    mainb = (ROOT / "build/extracted/boot/main_8000.bin").read_bytes()
    perma = (ROOT / "build/extracted/files/PERMA_05.bin").read_bytes()
    datal = (ROOT / "build/extracted/files/DATAL1_10.bin").read_bytes()
    pal31 = [struct.unpack_from(">H", mainb, 0xFFF6 - 0x8000 + 2 * i)[0] for i in range(31)]
    bgpal = np.array([[0, 0, 0]] + [amiga_rgb(c) for c in pal31[:15]])
    sppal = np.array([[0, 0, 0]] + [amiga_rgb(c) for c in pal31[16:31]])

    # starting window of level 1 (rows 38-50, columns 0-15) as Amiga indices
    win = np.zeros((13 * 16, 16 * 16), int)
    for r in range(13):
        for c in range(16):
            w = struct.unpack_from(">H", datal, 0x10000 + ((38 + r) * 160 + c) * 2)[0] & ~0x7F
            for y in range(16):
                for x in range(16):
                    v = sum(1 << p for p in range(4) if datal[w + (y * 4 + p) * 2 + (x >> 3)] & (0x80 >> (x & 7)))
                    win[r * 16 + y, c * 16 + x] = v
    # RoboCop frames: legs (walking) + torso with gun, as sprite indices
    frs = player.frames(mainb)

    def frame_img(f):
        wb, h = f["w"] // 8, f["h"]
        a = np.zeros((h, f["w"]), int)
        for y in range(h):
            for x in range(f["w"]):
                a[y, x] = sum(1 << p for p in range(4)
                              if perma[f["perma_offset"] + p * wb * h + y * wb + (x >> 3)] & (0x80 >> (x & 7)))
        return a
    pick = [frs[i] for i in (0, 2, 20, 21, 30)]
    imgs = [frame_img(f) for f in pick]

    # single palette by k-means
    bg_cols = bgpal[win.ravel()]
    sp_cols = np.concatenate([sppal[a[a > 0]] for a in imgs])
    samples = np.concatenate([bg_cols, sp_cols])
    weights = np.concatenate([np.ones(len(bg_cols)), np.full(len(sp_cols), 4.0)])
    pal = kmeans9(samples, weights)
    rgb = (pal * 255).astype(np.uint8)

    bg_q = nearest(bgpal[win], pal)
    scr = rgb[bg_q].copy()
    soft = scr.copy()
    hard = scr.copy()
    for n, a in enumerate(imgs):
        ox, oy = 24 + n * 46, 208 - a.shape[0] - 8
        q = nearest(sppal[a], pal)
        mask = a > 0
        region = soft[oy:oy + a.shape[0], ox:ox + a.shape[1]]
        region[mask] = rgb[q[mask]]
        # hardware: per line and 16 px column, the 2 most frequent colours + OR
        hq = q.copy()
        for y in range(a.shape[0]):
            for s0 in range(0, a.shape[1], 16):
                seg = q[y, s0:s0 + 16][mask[y, s0:s0 + 16]]
                if not len(seg):
                    continue
                vals, cnt = np.unique(seg, return_counts=True)
                top = list(vals[np.argsort(-cnt)][:2])
                allowed = top + ([top[0] | top[1]] if len(top) == 2 else [])
                for x in range(s0, min(s0 + 16, a.shape[1])):
                    if mask[y, x]:
                        hq[y, x] = min(allowed, key=lambda c: ((pal[c] - pal[q[y, x]]) ** 2).sum())
        region = hard[oy:oy + a.shape[0], ox:ox + a.shape[1]]
        region[mask] = rgb[hq[mask]]
    for name, im in (("software", soft), ("hardware", hard)):
        Image.fromarray(im).resize((im.shape[1] * 3, im.shape[0] * 3), Image.NEAREST).save(out / f"robocop_{name}.png")
    comb = np.concatenate([soft, np.full((soft.shape[0], 8, 3), 40, np.uint8), hard], axis=1)
    Image.fromarray(comb).resize((comb.shape[1] * 2, comb.shape[0] * 2), Image.NEAREST).save(out / "robocop_soft_vs_hard.png")
    print("single palette (3-bit RGB):", " ".join("".join(str(int(round(v * 7))) for v in c) for c in pal))
    print(out / "robocop_soft_vs_hard.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
