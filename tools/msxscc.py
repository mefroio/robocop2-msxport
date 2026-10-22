#!/usr/bin/env python3
"""Robocop 2's title music (TITM tune 1) for a Konami SCC: Amiga channels 0-2 as wavetable
voices on SCC channels 1-3, the drums of channel 3 as one PSG voice (C), for an MSX that has an
SCC (msxsound.py's PSG version stays for the others).

Input: the Amiga model of tools/msxsound.py (rc2music.py's exact per-tick output,
build/music/TITM.json; the samples in build/extracted/files/TITM_04.bin). Output:
build/msx/scc.bin (a header of five 24-bit little-endian offsets from the blob's start: the
streams of SCC voices 0, 1, 2, the PSG drum stream, the waveform table of SCC_WAVES x 32
signed bytes; then the data, unaligned), build/msx/scc.inc (SCC_WAVES, SCC_BYTES, a comment per
waveform), build/music/preview/titm_scc.wav (an SCC model plus the PSG model, to hear against
titm_amiga.wav) and a printed comparison. Needs numpy (the project's venv).

usage: msxscc.py [--out build/msx] [--seconds 60]

SCC voice stream: records of dur (1 byte, 1..255 ticks at 50 Hz; 0 = the end: the voice goes on
at its stream's start) then ctl (bits 0-3 the volume 0-15; bit 4: a word follows, the period N
0..4095, little-endian; bit 5: a byte follows, after the word, the waveform number; bits 6-7
zero). A field not given keeps the voice's value; the first record gives the period and the
waveform; identical consecutive states are one record (split at 255). The drum stream is
msxsound.py's PSG voice format; its first record gives both the tone and the noise period. All
four streams last the loop (5184 ticks) and go on at their start together.

How the Amiga sound is mapped (the decisions and why)
- Voices: Amiga channel c (0-2) on SCC channel c + 1; channels 4 and 5 share one waveform, so
  they stay unused. The drums (channel 3) need noise, which only the PSG has.
- Pitch: f = the Paula rate (3579545 / AUDxPER, at most one DMA word a line: AUDxPER >= 113.75)
  over the sample's own samples per cycle as measured (Title.pitch: the median YIN period of its
  body), not msxsound's tuning grid (Title.spc). The PSG snaps every instrument onto one grid
  because its pure squares, which keep nothing of the samples' timbres (inharmonic partials,
  detuned layers), expose the samples' detuning as plain dissonance; the SCC plays each sample's
  own waveform, so the Amiga's real tuning, detuning included, is the goal (on the Amiga TIMPANI
  sits 45 cents above that grid, PIZZICATO 22 below, #13 15 above, the rest within 8). The
  SCC's clock is Paula's NTSC clock, so N + 1 = 3579545 / (32 f) = AUDxPER x spc / 32: every
  note fits (N 188-3329) at its true octave (no PSG octave shift: FILTER-WAH plays at 34-67 Hz).
  The period is exact at key-ons; a slide (#1 only) keeps it while within PITCH_TOL cents.
- Waveforms (one per instrument of channels 0-2, the speech excepted; numbered in instrument
  order): the sustained timbre the title makes heard. Windows of 2 cycles and FIT_SAMPLES bytes
  or more hop a cycle at a time over the sample after its first ATTACK_CYCLES (the attack); each is
  fitted (least squares at its local YIN period: a resampling, whatever the fractional period)
  with harmonics 1-15, all a 32-sample cycle holds (13 for #1 and #13: 26.5 samples a cycle hold
  no more). A window weighs the power the title plays it with: each byte's (volume / 64)^2
  summed over the ticks that play it (the loop included: FILTER-WAH's sweep). The cycle takes
  the windows' mean power per harmonic and the phases of their mean after aligning them (cross-
  correlation): the phases drift (layered, detuned, evolving sounds), so a plain average of the
  cycles would keep only 27-82 % of the power, a duller wave. Then it is scaled to the full
  signed range (no DC: a volume change would click). Noisy or inharmonic samples keep their
  periodic part, the share printed: #10 80 % (aperiodicity 0.33), ORCH1 85 % (an orchestra
  hit), FILTER-WAH 86 % (its wah averaged), TIMPANI 93 % (inharmonic partials, the 2nd the
  strongest). The heard power above harmonic 15 is lost: 8 % for ORCH1, under 4 % for the rest.
- Loudness: per tick the RMS of the sample bytes played, as msxsound's Channel.amp, but over
  whole cycles (the tick's span rounded to whole cycles, at least one: at AUDxPER 447 a tick of
  ba1 is 1.5 cycles, and the raw RMS swings 2.4 dB with the phase: a tremolo on a flat SCC
  volume), times volume / 64. The SCC's output RMS is the waveform's RMS x volume / 15 (linear),
  so volume = 15 x amp / (waveform RMS x ref), ref the REF_PCT percentile of amp / waveform RMS
  over the three channels (the loudest ticks reach 15; 8 ticks clip, by 0.7 dB at most), the
  nearest level in dB (0 below 0.5). A tick within VOL_TOL_DB of the level playing keeps it
  (not at key-ons): inaudible, 6 % fewer bytes. Volume 0 when the channel is silent or plays the
  speech.
- Re-triggers: Paula restarts the sample at each key-on (DMA off, a click); the SCC's phase runs
  on, so a re-trigger of the same period, waveform and level (ba1's flat bass, repeated every 6
  ticks) would merge into one long note. When a key-on keeps the period and waveform and rises
  less than ACCENT_DB, the tick before it dips by DIP_DB (as msxsound's ACCENT on the PSG).
- Speech (instrument 24, "YOUR MOVE, CREEP"): silent here, as in the PSG streams (msxvoice.py).
- Drums (Amiga channel 3: BDRM, SNARE, TOM1): one PSG voice built as msxsound builds a sound
  effect's (Effects._target: per tick tone, tone + noise or noise from how periodic the bytes
  played are; the tone period from their YIN period at the played rate, the noise period from
  their brightness, always 31 here), then choose_volumes (lambda DRUM_LAMBDA) and records. The
  PSG's darkest noise (9.9 octaves) is brighter than these drums (BDRM 7.4, SNARE 9.2, TOM1
  8.5): about +0.6 octaves remain.
- Balance: the drum levels make the PSG's RMS match the Amiga's in the SCC's scale, at the
  output levels of openMSX's defaults (an assumption; real machines vary): a PSG voice (0..1 at
  level 15) at PSG_VOLUME, the SCC of a KonamiSCC ROM (+-1 at volume 15) at SCC_VOLUME.

The comparison (the Amiga reference rendered from the model vs the decoded streams on the SCC
and PSG models): per voice the loudness envelope (msxsound.env_compare: Pearson r, low where the
Amiga's envelope is flat; the mean |error| after aligning the medians; coverage) and its offset
(the median dB difference after the common gain: the balance), pitch (YIN on the Amiga from each
tick's start vs the SCC's f: within 50 cents, the same note name; YIN on the Amiga slips an
octave on FILTER-WAH and reads #13's detuned layer), chroma similarity and brightness (SCC -
Amiga, octaves); the drums' envelope and brightness; the mix, and msxsound's PSG preview.
"""
from __future__ import annotations

