import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import msxconv  # noqa: E402
import planar  # noqa: E402
import pp20  # noqa: E402

DISK1 = ROOT / "amiga" / "Robocop 2 (1991)(Ocean)[cr Melnok](Disk 1 of 2).adf"
DISK2 = ROOT / "amiga" / "Robocop 2 (1991)(Ocean)[cr Melnok](Disk 2 of 2).adf"
HAVE_DISKS = DISK1.exists() and DISK2.exists()


class PP20Tests(unittest.TestCase):
    def test_rejects_missing_magic(self):
        with self.assertRaises(pp20.PP20Error):
            pp20.decrunch(b"XXXX" + bytes(12))

    def test_trailer(self):
        self.assertEqual(pp20.trailer(b"\x01\x02\x03\x07"), (0x010203, 7))


class PlanarTests(unittest.TestCase):
    def test_two_planes_sequential_and_interleaved(self):
        # 16x1 pixels, 2 planes: plane0 = 0xF0F0, plane1 = 0xFF00 -> indices 3,3,3,3,2,2,2,2,1,1,1,1,0,0,0,0
        expected = [3] * 4 + [2] * 4 + [1] * 4 + [0] * 4
        seq = bytes([0xF0, 0xF0, 0xFF, 0x00])
        self.assertEqual(planar.decode_indices(seq, 0, 16, 1, 2, "planes")[0], expected)
        self.assertEqual(planar.decode_indices(seq, 0, 16, 1, 2, "interleaved")[0], expected)


class MsxConvTests(unittest.TestCase):
    def test_palette_12_to_9_bits(self):
        self.assertEqual(msxconv.amiga_to_msx(0x000), (0, 0, 0))
        self.assertEqual(msxconv.amiga_to_msx(0xFFF), (7, 7, 7))
        self.assertEqual(msxconv.amiga_to_msx(0x8F0), (4, 7, 0))

    def test_pack_sc5_left_pixel_in_high_nibble(self):
        px = [[x % 16 for x in range(16)] for _ in range(16)]
        packed = msxconv.pack_sc5(px)
        self.assertEqual(len(packed), 128)
        self.assertEqual(packed[:8], bytes([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]))


@unittest.skipUnless(HAVE_DISKS, "ADFs missing from amiga/")
class Robocop2DiskTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import rc2files
        cls.rc = rc2files.Robocop2(str(DISK1), str(DISK2))

    def test_boot_chain(self):
        loads = {(ld.disk_offset, ld.length, ld.final) for ld in self.rc.boot_loads}
        self.assertEqual(loads, {(0x400, 0xA600, 0x8000), (0xCE600, 0x200, 0x100),
                                 (0xCE800, 0x800, 0x300), (0xD4800, 0x5200, 0x71000)})
        self.assertTrue(self.rc.boot_ok)

    def test_tables(self):
        self.assertEqual(self.rc.name_table_addr, 0x14E)
        self.assertEqual(self.rc.directory_addr, 0x91C)
        self.assertEqual(len(self.rc.entries), 27)

    def test_all_pp20_files_decrunch_exactly(self):
        packed = [e for e in self.rc.entries if e.packed]
        self.assertEqual(len(packed), 14)
        for e in packed:
            self.assertEqual(e.notes, [], e.name)
        sizes = {e.name: len(e.data) for e in self.rc.entries}
        self.assertEqual(sizes["DATAE"], 32032)
        self.assertEqual(sizes["DATAL3"], 185356)

    def test_disks_fully_accounted(self):
        unknown = [(d, a, b) for d, runs in self.rc.coverage().items() for a, b, k in runs if k.startswith("??")]
        orphans = {(d, s // 512) for d, s, _ in self.rc.unlisted_pp20()}
        self.assertTrue(all((d, a) in orphans for d, a, _ in unknown), unknown)


if __name__ == "__main__":
    unittest.main()
