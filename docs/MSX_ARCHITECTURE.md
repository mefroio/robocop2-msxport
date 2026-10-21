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
| Frame rate | logic at 25 Hz, the PAL design speed (decision 7); video synchronised to VBL (50 or 60 Hz) | the game's timings and physics stay exact |

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
7. **Game logic at 25 Hz** (final, 2026-10-20 evening): the original's routines are ported
   with their variables, tables and order, and run 25 times per second, the PAL design speed
   (the dumped Data East release is NTSC: `main_loop` waits for 2 VBLs of 60 Hz, 30 Hz; the
   user compared a 30 Hz and a 25 Hz ROM and kept 25 Hz, which leaves the display more CPU).
   `tools/mkrom.py TICK_HZ=30` still builds the NTSC rate. The display keeps the machine's
   own refresh rate (the BIOS setting, `RG9SAV`).

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

- **Data** (`tools/msxsprites.py`, 264 KiB from bank `SPR_BASE_BANK`): 130 RoboCop
  compositions (frame record × aim, start-of-level arm poses) and the level's 220 BOB frames
  (enemies, lifts, the vehicle, shots, explosions). Each composition is cut into **bands of
  16 lines**, each band into the fewest 16×16 boxes that cover its pixels (a box at the
  leftmost pixel not yet covered: a stride's two feet take two boxes where a fixed 16 px grid
  needed three); per box and line one colour (layer A) or an OR pair (A + B, CC = 1). RoboCop's
  bands use at most 5 sprites on a line (`RC_CAP`: the boxes whose pairs gain least keep one
  layer, in the 24 poses with three boxes in a band), 14.4 sprites on average (11-18); BOB
  bands end on their lowest pixel line, so a band keeps its place from frame to frame, and use
  at most 3 sprites on a line (`BOB_CAP`: a character always fits beside RoboCop, so its look
  never has to change; the user's choice), the boxes that keep their OR layer being the same in
  every frame of an animation (summed gain; `robocop.json` "prefer"): 5.2 sprites on average. Per
  composition: a header (sprites, lines, bands, leftmost and rightmost dx, A sprites, most
  sprites on a line at full quality and on one layer), the sprites in SAT order (per band, per
  box: A, then B), each with its offset, a park bit (B), an A1 bit (A: one colour per line,
  every pixel, shown when its band's OR layer is dropped) and the ids of its pattern, colour row
  and A1 versions; then the **band table** (from the lowest band up: dy, A and B sprites,
  what dropping its OR layer costs). Patterns (4,408) and colour rows (3,893) are shared pools.
- **Left = right mirrored** (2026-10-21, the user's rule: the two sides of a character must be the
  same drawing). A left RoboCop composition takes its right counterpart's converted layout
  mirrored (`mirror_pairs`, `mirror_layout`: the same boxes, colours and OR pairs, so both
  sides use the same sprites per line), placed where the original's left drawing lies (exactly
  where it is the mirror, else feet on the same line and the most pixels in common; the
  original's own axes per animation, see `docs/AMIGA_ANALYSIS.md`); a left drawing the
  original shares between records with different right counterparts gets one composition per
  counterpart. The right punch's last step, which shows the left punch's first drawing in the
  original (a data slip), repeats the step before at its own hot spot (`slips`, `repeat_steps`,
  `move_layout`; the logic still counts 8 steps). A BOB frame that is the exact mirror of an
  earlier one takes that frame's layout mirrored (`bob_mirrors`; `robocop.json` "mirror"),
  48 of the level's 220. `tools/msxframe.py` rebuilds the same layouts for the checks. The VDP
  cannot flip sprites, so VRAM and the per-line counts are unchanged; the shared colour rows
  saved 16 KiB of ROM (sprite data 216 → 200 KiB). Storing one side and flipping the
  patterns on upload (a 256-byte table) would save about 30 KiB more for RoboCop, at about
  twice the CPU per pattern uploaded.
- **Frames removed** (`msx/level1_frames.json`, `--remove`; the user's choice in the frame
  chooser, 2026-10-21): a removed RoboCop step shows the step chosen instead (the one before
  that stays) on both sides and every aim, moved to the removed record's hot spot
  (`repeat_steps`); a removed BOB frame's index entry shows the frame chosen instead, moved
  where that frame is drawn when the game draws them at different heights (the hostage's
  frames 5–7 sit 4 px higher: table `$EE02`); a frame the level never draws is left out (the
  lift's two level-3 parts). Compositions no entry shows are not stored. The logic is
  unchanged (the steps and frames still count; only the drawing repeats).
- **Objects** (`obj_tab`, 8): object 0 is RoboCop, the others BOB groups (an enemy drawn from
  parts takes one object per part). The game calls `obj_rc` / `obj_bob` (composition; nothing
  happens when it is the same), `obj_pos`, `obj_hide`, and `sprites_moved` after its tick.
  Object order is SAT order: RoboCop in front, then the BOBs by object number.
- **Versions**: each object shows one version (`disp`) and prepares the one it wants (`pend`):
  composition, dropped columns, early clock and silhouette; its entries (dy, dx, pattern
  number, slot, pattern id, colour id) on one of the object's two **entry pages** (page-0 RAM).
  A version prepared takes a pattern slot per entry (`slot_for`: a slot that still holds the
  pattern costs nothing, `pat_slot` hints checked against `pat_held`; a new one gets a new
  slot generation); once its patterns are all loaded it **commits**: it takes a run of SAT
  entries (RoboCop's from entry 2, the spark's 0-1, a BOB's the smallest hole above
  RoboCop's zone, or its own run when the size is the same) and replaces the version shown in
  the next published frame. An object never shows half of a change nor another object's
  frame. When no hole fits but the free entries would, the BOB runs are packed against
  entry 31 (`sat_pack`, once a plan): fragmented holes once kept the vehicle invisible for
  seconds.
- **Two sprite sets, double-buffered** (colour table + SAT; R#5 = C7h / CFh). Every published
  register list that changes the sprites switches R#5 to the other set, which the frame's
  queue made complete beforehand: its colour rows (`rows_sync`: per entry the row its version
  wants against `col_held` / `col_held_b`), its SAT (`q_sat`) and the new patterns (slots no
  shown entry uses). The set on screen is never written, so no change can tear.
- **Upload queues**: the frame's queue (`pq_buf`: [bytes \| 80h for the early clock, VRAM
  address, source bank and address]) runs from the split interrupt until the vertical blank
  begins (S#2 VR: written later, the VBLANK interrupt's registers and palette came in the
  next picture's first lines) and resumes where it stopped; the VBLANK interrupt applies the
  list only once its queue is done, then adds `BQ_LATE` units of the background queue
  (`bq_buf`: patterns of versions still being prepared, with the slot's generation checked
  before the copy). Costs in units of 16 T-states (`QC_PAT`, `QC_COL`, `QC_COLEC`).
- **SAT**: built once per published frame (`sat_build`) for the set it goes to; objects that
  alternate get a second half (+80h) in which the other phase is parked, and the interrupt
  writes only their y's on the frames between two lists (`sat_mux_out`).
- **Y = 216** ends the sprite table: when one of an object's sprites would land on it, the
  whole object moves by the smallest offset (−1, +1, −2, …), never a single part. Objects
  wholly above or below the play area have their entries parked (their 8-bit SAT y would
  wrap around into it); parked sprites sit on screen line 200 (HUD, sprites off there).
- **Early clock**: on when an object's leftmost sprite falls below x 32, off from x 64 (ahead
  of time, since a new version takes frames); sprites still outside 0..255 are parked.
- **Budget** (after the game's tick, when an object's composition, place or visibility
  changed — `bu_dirty`). **RoboCop is never touched** (the user's rule: his sprites never
  change) and no object ever alternates between frames.
  1. When even the single-layer versions pass 30 sprites (32 less the spark's two; the BOBs'
     runs are packed when no hole fits), the BOBs that do not fit in their order of importance (lifts and the vehicle,
     enemies, enemy bullets, pickups, effects, explosions) are left out of the tick. RoboCop
     counts whole with the largest version of his last 2 s (`rc_hold`).
  2. Every line's sprites are counted (`ln_cnt`, one byte per play-area line): RoboCop with,
     per line, the most of the versions he wants, shows and prepares (his new frame goes on
     screen a picture or two after the budget planned for it), the BOBs band by band. A line
     above 8 makes the effects give way (`ft_give`), in this order: an OR layer of the
     explosions or the spark, one of them left out, an OR layer of the shots, enemy bullets,
     pickups and the characters' small parts (16 px: the vehicle's jets), one of them left out.
     An OR layer is a band's (its B sprites go, its A sprites show A1), the cheapest of its tier
     covering the line. RoboCop and the characters (enemies, lifts, the vehicle) keep their
     look; a line that still passes 8 (two characters and RoboCop on the same lines) is left to
     the VDP, which hides its last sprites: never RoboCop's, whose run comes first in the SAT.
  3. While the total is above 30, the effects give way in the same order, anywhere; only then,
     as the last resort (RoboCop, an enemy, a lift and the vehicle together), a character drops
     an OR layer and keeps it dropped until it is hidden or changes owner (`O_HOLD`): its look
     changes at most once.
- **BOBs to objects** (`bob.asm` `bob_flush`): a BOB keeps the object its identity (category,
  owner, part) had in the tick shown before; its frame comes from a 512-slot hash of (A2, D4)
  (`BOBHASH`). Objects without a record are hidden and forget their identity.
- **Frame structure** (main loop): wait for the last list's VBLANK; keys, seconds, HUD; after
  ticks: scroll update, `cam_mark`, RoboCop's composition, BOBs to objects, budget; without a
  tick: scroll update, `cam_follow`; then the plan (`spr_plan`: versions, queues, commits),
  colour rows, SAT; publish; then the ticks due. `feed_vdp` gives the scroll engine its next
  VDP command at many points (the tick's stages, each object the plan works on, the budget, the
  BOB lists): its pages are built only from these points.
- **Objects against the camera**: screen place = world place − the camera of the tick frame
  (`pl_show`, `bob_flush`; `cam_mark` keeps it in `sp_cam_x`/`sp_cam_y`). Both scroll engines
  also move the camera on frames without a tick (catching up with `v_x`/`v_y`); such a frame
  shifts every shown object by the camera's step (`cam_follow`: `obj_pos_ix`, then
  `sprites_moved` and `sprites_tick`). Before 2026-10-21 those pictures showed every sprite off
  the background by that step, and on the V9938 the SAT kept the previous R#18 correction
  (`spr_xadj` follows `cam_x` every frame, the SAT is rebuilt only when `sat_dirty`).
- **Checks** (`tools/openmsx_rc2.tcl`, all 0 on the level-1 coverage drive): `rc2_sprlines`
  (no displayed line with more than 8 sprites), `rc2_satcheck` (the SAT on screen is the one
  built for it), `rc2_patcheck` (every shown entry's pattern and colour row in VRAM),
  `rc2_sprvram` (no write into the set on screen during the play area), `rc2_lateirq`; exact
  display comparisons of refactors with `LOCKSTEP` builds and `tools/dispcmp.py`; what the MSX
  shows against the bench's BOBs with `tools/objcmp.py` (exact, late, missing: loading or left
  out). For the product ROM on a fresh machine (title, keyboard plans `rc2_keys`): `rc2_guard`
  (every VDP register, palette, command and VRAM write timed by scan line from the HUD split:
  whatever could spoil the picture; a command counts when it starts while the beam draws the
  play area, or in the 4 lines before it, into what the screen shows — R#2's page, the lines
  R#23 shows; with the V9958's SP2 both ring pages and only the 248 columns R#26/R#27 show
  (`rc2_rg_hits`) — or when it still runs into it as the picture starts (`rc2_rg_run`); `tear`
  counts the commands the beam really crossed (`rc2_rg_cend`, at the command's end from the
  `VDP.commandExecuting` probe: a play-area line it wrote was drawn while it ran; this probe
  slows a run about threefold); the
  VBLANK check is taken at `isr.asm` `iv_late`, the list's registers and SAT in, not at
  `iv_tick`, which comes after `spr_late`'s uploads), `rc2_camcheck` (at every `list_tail`,
  RoboCop's `O_X`/`O_Y` must be `p_x + p_hotx + SPR_X_OFS + 8 − cam_x` /
  `p_y + p_hoty + SPR_Y_OFS − cam_y` with the camera that list publishes), `rc2_overlines`
  (every frame with a line above 8, wanted against shown versions), `rc2_viewlag`, and
  `rc2_jumprec` + `tools/recframes.py`: the pictures after each jump recorded as the VDP drew
  the play area (with SP2 the ring's pair of pages: 64 KiB records; openMSX 21 renders only
  through OpenGL, which needs a window, so headless runs record the VDP state instead),
  rendered with `tools/msxscreen.py`'s model of openMSX's renderer, their background checked
  against the map with its patches (no right border on the V9958; a pixel matching the
  previous record's patches passes, since a record's RAM can be one tick ahead of the picture)
  and RoboCop's sprites against the 8-per-line and CC rules. Compatibility runs use only the
  15 machines available: openMSX's 8 C-BIOS MSX2/MSX2+ machines and the 7 configs whose
  firmware was already in the user's folders (Gradiente Expert 2.0 ×3, Panasonic FS-A1FX and
  FS-A1GT, Sony HB-F1XDJ 128K and 64K); no synthetic machine configs.
