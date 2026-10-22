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

The start-of-level arm poses (the gun drawn across his body, spun and held: start_layouts) are
converted together, group by group (START_GROUPS), so that a pixel two poses shown in a row share
keeps its colour where the original keeps the pixels around it (Converter.coherent; one by one a
gun pixel in a box line changed his chest's colours on that line: a stroke across his body from
one pose to the next), and add detail sprites for the gun's greys (GUN_GREYS): the OR-closed
colours have no grey or white, so the gun's highlights showed as two cyan stripes across his
black thigh and, while it spins, across his chest. A detail sprite is a box of its own placed
first in its band (in front, CC = 0, no B): one colour per line from the whole palette, set
only on the gun's pixels it brings closer to the original (chroma weighted: a grey stays grey),
while the band stays within RC_CAP; no other pixel changes.

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

The BOBs drawn into the play field instead (FIELD_PROCS, msx/field.asm): their atlas for the ROM
(<out>_field.bin, field_frames; the dynamic frames: <out>_fdyn.bin), its place table (<out>_field.inc) and the atlas as VRAM holds it
(<out>_field_vram.bin, for the checks).

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
GUN_GREYS = (9, 10, 11, 12)  # the gun's greys (Amiga sprite colours #333, #777, #AAA, #EEE)
GUN_CHROMA = 2.5             # chroma weight of their detail sprites' colours (a grey stays grey)
CALM_R, CALM_MOVE = 2, 0.3   # Converter.coherent: a pixel two poses in a row share keeps its colour
                             # where under CALM_MOVE of the 5 x 5 around it change
START_GROUPS = ((8, 15), (16, 25))  # start-of-level arm poses converted together (start_layouts):
                                    # the gun drawn, the gun spun
SKIP = 1                            # poses the display may skip in a row (a busy picture)
FIELD_PROCS = ("obj45_update", "obj26_update", "obj28_update", "FUN_00008de6",  # drawn into the
               "special_vehicle_l0")                                            # play field
FIELD_RIDDEN = ("FUN_00008de6", "special_vehicle_l0")   # the lifts and the vehicle: RoboCop rides
                                                        # them (msx/field.asm copies them last)
FIELD_FLASH = ("obj26_update", "obj28_update")  # the gunners that stay put (48 x 40: as sprites one
                                                # colour a line): their sprite frames stay for the
                                                # hit flash's silhouette, shown over the play field
FIELD_DYN = (0x45250, 0x45610, 0x45C28, 0x46420, 0x46CCC, 0x478FC,    # the explosion ($F266: 9 steps
             0x4857C, 0x487AC, 0x4898C, 0x4910C,                    # of one or two parts) and the
             0x67940, 0x67FD0, 0x68660, 0x68CF0, 0x69380, 0x69A10)  # smoke ($F080's frames 24-29):
                                                    # drawn into the play field from the ROM, a step
                                                    # at a time (the dynamic slot, msx/field.asm fb_dyn)
DYN_GROUPS = ((0x45250,), (0x45C28,), (0x46CCC,), (0x4857C, 0x4898C), (0x487AC, 0x4910C),
              (0x67940,), (0x68660,), (0x69380,))   # the frames shown together: side by side there
FIELD_HALF = {"45610:48:52": ["45250:48:32", 20, 0],  # (the user's choice, 2026-10-21: half the
              "46420:48:74": ["45c28:48:68", 6, 0],   # explosion's and the smoke's steps, the same
              "478fc:64:80": ["46ccc:64:78", 2, 0],   # time in all: each other step shows the one
              "67fd0:48:56": ["67940:48:56", 0, 0],   # before, where that one is drawn; the game's
              "68cf0:48:56": ["68660:48:56", 0, 0],   # logic is unchanged)
              "69a10:48:56": ["69380:48:56", 0, 0]}
FIELD_W, FIELD_H = 256, 112    # their atlas: page 3 lines FIELD_Y0.. (msx/field.asm)
FIELD_Y0 = 0                   # (tile slots 256-431 freed: the atlas; lines 112-175 the caches and
                               # the scratch, msx/field.asm)
DYN_H = 24                     # the dynamic slot: the atlas's last DYN_H lines, a frame's lines in
                               # strips of DYN_H side by side
FIELD_ID0 = 0xC8               # their BOBHASH ids: FIELD_ID0 + index (the sprite frames' stay below:
                               # 200 ids, the hit spark's four last)
