#!/usr/bin/env python3
"""Model of the Robocop 2 (Amiga) music and sound-effect player (the "MU1" player family).

The five music files (TITM, MU1, CH1, CMP, HI1) are loaded at $18000 and carry the same
player code; only the absolute addresses of their tables and the tune count differ. The
routines were read in REA/Ghidra on the level-1 RAM image (MU1); the addresses quoted below
are MU1's (the code is the same in every file, see docs/AMIGA_ANALYSIS.md, "Music and sound
effects"):

  $18000 init ($18180: instruments from the 8SVX list, then stop)   $18004 stop all ($18194)
  $18008/$1800C stop the channels of tune D0 ($181E8)
  $18010 start tune D0 as music ($1824E)   $18014 start tune D0 as a sound effect ($1822C)
  $18018 play one tick ($18316: channel processor $1839A x 4, Paula output $187E4)

This tool locates the tables from the player code of each file (instruction signatures),
checks that the rest of the code is MU1's, and re-implements the routines on an image of the
file (byte-exact: the channel structures live in the image at $18024 + $56 * channel). Every
tune is started the way the game does it (init, stop, start) and played one tick per call of
the play routine until all its channels have stopped or the whole player state repeats
(an exact loop). The output is what the routine writes to Paula each tick: period, volume,
sample pointer/length, and the key-ons (DMA restarts).

Writes build/music/<NAME>.json per file and prints a summary.

usage:
  rc2music.py [FILE ...] [--out build/music] [--ram build/ram/level1_full.bin]
              [--max-ticks 400000] [--trace NAME:TUNE [--ticks N]] [--entry music|sfx]
  rc2music.py --verify [FILE ...]

  FILE defaults to the five music files in build/extracted/files. --ram uses a RAM image as
  the memory around the file (reads outside the file are reported either way). --trace
  prints a per-tick listing of one tune instead of writing JSON (period, volume, * = key-on,
  instrument per channel). --verify runs the original 68000 player in Unicorn and compares
  every tick's Paula writes and the player's RAM with the model (the only part that needs a
  non-stdlib module; everything else is stdlib only).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ["TITM_04.bin", "MU1_09.bin", "CH1_07.bin", "CMP_24.bin", "HI1_26.bin"]
LOAD = 0x18000
CHIP = 0x80000                      # 512 KiB of chip RAM
STRUCT_SIZE = 0x56
PAL_CLOCK = 3546895                 # Paula clock (Hz) = colour clock
NTSC_CLOCK = 3579545

# Header: seven BRA.W entries and their targets (MU1 = every file).
HEADER = [0x18180, 0x18194, 0x181E8, 0x181E8, 0x1824E, 0x1822C, 0x18316]
HEADER_NAMES = ["init", "stop_all", "stop_tune", "stop_tune", "start_music", "start_sfx", "play"]

# Fixed player variables (absolute operands in the code, identical in all files).
V_MASK_MUSIC = 0x1801C              # AUDxVOL mask for music channels (FFFFh)
V_MASK_SFX = 0x1801E                # AUDxVOL mask for sound-effect channels (FFFFh)
V_ACTIVE = 0x18020                  # OR of the channel flags (bits 15/14 kept)
V_MUSIC = 0x18022                   # last tune started as music
V_SFX = 0x18023                     # last tune started as a sound effect (priority)
V_KEYON = 0x1817C                   # DMA bits of the channels that start a note this tick
V_TICKS = 0x1817E                   # tick counter (cleared by start, never read)
V_VHDR = 0x18AE6                    # init: address of the last VHDR data seen
V_BODY = 0x18B0E                    # init: address of the last BODY data seen
CODE_END = 0x18B36                  # first byte after the code (period table)

# Channel structure (A4) offsets.
F_FLAGS, F_SEQLOOP, F_SEQ, F_PATLOOP, F_PAT = 0x00, 0x02, 0x06, 0x0A, 0x0E
F_REPEAT, F_TRANSPOSE, F_ENV, F_ENVPTR = 0x12, 0x13, 0x14, 0x18
F_ENVRATE, F_ENVCNT, F_ENVLEFT, F_ENVSTEP = 0x1C, 0x1D, 0x1E, 0x20
F_GRACE_IV, F_GRACE_LEN, F_GRACE_CNT = 0x21, 0x22, 0x23
F_SLIDE_IV, F_SLIDE_CNT, F_SLIDE_STEP = 0x24, 0x25, 0x26
F_ARP, F_ARPPTR, F_ARPLEN, F_ARPCNT, F_ARPSPEED, F_ARPTICK = 0x28, 0x2C, 0x30, 0x31, 0x32, 0x33
F_VIB_IV, F_VIB_SPEED, F_VIB_DELAY, F_VIB_DCNT, F_VIB_SWING, F_VIB_SCNT, F_VIB_STEP = (
    0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A)
F_BASE, F_START, F_LEN, F_LOOP, F_LOOPLEN = 0x3C, 0x3E, 0x42, 0x44, 0x48
F_PERIOD, F_VOLUME, F_NOTE0, F_NOTE, F_FIXDUR, F_WAIT, F_DMA = 0x4A, 0x4C, 0x4F, 0x50, 0x51, 0x52, 0x54

# Flag bits (D7 / channel word +0).
B_GRACE, B_ARP, B_VIB, B_SLIDE, B_ENV, B_FIXDUR, B_NOTRANSP, B_REST = (
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80)
B_SFX, B_MUSIC = 0x4000, 0x8000

# Pattern command dispatch: jump table at $183D8 (lea 14h(pc) at $183C2), word offsets
# relative to each entry; handler addresses as in MU1.
HANDLERS = {
    0x18418: "end", 0x18494: "loop", 0x1849C: "nop", 0x184A0: "nop", 0x184A4: "fixdur",
    0x184B0: "freedur", 0x184B8: "wait256", 0x184C2: "rest", 0x184D2: "slide", 0x184E2: "grace",
    0x184F6: "grace_off", 0x1852E: "vibrato", 0x18546: "vibrato_off", 0x184FE: "arpeggio",
    0x18526: "arpeggio_off", 0x1854E: "envelope", 0x18566: "instrument",
}
JUMP_TABLE = 0x183D8
COMMANDS = {  # command byte -> (name, operand bytes)
    0x80: ("end of pattern", 0), 0x81: ("pattern loop point", 0), 0x82: ("no-op", 0),
    0x83: ("no-op", 0), 0x84: ("fixed duration", 1), 0x85: ("durations per note", 0),
    0x86: ("next duration + 256", 0), 0x87: ("rest", "dur"), 0x88: ("slide into note", 2),
    0x89: ("grace note", 2), 0x8A: ("grace off", 0), 0x8B: ("vibrato", 3),
    0x8C: ("vibrato off", 0), 0x8D: ("arpeggio table", 1), 0x8E: ("arpeggio off", 0),
    0x8F: ("envelope", 1), 0x90: ("instrument", 1),
}

# Where the game plays each file (from the call sites read in REA; see the ledger).
CONTEXT = {
    "TITM": ("title music: loaded by $11A20 ($11B4C); tune 1 started by $10884 (from $80A2)",
             "VBL hook $1031E, 5 of 6 VBLs"),
    "MU1": ("in-game sound effects: loaded by the level start ($8614, then jmp $18000); tunes "
            "requested through $B2C-$B31 by frame_keys $F76C (sound-effect entry)",
            "VBL hook $1031E, 5 of 6 VBLs"),
    "CH1": ("jingle started by $11F60, a handler of the key-sequence matcher $11EDA",
            "VBL hook $1031E, 5 of 6 VBLs"),
    "CMP": ("game completed: $11C54 (from $86DE) plays tune 1 for 1800h loop passes or until fire",
            "own loop at raster line C0h, 4 of 5 passes"),
    "HI1": ("high-score entry: $12300 starts tune 1; $1215C/$1225C start tunes 4/3 as sound "
            "effects", "VBL hook $1031E, 5 of 6 VBLs"),
}


class ModelError(Exception):
    pass


def s8(v: int) -> int:
    v &= 0xFF
    return v - 0x100 if v & 0x80 else v


def s16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def divs_w(dividend: int, divisor16: int) -> tuple[int, bool]:
    """68000 DIVS.W: 32-bit signed / 16-bit signed -> (new D0, overflow). Quotient in the low word."""
    d = s16(divisor16)
    if d == 0:
        raise ModelError("DIVS.W by zero (zero-divide trap on the real machine)")
    n = dividend & 0xFFFFFFFF
    n = n - (1 << 32) if n & 0x80000000 else n
    q = abs(n) // abs(d)
    q = q if (n >= 0) == (d > 0) else -q
    if not -0x8000 <= q <= 0x7FFF:
        return dividend & 0xFFFFFFFF, True
    r = n - q * d
    return ((r & 0xFFFF) << 16) | (q & 0xFFFF), False


class Mem:
    """Big-endian memory image; reads outside the loaded file are recorded."""

    def __init__(self, data: bytes, base: bytes | None = None):
        self.b = bytearray(base[:CHIP]) if base else bytearray(CHIP)
        if len(self.b) < CHIP:
            self.b.extend(bytes(CHIP - len(self.b)))
        self.b[LOAD:LOAD + len(data)] = data
        self.lo, self.hi = LOAD, LOAD + len(data)
        self.outside: set[int] = set()

    def _chk(self, a: int, n: int) -> int:
        a &= 0xFFFFFF
        if a < self.lo or a + n > self.hi:
            self.outside.add(a)
        if a + n > CHIP:
            raise ModelError("access beyond chip RAM at $%06X" % a)
        return a

    def rb(self, a: int) -> int:
        return self.b[self._chk(a, 1)]

    def rw(self, a: int) -> int:
        a = self._chk(a, 2)
        if a & 1:
            raise ModelError("word read at odd address $%06X (address error)" % a)
        return (self.b[a] << 8) | self.b[a + 1]

    def rl(self, a: int) -> int:
        return (self.rw(a) << 16) | self.rw(a + 2)

    def wb(self, a: int, v: int) -> None:
        self.b[a & 0xFFFFFF] = v & 0xFF

    def ww(self, a: int, v: int) -> None:
        a &= 0xFFFFFF
        if a & 1:
            raise ModelError("word write at odd address $%06X (address error)" % a)
        self.b[a] = (v >> 8) & 0xFF
        self.b[a + 1] = v & 0xFF

    def wl(self, a: int, v: int) -> None:
        self.ww(a, v >> 16)
        self.ww(a + 2, v)


# ---------------------------------------------------------------------------------------------
# Locating the tables from the player code
# ---------------------------------------------------------------------------------------------

def _find(code: bytes, pattern: str) -> list[int]:
    """Offsets of a hex pattern with ?? wildcards in code."""
    toks = pattern.split()
    pat = [None if t == "??" else int(t, 16) for t in toks]
    hits = []
    for i in range(len(code) - len(pat) + 1):
        for j, p in enumerate(pat):
            if p is not None and code[i + j] != p:
                break
        else:
            hits.append(i)
    return hits


def _hexwords(s: str) -> str:
    """'41F9 ???????? 7000' -> byte tokens."""
    out = []
    for w in s.split():
        if set(w) == {"?"}:
            out += ["??"] * (len(w) // 2)
        else:
            out += [w[i:i + 2] for i in range(0, len(w), 2)]
    return " ".join(out)


# (name, pattern, operand offset in bytes from the match, operand size, expected matches)
SIGNATURES = [
    ("sample_list", "41F9 ???????? 43F9 ???????? 6100", 2, 4, 1),
    ("first_record", "41F9 ???????? 43F9 ???????? 6100", 8, 4, 1),
    ("tune_count", "5340 6B?? B07C ???? 65??", 6, 2, 2),
    ("tunes", "41F9 ???????? E740 D0C0", 2, 4, 1),
    ("tunes_stop", "45F9 ???????? E740 D4C0", 2, 4, 1),
    ("patterns", "47F9 ???????? 4880 D040 D6C0 D6D3", 2, 4, 1),
    ("patterns_start", "45F9 ???????? 4880 D040 D4C0 D4D2", 2, 4, 1),
    ("arpeggios", "41F9 ???????? 7000 101B D040 D0C0 D0D0 1958 0032", 2, 4, 1),
    ("envelopes", "41F9 ???????? 7000 101B D040 D0C0 D0D0 2948 0014", 2, 4, 1),
    ("instruments", "41F9 ???????? 7000 101B E940 D0C0", 2, 4, 1),
    ("periods", "4DF9 00DFF000 4BF9 ????????", 8, 4, 1),
    ("silent", "41F9 ???????? 7202", 2, 4, 1),
    ("structs", "49F9 ???????? 3E14", 2, 4, 4),
    ("dispatch", "41FA 0014 0400 0080 4880 D040 D0C0 3010 67?? 4EF0 0000", 0, 0, 1),
]
# SHA-1 of MU1's player code ($18000-$18B35) with the table operands (sample list, first
# record, tune count, tunes, patterns, arpeggios, envelopes, silent buffer) zeroed.
CODE_SHA1 = "9d0ab6e2c68733dbc891cdd9b0801e4642446ef7"
MASKED = {"sample_list", "first_record", "tune_count", "tunes", "tunes_stop", "patterns",
          "patterns_start", "arpeggios", "envelopes", "silent"}


def locate(data: bytes) -> dict:
    """Find the player's tables in a music file (loaded at $18000)."""
    code = data[:CODE_END - LOAD]
    lay: dict = {"warnings": []}
    for i, (name, tgt) in enumerate(zip(HEADER_NAMES, HEADER)):
        op, disp = struct.unpack(">Hh", data[4 * i:4 * i + 4])
        if op != 0x6000 or LOAD + 4 * i + 2 + disp != tgt:
            raise ModelError("header entry %d is not BRA.W $%05X" % (i, tgt))
    masked = bytearray(code)
    for name, pat, off, size, count in SIGNATURES:
        hits = _find(code, _hexwords(pat))
        if len(hits) != count:
            raise ModelError("signature %s: %d matches (expected %d)" % (name, len(hits), count))
        vals = []
        for h in hits:
            if size == 4:
                vals.append(struct.unpack(">I", code[h + off:h + off + 4])[0])
            elif size == 2:
                vals.append(struct.unpack(">H", code[h + off:h + off + 2])[0])
            else:
                vals.append(LOAD + h + 2 + 0x14)          # lea 14h(pc): table address
            if name in MASKED:
                masked[h + off:h + off + size] = bytes(size)
        lay[name] = vals if count > 1 else vals[0]
    if len(set(lay["tune_count"])) != 1:
        raise ModelError("the two tune-count checks differ")
    lay["tune_count"] = lay["tune_count"][0]
    if lay["tunes"] != lay["tunes_stop"] or lay["patterns"] != lay["patterns_start"]:
        raise ModelError("tune or pattern table references disagree")
    if lay["dispatch"] != JUMP_TABLE:
        raise ModelError("command jump table not at $%05X" % JUMP_TABLE)
    lay["code_sha1"] = hashlib.sha1(bytes(masked)).hexdigest()
    lay["same_code_as_mu1"] = lay["code_sha1"] == CODE_SHA1
    if not lay["same_code_as_mu1"]:
        lay["warnings"].append("player code differs from MU1's: the model may not apply")
    return lay


