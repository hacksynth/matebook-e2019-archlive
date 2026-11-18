#!/usr/bin/env python3
"""List a FAT12 image without mounting it."""

from __future__ import annotations

import struct
import sys
from pathlib import Path


ATTR_LONG_NAME = 0x0F
ATTR_VOLUME_ID = 0x08
ATTR_DIRECTORY = 0x10


class Fat12:
    def __init__(self, data: bytes) -> None:
        self.data = data
        if data[510:512] != b"\x55\xaa" or data[0] not in (0xEB, 0xE9):
            raise ValueError("not a FAT boot sector")

        self.bytes_per_sector = struct.unpack_from("<H", data, 0x0B)[0]
        self.sectors_per_cluster = data[0x0D]
        self.reserved_sectors = struct.unpack_from("<H", data, 0x0E)[0]
        self.fat_count = data[0x10]
        self.root_entries = struct.unpack_from("<H", data, 0x11)[0]
        self.total_sectors = struct.unpack_from("<H", data, 0x13)[0]
        self.fat_sectors = struct.unpack_from("<H", data, 0x16)[0]
        if not self.total_sectors:
            self.total_sectors = struct.unpack_from("<I", data, 0x20)[0]
        if not self.total_sectors:
            self.total_sectors = len(data) // self.bytes_per_sector

        self.root_sectors = (
            self.root_entries * 32 + self.bytes_per_sector - 1
        ) // self.bytes_per_sector
        self.cluster_bytes = self.bytes_per_sector * self.sectors_per_cluster
        self.fat_offset = self.reserved_sectors * self.bytes_per_sector
        self.root_offset = (
            self.reserved_sectors + self.fat_count * self.fat_sectors
        ) * self.bytes_per_sector
        self.data_offset = self.root_offset + self.root_sectors * self.bytes_per_sector
        self.max_clusters = (
            self.total_sectors
            - self.reserved_sectors
            - self.fat_count * self.fat_sectors
            - self.root_sectors
        ) // self.sectors_per_cluster

    def next_cluster(self, cluster: int) -> int:
        entry_offset = self.fat_offset + cluster + cluster // 2
        pair = struct.unpack_from("<H", self.data, entry_offset)[0]
        return (pair >> 4) & 0xFFF if cluster & 1 else pair & 0xFFF

    def read_chain(self, cluster: int, size: int | None = None) -> bytes:
        chunks: list[bytes] = []
        seen: set[int] = set()
        while 2 <= cluster < 0xFF8:
            if cluster in seen:
                raise ValueError(f"cluster loop at {cluster}")
            seen.add(cluster)
            offset = self.data_offset + (cluster - 2) * self.cluster_bytes
            chunks.append(self.data[offset : offset + self.cluster_bytes])
            cluster = self.next_cluster(cluster)
        result = b"".join(chunks)
        return result if size is None else result[:size]

    @staticmethod
    def decode_short_name(entry: bytes) -> str:
        base = entry[:8].decode("cp437").rstrip(" ")
        ext = entry[8:11].decode("cp437").rstrip(" ")
        if base.startswith("\\x05"):
            base = chr(0xE5) + base[1:]
        return f"{base}.{ext}" if ext else base

    @staticmethod
    def decode_lfn(entries: list[bytes]) -> str:
        chars: list[str] = []
        for entry in sorted(entries, key=lambda item: item[0] & 0x1F):
            fragment = entry[1:11] + entry[14:26] + entry[28:32]
            chars.extend(
                fragment.decode("utf-16le", "replace")
                .split("\0", 1)[0]
                .replace("\uffff", "")
            )
        return "".join(chars)

    def walk(self, directory: bytes, prefix: str = "") -> None:
        lfn_entries: list[bytes] = []
        for offset in range(0, len(directory), 32):
            entry = directory[offset : offset + 32]
            if len(entry) < 32 or entry[0] == 0:
                break
            if entry[0] == 0xE5:
                lfn_entries.clear()
                continue

            attributes = entry[11]
            if attributes == ATTR_LONG_NAME:
                lfn_entries.append(entry)
                continue

            name = self.decode_lfn(lfn_entries) if lfn_entries else self.decode_short_name(entry)
            lfn_entries.clear()
            if attributes & ATTR_VOLUME_ID:
                continue
            if name in (".", ".."):
                continue

            cluster = struct.unpack_from("<H", entry, 26)[0]
            size = struct.unpack_from("<I", entry, 28)[0]
            path = f"{prefix}/{name}" if prefix else name
            if attributes & ATTR_DIRECTORY:
                print(f"DIR  {path}")
                if cluster >= 2:
                    self.walk(self.read_chain(cluster), path)
            else:
                print(f"FILE {path} size={size} cluster={cluster}")

    def list(self) -> None:
        print(
            f"sector={self.bytes_per_sector} cluster_sectors={self.sectors_per_cluster} "
            f"fats={self.fat_count} fat_sectors={self.fat_sectors} "
            f"root_entries={self.root_entries} total_sectors={self.total_sectors}"
        )
        root = self.data[self.root_offset : self.root_offset + self.root_entries * 32]
        self.walk(root)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} FAT_IMAGE", file=sys.stderr)
        return 2
    Fat12(Path(sys.argv[1]).read_bytes()).list()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
