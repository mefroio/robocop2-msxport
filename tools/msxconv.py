#!/usr/bin/env python3
"""Converts Robocop 2 (Amiga) graphics to MSX2 (SCREEN 5).

level: 16x16 tiles (4 planes interleaved per line, 128 bytes) + map (160 columns of
words: tile offset & ~$7F, attributes in the low 7 bits) -> SCREEN 5 format:

  <out>.pal   16 colours in V9938 palette format (2 bytes: R<<4|B, G; 3 bits each)
  <out>.til   N x 128 bytes, 2 pixels per byte (high nibble = left pixel)
  <out>.map   rows x 160 little-endian words = tile index into the .til
  <out>.atr   rows x 160 bytes = original attributes (low 7 bits of the word)
  <out>.otile 512 little-endian words: tile of each DATAL tile offset >> 7 (the game writes map
              words at run time: map objects, msx/tiles.asm map_write)
  <out>.atr2  attributes of the 2 rows of words after the map (graphics data the spawn-marker
              scan can read)
  <out>.atrp  the map's attributes packed: 4-bit codes, 80 bytes per row (even column in the
              high nibble), then the 16 attribute values of the codes
  <out>.vram  128 KiB: the tile sheet in pages 2-3 (tile i: page 2+i//256, x=(i%16)*16,
              y=((i//16)%16)*16), pages 0-1 empty
  <out>.png   map preview already in the 9-bit palette

Every one of the 512 DATAL tiles is kept (deduplicated by content after the remap), numbered by
use in the map, most used first: the first 432 fit the VRAM tile slots and are uploaded at the
start of the level, the others are loaded on demand by the tile cache (msx/tiles.asm).

usage: msxconv.py level DATAL.bin --pal-file main_8000.bin --pal-addr 0xfff6 --rows 51 -o build/msx/level1
"""
from __future__ import annotations

import argparse
import struct
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from planar import write_png  # noqa: E402

MAP_OFFSET = 0x10000
COLS = 160


def amiga_to_msx(c12: int) -> tuple[int, int, int]:
    """$0RGB (4 bits) -> (r, g, b) with 3 bits, rounded."""
    return tuple(round(((c12 >> s) & 15) * 7 / 15) for s in (8, 4, 0))  # type: ignore[return-value]


