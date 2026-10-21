# Robocop 2 (Amiga) — reverse-engineering ledger

Analysed version: *Robocop 2 (1991)(Ocean)[cr Melnok]*, 2 ADF disks.
Developed by Special FX for Ocean (credits on the `OAS` screen).

| Disk | SHA-1 |
|---|---|
| 1 | `f1bd7bc85c58df4a6f435c9742e37dc8eb8ddbf3` |
| 2 | `faf57c531bbf56017e0fcc55e222ec83ae7a968f` |

Legend: **[verified]** = confirmed by data/code/image; **[inferred]** = consistent
hypothesis not yet confirmed.

## 1. Disk format

- Neither disk has an AmigaDOS file system: sector 880 holds audio samples. All access is
  by sector (512 bytes) through a custom loader. **[verified]**
- Free sectors were filled with `DOS`+counter by the crack. **[verified]**
- `tools/rc2files.py list` maps 100% of the sectors of both disks; the only content outside
  the directory are 3 orphan PP20 copies identical to OAS, PIC4 and PIC7. **[verified]**

## 2. Boot chain (disk 1)

The bootblock (valid checksum) uses `trackdisk.device` (`DoIO`):

| Disk offset | Size | Final address | Content |
|---|---:|---|---|
| `$00400` | `$A600` | `$8000` (via `$48000`) | main code |
| `$CE600` | `$0200` | `$0100` (via `$60000`) | lookup by name + name table |
| `$CE800` | `$0800` | `$0300` (via `$70000`) | trackloader + directory |
| `$D4800` | `$5200` | `$71000` | run with `JSR` before the game (probably the crack intro) **[inferred]** |

Then it enters supervisor mode (vector `$20` trick), stores `$100` in `($C0)` and jumps to
`$8000`. The game calls the loader with `MOVEA.L $C0.W,A2 / JSR (A2)`, `A0` = file name.
**[verified]**

## 3. Loader file system

- Name table at `$14E`: 27 entries of 12 bytes `name[6] | id.w | dest.l`. Bit 7 of the id
  marks PP20 (the loader loads at `dest-8` and decrunches in place). **[verified]**
- Directory at `$91C`: 6-byte entries indexed by `id & $7F`: `(disk-1)<<12 | sector`,
  `length.l`. **[verified]**
- `PUZL` exists on both disks; the lookup switches entries when the 3rd character of the
  name is `Z` and `($8050) == 2`. **[verified]**
- The 14 PP20 files decrunch with exact bit-stream consumption (`tools/pp20.py`).
  **[verified]**

### Files

| Name | Destination | Final size | Content |
|---|---|---:|---|
| DATAE | `$40000` | 32032 | Data East logo, 320×200×4 + palette **[verified]** |
| OAS | `$18000` | 32032 | Special FX/Ocean credits, 320×200×4 **[verified]** |
| TPIC | `$6FFA0` | 61568 | title, HAM6 320×200 + data + 3 8SVX samples **[verified]** |
| PIC1–7, PIC9 | `$6FFA0` | 42368 | movie stills, HAM6 320×176 **[verified]** |
| PICF | `$6FFA0` | 61568 | final picture, HAM6 320×256 **[verified]** |
| TITM, MU1, CH1, CMP, HI1 | `$18000` | 152520 / 62800 / 24760 / 84031 / 36511 | player code, tunes and 8SVX samples (*Music and sound effects*, section 4) **[verified]** |
| PERMA | `$58850` | 96080 | resident graphics (player, common BOBs, HUD) **[verified for the player]** |
| SPERMA | `$4B68A` | 53700 | resident BOBs with masks **[verified]** |
| RB1 | `$12588` | 10290 | the 8 letters of the title logo, BOBs with masks (48 px wide), flown in by `$106E2` (section 5) **[verified]** |
| DATAL1–3 | `$28000` | 144716 / 105816 / 185356 | level data: tiles, map, BOBs **[verified]** |
| MADEX | `$45250` | 25340 | level-2 BOBs **[inferred]** |
| FRNG | `$1E980` | 93224 | bonus stage *Gun Calibration* **[inferred]** |
| PUZL | `$17080`/`$17100` | 76012 / 113632 | bonus stage *Brainstorm* **[inferred]** |

Static-screen format: 32 bytes of OCS palette (`$0RGB`) followed by sequential planes
(DATAE/OAS); `PIC*` have a 128-byte header (32 colours + zeros) and the bitmap at `+$80`.
Use `tools/planar.py`. The picture shown is `PIC('1'+D0)` (routine `$11E06`): D0 = 0/3/6
before levels 1/2/3 (PIC1/PIC4/PIC7), 1/5 and 2/4 around the bonus stages, and **8 = game
over (PIC9)**, called from `main_loop` when the lives counter `$8034` goes negative.
**[verified]**

## 4. Game engine (code at `$8000`)

- `$8000`: `BRA` to the initialisation; `$8004–$8028` are 10 public `BRA.W` entries (used
  by overlays). **[verified]**
- `$802C–$8063`: global variables; `$8050` = current level. **[verified]**
- Initialisation at `$11A20`: logos (DATAE, OAS), title (TPIC in HAM6, TITM music), then
  PERMA/SPERMA. **[verified]**
- Main loop at `$80C2`: waits for `($802C) >= 2` (the VBL counter), i.e. **30 game frames/s**
  on the NTSC Amiga this release targets (Data East, US: the DATAE logo; 25 on a PAL
  machine); calls ~17 routines per frame. **[verified loop; the rate follows from the VBL
  counter]**
- Per-level table at `$8664` (40 bytes × 3 levels): pointers patched into the code
  (`$9C18`, `$915E`, `$8B54`), initial camera, palette (`$FFF6` for level 1, `$10036` for
  levels 2–3). **[verified]**
- Game palette: 31 colours copied into copper list `$1049E` (COLOR01–31), fade routine at
  `$F8C4`. **[verified]**

### In-game video

- Copper list `$1049E`: `BPL1MOD=BPL2MOD=$72`, DDF `$38–$C8` (38 bytes per line),
  horizontal DIW `$90–$1B0` (288 px). **[verified]**
- **Interleaved 4-plane** playfield, 152 bytes per line (4 × 38), 16 colours; colours 16–31
  belong to the hardware sprites. **[verified in the BOB routine]**
- Two buffers swapped with `EORI.L #$18E00,$B16` starting at `$6FFA0` (difference `$7200`
  = 152 × 192 lines). **[inferred]**
- In-game copper list `$10332`: bitplanes on from line `$1E` to `$CD` (176 lines of play
  area); from line `$D0` the **status panel**: 5 planes (32 colours, COLOR01..31 set by the
  MOVEs at `$103FA`), 320 px, modulo 0, planes at `$6DA20` + n×`$780` — the last 9600
  bytes of PERMA (file offset `$151D0`); bitplanes off at `$FE` (46 lines shown). It
  holds the energy can, a message/energy box, the nuke counter, two heads (lives), the
  timer and the score (`build/png/panel.png`). **[verified]**
- **Panel elements and their routines** (via REA; assets rendered by `tools/panel.py`;
  the operations are modelled in `tools/hudmodel.py`, which redraws the panel stored in
  PERMA exactly from the start values — a unit test). **[verified]**
  - every routine blits into the panel bitmap; digits and characters write planes 0–2 only,
    so planes 3–4 (the colour bank) stay — the bank is 0 under every digit cell and under the
    text; the can, heads and icons write all 5 planes;
  - energy can, x 0 y 3: `update_energy_can` (`$89BE`, every game frame) moves the shown
    level `$169C` 8 units towards the target `$169A` (0..`$100`, 32 steps); a target of
    `$100` or more draws the full can (`$661D0`, 32×40) at once; otherwise a step from an old
    level L ≥ 2 (L = old shown >> 3) draws an "empty top" (32×8: `$664F0` for L > 23,
    `$66590` for 13–23, `$66630` for ≤ 12) at y = 33 − L and the can's own line 39 − L at
    y = 42 − L. A negative shown level sets the death flag `$16CC`. The energy only drops by
    fixed amounts (−`$A`, −`$C`, −`$10`, −`$18`, −`$20`, −`$30`, −D6, −1; `ST $169A` kills) or is
    set to full (`$100`/`$102`: refill counter `$16AA`, level start); stepping *up* would draw
    the surface two lines lower than stepping down, but the game never does it;
  - message box, x 35–212 y 1–15: `message_queue` (`$FD76`) stores a string pointer in the
    4-slot queue `$FD92` at the write index `$8056` (a busy slot drops the message);
    `message_ticker` (`$FDA2`) runs in the VBL interrupt (`irq_l3_vbl`, `$10324`): one
    character per VBL with `panel_draw_char` (`$10620`: 8×8 font `$65DB0`, 3 planes, at
    x 40 + 8c, y 5; code ' ' → glyph 41, codes ≥ '@' → code − 'A', others → code − `$16`, so
    the strings use lower-case letters for the punctuation glyphs: 'e' = '.'); the string's
    `$FF` terminator is not drawn; then `$805A` = `$50` VBLs of wait and columns 20..0 erased
    with spaces, one per VBL, before the slot is freed and the read index `$8054` moves on (an
    empty slot is skipped in one VBL). Messages: `$C222` "PROTECT THE INNOCENT.", `$DC76`
    "ARREST ARMED EMEMY.", `$C238` "SUSPECT DESTROYED.", `$C24B` "CAIN DESTROYED.", `$D46C`
    "CHASE CAIN.", `$ED11` "EXTRA LIFE.", `$865A` "TIMEOUT.", `$F837`/`$F82C` "PAUSE ON./OFF."
    and the debug `$F841` "NUKE xx HOST xx" (key `$21`);
  - timer, score and weapon ammo: `panel_update_digits` (`$F6B8`, from `frame_keys` `$F76C`
    every game frame) redraws, by the game frame counter `$B00`, the timer's minutes or seconds
    (`$804A`/`$804B`, red glyphs 12–21, x 224/240 and 272/288, y 6: the code passes the odd
    byte offsets `$10F`/`$10D` and the blitter aligns them to words), the ammo's hundreds or
    tens and units (`$8030`/`$8031`, green, x 48/64/80, y 23) and one score byte
    (`$8046`–`$8049`, 7 green digits, x 192–288, y 29) with `$105D2` (16×16, 3 planes,
    `$654B0`; columns 0, 1, 14 and 15 are the same for all ten digits); the dash between
    minutes and seconds is a static red cell at x 256;
  - weapon icon, x 96 y 25: `set_weapon` (`$FD30`) sets the weapon `$805C` (0–3: normal, rapid
    fire, scatter, three-way), its ammo from `$FD52` (000/500/300/400) and its icon from
    `$FD5A` (3, 0, 2, 1) → `panel_draw_icon` (`$896A`, 16×16, offsets `$AF76`, 8 icons);
  - lives, x 128 + 32n y 14: `panel_draw_head` (`$88DE`) draws a 32×34 head (`$666D0`, 6
    graphics: 0 RoboCop's helmet, 1–3 the helmet turning into Murphy's face, 4–5 Murphy's
    face); slot 0 is drawn without its last 4 columns except for its first 4 lines;
    `init_lives` (`$FFD8`) sets `$8034` = 2 and draws head 0 in both slots; an extra life
    (`$ECD8`) adds a life, draws head 0 in slot lives − 1 and queues "EXTRA LIFE."; during the
    death sequence (`main_loop` `$8270`, counter `$16BC` +4 per game frame) slot lives − 1
    shows heads 3, 4, 5 for counter values `$60`–`$8E`. **[inferred: how the lives decrement at
    `$82A0` interleaves with that animation is still to be read]**