import argparse
import math
import sys
import wave as wavfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import msxsound as ms  # noqa: E402  (the Amiga model, the PSG format, encoder and model)

ROOT = Path(__file__).resolve().parents[1]
SCC_HZ = 3579545                        # the MSX's clock: a channel plays SCC_HZ / (32 (N + 1)) Hz
WAVE_LEN = 32                           # bytes of an SCC waveform (one cycle)
MAX_HARM = 15                           # harmonics a 32-sample cycle holds below its Nyquist
ATTACK_CYCLES = 2                       # a sample's first cycles: its attack, not averaged
FIT_SAMPLES = 64                        # a fitting window: 2 cycles or more, this many samples or more
REF_PCT = 99.9                          # percentile of amp / waveform RMS that reaches volume 15
PITCH_TOL = 3.0                         # cents a slide may move before a new period
VOL_TOL_DB = 0.5                        # dB the level may drift before a new volume (not at key-ons)
ACCENT_DB = 1.5                         # a re-trigger rising less than this ...
DIP_DB = 6.0                            # ... lowers the tick before it by this
DRUM_LAMBDA = 0.25                      # the drum stream's bytes-vs-distortion trade-off
DRUM_VOICE = 2                          # PSG voice C
PSG_VOLUME = 21000                      # openMSX: <volume> of the PSG (nearly every machine)
SCC_VOLUME = 9000                       # openMSX: <volume> of a ROM cartridge's sound (KonamiSCC)
PSG_OVER_SCC = PSG_VOLUME / SCC_VOLUME  # a PSG voice's full level over an SCC channel's full range
MAX_SCC_BYTES = 24 * 1024               # the three SCC voice streams' budget (a warning above)


# ---------------------------------------------------------------------------------------------
# Waveforms
# ---------------------------------------------------------------------------------------------

def heard_power(title: ms.Title, inst: int) -> np.ndarray:
    """Per position of the instrument's sample stream (0 = its start, the loop unrolled): the
    power the title plays that byte with on channels 0-2, (volume / 64)^2 summed over the ticks
    that play it."""
    spans = []
    for ch in title.chans[:3]:
        for t in np.nonzero((ch.ins == inst) & (ch.amp > 0))[0]:
            a, b = ch.span(int(t))
            if b > a:
                spans.append((a, b, (ch.vol[t] / 64) ** 2))
    n = max(b for _, b, _ in spans)
    d = np.zeros(n + 1)
    for a, b, p in spans:
        d[a] += p
        d[b] -= p
    return np.cumsum(d)[:n]


