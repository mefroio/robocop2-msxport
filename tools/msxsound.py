#!/usr/bin/env python3
"""Robocop 2's sound for the MSX PSG: the title music (TITM tune 1) and the 42 in-game sound
effects (MU1 tunes 1-42) as PSG register streams for the Z80 player (msx/sndplay.asm).

Input: build/music/TITM.json and MU1.json (tools/rc2music.py, the Amiga player's exact output
per tick; made here when missing) and the samples in build/extracted/files/TITM_04.bin and
MU1_09.bin (loaded at $18000). Output: build/msx/sound.inc (z80asm data for the 8 KiB bank at
A000h: SND_SFX_N, snd_sfx, snd_title and the streams), preview WAVs of the Amiga reference
(rendered from the model) and of the PSG (the streams decoded as the Z80 player reads them,
on a PSG model), and a numeric comparison of the two. Needs numpy (the project's venv).

usage:
  msxsound.py [--out build/msx/sound.inc] [--wav DIR] [--no-wav] [--budget BYTES]
              [--fx-lambda X] [--seconds 60]

  --budget    bytes of sound.inc data (default 6656 = 6.5 KiB): the effects are encoded at a
              fixed quality (--fx-lambda, default 2; 0 = every tick exact), the title gets the
              best quality that fits the rest. --wav (default build/music/preview): the WAVs;
              --no-wav skips them and the comparison; --seconds: the title's preview length.

Stream format (one PSG voice): records of dur (1 byte, 1..255 ticks the state lasts, 50 ticks
a second; 0 = the end: an effect's voice goes silent, a title stream goes on at its loop
pointer) then ctl (bits 0-3 volume, 4 tone on, 5 noise on, 6 a word follows: the 12-bit tone
period, little-endian; 7 a byte follows: the noise period 0-31, after the word). A field not
given keeps the voice's value. Identical consecutive states are one record (split at 255).
What the encoder relies on from sndplay.asm (sq_rec / sq_out), modelled by play_streams: a
voice's period and noise period are never reset, so every stream (and the title at its loop
point) gives both before it first needs them; R6 is written from the voice's own noise period
at every record with noise on, so a silent record is always ctl 0 (no R6 write); the title has
one noise user at a time (its noise period is always 31).

How the Amiga sound is mapped (the decisions and why)
- Rates: Paula plays a sample at 3579545 / AUDxPER bytes a second (NTSC: the release targets
  NTSC machines), never faster than one DMA word per raster line (AUDxPER 113.75: the two TITM
  notes at AUDxPER 33 sound as that); the PSG's tone is 111860.78 / period Hz. A note's sample
  restarts at each key-on, plays once, then its loop part or the zero word (silence).
- Loudness: per tick the RMS of the sample bytes played in that tick, times the volume / 64;
  in dB from a reference (the 99.5th percentile of the title's ticks, the 99th of all the
  effects': the loudest ticks reach level 15), on the AY's measured 16-level curve. A one-shot
  sample's fade and end come out of this by themselves.
- The encoder (choose_volumes): a trellis over the 16 levels per tick minimising the squared
  level error (in ~3 dB steps, weighted by loudness) + lambda x bytes (a record 2, a period
  word +2, a noise byte +1). Periods, tone/noise on and noise periods are given by the targets
  below; the trellis only trades level detail for bytes. The format has no repeats, and the
  title has 1220 melodic notes (each period change costs 4 bytes) and 325 drum hits: at 6.5
  KiB every note is kept but its levels are coarse (see the printed comparison: about 2-4 dB
  off; 1.4-2.2 dB at 7.5 KiB); below ~6 KiB the trellis starts dropping quiet notes.
- Title, melodic (Amiga channels 0-2 -> PSG A-C, tones): an instrument's pitch is its
  sample's samples per cycle, measured (YIN over its body): the VHDR's samplesPerHiCycle is 32
  for nearly every sample (a default: ba1 is 106, BRASS4 53, PIZZICATO 54). The measured
  tunings share one grid (a common offset of ~ +0.45 semitone); each instrument is moved onto
  it (PIZZICATO +22 cents, TIMPANI -45: pure squares expose any detuning; TIMPANI, inharmonic
  and half-way between two semitones, takes the one with fewer dissonant intervals against the
  other channels, i.e. ba1's tuning). An instrument whose notes are mostly below 55 Hz goes up
  an octave (FILTER-WAH, an octave under ba1 with a strong second harmonic: a 35 Hz square
  hardly sounds on an MSX speaker). A re-trigger of the same pitch must change the level by a
  step (ACCENT): the PSG has no attack and ba1's envelope is flat, so repeated bass notes would
  merge into one; the trellis picks the cheapest articulation (often alternate levels). Slides
  send a new period when 30 cents away.
- Title, RoboCop's speech ("YOUR MOVE, CREEP": instrument 24, sample 11, "TOM" in its header;
  at 57.6 s on channel 2, again on channel 0 nine ticks later): tones cannot say it, so its notes
  are silent in the streams (SPEECH_INST) and the PSG plays the speech as PCM when the player
  starts (tools/msxvoice.py, the user's choice).
- Title, drums (Amiga channel 3: BDRM, SNARE, TOM1): the PSG has no fourth voice, so each hit
  rides one of the three for a few ticks. These samples are darker than any PSG noise (their
  brightness, the power-weighted mean log2 frequency over 60 Hz-8 kHz, is 7.3 octaves for BDRM,
  ~9 for SNARE/TOM1; PSG noise ranges from 9.9 (period 31) to 11.6): only tones reach that low.
  A kick (BDRM: a pitched thump, 134 -> 72 Hz) rides a voice playing a note below 200 Hz (the
  bass, nearly always): that note's level rises to the power sum of the two for 6 ticks, the
  note goes on (no melody lost, no byte unless the level needs one). Snares and toms (or a
  kick with no low note) turn tone + noise on the quietest voice for 3 ticks, on that voice's
  current period (no period word; the tone gating darkens the noise to ~9.0-9.6) with noise
  period 31, at the power sum of the hit and the note (+1.25 dB: the AND's quarter duty).
- Effects (one voice each; effect 42's two channels: the louder per tick, its table channel
  the one louder on most ticks): per tick the period YIN finds in the bytes played (the
  sample's own pitch: MU1 has samples that sweep inside, e.g. 6-9 and 15) and how aperiodic
  they are -> tone (< 0.25), tone + noise (< 0.45) or noise; the tone's period from that
  period at the played rate (arpeggios and slides follow the Amiga's periods exactly), the
  noise period from the brightness; medians within each note against chance periodicity in
  noise and YIN's octave slips (Effects._target). Record 0 (instrument 0, a looped 22-byte
  waveform: effects 19, 27-33, 38) is pitched on its strongest partial, 5.5 bytes a cycle:
  TITM's copy is a 2-cycle sine in 11 bytes, MU1's has its first half overwritten, which adds
  weaker partials of the 22-byte loop two octaves lower. An effect on Amiga channels 0-2 drops
  its trailing silence (the end marker silences the voice); one on channel 3 keeps its whole
  length (the player's priority test looks at channel 3 being busy, as the Amiga's does).

The comparison (per stream): loudness envelopes per tick (Pearson r of the dB values and the
mean |error| after aligning their medians: r is low where the Amiga's envelope is flat, e.g.
ba1, the MAE is then the telling number; the share of the Amiga's audible ticks the PSG
covers); pitch (YIN on the Amiga render from each tick's start vs the PSG's tone: the share
within 50 cents, and within 50 cents modulo octaves); brightness (as above) on the ticks with
noise or drums; for the title's mix also a chroma similarity (12 pitch classes per tick).
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rc2music  # noqa: E402  (the Amiga player's model: constants, and the JSON when missing)

ROOT = Path(__file__).resolve().parents[1]
LOAD = rc2music.LOAD                    # the music files load at $18000
PAULA_HZ = rc2music.NTSC_CLOCK          # the release targets NTSC machines (the ledger)
PSG_HZ = PAULA_HZ / 2                   # the MSX's PSG clock, 1789772.5 Hz
AY_STEP = PSG_HZ / 16                   # tone f = AY_STEP / period; the noise shifts at AY_STEP / np
AY_INT = PSG_HZ / 8                     # the PSG counters' rate (a tone half-period = period counts)
TICK_HZ = 50                            # the Amiga player's tick rate (and the MSX player's)
SPEECH_INST = 24                        # RoboCop's speech ("YOUR MOVE, CREEP": sample 11, "TOM" in its
                                        # header) in the title: PSG PCM on start instead
                                        # (tools/msxvoice.py, front.asm voice_play), silent here
FS = 44100                              # preview WAVs
SPT = FS // TICK_HZ                     # 882 output samples per tick
DMA_PERIOD = 113.75                     # one audio DMA word (2 bytes) per NTSC raster line: the
                                        # fastest rate Paula really plays (AUDxPER 33 sounds as this)
# The AY-3-8910's 16 output levels (the commonly cited measured curve, as in ayumi); level 0 = 0.
AY_VOL = np.array([0.0, 0.00999465934234, 0.0144502937362, 0.0210574502174, 0.0307011520562,
                   0.0455481803616, 0.0644998855573, 0.107362478065, 0.126588845655,
                   0.20498970016, 0.292210269322, 0.372838941024, 0.492530708782,
                   0.635324635691, 0.805584802014, 1.0])
FLOOR_DB = -46.0                        # "silent": below level 1 (-40 dB)
with np.errstate(divide="ignore"):
    AY_DB = np.where(AY_VOL > 0, 20 * np.log10(np.maximum(AY_VOL, 1e-12)), FLOOR_DB)
LFSR_LEN = (1 << 17) - 1


def _lfsr_bits() -> np.ndarray:
    """Bit 0 of the PSG's 17-bit noise LFSR after k shifts (k = 0 .. 2^17 - 2), from state 1."""
    out = np.empty(LFSR_LEN, np.uint8)
    s = 1
    for k in range(LFSR_LEN):
        out[k] = s & 1
        s = (s >> 1) | (((s ^ (s >> 3)) & 1) << 16)
    return out


