# MSX2 / MSX2+ feasibility — measurements

Measured in headless openMSX through MSX-AI (`msx_local_asm_load` + RAM reads), SCREEN 5,
display on, timed with JIFFY (1/60 s). Test program: page copy (HMMM 256×212), 16×16 tile
(HMMM), 32×48 software sprite with transparency (LMMM + TIMP) and screen fill (HMMV).

| Machine (openMSX) | VDP | S#1 | ID |
|---|---|---|---|
| Gradiente Expert 2.0 (`basic` profile) | V9938 | `$00` | 0 |
| Sony HB-F1XDJ (`msx2plus` profile) | V9958 | `$04` | 2 |

| Operation | Sprites on | Sprites off |
|---|---|---|
| HMMM full page 256×212 | 9.5 frames | 7.3 frames |
| HMMM 16×16 tile | ~17–18 per frame | ~20 per frame |
| LMMM+TIMP 32×48 | 0.66 frame | 0.58 frame |
| HMMV full screen | 4.6 frames | 4.5 frames |

Timings are identical on the V9938 and the V9958 (same command engine).

## Consequences for the port engine

- **No per-frame background redraw** (the Amiga redraws 19×12 tiles every frame; on the
  MSX that would take ~10 frames). The background must be scrolled by hardware and only the
  new edges redrawn.
- **Vertical (MSX2 and MSX2+):** R#23 (hardware, 256-line page used as a ring).
- **Horizontal on MSX2+:** R#26/R#27 (+ SP2 for a 512 px wide ring and MSK to hide the
  edge): only one new tile column every 16 px (~0.6 frame).
- **Horizontal on MSX2:** R#18 (±8 px) inside a 16 px step + a shifted copy to the other
  page spread over several frames, then a page flip. A 256×160 play area costs ~6 frames
  per step; at 1 px/frame (16 frames per step) it fits.
- **Characters:** large software sprites cost ~0.6 frame each; the player and most enemies
  need hardware sprites (mode 2, 16×16, 8 per line, colour per line, CC overlap for 3
  colours).
- **Tiles:** 16×16 at 4 bits = 128 bytes, the same size as the Amiga format; the 509 tiles
  of level 1 fit in 2 VRAM pages (512 tiles).

## Tile rendering test (MSX2, V9938)

- Conversion: `tools/msxconv.py level` (12-bit OCS palette → 9-bit V9938 palette, packed
  4 bpp tiles, deduplication, map with 16-bit indices, VRAM image with the tiles in pages
  2–3). Level 1: **160×51 tile** map, **431 unique tiles** (55 KiB).
- In openMSX (`basic` profile, Gradiente Expert 2.0): SCREEN 5, level palette, tiles loaded
  into VRAM with `load_debuggable VRAM`, and a Z80 renderer that copies a 16×13 map window
  with HMMM (208 tiles). Result identical to the preview: the start of level 1 (skyline,
  wall, pipes, crate) — capture in `build/png/msx2_level1_start.png`.
- The 3-bit-per-channel palette looks very close to the original; two dark colours
  (`$200`, `$310`) collapse into `100` — improve the quantisation later.

## MSX2+ scroll prototype (V9958) — `msx/`

- **Language**: Z80 assembly (z80asm 1.8, the same assembler MSX-AI uses); data tools in
  Python. KonamiSCC/MegaRAM MegaROM built by `tools/mkrom.py` (`make rom`): code in banks
  0–1 (`4000h–7FFFh`), level 1 tiles in banks 2–9 (copied into VRAM pages 2–3 by the Z80
  with the display off), map in banks 10–12 (25 rows per bank, read through the `A000h`
  window).
- **Engine**: SP2 (512×256 ring over pages 0+1), R#26/R#27 for x, R#23 for y, MSK on. Keeps
  columns [cx−1, cx+17] and rows [cy−1, cy+13] drawn; the column/row about to enter is drawn
  **one step ahead**, at most 6 tiles per frame. Loop synchronised to VBLANK by polling S#0.
