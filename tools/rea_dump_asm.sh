#!/bin/sh
# Exports, through the REA CLI (Ghidra provider, with the project seeds), the assembly of
# every procedure listed in build/rea/procedures.tsv to build/rea/asm/<address>.json.
# usage: tools/rea_dump_asm.sh build/ram/level1_full.bin [parallelism]
set -eu
IMG="$1"; PAR="${2:-3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export GHIDRA_INSTALL_DIR="${GHIDRA_INSTALL_DIR:-$HOME/Applications/ghidra_12.1.4_PUBLIC}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export REA_GHIDRA_SEED_FILE="$ROOT/analysis/ghidra_seeds.tsv"
export IMG OUTDIR="$ROOT/build/rea/asm"
mkdir -p "$OUTDIR"
python3 -I -c "
import sys
for l in open(sys.argv[1]):
    a = l.split('\t')[0]
    if int(a, 16) >= 0x8000: print(a)
" "$ROOT/build/rea/procedures.tsv" | xargs -P "$PAR" -n 1 sh -c '
  out="$OUTDIR/$1.json"
  [ -s "$out" ] && exit 0
  npx -y rea-agents@6.7.0 instructions "$IMG" "$1" --target-format raw-binary --architecture m68k \
      --entry-point 0x0 --provider ghidra --format json > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" || rm -f "$out.tmp"
' sh
ls "$OUTDIR" | wc -l