# ---------------------------------------------------------------------------------------------
# The Amiga side: instruments, channels, Paula
# ---------------------------------------------------------------------------------------------

def load_music(name: str, fname: str) -> tuple[dict, bytes]:
    """build/music/<NAME>.json (made by rc2music.py when missing) and the file's bytes."""
    path = ROOT / "build" / "extracted" / "files" / fname
    data = path.read_bytes()
    js = ROOT / "build" / "music" / (name + ".json")
    if js.exists():
        rep = json.loads(js.read_text())
    else:
        rep = rc2music.build_report(path, None, 400000)
    return rep, data


class Inst:
    """An instrument record as Paula plays it: the whole sample (one-shot + repeat part) once
    from its start, then its loop part for ever, or the zero word (silence) for a one-shot."""

    def __init__(self, rec: dict, sample: dict, data: bytes):
        self.index = rec["index"]
        self.sample = rec["sample"]
        self.name = sample.get("name") or "#%d" % self.sample
        self.rate = sample.get("rate") or 0
        a = int(rec["start"], 16) - LOAD
        self.first = np.frombuffer(data[a:a + rec["length_bytes"]], np.int8).astype(np.float64) / 128
        if rec["looped"]:
            b = int(rec["loop_start"], 16) - LOAD
            raw = data[b:b + rec["loop_length_bytes"]]
            self.loop = np.frombuffer(raw, np.int8).astype(np.float64) / 128
        else:
            self.loop = np.zeros(2)
        self.looped = bool(rec["looped"])
        self.c1 = np.concatenate([[0.0], np.cumsum(self.first ** 2)])
        self.c2 = np.concatenate([[0.0], np.cumsum(self.loop ** 2)])

    def values(self, idx: np.ndarray) -> np.ndarray:
        """Sample values at positions of the endless stream (0 = the start of the sample)."""
        n1 = len(self.first)
        out = np.empty(len(idx))
        m = idx < n1
        out[m] = self.first[idx[m]]
        out[~m] = self.loop[(idx[~m] - n1) % len(self.loop)]
        return out

    def _cum(self, i: int) -> float:
        n1 = len(self.first)
        if i <= n1:
            return self.c1[i]
        k, r = divmod(i - n1, len(self.loop))
        return self.c1[n1] + k * self.c2[-1] + self.c2[r]

    def energy(self, a: int, b: int) -> float:
        """Sum of the squares of the stream's values a .. b-1."""
        return self._cum(b) - self._cum(a)

    def segment(self, a: int, b: int) -> np.ndarray:
        return self.values(np.arange(a, b))


class Channel:
    """One Amiga channel of a tune, tick by tick: the period, volume and instrument written to
    Paula (rc2music.py's runs), the key-ons, and where the sample is at each tick."""

    def __init__(self, tune: dict, ch: int, insts: dict[int, Inst], ticks: int):
        self.ch = ch
        self.T = ticks
        per, vol, ins = [], [], []
        for n, p, v, i in tune["frames"][str(ch)]:
            per += [p] * n
            vol += [v] * n
            ins += [-1 if i is None else i] * n
        pad = ticks - len(per)
        self.per = np.array((per + [1] * pad)[:ticks])
        self.vol = np.array((vol + [0] * pad)[:ticks])
        self.ins = np.array((ins + [-1] * pad)[:ticks])
        self.keyon = np.zeros(ticks, bool)
        for k in tune["key_ons"]:
            if k[1] == ch and k[0] < ticks:
                self.keyon[k[0]] = True
        self.insts = insts
        # sample position (bytes from the sample's start) at each tick's start and the bytes played
        self.pos = np.zeros(ticks)
        self.nb = np.zeros(ticks)
        self.rate = np.zeros(ticks)
        pos = 0.0
        for t in range(ticks):
            if self.keyon[t]:
                pos = 0.0
            if self.per[t] > 1:
                r = PAULA_HZ / max(self.per[t], DMA_PERIOD)
                self.rate[t] = r
                self.nb[t] = r / TICK_HZ
            self.pos[t] = pos
            pos += self.nb[t]
        self.amp = np.zeros(ticks)               # RMS of the output, full scale = 1
        for t in range(ticks):
            a, b = self.span(t)
            if b > a and self.vol[t] and self.ins[t] >= 0:
                self.amp[t] = math.sqrt(self.insts[self.ins[t]].energy(a, b) / (b - a)) * self.vol[t] / 64

    def span(self, t: int) -> tuple[int, int]:
        """The stream positions Paula plays during tick t."""
        if self.nb[t] == 0:
            return 0, 0
        a = int(self.pos[t])
        return a, max(a + 1, int(self.pos[t] + self.nb[t]))

    def bytes_at(self, t: int, minimum: int = 0) -> np.ndarray:
        """The sample values played during tick t (at least `minimum` from its position on)."""
        a, b = self.span(t)
        if b <= a or self.ins[t] < 0:
            return np.zeros(0)
        return self.insts[self.ins[t]].segment(a, max(b, a + minimum))

    def render(self, t0: int = 0, t1: int | None = None) -> np.ndarray:
        """Paula's output of this channel at FS (a zero-order hold, as the DAC), full scale 1."""
        t1 = self.T if t1 is None else t1
        out = np.zeros((t1 - t0) * SPT)
        j = np.arange(SPT) + 0.5
        for t in range(t0, t1):
            if self.nb[t] == 0 or self.vol[t] == 0 or self.ins[t] < 0:
                continue
            idx = (self.pos[t] + j * self.rate[t] / FS).astype(np.int64)
            out[(t - t0) * SPT:(t - t0 + 1) * SPT] = self.insts[self.ins[t]].values(idx) * self.vol[t] / 64
        return out


# ---------------------------------------------------------------------------------------------
# The MSX side: the player's semantics (msx/sndplay.asm) and the PSG
# ---------------------------------------------------------------------------------------------

class Voice:
    """One voice of the Z80 player: sq_rec / sq_out of msx/sndplay.asm."""

    def __init__(self, code: bytes, start: int, loop: int | None):
        self.code, self.ptr, self.loop = code, start, loop
        self.left, self.ctl, self.per, self.noise = 0, 0, 0, 0

    def record(self, psg: "PsgState", v: int) -> None:
        c = self.code
        while True:
            d = c[self.ptr]
            self.ptr += 1
            if d:
                break
            if self.loop is None:
                self.left = self.ctl = 0
                psg.out(v, self)
                return
            self.ptr = self.loop
        self.left = d
        self.ctl = c[self.ptr]
        self.ptr += 1
        if self.ctl & 0x40:
            self.per = (c[self.ptr] | c[self.ptr + 1] << 8) & 0xFFF
            self.ptr += 2
        if self.ctl & 0x80:
            self.noise = c[self.ptr] & 31
            self.ptr += 1
        psg.out(v, self)


class PsgState:
    """The PSG registers the player writes (per voice: volume, mixer bits, tone period; R6)."""

    def __init__(self):
        self.vol = [0, 0, 0]
        self.tone = [False] * 3
        self.noise_on = [False] * 3
        self.per = [0, 0, 0]
        self.r6 = 0

    def out(self, v: int, voice: Voice) -> None:
        self.per[v] = voice.per
        self.vol[v] = voice.ctl & 15
        if voice.ctl & 0x20:
            self.r6 = voice.noise
        self.tone[v] = bool(voice.ctl & 0x10)
        self.noise_on[v] = bool(voice.ctl & 0x20)

    def snapshot(self) -> tuple:
        return (tuple(self.vol), tuple(self.tone), tuple(self.noise_on), tuple(self.per), self.r6)


def play_streams(code: bytes, voices: list[tuple[int, int, int | None]], ticks: int) -> list[tuple]:
    """Runs the player on streams in `code`: voices = [(PSG voice, start offset, loop offset or
    None)], all started at tick 0 (sq_title / sq_sfx). Returns the register state of each tick."""
    psg = PsgState()
    vs = {}
    for v, start, loop in voices:
        vs[v] = Voice(code, start, loop)
        vs[v].record(psg, v)
    states = [psg.snapshot()]
    for _ in range(1, ticks):
        for v in sorted(vs):                    # sq_frame: voices A, B, C in order
            x = vs[v]
            if x.left:
                x.left -= 1
                if x.left == 0:
                    x.record(psg, v)
        states.append(psg.snapshot())
    return states