def fit_harmonics(x: np.ndarray, period: float, k: int) -> tuple[np.ndarray, float]:
    """Least-squares fit of a constant plus harmonics 1..k of `period` (samples, fractional) to
    x: their complex amplitudes (x ~ Re sum X_h exp(2 pi i h n / period)) and the share of x's
    AC power the fit leaves (0 = periodic)."""
    n = len(x)
    ang = 2 * np.pi * np.outer(np.arange(n), np.arange(1, k + 1)) / period
    a = np.hstack([np.ones((n, 1)), np.cos(ang), np.sin(ang)])
    c, *_ = np.linalg.lstsq(a, x, rcond=None)
    ac = float(np.sum((x - x.mean()) ** 2))
    left = float(np.sum((x - a @ c) ** 2)) / ac if ac > 0 else 1.0
    return c[1:k + 1] - 1j * c[k + 1:], left


class Wave:
    """The SCC waveform of one instrument: its sample's heard, sustained cycle (see the module
    docstring) in WAVE_LEN signed bytes, and how it was made."""

    def __init__(self, title: ms.Title, inst: int, number: int):
        self.inst, self.number = inst, number
        smp = title.insts[inst]
        self.name = smp.name
        self.sample = smp.sample
        p0 = title.pitch[inst][0]                   # the measured samples per cycle
        k = min(MAX_HARM, math.ceil(p0 / 2) - 1)    # harmonics below the sample's own Nyquist
        m = max(2, math.ceil(FIT_SAMPLES / p0))     # cycles per window
        w = heard_power(title, inst)
        x = smp.values(np.arange(len(w) + int((m + 3) * p0) + 8))
        X, W, left, periods = [], [], [], []
        for skip in (ATTACK_CYCLES, 0):             # (a sample heard only in its attack: from 0)
            a = int(math.ceil(skip * p0))
            while a + m * p0 <= len(w):
                wt = float(w[a:a + int(m * p0)].mean())
                if wt > 0:
                    r = ms.yin(x[a:a + int((m + 1.5) * p0)], int(1.15 * p0), lo=int(0.87 * p0))
                    p = r[0] if r and abs(r[0] / p0 - 1) < 0.1 else p0
                    h, u = fit_harmonics(x[a:a + int(m * p)], p, k)
                    X.append(h)
                    W.append(wt)
                    left.append(u)
                    periods.append(p)
                a += max(1, int(round(p0)))
            if X:
                break
        if not X:                                   # (heard for less than a window: its start)
            h, u = fit_harmonics(x[:int(m * p0)], p0, k)
            X, W, left, periods = [h], [1.0], [u], [p0]
        X = np.array(X)
        W = np.array(W) / np.sum(W)
        power = W @ (np.abs(X) ** 2)                # the heard power of each harmonic
        hh = np.arange(1, k + 1)
        shifts = np.exp(2j * np.pi * np.outer(np.arange(1024) / 1024, hh))   # (shift, harmonic)
        ref = X[int(np.argmax(W))]
        for _ in range(4):                          # align every window on the mean cycle
            score = ((X * np.conj(ref)) @ shifts.T).real
            ref = W @ (X * shifts[np.argmax(score, axis=1)])
        self.coherence = float(np.sum(np.abs(ref) ** 2) / np.sum(power))
        self.windows = len(W)
        self.periodic = 1.0 - float(W @ np.array(left))
        self.period_used = float(W @ np.array(periods))
        hcoef = np.sqrt(power) * np.exp(1j * np.angle(ref))
        basis = np.exp(2j * np.pi * np.outer(np.arange(WAVE_LEN), hh) / WAVE_LEN)
        cyc = (hcoef[None, :] * basis).real.sum(1)
        s = min(127 / cyc.max(), 128 / -cyc.min())
        self.data = np.clip(np.round(cyc * s), -128, 127).astype(np.int8)
        self.rms = float(np.sqrt(np.mean((self.data / 128.0) ** 2)))
        self.harmonics = k
        self.high_loss = self._high_loss(x, w, p0, k)
        self.body = self._body(w, p0, skip)

    @staticmethod
    def _high_loss(x: np.ndarray, w: np.ndarray, p0: float, k: int) -> float:
        """Share of the heard periodic power above harmonic k (a fit of all the harmonics the
        sample holds on a few of its loudest heard windows)."""
        kmax = math.ceil(p0 / 2) - 1
        if kmax <= k:
            return 0.0
        m = max(4, math.ceil(8 * kmax / p0))        # >= 4 samples per unknown: little noise fitted
        n = int(m * p0)
        cand = sorted(range(0, max(1, len(w) - n), max(1, int(p0))),
                      key=lambda a: -float(w[a:a + n].mean()))[:12]
        lo = hi = 0.0
        for a in cand:
            if a + n > len(x):
                continue
            h, _ = fit_harmonics(x[a:a + n], p0, kmax)
            p = np.abs(h) ** 2 * float(w[a:a + n].mean())
            lo += float(p[:k].sum())
            hi += float(p[k:].sum())
        return hi / (lo + hi) if lo + hi > 0 else 0.0

    @staticmethod
    def _body(w: np.ndarray, p0: float, skip: int) -> tuple[int, int]:
        """The positions holding the middle 90 % of the heard power (after the attack skipped)."""
        a = int(math.ceil(skip * p0))
        c = np.cumsum(w[a:])
        if not len(c) or c[-1] <= 0:
            return a, len(w)
        return a + int(np.searchsorted(c, 0.05 * c[-1])), a + int(np.searchsorted(c, 0.95 * c[-1]))


