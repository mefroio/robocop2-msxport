#!/usr/bin/env python3
"""Execution bench for the Robocop 2 68000 code on top of Unicorn (experimental, parked).

Code analysis goes through REA + Ghidra (project rule); this bench only emulates the
Amiga hardware needed for the game code to run and be inspected (it is not a full
Amiga emulator):

- 512 KiB of chip RAM at $000000 and 512 KiB of "slow RAM" at $C00000;
- custom registers at $DFF000 (beam counters, DMA/INT, colours, pointers) and CIAs at
  $BFD000/$BFE001 (fire button, minimal keyboard);
- area-mode blitter (channels A-D, shifts, masks, minterm, ascending and descending),
  run when BLTSIZE is written;
- game loader intercepted at $100 (A0 = name): loads the files from build/extracted
  to their name-table destination, as the trackloader would;
- VBL interrupt (level 3) injected every frame when enabled;
- write watchpoints and address breakpoints, for tracing.

Depends on Unicorn (pip install unicorn).

usage:
  amigaemu.py run --frames 600 [--fire 300:20] [--dump build/emu/ram.bin]
                  [--watch 0x3e810-0x40000] [--screenshot build/emu/frame.png]
"""
from __future__ import annotations

import argparse
import ctypes
import json
import struct
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amigahw import CUSTOM, rgb12_to_rgb24  # noqa: E402

try:
    from unicorn import (UC_ARCH_M68K, UC_HOOK_CODE, UC_HOOK_MEM_WRITE, UC_MODE_BIG_ENDIAN, UC_PROT_ALL, Uc,
                         UcError)
    from unicorn.m68k_const import (UC_CPU_M68K_M68000, UC_M68K_REG_A0, UC_M68K_REG_A7, UC_M68K_REG_D0,
                                    UC_M68K_REG_PC, UC_M68K_REG_SR)
except ImportError:  # pragma: no cover
    sys.exit("amigaemu.py needs Unicorn: pip install unicorn")

ROOT = Path(__file__).resolve().parents[1]
CHIP_SIZE = 0x80000
SLOW_BASE, SLOW_SIZE = 0xC00000, 0x80000
CUSTOM_BASE = 0xDFF000
CIA_BASE = 0xBFD000
LOADER_ENTRY = 0x100
LINES = 312  # PAL

REG = {name: off for off, name in CUSTOM.items()}


def a_reg(n: int) -> int:
    return UC_M68K_REG_A0 + n


def d_reg(n: int) -> int:
    return UC_M68K_REG_D0 + n


