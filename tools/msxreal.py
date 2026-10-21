#!/usr/bin/env python3
"""Checks the pictures openMSX really rendered against the expected frames.

Input: the directories tools/openmsx_rc2.tcl rc2_real writes, one per frame (the state at the
end of the frame's display: VRAM, RAM, VDP registers; real.png: openMSX's raw screenshot of
that frame, 320 x 240 with the borders). The expected frame is tools/msxframe.py's (the map at
the camera of the list the frame showed, the sprite objects that list shows, the HUD as
msx/hud.asm records it), but compared with what the VDP drew line by line instead of a
static render of VRAM, so writes during the display, per-line sprite limits and the split
all count. openMSX's picture is taken at (32, 14) for the whole display (R#18 included: the
expected frame's coordinates are those of tools/msxscreen.py's render, which applies it);
colours are compared after taking openMSX's 8-bit levels back to the 3-bit ones. Capture with
openMSX rendering every frame ('set maxframeskip 0': unthrottled it skips frames otherwise).

Per frame: the differing pixels of the play area (sprite pixels apart: the expected sprite
pixels shown wrong, and other pixels where a sprite shows where none should), of the
border lines and of the HUD; with --png, frame and difference images (magenta: differs).

usage: msxreal.py CAPTURE_DIR [--level build/msx/level1] [--hud build/msx/hud] [--png OUTDIR]
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import msxframe as mf  # noqa: E402
from planar import write_png  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BORDER_X, BORDER_Y = 32, 14                     # raw screenshot: display (0, 0) without adjust


def read_png(path: Path) -> tuple[int, int, list[bytes]]:
    """RGB rows of a PNG (8-bit RGB or RGBA, no interlace: what openMSX writes)."""
    import zlib
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, kind = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack_from(">IIBB", body)
            assert depth == 8 and ctype in (2, 6), (depth, ctype)
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        rows.append(bytes(line) if bpp == 3 else bytes(v for k, v in enumerate(line) if k % 4 != 3))
    return w, h, rows


def level3(v: int) -> int:
    return (v * 7 + 127) // 255


def check(d: Path, level: Path, hud: Path) -> tuple[dict, list[bytes], list[bytes]]:
    ram = (d / "ram.bin").read_bytes()
    base = [int(v) for v in (d / "regs.txt").read_text().split()]
    play, cam_x, cam_y, objs = mf.applied_list(ram)
    regs_play = list(base)
    for r, v in play.items():
        regs_play[r] = v
    _, _, real = read_png(d / "real.png")
    pal_play = level.with_suffix(".pal").read_bytes()
    pal_hud = hud.with_suffix(".pal").read_bytes()
    prgb, hrgb = mf.rgb9(pal_play), mf.rgb9(pal_hud)
    mp = level.with_suffix(".map").read_bytes()
    til = level.with_suffix(".til").read_bytes()
    rows_map = len(mp) // (mf.COLS * 2)
    spr = mf.expected_sprites(objs, pal_play)
    hud_want = mf.hud_expected(ram)
    res = {"spr_bad": 0, "spr_px": 0, "extra": 0, "bg_bad": 0, "hud_bad": 0, "gap_bad": 0,
           "cam": (cam_x, cam_y), "objs": [o for o in objs if o["shown"]]}
    want_rows, diff_rows = [], []
    border = regs_play[7] & 15
    for y in range(212):
        wrow, drow = bytearray(256 * 3), bytearray(256 * 3)
        sy = BORDER_Y + y
        for x in range(256):
            if y < mf.VIEW:
                sx = BORDER_X + x
                wx, wy = cam_x + x - 8, cam_y + y
                if x < 8 or wy // 16 >= rows_map or wx // 16 >= mf.COLS or wx < 0:
                    want = None
                else:
                    t = mp[2 * ((wy // 16) * mf.COLS + wx // 16)] | mp[2 * ((wy // 16) * mf.COLS + wx // 16) + 1] << 8
                    b = til[t * 128 + (wy % 16) * 8 + (wx % 16) // 2]
                    want = prgb[(b >> 4) if wx % 2 == 0 else b & 15]
                    if (x, y) in spr:
                        want = prgb[spr[(x, y)]]
                kind = "spr" if (x, y) in spr else "bg"
            elif y < mf.HUD_TOP:
                sx, want, kind = BORDER_X + x, prgb[border], "gap"
            else:
                sx = BORDER_X + x
                want = None if hud_want is None else hrgb[hud_want[y - mf.HUD_TOP][x]]
                kind = "hud"
            got = real[sy][3 * sx:3 * sx + 3] if 0 <= sx < 320 else b"\0\0\0"
            g3 = tuple(level3(v) for v in got)
            wrow[3 * x:3 * x + 3] = bytes(want) if want is not None else got
            drow[3 * x:3 * x + 3] = got
            if want is None:
                continue
            w3 = tuple(level3(v) for v in want)
            if kind == "spr":
                res["spr_px"] += 1
            if g3 != w3:
                drow[3 * x:3 * x + 3] = b"\xff\x00\xff"
                if kind == "spr":
                    res["spr_bad"] += 1
                elif kind == "bg":
                    res["bg_bad"] += 1
                elif kind == "gap":
                    res["gap_bad"] += 1
                else:
                    res["hud_bad"] += 1
        want_rows.append(bytes(wrow))
        diff_rows.append(bytes(drow))
    return res, want_rows, diff_rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", type=Path)
    ap.add_argument("--level", type=Path, default=ROOT / "build/msx/level1")
    ap.add_argument("--hud", type=Path, default=ROOT / "build/msx/hud")
    ap.add_argument("--png", type=Path)
    a = ap.parse_args()
    frames = sorted(p for p in a.capture.iterdir() if p.is_dir() and (p / "real.png").exists())
    bad_frames = 0
    for d in frames:
        res, want, diff = check(d, a.level, a.hud)
        flag = res["spr_bad"] or res["bg_bad"] or res["hud_bad"] or res["gap_bad"]
        bad_frames += bool(flag)
        objs = "; ".join(f"{'BOB' if o['bob'] else 'RC'} {o['id']} ({o['x']},{o['y']})" for o in res["objs"])
        print(f"{d.name}: cam {res['cam']} sprite px {res['spr_px'] - res['spr_bad']}/{res['spr_px']} ok, "
              f"background {res['bg_bad']} bad, gap {res['gap_bad']}, HUD {res['hud_bad']} | {objs}")
        if a.png and flag:
            a.png.mkdir(parents=True, exist_ok=True)
            rows = [w + b"\0\0\0" * 4 + df for w, df in zip(want, diff)]
            write_png(a.png / f"{d.name}.png", 516, 212, rows)
    print(f"{len(frames)} frames, {bad_frames} with differences")
    return 1 if bad_frames else 0


if __name__ == "__main__":
    raise SystemExit(main())
