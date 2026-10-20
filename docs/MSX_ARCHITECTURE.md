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
| Screen layout | SCREEN 5, 212 lines: play area 256×163 (display lines 0–162), 4 blank lines, HUD 256×45 (display lines 167–211, page 3, own palette) | the Amiga panel is 45 visible lines; every HUD element kept 1:1 (user decision: option A) |
| Interrupts | own IM 2 handler: VBLANK applies the register list of the next frame; line interrupt switches to the HUD | no BIOS overhead; split timing under control |
| Vertical scroll | R#23 (MSX2 and MSX2+) | hardware, zero cost |
| Horizontal scroll MSX2+ | R#26/R#27 + SP2 (512 px) + MSK | only one new column every 16 px |
| Horizontal scroll MSX2 | R#18 (±8 px) + shifted copy to the other page spread over several frames + page flip | one page costs ~6–8 frames; fits at ~1 px/frame |
| Tiles in VRAM | page 2 + page 3 lines 0–175 (432 slots; level 1 uses 431); tile cache from ROM if a level needs more | page 3 lines 176–252 hold the sprite tables and the HUD |
| Frame rate | logic at 30 Hz like the NTSC original (decision 7); video synchronised to VBL (50 or 60 Hz) | the game's timings and physics stay exact |

## Decisions taken (2026-10-19)

1. **Characters in hardware sprites** (mode 2), looking as close as possible to the
   software rendering. Technique: per line and per 16 px column, 2 OR-ed layers p and q
   give the colours p, q and p|q. The sprites use the same 16-colour palette as the
   background; the character's 7 colours sit at indices 1–7 (an OR-closed set), a
   duplicated palette slot is freed for sprite black, and the pair of each line is chosen
   by minimising the Lab distance to the software rendering (`tools/msxmock_or3.py`;
   accepted mockup: `build/mock/robocop_sw_vs_hw_opt_zoom.png`).
   The Amiga composes RoboCop from a base part + head + arm with gun (+ muzzle flash), see
   `docs/AMIGA_ANALYSIS.md`; the 276 compositions (69 frame records × 4 aims, 118 distinct)
   are cut into 16 px columns with the grid offset chosen per composition and 16-line spans
   placed freely in y (`tools/msxsprites.py`). With OR pairs everywhere RoboCop takes 12–21
   sprites (16.4 on average) and at most 8 per line (only 2 compositions; 51 reach 6, the
   rest 4–5), leaving 2–4 per line for enemies and shots. `tools/msxmock_budget.py` compares a per-line
   cap of 4 and 3 (`build/mock/robocop_budget.png`). **Decision: adaptive** — RoboCop at full
   OR quality whenever possible; on lines shared with enemies he temporarily drops extra OR
   layers (those columns switch to a single-layer version, so no holes appear); enemies
   flicker only when that is still not enough; RoboCop never flickers. Closest to the
   original, where RoboCop is in hardware sprites and enemies are blitter BOBs with no
   per-line limit (software enemies are not viable on MSX2: the scroll uses ~60% of the VDP).
   Implemented in `msx/sprites.asm` (see "Sprite engine" below).
   **Enemies (decided after `tools/msxmock_enemies.py`, `build/png/enemies_or_vs_one_layer.png`):
   adaptive as well** — the BOBs (16×16 to 48×48, drawn with the background palette) become
   sprites with OR pairs over the whole joint palette when the limits allow (10–16 sprites for
   a 48×40 enemy, 6 per line); otherwise they lose OR layers only on the conflicting lines
   (one layer: 5–8 sprites, 3 per line, striped silhouettes), and flicker only as the last
   resort. On the same lines a 48×40 OR enemy never fits beside a full-quality RoboCop, and
   two OR enemies never fit together, so in play both often run on their single layers.
   As implemented, a BOB that can push a line over 8 drops all its OR layers (exact per-line
   choices cost too much CPU), and RoboCop drops only the cheapest columns he must.
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
7. **Game logic at 30 Hz, faithful to the NTSC original** (2026-10-20): the original's
   routines are ported with their variables, tables and order, and run 30 times per second
   like on the Amiga it was made for (the Data East release, NTSC: `main_loop` waits for 2
   VBLs of 60 Hz; the first choice, 25 Hz, assumed a PAL machine and was changed by the
   user's decision), on both 60 Hz machines (every other frame) and 50 Hz machines (3 ticks
   per 5 frames); the display keeps the machine's own refresh rate (the BIOS setting,
   `RG9SAV`).

