"""Unit tests for the FAT16 release image builder."""

from __future__ import annotations

import struct
import tempfile
import unittest
from pathlib import Path

from tools.make_fat16_image import create_image


def read_root_entries(image_bytes: bytes, partition_lba: int) -> list[bytes]:
    """Read populated FAT root directory entries from one generated image."""

    boot_offset = partition_lba * 512
    root_entry_count = struct.unpack_from("<H", image_bytes, boot_offset + 17)[0]
    reserved = struct.unpack_from("<H", image_bytes, boot_offset + 14)[0]
    fats = image_bytes[boot_offset + 16]
    fat_sectors = struct.unpack_from("<H", image_bytes, boot_offset + 22)[0]
    root_dir_sector = partition_lba + reserved + fats * fat_sectors
    root_offset = root_dir_sector * 512
    root_size = root_entry_count * 32

    entries = []
    for index in range(0, root_size, 32):
        entry = image_bytes[root_offset + index : root_offset + index + 32]
        if entry[0] == 0x00:
            break
        entries.append(entry)
    return entries


class MakeFat16ImageTests(unittest.TestCase):
    """Validate the release image builder output."""

    def test_create_image_writes_mbr_boot_sector_and_root_files(self) -> None:
        """Create one image and confirm the basic FAT16 structures are present."""

        with tempfile.TemporaryDirectory() as temp_dir:
            source_dir = Path(temp_dir) / "sdcard"
            source_dir.mkdir()
            (source_dir / "config.txt").write_text("kernel=firmware.img\n", encoding="ascii")
            (source_dir / "firmware.img").write_bytes(b"firmware")
            (source_dir / "bootcode.bin").write_bytes(b"bootcode")
            output_path = Path(temp_dir) / "release.img"

            create_image(source_dir, output_path, 16, "RPI_MICROPY")
            image_bytes = output_path.read_bytes()

        self.assertEqual(image_bytes[510:512], b"\x55\xaa")
        partition_lba = struct.unpack_from("<I", image_bytes, 454)[0]
        self.assertEqual(partition_lba, 2048)
        self.assertEqual(image_bytes[450], 0x0E)

        boot_offset = partition_lba * 512
        self.assertEqual(image_bytes[boot_offset + 510 : boot_offset + 512], b"\x55\xaa")
        self.assertEqual(struct.unpack_from("<H", image_bytes, boot_offset + 11)[0], 512)
        self.assertEqual(image_bytes[boot_offset + 54 : boot_offset + 62], b"FAT16   ")

        root_names = {entry[:11] for entry in read_root_entries(image_bytes, partition_lba)}
        self.assertIn(b"CONFIG  TXT", root_names)
        self.assertIn(b"FIRMWAREIMG", root_names)
        self.assertIn(b"BOOTCODEBIN", root_names)

    def test_create_image_generates_short_alias_for_long_names(self) -> None:
        """Create one image with a long filename and confirm it is aliased."""

        with tempfile.TemporaryDirectory() as temp_dir:
            source_dir = Path(temp_dir) / "sdcard"
            source_dir.mkdir()
            (source_dir / "verylongname.txt").write_text("alias", encoding="ascii")
            output_path = Path(temp_dir) / "release.img"

            create_image(source_dir, output_path, 16, "RPI_MICROPY")
            image_bytes = output_path.read_bytes()

        partition_lba = struct.unpack_from("<I", image_bytes, 454)[0]
        root_names = {entry[:11] for entry in read_root_entries(image_bytes, partition_lba)}
        self.assertIn(b"VERYLO~1TXT", root_names)


if __name__ == "__main__":
    unittest.main()