class Psg:
    """A PSG model: square tones, the 17-bit LFSR noise shared by the voices, the mixer's AND of
    tone and noise, the AY's volume curve. Counters run at clock / 8; the output is averaged
    over each FS sample (a box filter) and returned per voice."""

    LFSR = None

    def __init__(self):
        if Psg.LFSR is None:
            Psg.LFSR = _lfsr_bits()
        self.tc = [0, 0, 0]          # tone counters
        self.ts = [0, 0, 0]          # tone outputs
        self.nc = 0                  # noise counter
        self.ni = 0                  # LFSR shifts done

    def render(self, states: list[tuple]) -> np.ndarray:
        n_t = AY_INT / TICK_HZ
        out = np.zeros((3, len(states) * SPT))
        jb = np.arange(SPT + 1) * (n_t / SPT)
        for t, (vol, tone, noise, per, r6) in enumerate(states):
            s0, s1 = int(t * n_t), int((t + 1) * n_t)
            n = s1 - s0
            steps = np.arange(1, n + 1)
            npd = 2 * max(r6, 1)
            nbits = None
            if any(noise[v] and vol[v] for v in range(3)):
                k = (self.nc + steps) // npd
                nbits = Psg.LFSR[(self.ni + k) % LFSR_LEN]
            self.ni = (self.ni + (self.nc + n) // npd) % LFSR_LEN
            self.nc = (self.nc + n) % npd
            off = t * n_t - s0
            for v in range(3):
                p = max(per[v], 1)
                c = min(self.tc[v], p - 1)
                k = (c + steps) // p
                tb = (self.ts[v] ^ (k & 1)).astype(np.uint8)
                self.ts[v] ^= ((c + n) // p) & 1
                self.tc[v] = (c + n) % p
                if not vol[v]:
                    continue
                o = np.ones(n, np.uint8)            # (both off: the level itself, DC)
                if tone[v]:
                    o &= tb
                if noise[v]:
                    o &= nbits
                cs = np.concatenate([[0.0], np.cumsum(o * AY_VOL[vol[v]])])
                x = np.clip(jb + off, 0, n)
                y = np.interp(x, np.arange(n + 1), cs)
                out[v, t * SPT:(t + 1) * SPT] = np.diff(y) / np.diff(x).clip(1e-9)
        return out


def one_pole(x: np.ndarray, hz: float) -> np.ndarray:
    """One-pole low-pass y[n] = a y[n-1] + (1 - a) x[n], by blocks (closed form per block)."""
    a = math.exp(-2 * math.pi * hz / FS)
    y = np.empty_like(x)
    blk = 2048
    k = np.arange(blk)
    ak, ainv = a ** (k + 1), a ** -k
    prev = 0.0
    for i in range(0, len(x), blk):
        seg = x[i:i + blk]
        m = len(seg)
        acc = np.cumsum(seg * ainv[:m]) * (1 - a) * (ak[:m] / a)
        y[i:i + m] = acc + prev * ak[:m]
        prev = y[i + m - 1]
    return y


def dc_block(x: np.ndarray, hz: float = 15.0) -> np.ndarray:
    """A one-pole high-pass (the MSX's output capacitor): the PSG's output is unipolar."""
    return x - one_pole(x, hz)


def write_wav(path: Path, x: np.ndarray, peak: float = 0.89) -> None:
    """16-bit mono WAV at FS, normalised so that the 99.99th percentile of |x| is `peak`."""
    path.parent.mkdir(parents=True, exist_ok=True)
    m = np.percentile(np.abs(x), 99.99) if len(x) else 0
    y = np.clip(x * (peak / m if m > 0 else 1), -1, 1)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(FS)
        w.writeframes((y * 32767).astype("<i2").tobytes())


# ---------------------------------------------------------------------------------------------
# Signal analysis
# ---------------------------------------------------------------------------------------------

def yin(x: np.ndarray, hi: int, lo: int = 2, thr: float = 0.15) -> tuple[float, float] | None:
    """YIN pitch estimate of frame x: (period in samples, refined by a parabola; the cumulative-
    mean-normalised difference there: 0 = perfectly periodic, ~1 = noise). The first dip below
    `thr` in lo..hi-1, else the global minimum."""
    n = len(x)
    w = n - hi
    if w < 16 or hi <= lo + 1:
        return None
    x = x - x.mean()
    cs = np.concatenate([[0.0], np.cumsum(x * x)])
    nfft = 1 << math.ceil(math.log2(n + w))
    r = np.fft.irfft(np.conj(np.fft.rfft(x[:w], nfft)) * np.fft.rfft(x, nfft), nfft)[:hi + 1]
    tau = np.arange(hi + 1)
    d = np.maximum(cs[w] + cs[tau + w] - cs[tau] - 2 * r, 0)
    if cs[w] <= 1e-9:
        return None
    c = np.ones(hi + 1)
    c[1:] = d[1:] * tau[1:] / np.maximum(np.cumsum(d[1:]), 1e-12)
    below = np.nonzero(c[lo:hi] < thr)[0]
    if len(below):
        t = lo + int(below[0])
        while t + 1 < hi and c[t + 1] < c[t]:
            t += 1
    else:
        t = lo + int(np.argmin(c[lo:hi]))
    off = 0.0
    if lo < t < hi - 1:
        a, b, e = c[t - 1], c[t], c[t + 1]
        den = a - 2 * b + e
        if den > 0:
            off = max(-0.5, min(0.5, 0.5 * (a - e) / den))
    return t + off, float(c[t])


BAND = (60.0, 8000.0)                   # the band the brightness is measured in


def brightness(x: np.ndarray) -> float | None:
    """Power-weighted mean of log2(frequency) of a frame at FS over BAND (octaves; None when
    the frame is silent)."""
    if len(x) < 64 or not np.any(x):
        return None
    n = 2048
    X = np.abs(np.fft.rfft((x - x.mean()) * np.hanning(len(x)), n)) ** 2
    f = np.fft.rfftfreq(n, 1 / FS)
    m = (f >= BAND[0]) & (f <= BAND[1])
    p = X[m]
    if p.sum() <= 1e-15:
        return None
    return float((p * np.log2(f[m])).sum() / p.sum())


def frame(sig: np.ndarray, t: int, size: int = 1024) -> np.ndarray:
    """A frame of `size` samples centred on tick t of a signal at FS."""
    c = t * SPT + SPT // 2
    a = max(0, c - size // 2)
    return sig[a:a + size]


_NOISE_BRIGHT: list[float] | None = None


def noise_brightness() -> list[float]:
    """Brightness of the PSG's noise for each noise period 0-31 (measured on the model)."""
    global _NOISE_BRIGHT
    if _NOISE_BRIGHT is None:
        out = [0.0]
        for npd in range(1, 32):
            st = [((15, 0, 0), (False,) * 3, (True, False, False), (1, 1, 1), npd)] * 12
            sig = dc_block(Psg().render(st)[0])
            vals = [brightness(frame(sig, t)) for t in range(2, 11)]
            out.append(float(np.mean([v for v in vals if v is not None])))
        out[0] = out[1]
        _NOISE_BRIGHT = out
    return _NOISE_BRIGHT


def noise_for(bright: float) -> int:
    """The noise period whose brightness is nearest."""
    nb = noise_brightness()
    return int(min(range(1, 32), key=lambda k: abs(nb[k] - bright)))


def ay_period(f: float) -> int:
    """The PSG tone period nearest to frequency f (octaves down when out of range)."""
    p = AY_STEP / f
    while p > 4095:
        p /= 2
    return int(max(1, min(4095, round(p))))


# ---------------------------------------------------------------------------------------------
# Voice targets
# ---------------------------------------------------------------------------------------------

class Target:
    """What one PSG voice should play, tick by tick: the level (dB, 0 = PSG level 15; -inf =
    silent), tone/noise on, the tone period, the noise period; `accent` marks a re-trigger of
    the same pitch (the encoder must change the level there: a PSG voice has no attack of its
    own); `src` the Amiga channel the content comes from, `drum` a drum hit riding the voice."""

    def __init__(self, ticks: int):
        self.T = ticks
        self.lvl = np.full(ticks, -np.inf)
        self.tone = np.zeros(ticks, bool)
        self.noise = np.zeros(ticks, bool)
        self.per = np.zeros(ticks, np.int64)
        self.np = np.zeros(ticks, np.int64)
        self.accent = np.zeros(ticks, bool)
        self.src = np.full(ticks, -1)
        self.drum = np.zeros(ticks, bool)

    def audible(self, t: int) -> bool:
        return self.lvl[t] > FLOOR_DB

    def fields(self, t: int) -> tuple:
        return (bool(self.tone[t]), bool(self.noise[t]),
                int(self.per[t]) if self.tone[t] else None, int(self.np[t]) if self.noise[t] else None)


def smooth_pitch(tg: Target, fixed: np.ndarray, tol: float, which: np.ndarray | None = None) -> None:
    """Holds the tone period while it stays within `tol` cents of the last one sent (slides and
    sweeps: fewer period words); ticks in `fixed` (key-ons) always take their own period. Only
    the ticks in `which` when given (the others keep theirs and do not move the reference)."""
    ref = None
    for t in range(tg.T):
        if not (tg.tone[t] and tg.audible(t)) or (which is not None and not which[t]):
            continue
        p = int(tg.per[t])
        if ref is None or fixed[t] or abs(1200 * math.log2(ref / p)) >= tol:
            ref = p
        tg.per[t] = ref


def smooth_noise(tg: Target, tol: float) -> None:
    """Holds the noise period while its brightness stays within `tol` octaves."""
    nb = noise_brightness()
    ref = None
    for t in range(tg.T):
        if not (tg.noise[t] and tg.audible(t)):
            continue
        k = int(tg.np[t])
        if ref is None or abs(nb[ref] - nb[k]) >= tol:
            ref = k
        tg.np[t] = ref


# ---------------------------------------------------------------------------------------------
# The encoder: a rate-distortion trellis over the 16 volumes, then the records
# ---------------------------------------------------------------------------------------------

INF = 1e18
ACCENT = 1                              # a re-trigger moves the level this many steps


def _weights(lvl: np.ndarray) -> np.ndarray:
    """Distortion weight of a tick: about its loudness (amplitude ** 0.6)."""
    return 10 ** (0.6 * np.maximum(lvl, FLOOR_DB) / 20)


def choose_volumes(tg: Target, lam: float, block_noise_tail: bool) -> np.ndarray:
    """The PSG volume of each tick minimising sum(distortion) + lam * bytes. Distortion: the
    squared error in PSG steps (~3 dB) weighted by loudness. Bytes: 2 per record, + 2 for a
    period word, + 1 for a noise byte. A re-trigger (accent) must change the level by ACCENT
    steps or more from the tick before (or start from silence); a silent target tick may only
    keep the record running (or go silent), with `block_noise_tail` not after noise (the title:
    one noise voice at a time)."""
    T = tg.T
    aud = tg.lvl > FLOOR_DB
    lvl = np.where(aud, tg.lvl, FLOOR_DB)
    w = _weights(lvl)
    vv = np.arange(16)
    dist_sil = _weights(AY_DB) * ((AY_DB - FLOOR_DB) / 3) ** 2
    dist_sil[0] = 0
    # per tick: the fields' change relative to the last audible tick, and the extra bytes
    prev_f = None
    last_per = last_np = None
    change = np.zeros(T, bool)
    extra = np.zeros(T)
    after_noise = np.zeros(T, bool)
    last_noise = False
    for t in range(T):
        if aud[t]:
            f = tg.fields(t)
            change[t] = f != prev_f
            if f[0] and f[2] != last_per:
                extra[t] += 2
            if f[1] and f[3] != last_np:
                extra[t] += 1
            prev_f = f
            if f[0]:
                last_per = f[2]
            if f[1]:
                last_np = f[3]
            last_noise = f[1]
        else:
            after_noise[t] = last_noise
    cost = np.zeros(16)
    back = np.zeros((T, 16), np.int8)
    for t in range(T):
        c = np.full((16, 16), 2.0)                  # bytes of the transition v' -> v
        bad = np.zeros((16, 16), bool)              # forbidden transitions
        if aud[t]:
            d = w[t] * ((AY_DB - lvl[t]) / 3) ** 2
            c[:, 1:] += extra[t]
            if not change[t] and t > 0:
                c[vv[1:], vv[1:]] = 0.0
            if tg.accent[t]:
                bad |= (vv[:, None] > 0) & (vv[None, :] > 0) & (abs(vv[:, None] - vv[None, :]) < ACCENT)
        else:
            d = dist_sil
            bad[:, 1:] = True
            if t > 0 and not (block_noise_tail and after_noise[t]):
                bad[vv[1:], vv[1:]] = False
                c[vv[1:], vv[1:]] = 0.0
        if t > 0:
            c[0, 0] = 0.0
        else:
            bad[1:, :] = True                       # (the stream starts here: from "nothing")
        m = cost[:, None] + lam * c + np.where(bad, INF, 0.0)
        b = np.argmin(m, axis=0)
        back[t] = b
        cost = m[b, vv] + d
    v = np.zeros(T, np.int64)
    v[-1] = int(np.argmin(cost))
    for t in range(T - 1, 0, -1):
        v[t - 1] = back[t, v[t]]
    return v


def records(tg: Target, vol: np.ndarray, max_dur: int = 255) -> list[tuple]:
    """The stream's records (dur, ctl, period or None, noise or None) for the chosen volumes;
    the voice's period and noise start unknown (a stream start or its loop point)."""
    recs: list[list] = []
    cur = None
    sv_per = sv_np = None
    state = ("off",)
    for t in range(tg.T):
        v = int(vol[t])
        if v == 0:
            state = ("off",)
        elif tg.audible(t):
            state = (v,) + tg.fields(t)
        # else: a silent target tick that keeps the record running: the state stays
        if state == cur and recs[-1][0] < max_dur:
            recs[-1][0] += 1
            continue
        cur = state
        if state == ("off",):
            recs.append([1, 0, None, None])
            continue
        v, tone, noise, per, npd = state
        ctl = v | (0x10 if tone else 0) | (0x20 if noise else 0)
        w = b = None
        if tone and per != sv_per:
            ctl |= 0x40
            w = sv_per = per
        if noise and npd != sv_np:
            ctl |= 0x80
            b = sv_np = npd
        recs.append([1, ctl, w, b])
    return [tuple(r) for r in recs]


def stream_bytes(recs: list[tuple]) -> bytes:
    out = bytearray()
    for d, ctl, w, b in recs:
        out += bytes([d, ctl])
        if w is not None:
            out += bytes([w & 0xFF, w >> 8])
        if b is not None:
            out.append(b)
    out.append(0)
    return bytes(out)


def rec_size(recs: list[tuple]) -> int:
    return sum(2 + (2 if w is not None else 0) + (1 if b is not None else 0) for _, _, w, b in recs) + 1


# ---------------------------------------------------------------------------------------------
# Instruments: pitch, tuning
# ---------------------------------------------------------------------------------------------

def instruments(rep: dict) -> dict[int, dict]:
    """Instrument records by number, with their sample's 8SVX info."""
    samples = {s["id"]: s for s in rep["samples"]}
    return {r["index"]: dict(r, info=samples[r["sample"]]) for r in rep["instruments"]}


def load_insts(rep: dict, data: bytes) -> dict[int, Inst]:
    return {i: Inst(r, r["info"], data) for i, r in instruments(rep).items()}


def sample_pitch(inst: Inst) -> tuple[float, float, str]:
    """(samples per cycle, aperiodicity 0..1, how) of an instrument's sound. A looped waveform
    shorter than 64 bytes (record 0): its strongest partial. Else the median YIN period over
    windows at 10..70 % of the sample's first pass."""
    if len(inst.first) < 64 and inst.looped:
        X = np.abs(np.fft.rfft(inst.loop - inst.loop.mean()))
        k = int(np.argmax(X[1:])) + 1
        return len(inst.loop) / k, 0.0, "strongest partial of the %d-byte loop" % len(inst.loop)
    x = inst.first
    n = len(x)
    win = min(1024, max(256, n // 3))
    lags, aps = [], []
    for frac in (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7):
        a = int(frac * n)
        seg = x[a:a + win]
        if len(seg) < win or math.sqrt(np.mean(seg ** 2)) < 0.03:
            continue
        r = yin(seg, win // 2, lo=4)
        if r:
            lags.append(r[0])
            aps.append(r[1])
    if not lags:
        return 0.0, 1.0, "no periodic window"
    good = [l for l, a in zip(lags, aps) if a < 0.3] or lags
    return float(np.median(good)), float(np.median(aps)), "median YIN period of %d windows" % len(lags)


def tuning(spc: float) -> float:
    """Semitones from A4 (440 Hz) of a sample with `spc` samples per cycle at AUDxPER 447."""
    return 12 * math.log2(PAULA_HZ / (447 * spc) / 440)


DISSONANT = {1, 2, 6, 10, 11}


def snap_tuning(chans: list[Channel], tonal: dict[int, float], counts: dict[int, int]
                ) -> tuple[dict[int, float], float, dict[int, str]]:
    """The instruments' samples are tuned to one common grid (the composer's ear): the PSG's
    pure squares expose any detuning, so every tonal instrument is moved to the grid (its
    tuning rounded to whole semitones from the common offset, the note-weighted circular mean).
    An instrument halfway between two semitones takes the one with fewer dissonant intervals
    (1, 2, 6, 10, 11 semitones) against the other channels' simultaneous notes."""
    ang = sum(counts[i] * np.exp(2j * np.pi * tuning(s)) for i, s in tonal.items())
    phi = float(np.angle(ang) / (2 * np.pi))
    out, why = {}, {}
    for i, s in tonal.items():
        x = tuning(s) - phi
        k = round(x)
        if abs(x - k) > 0.3:
            cands = [math.floor(x), math.floor(x) + 1]
            score = {k2: _dissonance(chans, i, k2 - x, tonal) for k2 in cands}
            k = min(cands, key=lambda c: (score[c], abs(c - x)))
            why[i] = "%.2f semitones off the grid: %+d chosen (dissonant ticks %s)" % (
                x - round(x), k - math.floor(x), {c - math.floor(x): round(v) for c, v in score.items()})
        out[i] = s * 2 ** ((x - k) / 12)         # raising the pitch = fewer samples per cycle
    return out, phi, why


def _dissonance(chans: list[Channel], inst: int, shift: float, tonal: dict[int, float]) -> float:
    """Ticks (weighted by the quieter note) where `inst`, retuned by `shift` semitones, forms a
    dissonant interval with another channel's tonal note."""
    tot = 0.0
    for c in chans[:3]:
        m = (c.ins == inst) & (c.amp > 0) & (c.per > 1)
        for t in np.nonzero(m)[0]:
            p1 = 12 * math.log2(PAULA_HZ / (max(c.per[t], DMA_PERIOD) * tonal[inst]) / 440) + shift
            for o in chans[:3]:
                if o is c or o.amp[t] <= 0 or o.ins[t] not in tonal or o.per[t] <= 1:
                    continue
                p2 = 12 * math.log2(PAULA_HZ / (max(o.per[t], DMA_PERIOD) * tonal[o.ins[t]]) / 440)
                if round(p1 - p2) % 12 in DISSONANT:
                    tot += min(c.amp[t], o.amp[t])
    return tot


# ---------------------------------------------------------------------------------------------
# The title music (TITM tune 1)
# ---------------------------------------------------------------------------------------------

LOW_HZ = 55.0                           # a PSG square below A1 hardly sounds on an MSX speaker
DRUM_BURST = {"BDRM": 3, "SNARE": 3, "TOM1": 3}   # ticks a drum hit takes a voice for
KICK_BRIGHT = 8.0                       # a hit darker than this (log2 Hz) is a kick
KICK_HZ = 200.0                         # a kick rides a voice playing below this
KICK_RIDE = 6                           # ticks a kick raises the low note
DRUM_HZ = 150.0                         # the tone of a drum on a voice that never played one
PITCH_TOL = 30.0                        # cents a slide or sweep may lag before a new period


class Title:
    """TITM tune 1 mapped onto three voices: Amiga channels 0-2 (melodic) on PSG A-C as tones;
    the hits of channel 3 (drums) ride those voices (see _drums)."""

    def __init__(self, rep: dict, data: bytes):
        tune = rep["tunes"][0]
        loop = tune["loop"]
        self.T = loop["start_tick"] + loop["length_ticks"]
        self.loop_tick = loop["start_tick"]
        self.insts = load_insts(rep, data)
        self.chans = [Channel(tune, c, self.insts, self.T) for c in range(4)]
        amps = np.concatenate([c.amp[c.amp > 0] for c in self.chans])
        self.a_ref = float(np.percentile(amps, 99.5))
        # the melodic instruments' pitch
        counts: dict[int, int] = {}
        for k in tune["key_ons"]:
            if k[1] < 3:
                counts[k[2]] = counts.get(k[2], 0) + 1
        self.pitch = {i: sample_pitch(self.insts[i]) for i in counts}
        raw = {i: p[0] for i, p in self.pitch.items() if p[0] > 0}
        self.spc, self.phi, self.tune_why = snap_tuning(self.chans, raw, counts)
        self.octave = {}
        for i, s in self.spc.items():
            fs = [PAULA_HZ / (max(c.per[t], DMA_PERIOD) * s) for c in self.chans[:3]
                  for t in np.nonzero((c.ins == i) & (c.amp > 0) & (c.per > 1))[0]]
            k = 0
            while fs and np.median(fs) * 2 ** k < LOW_HZ:
                k += 1
            self.octave[i] = k
        self.counts = counts
        self.targets = [self._melodic(c) for c in range(3)]
        self.drum_log = self._drums()

    def freq(self, c: int, t: int) -> float:
        ch = self.chans[c]
        i = int(ch.ins[t])
        return PAULA_HZ / (max(ch.per[t], DMA_PERIOD) * self.spc[i]) * 2 ** self.octave[i]

    def _melodic(self, c: int) -> Target:
        ch = self.chans[c]
        tg = Target(self.T)
        prev = None
        for t in range(self.T):
            i = int(ch.ins[t])
            if ch.amp[t] <= 0 or i not in self.spc or ch.per[t] <= 1 or i == SPEECH_INST:
                prev = None
                continue
            lv = 20 * math.log10(ch.amp[t] / self.a_ref)
            if lv <= FLOOR_DB:
                prev = None
                continue
            tg.lvl[t] = lv
            tg.tone[t] = True
            tg.per[t] = ay_period(self.freq(c, t))
            tg.src[t] = c
            tg.accent[t] = bool(ch.keyon[t] and prev == tg.per[t])
            prev = tg.per[t]
        smooth_pitch(tg, ch.keyon, PITCH_TOL)
        return tg

    def _drums(self) -> list[dict]:
        """Each hit of channel 3 rides one voice for a few ticks (a PSG drum without a voice of
        its own). A kick (a dark hit: a pitched thump) rides a voice playing a low note (below
        KICK_HZ): that note's level rises to the sum of the two sounds' powers, the note goes on.
        Any other hit (or a kick with no low note around) turns tone + noise on the quietest
        voice for DRUM_BURST ticks, on that voice's current period (no period word) and the
        darkest noise (period 31: the PSG's noise is brighter than these samples, the tone
        gating darkens it); the level is the power sum again (+1.25 dB: the AND's quarter duty)."""
        ch = self.chans[3]
        ref = ch.render()
        hits = list(np.nonzero(ch.keyon)[0]) + [self.T]
        log = []
        for h0, h1 in zip(hits, hits[1:]):
            name = self.insts[int(ch.ins[h0])].name
            kick = (brightness(frame(ref, h0)) or 99) < KICK_BRIGHT
            best = None
            for v in range(3):
                tg = self.targets[v]
                per = self._period_at(tg, h0)
                low = per is not None and AY_STEP / per < KICK_HZ and tg.audible(h0)
                if kick and low:
                    n = min(h1 - h0, KICK_RIDE)
                    ticks = [t for t in range(h0, h0 + n) if ch.amp[t] > 0]
                    cost = (0.0, 0, v)                    # the note goes on: nothing lost
                    mode = "tone"
                else:
                    n = min(h1 - h0, DRUM_BURST.get(name, 3))
                    ticks = [t for t in range(h0, h0 + n) if ch.amp[t] > 0]
                    lost = sum(10 ** (tg.lvl[t] / 20) for t in ticks if tg.audible(t))
                    goes_on = h0 + n < self.T and tg.audible(h0 + n)
                    cost = (round(lost, 3), int(goes_on), v)
                    mode = "tone+noise"
                if ticks and (best is None or cost < best[0]):
                    best = (cost, v, mode, ticks, per)
            if best is None:
                continue
            cost, v, mode, ticks, per = best
            tg = self.targets[v]
            if per is None:
                per = ay_period(DRUM_HZ)
            for t in ticks:
                ld = 20 * math.log10(ch.amp[t] / self.a_ref)
                lm = tg.lvl[t] if tg.audible(t) else -np.inf
                lv = 10 * math.log10(10 ** (ld / 10) + (10 ** (lm / 10) if lm > -np.inf else 0))
                tg.drum[t] = True
                if mode == "tone":
                    tg.lvl[t] = lv
                    continue                              # (the note's period and accent stay)
                tg.lvl[t] = lv + 1.25
                tg.src[t] = 3
                if not (tg.tone[t] and tg.audible(t)):
                    tg.per[t] = per
                tg.tone[t] = True
                per = int(tg.per[t])
                tg.noise[t] = True
                tg.np[t] = 31
                tg.accent[t] = False
            log.append({"tick": int(h0), "drum": name, "voice": "ABC"[v], "mode": mode,
                        "ticks": len(ticks), "lost": cost[0]})
        return log

    @staticmethod
    def _period_at(tg: Target, t: int) -> int | None:
        """The voice's tone period at tick t: its note's if it plays one, else the last one."""
        for k in range(t, -1, -1):
            if tg.audible(k) and tg.tone[k]:
                return int(tg.per[k])
        return None


# ---------------------------------------------------------------------------------------------
# The sound effects (MU1 tunes 1-42)
# ---------------------------------------------------------------------------------------------

TONE_AP, MIX_AP = 0.25, 0.45            # YIN aperiodicity: below = tone, below = tone + noise
FX_LAMBDA = 2.0                         # the effects' bytes-vs-distortion trade-off
NOISE_TOL = 0.3                         # octaves of brightness before a new noise period
QUIET_DB = 12.0                         # a tick this far under its note's peak keeps the period


class Effects:
    """MU1's effects, one PSG voice each: per tick the louder Amiga channel (effect 42 uses two),
    its level, and tone (the period from the sample's pitch at the played rate), noise (the
    period from the brightness) or both, from how periodic the bytes played are."""

    def __init__(self, rep: dict, data: bytes):
        self.rep = rep
        self.insts = load_insts(rep, data)
        self.tunes = rep["tunes"]
        self.chans = {}
        for tn in self.tunes:
            T = tn["ends_at_tick"] if tn["ends_at_tick"] is not None else tn["ticks"]
            self.chans[tn["tune"]] = [Channel(tn, c, self.insts, T) for c in tn["channels"]]
        amps = np.concatenate([c.amp[c.amp > 0] for cs in self.chans.values() for c in cs])
        self.a_ref = float(np.percentile(amps, 99))
        self.wave_spc = {i: sample_pitch(x)[0] for i, x in self.insts.items()
                         if len(x.first) < 64 and x.looped}
        self.info: dict[int, dict] = {}
        self.targets = {n: self._target(n) for n in self.chans}

    def _target(self, n: int) -> Target:
        """Per tick: the louder channel, its level; the period YIN finds in the bytes it plays
        (in samples, i.e. the sample's own pitch: the played rate is known exactly) and how
        aperiodic they are; the brightness of the Amiga output. Within a note (from a key-on to
        the next, on one channel) the features go through medians (3 ticks for the period, when
        all three are periodic, and the brightness; 5 for the aperiodicity, in notes of 5 ticks
        or more: noise looks periodic by chance in short windows, YIN slips an octave). Then the
        mode by the aperiodicity; a tone's period from its period at the played rate; the
        tone + noise ticks of a note share one period (the median: the tone only colours the
        noise); a tick QUIET_DB under the note's peak keeps the period before it; the noise
        period from the brightness."""
        cs = self.chans[n]
        T = cs[0].T
        tg = Target(T)
        refs = [c.render() for c in cs]
        won = [0] * len(cs)
        rows = []                                   # per tick: j, level, lag, aperiodicity, brightness
        for t in range(T):
            j = int(np.argmax([c.amp[t] for c in cs]))
            c = cs[j]
            lv = 20 * math.log10(c.amp[t] / self.a_ref) if c.amp[t] > 0 else -np.inf
            if lv <= FLOOR_DB:
                rows.append(None)
                continue
            won[j] += 1
            i = int(c.ins[t])
            if i in self.wave_spc:
                lag, ap = self.wave_spc[i], 0.0
            else:
                seg = c.bytes_at(t, minimum=256)
                lo = max(2, int(c.rate[t] / 3000))
                hi = min(len(seg) - 64, int(c.rate[t] / 40))
                r = yin(seg, hi, lo=lo) if hi > lo + 2 else None
                lag, ap = (r[0], r[1]) if r else (0.0, 1.0)
            rows.append([j, lv, lag, ap, brightness(frame(refs[j], t)) or 10.0])
        # notes: runs of ticks on one channel without a key-on inside
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
        for note in notes:                          # medians over the note's ticks
            raw_ap = [rows[t][3] for t in note]
            for k, width in ((2, 1), (3, 2), (4, 1)):
                if k == 3 and len(note) < 2 * width + 1:
                    continue                        # (a short note keeps its own)
                vals = [rows[t][k] for t in note]
                for q, t in enumerate(note):
                    lo, hi = max(0, q - width), q + width + 1
                    if k == 2:
                        win = [math.log2(x) for x, a in zip(vals[lo:hi], raw_ap[lo:hi])
                               if x > 0 and a < MIX_AP]
                        if len(win) == 3 and rows[t][2] > 0:
                            rows[t][2] = 2 ** float(np.median(win))
                    else:
                        rows[t][k] = float(np.median(vals[lo:hi]))
        modes = {"tone": 0, "tone+noise": 0, "noise": 0}
        for note in notes:
            peak = max(rows[t][1] for t in note)
            mix = [rows[t][2] for t in note if TONE_AP <= rows[t][3] < MIX_AP and rows[t][2] > 0]
            mix_lag = float(np.median(mix)) if mix else 0.0
            prev_per = None
            for t in note:
                j, lv, lag, ap, br = rows[t]
                c = cs[j]
                mode = "tone" if ap < TONE_AP else "tone+noise" if ap < MIX_AP and lag > 0 else "noise"
                modes[mode] += 1
                tg.lvl[t] = lv + (1.25 if mode == "tone+noise" else 0.0)
                tg.src[t] = c.ch
                if mode != "noise":
                    tg.tone[t] = True
                    if lv < peak - QUIET_DB and prev_per:
                        tg.per[t] = prev_per        # a quiet tail keeps the period
                    else:
                        tg.per[t] = ay_period(c.rate[t] / (lag if mode == "tone" else mix_lag))
                    prev_per = int(tg.per[t])
                if mode != "tone":
                    tg.noise[t] = True
                    tg.np[t] = noise_for(br)
                tg.accent[t] = bool(c.keyon[t] and t and tg.audible(t - 1)
                                    and tg.fields(t - 1) == tg.fields(t))
        keyon = np.zeros(T, bool)
        for c in cs:
            keyon |= c.keyon[:T]
        pure = tg.tone & ~tg.noise
        smooth_pitch(tg, keyon, PITCH_TOL, pure)
        smooth_noise(tg, NOISE_TOL)
        main = cs[int(np.argmax(won))].ch
        self.info[n] = {"channels": [c.ch for c in cs], "main": main, "ticks": T, "modes": modes,
                        "inst": sorted({self.insts[int(i)].name for c in cs
                                        for i in set(c.ins[c.amp > 0])})}
        return tg


# ---------------------------------------------------------------------------------------------
# Encoding everything within the budget
# ---------------------------------------------------------------------------------------------

TABLES = 3 * 42 + 12                    # snd_sfx (dw + db per effect) and snd_title (6 dw)


def encode_title(title: Title, lam: float) -> tuple[list[list[tuple]], list[np.ndarray]]:
    """Records of the three voices; when the loop does not start at tick 0 the intro and the
    loop part are separate (a record starts at the loop point, the voice's state unknown)."""
    out, vols = [], []
    for tg in title.targets:
        vol = choose_volumes(tg, lam, True)
        if title.loop_tick:
            a, b = _split(tg, title.loop_tick)
            recs = records(a, vol[:title.loop_tick]) + records(b, vol[title.loop_tick:])
        else:
            recs = records(tg, vol)
        out.append(recs)
        vols.append(vol)
    return out, vols


def _split(tg: Target, k: int) -> tuple[Target, Target]:
    parts = []
    for sl in (slice(0, k), slice(k, tg.T)):
        x = Target(sl.stop - sl.start)
        for f in ("lvl", "tone", "noise", "per", "np", "accent", "src", "drum"):
            setattr(x, f, getattr(tg, f)[sl].copy())
        parts.append(x)
    return parts[0], parts[1]


def encode(title: Title, fx: Effects, budget: int, lam_fx: float) -> dict:
    """The effects at a fixed quality (lam_fx), the title at the best quality that fits the
    rest of the budget (bisection on its lambda)."""
    fxr = {}
    for n, tg in fx.targets.items():
        recs = records(tg, choose_volumes(tg, lam_fx, False))
        if fx.info[n]["main"] < 3:                  # (channel 3: its length is the priority's)
            while len(recs) > 1 and recs[-1][1] == 0:
                recs.pop()                          # the end silences the voice anyway
        fxr[n] = recs
    fx_size = sum(rec_size(r) for r in fxr.values())
    room = budget - fx_size - TABLES

    def size(lam: float) -> tuple[int, list, list]:
        recs, vols = encode_title(title, lam)
        return sum(rec_size(r) for r in recs), recs, vols

    best = size(0.0)
    lam = 0.0
    if best[0] > room:
        lo, hi = 0.0, 1.0
        top = size(hi)
        while top[0] > room and hi < 1e5:
            lo, hi = hi, hi * 4
            top = size(hi)
        best = top
        lam = hi
        for _ in range(30):
            mid = math.sqrt(lo * hi) if lo else hi / 2
            r = size(mid)
            if r[0] <= room:
                hi, best, lam = mid, r, mid
            else:
                lo = mid
            if hi - lo < 1e-3 * hi:
                break
    return {"fx": fxr, "title": best[1], "title_vols": best[2], "lam": lam, "lam_fx": lam_fx,
            "fx_size": fx_size, "title_size": best[0], "room": room}


def assemble(enc: dict, title: Title, fx: Effects) -> tuple[bytes, dict, dict]:
    """All streams in one blob (the title's three, then the effects): offsets and loop offsets."""
    blob = bytearray()
    offs: dict = {}
    for v, recs in enumerate(enc["title"]):
        offs["title", v] = len(blob)
        loop = len(blob)
        if title.loop_tick:
            t = 0
            for i, r in enumerate(recs):
                if t == title.loop_tick:
                    loop = len(blob) + len(stream_bytes(recs[:i])) - 1
                    break
                t += r[0]
        offs["loop", v] = loop
        blob += stream_bytes(recs)
    for n in sorted(enc["fx"]):
        offs["fx", n] = len(blob)
        blob += stream_bytes(enc["fx"][n])
    sizes = {"title": [rec_size(r) for r in enc["title"]],
             "fx": {n: rec_size(enc["fx"][n]) for n in enc["fx"]}}
    return bytes(blob), offs, sizes


def write_inc(path: Path, enc: dict, title: Title, fx: Effects, sizes: dict) -> int:
    """build/msx/sound.inc (z80asm): SND_SFX_N, snd_sfx, snd_title and the streams."""
    def recs_lines(label: str, recs: list[tuple], loop_label: str | None, loop_tick: int) -> list[str]:
        out = [label + ":"]
        if loop_label and loop_tick == 0:
            out.append(loop_label + ":")
        t = 0
        for d, ctl, w, b in recs:
            if loop_label and loop_tick and t == loop_tick:
                out.append(loop_label + ":")
            vals = [str(d), "0x%02X" % ctl]
            if w is not None:
                vals += ["0x%02X" % (w & 0xFF), "0x%02X" % (w >> 8)]
            if b is not None:
                vals.append(str(b))
            out.append("        db " + ",".join(vals))
            t += d
        out.append("        db 0")
        return out

    total = TABLES + sum(sizes["title"]) + sum(sizes["fx"].values())
    L = ["; generated by tools/msxsound.py from TITM (the title music, tune 1) and MU1 (the 42",
         "; in-game sound effects): PSG streams for msx/sndplay.asm, one per voice. A record: dur",
         "; (1-255 ticks at 50 Hz; 0 = the end: an effect's voice goes silent, a title stream goes on",
         "; at its loop pointer), ctl (bits 0-3 volume, 4 tone on, 5 noise on, 6 the tone period's",
         "; word follows, 7 the noise period's byte follows, after the word); a field not given keeps",
         "; the voice's value. Every stream (and the title at its loop) gives a period and a noise",
         "; period before it first needs them; a silent record is ctl 0. In the title one voice at a",
         "; time uses noise, always with noise period 31; its three streams loop on the same tick.",
         "; sizes: tables %d, title %s, effects %d: %d bytes" % (
             TABLES, "+".join(str(x) for x in sizes["title"]), sum(sizes["fx"].values()), total),
         "",
         "SND_SFX_N: equ %d" % len(enc["fx"]),
         "",
         "snd_sfx:                                ; effect n at n - 1: its stream, its Amiga channel"]
    for n in sorted(enc["fx"]):
        L.append("        dw sfx_%02d" % n)
        L.append("        db %d" % fx.info[n]["main"])
    L += ["",
          "snd_title:                              ; the streams of voices A, B, C, then their loops",
          "        dw title_a,title_b,title_c",
          "        dw title_a_loop,title_b_loop,title_c_loop",
          ""]
    for v, recs in enumerate(enc["title"]):
        L += recs_lines("title_" + "abc"[v], recs, "title_%s_loop" % "abc"[v], title.loop_tick)
        L.append("")
    for n in sorted(enc["fx"]):
        i = fx.info[n]
        L.append("; effect %d: Amiga channel%s %s, %d ticks, %s" % (
            n, "s" if len(i["channels"]) > 1 else "", "+".join(map(str, i["channels"])), i["ticks"],
            ", ".join(i["inst"])))
        L += recs_lines("sfx_%02d" % n, enc["fx"][n], None, 0)
        L.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(L))
    return total


# ---------------------------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------------------------

def tick_db(x: np.ndarray, T: int) -> np.ndarray:
    """AC RMS of each tick in dB (full scale 1)."""
    y = x[:T * SPT].reshape(T, SPT)
    r = y.std(axis=1)
    return 20 * np.log10(np.maximum(r, 1e-7))


def env_compare(ref: np.ndarray, psg: np.ndarray, T: int) -> dict:
    """Loudness envelopes per tick: Pearson r of the dB values (ticks where either is within 40
    dB of its peak), the mean |difference| after aligning the medians, the share of the
    reference's audible ticks (within 30 dB of its peak) where the PSG sounds."""
    a, b = tick_db(ref, T), tick_db(psg, T)
    fa, fb = a.max() - 40, b.max() - 40
    m = (a > fa) | (b > fb)
    a2, b2 = np.maximum(a, fa), np.maximum(b, fb)
    out = {"r": None, "mae_db": None, "coverage": None,
           "ref_std": float(np.std(a[a > a.max() - 30])) if np.any(a > a.max() - 30) else None}
    if m.sum() >= 3 and np.std(a2[m]) > 1e-6 and np.std(b2[m]) > 1e-6:
        out["r"] = float(np.corrcoef(a2[m], b2[m])[0, 1])
    both = (a > a.max() - 30) & (b > fb)
    if both.any():
        d = a[both] - b[both]
        out["mae_db"] = float(np.mean(np.abs(d - np.median(d))))
    aud = a > a.max() - 30
    if aud.any():
        out["coverage"] = float(np.mean(b[aud] > b.max() - 40))
    return out


def pitch_compare(ref: np.ndarray, psg_hz: np.ndarray, T: int, mask: np.ndarray | None = None) -> dict:
    """Ticks where the reference is clearly periodic (YIN on 2048 samples from the tick's start:
    aperiodicity < 0.2; within 30 dB of its peak) and the PSG plays a tone: the share within 50
    cents, the share within 50 cents modulo octaves (the same note name), the median |error| in
    cents modulo octaves. (A sound re-triggered every tick at a low pitch has no measurable
    pitch in such a window: effect 34.)"""
    a = tick_db(ref, T)
    ok, ok_oct, err, n = 0, 0, [], 0
    for t in range(T):
        if a[t] < a.max() - 30 or psg_hz[t] <= 0 or (mask is not None and not mask[t]):
            continue
        r = yin(ref[t * SPT:t * SPT + 2048], int(FS / 40), lo=int(FS / 4000))
        if not r or r[1] > 0.2:
            continue
        d = 1200 * math.log2(psg_hz[t] / (FS / r[0]))
        do = (d + 600) % 1200 - 600
        n += 1
        ok += abs(d) < 50
        ok_oct += abs(do) < 50
        err.append(abs(do))
    if not n:
        return {"ticks": 0}
    return {"ticks": n, "exact": ok / n, "chroma": ok_oct / n, "median_cents": float(np.median(err))}


def bright_compare(ref: np.ndarray, psg: np.ndarray, T: int, mask: np.ndarray) -> dict:
    """Brightness (mean log2 frequency) per tick on the masked ticks: Pearson r and the mean
    difference PSG - reference in octaves."""
    a, b = [], []
    for t in np.nonzero(mask)[0]:
        x, y = brightness(frame(ref, t)), brightness(frame(psg, t))
        if x is not None and y is not None:
            a.append(x)
            b.append(y)
    if len(a) < 2:
        return {"ticks": len(a)}
    a, b = np.array(a), np.array(b)
    r = float(np.corrcoef(a, b)[0, 1]) if np.std(a) > 1e-6 and np.std(b) > 1e-6 else None
    return {"ticks": len(a), "r": r, "diff_oct": float(np.mean(b - a))}


def chroma(x: np.ndarray, T: int) -> np.ndarray:
    """12-bin chroma (55 Hz .. 2 kHz) of each tick."""
    n = 4096
    f = np.fft.rfftfreq(n, 1 / FS)
    m = (f >= 55) & (f <= 2000)
    pc = np.round(12 * np.log2(f[m] / 440.0)).astype(int) % 12
    win = np.hanning(n)
    out = np.zeros((T, 12))
    for t in range(T):
        fr = frame(x, t, n)
        if len(fr) < n:
            fr = np.pad(fr, (0, n - len(fr)))
        X = np.abs(np.fft.rfft((fr - fr.mean()) * win)) ** 2
        out[t] = np.bincount(pc, weights=X[m], minlength=12)
    return out


def chroma_similarity(ref: np.ndarray, psg: np.ndarray, T: int) -> float:
    a, b = chroma(ref, T), chroma(psg, T)
    na, nb = np.linalg.norm(a, axis=1), np.linalg.norm(b, axis=1)
    m = (na > 1e-9) & (nb > 1e-9) & (na > np.percentile(na, 10))
    return float(np.mean((a[m] * b[m]).sum(axis=1) / (na[m] * nb[m])))


def voice_hz(states: list[tuple], v: int) -> np.ndarray:
    return np.array([AY_STEP / max(s[3][v], 1) if s[0][v] and s[1][v] else 0.0 for s in states])


# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

def intended(tg: Target, vol: np.ndarray, T: int) -> list[tuple]:
    """Per tick what the encoder meant the voice to play: (volume, tone, noise, period, noise
    period), None for the fields that do not matter."""
    out, state = [], (0, False, False, None, None)
    for t in range(T):
        v = int(vol[t])
        if v == 0:
            state = (0, False, False, None, None)
        elif tg.audible(t):
            state = (v,) + tg.fields(t)
        out.append(state)
    return out


def check_decode(states: list[tuple], wants: dict[int, list[tuple]]) -> int:
    """Ticks where the decoded registers differ from the encoder's intent."""
    bad = 0
    for t, s in enumerate(states):
        vol, tone, noise, per, r6 = s
        for v, want in wants.items():
            wv, wt, wn, wp, wnp = want[t]
            if vol[v] != wv or (wv and (tone[v] != wt or noise[v] != wn or (wt and per[v] != wp)
                                          or (wn and r6 != wnp))):
                bad += 1
    return bad


def audible_state(s: tuple) -> tuple:
    """The part of a register state that sounds."""
    vol, tone, noise, per, r6 = s
    out = []
    for v in range(3):
        out.append((vol[v], tone[v], noise[v], per[v] if tone[v] else None) if vol[v] else (0,))
    return tuple(out) + ((r6,) if any(vol[v] and noise[v] for v in range(3)) else ())


def fmt(x, spec="%.2f") -> str:
    return "-" if x is None else spec % x


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "msx" / "sound.inc")
    ap.add_argument("--wav", type=Path, default=ROOT / "build" / "music" / "preview",
                    help="directory of the preview WAVs")
    ap.add_argument("--no-wav", action="store_true", help="no WAVs and no comparison")
    ap.add_argument("--budget", type=int, default=6656,
                    help="bytes of sound.inc data (default 6.5 KiB)")
    ap.add_argument("--fx-lambda", type=float, default=FX_LAMBDA,
                    help="bytes-vs-distortion trade-off of the effects (0 = exact)")
    ap.add_argument("--seconds", type=float, default=60.0, help="title preview length")
    args = ap.parse_args()

    rep_t, data_t = load_music("TITM", "TITM_04.bin")
    rep_f, data_f = load_music("MU1", "MU1_09.bin")
    title = Title(rep_t, data_t)
    fx = Effects(rep_f, data_f)
    enc = encode(title, fx, args.budget, args.fx_lambda)
    blob, offs, sizes = assemble(enc, title, fx)
    total = write_inc(args.out, enc, title, fx, sizes)

    print("instruments of the title (Amiga channels 0-2 -> PSG tones):")
    for i in sorted(title.spc):
        p = title.pitch[i]
        print("  %2d %-10s %3d notes  %6.2f samples/cycle (%s, aperiodicity %.2f) -> %6.2f "
              "(tuning %+.2f -> %+.2f semitones from A4)%s%s" % (
                  i, title.insts[i].name, title.counts[i], p[0], p[2], p[1], title.spc[i],
                  tuning(p[0]), tuning(title.spc[i]),
                  ", an octave up" * title.octave[i] if title.octave[i] else "",
                  "; " + title.tune_why[i] if i in title.tune_why else ""))
    drums: dict = {}
    for d in title.drum_log:
        k = drums.setdefault(d["drum"], {"hits": 0, "voices": {}, "modes": {}, "lost": 0.0})
        k["hits"] += 1
        k["voices"][d["voice"]] = k["voices"].get(d["voice"], 0) + 1
        k["modes"][d["mode"]] = k["modes"].get(d["mode"], 0) + 1
        k["lost"] += d["lost"]
    print("drums (Amiga channel 3, riding a voice):")
    for name, k in sorted(drums.items()):
        print("  %-6s %3d hits on voices %s, as %s; melody lost: %.1f (sum of amplitudes)" % (
            name, k["hits"], k["voices"], k["modes"], k["lost"]))
    print("sizes: title %s = %d bytes (lambda %.3g), effects %d bytes (lambda %.3g), tables %d: "
          "%d bytes of data (budget %d)" % (
              "+".join(map(str, sizes["title"])), sum(sizes["title"]), enc["lam"],
              sum(sizes["fx"].values()), enc["lam_fx"], TABLES, total, args.budget))
    if sum(sizes["title"]) > enc["room"]:
        print("  warning: the title does not fit the budget even at its coarsest")
    print("wrote", args.out)

    # decode the bytes as the Z80 player does and check them against the encoder's intent
    T = title.T
    tstates = play_streams(blob, [(v, offs["title", v], offs["loop", v]) for v in range(3)], T + 20)
    wants = {v: intended(title.targets[v], enc["title_vols"][v], T) for v in range(3)}
    bad = check_decode(tstates[:T], wants)
    for n in sorted(enc["fx"]):
        tg = fx.targets[n]
        st = play_streams(blob, [(0, offs["fx", n], None)], tg.T)
        bad += check_decode(st, {0: intended(tg, choose_volumes(tg, args.fx_lambda, False), tg.T)})
        if sum(r[0] for r in enc["fx"][n]) > tg.T:
            bad += 1
    both = sum(1 for st in tstates[:T] if sum(1 for v in range(3) if st[0][v] and st[2][v]) > 1)
    print("decoded streams against the encoder: %d differing voice ticks; title ticks with "
          "noise on two voices: %d" % (bad, both))
    if any(sum(r[0] for r in recs) != T for recs in enc["title"]):
        print("error: a title stream does not last %d ticks" % T)
        return 1
    # the title's last ticks loop into its first: the decoded state at T.. equals 0..
    if [audible_state(s) for s in tstates[T:T + 20]] != [
            audible_state(s) for s in tstates[title.loop_tick:title.loop_tick + 20]]:
        print("error: the title does not loop seamlessly")
        return 1
    if args.no_wav:
        return 0 if not bad else 1

    # ---- the title: Amiga reference vs PSG ----
    N = min(T, int(args.seconds * TICK_HZ))
    refs = [c.render(0, N) for c in title.chans]
    voices = Psg().render(tstates[:N])
    voices = np.array([dc_block(v) for v in voices])
    src = np.full((3, N), -1)
    drum = np.zeros((3, N), bool)
    for v in range(3):
        on = np.array([s[0][v] > 0 for s in tstates[:N]])
        src[v] = np.where(on, title.targets[v].src[:N], -1)
        drum[v] = on & title.targets[v].drum[:N]
    per_src = np.zeros((4, N * SPT))
    hz = np.zeros((4, N))
    for v in range(3):
        vh = voice_hz(tstates[:N], v)
        for c in range(4):
            m = drum[v] if c == 3 else src[v] == c      # (a kick riding a note counts for both)
            per_src[c] += voices[v] * np.repeat(m, SPT)
            hz[c] = np.where(m, vh, hz[c])
    ref_mix, psg_mix = sum(refs), voices.sum(axis=0)
    write_wav(args.wav / "titm_amiga.wav", ref_mix)
    write_wav(args.wav / "titm_psg.wav", psg_mix)
    print("\ntitle, first %d s (Amiga reference rendered from the model vs the PSG streams "
          "decoded):" % (N // TICK_HZ))
    print("  %-22s %8s %8s %8s %8s   %s" % ("source", "ref std", "env r", "env MAE", "covered",
                                            "pitch / brightness"))
    for c in range(4):
        e = env_compare(refs[c], per_src[c], N)
        if c < 3:
            p = pitch_compare(refs[c], hz[c], N)
            extra = ("pitch on %d ticks: %s within 50 cents, %s same note name, median %s cents" % (
                p["ticks"], fmt(p.get("exact"), "%.3f"), fmt(p.get("chroma"), "%.3f"),
                fmt(p.get("median_cents"), "%.0f"))) if p["ticks"] else "no periodic ticks"
            name = "channel %d (voice %s)" % (c, "ABC"[c])
        else:
            b = bright_compare(refs[3], per_src[3], N, drum.any(axis=0))
            extra = "brightness on %d burst ticks: r %s, PSG - Amiga %s octaves" % (
                b["ticks"], fmt(b.get("r")), fmt(b.get("diff_oct"), "%+.2f"))
            name = "channel 3 (drums)"
        print("  %-22s %8s %8s %8s %8s   %s" % (
            name, fmt(e["ref_std"], "%.1f dB"), fmt(e["r"]), fmt(e["mae_db"], "%.1f dB"),
            fmt(e["coverage"], "%.2f"), extra))
    e = env_compare(ref_mix, psg_mix, N)
    print("  %-22s %8s %8s %8s %8s   chroma similarity %.3f" % (
        "mix", fmt(e["ref_std"], "%.1f dB"), fmt(e["r"]), fmt(e["mae_db"], "%.1f dB"),
        fmt(e["coverage"], "%.2f"), chroma_similarity(ref_mix, psg_mix, N)))

    # ---- the effects ----
    print("\neffects (Amiga reference vs PSG):")
    print("  %3s %-5s %5s %5s %-26s %6s %6s %6s  %s" % (
        "n", "ch", "ticks", "bytes", "modes (ticks)", "env r", "MAE", "cover", "pitch / brightness"))
    gap = np.zeros(int(0.4 * FS))
    all_a, all_p = [], []
    for n in sorted(enc["fx"]):
        tg = fx.targets[n]
        Tn = tg.T + 2
        cs = fx.chans[n]
        ref = sum(np.pad(c.render(), (0, 2 * SPT)) for c in cs)
        st = play_streams(blob, [(0, offs["fx", n], None)], Tn)
        out = dc_block(Psg().render(st)[0])
        e = env_compare(ref, out, Tn)
        vh = voice_hz(st, 0)
        p = pitch_compare(ref, vh, Tn)
        nmask = np.array([bool(s[0][0] and s[2][0]) for s in st])
        b = bright_compare(ref, out, Tn, nmask)
        bits = []
        if p["ticks"]:
            bits.append("pitch %d: %s/%s" % (p["ticks"], fmt(p["exact"]), fmt(p["chroma"])))
        if b["ticks"]:
            bits.append("bright %d: r %s %s oct" % (b["ticks"], fmt(b.get("r")),
                                                    fmt(b.get("diff_oct"), "%+.2f")))
        i = fx.info[n]
        print("  %3d %-5s %5d %5d %-26s %6s %6s %6s  %s" % (
            n, "+".join(map(str, i["channels"])), i["ticks"], sizes["fx"][n],
            " ".join("%s %d" % (k, v) for k, v in i["modes"].items() if v), fmt(e["r"]),
            fmt(e["mae_db"], "%.1f"), fmt(e["coverage"]), "; ".join(bits)))
        write_wav(args.wav / "sfx" / ("sfx_%02d_amiga.wav" % n), ref)
        write_wav(args.wav / "sfx" / ("sfx_%02d_psg.wav" % n), out)
        all_a += [ref / max(fx.a_ref, 1e-9), gap]
        all_p += [out, gap]
    write_wav(args.wav / "sfx_all_amiga.wav", np.concatenate(all_a))
    write_wav(args.wav / "sfx_all_psg.wav", np.concatenate(all_p))
    print("\nWAVs in", args.wav)
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