## VRAM layout

| Area | Content |
|---|---|
| pages 0–1 | play field: V9958 512×256 ring (SP2); V9938 two 256×256 pages |
| page 2, page 3 lines 0–175 | tiles (432 slots of 16×16) |
| page 3 lines 176–191 | sprite patterns `1D800h` (R#6 = 3Bh) |
| page 3 lines 192–199 | sprite set A: colour table `1E000h`, SAT `1E200h` (R#5 = C7h) |
| page 3 lines 200–207 | sprite set B: colour table `1E400h`, SAT `1E600h` (R#5 = CFh) |
| page 3 lines 208–252 | HUD (45 lines; shown with R#23 = 41 at display line 167) |

## Sprite engine (`msx/sprites.asm`): RoboCop and the enemies

- **Data** (`tools/msxsprites.py`, 184 KiB from bank `SPR_BASE_BANK`): 118 RoboCop
  compositions (frame record × aim) and the level's 60 BOB frames (enemies, shots,
  explosions, the vehicle). Per composition: a header (sprites, lines, columns, leftmost and
  rightmost dx, sprites of the single-layer version, most sprites on a line at full quality
  and on one layer), the sprites in SAT order (per column: A spans, then the B spans that OR
  into them), each with its offset, a park bit (B), an A1 bit (A) and the ids of its pattern,
  colour row and single-layer A1 versions; the rank list (columns in the order their OR
  layers are dropped, cheapest first, with their B spans) and the most sprites on a line after
  each prefix of it is dropped. Patterns (3,091) and colour rows (2,227) are shared pools.
- **Objects** (`obj_tab`, 8): object 0 is RoboCop, the others BOB groups (an enemy drawn from
  parts takes one object per part). The game calls `obj_rc` / `obj_bob` (composition; nothing
  happens when it is the same), `obj_pos`, `obj_hide`, and `sprites_moved` after its tick.
  Object order is SAT order: RoboCop in front, then the BOBs by object number.
- **Two sets** (colour table + SAT, R#5). A layout gives each shown object a run of SAT
  entries and one of its two **entry pages** (per entry: dy, dx, pattern slot, pattern and
  colour ids). An object shown the same way (composition, dropped columns, early clock) as in
  the layout on screen keeps its page and slots; otherwise its other page is filled. The 64
  pattern slots are shared by both sets: a slot that already holds a wanted pattern is used
  again (`pat_slot`, checked against `pat_held`).
- **Upload** into the set not on screen, a slice per frame: fill the pages (a record at a
  time), then the patterns and the colour rows that differ (`pat_held`, `lay_col`). Each
  frame it takes what is left of `UP_TOTAL` units (~100 T-states each) after the HUD
  (`hud_cost`), the game logic and the sprite engine (`spr_cost`) charged their work, and it
  stops once the beam is past the HUD split or when the frame is already late. A complete
  upload goes on screen on the next game frame (with the SAT built for it).
- **SAT**: built once per game tick with every object shown (`sat_build`); when objects
  alternate, each frame copies it and parks those off that frame (`sat_phase`). It is written
  into the set on screen right after the VBLANK that applies the frame's registers
  (`sprites_vblank`), so the sprites move exactly with R#18/R#23 (V9938) or R#26/R#27
  (V9958, where sprites do not follow the scroll).
- **Y = 216** ends the sprite table: when one of an object's sprites would land on it, the
  whole object moves by the smallest offset (−1, +1, −2, …), never a single part. Objects
  wholly above or below the play area have their entries parked (their 8-bit SAT y would
  wrap around into it); parked sprites sit on screen line 200 (HUD, sprites off there).
- **Early clock**: on when an object's leftmost sprite falls below x 32, off from x 64 (ahead
  of time, since a new layout takes frames); sprites still outside 0..255 are parked.
- **Budget** (on the frame after the game's tick, only when an object's composition, y or
  visibility changed — `bu_dirty`):
  1. When even the single-layer versions pass 32 sprites, the objects that do not fit then
     (in object order, RoboCop counted with his largest single-layer version) are left out
     of the tick.
  2. Lines can only pass 8 where objects meet: at each object's first line (where the sums
     grow) the per-line maxima of the objects there are added up. Where they can pass 8, the
     BOBs drop their OR layers (one layer), and RoboCop drops the fewest of his cheapest
     columns that let him fit beside them (the table of maxima per rank prefix). When even
     his single-layer version cannot fit, the BOBs that meet alternate between frames
     (multiplexing, the last resort); RoboCop is always shown.
  3. While the total is above 32, the cheapest OR layers anywhere go.
  Dropped columns stay dropped while the object keeps its composition (a new frame of
  animation brings its OR layers back), so the layout does not change every tick.
- **Frame structure**: the game ticks 25 times per second (see "Game logic"). Game frame:
  game logic (camera included), scroll engine, RoboCop's composition and position,
  `sprites_moved`, SAT, upload slice. The frame after it: scroll engine, budget, layout
  (`lay_check`/`lay_build`; it waits a tick after a frame the HUD took much of), SAT phase,
  upload slice; at 60 Hz some frames have no game work (scroll engine, SAT phase, upload).
  A complete upload goes on screen on a game frame. A few `feed_vdp` calls give the scroll
  engine its next VDP command while the CPU works on sprites, so the VDP does not wait for
  the end of the frame.
- **Known limits** (stress demo, 6 objects and 77 sprites): objects left out when even one
  layer passes 32 (no multiplexing of the total yet); when the upload cannot keep up, a new
  layout (dropped columns, early clock) reaches the screen late, so a line may briefly hold 9
  sprites (the VDP drops the last one) or an object entering the left border loses its left
  column for a few frames.

## Game logic (`msx/player.asm`)

- **Cadence** (decision 7): `cadence` adds 6 (50 Hz) or 5 (60 Hz) per frame and the game
  ticks when the sum reaches 10, so 30 ticks per second either way (60 Hz: every other
  frame; 50 Hz: intervals 2, 2, 1 frames). `game_tick` runs the ported routines in `main_loop`'s order and costs
  about 11,000 T-states with RoboCop moving (`COST_GAME` is charged to the sprite upload).
- **Ported so far**: the palette fade's counters and forced state (`$F878`, the palette
  itself comes with the palette effects), `player_move` (`$AFF8`: states, steps against the
  map walls, jumps, falls, landings, lifts `$BD72`, animation counter, camera, start of the
  level), the aim of `update_player` (`$ACEC`; the shots come next), the logic part of
  `draw_player` (`$B94A`: the state's last step, frame record, hotspot) and `read_joystick`
  (`$BDEC`). The variables keep the Amiga's meaning and values as little-endian words
  (`msx/msx.inc`, `CE00h`, the Amiga address beside each); the tables are generated from the
  game's code (`tools/player.py --inc` → `player.inc`).
- **Map attributes**: one byte per cell (`tools/msxconv.py` `.atr`, bank `ATR_BANK`, mapped at
  `A000h` when read); cells outside the map read as 0.
- **Controls**: joystick port 1 (trigger A fire, trigger B = the Amiga's F1/right Shift);
  without joystick input the keyboard as on the Amiga: cursor keys, SPACE/RETURN/TAB/ESC/BS/
  DEL fire, F1/SHIFT. Read once per game frame at the original's point (the logic sees them
  one frame later, as on the Amiga).
- **RoboCop on screen**: the composition (frame record × aim, or one of the 18 start-of-level
  arm poses added to the sprite data) with its top left at map (x + hotspot_x − 139,
  y + hotspot_y − 71), the original's sprite position against its play field.
- **View**: the MSX shows 256 × 163 of the game's 288 × 176 camera. The game's camera is kept
  exactly (enemies and spawns depend on it); the view runs ahead of it in proportion,
  view = camera + camera × extra / range (`VIEW_KX`, `VIEW_KY` from `tools/mkrom.py`), so it
  meets the camera at both ends of the map and never cuts the map's edges. The V9938 engine
  reaches a camera several columns away one page flip at a time (the camera waits at the
  page edge meanwhile); the V9958 engine one column at a time.
- **Verification**: test ROMs play a joystick script (`tools/mkrom.py ... JOY=F:C:KEYS,...`,
  the syntax of `tools/amigaemu.py game --joy`); `tools/openmsx_rc2.tcl` `rc2_trace` records
  the variables at each game tick and `tools/tracecmp.py` compares them with the bench's
  trace of the original. Identical over 340 game frames on MSX2 (60 Hz and forced 50 Hz) and
  MSX2+; rendered frames of the run (`tools/checkrun.py`) exact.

## HUD

The Amiga status panel (320×46, line 0 black) is rebuilt by `tools/msxhud.py` with every
piece of art at 1:1 (energy can, heads, weapon icon, seven-segment digits): only digit
spacing (16 → 13 px), letter spacing of the 21-character message line (8 → 7 px, letters
drawn with colour 0 transparent) and box lengths change, so the layout fills exactly 256 px.
The heads are copied with the frame pieces the game draws with them, so both are identical
to the original. Palette: 16 fixed MSX colours chosen for the digits' greens and reds, the
frames' greys, the can, four helmet blues and two skin tones. The green digit boxes'
background ($020, 9-bit 010 like the digits' unlit segments $030) is drawn black, so the
unlit segments stay visible and well below the lit ones (black / 010 / edges 020 / lit 030),
as the red digits do (100 / 200 / 500); one step up for the unlit segments instead made every
digit read as an 8 (user's choice). On the V9958 the split turns
the left-border mask off for the HUD. Positions of the run-time elements (digit cells,
message line, weapon icon, heads, can) are written to `build/msx/hud_layout.json`.

### HUD at run time (`msx/hud.asm`, data `tools/msxhudrt.py`)

The game's panel routines are redone on the HUD (`docs/AMIGA_ANALYSIS.md`), each drawing a
byte patch that `tools/msxhudrt.py` cut from the HUD of the panel after the Amiga operation
(`tools/hudmodel.py`): 40 distinct digit patches for the 14 cells, the can and its three
empty tops, 6 heads × 2 slots, 8 icons, the font packed for both byte phases and the game's
messages (15.6 KiB, banks `HUD_BANK`–`HUD_BANK+1`, mapped at 8000h–BFFFh while the HUD works).

- Shared bytes: the digit cells are 13 px wide, so every other boundary falls inside a byte.
  The left cell owns that byte: its last column changes with the digit, the right cell's
  first column never does (same in all ten glyphs, colour bank 0 everywhere).
- Message line: 7 px per character with colour 0 transparent; a character is drawn with
  its neighbours' pixels that share its bytes (4 bytes when it starts on a byte, 5 when it
  starts in the middle of one).
- Timing: `hud_frame` runs right after the VBLANK (after the SAT write), long before the
  beam reaches the HUD. Every frame: one ticker step (as the Amiga's per-VBL ticker), then
  one other piece of work: a slice of a job (head, icon, full can: 8 lines per frame), else
  an energy step (on the game's frames: it ran at 30 Hz), else one digit cell whose
  value changed. The HUD's work this frame is taken off the sprite upload (`hud_cost`, see
  "Sprite engine").
- Values use the game's layouts (BCD timer, ammo and score; energy 0..100h), so the ported
  game logic can write them directly; `hud_message`, `hud_request` (heads, icon) and
  `en_target` are its other entry points. A demo (`hud_demo`) drives them for now.
