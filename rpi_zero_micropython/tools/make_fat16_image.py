#!/usr/bin/env python3
"""Build a raw MBR+FAT16 disk image from a staging directory."""

from __future__ import annotations

import argparse
import math
import os
import struct
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable


SECTOR_SIZE = 512
PARTITION_START_LBA = 2048
RESERVED_SECTORS = 1
NUMBER_OF_FATS = 2
ROOT_ENTRY_COUNT = 512
MEDIA_DESCRIPTOR = 0xF8
FAT16_EOC = 0xFFFF
ALLOWED_SHORT_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$%'-_@~`!(){}^#&")


@dataclass
class ImageNode:
    """Represent one staged filesystem entry inside the FAT image."""

    path: Path
    relative_path: Path
    short_name: bytes
    is_dir: bool
    size: int
    modified: datetime
    children: list["ImageNode"] = field(default_factory=list)
    first_cluster: int = 0
    cluster_count: int = 0


@dataclass
class FatLayout:
    """Hold the derived FAT16 layout values for the partition."""

    total_sectors: int
    sectors_per_cluster: int
    fat_sectors: int
    root_dir_sectors: int
    first_fat_sector: int
    root_dir_sector: int
    data_sector: int
    cluster_count: int


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments for the image builder."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="Directory to image")
    parser.add_argument("--output", required=True, help="Output raw image path")
    parser.add_argument("--size-mb", type=int, default=64, help="Image size in MiB")
    parser.add_argument(
        "--volume-label",
        default="RPI_MICROPY",
        help="FAT volume label, up to 11 characters",
    )
    return parser.parse_args()


def sanitize_component(component: str) -> str:
    """Convert one FAT short-name component to a valid uppercase token."""

    result = []
    for char in component.upper():
        if char in ALLOWED_SHORT_CHARS:
            result.append(char)
        elif char == " ":
            continue
        else:
            result.append("_")
    sanitized = "".join(result).strip(".")
    return sanitized or "_"


def split_name(name: str) -> tuple[str, str]:
    """Split one path name into base and extension components."""

    if "." in name and not name.startswith("."):
        base, ext = name.rsplit(".", 1)
    else:
        base, ext = name, ""
    return base, ext


def make_short_name(name: str, used_names: set[bytes]) -> bytes:
    """Create one unique FAT 8.3 short name entry."""

    base, ext = split_name(name)
    base_sanitized = sanitize_component(base)
    ext_sanitized = sanitize_component(ext)[:3]

    preferred = base_sanitized[:8].ljust(8) + ext_sanitized.ljust(3)
    preferred_bytes = preferred.encode("ascii")

    normalized = name.upper()
    exact_base = base_sanitized == base.upper() and len(base_sanitized) <= 8
    exact_ext = ext_sanitized == ext.upper() and len(ext_sanitized) <= 3
    if exact_base and exact_ext and preferred_bytes not in used_names and normalized == name.upper():
        used_names.add(preferred_bytes)
        return preferred_bytes

    stem = base_sanitized[:6]
    for index in range(1, 10000):
        alias_base = f"{stem}~{index}"[:8]
        alias = alias_base.ljust(8) + ext_sanitized.ljust(3)
        alias_bytes = alias.encode("ascii")
        if alias_bytes not in used_names:
            used_names.add(alias_bytes)
            return alias_bytes
    raise ValueError(f"Could not create a unique FAT short name for {name!r}")


