#!/usr/bin/env python3
"""Robocop 2's title music (TITM tune 1) for an OPLL (YM2413: MSX-MUSIC built in, or an FM-PAC):
register streams for the Z80 player when an OPLL is found, much closer to the Amiga than the
PSG's: Amiga channels 0-2 on melodic channels 0-2, the drums of channel 3 on the rhythm section.

Input: tools/msxsound.py's Amiga model (its Title: build/music/TITM.json from rc2music.py and the
samples of build/extracted/files/TITM_04.bin; per channel and tick the period, volume, instrument,
key-ons and Channel.amp, the RMS of the sample bytes played x volume / 64; each instrument's
measured samples per cycle). Output: build/msx/fm.bin (the streams), fm.inc
(FM_BYTES, the mapping in comments), build/music/preview/titm_fm.wav (the streams decoded as the
player reads them, on the OPLL model below, as long as titm_amiga.wav), and a printed comparison
with the Amiga. Needs numpy (the project's venv). About a minute.

usage:
  msxfm.py [--out build/msx] [--seconds 60]
           [--wav DIR] [--budget BYTES] [--no-wav]

  --out: the directory of fm.bin and fm.inc; --seconds: the preview's length; --wav: the
  preview's directory (default build/music/preview); --budget: bytes of fm.bin (default 24 KiB:
  the volumes fit exact to the step well below it); --no-wav: no preview, no comparison.

fm.bin: five 24-bit little-endian offsets from the blob's start (bytes 0-14): the melodic
streams of channels 0, 1, 2, the rhythm stream, the patch block (14 bytes: the custom instrument,
registers 00h-07h, then 16h, 17h, 18h, 26h, 27h, 28h); then the data, unaligned.
- Melodic stream: records of dur (1..255 ticks at 50 Hz; 0 = the end: the voice goes on at its
  stream's start) and ctl: bits 0-3 the volume (attenuation, 3 dB a step); 4: a word follows
  (F-number bits 0-8, block bits 9-11, little-endian); 5: a byte follows, after the word
  (instrument bits 7-4: 0 custom, 1-15 the presets; sustain bit 0); 6: key on during the record;
  7: retrigger (key off, then on, at the record's start; with bit 6). A field not given keeps
  the voice's value; the first record gives both; identical consecutive states are one record
  (split at 255). Every note is a retrigger (also after silence and at tick 0: the loop).
- Rhythm stream: dur, ctl: bits 4-0 the keys struck (as 0Eh: BD SD TOM TCY HH); 5: the values of
  36h, 37h, 38h follow (the first record always gives them). The player writes them, 0Eh = 20h,
  then 20h | keys when any: every record keys off what it does not strike.
- Each of the four streams lasts the loop's 5184 ticks; the encoder's output is decoded here as
  the player reads it (twice round) and checked against what it meant, tick by tick.

The OPLL model (it only steers the choices and the preview: the chip in openMSX is the judge)
- Patches: the 15 ROM instruments and the 3 rhythm patches as emu2413 1.5 (M. Okazaki) carries
  them, quoted from memory: approximations of the chip's ROM (MAME's and older emu2413 tables
  differ in a few bytes). Two operators: the modulator (its feedback: the mean of its last two
  outputs, FB 7 = +-4 pi at full level) shifts the carrier's phase by 8 pi times its output;
  sine or half sine; multipliers; TL 0.75 dB, the volume 3 dB, KSL 1.5/3/6 dB an octave add to
  the EG, all saturating at 47.6 dB. Vibrato +-13 cents at 6.4 Hz, tremolo 4.9 dB at 3.7 Hz.
- EG (0.375 dB steps): decay 20.9 s for its 127 steps at rate 4, 2^(1/4) faster per rate step
  (key scaling: the block and F-number bit 8, all of it with KSR, else a quarter); attack
  1.73 s at rate 4 (eg -> 3/4 eg - 1 a step), instant from rate 60 (the YM2413 manual's tables
  as recalled); the decay to SL, then a hold (sustained patches) or RR (percussive ones); after
  the key-off rate 5 with the sustain bit, else RR (sustained) or 7 (percussive); a melodic
  modulator holds. A key-on first damps the sounding note (rate 12: up to ~10 ms) and then
  attacks with both phases at 0. The level model computes each tick's output for each volume
  from that EG and the patch's power at the modulator's level (one period computed: a 1:1
  modulated half sine is on for less than half the period); it matches the render to ~0.3 dB
  (a slow attack's first tick to ~3 dB).
- Rhythm: BD a two-operator voice on channel 6; SD the noise against the HH slot's phase bit 8
  (half a square at twice channel 7's frequency, half noise); TOM a sine at 5 x channel 8's; HH
  and TCY from the phase bits of channels 7 and 8 (unused); the rhythm sounds out at twice a
  melodic channel's level; the noise is a seeded white sequence (the chip's is a 23-bit LFSR).

How the Amiga sound is mapped (the decisions and why)
- Levels: the per-tick target is Channel.amp in dB from msxsound's reference a_ref, the loudest
  melodic tick at a full-level sine. The volume only does what the instrument's own envelope
  does not (no decay applied twice): a trellis per channel picks each tick's volume against the
  level model (the loudness-weighted squared error in 3 dB steps + lambda x bytes, lambda the
  smallest that fits the budget, at least 0.02); silent ticks score what the release leaks.
- Notes: a retrigger at every Amiga key-on and where the sound resumes after silence; the key
  off when the channel falls silent (-46 dB) or plays RoboCop's speech (SPEECH_INST: PCM on the
  PSG).
- Pitch: Paula's rate (3579545 / AUDxPER, DMA_PERIOD at least) over the sample's own samples
  per cycle as measured (Title.pitch: the median YIN period of its body), not msxsound's
  tuning grid (Title.spc), as tools/msxscc.py does: both chips agree. The PSG snaps every
  instrument onto one grid because its pure squares keep nothing of the samples' timbres
  (inharmonic partials, detuned layers) and expose their detuning as plain dissonance; here
  each instrument keeps much of its timbre (the patch fitted to its spectrum), so the Amiga's
  real tuning, detuning included, is the goal (on the Amiga TIMPANI sits 45 cents above that
  grid, PIZZICATO 22 below, #13 15 above, the rest within 8). No octave shifts (FILTER-WAH plays
  at 34-67 Hz). The F-number of the most precision (over the patch's fundamental: the synth
  bass's carrier runs at half; 3.4-6.8 cents a step), a new word per tick in slides (#1).
- Instruments: each Amiga instrument against each preset: the band profile (power in harmonic
  bands of f0: 1, 2, 3, 4, 5-6, 7-8, 9-12, 13-16, 17-24, 25-32, up to 5 kHz) of its 4 most
  frequent notes in windows of ticks 0-2, 2-6, 6-12, 12-24, 24-48, 48-96 (the mean |dB|
  difference, the energy-weighted windows), +1 dB per carrier LFO (the samples' pitch is steady
  to 2-4 cents, the chip's vibrato swings 13), plus the level error of all its notes at their
  best volumes, each after the note it retriggers (the damp delays a slow attack further).
- The custom patch: fitted (coordinate descent from the 3 best presets: multipliers, modulator
  level, feedback, waveforms and the modulator's envelope on the band profiles; then the
  carrier's envelope on the levels; no LFOs) for each instrument of 5 % of the music's weight;
  kept: the patch that gains most over the whole tune (weight x improvement on each
  instrument's best preset); an instrument it was not fitted for takes it only when 0.5 dB
  closer (near-ties keep their preset and the lines distinct timbres). It went to ba1, the
  bass (31 % of the weight; 0.79 dB tune-wide, #13 takes it too); BRASS4's came second (0.75),
  TIMPANI's third (0.62: its presets are poor, piano at 9.5 dB, but it is 8 % of the weight).
- Drums (channel 3 plays BDRM, SNARE and TOM1 only): BDRM -> BD, SNARE -> SD, TOM1 -> TOM, the
  rhythm pitches from the samples (BD 100 Hz, SD's tone 196 Hz, TOM 209 Hz); each hit's volume
  matches its energy over its first 4 ticks. The ROM's drums die in 3-6 ticks where the Amiga's
  ring for 10-20: a key-off record 1-8 ticks after a BD or SD hit releases it at rate 5 (the
  sustain bits of 26h and 27h, chosen by the error), much slower than its decay; the key-off
  tick follows the hit's shape (power-weighted, the error per tick capped at 12 dB). HH and TOM
  sit in modulator slots, and whether the chip releases those at a key-off is not certain:
  nothing relies on it (no early key-off for the TOM, which dies before the next hit; no HH).

The comparison (first --seconds, the speech's ticks left out of the reference): per channel the
envelopes per tick (msxsound's env_compare: Pearson r, the mean |error| after aligning their
medians, the share of the Amiga's audible ticks covered), the level error (mean |OPLL - target|
per audible tick; the drums over each hit's first 4 ticks), pitch (YIN on the Amiga render vs
the OPLL's note: within 50 cents, the same note name; the misses are TIMPANI's inharmonic
partials and FILTER-WAH's strong 2nd harmonic, read an octave up), the drums' brightness, and
for the mix the chroma similarity.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import msxsound as ms  # noqa: E402  (the Amiga model: Title, Channel, a_ref; WAV and comparison helpers)

ROOT = Path(__file__).resolve().parents[1]
FS, SPT, TICK_HZ = ms.FS, ms.SPT, ms.TICK_HZ
OPLL_FS = 3579545 / 72                  # the OPLL's sample rate: f = F-number * OPLL_FS / 2^(19 - block)

# ---------------------------------------------------------------------------------------------
# The OPLL's instruments
# ---------------------------------------------------------------------------------------------

PRESET_NAMES = ("custom", "violin", "guitar", "piano", "flute", "clarinet", "oboe", "trumpet",
                "organ", "horn", "synthesizer", "harpsichord", "vibraphone", "synth bass",
                "acoustic bass", "electric guitar")
# The ROM patches 1-15 (registers 00h-07h each) as emu2413 1.5 (M. Okazaki) carries them, quoted
# from memory: approximations of the chip's ROM (MAME's and older emu2413 tables differ in a few
# bytes). They only steer the choice of instruments and the previews; the chip plays its own.
PRESET_REGS = (None,
               "71611e17d0780017", "13411a0dd8f72313", "13019900f2c41123", "31610e07a8647027",
               "32211e06e0760028", "31221605e0710018", "21611d0782811107", "33212d13b0700007",
               "61611b0664651017", "41610b1885f08107", "33018311eaef1004", "17c12407f8f82212",
               "61500c05d2f54042", "01015503e9900302", "41418903f1e4c013")
# The rhythm patches (same source): BD on channel 6; HH (modulator) and SD (carrier) on 7; TOM
# (modulator) and TCY (carrier) on 8.
RHYTHM_REGS = {"bd": "0101180fdff86a6d", "hhsd": "01010000c8d8a768", "tomcy": "05010000f8aa5955"}

# Patch fields: name -> (register, shift, mask)
FIELDS = {"mod.am": (0, 7, 1), "mod.vib": (0, 6, 1), "mod.eg": (0, 5, 1), "mod.ksr": (0, 4, 1),
          "mod.mult": (0, 0, 15), "car.am": (1, 7, 1), "car.vib": (1, 6, 1), "car.eg": (1, 5, 1),
          "car.ksr": (1, 4, 1), "car.mult": (1, 0, 15), "mod.ksl": (2, 6, 3), "mod.tl": (2, 0, 63),
          "car.ksl": (3, 6, 3), "car.half": (3, 4, 1), "mod.half": (3, 3, 1), "fb": (3, 0, 7),
          "mod.ar": (4, 4, 15), "mod.dr": (4, 0, 15), "car.ar": (5, 4, 15), "car.dr": (5, 0, 15),
          "mod.sl": (6, 4, 15), "mod.rr": (6, 0, 15), "car.sl": (7, 4, 15), "car.rr": (7, 0, 15)}


def field(regs: bytes, name: str) -> int:
    r, s, m = FIELDS[name]
    return (regs[r] >> s) & m


def with_field(regs: bytes, name: str, v: int) -> bytes:
    r, s, m = FIELDS[name]
    out = bytearray(regs)
    out[r] = (out[r] & ~(m << s)) | ((v & m) << s)
    return bytes(out)


MULT = np.array([0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15])
# Key scale level: dB at block 7 by F-number bits 8-5 (6 dB an octave less per block below);
# KSL 1, 2, 3 take a quarter, a half, all of it (1.5, 3, 6 dB an octave).
KSL_DB = np.array([0, 18, 24, 27.75, 30, 32.25, 33.75, 35.25, 36, 37.5, 38.25, 39, 39.75, 40.5,
                   41.25, 42])
KSL_PART = (0.0, 0.25, 0.5, 1.0)


class Op:
    """One operator of a patch."""

    def __init__(self, regs: bytes, which: str):
        g = lambda f: field(regs, which + "." + f)  # noqa: E731
        self.am, self.vib, self.sustained, self.ksr = g("am"), g("vib"), g("eg"), g("ksr")
        self.mult, self.ksl, self.half = g("mult"), g("ksl"), g("half")
        self.tl = g("tl") if which == "mod" else 0
        self.ar, self.dr, self.sl, self.rr = g("ar"), g("dr"), g("sl"), g("rr")


class Patch:
    """An OPLL instrument (the 8 bytes of registers 00h-07h)."""

    def __init__(self, regs: bytes | str):
        self.regs = bytes.fromhex(regs) if isinstance(regs, str) else bytes(regs)
        self.mod = Op(self.regs, "mod")
        self.car = Op(self.regs, "car")
        self.fb = field(self.regs, "fb")

    def ratio(self) -> float:
        """The sound's fundamental over the channel's frequency (the multipliers' common part:
        0.5 for the synth bass, whose carrier runs at half the frequency)."""
        return math.gcd(int(MULT[self.mod.mult] * 2), int(MULT[self.car.mult] * 2)) / 2

    def describe(self) -> str:
        m, c = self.mod, self.car

        def op(o: Op, name: str) -> str:
            return "%s x%g%s%s%s%s, %s, AR %d DR %d SL %d RR %d%s" % (
                name, MULT[o.mult], ", TL %d (%.2f dB)" % (o.tl, 0.75 * o.tl) if name == "mod" else "",
                ", KSL %d" % o.ksl if o.ksl else "", ", KSR" if o.ksr else "",
                ", half sine" if o.half else "",
                "sustained" if o.sustained else "percussive", o.ar, o.dr, o.sl, o.rr,
                "".join(", " + x for x, on in (("vibrato", o.vib), ("tremolo", o.am)) if on))
        return "%s; %s; feedback %d" % (op(m, "mod"), op(c, "car"), self.fb)


PRESETS = [None] + [Patch(r) for r in PRESET_REGS[1:]]


def fnum_block(f: float) -> tuple[int, int]:
    """The F-number and block nearest to frequency f with the most precision (the smallest
    block whose F-number fits 9 bits)."""
    for b in range(8):
        fn = int(round(f * 2 ** (19 - b) / OPLL_FS))
        if fn <= 511:
            return max(fn, 1), b
    return 511, 7


def opll_hz(fn, block):
    return np.asarray(fn) * 2.0 ** np.asarray(block) * OPLL_FS / 2 ** 19


# ---------------------------------------------------------------------------------------------
# The envelope generator (in steps of 0.375 dB: 0 the loudest, 127 silent)
# ---------------------------------------------------------------------------------------------

EG_DB = 0.375
EG_MUTE = 127                           # the attenuation (EG + TL + KSL) saturates here (-47.6 dB)
EG_MAX = 123                            # an operator whose EG reaches this is silent
ATTACK_S = 1.73015                      # 0 -> 100 % attack at rate 4 (the YM2413 manual's table)
ATT_BASE = 131 / 4                      # eg = 131 * ATT_BASE^(-t / T) - 4: from 127 to 0 in T
DAMP_RATE = 12                          # a key-on first damps the sounding note at this rate
AM_UNITS, AM_HZ = 13, 3.7               # tremolo: up to 4.875 dB at 3.7 Hz
PM_HZ = 6.4                             # vibrato: F-number +-(fnum >> 6) / 2 at 6.4 Hz
RELEASE_HOLD = -1                       # a melodic modulator's EG holds after the key-off


def rks_of(op: Op, fnum: int, block: int) -> int:
    """Rate key scaling: (block, F-number bit 8), all of it with KSR, else its top two bits."""
    return ((block << 1) | (fnum >> 8)) >> (0 if op.ksr else 2)


def eff_rate(rate: int, rks: int) -> int:
    return 0 if rate == 0 else min(63, 4 * rate + rks)


def steps_per_s(R: int) -> float:
    """EG steps a second at effective rate R (0..63): rate 4 takes 20.9 s for 127 steps, each
    rate step 2^(1/4) faster (the manual's decay table)."""
    if R <= 0:
        return 0.0
    return OPLL_FS * 2.0 ** ((R >> 2) - 13) * (4 + (R & 3)) / 8


def attack_s(R: int) -> float:
    if R <= 0:
        return math.inf
    if R >= 60:
        return 0.0
    return ATTACK_S * 2.0 ** (1 - (R >> 2)) * 4 / (4 + (R & 3))


def ksl_units(op: Op, fnum: int, block: int) -> float:
    if not op.ksl:
        return 0.0
    db = max(0.0, KSL_DB[fnum >> 5] - 6.0 * (7 - block))
    return db * KSL_PART[op.ksl] / EG_DB


def release_rate(op: Op, sus: int, carrier: bool) -> int:
    """Rate after the key-off: 5 with the sustain bit, else RR for a sustained patch and 7 for a
    percussive one (the manual's table); a melodic modulator holds its level."""
    if not carrier:
        return RELEASE_HOLD
    return 5 if sus else (op.rr if op.sustained else 7)


def op_eg(op: Op, rks: int, t: np.ndarray, t_off: float | None, rel: int) -> np.ndarray:
    """The EG of an operator at times t (seconds from its attack's start; silent before): the
    attack from 127 to 0, the decay to SL x 8 at DR, then holding (sustained patches) or going on
    at RR (percussive ones); from t_off (the key-off; None: never) the release at rate `rel`."""
    t = np.asarray(t, dtype=float)
    eg = np.full(t.shape, float(EG_MUTE))
    ta = attack_s(eff_rate(op.ar, rks))
    if not math.isinf(ta):
        fd = steps_per_s(eff_rate(op.dr, rks))
        slu = 8.0 * op.sl
        fsus = 0.0 if op.sustained else steps_per_s(eff_rate(op.rr, rks))
        td = 0.0 if slu == 0 else (slu / fd if fd > 0 else math.inf)
        live = t >= 0
        if ta > 0:
            a = live & (t < ta)
            eg[a] = np.maximum(0.0, 131 * ATT_BASE ** (-t[a] / ta) - 4)
        else:
            a = np.zeros(t.shape, bool)
        u = t - ta
        d = live & ~a & (u < td)
        eg[d] = u[d] * fd
        s = live & ~a & (u >= td)
        eg[s] = slu + (u[s] - td) * fsus
        np.minimum(eg, EG_MUTE, out=eg)
    if t_off is not None:
        r = t >= t_off
        if np.any(r):
            e0 = float(op_eg(op, rks, np.array([t_off]), None, rel)[0])
            if rel == RELEASE_HOLD:
                eg[r] = e0
            else:
                eg[r] = np.minimum(EG_MUTE, e0 + (t[r] - t_off) * steps_per_s(eff_rate(rel, rks)))
    return eg


def att_amp(att: np.ndarray, eg: np.ndarray) -> np.ndarray:
    """Linear amplitude of an operator: its EG + TL + KSL (+ tremolo) in 0.375 dB steps,
    saturating at EG_MUTE; silent once the EG itself reaches EG_MAX."""
    return np.where(eg < EG_MAX, 10.0 ** (-EG_DB / 20 * np.minimum(att, EG_MUTE)), 0.0)


def lfo_am(t: np.ndarray) -> np.ndarray:
    x = (t * AM_HZ) % 1.0
    return AM_UNITS * (1 - np.abs(2 * x - 1))


def lfo_pm(t: np.ndarray) -> np.ndarray:
    x = (t * PM_HZ) % 1.0
    return 1 - np.abs(((4 * x + 1) % 4) - 2)            # a triangle -1..1 starting at 0


# ---------------------------------------------------------------------------------------------
# Operators
# ---------------------------------------------------------------------------------------------

class FbTable:
    """A self-fed operator's waveform: one cycle of y_n = w(2 pi phi_n + beta / 2 (y_{n-1} +
    y_{n-2})) (the chip feeds back the mean of the last two outputs) for a grid of beta, the
    feedback's swing in radians at the operator's amplitude a: 4 pi a 2^(FB - 7); run at 256
    samples a cycle until steady (above beta ~2 the real chip's output turns noisy: here one
    cycle of it repeats)."""

    BETA = np.concatenate([np.linspace(0.0, 2.0, 81), np.linspace(2.05, 4 * np.pi, 120)])

    def __init__(self, half: bool):
        n_c, cycles = 256, 16
        b = self.BETA
        y1 = np.zeros(len(b))
        y2 = np.zeros(len(b))
        cyc = np.zeros((len(b), n_c))
        for k in range(n_c * cycles):
            y = np.sin(2 * np.pi * (k % n_c) / n_c + 0.5 * b * (y1 + y2))
            if half:
                y = np.maximum(y, 0.0)
            y2, y1 = y1, y
            if k >= n_c * (cycles - 1):
                cyc[:, k % n_c] = y
        x = np.arange(1024) * (n_c / 1024)
        grid = np.arange(n_c + 1)
        self.tab = np.array([np.interp(x, grid, np.append(r, r[0])) for r in cyc])
        self.idx = np.arange(len(b), dtype=float)

    def lookup(self, beta: np.ndarray, phase: np.ndarray) -> np.ndarray:
        fi = np.interp(beta, self.BETA, self.idx)
        i0 = np.minimum(fi.astype(np.int64), len(self.BETA) - 2)
        u = fi - i0
        p = (np.mod(phase, 1.0) * 1024).astype(np.int64) & 1023
        return (1 - u) * self.tab[i0, p] + u * self.tab[i0 + 1, p]


_FBT: dict[bool, FbTable] = {}


def fb_table(half: bool) -> FbTable:
    if half not in _FBT:
        _FBT[half] = FbTable(half)
    return _FBT[half]


def wave(theta: np.ndarray, half: bool) -> np.ndarray:
    s = np.sin(theta)
    return np.maximum(s, 0.0) if half else s


def fm_voice(p: Patch, t_abs: np.ndarray, f_ch: np.ndarray, fnum: np.ndarray, eg_m: np.ndarray,
             eg_c: np.ndarray, tl_m: float, tl_c: np.ndarray) -> np.ndarray:
    """A two-operator voice from its attack's start: the modulator (with its feedback) shifts
    the carrier's phase by 8 pi times its output (the chip's 13-bit output against its 10-bit
    phase); both phases start at 0. t_abs: absolute times (the LFOs), f_ch: the channel's
    frequency per sample, tl_m / tl_c: the operators' attenuation besides the EG (0.375 dB
    steps: TL and KSL; the carrier's from the volume)."""
    m, c = p.mod, p.car
    fm = f_ch * MULT[m.mult]
    fc = f_ch * MULT[c.mult]
    if m.vib or c.vib:
        dev = 1 + (np.right_shift(fnum.astype(np.int64), 6) / (2.0 * np.maximum(fnum, 1))) * lfo_pm(t_abs)
        if m.vib:
            fm = fm * dev
        if c.vib:
            fc = fc * dev
    ph_m = (np.cumsum(fm) - fm[0]) / FS
    ph_c = (np.cumsum(fc) - fc[0]) / FS
    att_m = eg_m + tl_m + (lfo_am(t_abs) if m.am else 0.0)
    a_m = att_amp(att_m, eg_m)
    if p.fb:
        beta = 4 * np.pi * a_m * 2.0 ** (p.fb - 7)
        y_m = a_m * fb_table(bool(m.half)).lookup(beta, ph_m)
    else:
        y_m = a_m * wave(2 * np.pi * ph_m, bool(m.half))
    att_c = eg_c + tl_c + (lfo_am(t_abs) if c.am else 0.0)
    return att_amp(att_c, eg_c) * wave(2 * np.pi * ph_c + 8 * np.pi * y_m, bool(c.half))


_POWER: dict[bytes, np.ndarray] = {}


def power_table(p: Patch) -> np.ndarray:
    """AC power of a patch's output at full carrier level, by the modulator's attenuation
    (0..127 steps of 0.375 dB): one period of the sound (all the multipliers are whole or
    half numbers) computed exactly; with phase modulation it is not a constant (a half-sine
    carrier under 1:1 modulation is on for less than half the period)."""
    if p.regs in _POWER:
        return _POWER[p.regs]
    r = p.ratio()
    x = np.arange(1024) / 1024
    ph_m = MULT[p.mod.mult] / r * x
    ph_c = MULT[p.car.mult] / r * x
    a = 10.0 ** (-EG_DB / 20 * np.arange(EG_MUTE + 1))[:, None]
    if p.fb:
        beta = 4 * np.pi * a * 2.0 ** (p.fb - 7)
        y = a * fb_table(bool(p.mod.half)).lookup(np.broadcast_to(beta, (len(a), 1024)),
                                                  np.broadcast_to(ph_m, (len(a), 1024)))
    else:
        y = a * wave(2 * np.pi * ph_m, bool(p.mod.half))[None, :]
    w = wave(2 * np.pi * ph_c[None, :] + 8 * np.pi * y, bool(p.car.half))
    out = (w ** 2).mean(axis=1) - w.mean(axis=1) ** 2
    _POWER[p.regs] = out
    return out


# ---------------------------------------------------------------------------------------------
# A melodic channel as the chip plays the register states
# ---------------------------------------------------------------------------------------------

EG_SUB = 49                             # EG points per tick in the level model


class Melodic:
    """One melodic OPLL channel playing per-tick register states (key, retrig, fnum, block,
    inst, sus, vol): a note starts at a key-on or a retrigger; the sounding note is first damped
    (its EG rises at rate 12 to EG_MAX: up to ~10 ms) and the new one attacks from silence with
    both phases at 0; the key-off releases the carrier (the modulator holds)."""

    def __init__(self, st: dict, patches: list):
        self.st = st
        key, retrig = st["key"], st["retrig"]
        T = self.T = len(key)
        starts = [t for t in range(T) if key[t] and (retrig[t] or t == 0 or not key[t - 1])]
        self.notes = []
        for j, s in enumerate(starts):
            e = starts[j + 1] if j + 1 < len(starts) else T
            off = next((t for t in range(s + 1, e) if not key[t]), None)
            p = patches[int(st["inst"][s])]
            fn, bl = int(st["fnum"][s]), int(st["block"][s])
            self.notes.append({
                "s": s, "end": e, "off": off, "p": p, "fn": fn, "bl": bl,
                "rks_m": rks_of(p.mod, fn, bl), "rks_c": rks_of(p.car, fn, bl),
                "tl_m": 2 * p.mod.tl + ksl_units(p.mod, fn, bl), "ksl_c": ksl_units(p.car, fn, bl),
                "sus": int(st["sus"][off]) if off is not None else 0, "last": j + 1 == len(starts)})
        prev = None
        for n in self.notes:
            t0 = n["s"] / TICK_HZ
            d = 0.0
            if prev is not None:
                ec = float(self._eg(prev, np.array([t0]), True, tail=False)[0])
                prev["tail_c"] = ec
                prev["tail_m"] = float(self._eg(prev, np.array([t0]), False, tail=False)[0])
                if ec < EG_MAX:
                    d = (EG_MAX - ec) / steps_per_s(eff_rate(DAMP_RATE, prev["rks_c"]))
            n["a"] = t0 + d
            prev = n

    def _eg(self, n: dict, tau: np.ndarray, carrier: bool, tail: bool = True) -> np.ndarray:
        """EG of note n's carrier or modulator at absolute times tau (s)."""
        op = n["p"].car if carrier else n["p"].mod
        rks = n["rks_c"] if carrier else n["rks_m"]
        t_off = n["off"] / TICK_HZ - n["a"] if n["off"] is not None else None
        eg = op_eg(op, rks, tau - n["a"], t_off, release_rate(op, n["sus"], carrier))
        if tail and not n["last"]:
            t_next = n["end"] / TICK_HZ
            m = tau >= t_next
            if np.any(m):
                e0 = n["tail_c"] if carrier else n["tail_m"]
                eg[m] = np.minimum(EG_MUTE, e0 + (tau[m] - t_next) * steps_per_s(eff_rate(DAMP_RATE, rks)))
        return eg

    def _spans(self, times: np.ndarray):
        """(note, index range into the sorted `times`) of each note: from its attack's start to
        the next one's."""
        for j, n in enumerate(self.notes):
            a = np.searchsorted(times, n["a"])
            b = np.searchsorted(times, self.notes[j + 1]["a"]) if j + 1 < len(self.notes) else len(times)
            if b > a:
                yield n, a, b

    def levels(self) -> np.ndarray:
        """L[t, v]: the channel's output level in tick t (dB, full scale 1, RMS) with volume v:
        the carrier's EG at EG_SUB points a tick, the patch's power at the modulator's level."""
        T = self.T
        tau = (np.arange(T * EG_SUB) + 0.5) / (EG_SUB * TICK_HZ)
        pw = np.zeros(len(tau))
        ec = np.full(len(tau), float(EG_MUTE))
        for n, a, b in self._spans(tau):
            x = tau[a:b]
            c = self._eg(n, x, True)
            m = self._eg(n, x, False)
            am = np.clip(np.rint(m + n["tl_m"]), 0, EG_MUTE).astype(np.int64)
            am[m >= EG_MAX] = EG_MUTE
            pw[a:b] = power_table(n["p"])[am] * (c < EG_MAX)
            ec[a:b] = c + n["ksl_c"]
        out = np.empty((T, 16))
        for v in range(16):
            p = pw * 10.0 ** (-EG_DB / 10 * np.minimum(ec + 8 * v, EG_MUTE))
            out[:, v] = 10 * np.log10(np.maximum(p.reshape(T, EG_SUB).mean(axis=1), 1e-30))
        return out

    def render(self, t1: int | None = None) -> np.ndarray:
        """The channel's output at FS (full scale 1) for ticks 0..t1-1."""
        t1 = self.T if t1 is None else t1
        N = t1 * SPT
        out = np.zeros(N)
        tau = np.arange(N) / FS
        tick = np.minimum(np.arange(N) // SPT, self.T - 1)
        fn = np.asarray(self.st["fnum"])[tick]
        f_ch = opll_hz(fn, np.asarray(self.st["block"])[tick])
        vol = np.asarray(self.st["vol"])[tick].astype(float)
        for n, a, b in self._spans(tau):
            x = tau[a:b]
            eg_c = self._eg(n, x, True)
            eg_m = self._eg(n, x, False)
            out[a:b] = fm_voice(n["p"], x, f_ch[a:b], fn[a:b], eg_m, eg_c, n["tl_m"],
                                8 * vol[a:b] + n["ksl_c"])
        return out

    def hz(self) -> np.ndarray:
        """The pitch per tick (the sound's fundamental; 0 when the key is off)."""
        st = self.st
        out = np.zeros(self.T)
        for n in self.notes:
            e = n["off"] if n["off"] is not None else n["end"]
            r = n["p"].ratio()
            for t in range(n["s"], e):
                out[t] = float(opll_hz(st["fnum"][t], st["block"][t])) * r
        return out


# ---------------------------------------------------------------------------------------------
# The rhythm section
# ---------------------------------------------------------------------------------------------

RHYTHM = (("bd", 0x10), ("sd", 0x08), ("tom", 0x04), ("tcy", 0x02), ("hh", 0x01))   # 0Eh bits
RHYTHM_GAIN = 2.0                       # the chip outputs each rhythm sound twice (two DAC slots)
HH_HI, HH_LO = math.sin(2 * math.pi * 0xD0 / 1024), math.sin(2 * math.pi * 0x34 / 1024)
NOISE_SEED = 2413


def slot_patch(regs: str, slot: str) -> Patch:
    """A patch playing one rhythm slot as its carrier (its modulator silent): the slot's
    multiplier, KSR, EG type, KSL, rates and levels."""
    r = bytes.fromhex(regs)
    if slot == "mod":
        b = bytes([0x00, r[0], 63, (r[2] & 0xC0) | ((r[3] & 0x08) << 1), 0x00, r[4], 0x00, r[6]])
    else:
        b = bytes([0x00, r[1], 63, r[3] & 0xD0, 0x00, r[5], 0x00, r[7]])
    return Patch(b)


RHYTHM_PATCH = {"bd": Patch(RHYTHM_REGS["bd"]), "sd": slot_patch(RHYTHM_REGS["hhsd"], "car"),
                "hh": slot_patch(RHYTHM_REGS["hhsd"], "mod"),
                "tom": slot_patch(RHYTHM_REGS["tomcy"], "mod"),
                "tcy": slot_patch(RHYTHM_REGS["tomcy"], "car")}
RHYTHM_CH = {"bd": 0, "sd": 1, "hh": 1, "tom": 2, "tcy": 2}      # channel 6, 7, 8


def rhythm_volume(name: str, v36: int, v37: int, v38: int) -> int:
    return {"bd": v36 & 15, "hh": v37 >> 4, "sd": v37 & 15, "tom": v38 >> 4, "tcy": v38 & 15}[name]


def pitch_regs_hz(regs: bytes) -> list[tuple[int, int, float, int]]:
    """(F-number, block, Hz, sustain bit) of channels 6-8 from the 6 rhythm pitch registers
    (16h-18h, 26h-28h)."""
    out = []
    for c in range(3):
        fn = regs[c] | ((regs[3 + c] & 1) << 8)
        bl = (regs[3 + c] >> 1) & 7
        out.append((fn, bl, float(opll_hz(fn, bl)), (regs[3 + c] >> 5) & 1))
    return out


def pitch_regs(fbs: list[tuple[int, int]], sus: tuple[int, int, int]) -> bytes:
    """16h-18h, 26h-28h from channels 6-8's (F-number, block) and sustain bits (key bits off)."""
    return bytes([fn & 0xFF for fn, _ in fbs] +
                 [(s << 5) | (b << 1) | (fn >> 8) for (fn, b), s in zip(fbs, sus)])


class RhythmVoice(Melodic):
    """One rhythm sound: its slot's EG as a melodic carrier's (struck = a key-on, the next
    record's start = its key-off), its waveform: BD a two-operator voice, TOM a sine, SD the
    HH slot's phase bit 8 against the noise, HH its phase bits with channel 8's against the
    noise (the chip's rhythm logic; TCY is never struck here)."""

    def __init__(self, name: str, st: dict, chans: list[tuple[int, int, float]]):
        self.name = name
        self.chans = chans
        super().__init__(st, [RHYTHM_PATCH[name]])

    def render(self, t1: int | None = None) -> np.ndarray:
        if self.name in ("bd", "tom"):
            return super().render(t1)
        t1 = self.T if t1 is None else t1
        N = t1 * SPT
        tau = np.arange(N) / FS
        vol = np.asarray(self.st["vol"])[np.minimum(np.arange(N) // SPT, self.T - 1)].astype(float)
        p_hh = (np.mod(self.chans[1][2] * tau, 1.0) * 1024).astype(np.int64)
        p_tc = (np.mod(self.chans[2][2] * tau, 1.0) * 1024).astype(np.int64)
        noise = np.random.default_rng(NOISE_SEED).integers(0, 2, N)
        if self.name == "sd":
            b8 = (p_hh >> 8) & 1
            w = np.where(b8 == 0, noise, noise - 1).astype(float)
        else:
            rm = (((p_hh >> 2) ^ (p_hh >> 7)) | ((p_hh >> 3) ^ (p_tc >> 5)) | ((p_tc >> 3) ^ (p_tc >> 5))) & 1
            w = np.where(rm, -1.0, 1.0)
            if self.name == "hh":
                w = w * np.where(rm ^ noise, HH_HI, HH_LO)
        amp = np.zeros(N)
        for n, a, b in self._spans(tau):
            eg = self._eg(n, tau[a:b], True)
            amp[a:b] = att_amp(eg + 8 * vol[a:b] + n["ksl_c"], eg)
        return amp * w


class Rhythm:
    """The rhythm section playing the decoded per-tick states: rec (a record starts: all keys
    off, then the struck ones on), keys (struck), v36 / v37 / v38 (the volume registers)."""

    def __init__(self, st: dict, pitch: bytes):
        self.st = st
        self.chans = pitch_regs_hz(pitch)
        T = self.T = len(st["rec"])
        self.voices = {}
        for name, bit in RHYTHM:
            struck = np.array([bool(st["rec"][t] and st["keys"][t] & bit) for t in range(T)])
            if not struck.any():
                continue
            key = np.zeros(T, bool)
            on = False
            for t in range(T):
                if st["rec"][t]:
                    on = bool(st["keys"][t] & bit)
                key[t] = on
            fn, bl, _, sus = self.chans[RHYTHM_CH[name]]
            vol = np.array([rhythm_volume(name, st["v36"][t], st["v37"][t], st["v38"][t]) for t in range(T)])
            sv = {"key": key, "retrig": struck, "fnum": np.full(T, fn), "block": np.full(T, bl),
                  "inst": np.zeros(T, int), "sus": np.full(T, sus), "vol": vol}
            self.voices[name] = RhythmVoice(name, sv, self.chans)

    def render(self, t1: int | None = None) -> np.ndarray:
        t1 = self.T if t1 is None else t1
        out = np.zeros(t1 * SPT)
        for v in self.voices.values():
            out += RHYTHM_GAIN * v.render(t1)
        return out


def hit_levels(name: str, chans: list[tuple[int, int, float, int]], n: int, off: int | None) -> np.ndarray:
    """L[t, v] (dB, with the rhythm's gain) of one hit of a rhythm sound struck at tick 0 and
    keyed off at tick `off` (None: never), over n ticks."""
    fn, bl, _, sus = chans[RHYTHM_CH[name]]
    key = np.zeros(n, bool)
    key[:off if off is not None else n] = True
    retrig = np.zeros(n, bool)
    retrig[0] = True
    sv = {"key": key, "retrig": retrig, "fnum": np.full(n, fn), "block": np.full(n, bl),
          "inst": np.zeros(n, int), "sus": np.full(n, sus), "vol": np.zeros(n, int)}
    return Melodic(sv, [RHYTHM_PATCH[name]]).levels() + 20 * math.log10(RHYTHM_GAIN)


# ---------------------------------------------------------------------------------------------
# Levels: the error the encoder minimises
# ---------------------------------------------------------------------------------------------

SINE_DB = 20 * math.log10(math.sqrt(0.5))   # a full-level sine (RMS)


def tick_cost(L: np.ndarray, tgt: np.ndarray, ref: float, floor: float) -> np.ndarray:
    """C[t, v]: the loudness-weighted squared level error (in 3 dB steps) of each tick at each
    volume; target -inf = silence: the error is then what leaks above the floor (a release
    tail), weighted by its own loudness."""
    Lc = np.maximum(L, floor)
    aud = np.isfinite(tgt)
    tg = np.where(aud, tgt, floor)[:, None]
    w_a = 10 ** (0.6 * (tg - ref) / 20)
    w_s = 10 ** (0.6 * (Lc - ref) / 20)
    return np.where(aud[:, None], w_a * ((Lc - tg) / 3) ** 2, w_s * ((Lc - floor) / 3) ** 2)


def choose_volumes(C: np.ndarray, fixed: np.ndarray, lam: float) -> np.ndarray:
    """The volume of each tick minimising sum(C[t, v]) + lam x bytes: a volume change costs a
    record (2 bytes) unless a record starts there anyway (fixed: a note, a key-off, a new
    F-number or instrument)."""
    T = len(C)
    vv = np.arange(16)
    change = 2.0 * lam * (vv[:, None] != vv[None, :])
    cost = C[0].copy()
    back = np.zeros((T, 16), np.int8)
    for t in range(1, T):
        if fixed[t]:
            b = int(np.argmin(cost))
            back[t] = b
            cost = cost[b] + C[t]
        else:
            m = cost[:, None] + change
            b = np.argmin(m, axis=0)
            back[t] = b
            cost = m[b, vv] + C[t]
    v = np.zeros(T, np.int64)
    v[-1] = int(np.argmin(cost))
    for t in range(T - 1, 0, -1):
        v[t - 1] = back[t, v[t]]
    return v


# ---------------------------------------------------------------------------------------------
# Timbre
# ---------------------------------------------------------------------------------------------

WINDOWS = ((0, 2), (2, 6), (6, 12), (12, 24), (24, 48), (48, 96))   # ticks from the key-on
BANDS = (0.5, 1.5, 2.5, 3.5, 4.5, 6.5, 8.5, 12.5, 16.5, 24.5, 32.5)  # harmonics (x f0)
F_TOP = 5000.0                          # compared up to here (and 0.45 x the sample's rate)
BAND_FLOOR = -40.0


def band_db(x: np.ndarray, f0: float, fmax: float) -> np.ndarray | None:
    """Power of a frame in harmonic bands of f0 (dB re the bands' total, floor -40)."""
    if len(x) < 64 or not np.any(x):
        return None
    n = 1 << max(13, math.ceil(math.log2(len(x))))
    X = np.abs(np.fft.rfft((x - x.mean()) * np.hanning(len(x)), n)) ** 2
    cs = np.concatenate([[0.0], np.cumsum(X)])
    edges = [b * f0 for b in BANDS if b * f0 < fmax] + [min(fmax, BANDS[-1] * f0)]
    if len(edges) < 3:
        edges = [0.5 * f0, 1.5 * f0, max(fmax, 2.5 * f0)]
    k = np.clip(np.round(np.array(edges) * n / FS).astype(np.int64), 0, len(X))
    p = np.diff(cs[k])
    tot = p.sum()
    if tot <= 1e-20:
        return None
    return np.maximum(10 * np.log10(np.maximum(p / tot, 1e-30)), BAND_FLOOR)


def band_distance(a: np.ndarray, b: np.ndarray) -> float:
    """Mean |dB| difference of two band profiles, each band weighted by its amplitude share in
    either (a missing or an extra band counts alike)."""
    w = 10 ** (a / 20) + 10 ** (b / 20)
    return float((w * np.abs(a - b)).sum() / w.sum())


# ---------------------------------------------------------------------------------------------
# The title music (TITM tune 1) on the OPLL
# ---------------------------------------------------------------------------------------------

TIMBRE_FIELDS = ("mod.mult", "car.mult", "mod.tl", "fb", "mod.half", "car.half", "mod.ar", "mod.dr",
                 "mod.sl", "mod.rr", "mod.eg", "mod.ksr", "mod.ksl")
ENV_FIELDS = ("car.ar", "car.dr", "car.sl", "car.rr", "car.eg", "car.ksr")
REPS = 4                                # representative notes per instrument (timbre)
LFO_PENALTY = 1.0                       # dB added to the timbre score per carrier LFO (half per
                                        # modulator LFO): no sample has a vibrato or a tremolo
TAIL = 25                               # ticks of release scored after a note's sound ends
PREV_MAX = 24                           # ticks of a retriggered note simulated before a note
FIT_SEEDS = 3                           # presets a custom patch's fit starts from
FIT_SWEEPS = 4
DRUMS = {"BDRM": "bd", "SNARE": "sd", "TOM1": "tom"}
EARLY_OFF = ("bd", "sd")                # carrier slots: a key-off record may lengthen their tail
EARLY_OFF_MAX = 8                       # ticks after the hit
DRUM_WIN = 4                            # a hit's loudness: its energy over its first 80 ms
DRUM_CAP = 4                            # its shape error per tick saturates at 4 steps (12 dB)


def single_note(n_on: int, n: int, fn: int, bl: int) -> dict:
    """Register states of one note: key on for n_on ticks of n, struck at tick 0, volume 0."""
    key = np.zeros(n, bool)
    key[:n_on] = True
    retrig = np.zeros(n, bool)
    retrig[0] = True
    return {"key": key, "retrig": retrig, "fnum": np.full(n, fn), "block": np.full(n, bl),
            "inst": np.zeros(n, int), "sus": np.zeros(n, int), "vol": np.zeros(n, int)}


class FmTitle:
    """TITM tune 1 on the OPLL: Amiga channels 0-2 on melodic channels 0-2 (instruments chosen
    and the custom patch fitted here), channel 3 on the rhythm section."""

    def __init__(self, rep: dict, data: bytes, log=print):
        self.log = log
        ti = self.ti = ms.Title(rep, data)
        self.T = ti.T
        self.chans = ti.chans
        self.insts = ti.insts
        self.a_ref = ti.a_ref
        top = max(20 * math.log10(float(c.amp.max()) / ti.a_ref) for c in ti.chans[:3])
        self.ref = SINE_DB - max(0.0, top)          # the loudest melodic tick = a full sine
        self.floor = self.ref + ms.FLOOR_DB
        self.mel = sorted(i for i in ti.pitch if ti.pitch[i][0] > 0 and i != ms.SPEECH_INST)
        self._amiga()
        tot = sum(float(self._w(c, self.aud[c]).sum()) for c in range(3))
        self.importance = {i: sum(float(self._w(c, self.aud[c] & (self.chans[c].ins == i)).sum())
                                  for c in range(3)) / tot for i in self.mel}
        self.reps = {i: self._reps(i) for i in self.mel}
        self._lcache: dict = {}

    def _w(self, c: int, mask: np.ndarray) -> np.ndarray:
        return 10 ** (0.6 * (self.tgt[c][mask] - self.ref) / 20)

    def _amiga(self) -> None:
        """Per melodic channel and tick: audible (an instrument of channels 0-2 other than the
        speech, above the floor), the target level, the true pitch; the notes (a key-on, or the
        sound resuming after silence, to the next one)."""
        T = self.T
        self.aud, self.tgt, self.f0, self.notes = [], [], [], []
        for c in range(3):
            ch = self.chans[c]
            aud = np.zeros(T, bool)
            tgt = np.full(T, -np.inf)
            f0 = np.zeros(T)
            for t in range(T):
                i = int(ch.ins[t])
                if ch.amp[t] <= 0 or i not in self.mel or ch.per[t] <= 1:
                    continue
                lv = 20 * math.log10(ch.amp[t] / self.a_ref)
                if lv <= ms.FLOOR_DB:
                    continue
                aud[t] = True
                tgt[t] = lv + self.ref
                f0[t] = ms.PAULA_HZ / (max(ch.per[t], ms.DMA_PERIOD) * self.ti.pitch[i][0])
            start = aud & (ch.keyon | ~np.concatenate([[False], aud[:-1]]))
            starts = list(np.nonzero(start)[0])
            notes = []
            for j, s in enumerate(starts):
                e = int(starts[j + 1]) if j + 1 < len(starts) else T
                n = 1
                while s + n < e and aud[s + n]:
                    n += 1
                notes.append({"c": c, "s": int(s), "e": e, "n": n, "i": int(ch.ins[s])})
            self.aud.append(aud)
            self.tgt.append(tgt)
            self.f0.append(f0)
            self.notes.append(notes)

    def _reps(self, i: int) -> list[dict]:
        """The instrument's most frequent (period, length) notes, their Amiga band profiles per
        window."""
        notes = [nt for c in range(3) for nt in self.notes[c] if nt["i"] == i]
        cnt: dict = {}
        for nt in notes:
            k = (int(self.chans[nt["c"]].per[nt["s"]]), nt["n"])
            cnt.setdefault(k, []).append(nt)
        out = []
        for k, group in sorted(cnt.items(), key=lambda kv: -len(kv[1]))[:REPS]:
            nt = group[0]
            ch = self.chans[nt["c"]]
            n = min(nt["n"], WINDOWS[-1][1])
            x = ch.render(nt["s"], nt["s"] + n)
            f0 = float(self.f0[nt["c"]][nt["s"]])
            fmax = min(F_TOP, 0.45 * ch.rate[nt["s"]])
            wins = []
            for w0, w1 in WINDOWS:
                if w0 >= n:
                    break
                seg = x[w0 * SPT:min(w1, n) * SPT]
                b = band_db(seg, f0, fmax)
                if b is not None:
                    wins.append((w0, min(w1, n), b, float((seg ** 2).sum())))
            out.append({"n": n, "f0": f0, "fmax": fmax, "weight": len(group), "wins": wins})
        return out

    # ---- scores ----

    def timbre(self, i: int, p: Patch) -> float:
        """Band-profile distance (dB) of patch p against instrument i's representative notes,
        plus LFO_PENALTY per LFO the patch adds (the samples' pitch varies by 2-4 cents, 7-10
        for TIMPANI and PIZZICATO; the chip's vibrato swings 13 cents, its tremolo 4.9 dB)."""
        tot = wsum = 0.0
        lfo = LFO_PENALTY * (p.car.vib + p.car.am + 0.5 * (p.mod.vib + p.mod.am))
        for r in self.reps[i]:
            fn, bl = fnum_block(r["f0"] / p.ratio())
            y = Melodic(single_note(r["n"], r["n"], fn, bl), [p]).render()
            d = e = 0.0
            for w0, w1, a, energy in r["wins"]:
                b = band_db(y[w0 * SPT:w1 * SPT], r["f0"], r["fmax"])
                d += energy * (band_distance(a, b) if b is not None else -BAND_FLOOR)
                e += energy
            if e > 0:
                tot += r["weight"] * d / e
                wsum += r["weight"]
        return (tot / wsum if wsum else 0.0) + lfo

    def _levels(self, p: Patch, fn: int, bl: int, n_on: int, n: int, n_prev: int) -> np.ndarray:
        """Levels of a note (n_on ticks keyed on, n in all) with patch p, after n_prev ticks of
        a note it retriggers (its damp delays the attack)."""
        k = (p.regs, rks_of(p.car, fn, bl), rks_of(p.mod, fn, bl),
             round(ksl_units(p.mod, fn, bl)), round(ksl_units(p.car, fn, bl)), n_on, n, n_prev)
        L = self._lcache.get(k)
        if L is None:
            st = single_note(n_on, n, fn, bl)
            if n_prev:
                pre = single_note(n_prev, n_prev, fn, bl)
                st = {f: np.concatenate([pre[f], st[f]]) for f in st}
            L = Melodic(st, [p]).levels()[n_prev:]
            self._lcache[k] = L
        return L

    def env(self, i: int, p: Patch) -> float:
        """RMS level error (dB) of instrument i's notes played with patch p, each tick at its
        best volume; a note that retriggers a sounding one is preceded by it (as long, up to
        PREV_MAX ticks, on the same patch: the damp)."""
        err = wsum = 0.0
        for c in range(3):
            for j, nt in enumerate(self.notes[c]):
                if nt["i"] != i:
                    continue
                s = nt["s"]
                n = min(nt["e"] - s, nt["n"] + TAIL)
                fn, bl = fnum_block(self.f0[c][s] / p.ratio())
                pv = self.notes[c][j - 1] if j else None
                n_prev = min(pv["n"], PREV_MAX) if pv and pv["s"] + pv["n"] == s else 0
                C = tick_cost(self._levels(p, fn, bl, nt["n"], n, n_prev), self.tgt[c][s:s + n],
                              self.ref, self.floor)
                err += float(C.min(axis=1).sum())
                wsum += float((10 ** (0.6 * (self.tgt[c][s:s + nt["n"]] - self.ref) / 20)).sum())
        return 3 * math.sqrt(err / wsum) if wsum else 0.0

    def score(self, i: int, p: Patch) -> tuple[float, float]:
        return self.timbre(i, p), self.env(i, p)

    # ---- the custom patch ----

    def fit_custom(self, i: int, seeds: list[int]) -> tuple[Patch, float, float]:
        """Coordinate descent from each seed preset: first the timbre fields (multipliers,
        modulator level, feedback, waveforms, the modulator's envelope) on the band profiles,
        then the carrier's envelope on the levels. AM, vibrato and the carrier's KSL are off."""
        best = None
        for seed in seeds:
            regs = PRESETS[seed].regs
            for f in ("mod.am", "mod.vib", "car.am", "car.vib", "car.ksl"):
                regs = with_field(regs, f, 0)
            cur = self.timbre(i, Patch(regs))
            for _ in range(FIT_SWEEPS):
                moved = False
                for f in TIMBRE_FIELDS:
                    for v in range(FIELDS[f][2] + 1):
                        if v == field(regs, f):
                            continue
                        cand = with_field(regs, f, v)
                        sc = self.timbre(i, Patch(cand))
                        if sc < cur - 1e-4:
                            cur, regs, moved = sc, cand, True
                if not moved:
                    break
            e = self.env(i, Patch(regs))
            for _ in range(FIT_SWEEPS):
                moved = False
                for f in ENV_FIELDS:
                    for v in range(FIELDS[f][2] + 1):
                        if v == field(regs, f):
                            continue
                        cand = with_field(regs, f, v)
                        sc = self.env(i, Patch(cand))
                        if sc < e - 1e-4:
                            e, regs, moved = sc, cand, True
                if not moved:
                    break
            if best is None or cur + e < best[1] + best[2]:
                best = (Patch(regs), cur, e)
        return (best[0],) + self.score(i, best[0])

    # ---- the mapping ----

    def choose(self, custom_min: float) -> None:
        """Every instrument scored against the 15 presets; a custom patch fitted for each
        instrument of at least custom_min of the music's weight; the one kept is the patch that
        gains most over the whole tune (the sum over the instruments of weight x the score it
        improves on their best preset, by more than CUSTOM_MARGIN for the instruments it was not
        fitted for); then each instrument takes its best patch (the custom one, for those, only
        when CUSTOM_MARGIN closer: near-ties keep their preset and the lines distinct timbres)."""
        self.scores = {i: {k: self.score(i, PRESETS[k]) for k in range(1, 16)} for i in self.mel}
        best = {i: min(sum(v) for v in self.scores[i].values()) for i in self.mel}
        self.fits = {}
        for i in self.mel:
            if self.importance[i] < custom_min:
                continue
            seeds = sorted(range(1, 16), key=lambda k: sum(self.scores[i][k]))[:FIT_SEEDS]
            p, tb, ev = self.fit_custom(i, seeds)
            on = {j: (tb, ev) if j == i else self.score(j, p) for j in self.mel}
            gain = sum(self.importance[j] * max(0.0, best[j] - sum(on[j]) - (0 if j == i else CUSTOM_MARGIN))
                       for j in self.mel)
            self.fits[i] = (p, on, gain)
            self.log("  custom patch fitted for %-10s %s: %.2f dB (timbre %.2f + level %.2f) against "
                     "the best preset's %.2f; tune-wide gain %.3f dB (%s)" % (
                         self.insts[i].name, p.regs.hex(), tb + ev, tb, ev, best[i], gain,
                         ", ".join(self.insts[j].name for j in self.mel
                                   if sum(on[j]) < best[j] - (0 if j == i else CUSTOM_MARGIN)) or "-"))
        self.custom_for = max(self.fits, key=lambda i: self.fits[i][2])
        self.custom, on, _ = self.fits[self.custom_for]
        self.patches = [self.custom] + PRESETS[1:]
        self.mapping = {}
        for i in self.mel:
            self.scores[i][0] = on[i]
            self.mapping[i] = min(self.scores[i], key=lambda k: sum(self.scores[i][k]) + (
                CUSTOM_MARGIN if k == 0 and i != self.custom_for else 0))

    # ---- the melodic streams ----

    def melodic_states(self, c: int) -> dict:
        """Intended register states of OPLL channel c per tick (volumes still 0): key on while
        the Amiga channel sounds (not the speech), a retrigger at each note, the instrument
        chosen for the Amiga's, the true pitch; while the key is off the voice keeps its
        F-number and instrument."""
        T = self.T
        ch = self.chans[c]
        st = {"key": self.aud[c].copy(), "retrig": np.zeros(T, bool), "fnum": np.zeros(T, int),
              "block": np.zeros(T, int), "inst": np.zeros(T, int), "sus": np.zeros(T, int),
              "vol": np.zeros(T, int)}
        for nt in self.notes[c]:
            st["retrig"][nt["s"]] = True
        last = None
        first = None
        for t in range(T):
            if self.aud[c][t]:
                k = self.mapping[int(ch.ins[t])]
                fn, bl = fnum_block(self.f0[c][t] / self.patches[k].ratio())
                last = (k, fn, bl)
                first = first or last
            if last:
                st["inst"][t], st["fnum"][t], st["block"][t] = last
        first = first or (1, 256, 4)
        for t in range(T):
            if self.aud[c][t]:
                break
            st["inst"][t], st["fnum"][t], st["block"][t] = first
        return st

    def melodic_volumes(self, st: dict, c: int, lam: float) -> np.ndarray:
        L = Melodic(st, self.patches).levels()
        C = tick_cost(L, self.tgt[c], self.ref, self.floor)
        return choose_volumes(C, structural(st), lam)

    # ---- the drums ----

    def drums(self, lam: float) -> tuple[bytes, list[tuple[int, int, tuple | None]], list[dict]]:
        """The rhythm section's pitch registers and its events. Pitches: BD on BDRM's thump
        (the power-weighted mean frequency of its first 2 ticks, 40-300 Hz), SD's tone (twice
        channel 7's) and TOM (5 x channel 8's) on the spectral peaks of SNARE and TOM1. Each hit
        of Amiga channel 3 is struck at its key-on tick with the volume whose energy over the
        hit's first DRUM_WIN ticks matches the Amiga's; BD and SD (carrier slots) may get a
        key-off record 1-EARLY_OFF_MAX ticks after the hit: the chip then releases them at rate
        7, or 5 with their channel's sustain bit, much slower than their decay (the Amiga's
        drums ring for 10-20 ticks, the ROM's die in 3-6); the key-off tick and the sustain bits
        of channels 6 and 7 follow the hits' level shapes best (power-weighted, each tick's
        error capped at DRUM_CAP steps, + lambda x bytes)."""
        ch = self.chans[3]
        T = self.T
        hits = [int(t) for t in np.nonzero(ch.keyon & (ch.amp > 0))[0]]
        names = {}
        for t in hits:
            name = self.insts[int(ch.ins[t])].name
            if name not in DRUMS:
                raise SystemExit("error: channel 3 plays %s (instrument %d): no rhythm sound for it" % (
                    name, int(ch.ins[t])))
            names[t] = DRUMS[name]
        ref = ch.render()
        hz = {}
        for name in DRUMS.values():
            t0 = next(t for t in hits if names[t] == name)
            n = {"bd": 2, "sd": 6, "tom": 2}[name]
            seg = ref[t0 * SPT:(t0 + n) * SPT]
            N = 1 << 15
            X = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), N)) ** 2
            f = np.fft.rfftfreq(N, 1 / FS)
            if name == "bd":
                m = (f >= 40) & (f < 300)
                hz[name] = float(2 ** ((X[m] * np.log2(f[m])).sum() / X[m].sum()))
            else:
                m = (f >= 100) & (f < 500)
                hz[name] = float(f[m][np.argmax(X[m])])
        self.drum_hz = hz
        fbs = [fnum_block(hz["bd"]), fnum_block(hz["sd"] / 2), fnum_block(hz["tom"] / MULT[5])]
        tgt = np.where(ch.amp > 0, 20 * np.log10(np.maximum(ch.amp, 1e-12) / self.a_ref) + self.ref, -np.inf)
        tgt = np.where(tgt > self.floor, tgt, -np.inf)
        best = None
        for sus in ((0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0)):
            pitch = pitch_regs(fbs, sus)
            r = self._hits(hits, names, tgt, pitch_regs_hz(pitch), lam)
            if best is None or r[0] < best[0]:
                best = (r[0], pitch, r[1], r[2])
        _, pitch, events, log = best
        return pitch, events, log

    def _hits(self, hits: list[int], names: dict, tgt: np.ndarray, chans: list, lam: float) -> tuple:
        T = self.T
        vols = {"bd": 0, "sd": 0, "tom": 0, "hh": 15, "tcy": 15}
        events: dict[int, list] = {}
        log = []
        total = 0.0
        for j, t in enumerate(hits):
            nxt = hits[j + 1] if j + 1 < len(hits) else T
            name = names[t]
            n = nxt - t
            offs: list = [None]
            if name in EARLY_OFF:
                offs += [k for k in range(1, EARLY_OFF_MAX + 1) if k < n]
            tg = tgt[t:nxt]
            aud = np.isfinite(tg)
            k = min(n, DRUM_WIN)
            e_a = float(np.sum(10 ** (tg[:k][aud[:k]] / 10)))
            w = 10 ** ((np.where(aud, tg, self.floor) - self.ref) / 10)
            best = None
            for off in offs:
                key = (name, n, off, chans[RHYTHM_CH[name]])
                L = self._lcache.get(key)
                if L is None:
                    L = self._lcache[key] = hit_levels(name, chans, n, off)
                e_o = (10 ** (L[:k] / 10)).sum(axis=0)
                v = int(np.argmin(np.abs(10 * np.log10(np.maximum(e_o, 1e-30) / max(e_a, 1e-30)))))
                Lc = np.maximum(L[:, v], self.floor)
                e_aud = w * np.minimum(((Lc - np.where(aud, tg, 0.0)) / 3) ** 2, DRUM_CAP ** 2)
                e_sil = 10 ** ((Lc - self.ref) / 10) * np.minimum(((Lc - self.floor) / 3) ** 2, DRUM_CAP ** 2)
                err = np.where(aud, e_aud, e_sil)
                cost = float(err.sum()) + lam * (2 if off is not None else 0)
                if best is None or cost < best[0]:
                    best = (cost, v, off)
            cost, v, off = best
            total += cost + lam * (3 if v != vols[name] else 0)
            vols[name] = v
            regs = (vols["bd"], (vols["hh"] << 4) | vols["sd"], (vols["tom"] << 4) | vols["tcy"])
            events[t] = [dict(RHYTHM)[name], regs]
            if off is not None:
                events[t + off] = [0, None]
            log.append({"tick": t, "drum": name, "vol": v, "off": off})
        return total, sorted((t, k, r) for t, (k, r) in events.items()), log


def structural(st: dict) -> np.ndarray:
    """Ticks where a record starts whatever the volume: a note, a key change, a new F-number,
    block, instrument or sustain bit (and tick 0)."""
    T = len(st["key"])
    out = np.zeros(T, bool)
    out[0] = True
    for f in ("key", "fnum", "block", "inst", "sus"):
        a = np.asarray(st[f])
        out[1:] |= a[1:] != a[:-1]
    out |= np.asarray(st["retrig"], bool)
    return out


# ---------------------------------------------------------------------------------------------
# The stream formats (what the Z80 player reads)
# ---------------------------------------------------------------------------------------------

def melodic_records(st: dict, vol: np.ndarray, max_dur: int = 255) -> list[list]:
    """Records [dur, ctl, word or None, byte or None] of a melodic stream: a record a state
    (volume, key, F-number, block, instrument, sustain) and a new one at each retrigger; the
    first gives the F-number and the instrument."""
    T = len(vol)
    recs: list[list] = []
    prev = None
    cur_fb = cur_is = None
    for t in range(T):
        state = (int(vol[t]), bool(st["key"][t]), int(st["fnum"][t]), int(st["block"][t]),
                 int(st["inst"][t]), int(st["sus"][t]))
        if t and not st["retrig"][t] and state == prev and recs[-1][0] < max_dur:
            recs[-1][0] += 1
            continue
        v, key, fn, bl, inst, sus = state
        ctl = v | (0x40 if key else 0) | (0x80 if st["retrig"][t] else 0)
        w = b = None
        if (fn, bl) != cur_fb:
            ctl |= 0x10
            w = cur_fb = (fn, bl)
        if (inst, sus) != cur_is:
            ctl |= 0x20
            b = cur_is = (inst, sus)
        recs.append([1, ctl, w, b])
        prev = state
    return recs


def melodic_bytes(recs: list[list]) -> bytes:
    out = bytearray()
    for d, ctl, w, b in recs:
        out += bytes([d, ctl])
        if w is not None:
            x = (w[0] & 0x1FF) | (w[1] << 9)
            out += bytes([x & 0xFF, x >> 8])
        if b is not None:
            out.append((b[0] << 4) | b[1])
    out.append(0)
    return bytes(out)


def rhythm_records(events: list[tuple[int, int, tuple | None]], T: int, max_dur: int = 255) -> list[list]:
    """Records [dur, ctl, volumes or None] of the rhythm stream: one at each event (struck keys,
    or 0: a key-off) and at tick 0; the volumes when they change (the first record gives
    them)."""
    ev = {t: (k, r) for t, k, r in events}
    recs: list[list] = []
    cur = None
    regs = next((r for _, _, r in events if r is not None), (15, 0xFF, 0xFF))
    for t in range(T):
        if t in ev or t == 0 or recs[-1][0] >= max_dur:
            keys, r = ev.get(t, (0, None))
            r = r if r is not None else regs
            regs = r
            ctl = keys
            vb = None
            if r != cur:
                ctl |= 0x20
                vb = cur = r
            recs.append([1, ctl, vb])
        else:
            recs[-1][0] += 1
    return recs


def rhythm_bytes(recs: list[list]) -> bytes:
    out = bytearray()
    for d, ctl, vb in recs:
        out += bytes([d, ctl])
        if vb is not None:
            out += bytes(vb)
    out.append(0)
    return bytes(out)


def decode_melodic(code: bytes, start: int, ticks: int) -> dict:
    """The Z80 player's reading of a melodic stream: per tick vol, key, retrig (the record's
    first tick), fnum, block, inst, sus."""
    out = {f: np.zeros(ticks, int) for f in ("vol", "key", "retrig", "fnum", "block", "inst", "sus")}
    s = {"vol": 0, "key": 0, "fnum": 0, "block": 0, "inst": 0, "sus": 0}
    ptr = start

    def record() -> tuple[int, int]:
        nonlocal ptr
        d = code[ptr]
        ptr += 1
        if d == 0:
            ptr = start
            d = code[ptr]
            ptr += 1
            if d == 0:
                raise ValueError("empty stream")
        ctl = code[ptr]
        ptr += 1
        if ctl & 0x10:
            x = code[ptr] | (code[ptr + 1] << 8)
            ptr += 2
            s["fnum"], s["block"] = x & 0x1FF, (x >> 9) & 7
        if ctl & 0x20:
            b = code[ptr]
            ptr += 1
            s["inst"], s["sus"] = b >> 4, b & 1
        s["vol"], s["key"] = ctl & 15, (ctl >> 6) & 1
        return d, (ctl >> 7) & 1

    left, rt = record()
    for t in range(ticks):
        for f in s:
            out[f][t] = s[f]
        out["retrig"][t] = rt
        rt = 0
        left -= 1
        if left == 0:
            left, rt = record()
    out["key"] = out["key"].astype(bool)
    out["retrig"] = out["retrig"].astype(bool)
    return out


def decode_rhythm(code: bytes, start: int, ticks: int) -> dict:
    """The Z80 player's reading of the rhythm stream: per tick rec (a record starts: 0Eh = 20h,
    then 20h | keys), keys, v36, v37, v38."""
    out = {f: np.zeros(ticks, int) for f in ("rec", "keys", "v36", "v37", "v38")}
    s = {"v36": 0, "v37": 0, "v38": 0}
    ptr = start

    def record() -> tuple[int, int]:
        nonlocal ptr
        d = code[ptr]
        ptr += 1
        if d == 0:
            ptr = start
            d = code[ptr]
            ptr += 1
            if d == 0:
                raise ValueError("empty stream")
        ctl = code[ptr]
        ptr += 1
        if ctl & 0x20:
            s["v36"], s["v37"], s["v38"] = code[ptr], code[ptr + 1], code[ptr + 2]
            ptr += 3
        return d, ctl & 0x1F

    left, keys = record()
    rec = 1
    for t in range(ticks):
        for f in s:
            out[f][t] = s[f]
        out["rec"][t], out["keys"][t] = rec, keys if rec else 0
        rec = 0
        left -= 1
        if left == 0:
            left, keys = record()
            rec = 1
    out["rec"] = out["rec"].astype(bool)
    return out


HEADER = 15                             # five 24-bit offsets


def assemble(mel: list[bytes], rhy: bytes, patch: bytes) -> tuple[bytes, list[int]]:
    """fm.bin: the offsets of the three melodic streams, the rhythm stream and the patch block
    (24-bit little-endian, from the blob's start), then the patch block and the streams."""
    offs = []
    body = bytearray()
    parts = [patch] + mel + [rhy]
    for p in parts:
        offs.append(HEADER + len(body))
        body += p
    order = offs[1:4] + [offs[4], offs[0]]
    head = b"".join(bytes([o & 0xFF, (o >> 8) & 0xFF, o >> 16]) for o in order)
    return head + bytes(body), order


# ---------------------------------------------------------------------------------------------
# Encoding within the budget
# ---------------------------------------------------------------------------------------------

BUDGET = 24 * 1024                      # bytes of fm.bin
LAM_MIN = 0.02                          # the least bytes-vs-distortion trade-off (merges changes
                                        # below a fraction of a step)
CUSTOM_MIN = 0.05                       # weight share for which a custom patch is fitted
CUSTOM_MARGIN = 0.5                     # dB: an instrument the custom patch was not fitted for
                                        # takes it only when this much closer than its preset


def encode(ft: FmTitle, lam: float) -> dict:
    states, vols, mel = [], [], []
    for c in range(3):
        st = ft.melodic_states(c)
        v = ft.melodic_volumes(st, c, lam)
        st["vol"] = v
        states.append(st)
        vols.append(v)
        mel.append(melodic_bytes(melodic_records(st, v)))
    pitch, events, drum_log = ft.drums(lam)
    rrecs = rhythm_records(events, ft.T)
    rhy = rhythm_bytes(rrecs)
    patch = ft.custom.regs + pitch
    blob, offs = assemble(mel, rhy, patch)
    return {"states": states, "mel": mel, "rhy": rhy, "rrecs": rrecs, "events": events,
            "drum_log": drum_log, "pitch": pitch, "patch": patch, "blob": blob, "offs": offs, "lam": lam}


def encode_budget(ft: FmTitle, budget: int) -> dict:
    """The best quality (the smallest lambda, at least LAM_MIN) whose fm.bin fits the budget."""
    best = encode(ft, LAM_MIN)
    if len(best["blob"]) <= budget:
        return best
    lo, hi = LAM_MIN, 1.0
    top = encode(ft, hi)
    while len(top["blob"]) > budget and hi < 1e4:
        lo, hi = hi, hi * 4
        top = encode(ft, hi)
    best = top
    for _ in range(20):
        mid = math.sqrt(lo * hi)
        r = encode(ft, mid)
        if len(r["blob"]) <= budget:
            hi, best = mid, r
        else:
            lo = mid
        if hi - lo < 0.02 * hi:
            break
    return best


def check(enc: dict, T: int) -> list[str]:
    """Decodes the blob as the Z80 player reads it and compares it with the encoder's intent,
    twice round (the streams loop at their start)."""
    blob, offs = enc["blob"], enc["offs"]
    bad = []
    for c in range(3):
        d = decode_melodic(blob, offs[c], 2 * T)
        want = enc["states"][c]
        for f in ("vol", "key", "retrig", "fnum", "block", "inst", "sus"):
            w = np.asarray(want[f]).astype(int)
            for k in range(2):
                n = int(np.sum(d[f][k * T:(k + 1) * T].astype(int) != w))
                if n:
                    bad.append("channel %d: %s differs on %d ticks (pass %d)" % (c, f, n, k + 1))
    d = decode_rhythm(blob, offs[3], 2 * T)
    want_rec = np.zeros(T, bool)
    want_keys = np.zeros(T, int)
    t = 0
    for rec in enc["rrecs"]:
        want_rec[t] = True
        want_keys[t] = rec[1] & 0x1F
        t += rec[0]
    ev = {t: k for t, k, _ in enc["events"]}
    for t, k in ev.items():
        if not want_rec[t] or want_keys[t] != k:
            bad.append("rhythm: event at tick %d not encoded" % t)
    regs = {}
    cur = None
    evr = {t: r for t, _, r in enc["events"]}
    first = next(r for _, _, r in enc["events"] if r is not None)
    for t in range(T):
        r = evr.get(t)
        cur = r if r is not None else (cur if cur is not None else first)
        regs[t] = cur
    for k in range(2):
        sl = slice(k * T, (k + 1) * T)
        if np.any(d["rec"][sl] != want_rec) or np.any(d["keys"][sl] != want_keys):
            bad.append("rhythm: records or keys differ (pass %d)" % (k + 1))
        got = list(zip(d["v36"][sl], d["v37"][sl], d["v38"][sl]))
        n = sum(1 for t in range(T) if tuple(int(x) for x in got[t]) != tuple(regs[t]))
        if n:
            bad.append("rhythm: volumes differ on %d ticks (pass %d)" % (n, k + 1))
    for c in range(3):
        if sum(r for r in stream_durations(blob, offs[c], melodic=True)) != T:
            bad.append("channel %d: the stream does not last %d ticks" % (c, T))
        if blob[offs[c] + 1] & 0x30 != 0x30:
            bad.append("channel %d: the first record does not give the F-number and the instrument" % c)
    if sum(stream_durations(blob, offs[3], melodic=False)) != T:
        bad.append("rhythm: the stream does not last %d ticks" % T)
    if not blob[offs[3] + 1] & 0x20:
        bad.append("rhythm: the first record does not give the volumes")
    if any(b & 0x10 for b in enc["pitch"][3:]):
        bad.append("rhythm: a key bit set in 26h-28h")
    return bad


def stream_durations(code: bytes, start: int, melodic: bool) -> list[int]:
    out = []
    p = start
    while code[p]:
        out.append(code[p])
        ctl = code[p + 1]
        p += 2
        if melodic:
            p += (2 if ctl & 0x10 else 0) + (1 if ctl & 0x20 else 0)
        else:
            p += 3 if ctl & 0x20 else 0
    return out


# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------

def write_inc(path: Path, ft: FmTitle, enc: dict) -> None:
    sizes = [len(x) for x in enc["mel"]] + [len(enc["rhy"])]
    L = ["; generated by tools/msxfm.py from TITM (the title music, tune 1): OPLL (YM2413) streams",
         "; for the Z80 player in fm.bin (%d bytes): a header of five 24-bit little-endian offsets" % (
             len(enc["blob"])),
         "; (melodic channels 0-2, the rhythm stream, the patch block), then the data.",
         "; Melodic record: dur (1-255 ticks at 50 Hz; 0 = the end: back to the stream's start), ctl",
         "; (bits 0-3 volume, the attenuation; 4: a word follows, F-number bits 0-8, block bits 9-11;",
         "; 5: a byte follows, after the word: instrument bits 7-4, sustain bit 0; 6: key on; 7:",
         "; retrigger, key off then on at the record's start). Rhythm record: dur, ctl (bits 4-0 the",
         "; keys struck as in 0Eh; 5: the values of 36h, 37h, 38h follow; the first record gives",
         "; them). Patch block: the custom instrument (00h-07h: %s), the rhythm" % (
             " ".join("%02X" % b for b in ft.custom.regs)),
         "; pitches (16h-18h, 26h-28h: %s; sustain bits of channels 6-8: %s, key bits 0)." % (
             " ".join("%02X" % b for b in enc["pitch"]),
             "".join(str((b >> 5) & 1) for b in enc["pitch"][3:])),
         "; sizes: melodic %s, rhythm %d, patch block 14, header 15." % (
             "+".join(map(str, sizes[:3])), sizes[3]),
         ";",
         "; Amiga instrument -> OPLL instrument (timbre / level scores in dB, lower is closer):"]
    for i in ft.mel:
        k = ft.mapping[i]
        tb, ev = ft.scores[i][k]
        L.append(";   %2d %-10s -> %2d %-15s (%.1f / %.1f)%s" % (
            i, ft.insts[i].name, k, PRESET_NAMES[k], tb, ev,
            "  the custom patch was fitted for it" if i == ft.custom_for else ""))
    L.append(";   %2d %-10s -> key off (RoboCop's speech: PCM on the PSG)" % (
        ms.SPEECH_INST, ft.insts[ms.SPEECH_INST].name))
    for name, r in DRUMS.items():
        L.append(";   channel 3 %-6s -> rhythm %s at %.0f Hz" % (name, r.upper(), ft.drum_hz[r]))
    L += ["", "FM_BYTES:   equ %d" % len(enc["blob"]), ""]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(L))