- **Known limits**: about 7.5 pictures a second in busy scenes at 25 Hz (the CPU: logic
  ~74,000 T-states a tick, the sprite pipeline ~165,000 a picture, interrupts 16 %); scenes
  that pass 30 sprites even on one layer (explosion debris) leave their least important BOBs
  out; a BOB that must drop a band shows its old version for a picture or two while the new
  one loads (a line may then pass 8: about 0.5 % of the frames of a keyboard session); no
  multiplexing of the 32-sprite total.

## Game logic (`msx/player.asm` and the logic modules)

- **Cadence** (decision 7): `cadence` adds 6 (50 Hz) or 5 (60 Hz) per VBLANK since the last
  main-loop frame (`wf_n`) and the game ticks every `CAD_TICK` = 300 / `TICK_HZ` (12 at
  25 Hz). A frame whose work took longer (busy scenes: the logic costs about 74,000 T-states a
  tick, a 60 Hz frame has 59,659) is caught up: the ticks due run in a row (`g_tick`, at most
  `CAD_MAX` = 4 for one picture, `CAD_HOLD` = 2 while the V9938 scroll keeps the camera at a
  page's edge, none while the view shown is 32 px or more behind the one wanted, or behind at
  all with RoboCop's sprites within 16 px of the screen's edge (`cam_lag`, `rc_safe`: the scroll
  catches up first, so he never runs off the screen); a longer delay is lost and only then the
  game slows down, as the original does when its frame takes 3 VBLs) and the display skips
  their pictures (`bob_skip`: their BOBs are not even recorded). The timer's seconds count
  VBLANKs, not frames.
