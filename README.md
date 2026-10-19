# Robocop 2 — Amiga 500 to MSX2/MSX2+ port

Goal: port ROBOCOP 2 (Ocean/Special FX, 1990) from the Amiga 500 to MSX2 and MSX2+,
reusing as much of the original logic and graphics as the target machine allows. The MSX2
(V9938) is the mandatory baseline; the MSX2+ (V9958) is detected at run time and used when
present.

- Amiga reverse engineering: tools in `tools/` + REA (Ghidra).
- MSX development and testing: headless openMSX through the MSX-AI MCP.

The ADFs live in `amiga/` and **must not be committed or distributed**, and neither must
anything generated in `build/`.

## Quick start

```sh
make extract    # extracts and decrunches the 27 files of both disks
make list       # file table, classification and disk coverage
make pics       # renders the static screens into build/png/
make test
```

For the Capstone listing (optional, complements Ghidra):

```sh
make setup      # creates the venv in ~/.venvs/msxports (outside iCloud)
make disasm     # build/dis/main_8000.s
```

## Code reverse engineering (REA + Ghidra)

Project rule (see [CLAUDE.md](CLAUDE.md)): all Amiga code analysis goes through REA with
the Ghidra provider; the MSX side uses MSX-AI with headless openMSX.

| Item | Location |
|---|---|
| Ghidra 12.1.4 (`mac_arm_64` natives built) | `~/Applications/ghidra_12.1.4_PUBLIC` |
| JDK 21 (Homebrew, keg-only) | `/opt/homebrew/opt/openjdk@21` |
| `rea` MCP registration | user scope: `GHIDRA_INSTALL_DIR`, `JAVA_HOME`, `REA_GHIDRA_SEED_FILE` |

```sh
make ram      # per-level RAM images in build/ram/ (files at their real addresses)
make seeds    # analysis/ghidra_seeds.tsv: entries reached only through jump tables
make sprites  # Ghidra assembly via the REA CLI -> BOB catalogue and RoboCop frames
```

In REA, open the whole RAM of a level (entry at `$0`, which holds `JMP $8000`):

```text
open_binary(path=".../build/ram/level1_full.bin",
            format="raw-binary", architecture="m68k", entry_point="0x0")
```

The seeds are re-read on every `open_binary`; changing the server registration requires
reconnecting `rea` (`/mcp`). Names and comments live in `analysis/main_8000.sym`, the
source of truth, because the Ghidra session inside REA is ephemeral.

## MSX build

```sh
make msx      # level 1 conversion: palette, tiles, map (build/msx/level1/)
make rom      # MegaROM (KonamiSCC/MegaRAM mapper) in build/msx/rc2.rom
```

The engine is Z80 assembly in `msx/` (z80asm 1.8). Run it in openMSX with
`carta insert build/msx/rc2.rom -romtype KonamiSCC`.

## Documentation

- [Amiga reverse-engineering ledger](docs/AMIGA_ANALYSIS.md)
- [MSX2/MSX2+ feasibility measurements](docs/MSX_FEASIBILITY.md)
- [MSX port architecture and decisions](docs/MSX_ARCHITECTURE.md)
