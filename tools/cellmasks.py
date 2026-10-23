#!/usr/bin/env python3
"""Camera-cell masks of a level's spawn list and hazards, for the port's game logic shortcuts.

Every game tick the original walks the whole spawn list of the level for each free enemy slot
(update_objects $C44C: 28 entries in level 1, each tested against a window around the camera and
reset when outside it) and tests every hazard record against another window ($9150: 15 electric
beams in level 1), though only one or two of them are ever near the camera. The port visits only
the entries that can be inside the window for the camera's position (msx/objects.asm uo_free with
msx/level1.asm sw_prep; msx/special.asm hz_update): this tool works out, per 64-pixel cell of
camera x and per cell of camera y, the mask of the entries whose window test passes for some
camera coordinate in the cell. The tests are the ported routines' own, evaluated for each of the
cell's 64 coordinates, so a mask is a superset of the entries inside the window for any camera in
its cell: an entry in neither mask is outside the window for sure, and the code ANDs the x and the
y mask of the camera's cells. The windows, the camera at (cx, cy), with 16-bit arithmetic:

    spawn list: x - (cx + 5Eh) in [0, 152h) and cy - 28h < y <= cy + A8h
    hazards:    window x >= cx + 73h, x < cx + 1A0h and y - (cy - 64h) in [0, 110h)

Output: build/msx/gen/cells_<level>.inc for each level bank (l1, l2, l3) whose spawn list
(spawn_<level>) and hazard list (hz_<level>) analysis/amiga_tables.tsv lists, read from the
level's RAM image (tools/ramimage.py) as tools/amitab.py reads them; msx/rc2.asm includes it in
the level's bank: SW_N (the entries: up to 32, a mask is a long), SW_XN / SW_YN (the cells over
the map), sw_xm and sw_ym (a long per cell), sw_all (every entry), sw_ptr (the entries' addresses
in spawn_ram); the hazards' HZ_XN / HZ_YN, hz_xm and hz_ym (a word per cell: up to 16 records),
hz_all.

usage: cellmasks.py build/ram/level1_full.bin analysis/amiga_tables.tsv build/msx/gen MAP_COLS MAP_ROWS
       (the map's size in 16-pixel cells, as tools/mkrom.py knows it: the camera never leaves it)
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amitab import parse  # noqa: E402

CELL = 6                            # a cell is 2^6 = 64 pixels of camera x or y
LEVELS = ("l1", "l2", "l3")
SPAWN_REC = 14                      # a spawn list entry: x, y, type.b, ?, ?, flags.b, reload, counter, spawned.b, ?
HZ_REC = 8                          # a hazard record: x, y, window x, rows - 1 (words)
SW_MAX, HZ_MAX = 32, 16             # the masks: a long per cell, a word per cell


def s16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def spawn_entries(img: bytes, addr: int) -> list[tuple[int, int]]:
    """(x, y) of the spawn list's entries at addr, up to the end word (a negative x)."""
    out = []
    while struct.unpack_from(">h", img, addr)[0] >= 0:
        out.append(struct.unpack_from(">hh", img, addr))
        addr += SPAWN_REC
    return out


def hazard_records(img: bytes, addr: int) -> list[tuple[int, int, int, int]]:
    """(x, y, window x, rows - 1) of the hazard list's records at addr, up to the end word."""
    out = []
    while struct.unpack_from(">h", img, addr)[0] >= 0:
        out.append(struct.unpack_from(">hhhh", img, addr))
        addr += HZ_REC
    return out


def spawn_x(entry: tuple[int, int], cx: int) -> bool:
    """update_objects $C44C: x - D0 - 1 below 152h, D0 = camera x + 5Dh (objects.asm uf_at)."""
    return (entry[0] - (cx + 0x5E)) & 0xFFFF < 0x152


def spawn_y(entry: tuple[int, int], cy: int) -> bool:
    """D1 = camera y - 28h below y, D3 = camera y + A8h not below it (objects.asm uf_xin)."""
    return s16(cy - 0x28 - entry[1]) < 0 and s16(cy + 0xA8 - entry[1]) >= 0


def hazard_x(rec: tuple[int, int, int, int], cx: int) -> bool:
    """$9150: the window's x not below camera x + 73h and x below camera x + 1A0h (special.asm hz_x)."""
    return s16(rec[2] - (cx + 0x73)) >= 0 and s16(rec[0] - (cx + 0x1A0)) < 0


