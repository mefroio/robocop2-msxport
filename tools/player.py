#!/usr/bin/env python3
"""RoboCop (player) graphics from the animation table at $B4E2 (main code) and PERMA.

draw_player ($B94A, via REA/Ghidra) composes the player every frame into a 64 x 73 buffer
of 4 planes at $7E3A0 (planes every $248 bytes) and shows it with the 8 hardware sprites:
  1. base part: plain copy (A->D) of the frame record's graphic: legs and torso;
  2. head: 16 x 14 masked part (cookie-cut, minterm $CA), 9 variants at $61BD0 + head_g[d];
  3. arm with gun: 32 x 32 masked part, 26 variants at $62030 + arm_g[d'];
  4. muzzle flash: 16 x 16 masked part, 4 frames at $65230 + flash_g[n], while ($16A0) > 0.
d = (state & 1) * 4 + aim, aim = (($15DA) & 6) >> 1; d' = d unless ($1676) != 0 (special
poses). A negative head/arm y in the record means the part is not drawn.

Tables (main code): state s = 8 bytes at $B4E2+8s [steps-1][list offset][lines][0];
frame record = 16 bytes [PERMA offset][BLTSIZE][dest modulo][-][arm x.b][arm y.b][head x.b]
[head y.b][base x bytes.b][base y.b][hotspot x.b][hotspot y.b]; head g/x/y words at
$B408/$B41A/$B42C (9 each); arm g/x/y words at $B43E/$B472/$B4A6 (26 each); flash g at
$B4DA (4). Screen position: x = 5 + ($15D0) - camera_x + hotspot_x + 8,
y = ($15D4) - camera_y + hotspot_y + 8 - 16.

Logic tables (player_move $AFF8, update_player $ACEC, draw_player $B94A, level_init $871A):
x step per state ($B3F6, signed bytes); state parameters ($B3AE, 4 bytes: -, $15DF, $15E4,
hitbox offset from $B32C); hitboxes ($B32C, 3 x [x, y, w, h] words); aim per joystick
direction bits ($ACDC); x offset per facing of the state 6/7 effect ($AFAE); the camera
targets' offsets (immediates at $B2D8 and $B2FC, patched by level_init) and the camera's
rightmost x (immediate at $B2F0); the state the palette fade-in forces (level_init's immediate
for $F89D); per level the start
position and the camera's lowest y (header at $8664: x @16, y @18, $B08 @28).

usage: player.py OUTDIR   -> robocop.png (base parts), robocop_parts.png (heads, arms,
                             flashes), robocop_composed.png (every record x 4 aims)
       player.py --inc OUT.inc [--level N]
                          -> the logic tables for the MSX (msx/player.asm), level N (0-2)
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amigahw import rgb12_to_rgb24  # noqa: E402
from planar import write_png  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TABLE, NSTATES, PERMA_LOAD = 0xB4E2, 17, 0x58850
HEAD_G, HEAD_X, HEAD_Y, HEADS = 0xB408, 0xB41A, 0xB42C, 9
ARM_G, ARM_X, ARM_Y, ARMS = 0xB43E, 0xB472, 0xB4A6, 26
FLASH_G, FLASHES = 0xB4DA, 4
HEAD_BASE, ARM_BASE, FLASH_BASE = 0x61BD0, 0x62030, 0x65230
BUF_W, BUF_H = 64, 73
LEVEL_HEADERS, LEVEL_HEADER_SIZE = 0x8664, 40
XSTEP, STATE_PARAMS, NPARAMS, HITBOXES = 0xB3F6, 0xB3AE, 18, 0xB32C
AIM_TABLE, PUNCH_DX = 0xACDC, 0xAFAE
CAM_DX, CAM_DY, CAM_XMAX = 0xB2D8, 0xB2FC, 0xB2F0
FADE_STATE = {0: 0x88A7, 1: 0x88A7, 2: 0x88CF}   # level_init's immediates for $F89D (the state the
                                                 # palette fade-in $F878 forces)
ARM_POSES = range(8, 26)            # $1676 during the start of a level (player_move $B344)
ARM_STATE, ARM_AIM = 2, 2           # ... shown on state 2's first record, aim 2 (horizontal)


class Game:
    def __init__(self, main: bytes, perma: bytes):
        self.main, self.perma = main, perma

    def uw(self, a: int) -> int:
        return struct.unpack_from(">H", self.main, a - 0x8000)[0]

    def sw(self, a: int) -> int:
        return struct.unpack_from(">h", self.main, a - 0x8000)[0]

    def sb(self, a: int) -> int:
        return struct.unpack_from(">b", self.main, a - 0x8000)[0]

    def records(self) -> list[dict]:
        out = []
        for s in range(NSTATES):
            e = TABLE + 8 * s
            steps, lst = self.uw(e) + 1, TABLE + self.uw(e + 2)
            for i in range(0, steps, 2):
                r = lst + 8 * i
                bltsize = self.uw(r + 2)
                out.append({"state": s, "index": i // 2, "lines": self.uw(e + 4),
                            "perma_offset": self.uw(r), "w": (bltsize & 63) * 16, "h": bltsize >> 6,
                            "arm_x": self.sb(r + 8), "arm_y": self.sb(r + 9),
                            "head_x": self.main[r + 10 - 0x8000], "head_y": self.sb(r + 11),
                            "x": 8 * self.sb(r + 12), "y": self.main[r + 13 - 0x8000],
                            "hot_x": self.sb(r + 14), "hot_y": self.sb(r + 15)})
        return out

    def base(self, rec: dict) -> list[list[int]]:
        wb, h, o = rec["w"] // 8, rec["h"], rec["perma_offset"]
        return [[sum(1 << p for p in range(4) if self.perma[o + p * wb * h + y * wb + (x >> 3)] & (0x80 >> (x & 7)))
                 for x in range(rec["w"])] for y in range(h)]

    def masked(self, addr: int, w: int, h: int) -> list[list[int | None]]:
        """[mask][p0][p1][p2][p3], each (w/8) x h bytes; None where the mask is clear."""
        wb, o = w // 8, addr - PERMA_LOAD
        ps = wb * h
        img = []
        for y in range(h):
            row = []
            for x in range(w):
                byte, bit = y * wb + (x >> 3), 0x80 >> (x & 7)
                if not self.perma[o + byte] & bit:
                    row.append(None)
                else:
                    row.append(sum(1 << p for p in range(4) if self.perma[o + ps * (p + 1) + byte] & bit))
            img.append(row)
        return img

    def head(self, d: int) -> list[list[int | None]]:
        return self.masked(HEAD_BASE + self.sw(HEAD_G + 2 * d), 16, 14)

    def arm(self, d: int) -> list[list[int | None]]:
        return self.masked(ARM_BASE + self.sw(ARM_G + 2 * d), 32, 32)

    def flash(self, n: int) -> list[list[int | None]]:
        return self.masked(FLASH_BASE + self.sw(FLASH_G + 2 * n), 16, 16)

    def compose(self, rec: dict, aim: int, arm_override: int = 0) -> list[list[int]]:
        """The 64 x 73 buffer as draw_player leaves it (0 = transparent)."""
        buf = [[0] * BUF_W for _ in range(BUF_H)]

        def put(img, ox, oy, masked):
            for y, row in enumerate(img):
                for x, v in enumerate(row):
                    if (masked and v is None) or not (0 <= oy + y < BUF_H and 0 <= ox + x < BUF_W):
                        continue
                    buf[oy + y][ox + x] = v

        put(self.base(rec), rec["x"], rec["y"], False)
        d = (rec["state"] & 1) * 4 + aim
        if rec["head_y"] >= 0:
            put(self.head(d), rec["head_x"] + self.sw(HEAD_X + 2 * d), rec["head_y"] + self.sw(HEAD_Y + 2 * d), True)
        if rec["arm_y"] >= 0:
            a = arm_override or d
            put(self.arm(a), rec["arm_x"] + self.sw(ARM_X + 2 * a), rec["arm_y"] + self.sw(ARM_Y + 2 * a), True)
        return buf


def frames(main: bytes) -> list[dict]:
    """Frame records only (used by the mockups)."""
    return Game(main, b"").records()


def arm_record(recs: list[dict]) -> int:
    """Flat index of the record the start-of-level arm poses are shown on."""
    return next(i for i, r in enumerate(recs) if r["state"] == ARM_STATE)


def logic_inc(main: bytes, level: int = 0) -> str:
    """z80asm source: equates and tables of RoboCop's logic (msx/player.asm)."""
    g = Game(main, b"")
    recs = g.records()
    hdr = LEVEL_HEADERS + LEVEL_HEADER_SIZE * level

    def rows(label: str, values: list[int], directive: str = "db", per: int = 16) -> str:
        fmt = "0x{:02X}" if directive == "db" else "0x{:04X}"
        mask = 0xFF if directive == "db" else 0xFFFF
        out = [f"{label}:"]
        for i in range(0, len(values), per):
            out.append(f"        {directive} " + ", ".join(fmt.format(v & mask) for v in values[i:i + per]))
        return "\n".join(out) + "\n"

    first, count = [], []
    for s in range(NSTATES):
        idx = [i for i, r in enumerate(recs) if r["state"] == s]
        first.append(idx[0])
        count.append(len(idx))
    params = []
    for s in range(NPARAMS):
        params += list(main[STATE_PARAMS + 4 * s + 1 - 0x8000:STATE_PARAMS + 4 * s + 4 - 0x8000])
    hot = []
    for r in recs:
        hot += [r["hot_x"] + 8, r["hot_y"] + 8]
    return ("; generated by tools/player.py --inc: RoboCop's logic tables from the main code\n"
            f"LVL_X: equ {g.sw(hdr + 16)}                 ; start position ($15D0, $15D4) and camera\n"
            f"LVL_Y: equ {g.sw(hdr + 18)}\n"
            f"LVL_YMAX: equ {g.sw(hdr + 28)}               ; the camera's lowest y ($B08)\n"
            f"CAM_DX: equ {g.sw(CAM_DX)}                 ; camera target x = player x - CAM_DX\n"
            f"CAM_DY: equ {-g.sw(CAM_DY)}                 ; camera target y = player y - CAM_DY\n"
            f"CAM_XMAX: equ {g.sw(CAM_XMAX)}               ; the camera's rightmost x\n"
            f"FADE_STATE: equ {main[FADE_STATE[level] - 0x8000]}              ; state forced while the palette fades in ($F89D)\n"
            f"PL_ARM_REC: equ {arm_record(recs)}             ; record and aim of the start-of-level arm poses\n"
            f"PL_ARM_AIM: equ {ARM_AIM}\n"
            f"PL_ARM_FIRST: equ {ARM_POSES[0]}\n"
            + rows("pl_xstep", [g.sb(XSTEP + s) for s in range(NSTATES)])
            + rows("pl_stparm", params, per=12)
            + rows("pl_hitbox", [g.sw(HITBOXES + 2 * i) for i in range(12)], "dw", 4)
            + rows("pl_aimtab", list(main[AIM_TABLE - 0x8000:AIM_TABLE + 16 - 0x8000]))
            + rows("pl_punchdx", [g.sw(PUNCH_DX), g.sw(PUNCH_DX + 2)], "dw")
            + rows("pl_steps", [g.uw(TABLE + 8 * s) for s in range(NSTATES)], "dw", 9)
            + rows("pl_rec0", first)
            + rows("pl_nrec", count)
            + rows("pl_hot", hot))


