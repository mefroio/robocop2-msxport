#!/usr/bin/env python3
"""RoboCop in MSX hardware sprites (mode 2, OR technique) and the level's joint palette.

Joint palette (decision 1 in docs/MSX_ARCHITECTURE.md; approved mockup tools/msxmock_or3.py):
16 MSX colours from a weighted k-means over the level background (tile pixels counted over
the whole map) and RoboCop (every composition, weight 4). One of the slots 1..15 is black
(index 0 is transparent for sprites). RoboCop's 7 most useful colours sit at the OR-closed
indices 1..7, in the order that minimises the per-line error of the OR pairs. Background
pixels are remapped to the nearest entry (CIELAB).

Sprites: every composition draw_player can show (frame record x aim, tools/player.py) is cut
into bands of 16 lines and each band into the fewest 16x16 boxes that cover its pixels (each
box at the leftmost pixel not yet covered, so a stride's two feet take two boxes, not the three
of a fixed grid). Each line of a box gets either one colour (layer A only) or an OR pair: layer
A colour p and layer B colour q with CC = 1, so that pixels set in both show p|q (p, q in 1..7).
RoboCop's bands use at most RC_CAP sprites on a line (the boxes whose pairs gain least keep one
layer there): the run time never takes anything from him. Each box also has a single-layer
fallback A1 (one colour per line, every pixel set) that replaces A + B when the budget drops
its band's OR layer (BOBs only), so dropping a layer never leaves holes. In the SAT a band is
[A, B, A, B, ...]: on every line the B that covers it directly follows its A, which is what the
VDP needs for the OR.

Enemies and the other BOBs of the level (tools/bobcatalog.py's catalogue, with --bobs) go the
same way, with OR pairs over the whole palette (their colours are the background's, not
OR-closed), bands ending on their lowest pixel line (a band keeps its place from frame to
frame), and share the pattern and colour pools. Their look never changes at run time (the
user's choice): at most BOB_CAP sprites on a line, so that one fits beside RoboCop's RC_CAP;
in a band with more boxes than that allows, the boxes that keep their OR layer are the same in
every frame of an animation (the most gain summed over its frames; <out>.json "prefer").

ROM data (<out>.bin, 8 KiB banks, see FORMAT below) and <out>.inc (equates), plus <out>.pal
(joint palette, V9938 format), <out>.remap (16 bytes: Amiga background index -> joint index),
<out>.json (statistics) and <out>.png (every composition: software | full | fallback).

Run time (msx/sprites.asm): the budget counts every line's sprites from the band tables and,
where a line passes 8, drops the OR layer of a band of a BOB (its B sprites go, its A sprites
show A1) or leaves an effect out.

FORMAT (all little-endian words; banks relative to the first sprite bank):
  banks 0..SPR_PAT_BANK-1: index: per (record*4 + aim) db bank, dw offset in that bank;
                     then (at id SPR_RC_ARM) the same per start-of-level arm pose ($1676 =
                     8..25 on record PL_ARM_REC, aim 2: tools/player.py ARM_POSES);
                     then (at SPR_BOB_INDEX) the same per BOB frame (<out>.json "bobs")
                     compositions (none crosses a bank boundary):
                       db nspr, db nlines (end of the last sprite, from the top), db nbands,
                       db min dx, db max dx (signed: left edges of the leftmost and
                       rightmost sprites), db sprites of the one-layer version (A boxes),
                       db most sprites on a line, db the same for the one-layer version
                       nspr x 12 bytes in SAT order (per band from the top, per box: A, then B):
                         db dy, db dx (signed), db park bit (B sprite: its band's bit, else 0),
                         db A1 bit (A sprite: its band's bit, else 0), dw pattern, dw colour,
                         dw pattern A1, dw colour A1 (FFFFh for B sprites)
                       nbands x 4 bytes, from the lowest band up (band k: bit 1 << k):
                         db dy (signed), db A sprites, db B sprites, db gain (what dropping its
                         OR layer costs: 12 log2(1 + Lab error), at most 254; FFh: no B)
  banks 1..: pattern pool (32 bytes each, 256 per bank), then colour pool (16 bytes each,
             512 per bank); SPR_PAT_BANK / SPR_COL_BANK give the first bank of each.

usage: msxsprites.py MAIN_8000.bin PERMA.bin DATAL.bin --rows 51 [--bobs CATALOG.json --ram RAM.bin
                    --level level1] OUT
"""
from __future__ import annotations

import argparse
import itertools
import json
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import player  # noqa: E402
from planar import write_png  # noqa: E402

COLS, MAP_OFFSET = 160, 0x10000
BANK = 0x2000
PAIRS = [(p, q) for p in range(1, 8) for q in range(p + 1, 8)]           # RoboCop: OR-closed 1..7
PAIRS_ALL = [(p, q) for p in range(1, 16) for q in range(p + 1, 16)]     # BOBs: any two colours
FLASHES = (0x100B0, 0x10092, 0x100CE, 0x100EC, 0x10074, 0x1010A)  # $F80E's palettes, PAL_ENEMYHIT..PAL_REVERSE
RC_CAP = 5        # RoboCop: the most sprites on a line (msx/sprites.asm never drops his OR layers)
BOB_CAP = 3       # the BOBs: the most on a line, beside RoboCop's RC_CAP (a look that never changes)
SPARK_GFX, SPARK_OFFSETS = 0x65230, 0xB4DA  # the hit spark: draw_player ($BB78) cuts frame $65230 + word k


def amiga_rgb(c12: int) -> np.ndarray:
    return np.array([(c12 >> 8) & 15, (c12 >> 4) & 15, c12 & 15], float) / 15.0