def msx_rgb24(rgb3: tuple[int, int, int]) -> tuple[int, int, int]:
    return tuple(v * 255 // 7 for v in rgb3)  # type: ignore[return-value]


def tile_indices(d: bytes, off: int) -> list[list[int]]:
    """Amiga tile (16 lines x 4 planes x 2 bytes) -> 16x16 matrix of indices."""
    rows = []
    for y in range(16):
        row = []
        for x in range(16):
            v = 0
            for p in range(4):
                if d[off + (y * 4 + p) * 2 + (x >> 3)] & (0x80 >> (x & 7)):
                    v |= 1 << p
            row.append(v)
        rows.append(row)
    return rows


def pack_sc5(px: list[list[int]]) -> bytes:
    out = bytearray()
    for row in px:
        for x in range(0, 16, 2):
            out.append((row[x] << 4) | row[x + 1])
    return bytes(out)


def cmd_level(a) -> int:
    d = Path(a.datal).read_bytes()
    pdata = Path(a.pal_file).read_bytes()
    amiga_pal = [0] + [struct.unpack_from(">H", pdata, a.pal_addr - a.pal_load + 2 * i)[0] for i in range(15)]
    msx_pal = [amiga_to_msx(c) for c in amiga_pal]
    remap = list(range(16))
    if a.joint:
        # joint background + sprite palette and the background remap (tools/msxsprites.py)
        jp = Path(a.joint).with_suffix(".pal").read_bytes()
        msx_pal = [(jp[2 * i] >> 4, jp[2 * i + 1] & 7, jp[2 * i] & 7) for i in range(16)]
        remap = list(Path(a.joint).with_suffix(".remap").read_bytes())
    out = Path(a.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.with_suffix(".pal").write_bytes(bytes(b for r, g, bl in msx_pal for b in ((r << 4) | bl, g)))

    words = [[struct.unpack_from(">H", d, MAP_OFFSET + (r * COLS + c) * 2)[0] for c in range(COLS)]
             for r in range(a.rows)]
    uses = Counter(w & ~0x7F for row in words for w in row)
    # every DATAL tile, deduplicated by content (two offsets may hold the same graphic), most
    # used in the map first
    by_content: dict[bytes, list[int]] = {}
    for o in range(0, MAP_OFFSET, 0x80):
        packed = pack_sc5([[remap[v] for v in row] for row in tile_indices(d, o)])
        by_content.setdefault(packed, []).append(o)
    order = sorted(by_content.items(), key=lambda kv: (-sum(uses[o] for o in kv[1]), kv[1][0]))
    tiles = [packed for packed, _ in order]
    index_of_offset = {o: i for i, (_, offs) in enumerate(order) for o in offs}
    in_map = sum(1 for _, offs in order if any(uses[o] for o in offs))
    out.with_suffix(".til").write_bytes(b"".join(tiles))
    out.with_suffix(".map").write_bytes(b"".join(struct.pack("<H", index_of_offset[w & ~0x7F])
                                                 for row in words for w in row))
    out.with_suffix(".atr").write_bytes(bytes(w & 0x7F for row in words for w in row))
    # the same packed for page-0 RAM (msx/tiles.asm atr_rc): 4-bit codes, two cells per byte
    # (even column in the high nibble), and the 16-entry table of the attribute values
    vals = sorted({w & 0x7F for row in words for w in row})
    if len(vals) > 16:
        raise SystemExit(f"{len(vals)} distinct map attributes: more than the 16 of the packed map")
    code = {v: i for i, v in enumerate(vals)}
    packed = bytearray()
    for row in words:
        for c in range(0, COLS, 2):
            packed.append(code[row[c] & 0x7F] << 4 | code[row[c + 1] & 0x7F])
    out.with_suffix(".atrp").write_bytes(bytes(packed) + bytes(vals) + bytes(16 - len(vals)))
    # the attribute bits of the two rows after the map (the level's graphics follow it in
    # memory: the spawn-marker scan of update_objects reaches row 51 with the camera at its
    # lowest, and the bits it finds there move its table on)
    after = MAP_OFFSET + a.rows * COLS * 2
    out.with_suffix(".atr2").write_bytes(bytes(struct.unpack_from(">H", d, after + 2 * i)[0] & 0x7F
                                               for i in range(2 * COLS)))
    out.with_suffix(".otile").write_bytes(b"".join(struct.pack("<H", index_of_offset[o])
                                                   for o in range(0, MAP_OFFSET, 0x80)))

    vram = bytearray(0x20000)
    for i, t in enumerate(tiles[:512]):
        page, rest = 2 + i // 256, i % 256
        x0, y0 = (rest % 16) * 16, (rest // 16) * 16
        for y in range(16):
            base = page * 0x8000 + (y0 + y) * 128 + x0 // 2
            vram[base:base + 8] = t[y * 8:(y + 1) * 8]
    out.with_suffix(".vram").write_bytes(bytes(vram))

    # preview with the 9-bit palette
    rgb = [msx_rgb24(c) for c in msx_pal]
    W, H = COLS * 16, a.rows * 16
    img = [bytearray(W * 3) for _ in range(H)]
    for r in range(a.rows):
        for c in range(COLS):
            t = tiles[index_of_offset[words[r][c] & ~0x7F]]
            for y in range(16):
                line = img[r * 16 + y]
                for x in range(16):
                    v = (t[y * 8 + x // 2] >> (4 if x % 2 == 0 else 0)) & 15
                    line[(c * 16 + x) * 3:(c * 16 + x) * 3 + 3] = bytes(rgb[v])
    write_png(out.with_suffix(".png"), W, H, [bytes(l) for l in img])
    print(f"{out}: {a.rows}x{COLS} map, {len(uses)} offsets used ({in_map} tiles), {len(tiles)} tiles in all "
          f"({len(tiles) * 128} bytes, {max(0, in_map - 432)} of the map's beyond the 432 VRAM slots); MSX palette: "
          + " ".join(f"{r}{g}{b}" for r, g, b in msx_pal))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    lv = sub.add_parser("level")
    lv.add_argument("datal")
    lv.add_argument("--pal-file", required=True)
    lv.add_argument("--pal-load", type=lambda s: int(s, 0), default=0x8000)
    lv.add_argument("--pal-addr", type=lambda s: int(s, 0), required=True)
    lv.add_argument("--rows", type=int, required=True)
    lv.add_argument("--joint", help="prefix of the .pal/.remap written by tools/msxsprites.py")
    lv.add_argument("-o", "--output", required=True)
    a = ap.parse_args()
    return cmd_level(a)


if __name__ == "__main__":
    raise SystemExit(main())
