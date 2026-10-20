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
| TITM, MU1, CH1, CMP, HI1 | `$18000` | — | music with 8SVX instruments (player code inside) **[inferred]** |
| PERMA | `$58850` | 96080 | resident graphics (player, common BOBs, HUD) **[verified for the player]** |
| SPERMA | `$4B68A` | 53700 | resident BOBs with masks **[verified]** |
| RB1 | `$12588` | 10290 | graphics with masks (48 px); only referenced by the loader **[inferred]** |
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
  every third frame (`$1679`). Fire (not ported yet): latch `$D78` (cleared every 4 frames
  with the rapid-fire weapon), no shot in states 6, 7, 12, 13, 16, 17 (`$330C0`), offsets per
  facing and aim at `$AE52`/`$AE62` plus per state at `$AE72`/`$AE92`, ammo (`$AC9A`,
  weapon 0 when empty), extra shots for weapons 2 and 3; shots and effects are 8 slots
  (type, direction, x, y at `$15F4`/`$1614`/`$1634`/`$1654`, next slot `$1692`, `$ACBC`)
  run by the handlers dispatched at `$AEBE`.
- **Level start values** (header at `$8664`, 40 bytes per level): +16/+18 player and camera
  x/y (level 1: 144, 800), +28 `$B08` (640), +30 timer.
- Execution bench (`tools/amigaemu.py game`) traces of the original against the MSX port
  (`tools/tracecmp.py`): identical over 160 and 340 game frames of scripted input (walking
  into walls, jumps, landings, crouching and turning, rising, down + fire, diagonal aims).

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

The level music (`MU1`, with its player code) is loaded at `$18000`.

## 5. Texts and content

Strings in the main code describe levels and objectives: *The River Rouge Complex*,
*Tokugawa Brewery*, *Civic Centrum*; collect 10 Nuke capsules and destroy the drugs lab;
rescue hostages; reach the roof and confront Cain. Bonus stages: *Gun Calibration*
(shooting range) and *Brainstorm* (chip puzzle). Items: *scatter gun*, *rapid fire*,
*three way gun*, *time gain/lost*, *reverse control*. There is a cheat mode (F keys for
energy and level skip).

## 6. Tools

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

Code analysis: **REA + Ghidra** (project rule, see `CLAUDE.md`). Targets to open in REA:
`build/ram/level1_full.bin` (whole level-1 RAM, entry `$0` with `JMP $8000`) or
`build/ram/level1_8000.bin`. Entries reached only through jump tables are seeded into
Ghidra by `analysis/ghidra_seeds.tsv` (generated by `tools/ghidra_seeds.py` from
`analysis/main_8000.sym`).