# ---------------------------------------------------------------------------------------------
# IFF 8SVX (for the report; the player's own parsing is emulated in Player.init)
# ---------------------------------------------------------------------------------------------

def scan_8svx(mem: Mem, form: int) -> dict | None:
    b = mem.b
    if bytes(b[form:form + 4]) != b"FORM" or bytes(b[form + 8:form + 12]) != b"8SVX":
        return None
    size = struct.unpack(">I", b[form + 4:form + 8])[0]
    info: dict = {"form": form, "form_size": size}
    a, end = form + 12, form + 8 + size
    while a + 8 <= end:
        cid = bytes(b[a:a + 4])
        n = struct.unpack(">I", b[a + 4:a + 8])[0]
        d = a + 8
        if cid == b"VHDR":
            os_, rp, spc, sps, octv, comp, vol = struct.unpack(">IIIHBBI", b[d:d + 20])
            info.update(one_shot=os_, repeat=rp, samples_per_cycle=spc, rate=sps, octaves=octv,
                        compression=comp, vhdr_volume=vol / 65536)
        elif cid == b"BODY":
            info.update(body=d, body_size=n)
        elif cid in (b"NAME", b"ANNO", b"AUTH", b"(c) "):
            info[cid.decode().strip().lower()] = bytes(b[d:d + n]).split(b"\0")[0].decode("latin-1")
        a = d + n + (n & 1)
    return info