FIELD_ROM = 0x2000             # the atlas in the ROM: one bank (upload table, then the frames)
DYN_ROM = 2 * 0x2000           # the dynamic frames in the ROM: two banks (none across a bank's end)


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
                   bg_count: np.ndarray, field: np.ndarray | None = None) -> tuple[list[int], list[list[np.ndarray]]]:
    """RoboCop's palette flashes ($F80E: COLOR17-31 from one of FLASHES for 5 game frames) on the
    joint palette. The entries tinted are RoboCop's (1..7) that the background never uses, nor
    the BOBs drawn into the play field ('field': their pixels per entry; their black is RoboCop's,
    which flashed their outlines), so that only the sprites change colour as on the Amiga; each
    takes the mean of the flash colours of the Amiga colours shown with it over every composition.
    -> (entries, per flash their 3-bit RGB colours)."""
    count = np.zeros((16, 16))
    for img, full in zip(comps, shown):
        m = (img > 0) & (full > 0)
        np.add.at(count, (img[m], full[m]), 1)
    bg_use = np.zeros(16)
    for c, k in enumerate(remap):
        bg_use[k] += bg_count[c]
    if field is not None:
        bg_use += field
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
        self.P = P
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

    def coherent(self, tgts: list[np.ndarray], links: list[tuple[int, int]],
                 fixed: list[tuple[int, np.ndarray, np.ndarray]], y_first: int,
                 extra: list[tuple[int, int]] = ()) -> list[list[tuple[int, list[dict]]]]:
        """Layouts of compositions shown one after another (the start of a level: his body still
        while his arm and the gun move) such that a pixel two of them shown in a row share shows
        the same in both, else each as close to the original as it can be on its own (converted
        one by one, a gun pixel in a box line changed his chest's colours on that line from one
        step to the next: a stroke across his body). links: the pairs (i, j) of 'tgts' shown in a
        row; fixed: (i, target, look) a composition shown next to i whose look (joint palette
        indices, 0 transparent) cannot change. The boxes are the same for all (over the pixels of
        all, bands from y_first); each keeps the OR layer of its boxes that gain most within cap;
        per box line every composition takes the colour or OR pair that minimises its error
        while no shared pixel shows two colours (the fewest mismatches with a fixed look where it
        cannot match): an exact min-sum over the links, a tree once one end of each loop's
        closing link is enumerated; extra: pairs also shown in a row now and then (a pose the
        display skips when the game is busy): with them, a branch and bound over every link,
        bounded by that solution improved one composition at a time."""
        n = len(tgts)
        h, w = tgts[0].shape
        union = np.zeros((h, w), bool)
        for t in tgts:
            union |= t > 0
        bottom = int(np.nonzero(union.any(1))[0][-1])
        opts: list[tuple[int, ...]] = [(c,) for c in range(1, len(self.P))] + [tuple(p) for p in self.pairs]
        n_single = len(self.P) - 1
        shown = np.array([[o[0], o[0], o[0]] if len(o) == 1 else [o[0], o[1], o[0] | o[1]] for o in opts])
        edges = sorted({(min(i, j), max(i, j)) for i, j in links if i != j})
        nb: list[set[int]] = [set() for _ in range(n)]
        for i, j in edges:
            nb[i].add(j)
            nb[j].add(i)
        parent = [-1] * n
        seen = [False] * n
        order: list[int] = []
        for r in range(n):
            if seen[r]:
                continue
            seen[r] = True
            queue = [r]
            while queue:
                u = queue.pop(0)
                order.append(u)
                for v in sorted(nb[u]):
                    if not seen[v]:
                        seen[v] = True
                        parent[v] = u
                        queue.append(v)
        tree = {(min(v, parent[v]), max(v, parent[v])) for v in range(n) if parent[v] >= 0}
        loops = [e for e in edges if e not in tree]
        cuts = sorted({j for _, j in loops})
        children = [[c for c in range(n) if parent[c] == u] for u in range(n)]

        def calm(a: np.ndarray, b: np.ndarray) -> np.ndarray:
            """The pixels a and b share whose surroundings stay still (fewer than CALM_MOVE of the
            (2 CALM_R + 1)^2 around change): there a pixel changing colour shows as a stroke; in
            a part that changes anyway (a black hip becoming a blue thigh) it goes unseen."""
            moved = ((a > 0) | (b > 0)) & (a != b)
            r = CALM_R
            pad = np.pad(moved, r)
            near = sum(pad[r + dy:r + dy + h, r + dx:r + dx + w].astype(int)
                       for dy in range(-r, r + 1) for dx in range(-r, r + 1))
            return (a > 0) & (a == b) & (near < CALM_MOVE * (2 * r + 1) ** 2)
        every = sorted(set(edges) | {(min(i, j), max(i, j)) for i, j in extra if i != j})
        static = {(i, j): calm(tgts[i], tgts[j]) for i, j in every}
        nb_all: list[list[int]] = [[] for _ in range(n)]
        for i, j in every:
            nb_all[i].append(j)
            nb_all[j].append(i)
        MISS = 1e7                                          # a shared pixel showing two colours

        def row(a: np.ndarray, y: int, x0: int) -> np.ndarray:
            return np.array([a[y, x] if 0 <= y < h and 0 <= x < w else 0 for x in range(x0, x0 + 16)])

        def solve_line(y: int, x0: int, allowed: np.ndarray) -> list[int]:
            """Per composition its option for one box line ('allowed': which options it may use)."""
            K, C = [], []
            for i in range(n):
                r = row(tgts[i], y, x0)
                m = r > 0
                d = self.D[r[:, None, None], shown[None, :, :]]          # (16, opts, 3)
                k = np.take_along_axis(shown[None, :, :].repeat(16, 0), d.argmin(2)[:, :, None], 2)[:, :, 0]
                k = np.where(m[:, None], k, 0).T                          # (opts, 16)
                c = (d.min(2) * m[:, None]).sum(0)
                for ti, tt, look in fixed:
                    if ti == i:
                        fl = row(look, y, x0)
                        same = m & (row(calm(tgts[i], tt).astype(np.int64), y, x0) > 0) & (fl > 0)
                        c = c + MISS * ((k != fl[None, :]) & same[None, :]).sum(1)
                C.append(np.where(allowed[i], c, np.inf))
                K.append(k)
            P = {}
            for i, j in every:
                s = row(static[(i, j)].astype(np.int64), y, x0) > 0
                P[(i, j)] = MISS * ((K[i][:, None, :] != K[j][None, :, :]) & s[None, None, :]).sum(2)

            def link(u: int, v: int) -> np.ndarray:                      # [option of u, option of v]
                return P[(u, v)] if u < v else P[(v, u)].T

            best = None
            for cut_opts in itertools.product(*[np.nonzero(allowed[c])[0].tolist() for c in cuts]):
                fix = dict(zip(cuts, cut_opts))
                msg, arg = {}, {}
                vals = {}
                for u in reversed(order):
                    v = C[u].copy()
                    if u in fix:
                        keep_only = np.full(len(opts), np.inf)
                        keep_only[fix[u]] = 0.0
                        v = v + keep_only
                    for a, b in loops:
                        if u == a and b in fix:
                            v = v + link(u, b)[:, fix[b]]
                        elif u == b and a in fix and a not in (u,) and u not in fix:
                            v = v + link(u, a)[:, fix[a]]
                    for ch in children[u]:
                        v = v + msg[ch]
                    vals[u] = v
                    if parent[u] >= 0:
                        tot = v[:, None] + link(u, parent[u])
                        arg[u] = tot.argmin(0)
                        msg[u] = tot.min(0)
                choice = {}
                total = 0.0
                for u in order:
                    if parent[u] < 0:
                        choice[u] = int(vals[u].argmin())
                        total += float(vals[u][choice[u]])
                    else:
                        choice[u] = int(arg[u][choice[parent[u]]])
                if best is None or total < best[0]:
                    best = (total, [choice[i] for i in range(n)])
            pick = best[1]
            if every == edges:
                return pick
            # the extra links: an exact branch and bound over all of them, bounded by that
            # solution improved one composition at a time
            for _ in range(4 * n):
                moved = False
                for i in range(n):
                    tot = C[i] + sum(link(i, j)[:, pick[j]] for j in nb_all[i])
                    o = int(tot.argmin())
                    if tot[o] < tot[pick[i]]:
                        pick[i] = o
                        moved = True
                if not moved:
                    break
            seq_ = sorted(range(n), key=lambda i: -len(nb_all[i]))
            cand = [[int(o) for o in np.argsort(C[i]) if np.isfinite(C[i][o])] for i in range(n)]
            low = [0.0] * (n + 1)
            for d in range(n - 1, -1, -1):
                low[d] = low[d + 1] + float(C[seq_[d]].min())
            bound = [float(sum(C[i][pick[i]] for i in range(n)) +
                           sum(link(i, j)[pick[i], pick[j]] for i, j in every)), list(pick)]
            assign: dict[int, int] = {}

            def search(d: int, run: float) -> None:
                if d == n:
                    if run < bound[0]:
                        bound[0], bound[1] = run, [assign[i] for i in range(n)]
                    return
                i = seq_[d]
                for o in cand[i]:
                    c = run + float(C[i][o])
                    if c + low[d + 1] >= bound[0]:
                        break
                    for j in nb_all[i]:
                        if j in assign:
                            c += float(link(i, j)[o, assign[j]])
                    if c + low[d + 1] >= bound[0]:
                        continue
                    assign[i] = o
                    search(d + 1, c)
                    del assign[i]
            search(0, 0.0)
            return bound[1]

        out: list[list[tuple[int, list[dict]]]] = [[] for _ in range(n)]
        for y0 in range(y_first, bottom + 1, 16):
            xs = np.nonzero(union[max(0, y0):max(0, y0 + 16)].any(0))[0]
            places, i = [], 0
            while i < len(xs):
                places.append(int(xs[i]))
                while i < len(xs) and xs[i] < places[-1] + 16:
                    i += 1
            if not places:
                continue
            # per composition, the boxes that keep an OR layer: within cap for the boxes it shows in
            # the band, those whose pairs gain most first (as one by one)
            gains = np.zeros((n, len(places)))
            for i, t in enumerate(tgts):
                for kb, x0 in enumerate(places):
                    for k in range(16):
                        r = row(t, y0 + k, x0)
                        if (r > 0).any():
                            _, e1, pr, e2 = self.line_choice(r[r > 0])
                            if pr is not None and e2 < e1:
                                gains[i, kb] += e1 - e2
            two = []
            for i, t in enumerate(tgts):
                has = [kb for kb, x0 in enumerate(places)
                       if (t[max(0, y0):max(0, y0 + 16), max(0, x0):x0 + 16] > 0).any()]
                keep = (self.cap - len(has)) if self.cap is not None else len(has)
                two.append(set(sorted((kb for kb in has if gains[i, kb] > 0), key=lambda kb: -gains[i, kb])[:max(0, keep)]))
            boxes: list[list[dict]] = [[] for _ in range(n)]
            for kb, x0 in enumerate(places):
                allowed = np.array([[o < n_single or kb in two[i] for o in range(len(opts))] for i in range(n)])
                A, B, A1, full, fb = ([np.zeros((16, 16), np.uint8) for _ in range(n)] for _ in range(5))
                cA, cB, cA1 = ([np.zeros(16, np.uint8) for _ in range(n)] for _ in range(3))
                pairs = [0] * n
                for kk in range(16):
                    y = y0 + kk
                    rows = [row(t, y, x0) for t in tgts]
                    if not any((r > 0).any() for r in rows):
                        continue
                    pick = solve_line(y, x0, allowed)
                    for i in range(n):
                        r = rows[i]
                        m = r > 0
                        if not m.any():
                            continue
                        c1 = self.line_choice(r[m])[0]
                        A1[i][kk, m] = 1
                        cA1[i][kk] = c1
                        fb[i][kk, m] = c1
                        o = opts[pick[i]]
                        if len(o) == 1:
                            A[i][kk, m] = 1
                            cA[i][kk] = o[0]
                            full[i][kk, m] = o[0]
                            continue
                        p, q = o
                        pairs[i] += 1
                        cA[i][kk], cB[i][kk] = p, q
                        for xx in np.nonzero(m)[0]:
                            kc = min((p, q, p | q), key=lambda t: self.D[r[xx], t])
                            full[i][kk, xx] = kc
                            A[i][kk, xx] = kc in (p, p | q)
                            B[i][kk, xx] = kc in (q, p | q)
                for i in range(n):
                    if A1[i].any():
                        boxes[i].append({"x": x0, "A": A[i], "A1": A1[i], "B": B[i], "cA": cA[i], "cA1": cA1[i],
                                         "cB": cB[i], "full": full[i], "fallback": fb[i], "has_b": pairs[i] > 0,
                                         "gain": float(gains[i, kb]), "err": 0.0})
            for i in range(n):
                out[i].append((y0, boxes[i]))
        return out

    def details(self, lays: list[list[tuple[int, list[dict]]]], srcs: list[np.ndarray],
                sppal: np.ndarray, keep: tuple[int, ...], chroma: float) -> list[list[tuple[int, list[dict]]]]:
        """Detail sprites for the pixels of colours 'keep' of the compositions 'srcs' (Amiga
        indices, colours 'sppal') over their layouts 'lays' (the same bands, as coherent() gives
        them): while a band has fewer than cap sprites on a line (in the layout that has most), a
        box in front of it (first in the band: CC = 0, no B) with one colour per line from the
        whole palette, placed and coloured for all of them at once (the gain summed; colours in
        CIELAB, the chroma weighted by 'chroma'), each setting only its own pixels that colour
        brings closer to the original, so that a pixel they share keeps its detail colour from
        one to the next."""
        w3 = np.array([1.0, chroma, chroma])
        E = (((lab(sppal)[:, None, :] - self.P[None, :, :]) * w3) ** 2).sum(-1)
        h, w = srcs[0].shape
        n = len(lays)
        out: list[list] = [[] for _ in range(n)]
        for bi in range(len(lays[0])):
            y0 = lays[0][bi][0]
            bands = [list(lay[bi][1]) for lay in lays]
            # the band's sprites on a line: the most of any of them (their boxes are the joint ones)
            used = max(len(bx) + sum(b["has_b"] for b in bx) for bx in bands)
            while used < self.cap:
                shown = [band_look(bands[j], y0, h, w) for j in range(n)]
                best = None
                for x0 in range(w):
                    gain = 0.0
                    As = [np.zeros((16, 16), np.uint8) for _ in range(n)]
                    cA = np.zeros(16, np.uint8)
                    for k in range(16):
                        y = y0 + k
                        if not 0 <= y < h:
                            continue
                        gs, sets = [], []
                        for j in range(n):
                            xs = [x for x in range(x0, min(w, x0 + 16)) if srcs[j][y, x] in keep]
                            if xs:
                                s = srcs[j][y, xs]
                                gs.append(np.maximum(0.0, E[s, shown[j][y, xs]][:, None] - E[s][:, 1:]))
                                sets.append((j, xs))
                        if not gs:
                            continue
                        tot = sum(g.sum(0) for g in gs)
                        c = int(tot.argmax()) + 1
                        if tot[c - 1] <= 0:
                            continue
                        gain += float(tot[c - 1])
                        cA[k] = c
                        for g, (j, xs) in zip(gs, sets):
                            As[j][k, [x - x0 for x, gx in zip(xs, g[:, c - 1]) if gx > 0]] = 1
                    if best is None or gain > best[0]:
                        best = (gain, x0, As, cA.copy())
                if best is None or best[0] <= 0:
                    break
                _, x0, As, cA = best
                for j in range(n):
                    if not As[j].any():
                        continue
                    full = np.where(As[j] > 0, cA[:, None], 0).astype(np.uint8)
                    bands[j].insert(0, {"x": x0, "A": As[j], "A1": As[j].copy(), "B": np.zeros_like(As[j]),
                                        "cA": cA, "cA1": cA.copy(), "cB": np.zeros_like(cA), "full": full,
                                        "fallback": full.copy(), "has_b": False, "gain": 0.0, "err": 0.0,
                                        "detail": True})
                used += 1
            for j in range(n):
                out[j].append((y0, bands[j]))
        return out