def lab(rgb: np.ndarray) -> np.ndarray:
    """sRGB [0,1] -> CIELAB (D65)."""
    c = np.where(rgb > 0.04045, ((rgb + 0.055) / 1.055) ** 2.4, rgb / 12.92)
    xyz = c @ np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]).T
    xyz = xyz / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def kmeans9(cols: np.ndarray, weights: np.ndarray, k: int = 16, iters: int = 60) -> np.ndarray:
    """Weighted k-means (k-means++ init, fixed seed) over unique colours in [0,1]; colour 0 is
    fixed to black; the result is rounded to the MSX 3-bit levels."""
    pts, w = cols, weights
    rng = np.random.default_rng(1)
    cent = [np.zeros(3)]
    while len(cent) < k:
        d = np.min([((pts - c) ** 2).sum(1) for c in cent], axis=0) * w
        cent.append(pts[rng.choice(len(pts), p=d / d.sum())] if d.sum() > 0 else pts[rng.integers(len(pts))])
    cent = np.array(cent)
    for _ in range(iters):
        lbl = ((pts[:, None] - cent[None]) ** 2).sum(-1).argmin(1)
        for j in range(1, k):
            m = lbl == j
            if m.any():
                cent[j] = (pts[m] * w[m, None]).sum(0) / w[m].sum()
            else:
                cent[j] = pts[(((pts[:, None] - cent[None]) ** 2).sum(-1).min(1) * w).argmax()]
        cent[0] = 0.0
    return np.round(cent * 7) / 7


def nearest(cols: np.ndarray, pal: np.ndarray, first: int = 0) -> np.ndarray:
    """Index of the nearest palette entry (CIELAB), searching from index 'first'."""
    d = ((lab(cols)[..., None, :] - lab(pal[first:])) ** 2).sum(-1)
    return d.argmin(-1) + first


class Level:
    def __init__(self, main: bytes, perma: bytes, datal: bytes, rows: int):
        pal12 = [struct.unpack_from(">H", main, 0xFFF6 - 0x8000 + 2 * i)[0] for i in range(31)]
        self.bgpal = np.array([[0, 0, 0]] + [amiga_rgb(c) for c in pal12[:15]])
        self.sppal = np.array([[0, 0, 0]] + [amiga_rgb(c) for c in pal12[16:31]])
        words = [struct.unpack_from(">H", datal, MAP_OFFSET + 2 * i)[0] & ~0x7F for i in range(rows * COLS)]
        uses: dict[int, int] = {}
        for w in words:
            uses[w] = uses.get(w, 0) + 1
        self.bg_count = np.zeros(16)
        for off, n in uses.items():
            for y in range(16):
                for x in range(16):
                    v = sum(1 << p for p in range(4) if datal[off + (y * 4 + p) * 2 + (x >> 3)] & (0x80 >> (x & 7)))
                    self.bg_count[v] += n
        self.game = player.Game(main, perma)
        self.records = self.game.records()

    def compositions(self) -> tuple[list[np.ndarray], list[int]]:
        return rc_compositions(self.game)


def rc_compositions(game: "player.Game") -> tuple[list[np.ndarray], list[int]]:
    """Distinct compositions and the index of its composition per (record, aim), then per
    start-of-level arm pose."""
    comps, index, seen = [], [], {}
    records = game.records()

    def add(img: np.ndarray) -> None:
        key = img.tobytes()
        if key not in seen:
            seen[key] = len(comps)
            comps.append(img)
        index.append(seen[key])

    for r in records:
        for aim in range(4):
            add(np.array(game.compose(r, aim)))
    rec = records[player.arm_record(records)]
    for arm in player.ARM_POSES:
        add(np.array(game.compose(rec, player.ARM_AIM, arm)))
    return comps, index


def joint_palette(level: Level, comps: list[np.ndarray]) -> np.ndarray:
    sp_count = np.zeros(16)
    for a in comps:
        sp_count += np.bincount(a.ravel(), minlength=16)
    sp_count[0] = 0
    cols = np.concatenate([level.bgpal[1:], level.sppal[1:]])
    w = np.concatenate([level.bg_count[1:], 4 * sp_count[1:]])
    keep = w > 0
    pal = kmeans9(cols[keep], w[keep])
    if not any((pal[i] == 0).all() for i in range(1, 16)):
        q9 = [tuple(int(round(v * 7)) for v in c) for c in pal]
        dup = [i for i in range(1, 16) if q9[i] in q9[:i]]
        if dup:
            pal[dup[0]] = 0.0
        else:
            P = lab(pal[1:])
            d = ((P[:, None] - P[None]) ** 2).sum(-1) + np.eye(15) * 1e9
            i, j = np.unravel_index(d.argmin(), d.shape)
            pal[1 + max(i, j)] = 0.0
    return pal


def order_palette(pal: np.ndarray, comps: list[np.ndarray], sppal: np.ndarray) -> np.ndarray:
    """Puts RoboCop's 7 most useful colours at indices 1..7 in the best OR arrangement."""
    hist: dict[bytes, int] = {}
    usage = np.zeros(16)
    for a in comps:
        q = np.where(a > 0, nearest(sppal[a], pal, 1), 0)
        usage += np.bincount(q[a > 0], minlength=16)
        for y in range(a.shape[0]):
            for s0 in range(0, a.shape[1], 16):
                seg = q[y, s0:s0 + 16][a[y, s0:s0 + 16] > 0]
                if len(seg):
                    h = np.bincount(seg, minlength=16).astype(np.int16).tobytes()
                    hist[h] = hist.get(h, 0) + 1
    H = np.array([np.frombuffer(h, np.int16) for h in hist], float)
    cnt = np.array(list(hist.values()), float)
    P = lab(pal)
    D = ((P[:, None, :] - P[None, :, :]) ** 2).sum(-1)
    cands = [(p, p) for p in range(1, 8)] + PAIRS

    def evaluate(robo):
        best = None
        others = [i for i in range(1, 16) if i not in robo]
        for perm in itertools.permutations(robo):
            newpal = np.zeros(16, int)
            newpal[1:8] = perm
            newpal[8:16] = others + [0] * (8 - len(others))
            M = np.array([np.minimum(np.minimum(D[:, newpal[p]], D[:, newpal[q]]), D[:, newpal[p | q]])
                          for p, q in cands])
            e = (cnt * (H @ M.T).min(1)).sum()
            if best is None or e < best[0]:
                best = (e, newpal)
        return best

    usage[0] = 0
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


