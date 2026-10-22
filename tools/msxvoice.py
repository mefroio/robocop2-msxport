#!/usr/bin/env python3
"""RoboCop's speech ("YOUR MOVE, CREEP") for the MSX PSG: the title music's speech as PCM.

The title tune (TITM tune 1) says it at 57.6 s: instrument 24 (sample 11, "TOM" in its 8SVX
header, in fact the speech: the user identified it) on Amiga channel 2 from tick 2880 and again
on channel 0 from tick 2889 (a left/right echo nine ticks later), AUDxPER 335, volume 64
(build/music/TITM.json, rc2music.py's exact model).

Here both channels are rendered as Paula plays them (tools/msxsound.py Channel: a zero-order
hold at each channel's rate), summed, filtered as the A500's fixed output filter (one pole at
~4.4 kHz), resampled to the Z80 loop's rate (msx/music.asm vm_play: RATE_T T-states a sample,
measured in openMSX; 11.1 kHz, which puts the zero-order hold's first image above the speech
band, about 11 kHz: at 8 kHz it sat at 6-10 kHz) and cut where it falls silent. Each sample
becomes a byte: an index into the PSG table (voice_tab: smooth_table), the three voices'
volumes (tone and noise off: a voice outputs its volume's level) whose summed level on the AY's
curve comes nearest to the sample. A short ramp in and out of the middle level keeps the
speaker's DC step (the MSX's output capacitor) from thumping.

The table (smooth_table): vm_play writes voice C's volume, then B's, then A's, WRITE_GAP_T
T-states apart, and until the three are written the PSG outputs a mix of the old and the new
volumes. The nearest combination per level (the first table) jumps from one level to the next
((0, 12, 15) beside (6, 13, 14)), so every sample left 13-25 us of a level far from both: the
user heard it as a hiss under the speech in the music ("um chiado horrível"), simulated and
measured in openMSX 15-20 dB above the Amiga's highs (SNR against the Amiga's mix 7 dB). Here
the voices written later only grow with the level: A and B follow a path of single-volume steps
(coarse; chosen by dynamic programming against the transients and the error), C, written first,
gives the fine levels within each step (its jumps leave no transient). SNR against the Amiga's
mix 20 dB (simulated with the writes' timing); quantisation about 2-4 %.

With an SCC or an OPLL the speech keeps its place in the music (msx/music.asm vm_music): for
its VOICE_TICKS ticks the chips are muted and the PSG plays voice_mix.bin instead, the Amiga's
four channels from VOICE_TICK on (the speech with the bass and the drums going on, rendered the
same way), at MIX_GAIN times its own peak's level (measured in openMSX: the SCC's music around
it as loud against the PCM as on the Amiga); then the chips go on from the tick after. (A music
tick inside the PCM loop would hold the samples for 0.4-1 ms every 20 ms: measured in openMSX, a
buzz louder than the PCM's quantisation.) It swings around the table's coarse level (C at 0)
nearest DC_LEVEL, which voices A and B hold while the music plays (VOICE_DC_A, VOICE_DC_B;
music.asm: a silent DC, ramped at its start and end), so it starts and ends without a step: no
fades, only DC_FADE seconds of the swing at each end.

Outputs: build/msx/voice.bin and voice_mix.bin (the index bytes, whole 8 KiB banks:
tools/mkrom.py appends them to the ROM), build/msx/voice.inc (VOICE_LEN, VOICE_MIX_LEN,
VOICE_RATE_T, VOICE_TICK, VOICE_TICKS and voice_tab: 3 x 256 volumes, the table rc2.asm aligns),
and the preview WAVs build/music/preview/voice_amiga.wav, voice_msx.wav, voice_mix_amiga.wav and
voice_mix_msx.wav (the PSG model, as the loop plays them).

usage: msxvoice.py [OUT_DIR]   (default build/msx; needs numpy)
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import msxsound as ms  # noqa: E402  (the Amiga model: load_music, load_insts, Channel; AY_VOL)

ROOT = Path(__file__).resolve().parents[1]
CPU_HZ = 3579545                        # the MSX's Z80
RATE_T = 322                            # T-states of one vm_play sample (msx/music.asm: keep equal)
RATE = CPU_HZ / RATE_T                  # ~11117 samples a second
WRITE_GAP_T = 45                        # vm_play: T-states between its volume writes (C, B, A)
VOICE_INST = ms.SPEECH_INST             # instrument 24 = sample 11
VOICE_CHANNELS = (2, 0)                 # channel 2 from VOICE_TICK, channel 0 nine ticks later
VOICE_TICK = 2880                       # the speech's first tick in TITM tune 1
A500_LP_HZ = 4400.0                     # the A500's fixed output low-pass (one pole)
RAMP_S = 0.02                           # bias ramp in and out (seconds)
SILENT = 0.004                          # the end: the last sample louder than this (full scale 1)
MIX_GAIN = 0.57                         # voice_mix.bin's level: times its own peak's (msx/music.asm)
DC_LEVEL = 1.5                          # the level A and B hold under the music: the table's
                                        #   coarse level (C at 0) nearest to it
DC_FADE = 0.0015                        # the mix's swing faded in and out (seconds)
BANK = 0x2000


def lowpass(x: np.ndarray, hz: float, fs: float) -> np.ndarray:
    """One-pole low-pass at hz (msxsound.one_pole overflows for cutoffs this high)."""
    a = math.exp(-2 * math.pi * hz / fs)
    y = np.empty_like(x)
    prev = 0.0
    for i, v in enumerate(x):
        prev = a * prev + (1 - a) * v
        y[i] = prev
    return y


def render_amiga() -> np.ndarray:
    """Channels 0-2 of the title from VOICE_TICK to the tune's end, summed (full scale 1 each)."""
    rep, data = ms.load_music("TITM", "TITM_04.bin")
    tune = rep["tunes"][0]
    ticks = tune["ticks"]
    insts = ms.load_insts(rep, data)
    out = None
    for c in VOICE_CHANNELS:
        ch = ms.Channel(tune, c, insts, ticks)
        on = [t for t in range(VOICE_TICK, VOICE_TICK + 16) if ch.keyon[t] and ch.ins[t] == VOICE_INST]
        assert on, f"channel {c}: no speech key-on from tick {VOICE_TICK}"
        end = next(t for t in range(on[0], ticks) if ch.ins[t] != VOICE_INST)
        y = np.zeros((ticks - VOICE_TICK) * ms.SPT)
        y[(on[0] - VOICE_TICK) * ms.SPT:(end - VOICE_TICK) * ms.SPT] = ch.render(on[0], end)
        out = y if out is None else out + y
    return out