def band_look(boxes: list[dict], y0: int, h: int, w: int) -> np.ndarray:
    """What a band's boxes show (joint palette indices, h x w; only its lines): the first box of
    a band in front, as the VDP draws the earlier SAT entries."""
    out = np.zeros((h, w), np.uint8)
    for b in reversed(boxes):
        for k in range(16):
            y = y0 + k
            if not 0 <= y < h:
                continue
            for i in range(16):
                x = b["x"] + i
                if 0 <= x < w and b["full"][k, i]:
                    out[y, x] = b["full"][k, i]
    return out


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
               moves: dict[int, tuple[int, int, int]], sppal: np.ndarray | None = None,
               start: tuple[list[int], int] | None = None) -> list[list[tuple[int, list[dict]]]]:
    """RoboCop's layouts: converted, the left side the right one mirrored (mirror_pairs), the
    compositions repeat_steps added another one moved; start = (the start-of-level arm poses'
    compositions in their order, the one shown after them): those from start_layouts (colours
    'sppal' for the gun's detail sprites)."""
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

    if start is not None:
        lays.update(start_layouts(conv, comps, targets, start[0], start[1], sppal, lay))
    return [lay(c) for c in range(len(comps))]


def layout_look(lay: list[tuple[int, list[dict]]], shape: tuple[int, int]) -> np.ndarray:
    """What a layout shows (joint palette indices, 0 transparent): the first box of a band in front."""
    h, w = shape
    out = np.zeros((h, w), np.int64)
    for y0, boxes in lay:
        k0, k1 = max(0, -y0), min(16, h - y0)
        if k1 > k0:
            out[y0 + k0:y0 + k1] = np.where(out[y0 + k0:y0 + k1] > 0, out[y0 + k0:y0 + k1],
                                           band_look(boxes, y0, h, w)[y0 + k0:y0 + k1])
    return out