- **Ported**: `main_loop` in its order: palette effects (`$F878`), `frame_keys` (`$F76C`),
  `player_move` (`$AFF8`), the collisions and pickups (`$FA7C`), the level's hazards (`$9150`:
  level 1's electric beams), `activate_objects` (`$9C06`), the special objects (`$8B32`: lifts,
  the vehicle), `update_player` (`$ACEC`), `draw_player`'s logic (`$B94A`, with the hit spark),
  enemy bullets (`$F3CE`), `read_joystick` (`$BDEC`), `update_objects` (`$C3E4`) with every
  level-1 enemy type, explosions (`$F080`), pickups (`$F900`), the energy can (`$89BE`), the
  random word (`$BDCE`) and the frame's end (`$8144-$82E8`, `frame.asm`: cheats, time out, the
  level's end, the death sequence, lives; `FE_RESTART` runs `level_restart`, `FE_OVER` and
  `FE_NEXT` start a new game until the front end and the next levels exist).
- **Where**: fixed code (`4000h-7FFFh`): `player.asm`, `logic.asm` (helpers), `bob.asm`; module
  1 (`BANK_LC1` at `8000h` during the tick: `objects.asm`, `shots.asm`, `hits.asm`), module 2
  (`BANK_LC2`, mapped around `activate_objects`: `mapobj.asm`), module 3 (`BANK_LC3`, mapped
  around `$8B32`, `$9150` and the frame's end: `special.asm`, `frame.asm`), the level's bank
  (`BANK_L1` at `A000h`: `level1.asm`, starting with the type handler table, `lv_init`,
  `lv_tick`, `lv_hz`). The variables keep the Amiga's meaning and values: the mirror
  `AM`/`AG` (every Amiga word little-endian at its own address, a byte at A ^ 1), the code
  area's patched values in `AC_VARS`, the level's lists in RAM (`spawn_ram`, `objl_ram`,
  `SP_RAM`); the original's tables are copied at build time (`tools/amitab.py`,
  `analysis/amiga_tables.tsv`). `pl_init` clears what `clear_game_vars` clears (`$B00-$16EB`,
  the keyboard and joystick bytes, the input lock, the joystick mask) and the port's own
  per-life variables (`G_VARS`); what lives across lives (`lvl_bank`, `tick_n`) is kept apart.
