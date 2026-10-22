# Project rules (Robocop 2 Amiga → MSX2/MSX2+ port)

## Language
- Everything related to code is written in **English**: source code, comments, docstrings,
  tool output messages, generated files and documentation (`.md`).
- Only the chat with the user is in Brazilian Portuguese.

## Mandatory tools
- **Amiga code reverse engineering: REA MCP with the Ghidra provider.** Every question about
  code (what a routine does, who calls it, who writes an address, which data format the code
  reads) must be answered with REA calls (`open_binary` in `raw-binary`/`m68k` mode,
  `procedure_pseudo_code`, `batch_decompile`, `xrefs`, `analyze_function`, `get_call_graph`,
  `read_bytes`, ...). Bulk exports may use the REA CLI (same Ghidra engine and seeds).
  Own scripts only for data formats (ADF, PP20, bitplanes, copper, MSX conversion) or to
  complement what REA does not cover — never as a silent substitute.
- **MSX side: MSX-AI MCP with headless openMSX** (`msx_local_*`) to load, run, inspect
  memory/VRAM and capture screens.

## Hardware reference
- MSX2 Technical Handbook (ASCII 1987, Konamiman's transcription), cloned by `make reference`
  into `reference/MSX2-Technical-Handbook` (git-ignored: third-party text, never commit it):
  `md/Chapter4a.md` / `md/Chapter4b.md` (VDP: registers, sprites, commands and their register
  settings), `md/Appendix3.md` (bit block transfer), `md/Appendix5.md` (VRAM map),
  `md/Appendix6.md` (I/O map). Consult it for VDP and hardware details before guessing.

## Target
- MSX2 (V9938) is the mandatory baseline; detect a V9958 at runtime and use MSX2+ features
  when present. Never MSX2+-only.

## Conventions
- `tools/` in Python (stdlib whenever possible), `Makefile`, `docs/`, `tests/`; `build/` is ignored.
- Never commit ADFs, ROMs or data extracted from the game.
- Discovered names and comments live in `analysis/*.sym` (source of truth, because the Ghidra
  session inside REA is ephemeral) and seed Ghidra through `analysis/ghidra_seeds.tsv`.
- For cross-references into data, open the composite RAM image in REA
  (`build/ram/level1_full.bin`, entry point `0x0`), not only the main code.
- Findings ledger: `docs/AMIGA_ANALYSIS.md` (keep verified facts apart from inferences).
