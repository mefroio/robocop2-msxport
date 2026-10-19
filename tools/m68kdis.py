#!/usr/bin/env python3
"""Recursive-descent 68000 disassembler with Amiga hardware annotations.

Depends on Capstone (pip install capstone). Produces a listing with labels,
code/data separation and cross-references. Names and comments live in a text
symbol file (versionable):

    # comment
    8000  start            entry point (JMP $8000 from the bootblock)
    8050  current_disk     word: current disk (1/2)
    +entry 9abc            forces an extra code entry
    +data  a000 a100       forces a range as data

usage:
    m68kdis.py BIN --base 0x8000 [--entry 0x8000 ...] [--sym file.sym] [-o out.s]
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amigahw import CUSTOM, VECTORS, hw_name  # noqa: E402

try:
    from capstone import CS_ARCH_M68K, CS_MODE_M68K_000, Cs
except ImportError:  # pragma: no cover
    sys.exit("m68kdis.py needs Capstone: pip install capstone")

HEXNUM = re.compile(r"\$([0-9a-fA-F]+)")
COND = "(?:t|f|hi|ls|cc|cs|ne|eq|vc|vs|pl|mi|ge|lt|gt|le|hs|lo)"
BRANCH = re.compile(rf"^(?:b{COND}|bra|bsr|db{COND}|dbra)(?:\.[bswl])?$")
ENDS = {"rts", "rte", "rtr", "illegal"}


class Symbols:
    def __init__(self, path: Path | None):
        self.names: dict[int, str] = {}
        self.comments: dict[int, str] = {}
        self.entries: list[int] = []
        self.data: list[tuple[int, int]] = []
        if path and path.exists():
            for line in path.read_text().splitlines():
                line = line.split("#", 1)[0].rstrip() if not line.lstrip().startswith("#") else ""
                if not line.strip():
                    continue
                parts = line.split(None, 2)
                if parts[0] == "+entry":
                    self.entries.append(int(parts[1], 16))
                elif parts[0] == "+data":
                    a, b = parts[1].split("-") if "-" in parts[1] else (parts[1], parts[2].split()[0])
                    self.data.append((int(a, 16), int(b, 16)))
                else:
                    addr = int(parts[0], 16)
                    if len(parts) > 1:
                        self.names[addr] = parts[1]
                    if len(parts) > 2:
                        self.comments[addr] = parts[2]


A6REL = re.compile(r"(-?)\$([0-9a-f]+)\(a6\)")
# Instructions that almost never appear in this game's real code; they reject a gap probe.
SUSPECT = re.compile(r"^(ori\.b\s+#\$0, d0|dc\.|illegal|reset|stop|trapv|chk|abcd|sbcd|nbcd|move\s+usp|rtr)")


class Disassembler:
    def __init__(self, data: bytes, base: int, syms: Symbols, a6_base: int | None = None):
        self.data, self.base, self.syms = data, base, syms
        self.end = base + len(data)
        self.a6_base = a6_base
        self.md = Cs(CS_ARCH_M68K, CS_MODE_M68K_000)
        self.insns: dict[int, tuple[int, str, str]] = {}  # addr -> (size, mnem, ops)
        self.code_refs: dict[int, set[int]] = defaultdict(set)  # target -> sources
        self.data_refs: dict[int, set[int]] = defaultdict(set)
        self.calls: set[int] = set()
        self.heuristic: set[int] = set()  # entries found by the gap scan

    def inside(self, a: int) -> bool:
        return self.base <= a < self.end

    def forced_data(self, a: int) -> bool:
        return any(x <= a < y for x, y in self.syms.data)

    def decode(self, a: int):
        off = a - self.base
        for insn in self.md.disasm(self.data[off:off + 10], a, 1):
            return insn.size, insn.mnemonic, insn.op_str
        return None

    def explore(self, entries: list[int]) -> None:
        work = [e for e in entries if self.inside(e)]
        while work:
            a = work.pop()
            while self.inside(a) and a not in self.insns and not self.forced_data(a):
                d = self.decode(a)
                if d is None:
                    break
                size, mn, ops = d
                self.insns[a] = d
                nxt = a + size
                base_mn = mn.split(".")[0]
                if BRANCH.match(mn):
                    t = int(HEXNUM.findall(ops)[-1], 16)
                    self.code_refs[t].add(a)
                    if base_mn == "bsr":
                        self.calls.add(t)
                    work.append(t)
                    if base_mn == "bra":
                        break
                elif base_mn in ("jsr", "jmp"):
                    m = re.fullmatch(r"\$([0-9a-f]+)(?:\.[wl]|\(pc\))", ops)
                    if m:
                        t = int(m.group(1), 16)
                        self.code_refs[t].add(a)
                        if base_mn == "jsr":
                            self.calls.add(t)
                        work.append(t)
                    if base_mn == "jmp":
                        break
                elif base_mn in ENDS:
                    break
                else:
                    for m in re.finditer(r"\$([0-9a-f]+)(?:\(pc\)|\.l|\.w)", ops):
                        t = int(m.group(1), 16)
                        if self.inside(t):
                            self.data_refs[t].add(a)
                    for m in re.finditer(r"#\$([0-9a-f]+)", ops):
                        t = int(m.group(1), 16)
                        if self.inside(t) and t >= self.base + 0x10 and mn.startswith(("move.l", "lea", "pea")):
                            self.data_refs[t].add(a)
                a = nxt

    def probe(self, a: int, max_ins: int = 400) -> bool:
        """Decodes linearly from `a`; accepts if it reaches a terminator without anything suspicious."""
        count = 0
        while self.inside(a) and count < max_ins:
            if a in self.insns:
                return count >= 3
            d = self.decode(a)
            if d is None:
                return False
            size, mn, ops = d
            if SUSPECT.match(f"{mn} {ops}"):
                return False
            count += 1
            base_mn = mn.split(".")[0]
            if base_mn in ENDS or base_mn in ("jmp", "bra"):
                return count >= 3
            a += size
        return False

    def scan_gaps(self) -> int:
        """Looks for unreached functions in gaps between known code."""
        found = 0
        changed = True
        while changed:
            changed = False
            a = self.base
            while a < self.end:
                if a in self.insns:
                    a += self.insns[a][0]
                    continue
                if a % 2 == 0 and not self.forced_data(a) and self.probe(a):
                    self.heuristic.add(a)
                    self.calls.add(a)
                    self.explore([a])
                    found += 1
                    changed = True
                    continue
                a += 2
        return found

    def label(self, a: int) -> str:
        if a in self.syms.names:
            return self.syms.names[a]
        if a in self.calls:
            return f"sub_{a:x}"
        if a in self.code_refs:
            return f"loc_{a:x}"
        return f"dat_{a:x}"

    def render_ops(self, ops: str) -> str:
        def rep(m):
            v = int(m.group(1), 16)
            tail = ops[m.end():m.end() + 4]
            if (v in self.syms.names or v in self.code_refs or v in self.data_refs) and self.inside(v) \
                    and not tail.startswith(","):
                return self.label(v)
            if v in self.syms.names and not self.inside(v):
                return self.syms.names[v]
            return m.group(0)
        return HEXNUM.sub(rep, ops)

    def notes(self, a: int, ops: str) -> list[str]:
        n = []
        for m in HEXNUM.finditer(ops):
            v = int(m.group(1), 16)
            h = hw_name(v)
            if h:
                n.append(h)
            elif v in VECTORS and (ops[m.end():m.end() + 2] in (".w", ".l")):
                n.append(VECTORS[v])
        if self.a6_base is not None:
            for m in A6REL.finditer(ops):
                disp = int(m.group(2), 16) * (-1 if m.group(1) else 1)
                h = hw_name(self.a6_base + disp)
                if h:
                    n.append(f"a6:{h}")
        if a in self.syms.comments:
            n.append(self.syms.comments[a])
        return n

    def listing(self) -> str:
        out = [f"; base ${self.base:x}  size ${len(self.data):x}  "
               f"instructions={len(self.insns)}  subroutines={len(self.calls)}", ""]
        a = self.base
        while a < self.end:
            if a in self.insns:
                size, mn, ops = self.insns[a]
                if a in self.calls or a in self.syms.names or a in self.code_refs:
                    refs = sorted(self.code_refs.get(a, ()))
                    if a in self.calls or a in self.syms.names:
                        out.append("")
                    xr = f"   ; xref {' '.join(f'{r:x}' for r in refs[:8])}{' …' if len(refs) > 8 else ''}" \
                        if refs else ""
                    if a in self.heuristic:
                        xr += "   ; [heuristic entry: no direct reference]"
                    out.append(f"{self.label(a)}:{xr}")
                raw = self.data[a - self.base:a - self.base + size].hex()
                n = self.notes(a, ops)
                c = ("   ; " + "; ".join(n)) if n else ""
                out.append(f"  {a:06x}  {raw:<20} {mn:<9} {self.render_ops(ops)}{c}")
                a += size
            else:
                b = a
                while b < self.end and b not in self.insns and (b == a or (b not in self.data_refs
                                                                           and b not in self.syms.names)):
                    b += 1
                out.extend(self.render_data(a, b))
                a = b
        return "\n".join(out) + "\n"

    def render_data(self, a: int, b: int) -> list[str]:
        lines = []
        if a in self.data_refs or a in self.syms.names:
            refs = sorted(self.data_refs.get(a, ()))
            xr = f"   ; dref {' '.join(f'{r:x}' for r in refs[:8])}" if refs else ""
            lines.append(f"{self.label(a)}:{xr}" + (f"   ; {self.syms.comments[a]}" if a in self.syms.comments else ""))
        chunk = self.data[a - self.base:b - self.base]
        i = 0
        while i < len(chunk):
            row = chunk[i:i + 16]
            txt = "".join(chr(c) if 32 <= c < 127 else "." for c in row)
            lines.append(f"  {a + i:06x}  dc.b {', '.join(f'${c:02x}' for c in row):<95} ; {txt}")
            i += 16
        return lines


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bin", type=Path)
    ap.add_argument("--base", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--entry", type=lambda s: int(s, 0), action="append", default=[])
    ap.add_argument("--sym", type=Path)
    ap.add_argument("--a6", type=lambda s: int(s, 0), help="base assumed in A6 to annotate d16(a6), e.g. 0xdff002")
    ap.add_argument("--scan-gaps", action="store_true", help="looks for functions in gaps (heuristic)")
    ap.add_argument("-o", "--output", type=Path)
    a = ap.parse_args()
    data = a.bin.read_bytes()
    syms = Symbols(a.sym)
    dis = Disassembler(data, a.base, syms, a.a6)
    dis.explore((a.entry or [a.base]) + syms.entries)
    if a.scan_gaps:
        dis.scan_gaps()
    text = dis.listing()
    if a.output:
        a.output.parent.mkdir(parents=True, exist_ok=True)
        a.output.write_text(text)
        cov = sum(s for s, _, _ in dis.insns.values())
        print(f"{a.output}: {len(dis.insns)} instructions, {len(dis.calls)} subroutines "
              f"({len(dis.heuristic)} heuristic), {cov}/{len(data)} code bytes ({100 * cov / len(data):.1f}%)")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