- **Map attributes**: 4-bit codes per cell packed in page-0 RAM (`atr_load`) with a list of
  patched cells per row (`MP_ROW`...); `atr_rc` reads them without bank switching.
- **Palette on screen**: `pf_pal` (RAM) is the play field's palette the VBLANK loads (the HUD
  keeps its own, loaded at the split). It changes as the original's copper colours do: the
  fade (`pal_fade`: every 3-bit component at most the fade level / 4, the original's eight
  steps) computes all of it; a flash (`pal_flash`) and its end write RoboCop's entries
  (`pal_robo`). The Amiga tints only his sprite colours (COLOR17-31, six palettes); here his
  joint-palette entries that the background never uses take the tint (`tools/msxsprites.py`
  `robocop_flash.inc`: entries 2, 3, 5, 7 in level 1), so the background never changes.
- **Controls**: joystick port 1 (trigger A fire, trigger B = the Amiga's F1/right Shift);
  without joystick input the keyboard as on the Amiga: cursor keys, SPACE/RETURN/TAB/ESC/BS/
  DEL fire, F1/SHIFT. Read once per game frame at the original's point (the logic sees them
  one frame later, as on the Amiga).
- **RoboCop on screen**: the composition (frame record × aim, or one of the 18 start-of-level
  arm poses added to the sprite data) with its top left at map (x + hotspot_x − 139,
  y + hotspot_y − 71), the original's sprite position against its play field. The hit spark
  (`$16A0`, four 16 × 16 frames in his colours) is sprite object `SPARK_OBJ`, placed first in
  the SAT so that it shows in front of him as on the Amiga.
