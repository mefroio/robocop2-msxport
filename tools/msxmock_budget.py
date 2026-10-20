#!/usr/bin/env python3
"""Mockup 5: the composed RoboCop (base + head + arm, as draw_player builds it) in hardware
sprites with the OR technique of mockup 4, with and without a per-line sprite budget.

Same joint palette procedure as tools/msxmock_or3.py (k-means over the background window and
the sprite pixels, a duplicate slot freed for black, RoboCop's 7 main colours at the
OR-closed indices 1..7). The composition is cut into 16x16 blocks (grid offset chosen per
composition); each block is one sprite (one colour per line, any of 1..15) or an OR pair
(colours p, q, p|q per line, p, q in 1..7). With a budget, blocks start as single sprites and
the upgrades to pairs with the largest error reduction are applied while every line stays
within the cap (the MSX shows at most 8 sprites per line, shared with enemies and shots).

Output: build/mock/robocop_budget.png (software | pairs everywhere | at most 4 per line |
at most 3 per line), sprite counts on the console. Requires numpy and Pillow.
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
from msxmock_or3 import perceptual  # noqa: E402

SAMPLES = [(2, 2), (2, 0), (8, 3), (38, 2), (20, 0)]   # (frame record, aim)
CAPS = [None, 4, 3]


def joint_palette(bg_cols: np.ndarray, sp_cols: np.ndarray):
    """k-means palette; one of the slots 1..15 is made black, because index 0 is transparent
    for sprites (a duplicate slot if there is one, else the closer of the two closest colours)."""
    pal = msxmock.kmeans9(np.concatenate([bg_cols, sp_cols]),
                          np.concatenate([np.ones(len(bg_cols)), np.full(len(sp_cols), 4.0)]))
    if not any((pal[i] == 0).all() for i in range(1, 16)):
        q9 = [tuple(int(round(v * 7)) for v in c) for c in pal]
        dup = [i for i in range(1, 16) if q9[i] in q9[:i]]
        if dup:
            pal[dup[0]] = 0.0
        else:
            P = perceptual(pal)
            d = ((P[1:, None, :] - P[None, 1:, :]) ** 2).sum(-1) + np.eye(15) * 1e9
            i, j = np.unravel_index(d.argmin(), d.shape)
            pal[1 + max(i, j)] = 0.0
    return pal


def sprite_nearest(cols: np.ndarray, pal: np.ndarray) -> np.ndarray:
    """Nearest palette index for sprite pixels: 1..15 only (0 is transparent)."""
    return msxmock.nearest(cols, pal[1:]) + 1


def order_palette(pal: np.ndarray, imgs: list[np.ndarray], sppal: np.ndarray) -> np.ndarray:
    """Final palette with RoboCop's 7 most useful colours at indices 1..7 (mockup 4 search)."""
    sw = [sprite_nearest(sppal[a], pal) for a in imgs]
    usage = np.bincount(np.concatenate([q[a > 0] for q, a in zip(sw, imgs)]), minlength=16)
    usage[0] = 0
    segs = []
    for q, a in zip(sw, imgs):
        for y in range(a.shape[0]):
            for s0 in range(0, a.shape[1], 16):
                m = a[y, s0:s0 + 16] > 0
                if m.any():
                    segs.append(np.bincount(q[y, s0:s0 + 16][m], minlength=16))
    H = np.array(segs, float)
    P = perceptual(pal)
    D = ((P[:, None, :] - P[None, :, :]) ** 2).sum(-1)
    cands = [(p, p) for p in range(1, 8)] + [(p, q) for p in range(1, 8) for q in range(p + 1, 8)]

    def evaluate(robo):
        best = None
        others = [i for i in range(1, 16) if i not in robo]
        for perm in itertools.permutations(robo):
            newpal = np.zeros(16, int)
            newpal[1:8] = perm
            newpal[8:16] = others + [0] * (8 - len(others))
            M = np.array([np.minimum(np.minimum(D[:, newpal[p]], D[:, newpal[q]]), D[:, newpal[p | q]])
                          for p, q in cands])
            e = (H @ M.T).min(1).sum()
            if best is None or e < best[0]:
                best = (e, newpal)
        return best

    pool = [i for i in range(1, 16) if usage[i] > 0]
    robo = sorted(pool, key=lambda i: -usage[i])[:7]
    best = evaluate(robo)
    improved = True
    while improved:
        improved = False
        for out_c in list(robo):
            for in_c in pool:
                if in_c in robo:
                    continue
                trial = [in_c if c == out_c else c for c in robo]
                r = evaluate(trial)
                if r[0] < best[0] - 1e-9:
                    best, robo, improved = r, trial, True
                    break
            if improved:
                break
    return pal[best[1]]


