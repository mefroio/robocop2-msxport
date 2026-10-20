#!/usr/bin/env python3
"""RoboCop in MSX hardware sprites (mode 2, OR technique) and the level's joint palette.

Joint palette (decision 1 in docs/MSX_ARCHITECTURE.md; approved mockup tools/msxmock_or3.py):
16 MSX colours from a weighted k-means over the level background (tile pixels counted over
the whole map) and RoboCop (every composition, weight 4). One of the slots 1..15 is black
(index 0 is transparent for sprites). RoboCop's 7 most useful colours sit at the OR-closed
indices 1..7, in the order that minimises the per-line error of the OR pairs. Background
pixels are remapped to the nearest entry (CIELAB).

Sprites: every composition draw_player can show (frame record x aim, tools/player.py) is cut
into 16 px columns (grid offset chosen per composition). Each line of a column gets either one
colour (layer A only) or an OR pair: layer A colour p and layer B colour q with CC = 1, so
that pixels set in both show p|q (p, q in 1..7). A covers the lines with pixels, B only the
lines that use a pair; both are 16-line sprites placed freely in y. Each column also has a
single-layer fallback A1 (one colour per line, every pixel set) that replaces A + B when its
B sprites must be dropped on lines shared with enemies (adaptive budget), so dropping a layer
never leaves holes. In the SAT a column is [A spans..., B spans...]: on every line the B that
covers it directly follows the A that covers it, which is what the VDP needs for the OR.

Enemies and the other BOBs of the level (tools/bobcatalog.py's catalogue, with --bobs) go the
same way, with OR pairs over the whole palette (their colours are the background's, not
OR-closed), and share the pattern and colour pools.

ROM data (<out>.bin, 8 KiB banks, see FORMAT below) and <out>.inc (equates), plus <out>.pal
(joint palette, V9938 format), <out>.remap (16 bytes: Amiga background index -> joint index),
<out>.json (statistics) and <out>.png (every composition: software | full | fallback).

Run time (msx/sprites.asm): dropping a column's OR layer takes its B sprites out and switches
its A sprites to A1; the header's per-line maxima tell the budget where objects can conflict,
the rank list gives the columns in the order their OR layers are dropped, and the maxima after
each prefix of it how many RoboCop must drop beside enemies.

FORMAT (all little-endian words; banks relative to the first sprite bank):
  banks 0..SPR_PAT_BANK-1: index: per (record*4 + aim) db bank, dw offset in that bank;
                     then (at id SPR_RC_ARM) the same per start-of-level arm pose ($1676 =
                     8..25 on record PL_ARM_REC, aim 2: tools/player.py ARM_POSES);
                     then (at SPR_BOB_INDEX) the same per BOB frame (<out>.json "bobs")
                     compositions (none crosses a bank boundary):
                       db nspr, db nlines (lines covered by the sprites), db ncols,
                       db min dx, db max dx (signed: left edges of the leftmost and
                       rightmost sprites), db sprites of the one-layer version (A spans),
                       db most sprites on a line, db the same for the one-layer version
                       nspr x 12 bytes in SAT order (per column: A spans, then B spans):
                         db dy, db dx (signed), db park bit (B sprite: 1 << column, else 0),
                         db A1 bit (A sprite: 1 << column, else 0), dw pattern, dw colour,
                         dw pattern A1, dw colour A1 (FFFFh for B sprites)
                       ncols x rank list entries, lowest rank (dropped first) first:
                         db 1 << column, db gain (what dropping its OR layer costs:
                         12 log2(1 + Lab error), at most 254: FFh means "none" at run
                         time), db nB, nB x db dy of its B spans
                       (ncols + 1) x db: most sprites on a line with the first k rank entries'
                         OR layers dropped, k = 0..ncols (the first is the header's maximum,
                         the last the one-layer version's)
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
        """Distinct compositions and the index of its composition per (record, aim), then per
        start-of-level arm pose."""
        comps, index, seen = [], [], {}

        def add(img: np.ndarray) -> None:
            key = img.tobytes()
            if key not in seen:
                seen[key] = len(comps)
                comps.append(img)
            index.append(seen[key])

        for r in self.records:
            for aim in range(4):
                add(np.array(self.game.compose(r, aim)))
        rec = self.records[player.arm_record(self.records)]
        for arm in player.ARM_POSES:
            add(np.array(self.game.compose(rec, player.ARM_AIM, arm)))
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


def spans(lines: list[int]) -> list[int]:
    """First lines of the 16-line sprites that cover the given (sorted) lines."""
    out, i = [], 0
    while i < len(lines):
        out.append(lines[i])
        while i < len(lines) and lines[i] < out[-1] + 16:
            i += 1
    return out


class Converter:
    def __init__(self, pal: np.ndarray, pairs: list[tuple[int, int]] = PAIRS):
        P = lab(pal)
        self.D = ((P[:, None, :] - P[None, :, :]) ** 2).sum(-1)
        self.pairs = pairs

    def line_choice(self, t: np.ndarray) -> tuple:
        """t = target indices of the opaque pixels of one line of a column.
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

    def column(self, tgt: np.ndarray, x0: int) -> dict | None:
        h = tgt.shape[0]
        cols = range(x0, x0 + 16)
        A, A1, B = np.zeros((h, 16), np.uint8), np.zeros((h, 16), np.uint8), np.zeros((h, 16), np.uint8)
        cA, cA1, cB = np.zeros(h, np.uint8), np.zeros(h, np.uint8), np.zeros(h, np.uint8)
        full = np.zeros((h, 16), np.uint8)
        fb = np.zeros((h, 16), np.uint8)
        lines_a, lines_b = [], []
        e_full = e_fb = 0.0
        for y in range(h):
            row = np.array([tgt[y, x] if 0 <= x < tgt.shape[1] else 0 for x in cols])
            m = row > 0
            if not m.any():
                continue
            lines_a.append(y)
            c, e1, pair, e2 = self.line_choice(row[m])
            A1[y, m] = 1
            cA1[y] = c
            fb[y, m] = c
            e_fb += e1
            if pair is None or e1 <= e2:
                A[y, m] = 1
                cA[y] = c
                full[y, m] = c
                e_full += e1
                continue
            p, q = pair
            lines_b.append(y)
            cA[y], cB[y] = p, q
            e_full += e2
            for i in np.nonzero(m)[0]:
                k = min((p, q, p | q), key=lambda k: self.D[row[i], k])
                full[y, i] = k
                A[y, i] = k in (p, p | q)
                B[y, i] = k in (q, p | q)
        if not lines_a:
            return None
        return {"x": x0, "A": A, "A1": A1, "B": B, "cA": cA, "cA1": cA1, "cB": cB,
                "spans_a": spans(lines_a), "spans_b": spans(lines_b),
                "gain": e_fb - e_full, "full": full, "fallback": fb}

    def composition(self, tgt: np.ndarray) -> list[dict]:
        xs = np.nonzero((tgt > 0).any(0))[0]
        best = None
        for off in range(16):
            gx = int(xs[0]) - off
            n = (int(xs[-1]) - gx) // 16 + 1
            cols = [c for c in (self.column(tgt, gx + 16 * k) for k in range(n)) if c]
            cost = (sum(len(c["spans_a"]) + len(c["spans_b"]) for c in cols), max_per_line(cols, tgt.shape[0]))
            if best is None or cost < best[0]:
                best = (cost, cols)
        return best[1]