- **View**: the MSX shows 256 × 163 of the game's 288 × 176 camera. The game's camera is kept
  exactly (enemies and spawns depend on it); the view runs ahead of it in proportion,
  view = camera + camera × extra / range (per 16 pixels of camera from tables that
  `tools/mkrom.py` writes), so it meets the camera at both ends of the map and never cuts the
  map's edges. The game's camera follows RoboCop with a lag (1/16 of the way a tick in x, 1/8
  in y) that its wider view hides: running, he got near the right edge of the MSX's view and
  past it. So the view also keeps his place on screen within x 48..160 and his feet within
  y 76..150 (`pv_keep`), still within the map. Both engines start every frame's update from
  the view wanted (`v_x`, `v_y`; `cam_x`, `cam_y` are what they show, held at a page's, cell's
  or row's edge), also on frames without a tick (`s38_update`, `scroll_update`). The V9958
  engine used to start from `cam_x`/`cam_y`, which only `pl_view` sets on ticks: with the
  cadence holding the ticks while the view lags (`cam_lag`, `rc_safe`) its camera could never
  move again and the game froze (fixed 2026-10-21; not seen in the drives, where the V9958
  never held its camera, but reachable).
  The V9938 engine reaches a camera several columns away one page flip at a time;
  the V9958 engine one column at a time. The V9938 engine's VDP commands are fed between the
  tick's stages too (`feed_vdp`, which puts back the banks of both windows): with the CPU busy
  it would starve otherwise. Its page build (the new column's tiles, then the old page copied
  16 px over: ~27 KB of HMMM, about 10 frames of VDP time) starts as soon as the list with the
  last flip is on screen (`s38_flip_seq`), not at the next frame's update; walking right it
  keeps up (5 % of the pictures hold the camera at a page's edge, at most 23 px behind the
  view wanted), a camera that jumps far (teleports, the start of a level) takes one flip per
  build to catch up.
- **MSX2+ play field (fixed 2026-10-21)**: since the tile cache, `tile_src` leaves the source
  page (2 or 3) in A; the V9958 engine's `draw_tile` took A for the row, so every tile went to
  ring line 32 or 48 and on every MSX2+ the play field stayed almost empty (VRAM's 44h fill).
  `dt_prep` now keeps the row in C. Found by recording the 64 KiB ring and rendering it; the
  compatibility runs before had only checked that the game ran.
- **Changed cells** (map patches queued by `tiles.asm` `rd_queue`, 64 requests): redrawn on the
  page shown (the V9938's first phase; the V9958's ring is always shown); a cell the beam
  crosses during its copy shows half old, half new for one picture (a 16x16 HMMM takes about
  13 lines while the play area is displayed). Between the HUD split and the VBLANK interrupt
  (`split_armed` = 0) the changed cells come first, up to `RD_BURST` (6) in a row, each
  started through `vdp_cmd_q` (R#32-R#45 first, then the window test and the R#46 write with
  interrupts off) after the one before (`sw_redraw`, `s38_rburst`); at other times the oldest
  is drawn at once, as before: a change never waits. Tried and dropped: starting them only in
  that window. Near level 1's animated mechanism (x ≈ 1016, about 100 `rd_queue` calls a
  second) the window served about 20 a second and the queue overflowed (`rd_lost` 76 / 155 over
  260 s); with a fallback only past 8 waiting, a changed cell still waited up to about a second
  for a window (the main loop seldom runs there). On the V9938 a flip between a cell's two
  phases restarts it on the new displayed page (`s38_update` clears `rd_phase`): before, the
  second phase found no back page and the new displayed page could keep the tile its shifted
  copy brought before the change (seen: 4-17 pictures with an old tile after a flip).
- **Verification**: test ROMs play a joystick script (`tools/mkrom.py ... JOY=F:C:KEYS,...`,
  `TELE=`, `GOD=1`), or are driven from openMSX (`EXTJOY=1`: `tools/openmsx_rc2.tcl`
  `rc2_drive_rom` / `rc2_drive_trace` feed each tick the joystick byte, teleports, god mode
  and pokes of the game's variables of a `tools/drivejoy.py` file, the same file the bench
  plays with `--drive`). Each tick's whole game state is recorded (streamed) and
  `tools/tracecmp.py --ram` compares it field by field (`analysis/amiga_ram.tsv`) with the
  bench's trace of the original. Identical so far: movement, fire, the level-1 coverage
  scenarios (20,540 and 4,400 frames), a death and the restart, game over after three deaths,
  and the level's end (type 32's sequence, the score count, the fade, `$8050` + 1).