def make_waves(title: ms.Title) -> dict[int, Wave]:
    """One waveform per instrument heard on channels 0-2 (the speech excepted), by instrument."""
    used = set()
    for ch in title.chans[:3]:
        used |= {int(i) for i in ch.ins[(ch.amp > 0) & (ch.per > 1)]}
    insts = sorted(i for i in used if i in title.pitch and title.pitch[i][0] > 0
                   and i != ms.SPEECH_INST)
    return {i: Wave(title, i, n) for n, i in enumerate(insts)}


# ---------------------------------------------------------------------------------------------
# The melodic voices (Amiga channels 0-2 -> SCC channels 1-3)
# ---------------------------------------------------------------------------------------------

def cycle_amp(ch: ms.Channel, t: int, period: float) -> float:
    """The tick's amplitude (Channel.amp) over whole cycles: the RMS of the sample bytes around
    the tick's span, its length rounded to whole cycles (at least one), times volume / 64."""
    a, b = ch.span(t)
    n = max(1, round((b - a) / period)) * period
    lo = max(0.0, (a + b) / 2 - n / 2)
    ia, ib = int(round(lo)), int(round(lo + n))
    return math.sqrt(ch.insts[int(ch.ins[t])].energy(ia, ib) / (ib - ia)) * ch.vol[t] / 64


def level_db(v: float) -> float:
    return 20 * math.log10(v / 15) if v > 0 else -np.inf


def nearest_level(x: float) -> int:
    """The SCC volume (linear 0-15) nearest to x in dB; 0 below 0.5 (half of level 1)."""
    if x < 0.5:
        return 0
    k = max(1, min(15, int(math.floor(x))))
    if k < 15 and x > math.sqrt(k * (k + 1)):
        k += 1
    return k


class SccVoice:
    """One SCC voice tick by tick: volume (0 = silent), period N, waveform number; the exact
    level each tick wants (x, in volume units) and the key-ons."""

    def __init__(self, title: ms.Title, c: int, waves: dict[int, Wave]):
        ch = title.chans[c]
        T = title.T
        self.c = c
        self.T = T
        self.amp = np.zeros(T)
        self.inst = np.full(T, -1)
        self.per = np.zeros(T, np.int64)
        self.wave = np.full(T, -1)
        self.keyon = ch.keyon.copy()
        for t in range(T):
            i = int(ch.ins[t])
            if i not in waves or ch.amp[t] <= 0 or ch.per[t] <= 1:
                continue                                # (silent, or the speech: no waveform)
            self.amp[t] = cycle_amp(ch, t, title.pitch[i][0])
            self.inst[t] = i
            self.wave[t] = waves[i].number
            n = round(max(ch.per[t], ms.DMA_PERIOD) * title.pitch[i][0] / WAVE_LEN) - 1
            self.per[t] = int(min(4095, max(0, n)))
        self.ratio = np.array([self.amp[t] / waves[int(self.inst[t])].rms if self.inst[t] >= 0
                               else 0.0 for t in range(T)])
        self.x = np.zeros(T)
        self.vol = np.zeros(T, np.int64)
        self.dips = 0

    def quantise(self, ref: float) -> None:
        """Volumes from the exact levels (15 x ratio / ref), periods held in slides, the
        re-trigger dips (see the module docstring)."""
        T = self.T
        self.x = 15 * self.ratio / ref
        ref_n, ref_w, prev = None, None, 0
        for t in range(T):
            v = nearest_level(self.x[t]) if self.inst[t] >= 0 else 0
            if not v:
                self.vol[t] = prev = 0
                continue
            drift = abs(20 * math.log10(self.x[t] / 15) - level_db(prev)) if prev else np.inf
            if not self.keyon[t] and drift <= VOL_TOL_DB:
                v = prev
            self.vol[t] = prev = v
            n, w = int(self.per[t]), int(self.wave[t])
            if (ref_n is None or self.keyon[t] or w != ref_w
                    or abs(1200 * math.log2((ref_n + 1) / (n + 1))) >= PITCH_TOL):
                ref_n, ref_w = n, w
            self.per[t] = ref_n
        for t in range(1, T):
            if not (self.keyon[t] and self.vol[t] and self.vol[t - 1]) or self.keyon[t - 1]:
                continue
            if self.per[t] != self.per[t - 1] or self.wave[t] != self.wave[t - 1]:
                continue
            if level_db(self.vol[t]) - level_db(self.vol[t - 1]) < ACCENT_DB:
                low = min(self.vol[t - 1], self.vol[t])
                self.vol[t - 1] = nearest_level(low * 10 ** (-DIP_DB / 20))
                self.dips += 1

    def intended(self) -> list[tuple]:
        """Per tick what the stream must play: (volume, period, waveform), (0,) when silent."""
        return [(int(self.vol[t]), int(self.per[t]), int(self.wave[t])) if self.vol[t] else (0,)
                for t in range(self.T)]