def sample_stats(raw: bytes, rate: int) -> dict:
    """Peak/RMS/zero crossings and a rough autocorrelation pitch estimate (an inference)."""
    if not raw:
        return {}
    v = [x - 256 if x > 127 else x for x in raw]
    peak = max(abs(x) for x in v)
    rms = math.sqrt(sum(x * x for x in v) / len(v))
    zc = sum(1 for i in range(1, len(v)) if (v[i - 1] < 0) != (v[i] < 0))
    out = {"peak": peak, "rms": round(rms, 1),
           "zero_crossings_per_s": round(zc * rate / len(v)) if rate else None}
    if rate and len(v) >= 512:
        # normalised autocorrelation of a window after the attack; the peak is searched after
        # the first zero crossing of the autocorrelation (so a smooth wave does not pick lag 1)
        start = len(v) // 10
        w = v[start:start + 2048]
        hi = min(len(w) // 2, rate // 40)
        e0 = sum(x * x for x in w) or 1
        acf = [1.0]
        for lag in range(1, hi):
            n = len(w) - lag
            acf.append(sum(w[i] * w[i + lag] for i in range(n)) * len(w) / (n * e0))
        z = next((i for i, c in enumerate(acf) if c < 0), None)
        if z is not None and z + 1 < len(acf):
            lag = max(range(z, len(acf)), key=acf.__getitem__)
            out["pitch_hz_estimate"] = round(rate / lag, 1)
            out["pitch_clarity"] = round(acf[lag], 2)
    return out


# ---------------------------------------------------------------------------------------------
# The player
# ---------------------------------------------------------------------------------------------

class Player:
    def __init__(self, data: bytes, lay: dict, base: bytes | None = None):
        self.m = Mem(data, base)
        self.L = lay
        self.structs = lay["structs"]
        self.inst = [None] * 4           # instrument number last set by command 90h (model only)
        self.playing = [None] * 4        # instrument of the last key-on (model only)
        self._writes: dict | None = None  # Paula writes of the current play call
        self.tick_events: list = []
        self.cmds_seen: dict[int, int] = {}
        self.warn: list[str] = []
        self.inst_records: list[dict] = []

    # -- $18180 init: instrument records from the 8SVX list, then stop all ($18194) ----------
    def init(self) -> None:
        m = self.m
        a0, a1 = self.L["sample_list"], self.L["first_record"]
        k = 1
        while True:                                       # $1896E
            d0 = m.rl(a0)
            if d0 == 0:
                break
            rec = a1
            m.ww(a1, m.rw(a0 + 4))                        # +0 base note
            m.ww(a1 + 0xE, m.rw(a0 + 6))                  # +14 no-transpose flag
            form = (a0 + d0) & 0xFFFFFF                   # lea -8(a0,d0.l) after two reads
            size = (m.rl(form + 4) + 8) & 0xFFFFFFFF
            stale = not self._iff(form, size)             # $189D2
            a1 += 2                                       # $1898E
            vh = m.rl(V_VHDR)
            os_, rp = m.rl(vh) & ~1, m.rl(vh + 4) & ~1
            body = m.rl(V_BODY)
            m.wl(a1, body)
            lp = (body + os_) & 0xFFFFFFFF
            m.ww(a1 + 4, ((os_ + rp) & 0xFFFFFFFF) >> 1)
            if rp == 0:
                lp, rp = self.L["silent"], 2
            m.wl(a1 + 6, lp)
            m.ww(a1 + 10, rp >> 1)
            a1 += 14
            self.inst_records.append({"index": k, "record": rec, "entry": a0, "form": form,
                                      "form_ok": not stale})
            a0 += 8
            k += 1
        self.stop_all()

    def _iff(self, a0: int, d0: int) -> bool:
        """$189D2/$189E0/$189F4: top-level IFF walk; True when an 8SVX FORM was parsed."""
        m = self.m
        ok = False
        guard = 0
        while d0 & 0xFFFFFFFF:
            guard += 1
            if guard > 10000:
                raise ModelError("IFF walk does not terminate")
            d1 = m.rl(a0)
            a0, d0 = a0 + 4, d0 - 4
            if d1 == 0x464F524D:                          # 'FORM'
                a0, d0, ok = self._form(a0, d0)
            elif d1 == 0x43415420:                        # 'CAT ' ($18A14, not modelled)
                raise ModelError("IFF CAT chunk: not modelled")
            else:                                         # error 1, stop
                d0 = 0
        return ok

    def _skip(self, a0: int, d0: int) -> tuple[int, int, int]:
        n = self.m.rl(a0)
        step = n + (n & 1) + 4
        return n, a0 + step, d0 - step

    def _form(self, a0: int, d0: int) -> tuple[int, int, bool]:
        """$18A52: FORM; sub-chunks through $18A9A when the type is 8SVX."""
        m = self.m
        n, ra0, rd0 = self._skip(a0, d0)
        a = a0 + 4
        typ = m.rl(a)
        a += 4
        d = n - 4
        if typ != 0x38535658:                             # '8SVX' (error 2)
            return ra0, rd0, False
        guard = 0
        while d & 0xFFFFFFFF:                             # $18A86
            guard += 1
            if guard > 10000:
                raise ModelError("8SVX walk does not terminate")
            cid = m.rl(a)
            a, d = a + 4, d - 4
            if cid == 0x464F524D:
                a, d, _ = self._form(a, d)
            elif cid == 0x43415420:
                raise ModelError("IFF CAT chunk: not modelled")
            else:
                if cid == 0x56484452:                     # 'VHDR' -> $18AE6
                    m.wl(V_VHDR, a + 4)
                elif cid == 0x424F4459:                   # 'BODY' -> $18B0E
                    m.wl(V_BODY, a + 4)
                _, a, d = self._skip(a, d)                # LIST and the others are skipped
        return ra0, rd0, True

    # -- $18194 / $181CA ------------------------------------------------------------------------
    def stop_channel(self, ch: int) -> None:
        a = self.structs[ch]
        self.m.ww(a, 0)
        self.m.ww(a + F_PERIOD, 1)
        self.m.ww(a + F_VOLUME, 0)
        self._paula(ch, "vol", 0)

    def stop_all(self) -> None:
        self.m.wb(V_MUSIC, 0)
        self.m.wb(V_SFX, 0)
        for ch in range(4):
            self.stop_channel(ch)
        self.m.ww(V_ACTIVE, 0)

    def stop_tune(self, n: int) -> None:                  # $181E8
        d0 = (n - 1) & 0xFFFF
        if d0 & 0x8000 or d0 >= self.L["tune_count"]:
            self.stop_all()
            return
        e = self.L["tunes"] + 8 * d0
        for ch in range(4):
            if self.m.rw(e + 2 * ch):
                self.stop_channel(ch)

    # -- $1824E / $1822C / $1825C ---------------------------------------------------------------
    def start_music(self, n: int) -> None:
        self.m.wb(V_MUSIC, n)
        self._start(n, B_MUSIC)

    def start_sfx(self, n: int) -> bool:
        m = self.m
        if m.rw(self.structs[3]) != 0 and (n & 0xFF) < m.rb(V_SFX):
            return False                                  # channel 3 busy with a higher number
        m.wb(V_SFX, n)
        self._start(n, B_SFX)
        return True

    def _start(self, n: int, d1: int) -> None:
        m = self.m
        m.ww(V_TICKS, 0)                                  # (also: CIA-A PRA bit 1 set, filter off)
        d0 = (n - 1) & 0xFFFF
        if d0 & 0x8000 or d0 >= self.L["tune_count"]:
            self.stop_all()
            return
        e = self.L["tunes"] + 8 * d0
        for ch in range(4):
            off = m.rw(e + 2 * ch)
            if off == 0:
                continue                                  # the channel is left as it is
            a1 = self.structs[ch]
            a2 = (e + 2 * ch + s16(off)) & 0xFFFFFF
            m.ww(a1 + F_VOLUME, 0)
            m.wl(a1 + F_SEQLOOP, 0)
            m.wl(a1 + F_PATLOOP, 0)
            m.wb(a1 + F_TRANSPOSE, 0)
            m.wb(a1 + F_REPEAT, 1)
            m.ww(a1, d1)                                  # instrument & effect data are kept
            while True:                                   # $182B0
                d0b = m.rb(a2)
                a2 += 1
                if d0b < 0x80:
                    break
                x = (d0b - 0x80) & 0xFF
                if x == 0:
                    a2 = m.rl(a1 + F_SEQLOOP)
                    if a2:
                        continue
                    m.ww(a1, 0)                           # empty sequence: channel off
                    break
                if x == 1:
                    m.wl(a1 + F_SEQLOOP, a2)
                elif x == 2:
                    m.wb(a1 + F_TRANSPOSE, m.rb(a2))
                    a2 += 1
                elif x == 3:
                    m.wb(a1 + F_REPEAT, m.rb(a2))
                    a2 += 1
            if m.rw(a1) == 0:
                continue
            m.wl(a1 + F_SEQ, a2)
            p = self.L["patterns"] + 2 * d0b
            m.wl(a1 + F_PAT, (p + s16(m.rw(p))) & 0xFFFFFF)
            m.ww(a1 + F_WAIT, 1)
        m.ww(V_ACTIVE, m.rw(V_ACTIVE) | d1)

    # -- $18316 play one tick ---------------------------------------------------------------
    def play(self) -> dict:
        m = self.m
        self.tick_events = []
        self._writes = {"dmacon": []}
        m.ww(V_KEYON, 0)
        if m.rw(V_ACTIVE):
            m.ww(V_TICKS, m.rw(V_TICKS) + 1)
            m.ww(V_ACTIVE, 0)
            for ch in range(4):
                a4 = self.structs[ch]
                d7 = m.rw(a4)
                if d7:
                    d7 = self.channel(ch, a4, d7) & 0xFFFF
                    m.ww(a4, d7)
                    m.ww(V_ACTIVE, m.rw(V_ACTIVE) | d7)
        m.ww(V_ACTIVE, m.rw(V_ACTIVE) & 0xC000)
        self.output()
        return self._writes

    def _period(self, a4: int, note_byte: int) -> int:
        """move.w 0(a5,d0.w): period of note byte (sign-extended) minus the instrument base."""
        m = self.m
        off = ((s8(note_byte) - m.rw(a4 + F_BASE)) * 2) & 0xFFFF
        a = (self.L["periods"] + s16(off)) & 0xFFFFFF
        if not self.L["periods"] - 48 <= a < self.L["periods"] + 48:
            self.warn.append("period read outside the table at $%05X (note %d, base %d)"
                             % (a, s8(note_byte), s16(m.rw(a4 + F_BASE))))
        return m.rw(a)

    # -- $1839A channel processor -------------------------------------------------------------
    def channel(self, ch: int, a4: int, d7: int) -> int:
        m = self.m
        w = m.rw(a4 + F_WAIT)
        if w:
            w = (w - 1) & 0xFFFF
            m.ww(a4 + F_WAIT, w)
            if w == 0:
                a3 = m.rl(a4 + F_PAT)
                d7 &= ~B_REST
                r = self._read(ch, a4, a3, d7)
                if r is None:
                    return 0                              # sequence ended: channel off
                d7 = r
        return self._effects(a4, d7)

    def _read(self, ch: int, a4: int, a3: int, d7: int) -> int | None:
        m = self.m
        guard = 0
        while True:                                       # $183B2
            guard += 1
            if guard > 100000:
                raise ModelError("pattern read does not terminate")
            d0 = m.rb(a3)
            a3 += 1
            if d0 < 0x80:
                return self._note(ch, a4, a3, d7, d0)
            d7 &= ~B_SLIDE                                # any command byte cancels a slide
            self.cmds_seen[d0] = self.cmds_seen.get(d0, 0) + 1
            if d0 >= 0xA0:
                continue
            ent = JUMP_TABLE + 2 * (d0 - 0x80)
            off = m.rw(ent)
            if off == 0:
                continue
            h = HANDLERS.get(ent + s16(off))
            if h is None:
                raise ModelError("unknown command handler $%05X" % (ent + s16(off)))
            if h == "end":                                # $18418
                p = m.rl(a4 + F_PATLOOP)
                if p:
                    a3 = p
                    continue
                a3 = m.rl(a4 + F_SEQ)
                d0 = m.rb(a3 - 1)
                c = (m.rb(a4 + F_REPEAT) - 1) & 0xFF
                m.wb(a4 + F_REPEAT, c)
                if c == 0:
                    m.wb(a4 + F_REPEAT, 1)
                    m.wb(a4 + F_TRANSPOSE, 0)
                    while True:                           # $1843C
                        d0 = m.rb(a3)
                        a3 += 1
                        if d0 < 0x80:
                            break
                        x = (d0 - 0x80) & 0xFF
                        if x == 0:
                            a3 = m.rl(a4 + F_SEQLOOP)
                            if a3:
                                self.tick_events.append((ch, "seqloop"))
                                continue
                            m.ww(a4 + F_PERIOD, 1)
                            m.ww(a4 + F_VOLUME, 0)
                            self.tick_events.append((ch, "end"))
                            return None
                        if x == 1:
                            m.wl(a4 + F_SEQLOOP, a3)
                        elif x == 2:
                            m.wb(a4 + F_TRANSPOSE, m.rb(a3))
                            a3 += 1
                        elif x == 3:
                            m.wb(a4 + F_REPEAT, m.rb(a3))
                            a3 += 1
                m.wl(a4 + F_SEQ, a3)                      # $1847E
                p = self.L["patterns"] + 2 * d0
                a3 = (p + s16(m.rw(p))) & 0xFFFFFF
                self.tick_events.append((ch, "pattern", d0))
            elif h == "loop":
                m.wl(a4 + F_PATLOOP, a3)
            elif h == "nop":
                pass
            elif h == "fixdur":
                d7 |= B_FIXDUR
                m.wb(a4 + F_FIXDUR, m.rb(a3))
                a3 += 1
            elif h == "freedur":
                d7 &= ~B_FIXDUR
            elif h == "wait256":
                m.ww(a4 + F_WAIT, m.rw(a4 + F_WAIT) + 0x100)
            elif h == "rest":                             # $184C2
                d7 &= ~B_ENV
                d7 |= B_REST
                m.ww(a4 + F_VOLUME, 0)
                self.tick_events.append((ch, "rest"))
                return self._duration(a4, a3, d7)
            elif h == "slide":
                d7 |= B_SLIDE
                m.wb(a4 + F_SLIDE_IV, m.rb(a3))
                m.wb(a4 + F_SLIDE_CNT, m.rb(a3 + 1))
                a3 += 2
            elif h == "grace":
                d7 = (d7 & 0xFFF8) | B_GRACE
                m.wb(a4 + F_GRACE_IV, m.rb(a3))
                m.wb(a4 + F_GRACE_LEN, m.rb(a3 + 1))
                a3 += 2
            elif h == "grace_off":
                d7 &= ~B_GRACE
            elif h == "vibrato":
                d7 = (d7 & 0xFFF8) | B_VIB
                m.wb(a4 + F_VIB_DELAY, m.rb(a3))
                m.wb(a4 + F_VIB_IV, m.rb(a3 + 1))
                m.wb(a4 + F_VIB_SPEED, m.rb(a3 + 2))
                a3 += 3
            elif h == "vibrato_off":
                d7 &= ~B_VIB
            elif h == "arpeggio":
                d7 = (d7 & 0xFFF8) | B_ARP
                a0 = self.L["arpeggios"] + 2 * m.rb(a3)
                a3 += 1
                a0 = (a0 + s16(m.rw(a0))) & 0xFFFFFF
                m.wb(a4 + F_ARPSPEED, m.rb(a0))
                m.wb(a4 + F_ARPLEN, m.rb(a0 + 1))
                m.wl(a4 + F_ARP, a0 + 2)
            elif h == "arpeggio_off":
                d7 &= ~B_ARP
            elif h == "envelope":
                a0 = self.L["envelopes"] + 2 * m.rb(a3)
                a3 += 1
                m.wl(a4 + F_ENV, (a0 + s16(m.rw(a0))) & 0xFFFFFF)
            elif h == "instrument":                       # $18566
                n = m.rb(a3)
                a3 += 1
                a0 = self.L["instruments"] + 16 * n
                m.ww(a4 + F_BASE, m.rw(a0))
                m.wl(a4 + F_START, m.rl(a0 + 2))
                m.ww(a4 + F_LEN, m.rw(a0 + 6))
                m.wl(a4 + F_LOOP, m.rl(a0 + 8))
                m.ww(a4 + F_LOOPLEN, m.rw(a0 + 12))
                d7 &= ~B_NOTRANSP
                if m.rw(a0 + 14):
                    d7 |= B_NOTRANSP
                self.inst[ch] = n

    def _note(self, ch: int, a4: int, a3: int, d7: int, d0: int) -> int:
        m = self.m                                        # $1859A
        if not d7 & B_NOTRANSP:
            d0 = (d0 + m.rb(a4 + F_TRANSPOSE)) & 0xFF
        m.wb(a4 + F_NOTE0, d0)
        if d7 & B_GRACE:
            d0 = (d0 + m.rb(a4 + F_GRACE_IV)) & 0xFF
            m.wb(a4 + F_GRACE_CNT, m.rb(a4 + F_GRACE_LEN))
        m.wb(a4 + F_NOTE, d0)
        m.ww(a4 + F_PERIOD, self._period(a4, d0))
        if d7 & B_VIB:
            p2 = self._period(a4, m.rb(a4 + F_NOTE) + m.rb(a4 + F_VIB_IV))
            diff = s16(p2 - m.rw(a4 + F_PERIOD)) >> 1     # sub.w, asr.w #1, ext.l
            r, _ = divs_w(diff, s8(m.rb(a4 + F_VIB_SPEED)) & 0xFFFF)
            m.ww(a4 + F_VIB_STEP, r)
            m.wb(a4 + F_VIB_SCNT, m.rb(a4 + F_VIB_SPEED))
            m.wb(a4 + F_VIB_SWING, 2 * m.rb(a4 + F_VIB_SPEED))
            m.wb(a4 + F_VIB_DCNT, m.rb(a4 + F_VIB_DELAY))
        if d7 & B_SLIDE:
            p2 = self._period(a4, m.rb(a4 + F_NOTE) + m.rb(a4 + F_SLIDE_IV))
            diff = s16(p2 - m.rw(a4 + F_PERIOD))
            d1 = m.rb(a4 + F_SLIDE_CNT)
            r, _ = divs_w(diff, d1)
            m.ww(a4 + F_SLIDE_STEP, r)
            prod = s16(-r) * d1                           # neg.w d0, muls.w d1,d0
            m.ww(a4 + F_PERIOD, m.rw(a4 + F_PERIOD) - prod)
        if d7 & B_ARP:
            m.wb(a4 + F_ARPTICK, 1)
            m.wl(a4 + F_ARPPTR, m.rl(a4 + F_ARP))
            m.wb(a4 + F_ARPCNT, m.rb(a4 + F_ARPLEN))
        d7 |= B_ENV
        m.wl(a4 + F_ENVPTR, m.rl(a4 + F_ENV))
        m.ww(a4 + F_ENVLEFT, 1)
        m.ww(a4 + F_VOLUME, 0)
        m.ww(V_KEYON, m.rw(V_KEYON) | m.rw(a4 + F_DMA))
        if self.inst[ch] is None:
            self.warn.append("channel %d: note before any instrument command" % ch)
        if m.rl(a4 + F_ENV) == 0:
            self.warn.append("channel %d: note before any envelope command" % ch)
        self.playing[ch] = self.inst[ch]
        self.tick_events.append((ch, "note", m.rb(a4 + F_NOTE), self.inst[ch]))
        return self._duration(a4, a3, d7)

    def _duration(self, a4: int, a3: int, d7: int) -> int:
        m = self.m                                        # $18672
        if d7 & B_FIXDUR:
            d0 = m.rb(a4 + F_FIXDUR)
        else:
            d0 = m.rb(a3)
            a3 += 1
        m.ww(a4 + F_WAIT, m.rw(a4 + F_WAIT) + d0)
        m.wl(a4 + F_PAT, a3)
        return d7

    def _effects(self, a4: int, d7: int) -> int:
        m = self.m                                        # $18688
        if d7 & B_REST:
            return d7
        d0 = m.rw(a4 + F_PERIOD)
        if d7 & B_SLIDE:
            c = (m.rb(a4 + F_SLIDE_CNT) - 1) & 0xFF
            m.wb(a4 + F_SLIDE_CNT, c)
            if c == 0:
                d7 &= ~B_SLIDE
            d0 = (d0 - m.rw(a4 + F_SLIDE_STEP)) & 0xFFFF
        elif d7 & B_GRACE:
            old = m.rb(a4 + F_GRACE_CNT)
            m.wb(a4 + F_GRACE_CNT, old - 1)
            if old == 0:                                  # borrow: back to the real note
                n0 = m.rb(a4 + F_NOTE0)
                m.wb(a4 + F_NOTE, n0)
                d0 = self._period(a4, n0)
        elif d7 & B_ARP:
            c = (m.rb(a4 + F_ARPTICK) - 1) & 0xFF
            m.wb(a4 + F_ARPTICK, c)
            if c == 0:
                a0 = m.rl(a4 + F_ARPPTR)
                e = m.rb(a0)
                a0 += 1
                c2 = (m.rb(a4 + F_ARPCNT) - 1) & 0xFF
                m.wb(a4 + F_ARPCNT, c2)
                if c2 == 0:
                    a0 = m.rl(a4 + F_ARP)
                    m.wb(a4 + F_ARPCNT, m.rb(a4 + F_ARPLEN))
                m.wl(a4 + F_ARPPTR, a0)
                m.wb(a4 + F_ARPTICK, m.rb(a4 + F_ARPSPEED))
                d0 = self._period(a4, e + m.rb(a4 + F_NOTE))
        elif d7 & B_VIB:
            old = m.rb(a4 + F_VIB_DCNT)
            m.wb(a4 + F_VIB_DCNT, old - 1)
            if old == 0:
                m.wb(a4 + F_VIB_DCNT, 0)
                c = (m.rb(a4 + F_VIB_SCNT) - 1) & 0xFF
                m.wb(a4 + F_VIB_SCNT, c)
                if c == 0:
                    m.ww(a4 + F_VIB_STEP, -m.rw(a4 + F_VIB_STEP))
                    m.wb(a4 + F_VIB_SCNT, m.rb(a4 + F_VIB_SWING))
                d0 = (d0 + m.rw(a4 + F_VIB_STEP)) & 0xFFFF
        m.ww(a4 + F_PERIOD, d0)                           # $1873A
        if not d7 & B_ENV:
            return d7
        left = (m.rw(a4 + F_ENVLEFT) - 1) & 0xFFFF
        m.ww(a4 + F_ENVLEFT, left)
        if left == 0:
            a0 = m.rl(a4 + F_ENVPTR)
            b = m.rb(a0)
            a0 += 1
            if b == 0:                                    # $1879A: end or release point
                r = m.rb(a0)
                if r == 0:
                    return d7 & ~B_ENV
                v = r if r < 0x80 else (-r) & 0xFF
                t = (v - m.rw(a4 + F_WAIT)) & 0xFFFF
                if not t & 0x8000:
                    return d7 & ~B_ENV                    # note too short: hold
                m.ww(a4 + F_ENVLEFT, -t)                  # wait until |r| ticks before the end
                m.wb(a4 + F_ENVRATE, 0)
                m.wb(a4 + F_ENVCNT, 0)
                m.wb(a4 + F_ENVSTEP, 0)
                m.wl(a4 + F_ENVPTR, a0)
                return d7
            if b < 0x80:                                  # b ticks of (signed) step
                m.ww(a4 + F_ENVLEFT, b)
                m.wb(a4 + F_ENVRATE, 1)
                m.wb(a4 + F_ENVCNT, 1)
                m.wb(a4 + F_ENVSTEP, m.rb(a0))
                a0 += 1
            else:                                         # -b ticks of +-1 every |p| ticks
                m.ww(a4 + F_ENVLEFT, (-b) & 0xFF)
                m.wb(a4 + F_ENVSTEP, 1)
                p = m.rb(a0)
                a0 += 1
                if p & 0x80:
                    p = (-p) & 0xFF
                    m.wb(a4 + F_ENVSTEP, -m.rb(a4 + F_ENVSTEP))
                m.wb(a4 + F_ENVRATE, p)
                m.wb(a4 + F_ENVCNT, 1)
            m.wl(a4 + F_ENVPTR, a0)
        c = (m.rb(a4 + F_ENVCNT) - 1) & 0xFF              # $187CC
        m.wb(a4 + F_ENVCNT, c)
        if c == 0:
            m.wb(a4 + F_ENVCNT, m.rb(a4 + F_ENVRATE))
            m.ww(a4 + F_VOLUME, m.rw(a4 + F_VOLUME) + s8(m.rb(a4 + F_ENVSTEP)))
        return d7

    # -- $187E4 Paula output ------------------------------------------------------------------
    def _paula(self, ch: int, reg: str, v: int) -> None:
        if self._writes is not None:                      # outside play(): not recorded
            self._writes.setdefault(ch, {})[reg] = v

    def output(self) -> None:
        m = self.m
        d0 = m.rw(V_KEYON)
        if d0:
            self._writes["dmacon"].append(d0)             # DMA off for these channels
            self._writes["intreq"] = d0 << 7
            for ch in range(4):
                if d0 & (1 << ch):
                    self._paula(ch, "per_stop", 1)        # AUDxPER = 1, AUDxDAT = 0, then waits
        mask_music, mask_sfx = m.rw(V_MASK_MUSIC), m.rw(V_MASK_SFX)
        for ch in range(4):
            a0 = self.structs[ch]
            mask = mask_sfx if m.rb(a0) & 0x40 else mask_music
            self._paula(ch, "vol", m.rw(a0 + F_VOLUME) & mask)
            self._paula(ch, "per", m.rw(a0 + F_PERIOD))
            if d0 & (1 << ch):
                self._paula(ch, "len", m.rw(a0 + F_LEN))
                self._paula(ch, "lc", m.rl(a0 + F_START))
            else:
                self._paula(ch, "len", m.rw(a0 + F_LOOPLEN))
                self._paula(ch, "lc", m.rl(a0 + F_LOOP))
        self._writes["dmacon"].append(d0 | 0x8000)
        self._writes["keyon"] = d0
        m.ww(V_KEYON, 0)

    def state(self) -> bytes:
        """Everything the next ticks depend on (the tick counter excluded)."""
        b = self.m.b
        s = bytearray()
        for a in self.structs:
            s += b[a:a + STRUCT_SIZE]
        s += b[V_ACTIVE:V_ACTIVE + 4]
        s += bytes(255 if i is None else i for i in self.inst + self.playing)
        return hashlib.blake2b(bytes(s), digest_size=16).digest()


def paula_volume(v: int) -> int:
    """Effective AUDxVOL: bit 6 set means maximum (64), else bits 0-5."""
    return 64 if v & 0x40 else v & 0x3F


# ---------------------------------------------------------------------------------------------
# Tunes
# ---------------------------------------------------------------------------------------------

def parse_sequence(mem: Mem, a: int) -> list:
    items: list = []
    for _ in range(4096):
        x = mem.rb(a)
        a += 1
        if x < 0x80:
            items.append(x)
        elif x == 0x80:
            items.append("end")
            return items
        elif x == 0x81:
            items.append("loop")
        elif x in (0x82, 0x83):
            items.append(["transpose" if x == 0x82 else "repeat", s8(mem.rb(a)) if x == 0x82
                          else mem.rb(a)])
            a += 1
        else:
            items.append("ignored %02X" % x)
    items.append("...")
    return items


def disassemble_pattern(mem: Mem, a: int, limit: int = 4096) -> list:
    """Static listing of a pattern (fixed-duration mode followed linearly)."""
    out: list = []
    fixed = False
    for _ in range(limit):
        x = mem.rb(a)
        a += 1
        if x < 0x80:
            if fixed:
                out.append(["note", x])
            else:
                out.append(["note", x, mem.rb(a)])
                a += 1
            continue
        if x == 0x80:
            out.append(["end"])
            return out
        if x >= 0xA0 or x > 0x90:
            out.append(["ignored", x])
            continue
        name, n = COMMANDS[x]
        if x == 0x84:
            fixed = True
        elif x == 0x85:
            fixed = False
        if n == "dur":
            n = 0 if fixed else 1
        out.append([name] + [mem.rb(a + i) for i in range(n)])
        a += n
    out.append(["..."])
    return out


def run_tune(data: bytes, lay: dict, n: int, entry: str = "music", base: bytes | None = None,
             max_ticks: int = 400000, trace: bool = False) -> dict:
    p = Player(data, lay, base)
    p.init()                                              # jsr $18000
    p.stop_all()                                          # jsr $18004
    if entry == "music":
        p.start_music(n)                                  # jsr $18010
    else:
        p.start_sfx(n)                                    # jsr $18014
    e = lay["tunes"] + 8 * (n - 1)
    used = [ch for ch in range(4) if p.m.rw(e + 2 * ch)]
    ticks: list = []
    keyons: list = []
    seen: dict = {}
    end_tick = loop_start = loop_len = None
    events: list = []
    seqloops: dict = {}
    error = None
    for t in range(max_ticks):
        try:
            w = p.play()
        except ModelError as exc:
            error = "tick %d: %s" % (t, exc)
            break
        # per channel: AUDxPER, AUDxVOL (as written), instrument of the last key-on, AUDxLC, AUDxLEN
        row = [(w[ch]["per"], w[ch]["vol"], p.playing[ch], w[ch]["lc"], w[ch]["len"])
               for ch in range(4)]
        ticks.append((row, w["keyon"]))
        for ev in p.tick_events:
            events.append((t,) + ev)
            if ev[1] == "note":
                ch = ev[0]
                idx = s8(ev[2]) - s16(p.m.rw(p.structs[ch] + F_BASE))
                keyons.append({"tick": t, "ch": ch, "note": ev[2], "index": idx, "inst": ev[3],
                               "period": w[ch]["per"], "start": w[ch]["lc"], "words": w[ch]["len"]})
            elif ev[1] == "seqloop":
                seqloops.setdefault(ev[0], []).append(t)
        if trace:
            print("%6d  %s  %s" % (t, " | ".join("%4d %2d %s%s" % (
                row[c][0], paula_volume(row[c][1]), "*" if w["keyon"] & (1 << c) else " ",
                "" if row[c][2] is None else "i%-2d" % row[c][2]) for c in range(4)),
                " ".join("%d:%s" % (ev[0], "/".join(str(x) for x in ev[1:])) for ev in p.tick_events)))
        if all(p.m.rw(p.structs[ch]) == 0 for ch in used):
            end_tick = t
            break
        s = p.state()
        if s in seen:
            loop_start, loop_len = seen[s] + 1, t - seen[s]
            break
        seen[s] = t
    state_loop = loop_start
    if loop_start is not None:
        # The state repeats, so ticks >= loop_start repeat with period loop_len. Earlier ticks
        # whose audible output (key-ons, and period/volume/sample of the channels that are not
        # at volume 0) equals the output loop_len ticks later belong to the loop too: what kept
        # the state different (e.g. a silent channel's old sample pointer) does not sound.
        def audible(tk):
            row, keyon = tk
            return keyon, tuple(r if paula_volume(r[1]) or keyon & (1 << c) else 0
                                for c, r in enumerate(row))
        while loop_start > 0 and audible(ticks[loop_start - 1]) == audible(
                ticks[loop_start - 1 + loop_len]):
            loop_start -= 1
        del ticks[loop_start + loop_len:]
        keyons = [k for k in keyons if k["tick"] < loop_start + loop_len]
        events = [e for e in events if e[0] < loop_start + loop_len]
    return {"player": p, "used": used, "ticks": ticks, "keyons": keyons, "events": events,
            "seqloops": seqloops, "end_tick": end_tick, "loop_start": loop_start,
            "loop_len": loop_len, "state_loop_start": state_loop, "error": error}


def rle_channel(ticks: list, ch: int) -> list:
    runs: list = []
    for row, _ in ticks:
        per, vol, inst = row[ch][:3]
        cur = [per, paula_volume(vol), inst]
        if runs and runs[-1][1:] == cur:
            runs[-1][0] += 1
        else:
            runs.append([1] + cur)
    return runs


def classify(res: dict) -> str:
    n = len(res["used"])
    if res["loop_start"] is not None:
        return "music (loops)"
    if n >= 3:
        return "jingle (multi-channel, ends)"
    return "sound effect"


# ---------------------------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------------------------

def table_entries(mem: Mem, base: int, end: int) -> list[int]:
    """Self-relative word pointers from base up to the first target (the list's own end)."""
    out = []
    a, first = base, None
    while first is None or a < first:
        if a >= end or len(out) > 256:
            break
        t = (a + s16(mem.rw(a))) & 0xFFFFFF
        out.append(t)
        first = t if first is None else min(first, t)
        a += 2
    return out


def _hex(v):
    return "0x%05X" % v


def build_report(path: Path, base: bytes | None, max_ticks: int) -> dict:
    data = path.read_bytes()
    name = path.stem.split("_")[0]
    lay = locate(data)
    probe = Player(data, lay, base)
    probe.init()
    mem = probe.m
    ctx = CONTEXT.get(name, ("?", "?"))
    player = {}
    for k, v in lay.items():
        if k == "warnings":
            continue
        if isinstance(v, bool) or isinstance(v, str) or k == "tune_count":
            player[k] = v
        elif isinstance(v, list):
            player[k] = [_hex(x) for x in v]
        else:
            player[k] = _hex(v)
    rep: dict = {
        "file": path.name, "load_address": _hex(LOAD), "size": len(data),
        "context": ctx[0], "tick_source": ctx[1],
        "ticks_per_second": {"vbl_hook_ntsc": 50.0, "vbl_hook_pal": 41.667,
                             "cmp_loop_ntsc": "48 (4 of 5 frames; see the ledger)",
                             "note": "durations in the data count player ticks"},
        "paula_clock_hz": {"ntsc": NTSC_CLOCK, "pal": PAL_CLOCK},
        "player": player,
        "warnings": list(lay["warnings"]),
    }
    per0 = lay["periods"]
    rep["period_table"] = {"address": _hex(per0 - 48), "index0": _hex(per0), "first_index": -24,
                           "periods": [mem.rw(per0 - 48 + 2 * i) for i in range(48)]}
    # Instrument records as init leaves them; samples deduplicated by BODY address.
    samples: dict = {}
    insts = []
    recs = [{"index": 0, "record": lay["instruments"], "entry": None, "form": None,
             "form_ok": None}] + probe.inst_records
    for r in recs:
        a = r["record"]
        start, words, loop, loopw = mem.rl(a + 2), mem.rw(a + 6), mem.rl(a + 8), mem.rw(a + 12)
        sid = None
        if r["form"] is None:                             # built-in record: a looped waveform
            raw = bytes(mem.b[start:start + 2 * words])
            samples[start] = {"id": 0, "builtin": True, "body": start, "body_size": len(raw),
                              "one_shot": 0, "repeat": 2 * loopw if loop == start else 0,
                              "waveform": [s8(x) for x in raw]}
            sid = 0
        elif r["form"] is not None:
            if start not in samples:
                info = scan_8svx(mem, r["form"]) or {}
                raw = bytes(mem.b[start:start + 2 * words])
                info.update(sample_stats(raw, info.get("rate", 0)))
                samples[start] = {"id": len(samples), **info}
            sid = samples[start]["id"]
        insts.append({
            "index": r["index"], "record": _hex(a),
            "list_entry": None if r["entry"] is None else _hex(r["entry"]),
            "base_note": s16(mem.rw(a)), "no_transpose": bool(mem.rw(a + 14)),
            "sample": sid, "start": _hex(start), "length_bytes": 2 * words,
            "loop_start": _hex(loop), "loop_length_bytes": 2 * loopw,
            "looped": loop != lay["silent"], "form_ok": r["form_ok"],
            "note": ("built-in record (not set by init)" if r["form"] is None else
                     "list entry does not point at a FORM: init kept the previous VHDR/BODY"
                     if not r["form_ok"] else None),
        })
    rep["instruments"] = insts
    rep["samples"] = []
    for s in samples.values():
        d = {k: (_hex(v) if k in ("form", "body") else v) for k, v in s.items()}
        os_, rp = s.get("one_shot", 0), s.get("repeat", 0)
        d["length_bytes"] = (os_ & ~1) + (rp & ~1)
        d["loop"] = None if not rp & ~1 else {"start_offset": os_ & ~1, "length_bytes": rp & ~1}
        rep["samples"].append(d)
    envs = table_entries(mem, lay["envelopes"], lay["tunes"])
    arps = (table_entries(mem, lay["arpeggios"], lay["envelopes"])
            if lay["arpeggios"] != lay["envelopes"] else [])
    ends = sorted(set(envs + [lay["tunes"]]))
    rep["envelopes"] = [{"index": i, "address": _hex(t),
                         "bytes": bytes(mem.b[t:min(x for x in ends if x > t)]).hex()}
                        for i, t in enumerate(envs)]
    rep["arpeggios"] = [{"index": i, "address": _hex(t), "speed": mem.rb(t), "length": mem.rb(t + 1),
                         "offsets": [s8(mem.rb(t + 2 + j)) for j in range(mem.rb(t + 1))]}
                        for i, t in enumerate(arps)]
    rep["tunes"] = []
    all_cmds: dict = {}
    static_cmds: dict = {}
    for n in range(1, lay["tune_count"] + 1):
        e = lay["tunes"] + 8 * (n - 1)
        seqs, pats = {}, set()
        for ch in range(4):
            off = mem.rw(e + 2 * ch)
            if off:
                a = (e + 2 * ch + s16(off)) & 0xFFFFFF
                items = parse_sequence(mem, a)
                seqs[str(ch)] = {"address": _hex(a), "items": items}
                pats |= {x for x in items if isinstance(x, int)}
        res = run_tune(data, lay, n, base=base, max_ticks=max_ticks)
        p = res["player"]
        for c, k in p.cmds_seen.items():
            all_cmds[c] = all_cmds.get(c, 0) + k
        if res["end_tick"] is not None:
            length = res["end_tick"]
        elif res["loop_start"] is not None:
            length = res["loop_start"] + res["loop_len"]
        else:
            length = len(res["ticks"])
        live = [row[ch] for row, _ in res["ticks"] for ch in res["used"]]
        pers = [r[0] for r in live if r[1] and r[0] > 1]
        warns = sorted(set(p.warn))
        if res["error"]:
            warns.append(res["error"])
        if p.m.outside:
            warns.append("reads outside the file: " + ", ".join(
                "$%05X" % a for a in sorted(p.m.outside)[:12]))
        odd = sorted({r[1] for r in live if r[1] > 64})
        if odd:
            warns.append("AUDxVOL values above 64: " + ", ".join("%04X" % v for v in odd[:8]))
        if res["end_tick"] is None and res["loop_start"] is None:
            warns.append("no end and no exact loop within %d ticks" % max_ticks)
        pat_info = {}
        for x in sorted(pats):
            pa = (lay["patterns"] + 2 * x + s16(mem.rw(lay["patterns"] + 2 * x))) & 0xFFFFFF
            pat_info[str(x)] = {"address": _hex(pa), "listing": disassemble_pattern(mem, pa)}
            for it in pat_info[str(x)]["listing"]:
                k = it[0] if it[0] != "note" else "note"
                static_cmds[k] = static_cmds.get(k, 0) + 1
        ch_loops = {}
        for ch, ts in sorted(res["seqloops"].items()):
            d = sorted({b - a for a, b in zip(ts, ts[1:])})
            ch_loops[str(ch)] = {"first_jump_tick": ts[0], "jumps": len(ts),
                                 "period_ticks": d[0] if len(d) == 1 else (d or None)}
        idx = [k["index"] for k in res["keyons"]]
        rep["tunes"].append({
            "tune": n, "channels": res["used"], "kind": classify(res),
            "ticks": length, "seconds_at_50hz": round(length / 50, 2),
            "ends_at_tick": res["end_tick"],
            "loop": None if res["loop_start"] is None else {
                "start_tick": res["loop_start"], "length_ticks": res["loop_len"],
                "state_repeats_from": res["state_loop_start"]},
            "channel_loops": ch_loops,
            "period_range": [min(pers), max(pers)] if pers else None,
            "index_range": [min(idx), max(idx)] if idx else None,
            "warnings": warns,
            "sequences": seqs, "patterns": pat_info,
            "key_ons": [[k["tick"], k["ch"], k["inst"], k["note"], k["index"], k["period"]]
                        for k in res["keyons"]],
            "frames": {str(ch): rle_channel(res["ticks"], ch) for ch in res["used"]},
        })
    rep["commands_executed"] = {"%02X" % c: k for c, k in sorted(all_cmds.items())}
    rep["commands_static"] = static_cmds
    rep["format"] = {
        "frames": "per used channel: runs [count, AUDxPER, effective volume 0-64, instrument of "
                  "the last key-on]; they cover ticks 0..ends_at_tick (the last run is the silent "
                  "stop: period 1, volume 0) or 0..loop start + loop length - 1",
        "key_ons": "[tick, channel, instrument, note byte after transpose and grace, period-table "
                   "index (note - instrument base; -24..23 is inside the table), AUDxPER]",
        "instrument": "the number given to command 90h; its record is in 'instruments'",
        "pitch": "AUDxPER p plays the sample at clock/p samples per second (NTSC clock "
                 "3579545 Hz); index i of the table is i semitones above period 447",
    }
    return rep


def summarize(rep: dict) -> None:
    print("%s: %d tunes, %d instruments, %d samples; tables tunes %s patterns %s envelopes %s "
          "arpeggios %s; code %s MU1's" % (
              rep["file"], len(rep["tunes"]), len(rep["instruments"]) - 1, len(rep["samples"]),
              rep["player"]["tunes"], rep["player"]["patterns"], rep["player"]["envelopes"],
              rep["player"]["arpeggios"], "=" if rep["player"]["same_code_as_mu1"] else "!="))
    for t in rep["tunes"]:
        loop = t["loop"]
        print("  tune %2d  ch %-8s %6d ticks (%6.2f s)  %-28s %-26s idx %-9s per %s%s" % (
            t["tune"], ",".join(str(c) for c in t["channels"]), t["ticks"], t["seconds_at_50hz"],
            t["kind"], "loop from %d, %d ticks" % (loop["start_tick"], loop["length_ticks"])
            if loop else "ends", "%s..%s" % tuple(t["index_range"]) if t["index_range"] else "-",
            "%s..%s" % tuple(t["period_range"]) if t["period_range"] else "-",
            "  [%s]" % "; ".join(t["warnings"]) if t["warnings"] else ""))
        for ch, cl in t["channel_loops"].items():
            print("           ch %s: sequence jumps to its loop point at tick %d%s" % (
                ch, cl["first_jump_tick"], ", then every %s ticks" % cl["period_ticks"]
                if cl["period_ticks"] else ""))
    print("  commands executed:", " ".join("%s x%d" % kv for kv in rep["commands_executed"].items()))


def verify(files: list[Path], max_ticks: int) -> int:
    """Runs the original player code in Unicorn (optional dependency, as tools/amigaemu.py) and
    compares each tick's Paula writes and the player's RAM ($18020-$1817F) with the model."""
    try:
        from unicorn import UC_ARCH_M68K, UC_MODE_BIG_ENDIAN, Uc
        from unicorn.m68k_const import (UC_CPU_M68K_M68000, UC_M68K_REG_A7, UC_M68K_REG_D0,
                                        UC_M68K_REG_PC)
    except ImportError:
        print("--verify needs Unicorn (pip install unicorn)")
        return 2
    sentinel = 0x400

    class Real:
        def __init__(self, data: bytes):
            self.uc = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
            self.uc.ctl_set_cpu_model(UC_CPU_M68K_M68000)
            self.uc.mem_map(0, CHIP)
            self.uc.mem_write(LOAD, data)
            self.uc.mem_write(sentinel, b"\x4e\x71" * 4)
            self.uc.mmio_map(0xDFF000, 0x1000, self._read, None, self._write, None)
            self.uc.mmio_map(0xBFE000, 0x1000, lambda *a: 0xFF, None, lambda *a: None, None)
            self.line = 0
            self.log: list = []

        def _read(self, uc, off, size, ud):
            if size == 4:
                return (self._read(uc, off, 2, ud) << 16) | self._read(uc, off + 2, 2, ud)
            v = 0
            if off & ~1 == 0x1E:
                v = 0x0780                                # INTREQR: the audio requests are set
            elif off & ~1 == 0x06:
                self.line = (self.line + 1) & 0xFF        # VHPOSR: one line per read
                v = self.line << 8
            return ((v >> 8) if off % 2 == 0 else v) & 0xFF if size == 1 else v

        def _write(self, uc, off, size, value, ud):
            if size == 4:
                self.log += [(off, value >> 16), (off + 2, value & 0xFFFF)]
            else:
                self.log.append((off, value & 0xFFFF))

        def call(self, addr: int, d0: int = 0) -> dict:
            self.log = []
            self.uc.mem_write(0x7FF00, struct.pack(">I", sentinel))
            self.uc.reg_write(UC_M68K_REG_A7, 0x7FF00)
            self.uc.reg_write(UC_M68K_REG_D0, d0)
            self.uc.emu_start(addr, sentinel, count=2_000_000)
            if self.uc.reg_read(UC_M68K_REG_PC) != sentinel:
                raise ModelError("$%05X did not return" % addr)
            out: dict = {c: {} for c in range(4)}
            out["dmacon"] = []
            for off, v in self.log:
                if off == 0x96:
                    out["dmacon"].append(v)
                elif 0xA0 <= off < 0xE0:
                    d, r = out[(off - 0xA0) >> 4], (off - 0xA0) & 0xF
                    if r == 0:
                        d["lch"] = v
                    elif r == 2:
                        d["lc"] = (d.pop("lch") << 16) | v
                    elif r == 4:
                        d["len"] = v
                    elif r == 6:
                        if "per" in d:
                            d["per_stop"] = d["per"]
                        d["per"] = v
                    elif r == 8:
                        d["vol"] = v
            return out

    total = bad = 0
    for f in files:
        data = f.read_bytes()
        lay = locate(data)
        for n in range(1, lay["tune_count"] + 1):
            for entry in ("music", "sfx"):
                res = run_tune(data, lay, n, entry, None, max_ticks)
                length = (res["end_tick"] + 1 if res["end_tick"] is not None else
                          res["state_loop_start"] + res["loop_len"])   # a full exact cycle
                real, mp = Real(data), Player(data, lay)
                real.call(0x18000)
                real.call(0x18004)
                real.call(0x18010 if entry == "music" else 0x18014, n)
                mp.init()
                mp.stop_all()
                mp.start_music(n) if entry == "music" else mp.start_sfx(n)
                for t in range(length + 50):
                    w, r = mp.play(), real.call(0x18018)
                    total += 1
                    diff = [k for c in range(4) for k in ("per", "vol", "len", "lc", "per_stop")
                            if w[c].get(k) != r[c].get(k)]
                    if w["dmacon"] != r["dmacon"]:
                        diff.append("dmacon")
                    if bytes(real.uc.mem_read(V_ACTIVE, 0x160)) != bytes(mp.m.b[V_ACTIVE:V_ACTIVE + 0x160]):
                        diff.append("ram")
                    if diff:
                        bad += 1
                        print("%s tune %d (%s) tick %d differs: %s" % (f.name, n, entry, t, diff))
                        break
        print("%s: %d tunes checked against the 68000 code" % (f.name, lay["tune_count"]))
    print("ticks compared: %d, tunes with a difference: %d" % (total, bad))
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "music")
    ap.add_argument("--ram", type=Path, help="RAM image used as the memory around the file")
    ap.add_argument("--max-ticks", type=int, default=400000)
    ap.add_argument("--trace", help="NAME:TUNE, e.g. MU1:5 (prints ticks, writes nothing)")
    ap.add_argument("--ticks", type=int, default=3000, help="ticks to trace")
    ap.add_argument("--entry", choices=("music", "sfx"), default="music")
    ap.add_argument("--verify", action="store_true",
                    help="compare the model with the original code run in Unicorn")
    args = ap.parse_args()
    files = args.files or [ROOT / "build" / "extracted" / "files" / f for f in FILES]
    if args.verify:
        return verify(files, args.max_ticks)
    base = args.ram.read_bytes() if args.ram else None
    if args.trace:
        nm, tn = args.trace.split(":")
        path = next(f for f in files if f.name.upper().startswith(nm.upper() + "_"))
        data = path.read_bytes()
        res = run_tune(data, locate(data), int(tn), args.entry, base, args.ticks, trace=True)
        print("end tick", res["end_tick"], "loop", res["loop_start"], res["loop_len"],
              "warnings", sorted(set(res["player"].warn)), res["error"] or "")
        return 0
    args.out.mkdir(parents=True, exist_ok=True)
    for f in files:
        rep = build_report(f, base, args.max_ticks)
        out = args.out / (f.stem.split("_")[0] + ".json")
        out.write_text(json.dumps(rep, separators=(",", ":")) + "\n")
        summarize(rep)
        print("  ->", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
