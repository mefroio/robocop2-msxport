#!/usr/bin/env python3
"""The text screens' data for the MSX front end (msx/front.asm): the 8x8 bitmap font of the
Amiga's text screens and the level statistics script, from the composite RAM image as the game
code reads them (tools/rc2front.py; docs/AMIGA_ANALYSIS.md, "Front end: title, text screens,
high scores").

- Font ($65DB0, PERMA): 44 glyphs of 3 planes x 8 lines, drawn with move.b into planes 0-2 by
  $118D6. Plane 1 is always clear and planes 0 and 2 never meet: the strokes are colour 1, their
  hand-drawn shadow colour 4. Here each glyph is 8 x 8 pixels in SCREEN 5 (4 bytes a line, the
  left pixel high), the cell's every pixel written (colour 0 between).
- Palette ($109A8, COLOR01-15, components at most E): the MSX's 3-bit components (c * 7 / 15,
  rounded, then the colour grade: tools/msxbright.py), as the VBLANK loads the play field's
  (isr.asm pf_pal: R then B in the first byte, G in the second).
- Statistics script ($1132F, show_level_stats $85D8 fills its three number fields with $11DC6
  and runs it through $10762): its bytes up to its FF 07 (the interpreter's format in
  rc2front.py), with the offsets of the three 8-character fields.
- The port's credit on the title picture (with TITLE.sc8 and OUT.sc8: the SCREEN 8 picture of
  tools/msxpic.py): CREDIT's lines in the same font (capitals only), centred over the dark band
  below RoboCop's chin, the strokes in the logo's light grey-blue and their shadow in dark blue
  (G7 bytes: the text screens' green and blue are too dark over the picture); the pixels between
  them keep the picture. OUT.png is its preview. (The pictures keep the plain colours: the
  colour grade made them look blown out, the user's choice, 2026-10-22.)
- GAME OVER under the game over picture (with OVER.sc8 and OUT2.sc8, the user's choice: PIC9
  has no text): a black band of BAND lines below it with the words in the same font and colours
  at twice the size, centred (front.asm pic_show centres the taller picture).

usage: msxtext.py [RAM_IMAGE] [OUT.inc] [TITLE.sc8 OUT.sc8 [OVER.sc8 OUT2.sc8]]
       (defaults: build/ram/level1_full.bin, build/msx/text.inc)
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rc2front  # noqa: E402
from msxbright import grade_pal  # noqa: E402
from planar import write_png  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
STATS = 0x1132F                     # show_level_stats' script
STATS_FIELDS = (0x1135A, 0x11379, 0x11398)  # henchmen ($16C2), nukes ($16C0), hostages ($16BE)
CREDIT = ((158, "2026 PORT BY RODRIGO G.M. GARCIA"),   # (picture line, text): the user's credit
          (168, "ORIGINAL AMIGA GAME BY"),              # (32 characters a line at most)
          (178, "OCEAN SOFTWARE LTD"))
CREDIT_INK = 0xDB                   # G7 (GGGRRRBB): the strokes (glyph colour 1),
CREDIT_SHADE = 0x21                 #   their shadow (colour 4)
OVER_TEXT = "GAME OVER"
BAND = 16                           # lines below the game over picture (the text: 192 lines, 6 banks as PIC9)


def glyph_sc5(ram: bytes, g: int) -> bytes:
    """Glyph g as 8 lines of 4 SCREEN 5 bytes: plane 0 -> colour 1, plane 2 -> colour 4."""
    a = rc2front.BITMAP_FONT + 24 * g
    out = bytearray()
    for y in range(8):
        p0, p1, p2 = ram[a + y], ram[a + 8 + y], ram[a + 16 + y]
        assert p1 == 0 and p0 & p2 == 0, f"glyph {g}: colours other than 1 and 4"
        px = [(1 if p0 & (0x80 >> x) else 0) | (4 if p2 & (0x80 >> x) else 0) for x in range(8)]
        out += bytes(px[x] << 4 | px[x + 1] for x in range(0, 8, 2))
    return bytes(out)


def msx_palette(ram: bytes) -> bytes:
    """COLOR00 (black) + COLOR01-15 as V9938 palette pairs (before the colour grade)."""
    out = bytearray(b"\x00\x00")
    for i in range(15):
        c = struct.unpack_from(">H", ram, rc2front.TEXT_PALETTE + 2 * i)[0]
        r, g, b = (min(c >> s & 15, 14) for s in (8, 4, 0))
        r, g, b = (round(v * 7 / 15) for v in (r, g, b))
        out += bytes([r << 4 | b, g])
    return bytes(out)


def stats_script(ram: bytes) -> bytes:
    """The script's bytes up to and including its FF 07."""
    a = STATS
    while True:
        b = ram[a]
        if b == 0:
            a += 3
        elif b < 0x80:
            a += 1
        else:
            cmd = ram[a + 1]
            a += 3 if cmd in (2, 4) else 2
            if cmd == 7:
                return ram[STATS:a]
            assert cmd == 2, f"command {cmd} in the statistics script"


