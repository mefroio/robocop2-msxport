#!/usr/bin/env python3
"""Robocop 2 (Amiga, Ocean/Special FX, Melnok crack): loader tables and extraction.

Boot chain (disk 1), derived from the bootblock:
    $00400 +$A600 -> $48000 -> copied to $8000   main code (JMP $8000)
    $CE600 +$0200 -> $60000 -> copied to $100    lookup by name + name table
    $CE800 +$0800 -> $70000 -> copied to $300    trackloader + directory
    $D4800 +$5200 -> $71000                      run with JSR before the game
    ($C0).l = $100                               loader pointer used by the game

Name table (in the $100 block): 12-byte entries
    name[6] (ASCII, space padded) | id.w | destination.l
    id bit 7 = PP20 file (the loader loads at destination-8 and decrunches in place)
    id & $7F = directory index

Directory (in the $300 block): 6-byte entries indexed by the id
    word = (disk-1) << 12 | first sector (512 bytes) ; length.l in bytes

usage:
    rc2files.py info   DISK1.adf DISK2.adf
    rc2files.py list   DISK1.adf DISK2.adf
    rc2files.py extract DISK1.adf DISK2.adf OUT/
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from adf import SECTOR, Adf, bootblock_checksum_ok, locate, u16, u32  # noqa: E402
import pp20  # noqa: E402

IO_LENGTH, IO_DATA, IO_OFFSET = 0x24, 0x28, 0x2C


@dataclass
class BootLoad:
    disk_offset: int
    length: int
    staging: int
    final: int
    name: str = ""


@dataclass
class Entry:
    name: str
    file_id: int
    dest: int
    disk: int = 0
    sector: int = 0
    length: int = 0
    raw: bytes = b""
    data: bytes = b""
    notes: list[str] = field(default_factory=list)

    @property
    def packed(self) -> bool:
        return bool(self.file_id & 0x80)

    @property
    def index(self) -> int:
        return self.file_id & 0x7F

    @property
    def offset(self) -> int:
        return self.sector * SECTOR


def parse_boot_loads(bb: bytes) -> list[BootLoad]:
    """Extracts the DoIO loads (io_Data/io_Offset/io_Length) and the memory copies."""
    loads: list[BootLoad] = []
    cur: dict[int, int] = {}
    i = 12
    while i + 8 <= len(bb):
        if bb[i:i + 2] == b"\x23\x7c" and u16(bb, i + 6) in (IO_LENGTH, IO_DATA, IO_OFFSET):
            cur[u16(bb, i + 6)] = u32(bb, i + 2)
            if len(cur) == 3:
                loads.append(BootLoad(cur[IO_OFFSET], cur[IO_LENGTH], cur[IO_DATA], cur[IO_DATA]))
                cur = {}
            i += 8
        else:
            i += 2
    # copies: lea SRC.l,a0 / lea DST.l,a1 / move.l #LEN,d0
    i = 12
    while i + 18 <= len(bb):
        if bb[i:i + 2] == b"\x41\xf9" and bb[i + 6:i + 8] == b"\x43\xf9" and bb[i + 12:i + 14] == b"\x20\x3c":
            src, dst, ln = u32(bb, i + 2), u32(bb, i + 8), u32(bb, i + 14)
            for ld in loads:
                if ld.staging == src and ld.length == ln:
                    ld.final = dst
            i += 18
        else:
            i += 2
    names = {0x8000: "main_8000", 0x100: "loader_100", 0x300: "loader_300"}
    for ld in loads:
        ld.name = names.get(ld.final, f"boot_{ld.final:x}")
    return loads


def pc_lea_target(blob: bytes, base: int, pattern_after: bytes = b"") -> int:
    """Address of a LEA d16(PC),A1 (43FA xxxx), optionally followed by `pattern_after`."""
    for i in range(0, len(blob) - 4, 2):
        if blob[i:i + 2] == b"\x43\xfa" and blob[i + 4:i + 4 + len(pattern_after)] == pattern_after:
            disp = struct.unpack_from(">h", blob, i + 2)[0]
            return base + i + 2 + disp
    raise ValueError("LEA d16(PC),A1 not found")


def is_filler_sector(sec: bytes) -> bool:
    """Unused sectors were filled with 'DOS' + counter."""
    return all(sec[i:i + 3] == b"DOS" for i in range(0, SECTOR, 4))


def entropy(b: bytes) -> float:
    if not b:
        return 0.0
    n = len(b)
    return -sum(v / n * math.log2(v / n) for v in Counter(b).values())


def classify(data: bytes) -> str:
    tags = []
    if data[:4] == b"FORM":
        tags.append(f"IFF {data[8:12].decode('latin-1')}")
    n8 = data.count(b"8SVX")
    if n8:
        tags.append(f"{n8}x 8SVX")
    if data.count(b"PP20"):
        tags.append(f"{data.count(b'PP20')}x embedded PP20")
    code = sum(data.count(op) for op in (b"\x4e\x75", b"\x4e\xb9", b"\x61\x00", b"\x4e\xf9", b"\x4a\x79"))
    if len(data) and code / (len(data) / 1024) > 6:
        tags.append(f"likely code ({code} typical opcodes)")
    tags.append(f"H={entropy(data):.2f}")
    return ", ".join(tags)


class Robocop2:
    def __init__(self, disk1: str, disk2: str):
        self.disks = {1: Adf(disk1), 2: Adf(disk2)}
        d1 = self.disks[1]
        self.boot_ok = bootblock_checksum_ok(d1.bootblock)
        self.boot_loads = parse_boot_loads(d1.bootblock)
        by_final = {ld.final: ld for ld in self.boot_loads}
        self.blob100 = d1.read(by_final[0x100].disk_offset, by_final[0x100].length)
        self.blob300 = d1.read(by_final[0x300].disk_offset, by_final[0x300].length)
        self.name_table_addr = pc_lea_target(self.blob100, 0x100)
        # LEA dir(PC),A1 followed by MULU #6,D0
        self.directory_addr = pc_lea_target(self.blob300, 0x300, b"\xc0\xfc\x00\x06")
        self.entries = self._parse_tables()

    def _parse_tables(self) -> list[Entry]:
        out = []
        o = self.name_table_addr - 0x100
        while self.blob100[o] != 0:
            nm = self.blob100[o:o + 6].decode("ascii").rstrip()
            fid, dest = u16(self.blob100, o + 6), u32(self.blob100, o + 8)
            out.append(Entry(nm, fid, dest))
            o += 12
        dbase = self.directory_addr - 0x300
        for e in out:
            w, ln = struct.unpack_from(">HI", self.blob300, dbase + e.index * 6)
            e.disk, e.sector, e.length = (w >> 12) + 1, w & 0x0FFF, ln
            e.raw = self.disks[e.disk].read(e.offset, ln)
            if e.packed:
                if e.raw[:4] != pp20.MAGIC:
                    e.notes.append("PP flag but no PP20 signature")
                    e.data = e.raw
                else:
                    try:
                        e.data = pp20.decrunch(e.raw, exact=True)
                    except pp20.PP20Error as err:
                        e.notes.append(f"inexact PP20: {err}")
                        e.data = pp20.decrunch(e.raw, exact=False)
            else:
                e.data = e.raw
        return out

    def extents(self) -> dict[int, list[tuple[int, int, str]]]:
        ext: dict[int, list[tuple[int, int, str]]] = {1: [(0, 1024, "bootblock")], 2: [(0, 1024, "bootblock")]}
        for ld in self.boot_loads:
            ext[1].append((ld.disk_offset, ld.disk_offset + ld.length, ld.name))
        for e in self.entries:
            ext[e.disk].append((e.offset, e.offset + e.length, e.name))
        for d in ext:
            ext[d].sort()
        return ext

    def unlisted_pp20(self) -> list[tuple[int, int, int | None]]:
        """(disk, start, end) of PP20 blocks at a sector start outside every known extent."""
        found = []
        ext = self.extents()
        for d, adf in self.disks.items():
            starts = sorted(s for s, _, _ in ext[d])
            pos = 0
            while True:
                i = adf.data.find(pp20.MAGIC, pos)
                if i < 0:
                    break
                pos = i + 1
                if i % SECTOR or any(s <= i < e for s, e, _ in ext[d]):
                    continue
                limit = min([s for s in starts if s > i] + [len(adf.data)])
                found.append((d, i, pp20.find_end(adf.data, i, limit)))
        return found

    def coverage(self) -> dict[int, list[tuple[int, int, str]]]:
        """Regions of each disk by kind: known / filler / unknown (in sectors)."""
        ext = self.extents()
        res = {}
        for d, adf in self.disks.items():
            kinds = []
            for s in range(len(adf.data) // SECTOR):
                a, b = s * SECTOR, (s + 1) * SECTOR
                names = [n for (x, y, n) in ext[d] if x < b and y > a]
                if names:
                    kinds.append("+".join(dict.fromkeys(names)))
                elif is_filler_sector(adf.sector(s)):
                    kinds.append("(filler)")
                else:
                    kinds.append("?? unknown")
            runs = []
            start = 0
            for s in range(1, len(kinds) + 1):
                if s == len(kinds) or kinds[s] != kinds[start]:
                    runs.append((start, s, kinds[start]))
                    start = s
            res[d] = runs
        return res


def cmd_info(rc: Robocop2) -> None:
    for d, adf in rc.disks.items():
        print(f"disk {d}: {adf.path.name}  sha1={adf.sha1()}")
    print(f"bootblock checksum (disk 1): {'ok' if rc.boot_ok else 'INVALID'}")
    print("bootblock loads:")
    for ld in rc.boot_loads:
        loc = locate(ld.disk_offset)
        print(f"  {ld.name:12} disk ${ld.disk_offset:06x} (track {loc.track} sector {loc.sector}) "
              f"+${ld.length:05x} -> ${ld.staging:05x} -> final ${ld.final:05x}")
    print(f"name table at ${rc.name_table_addr:x}; directory at ${rc.directory_addr:x}")


def cmd_list(rc: Robocop2) -> None:
    print(f"{'name':6} {'id':>5} {'PP':2} {'idx':>3} {'dest':>8} {'d':>1} {'sect':>5} {'offset':>8} "
          f"{'size':>7} {'final':>7}  classification")
    for e in rc.entries:
        print(f"{e.name:6} {e.file_id:#05x} {'PP' if e.packed else '--'} {e.index:3d} ${e.dest:06x} "
              f"{e.disk} {e.sector:5d} ${e.offset:06x} {e.length:7d} {len(e.data):7d}  {classify(e.data)}"
              + (f"  [{'; '.join(e.notes)}]" if e.notes else ""))
    print("\nPP20 blocks outside the directory:")
    for d, s, end in rc.unlisted_pp20():
        if end is None:
            print(f"  disk {d} ${s:06x}: end not found")
        else:
            out = pp20.decrunch(rc.disks[d].data[s:end])
            print(f"  disk {d} ${s:06x}-${end:06x} ({end - s} -> {len(out)} bytes)  {classify(out)}")
    print("\ncoverage (sectors):")
    for d, runs in rc.coverage().items():
        print(f"  disk {d}:")
        for a, b, k in runs:
            print(f"    {a:5d}-{b - 1:5d} ({b - a:4d} sectors, ${a * SECTOR:06x}-${b * SECTOR - 1:06x})  {k}")


def sha1(b: bytes) -> str:
    return hashlib.sha1(b).hexdigest()


def cmd_extract(rc: Robocop2, out: Path) -> None:
    for sub in ("boot", "raw", "files", "unlisted"):
        (out / sub).mkdir(parents=True, exist_ok=True)
    manifest: dict = {"disks": {}, "boot": [], "files": [], "unlisted": []}
    for d, adf in rc.disks.items():
        manifest["disks"][d] = {"name": adf.path.name, "sha1": adf.sha1()}
    (out / "boot" / "bootblock.bin").write_bytes(rc.disks[1].bootblock)
    for ld in rc.boot_loads:
        blob = rc.disks[1].read(ld.disk_offset, ld.length)
        fn = f"{ld.name}.bin"
        (out / "boot" / fn).write_bytes(blob)
        manifest["boot"].append({"file": f"boot/{fn}", "disk_offset": ld.disk_offset, "length": ld.length,
                                 "staging": ld.staging, "load_address": ld.final, "sha1": sha1(blob)})
    for e in rc.entries:
        tag = f"{e.name}_{e.index:02d}"
        (out / "raw" / f"{tag}.raw").write_bytes(e.raw)
        (out / "files" / f"{tag}.bin").write_bytes(e.data)
        manifest["files"].append({
            "name": e.name, "id": e.file_id, "index": e.index, "pp20": e.packed, "load_address": e.dest,
            "disk": e.disk, "sector": e.sector, "disk_offset": e.offset, "packed_length": e.length,
            "length": len(e.data), "sha1": sha1(e.data), "file": f"files/{tag}.bin", "notes": e.notes,
            "classification": classify(e.data)})
    for d, s, end in rc.unlisted_pp20():
        if end is None:
            continue
        out_data = pp20.decrunch(rc.disks[d].data[s:end])
        fn = f"d{d}_{s:06x}.bin"
        (out / "unlisted" / fn).write_bytes(out_data)
        manifest["unlisted"].append({"disk": d, "disk_offset": s, "packed_length": end - s,
                                     "length": len(out_data), "sha1": sha1(out_data), "file": f"unlisted/{fn}",
                                     "classification": classify(out_data)})
    manifest["coverage"] = {d: [{"first_sector": a, "last_sector": b - 1, "kind": k} for a, b, k in runs]
                            for d, runs in rc.coverage().items()}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False))
    print(f"extracted to {out}: {len(rc.entries)} files, {len(manifest['unlisted'])} blocks outside the directory")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("info", "list", "extract"))
    ap.add_argument("disk1")
    ap.add_argument("disk2")
    ap.add_argument("out", nargs="?")
    a = ap.parse_args()
    rc = Robocop2(a.disk1, a.disk2)
    if a.cmd == "info":
        cmd_info(rc)
    elif a.cmd == "list":
        cmd_info(rc)
        print()
        cmd_list(rc)
    else:
        if not a.out:
            ap.error("extract needs OUT")
        cmd_extract(rc, Path(a.out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