def render_mix(ticks: int) -> np.ndarray:
    """All four channels of the title from VOICE_TICK for `ticks` ticks, summed (the notes going
    on from before included: Channel keeps every sample's position from tick 0)."""
    rep, data = ms.load_music("TITM", "TITM_04.bin")
    tune = rep["tunes"][0]
    insts = ms.load_insts(rep, data)
    out = np.zeros(ticks * ms.SPT)
    for c in range(4):
        out += ms.Channel(tune, c, insts, tune["ticks"]).render(VOICE_TICK, VOICE_TICK + ticks)
    return out


def resample(x: np.ndarray) -> np.ndarray:
    """x at FS -> RATE (an anti-alias one-pole twice at 0.45 RATE, then linear interpolation)."""
    lp = lowpass(lowpass(x, 0.45 * RATE, ms.FS), 0.45 * RATE, ms.FS)
    n = int(len(lp) * RATE / ms.FS)
    return np.interp(np.arange(n) * ms.FS / RATE, np.arange(len(lp)), lp)


def quantise(target: np.ndarray, levels: np.ndarray) -> np.ndarray:
    """The nearest of the table's (sorted) levels to each target."""
    idx = np.clip(np.searchsorted(levels, target), 1, len(levels) - 1)
    left = levels[idx - 1]
    return np.where(np.abs(target - left) <= np.abs(levels[idx] - target), idx - 1, idx).astype(np.uint8)


def ramps(n: int) -> np.ndarray:
    r = int(RAMP_S * RATE)
    ramp = np.ones(n)
    ramp[:r] = np.linspace(0, 1, r)
    ramp[-r:] = np.linspace(1, 0, r)
    return ramp


def playback(idx: np.ndarray, triples: np.ndarray) -> np.ndarray:
    """The PSG's output at FS as vm_play plays the indexes: each sample's volumes written C, B,
    A, WRITE_GAP_T apart (the old ones until then), each output sample the average over its
    span."""
    n = len(idx)
    edges = np.arange(int(n * RATE_T / CPU_HZ * ms.FS) + 1) * CPU_HZ / ms.FS     # in T-states
    out = np.zeros(len(edges) - 1)
    vol = triples[idx]
    for voice, off in ((2, 0), (1, WRITE_GAP_T), (0, 2 * WRITE_GAP_T)):    # (C, B, A)
        t = np.concatenate(([0.0], np.arange(n) * RATE_T + off))
        v = ms.AY_VOL[np.concatenate(([vol[0, voice]], vol[:, voice]))]
        cum = np.concatenate(([0.0], np.cumsum(v[:-1] * np.diff(t))))
        j = np.searchsorted(t, edges, side="right") - 1
        integ = cum[j] + v[j] * (edges - t[j])
        out += np.diff(integ) / np.diff(edges)
    return out


