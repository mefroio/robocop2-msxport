"""Amiga OCS hardware tables: custom registers, CIAs and vectors."""
from __future__ import annotations

CUSTOM_BASE = 0xDFF000

CUSTOM = {
    0x000: "BLTDDAT", 0x002: "DMACONR", 0x004: "VPOSR", 0x006: "VHPOSR", 0x008: "DSKDATR", 0x00A: "JOY0DAT",
    0x00C: "JOY1DAT", 0x00E: "CLXDAT", 0x010: "ADKCONR", 0x012: "POT0DAT", 0x014: "POT1DAT", 0x016: "POTGOR",
    0x018: "SERDATR", 0x01A: "DSKBYTR", 0x01C: "INTENAR", 0x01E: "INTREQR", 0x020: "DSKPTH", 0x022: "DSKPTL",
    0x024: "DSKLEN", 0x026: "DSKDAT", 0x028: "REFPTR", 0x02A: "VPOSW", 0x02C: "VHPOSW", 0x02E: "COPCON",
    0x030: "SERDAT", 0x032: "SERPER", 0x034: "POTGO", 0x036: "JOYTEST", 0x040: "BLTCON0", 0x042: "BLTCON1",
    0x044: "BLTAFWM", 0x046: "BLTALWM", 0x048: "BLTCPTH", 0x04A: "BLTCPTL", 0x04C: "BLTBPTH", 0x04E: "BLTBPTL",
    0x050: "BLTAPTH", 0x052: "BLTAPTL", 0x054: "BLTDPTH", 0x056: "BLTDPTL", 0x058: "BLTSIZE", 0x060: "BLTCMOD",
    0x062: "BLTBMOD", 0x064: "BLTAMOD", 0x066: "BLTDMOD", 0x070: "BLTCDAT", 0x072: "BLTBDAT", 0x074: "BLTADAT",
    0x07E: "DSYNC", 0x080: "COP1LCH", 0x082: "COP1LCL", 0x084: "COP2LCH", 0x086: "COP2LCL", 0x088: "COPJMP1",
    0x08A: "COPJMP2", 0x08C: "COPINS", 0x08E: "DIWSTRT", 0x090: "DIWSTOP", 0x092: "DDFSTRT", 0x094: "DDFSTOP",
    0x096: "DMACON", 0x098: "CLXCON", 0x09A: "INTENA", 0x09C: "INTREQ", 0x09E: "ADKCON",
    0x100: "BPLCON0", 0x102: "BPLCON1", 0x104: "BPLCON2", 0x108: "BPL1MOD", 0x10A: "BPL2MOD",
}
for _i in range(4):
    _b = 0x0A0 + 0x10 * _i
    CUSTOM.update({_b: f"AUD{_i}LCH", _b + 2: f"AUD{_i}LCL", _b + 4: f"AUD{_i}LEN", _b + 6: f"AUD{_i}PER",
                   _b + 8: f"AUD{_i}VOL", _b + 10: f"AUD{_i}DAT"})
for _i in range(6):
    CUSTOM.update({0x0E0 + 4 * _i: f"BPL{_i + 1}PTH", 0x0E2 + 4 * _i: f"BPL{_i + 1}PTL",
                   0x110 + 2 * _i: f"BPL{_i + 1}DAT"})
for _i in range(8):
    CUSTOM.update({0x120 + 4 * _i: f"SPR{_i}PTH", 0x122 + 4 * _i: f"SPR{_i}PTL", 0x140 + 8 * _i: f"SPR{_i}POS",
                   0x142 + 8 * _i: f"SPR{_i}CTL", 0x144 + 8 * _i: f"SPR{_i}DATA", 0x146 + 8 * _i: f"SPR{_i}DATB"})
for _i in range(32):
    CUSTOM[0x180 + 2 * _i] = f"COLOR{_i:02d}"

CIAA = {0x001: "CIAA_PRA", 0x101: "CIAA_PRB", 0x201: "CIAA_DDRA", 0x301: "CIAA_DDRB", 0x401: "CIAA_TALO",
        0x501: "CIAA_TAHI", 0x601: "CIAA_TBLO", 0x701: "CIAA_TBHI", 0x801: "CIAA_TODLO", 0x901: "CIAA_TODMID",
        0xA01: "CIAA_TODHI", 0xC01: "CIAA_SDR", 0xD01: "CIAA_ICR", 0xE01: "CIAA_CRA", 0xF01: "CIAA_CRB"}
CIAB = {0x000: "CIAB_PRA", 0x100: "CIAB_PRB", 0x200: "CIAB_DDRA", 0x300: "CIAB_DDRB", 0x400: "CIAB_TALO",
        0x500: "CIAB_TAHI", 0x600: "CIAB_TBLO", 0x700: "CIAB_TBHI", 0xD00: "CIAB_ICR", 0xE00: "CIAB_CRA",
        0xF00: "CIAB_CRB"}
VECTORS = {0x64: "VEC_L1", 0x68: "VEC_L2_PORTS", 0x6C: "VEC_L3_VBL", 0x70: "VEC_L4_AUDIO", 0x74: "VEC_L5",
           0x78: "VEC_L6_EXTER", 0x7C: "VEC_NMI", 0x80: "VEC_TRAP0", 0xC0: "LOADER_PTR"}


def hw_name(v: int) -> str | None:
    """Name of an absolute hardware address, or None."""
    if CUSTOM_BASE <= v <= CUSTOM_BASE + 0x1FE:
        return CUSTOM.get(v - CUSTOM_BASE, f"CUSTOM+${v - CUSTOM_BASE:03x}")
    if 0xBFE001 <= v <= 0xBFEF01:
        return CIAA.get(v - 0xBFE000)
    if 0xBFD000 <= v <= 0xBFDF00:
        return CIAB.get(v - 0xBFD000)
    return None


def rgb12_to_rgb24(c: int) -> tuple[int, int, int]:
    """12-bit OCS colour ($0RGB) to RGB with 8 bits per channel."""
    return ((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17
