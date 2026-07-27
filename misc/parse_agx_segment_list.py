"""Decode captured IOGPU segment/resource-list records.

Invoke with the interpreter because AMFI blocks shebang execution on the
target device:

    python3 misc/parse_agx_segment_list.py post_kcmd.bin post_segments.bin

The layout is taken from the runtime Objective-C type encoding in the actual
iOS 16.3 IOGPU image:

    IOGPUSegmentListHeader=QII[0{...=QIIIIII[0{...=[6I][6I][6S]SS}]}]

Names not present in that encoding remain deliberately neutral below.  The
last uint16 in every 0x40-byte group is treated as the valid-entry count only
after validating that it is <= 6 and that all group counts sum to the resource
count in the enclosing header.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import struct


def u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def u64(data: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", data, offset)[0]


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Decode an IOGPU KCMD segment list captured by libmachook"
    )
    parser.add_argument("kcmd", type=Path)
    parser.add_argument("segments", type=Path)
    return parser.parse_args()


def find_unique_range(data: bytes, start: int, end: int) -> int:
    needle = struct.pack("<II", start, end)
    matches = [
        offset
        for offset in range(0, len(data) - len(needle) + 1, 8)
        if data[offset : offset + len(needle)] == needle
    ]
    if len(matches) != 1:
        raise ValueError(
            f"KCMD range {start:#x}..{end:#x} occurs {len(matches)} times"
        )
    return matches[0]


def main() -> None:
    arguments = parse_arguments()
    commands = arguments.kcmd.read_bytes()
    segments = arguments.segments.read_bytes()
    if len(segments) < 0x10:
        raise ValueError("segment list is shorter than its 0x10-byte header")

    list_token = u64(segments, 0)
    segment_count = u32(segments, 8)
    encoded_length = u32(segments, 0x0C)
    expected_length = 0x80000000 | len(segments)
    if encoded_length != expected_length:
        raise ValueError(
            f"encoded length {encoded_length:#x} != {expected_length:#x}"
        )
    if segment_count == 0 or segment_count > 1024:
        raise ValueError(f"implausible segment count {segment_count}")

    print(
        f"kcmd={arguments.kcmd} bytes={len(commands):#x} "
        f"sha256={hashlib.sha256(commands).hexdigest()}"
    )
    print(
        f"segments={arguments.segments} bytes={len(segments):#x} "
        f"sha256={hashlib.sha256(segments).hexdigest()}"
    )
    print(
        f"list_token={list_token:#x} count={segment_count} "
        f"encoded_length={encoded_length:#x}"
    )

    command_start = 0
    unique_gids: set[int] = set()
    for segment_index in range(segment_count):
        if command_start + 8 > len(commands):
            raise ValueError(f"segment {segment_index} KCMD header is truncated")
        command_type = u32(commands, command_start)
        command_span = u32(commands, command_start + 4)
        command_end = command_start + command_span
        if command_span < 8 or command_end > len(commands):
            raise ValueError(
                f"segment {segment_index} invalid KCMD span {command_span:#x}"
            )

        range_offset = find_unique_range(segments, command_start, command_end)
        if range_offset < 8:
            raise ValueError(f"segment {segment_index} range has no Q header")
        header_offset = range_offset - 8
        if header_offset + 0x20 > len(segments):
            raise ValueError(f"segment {segment_index} header is truncated")

        segment_token = u64(segments, header_offset)
        field_10 = u32(segments, header_offset + 0x10)
        field_14 = u32(segments, header_offset + 0x14)
        resource_count = u32(segments, header_offset + 0x18)
        group_count = u32(segments, header_offset + 0x1C)
        entry_end = header_offset + 0x20 + group_count * 0x40
        if entry_end > len(segments):
            raise ValueError(f"segment {segment_index} descriptor groups are truncated")

        resources: list[tuple[int, int, int]] = []
        for group_index in range(group_count):
            group = header_offset + 0x20 + group_index * 0x40
            valid_count = u16(segments, group + 0x3E)
            if valid_count > 6:
                raise ValueError(
                    f"segment {segment_index} group {group_index} "
                    f"valid count {valid_count} > 6"
                )
            for item_index in range(valid_count):
                gid = u32(segments, group + item_index * 4)
                value = u32(segments, group + 0x18 + item_index * 4)
                flags = u16(segments, group + 0x30 + item_index * 2)
                resources.append((gid, value, flags))
                unique_gids.add(gid)

        if len(resources) != resource_count:
            raise ValueError(
                f"segment {segment_index} header count {resource_count} "
                f"!= decoded count {len(resources)}"
            )
        print(
            f"segment={segment_index} token={segment_token:#x} "
            f"kcmd={command_start:#x}..{command_end:#x} type={command_type:#x} "
            f"list_header={header_offset:#x} fields10/14={field_10:#x}/{field_14:#x} "
            f"resources={resource_count} groups={group_count}"
        )
        for gid, value, flags in resources:
            print(f"  gid={gid:#x} value={value:#x} flags={flags:#x}")
        command_start = command_end

    if command_start != len(commands):
        raise ValueError(
            f"decoded KCMD chain ends at {command_start:#x}, "
            f"file ends at {len(commands):#x}"
        )
    gids = " ".join(f"{gid:#x}" for gid in sorted(unique_gids))
    print(f"unique_gids={len(unique_gids)} {gids}")


if __name__ == "__main__":
    main()
