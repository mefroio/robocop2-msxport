#!/usr/bin/env python3
"""PowerPacker (PP20) decruncher in pure Python.

File format:
    "PP20" | offset_lens[4] | compressed data ... | dest_len(24 bits BE) | skip_bits(8)

The bit stream is read backwards (from the end of the data to the start), and
the output is also written from the end to the start. This is a direct port of
the reference algorithm (ppdepack/amigadepacker).
"""
from __future__ import annotations

import sys

MAGIC = b"PP20"


class PP20Error(ValueError):
    pass


def trailer(packed: bytes) -> tuple[int, int]:
    """Returns (decrunched_size, bits_to_skip) from the 4-byte trailer."""
    return (packed[-4] << 16) | (packed[-3] << 8) | packed[-2], packed[-1]


def decrunch(packed: bytes, *, exact: bool = True) -> bytes:
    """Decrunches a complete PP20 file (with header and trailer).

    With exact=True the bit stream must be consumed entirely, which validates
    the size of the input file (useful to find unknown ends).
    """
    if packed[:4] != MAGIC:
        raise PP20Error("missing PP20 signature")
    if len(packed) < 12:
        raise PP20Error("file too short")
    offset_lens = packed[4:8]
    dest_len, skip_bits = trailer(packed)
    if skip_bits > 32:
        raise PP20Error(f"invalid skip_bits: {skip_bits}")

    src = packed
    src_start = 8
    pos = len(packed) - 4  # next byte to read is src[pos - 1]
    bit_buffer = 0
    bits_left = 0
    out = bytearray(dest_len)
    o = dest_len  # next byte is written to out[o - 1]

    def bits(n: int) -> int:
        nonlocal pos, bit_buffer, bits_left
        while bits_left < n:
            if pos <= src_start:
                raise PP20Error("bit stream ended before the end of the output")
            pos -= 1
            bit_buffer |= src[pos] << bits_left
            bits_left += 8
        v = 0
        for _ in range(n):
            v = (v << 1) | (bit_buffer & 1)
            bit_buffer >>= 1
        bits_left -= n
        return v

    bits(skip_bits)
    while o > 0:
        if bits(1) == 0:
            todo = 1
            while True:
                x = bits(2)
                todo += x
                if x != 3:
                    break
            if todo > o:
                raise PP20Error("literal exceeds the output")
            for _ in range(todo):
                o -= 1
                out[o] = bits(8)
            if o == 0:
                break
        x = bits(2)
        offbits = offset_lens[x]
        todo = x + 2
        if x == 3:
            if bits(1) == 0:
                offbits = 7
            offset = bits(offbits)
            while True:
                y = bits(3)
                todo += y
                if y != 7:
                    break
        else:
            offset = bits(offbits)
        if o + offset >= dest_len:
            raise PP20Error("reference points beyond the output")
        if todo > o:
            raise PP20Error("copy exceeds the output")
        for _ in range(todo):
            o -= 1
            out[o] = out[o + offset + 1]
    if exact and pos != src_start:
        raise PP20Error(f"{pos - src_start} bytes left unconsumed")
    return bytes(out)


def find_end(data: bytes, start: int, limit: int, *, max_out: int = 0x80000) -> int | None:
    """Finds the end of a PP20 stream starting at `start` without knowing its size.

    Tries 4-byte aligned ends and accepts the first one whose trailer is
    plausible and whose stream is consumed exactly.
    """
    for end in range(start + 16, min(limit, len(data)) + 1, 4):
        dest_len, skip = trailer(data[end - 4:end])
        if skip > 32 or not (end - start - 12) < dest_len <= max_out:
            continue
        try:
            decrunch(data[start:end], exact=True)
        except PP20Error:
            continue
        return end
    return None


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: pp20.py INPUT.pp OUTPUT.bin", file=sys.stderr)
        return 2
    data = open(argv[1], "rb").read()
    out = decrunch(data)
    open(argv[2], "wb").write(out)
    print(f"{argv[1]}: {len(data)} -> {len(out)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