def linked_pixels(comps: list[np.ndarray], order: list[int], ends: list[int], skip: int = 0) -> dict[int, np.ndarray]:
    """Per composition of 'order' (shown one after another, up to 'skip' of them skipped now and
    then) other than 'ends': the pixels linked to the same pixel of one of 'ends' by equal pixels
    from one composition shown to the next."""
    cs = list(dict.fromkeys(order))
    pos = {c: i for i, c in enumerate(cs)}
    h, w = comps[cs[0]].shape
    stack = np.stack([comps[c] for c in cs])
    out = {c: np.zeros((h, w), bool) for c in cs if c not in ends}
    pairs = [(pos[order[k]], pos[order[k + d]]) for k in range(len(order)) for d in range(1, skip + 2)
             if k + d < len(order) and order[k] != order[k + d]]
    for y in range(h):
        for x in range(w):
            par = list(range(len(cs)))

            def root(i: int) -> int:
                while par[i] != i:
                    par[i] = par[par[i]]
                    i = par[i]
                return i
            for u, v in pairs:
                if stack[u, y, x] and stack[u, y, x] == stack[v, y, x]:
                    par[root(u)] = root(v)
            ends_r = {root(pos[e]) for e in ends}
            for c in out:
                if stack[pos[c], y, x] and root(pos[c]) in ends_r:
                    out[c][y, x] = True
    return out


