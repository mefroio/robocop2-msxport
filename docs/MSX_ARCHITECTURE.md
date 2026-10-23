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
| Tiles in VRAM | page 2 (256 slots; level 1 uses 431 tiles); tile cache from ROM (clock replacement) | page 3 lines 0–175 hold the play-field BOBs' frames, caches and scratch; 176–252 the sprite tables and the HUD |
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
   a slot — the MegaRAM has no SCC. (2026-10-22, the user's request, "muito melhor e mais
   próximo possível do Amiga": the title music on an SCC or SCC+ and on an OPLL when found;
   the in-game effects stay on the PSG. See Sound.)
4. **SCREEN 5 everywhere** (game, HUD, logos, text screens). SCREEN 8 rejected: fixed 3-3-2
   palette worse for 16-colour art, sprites with a fixed 16-colour palette (rules out the
   approved RoboCop), double VDP cost and 64 KiB pages without room for tiles.
5. **Only two digitised photos, in SCREEN 8 and in their original places**: TPIC = title
   screen and PIC9 = game over (confirmed in code: `$11E06` builds `PIC('1'+D0)`; D0 = 8
   comes from `main_loop` when the lives run out). 320→256 px width conversion (same width
   on the TV), fixed 3-3-2 palette with Floyd–Steinberg (`tools/msxpic.py`). The other
   photos are dropped and the between-level scenes become text/briefing screens; MegaROM
   estimated at ~300–450 KiB compressed (fits in 512 KiB; the ROM grew to 1 MiB later for the speech).
6. **MegaROM** kept; bank switching goes through a single routine, so a floppy + memory
   mapper version stays possible in the future.
7. **Game logic at 25 Hz** (final, 2026-10-20 evening): the original's routines are ported
   with their variables, tables and order, and run 25 times per second, the PAL design speed
   (the dumped Data East release is NTSC: `main_loop` waits for 2 VBLs of 60 Hz, 30 Hz; the
   user compared a 30 Hz and a 25 Hz ROM and kept 25 Hz, which leaves the display more CPU).
   `tools/mkrom.py TICK_HZ=30` still builds the NTSC rate. The display keeps the machine's
   own refresh rate (the BIOS setting, `RG9SAV`).
