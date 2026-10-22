"""The port's colour grade: a picture a little brighter and with more contrast than the Amiga's
colours converted level for level (the user's choice, 2026-10-22, from previews of the play
field and the HUD: the brightest of three, over a lighter one and the plain conversion).

Every 3-bit component the VDP shows goes through BRIGHT: the shadows kept (0, 1), the tones
above them a level up, 6 and 7 both full. Only colours change, never a colour index: the tiles,
sprites and HUD stay as they are. The conversions and their outputs (the .pal files, the
previews) stay in the plain colours, which their colour matching and the checks work in
(tools/msxframe.py, recframes.py); the grade goes where the ROM's colours are made:
  - tools/mkrom.py: level1.pal and hud.pal into build/msx/gen (level1_grade.pal, hud_grade.pal),
    and the fade's limits
    (grade.inc fade_cap: msx/logic.asm pal_fade limits the graded palette to BRIGHT[step], the
    graded colour of the original's limited one, as BRIGHT never decreases);
  - tools/msxsprites.py: RoboCop's flash palettes (robocop_flash.inc);
  - tools/msxtext.py: the text screens' palette (the level statistics, over the HUD);
  - tools/msxreal.py: the colours openMSX's pictures are checked against.
The SCREEN 8 pictures (title, game over) keep the plain colours: graded they looked blown out
(the user's choice: the grade for the game play only).
"""
from __future__ import annotations

BRIGHT = (0, 1, 3, 4, 5, 6, 7, 7)


def grade_pal(pal: bytes) -> bytes:
    """V9938 palette pairs (R << 4 | B, G) with every component through BRIGHT."""
    out = bytearray()
    for i in range(0, len(pal), 2):
        rb, g = pal[i], pal[i + 1]
        out += bytes((BRIGHT[rb >> 4 & 7] << 4 | BRIGHT[rb & 7], BRIGHT[g & 7]))
    return bytes(out)