def start_layouts(conv: "Converter", comps: list[np.ndarray], targets: list[np.ndarray], arms: list[int],
                  after: int, sppal: np.ndarray, lay) -> dict[int, list]:
    """The start-of-level arm poses (arms: their compositions in the order shown, ARM_POSES; after:
    the composition shown next, a frame of the game whose layout 'lay' gives and stays): one by
    one, a gun pixel in a box line changed his chest's colours on that line from one pose to the
    next (the user saw a stroke across his chest, arm and back while the gun spins). The groups
    START_GROUPS are converted together (Converter.coherent, the bands where 'after' has them),
    the last first, each pinned to the composition shown after it; the gun's grey detail sprites
    of a group are placed together (Converter.details) and never on a pixel linked to a
    neighbour group's or to 'after' (those the OR layers draw, the same on both sides)."""
    out: dict[int, list] = {}
    look = {after: layout_look(lay(after), comps[after].shape)}
    y_first = lay(after)[0][0]
    poses = list(player.ARM_POSES)
    shown = arms + [after]                              # (the display may skip a pose: SKIP)
    spans = [[k for k, a in enumerate(poses) if lo <= a <= hi] for lo, hi in START_GROUPS]
    for gi in reversed(range(len(spans))):
        ks = spans[gi]
        order = [shown[k] for k in ks]
        g = list(dict.fromkeys(order))
        pos = {c: i for i, c in enumerate(g)}
        links = [(pos[a], pos[b]) for a, b in zip(order, order[1:]) if a != b]
        extra = [(pos[shown[k]], pos[shown[k + d]]) for k in ks for d in range(2, SKIP + 2)
                 if k + d <= ks[-1] and shown[k] != shown[k + d]]
        fixed = [(pos[shown[k]], targets[shown[k + d]], look[shown[k + d]]) for k in ks for d in range(1, SKIP + 2)
                 if ks[-1] < k + d < len(shown) and shown[k + d] in look]
        lays = conv.coherent([targets[c] for c in g], links, fixed, y_first, extra)
        lo, hi = max(0, ks[0] - SKIP - 1), min(len(shown), ks[-1] + SKIP + 2)
        ends = [shown[k] for k in range(lo, hi) if not ks[0] <= k <= ks[-1]]
        linked = linked_pixels(comps, shown[lo:hi], ends, SKIP)
        lays = conv.details(lays, [np.where(linked[c], 0, comps[c]) for c in g], sppal, GUN_GREYS, GUN_CHROMA)
        for c, lc in zip(g, lays):
            out[c] = [(y, bx) for y, bx in lc if bx]
            look[c] = layout_look(out[c], comps[c].shape)
    return out


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
        for b in reversed(boxes):                       # (the first box of a band in front)
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