- **Main loop order**: wait for the VBLANK, SAT, keys, seconds, HUD; the picture of the ticks
  run at the end of the last frame (scroll engine, RoboCop, BOBs to objects, budget and layout
  when late) or, without one, the scroll engine and `cam_follow`; the sprite engine's frame;
  upload slice; publish the registers; then the ticks
  due run at once, while the published list waits for its VBLANK (the CPU never idles waiting
  for it when the game is behind).
- **Hit flashes** (`draw_bob`'s flash `$AC6E`, black `$AC84`): an object drawn as a silhouette
  shows its single-layer patterns (they hold every pixel) with one colour row
  (`SPR_SIL_FLASH`: the joint palette's nearest to the background's colour 15;
  `SPR_SIL_BLACK`: its black), chosen per object (`os_mode`, bits 0-1 of `O_EC`). A hit flash
  drawn in a tick the display skips is held for the tick shown (`fl_pend`), or it would never
  reach the screen.
- **Speed (2026-10-20, 25 Hz)**: about 23 ticks per second and 7.2-7.5 pictures in the busiest
  scene of level 1 (the start, five enemies), 8.2 pictures walking (the CPU is the limit: the
  logic about 74,000 T-states a tick, the sprite pipeline about 165,000 per picture, the
  interrupts 16 % of the time). `CAD_MAX=2` trades speed in busy scenes (about 74 %) for
  9.3 pictures. Lighter scenes run at full speed. Measured with `tools/openmsx_rc2.tcl`
  (`rc2_prof` for the main loop's stages, `rc2_sample_span` for a sampling profile of one
  stretch, `tools/msxprof.py` to name the samples). Done so far: the catch-up cadence, ticks
  run while the published list waits, BOBs not recorded for skipped pictures, category lists
  and a 512-slot hash for the BOBs, the budget's line phase on difference arrays, `bob_draw`'s
  quick test, the attribute reads, the view's tables, the spawn list walk, the lifts' path
  stepping, the hazards' window.

## Front end (`msx/front.asm`, bank `BANK_FRONT` at `8000h`)

- The title (TPIC) and the game over (PIC9) are SCREEN 8 pictures (`tools/msxpic.py`: 256 ×
  lines, the fixed 3-3-2 colours, Floyd-Steinberg), stored uncompressed from their own banks
  (`PIC_TITLE_BANK`, `PIC_GAMEOVER_BANK`, 32 lines per bank). `pic_show` switches the VDP to G7
  (no line interrupt, sprites off, page 0, no scroll; V9958: R#25-R#27 cleared), clears the
  screen (HMMV) and copies the picture centred on the 212 lines; the play field's pages are
  overwritten, so the game redraws them when it starts again (`new_game` / `display_on` set
  SCREEN 5 back). While a picture shows, `front_mode` makes the VBLANK interrupt count frames
  and run the sound only.
- Flow: power-on → title (fire) → level 1; game over → PIC9 for 128 frames → title; the level's
  end → title (the statistics, the bonus stages and level 2 come later). Test builds with a
  script skip the front end.
- The ROM is 1 MiB since the pictures were added (the complete game with levels 2 and 3 will
  need 2 MiB: MegaROM or MegaRAM of that size).

## Sound (`msx/sound.asm`)

- At power-on, with the BIOS still in page 0, every slot's page 1 is searched for an OPLL BIOS
  ("APRLOPLL": MSX-MUSIC built in; "PAC2OPLL": an FM-PAC, whose I/O ports are switched on with
  bit 0 of `7FF6h` in its slot). The PSG is always used; the OPLL (ports `7Ch`/`7Dh`) when
  found (`snd_fm`).
- `snd_frame` runs from the VBLANK interrupt (the music keeps its tempo while the game catches
  up); the PSG's address latch is shared with the joystick reads, so outside the interrupt
  every PSG access runs with interrupts disabled and R7 keeps port A as input.
- The original's music and sound effects are tunes of the same player (MU1 at `$18000`); their
  conversion and the MSX player are in progress.

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

The split interrupt (`isr.asm` `isr_split`) ends by writing R#19 = `SPLIT_R19`
(`(HUD_R23 + SPLIT_LINE) & 255`, a match already behind) and reading S#1. Fixed 2026-10-21:
before, the play field's R#19 against the HUD's R#23 (41) matched again at line
`(cam_y + 118) & 255`; with `cam_y & 255` around 45-94 (level 1's first lift floor, y 720)
that second match came while the split interrupt was still uploading sprite patterns
(interrupts off; long after a pose change, so at every jump), stayed pending past the VBLANK,
which had re-armed the split, and ran the split in the blank: the next picture showed VRAM
page 3 from line 41 (the tile cache) in the HUD palette over the whole play area (the user's
"garbage when jumping"; 2-3 pictures a second there, gone after a death since the start floor
has `cam_y` 653). Found by attaching to the user's openMSX: the split routine ran 10 or 35-47
lines after the VBLANK instead of 210. The guard's split check had looked at the interrupt's
assertion, when `split_armed` was still 0; it now also times `isr_split` itself
(`rc2_rg_isr`).

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
  an energy step (on the game's frames), else one digit cell whose value changed.
- Values use the game's layouts (BCD timer, ammo and score; energy 0..100h), so the ported
  game logic can write them directly; `hud_message`, `hud_request` (heads, icon) and
  `en_target` are its other entry points. A demo (`hud_demo`) drives them for now.
