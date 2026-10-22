#!/usr/bin/env python3
"""Robocop 2's 42 in-game sound effects (MU1 tunes 1-42) for an MSX with a Konami SCC: each
effect's tonal part on SCC channel 0-3 (its Amiga channel), its noise part on a PSG voice, as close
to the Amiga as the two chips allow; msxsound.py's effects (one PSG voice each) stay for the
machines without an SCC.

Input: the Amiga model of tools/msxsound.py (rc2music.py's exact per-tick output,
build/music/MU1.json; the samples in build/extracted/files/MU1_09.bin). Output: build/msx/sccfx.bin,
build/msx/sccfx.inc (SCCFX_BYTES, SCCFX_WAVES, a line per effect and per waveform),
build/music/preview/sfx_all_scc.wav (the blob decoded, on msxscc's SCC model plus msxsound's PSG
model, laid out as msxsound's sfx_all_amiga.wav and sfx_all_psg.wav: each effect its length + 2
ticks, then 0.4 s) and a comparison with the Amiga next to msxsound's PSG version. Needs numpy (the
project's venv).

usage: msxsccfx.py [--out build/msx] [--wav build/music/preview]

sccfx.bin: bytes 0-2 the waveform table's offset (24-bit little-endian from the blob's start), byte
3 the number of waveforms W; effect n (1-42) at 4 + 7 (n - 1): its Amiga channel (0-3, sound.inc's
snd_sfx byte), its SCC stream's offset and its PSG stream's (24-bit, 0 = none); then the streams and
the table (W x 32 signed bytes), unaligned. SCC stream: records of dur (1-255 ticks at 50 Hz; 0 =
the end: the channel falls silent) and ctl (bits 0-3 the volume; bit 4: a word follows, the period N
0-4095, little-endian; bit 5: a byte follows, after the word, the waveform number; bits 6-7 zero); a
field not given keeps its value, the first record gives both, identical consecutive states are one
record (split at 255). PSG stream: sound.inc's voice format (msxsound.py). An effect on Amiga
channels 0-2 ends with its last sound; one on channel 3 lasts its whole length, on its SCC stream
(its PSG stream without an SCC part): the priority test looks at channel 3 being busy ($1822C).

How the Amiga sound is mapped (the decisions and why; the numbers are this tool's printout, the
alternatives measured the same way)
- Each tick: Effects._target's measurement, step for step (measure; checked against msxsound's
  modes on every tick): the louder channel (effect 42 plays on two), its level, the YIN period of
  the bytes played (the sample's own pitch at the played rate) and their aperiodicity: tone (342
  ticks), tone + noise (164) or noise (231); the brightness of the Amiga's output.
- Pitch: f = the played rate over the period in bytes, N + 1 = 3579545 / (32 f) (the SCC's step is
  the PSG's). The period (Plan._pitch): YIN's and its octaves (x2 .. /4) in YIN's range (40 Hz - 3
  kHz), each fitted (harmonics at that period, least squares, windows of 2+ cycles a cycle apart);
  of those whose periodic share is near the best, the longest halves while its odd harmonics hold
  under 10 % of the power (a multiple of the period fits as well; under 3 % surely, else the note's
  previous tick decides). YIN slips an octave in short windows (effect 21: 46.9 bytes among 22-25)
  and samples jump an octave (#16: 21 <-> 43 bytes): against YIN on the Amiga's render
  (msxsound.pitch_compare) the per-tick YIN periods agree on 62 % of the tonal ticks, these on 82 %
  (the PSG version: 21 %). Held within 3 cents in a note.
- Sample #0 (effects 19, 27-33, 38: a looped 22-byte waveform): one SCC cycle holds the whole loop,
  at rate / 22 (the PSG version plays its strongest partial, 5.5 bytes: two octaves up): the
  staircase Paula plays (harmonics 1-15: the loop's 11, then its zero-order hold's images; their
  gain and half-step delay) played back through the SCC's own: the Amiga's output itself up to
  harmonic 15 (spectral distance 0.3 dB; the PSG version's 3.0).
- Restart runs (effect 34: a key-on every tick restarts the square-ish #4, 90 bytes a cycle, after
  80-170 bytes): Paula's output repeats at the tick rate (YIN on it: 50.0 Hz while the period
  stays), so the SCC plays 50 Hz, a cycle being a tick's bytes.
- Waveforms: an effect's tonal ticks' harmonic spectra (the fit's power per harmonic times the
  Amiga's zero-order-hold droop at the sample's own steps per cycle; normalised; weighted by
  loudness, amp ** 0.6) clustered: for k = 1-4 the best split into k runs, then a Viterbi assignment
  (the timbre distance: per harmonic the |dB| difference weighted by the power share; CHANGE_DB per
  change) and the means in turn; the k with the least total. A waveform: its ticks' windows' mean
  power per harmonic with the phases of their aligned mean (msxscc.Wave's way), divided by the
  SCC's own zero-order hold (gain and half-step delay at 32 steps a cycle), no DC, scaled to the
  full range; identical ones shared (#0's loop: 9 effects). A change costs about 1000 T-states in
  the VBLANK interrupt: CHANGE_DB 12 makes 20 in all (3 at most in an effect), spectral distance
  3.32 dB; 6: 54 (15 in effect 40), 2.98 dB; none: 3.65 dB.
- Tone + noise ticks: the tick's power split by the fit's periodic share (what the harmonics at its
  period explain, corrected for the 2K + 1 unknowns fitted): that to the SCC, the rest to the PSG.
  The nearest of the splits measured (spectral distance 3.32 dB, |brightness| 0.44 octave; YIN's
  aperiodicity 3.38 / 0.47, a half 3.44 / 0.49, all to the PSG 3.83 / 0.59; all to the SCC 3.32 /
  0.45 but 2.2 dB quieter).
- Levels: one scale for both chips from the Amiga's RMS to the MSX's output (the effects' loudness
  relative to each other, and their parts', as on the Amiga), at openMSX's default balance (msxscc:
  the PSG at 21000, a KonamiSCC ROM's SCC at 9000): the largest that keeps 99 % of the tonal ticks
  within SCC volume 15 (the tonal RMS over the waveform's RMS; a tone tick's over whole cycles) and
  of the noise ticks within PSG level 15. The SCC binds: at volume 15 a channel's RMS (its
  waveform's, 0.33-0.77 of the range with the samples' own phases) is 4-11 dB under a PSG voice's,
  so the scale is 5.0 dB under msxsound's and the effects are 4.8 dB quieter than its PSG version
  (the noise parts reach PSG level 14, the loudest tonal ticks SCC volume 15). The phases that give
  the least crest factor for the same harmonics would gain 0.4-8 dB of RMS, 2.4 dB on the scale,
  but change the waveforms' shapes, audible on these low sounds. The volume: the nearest level in
  dB (mean error 0.3 dB; 3 ticks under -31 dB fall to 0).
- The noise part: msxsound's Target (levels in dB from PSG level 15) and encoder (choose_volumes,
  lambda 0.25; records): noise on, tone off. The noise period: the one that brings the brightness
  of the whole tick (the SCC part as rendered plus the noise: their band powers add) nearest the
  Amiga's, i.e. the noise part's own (3.32 dB / 0.44 octave; from the tick's brightness alone, as
  msxsound: 3.37 / 0.46); held within 0.2 octave. Tone + noise (the AND: the tone chops the noise
  and adds its square's low partials, darker) on noise ticks darker than the PSG's darkest noise
  (9.9 octaves, period 31) where it measurably gets closer: the effect rendered with plain noise
  and with a 60, 100, 150 or 200 Hz tone on all those ticks (noise period 31, +1.25 dB: the AND's
  quarter duty); a tick keeps the tone whose frame spectrum comes nearest the Amiga's, when 2 dB
  nearer than plain noise's (87 ticks: spectral distance 3.65 -> 3.32 dB, |brightness| 0.51 -> 0.44
  octave, the envelope as before).
- The PSG has one noise generator: effects with noise at once share R6 (the last record with noise
  on sets it), as with the PSG version.

The comparison (this version and msxsound's PSG version, encoded and decoded as msxsound does,
against the Amiga rendered from the model): msxsound's envelope comparison (Pearson r of the
per-tick dB, meaningless where the Amiga's envelope is flat, as on sample #0's effects; the MAE
after aligning the medians), the brightness difference on the Amiga's audible ticks (mean, mean
|.|), the pitch agreement (msxsound.pitch_compare: YIN on the Amiga's render from each tick's start
against the tone played: within 50 cents, the same note), the spectral distance (third-octave band
spectra 63 Hz - 8 kHz, each normalised: the power-weighted mean |dB| difference, timbre whatever
the level); totals over the effects. The blob is read back by an independent decoder of the
formats above and checked tick by tick against what the encoder meant.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import msxsound as ms  # noqa: E402  (the Amiga model, the PSG format, encoder and model)
import msxscc as sc  # noqa: E402  (the SCC model, its record format, the SCC/PSG balance)

ROOT = Path(__file__).resolve().parents[1]
N_FX = 42                               # MU1 tunes 1-42
SCC_HZ = sc.SCC_HZ                      # a channel plays SCC_HZ / (32 (N + 1)) Hz
WAVE_LEN = sc.WAVE_LEN                  # 32 signed bytes a waveform
MAX_HARM = sc.MAX_HARM                  # harmonics a 32-point cycle holds below its Nyquist
PSG_OVER_SCC = sc.PSG_OVER_SCC          # a PSG voice's full level over an SCC channel's full range
FIT_MIN = 48                            # a fitting window: 2 cycles or more, this many bytes or more
PITCH_SLACK = 0.06                      # periodic share a candidate period may lose against the best
PERIODIC_MIN = 0.5                      # ... and the least it must keep (else the best one is taken)
ODD_MIN = 0.1                           # odd harmonics' power share under which a period halves ...
ODD_SURE = 0.03                         # ... surely (between the two: ambiguous, continuity decides)
RESTART_RUN = 3                         # one-tick notes in a row that make a restart run
MAX_WAVES_FX = 4                        # waveforms an effect may use (a looped sample's excepted)
CHANGE_DB = 12.0                        # timbre distance (dB x weighted ticks) a waveform change must save


# ---------------------------------------------------------------------------------------------
# The Amiga side: what each tick plays (Effects._target's measurement, then the tonal analysis)
# ---------------------------------------------------------------------------------------------

def measure(fx: ms.Effects, n: int) -> tuple[list, list]:
    """Effects._target's per-tick measurement of effect n, the same steps and constants: per tick
    the louder channel, its level (dB from fx.a_ref), the YIN period of the bytes played (the
    sample's own pitch), its aperiodicity and the Amiga output's brightness, then the medians
    within notes. Returns the rows ([j, level, lag, aperiodicity, brightness] or None when
    silent) and the notes (lists of ticks)."""
    cs = fx.chans[n]
    T = cs[0].T
    refs = [c.render() for c in cs]
    rows: list = []
    for t in range(T):
        j = int(np.argmax([c.amp[t] for c in cs]))
        c = cs[j]
        lv = 20 * math.log10(c.amp[t] / fx.a_ref) if c.amp[t] > 0 else -np.inf
        if lv <= ms.FLOOR_DB:
            rows.append(None)
            continue
        i = int(c.ins[t])
        if i in fx.wave_spc:
            lag, ap = fx.wave_spc[i], 0.0
        else:
            seg = c.bytes_at(t, minimum=256)
            lo = max(2, int(c.rate[t] / 3000))
            hi = min(len(seg) - 64, int(c.rate[t] / 40))
            r = ms.yin(seg, hi, lo=lo) if hi > lo + 2 else None
            lag, ap = (r[0], r[1]) if r else (0.0, 1.0)
        rows.append([j, lv, lag, ap, ms.brightness(ms.frame(refs[j], t)) or 10.0])
    notes, cur = [], []
    for t, r in enumerate(rows):
        if r is None or (cur and (rows[cur[-1]][0] != r[0] or cs[r[0]].keyon[t] or cur[-1] != t - 1)):
            if cur:
                notes.append(cur)
            cur = []
        if r is not None:
            cur.append(t)
    if cur:
        notes.append(cur)
    for note in notes:
        raw_ap = [rows[t][3] for t in note]
        for k, width in ((2, 1), (3, 2), (4, 1)):
            if k == 3 and len(note) < 2 * width + 1:
                continue
            vals = [rows[t][k] for t in note]
            for q, t in enumerate(note):
                lo, hi = max(0, q - width), q + width + 1
                if k == 2:
                    win = [math.log2(x) for x, a in zip(vals[lo:hi], raw_ap[lo:hi])
                           if x > 0 and a < ms.MIX_AP]
                    if len(win) == 3 and rows[t][2] > 0:
                        rows[t][2] = 2 ** float(np.median(win))
                else:
                    rows[t][k] = float(np.median(vals[lo:hi]))
    return rows, notes


def mode_of(row: list | None) -> int:
    """0 tone, 1 tone + noise, 2 noise (Effects._target's thresholds), -1 silent."""
    if row is None:
        return -1
    _, _, lag, ap, _ = row
    return 0 if ap < ms.TONE_AP else 1 if ap < ms.MIX_AP and lag > 0 else 2


def droop(h: np.ndarray, per_cycle: float) -> np.ndarray:
    """A zero-order hold's gain at harmonic h of a cycle of `per_cycle` steps: sinc(h / n)."""
    return np.sinc(h / per_cycle)


def fit_window(inst: ms.Inst, s: int, lag: float, cycles: int) -> tuple[np.ndarray, float, float, float]:
    """The harmonic content of `cycles` cycles of the sample stream from position s: the local
    YIN period (within 10 % of `lag`), harmonics 1..K (K below the sample's own Nyquist at that
    period, MAX_HARM at most) fitted by least squares (msxscc.fit_harmonics). Returns (their
    complex amplitudes padded to MAX_HARM, the AC power share the fit leaves, corrected for the
    2K + 1 unknowns fitted, the period used, the window's AC power)."""
    lo, hi = max(2, int(0.87 * lag)), int(1.15 * lag) + 1
    p = lag
    if hi - lo >= 3:
        r = ms.yin(inst.segment(s, s + int((cycles + 1.5) * lag) + 1), hi, lo=lo)
        if r and abs(r[0] / lag - 1) < 0.1:
            p = r[0]
    k = max(1, min(MAX_HARM, math.ceil(p / 2) - 1))
    x = inst.segment(s, s + max(int(round(cycles * p)), 2 * k + 9))
    h, left = sc.fit_harmonics(x, p, k)
    n = len(x)
    left = min(1.0, left * n / max(1, n - (2 * k + 1)))
    out = np.zeros(MAX_HARM, complex)
    out[:k] = h
    return out, left, p, float(np.var(x))


def tick_fit(c: ms.Channel, t: int, lag: float, restart: bool = False) -> dict:
    """The tick's bytes as windows of 2+ cycles (FIT_MIN bytes or more) a cycle apart over its
    span (one window centred on it when shorter): per window the fit_window results; the tick's
    harmonic powers (their power-weighted mean, as the Amiga's output holds them: times the
    zero-order hold's droop at the sample's own steps per cycle) and its periodic share. With
    `restart` the tick's span is one cycle (a sample restarted every tick: see Plan)."""
    inst = c.insts[int(c.ins[t])]
    a, b = c.span(t)
    hh = np.arange(1, MAX_HARM + 1)
    if restart:
        x = inst.segment(a, b)
        k = max(1, min(MAX_HARM, math.ceil(len(x) / 2) - 1))
        h, u = sc.fit_harmonics(x, len(x), k)
        X = np.zeros((1, MAX_HARM), complex)
        X[0, :k] = h * droop(hh[:k], len(x))
        return {"X": X, "w": np.ones(1), "power": np.abs(X[0]) ** 2, "periodic": 1.0 - u,
                "lag": float(len(x))}
    cyc = max(2, math.ceil(FIT_MIN / lag))
    wlen = cyc * lag
    if b - a <= wlen:
        starts = [max(0, int(round((a + b) / 2 - wlen / 2)))]
    else:
        starts = list(range(a, int(b - wlen) + 1, max(1, int(round(lag)))))
    X, left, per, pw = [], [], [], []
    for s in starts:
        h, u, p, v = fit_window(inst, s, lag, cyc)
        X.append(h * droop(hh, p))
        left.append(u)
        per.append(p)
        pw.append(v)
    w = np.array(pw)
    w = w / w.sum() if w.sum() > 0 else np.full(len(pw), 1 / len(pw))
    X = np.array(X)
    power = w @ (np.abs(X) ** 2)
    return {"X": X, "w": w, "power": power, "periodic": float(1 - w @ np.array(left)),
            "lag": float(w @ np.array(per))}


def odd_share(power: np.ndarray) -> float:
    """The share of the fitted harmonic power in the odd harmonics (1, 3, 5, ...)."""
    tot = float(power.sum())
    return float(power[0::2].sum()) / tot if tot > 0 else 1.0


class Plan:
    """What effect n plays, tick by tick, split into its tonal part (for the SCC) and its noise
    part (for the PSG): the Amiga channel (the louder one), the mode, the tonal part's period in
    samples (lag) and frequency, its periodic power share, the levels of both parts (RMS, full
    scale 1) and the harmonic analysis of the bytes played."""

    def __init__(self, fx: ms.Effects, n: int):
        self.n = n
        cs = fx.chans[n]
        self.cs = cs
        T = cs[0].T
        self.T = T
        self.channel = fx.info[n]["main"]
        rows, notes = measure(fx, n)
        self.rows, self.notes = rows, notes
        tg = fx.targets[n]
        self.replica_ok = all(
            (bool(tg.tone[t]), bool(tg.noise[t])) == ((m in (0, 1)), (m in (1, 2))) if m >= 0
            else not tg.audible(t) for t, m in ((t, mode_of(rows[t])) for t in range(T)))
        self.mode = np.array([mode_of(r) for r in rows])
        self.src = np.full(T, -1)
        self.inst = np.full(T, -1)
        self.rate = np.zeros(T)
        self.amp = np.zeros(T)
        self.lag0 = np.zeros(T)                 # Effects._target's period (samples), after medians
        self.lag = np.zeros(T)                  # the tonal part's period (samples)
        self.periodic = np.zeros(T)             # the tonal part's power share
        self.amp_t = np.zeros(T)                # the tonal part's RMS
        self.amp_n = np.zeros(T)                # the noise part's RMS
        self.bright = np.zeros(T)               # the Amiga output's brightness (medians in notes)
        self.keyon = np.zeros(T, bool)
        self.f = np.zeros(T)                    # the tonal part's frequency (Hz)
        self.fits: list[dict | None] = [None] * T
        self.loop_inst = {i for i in fx.wave_spc}
        for t, r in enumerate(rows):
            if r is None:
                continue
            j, _, lag, _, br = r
            c = cs[j]
            self.src[t] = c.ch
            self.inst[t] = int(c.ins[t])
            self.rate[t] = c.rate[t]
            self.amp[t] = c.amp[t]
            self.lag0[t] = lag
            self.bright[t] = br
            self.keyon[t] = bool(c.keyon[t])
        self._tonal(fx)

    def _tonal(self, fx: ms.Effects) -> None:
        """The tonal part of each tone and tone + noise tick: its period (Plan._pitch, or one cycle
        a tick in a restart run), its share of the power (all of it on tone ticks, the fit's
        periodic share on tone + noise ticks) and level: a tone tick's over whole cycles
        (msxscc.cycle_amp: a tick of 1.5 cycles would swing with the phase), a tone + noise tick's
        the tick's power split between the two parts."""
        cs = self.cs
        self.restart = self._restarts()
        for note in self.notes:
            mixl = [self.lag0[t] for t in note if self.mode[t] == 1 and self.lag0[t] > 0]
            mix_lag = float(np.median(mixl)) if mixl else 0.0
            prev = None
            for t in note:
                m = self.mode[t]
                if m == 2:
                    self.amp_n[t] = self.amp[t]
                    continue
                c = cs[self.rows[t][0]]
                i = int(self.inst[t])
                if i in self.loop_inst:                     # a looped waveform: the whole loop
                    self.lag[t] = len(fx.insts[i].loop)
                    self.f[t] = self.rate[t] / self.lag[t]
                    self.periodic[t] = 1.0
                    self.amp_t[t] = sc.cycle_amp(c, t, self.lag[t])
                    continue
                if self.restart[t]:
                    f = tick_fit(c, t, 0.0, restart=True)
                    self.f[t] = ms.TICK_HZ
                    amp_c = self.amp[t]
                else:
                    f = self._pitch(c, t, [self.lag0[t]] + ([mix_lag] if m == 1 else []), prev)
                    self.f[t] = self.rate[t] / f["lag"]
                    amp_c = sc.cycle_amp(c, t, f["lag"]) if m == 0 else self.amp[t]
                prev = f["lag"]
                self.fits[t] = f
                self.lag[t] = f["lag"]
                self.periodic[t] = 1.0 if m == 0 else max(0.0, f["periodic"])
                self.amp_t[t] = math.sqrt(self.periodic[t]) * amp_c
                self.amp_n[t] = math.sqrt(max(0.0, 1 - self.periodic[t])) * self.amp[t]

    def _pitch(self, c: ms.Channel, t: int, bases: list[float], prev: float | None) -> dict:
        """The tick's period. Candidates: the YIN period (and on a tone + noise tick the note's
        median one) and their octaves within YIN's range, each fitted (tick_fit). The ones within
        PITCH_SLACK of the best periodic share (and PERIODIC_MIN or more; none: the best) are
        near; from the longest near one the period halves while its odd harmonics hold under
        ODD_MIN of the fitted power and the half is near too (a multiple of the period fits as
        well as the period, with odd harmonics of nothing: YIN's minimum slips an octave down in
        short windows, or the sample's pitch jumps an octave). On that chain a step whose odd
        share is ODD_SURE or more is ambiguous (a weak subharmonic): of the steps left the one
        nearest the note's previous tick, else the last (the shortest)."""
        lo, hi = max(2.0, c.rate[t] / 3000), c.rate[t] / 40
        cands: list[float] = []
        for b in bases:
            if b <= 0:
                continue
            for k in (1, 0, -1, -2):
                x = b * 2.0 ** k
                if lo <= x <= hi and all(abs(math.log2(x / y)) > 0.03 for y in cands):
                    cands.append(x)
        if not cands:
            cands = [min(max(bases[0], lo), hi)]
        fits = [tick_fit(c, t, x) for x in cands]
        best = max(f["periodic"] for f in fits)
        near = sorted((f for f in fits if f["periodic"] >= max(best - PITCH_SLACK, PERIODIC_MIN)),
                      key=lambda f: -f["lag"])
        if not near:
            return max(fits, key=lambda f: f["periodic"])
        chain = [near[0]]
        while odd_share(chain[-1]["power"]) < ODD_MIN:
            half = [f for f in near if abs(math.log2(2 * f["lag"] / chain[-1]["lag"])) < 0.1]
            if not half:
                break
            chain.append(half[0])
        left = [f for f in chain[:-1] if odd_share(f["power"]) >= ODD_SURE] + [chain[-1]]
        if prev:
            return min(left, key=lambda f: abs(math.log2(f["lag"] / prev)))
        return left[-1]

    def _restarts(self) -> np.ndarray:
        """Ticks of restart runs: RESTART_RUN or more one-tick notes in a row (a key-on every tick)
        whose ticks hold under two cycles of the sample's own (YIN) period: the Amiga restarts the
        sample every tick, so its output repeats at the tick rate (effect 34: exactly 50 Hz while
        the period stays), not at the sample's pitch."""
        T = self.T
        single = np.zeros(T, bool)
        for note in self.notes:
            t = note[0]
            if (len(note) == 1 and self.mode[t] in (0, 1) and self.inst[t] not in self.loop_inst
                    and self.lag0[t] > 0):
                a, b = self.cs[self.rows[t][0]].span(t)
                single[t] = (b - a) < 2 * self.lag0[t]
        out = np.zeros(T, bool)
        t = 0
        while t < T:
            if not single[t]:
                t += 1
                continue
            u = t
            while u + 1 < T and single[u + 1] and self.src[u + 1] == self.src[t]:
                u += 1
            if u - t + 1 >= RESTART_RUN:
                out[t:u + 1] = True
            t = u + 1
        return out


# ---------------------------------------------------------------------------------------------
# Waveforms
# ---------------------------------------------------------------------------------------------

EPS_SPEC = 1e-3                         # the timbre distance's floor (-30 dB of a tick's power)


def timbre_distances(S: np.ndarray, Q: np.ndarray) -> np.ndarray:
    """How far each harmonic power spectrum (a row of S) is from Q in shape: each normalised to a
    sum of 1, the |dB difference| per harmonic weighted by their mean share (floor EPS_SPEC)."""
    S = S / np.maximum(S.sum(1, keepdims=True), 1e-30)
    Q = Q / max(float(Q.sum()), 1e-30)
    return np.sum((S + Q) / 2 * np.abs(10 * np.log10((S + EPS_SPEC) / (Q + EPS_SPEC))), axis=1)


def cycle_from_harmonics(Y: np.ndarray) -> np.ndarray:
    """A WAVE_LEN-point cycle from complex harmonic amplitudes 1..MAX_HARM (x = Re sum Y_h
    exp(2 pi i h n / WAVE_LEN)), no DC, scaled to the full signed range, as int8."""
    hh = np.arange(1, MAX_HARM + 1)
    basis = np.exp(2j * np.pi * np.outer(np.arange(WAVE_LEN), hh) / WAVE_LEN)
    cyc = (Y[None, :] * basis).real.sum(1)
    s = min(127 / cyc.max(), 128 / -cyc.min())
    return np.clip(np.round(cyc * s), -128, 127).astype(np.int8)


def scc_harmonics(X: np.ndarray) -> np.ndarray:
    """The SCC waveform's harmonics that play the Amiga output's X (harmonics 1..MAX_HARM, the
    Amiga's own droop included): divided by the SCC's own zero-order hold at WAVE_LEN steps a
    cycle (its gain and half-step delay)."""
    hh = np.arange(1, MAX_HARM + 1)
    return X / (droop(hh, WAVE_LEN) * np.exp(-1j * np.pi * hh / WAVE_LEN))


def loop_wave(loop: np.ndarray) -> np.ndarray:
    """A looped waveform (sample #0: 22 bytes) as one SCC cycle: the Fourier series of the
    staircase Paula plays (harmonic m: the loop's DFT bin m mod L, its zero-order hold's gain
    and half-step delay), harmonics 1..MAX_HARM (the loop's own up to L / 2, the staircase's
    images above), as the SCC's zero-order hold plays them back."""
    L = len(loop)
    D = np.fft.fft(loop) / L
    hh = np.arange(1, MAX_HARM + 1)
    X = 2 * D[hh % L] * droop(hh, L) * np.exp(-1j * np.pi * hh / L)
    return cycle_from_harmonics(scc_harmonics(X))


def aligned_mean(X: np.ndarray, w: np.ndarray) -> np.ndarray:
    """The windows' harmonics (rows of X, complex) as one cycle: their weighted mean power per
    harmonic, with the phases of their mean after each window is shifted onto it (the best of
    1024 shifts, 4 rounds: msxscc.Wave's way; the phases drift between windows)."""
    w = w / w.sum()
    power = w @ (np.abs(X) ** 2)
    hh = np.arange(1, X.shape[1] + 1)
    shifts = np.exp(2j * np.pi * np.outer(np.arange(1024) / 1024, hh))
    ref = X[int(np.argmax(w))]
    for _ in range(4):
        score = ((X * np.conj(ref)) @ shifts.T).real
        ref = w @ (X * shifts[np.argmax(score, axis=1)])
    return np.sqrt(power) * np.exp(1j * np.angle(ref))


def _segments(S: np.ndarray, w: np.ndarray, k: int) -> np.ndarray:
    """The best split of the ticks (in order) into k runs, each with its weighted mean spectrum:
    the labels."""
    m = len(S)
    seg = np.full((m, m + 1), np.inf)
    for i in range(m):
        for j in range(i + 1, m + 1):
            Q = (w[i:j, None] * S[i:j]).sum(0) / w[i:j].sum()
            seg[i, j] = float(w[i:j] @ timbre_distances(S[i:j], Q))
    D = np.full((k + 1, m + 1), np.inf)
    arg = np.zeros((k + 1, m + 1), np.int64)
    D[0, 0] = 0.0
    for q in range(1, k + 1):
        for j in range(q, m + 1):
            c = D[q - 1, :j] + seg[:j, j]
            arg[q, j] = int(np.argmin(c))
            D[q, j] = c[arg[q, j]]
    lab = np.zeros(m, np.int64)
    j = m
    for q in range(k, 0, -1):
        i = arg[q, j]
        lab[i:j] = q - 1
        j = i
    return lab


def _assign(S: np.ndarray, w: np.ndarray, Q: np.ndarray, lam: float) -> tuple[np.ndarray, float]:
    """The waveform of each tick (in order) minimising the weighted timbre distance plus lam per
    change: a Viterbi pass. Returns the labels and the total."""
    m, k = len(S), len(Q)
    d = np.stack([w * timbre_distances(S, Q[a]) for a in range(k)], axis=1)
    cost = d[0].copy()
    back = np.zeros((m, k), np.int64)
    pen = lam * (1 - np.eye(k))
    for i in range(1, m):
        trans = cost[:, None] + pen
        back[i] = np.argmin(trans, axis=0)
        cost = trans[back[i], np.arange(k)] + d[i]
    lab = np.zeros(m, np.int64)
    lab[-1] = int(np.argmin(cost))
    for i in range(m - 1, 0, -1):
        lab[i - 1] = back[i, lab[i]]
    return lab, float(cost.min())


def cluster_ticks(S: np.ndarray, w: np.ndarray, kmax: int, lam: float) -> tuple[np.ndarray, int]:
    """Waveforms for a run of tonal ticks (rows of S: their harmonic powers; w: their weights):
    for k = 1..kmax the best split into k runs, then the Viterbi assignment and the means in
    turn until they settle; the k whose distance + lam x changes is least. Returns the labels
    (0..k-1, numbered in order of first use) and k."""
    best = None
    for k in range(1, min(kmax, len(S)) + 1):
        lab = _segments(S, w, k)
        total = np.inf
        for _ in range(12):
            Q = np.array([(w[lab == a, None] * S[lab == a]).sum(0) / w[lab == a].sum()
                          for a in range(k) if np.any(lab == a)])
            new, total = _assign(S, w, Q, lam)
            if np.array_equal(new, lab):
                break
            lab = new
        if best is None or total < best[0] - 1e-9:
            best = (total, lab)
    lab = best[1]
    order = {}
    for a in lab:
        order.setdefault(int(a), len(order))
    lab = np.array([order[int(a)] for a in lab])
    return lab, len(order)


class Waves:
    """The effects' waveform table: each entry WAVE_LEN signed bytes, numbered in order of first
    use; identical ones shared."""

    def __init__(self):
        self.data: list[np.ndarray] = []
        self.what: list[str] = []
        self.users: list[list[int]] = []

    def add(self, cyc: np.ndarray, what: str, n: int) -> int:
        for i, d in enumerate(self.data):
            if np.array_equal(d, cyc):
                if n not in self.users[i]:
                    self.users[i].append(n)
                return i
        self.data.append(cyc)
        self.what.append(what)
        self.users.append([n])
        return len(self.data) - 1

    def rms(self, i: int) -> float:
        return float(np.sqrt(np.mean((self.data[i] / 128.0) ** 2)))

    def table(self) -> np.ndarray:
        return np.array(self.data, np.int8).reshape(-1, WAVE_LEN)


def make_waves(fx: ms.Effects, plans: dict[int, Plan], waves: Waves,
               change_db: float = CHANGE_DB) -> None:
    """Each plan's waveform per tonal tick (plan.wave): a looped waveform's own cycle (loop_wave,
    shared by every effect that plays it); else the effect's own waveforms: its tonal ticks'
    harmonic spectra (normalised, weighted by loudness: amp_t ** 0.6) clustered (cluster_ticks,
    at most MAX_WAVES_FX, CHANGE_DB per change), each cluster's cycle the aligned mean of its
    ticks' windows (each tick's spectrum normalised, so every tick counts by its weight)."""
    for n in sorted(plans):
        pl = plans[n]
        pl.wave = np.full(pl.T, -1)
        for t in range(pl.T):
            i = int(pl.inst[t])
            if pl.amp_t[t] > 0 and i in pl.loop_inst:
                pl.wave[t] = waves.add(loop_wave(fx.insts[i].loop), "sample #%d's %d-byte loop" % (
                    fx.insts[i].sample, len(fx.insts[i].loop)), n)
        ticks = [t for t in range(pl.T) if pl.amp_t[t] > 0 and pl.fits[t] is not None]
        if not ticks:
            continue
        S = np.array([pl.fits[t]["power"] / max(pl.fits[t]["power"].sum(), 1e-30) for t in ticks])
        w = np.array([pl.amp_t[t] ** 0.6 for t in ticks])
        w = w / w.mean()
        lab, k = cluster_ticks(S, w, MAX_WAVES_FX, change_db)
        names = sorted({fx.insts[int(pl.inst[t])].name for t in ticks})
        for a in range(k):
            X, W = [], []
            tt = [t for t, la in zip(ticks, lab) if la == a]
            for i, t in enumerate(ticks):
                if lab[i] != a:
                    continue
                f = pl.fits[t]
                norm = math.sqrt(max(float(f["power"].sum()), 1e-30))
                for row, ww in zip(f["X"], f["w"]):
                    X.append(row / norm)
                    W.append(ww * w[i])
            Y = aligned_mean(np.array(X), np.array(W))
            idx = waves.add(cycle_from_harmonics(scc_harmonics(Y)), "effect %d, %s, %d tick%s from %d" % (
                n, "+".join(names), len(tt), "s" if len(tt) > 1 else "", tt[0]), n)
            for t in tt:
                pl.wave[t] = idx


# ---------------------------------------------------------------------------------------------
# Levels, the SCC part, the PSG part
# ---------------------------------------------------------------------------------------------

LEVEL_PCT = 99.0                        # percentile of each part's ticks that reaches its chip's top
PITCH_TOL = 3.0                         # cents a note's period may drift before a new period word
NOISE_TOL = 0.2                         # octaves of brightness before a new noise period
PSG_LAMBDA = 0.25                       # the noise part's bytes-vs-distortion trade-off (ms.choose_volumes)
GATE_HZ = (60.0, 100.0, 150.0, 200.0)   # tone frequencies tried for tone + noise on dark noise ticks ...
GATE_GAIN_DB = 2.0                      # ... kept on a tick only when its spectrum gets this much closer
GATE_DB = 1.25                          # the tone AND noise's RMS is this much under the noise's


def band_power(x: np.ndarray) -> float:
    """The power ms.brightness weighs (a Hann-windowed frame's spectrum over ms.BAND)."""
    if len(x) < 64:
        return 0.0
    n = 2048
    X = np.abs(np.fft.rfft((x - x.mean()) * np.hanning(len(x)), n)) ** 2
    f = np.fft.rfftfreq(n, 1 / ms.FS)
    m = (f >= ms.BAND[0]) & (f <= ms.BAND[1])
    return float(X[m].sum())


_NOISE_BAND: np.ndarray | None = None


def noise_band() -> np.ndarray:
    """Per noise period 0-31 the band power (band_power, a 1024-sample frame) of the PSG's noise
    per unit of its AC power (measured on the model, as ms.noise_brightness)."""
    global _NOISE_BAND
    if _NOISE_BAND is None:
        out = [0.0]
        for npd in range(1, 32):
            st = [((15, 0, 0), (False,) * 3, (True, False, False), (1, 1, 1), npd)] * 12
            sig = ms.dc_block(ms.Psg().render(st)[0])
            vals = [band_power(ms.frame(sig, t)) / max(float(np.var(ms.frame(sig, t))), 1e-30)
                    for t in range(2, 11)]
            out.append(float(np.mean(vals)))
        out[0] = out[1]
        _NOISE_BAND = np.array(out)
    return _NOISE_BAND


def scc_period(f: float) -> int:
    return int(min(4095, max(0, round(SCC_HZ / (WAVE_LEN * f)) - 1)))


def choose_gain(plans: dict[int, Plan], waves: Waves) -> dict:
    """The one scale from the Amiga's RMS to the MSX's output (in the SCC's units: a channel's
    full range +-1; a PSG voice at level 15 swings 0..PSG_OVER_SCC): the largest that keeps
    LEVEL_PCT % of the tonal ticks within SCC volume 15 (the waveform's RMS at volume 15) and of
    the noise ticks within PSG level 15 (a noise's RMS: half its level). One scale for both chips
    keeps the effects' loudness relative to each other and between their parts as on the
    Amiga."""
    xs = [pl.amp_t[t] / waves.rms(int(pl.wave[t])) for pl in plans.values() for t in range(pl.T)
          if pl.amp_t[t] > 0 and pl.wave[t] >= 0]
    ys = [pl.amp_n[t] / (0.5 * PSG_OVER_SCC) for pl in plans.values() for t in range(pl.T)
          if pl.amp_n[t] > 0]
    g_scc = 1 / float(np.percentile(xs, LEVEL_PCT))
    g_psg = 1 / float(np.percentile(ys, LEVEL_PCT))
    return {"gain": min(g_scc, g_psg), "scc": g_scc, "psg": g_psg}


def scc_states(pl: Plan, waves: Waves, gain: float) -> list[tuple]:
    """The SCC part tick by tick: (volume, period N, waveform) or (0,) when silent. The volume
    the nearest (in dB) to 15 x gain x the tonal RMS / the waveform's RMS; the period from the
    tonal frequency, held while within PITCH_TOL cents in a note (a key-on or a new waveform
    takes its own)."""
    out = []
    ref_n = ref_w = None
    for t in range(pl.T):
        if pl.amp_t[t] <= 0 or pl.wave[t] < 0:
            out.append((0,))
            continue
        w = int(pl.wave[t])
        v = sc.nearest_level(15 * gain * pl.amp_t[t] / waves.rms(w))
        n = scc_period(pl.f[t])
        if (ref_n is None or pl.keyon[t] or w != ref_w
                or abs(1200 * math.log2((ref_n + 1) / (n + 1))) >= PITCH_TOL):
            ref_n, ref_w = n, w
        out.append((v, ref_n, w) if v else (0,))
    return out


def scc_render_states(states: list[tuple], ticks: int) -> list[tuple]:
    """Per-tick SCC states for sc.render_scc: (volume, N, waveform), the last N and waveform held
    through silence (the first given at the start)."""
    first = next((s for s in states if s[0]), (1, 0, 0))
    n, w = first[1], first[2]
    out = []
    for t in range(ticks):
        s = states[t] if t < len(states) else (0,)
        if s[0]:
            n, w = s[1], s[2]
            out.append(s)
        else:
            out.append((0, n, w))
    return out


def psg_target(pl: Plan, gain: float, scc_sig: np.ndarray) -> ms.Target:
    """The noise part as a PSG voice's target (ms.Target: levels in dB from level 15, noise on,
    tone off): the level from gain x the noise RMS (a noise's RMS is half its level); the noise
    period the one that brings the brightness of the tick's whole sound (the SCC part as rendered
    plus the noise, their band powers adding) nearest the Amiga's (Plan.bright), i.e. the noise
    part's own brightness; held while within NOISE_TOL octaves (ms.smooth_noise)."""
    T = pl.T
    tg = ms.Target(T)
    nb = ms.noise_brightness()
    kb = noise_band()
    for t in range(T):
        if pl.amp_n[t] <= 0:
            continue
        lv = 20 * math.log10(gain * pl.amp_n[t] / (0.5 * PSG_OVER_SCC))
        if lv <= ms.FLOOR_DB:
            continue
        tg.lvl[t] = lv
        tg.noise[t] = True
        tg.src[t] = pl.src[t]
        fr = ms.frame(scc_sig, t)
        ps = band_power(fr) if np.any(fr) else 0.0
        bs = ms.brightness(fr) if ps > 0 else None
        pn = (gain * pl.amp_n[t]) ** 2 * kb
        if bs is None:
            mix = nb
        else:
            mix = (ps * bs + pn * np.array(nb)) / (ps + pn)
        tg.np[t] = int(1 + np.argmin(np.abs(np.array(mix[1:]) - pl.bright[t])))
    ms.smooth_noise(tg, NOISE_TOL)
    return tg


def set_accents(pl: Plan, tg: ms.Target) -> None:
    """A key-on that keeps the noise part's fields must change its level (ms.choose_volumes'
    accent: Paula restarts the sample, the PSG's noise would run on as one sound)."""
    for t in range(1, pl.T):
        tg.accent[t] = bool(pl.keyon[t] and tg.audible(t) and tg.audible(t - 1)
                            and tg.fields(t - 1) == tg.fields(t))


def spectral_distance(x: np.ndarray, y: np.ndarray) -> float:
    """Two frames' third-octave band spectra, each normalised: the power-weighted mean |dB
    difference| (floor EPS_SPEC): how far apart their timbres are, whatever their levels."""
    u, v = band_levels(x), band_levels(y)
    u, v = u / max(u.sum(), 1e-30), v / max(v.sum(), 1e-30)
    return float(np.sum((u + v) / 2 * np.abs(10 * np.log10((u + EPS_SPEC) / (v + EPS_SPEC)))))


def render_target(tg: ms.Target, vol: np.ndarray) -> np.ndarray:
    """A PSG part's target at the given volumes, as its decoded registers on the PSG model (SCC
    units)."""
    st = []
    for v, tone, noise, per, npd in ms.intended(tg, vol, tg.T):
        st.append(((v, 0, 0), (tone, False, False), (noise, False, False), (per or 1, 1, 1), npd or 0))
    return ms.dc_block(ms.Psg().render(st)[0]) * PSG_OVER_SCC


def gate_noise(fx: ms.Effects, pl: Plan, tg: ms.Target, scc_sig: np.ndarray) -> None:
    """Tone + noise (the PSG's AND: the tone chops the noise, its square adds low partials) on the
    noise ticks darker than the PSG's darkest noise (period 31), where it measurably gets closer
    to the Amiga: the whole effect rendered (the SCC part plus the PSG part) with plain noise and
    with each GATE_HZ tone on all those ticks (noise period 31, the level GATE_DB up); a tick
    takes the tone whose output frame's spectral distance to the Amiga's is least, when it beats
    plain noise's by GATE_GAIN_DB or more."""
    dark = ms.noise_brightness()[31]
    cand = [t for t in range(pl.T) if tg.noise[t] and tg.audible(t) and pl.bright[t] < dark]
    if not cand:
        return
    ref = sum(c.render() for c in pl.cs)

    def dist(t_: ms.Target) -> np.ndarray:
        out = scc_sig + render_target(t_, ms.choose_volumes(t_, PSG_LAMBDA, False))
        return np.array([spectral_distance(ms.frame(ref, t), ms.frame(out, t)) for t in cand])
    base = dist(tg)
    best = base.copy()
    choice = [None] * len(cand)
    for hz in GATE_HZ:
        g = ms.Target(pl.T)
        for f in ("lvl", "tone", "noise", "per", "np", "accent", "src", "drum"):
            setattr(g, f, getattr(tg, f).copy())
        for t in cand:
            g.tone[t], g.per[t], g.np[t] = True, ms.ay_period(hz), 31
            g.lvl[t] += GATE_DB
        d = dist(g)
        for k in range(len(cand)):
            if d[k] < best[k] and d[k] <= base[k] - GATE_GAIN_DB:
                best[k], choice[k] = d[k], hz
    pl.gated = 0
    for t, hz in zip(cand, choice):
        if hz is not None:
            tg.tone[t], tg.per[t], tg.np[t] = True, ms.ay_period(hz), 31
            tg.lvl[t] += GATE_DB
            pl.gated += 1


# ---------------------------------------------------------------------------------------------
# Streams, the blob, an independent decoder
# ---------------------------------------------------------------------------------------------

HEADER = 4 + 7 * N_FX


def trim(recs: list[tuple], keep: int | None) -> list[tuple]:
    """A one-shot stream's records: the trailing silence dropped (the end marker silences the
    voice); with `keep`, silence padded up to that many ticks."""
    recs = [list(r) for r in recs]
    while recs and recs[-1][1] == 0:
        recs.pop()
    if keep is not None:
        t = sum(r[0] for r in recs)
        while t < keep:
            d = min(255, keep - t)
            recs.append([d, 0, None, None])
            t += d
    return [tuple(r) for r in recs]


def offset24(v: int) -> bytes:
    return bytes([v & 0xFF, (v >> 8) & 0xFF, v >> 16])


def build_blob(streams: dict[int, dict], table: np.ndarray) -> tuple[bytes, dict]:
    """sccfx.bin: bytes 0-2 the waveform table's offset, byte 3 its count; per effect n at
    4 + 7 (n - 1): its Amiga channel, its SCC stream's offset, its PSG stream's offset (24-bit
    little-endian from the blob's start, 0 = none); the streams; the table."""
    body = bytearray()
    offs = {}
    for n in range(1, N_FX + 1):
        st = streams[n]
        so = po = 0
        if st["scc"] is not None:
            so = HEADER + len(body)
            body += st["scc"]
        if st["psg"] is not None:
            po = HEADER + len(body)
            body += st["psg"]
        offs[n] = (st["channel"], so, po)
    woff = HEADER + len(body)
    head = bytearray(offset24(woff) + bytes([len(table)]))
    for n in range(1, N_FX + 1):
        ch, so, po = offs[n]
        head += bytes([ch]) + offset24(so) + offset24(po)
    blob = bytes(head) + bytes(body) + table.astype(np.int8).tobytes()
    return blob, offs


def u24(b: bytes, i: int) -> int:
    return b[i] | b[i + 1] << 8 | b[i + 2] << 16


def decode_scc(b: bytes, start: int, waves: int, ticks: int) -> tuple[list[tuple], int, int]:
    """The SCC stream format read back, independently of the encoder: per tick (volume, N,
    waveform) for `ticks` ticks (silent, the fields kept, after the end marker); the stream's
    length in ticks and its waveform loads. Raises on anything the format forbids."""
    ptr, out, vol, per, wav, loads, first = start, [], 0, None, None, 0, True
    while True:
        d = b[ptr]
        ptr += 1
        if d == 0:
            break
        ctl = b[ptr]
        ptr += 1
        if ctl & 0xC0:
            raise ValueError("SCC ctl bits 6-7 set at %d" % (ptr - 1))
        if first and (ctl & 0x30) != 0x30:
            raise ValueError("the first SCC record gives no period or waveform at %d" % start)
        first = False
        vol = ctl & 15
        if ctl & 0x10:
            per = b[ptr] | b[ptr + 1] << 8
            ptr += 2
            if per > 4095:
                raise ValueError("SCC period above 4095")
        if ctl & 0x20:
            wav = b[ptr]
            ptr += 1
            loads += 1
            if wav >= waves:
                raise ValueError("waveform %d of %d" % (wav, waves))
        out += [(vol, per, wav)] * d
    length = len(out)
    out = (out + [(0, per, wav)] * ticks)[:ticks]
    return out, length, loads


def decode_psg(b: bytes, start: int, ticks: int) -> tuple[list[tuple], int]:
    """sndplay.asm's PSG voice format read back, independently of msxsound: per tick (volume,
    tone on, noise on, tone period, noise period) for `ticks` ticks (silent after the end
    marker); the stream's length. Raises when a record uses a period no record gave yet or a
    silent record is not ctl 0."""
    ptr, out = start, []
    per = npd = None
    while True:
        d = b[ptr]
        ptr += 1
        if d == 0:
            break
        ctl = b[ptr]
        ptr += 1
        if ctl & 0x40:
            per = (b[ptr] | b[ptr + 1] << 8) & 0xFFF
            ptr += 2
        if ctl & 0x80:
            npd = b[ptr] & 31
            ptr += 1
        vol, tone, noise = ctl & 15, bool(ctl & 0x10), bool(ctl & 0x20)
        if vol == 0 and ctl != 0:
            raise ValueError("a silent PSG record with ctl %02X" % ctl)
        if (tone and per is None) or (noise and npd is None):
            raise ValueError("a PSG record uses a period not given yet")
        out += [(vol, tone, noise, per, npd)] * d
    length = len(out)
    out = (out + [(0, False, False, per, npd)] * ticks)[:ticks]
    return out, length


def decode_blob(b: bytes, ticks: dict[int, int]) -> dict:
    """The whole blob read back: the table and per effect its channel and decoded parts."""
    woff, W = u24(b, 0), b[3]
    table = np.frombuffer(b[woff:woff + W * WAVE_LEN], np.int8).reshape(W, WAVE_LEN)
    if woff + W * WAVE_LEN != len(b):
        raise ValueError("the waveform table does not end the blob")
    out = {"table": table, "fx": {}}
    for n in range(1, N_FX + 1):
        e = 4 + 7 * (n - 1)
        ch, so, po = b[e], u24(b, e + 1), u24(b, e + 4)
        if ch > 3:
            raise ValueError("effect %d: channel %d" % (n, ch))
        d = {"channel": ch, "scc": None, "psg": None}
        if so:
            d["scc"] = decode_scc(b, so, W, ticks[n])
        if po:
            d["psg"] = decode_psg(b, po, ticks[n])
        out["fx"][n] = d
    return out


def psg_states(dec: list[tuple]) -> list[tuple]:
    """Decoded PSG voice ticks as ms.Psg's register states (on voice A)."""
    out = []
    for vol, tone, noise, per, npd in dec:
        out.append(((vol, 0, 0), (tone, False, False), (noise, False, False),
                    (per or 1, 1, 1), npd or 0))
    return out


# ---------------------------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------------------------

def bands() -> list[tuple[float, float]]:
    """Third-octave bands from 63 Hz to 8 kHz."""
    return [(63 * 2 ** ((k - 0.5) / 3), 63 * 2 ** ((k + 0.5) / 3)) for k in range(22)]


def band_levels(x: np.ndarray) -> np.ndarray:
    n = 2048
    X = np.abs(np.fft.rfft((x - x.mean()) * np.hanning(len(x)), n)) ** 2
    f = np.fft.rfftfreq(n, 1 / ms.FS)
    return np.array([X[(f >= a) & (f < b)].sum() for a, b in bands()])


def compare(ref: np.ndarray, out: np.ndarray, hz: np.ndarray, T: int) -> dict:
    """The MSX output against the Amiga reference: msxsound's envelope comparison and pitch
    agreement (ms.env_compare, ms.pitch_compare: the MSX's tone frequency per tick); on the
    reference's audible ticks (within 30 dB of its peak) where both sound, the brightness
    difference (MSX - Amiga, octaves: the mean and the mean |.|) and the spectral distance (the
    third-octave band spectra, each normalised, power-weighted mean |dB difference|, floor -30
    dB: timbre, not level)."""
    e = ms.env_compare(ref, out, T)
    p = ms.pitch_compare(ref, hz, T)
    a, b = ms.tick_db(ref, T), ms.tick_db(out, T)
    db, ds = [], []
    for t in range(T):
        if a[t] < a.max() - 30 or b[t] < b.max() - 40:
            continue
        fr, fo = ms.frame(ref, t), ms.frame(out, t)
        x, y = ms.brightness(fr), ms.brightness(fo)
        if x is None or y is None:
            continue
        db.append(y - x)
        ds.append(spectral_distance(fr, fo))
    return {"env": e, "pitch": p, "bright": float(np.mean(db)) if db else None,
            "bright_abs": float(np.mean(np.abs(db))) if db else None, "bright_n": len(db),
            "spec": float(np.mean(ds)) if ds else None}


def psg_version(fx: ms.Effects, n: int, T: int) -> np.ndarray:
    """msxsound.py's PSG voice of effect n (its encoding at the default fx lambda, decoded by its
    player model, on its PSG model), in the SCC's units; and its tone frequency per tick."""
    tg = fx.targets[n]
    recs = ms.records(tg, ms.choose_volumes(tg, ms.FX_LAMBDA, False))
    if fx.info[n]["main"] < 3:
        while len(recs) > 1 and recs[-1][1] == 0:
            recs.pop()
    st = ms.play_streams(ms.stream_bytes(recs), [(0, 0, None)], T)
    out = ms.dc_block(ms.Psg().render(st)[0]) * PSG_OVER_SCC
    return out, ms.voice_hz(st, 0)


def fmt(x, spec: str = "%.2f") -> str:
    return "-" if x is None else spec % x


# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

def describe(fx: ms.Effects, pl: Plan, res: Result, dec: dict) -> str:
    """One line on an effect: its channel, samples, and what each part carries."""
    d = dec["fx"][pl.n]
    m = [int(np.sum(pl.mode == k)) for k in range(3)]
    names = sorted({fx.insts[int(i)].name for i in pl.inst if i >= 0})
    st = res.streams[pl.n]
    if d["scc"] is not None:
        used = sorted({int(w) for w in pl.wave if w >= 0})
        scc = "SCC %d bytes: %s, waveform%s %s (%d change%s)%s" % (
            len(st["scc"]), " + ".join(x for x in (
                "%d tone tick%s" % (m[0], "s" if m[0] > 1 else "") if m[0] else "",
                "the tonal share of %d tone+noise" % m[1] if m[1] else "") if x),
            "s" if len(used) > 1 else "", ",".join(map(str, used)), d["scc"][2] - 1,
            "" if d["scc"][2] == 2 else "s",
            ", restarted every tick: 50 Hz" if pl.restart.any() else "")
    else:
        scc = "no SCC part"
    if d["psg"] is not None:
        tg = res.intent[pl.n]["tg"]
        gated = int(np.sum(tg.tone & tg.noise))
        nps = sorted({int(tg.np[t]) for t in range(pl.T) if tg.noise[t] and tg.audible(t)})
        psg = "PSG %d bytes: %s, noise period%s %s%s" % (
            len(st["psg"]), " + ".join(x for x in (
                "%d noise tick%s" % (m[2], "s" if m[2] > 1 else "") if m[2] else "",
                "the noise share of %d tone+noise" % m[1] if m[1] else "") if x),
            "s" if len(nps) > 1 else "", ",".join(map(str, nps)),
            ", tone + noise on %d" % gated if gated else "")
    else:
        psg = "no PSG part"
    return "effect %d: channel %d, %s, %d ticks; %s; %s" % (
        pl.n, pl.channel, "+".join(names), pl.T, scc, psg)


def write_inc(path: Path, res: Result, lines: list[str]) -> None:
    L = ["; generated by tools/msxsccfx.py from MU1 (the 42 in-game sound effects, tunes 1-42) for",
         "; an MSX with a Konami SCC: build/msx/sccfx.bin. Bytes 0-2: the waveform table's offset",
         "; (24-bit little-endian from the blob's start), byte 3: its count (SCCFX_WAVES); effect n",
         "; at 4 + 7 (n - 1): its Amiga channel (0-3), its SCC stream's offset, its PSG stream's",
         "; offset (24-bit, 0 = none); then the streams and the table (32 signed bytes a waveform).",
         "; SCC record: dur (1-255 ticks at 50 Hz; 0 = the end: the channel falls silent), ctl (bits",
         "; 0-3 volume; 4: the period N follows, a word; 5: the waveform number follows, a byte, after",
         "; the word); the first record gives both. PSG record: sound.inc's format (bits 0-3 volume, 4",
         "; tone on, 5 noise on, 6 the tone period's word follows, 7 the noise period's byte follows).",
         "; An effect on channels 0-2 ends with its last sound; one on channel 3 lasts its whole length",
         "; (on its SCC stream when it has one).",
         "",
         "SCCFX_BYTES: equ %d" % len(res.blob),
         "SCCFX_WAVES: equ %d" % len(res.waves.data),
         ""] + ["; " + x for x in lines] + [""]
    for i, wh in enumerate(res.waves.what):
        L.append("; waveform %d: %s (RMS %.3f)" % (i, wh, res.waves.rms(i)))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(L) + "\n")


class Result:
    """A conversion: the waveforms, the gain, per effect its streams (bytes), what they must play
    tick by tick (intent) and the blob."""

    def __init__(self):
        self.waves = Waves()
        self.table = np.zeros((0, WAVE_LEN), np.int8)
        self.gain = {}
        self.streams: dict[int, dict] = {}
        self.intent: dict[int, dict] = {}
        self.blob = b""


def convert(fx: ms.Effects, plans: dict[int, Plan], change_db: float = CHANGE_DB,
            gate: bool = True) -> Result:
    """The effects' waveforms (make_waves), the gain (choose_gain), each effect's SCC part
    (scc_states, msxscc's records) and PSG part (psg_target, ms.choose_volumes, ms.records; one
    stream per part, trimmed: an effect on channels 0-2 drops its trailing silence, one on
    channel 3 lasts its whole length, on its SCC stream when it has one), then the blob."""
    res = Result()
    make_waves(fx, plans, res.waves, change_db)
    res.table = res.waves.table()
    res.gain = choose_gain(plans, res.waves)
    gain = res.gain["gain"]
    for n, pl in plans.items():
        sst = scc_states(pl, res.waves, gain)
        sig = sc.render_scc(scc_render_states(sst, pl.T), res.table, pl.T)
        tg = psg_target(pl, gain, sig)
        set_accents(pl, tg)
        if gate:
            gate_noise(fx, pl, tg, sig)
            set_accents(pl, tg)
        vol = ms.choose_volumes(tg, PSG_LAMBDA, False)
        keep = pl.T if pl.channel == 3 else None
        has_scc = any(x[0] for x in sst)
        srecs = trim(sc.scc_records(sst), keep) if has_scc else None
        precs = trim(ms.records(tg, vol), None if has_scc else keep) if np.any(vol) else None
        res.streams[n] = {"channel": pl.channel,
                          "scc": sc.scc_bytes(srecs) if srecs else None,
                          "psg": ms.stream_bytes(precs) if precs else None}
        res.intent[n] = {"scc": sst if srecs else None,
                         "psg": ms.intended(tg, vol, pl.T) if precs else None, "tg": tg, "vol": vol}
    res.blob = build_blob(res.streams, res.table)[0]
    return res


def check(res: Result, plans: dict[int, Plan], dec: dict) -> int:
    """Differences between the decoded blob and the intent: per tick each part's state, the
    channels, the table, the streams' lengths (channel 3: its whole length on one stream)."""
    errors = 0 if np.array_equal(dec["table"], res.table) else 1
    for n, pl in plans.items():
        d, want = dec["fx"][n], res.intent[n]
        if d["channel"] != pl.channel:
            errors += 1
        if (want["scc"] is None) != (d["scc"] is None) or (want["psg"] is None) != (d["psg"] is None):
            errors += 1
            continue
        lengths = []
        if d["scc"] is not None:
            st, length, _ = d["scc"]
            got = [x if x[0] else (0,) for x in st[:pl.T]]
            errors += sum(1 for a, b in zip(got, want["scc"]) if a != b)
            lengths.append(length)
        if d["psg"] is not None:
            st, length = d["psg"]
            for a, w in zip(st[:pl.T], want["psg"]):
                vol, tone, noise, per, npd = a
                wv, wt, wn, wp, wnp = w
                if vol != wv or (wv and (tone != wt or noise != wn or (wt and per != wp)
                                         or (wn and npd != wnp))):
                    errors += 1
            lengths.append(length)
        if any(x > pl.T for x in lengths) or (pl.channel == 3 and lengths[0] != pl.T):
            errors += 1
    return errors


def evaluate(fx: ms.Effects, plans: dict[int, Plan], dec: dict) -> tuple[dict, list[np.ndarray]]:
    """Per effect the decoded streams rendered (the SCC model plus the PSG model in the SCC's
    units, each effect T + 2 ticks as msxsound's previews) and compared with the Amiga reference,
    next to msxsound's PSG version. Returns the rows and the renders."""
    rows, outs = {}, []
    for n, pl in plans.items():
        T = pl.T + 2
        ref = sum(np.pad(c.render(), (0, 2 * ms.SPT)) for c in fx.chans[n])
        d = dec["fx"][n]
        out = np.zeros(T * ms.SPT)
        hz = np.zeros(T)
        if d["scc"] is not None:
            st = d["scc"][0][:T]
            out += sc.render_scc(st, dec["table"], T)
            hz = np.array([SCC_HZ / (WAVE_LEN * (x[1] + 1)) if x[0] else 0.0 for x in st])
        if d["psg"] is not None:
            out += ms.dc_block(ms.Psg().render(psg_states(d["psg"][0][:T]))[0]) * PSG_OVER_SCC
        psg, phz = psg_version(fx, n, T)
        rows[n] = {"scc": compare(ref, out, hz, T), "psg": compare(ref, psg, phz, T),
                   "rms": (float(np.sum(out ** 2)), float(np.sum(psg ** 2)), float(np.sum(ref ** 2)))}
        outs.append(out)
    return rows, outs


def totals(rows: dict, plans: dict[int, Plan]) -> dict:
    """The comparison over all effects: mean envelope r (effects whose reference varies by 3 dB
    or more: r means nothing on a flat one), tick-weighted MAE, |brightness| and spectral
    distance, the pitch agreement pooled over the ticks."""
    out = {}
    for v in ("scc", "psg"):
        rs = [rows[n][v]["env"]["r"] for n in rows if rows[n][v]["env"]["r"] is not None
              and (rows[n][v]["env"]["ref_std"] or 0) >= 3]
        w = {n: plans[n].T for n in rows}

        def mean(key, sub=None):
            num = den = 0.0
            for n in rows:
                x = rows[n][v][sub][key] if sub else rows[n][v][key]
                if x is not None:
                    num += w[n] * x
                    den += w[n]
            return num / den if den else None
        pt = sum(rows[n][v]["pitch"]["ticks"] for n in rows)
        ex = sum(rows[n][v]["pitch"]["ticks"] * rows[n][v]["pitch"].get("exact", 0) for n in rows)
        ch = sum(rows[n][v]["pitch"]["ticks"] * rows[n][v]["pitch"].get("chroma", 0) for n in rows)
        out[v] = {"r": float(np.mean(rs)), "r_n": len(rs), "mae": mean("mae_db", "env"),
                  "bright": mean("bright"), "bright_abs": mean("bright_abs"), "spec": mean("spec"),
                  "pitch_ticks": pt, "exact": ex / pt if pt else None, "chroma": ch / pt if pt else None,
                  "level_db": 10 * math.log10(sum(rows[n]["rms"][0 if v == "scc" else 1] for n in rows) /
                                              sum(rows[n]["rms"][1] for n in rows))}
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "msx",
                    help="directory of sccfx.bin and sccfx.inc")
    ap.add_argument("--wav", type=Path, default=ROOT / "build" / "music" / "preview",
                    help="directory of sfx_all_scc.wav")
    args = ap.parse_args()

    rep, data = ms.load_music("MU1", "MU1_09.bin")
    fx = ms.Effects(rep, data)
    plans = {n: Plan(fx, n) for n in sorted(fx.chans)}
    if sorted(plans) != list(range(1, N_FX + 1)):
        print("error: MU1 does not hold tunes 1-%d" % N_FX)
        return 1
    bad = [n for n, pl in plans.items() if not pl.replica_ok]
    if bad:
        print("error: the measurement differs from msxsound's Effects on effects %s" % bad)
        return 1
    res = convert(fx, plans)
    dec = decode_blob(res.blob, {n: pl.T + 2 for n, pl in plans.items()})
    errors = check(res, plans, dec)
    lines = [describe(fx, pl, res, dec) for pl in plans.values()]
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "sccfx.bin").write_bytes(res.blob)
    write_inc(args.out / "sccfx.inc", res, lines)
    rows, outs = evaluate(fx, plans, dec)
    gap = np.zeros(int(0.4 * ms.FS))
    ms.write_wav(args.wav / "sfx_all_scc.wav", np.concatenate([x for o in outs for x in (o, gap)]))

    modes = [sum(int(np.sum(pl.mode == k)) for pl in plans.values()) for k in range(3)]
    print("ticks: %d tone, %d tone+noise, %d noise (Effects._target's modes, checked tick by tick); "
          "restart runs: %s" % (*modes, ", ".join("effect %d (%d ticks)" % (n, int(pl.restart.sum()))
                                                 for n, pl in plans.items() if pl.restart.any())))
    waves, g = res.waves, res.gain
    g_ref = 0.5 * PSG_OVER_SCC / fx.a_ref
    print("waveforms: %d (%s):" % (len(waves.data), "each effect's tonal ticks clustered, CHANGE_DB "
                                   "%g a change; sample #0's loop exact, shared" % CHANGE_DB))
    for i, wh in enumerate(waves.what):
        print("  %2d: %s; RMS %.3f%s" % (i, wh, waves.rms(i), "; effects " + ",".join(
            map(str, waves.users[i])) if len(waves.users[i]) > 1 else ""))
    loads = {n: dec["fx"][n]["scc"][2] if dec["fx"][n]["scc"] else 0 for n in plans}
    print("waveform loads (about 1000 T-states each in the VBLANK interrupt): %d at the starts of "
          "%d effects, %d changes inside %d effects (at most %d in one)" % (
              sum(1 for x in loads.values() if x), sum(1 for x in loads.values() if x),
              sum(max(0, x - 1) for x in loads.values()), sum(1 for x in loads.values() if x > 1),
              max(max(0, x - 1) for x in loads.values())))
    print("gain: %+.1f dB from msxsound's (fx.a_ref at PSG level 15): the SCC part allows %+.1f "
          "(%.0f %% of its ticks within volume 15), the PSG part %+.1f" % (
              20 * math.log10(g["gain"] / g_ref), 20 * math.log10(g["scc"] / g_ref), LEVEL_PCT,
              20 * math.log10(g["psg"] / g_ref)))
    gated = sum(int(np.sum(res.intent[n]["tg"].tone & res.intent[n]["tg"].noise)) for n in plans)
    print("noise part: tone + noise on %d ticks (GATE_GAIN_DB %g)" % (gated, GATE_GAIN_DB))
    sb = sum(len(x["scc"] or b"") for x in res.streams.values())
    pb = sum(len(x["psg"] or b"") for x in res.streams.values())
    print("sizes: header %d, SCC streams %d (%d effects), PSG streams %d (%d effects), waveforms %d: "
          "sccfx.bin %d bytes" % (HEADER, sb, sum(1 for x in res.streams.values() if x["scc"]), pb,
                                  sum(1 for x in res.streams.values() if x["psg"]), res.table.size,
                                  len(res.blob)))
    print("decoded blob (an independent decoder) against the encoder's intent: %d differences" % errors)

    print("\nper effect, this SCC version / msxsound's PSG version against the Amiga (env r: Pearson "
          "r of the per-tick dB, meaningless on a flat envelope; MAE after aligning the medians; "
          "brightness MSX - Amiga and its mean |.| on the Amiga's audible ticks; pitch: share of "
          "the tonal ticks within 50 cents of YIN on the Amiga render; spectral distance: timbre):")
    print("  %3s %2s %5s %-9s %4s %4s %2s %3s | %-11s | %-9s | %-11s | %-9s | %-9s | %-9s" % (
        "n", "ch", "ticks", "T/TN/N", "scc", "psg", "w", "chg", "env r", "MAE dB", "bright oct",
        "|bright|", "pitch", "spec dB"))
    for n, pl in plans.items():
        r = rows[n]
        m = [int(np.sum(pl.mode == k)) for k in range(3)]
        st = res.streams[n]

        def two(key, spec, sub=None):
            a = r["scc"][sub].get(key) if sub else r["scc"][key]
            b = r["psg"][sub].get(key) if sub else r["psg"][key]
            return "%s %s" % (fmt(a, spec), fmt(b, spec))
        print("  %3d %2d %5d %-9s %4d %4d %2d %3d | %-11s | %-9s | %-11s | %-9s | %-9s | %-9s" % (
            n, pl.channel, pl.T, "%d/%d/%d" % tuple(m), len(st["scc"] or b""), len(st["psg"] or b""),
            len({int(w) for w in pl.wave if w >= 0}), max(0, loads[n] - 1),
            two("r", "%.2f", "env"), two("mae_db", "%.1f", "env"), two("bright", "%+.2f"),
            two("bright_abs", "%.2f"), two("exact", "%.2f", "pitch"), two("spec", "%.1f")))
    tt = totals(rows, plans)
    print("totals (env r: the mean over the %d effects whose Amiga envelope spans 3 dB or more; MAE, "
          "brightness, spectral distance: tick-weighted means; pitch: pooled; level: the whole "
          "output's power against the PSG version's):" % tt["scc"]["r_n"])
    for v, name in (("scc", "SCC version"), ("psg", "PSG version")):
        x = tt[v]
        print("  %s: env r %.3f, MAE %.2f dB, brightness %+.2f (|.| %.2f) octaves, pitch on %d "
              "ticks %.3f within 50 cents (%.3f the same note), spectral distance %.2f dB, level "
              "%+.1f dB" % (name, x["r"], x["mae"], x["bright"], x["bright_abs"], x["pitch_ticks"],
                            x["exact"], x["chroma"], x["spec"], x["level_db"]))
    print("\nwrote %s, %s, %s" % (args.out / "sccfx.bin", args.out / "sccfx.inc",
                                 args.wav / "sfx_all_scc.wav"))
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
