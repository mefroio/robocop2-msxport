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
make msx      # level 1 conversion: joint palette, RoboCop and BOB sprites, tiles, map and attributes, HUD and its run-time data, RoboCop's logic tables (build/msx/)
make rom      # MegaROM (KonamiSCC/MegaRAM mapper) in build/msx/rc2.rom
make rom ROMOPTS="DEMO_ACTORS=2"    # build options (tools/mkrom.py OPTIONS: DEMO_ACTORS, FORCE_V9938)
make rom ROMOPTS="JOY=70:30:r,105:10:d"   # test ROM playing a joystick script instead of the controls
```

The engine is Z80 assembly in `msx/` (z80asm 1.8). Run it in openMSX with
`carta insert build/msx/rc2.rom -romtype KonamiSCC`. RoboCop is played with joystick port 1
or the keyboard (cursor keys, SPACE/RETURN fire), at the NTSC original's 30 game frames per
second on 50 and 60 Hz machines (`msx/player.asm`).

The game logic is checked against the original: `tools/amigaemu.py game --ram
build/ram/level1_full.bin --gframes N --joy F:C:KEYS ... --trace A.jsonl` runs the Amiga code
with a joystick script and traces its variables per game frame; a ROM built with the same
script (`JOY=...`) traced with `rc2_trace FILE N ADDR TARGET` (`tools/openmsx_rc2.tcl`, the
`tick_start` and `game_tick` addresses from `build/msx/rc2.labels`) is compared with
`tools/tracecmp.py A.jsonl FILE`.

Checking a run in headless openMSX (MSX-AI `msx_local_cmd`): `source tools/openmsx_rc2.tcl`,
then `rc2_snaps DIR N SECS` (or `rc2_snaps_when` for a condition) saves VRAM, RAM and VDP
registers; `tools/checkrun.py DIR build/msx/level1 build/msx/hud` rebuilds every frame
(`tools/msxframe.py`) and compares it pixel by pixel with the map, the HUD and every sprite
object (RoboCop and the BOBs) as converted, reports lines where the SAT holds more than 8
sprites and checks that the tile area of VRAM is untouched. `rc2_prof SECS LOG LABELS` +
`tools/proflog.py LOG` profile the main loop (addresses from `build/msx/rc2.labels`);
`rc2_count_too_fast` counts lost VRAM writes.

## Documentation

- [Amiga reverse-engineering ledger](docs/AMIGA_ANALYSIS.md)
- [MSX2/MSX2+ feasibility measurements](docs/MSX_FEASIBILITY.md)
- [MSX port architecture and decisions](docs/MSX_ARCHITECTURE.md)
