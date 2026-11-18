#!/usr/bin/env python3
"""Extract raw files from the UEFI Firmware Volume inside the Planck FMP capsule."""

from __future__ import annotations

import hashlib
import json
import struct
import sys
import uuid
from pathlib import Path


FV_SIGNATURE = b"_FVH"


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(
            f"usage: {sys.argv[0]} CAPSULE OUTPUT_DIR [FV_FILE_OFFSET]",
            file=sys.stderr,
        )
        return 2

    capsule_path = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    blob = capsule_path.read_bytes()

    if len(sys.argv) == 4:
        fv_offset = int(sys.argv[3], 0)
        if blob[fv_offset + 0x28 : fv_offset + 0x2C] != FV_SIGNATURE:
            raise ValueError(f"no firmware volume at 0x{fv_offset:x}")
    else:
        signature_offset = blob.find(FV_SIGNATURE)
        if signature_offset < 0:
            raise ValueError("UEFI firmware volume signature not found")
        fv_offset = signature_offset - 0x28
    fv_length = struct.unpack_from("<Q", blob, fv_offset + 0x20)[0]
    header_length = struct.unpack_from("<H", blob, fv_offset + 0x30)[0]
    extended_header_offset = struct.unpack_from("<H", blob, fv_offset + 0x34)[0]
    fv_end = fv_offset + fv_length
    if header_length < 0x38 or fv_end > len(blob):
        raise ValueError("invalid UEFI firmware volume header")

    body_offset = fv_offset + header_length
    if extended_header_offset:
        extended_header = fv_offset + extended_header_offset
        extended_header_size = struct.unpack_from(
            "<I", blob, extended_header + 0x10
        )[0]
        body_offset = align_up(extended_header + extended_header_size, 8)

    output_dir.mkdir(parents=True, exist_ok=True)
    manifest: list[dict[str, object]] = []
    offset = body_offset

    for index in range(256):
        if offset + 24 > fv_end:
            break
        if blob[offset : offset + 3] == b"\xff\xff\xff":
            break

        file_guid = uuid.UUID(bytes_le=blob[offset : offset + 16])
        integrity_check = struct.unpack_from("<H", blob, offset + 0x10)[0]
        file_type = blob[offset + 0x12]
        attributes = blob[offset + 0x13]
        size = int.from_bytes(blob[offset + 0x14 : offset + 0x17], "little")
        state = blob[offset + 0x17]
        file_end = offset + size

        if size < 24 or file_end > fv_end:
            raise ValueError(f"invalid FFS file at 0x{offset:x}: size=0x{size:x}")

        payload = blob[offset + 24 : file_end]
        digest = hashlib.sha256(payload).hexdigest()
        name = f"{index:02d}_{file_guid}.bin"
        (output_dir / name).write_bytes(payload)
        manifest.append(
            {
                "index": index,
                "name": name,
                "offset": offset,
                "file_end": file_end,
                "size": size,
                "payload_size": len(payload),
                "guid": str(file_guid),
                "type": file_type,
                "attributes": attributes,
                "integrity_check": integrity_check,
                "state": state,
                "sha256": digest,
                "magic": payload[:16].hex(),
            }
        )
        offset = fv_offset + align_up(offset - fv_offset + size, 8)

    (output_dir / "manifest.json").write_text(
        json.dumps(
            {
                "firmware_volume": {
                    "offset": fv_offset,
                    "length": fv_length,
                    "header_length": header_length,
                    "extended_header_offset": extended_header_offset,
                    "body_offset": body_offset,
                },
                "files": manifest,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    for record in manifest:
        print(
            f"[{record['index']:02d}] {record['guid']} "
            f"offset=0x{record['offset']:x} size=0x{record['payload_size']:x} "
            f"magic={record['magic']} sha256={record['sha256']}"
        )
    print(f"extracted {len(manifest)} FFS files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
