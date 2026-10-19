#!/usr/bin/env python3
"""Access to ADF images (Amiga DD, 880 KiB) without an AmigaDOS file system.

The Robocop 2 disks use their own trackloader: there is no valid root block
in sector 880 (it holds audio samples). This module only knows the physical
geometry and the bootblock.
"""
from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass
from pathlib import Path

SECTOR = 512
SECTORS_PER_TRACK = 11
TRACK = SECTOR * SECTORS_PER_TRACK  # 5632 bytes
TRACKS = 160  # 80 cylinders x 2 sides
ADF_SIZE = TRACK * TRACKS  # 901120


def u16(b: bytes, o: int = 0) -> int:
    return struct.unpack_from(">H", b, o)[0]


def u32(b: bytes, o: int = 0) -> int:
    return struct.unpack_from(">I", b, o)[0]


def bootblock_checksum_ok(bb: bytes) -> bool:
    """Longword sum with end-around carry; valid when the total is 0xFFFFFFFF."""
    s = 0
    for i in range(0, 1024, 4):
        s += u32(bb, i)
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    return s == 0xFFFFFFFF


@dataclass(frozen=True)
class Location:
    track: int
    cylinder: int
    head: int
    sector: int  # sector within the track (0..10)
    byte: int  # byte within the sector


def locate(offset: int) -> Location:
    t, r = divmod(offset, TRACK)
    s, b = divmod(r, SECTOR)
    return Location(t, t // 2, t % 2, s, b)


class Adf:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        if len(self.data) != ADF_SIZE:
            raise ValueError(f"{self.path}: size {len(self.data)} != {ADF_SIZE} (DD ADF)")

    def read(self, offset: int, length: int) -> bytes:
        if offset < 0 or offset + length > len(self.data):
            raise ValueError(f"read outside the disk: {offset:#x}+{length:#x}")
        return self.data[offset:offset + length]

    def sector(self, n: int, count: int = 1) -> bytes:
        return self.read(n * SECTOR, count * SECTOR)

    def track(self, n: int) -> bytes:
        return self.read(n * TRACK, TRACK)

    @property
    def bootblock(self) -> bytes:
        return self.data[:1024]

    def sha1(self) -> str:
        return hashlib.sha1(self.data).hexdigest()