def palette(main: bytes) -> list[tuple[int, int, int]]:
    pal12 = [struct.unpack_from(">H", main, 0xFFF6 - 0x8000 + 2 * i)[0] for i in range(31)]
    return [(255, 0, 255)] + [rgb12_to_rgb24(c) for c in pal12[16:31]]  # COLOR17..31


def sheet(images: list[list[list[int | None]]], pal, path: Path, cols: int, scale: int = 2) -> None:
    cw = max(len(i[0]) for i in images) + 4
    ch = max(len(i) for i in images) + 4
    rows = (len(images) + cols - 1) // cols
    W, H = cols * cw, rows * ch
    canvas = [[(60, 60, 60)] * W for _ in range(H)]
    for n, img in enumerate(images):
        ox, oy = (n % cols) * cw + 2, (n // cols) * ch + 2
        for y, row in enumerate(img):
            for x, v in enumerate(row):
                canvas[oy + y][ox + x] = pal[0] if v is None else pal[v]
    write_png(path, W * scale, H * scale, [b"".join(bytes(c) * scale for c in r) for r in canvas for _ in range(scale)])


def main() -> int:
    mainb = (ROOT / "build/extracted/boot/main_8000.bin").read_bytes()
    if len(sys.argv) > 2 and sys.argv[1] == "--inc":
        level = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[3] == "--level" else 0
        Path(sys.argv[2]).write_text(logic_inc(mainb, level))
        print(f"{sys.argv[2]}: logic tables of level {level + 1}")
        return 0
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/sprites")
    g = Game(mainb, (ROOT / "build/extracted/files/PERMA_05.bin").read_bytes())
    pal = palette(mainb)
    recs = g.records()
    seen, uniq = set(), []
    for r in recs:
        k = (r["perma_offset"], r["w"], r["h"])
        if k not in seen:
            seen.add(k)
            uniq.append(r)
    sheet([g.base(r) for r in uniq], pal, out / "robocop.png", 12)
    sheet([g.head(d) for d in range(HEADS)] + [g.arm(d) for d in range(ARMS)] + [g.flash(n) for n in range(FLASHES)],
          pal, out / "robocop_parts.png", 13)
    sheet([g.compose(r, aim) for r in recs for aim in range(4)], pal, out / "robocop_composed.png", 16)
    print(f"{out}: {len(recs)} frame records ({len(uniq)} distinct base graphics), sizes",
          sorted({(r['w'], r['h']) for r in uniq}), f"; {HEADS} heads, {ARMS} arms, {FLASHES} flashes;",
          f"{4 * len(recs)} compositions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
