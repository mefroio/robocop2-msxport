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

- **Technique**: two pages aligned to 16 px; set-adjust (R#18) shifts image and sprites by
  s = 8 − f px (−7..+8, applied from the next line, as in the openMSX source); the back page
  is built for the next column (new column + 16 px shifted copy in 4 strips of 240×64,
  issued without blocking the CPU) and flipped when crossing 16 px; new rows (R#23) go to
  both pages. If the back page is not ready, the camera waits.
- **Bug found and fixed**: scheduler starvation (1 command per frame → the copy strips
  never ran while the camera moved down). Fix: bursts of short tiles, new column before the
  copy, and a second chance at the end of the frame.
- **Result** (headless openMSX, Gradiente Expert 2.0, via MSX-AI): pixel check with
  R#18 = −6 px → **0 pixels differ** out of 48,000 (`build/png/msx2_scroll_vs_ref.png`).
  Full map run (x 0→2304, 2675 frames, camera at 1 px/frame horizontally and 0.5 px/frame
  vertically): **1 late frame** and **84 stall frames** (3%).
- **Pending optimisations** (needed once sprites are on, ~25% slower): do not redraw on the
  back page the rows the copy will bring anyway; copy only the ring lines in use (240
  instead of 256); start building earlier.
- On both machines the usable area is 248 px wide (MSK on MSX2+, moving R#18 border on
  MSX2).