class Blitter:
    """OCS blitter in area mode (no line mode, no fill)."""

    def __init__(self, emu: "AmigaEmu"):
        self.emu = emu
        self.count = 0
        self.unsupported: dict[str, int] = defaultdict(int)

    def run(self, size: int) -> None:
        r = self.emu.regs
        con0, con1 = r[REG["BLTCON0"]], r[REG["BLTCON1"]]
        if con1 & 1:
            self.unsupported["line"] += 1
            return
        if con1 & 0x18:
            self.unsupported["fill"] += 1
        h = (size >> 6) & 0x3FF or 1024
        w = size & 0x3F or 64
        use_a, use_b, use_c, use_d = con0 & 0x800, con0 & 0x400, con0 & 0x200, con0 & 0x100
        lf = con0 & 0xFF
        ash, bsh = con0 >> 12, con1 >> 12
        desc = bool(con1 & 2)
        step = -2 if desc else 2

        def ptr(name):
            return ((r[REG[name + "PTH"]] << 16) | r[REG[name + "PTL"]]) & (CHIP_SIZE - 2)

        def smod(name):
            v = r[REG[name + "MOD"]] & 0xFFFE
            return v - 0x10000 if v & 0x8000 else v

        apt, bpt, cpt, dpt = ptr("BLTA"), ptr("BLTB"), ptr("BLTC"), ptr("BLTD")
        amod, bmod, cmod, dmod = smod("BLTA"), smod("BLTB"), smod("BLTC"), smod("BLTD")
        if desc:
            amod, bmod, cmod, dmod = -amod, -bmod, -cmod, -dmod
        afwm, alwm = r[REG["BLTAFWM"]], r[REG["BLTALWM"]]
        adat, bdat, cdat = r[REG["BLTADAT"]], r[REG["BLTBDAT"]], r[REG["BLTCDAT"]]
        mem = self.emu.chip
        aold = bold = 0
        zero = True
        for _y in range(h):
            for x in range(w):
                apt &= CHIP_SIZE - 2
                bpt &= CHIP_SIZE - 2
                cpt &= CHIP_SIZE - 2
                dpt &= CHIP_SIZE - 2
                a = (mem[apt] << 8 | mem[apt + 1]) if use_a else adat
                if use_a:
                    apt += step
                if x == 0:
                    a &= afwm
                if x == w - 1:
                    a &= alwm
                b = (mem[bpt] << 8 | mem[bpt + 1]) if use_b else bdat
                if use_b:
                    bpt += step
                c = (mem[cpt] << 8 | mem[cpt + 1]) if use_c else cdat
                if use_c:
                    cpt += step
                if desc:
                    asft = ((a << 16 | aold) << ash >> 16) & 0xFFFF
                    bsft = ((b << 16 | bold) << bsh >> 16) & 0xFFFF
                else:
                    asft = ((aold << 16 | a) >> ash) & 0xFFFF
                    bsft = ((bold << 16 | b) >> bsh) & 0xFFFF
                aold, bold = a, b
                d = 0
                for k in range(8):
                    if lf >> k & 1:
                        t = asft if k & 4 else ~asft
                        t &= bsft if k & 2 else ~bsft
                        t &= c if k & 1 else ~c
                        d |= t
                d &= 0xFFFF
                if d:
                    zero = False
                if use_d:
                    mem[dpt] = d >> 8
                    mem[dpt + 1] = d & 0xFF
                    self.emu.note_write(dpt, 2, "blitter")
                    dpt += step
            apt += amod if use_a else 0
            bpt += bmod if use_b else 0
            cpt += cmod if use_c else 0
            dpt += dmod if use_d else 0
        self.count += 1
        self.emu.bzero = zero
        # final pointers stay in the registers, as on the hardware
        for name, v in (("BLTA", apt), ("BLTB", bpt), ("BLTC", cpt), ("BLTD", dpt)):
            r[REG[name + "PTH"]], r[REG[name + "PTL"]] = (v >> 16) & 0xFFFF, v & 0xFFFF