def blocks_for(target: np.ndarray, D: np.ndarray):
    """Per 16x16 block of the composition: errors and colours for 1 sprite and for an OR pair."""
    ys, xs = np.nonzero(target)
    y0, x0 = ys.min(), xs.min()
    pairs = [(p, q) for p in range(1, 8) for q in range(p, 8)]
    best = None
    for off in range(16):
        gx = x0 - off
        ncol = (xs.max() - gx) // 16 + 1
        out = []
        for by in range(y0, ys.max() + 1, 16):
            for c in range(ncol):
                blk = target[by:by + 16, max(gx + 16 * c, 0):gx + 16 * c + 16]
                if not blk.any():
                    continue
                e1, e2, col1, col2 = 0.0, 0.0, [], []
                for row in blk:
                    t = row[row > 0]
                    if not len(t):
                        col1.append(0)
                        col2.append((0, 0))
                        continue
                    one = D[t][:, 1:].sum(0)
                    k = int(one.argmin()) + 1
                    e1 += one[k - 1]
                    col1.append(k)
                    two = [np.minimum(np.minimum(D[t, p], D[t, q]), D[t, p | q]).sum() for p, q in pairs]
                    j = int(np.argmin(two))
                    e2 += two[j]
                    col2.append(pairs[j])
                out.append({"y": by, "x": gx + 16 * c, "e1": e1, "e2": e2, "c1": col1, "c2": col2})
        if best is None or len(out) < len(best):
            best = out
    return best


def render(target: np.ndarray, blocks: list[dict], layers: list[int], D: np.ndarray) -> np.ndarray:
    img = np.zeros_like(target)
    for b, n in zip(blocks, layers):
        for dy in range(16):
            y = b["y"] + dy
            if y >= target.shape[0]:
                break
            for x in range(max(b["x"], 0), min(b["x"] + 16, target.shape[1])):
                t = target[y, x]
                if not t:
                    continue
                if n == 1:
                    img[y, x] = b["c1"][dy]
                else:
                    p, q = b["c2"][dy]
                    img[y, x] = min((p, q, p | q), key=lambda c: D[t, c])
    return img


def budget(blocks: list[dict], height: int, cap: int | None) -> list[int]:
    layers = [1] * len(blocks)
    if cap is None:
        return [2 if b["e2"] < b["e1"] else 1 for b in blocks]
    count = np.zeros(height + 32, int)
    for b in blocks:
        count[b["y"]:b["y"] + 16] += 1
    if count.max() > cap:
        return layers                         # cannot even fit one sprite per block
    for i in sorted(range(len(blocks)), key=lambda i: blocks[i]["e2"] - blocks[i]["e1"]):
        b = blocks[i]
        if b["e2"] >= b["e1"]:
            break
        if (count[b["y"]:b["y"] + 16] + 1).max() <= cap:
            count[b["y"]:b["y"] + 16] += 1
            layers[i] = 2
    return layers


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
    g = player.Game(mainb, perma)
    recs = g.records()
    imgs = [np.array(g.compose(recs[i], aim)) for i, aim in SAMPLES]
    pal = joint_palette(bgpal[win.ravel()], np.concatenate([sppal[a[a > 0]] for a in imgs]))
    pal = order_palette(pal, imgs, sppal)
    D = (lambda P: ((P[:, None, :] - P[None, :, :]) ** 2).sum(-1))(perceptual(pal))
    rgb = (pal * 255).astype(np.uint8)
    base = rgb[msxmock.nearest(bgpal[win], pal)]
    tiles = []
    for (i, aim), a in zip(SAMPLES, imgs):
        target = np.where(a > 0, sprite_nearest(sppal[a], pal), 0)
        target[a == 0] = 0
        blocks = blocks_for(target, D)
        row = []
        crop = base[100:100 + 80, 40:40 + 72].copy()
        sw = crop.copy()
        m = target > 0
        sw[4:4 + 73, 4:4 + 64][m] = rgb[target[m]]
        row.append(sw)
        info = []
        for cap in CAPS:
            layers = budget(blocks, target.shape[0], cap)
            hw = render(target, blocks, layers, D)
            im = crop.copy()
            im[4:4 + 73, 4:4 + 64][m] = rgb[hw[m]]
            row.append(im)
            per_line = np.zeros(target.shape[0] + 32, int)
            for b, n in zip(blocks, layers):
                per_line[b["y"]:b["y"] + 16] += n
            info.append(f"{'all' if cap is None else cap}: {sum(layers)} sprites, max {per_line.max()}/line")
        print(f"record {i} aim {aim}: {len(blocks)} blocks; " + "; ".join(info))
        sep = np.full((80, 4, 3), 40, np.uint8)
        tiles.append(np.concatenate(sum(([t, sep] for t in row), [])[:-1], axis=1))
    sheet = np.concatenate(sum(([t, np.full((4, tiles[0].shape[1], 3), 40, np.uint8)] for t in tiles), [])[:-1], axis=0)
    out = ROOT / "build/mock/robocop_budget.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(sheet).resize((sheet.shape[1] * 3, sheet.shape[0] * 3), Image.NEAREST).save(out)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