def max_per_line(cols: list[dict], h: int, use_b: bool = True) -> int:
    count = np.zeros(h + 16, int)
    for c in cols:
        for y in c["spans_a"] + (c["spans_b"] if use_b else []):
            count[y:y + 16] += 1
    return int(count.max())


def pattern_bytes(bits: np.ndarray, y0: int) -> bytes:
    """16x16 sprite pattern from rows y0..y0+15 of a column bitmap: the VDP reads line y of
    the left half at byte y and of the right half at byte y + 16."""
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


def encode(columns: list[dict], pats: "Pool", cols_pool: "Pool") -> tuple[bytes, list, int]:
    """Composition record (FORMAT) of the cut columns; returns (blob, sprites, nlines)."""
    order = sorted(range(len(columns)), key=lambda k: columns[k]["gain"])
    assert len(columns) <= 8, "the drop mask has 8 bits"
    sprites = []
    for k, c in enumerate(columns):
        for y in c["spans_a"]:
            sprites.append((c["x"], y, 0, 1 << k, pats.add(pattern_bytes(c["A"], y)),
                            cols_pool.add(colour_bytes(c["cA"], y, False)),
                            pats.add(pattern_bytes(c["A1"], y)), cols_pool.add(colour_bytes(c["cA1"], y, False))))
        for y in c["spans_b"]:
            sprites.append((c["x"], y, 1 << k, 0, pats.add(pattern_bytes(c["B"], y)),
                            cols_pool.add(colour_bytes(c["cB"], y, True)), 0xFFFF, 0xFFFF))
    nlines = max(y for _, y, *_ in sprites) + 16
    count, count1 = [0] * nlines, [0] * nlines
    for _, y, pbit, *_ in sprites:
        for line in range(y, y + 16):
            count[line] += 1
            count1[line] += not pbit
    dxs = [x for x, *_ in sprites]
    n_a = sum(1 for s in sprites if not s[2])
    out = bytearray(struct.pack("<BBBbbBBB", len(sprites), nlines, len(columns), min(dxs), max(dxs), n_a,
                                max(count), max(count1)))
    for x, y, pbit, abit, p, c, p1, c1 in sprites:
        out += struct.pack("<BbBBHHHH", y, x, pbit, abit, p, c, p1, c1)
    for k in order:
        out += bytes([1 << k, gain_byte(columns[k]["gain"]), len(columns[k]["spans_b"])] + columns[k]["spans_b"])
    for k in range(len(order) + 1):
        dropped = sum(1 << c for c in order[:k])
        cnt = [0] * nlines
        for _, y, pbit, *_ in sprites:
            if not pbit & dropped:
                for line in range(y, y + 16):
                    cnt[line] += 1
        out.append(max(cnt))
    return bytes(out), sprites, nlines