def preview(path: Path, idx: np.ndarray, triples: np.ndarray) -> None:
    """The PSG as the loop plays the indexes (playback), the MSX's DC block."""
    ms.write_wav(path, ms.dc_block(playback(idx, triples)))


def error(levels: np.ndarray, target: np.ndarray) -> float:
    return float(np.sqrt(((levels - target) ** 2).mean()) / np.sqrt(((target - target.mean()) ** 2).mean()))


def snr(y: np.ndarray, ref: np.ndarray) -> float:
    """dB of ref's AC power over the error of y against it (both at FS), at the best gain and a
    delay within 1 ms (the loop's own delay is inaudible)."""
    k = min(len(y), len(ref)) - 100
    y = y[50:k] - y[50:k].mean()
    best = -99.0
    for d in range(-44, 45):
        r = ref[50 + d:k + d]
        r = r - r.mean()
        g = np.dot(y, r) / np.dot(r, r)
        best = max(best, 10 * math.log10(np.dot(g * r, g * r) / np.dot(y - g * r, y - g * r)))
    return best


def smooth_table() -> tuple[np.ndarray, np.ndarray]:
    """(levels, triples (a, b, c)) of voice_tab, sorted by level: A and B along a monotone path
    of single-volume steps, C the fine levels within each (see the docstring). The path: dynamic
    programming over 256 levels evenly spread over 0..3, the state (a, b) never decreasing, the
    cost the squared error of the best C plus the transient of a step at WRITE_GAP_T: the B and
    A changes after C's write, the A change after B's."""
    lv = ms.AY_VOL
    t = np.linspace(0, 3, 256)
    ab = lv[:, None] + lv[None, :]
    err = np.abs((t[:, None, None] - ab[None])[..., None] - lv[None, None, None, :])
    qerr = (err.min(axis=-1) ** 2).reshape(256, 256)                 # [level, state a*16+b]
    da = lv[None, None, :, None] - lv[:, None, None, None]           # [a, b, a', b']: from (a', b')
    db = lv[None, None, None, :] - lv[None, :, None, None]
    trans = ((da + db) ** 2 + da ** 2) * (WRITE_GAP_T / RATE_T)
    up = (np.arange(16)[None, None, :, None] <= np.arange(16)[:, None, None, None]) & \
         (np.arange(16)[None, None, None, :] <= np.arange(16)[None, :, None, None])
    trans = np.where(up, trans, np.inf).reshape(256, 256)            # [state, previous state]
    cost, back = qerr[0].copy(), np.zeros((256, 256), dtype=int)
    for i in range(1, 256):
        tot = cost[None, :] + trans
        back[i] = tot.argmin(axis=1)
        cost = tot[np.arange(256), back[i]] + qerr[i]
    state = [int(cost.argmin())]
    for i in range(255, 0, -1):
        state.append(int(back[i][state[-1]]))
    path = []
    for st in reversed(state):
        if not path or path[-1] != divmod(st, 16):
            path.append(divmod(st, 16))
    levels, triples = [], []
    for k, (a, b) in enumerate(path):
        top = lv[path[k + 1][0]] + lv[path[k + 1][1]] if k + 1 < len(path) else np.inf
        for c in range(16):
            if lv[a] + lv[b] + lv[c] < top - 1e-9:
                levels.append(lv[a] + lv[b] + lv[c])
                triples.append((a, b, c))
    order = np.argsort(levels, kind="stable")
    assert len(order) <= 256
    return np.array(levels)[order], np.array(triples)[order]