- Area at `$7F5E0` swapped with `EORI.L #$1920` and cleared with `BLTSIZE=$9202`
  (2336 bytes): hardware-sprite double buffer. **[inferred]**

### BOBs (routine `$AB08`, `draw_bob`)

- Input: `D0/D1` = world x/y (camera `$B04/$B06` subtracted), `A2` = data, `D4` = BLTSIZE.
  **[verified]**
- Format: `[mask][plane0][plane1][plane2][plane3]`, each `width_bytes × height`,
  `width = ((D4 & 63) − 1) × 2`. Cookie-cut with minterm `$CA` (`D = A ? B : C`), clipped to
  288 × 177. **[verified]**
- The planes may contain bits outside the mask (the artists did not clean them; the
  cookie-cut discards them), so "mask ⊇ planes" is **not** a valid format test. Always read
  the real BLTSIZE from the assembly. **[verified]**
- BOB addresses are **per level**: every handler belongs to one level and that level's
  DATAL holds the graphics at the fixed address. E.g. `$3E450` (16×16, step `$A0`) in level
  1 = flames/smoke of the vehicle routine `$8B9E`; `$3E810` (32×23, step `$1CC`) in level 2
  = walking legs of enemy type 1. **[verified visually]**
- Enemies are **built from parts** (legs, torso, arm/gun from PERMA), each part a BOB.
  **[verified for type 1]**

### Background and maps (routine `$BCCA`) **[verified]**

- The background is **redrawn entirely every frame**: 19 × 12 tiles of 16×16 copied by the
  blitter (`BLTCON0=$09F0`, `BLTSIZE=$1001`) into the back buffer.
- **Tiles**: 16×16, 4 planes interleaved per line = 128 bytes, at the start of the DATAL.
- **Map**: at `$38000` (DATAL + `$10000`), **160 columns** of 16-bit words;
  `graphic = DATAL_base + (word & ~$7F)`, the low 7 bits are attributes.
- Fine scroll: horizontal through BPLCON1 (`15 − (camera_x & 15)`), vertical through the
  line offset `(camera_y & 15) × 152`.
- **Level 1**: map of **160 × 51 tiles (2560 × 816 px)**, **431 unique tiles** (~55 KiB in
  4 bpp), scrolling in both directions; the map ends at `$3BFC0`, exactly where the first
  BOB graphics start.

### Objects (routines `$9C06` and `$C3E4`) **[verified in code]**

- Per-level object lists (`$A562`, `$A828`, `$AA3A`): 12-byte entries `type, ?, ?, ?, x, y`,
  terminated by a negative word; `$9C06` activates the ones entering the camera window
  (some also write patterns into the map).
- 5 active slots at `$BE4` (structure of arrays: x at `−$80`, y at `−$20`, type at `+$20`,
  flags at `+$21`).
- Type descriptors at `$BEB0` (16 bytes; types 1–52): score (BCD), handler, death routine,
  energy, collision width/height. Death adds the score and counts *henchmen obliterated*.

### Player (routine `$B94A`) **[verified]**

- RoboCop is **not a BOB**: every frame `draw_player` composes it into a 64 px × 73 lines ×
  4 planes buffer at `$7E3A0` (planes every `$248`) and copies it into the **8 hardware
  sprites** (4 attached pairs, 16 colours, COLOR16–31; colour 0 transparent), whose data
  pointer is at `$8036`.
- Animation table at `$B4E2`: 17 states × 8 bytes (`steps−1`, list offset, lines); state in
  `$15E2`, frame counter in `$15DC` (record = list + (counter & ~1) × 8). Frame record,
  16 bytes: PERMA offset, BLTSIZE, destination modulo, —, arm x/y (`+8`/`+9`, signed), head
  x/y (`+10` unsigned / `+11` signed), base x in bytes / y (`+12`/`+13`), hotspot x/y
  (`+14`/`+15`, stored +8 in `$15CC`/`$15CE`). A negative head/arm y means "not drawn".
- Composition order: (1) **base part** (legs and torso; 69 records, 34 distinct graphics,
  32×40 to 48×72) copied plainly; (2) **head**, 16×14 masked part, 9 variants at
  `$61BD0`, tables g/x/y at `$B408`/`$B41A`/`$B42C`; (3) **arm with gun**, 32×32 masked
  part, 26 variants at `$62030`, tables at `$B43E`/`$B472`/`$B4A6`; (4) **muzzle flash**,
  16×16 masked, 4 frames at `$65230` (offsets `$B4DA`) while the counter `$16A0` runs, at
  (`$16A2`, `$16A4`). Head and arm variant d = (state & 1) × 4 + aim, aim =
  (`$15DA` & 6) >> 1 (up, diagonal up, horizontal, diagonal down); `$1676` ≠ 0 forces a
  special arm pose (variants 8–25: crouching, torso-held gun…). Masked parts are
  cookie-cut (minterm `$CA`).
- Screen position: x = 5 + `$15D0` − camera_x + hotspot_x, y = `$15D4` − camera_y +
  hotspot_y − 16 (`$15D0`/`$15D4` = player world position). The level-3 handler `$10266`
  turns them into SPRxPOS/CTL with HSTART = x and VSTART = y − 25 (`$102BA`). **[verified]**
- Against the play field: the display window starts at H `$90` (copper `$10332`), the
  bitplanes at line `$1E`, and map pixel X shows at H `$90` + X − camera_x (DDFSTRT `$38`,
  BPLCON1 = 15 − (camera_x & 15), first tile column camera_x >> 4). So the composition's top
  left sits at map (x + `$15CC` − 139, y + `$15CE` − 71). **[verified arithmetic; inferred
  that sprite HSTART and DIW share the same horizontal origin (±1 px)]**
- `tools/player.py` → `build/sprites/robocop.png` (base parts), `robocop_parts.png` (heads,
  arms, flashes) and `robocop_composed.png` (the 69 records × 4 aims as the game composes
  them).

### Player control (`$AFF8`, `$ACEC`, `$BDEC`) **[verified: code and execution bench]**

- `main_loop` order per game frame: `$F878` (palette fades), `$F76C` (keys, panel digits),
  **`$AFF8` player_move**, `$FA7C`, `$9150`, `$9C06` activate_objects, `$BCCA`
  draw_background, `$8B32` special objects (lifts), **`$ACEC` update_player**, **`$B94A`
  draw_player**, `$F3CE`, **`$BDEC` read_joystick**, `$C3E4` update_objects, `$F080`,
  `$F900`, `$89BE` energy can, `$BDCE`; then `$B00` += 1, `$B02` += 3.
- **Input.** `read_joystick` (`$BDEC`) runs once per game frame, late in it, so the logic
  sees the controls one frame later: JOY1DAT & `$303` → table `$BE26` (up 1, down 2, left 4,
  right 8 in `$802E`), fire from CIA-A PRA bit 7 (`$10`); with no joystick input `$802E`
  takes the keyboard byte `$802D`, which the level-2 handler `$101DC` keeps from the key
  codes `$40–$50` through the table `$10254` (cursor keys as the joystick; Space, Backspace,
  Tab, Return, Esc, Del… fire; F1 and right Shift `$20`; bit 7 set on any press). Nothing is
  read while `$804D` is set (start of a level, death).
- **Map attributes** (low 7 bits of the map words): bit 1 wall, bits 0/2 floor (bit 2: up
  there is turned into fire, and fire into states 12/13), bit 3 enemy spawn points (scanned
  by `update_objects` at `$C546` around `$B1A`). The player's cell is A0 = `$37FF2` +
  ((x & `$FFF0`) >> 3) + (y >> 4) × `$140`: the map starts 7 cells to the right of x = 0,
  so map pixel x = player x − 112.
- **The map changes at run time** (bench write watch on `$38000–$3BFC0`): map objects copy
  the words of their current look into the map, a block of (`$110`+1) × (`$112`+1) words
  per object, every time `activate_objects` handles them (`$9C76`, the copy at `$9CF0`;
  a negative look pointer = destroyed, `$F98C`). Level 1: `level_init`'s activation pass
  over the whole map (`$886E`) changes 59 words (platform looks, tiles only); the wall
  right of the start (columns 4–6, rows 46–49, x 176–223) is such an object: RoboCop's
  down + fire punches break it (tiles and attributes 2 → 0), which is the way out of the
  start area. The end of level 1 (`$DF6E`, object type 32) also writes map words from its
  own table. **[verified]**