def scc_records(states: list[tuple], max_dur: int = 255) -> list[tuple]:
    """The records (dur, ctl, period or None, waveform or None) of a voice's per-tick states;
    the first gives the period and waveform of the first audible state."""
    first = next((s for s in states if s[0]), (1, 0, 0))
    recs: list[list] = []
    cur = None
    sv_n = sv_w = None
    for s in states:
        if recs and s == cur and recs[-1][0] < max_dur:
            recs[-1][0] += 1
            continue
        cur = s
        v, n, w = s if s[0] else ((0,) + first[1:] if not recs else (0, None, None))
        ctl = v
        word = byte = None
        if n is not None and n != sv_n:
            ctl |= 0x10
            word = sv_n = n
        if w is not None and w != sv_w:
            ctl |= 0x20
            byte = sv_w = w
        recs.append([1, ctl, word, byte])
    return [tuple(r) for r in recs]


def scc_bytes(recs: list[tuple]) -> bytes:
    out = bytearray()
    for d, ctl, n, w in recs:
        out += bytes([d, ctl])
        if n is not None:
            out += bytes([n & 0xFF, n >> 8])
        if w is not None:
            out.append(w)
    out.append(0)
    return bytes(out)


def decode_scc(code: bytes, start: int, ticks: int) -> list[tuple]:
    """The SCC voice player on a stream at `start`: per tick (volume, period, waveform); at
    the end marker it goes on at `start`. Raises on a malformed record."""
    st = {"ptr": start, "left": 0, "vol": 0, "per": None, "wav": None}

    def record() -> None:
        d = code[st["ptr"]]
        st["ptr"] += 1
        if d == 0:
            st["ptr"] = start
            d = code[st["ptr"]]
            st["ptr"] += 1
            if d == 0:
                raise ValueError("an empty stream")
        ctl = code[st["ptr"]]
        st["ptr"] += 1
        if ctl & 0xC0:
            raise ValueError("ctl bits 6-7 set at %d" % (st["ptr"] - 1))
        st["vol"] = ctl & 15
        if ctl & 0x10:
            st["per"] = code[st["ptr"]] | code[st["ptr"] + 1] << 8
            st["ptr"] += 2
            if st["per"] > 4095:
                raise ValueError("period above 4095")
        if ctl & 0x20:
            st["wav"] = code[st["ptr"]]
            st["ptr"] += 1
        st["left"] = d

    record()
    out = []
    for t in range(ticks):
        if t:
            st["left"] -= 1
            if st["left"] == 0:
                record()
        out.append((st["vol"], st["per"], st["wav"]))
    return out


def audible(states: list[tuple]) -> list[tuple]:
    return [s if s[0] else (0,) for s in states]


# ---------------------------------------------------------------------------------------------
# The drums (Amiga channel 3 -> PSG voice C)
# ---------------------------------------------------------------------------------------------

class TitleDrums(ms.Effects):
    """The title's channel 3 as one PSG voice, made as msxsound makes a sound effect's voice
    (Effects._target), its levels against `a_ref` (0 dB = PSG level 15)."""

    def __init__(self, title: ms.Title, a_ref: float):     # (not Effects.__init__: no MU1 here)
        self.insts = title.insts
        self.chans = {3: [title.chans[3]]}
        self.a_ref = a_ref
        self.wave_spc = {i: ms.sample_pitch(x)[0] for i, x in self.insts.items()
                         if len(x.first) < 64 and x.looped}
        self.info = {}
        self.target = self._target(3)


def both_periods_first(recs: list[tuple]) -> list[tuple]:
    """msxsound's records with the first record giving the tone and the noise period (the
    stream's start is its loop point): the first of each the stream uses, moved there."""
    recs = [list(r) for r in recs]
    for k, bit, default in ((2, 0x40, ms.ay_period(ms.DRUM_HZ)), (3, 0x80, 31)):
        j = next((n for n, r in enumerate(recs) if r[k] is not None), None)
        val = default if j is None else recs[j][k]
        if j is not None:
            recs[j][k] = None
            recs[j][1] &= ~bit
        recs[0][k] = val
        recs[0][1] |= bit
    return [tuple(r) for r in recs]


# ---------------------------------------------------------------------------------------------
# The SCC model
# ---------------------------------------------------------------------------------------------

