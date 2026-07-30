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

    leading_wrapper_list = (
        len(segments) >= 0x38
        and u32(segments, 8) == 1
        and u32(segments, 0x0C) == 0x40000001
        and u32(segments, 0x10) == 0
        and u32(segments, 0x14) == 0x10
        and u32(segments, 0x18) == u32(segments, 0)
        and u32(segments, 0x1C) == u32(segments, 4)
    )
    list_bytes = segments[0x18:] if leading_wrapper_list else segments
    list_token = u64(list_bytes, 0)
    segment_count = u32(list_bytes, 8)
    encoded_length = u32(list_bytes, 0x0C)
    expected_direct_length = 0x80000000 | len(list_bytes)
    direct_list = encoded_length == expected_direct_length
    trailing_wrapper_list = (
        not leading_wrapper_list
        and encoded_length >= 0x20
        and encoded_length + 0x18 == len(list_bytes)
    )
    if not direct_list and not trailing_wrapper_list:
        raise ValueError(
            f"encoded length {encoded_length:#x} is neither direct "
            f"{expected_direct_length:#x} nor a 0x18-byte trailing-wrapper offset"
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
    form_name = (
        "leading-wrapper"
        if leading_wrapper_list
        else ("direct" if direct_list else "trailing-wrapper")
    )
    print(
        f"list_token={list_token:#x} count={segment_count} "
        f"encoded_length={encoded_length:#x} "
        f"form={form_name}"
    )

    descriptor_bytes = list_bytes if direct_list else list_bytes[:encoded_length]
    command_start = 0
    if leading_wrapper_list:
        if len(commands) < 0x10:
            raise ValueError("leading-wrapper KCMD record is truncated")
        if (
            u32(commands, 0) != 9
            or u32(commands, 4) != 0x10
            or u32(commands, 8) != 1
        ):
            raise ValueError("leading-wrapper KCMD framing is unknown")
        print(
            f"leading_wrapper generation={u32(segments, 4)} "
            "kcmd=0x0..0x10 type=0x9"
        )
        command_start = 0x10
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

        range_offset = find_unique_range(
            descriptor_bytes, command_start, command_end
        )
        if range_offset < 8:
            raise ValueError(f"segment {segment_index} range has no Q header")
        header_offset = range_offset - 8
        if header_offset + 0x20 > len(list_bytes):
            raise ValueError(f"segment {segment_index} header is truncated")

        segment_token = u64(list_bytes, header_offset)
        field_10 = u32(list_bytes, header_offset + 0x10)
        field_14 = u32(list_bytes, header_offset + 0x14)
        resource_count = u32(list_bytes, header_offset + 0x18)
        group_count = u32(list_bytes, header_offset + 0x1C)
        entry_end = header_offset + 0x20 + group_count * 0x40
        if entry_end > len(list_bytes):
            raise ValueError(
                f"segment {segment_index} descriptor groups are truncated"
            )

        resources: list[tuple[int, int, int]] = []
        for group_index in range(group_count):
            group = header_offset + 0x20 + group_index * 0x40
            valid_count = u16(list_bytes, group + 0x3E)
            if valid_count > 6:
                raise ValueError(
                    f"segment {segment_index} group {group_index} "
                    f"valid count {valid_count} > 6"
                )
            for item_index in range(valid_count):
                gid = u32(list_bytes, group + item_index * 4)
                value = u32(list_bytes, group + 0x18 + item_index * 4)
                flags = u16(list_bytes, group + 0x30 + item_index * 2)
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

    expected_command_end = len(commands)
    if trailing_wrapper_list:
        wrapper = list_bytes[encoded_length:]
        list_magic = u32(list_bytes, 0)
        list_generation = u32(list_bytes, 4)
        wrapper_start = u32(wrapper, 0x10)
        wrapper_end = u32(wrapper, 0x14)
        # Runtime-confirmed by VS Code Simple Browser Aquarium GPU submit 108
        # on 2026-07-30: generation 4 retains the same trailing-wrapper list
        # framing and carries the range [0x210,0x228).  The first mapped submit
        # from an empty post-reboot profile uses the same framing with both
        # generation fields zero and range [0x840,0x870).  Generation 1 has
        # not been observed and remains rejected.
        if list_generation not in (0, 2, 3, 4):
            raise ValueError(
                f"unobserved trailing-wrapper list generation {list_generation}"
            )
        if u32(wrapper, 0) != list_magic:
            raise ValueError("trailing-wrapper magic does not match outer list")
        if u32(wrapper, 4) != list_generation:
            raise ValueError(
                "trailing-wrapper generation does not match outer list"
            )
        if u32(wrapper, 8) != 1 or u32(wrapper, 0x0C) != 0xC0000001:
            raise ValueError("trailing-wrapper record framing is unknown")
        if wrapper_start != command_start or wrapper_end != len(commands):
            raise ValueError(
                f"trailing-wrapper KCMD range {wrapper_start:#x}..{wrapper_end:#x} "
                f"does not follow decoded chain at {command_start:#x} or file end"
            )
        wrapper_bytes = wrapper_end - wrapper_start
        if wrapper_bytes not in (0x18, 0x30):
            raise ValueError(
                f"trailing-wrapper KCMD size {wrapper_bytes:#x} is not one/two records"
            )
        wrapper_type = u32(commands, wrapper_start)
        wrapper_opcode = u32(commands, wrapper_start + 8)
        if wrapper_type == 3:
            for wrapper_index in range(wrapper_bytes // 0x18):
                offset = wrapper_start + wrapper_index * 0x18
                if (
                    u32(commands, offset) != 3
                    or u32(commands, offset + 4) != 0x18
                    or u32(commands, offset + 8) != wrapper_opcode
                ):
                    raise ValueError(
                        f"trailing KCMD wrapper {wrapper_index} framing is unknown"
                    )
        elif not (
            wrapper_bytes == 0x18
            and wrapper_type == 5
            and u32(commands, wrapper_start + 4) == 0x18
            and 1 <= wrapper_opcode <= 3
            and u32(commands, wrapper_start + 0x0C) == 0
            and u32(commands, wrapper_start + 0x10) == 1
            and u32(commands, wrapper_start + 0x14) == 0
        ):
            raise ValueError("trailing type-5 KCMD wrapper framing is unknown")
        print(
            f"trailing_wrapper generation={list_generation} "
            f"kcmd={wrapper_start:#x}..{wrapper_end:#x} "
            f"records={wrapper_bytes // 0x18} type={wrapper_type:#x} "
            f"opcode_or_ordinal={wrapper_opcode:#x}"
        )
        expected_command_end = wrapper_start

    if command_start != expected_command_end:
        raise ValueError(
            f"decoded KCMD chain ends at {command_start:#x}, "
            f"expected descriptor-backed end is {expected_command_end:#x}"
        )
    gids = " ".join(f"{gid:#x}" for gid in sorted(unique_gids))
    print(f"unique_gids={len(unique_gids)} {gids}")


if __name__ == "__main__":
    main()
