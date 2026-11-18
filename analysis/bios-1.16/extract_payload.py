#!/usr/bin/env python3
"""Extract files described by the FE&FR&SH table appended to Planck_BIOS_1.16.exe."""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path


MARKER = b"FE&FR&SH"
RECORD_SIZE = 0x30


def read_record(blob: bytes, offset: int) -> tuple[int, int, str]:
    size, data_offset, name_length = struct.unpack_from("<III", blob, offset)
    if name_length == 0 or name_length > RECORD_SIZE - 0xC:
        raise ValueError(f"invalid name length {name_length} at 0x{offset:x}")
    raw_name = blob[offset + 0xC : offset + 0xC + name_length]
    name = raw_name.rstrip(b"\0").decode("ascii")
    return size, data_offset, name


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} PLANCK_EXE OUTPUT_DIR", file=sys.stderr)
        return 2

    executable = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    blob = executable.read_bytes()

    marker_offset = blob.rfind(MARKER)
    if marker_offset < 0:
        raise ValueError("FE&FR&SH payload table not found")

    count = struct.unpack_from("<I", blob, marker_offset + 8)[0]
    table_offset = marker_offset + 0xC
    print(f"marker=0x{marker_offset:x} count={count} table=0x{table_offset:x}")

    output_dir.mkdir(parents=True, exist_ok=True)
    ranges: list[tuple[int, int, str]] = []

    for index in range(count):
        record_offset = table_offset + index * RECORD_SIZE
        size, data_offset, name = read_record(blob, record_offset)
        data_end = data_offset + size
        if not data_offset < data_end <= marker_offset:
            raise ValueError(
                f"{name}: invalid range 0x{data_offset:x}..0x{data_end:x}"
            )
        data = blob[data_offset:data_end]
        target = output_dir / name
        target.write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        ranges.append((data_offset, data_end, name))
        print(
            f"[{index}] {name} offset=0x{data_offset:x} size={size} "
            f"end=0x{data_end:x} sha256={digest}"
        )

    ordered = sorted(ranges)
    for previous, current in zip(ordered, ordered[1:]):
        if previous[1] > current[0]:
            raise ValueError(f"overlapping payloads: {previous[2]} and {current[2]}")

    print("payload table and file ranges validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
