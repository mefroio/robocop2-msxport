#!/usr/bin/env python3
"""Converts a static screen (RGB PNG) to MSX2 SCREEN 8 (256 fixed colours GGGRRRBB).

- Width 320 (Amiga lowres) -> 256: same width on the TV (an MSX pixel is 1.25x wider);
  the height is kept.
- Fixed SCREEN 8 palette: G 3 bits, R 3 bits, B 2 bits; Floyd-Steinberg dithering.
Outputs: <out>.sc8 (1 byte per pixel, row by row) and <out>.png (preview).
usage: msxpic.py INPUT.png OUTPUT  (requires numpy and Pillow)
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

LEVELS3 = np.array([0, 36, 73, 109, 146, 182, 219, 255], float)
LEVELS2 = np.array([0, 85, 170, 255], float)


def main() -> int:
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    im = Image.open(src).convert("RGB")
    w, h = im.size
    im = im.resize((256, h), Image.LANCZOS)
    a = np.array(im, float)
    H, W, _ = a.shape
    code = np.zeros((H, W), np.uint8)
    prev = np.zeros((H, W, 3), np.uint8)
    for y in range(H):
        for x in range(W):
            r, g, b = a[y, x]
            ri = int(np.abs(LEVELS3 - r).argmin())
            gi = int(np.abs(LEVELS3 - g).argmin())
            bi = int(np.abs(LEVELS2 - b).argmin())
            q = np.array([LEVELS3[ri], LEVELS3[gi], LEVELS2[bi]])
            err = a[y, x] - q
            code[y, x] = (gi << 5) | (ri << 2) | bi
            prev[y, x] = q.astype(np.uint8)
            for dx, dy, k in ((1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)):
                xx, yy = x + dx, y + dy
                if 0 <= xx < W and yy < H:
                    a[yy, xx] += err * k
    out.parent.mkdir(parents=True, exist_ok=True)
    out.with_suffix(".sc8").write_bytes(code.tobytes())
    Image.fromarray(prev).save(out.with_suffix(".png"))
    print(f"{out.with_suffix('.sc8')}: {W}x{H} = {W * H} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