def flash_palettes(main: bytes, comps: list[np.ndarray], shown: list[np.ndarray], remap: list[int],
                   bg_count: np.ndarray) -> tuple[list[int], list[list[np.ndarray]]]:
    """RoboCop's palette flashes ($F80E: COLOR17-31 from one of FLASHES for 5 game frames) on the
    joint palette. The entries tinted are RoboCop's (1..7) that the background never uses, so that
    only the sprites change colour as on the Amiga; each takes the mean of the flash colours of
    the Amiga colours shown with it over every composition. -> (entries, per flash their 3-bit
    RGB colours)."""
    count = np.zeros((16, 16))
    for img, full in zip(comps, shown):
        m = (img > 0) & (full > 0)
        np.add.at(count, (img[m], full[m]), 1)
    bg_use = np.zeros(16)
    for c, k in enumerate(remap):
        bg_use[k] += bg_count[c]
    idx = [k for k in range(1, 8) if bg_use[k] == 0 and count[:, k].sum() > 0]
    out = []
    for addr in FLASHES:
        words = [struct.unpack_from(">H", main, addr - 0x8000 + 2 * i)[0] for i in range(15)]
        fl = np.array([[0, 0, 0]] + [amiga_rgb(c) for c in words])
        out.append([np.round((fl * count[:, k, None]).sum(0) / count[:, k].sum() * 7).astype(int) for k in idx])
    return idx, out


def spans(lines: list[int]) -> list[int]:
    """First lines of the 16-line sprites that cover the given (sorted) lines (the mockups)."""
    out, i = [], 0
    while i < len(lines):
        out.append(lines[i])
        while i < len(lines) and lines[i] < out[-1] + 16:
            i += 1
    return out


