#!/usr/bin/env python3
"""RoboCop's speech ("YOUR MOVE, CREEP") for the MSX PSG: the title music's speech as PCM.

The title tune (TITM tune 1) says it at 57.6 s: instrument 24 (sample 11, "TOM" in its 8SVX
header, in fact the speech: the user identified it) on Amiga channel 2 from tick 2880 and again
on channel 0 from tick 2889 (a left/right echo nine ticks later), AUDxPER 335, volume 64
(build/music/TITM.json, rc2music.py's exact model).

Here both channels are rendered as Paula plays them (tools/msxsound.py Channel: a zero-order
hold at each channel's rate), summed, filtered as the A500's fixed output filter (one pole at
~4.4 kHz), resampled to the Z80 loop's rate (msx/music.asm vm_play: RATE_T T-states a sample,
measured in openMSX) and cut where it falls silent. Each sample becomes a byte: an index into
the PSG table (voice_tab): the three voices' volumes (tone and noise off: a voice outputs its
volume's level) whose summed levels on the AY's curve come nearest to the sample, the 256
indexes spread evenly over the sums' range. A short ramp in and out of the middle level keeps
the speaker's DC step (the MSX's output capacitor) from thumping.

With an SCC or an OPLL the speech keeps its place in the music (msx/music.asm vm_music): for
its VOICE_TICKS ticks the chips are muted and the PSG plays voice_mix.bin instead, the Amiga's
four channels from VOICE_TICK on (the speech with the bass and the drums going on, rendered the
same way), at MIX_GAIN times its own peak's level (measured in openMSX: the SCC's music around
it as loud against the PCM as on the Amiga); then the chips go on from the tick after. (A music
tick inside the PCM loop would hold the samples for 0.4-1 ms every 20 ms: measured in openMSX, a
buzz louder than the PCM's quantisation.) It swings around voices A and B's levels DC_A and DC_B
(C at 0), which they hold while the music plays (music.asm: a silent DC, ramped at its start and
end), so it starts and ends without a step: no fades, only DC_FADE seconds of the swing at each
end; the table's entry nearest that level is set to those volumes exactly.

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
RATE_T = 448                            # T-states of one vm_play sample (msx/music.asm: keep equal)
RATE = CPU_HZ / RATE_T                  # ~7990 samples a second
VOICE_INST = ms.SPEECH_INST             # instrument 24 = sample 11
VOICE_CHANNELS = (2, 0)                 # channel 2 from VOICE_TICK, channel 0 nine ticks later
VOICE_TICK = 2880                       # the speech's first tick in TITM tune 1
A500_LP_HZ = 4400.0                     # the A500's fixed output low-pass (one pole)
RAMP_S = 0.02                           # bias ramp in and out (seconds)
SILENT = 0.004                          # the end: the last sample louder than this (full scale 1)
MIX_GAIN = 0.57                         # voice_mix.bin's level: times its own peak's (msx/music.asm)
DC_A, DC_B = 15, 12                     # the level voices A and B hold under the music (C: 0)
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


def quantise(target: np.ndarray, sums: np.ndarray) -> np.ndarray:
    """The nearest of the table's 256 levels to each target."""
    idx = np.clip(np.searchsorted(sums, target), 1, 255)
    left = sums[idx - 1]
    return np.where(np.abs(target - left) <= np.abs(sums[idx] - target), idx - 1, idx).astype(np.uint8)


def ramps(n: int) -> np.ndarray:
    r = int(RAMP_S * RATE)
    ramp = np.ones(n)
    ramp[:r] = np.linspace(0, 1, r)
    ramp[-r:] = np.linspace(1, 0, r)
    return ramp


def preview(path: Path, levels: np.ndarray) -> None:
    """The PSG as the loop plays the levels: a zero-order hold, the MSX's DC block."""
    n = len(levels)
    hold = levels[np.minimum((np.arange(int(n * ms.FS / RATE)) * RATE / ms.FS).astype(int), n - 1)]
    ms.write_wav(path, ms.dc_block(hold))


def error(levels: np.ndarray, target: np.ndarray) -> float:
    return float(np.sqrt(((levels - target) ** 2).mean()) / np.sqrt(((target - target.mean()) ** 2).mean()))


def psg_table() -> tuple[np.ndarray, np.ndarray]:
    """(sums, triples): 256 sums of three AY levels spread evenly over 0..3, each the nearest
    combination, and those combinations (volumes 0-15)."""
    lv = ms.AY_VOL
    combos = [(lv[a] + lv[b] + lv[c], a, b, c) for a in range(16) for b in range(16) for c in range(16)]
    sums = np.array([s for s, *_ in combos])
    targets = np.linspace(0, 3, 256)
    best = [combos[int(np.abs(sums - t).argmin())] for t in targets]
    return np.array([b[0] for b in best]), np.array([b[1:] for b in best])


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
    sums, triples = psg_table()
    dc = ms.AY_VOL[DC_A] + ms.AY_VOL[DC_B]
    dc_idx = int(np.abs(sums - dc).argmin())        # (the held level: exactly A, B, 0)
    sums[dc_idx] = dc
    triples[dc_idx] = (DC_A, DC_B, 0)
    idx = quantise(target, sums)
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
    imix = quantise(tmix, sums)
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
           f"VOICE_DC_A: equ {DC_A}               ; the level voices A and B hold under the music (C: 0),",
           f"VOICE_DC_B: equ {DC_B}",
           f"VOICE_DC_IDX: equ {dc_idx}            ;   voice_tab's index of it",
           "voice_tab:                          ; per index: voice A's volume, then B's, then C's (256 each)"]
    for k in range(3):
        col = triples[:, k]
        inc += ["        db " + ", ".join(str(int(v)) for v in col[i:i + 16]) for i in range(0, 256, 16)]
    (out_dir / "voice.inc").write_text("\n".join(inc) + "\n")
    # previews: the Amiga's (its filter) and the PSG's as the loop plays it
    prev = ROOT / "build" / "music" / "preview"
    ms.write_wav(prev / "voice_amiga.wav", filt)
    preview(prev / "voice_msx.wav", sums[idx])
    ms.write_wav(prev / "voice_mix_amiga.wav", mix_amiga)
    preview(prev / "voice_mix_msx.wav", sums[imix])
    clip = float(np.mean((dc + um < 0) | (dc + um > 3)))
    print(f"voice: {len(pcm)} samples at {RATE:.0f} Hz ({len(pcm) / RATE:.2f} s, {ticks} ticks), "
          f"{banks} banks; quantisation error {100 * error(sums[idx], target):.1f} % of the signal; "
          f"in the music: {len(imix)} samples, {mbanks} banks, error {100 * error(sums[imix], tmix):.1f} %, "
          f"{100 * clip:.2f} % clipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