def preview(columns: list[dict], tgt: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    full = np.zeros_like(tgt)
    fb = np.zeros_like(tgt)
    for c in columns:
        for i in range(16):
            x = c["x"] + i
            if 0 <= x < tgt.shape[1]:
                full[:, x] = np.where(c["full"][:, i] > 0, c["full"][:, i], full[:, x])
                fb[:, x] = np.where(c["fallback"][:, i] > 0, c["fallback"][:, i], fb[:, x])
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
    ap.add_argument("out", type=Path)
    a = ap.parse_args()
    level = Level(a.main.read_bytes(), a.perma.read_bytes(), a.datal.read_bytes(), a.rows)
    comps, index = level.compositions()
    pal = order_palette(joint_palette(level, comps), comps, level.sppal)
    remap = [0] + [int(i) for i in nearest(level.bgpal[1:], pal)]
    conv = Converter(pal)
    pats, cols_pool = Pool(), Pool()
    blobs, stats = [], {"compositions": len(comps), "sprites": [], "one_layer": [], "lines": [], "max_line": [],
                        "max_line_fallback": []}
    previews = []
    for img in comps:
        tgt = np.where(img > 0, nearest(level.sppal[img], pal, 1), 0)
        columns = conv.composition(tgt)
        blob, sprites, nlines = encode(columns, pats, cols_pool)
        assert len(sprites) <= 32, "an entry page (msx/sprites.asm) holds 32 entries"
        blobs.append(blob)
        stats["sprites"].append(len(sprites))
        stats["one_layer"].append(sum(1 for s in sprites if not s[2]))
        stats["lines"].append(nlines)
        stats["max_line"].append(max_per_line(columns, tgt.shape[0]))
        stats["max_line_fallback"].append(max_per_line(columns, tgt.shape[0], False))
        previews.append(preview(columns, tgt))
    # the level's BOBs (enemies, shots, explosions...): opaque pixels take entries 1..15
    bobs, bob_blobs, bob_previews = [], [], []
    if a.bobs:
        ram = a.ram.read_bytes()
        bconv = Converter(pal, PAIRS_ALL)
        frames = bob_frames(a.bobs, a.level)
        seen = {(f["addr"], f["w"], f["h"]) for f in frames}
        for d in a.drawn:
            j = json.loads(d.read_text())
            for f in j.get("bobs", j.get("frames", [])):
                key = (f["addr"], f["w"], f["h"])
                if key not in seen and f["w"] > 0 and f["h"] > 0:
                    seen.add(key)
                    frames.append({"proc": "drawn", "addr": f["addr"], "w": f["w"], "h": f["h"]})
        for fr in frames:
            src = bob_image(ram, fr["addr"], fr["w"], fr["h"])
            if (src >= 0).sum() == 0:
                continue
            near = nearest(level.bgpal, pal, 1)
            tgt = np.where(src >= 0, near[np.clip(src, 0, 15)], 0)
            columns = bconv.composition(tgt)
            blob, sprites, nlines = encode(columns, pats, cols_pool)
            bob_blobs.append(blob)
            fr.update({"id": len(bobs), "sprites": len(sprites), "fallback": sum(1 for s in sprites if s[3]),
                       "lines": nlines, "max_line": max_per_line(columns, tgt.shape[0]),
                       "max_line_fallback": max_per_line(columns, tgt.shape[0], False)})
            bobs.append(fr)
            bob_previews.append(preview(columns, tgt))
    # index + compositions, packed so that no composition crosses a bank boundary
    nidx = len(index) + len(bobs)
    where, area, pos = [], bytearray(3 * nidx), 3 * nidx
    for b in blobs + bob_blobs:
        if pos // BANK != (pos + len(b) - 1) // BANK:
            pos = (pos // BANK + 1) * BANK
        where.append(pos)
        area += b"\xff" * (pos - len(area)) + b
        pos += len(b)
    for k, i in enumerate(index):
        area[3 * k:3 * k + 3] = struct.pack("<BH", where[i] // BANK, where[i] % BANK)
    for k in range(len(bobs)):
        w = where[len(blobs) + k]
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
        f"SPR_BOB_INDEX: equ 0x{0x8000 + 3 * len(index):04X}           ; their index (bank SPR_BASE_BANK at 8000h)\n")
    q = np.round(pal * 7).astype(int)
    a.out.with_suffix(".pal").write_bytes(bytes(b for r, g, bl in q for b in ((r << 4) | bl, g)))
    a.out.with_suffix(".remap").write_bytes(bytes(remap))
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