def fmt(x, spec="%.2f") -> str:
    return "-" if x is None else spec % x


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "msx", help="directory of fm.bin, fm.inc")
    ap.add_argument("--wav", type=Path, default=ROOT / "build" / "music" / "preview",
                    help="directory of the preview WAV")
    ap.add_argument("--seconds", type=float, default=60.0, help="preview length")
    ap.add_argument("--budget", type=int, default=BUDGET, help="bytes of fm.bin (default 24 KiB)")
    ap.add_argument("--no-wav", action="store_true", help="no preview and no comparison")
    args = ap.parse_args()

    rep, data = ms.load_music("TITM", "TITM_04.bin")
    ft = FmTitle(rep, data)
    print("choosing the instruments (%d melodic Amiga instruments, 15 presets + a custom patch):" % (
        len(ft.mel)))
    ft.choose(CUSTOM_MIN)
    print("custom patch (00h-07h): %s, fitted for %s: %s" % (
        " ".join("%02X" % b for b in ft.custom.regs), ft.insts[ft.custom_for].name, ft.custom.describe()))
    print("instruments of channels 0-2 (scores: band-profile distance / level error, dB):")
    for i in ft.mel:
        k = ft.mapping[i]
        alt = sorted((sum(v), kk) for kk, v in ft.scores[i].items() if kk != k)[:2]
        print("  %2d %-10s weight %.3f -> %2d %-15s %.1f / %.1f   (next: %s)" % (
            i, ft.insts[i].name, ft.importance[i], k, PRESET_NAMES[k], *ft.scores[i][k],
            ", ".join("%s %.1f" % (PRESET_NAMES[kk], s) for s, kk in alt)))
    enc = encode_budget(ft, args.budget)
    blob = enc["blob"]
    hz = ft.drum_hz
    chans = pitch_regs_hz(enc["pitch"])
    print("rhythm: BDRM -> BD at %.0f Hz (channel 6 %.1f Hz), SNARE -> SD (tone %.0f Hz: channel 7 %.1f Hz "
          "x 2), TOM1 -> TOM at %.0f Hz (channel 8 %.1f Hz x 5); sustain bits of channels 6-8: %s; "
          "registers 16h-18h, 26h-28h: %s" % (
              hz["bd"], chans[0][2], hz["sd"], chans[1][2], hz["tom"], chans[2][2],
              "".join(str(c[3]) for c in chans), " ".join("%02X" % b for b in enc["pitch"])))
    drums: dict = {}
    for d in enc["drum_log"]:
        k = drums.setdefault(d["drum"], {"hits": 0, "vols": {}, "offs": {}})
        k["hits"] += 1
        k["vols"][d["vol"]] = k["vols"].get(d["vol"], 0) + 1
        k["offs"][d["off"]] = k["offs"].get(d["off"], 0) + 1
    for name, k in drums.items():
        offs = sorted(k["offs"].items(), key=lambda x: -1 if x[0] is None else x[0])
        print("  %-3s %3d hits, volumes %s, key-off after %s" % (
            name.upper(), k["hits"], k["vols"],
            {("the next hit" if o is None else "%d ticks" % o): n for o, n in offs}))
    sizes = [len(x) for x in enc["mel"]] + [len(enc["rhy"])]
    print("sizes: melodic %s, rhythm %d, patch block 14, header 15: %d bytes (budget %d, lambda %.3g)" % (
        "+".join(map(str, sizes[:3])), sizes[3], len(blob), args.budget, enc["lam"]))
    if len(blob) > args.budget:
        print("  warning: over the budget even at the coarsest")
    bad = check(enc, ft.T)
    print("decoded streams against the encoder: %s" % (
        "identical, twice round" if not bad else "; ".join(bad)))
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "fm.bin").write_bytes(blob)
    write_inc(args.out / "fm.inc", ft, enc)
    print("wrote", args.out / "fm.bin", "and", args.out / "fm.inc")
    if bad:
        return 1
    if args.no_wav:
        return 0

    # ---- the preview and the comparison (the streams decoded as the player reads them) ----
    T = ft.T
    N = min(T, int(args.seconds * TICK_HZ))
    patches = [Patch(enc["patch"][:8])] + PRESETS[1:]
    dec = [decode_melodic(blob, enc["offs"][c], T) for c in range(3)]
    voices = [Melodic(d, patches) for d in dec]
    outs = [v.render(N) for v in voices]
    rh = Rhythm(decode_rhythm(blob, enc["offs"][3], T), enc["patch"][8:])
    r_out = rh.render(N)
    mix = sum(outs) + r_out
    ms.write_wav(args.wav / "titm_fm.wav", ms.dc_block(mix))
    refs = [c.render(0, N) for c in ft.chans]
    speech = 0
    for c in range(3):                              # (the speech is PCM on the PSG: left out)
        for t in np.nonzero((ft.chans[c].ins[:N] == ms.SPEECH_INST) & (ft.chans[c].amp[:N] > 0))[0]:
            refs[c][t * SPT:(t + 1) * SPT] = 0.0
            speech += 1
    ch3 = ft.chans[3]
    tgt3 = np.where(ch3.amp > 0, 20 * np.log10(np.maximum(ch3.amp, 1e-12) / ft.a_ref) + ft.ref, -np.inf)
    hit = np.zeros(N, bool)
    for t in np.nonzero(ch3.keyon[:N])[0]:
        hit[t:t + DRUM_WIN] = True
    print("\ntitle, first %d s (Amiga reference rendered from the model, the speech's %d channel ticks "
          "left out, vs the OPLL streams decoded on the OPLL model; level err: mean |OPLL - target| "
          "per tick, the drums over each hit's first %d ticks):" % (N // TICK_HZ, speech, DRUM_WIN))
    print("  %-20s %8s %8s %8s %8s %9s   %s" % ("source", "ref std", "env r", "env MAE", "covered",
                                               "level err", "pitch / brightness"))
    for c in range(4):
        y = outs[c] if c < 3 else r_out
        e = ms.env_compare(refs[c], y, N)
        b = ms.tick_db(y, N)
        tg = ft.tgt[c][:N] if c < 3 else np.where(hit, tgt3[:N], -np.inf)
        aud = np.isfinite(tg)
        lerr = float(np.mean(np.abs(b[aud] - tg[aud]))) if aud.any() else None
        if c < 3:
            p = ms.pitch_compare(refs[c], voices[c].hz()[:N], N)
            extra = ("pitch on %d ticks: %s within 50 cents, %s same note name, median %s cents" % (
                p["ticks"], fmt(p.get("exact"), "%.3f"), fmt(p.get("chroma"), "%.3f"),
                fmt(p.get("median_cents"), "%.0f"))) if p["ticks"] else "no periodic ticks"
            name = "channel %d (FM %d)" % (c, c)
        else:
            mask = np.zeros(N, bool)
            for t in np.nonzero(ch3.keyon[:N])[0]:
                mask[t:t + 3] = True
            bc = ms.bright_compare(refs[3], r_out, N, mask)
            extra = "brightness on %d hit ticks: r %s, OPLL - Amiga %s octaves" % (
                bc["ticks"], fmt(bc.get("r")), fmt(bc.get("diff_oct"), "%+.2f"))
            name = "channel 3 (rhythm)"
        print("  %-20s %8s %8s %8s %8s %9s   %s" % (
            name, fmt(e["ref_std"], "%.1f dB"), fmt(e["r"]), fmt(e["mae_db"], "%.1f dB"),
            fmt(e["coverage"], "%.2f"), fmt(lerr, "%.1f dB"), extra))
    ref_mix = sum(refs)
    e = ms.env_compare(ref_mix, mix, N)
    print("  %-20s %8s %8s %8s %8s %9s   chroma similarity %.3f" % (
        "mix", fmt(e["ref_std"], "%.1f dB"), fmt(e["r"]), fmt(e["mae_db"], "%.1f dB"),
        fmt(e["coverage"], "%.2f"), "", ms.chroma_similarity(ref_mix, mix, N)))
    print("wrote", args.wav / "titm_fm.wav")
    return 0


if __name__ == "__main__":
    sys.exit(main())