class AmigaEmu:
    def __init__(self, extracted: Path, *, verbose: bool = False):
        self.extracted = extracted
        self.verbose = verbose
        self.manifest = json.loads((extracted / "manifest.json").read_text())
        self.uc = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
        self.uc.ctl_set_cpu_model(UC_CPU_M68K_M68000)
        # chip RAM mirrored up to $1FFFFF, as on an A500 with 512 KiB of chip RAM
        self._chipbuf = (ctypes.c_ubyte * CHIP_SIZE)()
        self.chip = memoryview(self._chipbuf).cast("B")
        for mirror in range(0, 0x200000, CHIP_SIZE):
            self.uc.mem_map_ptr(mirror, CHIP_SIZE, UC_PROT_ALL, ctypes.addressof(self._chipbuf))
        self.uc.mem_map(SLOW_BASE, SLOW_SIZE)
        self.uc.mmio_map(CUSTOM_BASE, 0x1000, self._custom_read, None, self._custom_write, None)
        self.uc.mmio_map(CIA_BASE, 0x2000, self._cia_read, None, self._cia_write, None)
        self.regs = [0] * 0x100  # custom register words, index = offset
        self.dmacon = 0
        self.intena = 0
        self.intreq = 0
        self.vpos = 0
        self.bzero = True
        self.frame = 0
        self.fire = False
        self.fire_script: list[tuple[int, int]] = []
        self.blitter = Blitter(self)
        self.watch: list[tuple[int, int]] = []
        self.write_log: list[tuple[int, int, int, str]] = []
        self.loads: list[tuple[int, str, int, int]] = []
        self.breakpoints: dict[int, str] = {}
        self.hits: list[tuple[int, int, str]] = []
        self._stop_reason: str | None = None
        self._pending_loader = False
        self.uc.hook_add(UC_HOOK_CODE, self._on_loader, None, LOADER_ENTRY, LOADER_ENTRY + 1)
        self.names = self._name_table()

    # ------------------------------------------------------------ memory
    def read_long(self, a: int) -> int:
        return struct.unpack(">I", self.uc.mem_read(a, 4))[0]

    def read_word(self, a: int) -> int:
        return struct.unpack(">H", self.uc.mem_read(a, 2))[0]

    def note_write(self, addr: int, size: int, who: str) -> None:
        for lo, hi in self.watch:
            if lo <= addr < hi:
                self.write_log.append((self.frame, addr, size, who))
                return

    # ------------------------------------------------------------ files
    def _name_table(self) -> list[dict]:
        files = self.manifest["files"]
        return files

    def load_file(self, name: str) -> tuple[int, int]:
        cands = [f for f in self.names if f["name"] == name]
        if not cands:
            raise KeyError(f"unknown file: {name!r}")
        f = cands[0]
        if name[2:3] == "Z" and self.read_word(0x8050) == 2 and len(cands) > 1:
            f = cands[1]
        data = (self.extracted / f["file"]).read_bytes()
        dest = f["load_address"]
        self.uc.mem_write(dest, data)
        self.loads.append((self.frame, name, dest, len(data)))
        if self.verbose:
            print(f"[frame {self.frame}] loaded {name} at ${dest:05x} (+{len(data)})")
        if self.watch:
            for lo, hi in self.watch:
                if dest < hi and dest + len(data) > lo:
                    self.write_log.append((self.frame, max(lo, dest), min(hi, dest + len(data)) - max(lo, dest),
                                           f"loader:{name}"))
        return dest, f["id"]

    def _on_loader(self, uc, address, size, user_data):
        self._pending_loader = True
        uc.emu_stop()

    def _service_loader(self) -> None:
        a0 = self.uc.reg_read(a_reg(0))
        raw = bytes(self.uc.mem_read(a0, 8))
        name = raw.split(b"\0", 1)[0].decode("ascii", "replace")
        dest, fid = self.load_file(name)
        sp = self.uc.reg_read(UC_M68K_REG_A7)
        ret = self.read_long(sp)
        self.uc.reg_write(UC_M68K_REG_A7, sp + 4)
        self.uc.reg_write(a_reg(0), dest)
        self.uc.reg_write(d_reg(0), fid & 0x7F)
        self.uc.reg_write(UC_M68K_REG_PC, ret)

    # ------------------------------------------------------------ custom chips
    def _custom_read(self, uc, offset, size, user_data):
        if size == 4:
            return (self._custom_read(uc, offset, 2, None) << 16) | self._custom_read(uc, offset + 2, 2, None)
        word_off = offset & ~1
        v = self._custom_word(word_off)
        if size == 1:
            return (v >> 8) & 0xFF if offset % 2 == 0 else v & 0xFF
        return v

    def _custom_word(self, off: int) -> int:
        if off == 0x002:  # DMACONR
            return (self.dmacon & 0x07FF) | (0x2000 if self.bzero else 0)
        if off == 0x004:  # VPOSR
            return (self.vpos >> 8) & 1
        if off == 0x006:  # VHPOSR: advances one line per read
            self.vpos = (self.vpos + 1) % LINES
            return (self.vpos & 0xFF) << 8
        if off == 0x01C:
            return self.intena
        if off == 0x01E:
            return self.intreq
        if off in (0x00A, 0x00C):  # JOYxDAT
            return 0
        if off == 0x016:  # POTGOR: secondary buttons released
            return 0xFF00
        return self.regs[off >> 0] if off < len(self.regs) else 0

    def _custom_write(self, uc, offset, size, value, user_data):
        if size == 4:
            self._custom_write(uc, offset, 2, (value >> 16) & 0xFFFF, None)
            self._custom_write(uc, offset + 2, 2, value & 0xFFFF, None)
            return
        if size == 1:
            return
        off = offset & 0x1FE
        if off == 0x096:
            self.dmacon = self._setclr(self.dmacon, value)
        elif off == 0x09A:
            self.intena = self._setclr(self.intena, value)
        elif off == 0x09C:
            self.intreq = self._setclr(self.intreq, value)
        else:
            if off < len(self.regs):
                self.regs[off] = value & 0xFFFF
            if off == 0x058:  # BLTSIZE
                self.blitter.run(value & 0xFFFF)

    @staticmethod
    def _setclr(reg: int, value: int) -> int:
        return reg | (value & 0x7FFF) if value & 0x8000 else reg & ~value & 0x7FFF

    # ------------------------------------------------------------ CIAs
    def _cia_read(self, uc, offset, size, user_data):
        addr = CIA_BASE + offset
        if addr == 0xBFE001:  # CIAA PRA: bit 7 = port 2 fire (active low)
            return 0x7F if self.fire else 0xFF
        if addr == 0xBFED01:  # CIAA ICR
            return 0
        return 0xFF

    def _cia_write(self, uc, offset, size, value, user_data):
        return

    # ------------------------------------------------------------ execution
    def boot(self) -> None:
        x = self.extracted / "boot"
        self.uc.mem_write(0x8000, (x / "main_8000.bin").read_bytes())
        self.uc.mem_write(0x100, (x / "loader_100.bin").read_bytes())
        self.uc.mem_write(0x300, (x / "loader_300.bin").read_bytes())
        self.uc.mem_write(0xC0, struct.pack(">I", 0x100))
        self.uc.reg_write(UC_M68K_REG_SR, 0x2700)
        self.uc.reg_write(UC_M68K_REG_A7, 0x7FFF0)
        self.uc.reg_write(UC_M68K_REG_PC, 0x8000)

    def inject_vbl(self) -> bool:
        sr = self.uc.reg_read(UC_M68K_REG_SR)
        if not (self.intena & 0x4000 and self.intena & 0x0020):
            return False
        if (sr >> 8) & 7 >= 3:
            return False
        self.intreq |= 0x0020
        pc = self.uc.reg_read(UC_M68K_REG_PC)
        sp = self.uc.reg_read(UC_M68K_REG_A7) - 6
        self.uc.mem_write(sp, struct.pack(">HI", sr & 0xFFFF, pc))
        self.uc.reg_write(UC_M68K_REG_A7, sp)
        self.uc.reg_write(UC_M68K_REG_SR, (sr & 0xF8FF) | 0x2000 | 0x0300)
        self.uc.reg_write(UC_M68K_REG_PC, self.read_long(0x6C))
        return True

    def run_frames(self, frames: int, insns_per_frame: int = 40000) -> None:
        for _ in range(frames):
            self.fire = any(s <= self.frame < s + n for s, n in self.fire_script)
            budget = insns_per_frame
            while budget > 0:
                pc = self.uc.reg_read(UC_M68K_REG_PC)
                chunk = min(budget, 5000)
                try:
                    self.uc.emu_start(pc, 0xFFFFFFFE, 0, chunk)
                except UcError as e:
                    raise RuntimeError(f"CPU fault in frame {self.frame}: {e}\n{self.regs_text()}") from e
                if self._pending_loader:
                    self._pending_loader = False
                    self._service_loader()
                    budget -= 100
                    continue
                budget -= chunk
            self.vpos = 0
            self.inject_vbl()
            self.frame += 1

    # ------------------------------------------------------------ inspection
    def regs_text(self) -> str:
        r = self.uc.reg_read
        d = " ".join(f"D{i}={r(d_reg(i)):08x}" for i in range(8))
        a = " ".join(f"A{i}={r(a_reg(i)):08x}" for i in range(8))
        return f"PC={r(UC_M68K_REG_PC):06x} SR={r(UC_M68K_REG_SR):04x}\n{d}\n{a}"

    def dump(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(bytes(self.uc.mem_read(0, CHIP_SIZE)))

    def screenshot(self, path: Path, base: int | None = None, lines: int = 192) -> None:
        """Renders the interleaved playfield (4 planes x 38 bytes) with the palette of copper list $1049E."""
        from planar import decode_indices, render, write_png
        ram = bytes(self.uc.mem_read(0, CHIP_SIZE))
        if base is None:
            base = self.read_long(0xB16) ^ 0x18E00  # front buffer
        pal = [(0, 0, 0)] + [rgb12_to_rgb24(struct.unpack_from(">H", ram, 0x104A4 + 4 * i)[0]) for i in range(15)]
        idx = decode_indices(ram, base, 304, lines, 4, "interleaved", row_bytes=38)
        write_png(path, 304 * 2, lines * 2, render(idx, pal, False, 2))


def parse_range(s: str) -> tuple[int, int]:
    lo, hi = s.split("-")
    return int(lo, 0), int(hi, 0)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("run",))
    ap.add_argument("--extracted", type=Path, default=ROOT / "build" / "extracted")
    ap.add_argument("--frames", type=int, default=300)
    ap.add_argument("--insns", type=int, default=40000, help="instructions per frame")
    ap.add_argument("--fire", action="append", default=[], help="FRAME:DURATION with fire pressed")
    ap.add_argument("--watch", action="append", default=[], help="write range to log, e.g. 0x3e810-0x40000")
    ap.add_argument("--dump", type=Path)
    ap.add_argument("--screenshot", type=Path)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    emu = AmigaEmu(a.extracted, verbose=a.verbose)
    emu.fire_script = [tuple(int(x) for x in f.split(":")) for f in a.fire]
    emu.watch = [parse_range(w) for w in a.watch]
    if emu.watch:
        def on_write(uc, access, address, size, value, user_data):
            pc = uc.reg_read(UC_M68K_REG_PC)
            emu.write_log.append((emu.frame, address, size, f"cpu@{pc:06x}"))
        for lo, hi in emu.watch:
            emu.uc.hook_add(UC_HOOK_MEM_WRITE, on_write, None, lo, hi - 1)
    emu.boot()
    try:
        emu.run_frames(a.frames, a.insns)
    finally:
        pc = emu.uc.reg_read(UC_M68K_REG_PC)
        print(f"frames={emu.frame} PC=${pc:06x} blits={emu.blitter.count} "
              f"unsupported={dict(emu.blitter.unsupported)} level={emu.read_word(0x8050)}")
        for fr, name, dest, ln in emu.loads:
            print(f"  load f{fr}: {name} -> ${dest:05x} (+{ln})")
        if emu.write_log:
            by_who = defaultdict(lambda: [0, None, None])
            for fr, addr, size, who in emu.write_log:
                e = by_who[who]
                e[0] += 1
                e[1] = addr if e[1] is None else min(e[1], addr)
                e[2] = addr if e[2] is None else max(e[2], addr)
            print("  writes in the watched ranges (source: n, range):")
            for who, (n, lo, hi) in sorted(by_who.items(), key=lambda kv: -kv[1][0])[:30]:
                print(f"    {who:24} {n:7d}  ${lo:06x}-${hi:06x}")
        if a.dump:
            emu.dump(a.dump)
        if a.screenshot:
            emu.screenshot(a.screenshot)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