- **States** (`$15E2`; odd = facing left): 0/1 walk, 2/3 stand, 4/5 jump/fall, 6/7 down +
  fire (asked through `$1696` for the next frame; at step 4 an effect of type 8 ahead of
  him), 8/9 crouch (holds step 4, turns with left/right, rises backwards with up), 10/11
  forced by the palette fade-in (left/right only, no fire), 12/13 fire on a bit-2 floor,
  14/15 up only (tall hitbox), 16 death. x step per state at `$B3F6` (±3 walking and
  jumping); per state at `$B3AE` [−, `$15DF`, `$15E4` (animation backwards), hitbox offset
  from `$B32C`: 3 boxes x, y, w, h = (12, −54, 24, 54), (10, −38, 38, 38), (12, −72, 24, 72)].
- **Movement.** A step is refused when the cell beside the start cell (the row above while
  vy < 0, i.e. standing or rising) has bit 1, whatever the position inside the cell. In the
  air y += vy >> 2 and vy += 2 up to `$1F`; on the ground vy = −`$14` (a jump's start).
  Landing needs vy ≥ 0 and a floor bit in the start cell (y snapped to the cell's top),
  then `$1678` = 1 delays the next jump; with no floor RoboCop falls from vy = 0. The lift
  check `$BD72` comes first: 4 lifts (left, right, top, dx, flag index at `$B3C–$B63`,
  written by the special objects), standing on one when left ≤ x < right and top − 15 < y ≤
  top (not rising): y = top − 4, x += dx, flag `$167A + index` set. `$1698` > 0 reverses
  left/right (and flashes the palette every 8 frames).
- **Animation.** `$15DC` counts up to `$15E8` (= steps − 1 of the state, set by
  `draw_player`) and wraps, or backwards when `$15E4` is set; a new state restarts it.
  The frame record is the counter / 2. State 6 (right punch: steps − 1 = 15, list offset
  `$328`) owns 7 records but reads 8: its last one (steps 14–15) is state 7's first (`$398` =
  `$328` + 7 × 16), the left punch's first drawing, so the right punch faces left for its last
  two game frames (a data slip). **[verified: REA read_bytes `$B4E2`]**
- **Left and right drawings** (measured from the data with `tools/msxsprites.py`'s
  `mirror_place`; a buffer pixel shows at screen x = 13 + `$15D0` − camera_x + the record's hot
  spot x + its buffer x): most left drawings are the exact mirror of the right ones about an
  axis of each animation (at hot spot x + buffer x = walk 20, stand 19.5, jump 15.5, punch
  18.5, first crouch step 17.5); the others
  differ in a few pixels (the arm of the up and up-diagonal aims, the punch's step 6, the
  crouch's last two steps, the up-only pose) and are placed about other axes (crouch steps 1–2:
  19.5 and 23.5, matching the crouch hit box). The left arm table has the diagonals the other
  way round (left aim 1 is the right's aim 3). The frontal poses (states 10–13) are the same
  drawings on both sides. The left punch's last steps and the left crouch's first step share
  one drawing whose right counterparts differ. **[measured]**
- **Camera.** camera_x += (x − `$108` − camera_x) >> 4, within 0..`$8E0`; camera_y += (t −
  camera_y) >> 3 with t = y − `$70`, or −`$60` when that is above `$38`, within 0..`$B08`
  (the level's lowest camera, header +28). `$108` and `$70` are immediates patched by
  `level_init` (`$880E`, `$8816`).
- **Start of a level** (`$15CA` clear): RoboCop stands (state 2, aim 4), `$804D` locks the
  controls and `$1676` = 8; from game frame `$1C` the arm poses 8 + n/2 for n = 0..36
  (`$15CB`), sound `$303` in `$B2E` when n & `$B` = 0, then `$15CA` is set: 65 game frames.
  Meanwhile `$F878` fades the palette in over 31 frames (`$16CD`, `$16CE`) and forces state
  `$A` (`$F89D`, patched by `level_init`; `$B` on the third level).
- **Aim** (`update_player`): with a direction held, `$15DA` = table `$ACDC`[joystick & 15]
  every third frame (`$1679`). The fire: see *RoboCop's fire* below.
- **Level start values** (header at `$8664`, 40 bytes per level): +16/+18 player and camera
  x/y (level 1: 144, 800), +28 `$B08` (640), +30 timer.
- Execution bench (`tools/amigaemu.py game`) traces of the original against the MSX port
  (`tools/tracecmp.py`): identical over 160 and 340 game frames of scripted input (walking
  into walls, jumps, landings, crouching and turning, rising, down + fire, diagonal aims),
  600 frames of fire (shots, hits, flashes, lifts), and 1832 frames of the level-1 coverage
  scenario with teleports and god mode (`--drive`, openMSX `rc2_drive_trace`).

### RoboCop's fire (`$ACEC` after the aim, `$ACBC`, `$AF08`, `$AF90`, `$BE48`) **[verified: code and bench traces]**

- Fire latch `$D78`: one shot per press; weapon 1 (rapid fire) clears it every 4 frames. On a
  floor with bit 2 (but in states 14/15) fire asks for state 12/13 and spawns the punch's hit
  box (type 8) 50 px above him with D7 = whatever `$8B32` left (0, or `6 & $168C`); its
  lifetime is 6 frames from direction 0, fewer from 2/4, none from 6 on.
- No shot in states 6, 7, 12, 13, 16, 17 (`$330C0`). D7 = ((state & 1) × 4 + (aim & 6) / 2) × 2
  (8 → 0); offsets `$AE52`/`$AE62` + 7 by D7, `$AE72`/`$AE92` by state. Weapons 1–3 use ammo
  (`$8030`, 4 BCD digits, `$AC9A`); with none: `set_weapon(0)` and update_player returns at
  once (`bra.w`: the shots do not move that frame). Weapon 2 adds shots at D7 ± 4 (sound 0Bh),
  weapon 3 alternates (`$16D6`) that with D7 ± 2, which leaves D7 two directions back (its
  muzzle flash turns: a bug). Sound 4 (`$B31`); muzzle flash `$6B9A0 + 50h × D7` (402h).
- `set_weapon` (`$FD30`): weapon `$805C`, ammo from `$FD52` (0, 500, 300, 400), panel icon
  from `$FD5A` (3, 0, 2, 1). Weapons: 1 rapid fire, 2 three-way gun, 3 scatter gun.
- 8 shot/effect slots (`$ACBC`: type, direction & 14, x, y at `$15F4`/`$1614`/`$1634`/`$1654`,
  next slot `$1692` & 14), handlers at `$AECA + type`: 4 = shot `$AF08` (16 px per frame by
  `$AEE8`/`$AEF8`; hit test at the old position; an enemy hit is pushed by dx / 4 and the shot
  ends with explosion 1; then the wall test (bit 1) of the cell 8 px left of it ends it with
  explosion 1 (a second one after a hit); its BOB `$6BEA0 + $AF76[D7]`, gone off screen),
  8 = punch box `$AF90`. Player_move `$AFC4` spawns the punch of states 6/7 at step 4
  (`$AFAE`: +48 / −16 px, 48 up, D7 = 0).
- Hit test `$BE48`: 10 collision slots (5 enemies at `$BC4 + 4k` and the 5 map-object slots
  after them), box [x − 8, x + w) × [y − 8, y + h) from the type's record (`$BEAA`/`$BEAC`);
  a hit sets the flash byte (+42h) and takes a hit point (+41h, when ≥ 0; below 0 the +23h
  byte is cleared).
- `bob_part`/`bob_part2` (`$AC44`/`$AC56`) test the flash byte at +22h of the slot (the
  object is drawn white and the byte cleared by its last part); `update_objects` sets the
  high byte of `$16BA` before each handler (`$C42E`).

### Collisions and pickups (`$FA7C`, `$F900`) **[verified: code and bench traces]**

- RoboCop's box = position + the state's hitbox (`$168E`). `$FA7C`, right after
  player_move: (1) the first 6 enemy bullets (of 8) by type tables `$FA35` width (negative:
  never hits), `$FA4C` height, `$FA63` damage — unless `$16BC`'s high byte is set (the death
  sequence past 64 frames, a bug): bullet gone, energy − damage, PAL_SHOT flash and, when the
  bullet was less than 50 px right of him, the hit spark (`$16A0` = 7 at `$16A2`/`$16A4`;
  both get the y value, the x is overwritten: a bug); (2) the first enemy whose box (no −8
  margins) overlaps: touch byte +23h set, PAL_ENEMYHIT flash, energy − 1; (3) pickups 3..0 not
  rising, box (x − 8, y − 8, 15 × 15): the first is taken (message `$FC12`[type] = HUD
  messages 11–20, sound `$FC0B`[type / 4], the vehicle's vy + 6.0 when riding `$16D8`) and its
  effect runs through `$FBE0 + type` (one per frame).
- Pickup effects: 4 scatter gun (weapon 3), 8 rapid fire (1), 12 time − 1 minute (00:00 at
  the bottom), 16 time + 1 minute, 20 reversed controls (100h frames, or off), 24 shield
  (`$16AA` = 100h), 28 energy full (102h), 32 three-way gun (2), 36/40 nuke retrieved (energy
  + 20h, `$16C0` + 1, key code 21h in `$8032` so frame_keys shows the counts).
- `$F900`: 4 pickup slots (type `$D80 + k`, x `$D84`, y / vy longs `$D94` / `$DA4`): y += vy;
  rising above y 4 it bounces; vy + 0.2800h; on a solid cell at y + 15 (`$EF8E`) vy = 0 and it
  is drawn on the cell's top; BOB `$F964`[type] (402h). Type 40's graphics long is the code at
  `$F98C` (garbage).
- `draw_player` counts the hit spark `$16A0` down.

### Special objects (`$8B32`) **[verified: code and bench traces]**

- The level's list (header +8; level 1 `$8FC0`: 6 lifts then the vehicle; records in the code
  area, changed at run time: handler offset, x, y long, path index, path of y values). Each
  runs with D0 = x, D1 = y, the lifts' table entry `$B4C + (6 & $168C)` and the flag
  `$167A + n`. Right/top/dx of the 4 entries are cleared first.
- Lift (`$8DE6`): at its path point it takes the next one (or with RoboCop on it the previous
  for up, the next for down; the index stays within the path), then moves 2 px towards it;
  seen by the camera: sound 0Ah every 4th moving frame, RoboCop on it asks for state 10 (y =
  top − 4 in state 10), table entry (left, right = x + 30h, top, flag index), BOB `$4B68A`
  (48 × 24 at x + 22h, y − 12) unless `level_number` (`$8050`) = 2: the third level's lift is
  two parts, `$5397C` (32 × 29 at x + 20h, y − 52h) and `$53BC0` (32 × 16, 78 px lower)
  (`$8EB0`). In level 1 those addresses hold other SPERMA graphics (the level-3 data is not
  loaded), and the level-1 execution bench never draws them. **[verified: REA, bench]**
- Hostage (`obj45_update` `$ED1E`): legs `$4B31C` (32 × 20 at x + 8, y + 1Bh), then the body,
  one of 8 frames of 48 × 28 from `$498DC` (step `$348`) by game_frame & 1Eh through the table
  at `$EDE2` (0–7 then 7–0: a ping-pong, 2 game frames each) with dy from `$EE02` (frames 0–4:
  +4, frames 5–7: 0). **[verified: REA]**
- Vehicle (`$8B9E`, level 1, x 440h–4DFh): vx `$D7A`, vy long `$D7C`; ridden it carries
  RoboCop (x + 12h, y − 4, `$16D8`), rises, takes the joystick from player_move by patching
  its `moveq #$7F` immediate at `$B02B` to 0, and patches the state RoboCop shows (`$8C98`: 2
  or 3); alone it returns to x 480h. D7 at the end of `$8B32` reaches `update_player`.

### Level hazards (`$9150`, `level_tick_0` `$933A`) **[verified: code and bench traces]**

- The list's address is the header's long at +4 (level 1 `$9538`, 15 electric beams; the RAM
  image's `$915E` immediate holds level 2's `$95B2` until `level_init` patches it). Records
  inside the camera window run `$91B0 + 4 × level`.
- Level 1 beams: 16 frames on / 16 off (`$B00` & 10h). On: RoboCop in [x − 16, x) × [y, y +
  (rows + 2) × 16] loses 10h energy, PAL `$10074` flash, sound 22h (`$B30`); the beam's map
  cells are rewritten every frame (top `$93CA`[random & 6], body `$93D2`[(random + x + 2n) &
  3Eh]); off: E800h and D00h.

### Random word (`$BDCE`) **[verified]**

- Every game frame (last in main_loop): `$B32` rotated left by CIA-A timer A's low byte and
  XORed with timer B. The execution bench returns FFh for these reads (rotate 63, XOR FFFFh);
  the MSX test builds do the same.

### Palette effects (`$F878`, `$F8C4`, `$F80E`) **[verified: code; MSX traces of the fade and flashes]**

- The copper's colours (`$104A4` + 4n: COLOR01-31) have two writers. The fade (`$F878`: `$16CE`
  set = in, `$16CD` up to 1Fh, state 10 forced on every step; clear = out, `$16CD` down to 0)
  recomputes all 31 on every step from the level palette (the immediate at `$F8C6`, `$FFF6`
  for level 1) with each 4-bit component at most (`$16CD` >> 1) & 1Eh: eight steps of four
  frames, 0..Eh (a component F stays E after a fade in).
- A flash (`$F80E`, A0 = 15 colours) sets `$F826` = 4 and writes COLOR17-31, RoboCop's sprite
  colours, at once (`$F816`); `$F878` counts it down and at 0 writes COLOR17-31 from `$10016`
  (`$FFF6` + 32, level 1's), then idles at -1: RoboCop shows the tint for 5 game frames. The
  palettes: `$100B0` an enemy touches him, `$10092` an enemy shot, `$100CE` an electric
  barrier, `$100EC` energy refill, `$10074` a level-1 beam, `$1010A` reversed controls
  (`player_move` `$B030`: every 8th frame while `$1698` runs).
- The panel's colours are separate copper moves (`$103FA`): fades and flashes leave it alone.

### Hit spark (`$16A0`) **[verified: code (xrefs: only `$FA7C` and `draw_player`)]**

- `$FA7C` sets `$16A0` = 7 when an enemy bullet less than 50 px right of RoboCop hits him,
  with `$16A2` = `$16A4` = bullet y + 3Ch − his y clamped to 0..32h (the x written first is
  overwritten by the y).
- `draw_player` (`$BB78`), while `$16A0` ≠ 0: counts it down and cuts a 16 × 16 frame (mask +
  4 planes) from `$65230` + the word at `$B4DA` + (`$16A0` & 0Eh) into RoboCop's buffer at word
  `$16A2` >> 4, line `$16A4` (cookie-cut, so in his sprite colours, in front of him).

### Timer and death **[verified: code; the death sequence: code only]**

- The CIA-B interrupt (`$1015E`), once a second unless paused: `$804B` seconds − 1 (BCD), at
  the bottom `$804A` minutes − 1 and seconds 59; below 0:00 `$804C` is set (time out).
- `en_update` (`$89BE`): the shown energy below 0 sets `$16CC` (dying). main_loop: `$804C`
  with `$16CC` clear shows message `$865A` and sets `$16CC`; while `$16CC`: state 16 asked,
  controls locked, `$16BC` += 4; below 60h explosions around him (table `$81C2`), then the
  head icons (`$88DE`) and the fade out; lives `$8034` − 1 → `level_init` again, or game over.
- Level end (`$16D0`, set by type 32): score + 100h a frame (sound 26h every 4th), `$16C4`
  counts down, fade out, `$8050` + 1, the next level loads.
- `level_init` after a death runs `clear_game_vars` (`$FE96`): `$B00-$16EB` cleared, and also
  `$802D`, `$802E` (keyboard and joystick bytes), `$804D` (input lock), `$B02B` = 7Fh (the
  joystick mask), `$B16` = `$6FFA0`. **[verified: code; MSX death trace]**
- Game over (`$82A8`, `$8034` below 0): `show_picture` D0 = 8 (PIC9), 128 VBLs, `$12082`
  (the score as 8 characters (+5Bh) against the last of the **6** high-score entries (13h
  bytes each); when higher: a name is entered (`$12300`, `$1215C`) and the table sorted),
  `$11FD2` (continue offer); fire held: `$FFD8` (two lives) and `level_init` (the same level,
  score kept: a continue); else `$8098`: `$FEDA`, `clear_game_vars`, `$10884`, `$FFC4`,
  `level_init`. Details in section 5. **[verified: code]**

### Enemy types of level 1 **[verified: code; bench traces for 3, 28-31, 45]**

- 3 (`$CB6E`) walker2 with a torso; far from RoboCop it kneels every 16 steps. 12 (`$CEF8`)
  gunner behind cover, its gun by RoboCop's 32-px column, fires when (`$B02` & 2Eh) = 0. 13
  (`$CE72`) standing gunner, fires every 8th frame when in RoboCop's column. 23 (`$DD04`) rail
  crawler: finds a cell with attribute bit 5 near the camera and follows that rail at 4 px per
  frame. 25 (`$DB70`) the machine at the top (only with the camera at y < 20h): fires, drawn
  normal / black / white by frame; RoboCop touching it refills the energy. 26 (`$DAFA`)
  kneeling gunner. 27 (`$D9A4`) walker that stops to fire bursts with recoil and smoke. 32
  (`$DF6E`) the end of level 1 (10 more henchmen, then the destruction sequence `$DE68`).
  44 (`$EC22`) drops random pickups from the sky while RoboCop rides the vehicle.

### Enemy spawning (inside `update_objects`) **[verified]**

- Per-level lists (pointer in `$B0E`): `$9626`, `$97B0`, `$99E2`; 14-byte entries: x (`+0`),
  **type** (`+4`), flags (`+7`, bit 7 = spawn at the screen edge), respawn reload/counter.
- Types per level: level 1 = 4, 12, 23, 25, 26, 28, 32, 44, 45; level 2 = 1, 2, 4, 5, 6, 12,
  13, 14, 45, 49; level 3 = 21, 22, 33, 35, 36, 38–43, 47, 48, 50, 52. Types missing from the
  lists are spawned by other objects (shots, boss parts…).
- Per-level special objects (list in `$8B54`, dispatched by the table at `$8B92`):
  `$8DE6` (lifts, every level), `$8F02` (level 2), `$8B9E` (vehicle, level 1).

### Sprite catalogue **[verified: format; levels from code]**

- `make sprites`: Ghidra assembly exported with the REA CLI (`tools/rea_dump_asm.sh`) →
  `tools/bobcatalog.py` follows A2/D4 up to every call to `draw_bob` and its wrappers
  (`$AC44`, `$AC56`, `$AC6E`, `$AC84`), enumerates frames (adjustments and tables) and
  assigns the level from code (spawn lists, special objects, common PERMA/SPERMA).
- 76 references; unique frames: 22 common, 39 (level 1), 41 (level 2), 60 (level 3); mostly
  between 16×16 and 48×56, bosses up to 80×48. 17 references of "child" objects still have
  an inferred level. Sheets in `build/sprites/<level>_<routine>.png`.

### Per-level loading (`$86FA`) **[verified]**

| Level | Files | Before the level |
|---|---|---|
| 1 | DATAL1 (+ resident SPERMA/PERMA) | briefing and PIC1 |
| 2 | MADEX at `$45250` + DATAL2 | statistics, 2 bonus stages, PIC4 |
| 3 | DATAL3 (overwrites MADEX and SPERMA) | statistics, 2 bonus stages, PIC7 |

The level's sound file (`MU1`, with its player code) is loaded at `$18000` by the level start
(`$8614`, then `jmp $18000`); it holds sound effects only (see below).

### Music and sound effects (MU1 player) **[verified: REA listing of `$18000-$18B35` (level-1 image); `tools/rc2music.py --verify` runs that code in Unicorn and matches the model's Paula writes and player RAM on every tick of every tune of the five files (49986 ticks); the paths the data never takes (vibrato, 86h, 81h-83h in patterns, 83h in sequences, stop tune, the effect priority, effects over music) matched the same way on patched images and call scripts]**

- **Files.** TITM (title), MU1 (in-game sound effects), CH1 (a jingle), CMP (game completed)
  and HI1 (high-score entry) are loaded at `$18000` and carry the same player: `$18000-$18B35`
  is identical in the five files except the table operands and the tune count (`cmp.w #n` at
  `$181F2`/`$18270`); `rc2music.py` finds them by instruction signatures and checks the rest
  (SHA-1 with the operands masked). The samples, tables and tune data follow the code.
- **Entries** (7 × `bra.w`): `$18000` → `$18180` init, `$18004` → `$18194` stop all,
  `$18008`/`$1800C` → `$181E8` stop the channels of tune D0, `$18010` → `$1824E` start tune D0
  as music, `$18014` → `$1822C` as a sound effect, `$18018` → `$18316` play one tick. The game
  calls stop all from `$83EC`, `$8720`, `$FE14`, `$10894`, `$11CD0`, `$11FB4`; nothing calls
  `$18008`/`$1800C` (xrefs: `$1800C`'s only one is inside PERMA's graphics). Variables: `$1801C`/`$1801E` AUDxVOL masks of music/effect channels (FFFFh, never changed by
  the player), `$18020` OR of the channel flags (bits 15-14 kept; 0 = nothing to process),
  `$18022` last music started, `$18023` last effect started, `$1817C` DMA bits of this tick's
  key-ons, `$1817E` tick counter (cleared by start, never read).
- **Channel structure** (`$18024 + 56h × ch`): +0 flags (bit 0 grace, 1 arpeggio, 2 vibrato,
  3 slide, 4 envelope running, 5 fixed duration, 6 no transpose, 7 rest, 14 effect, 15 music),
  +2 sequence loop point, +6 sequence pointer, +0Ah pattern loop point, +0Eh pattern pointer,
  +12h repeat count, +13h transpose, +14h/+18h envelope start/pointer, +1Ch-+20h envelope
  rate, counter, ticks left, step, +21h-+23h grace, +24h-+26h slide, +28h-+33h arpeggio,
  +34h-+3Ah vibrato, +3Ch-+48h copy of the instrument record, +4Ah period, +4Ch volume,
  +4Fh/+50h note without/with the grace interval (the arpeggio adds its offsets to +50h),
  +51h fixed duration, +52h ticks to the next read, +54h DMA bit.
- **Layout** (MU1; the other files' addresses are in `build/music/*.json`): period table
  `$18B36-$18B95` (48 equal-tempered words, 1790 … 119; A5 = `$18B66` is index 0 = 447, indices
  −24…23); instrument records `$18B96` + 16n (35 slots; 31 in the other files); a zero word at
  `$18DC6` (`$18D86`) that every one-shot sample loops on; the sample list `$18DDE`
  (`$18D9E`); the 8SVX FORMs; then self-relative word lists (target = word address + word):
  arpeggios `$270CE`, envelopes `$270D6`, tunes `$27156` (8 bytes per tune), patterns `$272A6`;
  then the sequences and patterns.
- **Instrument record** (16 bytes, copied into the channel by command 90h): +0 base note
  (subtracted from the note before the period lookup), +2 sample start, +6 length in words
  (one-shot + repeat), +8 loop start (BODY + one-shot, or the zero word), +12 loop length in
  words (1 for a one-shot), +14 ≠ 0: the note is not transposed. Record 0 is not set by init:
  base 33 and a looped 22-byte waveform at `$18DC8` (`$18D88`; the bytes differ per file, TITM
  has two copies of an 11-sample two-cycle sine), used by MU1 effects 19, 27-33 and 38, CH1's
  jingle and HI1's effects 3 and 4.
- **Init** (`$18180`): `$1896E` walks the sample list (8-byte entries: `offset.l` from the entry
  to a `FORM 8SVX`, base note `.w`, no-transpose `.w`; 0 ends) and fills records 1…n. The IFF
  walker (`$189D2`, `$189F4`, `$18A52`, `$18A9A`) stores the VHDR data address in `$18AE6` and the
  BODY's in `$18B0E` (nested FORMs recursed, other chunks skipped); `$1898E` takes
  oneShotHiSamples and repeatHiSamples (rounded down to even) and the BODY address; the VHDR
  rate, octave count and volume are ignored. An entry that does not point at a FORM is not
  detected: its record repeats the previous sample (CH1 20-26, CMP 23-26, HI1 20-26). Then stop
  all.
- **Tunes and sequences.** Tune n (1…count) = 4 words at tunes + 8(n−1), one per channel,
  self-relative to a sequence; 0 = the channel is not touched. Sequence bytes: 00-7Fh pattern;
  80h end: jump to the loop point, else stop the channel (period 1, volume 0, flags 0); 81h loop
  point here; 82h t transpose (signed) of the next pattern; 83h n play the next pattern n times;
  84h-FFh ignored, without operand. After a pattern and its repeats the transpose returns to 0
  and the count to 1.
- **Patterns**: a note 00-7Fh followed by its duration in ticks (none in fixed mode); commands
  80h-90h through the jump table `$183D8` (`lea 14h(pc)` at `$183C2`: words relative to each
  entry, 91h-9Fh are 0 = ignored); A0h-FFh ignored. Any command byte cancels a pending slide.

  | Byte | Operands | Effect |
  |---|---|---|
  | 80 | — | end of pattern: to the pattern loop point if one was set, else the next sequence entry |
  | 81 | — | pattern loop point (+0Ah; only a new start clears it) |
  | 82, 83, 91-9F | — | nothing (an operand is *not* skipped) |
  | 84 / 85 | d / — | fixed duration d for the following notes and rests (bit 5) / durations per note |
  | 86 | — | +256 ticks on the next duration |
  | 87 | [d] | rest: volume 0, envelope and effects stopped (bit 7) for d ticks; no DMA stop |
  | 88 | i, n | the next note (if it is the next byte) slides into place from i semitones away in n ticks: step = (period(note + i) − period(note)) / n (DIVS, towards 0); the period starts at period(note) + n × step and moves by −step per tick from the note's first tick (bit 3) |
  | 89 / 8A | i, n / — | grace: each note starts i semitones away for n ticks (bit 0) / off |
  | 8B / 8C | d, i, s / — | vibrato: after d ticks, steps of (period(note + i) − period) / 2 / s per tick, turning on the s-th step and then every 2s (a triangle of about ± half the interval, centred one step off) (bit 2) / off — never used |
  | 8D / 8E | t / — | arpeggio table t: speed, length, semitone offsets; one entry every speed ticks from the note's first tick, cycling (bit 1) / off |
  | 8F | e | envelope e (used from the next note) |
  | 90 | n | instrument n (bit 6 from its +14) |

  89h, 8Bh and 8Dh clear bits 0-2 before setting theirs: grace, vibrato and arpeggio exclude
  each other (MU1 27, 28, 29 and 33 give 89h then 8Dh: only the arpeggio sounds); a slide
  takes priority over them on its note.
- **Channel processor** (`$1839A`, each tick for each channel with flags ≠ 0): +52h counts down;
  at 0 the pattern is read up to a note or a rest. A note: + transpose unless bit 6, + the
  grace interval; period = word at A5 + 2 × (sign-extended note − base); the slide or vibrato
  is set up, the arpeggio restarts, the envelope restarts at volume 0, the channel's DMA bit
  goes into `$1817C`, the duration into +52h. Then one effect (the first of slide, grace,
  arpeggio, vibrato), then the envelope.
- **Envelopes** (byte pairs; restarted by each note; the first segment acts on the note's first
  tick): n s with n = 01-7Fh: n ticks of volume + s (signed); n p with n = 80h-FFh: −n ticks
  (as a byte) of ±1 every |p| ticks (− when p < 0); 00 00: end, volume held; 00 r: hold until
  |r| ticks before the note's end (its +52h counter), then go on with r as the next segment's
  count, or end when the note is already shorter. No clamping: AUDxVOL = volume word & mask.
- **Paula output** (`$187E4`, every tick, all four channels): for the key-on channels DMACON
  off, INTREQ cleared, AUDxPER = 1, AUDxDAT = 0, then a wait for their audio interrupt requests
  and 3 raster lines; then per channel AUDxVOL = volume & `$1801C` (`$1801E` with flag bit 14),
  AUDxPER = period, AUDxLC/AUDxLEN = sample start/length on a key-on tick and loop
  start/length otherwise (Paula takes them when the buffer ends: the sample plays once, then
  its loop part or the zero word); DMACON on for the key-on channels.
- **Start** (`$1825C`, both entries): clears `$1817E`, sets CIA-A PRA bit 1 (LED off: the A500
  audio filter off), stops all for n = 0 or n > count; per channel of the tune: volume 0, loop
  points 0, transpose 0, count 1, flags 8000h (music) or 4000h (effect), the sequence read up
  to its first pattern, +52h = 1 (the first note is read by the next play call). Instrument,
  envelope and effect parameters stay from what the channel played before. The effect entry
  `$1822C` does nothing when channel 3 is busy (`$18126` ≠ 0) and n < `$18023`, whichever
  channels the new effect uses. An effect takes over its channels' structures: music there
  stays silent afterwards.
- **Tick rate.** Durations count calls of the play routine. In the game (MU1) and for TITM, CH1
  and HI1 the level-3 VBL handler calls it through the patchable `jsr` at `$1031E` (long
  `$10320`: `$18018`, or `$1032E` = `rts`) on 5 of every 6 VBLs (counter `$10330`): **50
  ticks/s** on the NTSC machine this release targets (41.7 on PAL), the tempo of a PAL machine
  calling it every VBL. CMP is played by the
  game-completed loop `$11C54` (from `$86DE`) on 4 of 5 passes (counter `$11C52`) of a loop that
  waits for raster line C0h, for 1800h passes or until fire: 48 ticks/s on NTSC **[inferred:
  one pass per frame; the skipped pass takes about 420 cycles, a line 455]**. An MSX at 60 Hz
  must skip every sixth VBL like the Amiga.
- **Where each file plays**: TITM is loaded by `$11A20` (`$11B4C`) and its tune 1 started by
  `$10884`, which `$8064` calls after `$11A20` (`$80A2`); MU1 by the level start (`$8614`); CH1
  tune 1 by `$11F60`, a handler of the typed-key sequence matcher `$11EDA`; CMP by `$11C54`; HI1
  tune 1 by `$12300`, its name entry starting effects 4 (`$121F8`) and 3 (`$1228A`). HI1 tune 2
  is not started by any call site of `$18010`/`$18014` **[inferred: from those xrefs only]**.
- **Sound requests.** `frame_keys` (`$F76C`) passes `$B31`, `$B30` … `$B2C` (in that order, each
  cleared) to the effect entry once per game frame. Writers (number, site): `$B2C` 14h
  `$AFC8`; `$B2D` 0Ah lift `$8E72`, 0Ch `$8FAC`/`$A06E`, 0Eh `$9FA8`/`$D540`, 14h `$A138`, 19h
  `$A0F0`, 25h `$E824`/`$E8F4`, 28h `$9F08`/`$E9D0`/`$EB4E`, `$C336`[`$B00` & 7] (15h-19h)
  `$C32E`, `$F37C`[D5] `$F38E`, pickups `$FC0B`[type / 4] (10h, 1Bh-21h) `$FBC6`; `$B2E` 10h
  `$9208`, 12h `$D124`, 19h `$D298`, 1Ah `$91C4`, 23h `$E1DE`/`$EE70`, 24h `$E0AC`, word 0303h
  `$B380` (3 in `$B2E` and `$B2F` at the level start); `$B2F` 13h `$ECCA`, 25h `$E400`, 29h
  vehicle `$8C1C`, `$F5D2`[D6] `$F604`; `$B30` 6 `$B0F2`, 9 `$ED9A`, 22h beams `$937A`/`$9474`,
  27h `$D5A4`, 2Ah `$C314`/`$E092`; `$B31` 4 shot `$ADE0`/`$AE12`, 0Bh extra shots `$AE30`, 26h
  level-end score `$8198`.
- **Contents** (ticks at 50/s; loop = start tick + length, from where the audible output
  repeats): TITM 1 music, 4 channels, 5184-tick loop from 0 (103.7 s). MU1 42 effects of one
  pattern on one channel (42: channels 2 and 3), 2-57 ticks (channel/ticks: 1 2/26, 2 2/27, 3
  1/10, 4 0/13, 5 3/12, 6 1/10, 7 3/28, 8 3/12, 9 2/30, 10 1/6, 11 0/12, 12 1/2, 13 0/15, 14 0/20,
  15 1/17, 16 2/47, 17 1/10, 18 2/9, 19 2/36, 20 0/22, 21-24 3/20, 25 1/18, 26 1/24, 27 2/19, 28
  2/19, 29 2/5, 30 2/22, 31 2/12, 32 2/14, 33 2/14, 34 3/57, 35 2/2, 36 2/3, 37 3/9, 38 1/3, 39
  2/22, 40 1/32, 41 1/5, 42 2+3/48). CH1 1 jingle, 4 channels, 582 ticks, ends. CMP 1 music, 4
  channels, 192 + 4608-tick loop. HI1 1 music, 48 + 1920-tick loop (channel 3 plays only the
  48-tick intro, so it is free for the name-entry effects, which use channel 3); 2 music,
  5760-tick loop from 0; 3 and 4 effects on channel 3, 6 and 14 ticks.
- **Samples** (in the JSON: start, length, loop, VHDR rate, NAME/ANNO, peak/RMS/zero crossings
  and an autocorrelation pitch estimate **[inferred]**): MU1 19 samples, TITM 13, CH1 4, CMP 7,
  HI1 4 (plus record 0's waveform); all one-shot except MU1 "WHITE" (3956 bytes of looped
  noise) and TITM "FILTER-WAH" (12816 + 8756-byte loop). The NAME chunks (Audio Master II)
  give BDRM, SNARE, CLOSEDHAT, TOM, TOM1, TIMPANI, PIZZICATO, BRASS4, ORCH1, FILTER-WAH, ba1,
  CLUB, SNAZ, WHITE, barrel.
- **Data quirks.** A note at table index 24 (one past the table) reads `$18B96`, record 0's base
  note 21h: AUDxPER = 33 (TITM notes 48/base 24 and 60/base 36, HI1 tune 1 note 36/base 12, HI1
  tune 2 through its arpeggio); that is below Paula's DMA limit (~124), so the hardware repeats
  data words — the intent was presumably the semitone above index 23 (≈ 112) **[inferred]**.
  MU1 5 slides for 48 ticks on a 12-tick note (cut). No file uses 81h, 82h or 83h inside
  patterns, 83h in sequences, 86h, 8Bh or 8Ch.
- **Model and output.** `tools/rc2music.py` → `build/music/<NAME>.json`: per tune the channels,
  the end tick or the loop (plus the tick from which the whole player state repeats), the
  sequence loop jumps per channel, the key-ons [tick, channel, instrument, note, table index,
  period], per-channel runs [ticks, AUDxPER, effective volume 0-64, instrument], the sequences
  and a listing of each pattern; per file the instrument records, unique samples, envelopes,
  arpeggios and the period table. `--trace NAME:N` prints one tune tick by tick.

## 5. Front end: title, text screens, high scores

Read with REA/Ghidra in `level1_full.bin`. Ghidra follows neither the BRA table `$11746` nor
the particle routines at `$10E46`–`$10EF7` and `$10F40`–`$10FC7`; those were exported with the
REA CLI and extra function seeds (same engine, project seeds plus the targets).
`tools/rc2front.py` decodes the data and models the effects → `build/front/`: `scripts.json`,
`hiscores.json`, `font.json`, `font.png`, `font_strokes.png`, `title.json` and a render of
every screen in `screens/`.

### Sequence **[verified: code]**

- **Boot** (`game_boot` `$11A20`), silent and without waits: each picture stays while the next
  files load. DATAE (4 planes, copper `$12352`) while RB1 and OAS load; OAS while TPIC loads;
  TPIC (HAM6) while TITM, PERMA and SPERMA load; then a blank copper (`$1049E`) and the
  buffers cleared. The expansion-RAM file cache (`$1195E` stores, `$11932` restores; TITM,
  SPERMA, MU1, PIC\*, HI1) is off: only the code that the `BRA.B` at `$8078` skips sets its
  magic `$12343210` in `$803A` **[inferred: a cracked `BNE`]**.
- **`$8098`** (also after every game): `$FEDA` (palette black, buffers cleared, CIA set-up,
  random seed, game copper `$10332` through `$FE14`), `clear_game_vars`, title loop `$10884`,
  `$FFC4` (level 0, `$805E` = 0, score 0, `init_lives`), `level_init`.
- **Title loop** `$10884`, one pass per frame (raster line `$F0`): player init, stop all,
  **tune 1** of the file at `$18000`; both buffers cleared; palette `$109A8`. Fire at any
  moment (`read_joystick` bit 4: joystick or keyboard fire keys) returns and starts a game;
  there is no demo. Nothing reloads TITM: after a game the title plays tune 1 of the resident
  file, MU1 (its effect 1), HI1 or CMP **[verified: code; audible result inferred]**.
  1. Logo fly-in (`$106E2`, 77 frames, double-buffered): *Title logo* below.
  2. Attract script `$11237` on the front buffer, one element per frame, plus the cheat matcher
     `$11EDA` and `$B00` + 1 (cursor blink): credits typed (115 frames), wait 192, diagonal
     wipe 38, the high-score table written by the particle writer (373) and unwritten (373),
     `FF 05`: a 1094-frame cycle, 18 s at 60 Hz (`screens/attract_*.png`).
- **New game**: `level_init` stops the music; `load_level0`: level-1 briefing `$11108` through
  the curtain entry, `$FE14`, PIC1, MU1 (`$8614`: init only, no tune), SPERMA and DATAL1 when
  not resident; `$8060` = `$C716` (*Gun calibration*).
- **Between levels** (`load_level1` `$8582` / `load_level2` `$8524`): statistics, Brainstorm
  (`$8382` D0 = 2 / 4: PIC3 / PIC5), shooting range (`$8420` D0 = 1 / 5: PIC2 / PIC6), briefing
  `$110F0` / `$110B4`, PIC4 / PIC7, MU1, MADEX + DATAL2 / DATAL3.
- **After level 3** (`level_load_3` `$86DE`): script `$112C5`, `$11C54` (PICF and CMP tune 1,
  see *Music*; 1801h passes or fire), `high_score_entry`, `$8090` (stack reset, title).
- **Pictures** (`show_picture` `$11E06`): `$FE14` (music stopped) and `$FEDA`, PIC('1'+D0)
  loaded at `$6FFA0`, shown at once with its own palette, for 251 VBLs or until fire.

### Text screens **[verified: code]**

- Entries: `$10768` (A0 = script; `$FE14`: music stopped, palette black; front buffer
  cleared), `$1079A` (curtain: 16 frames, each clearing a 16-px column from both sides; music
  kept), `$10772` (`$10768` after its `$FE14`), `$10762` (`$10768`, then `$FE14`). Then palette
  `$109A8` at fade level `$1F`, text origin `$109A2` = front buffer + 2 + `$2600`, particles
  cleared, `$B04` = 50.
- Loop `$1084C`: one script element per VBL (`$116CA`); ends when (fire or `$16D1` set) and 50
  VBLs have passed. No fade out: the caller's `$FE14` or `show_picture` blacks the screen.
- Display: game copper `$10332`, 4 interleaved planes (152 bytes per line), buffer lines 0–175
  on display lines `$1E`–`$CD`, 304 px fetched (x 15–302 visible with BPLCON1 = 0); the status
  panel stays below (its `BPLCON0` move `$10494` is never written). The VBL handler applies the
  line offset `$B28` and BPLCON1 `$B0C`, which `main_loop` sets every frame and only
  `clear_game_vars` clears: the screens between levels and after a game over keep the last
  frame's fine scroll **[inferred: not observed]**.
- Palette `$109A8`, COLOR01–15 (components at most E after `$F8C4`): 070 050 020 147 347 AAB
  35A 46A 67A BBB 78A 8AD 58D 79C 9AB; COLOR16–31 read the stroke glyph 'A' that follows.
- Text grid: 8 × 8 cells, column c at bitplane x 16 + 8c, row r (signed) at line 67 + 8r;
  glyphs written into planes 0–2 (colour 1 with a colour-4 shadow).
- Cursor (`$118B4`): lines 6–7 of the next cell, plane 0 `$7F`, plane 1 `$63`. It is erased (a
  space) at the start of every call and drawn after a character, a position, a wait or the
  halt when bit 2 of `$B01` is set. `$B00` moves only in `main_loop` and the title loop: in the
  other screens the cursor is always on or always off.

### Script format (`$116CA`, pointer `$10F2C`) **[verified: code]**

| Bytes | Handler | Effect | Calls |
|---|---|---|---|
| `00 x y` | — | cursor to column x (`$16C9`), row y signed (`$16CA` = 8y) | 1 |
| `01`–`7F` | `$118D6` | one character, cursor + 1 | 1 |
| `80`–`FF` 0 | `$1171E` | halt, cursor blinking (the prefix's value is ignored) | — |
| `80`–`FF` 1 | `$11768` | diagonal wipe: call k (0–36) blanks column k − 4 + r of rows r = 0–12 (`$16B2`), then cursor (0, 0) | 38 |
| `80`–`FF` 2 n | `$117A8` | wait | max(1, 4n) |
| `80`–`FF` 3 | `$11864` | particle writer until its 24 particles are idle at the end of the text (`$16C6` = 24) | per text |
| `80`–`FF` 4 p | `$117C6` | particle set-up p / 12 of `$11804`: colour set → `$10F28`, text → `$10F30`, origin → `$10F34`/`$10F36`; particles `$DB4`–`$15C3` and cursor cleared | 1 |
| `80`–`FF` 5 | `$118A2` | script = `$11237` | 1 |
| `80`–`FF` 6 | `$1175E` | halt (`rts`), no cursor | — |
| `80`–`FF` 7 | `$11762` | `$16D1` set (done), halt | — |

- Characters (`$118D6`; the panel's `$10620` is the same): `' '` → glyph 41, codes ≥ `'@'` →
  code − `'A'`, others → code − `$16`. So `'0'`–`'9'` and `'['`–`'d'` are digits, `'e'`–`'l'`
  (and `':'`–`'?'`) are `. , ? " !`, blank, `©`, `%`; `'@'` reads the `$FF` bytes before the
  font (a colour-7 block). Numbers come from `$11DC6`: D2 → BCD at `$11DFA` (subtracting
  `$11D30`'s powers of ten) → 8 characters `'['` + digit at A4, leading zeros as spaces.
- Scripts (calls = VBLs without fire; each screen lasts max(calls + 1, 50) VBLs, + 16 for the
  curtain):

| Script | Entered from | Text (`/` = new position) | Calls |
|---|---|---|---|
| `$11237` | title loop | TM AND © ORION PICTURES CORP / ALL RIGHTS RESERVED / WRITTEN BY SPECIAL FX / FOR OCEAN SOFTWARE LTD. / PRESS FIRE TO START; then the high scores (particles 0, 1) | 1093 + 1 |
| `$11108` | `load_level0`, `restart_level0` (lives = 2) | particles 3; NEGOTIATE THE RIVER COMPLEX / COLLECT TEN NUKE CAPSULES / THEN DESTROY THE DRUGS LAB / RESCUE ALL HOSTAGES / FOR AN EXTRA LIFE. | 485 |
| `$110F0` | `load_level1` | particles 4; ARREST CAIN | 393 |
| `$110B4` | `load_level2` | particles 5; BATTLE YOUR WAY TO THE ROOF TO / CONFRONT CAIN. | 411 |
| `$1132F` | `show_level_stats` | LEVEL STATISTICS. / HENCHMEN OBLITERATED n / NUKES COLLECTED n / HOSTAGES RESCUED n (fields `$1135A`, `$11379`, `$11398`) | 361 |
| `$114AA` | `$8382` | BRAINSTORM. / DESTROY ALL RED CHIPS ON THE BOARD / COMPLETE 4 TO REGAIN MEMORY. / AND EARN A GAME CREDIT. | 292 |
| `$1162F` | `$8382` result 0 | WELL DONE MEMORY RESTORED. / GAME CREDIT AWARDED | 143 |
| `$11667` | `$8382` result 1 | MEMORY MALFUNCTION. / ATTEMPT TERMINATED. | 136 |
| `$11698` | `$8382` result 2, `$8420` time out | OUT OF TIME. / ATTEMPT TERMINATED. | 129 |
| `$1142D` | `$8420` | SHOOTING RANGE. / YOU MUST SHOOT ARMED TARGETS / YOUR GUN CALIBRATION WILL BE TESTED / WARNING ACCURACY IS ESSENTIAL. | 304 |
| `$113A5` | `$8420` | GUN CALIBRATION. / CORRECT TARGETS n / DUMMY TARGETS n / YOU ARE RATED AS POOR. FAIR. GOOD. SHARP. (fields `$113CA`, `$113E4`, `$11400`) | 347 |
| `$112C5` | `level_load_3` | particles 7; YOU HAVE DEFEATED ROBOCOP 2, / AND THE SUPPLY OF NUKE HAS BEEN / STAMPED OUT. | 341 |
| `$1151B` | cheat `$11F60` | CHEAT MODE NOW ACTIVE. / USE F9 TO TOP UP ENERGY. / USE F10 TO SKIP MAIN LEVELS. / PRESS FIRE BUTTON TO START | 232 |
| `$11590` | `$11FD2` | YOU HAVE A GAME CREDIT. / PRESS FIRE TO CONTINUE. | 304 |
| `$115C9` | `$1215C` | YOU HAVE A HIGH SCORE. / ENTER NAME ON THE KEYBOARD / USE BACKSPACE TO DELETE / RETURN TO FINISH. | 92 |
| `$116C2` | `disk_prompt` `$11BD2` | particles 6, then `FF 06` (until fire) | 218 |

  `disk_prompt` (D0 → the digit at `$11211`) has no caller in the image **[inferred: the
  crack's loader does not prompt]**; particle text 2 "LEVEL COMPLEATE" is never set up.

### Particle writer (commands 3 and 4) **[verified: code; modelled by `rc2front.py`]**

- 24 particles of 86 bytes at `$DB4`, all updated once per call (`$11870` → `$10FC8`). A free
  one reads the text at `$10F30` (`$10F40`): `0D` new line (x = 0, y + 16), space x + 16,
  `FE i v` byte `$10F38` + i = v (nothing reads it), `FF 00` end (counted in `$16C6`; the
  pointer stays), `FF n` colour set `$10F04` + 6(n − 1); any other byte is glyph code − `'A'`
  at (x, y) (`$10E46`), then x + 16.
- Stroke font `$109C6`: 36 glyphs ('A'–'Z', then `'['`–`'d'` = 0–9), each 16 (x, y) byte
  points on a 14 × 14 grid: a 15-segment polyline. A segment (`$10E84`) moves in 16.16 steps
  halved until both are below one pixel: 2^k frames with 2^k > max(|dx|, |dy|), k ≥ 1. After
  the last point the particle waits 10 frames, then takes the next character.
- Plot (`$11062`): the pixel gets the colour in all 4 planes at bitplane (16 + origin x + px,
  64 + origin y + py), skipped when origin y + py ≥ 160. Per frame: head colour at the current
  point, middle colour 5 points back, final colour 10 points back (history at +`$1E`).
- Colour sets (`$10EF8`, head / final / middle): A 7/4/8 (every set-up but 1), B 8/0/7 (erases
  what A drew), `FF 1`–`6`: 1/2/3, 4/6/5, 7/9/8, 10/12/11, 1/6/8, 0/0/0 (unused).
- Set-ups (`$11804`: colour set, text, origin x, y): 0 high-score table (A; 16, 0), 1 the same
  with B, 2 "LEVEL COMPLEATE" (32, −48), 3 "THE RIVER ROUGE / COMPLEX" (0, −48), 4 "TOKUGAWA
  BREWERY" (16, −24), 5 "CIVIC CENTRUM" (48, −48), 6 "PLEASE INSERT / DISK n / AND PRESS THE /
  FIRE BUTTON" (32, −24), 7 "WELL DONE" (32, −24). Durations: 373, 373, 106, 108, 124, 108,
  217, 106 calls.

### Fonts **[verified]**

- Bitmap `$65DB0` (PERMA): 44 glyphs × 24 bytes (planes 0, 1, 2 × 8 lines, MSB left): 0–25
  A–Z, 26–35 0–9, 36–40 `. , ? " !`, 41 blank, 42 `©`, 43 `%`; strokes in colour 1, shadow
  in colour 4 (`font.png`).
- Stroke `$109C6`: above (`font_strokes.png`).

### Title logo (`$106E2`, `$10720`) **[verified: code; positions computed by `rc2front.py`]**

- RB1 (`$12588`) holds the 8 letters, BOBs with masks, 48 px wide (R, C, 2: 51 lines; the O, B,
  O, O, P: 38 lines, 6 lower). Table `$10682`: x/y offsets, x0 and BLTSIZE, graphics (R
  `$13BCC`, O `$12588`, B `$129FC`, O `$12E70`, C `$141C6`, O `$132E4`, P `$13758`, 2 `$147C0`).
- Countdown t at `$1067A` (16.16, from 136.0): each frame t −= t / 16 (`asr.l #4`; 1.0 when
  that is 0); letter at x0 − ((280 − x0) · t >> 5), y = t + y offset (`draw_bob`: bitplane x =
  x − 128): the letters rise from 136 lines below and slide in from beyond both edges (their
  distance to bitplane x 152 scales with 1 + t / 32), slowing down. The loop ends at
  t = 0, which is not drawn: 77 frames; the last image (t = 1) has the letters at bitplane x 15,
  53, 89, 124, 158, 193, 230, 267 and y 1 (R, C, 2) or 7.
- Each frame clears the rectangles drawn two frames earlier in the back buffer (`draw_bob`'s
  BLTCON0 immediate `$AC16` patched from `$0FCA` to `$0100`) and ORs a "TM" (`$1254E`, 5 lines)
  into plane 2 of the front buffer at byte `$1F50` (x 288–303, lines 52–56). Palette `$109A8`.

### Level statistics and bonus stages **[verified: code]**

- `show_level_stats` (`$85D8`): `$16C2` henchmen obliterated (+1 per enemy killed, `$C422`),
  `$16C0` nukes collected (+1 per nuke pickup, `$FD20`), `$16BE` hostages rescued (+1 at
  `$ECC0`; the 10th gives a life) → `$11DC6` → script `$1132F`. No score is added here (the
  level bonus is the in-game count of `$16D0`, *Timer and death*). The counters lie in
  `$B00`–`$16EB`, which every `level_init` clears (also after a death or a continue): the
  screen counts since the last (re)start.
- Brainstorm (`$8382`): intro, picture, PUZL (level 1 → 2: the disk-1 copy decrunched by
  `$124A6` from `$17080` to `$17100`; level 2 → 3: disk 2's at `$17100`), `jsr $17100` → D0 =
  0 solved (`$805E` + 1: a continue), 1 failed, 2 out of time; result text from `$840A`.
- Shooting range (`$8420`): intro, picture, FRNG (decrunched from `$1E980` to `$1EA00`; `$1880`
  and `$3FF0` patched at `$1FB34`/`$1FB38`), `jsr $1EA00` → D0 dummy targets, D1 correct
  targets. Time out (`$804C`): `$8060` = `$C72E` and `$11698`. Otherwise rating = max(0, min(3,
  (6 × correct − dummy − 50 − 12 × [timer minutes = 0]) div 14)): POOR, FAIR, GOOD, SHARP
  (`$1140D`), `$8060` = `$C716` + 24 − 8 × rating.
- **Gun calibration = enemy hit points**: a spawned enemy (`$C512`, `$C706`) gets slot byte
  +`$21` (= +41h from `$BC4` in *Hit test*: one off per hit while ≥ 0, so n + 1 hits kill)
  from `$8060`'s table, indexed by its class, the word at `$BEB4` + 16 × type (0–7): SHARP
  `$C716` 0 1 1 2 3 3 4 99, GOOD `$C71E` 1 2 2 3 3 4 4 99, FAIR `$C726` 2 3 3 3 4 4 4 99, POOR
  and time out `$C72E` 3 3 3 4 4 4 5 99. Level 1 uses SHARP.

### Game over, high scores and continues **[verified: code]**

- `main_loop` `$82A8`: PIC9 (251 VBLs or fire), 128 more VBLs, `high_score_entry` `$12082`,
  `$11FD2`; fire held → `init_lives` and `level_init` (same level, score kept), else `$8098`.
- Table `$11FF6` (it is particle text 0 of the attract script; in the code area, so kept in
  RAM only **[inferred]**): `"   TODAYS BEST "`, CR, then **6** entries of 19 bytes from
  `$12006` (`' '`, name of 9, `' '`, score of 7 digits `'['`–`'d'`, CR) and `FF 00` at
  `$12078`. Defaults: IAN 100000, KAREN 90000, COLIN 50000, KEITH 45000, ANDY 9000, PAUL 7500
  (`hiscores.json`).
- `high_score_entry`: the score `$8046` as 8 digit characters at `$1207A`; its low 7 against
  entry 6 (`$12070`), only a greater score goes on: entry 6 = the score and 9 spaces,
  `$12300` (HI1 restored or loaded, copper `$10356` meanwhile; tune 1), `$1215C`, fade out,
  24 bubble passes (18 bytes swapped when the upper score is lower: ties keep the older entry
  above). The `$FE14` of `$1215C`'s text screen stops all before the tune's first tick: only
  the effects are heard **[verified: code; audible result inferred]**.
- Name entry `$1215C`: script `$115C9`, then the field `$12066` (index `$15D0`) drawn by
  `$12218` at bitplane x 128 + 8i, lines 80–87 (no text origin); `'g'` (glyph `?`) marks the
  next position, first under the 2nd character. `$1225C` takes one key per press (latch
  `$15EF`), raw codes `$122C8` → characters `$12296`: A–Z, 0–9 (main row and keypad, stored as
  `'['`–`'d'`), Space; Backspace (`$41`) deletes the last one; Return (`$44`) or `$2B` ends;
  after 9 characters others are ignored. Every key starts effect 3; Return effect 4, the
  palette black and both buffers cleared.
- Continues `$805E`: 0 at a new game, + 1 per solved Brainstorm. `$11FD2`: − 1; if still ≥ 0,
  MU1 init and script `$11590`, and fire during it (or held when it ends) continues; else
  `$802E` cleared and the title. A continue restarts the level with 2 lives; on level 1,
  `restart_level0` shows the briefing and PIC1 again.

### Cheat mode **[verified: code]**

- `$11EDA` (title loop): sequences at `$11F36` (8 bytes each: sequence = progress, length, raw
  key codes; handler; `FFFFFFFF` ends); the only one is S E R I A L I N T E R F A C E, a wrong
  key restarts it. Handler `$11F60`: `$804F` set, CH1 tune 1, script `$1151B` (front buffer
  cleared); the title loop then goes on with that halted script until fire. In play
  (`main_loop` `$8144`): F10 (`$59`) sets `$16D0` (level complete), F9 (`$58`) energy `$102`.

## 6. Texts and content

Strings in the main code describe levels and objectives: *The River Rouge Complex*,
*Tokugawa Brewery*, *Civic Centrum*; collect 10 Nuke capsules and destroy the drugs lab;
rescue hostages; reach the roof and confront Cain. Bonus stages: *Gun Calibration*
(shooting range) and *Brainstorm* (chip puzzle). Items: *scatter gun*, *rapid fire*,
*three way gun*, *time gain/lost*, *reverse control*. There is a cheat mode (F keys for
energy and level skip; section 5).

## 7. Tools

| Tool | Purpose | Dependency |
|---|---|---|
| `tools/rc2files.py` | lists/extracts/decrunches the disk files | stdlib |
| `tools/pp20.py` | PowerPacker decruncher | stdlib |
| `tools/planar.py` | bitplanes (sequential/interleaved, HAM6) → PNG | stdlib |
| `tools/bobs.py` | BOB frames → PNG | stdlib |
| `tools/copper.py` | copper list decoder | stdlib |
| `tools/m68kdis.py` | quick listing (complements Ghidra) | Capstone |
| `tools/ghidra_seeds.py` | REA/Ghidra seeds from the jump tables | stdlib |
| `tools/ramimage.py` | per-level RAM images to open in REA | stdlib |
| `tools/rea_dump_asm.sh` | bulk Ghidra assembly export through the REA CLI | REA |
| `tools/bobcatalog.py` | BOB catalogue and sheets from the exported assembly | stdlib |
| `tools/player.py` | RoboCop frames from the animation table | stdlib |
| `tools/amigaemu.py` | execution bench: `game` runs a level from its RAM image with a joystick script and traces the game variables per game frame (reference for the port's logic) | Unicorn |
| `tools/tracecmp.py` | compares a bench trace with the MSX port's (`tools/openmsx_rc2.tcl` rc2_trace) | stdlib |
| `tools/rc2music.py` | model of the music/sound-effect player: tunes, instruments, samples and per-tick Paula state to `build/music/*.json`; `--verify` against the original code | stdlib (Unicorn for `--verify`) |
| `tools/rc2front.py` | front end from the RAM image: text scripts and particle texts, high-score table, bitmap and stroke fonts, logo fly-in, renders of every screen → `build/front/` | stdlib |

Code analysis: **REA + Ghidra** (project rule, see `CLAUDE.md`). Targets to open in REA:
`build/ram/level1_full.bin` (whole level-1 RAM, entry `$0` with `JMP $8000`) or
`build/ram/level1_8000.bin`. Entries reached only through jump tables are seeded into
Ghidra by `analysis/ghidra_seeds.tsv` (generated by `tools/ghidra_seeds.py` from
`analysis/main_8000.sym`).