def to_dos_datetime(timestamp: datetime) -> tuple[int, int]:
    """Encode one datetime into DOS date and time words."""

    year = min(max(timestamp.year, 1980), 2107)
    dos_date = ((year - 1980) << 9) | (timestamp.month << 5) | timestamp.day
    dos_time = (timestamp.hour << 11) | (timestamp.minute << 5) | (timestamp.second // 2)
    return dos_date, dos_time


def build_tree(source_dir: Path) -> ImageNode:
    """Walk the staging directory and build an in-memory node tree."""

    stat_result = source_dir.stat()
    root = ImageNode(
        path=source_dir,
        relative_path=Path("."),
        short_name=b" " * 11,
        is_dir=True,
        size=0,
        modified=datetime.fromtimestamp(stat_result.st_mtime),
    )
    populate_children(root)
    return root


def populate_children(node: ImageNode) -> None:
    """Populate child nodes for one directory node."""

    used_names: set[bytes] = set()
    children: list[ImageNode] = []
    for child_path in sorted(node.path.iterdir(), key=lambda path: path.name.lower()):
        stat_result = child_path.stat()
        child = ImageNode(
            path=child_path,
            relative_path=node.relative_path / child_path.name,
            short_name=make_short_name(child_path.name, used_names),
            is_dir=child_path.is_dir(),
            size=stat_result.st_size,
            modified=datetime.fromtimestamp(stat_result.st_mtime),
        )
        if child.is_dir:
            populate_children(child)
        children.append(child)
    node.children = children


def choose_sectors_per_cluster(total_sectors: int) -> int:
    """Pick a conservative FAT16 cluster size for the requested image size."""

    mib = total_sectors // 2048
    if mib <= 16:
        return 2
    if mib <= 128:
        return 4
    return 8


def compute_layout(total_sectors: int) -> FatLayout:
    """Compute the final FAT16 partition layout."""

    sectors_per_cluster = choose_sectors_per_cluster(total_sectors)
    root_dir_sectors = (ROOT_ENTRY_COUNT * 32 + (SECTOR_SIZE - 1)) // SECTOR_SIZE
    fat_sectors = 1

    while True:
        data_sectors = total_sectors - RESERVED_SECTORS - root_dir_sectors - NUMBER_OF_FATS * fat_sectors
        cluster_count = data_sectors // sectors_per_cluster
        next_fat_sectors = math.ceil((cluster_count + 2) * 2 / SECTOR_SIZE)
        if next_fat_sectors == fat_sectors:
            break
        fat_sectors = next_fat_sectors

    if cluster_count < 4085 or cluster_count >= 65525:
        raise ValueError(
            f"Image size yields {cluster_count} clusters, which is outside FAT16 limits"
        )

    first_fat_sector = RESERVED_SECTORS
    root_dir_sector = first_fat_sector + NUMBER_OF_FATS * fat_sectors
    data_sector = root_dir_sector + root_dir_sectors
    return FatLayout(
        total_sectors=total_sectors,
        sectors_per_cluster=sectors_per_cluster,
        fat_sectors=fat_sectors,
        root_dir_sectors=root_dir_sectors,
        first_fat_sector=first_fat_sector,
        root_dir_sector=root_dir_sector,
        data_sector=data_sector,
        cluster_count=cluster_count,
    )


def iter_nodes(root: ImageNode) -> Iterable[ImageNode]:
    """Yield all nodes in depth-first order."""

    for child in root.children:
        yield child
        if child.is_dir:
            yield from iter_nodes(child)


def directory_entry_count(node: ImageNode) -> int:
    """Return the number of on-disk directory entries for one directory."""

    return len(node.children) + 2


def assign_clusters(root: ImageNode, layout: FatLayout) -> None:
    """Assign clusters to all directory and file nodes."""

    cluster_bytes = layout.sectors_per_cluster * SECTOR_SIZE
    next_cluster = 2

    for node in iter_nodes(root):
        if node.is_dir:
            bytes_needed = directory_entry_count(node) * 32
            node.cluster_count = max(1, math.ceil(bytes_needed / cluster_bytes))
            node.first_cluster = next_cluster
            next_cluster += node.cluster_count
        elif node.size > 0:
            node.cluster_count = math.ceil(node.size / cluster_bytes)
            node.first_cluster = next_cluster
            next_cluster += node.cluster_count

    used_clusters = next_cluster - 2
    if used_clusters > layout.cluster_count:
        raise ValueError(
            f"Image is too small: need {used_clusters} clusters, have {layout.cluster_count}"
        )


def pack_dirent(short_name: bytes, attr: int, modified: datetime, first_cluster: int, size: int) -> bytes:
    """Pack one FAT directory entry."""

    dos_date, dos_time = to_dos_datetime(modified)
    entry = bytearray(32)
    entry[0:11] = short_name
    entry[11] = attr
    struct.pack_into("<H", entry, 14, dos_time)
    struct.pack_into("<H", entry, 16, dos_date)
    struct.pack_into("<H", entry, 18, dos_date)
    struct.pack_into("<H", entry, 20, 0)
    struct.pack_into("<H", entry, 22, dos_time)
    struct.pack_into("<H", entry, 24, dos_date)
    struct.pack_into("<H", entry, 26, first_cluster)
    struct.pack_into("<I", entry, 28, size)
    return bytes(entry)


def build_directory_bytes(node: ImageNode, parent: ImageNode | None, cluster_bytes: int) -> bytes:
    """Create the on-disk byte stream for one directory body."""

    entries = bytearray()
    if parent is not None:
        entries.extend(pack_dirent(b".          ", 0x10, node.modified, node.first_cluster, 0))
        parent_cluster = parent.first_cluster if parent.relative_path != Path(".") else 0
        entries.extend(pack_dirent(b"..         ", 0x10, parent.modified, parent_cluster, 0))

    for child in node.children:
        attr = 0x10 if child.is_dir else 0x20
        entries.extend(pack_dirent(child.short_name, attr, child.modified, child.first_cluster, child.size))

    if parent is None and len(entries) > ROOT_ENTRY_COUNT * 32:
        raise ValueError("Root directory exceeds FAT16 fixed root directory size")

    padded_size = len(entries)
    if parent is None:
        padded_size = ROOT_ENTRY_COUNT * 32
    else:
        padded_size = math.ceil(len(entries) / cluster_bytes) * cluster_bytes
    entries.extend(b"\x00" * (padded_size - len(entries)))
    return bytes(entries)


def cluster_offset(layout: FatLayout, cluster: int) -> int:
    """Translate one data cluster number to an image byte offset."""

    data_sector = PARTITION_START_LBA + layout.data_sector
    return (data_sector + (cluster - 2) * layout.sectors_per_cluster) * SECTOR_SIZE


def write_boot_sector(image, layout: FatLayout, total_image_sectors: int, label: bytes) -> None:
    """Write the MBR and FAT16 boot sector."""

    mbr = bytearray(SECTOR_SIZE)
    entry = bytearray(16)
    entry[0] = 0x00
    entry[1:4] = b"\xfe\xff\xff"
    entry[4] = 0x0E
    entry[5:8] = b"\xfe\xff\xff"
    struct.pack_into("<I", entry, 8, PARTITION_START_LBA)
    struct.pack_into("<I", entry, 12, layout.total_sectors)
    mbr[446:462] = entry
    mbr[510:512] = b"\x55\xaa"
    image.seek(0)
    image.write(mbr)

    boot = bytearray(SECTOR_SIZE)
    boot[0:3] = b"\xeb\x3c\x90"
    boot[3:11] = b"MSDOS5.0"
    struct.pack_into("<H", boot, 11, SECTOR_SIZE)
    boot[13] = layout.sectors_per_cluster
    struct.pack_into("<H", boot, 14, RESERVED_SECTORS)
    boot[16] = NUMBER_OF_FATS
    struct.pack_into("<H", boot, 17, ROOT_ENTRY_COUNT)
    if layout.total_sectors < 65536:
        struct.pack_into("<H", boot, 19, layout.total_sectors)
    else:
        struct.pack_into("<H", boot, 19, 0)
    boot[21] = MEDIA_DESCRIPTOR
    struct.pack_into("<H", boot, 22, layout.fat_sectors)
    struct.pack_into("<H", boot, 24, 63)
    struct.pack_into("<H", boot, 26, 255)
    struct.pack_into("<I", boot, 28, PARTITION_START_LBA)
    if layout.total_sectors >= 65536:
        struct.pack_into("<I", boot, 32, layout.total_sectors)
    boot[36] = 0x80
    boot[38] = 0x29
    serial = int(datetime.now().timestamp()) & 0xFFFFFFFF
    struct.pack_into("<I", boot, 39, serial)
    boot[43:54] = label.ljust(11, b" ")
    boot[54:62] = b"FAT16   "
    boot[510:512] = b"\x55\xaa"
    image.seek(PARTITION_START_LBA * SECTOR_SIZE)
    image.write(boot)
    truncate_size = total_image_sectors * SECTOR_SIZE
    image.truncate(truncate_size)


def write_fat_tables(image, layout: FatLayout, root: ImageNode) -> None:
    """Write both FAT16 tables from the assigned cluster chains."""

    fat_entries = [0] * (layout.cluster_count + 2)
    fat_entries[0] = 0xFFF8
    fat_entries[1] = FAT16_EOC

    for node in iter_nodes(root):
        if node.cluster_count == 0:
            continue
        for index in range(node.cluster_count):
            cluster = node.first_cluster + index
            fat_entries[cluster] = cluster + 1 if index + 1 < node.cluster_count else FAT16_EOC

    fat_bytes = bytearray(layout.fat_sectors * SECTOR_SIZE)
    for index, value in enumerate(fat_entries):
        struct.pack_into("<H", fat_bytes, index * 2, value)

    fat_offset = (PARTITION_START_LBA + layout.first_fat_sector) * SECTOR_SIZE
    for fat_index in range(NUMBER_OF_FATS):
        image.seek(fat_offset + fat_index * layout.fat_sectors * SECTOR_SIZE)
        image.write(fat_bytes)


def write_directory_data(image, layout: FatLayout, root: ImageNode) -> None:
    """Write root and subdirectory bodies to the image."""

    cluster_bytes = layout.sectors_per_cluster * SECTOR_SIZE
    root_bytes = build_directory_bytes(root, None, cluster_bytes)
    root_offset = (PARTITION_START_LBA + layout.root_dir_sector) * SECTOR_SIZE
    image.seek(root_offset)
    image.write(root_bytes)

    for node in iter_nodes(root):
        if not node.is_dir:
            continue
        directory_bytes = build_directory_bytes(node, root if node.relative_path.parent == Path(".") else find_parent(root, node), cluster_bytes)
        image.seek(cluster_offset(layout, node.first_cluster))
        image.write(directory_bytes)


def find_parent(root: ImageNode, child: ImageNode) -> ImageNode:
    """Find the parent node for one child node."""

    if child.relative_path.parent == Path("."):
        return root
    target = child.relative_path.parent
    for node in iter_nodes(root):
        if node.relative_path == target:
            return node
    raise ValueError(f"Could not resolve parent for {child.relative_path}")


def write_file_data(image, layout: FatLayout, root: ImageNode) -> None:
    """Write all staged file payloads into data clusters."""

    cluster_bytes = layout.sectors_per_cluster * SECTOR_SIZE
    for node in iter_nodes(root):
        if node.is_dir or node.cluster_count == 0:
            continue
        image.seek(cluster_offset(layout, node.first_cluster))
        with node.path.open("rb") as source_file:
            payload = source_file.read()
        image.write(payload)
        padding = node.cluster_count * cluster_bytes - len(payload)
        if padding:
            image.write(b"\x00" * padding)


def normalize_label(label: str) -> bytes:
    """Normalize a volume label to an 11-byte FAT field."""

    sanitized = sanitize_component(label)[:11]
    if not sanitized:
        raise ValueError("Volume label must contain at least one usable character")
    return sanitized.encode("ascii")


def create_image(source_dir: Path, output_path: Path, size_mb: int, label: str) -> None:
    """Create the final raw disk image from the staged source directory."""

    if size_mb < 8:
        raise ValueError("Image size must be at least 8 MiB for FAT16")
    if not source_dir.is_dir():
        raise ValueError(f"Source directory does not exist: {source_dir}")

    total_image_sectors = size_mb * 1024 * 1024 // SECTOR_SIZE
    if total_image_sectors <= PARTITION_START_LBA:
        raise ValueError("Image is too small to contain the partition offset")

    layout = compute_layout(total_image_sectors - PARTITION_START_LBA)
    root = build_tree(source_dir)
    assign_clusters(root, layout)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb+") as image:
        write_boot_sector(image, layout, total_image_sectors, normalize_label(label))
        write_fat_tables(image, layout, root)
        write_directory_data(image, layout, root)
        write_file_data(image, layout, root)


def main() -> int:
    """Run the command-line entry point."""

    args = parse_args()
    create_image(
        source_dir=Path(args.source),
        output_path=Path(args.output),
        size_mb=args.size_mb,
        label=args.volume_label,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