def field_frames(ram: bytes, near: np.ndarray, frames: list[dict], removed: dict) -> dict:
    """The play-field BOB frames (FIELD_PROCS, FIELD_DYN): their atlas (FIELD_H x FIELD_W
    joint-palette indices, 0 transparent: opaque black takes another black, as near[] starts at
    entry 1) and per frame its place there, the size drawn ("sw", "sh"; "w", "h" stay the game's,
    BOBHASH's key) and its draw offset. A removed frame (removed: "addr:w:h" -> [the frame shown
    instead, dy, dx]) shows that one moved by (dx, dy). The others are packed in shelves by height
    (even x: two pixels a byte) above the dynamic slot, the atlas's last DYN_H lines: the frames of
    FIELD_DYN, too big to stay in VRAM, each group of DYN_GROUPS side by side from its left, each
    frame's lines in strips of DYN_H side by side, copied there from the ROM when shown
    (msx/field.asm fb_dyn). The rest of the atlas goes into the ROM frame by frame (FIELD_ROM: no
    room for its empty parts), a frame that is another's exact mirror as a reference to that one's
    pixels (msx/field.asm field_upload mirrors them):
      db n; n x [db atlas line, db x / 2, db bytes a line, db lines, db 1 when mirrored,
      dw offset of the pixels in the image]; the pixels (two a byte, the left one high).
    The dynamic frames' pixels (a line of the slot after another: its strips' lines side by side,
    as VRAM holds them; none across a bank's end) go into their own banks
    ("dyn_rom"), per frame ("dyn_tab") its bit, the frames whose place in the slot it takes,
    its bank and its address in the 8000h window."""
    key = lambda f: f"{f['addr']:x}:{f['w']}:{f['h']}"      # noqa: E731
    rank = {p: i for i, p in enumerate(FIELD_PROCS)}
    late = min(rank[p] for p in FIELD_RIDDEN)               # (the dynamic frames before the lifts)
    frames = sorted(frames, key=lambda f: (late - 0.5 if f["addr"] in FIELD_DYN else rank[f["proc"]], f["addr"]))
    imgs = {}
    for f in frames:
        src = bob_image(ram, f["addr"], f["w"], f["h"])
        if (src >= 0).sum() and key(f) not in removed:
            imgs[key(f)] = np.where(src >= 0, near[np.clip(src, 0, 15)], 0)
    dyn = {key(f) for f in frames if f["addr"] in FIELD_DYN and key(f) in imgs}
    dyn_y = FIELD_H - DYN_H
    atlas = np.zeros((FIELD_H, FIELD_W), np.uint8)
    place, x, y, shelf = {}, 0, 0, 0
    table, pixels, stored = [], bytearray(), {}
    for k in sorted((k for k in imgs if k not in dyn), key=lambda k: (-imgs[k].shape[0], -imgs[k].shape[1], k)):
        h, w = imgs[k].shape
        assert w % 2 == 0, "a play-field frame of an odd width"
        if x + w > FIELD_W:
            x, y, shelf = 0, y + shelf, 0
        assert y + h <= dyn_y, "the play-field frames do not fit their atlas"
        atlas[y:y + h, x:x + w] = imgs[k]
        place[k] = (x, y)
        src = next((j for j in stored if imgs[j].shape == (h, w) and np.array_equal(imgs[j][:, ::-1], imgs[k])),
                   None)
        if src is None:
            stored[k] = len(pixels)
            pixels += bytes(int(imgs[k][r, c]) << 4 | int(imgs[k][r, c + 1]) for r in range(h) for c in range(0, w, 2))
        table.append((y, x // 2, w // 2, h, int(src is not None), stored[src if src is not None else k]))
        x += w
        shelf = max(shelf, h)
    lines = y + shelf
    head = 1 + 7 * len(table)
    rom = bytes([len(table)]) + b"".join(struct.pack("<BBBBBH", ty, tx, bpl, h, m, head + off)
                                         for ty, tx, bpl, h, m, off in table) + bytes(pixels)
    assert len(table) < 256 and len(rom) <= FIELD_ROM, f"the play-field atlas takes {len(rom)} bytes of the ROM"
    dyn_list, span = [], {}                                 # the dynamic slot
    for group in DYN_GROUPS:
        x = 0
        for a in group:
            k = next(k for k in dyn if int(k.split(":")[0], 16) == a)
            h, w = imgs[k].shape
            n = -(-h // DYN_H)
            place[k], span[k] = (x, dyn_y), (x, x + n * w)
            for s in range(n):                              # (the atlas image: the last group's)
                strip = imgs[k][s * DYN_H:(s + 1) * DYN_H]
                atlas[dyn_y:dyn_y + len(strip), x + s * w:x + (s + 1) * w] = strip
            x += n * w
            assert x <= FIELD_W, "a group of dynamic frames wider than the slot"
            dyn_list.append(k)
    assert set(dyn_list) == dyn and len(dyn_list) <= 16, "the dynamic frames and DYN_GROUPS differ"
    dyn_rom, dyn_tab = bytearray(), []
    for i, k in enumerate(dyn_list):
        h, w = imgs[k].shape
        rows = [r + DYN_H * st for r in range(min(h, DYN_H)) for st in range(-(-h // DYN_H)) if r + DYN_H * st < h]
        data = bytes(int(imgs[k][r, c]) << 4 | int(imgs[k][r, c + 1]) for r in rows for c in range(0, w, 2))
        if len(dyn_rom) // BANK != (len(dyn_rom) + len(data) - 1) // BANK:
            dyn_rom += b"\xff" * (-len(dyn_rom) % BANK)
        evict = sum(1 << j for j, k2 in enumerate(dyn_list)
                    if j != i and span[k2][0] < span[k][1] and span[k][0] < span[k2][1])
        dyn_tab.append((1 << i, evict, len(dyn_rom) // BANK, 0x8000 + len(dyn_rom) % BANK))
        dyn_rom += data
    assert len(dyn_rom) <= DYN_ROM, f"the dynamic frames take {len(dyn_rom)} bytes of the ROM"
    out = []
    for f in frames:
        k = key(f)
        if k in imgs:
            src, ox, oy = k, 0, 0
        elif k in removed and removed[k] and removed[k][0] in place:
            src, oy, ox = removed[k]
        else:
            continue                                        # (no pixel: never drawn)
        (x, y), (sh, sw) = place[src], imgs[src].shape
        e = {"proc": f["proc"], "addr": f["addr"], "w": f["w"], "h": f["h"], "fid": len(out),
             "x": x, "y": y, "sw": sw, "sh": sh, "ox": ox, "oy": oy, "src": src}
        if src in dyn:
            e["dyn"] = dyn_list.index(src)
        out.append(e)
    fid = {e["src"]: e["fid"] for e in out if key(e) == e["src"]}
    for e in out:                                           # (the frame of the look it draws: a
        e["look"] = fid[e["src"]]                           # removed frame where the frame shown is
                                                            # drawn changes nothing, msx/field.asm)
    assert len(out) <= 0xFF - FIELD_ID0, "too many play-field frames for their BOBHASH ids"
    fd = [e["fid"] for e in out if "dyn" in e]
    assert fd == list(range(fd[0], fd[-1] + 1)) if fd else True, "the dynamic frames' ids not in a row"
    used = sum(np.bincount(img.ravel(), minlength=16) for img in imgs.values())
    return {"frames": out, "atlas": atlas, "lines": lines, "rom": rom, "dyn_rom": bytes(dyn_rom),
            "dyn_tab": dyn_tab, "dyn_y": dyn_y, "used": used}


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
    n0 = 4 * len(level.records)
    arms = [index[n0 + k] for k in range(len(player.ARM_POSES))]
    after = index[player.arm_record(level.game.records()) * 4 + player.ARM_AIM]
    assert not set(arms) & set(index[:n0]), "an arm pose shared with a frame record would change its look"
    layouts = rc_layouts(conv, comps, targets, pairs, moves, level.sppal, (arms, after))
    assert len(targets) == len(layouts) == len(comps)
    stats.update({"rc_index": index, "rc_moves": {str(c): list(v) for c, v in sorted(moves.items())},
                  "rc_mirrors": {str(c): list(v) for c, v in sorted(pairs.items())},
                  "rc_start": {"arms": arms, "after": after}})
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
    field = None
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
        # the hostage, the gunners that stay put, the explosion, the smoke, the lifts and the vehicle
        # are drawn into the play field (decision 13): no sprite data for them but the gunners' (their
        # hit flash's silhouette)
        field = field_frames(ram, near, [f for f in frames if f["proc"] in FIELD_PROCS or f["addr"] in FIELD_DYN],
                             dict(removed.get("bob", {}), **FIELD_HALF))
        frames = [f for f in frames if (f["proc"] not in FIELD_PROCS or f["proc"] in FIELD_FLASH)
                  and f["addr"] not in FIELD_DYN]
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
    fidx, fpals = flash_palettes(a.main.read_bytes(), comps, [p[1] for p in previews], remap, level.bg_count,
                                 field["used"] if field else None)
    a.out.with_name(a.out.name + "_flash.inc").write_text(
        "; generated by tools/msxsprites.py: RoboCop's palette flashes ($F80E) on the joint palette\n"
        f"FLASH_N: equ {len(fidx)}                  ; entries tinted (RoboCop's that the background and the play-field BOBs never use)\n"
        "flash_idx:\n        db " + ", ".join(map(str, fidx)) + "\n"
        "flash_pals:                         ; PAL_ENEMYHIT, PAL_SHOT, PAL_ELECTRIC, PAL_REFILL, PAL_BEAM, PAL_REVERSE\n"
        + "".join("        db " + ", ".join(f"0x{(r << 4) | b:02X}, 0x{g:02X}" for r, g, b in row) + "\n"
                  for row in fpals))
    for f in field["frames"] if field else []:          # the gunners' play-field frames: their sprite
        f["sil"] = 0xFF                                 # frames show only their hit flash (BOBHASH
        if f["proc"] in FIELD_FLASH:                    # gives the play-field one, and "sil")
            b = next(b for b in bobs if (b["addr"], b["w"], b["h"]) == (f["addr"], f["w"], f["h"]))
            b["field"] = f["fid"]
            f["sil"] = b["id"]
    stats.update({"palette": ["%d%d%d" % tuple(c) for c in q], "remap": remap, "patterns": len(pats.items),
                  "colour_rows": len(cols_pool.items), "bytes": len(data), "bobs": bobs,
                  "field": field["frames"] if field else []})
    if field:                                           # the play-field BOBs: atlas and table
        at = field["atlas"]
        a.out.with_name(a.out.name + "_field.bin").write_bytes(field["rom"])
        a.out.with_name(a.out.name + "_fdyn.bin").write_bytes(field["dyn_rom"])
        a.out.with_name(a.out.name + "_field_vram.bin").write_bytes(     # (the atlas as VRAM holds it:
            bytes(int(at[y, x]) << 4 | int(at[y, x + 1])                 # the tools' checks)
                  for y in range(FIELD_H) for x in range(0, FIELD_W, 2)))
        fd = [f for f in field["frames"] if "dyn" in f]
        a.out.with_name(a.out.name + "_field.inc").write_text(
            "; generated by tools/msxsprites.py: the play-field BOB frames (msx/field.asm)\n"
            f"FIELD_N: equ {len(field['frames'])}\n"
            f"FIELD_Y0: equ {FIELD_Y0}                ; their atlas: page 3 from this line (VRAM {0x18000 + FIELD_Y0 * 128:05X}h)\n"
            f"FIELD_LINES: equ {field['lines']}\n"
            f"FIELD_ID0: equ 0x{FIELD_ID0:02X}             ; their BOBHASH ids: FIELD_ID0 + index\n"
            f"FIELD_LATE: equ {min([f['fid'] for f in field['frames'] if f['proc'] in FIELD_RIDDEN] or [len(field['frames'])])}"
            "              ; frames from here: the lifts and the vehicle\n"
            f"FIELD_DYN0: equ {fd[0]['fid'] if fd else 0}              ; frames from here to FIELD_DYN1 (excluded): the\n"
            f"FIELD_DYN1: equ {fd[-1]['fid'] + 1 if fd else 0}              ;   dynamic slot's (field.asm fb_dyn)\n"
            f"DYN_Y: equ {field['dyn_y']}                   ; the dynamic slot: atlas lines DYN_Y..DYN_Y + DYN_H - 1\n"
            f"DYN_H: equ {DYN_H}\n"
            "field_tab:                          ; per frame: x, y in the atlas, width, height (as drawn), dx, dy\n"
            "                                    ; (signed: the draw offset of a removed frame shown as another)\n"
            + "".join(f"        db {f['x']}, {f['y']}, {f['sw']}, {f['sh']}, {f['ox'] & 255}, {f['oy'] & 255}"
                      f"      ; {f['proc']} {f['addr']:05X}\n" for f in field["frames"])
            + "field_look:                         ; per frame: the frame it looks like (a removed frame: the\n"
              "                                    ; one shown instead; field.asm fb_wants)\n"
            + "".join(f"        db {f['look']}      ; {f['addr']:05X}\n" for f in field["frames"])
            + "field_dyn:                          ; per frame from FIELD_DYN0: the dynamic frame of its pixels\n"
            + "".join(f"        db {f['dyn']}      ; {f['addr']:05X}\n" for f in fd)
            + "dyn_tab:                            ; per dynamic frame: its bit, the frames whose place it takes\n"
              "                                    ; (bits), bank (from FIELD_DYN_BANK), address (8000h window)\n"
            + "".join(f"        dw 0x{bit:04X}, 0x{ev:04X}\n        db {bk}\n        dw 0x{ad:04X}\n        db 0\n"
                      for bit, ev, bk, ad in field["dyn_tab"]))
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