def main(argv: list[str]) -> int:
    out_dir = Path(argv[1]) if len(argv) > 1 else ROOT / "build" / "msx"
    amiga = render_amiga()
    filt = lowpass(amiga, A500_LP_HZ, ms.FS)
    # the end: where the sound stays below SILENT
    loud = np.nonzero(np.abs(filt) > SILENT)[0]
    end = int(loud[-1]) + 1 if len(loud) else len(filt)
    filt = filt[:end]
    x = resample(filt)
    n = len(x)
    # around the middle of the PSG's range: full use of 0..3 with the bias ramps
    peak = np.percentile(np.abs(x), 99.9)
    u = x / peak * 1.45
    target = np.clip(1.5 * ramps(n) + u, 0, 3)
    levels, triples = smooth_table()
    coarse = np.nonzero(triples[:, 2] == 0)[0]
    dc_idx = int(coarse[np.abs(levels[coarse] - DC_LEVEL).argmin()])      # (A, B and C at 0)
    dc_a, dc_b = (int(v) for v in triples[dc_idx, :2])
    dc = levels[dc_idx]
    idx = quantise(target, levels)
    # the PCM bytes, padded to whole banks
    pcm = bytes(idx)
    banks = -(-len(pcm) // BANK)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "voice.bin").write_bytes(pcm + bytes([idx[-1]]) * (banks * BANK - len(pcm)))
    ticks = math.ceil(len(pcm) / RATE * ms.TICK_HZ)
    # the speech in the music: all four channels for those ticks around the held level (its
    # first and last samples exactly that), at MIX_GAIN times its own peak's level
    mix_amiga = lowpass(render_mix(ticks), A500_LP_HZ, ms.FS)
    xm = resample(mix_amiga)[:round(ticks * RATE / ms.TICK_HZ)]
    um = xm / np.percentile(np.abs(xm), 99.9) * 1.45 * MIX_GAIN
    f = int(DC_FADE * RATE)
    fade = np.ones(len(um))
    fade[:f] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, f))
    fade[-f:] = fade[:f][::-1]
    tmix = np.clip(dc + fade * um, 0, 3)
    imix = quantise(tmix, levels)
    imix[0] = imix[-1] = dc_idx
    mbanks = -(-len(imix) // BANK)
    (out_dir / "voice_mix.bin").write_bytes(bytes(imix) + bytes([imix[-1]]) * (mbanks * BANK - len(imix)))
    inc = ["; generated by tools/msxvoice.py: RoboCop's speech (\"YOUR MOVE, CREEP\") as PSG PCM",
           f"VOICE_LEN: equ {len(pcm)}             ; samples ({len(pcm) / RATE:.2f} s)",
           f"VOICE_BANKS: equ {banks}",
           f"VOICE_MIX_LEN: equ {len(imix)}         ; the speech in the music (voice_mix.bin): samples",
           f"VOICE_MIX_BANKS: equ {mbanks}",
           f"VOICE_RATE_T: equ {RATE_T}            ; T-states a sample (msx/music.asm vm_play)",
           f"VOICE_TICK: equ {VOICE_TICK}           ; the title's tick where it starts",
           f"VOICE_TICKS: equ {ticks}              ; its length in 50 Hz ticks (voice_mix.bin's too)",
           f"VOICE_DC_A: equ {dc_a}               ; the level voices A and B hold under the music (C: 0),",
           f"VOICE_DC_B: equ {dc_b}",
           f"VOICE_DC_IDX: equ {dc_idx}            ;   voice_tab's index of it",
           "voice_tab:                          ; per index: voice C's volume (written first), then B's,"
           " then A's (256 each)"]
    tab = np.concatenate((triples, np.repeat(triples[-1:], 256 - len(triples), axis=0)))
    for k in (2, 1, 0):
        col = tab[:, k]
        inc += ["        db " + ", ".join(str(int(v)) for v in col[i:i + 16]) for i in range(0, 256, 16)]
    (out_dir / "voice.inc").write_text("\n".join(inc) + "\n")
    # previews: the Amiga's (its filter) and the PSG's as the loop plays it
    prev = ROOT / "build" / "music" / "preview"
    ms.write_wav(prev / "voice_amiga.wav", filt)
    preview(prev / "voice_msx.wav", idx, triples)
    ms.write_wav(prev / "voice_mix_amiga.wav", mix_amiga)
    preview(prev / "voice_mix_msx.wav", imix, triples)
    clip = float(np.mean((dc + um < 0) | (dc + um > 3)))
    print(f"voice: {len(pcm)} samples at {RATE:.0f} Hz ({len(pcm) / RATE:.2f} s, {ticks} ticks), "
          f"{banks} banks; table: {len(levels)} levels, the held one {dc:.3f} = A {dc_a}, B {dc_b}; "
          f"quantisation error {100 * error(levels[idx], target):.1f} % of the signal, against the "
          f"Amiga {snr(playback(idx, triples), filt):.1f} dB; in the music: {len(imix)} samples, "
          f"{mbanks} banks, error {100 * error(levels[imix], tmix):.1f} %, against the Amiga "
          f"{snr(playback(imix, triples), mix_amiga):.1f} dB, {100 * clip:.2f} % clipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