def render_scc(states: list[tuple], table: np.ndarray, ticks: int) -> np.ndarray:
    """One SCC channel at ms.FS: its waveform stepped at SCC_HZ / (N + 1) samples a second (a
    zero-order hold, averaged over each output sample), times volume / 15, full scale 1. The
    phase runs on through period, waveform and volume changes (no reset), as on the chip."""
    out = np.zeros(ticks * ms.SPT)
    ph = 0.0
    j = np.arange(ms.SPT + 1)
    for t in range(ticks):
        v, n, w = states[t]
        step = SCC_HZ / (n + 1) / ms.FS
        p = ph + j * step
        ph = (ph + ms.SPT * step) % WAVE_LEN
        if not v:
            continue
        tab = table[w] / 128.0 * v / 15
        cs = np.concatenate([[0.0], np.cumsum(tab)])
        q = np.floor(p)
        k = q.astype(np.int64) % WAVE_LEN
        c = (q // WAVE_LEN) * cs[WAVE_LEN] + cs[k] + (p - q) * tab[k]
        out[t * ms.SPT:(t + 1) * ms.SPT] = np.diff(c) / step
    return out


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(x ** 2))) if len(x) else 0.0


def write_wav_scaled(path: Path, x: np.ndarray, scale: float, knee: float = 0.9) -> None:
    """ms.write_wav of x times `scale`; the rare peaks above `knee` are bent under full scale
    (a soft knee) instead of clipped."""
    y = x * scale
    a = np.abs(y)
    over = a > knee
    y[over] = np.sign(y[over]) * (knee + (1 - knee) * np.tanh((a[over] - knee) / (1 - knee)))
    p = float(np.percentile(np.abs(y), 99.99))
    ms.write_wav(path, y, peak=p if p > 0 else 0.89)


def read_wav(path: Path) -> np.ndarray | None:
    try:
        with wavfile.open(str(path), "rb") as w:
            if w.getframerate() != ms.FS or w.getnchannels() != 1 or w.getsampwidth() != 2:
                return None
            return np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64) / 32767
    except (OSError, wavfile.Error):
        return None


# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

def offset24(v: int) -> bytes:
    return bytes([v & 0xFF, (v >> 8) & 0xFF, v >> 16])


def write_inc(path: Path, waves: dict[int, Wave], size: int, parts: list[int]) -> None:
    L = ["; generated by tools/msxscc.py from TITM (the title music, tune 1) for a Konami SCC:",
         "; build/msx/scc.bin holds a header of five 24-bit little-endian offsets (SCC voices 0-2,",
         "; the PSG drum stream for voice C, the waveform table of SCC_WAVES x 32 signed bytes), then",
         "; the data. SCC record: dur (1-255 ticks at 50 Hz; 0 = the end: go on at the stream's start),",
         "; ctl (bits 0-3 volume, 4: the period word follows, 5: the waveform byte follows, after the",
         "; word); a field not given keeps the voice's value. The drum stream: sound.inc's PSG format.",
         "; sizes: SCC voices %s, drums %d, waveforms %d, header 15: %d bytes" % (
             "+".join(map(str, parts[:3])), parts[3], parts[4], size),
         "",
         "SCC_WAVES: equ %d" % len(waves),
         "SCC_BYTES: equ %d" % size,
         ""]
    for i, wv in sorted(waves.items(), key=lambda kv: kv[1].number):
        L.append("; waveform %d: instrument %d, sample %d %s" % (
            wv.number, i, wv.sample, "(no NAME chunk)" if wv.name.startswith("#") else wv.name))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(L) + "\n")