8. **Colour grade** (2026-10-22): the game play a little brighter and with more contrast than
   the Amiga's colours converted level for level, palettes only (no tile, sprite or HUD pixel
   changes). Every 3-bit component goes through `BRIGHT` = 0 1 3 4 5 6 7 7
   (`tools/msxbright.py`): the play field's palette, RoboCop's flashes, the HUD's, the fade's
   limits and the level statistics' text (shown over the HUD); the user chose the brightest of
   three previews of the play field and HUD. The SCREEN 8 pictures (title, game over) keep the
   plain colours: graded they looked blown out (the user's choice). The conversions' `.pal`
   files and previews stay in the plain colours, which their colour matching and the checks use;
   `tools/mkrom.py` grades them into `build/msx/gen` (`level1_grade.pal`, `hud_grade.pal`: names
   of their own, z80asm looks in its working directory first) and writes `grade.inc`.
   Checked in openMSX: the VDP's play-field and HUD palettes equal the graded ones, a frame
   of the coverage drive equals the approved preview pixel for pixel, and every step of a fade
   (32 calls, the 8 steps) equals the graded palette limited by `fade_cap`.

## VRAM layout

| Area | Content |
|---|---|
| pages 0–1 | play field: V9958 512×256 ring (SP2); V9938 two 256×256 pages |
| page 2 | tile cache (256 slots of 16×16) |
| page 3 lines 0–87 | play-field BOB frames (atlas, `robocop_field.bin`) |
| page 3 lines 88–111 | the atlas's dynamic slot: the explosion's or the smoke's step being shown (`robocop_fdyn.bin`, strips of 24 lines) |
| page 3 lines 112–175 | play-field BOB background caches (x 0–191, three 64×64) and scratch (x 192–255) |
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
- **Start of a level** (2026-10-21, `start_layouts`): the 18 arm poses (12 compositions: the gun
  drawn, `START_GROUPS` 8-15, then spun, 16-25, then composition 18, a frame of the game) were
  converted one by one, so a gun pixel in a box line changed his chest's colours on that line
  from one pose to the next: the user saw a stroke across his chest, arm and back between poses
  20 and 21 (46 pixels; 601 over every step the display can show). Now each group is converted
  together (`Converter.coherent`): the same boxes for all, each pose its own OR boxes within
  `RC_CAP`, and per box line the colours chosen by an exact min-sum over the steps the display
  can show (the next pose, or one skipped when the game is busy: `SKIP`), so that a pixel the
  original keeps, among pixels it keeps around it (`CALM_R`, `CALM_MOVE`), never changes colour;
  the spin is pinned to composition 18, the drawing to the spin's first pose. The gun's greys
  (Amiga colours 9-12, cyan stripes in the OR colours) are detail sprites in front, placed for
  a group at once (`Converter.details`), never on a pixel linked to a neighbour's. Checked on the
  recorded start (MSX2 50/60 Hz, MSX2+): every picture shows exactly the converted look, no
  stroke pixel in any step; 11 pixels far from the original over the 12 poses (12 one by one),
  80 % of the gun's grey pixels grey.
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
  entry 31 (`sat_pack`, once a plan, once more for each part a group shows): fragmented holes
  once kept the vehicle invisible for seconds. Runs in RoboCop's zone move above it in the
  pack too, and when his new version takes entries a BOB's run holds, that run moves above his
  zone (`pr_clear`); dropped instead, an enemy's legs vanished for up to 10 pictures whenever
  his next frame took more sprites. His zone is worked out again once his new version is shown
  (`rc_zone`): the entries only the old one took serve the BOBs in that plan already.
- **Parts of one character** (the BOB objects of one owner and category, `obj_key`: an enemy's
  legs, torso and arm) always show versions prepared in one plan, so of one tick, and change
  together: shown one by one, a walking enemy's torso stood on legs of another tick for 7–17
  pictures, or one part was missing (the user, 2026-10-22). A part prepares no version while
  another prepares one of an earlier plan (`pgc_old`); one that shows nothing yet does not wait:
  the others' versions of earlier plans go and are prepared again with its own (`pgc_new`); a
  part back on the frame it shows keeps the version it prepares while another prepares one
  (the plan's first look); one that finds no slots makes the others drop those of the plan
  (`pgc_drop`). Complete versions wait for the other parts' (`pw_ready`, state 1) and the plan
  ends showing them together (`pl_groups`), in three passes: those that take fewer entries
  first (within their own run: they free entries), then those that take more or show nothing
  yet (when no run fits, their parts wait with them), then those that keep their run; a part
  whose smaller new version waited for another that had no room, while its larger old one held
  the entries, had kept the other out for good. Only enemies, lifts, the vehicle and explosions
  have parts: the other objects skip the search, and the search itself walks only the objects
  whose category can have parts (`pg_list`, built at the plan's start when an identity changed,
  `pg_new`: 1-4 objects with `ENEMY_CAP` 1 where it compared all 14; 2026-10-23). Measured on the coverage drive (2,500 ticks,
  what the list on screen shows: `pub_spr`), pictures of a character from two ticks went from
  11.4 % to 0.8 % (MSX2) and from 8.2 % to 0 (MSX2+); parts missing 1.0–1.3 %, single plans
  while a new part loads in busy scenes; the game 2 % slower there.
- **RoboCop's next step ahead** (`rc_prefetch`, after the plan's work, while the background
  queue holds fewer than 4 loads): the patterns of his state's next record (the one before when
  the animation runs backwards; same aim) go into free slots (`slot_warm`: `slot_ref` 0, as
  `alloc_slot` gives them, so no version loses any) through the background queue, and the
  step's version is complete as soon as the logic asks for it. A walk step has 11–18 patterns
  of its own (the original redraws the body and arms every step; a cycle uses 106 against the
  64 slots); loaded only after the change, a step showed 7–12 VBLANKs late and the steps in
  between (2 ticks each) were skipped: only 21–27 % of the shown step changes were one step,
  and the walk looked to go backwards (the user, 2026-10-21). With it 67–79 %; with
  `CAD_MAX` 2 as well, 93–94 % (the rest: pictures that still carry 3 ticks).
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
  2. When a line could pass 8 at all (the shown BOBs' most sprites on a line, `O_MFULL`, summed,
     with RoboCop as `RC_LINE` = 5, his cap, above 8; in normal play 82 % of the runs stop here,
     +9.8 % pictures a second, 2026-10-23), every line's sprites are counted (`ln_cnt`, one byte per play-area line): RoboCop with,
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
  tick: scroll update, `cam_follow`; then the plan (`spr_plan`: versions, queues, commits; its
  look visits only the objects wanted now or at its last run, one bit each in `pl_fl` / `pl_flp`,
  set by `obj_set` and cleared by `obj_hide`: any other object shows and prepares nothing and
  keeps `pl_st` and `pl_gs` 0, so the look would do nothing for it; 2.1 of the 16 objects are
  live in normal play, and the skip gave +1.9 % pictures a second, 2026-10-23),
  colour rows, SAT; publish; then the ticks due. `feed_vdp` gives the scroll engine its next
  VDP command at many points (the tick's stages, each object the plan works on, the budget, the
  BOB lists): its pages are built only from these points. It looks at the engines only while
  one may have work (`iw_more`: set once a frame by `wait_frame` and by the engine's update,
  and when a changed cell is queued, `rq_add`; cleared by the engine's idle exit when its
  queues are empty): 96 % of its 25 calls a picture found none, each ~1,000 T-states of status
  reads, pushes and bank checks; the fast return gave +7 % pictures a second (2026-10-23).
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
  display comparisons of refactors with `LOCKSTEP` builds and `tools/dispcmp.py` (`LOCKSTEP=24`:
  no frame comes late on either VDP, and the same ROM gives the same 3,000 lists twice; the test
  builds also pin the engine's two inputs that depend on its own speed, so that a faster build
  decides alike: the interrupts load nothing from the background queue while `spr_plan` runs,
  `pl_busy`, since `rc_prefetch` and `bq_pat` read that queue, and `rc_hold` reads `last_tick`
  instead of `tick`, the VBLANK count at the moment the budget runs; without the pins a build
  that is only faster differed in 2,300-2,500 of 3,000 lists); what the MSX
  shows against the bench's BOBs with `tools/objcmp.py` (exact, late, missing: loading, left
  out, or no frame at all in the sprite data, which `bob_flush` hides: the ride's pickups until
  2026-10-21). For the product ROM on a fresh machine (title, keyboard plans `rc2_keys`): `rc2_guard`
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

## Play-field BOBs (decision 13; `msx/field.asm`, 2026-10-21)

