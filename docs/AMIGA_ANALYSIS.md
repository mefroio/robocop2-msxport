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
- Main loop at `$80C2`: waits for `($802C) >= 2`, i.e. **25 frames/s** on PAL; calls ~17
  routines per frame. **[verified loop; 25 Hz inferred from the VBL counter]**
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

- RoboCop is **not a BOB**: every frame it is composed into a 64 px × 73 lines × 4 planes
  buffer at `$7E3A0` (planes every `$248`) and shown with **attached hardware sprites**
  (16 colours, COLOR16–31; colour 0 transparent).
- Animation table at `$B4E2`: 17 states × 8 bytes (`steps−1`, list offset, height); 16-byte
  frame records with PERMA offset, BLTSIZE, modulo and x/y offsets. Legs and torso/gun are
  separate parts.
- 69 frames (34 distinct graphics), from 32×40 to 48×58 (up to 72 lines) —
  `tools/player.py` → `build/sprites/robocop.png`.

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
| `tools/amigaemu.py` | auxiliary execution bench (experimental, parked) | Unicorn |

Code analysis: **REA + Ghidra** (project rule, see `CLAUDE.md`). Targets to open in REA:
`build/ram/level1_full.bin` (whole level-1 RAM, entry `$0` with `JMP $8000`) or
`build/ram/level1_8000.bin`. Entries reached only through jump tables are seeded into
Ghidra by `analysis/ghidra_seeds.tsv` (generated by `tools/ghidra_seeds.py` from
`analysis/main_8000.sym`).