def draw_text(ram: bytes, out: bytearray, top: int, text: str, scale: int = 1) -> None:
    """text in the font into the SCREEN 8 picture out (256 bytes a line), centred, from line top,
    each glyph pixel scale x scale; the pixels between the strokes and the shadow are kept."""
    x0 = (256 - 8 * scale * len(text)) // 2
    for i, ch in enumerate(text):
        a = rc2front.BITMAP_FONT + 24 * rc2front.GLYPH_NAMES.index(ch)
        for y in range(8 * scale):
            p0, p2 = ram[a + y // scale], ram[a + 16 + y // scale]
            for x in range(8 * scale):
                o = (top + y) * 256 + x0 + 8 * scale * i + x
                if p0 & (0x80 >> x // scale):
                    out[o] = CREDIT_INK
                elif p2 & (0x80 >> x // scale):
                    out[o] = CREDIT_SHADE


def credit_sc8(ram: bytes, pic: bytes) -> bytes:
    """The title picture with CREDIT drawn into it."""
    out = bytearray(pic)
    for top, text in CREDIT:
        draw_text(ram, out, top, text)
    return bytes(out)


def over_sc8(ram: bytes, pic: bytes) -> bytes:
    """The game over picture with a band below it: GAME OVER at twice the size."""
    out = bytearray(pic) + bytes(256 * BAND)
    draw_text(ram, out, len(pic) // 256 + (BAND - 16) // 2, OVER_TEXT, 2)
    return bytes(out)


def write_sc8(path: Path, pic: bytes) -> None:
    """The SCREEN 8 picture and its preview (.png)."""
    path.write_bytes(pic)
    write_png(path.with_suffix(".png"), 256, len(pic) // 256,
              [b"".join(g7_rgb(v) for v in pic[y * 256:y * 256 + 256]) for y in range(len(pic) // 256)])


def g7_rgb(v: int) -> bytes:
    return bytes((round((v >> 2 & 7) * 255 / 7), round((v >> 5) * 255 / 7), round((v & 3) * 255 / 3)))


def db_lines(data: bytes, per: int = 16) -> str:
    return "".join("        db " + ", ".join(f"0x{v:02X}" for v in data[i:i + per]) + "\n"
                   for i in range(0, len(data), per))


def main(argv: list[str]) -> int:
    ram = Path(argv[1] if len(argv) > 1 else ROOT / "build/ram/level1_full.bin").read_bytes()
    out = Path(argv[2] if len(argv) > 2 else ROOT / "build/msx/text.inc")
    script = stats_script(ram)
    text = ("; generated by tools/msxtext.py: the text screens' font, palette and the level statistics\n"
            f"TXT_STATS_LEN: equ {len(script)}\n"
            + "".join(f"TXT_F{i + 1}: equ {f - STATS}{' ' * 12}; its number field ($11DC6: 8 characters)\n"
                      for i, f in enumerate(STATS_FIELDS))
            + "txt_pal:                            ; $109A8 (pf_pal's format)\n" + db_lines(grade_pal(msx_palette(ram)))
            + "txt_stats:                          ; $1132F\n" + db_lines(script)
            + f"txt_glyphs:                         ; $65DB0: {rc2front.BITMAP_GLYPHS} x 8 lines x 4 bytes\n"
            + "".join(f"        ; {rc2front.GLYPH_NAMES[g]!r}\n" + db_lines(glyph_sc5(ram, g))
                      for g in range(rc2front.BITMAP_GLYPHS)))
    out.write_text(text)
    print(f"{out}: {rc2front.BITMAP_GLYPHS} glyphs, statistics script {len(script)} bytes")
    if len(argv) > 4:
        write_sc8(Path(argv[4]), credit_sc8(ram, Path(argv[3]).read_bytes()))
        print(f"{argv[4]}: the title with the credit ({len(CREDIT)} lines)")
    if len(argv) > 6:
        write_sc8(Path(argv[6]), over_sc8(ram, Path(argv[5]).read_bytes()))
        print(f"{argv[6]}: the game over picture with {OVER_TEXT} below it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