def hazard_y(rec: tuple[int, int, int, int], cy: int) -> bool:
    """y - (camera y - 64h) below 110h, unsigned (special.asm hz_lp)."""
    return (rec[1] - (cy - 0x64)) & 0xFFFF < 0x110


def cell_masks(items: list, cells: int, test) -> list[int]:
    """Per cell the mask (bit k: item k) of the items whose test passes for some camera
    coordinate in the cell."""
    masks = []
    for c in range(cells):
        m = 0
        for k, item in enumerate(items):
            if any(test(item, cam) for cam in range((c << CELL), ((c + 1) << CELL))):
                m |= 1 << k
        masks.append(m)
    return masks


def db(mask: int, size: int) -> str:
    return ",".join(f"0x{(mask >> (8 * b)) & 0xFF:02X}" for b in range(size))


def inc_text(level: str, entries: list, records: list, xn: int, yn: int, source: str) -> str:
    """The level's cells_<level>.inc."""
    def table(label: str, masks: list[int], size: int, axis: str, what: str) -> list[str]:
        out = [f"{label}:{' ' * (36 - len(label) - 1)}; per camera {axis} cell {what}"]
        out += [f"        db {db(m, size)}{' ' * (10 if size == 2 else 0)}      ; camera {axis} "
                f"{c << CELL}..{((c + 1) << CELL) - 1}" for c, m in enumerate(masks)]
        return out
    sw = [f"SW_N:       equ {len(entries)}                  ; the spawn list's entries (up to {SW_MAX})",
          f"SW_XN:      equ {xn}                  ; cells of 64 pixels over the map's width,",
          f"SW_YN:      equ {yn}                  ;   its height"]
    sw += table("sw_xm", cell_masks(entries, xn, spawn_x), 4, "x", "the entries the walk's window can reach")
    sw += table("sw_ym", cell_masks(entries, yn, spawn_y), 4, "y", "the same")
    sw.append(f"sw_all:  db {db((1 << len(entries)) - 1, 4)}      ; every entry (the camera outside the cells)")
    sw.append("sw_ptr:                             ; the entries' addresses (spawn_ram + 14 k)")
    sw += [f"        dw spawn_ram + {SPAWN_REC * k}" for k in range(len(entries))]
    hz = [f"HZ_XN:      equ {xn}                  ; the hazards' cells (the same cells)",
          f"HZ_YN:      equ {yn}"]
    hz += table("hz_xm", cell_masks(records, xn, hazard_x), 2, "x", "the records whose window test can pass")
    hz += table("hz_ym", cell_masks(records, yn, hazard_y), 2, "y", "the same")
    hz.append(f"hz_all:  db {db((1 << len(records)) - 1, 2)}            ; every record")
    return (f"; generated by tools/cellmasks.py from {source}: level {level[1:]}'s spawn list ({len(entries)} "
            f"entries) and hazards ({len(records)} records) per 64-pixel cell of the camera\n" + "\n".join(sw + hz) + "\n")


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    img = Path(argv[1]).read_bytes()
    rows = {r["label"]: r for r in parse(Path(argv[2]))}
    out = Path(argv[3])
    out.mkdir(parents=True, exist_ok=True)
    cols, maprows = int(argv[4], 0), int(argv[5], 0)
    xn, yn = -(-cols * 16 >> CELL), -(-maprows * 16 >> CELL)
    done = []
    for lv in LEVELS:
        sp, hz = rows.get(f"spawn_{lv}"), rows.get(f"hz_{lv}")
        if sp is None or hz is None:
            continue
        entries, records = spawn_entries(img, sp["addr"]), hazard_records(img, hz["addr"])
        if not 1 <= len(entries) <= SW_MAX or len(records) > HZ_MAX:
            print(f"error: {lv}: {len(entries)} spawn entries, {len(records)} hazards: the masks hold "
                  f"{SW_MAX} and {HZ_MAX} (and the walk at least one entry: objects.asm uf_last)", file=sys.stderr)
            return 1
        (out / f"cells_{lv}.inc").write_text(inc_text(lv, entries, records, xn, yn, Path(argv[1]).name))
        done.append(f"{lv}: {len(entries)} entries, {len(records)} hazards")
    print(f"{out}: {xn} x {yn} cells; " + "; ".join(done))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