def fmt(x, spec: str = "%.2f") -> str:
    return "-" if x is None else spec % x


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "msx",
                    help="directory of scc.bin and scc.inc")
    ap.add_argument("--seconds", type=float, default=60.0, help="the preview's length")
    args = ap.parse_args()

    rep, data = ms.load_music("TITM", "TITM_04.bin")
    title = ms.Title(rep, data)
    T = title.T
    if title.loop_tick:
        print("error: the title's loop does not start at tick 0")
        return 1

    # ---- waveforms, the melodic voices ----
    waves = make_waves(title)
    table = np.array([wv.data for wv in sorted(waves.values(), key=lambda w: w.number)])
    voices = [SccVoice(title, c, waves) for c in range(3)]
    ratios = np.concatenate([v.ratio[v.inst >= 0] for v in voices])
    ref = float(np.percentile(ratios, REF_PCT))
    for v in voices:
        v.quantise(ref)
    wants = [v.intended() for v in voices]
    srecs = [scc_records(w) for w in wants]

    # ---- the drums: levels in the same scale (SCC RMS = Amiga RMS / ref) ----
    a_ref = 0.5 * PSG_OVER_SCC * ref                # a PSG tone at level 15: AC RMS 0.5
    drums = TitleDrums(title, a_ref)
    dtg = drums.target
    dvol = ms.choose_volumes(dtg, DRUM_LAMBDA, False)
    drecs = both_periods_first(ms.records(dtg, dvol))

    # ---- the blob ----
    parts = [scc_bytes(r) for r in srecs] + [ms.stream_bytes(drecs), table.astype(np.int8).tobytes()]
    offs, pos = [], 15
    for p in parts:
        offs.append(pos)
        pos += len(p)
    blob = b"".join(offset24(o) for o in offs) + b"".join(parts)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "scc.bin").write_bytes(blob)
    write_inc(args.out / "scc.inc", waves, len(blob), [len(p) for p in parts])

    print("waveforms (number: instrument, sample; samples per cycle: the fitted cycles', the one "
          "played (Title.pitch, measured; its pitch against the PSG's grid, Title.spc, not used); "
          "windows over the heard bytes (the middle 90 % of the power), harmonics kept; the heard "
          "power that is periodic, above those harmonics, coherent across the windows; its RMS):")
    for i, wv in sorted(waves.items(), key=lambda kv: kv[1].number):
        print("  %d: inst %2d, sample %2d %-10s %6.2f, plays %6.2f (%+3.0f cents from the grid), "
              "%4d windows over %5d-%5d, %2d harmonics; periodic %3.0f %%, above %4.1f %%, coherent "
              "%3.0f %%; RMS %.3f" % (
                  wv.number, i, wv.sample, wv.name, wv.period_used, title.pitch[i][0],
                  1200 * math.log2(title.spc[i] / title.pitch[i][0]), wv.windows, wv.body[0],
                  wv.body[1], wv.harmonics, 100 * wv.periodic, 100 * wv.high_loss,
                  100 * wv.coherence, wv.rms))
    clip = int(np.sum(ratios > ref))
    print("volume reference: amp / waveform RMS %.3f (the %.1fth percentile; %d ticks above, by "
          "%.2f dB at most); re-trigger dips: %s" % (
              ref, REF_PCT, clip, 20 * math.log10(ratios.max() / ref),
              "+".join(str(v.dips) for v in voices)))
    sizes = [len(p) for p in parts]
    print("sizes: SCC voices %s = %d bytes, drums %d (lambda %g), waveforms %d, header 15: "
          "scc.bin %d bytes" % ("+".join(map(str, sizes[:3])), sum(sizes[:3]), sizes[3],
                                DRUM_LAMBDA, sizes[4], len(blob)))
    if sum(sizes[:3]) > MAX_SCC_BYTES:
        print("  warning: the SCC voice streams exceed %d bytes" % MAX_SCC_BYTES)
    print("wrote", args.out / "scc.bin", "and", args.out / "scc.inc")

    # ---- decode the blob as the Z80 player will and check it against the intent ----
    hdr = [blob[3 * k] | blob[3 * k + 1] << 8 | blob[3 * k + 2] << 16 for k in range(5)]
    bad = 0
    sstates = []
    for v in range(3):
        st = decode_scc(blob, hdr[v], T + 20)
        sstates.append(st)
        bad += sum(1 for a, b in zip(audible(st[:T]), wants[v]) if a != b)
        if audible(st[T:T + 20]) != audible(st[:20]):
            print("error: SCC voice %d does not loop seamlessly" % v)
            bad += 1
    dstates = ms.play_streams(blob, [(DRUM_VOICE, hdr[3], hdr[3])], T + 20)
    bad += ms.check_decode(dstates[:T], {DRUM_VOICE: ms.intended(dtg, dvol, T)})
    if [ms.audible_state(s) for s in dstates[T:T + 20]] != [ms.audible_state(s) for s in dstates[:20]]:
        print("error: the drum stream does not loop seamlessly")
        bad += 1
    lens = [sum(r[0] for r in recs) for recs in srecs] + [sum(r[0] for r in drecs)]
    if any(n != T for n in lens):
        print("error: stream lengths %s, not %d ticks" % (lens, T))
        bad += 1
    wt = np.frombuffer(blob[hdr[4]:hdr[4] + len(waves) * WAVE_LEN], np.int8).reshape(-1, WAVE_LEN)
    if not np.array_equal(wt, table):
        print("error: the waveform table does not read back")
        bad += 1
    print("decoded streams against the encoder: %d differing ticks" % bad)

    # ---- previews and the comparison ----
    N = min(T, int(args.seconds * ms.TICK_HZ))
    refs = [c.render(0, N) for c in title.chans]
    scc = [render_scc(sstates[v], table, N) for v in range(3)]
    drum = ms.dc_block(ms.Psg().render(dstates[:N])[DRUM_VOICE]) * PSG_OVER_SCC
    ref_mix, msx_mix = sum(refs), sum(scc) + drum
    wdir = ROOT / "build" / "music" / "preview"
    amiga_wav = wdir / "titm_amiga.wav"
    if not amiga_wav.exists():
        ms.write_wav(amiga_wav, ref_mix)
    # titm_scc.wav as loud as titm_amiga.wav (ms.write_wav's scale), the speech's ticks left out
    speech = np.zeros(N, bool)
    for c in title.chans[:3]:
        speech |= c.ins[:N] == ms.SPEECH_INST
    keep = ~np.repeat(speech, ms.SPT)
    amiga_scale = 0.89 / np.percentile(np.abs(ref_mix), 99.99)
    write_wav_scaled(wdir / "titm_scc.wav", msx_mix,
                     amiga_scale * rms(ref_mix[keep]) / max(rms(msx_mix[keep]), 1e-12))
    gain_db = -20 * math.log10(ref)                 # Amiga RMS -> SCC model RMS

    print("\ntitle, first %d s (Amiga reference rendered from the model vs the decoded streams "
          "on the SCC and PSG models):" % (N // ms.TICK_HZ))
    print("  %-17s %6s %6s %7s %7s %6s  %s" % ("voice", "env r", "MAE", "offset", "covered",
                                                "chroma", "pitch / brightness"))
    for v in range(3):
        e = ms.env_compare(refs[v], scc[v], N)
        hz = np.array([SCC_HZ / (32 * (s[1] + 1)) if s[0] else 0.0 for s in sstates[v][:N]])
        p = ms.pitch_compare(refs[v], hz, N)
        on = np.array([s[0] > 0 for s in sstates[v][:N]])
        b = ms.bright_compare(refs[v], scc[v], N, on)
        da, db = ms.tick_db(refs[v], N) + gain_db, ms.tick_db(scc[v], N)
        m = on & (da > da.max() - 30)
        off = float(np.median(db[m] - da[m])) if m.any() else None
        print("  %-17s %6s %6s %7s %7s %6.3f  pitch on %d ticks: %s within 50 cents, %s same note "
              "name, median %s cents; brightness r %s, %s octaves" % (
                  "channel %d (SCC %d)" % (v, v + 1), fmt(e["r"]), fmt(e["mae_db"], "%.1f dB"),
                  fmt(off, "%+.1f dB"), fmt(e["coverage"]), ms.chroma_similarity(refs[v], scc[v], N),
                  p["ticks"], fmt(p.get("exact"), "%.3f"), fmt(p.get("chroma"), "%.3f"),
                  fmt(p.get("median_cents"), "%.0f"), fmt(b.get("r")), fmt(b.get("diff_oct"), "%+.2f")))
    e = ms.env_compare(refs[3], drum, N)
    on = np.array([bool(s[0][DRUM_VOICE]) for s in dstates[:N]])
    b = ms.bright_compare(refs[3], drum, N, on)
    da, db = ms.tick_db(refs[3], N) + gain_db, ms.tick_db(drum, N)
    m = on & (da > da.max() - 30)
    off = float(np.median(db[m] - da[m])) if m.any() else None
    modes = drums.info[3]["modes"]
    print("  %-17s %6s %6s %7s %7s %6s  %s; brightness r %s, %s octaves" % (
        "channel 3 (PSG C)", fmt(e["r"]), fmt(e["mae_db"], "%.1f dB"), fmt(off, "%+.1f dB"),
        fmt(e["coverage"]), "", ", ".join("%s %d" % kv for kv in modes.items() if kv[1]),
        fmt(b.get("r")), fmt(b.get("diff_oct"), "%+.2f")))
    e = ms.env_compare(ref_mix, msx_mix, N)
    print("  %-17s %6s %6s %7s %7s %6.3f" % (
        "mix", fmt(e["r"]), fmt(e["mae_db"], "%.1f dB"), "", fmt(e["coverage"]),
        ms.chroma_similarity(ref_mix, msx_mix, N)))
    psg = read_wav(wdir / "titm_psg.wav")
    if psg is not None and len(psg) >= N * ms.SPT:
        e = ms.env_compare(ref_mix, psg[:N * ms.SPT], N)
        print("  %-17s %6s %6s %7s %7s %6.3f  (msxsound.py's titm_psg.wav, for reference)" % (
            "PSG version mix", fmt(e["r"]), fmt(e["mae_db"], "%.1f dB"), "", fmt(e["coverage"]),
            ms.chroma_similarity(ref_mix, psg[:N * ms.SPT], N)))
    # each waveform's timbre: brightness on the ticks a voice plays it
    print("  brightness by waveform (SCC - Amiga, octaves, on the ticks it plays):")
    line = []
    for i, wv in sorted(waves.items(), key=lambda kv: kv[1].number):
        d, n = [], 0
        for v in range(3):
            mk = np.array([s[0] > 0 and s[2] == wv.number for s in sstates[v][:N]])
            if mk.sum() >= 2:
                b = ms.bright_compare(refs[v], scc[v], N, mk)
                if b.get("diff_oct") is not None:
                    d.append(b["diff_oct"] * b["ticks"])
                    n += b["ticks"]
        line.append("%s %s" % (wv.name, "%+.2f (%d)" % (sum(d) / n, n) if n else "- (0)"))
    print("    " + ", ".join(line))
    print("\nWAV:", wdir / "titm_scc.wav", "(reference:", amiga_wav, ")")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