Why: on the level-1 coverage drive (`tools/objcmp.py` against the bench, 2995 lists, one
enemy) 2132 BOB instances were left out by the sprite budget (88 % small 16x16 effects:
bullets, debris, sparks), 84 % of them while the lift, the hostage or the vehicle were on
screen. Those three are drawn into the play field by the VDP in all 16 colours, like the
Amiga's blitter, and their sprites go to everything else. Since 2026-10-21 also the gunners that
stay put (types 26 and 28: 48x40, one colour a line as sprites, "almost invisible" against the
truck), the explosion ($F266, up to 80x88 in two parts) and the smoke ($F080's 48x56 frames),
which as sprites were striped, cut or left out.

- **Data**: `tools/msxsprites.py` gives their frames BOBHASH ids from C8h and packs them into an
  atlas (page 3 lines 0-87; `robocop_field.inc`: place, size and the draw offset of a frame
  removed by the user's choices, the frame each one looks like). The ROM keeps the atlas frame by
  frame (`robocop_field.bin`, one bank; a gunner's other facing is the mirror of the first,
  `field_upload` mirrors it). `bob_flush` sends their records to `fb_new` (frame, x, y, owner =
  the record's object) instead of sprite objects; a gunner's hit flash also shows its sprite
  silhouette over the play field (BOBHASH's silhouette byte, `bf_frame`).
- **Dynamic frames**: the explosion and the smoke do not fit in VRAM: their frames stay in two
  ROM banks of their own (`robocop_fdyn.bin`) and the step shown is copied into the atlas's last
  24 lines when an item needs it (`fb_dyn`, `dyn_res`; a frame's lines in strips of 24 side by
  side, one LMMM a strip). The user chose half of their steps ("metade dos quadros", the same
  time in all): every other step shows the one before where that one was drawn (`FIELD_HALF`;
  `field_look` makes it no change at all for the engine).
- **What changes**: once a picture (`fb_frame`, before the sprites' frame) the wanted list is
  compared with what each page holds (`fb_dr0`/`fb_dr1`; the V9958's ring is page 0). Every
  BOB that changed queues its old and new rectangles with its owner; rectangles of a page with
  the same owner are merged, and so are those that meet when one 64x64 piece holds both (a
  bigger item reached the page in pieces a picture apart: until 2026-10-21 a hostage next to
  smoke showed half old, half new for 3-4 pictures); a merged item keeps a BOB's owner over an
  explosion's. A changed cell or a tile the scroll engines draw where a BOB is also becomes an
  item (`fb_cellq`): it is composed with the BOBs over it, never a hole in one.
- **Composing** (`fb_work`, one VDP command a call while the VDP is idle; the field goes first
  in `idle_work`): an item is composed in the 64x64 scratch (page 3, x 192, line 112) from its
  page's list as it was when the item started (`fb_sn`): the background, every BOB over it
  (LMMM with TIMP, the game's drawing order), then one HMMM onto the page (two to four where
  the V9958 ring's 256 px or a page's 256 lines are crossed).
- **Background caches**: three 64x64 blocks (page 3 x 0, 64, 128) each hold the tiles of a
  4x4-cell window of the map around one owner, cell (r, c) at ((r - oy) & 3, (c - ox) & 3) so
  that a moving owner refills only the cells that come in (one 16x16 HMMM each, `FB_BURST` in a
  row); the background of an item is then one to four HMMMs. An item of 5 columns takes the
  narrower edge column from the tile cache (the hostage moves 2 px with its animation: 52 px).
  `map_write` forgets a cell whose tile changed (`fb_inval`). Items without an owner or larger
  than that take their background tile by tile.
- **Never half a change on screen**: the copy onto the page shown starts only where the beam is
  off the play area: the HUD split interrupt starts it when the VDP is idle (`isr_fbgo`), the
  VBLANK interrupt too when it keeps ahead of the beam from there (`fb_vok`), the main loop in
  the blank when it is short enough (`fb_mayq`); while such a copy waits nothing else may take
  the VDP. A copy in two parts (the V9958 ring's x 256 or y 256 crossed) is a pair: the split
  interrupt starts the second (`fb_cmd2`) as soon as the first is done, both in the same frame.
  All of an owner's BOBs change in one item (items of one owner always merge). `cmd_lock` keeps
  the interrupts off the command registers while the main program writes them.
- **With the sprites**: every item carries the picture it belongs to (`fb_tick`, counted by
  `do_publish`; a merged item keeps the older picture): its copy onto the page shown waits until
  that picture is published and its sprites uploaded (`pk_state`), and the VBLANK keeps a
  published list off the screen until its play-field BOBs are copied (`fb_pend`, `FB_HOLD` = 8
  VBLANKs at most; `fb_qlk` while an item moves between the queue and the work), but for the
  explosions' (their owner an explosion slot, high byte 0: a step drawn late shows the next one,
  they never slow the game down). The page shown's items of a published picture go first
  (`fn_take`; the V9938's other page after them): those the picture waits for (a BOB's change, a
  cell's) in their order, then a lift's or the vehicle's on the screen (`fb_late`, frames from
  `FIELD_LATE`: their copy is the one right before the picture goes on screen, so RoboCop riding
  them and the platform change in the same VBLANK), then the explosions' (until 2026-10-21 an
  explosion item of four pieces went first and the vehicle's waited past the hold: the vehicle
  showed 1 px off for 4 pictures); a hostage may show its next frame a picture early, never
  late. The V9938's old page counts as shown until a flip is on screen (an update in progress
  there ends whole). Measured on the coverage drive: the hold costs about 3 % of pictures in the
  busiest place (6.6 instead of 6.8 a second, the game's speed the same). Known: a lift's edge
  and the vehicle on the screen together are copied in two windows, one of them a picture early
  (2 frames, 1 px; MSX2+ only in the test; two items in the scratch would fix it).
- **V9938**: the next page is built from a 16 px shifted copy of the displayed one, which brings
  the BOBs in their place as they were when copied: once the copy is done, only where that may
  differ from the BOBs wanted is composed on that page (`fb_bb`: the displayed page's work under
  way when the build began, `fb_bbinit` called by `s38_target` before the build draws anything;
  its changes since, `fb_qdiff`; the tiles drawn on the page being built that meet a BOB, its
  new column among them, `fb_bbcell` from `fb_mark38`), and a marker lets it be shown
  (`fb_bsync`). Until 2026-10-21 every BOB was composed again on every build: one build's items
  held the page shown's for ~12 pictures (a hostage shown long after turning into smoke).
  Page-copy chunks are one row slot instead of four while the field has work, so its commands
  never wait long behind them.
- **Checked** (headless, `fieldcheck.py` in the scratchpad: every play-area pixel no sprite
  covers against the tiles and the BOB list of the list on screen, `fb_vis` in test builds; cells
  the game rewrote in the last 30 frames are the scroll engine's and not checked; a hostage may
  be one picture ahead, never behind or half drawn; lifts and the vehicle exactly): coverage
  drive, game frames 430-555, 860-1340 (the vehicle, lifts, a hostage) and 1490-1850 (the
  beams, a hostage), 4800 pictures per machine: MSX2 3 differ (a 7 px map cell), MSX2+ 6 (the
  case above). First version (one VDP command per cell, no caches, no picture sync): 87 (MSX2)
  and 51 (MSX2+) of the first 600. With the stricter check of 2026-10-21 (explosion steps no
  longer excuse other BOBs; a picture mixing two steps of an explosion counts as torn) the
  vehicle's window (game frames 860+, 1200 pictures) still differs in 15 pictures on an MSX2
  (0 torn) and 35 on an MSX2+ (10 torn; the old engine: 30 and 35): a big explosion (smoke
  80 x 40 and fire 48 x 16, one item of four 64 x 64 pieces, tile by tile) is erased about 0.2 s
  after it ended. The CPU is the limit there: the logic and the sprite pipeline take about
  95 % of it, the field's work waits 2-15 ms between calls (`idle_work`, `feed_vdp`) while each
  16 x 16 tile takes the VDP 0.75 ms. Not fixed.
- **Code**: a bank of its own at A000h (`BANK_FIELD`, through `field_call`; it also holds the
  scroll engines' set-up); the fixed area keeps only the hooks (`fb_redraw`, `fb_mark`,
  `fb_pend`, `fb_invf`, the interrupts' `isr_fbgo`).

## Game logic (`msx/player.asm` and the logic modules)

- **Cadence** (decision 7): `cadence` adds 6 (50 Hz) or 5 (60 Hz) per VBLANK since the last
  main-loop frame (`wf_n`) and the game ticks every `CAD_TICK` = 300 / `TICK_HZ` (12 at
  25 Hz). A frame whose work took longer (busy scenes: the logic costs about 74,000 T-states a
  tick, a 60 Hz frame has 59,659) is caught up: the ticks due run in a row (`g_tick`, at most
  `CAD_MAX` = 2 for one picture (4 until 2026-10-21: catching up skipped animation steps,
  the walk's among them; 2 costs about 5 % of speed in busy scenes, 92 % in the worst 2 s), `CAD_HOLD` = 2 while the V9938 scroll keeps the camera at a
  page's edge, none while the view shown is 32 px or more behind the one wanted, or behind at
  all with RoboCop's sprites within 16 px of the screen's edge (`cam_lag`, `rc_safe`: the scroll
  catches up first, so he never runs off the screen; until 2026-10-23 `rc_safe` left D = FFh on its
  right-edge return and the cadence took that as its cap: every due tick ran there instead of
  none, up to 4 a picture, and his sprites reached 7-9 px past the right edge in 1-4 lists of
  each busy coverage window; fixed: never above 2, 0 lists beyond); a longer delay is lost and only then the
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
  level's end, the death sequence, lives; `FE_RESTART` runs `level_restart`, `FE_OVER` shows
  the game over picture, `FE_NEXT` the level's statistics; both then go to the title and a new
  game until the next levels exist).
- **Fewer enemies** (`tools/mkrom.py` `ENEMY_CAP`, 1 in the product): with that many enemies in
  use their spawns wait (`objects.asm` `uo_cap`): a free slot still walks the level's spawn list,
  but the enemies' entries stay as they are, and the spawn delay and the map's markers do not
  count. Only the enemies count: not the types that draw nothing, 32, the level's end, which
  forces the henchmen's spawns it waits for (counted, it took the only slot and the level could
  never end), and 44, the ride's pickup dropper; nor 45, the hostage, drawn into the play field
  (the user's choice, 2026-10-22: a hostage shows together with an enemy). Those three spawn as
  on the Amiga, when their entry comes into the window just outside the screen. Until
  2026-10-22 the whole walk waited: a hostage whose place came into view while an enemy lived
  appeared when that enemy went, on screen out of nowhere (the user saw it; reproduced in
  openMSX: entry 10, 23 ticks late, spawned the tick the enemy left). An enemy that waited still
  appears at its place when the slot frees, on screen if its place is in view (kept, the user's
  choice, 2026-10-22, over skipping it or waiting until its place is off screen).
- **Harder hits** (`tools/mkrom.py` `DAMAGE_X`, 3 in the product): the enemies' bullets take
  their damage (`$FA63`) times `DAMAGE_X` and touching an enemy costs `DAMAGE_X` instead of 1
  (`hits.asm`), but the missile, enemy bullet types 1 and 2 (damage 40h, fired only by the
  enemies of types 3 and 27: REA, the 28 calls of `ebullet_add` `$F5BC`), at most twice its
  damage: 192 of the 258 energy points was too much (the user's choice, 2026-10-22).
- **The cracked wall** (map object 25 of level 1, type 5Ch, activator `obj_relocate` `$9FC4`,
  `mapobj.asm` `act_10`): after 80 ticks of "up" in front of it RoboCop and the camera go to
  the level header's +20/+22 (`$15D6`/`$15D8`, set by `level1.asm` `l1i_hdr` as `level_init`
  does at `$87A4`: (996, 640) in level 1), the palette black, fading in again. The object
  list's entries after this one meet the new camera's window in the same tick (the candidates
  rebuilt from the next entry), as the Amiga's loop goes on with the camera it changed. The
  scroll engines would walk to the new view a column (V9958) or a page (V9938) at a time with
  the ticks held (949 VBLANKs on an MSX2): `act_10` sets `jump_pend` and the main loop, after
  the tick, calls `field.asm` `engines_jump`: the play field black from the next VBLANK
  (`pal_fade` 0), the view computed (`pl_view`), the play-field BOBs and the waiting changed
  cells forgotten (`fb_init`, `rd_*`), the view drawn by the engine's set-up (`scroll_init` /
  `s38_init`) with the display, the HUD and the interrupts going on; about 26 VBLANKs on an
  MSX2, 21 on an MSX2+, all black, then the original's fade-in. Measured against the bench
  (`drive_reloc_up`): identical but `player_hot_x`/`_y` for 7 ticks right after the jump, while
  the screen is still black (the Amiga reads past state 10's records there).
- **Where**: fixed code (`4000h-7FFFh`): `player.asm`, `logic.asm` (helpers), `bob.asm`; module
  1 (`BANK_LC1` at `8000h` during the tick: `objects.asm`, `shots.asm`, `hits.asm`), module 2
  (`BANK_LC2`, mapped around `activate_objects`: `mapobj.asm`), module 3 (`BANK_LC3`, mapped
  around `$8B32`, `$9150`, the frame's end and `player_move`: `special.asm`, `frame.asm`,
  `plmove.asm`, which reaches `shots.asm` `pl_punch` through `player.asm` `pm_punch`: out of
  the fixed code, the 1.2 KiB the sprite engine needed), the level's bank
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
  `robocop_flash.inc`: entries 2, 3, 7 in level 1), so the background never changes. Every
  colour here is through the colour grade (decision 8): the fade limits the graded palette to
  `fade_cap[step]` (the grade of the original's limit, the same as grading the faded colours).
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
  copy brought before the change (seen: 4-17 pictures with an old tile after a flip). Until a
  flip is on screen (`s38_flip_wait`: the list that shows it is published at the end of the
  main loop's frame, several VBLANKs after `s38_update` decided it) the first phase draws on the
  page still shown (`s38_shown`, its first column kept in `s38_old_c0`) and the second on the new
  displayed page: before, a cell changed then stayed old on the screen until the flip showed
  (seen: 9 pictures); when the flip reaches the screen a cell half done restarts on the new
  displayed page (`rd_phase`). A changed cell where a play-field BOB is goes to `field.asm`
  instead (see "Play-field BOBs"). A cell waiting in `RD_Q` is not queued again (`rd_bits`, one
  bit per cell of the window `rd_queue` keeps; its redraw reads the map then): the level's
  electric beams rewrite their cells every tick and overflowed the queue (238 requests lost in
  the beams' corridor; now none, the queue at most 38). Known: a map object of several cells
  changed in one tick (a bin of 2x2) is redrawn one cell a call, so for about 2 pictures it
  shows partly changed; on the V9938 a beam cell may wait about 20 frames for its redraw (two
  pages to draw); a cell drawn "at once" outside the blank can tear for one picture (the
  15-machine batch: 1-6 in 40 s).
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
  interrupts 16 % of the time). `CAD_MAX=2` traded speed in busy scenes (about 74 %) for
  9.3 pictures then (with five enemies). 2026-10-21 (one enemy, `drive_play`, 38-40 s):
  `CAD_MAX` 4 100 % speed and 11.7-12.0 pictures a second, `CAD_MAX` 2 (the default since)
  94-96 % (92 % in the worst 2 s) and 12.1-12.4 pictures. Lighter scenes run at full speed. Measured with `tools/openmsx_rc2.tcl`
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
- Text added at build time (`tools/msxtext.py`, in the game's own 8 × 8 font: capitals only;
  the strokes in the logo's light grey-blue, their shadow dark blue): the port's credit on the
  title, over the dark band below RoboCop's chin ("2026 PORT BY RODRIGO G.M. GARCIA", "ORIGINAL
  GAME BY", "OCEAN SOFTWARE LTD"; 32 characters a line at most), and GAME OVER at twice the
  size in 16 lines below PIC9 (192 lines: the 6 banks PIC9 took). The user's choice,
  2026-10-22: the original has neither.
- Flow: power-on → title (fire) → level 1; game over → PIC9 for 30 seconds or until fire is
  pressed once released (the original: 128 frames; the user's choice) → title; the level's
  end → the level's statistics → title (the bonus stages and level 2 come later). Test builds
  with a script skip the title.
- **The level's statistics** (`front_stats`, `show_level_stats` `$85D8`: script `$1132F` through
  `$10762`): the henchmen killed (`$16C2`), the nukes collected (`$16C0`) and the hostages
  rescued (`$16BE`) typed into the play area of page 0 (a register list of its own: page 0
  unscrolled, no sprites; the split shows the HUD as in the game), one script element a tick
  (50 a second; at 60 Hz every sixth VBLANK is skipped), in the text screens' 8 x 8 font and
  palette (`tools/msxtext.py` → `build/msx/text.inc`: the font's strokes colour 1, `$070`, its
  hand-drawn shadow colour 4, `$147`; column c at x 8c − 16, the Amiga's bitplane x − 32, row r
  at line 67 + 8r). No cursor: `$FE14` falls through into `clear_game_vars`, so `$B00` is 0 and
  `$1171E` never draws it. It lasts 362 ticks (the 105 elements typed, the script's 256-call
  wait, its end), or ends with fire from tick 50 on; then the play area goes black at once.
  The bench's picture of the screen and the model's are identical (agent run, 2026-10-21).
- The ROM is 1 MiB (128 banks; the user's choice, 2026-10-22, for RoboCop's speech and the next
  levels: a 1 MiB MegaRAM or flash cartridge): the first 65 hold the game (the pictures take the
  last 13 of them), then the speech (`VOICE_BANK`; in the music: `VOICE_MIX_BANK`), the title
  music for the SCC (`SCC_BANK`) and for the OPLL (`FM_BANK`), 74 banks in all; the rest is free.
  The 8000h window must never map bank 63 or 127: on a KonamiSCC cartridge they select the
  SCC's registers at `9800h` (`tools/mkrom.py` checks every bank that window maps: the pictures,
  read at `A000h`, take bank 63). `BANK_INPUT` holds the test builds' joystick script and the
  PSG player with its streams, `BANK_MUSIC` the SCC / OPLL player and the speech's tables. The
  complete game with levels 2 and 3 may need 2 MiB.

## Sound (`msx/sound.asm`)

- At power-on, with the BIOS still in page 0, every slot's page 1 is searched for an OPLL BIOS
  ("APRLOPLL": MSX-MUSIC built in; "PAC2OPLL": an FM-PAC, whose I/O ports are switched on with
  bit 0 of `7FF6h` in its slot; `cold.asm` keeps these texts complemented, see the MSX Pico+
  below). The PSG is always used; the OPLL (ports `7Ch`/`7Dh`) when
  found (`snd_fm`). Then `music.asm` `mus_init` looks for an SCC: in the cartridge's own slot
  (its mapper's bank 3Fh at `8000h` shows the registers at `9800h`: a Konami SCC or flash
  cartridge; a MegaRAM has none) by four values written to the first waveform byte (`9800h`),
  each read back after about 1 ms, in up to eight tries: one value read back is enough in the
  cartridge's own slot (`sound.asm` `scc_pat`; the MSX Pico+ on the user's SX-2 reads back 00
  one time in four to two in four; on a MegaRAM or a Konami mapper a write there selects the
  `8000h` bank, without the chip bank 3Fh shows there, and `tools/mkrom.py` checks that no such
  byte of this image at `1800h` is a test value; in openMSX found with 90 % of the reads made
  to fail), three different ones in another slot (an unknown cartridge), else
  (`sound.asm` `scc_scan`) in the other primary slots that are not expanded (an SCC or SCC+
  cartridge beside a MegaRAM: page 2 switched to it through port `A8h`), skipping any whose
  `8000h` is RAM, after 3Fh written to its `9000h` (an SCC+ starts in SCC mode). Every SCC
  access then runs in the fixed area (`sound.asm` `scc_pv`, `scc_on`, `scc_v0`, `scc_wv`
  between `scc_open` and `scc_close`: page 2 may be the other cartridge meanwhile), but the
  in-cartridge effects' fast path (`music.asm` `fxr_so`, page 2's `A000h` half untouched).
- **Stores to the SCC, as Konami's games make them** (2026-10-22): every register store is to a
  fixed address (`ld (nn),a`), per channel (`scc_pvs`), and the channels' enable is written
  again with every record (1-3 for the title music, 0-3 for the effects); the waveforms go with
  `ldir` (each store right after a load). Byte for byte the same writes on every machine: the
  title music and the effects stay register-exact in openMSX. (Made while the MSX Pico+ was
  silent; the cause turned out to be the next point, not the stores.)
- **The MSX Pico+** (the user's SX-2, an MSX2+ on an FPGA, with Jeroen Taverne's RP2350
  cartridge). Verified in its firmware v2.12 (`msxpico_noroms_v212.uf2` from msxpico.com,
  decompiled with REA/Ghidra as Cortex-M33 Thumb code at `10000000h`; addresses of that image):
  - The mapper is sure (`1000DA6Ch`) only for an 8-byte tag at the ROM's offset 10h (`ROM_ASC8`,
    `ROM_AS16`, `ROM_KON4`, `ROM_KON5`, `ROM_NEO8`, `ROM_NE16`, ...) or a ROM in its SHA1
    database; any other ROM gets "Not 100% sure about mapper type" with a guess from its
    `ld (nn),a` targets (`1000DC74h`: 7000h, 9000h and B000h give Konami SCC). `rc2.asm` puts
    `ROM_KON5` at `4010h` (the BIOS reads the header only up to `400Fh`).
  - Starting a Konami SCC ROM (`1000A6C0h`, mapper 2), it searches the whole image for "OPLL"
    and then for `21 18 40` or `11 18 40` (`ld hl,4018h` / `ld de,4018h`): with both it takes
    the ROM for an FM-PAC game (release notes v1.28 "FM-PAC sound in Konami5 mapper", v1.33 the
    `4018h` condition) and starts it with an FM-PAC in its subslot 1 and a Konami5 mapper
    without the SCC, otherwise with the SCC. This image had both (the OPLL search's texts and
    its `ld hl,4018h`): `cold.asm` now keeps the texts complemented (compared after a `cpl`)
    and loads `4018h` as `ld l,18h`, and `tools/mkrom.py` refuses an image holding "OPLL".
  - Observed on the user's machine before the fix (the DIAG build): the cartridge's slot 1
    expanded, game in subslot 1-0, and with 3Fh at `9000h` every read of `9800h` the ROM's own
    byte (bank 63 at `1800h`) from the first probe on; three test cartridges without that pair
    of patterns had the SCC (a tone; the waveform read back right in one try in four to all
    four, else 00 — hence `scc_pat`'s tries).
- `snd_frame` runs from the VBLANK interrupt (the music keeps its tempo while the game catches
  up); the PSG's address latch is shared with the joystick reads, so outside the interrupt
  every PSG access runs with interrupts disabled and R7 keeps port A as input.
- **RoboCop's speech** ("YOUR MOVE, CREEP", in the title music at 57.6 s: instrument 24, sample
  11, "TOM" in its 8SVX header, on Amiga channel 2 and again on channel 0 nine ticks later; the
  user identified it): tones cannot say it, so every stream leaves its notes silent and the PSG
  plays it as PCM (`music.asm` `vm_play`; `tools/msxvoice.py`: the channels rendered as Paula
  plays them, the A500's filter, 11,117 samples a second, 1.68 s in 3 banks). With the PSG alone
  (the user's choice for the PSG) it plays when the player starts: the title music stops, then
  `vm_alone` plays the speech (`VOICE_BANK`). With an SCC or an OPLL it keeps its place in the
  music (the user's choice: "manter a originalidade"; below). Each sample byte indexes
  `voice_tab`: the three voices' volumes (tone and noise off, a voice outputs its level), whose
  summed level on the AY's curve comes nearest to the sample. The loop writes C's volume, then
  B's, then A's, 45 T-states apart, and until the third write the PSG mixes old and new volumes:
  the first table (each level's nearest combination, 1.5 % quantisation error) jumped from one
  level to the next (`(0, 12, 15)` beside `(6, 13, 14)`), so every sample left 13-25 µs of a
  level far from both, a hiss the user heard under the speech in the music ("um chiado
  horrível"; 2026-10-22): measured in openMSX 15-20 dB over the Amiga's highs (4-6 kHz: −10.9 dB
  against the Amiga's −26.5, relative to 50-4000 Hz), simulated with the writes' timing as
  closely, SNR against the Amiga's mix 6 dB. Now (`smooth_table`) B and A only grow with the
  level, along a path of single-volume steps chosen by dynamic programming against those
  transients, and C, written first, gives the fine levels within each step: in simulation the
  writes' timing then costs 0.1 dB, SNR against the Amiga 17 dB in the music (16 dB alone),
  quantisation 2.6-3.7 %; measured in openMSX 4-6 kHz −25.9 dB, 10-14 kHz −24.8 (was −9.5; the
  rest above the Amiga is the PCM's own image near 11 kHz, which 322 T a sample put there
  instead of 6-10 kHz at 448). The loop takes 322 T-states a sample (measured in openMSX:
  18,602 of 18,675 samples, the others the fire reads, 530, and the bank changes, 603) with the
  interrupts off; every 256 samples it reads fire: pressed once released, it ends the speech.
  Recorded in openMSX: the music up to the key, then the speech, then silence.
- The original's music and sound effects are tunes of the same player (MU1 at `$18000`):
  `tools/rc2music.py` models it exactly; `tools/msxsound.py` turns its output (per Amiga channel
  and tick: period, volume, instrument, key-ons) and the samples into PSG streams
  (`build/msx/sound.inc`, 7571 bytes with `--budget 7680`): the title's music (TITM tune 1,
  three voices that loop together after 5184 ticks) and the 42 in-game effects (MU1, one voice
  each). Its docstring gives the mapping and why: each instrument's pitch measured from its
  sample (the 8SVX headers' samples per cycle are a default 32), the tunings snapped to one
  grid (square waves expose detuning), the loudness from the RMS of the sample bytes played in
  each tick (one-shot fades come out by themselves), the Amiga's drum channel riding the three
  voices (a kick lifts the bass note's level, snares and toms are tone + noise for 3 ticks on
  the quietest voice), effects as tone, tone + noise or noise per tick from the bytes played;
  a trellis trades level detail for bytes to fit the budget. It writes preview WAVs of the
  Amiga reference and of the PSG (`build/music/preview`) and prints how close they are (title:
  chroma similarity about 0.85, levels within 1.5-2.2 dB; effects: envelope correlation
  0.84-0.99).
- Player (`msx/sndplay.asm`, in `BANK_INPUT` at `A000h` after the test builds' joystick script:
  the ROM's 64 banks are full; `sound.asm` keeps only the stubs in the fixed area: `snd_frame`
  from the VBLANK interrupt, `snd_play` from `frame_keys`, `snd_music` from `front_title`,
  `snd_stop` in `pl_init` (`level_init` `$8720`), the game over, the statistics and the end of
  the title; `sq_init` at power-on). The main program only queues a request (`sq_put`: an
  effect, the title's music or a stop; 8 entries, `snd_q`); the VBLANK interrupt starts them
  before its tick, so the voices change in one place and the main program never keeps the
  interrupts off for them: an effect started there with the interrupts off took about 1300
  cycles, and the HUD's split came 10 lines late once in a 40 s start check (2026-10-22). A
  stop also silences the PSG at once (the VBLANK interrupt is off while a level starts). Three
  voices of 10 bytes (`snd_v`): a stream is records of a duration
  in ticks (0: the end: the title's voices go on at their loop point, an effect's voice goes
  silent) and the voice's state (volume, tone and noise on, the 12-bit tone period, the noise
  period: only what changes). 50 ticks a second as the Amiga's player (at 60 Hz every sixth
  VBLANK is skipped). An effect plays on the voice of its Amiga channel (0-2: A-C; 3: an idle
  voice, C first since A plays the shots, else the one nearest its record's end); while the
  Amiga's channel 3 plays an effect,
  an effect numbered lower than the last one started is not played (`$1822C`). The mixer
  (R7) keeps port A as input and port B as output. Checked headless: the PSG's registers read
  at every VBLANK of the title (60 and 50 Hz machines) follow the streams state by state at 1.2
  and 1.0 VBLANKs a tick; in game the effects start on their voices (`sess_psgdrive.tcl` in the
  scratchpad). With the SCC / OPLL player in the ROM the PSG title's registers are the same
  sequence as before, state by state (858 states, a `NO_SCC=1 NO_FM=1` build, 2026-10-22).

### The title music on the SCC and the OPLL (`msx/music.asm`, `BANK_MUSIC` at `A000h`)

- **What plays it** (`mus_mode`, the user's request for the sound closest to the Amiga): an SCC
  takes the melody (Amiga channels 0-2 on SCC channels 1-3: each sample's own waveform), an
  OPLL the drums (channel 3 on its rhythm section) and, without an SCC, the melody too (OPLL
  channels 0-2); with an SCC alone the drums ride PSG voice C; with neither, the PSG player's
  title as before. The in-game effects stay on the PSG player in every mode. Test builds:
  `NO_SCC=1`, `NO_FM=1`, `NO_SCC_INT=1` (only another slot's SCC), `FORCE_SCC=1` (the
  cartridge's SCC, not tested for: hardware whose SCC the test misses), `DIAG=1` (`msx/diag.asm`:
  after the sound detection, at its place in the start, a screen of what this machine showed it
  — the BIOS's slot tables, A8h, the mapper's banks at `8000h`, whether a store at `9800h` switches
  the bank, every value the SCC test read, 64 stores and loads at `9800h` by instruction form, the
  CPU's speed — then SCC test tones in turn: the engine's stores with bank 3Fh held, `(hl)` stores,
  bank 02h at `8000h` meanwhile, the window switched every frame; no game; the other builds are
  byte for byte the same).
- **The data**: `tools/msxscc.py` (`scc.bin`: three SCC voice streams, the PSG drum stream in
  `sndplay.asm`'s format, nine 32-byte waveforms; 25.8 KiB) and `tools/msxfm.py` (`fm.bin`:
  three OPLL voice streams, the rhythm stream, the custom instrument and the rhythm's pitches;
  13 KiB), from the same exact Amiga model as `msxsound.py`; their docstrings give the mapping
  and why (the SCC: waveforms fitted from each sample's sustained body, harmonics 1-15, the
  levels from the bytes played per whole cycle, a dip before a re-trigger of the same note,
  the Amiga's real tuning; the OPLL: the preset or the custom patch nearest each sample's
  spectrum and envelope, the custom one fitted for the bass, per-tick volumes that follow the
  Amiga through the instruments' own envelopes, BD / SD / TOM at the drums' measured pitches).
  `tools/mkrom.py` appends both from their banks and writes `gen/music.inc` (each stream's bank
  and address, the waveforms, the patch, and the voices' state after the speech).
- **The player**: four voices of 16 bytes (`mus_v`: three melodic, the drums) read their streams
  through the 8000h window, crossing banks: records of a duration in ticks (0: the stream's
  start again) and a ctl byte giving the volume and which fields follow (the SCC: the period N
  and the waveform; the OPLL: the F-number and block, the instrument and sustain, key on, a new
  note: the key off and on again; the rhythm: the keys struck and the three volume registers).
  Every stream lasts the tune's loop (5184 ticks), so the voices stay in step. 50 ticks a
  second from the VBLANK interrupt (`snd_frame` → `mus_frame`; at 60 Hz every sixth VBLANK is
  skipped); `snd_music` starts it at once (`mus_start`: the custom instrument, the rhythm's
  pitches, the SCC's channels on), `snd_stop` silences it at once (`mus_stop`).
- **The speech in the music** (tick `VOICE_TICK`, 2880): the tick raises `mus_speak`; `front.asm`
  `front_fire` then calls `vm_music`, which mutes the chips (the SCC's volumes 0, the OPLL's
  melodic volumes 15 with the keys as they are, its rhythm off) and plays `voice_mix.bin` (3
  banks from `VOICE_MIX_BANK`): the
  Amiga's four channels for the speech's 84 ticks (the speech with the bass and the drums going
  on, rendered the same way, `MIX_GAIN` 0.57: measured in openMSX, the music around it as loud
  against the PCM as on the Amiga, within 1 dB in all three modes). Then the voices take the
  state `mkrom.py` computed for tick 2964 (`mus_snap_...`: each stream decoded to that tick,
  every field given; an OPLL note again only when one began meanwhile, the rhythm's keys not
  struck again) and the chips with it, in about 1 ms; the VBLANK the speech held off is
  dropped and the 60 Hz divider reset, so the next tick comes at its time (+2 ms at 60 Hz, +0
  at 50 Hz, measured). While the music plays, PSG voices A and B hold the PCM's middle level
  (`VOICE_DC_A`, `VOICE_DC_B`: 14 and 13, the table's coarse level nearest 1.5 with C at 0; a
  DC, silent; ramped along `voice_tab` over 20 ms at the music's start and end; read in openMSX:
  R8 14, R9 13, their tone and noise off, C playing the drums),
  so the PCM starts and ends on it without a fade. (First tried: ticking the music from inside
  the PCM loop every 160 samples; each tick held the samples for 0.4-1 ms, measured, a buzz
  louder than the quantisation. Fire pressed once released during the speech ends the title.)
- **Checked headless in openMSX** (2026-10-22, scratchpad `sess_sccregs.tcl`, `sess_fmregs.tcl`,
  `sess_fmwrites.tcl`, `scccheck.py`, `fmcheck.py`): at every tick of a whole loop and past it
  (5,564 ticks) the SCC's registers (period, volume, waveform of each channel, the enable) and
  the drums' PSG registers, or the OPLL's (channels 0-2, the rhythm, the patch), equal the
  streams decoded independently, on 60 and 50 Hz machines, with the SCC in the cartridge
  (KonamiSCC), in another slot (`-extb scc`, `-extb scc+`) and with SCC + OPLL; the 84 speech
  ticks muted, tick 2964 and every tick after it as the streams say. Every new OPLL note writes
  the key off before the key on (82 of 82). The slot scan finds no SCC on the 15 machines
  without one, and the game starts on all. Recorded against the Amiga reference (the first 50
  s, tempo aligned): chroma similarity 0.92 and level error 1.4 dB with the SCC (PSG voice C
  drums), 0.91 / 1.5 dB with SCC + OPLL, 0.90 / 1.6 dB with the OPLL alone, against 0.84 /
  2.1 dB for the PSG title on the same machine. The OPLL's drums end sooner than the Amiga's
  samples (a snare's tail, 20 ticks on, is silent: the rhythm section's envelopes).

### The in-game sound effects on the SCC (`msx/music.asm` `fx_...`, 2026-10-22)

- **Why** (the user: "agora com suporte a SCC+ não poderíamos também converter todos os SFX para
  ficar o mais próximo do Amiga?"): of the 42 effects' 737 ticks (the exact Amiga model) 342 are
  a tone, 164 tone + noise, 231 noise; an SCC plays the tones with the samples' own waveforms
  (#0, a 22-byte synthetic cycle, exactly), the PSG keeps the noise (the SCC has none). Without
  an SCC the effects stay as they were (`sndplay.asm`).
- **Data**: `tools/msxsccfx.py` (`sccfx.bin` in `SCCFX_BANK`, 4473 bytes: its streams must fit
  the bank, `tools/mkrom.py` checks it; its 49 waveforms copied into `BANK_MUSIC` as `fx_waves`):
  per effect its Amiga channel, an SCC stream (the tonal part: 37 effects) and a PSG stream (the
  noise part: 29), in the title music's formats, one-shot. Each tick of the exact Amiga model is
  measured (pitch with an octave check over YIN, the tone and noise shares, the brightness) and
  each effect's tonal ticks grouped into 1-4 waveforms fitted to the bytes played. Against the
  Amiga, SCC version / PSG version: spectral distance 3.3 / 5.9 dB, pitch within 50 cents 82 /
  21 % of the tonal ticks, envelope error 0.6 / 1.0 dB, brightness error 0.44 / 0.81 octave; the
  pure-noise effects stay as they were (the same PSG noise), the dark explosions are still
  0.5-1.6 octaves brighter (the PSG's darkest noise). Previews: `build/music/preview/sfx_all_*.wav`.
- **Engine**: `sndplay.asm` `sq_sfx` hands an effect over when an SCC was found (`sound.asm`
  `fx_go` → `fx_start`, `BANK_MUSIC` mapped meanwhile) and ticks the engine with its own 50 Hz
  ticks while one plays (`fx_act`; `fx_tk` → `fx_tick`). The tonal part plays on SCC channel 0-3
  = the effect's Amiga channel (a new effect there replaces the one playing, as on the Amiga; the
  title music's voices `mus_v` serve, idle in game), the noise part on a PSG voice (`fx_pv`:
  channels 0-2 on A-C, channel 3 on an idle voice, C first, else the one nearest its record's
  end, as `sndplay.asm` does); the `$1822C` rule (a lower effect than the last one is not played
  while channel 3 plays one) is kept. The SCC in the cartridge: its registers mapped once per
  output and written straight, the waveform from `fx_waves` straight into the chip, skipped when
  the channel holds it already (`fx_wc`); in another slot: through `scc_pv` / `scc_wv`.
- **Cost, measured in openMSX** (the coverage drive, game frames 90-1400, C-BIOS MSX2 at 60 Hz:
  an effect playing 92 % of the ticks): the whole sound hook takes 3.25 % of the CPU (1940
  T-states a VBLANK) against 1.87 % (1120) with the PSG effects. Through the music's record
  reader and output it took 4.81 % (a tick 2290 T-states, a start 4500); the effects' own
  readers (`fxr_sc`, `fxr_ps`: no bank crossing, the fields straight to the chip, `MV_LEFT`
  counted down in place), the PSG player's voices skipped with an SCC (idle there) and the tone
  period written only with the tone on brought a tick to 1560, a start to 3340. The game's
  speed (game frames a second over five busy windows, C-BIOS MSX2 and FS-A1FX): 1.9 % lower than
  with the PSG effects on average (2.9 % before), within the windows' own spread of ±3 %.
- **Checked headless** (`sess_fxlog.tcl`, `fxcheck.py`: a model of the engine replays the effect
  starts the game made against `sccfx.bin`): every tick of 40 s of the drive (about 230 starts,
  1500 ticks) the SCC's channels 0-3 (volume, period, waveform) and the PSG voices' volumes and
  noise bits equal the model, with the SCC in the cartridge and in another slot (`-extb scc`).
  The title music stays register-exact on every chip set (SCC in the cartridge or another slot,
  OPLL, SCC + OPLL) after the routines it shares changed.

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