class Converter:
    """Cuts a composition into 16x16 boxes band by band (16 lines each, numbered from the
    bottom): per band the fewest boxes that cover its pixels (each at the leftmost pixel not yet
    covered), per box and line one colour (layer A) or an OR pair (layer B, CC = 1, on top).
    cap: the most sprites (A + B) a band may put on a line (RoboCop: the boxes whose pairs gain
    least then keep one layer); align "best" tries the 16 band offsets (the fewest sprites on a
    line, then in all, then the least error), "bottom" ends the lowest band on the lowest pixel
    line (the BOBs: a band keeps its place from frame to frame, which the budget's held drops
    rely on)."""

    def __init__(self, pal: np.ndarray, pairs: list[tuple[int, int]] = PAIRS, cap: int | None = None,
                 align: str = "best"):
        P = lab(pal)
        self.D = ((P[:, None, :] - P[None, :, :]) ** 2).sum(-1)
        self.pairs = pairs
        self.cap = cap
        self.align = align
        self.prefer: dict[tuple[int, int], list[int]] = {}  # (band from the bottom, boxes) -> boxes to
                                                            # keep the OR layer of first (an animation's)

    def line_choice(self, t: np.ndarray) -> tuple:
        """t = target indices of the opaque pixels of one line of a box.
        Returns (single colour, its error, pair or None, pair error)."""
        one = self.D[t][:, 1:].sum(0)
        c = int(one.argmin()) + 1
        e1 = float(one[c - 1])
        if len(set(t.tolist())) == 1:
            return c, e1, None, e1
        best = None
        for p, q in self.pairs:
            e = float(np.minimum(np.minimum(self.D[t, p], self.D[t, q]), self.D[t, p | q]).sum())
            if best is None or e < best[0]:
                best = (e, (p, q))
        return c, e1, best[1], best[0]

    def box(self, tgt: np.ndarray, x0: int, y0: int) -> dict | None:
        """The box at (x0, y0): A, A1 (one colour per line, every pixel), B and their colours."""
        h, w = tgt.shape
        A, A1, B = (np.zeros((16, 16), np.uint8) for _ in range(3))
        cA, cA1, cB = (np.zeros(16, np.uint8) for _ in range(3))
        full, fb = np.zeros((16, 16), np.uint8), np.zeros((16, 16), np.uint8)
        e_full = e_fb = 0.0
        pairs = 0
        for k in range(16):
            y = y0 + k
            if not 0 <= y < h:
                continue
            row = np.array([tgt[y, x] if 0 <= x < w else 0 for x in range(x0, x0 + 16)])
            m = row > 0
            if not m.any():
                continue
            c, e1, pair, e2 = self.line_choice(row[m])
            A1[k, m] = 1
            cA1[k] = c
            fb[k, m] = c
            e_fb += e1
            if pair is None or e1 <= e2:
                A[k, m] = 1
                cA[k] = c
                full[k, m] = c
                e_full += e1
                continue
            p, q = pair
            pairs += 1
            cA[k], cB[k] = p, q
            e_full += e2
            for i in np.nonzero(m)[0]:
                kk = min((p, q, p | q), key=lambda t: self.D[row[i], t])
                full[k, i] = kk
                A[k, i] = kk in (p, p | q)
                B[k, i] = kk in (q, p | q)
        if not A1.any():
            return None
        return {"x": x0, "A": A, "A1": A1, "B": B, "cA": cA, "cA1": cA1, "cB": cB, "full": full,
                "fallback": fb, "has_b": pairs > 0, "gain": e_fb - e_full, "err": e_full}

    @staticmethod
    def one_layer(b: dict) -> None:
        """A box keeps one layer: its A sprite shows A1."""
        b.update({"A": b["A1"].copy(), "cA": b["cA1"].copy(), "B": np.zeros_like(b["B"]),
                  "cB": np.zeros_like(b["cB"]), "full": b["fallback"].copy(), "has_b": False,
                  "err": b["err"] + b["gain"], "gain": 0.0})

    def bands(self, tgt: np.ndarray, y_first: int) -> list[tuple[int, list[dict]]]:
        m = tgt > 0
        bottom = int(np.nonzero(m.any(1))[0][-1])
        out = []
        for y in range(y_first, bottom + 1, 16):
            xs = np.nonzero(m[max(0, y):max(0, y + 16)].any(0))[0]
            boxes, i = [], 0
            while i < len(xs):
                x0 = int(xs[i])
                b = self.box(tgt, x0, y)
                if b:
                    boxes.append(b)
                while i < len(xs) and xs[i] < x0 + 16:
                    i += 1
            if boxes:
                out.append((y, boxes))
        if self.cap is not None:
            for j, (_, boxes) in enumerate(out):
                keep = self.cap - len(boxes)
                order = self.prefer.get((len(out) - 1 - j, len(boxes)))
                rank = (lambda b: order.index(boxes.index(b))) if order else (lambda b: -b["gain"])
                for b in sorted((b for b in boxes if b["has_b"]), key=rank)[max(0, keep):]:
                    self.one_layer(b)
        return out

    def composition(self, tgt: np.ndarray) -> list[tuple[int, list[dict]]]:
        rows = np.nonzero((tgt > 0).any(1))[0]
        top, bottom = int(rows[0]), int(rows[-1])
        if self.align == "bottom":
            firsts = [bottom + 1 - 16 * ((bottom - top) // 16 + 1)]
        else:
            firsts = [top - off for off in range(16)]
        best = None
        for yf in firsts:
            lay = self.bands(tgt, yf)
            per = [len(bx) + sum(b["has_b"] for b in bx) for _, bx in lay]
            key = (max(per), sum(per), sum(b["err"] for _, bx in lay for b in bx))
            if best is None or key < best[0]:
                best = (key, lay)
        return best[1]


# Facing left (odd states) the original keeps drawings of its own: most are the right ones mirrored
# (about an axis of each animation, through the records' hot spots), some differ (the arm of the up
# and up-diagonal aims, the crouch, the up-only pose; its left arm table has the diagonals the other
# way round: left aim 1 shows the right's 3), and the frontal poses (states 10-13) are the same
# drawings on both sides. The user's rule (2026-10-21): the left side is always the right one
# mirrored, so a left composition takes the right one's converted layout, mirrored (the same boxes,
# colours and OR pairs), placed where the left drawing lies (exactly where it is the mirror, else
# feet on the same line and the most pixels in common). BOB frames that are the exact mirror of an
# earlier one do the same.
LEFT_AIM = (0, 3, 2, 1)          # left aim -> the right aim it mirrors


def bbox(a: np.ndarray) -> tuple[int, int, int, int]:
    """Top, left, height, width of the opaque (> 0) pixels."""
    ys, xs = np.nonzero(a > 0)
    return int(ys.min()), int(xs.min()), int(ys.max() - ys.min() + 1), int(xs.max() - xs.min() + 1)


def mirror_exact(left: np.ndarray, right: np.ndarray) -> tuple[int, int] | None:
    """(dy, dx) when left is right[:, ::-1] moved by (dy, dx), else None."""
    m = right[:, ::-1]
    yl, xl, hl, wl = bbox(left)
    ym, xm, hm, wm = bbox(m)
    if (hl, wl) == (hm, wm) and (left[yl:yl + hl, xl:xl + wl] == m[ym:ym + hm, xm:xm + wm]).all():
        return yl - ym, xl - xm
    return None


def mirror_place(left: np.ndarray, right: np.ndarray) -> tuple[int, int]:
    """(dy, dx): where right[:, ::-1] goes in left's frame."""
    exact = mirror_exact(left, right)
    if exact:
        return exact
    m = right[:, ::-1]
    yl, _, hl, _ = bbox(left)
    ym, _, hm, _ = bbox(m)
    dy = (yl + hl) - (ym + hm)
    h = max(left.shape[0], m.shape[0] + abs(dy)) + abs(dy)
    w = left.shape[1] + 2 * m.shape[1]
    cl = np.zeros((h, w), int)
    cl[abs(dy):abs(dy) + left.shape[0], m.shape[1]:m.shape[1] + left.shape[1]] = left
    best = None
    for dx in range(-m.shape[1], left.shape[1] + 1):
        cm = np.zeros((h, w), int)
        y0, x0 = abs(dy) + dy, m.shape[1] + dx
        cm[y0:y0 + m.shape[0], x0:x0 + m.shape[1]] = m
        d = int(((cl != cm) & ((cl > 0) | (cm > 0))).sum())
        if best is None or d < best[0]:
            best = (d, dx)
    return dy, best[1]


def slips(records: list[dict], index: list[int]) -> dict[tuple[int, int], tuple[int, int]]:
    """Right records that show a left drawing (a composition of the left side's that is not their
    own left counterpart's): each repeats the step before (repeat_steps). The original's right
    punch (state 6) reads its last step from the left punch's list (one entry past its own): one
    step faced left. -> {(state, step): (state, step - 1)}."""
    by_key = {(r["state"], r["index"]): i for i, r in enumerate(records)}
    lefts = {index[4 * i + a] for (s, _), i in by_key.items() if s % 2 and s < 16 for a in range(4)}
    out = {}
    for (s, f), ir in sorted(by_key.items()):
        if s % 2 or s >= 16 or (s + 1, f) not in by_key:
            continue
        il = by_key[(s + 1, f)]
        if any(index[4 * ir + a] in lefts and index[4 * ir + a] != index[4 * il + LEFT_AIM[a]] for a in range(4)):
            out[(s, f)] = (s, f - 1)
    return out


def repeat_steps(records: list[dict], comps: list[np.ndarray], index: list[int],
                 repl: dict[tuple[int, int], tuple[int, int]]) -> dict[int, tuple[int, int, int]]:
    """Records that show another record's compositions (every aim) instead of their own, moved to
    their own hot spot (the run-time places a composition at its record's): repl (state, step) ->
    the (state, step) shown. -> the compositions added: (the one each moves, dy, dx); their images
    (previews only) are clipped to the buffer."""
    by_key = {(r["state"], r["index"]): i for i, r in enumerate(records)}
    moves: dict[int, tuple[int, int, int]] = {}
    made: dict[tuple[int, int, int], int] = {}
    for key, shown in repl.items():
        ir, ip = by_key[key], by_key[shown]
        dy = records[ip]["hot_y"] - records[ir]["hot_y"]
        dx = records[ip]["hot_x"] - records[ir]["hot_x"]
        for aim in range(4):
            mv = (index[4 * ip + aim], dy, dx)
            if (dy, dx) == (0, 0):
                index[4 * ir + aim] = mv[0]
                continue
            if mv not in made:
                src = comps[mv[0]]
                h, w = src.shape
                img = np.zeros_like(src)
                img[max(0, dy):h + min(0, dy), max(0, dx):w + min(0, dx)] = \
                    src[max(0, -dy):h - max(0, dy), max(0, -dx):w - max(0, dx)]
                made[mv] = len(comps)
                moves[len(comps)] = mv
                comps.append(img)
            index[4 * ir + aim] = made[mv]
    return moves


def mirror_pairs(records: list[dict], comps: list[np.ndarray], index: list[int]) -> dict[int, tuple[int, int, int]]:
    """Left composition -> (the right one it mirrors, dy, dx: mirror_place). A left drawing that
    the original shares between records whose right counterparts differ (the left punch's last
    steps and the left crouch's first) takes one composition per right one (added to comps, a copy
    of the left image for the previews; index follows)."""
    by_key = {(r["state"], r["index"]): i for i, r in enumerate(records)}
    rights = {index[4 * i + a] for (s, _), i in by_key.items() if s % 2 == 0 for a in range(4)}
    out: dict[int, tuple[int, int, int]] = {}
    made: dict[tuple, int] = {}
    for (s, f), il in by_key.items():
        if s % 2 == 0 or s >= 16 or (s - 1, f) not in by_key:
            continue
        ir = by_key[(s - 1, f)]
        for aim in range(4):
            cl, cr = index[4 * il + aim], index[4 * ir + LEFT_AIM[aim]]
            if cl == cr:                            # (the frontal poses: one drawing)
                continue
            want = (cr, *mirror_place(comps[cl], comps[cr]))
            if (cl, want) not in made:
                if cl in out or cl in rights:
                    made[(cl, want)] = len(comps)
                    comps.append(comps[cl].copy())
                else:
                    made[(cl, want)] = cl
                out[made[(cl, want)]] = want
            index[4 * il + aim] = made[(cl, want)]
    return out


def bob_mirrors(targets: list[np.ndarray]) -> dict[int, tuple[int, int, int]]:
    """BOB frame -> (the earlier frame it is the exact mirror of, dy, dx: mirror_exact)."""
    first: dict[tuple, int] = {}
    out: dict[int, tuple[int, int, int]] = {}
    for k, t in enumerate(targets):
        y, x, h, w = bbox(t)
        tr = t[y:y + h, x:x + w]
        m = first.get((tr.shape, tr[:, ::-1].tobytes()))
        if m is not None and not (tr == tr[:, ::-1]).all():
            out[k] = (m, *mirror_exact(t, targets[m]))
        else:
            first.setdefault((tr.shape, tr.tobytes()), k)
    return out


def mirror_layout(lay: list[tuple[int, list[dict]]], width: int, dy: int, dx: int) -> list[tuple[int, list[dict]]]:
    """A converted layout of a composition 'width' pixels wide, mirrored and moved by (dy, dx)."""
    out = []
    for y, boxes in lay:
        nb = []
        for b in reversed(boxes):                   # (left to right again)
            m = {k: (v[:, ::-1].copy() if isinstance(v, np.ndarray) and v.ndim == 2 else v) for k, v in b.items()}
            m["x"] = width - 16 - b["x"] + dx
            nb.append(m)
        out.append((y + dy, nb))
    return out


def move_layout(lay: list[tuple[int, list[dict]]], dy: int, dx: int) -> list[tuple[int, list[dict]]]:
    return [(y + dy, [dict(b, x=b["x"] + dx) for b in boxes]) for y, boxes in lay]


def rc_layouts(conv: "Converter", comps: list[np.ndarray], targets: list[np.ndarray],
               pairs: dict[int, tuple[int, int, int]],
               moves: dict[int, tuple[int, int, int]]) -> list[list[tuple[int, list[dict]]]]:
    """RoboCop's layouts: converted, the left side the right one mirrored (mirror_pairs), the
    compositions repeat_steps added another one moved."""
    lays: dict[int, list] = {}

    def lay(c: int) -> list:
        if c not in lays:
            if c in moves:
                src, dy, dx = moves[c]
                lays[c] = move_layout(lay(src), dy, dx)
            elif c in pairs:
                cr, dy, dx = pairs[c]
                lays[c] = mirror_layout(lay(cr), comps[cr].shape[1], dy, dx)
            else:
                lays[c] = conv.composition(targets[c])
        return lays[c]

    return [lay(c) for c in range(len(comps))]


def layout_sprites(lay: list[tuple[int, list[dict]]], use_b: bool = True) -> int:
    return sum(len(bx) + (sum(b["has_b"] for b in bx) if use_b else 0) for _, bx in lay)


def max_per_line(lay: list[tuple[int, list[dict]]], use_b: bool = True) -> int:
    return max(len(bx) + (sum(b["has_b"] for b in bx) if use_b else 0) for _, bx in lay)


def pattern_bytes(bits: np.ndarray, y0: int) -> bytes:
    """16x16 sprite pattern from rows y0..y0+15 of a bitmap: the VDP reads line y of the left
    half at byte y and of the right half at byte y + 16."""
    rows = [bits[y] if y < len(bits) else np.zeros(16, np.uint8) for y in range(y0, y0 + 16)]
    out = bytearray()
    for half in (0, 8):
        for r in rows:
            v = 0
            for x in range(8):
                v = (v << 1) | int(r[half + x])
            out.append(v)
    return bytes(out)


def colour_bytes(c: np.ndarray, y0: int, cc: bool) -> bytes:
    return bytes((int(c[y]) if y < len(c) else 0) | (0x40 if cc else 0) for y in range(y0, y0 + 16))


def gain_byte(gain: float) -> int:
    return min(254, round(12 * np.log2(1 + max(0.0, gain))))


def encode(lay: list[tuple[int, list[dict]]], pats: "Pool", cols_pool: "Pool") -> tuple[bytes, list, int]:
    """Composition record (FORMAT) of a band layout; returns (blob, sprites, nlines)."""
    nb = len(lay)
    assert nb <= 8, "the drop mask has 8 bits"
    sprites, table = [], []
    for j, (y, boxes) in enumerate(lay):
        bit = 1 << (nb - 1 - j)
        na = nbb = 0
        gain = 0.0
        for b in boxes:
            sprites.append((b["x"], y, 0, bit, pats.add(pattern_bytes(b["A"], 0)),
                            cols_pool.add(colour_bytes(b["cA"], 0, False)),
                            pats.add(pattern_bytes(b["A1"], 0)), cols_pool.add(colour_bytes(b["cA1"], 0, False))))
            na += 1
            if b["has_b"]:
                sprites.append((b["x"], y, bit, 0, pats.add(pattern_bytes(b["B"], 0)),
                                cols_pool.add(colour_bytes(b["cB"], 0, True)), 0xFFFF, 0xFFFF))
                nbb += 1
                gain += b["gain"]
        table.append((y, na, nbb, gain_byte(gain) if nbb else 0xFF))
    nlines = max(y for _, y, *_ in sprites) + 16
    dxs = [x for x, *_ in sprites]
    n_a = sum(1 for s in sprites if not s[2])
    out = bytearray(struct.pack("<BBBbbBBB", len(sprites), nlines, nb, min(dxs), max(dxs), n_a,
                                max_per_line(lay), max_per_line(lay, False)))
    for x, y, pbit, abit, p, c, p1, c1 in sprites:
        out += struct.pack("<bbBBHHHH", y, x, pbit, abit, p, c, p1, c1)
    for y, na, nbb, g in reversed(table):
        out += struct.pack("<bBBB", y, na, nbb, g)
    return bytes(out), sprites, nlines


def preview(lay: list[tuple[int, list[dict]]], tgt: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    full = np.zeros_like(tgt)
    fb = np.zeros_like(tgt)
    h, w = tgt.shape
    for y0, boxes in lay:
        for b in boxes:
            for k in range(16):
                y = y0 + k
                if not 0 <= y < h:
                    continue
                for i in range(16):
                    x = b["x"] + i
                    if 0 <= x < w:
                        if b["full"][k, i]:
                            full[y, x] = b["full"][k, i]
                        if b["fallback"][k, i]:
                            fb[y, x] = b["fallback"][k, i]
    return tgt, full, fb


def bob_frames(catalog: Path, level: str) -> list[dict]:
    """The level's BOB frames (and the common ones) from tools/bobcatalog.py's catalogue."""
    cat = json.loads(catalog.read_text())
    out, seen = [], set()
    for r in cat["refs"]:
        lv = (r["level"] or "").split("+")
        if level not in lv and "common" not in lv:
            continue
        for f in r["frames"]:
            key = (f, r["width"], r["height"])
            if key not in seen:
                seen.add(key)
                out.append({"proc": r["proc_name"], "addr": f, "w": r["width"], "h": r["height"]})
    return out


def bob_image(ram: bytes, addr: int, w: int, h: int) -> np.ndarray:
    """BOB [mask][plane0..3] -> background colour indices, -1 where the mask is clear."""
    wb, ps = w // 8, (w // 8) * h
    out = np.full((h, w), -1, int)
    for y in range(h):
        for x in range(w):
            byte, bit = y * wb + (x >> 3), 0x80 >> (x & 7)
            if ram[addr + byte] & bit:
                out[y, x] = sum(1 << p for p in range(4) if ram[addr + ps * (p + 1) + byte] & bit)
    return out


def render_sheet(path: Path, items: list[tuple], pal: np.ndarray):
    """Every item: software | full | fallback (magenta = transparent)."""
    rgb = (np.round(pal * 7) * 255 / 7).astype(np.uint8)
    cw = 3 * (max(t.shape[1] for t, _, _ in items) + 2) + 8
    ch = max(t.shape[0] for t, _, _ in items) + 2
    per = 8
    rows_n = (len(items) + per - 1) // per
    canvas = np.full((rows_n * ch, per * cw, 3), 40, np.uint8)
    for n, (t, f, fb) in enumerate(items):
        oy, ox = (n // per) * ch, (n % per) * cw
        for k, im in enumerate((t, f, fb)):
            x0 = ox + k * (t.shape[1] + 2)
            reg = canvas[oy:oy + im.shape[0], x0:x0 + im.shape[1]]
            reg[:] = 255, 0, 255
            m = im > 0
            reg[m] = rgb[im[m]]
    write_png(path, canvas.shape[1], canvas.shape[0], [bytes(r.ravel()) for r in canvas])


class Pool:
    def __init__(self):
        self.items: list[bytes] = []
        self.index: dict[bytes, int] = {}

    def add(self, b: bytes) -> int:
        if b not in self.index:
            self.index[b] = len(self.items)
            self.items.append(b)
        return self.index[b]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("main", type=Path)
    ap.add_argument("perma", type=Path)
    ap.add_argument("datal", type=Path)
    ap.add_argument("--rows", type=int, required=True)
    ap.add_argument("--bobs", type=Path, help="BOB catalogue (tools/bobcatalog.py)")
    ap.add_argument("--drawn", type=Path, action="append", default=[],
                    help="BOB frames the original drew (tools/amigacov.py \"bobs\" or tools/bobdrawn.py \"frames\")")
    ap.add_argument("--ram", type=Path, help="the level's composite RAM image (tools/ramimage.py)")
    ap.add_argument("--level", default="level1")
    ap.add_argument("--remove", type=Path,
                    help="frames removed: JSON {\"rc\": {\"state:step\": \"state:step shown\"}, "
                         "\"bob\": {\"addr:w:h\": \"addr:w:h shown\"}} (hex address)")
    ap.add_argument("out", type=Path)
    a = ap.parse_args()
    removed = json.loads(a.remove.read_text()) if a.remove else {}
    level = Level(a.main.read_bytes(), a.perma.read_bytes(), a.datal.read_bytes(), a.rows)
    comps, index = level.compositions()
    pal = order_palette(joint_palette(level, comps), comps, level.sppal)
    remap = [0] + [int(i) for i in nearest(level.bgpal[1:], pal)]
    conv = Converter(pal, cap=RC_CAP)
    pats, cols_pool = Pool(), Pool()
    blobs, stats = [], {"compositions": len(comps), "sprites": [], "one_layer": [], "lines": [], "max_line": [],
                        "max_line_fallback": []}
    previews = []
    moves = repeat_steps(level.records, comps, index, slips(level.records, index))
                                                        # (after the palette: a moved copy would
                                                        # count its colours twice)
    pairs = mirror_pairs(level.records, comps, index)
    # the frames removed (both sides chosen together): a removed step shows the one chosen instead
    # (the step before that stays), at its own hot spot
    moves.update(repeat_steps(level.records, comps, index,
                              {tuple(map(int, k.split(":"))): tuple(map(int, v.split(":")))
                               for k, v in removed.get("rc", {}).items()}))
    stats["compositions"] = len(comps)
    targets = [np.where(img > 0, nearest(level.sppal[img], pal, 1), 0) for img in comps]
    layouts = rc_layouts(conv, comps, targets, pairs, moves)
    assert len(targets) == len(layouts) == len(comps)
    stats.update({"rc_index": index, "rc_moves": {str(c): list(v) for c, v in sorted(moves.items())},
                  "rc_mirrors": {str(c): list(v) for c, v in sorted(pairs.items())}})
    used = set(index)                                   # (no longer shown: not in the ROM)
    for ci, (tgt, columns) in enumerate(zip(targets, layouts)):
        previews.append(preview(columns, tgt))
        if ci not in used:
            blobs.append(None)
            continue
        blob, sprites, nlines = encode(columns, pats, cols_pool)
        assert len(sprites) <= 32, "an entry page (msx/sprites.asm) holds 32 entries"
        blobs.append(blob)
        stats["sprites"].append(len(sprites))
        stats["one_layer"].append(sum(1 for s in sprites if not s[2]))
        stats["lines"].append(nlines)
        stats["max_line"].append(max_per_line(columns))
        stats["max_line_fallback"].append(max_per_line(columns, False))
    # the level's BOBs (enemies, shots, explosions...): opaque pixels take entries 1..15
    bobs, bob_blobs, bob_previews = [], [], []
    if a.bobs:
        ram = a.ram.read_bytes()
        bconv = Converter(pal, PAIRS_ALL, align="bottom")             # (full colour: the gains)
        cconv = Converter(pal, PAIRS_ALL, cap=BOB_CAP, align="bottom")
        frames = bob_frames(a.bobs, a.level)
        seen = {(f["addr"], f["w"], f["h"]) for f in frames}
        for d in a.drawn:
            j = json.loads(d.read_text())
            for f in j.get("bobs", j.get("frames", [])):
                key = (f["addr"], f["w"], f["h"])
                if key not in seen and f["w"] > 0 and f["h"] > 0:
                    seen.add(key)
                    frames.append({"proc": "drawn", "addr": f["addr"], "w": f["w"], "h": f["h"]})
        bob_key = lambda f: f"{f['addr']:x}:{f['w']}:{f['h']}"      # noqa: E731
        frames = [f for f in frames if removed.get("bob", {}).get(bob_key(f), 0) is not None]
                                                        # (null: a frame the level never draws)
        near = nearest(level.bgpal, pal, 1)
        targets = []
        for fr in frames:
            src = bob_image(ram, fr["addr"], fr["w"], fr["h"])
            if (src >= 0).sum() == 0:
                continue
            targets.append((fr, np.where(src >= 0, near[np.clip(src, 0, 15)], 0)))
        # an animation's frames keep the OR layer on the same boxes (by their summed gain): its
        # colours never move from one side to the other as it animates
        group, last = {}, None
        for fr, _ in sorted(targets, key=lambda ft: (ft[0]["proc"] != "drawn", ft[0]["addr"])):
            if fr["proc"] != "drawn":
                group[id(fr)] = (fr["proc"], fr["w"], fr["h"])
                continue
            if last is None or (last["w"], last["h"]) != (fr["w"], fr["h"]) or fr["addr"] - last["addr"] > 0x1000:
                gid = ("drawn", fr["addr"], fr["w"], fr["h"])
            group[id(fr)] = gid
            last = fr
        # (a frame that mirrors an earlier one takes its layout, mirrored: bob_mirrors)
        mirrors = bob_mirrors([tgt for _, tgt in targets])
        gains: dict = {}
        for k, (fr, tgt) in enumerate(targets):
            if k in mirrors:
                continue
            lay = bconv.composition(tgt)
            for j, (_, boxes) in enumerate(lay):
                for n, b in enumerate(boxes):
                    key = (group[id(fr)], len(lay) - 1 - j, len(boxes))
                    gains.setdefault(key, [0.0] * len(boxes))[n] += b["gain"]
        capped = []
        for k, (fr, tgt) in enumerate(targets):
            if k in mirrors:
                m, dy, dx = mirrors[k]
                columns = mirror_layout(capped[m], targets[m][1].shape[1], dy, dx)
                fr["mirror"] = [m, dy, dx]
            else:
                cconv.prefer = {(band, n): sorted(range(n), key=lambda i: -g[i])
                                for (gid, band, n), g in gains.items() if gid == group[id(fr)]}
                columns = cconv.composition(tgt)
                fr["prefer"] = [[band, n] + order for (band, n), order in sorted(cconv.prefer.items())]
            capped.append(columns)
        # the frames removed: each shows the one chosen instead, moved to where that one is drawn
        keys = {bob_key(fr): k for k, (fr, _) in enumerate(targets)}
        for k, (fr, tgt) in enumerate(targets):
            columns = capped[k]
            shown = removed.get("bob", {}).get(bob_key(fr))
            if shown:
                assert not removed["bob"].get(shown[0]), "a removed frame shows a kept one"
                fr["repeat"] = [keys[shown[0]], shown[1], shown[2]]
                columns = move_layout(capped[keys[shown[0]]], shown[1], shown[2])
            if shown and shown[1:] == [0, 0]:           # (the index shows that frame's record)
                blob, sprites, nlines = encode(columns, Pool(), Pool())
                bob_blobs.append(None)
            else:
                blob, sprites, nlines = encode(columns, pats, cols_pool)
                bob_blobs.append(blob)
            fr.update({"id": len(bobs), "sprites": len(sprites), "fallback": sum(1 for s in sprites if s[3]),
                       "lines": nlines, "max_line": max_per_line(columns),
                       "max_line_fallback": max_per_line(columns, False)})
            bobs.append(fr)
            bob_previews.append(preview(columns, tgt))
        # the hit spark ($16A0): 4 frames of 16 x 16 that draw_player cuts into RoboCop's buffer,
        # so in his colours and OR pairs; frames SPR_SPARK + k (k = the offset table's index), not
        # in BOBHASH (msx/player.asm pl_show places them, not bob_draw). Colour 0 inside the mask
        # (a hole cut into him) stays transparent: sprites in front cannot cut holes.
        main_b = a.main.read_bytes()
        for k in range(4):
            addr = SPARK_GFX + struct.unpack_from(">H", main_b, SPARK_OFFSETS - 0x8000 + 2 * k)[0]
            src = bob_image(ram, addr, 16, 16)
            tgt = np.where(src > 0, nearest(level.sppal[np.clip(src, 0, 15)], pal, 1), 0)
            columns = conv.composition(tgt)
            blob, sprites, nlines = encode(columns, pats, cols_pool)
            bob_blobs.append(blob)
            bobs.append({"proc": "spark", "addr": addr, "w": 16, "h": 16, "spark": True, "id": len(bobs),
                         "sprites": len(sprites), "fallback": sum(1 for s in sprites if s[3]), "lines": nlines,
                         "max_line": max_per_line(columns), "max_line_fallback": max_per_line(columns, False)})
            bob_previews.append(preview(columns, tgt))
    # the silhouettes (draw_bob's flash $AC6E: colour 15; black $AC84: colour 0, shown with the
    # joint palette's black, as colour 0 is transparent for sprites): one colour row each, used
    # with the single-layer (A1) patterns, which hold every pixel
    white = int(nearest(level.bgpal[15:16], pal, 1)[0])
    black = next(i for i in range(1, 16) if (pal[i] == 0).all())
    sil_flash = cols_pool.add(bytes([white] * 16))
    sil_black = cols_pool.add(bytes([black] * 16))
    # index + compositions, packed so that no composition crosses a bank boundary
    nidx = len(index) + len(bobs)
    where, area, pos = [], bytearray(3 * nidx), 3 * nidx
    for b in blobs + bob_blobs:
        if b is None:                                   # (not shown)
            where.append(None)
            continue
        if pos // BANK != (pos + len(b) - 1) // BANK:
            pos = (pos // BANK + 1) * BANK
        where.append(pos)
        area += b"\xff" * (pos - len(area)) + b
        pos += len(b)
    for k, i in enumerate(index):
        area[3 * k:3 * k + 3] = struct.pack("<BH", where[i] // BANK, where[i] % BANK)
    for k in range(len(bobs)):
        w = where[len(blobs) + k]
        if w is None:                                   # (a frame removed: another one's record)
            w = where[len(blobs) + bobs[k]["repeat"][0]]
        area[3 * (len(index) + k):3 * (len(index) + k) + 3] = struct.pack("<BH", w // BANK, w % BANK)
    pat_blob = b"".join(pats.items)
    col_blob = b"".join(cols_pool.items)
    pad = lambda b: bytes(b) + b"\xff" * (-len(b) % BANK)  # noqa: E731
    comp_banks = len(pad(area)) // BANK
    pat_banks = len(pad(pat_blob)) // BANK
    data = pad(area) + pad(pat_blob) + pad(col_blob)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.with_suffix(".bin").write_bytes(data)
    a.out.with_suffix(".inc").write_text(
        "; generated by tools/msxsprites.py\n"
        f"SPR_PAT_BANK: equ {comp_banks}                 ; relative to the first sprite bank\n"
        f"SPR_COL_BANK: equ {comp_banks + pat_banks}\n"
        f"SPR_COMPS: equ {len(comps)}\nSPR_RECORDS: equ {len(level.records)}\n"
        f"SPR_RC_ARM: equ {4 * len(level.records)}                ; id of the first start-of-level arm pose\n"
        f"SPR_RC_ARMS: equ {len(player.ARM_POSES)}\n"
        f"SPR_MAX: equ {max(stats['sprites'])}                    ; most sprites in one composition\n"
        f"SPR_RC_ONE: equ {max(stats['one_layer'])}                 ; most sprites of RoboCop on one layer\n"
        f"SPR_MAX_LINES: equ {max(stats['lines'] + [f['lines'] for f in bobs])}              ; most lines covered by one composition\n"
        f"SPR_BOBS: equ {len(bobs)}                   ; BOB frames (<out>.json \"bobs\")\n"
        f"SPR_SPARK: equ {next((f['id'] for f in bobs if f.get('spark')), 0)}                 ; the hit spark's 4 frames\n"
        f"SPR_SIL_FLASH: equ {sil_flash}            ; colour rows of the silhouettes (white, black)\n"
        f"SPR_SIL_BLACK: equ {sil_black}\n"
        f"SPR_BOB_INDEX: equ 0x{0x8000 + 3 * len(index):04X}           ; their index (bank SPR_BASE_BANK at 8000h)\n")
    q = np.round(pal * 7).astype(int)
    a.out.with_suffix(".pal").write_bytes(bytes(b for r, g, bl in q for b in ((r << 4) | bl, g)))
    a.out.with_suffix(".remap").write_bytes(bytes(remap))
    fidx, fpals = flash_palettes(a.main.read_bytes(), comps, [p[1] for p in previews], remap, level.bg_count)
    a.out.with_name(a.out.name + "_flash.inc").write_text(
        "; generated by tools/msxsprites.py: RoboCop's palette flashes ($F80E) on the joint palette\n"
        f"FLASH_N: equ {len(fidx)}                  ; entries tinted (RoboCop's that the background never uses)\n"
        "flash_idx:\n        db " + ", ".join(map(str, fidx)) + "\n"
        "flash_pals:                         ; PAL_ENEMYHIT, PAL_SHOT, PAL_ELECTRIC, PAL_REFILL, PAL_BEAM, PAL_REVERSE\n"
        + "".join("        db " + ", ".join(f"0x{(r << 4) | b:02X}, 0x{g:02X}" for r, g, b in row) + "\n"
                  for row in fpals))
    stats.update({"palette": ["%d%d%d" % tuple(c) for c in q], "remap": remap, "patterns": len(pats.items),
                  "colour_rows": len(cols_pool.items), "bytes": len(data), "bobs": bobs})
    a.out.with_suffix(".json").write_text(json.dumps(stats))
    render_sheet(a.out.with_suffix(".png"), previews, pal)
    if bob_previews:
        render_sheet(a.out.with_name(a.out.name + "_bobs.png"), bob_previews, pal)
    sp, ml, mf = stats["sprites"], stats["max_line"], stats["max_line_fallback"]
    print(f"{a.out.with_suffix('.bin')}: {len(comps)} compositions, {len(bobs)} BOB frames, {len(pats.items)} patterns, "
          f"{len(cols_pool.items)} colour rows, {len(data) // 1024} KiB; RoboCop sprites per composition "
          f"{min(sp)}-{max(sp)} (mean {sum(sp) / len(sp):.1f}); per line: full max {max(ml)}, fallback max {max(mf)}")
    if bobs:
        bs = [f["sprites"] for f in bobs]
        print(f"  BOBs: sprites per frame {min(bs)}-{max(bs)} (mean {sum(bs) / len(bs):.1f}), one layer "
              f"{min(f['fallback'] for f in bobs)}-{max(f['fallback'] for f in bobs)}; per line: full max "
              f"{max(f['max_line'] for f in bobs)}, one layer max {max(f['max_line_fallback'] for f in bobs)}")
    print("joint palette " + " ".join(stats["palette"]) + "; background remap " + " ".join(map(str, remap)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
