# MSX2 / MSX2+ port architecture — proposal (draft)

Mandatory baseline: **MSX2 (V9938)**; the MSX2+ (V9958) is detected at run time (ID in
S#1) and used when present. Source facts in `docs/AMIGA_ANALYSIS.md`; measurements in
`docs/MSX_FEASIBILITY.md`.

## What the original does (Amiga)

| Item | Amiga |
|---|---|
| Logic / video | 25 frames/s; visible area 288×177, 16 colours + hardware sprites (15 colours) |
| Background | fully redrawn every frame (19×12 tiles of 16×16) |
| Level 1 | 160×51 tile map (2560×816 px), 431 unique tiles, 8-way scrolling |
| Player | composed into hardware sprites (up to 48×72, 15 colours) |
| Enemies | 5 slots; masked BOBs built from parts (16×16 to 64×40) |

## Proposal for the MSX

| Item | Proposal | Reason |
|---|---|---|
| Video mode | SCREEN 5 (256×212, 16 of 512 colours) | same 4 bpp tile format; 9-bit palette ≈ original |
| Play area | 256×176 (11 tile rows) + HUD | the Amiga shows 177 lines |
| Vertical scroll | R#23 (MSX2 and MSX2+) | hardware, zero cost |
| Horizontal scroll MSX2+ | R#26/R#27 + SP2 (512 px) + MSK | only one new column every 16 px |
| Horizontal scroll MSX2 | R#18 (±8 px) + shifted copy to the other page spread over several frames + page flip | one page costs ~6–8 frames; fits at ~1 px/frame |
| Tiles in VRAM | VRAM tile cache fed from RAM/ROM as the camera moves, if a level exceeds 512 tiles | 431 tiles (55 KiB) fit in pages 2–3 for level 1 |
| Frame rate | logic at 25–30 Hz (like the original); video synchronised to VBL | measured VDP budget |

## Decisions taken (2026-10-19)

1. **Characters in hardware sprites** (mode 2), looking as close as possible to the
   software rendering. Technique: per line and per 16 px column, 2 OR-ed layers p and q
   give the colours p, q and p|q. The sprites use the same 16-colour palette as the
   background; the character's 7 colours sit at indices 1–7 (an OR-closed set), a
   duplicated palette slot is freed for sprite black, and the pair of each line is chosen
   by minimising the Lab distance to the software rendering (`tools/msxmock_or3.py`;
   accepted mockup: `build/mock/robocop_sw_vs_hw_opt_zoom.png`). RoboCop needs 12–22
   sprites per frame (median 16, worst line 6) → enemies need multiplexing or reductions.
2. **MegaROM, with MegaRAM as the minimum requirement**: 8 KiB bank switching by writes
   inside the page itself (Konami/SCC style: `5000h`, `7000h`, `9000h`, `B000h`), which
   works on MegaRAM and on Konami SCC cartridges. 128 KiB of VRAM remain required.
3. **Sound**: PSG mandatory + **FM-PAC/MSX-MUSIC** when detected (built into several MSX2+,
   common as a cartridge on MSX2; 9 channels plus drums). SCC only as an option if found in
   a slot — the MegaRAM has no SCC.
4. **SCREEN 5 everywhere** (game, HUD, logos, text screens). SCREEN 8 rejected: fixed 3-3-2
   palette worse for 16-colour art, sprites with a fixed 16-colour palette (rules out the
   approved RoboCop), double VDP cost and 64 KiB pages without room for tiles.
5. **Only two digitised photos, in SCREEN 8 and in their original places**: TPIC = title
   screen and PIC9 = game over (confirmed in code: `$11E06` builds `PIC('1'+D0)`; D0 = 8
   comes from `main_loop` when the lives run out). 320→256 px width conversion (same width
   on the TV), fixed 3-3-2 palette with Floyd–Steinberg (`tools/msxpic.py`). The other
   photos are dropped and the between-level scenes become text/briefing screens; MegaROM
   estimated at ~300–450 KiB compressed (fits in 512 KiB).
6. **MegaROM** kept; bank switching goes through a single routine, so a floppy + memory
   mapper version stays possible in the future.