- **Result** (headless openMSX, HB-F1XDJ, via MSX-AI): V9958 detected; camera at 1 px/frame
  horizontally and 0.5 px/frame vertically; **0 late frames** in more than 57 thousand
  frames. Pixel check: VRAM and registers saved from the openMSX console →
  `tools/msxscreen.py` (rebuilds the display with openMSX's SP2/R#26/R#27 logic) →
  **0 pixels differ** from the expected map at position (131, 559)
  (`build/png/msx2plus_scroll_vs_ref.png`).

## MSX2 scroll prototype (V9938) — `msx/scroll9938.asm`

- **Technique**: two pages aligned to 16 px; the set-adjust (R#18) shifts image and sprites
  by s = 8 − f px (−7..+8, applied from the next line, as in the openMSX source). The kept
  rows are [cy−1, cy+12] (14 rows = 224 lines for the 176-line view). The back page is built
  for the next column: first the new column (one tile per ring slot, using the kept row that
  occupies the slot at that moment), then a 16 px shifted copy of the 14 row slots from the
  displayed page, in chunks of up to 4 rows that never cross the ring wrap (240 × ≤64 px).
  New rows go to both pages; on the back page only the new column is drawn when the pending
  copy will still bring the rest of the row. The scheduler issues at most one VDP command at
  a time and never blocks; it is also called while the main loop waits for VBLANK. Page flips
  are applied by the VBLANK interrupt, and the old page is reused only after that.
- **Result** (headless openMSX, Gradiente Expert 2.0, via MSX-AI), 212-line mode with the
  HUD split and sprites enabled, play area 163 lines: pixel check of the whole frame (play
  area + HUD, `tools/msxframe.py`) at camera (516, 395) → **0 pixels differ** out of 52,936.
  Run over 3,872 frames (x 0 → 2304 → 744, 1 px/frame horizontally and 0.5 px/frame
  vertically, bouncing vertically): **0 late frames** and **7 stall frames** (0.18%), all at
  the reversal at the right edge of the map (the back page has to be rebuilt for the other
  side). With a 176-line play area: 0 late, 10 stalls; the first version (sprites off): 1
  late frame and 3% stalls.
- **Fix found with the sprite tests**: a page flip could happen while a new row was still
  being drawn; the columns the row had already drawn went only to the old page and the new
  displayed page kept stale tiles (here still the CHGMOD fill, colour 4). A row still pending
  at a flip now starts again on the new displayed page.
- The camera (world `cam_x`) is at screen x = 8 on both machines. The usable area is
  248 px wide (screen x 8–255); on MSX2 the right edge shows up to 7 px of border while
  s < 0 (f ≥ 9), a limit of the ±8 px set-adjust with 256 px pages.

## MSX2+ scroll (V9958) with the HUD

- Same frame structure (VBLANK register list, HUD split); kept rows [cy−1, cy+12], columns
  [cx−1, cx+17]; R#26/R#27 computed from cam_x − 8 so that the camera sits at screen x = 8
  as on MSX2 (MSK hides x 0–7).
- **Result** (headless openMSX, HB-F1XDJ), play area 163 lines: pixel check at camera
  (430, 438) → **0 pixels differ** out of 52,936 (the HUD checked over all 256 px); run over
  4,026 frames with direction reversals: **0 late frames**, **0 stall frames**.

## HUD split (line interrupt) — `msx/isr.asm`

- SCREEN 5 in 212-line mode: play area = display lines 0–162 (pages 0–1), lines 163–166
  blank, HUD = display lines 167–211 showing page 3 lines 208–252 (R#23 = 41) with its own
  16-colour palette (`tools/msxhud.py`). A first version used 176 + 36 lines with a shrunk
  panel; the user chose the full 45-line panel with all elements 1:1.
- Own IM 2 handler (257-byte vector table, no BIOS interrupt code). At VBLANK it applies the
  register list the main loop published for the next frame (R#1, R#2, R#8, R#23, R#19 and
  R#18 or R#26/R#27, plus the sprite table R#5) and the play-field palette. The line
  interrupt fires at the right border of line V−4 (V = 163, R#19 = V−4 + R#23): the handler
  polls HR (S#2 bit 5) to find the end of line V−2, blanks the display and switches sprites
  off during line V−1 (both take effect at the next line), waits for the right border of
  line V−1, then writes R#2 = page 3, R#23 = 41, R#18 = 0 (V9958: R#26/R#27) and the HUD
  palette with unrolled OUTI, turns the display back on while still in line V+3 and, on the
  V9958, turns the border mask off (the HUD's left columns are still black there).
- Timing facts from the openMSX VDP source used here: the line interrupt matches display
  line (R#19 − R#23) & 255 at its right border; R#1, R#8 and R#18 changes take effect at the
  next line start; R#2, R#23, R#26, R#27 and the palette take effect immediately; HR lasts
  312 VDP ticks from the right border and moves with the horizontal adjust. A first version
  that wrote R#18 during line 175 missed the HR window by 3 T-states and lost a line.
- **Measured** with the VDP probes (`tools/openmsx_rc2.tcl`, `tools/splitlog.py`): display
  off written in line V−1 (ticks 514–748), display on written in line V+3 (V9938 tick ~775,
  V9958 tick ~1160–1230, deadline 1512): the HUD shows from line V+4 on both VDPs (measured
  with V = 176 and again with V = 163).
- The line interrupt stays enabled; the extra match that R#23 = 0 can create inside the HUD
  is acknowledged and ignored by the handler. Main-program rule: every port 99h sequence
  runs with interrupts disabled, and R#15 is 0 whenever interrupts are enabled.

## RoboCop in hardware sprites (adaptive budget, RoboCop only) — `msx/sprites.asm`

Superseded by the engine with the enemies (next section). Demo: RoboCop runs through
all 69 frame records (a new one every 4 frames) and the 4 aims while the camera scrolls in
x and y; a 32×16 enemy ball (2 sprites) sweeps lines 40–150, so it meets every line of him.

- **First version**: both sets alternated every frame and the budget and the SAT list walked
  every span: budget 17,200 T, list 16,900 T, pattern and colour uploads 16,500 + 17,300 T
  per set (so twice per pose change). The main loop took more than a frame: 12 of 23 frames
  late on MSX2.
- **Current version** (profile with `rc2_prof` + `tools/proflog.py`, 20 s of emulated time,
  T-states at 3.58 MHz, a frame = 59,736 T):

  | | MSX2 (Expert) | MSX2+ (HB-F1XDJ) |
  |---|---|---|
  | late frames | 0 of 1,198 | 0 of 1,197 |
  | main-loop work per frame (scroll + sprites, without the wait) | mean 21,774 T (36.4%), max 37,844 T (63.4%) | mean 21,533 T (36.0%), max 39,103 T (65.5%) |
  | sprite upload (pose changes, 150 units per frame) | mean 11,692 T, max 24,421 T | mean 11,772 T, max 24,421 T |
  | SAT build (21 RoboCop entries + enemy) | mean 5,557 T, max 11,407 T | mean 5,552 T, max 11,407 T |
  | SAT write after the VBLANK | 2,452 T | 2,452 T |
  | budget | mean 1,567 T, max 5,158 T | mean 1,495 T, max 5,158 T |

  The SAT write ends at most 7,013 T (MSX2) / 7,510 T (MSX2+) after the VBLANK interrupt,
  i.e. within ~33 of the 50 lines before display line 0 (60 Hz).
- **Pixel checks** (`rc2_snaps` + `tools/checkrun.py`; the whole frame: map, HUD, RoboCop as
  `tools/msxsprites.py` converts the composition shown, with A1 for dropped columns, and the
  ball where it is expected): 32 snapshots on each machine → **0 pixels differ** (snapshots
  taken between the VBLANK and the SAT write are reported and their sprites skipped).
  Dropping: test ROM with RoboCop on frame record 20 (8 sprites on lines 16–30), 12
  snapshots on each machine while columns were dropped (masks 08h and 09h) → RoboCop exact
  and the ball fully shown (360 of 360 pixels: no line went over 8). Lost VRAM writes with
  `too_fast_vram_access = real`: 0.
- Found on the way: a sprite whose SAT y is 216 ends the table; the old workaround (215)
  showed that part one line off. Now the whole of RoboCop moves by the smallest offset that
  avoids 216 (seen as "(96,59)" in the checks: exact, one line up).

## RoboCop and the enemies in hardware sprites — `msx/sprites.asm`

Design in `docs/MSX_ARCHITECTURE.md` ("Sprite engine"). Demo (`demo_actors`, build option
`DEMO_ACTORS`): RoboCop runs through all 69 frame records (a new one every 2 ticks) and the
4 aims; screen actors (gunner 48×40, woman 32×48) bounce across his lines; world actors
(bazooka man 48×40, vehicle 48×24, an explosion's 8 frames) scroll with the map. Two scenes:
**two enemies** (`DEMO_ACTORS=2`, the gunner and the woman, both on RoboCop's lines) and
**stress** (all five: 77 sprites at full quality, 39 on one layer).

- **Path to the current version** (MSX2, stress scene, profile with `rc2_prof`): the first
  version with enemies took ~300k T per tick (budget alone ~190k: a column-by-column greedy
  over per-line counts). Exact greedies with cheaper data still cost 20–80k T per tick; the
  layout and the SAT ~25k T each; every layout change refilled and uploaded everything.
  What made it fit: a budget that runs only when something it looks at changed, decides from
  per-composition maxima (no per-line arrays), leaves out what cannot fit at all and keeps
  dropped columns while the composition stays; entry pages kept or refilled per object;
  the page filling, pattern and colour uploads as one progressive job sharing a per-frame
  work budget with the HUD and the logic, stopping at the HUD split; the SAT built once per
  tick; the scroll engine's VDP commands fed during the sprite work.
- **Current version** (10 s of emulated time each; a frame = 59,736 T):

  | | MSX2 two enemies | MSX2 stress | MSX2+ two enemies | MSX2+ stress |
  |---|---|---|---|---|
  | late frames | 0 of 599 | 20 of 575 | 0 of 598 | 26 of 567 |
  | main-loop work per frame | mean 62.3%, max 86.6% | mean 79.3%, max 111.6% | mean 62.1%, max 86.7% | mean 79.6%, max 116.9% |
  | camera stalls (scroll waiting) | 6 in 1,108 frames | 6 in 1,042 | 0 | 0 |

  Costs (MSX2, two enemies, mean / max T): budget 3,951 + conflicts 5,091 + RoboCop's need
  2,721 + his drops 1,334 / 2,695 + total 1,067 / 2,388 (only when something changed: half
  the ticks); layout pass 9,860 / 12,028 (35% of the ticks); SAT 10,808 / 12,888 per tick;
  SAT phase 4,418 per frame while objects alternate; the demo's own work 5,261 / 9,753.
- **Pixel checks** (24 snapshots per run, `tools/checkrun.py`): two enemies → 24 of 24
  exact on both machines; stress → 24 of 24 on the MSX2+ and 22 of 24 on the MSX2 (an
  object crossing the left border lost its left column: its early-clock layout was still on
  its way, the upload being saturated). Lines where the SAT shown holds more than 8 sprites
  are now reported apart by `tools/msxframe.py` (none in these runs); it also checks that
  nothing wrote into the tile area of VRAM.
- **Found on the way**: the HUD's energy can wrote its "empty top" for levels 31–32 (the first
  two steps down from full, whose top starts above the can) to a wrapped address in the tile
  area, corrupting tile slots 208–209; `can_line` now takes signed lines. Objects wholly above
  the play area could show at its bottom (8-bit SAT y wrapping around); they are parked now.

## HUD at run time — `msx/hud.asm`

Demo events (`hud_demo`): timer −1 s per second, score +150 every 97 frames, ammo −1 every
8 frames, a weapon change every 8 s (ammo and icon from the game's tables), energy −18h every
90 frames with refills to full, a message every 4 s, a life lost (heads 3, 4, 5) or gained
every 15 s; RoboCop and the ball keep running as in the sprite test.

- **Pixel checks**: 40 snapshots on each machine (taken when no HUD job is half written) →
  **0 pixels differ** over the whole frame, the HUD compared with the Amiga panel model in
  the state `msx/hud.asm` records (`tools/msxframe.py`, `tools/hudmodel.py`). Lost VRAM
  writes: 0.
- **Profile** (30 s, with the sprites): first version (every HUD task in the same frame):
  10 late frames in 1,186 (text drawing up to 12,152 T, a digit cell plus the scan up to
  10,933 T). Current version (font packed for both phases, one piece of work per frame
  besides the ticker, the HUD's work taken off the sprite upload):

  | | MSX2 (Expert) | MSX2+ (HB-F1XDJ) |
  |---|---|---|
  | late frames | 0 of 1,797 | 0 of 1,797 |
  | main-loop work per frame (scroll, sprites, HUD) | mean 29,316 T (49.1%), max 45,645 T (76.4%) | mean 29,130 T (48.8%), max 45,386 T (76.0%) |
  | latest publication after its VBLANK | 47,327 T (79%) | 47,196 T (79%) |
  | ticker step (one character) | max 8,298 T | max 8,298 T |
  | digit cell (with the scan) | max 11,349 T | max 11,349 T |
  | energy step / job slice | max 6,717 T / 6,252 T | max 6,717 T / 6,252 T |


## RoboCop's control at the game's rate (`msx/player.asm`; 25 Hz then, 30 Hz since decision 7 was revised)

- **Test**: ROM playing a joystick script (walking into walls, jumps and landings, crouching
  and turning, rising, down + fire, diagonal aims; `tools/mkrom.py JOY=...`), no demo enemies,
  headless openMSX through MSX-AI.
- **Logic against the original**: the game variables at each of 340 game ticks
  (`rc2_trace`) are identical to the Amiga code's on the execution bench (`tools/amigaemu.py
  game`, `tools/tracecmp.py`) on the MSX2 at 60 Hz, the MSX2 forced to 50 Hz (R#9 PAL: 2
  frames per tick, 679 frames for 340 ticks) and the MSX2+.
- **Frames**: 9 snapshots per machine rebuilt exactly (`tools/checkrun.py`: map at the
  recorded camera, RoboCop's sprites, HUD).
- **Cost** (MSX2, 60 Hz, 573 main-loop iterations): 0 late frames; the game tick ≈ 11,000 T
  (`player_move` 6,535 T on average, 7,225 T at most, of which ~2,200 T are the two
  multiplications of the view mapping; `read_joystick` with the script 2,115 T;
  RoboCop's composition and position 1,731 T); the whole frame at most 51,238 T (86%).
- **Scroll**: the game's camera pans 144 px left at the start of the level (about 17 px per
  tick); the V9938 engine follows one page flip at a time (44 frames waiting, all during the
  start-of-level sequence), the V9958 engine with no wait.
