#!/usr/bin/env python3
"""Reassemble selected AIR modules in an iOS/macOS MTLB for Mac Catalyst.

This is a structural target conversion, not a loader/check bypass. Selected
AIR modules are normally round-tripped through llvm-dis/llvm-as with their
target triple changed from iOS/macOS to macabi. For legacy Apple AIR whose
bitcode dialect an upstream llvm-as cannot reproduce, a same-length target
triple can instead be patched in place. The MTLB function records receive the
real new byte sizes, SHA-256 hashes, and bitcode offsets; the container header
and trailing-section offsets are then rebuilt around the new bitcode section.

The parser follows the tag/section layout documented by YuAo's
MetalLibraryArchive and validates each input function hash before touching it.
It deliberately accepts only an iOS/macOS executable MTLB and fails closed on
tags or section layouts that it does not understand.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import struct
import subprocess
import tempfile


MACOS_PLATFORM = 0x8001
IOS_PLATFORM = 0x0001
MACOS_TARGET_OS = 0x81
IOS_TARGET_OS = 0x82
MACABI_TARGET_OS = 0x86
UNKNOWN_TARGET_OS = 0x00
CURRENT_MTLB_FILE_VERSION = (2, 7)
MTLB_HEADER_SIZE = 88
OFFSET_SECTION_TAGS = {"HDYN", "VLST", "ILST", "HSRD", "HSRC", "RLST"}
OUTPUT_CONTAINER_TARGETS = {
    "macabi": (MACOS_PLATFORM, MACABI_TARGET_OS),
    "ios": (IOS_PLATFORM, IOS_TARGET_OS),
    "macos": (MACOS_PLATFORM, MACOS_TARGET_OS),
}


def target_triple_matches_container(target_triple: str,
                                    container_target: str) -> bool:
    if container_target == "macabi":
        return re.fullmatch(
            r"air64-apple-ios[0-9]+(?:\.[0-9]+){0,2}-macabi",
            target_triple,
        ) is not None
    if container_target == "ios":
        return re.fullmatch(
            r"air64-apple-ios[0-9]+(?:\.[0-9]+){0,2}",
            target_triple,
        ) is not None
    if container_target == "macos":
        return re.fullmatch(
            r"air64-apple-macosx[0-9]+(?:\.[0-9]+){0,2}",
            target_triple,
        ) is not None
    return False


def retarget_air_in_place(module: bytes, name: str,
                          target_triple: str) -> bytes:
    """Replace one same-length AIR target without re-encoding Apple bitcode."""
    pattern = re.compile(
        rb"air64-apple-(?:ios|macosx)[0-9]+(?:\.[0-9]+){0,2}"
    )
    matches = list(pattern.finditer(module))
    if len(matches) != 1:
        raise ValueError(
            f"{name}: expected exactly one AIR target triple, "
            f"found {len(matches)}"
        )
    replacement = target_triple.encode("ascii")
    match = matches[0]
    if len(replacement) != match.end() - match.start():
        source = match.group().decode("ascii")
        raise ValueError(
            f"{name}: in-place AIR target must remain {len(source)} bytes "
            f"({source!r} -> {target_triple!r})"
        )
    rebuilt = bytearray(module)
    rebuilt[match.start():match.end()] = replacement
    return bytes(rebuilt)


def u16(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u32(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def u64(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<Q", data, offset)[0]


def parse_function_records(data: bytes | bytearray) -> list[dict[str, object]]:
    function_offset = u64(data, 24)
    function_size = u64(data, 32)
    if function_offset < MTLB_HEADER_SIZE or function_offset + function_size >= len(data):
        raise ValueError("invalid function-list bounds")
    cursor = function_offset
    count = u32(data, cursor)
    cursor += 4
    records: list[dict[str, object]] = []
    for index in range(count):
        group_start = cursor
        group_size = u32(data, cursor)
        cursor += 4
        tags: dict[str, tuple[int, int]] = {}
        while True:
            name_bytes = bytes(data[cursor : cursor + 4])
            cursor += 4
            try:
                name = name_bytes.decode("ascii")
            except UnicodeDecodeError as error:
                raise ValueError(f"function {index}: invalid tag name") from error
            if name == "ENDT":
                break
            size = u16(data, cursor)
            cursor += 2
            if name in tags:
                raise ValueError(f"function {index}: duplicate {name} tag")
            tags[name] = (cursor, size)
            cursor += size
        if cursor - group_start != group_size:
            raise ValueError(f"function {index}: tag-group size mismatch")
        required = {"NAME", "HASH", "OFFT", "MDSZ"}
        if not required.issubset(tags):
            raise ValueError(f"function {index}: incomplete function record")
        if tags["HASH"][1] != 32 or tags["OFFT"][1] != 24 or tags["MDSZ"][1] != 8:
            raise ValueError(f"function {index}: unexpected fixed tag size")
        name_offset, name_size = tags["NAME"]
        name_bytes = bytes(data[name_offset : name_offset + name_size])
        if not name_bytes.endswith(b"\0"):
            raise ValueError(f"function {index}: NAME is not NUL-terminated")
        records.append({
            "index": index,
            "name": name_bytes[:-1].decode("utf-8"),
            "tags": tags,
            "bitcode_offset": u64(data, tags["OFFT"][0] + 16),
            "bitcode_size": u64(data, tags["MDSZ"][0]),
        })
    # The header's function-list size excludes the initial UInt32 count but
    # includes every group.  Therefore the cursor ends four bytes after
    # function_offset + function_size, with the final group's ENDT occupying
    # the four bytes at that advertised end position.
    if cursor != function_offset + function_size + 4:
        raise ValueError("function-list size does not end after final group")
    if bytes(data[cursor - 4 : cursor]) != b"ENDT":
        raise ValueError("function-list ENDT marker is missing")
    return records


def parse_header_extension_tags(data: bytearray) -> list[tuple[str, int, int]]:
    function_end = u64(data, 24) + u64(data, 32) + 4
    public_offset = u64(data, 40)
    if function_end == public_offset:
        return []
    if function_end > public_offset:
        raise ValueError("header extension overlaps public metadata")
    tags: list[tuple[str, int, int]] = []
    cursor = function_end
    while cursor < public_offset:
        name = bytes(data[cursor : cursor + 4]).decode("ascii")
        cursor += 4
        if name == "ENDT":
            if cursor != public_offset:
                raise ValueError("unexpected bytes after header extension ENDT")
            return tags
        size = u16(data, cursor)
        cursor += 2
        tags.append((name, cursor, size))
        cursor += size
    raise ValueError("header extension has no ENDT marker")


def rewrite_fract_v3f16(text: str, name: str) -> str:
    """Lower the one unsupported half3 fract call without weakening AGX.

    Ventura QuartzCore's fixed_frag_lph_cpf contains one
    air.fract.v3f16(x).  The iOS 16.3 AGX compiler renames that declaration
    to agx.air.fract.v3f16.fast but has no matching lowering-table entry.
    The compiler's implemented regular fract lowering is x - floor(x), so
    express that same operation directly in AIR and leave verifier/codegen
    validation enabled.
    """
    call_pattern = re.compile(
        r"^(?P<indent>\s*)(?P<result>%[-a-zA-Z$._0-9]+) = "
        r"tail call fast <3 x half> @air\.fract\.v3f16\("
        r"<3 x half> (?P<argument>%[-a-zA-Z$._0-9]+)\) "
        r"(?P<attributes>#[0-9]+)$",
        re.MULTILINE,
    )

    def replace_call(match: re.Match[str]) -> str:
        indent = match.group("indent")
        result = match.group("result")
        argument = match.group("argument")
        attributes = match.group("attributes")
        floor_result = "%macws.fract.v3f16.floor"
        return (
            f"{indent}{floor_result} = tail call fast <3 x half> "
            f"@air.floor.v3f16(<3 x half> {argument}) {attributes}\n"
            f"{indent}{result} = fsub fast <3 x half> {argument}, "
            f"{floor_result}"
        )

    text, call_count = call_pattern.subn(replace_call, text)
    declaration_pattern = re.compile(
        r"^declare <3 x half> @air\.fract\.v3f16\(<3 x half>\) "
        r"local_unnamed_addr (?P<attributes>#[0-9]+)$",
        re.MULTILINE,
    )
    text, declaration_count = declaration_pattern.subn(
        r"declare <3 x half> @air.floor.v3f16(<3 x half>) "
        r"local_unnamed_addr \g<attributes>",
        text,
    )
    if call_count != 1 or declaration_count != 1:
        raise ValueError(
            f"{name}: expected exactly one fract.v3f16 call/declaration, "
            f"found {call_count}/{declaration_count}"
        )
    if "@air.fract.v3f16" in text:
        raise ValueError(f"{name}: residual fract.v3f16 reference")
    return text


def lower_zero_memset_24(text: str, name: str) -> str:
    """Lower one fixed 24-byte zero memset to ordinary AIR stores.

    Ventura's Metal frontend emits this LLVM intrinsic while copying a
    three-element float2 varying array.  The iOS 16.3 AGX compiler accepts the
    surrounding AIR but returns an internal compiler error for the intrinsic.
    Three aligned i64 stores are byte-for-byte equivalent and remain subject
    to the normal AIR verifier and AGX code generator.
    """
    call_pattern = re.compile(
        r"^(?P<indent>\s*)call void @llvm\.memset\.p0i8\.i64\("
        r"i8\* nonnull align 8 dereferenceable\(24\) "
        r"(?P<pointer>%[-a-zA-Z$._0-9]+), i8 0, i64 24, i1 false\)$",
        re.MULTILINE,
    )

    def replace_call(match: re.Match[str]) -> str:
        indent = match.group("indent")
        pointer = match.group("pointer")
        lines = []
        for index, offset in enumerate((0, 8, 16)):
            byte_pointer = pointer
            if offset:
                byte_pointer = f"%macws.memset.byte.{index}"
                lines.append(
                    f"{indent}{byte_pointer} = getelementptr inbounds i8, "
                    f"i8* {pointer}, i64 {offset}"
                )
            word_pointer = f"%macws.memset.word.{index}"
            lines.append(
                f"{indent}{word_pointer} = bitcast i8* {byte_pointer} to i64*"
            )
            lines.append(
                f"{indent}store i64 0, i64* {word_pointer}, align 8"
            )
        return "\n".join(lines)

    text, typed_call_count = call_pattern.subn(replace_call, text)

    # LLVM 17+ prints the same AIR intrinsic with opaque pointers.  Metal
    # 32023.35 emits both spellings across Stray's cached shader set, so keep
    # the semantic lowering identical while emitting valid opaque-pointer IR.
    opaque_call_pattern = re.compile(
        r"^(?P<indent>\s*)call void @llvm\.memset\.p0\.i64\("
        r"ptr nonnull align 8 dereferenceable\(24\) "
        r"(?P<pointer>%[-a-zA-Z$._0-9]+), i8 0, i64 24, i1 false\)$",
        re.MULTILINE,
    )

    def replace_opaque_call(match: re.Match[str]) -> str:
        indent = match.group("indent")
        pointer = match.group("pointer")
        lines = []
        for index, offset in enumerate((0, 8, 16)):
            word_pointer = pointer
            if offset:
                word_pointer = f"%macws.memset.word.{index}"
                lines.append(
                    f"{indent}{word_pointer} = getelementptr inbounds i8, "
                    f"ptr {pointer}, i64 {offset}"
                )
            lines.append(
                f"{indent}store i64 0, ptr {word_pointer}, align 8"
            )
        return "\n".join(lines)

    text, opaque_call_count = opaque_call_pattern.subn(
        replace_opaque_call, text
    )
    declaration_pattern = re.compile(
        r"^declare void @llvm\.memset\.p0i8\.i64\(i8\* nocapture "
        r"writeonly, i8, i64, i1 immarg\) #[0-9]+\n?",
        re.MULTILINE,
    )
    text, typed_declaration_count = declaration_pattern.subn("", text)
    opaque_declaration_pattern = re.compile(
        r"^declare void @llvm\.memset\.p0\.i64\(ptr writeonly "
        r"captures\(none\), i8, i64, i1 immarg\) #[0-9]+\n?",
        re.MULTILINE,
    )
    text, opaque_declaration_count = opaque_declaration_pattern.subn(
        "", text
    )
    call_count = typed_call_count + opaque_call_count
    declaration_count = (
        typed_declaration_count + opaque_declaration_count
    )
    if call_count != 1 or declaration_count != 1:
        raise ValueError(
            f"{name}: expected exactly one fixed zero memset "
            f"call/declaration, found {call_count}/{declaration_count}"
        )
    if ("@llvm.memset.p0i8.i64" in text or
            "@llvm.memset.p0.i64" in text):
        raise ValueError(f"{name}: residual llvm.memset reference")
    return text


def retarget_air(
    module: bytes,
    name: str,
    llvm_dis: pathlib.Path,
    llvm_as: pathlib.Path,
    target_triple: str,
    scratch: pathlib.Path,
    lower_fract_v3f16: bool,
    lower_zero_memset: bool,
) -> bytes:
    source = scratch / f"{name}.input.air"
    assembly = scratch / f"{name}.ll"
    output = scratch / f"{name}.output.air"
    source.write_bytes(module)
    subprocess.run([llvm_dis, source, "-o", assembly], check=True)
    text = assembly.read_text(encoding="utf-8")
    pattern = re.compile(
        r'^target triple = "air64-apple-(?:ios|macosx)[^\"]*"$',
        re.MULTILINE,
    )
    text, count = pattern.subn(f'target triple = "{target_triple}"', text)
    if count != 1:
        raise ValueError(
            f"{name}: expected one iOS/macOS AIR target triple, found {count}"
        )
    if lower_fract_v3f16:
        text = rewrite_fract_v3f16(text, name)
    if lower_zero_memset:
        text = lower_zero_memset_24(text, name)
    assembly.write_text(text, encoding="utf-8")
    subprocess.run([llvm_as, assembly, "-o", output], check=True)
    rebuilt = output.read_bytes()
    if rebuilt[:4] != b"\xde\xc0\x17\x0b":
        raise ValueError(f"{name}: llvm-as did not emit wrapped LLVM bitcode")
    padding = (-len(rebuilt)) % 16
    return rebuilt + b"\0" * padding


def convert(args: argparse.Namespace) -> None:
    input_path = pathlib.Path(args.input)
    output_path = pathlib.Path(args.output)
    original = input_path.read_bytes()
    if len(original) < MTLB_HEADER_SIZE or original[:4] != b"MTLB":
        raise ValueError("input is not an MTLB container")
    input_platform = u16(original, 4)
    input_file_version = (u16(original, 6), u16(original, 8))
    input_target = (input_platform, original[11])
    legacy_unknown_target = (
        input_platform in {IOS_PLATFORM, MACOS_PLATFORM}
        and original[11] == UNKNOWN_TARGET_OS
        and input_file_version == (2, 3)
    )
    if input_target not in {
        (IOS_PLATFORM, IOS_TARGET_OS),
        (MACOS_PLATFORM, MACOS_TARGET_OS),
    } and not legacy_unknown_target:
        raise ValueError("input must be an iOS or macOS executable MTLB")
    if original[10] != 0:
        raise ValueError("input must be an executable MTLB")
    if (not args.preserve_container_target and
            not target_triple_matches_container(
                args.target_triple, args.container_target
            )):
        raise ValueError(
            f"AIR target {args.target_triple!r} does not match "
            f"MTLB container target {args.container_target!r}"
        )
    if u64(original, 16) != len(original):
        raise ValueError("input file-size field is invalid")
    bitcode_offset = u64(original, 72)
    bitcode_size = u64(original, 80)
    bitcode_end = bitcode_offset + bitcode_size
    if bitcode_offset < MTLB_HEADER_SIZE or bitcode_end > len(original):
        raise ValueError("input bitcode-section bounds are invalid")

    selected_names = set(args.function or [])
    fract_rewrite_names = set(args.rewrite_fract_v3f16_function or [])
    zero_memset_names = set(args.lower_zero_memset_function or [])
    if args.in_place_air_target:
        if not legacy_unknown_target:
            raise ValueError(
                "--in-place-air-target currently accepts only the validated "
                "legacy 2.3/unknown-target MTLB format"
            )
        if (args.preserve_container_target or selected_names or
                fract_rewrite_names or zero_memset_names):
            raise ValueError(
                "--in-place-air-target cannot be combined with selective "
                "AIR conversion or --preserve-container-target"
            )
    if (args.preserve_container_target and not selected_names
            and not legacy_unknown_target):
        raise ValueError(
            "--preserve-container-target without --function is accepted only "
            "for the validated legacy 2.3/unknown-target MTLB format"
        )
    if not fract_rewrite_names.issubset(selected_names):
        raise ValueError(
            "--rewrite-fract-v3f16-function must also be selected by "
            "--function"
        )
    if not zero_memset_names.issubset(selected_names):
        raise ValueError(
            "--lower-zero-memset-function must also be selected by "
            "--function"
        )

    rebuilt = bytearray(original[:bitcode_offset])
    records = parse_function_records(rebuilt)
    if legacy_unknown_target:
        # Metal 902.1 emits MTLB 2.3 containers whose target-OS header byte is
        # zero.  In that format the authoritative target is the AIR triple in
        # every module.  Fail closed unless all modules agree with the header's
        # platform; this keeps an arbitrary unknown-target container from being
        # promoted merely because it happens to use the old header version.
        expected_triple = (b"air64-apple-macosx" if
                           input_platform == MACOS_PLATFORM else
                           b"air64-apple-ios")
        for record in records:
            module_offset = int(record["bitcode_offset"])
            module_size = int(record["bitcode_size"])
            module = original[
                bitcode_offset + module_offset:
                bitcode_offset + module_offset + module_size
            ]
            if expected_triple not in module:
                raise ValueError(
                    f"{record['name']}: legacy MTLB AIR target does not match "
                    "the container platform"
                )
    available_names = {str(record["name"]) for record in records}
    missing_names = selected_names - available_names
    if missing_names:
        raise ValueError(
            "requested function(s) not present: " + ", ".join(sorted(missing_names))
        )
    next_bitcode_offset = 0
    rebuilt_modules: list[bytes] = []
    converted_count = 0
    with tempfile.TemporaryDirectory(prefix="macws-macabi-mtlb-") as temp:
        scratch = pathlib.Path(temp)
        for record in records:
            module_offset = int(record["bitcode_offset"])
            module_size = int(record["bitcode_size"])
            module = original[
                bitcode_offset + module_offset :
                bitcode_offset + module_offset + module_size
            ]
            tags = record["tags"]
            assert isinstance(tags, dict)
            hash_offset = tags["HASH"][0]
            if hashlib.sha256(module).digest() != original[hash_offset : hash_offset + 32]:
                raise ValueError(f"{record['name']}: input SHA-256 mismatch")
            if args.in_place_air_target:
                # Keep Apple's AIR record layout byte-for-byte. Upstream
                # llvm-as
                # emits records (for example ATTR_KIND_CAPTURES=102) that the
                # iOS 16 Apple LLVM reader cannot decode, even when the IR is
                # otherwise unchanged. A same-length target replacement
                # changes only the original string payload; hashes and the
                # outer MTLB target are rebuilt normally below.
                converted = retarget_air_in_place(
                    module,
                    f"{record['index']}-{record['name']}",
                    args.target_triple,
                )
                converted_count += 1
            elif not selected_names or str(record["name"]) in selected_names:
                converted = retarget_air(
                    module,
                    f"{record['index']}-{record['name']}",
                    pathlib.Path(args.llvm_dis),
                    pathlib.Path(args.llvm_as),
                    args.target_triple,
                    scratch,
                    str(record["name"]) in fract_rewrite_names,
                    str(record["name"]) in zero_memset_names,
                )
                converted_count += 1
            else:
                converted = module
            struct.pack_into("<Q", rebuilt, tags["MDSZ"][0], len(converted))
            rebuilt[hash_offset : hash_offset + 32] = hashlib.sha256(converted).digest()
            struct.pack_into("<Q", rebuilt, tags["OFFT"][0] + 16,
                             next_bitcode_offset)
            rebuilt_modules.append(converted)
            next_bitcode_offset += len(converted)

    new_bitcode = b"".join(rebuilt_modules)
    delta = len(new_bitcode) - bitcode_size
    rebuilt.extend(new_bitcode)
    rebuilt.extend(original[bitcode_end:])
    if not args.preserve_container_target:
        output_platform, output_target_os = OUTPUT_CONTAINER_TARGETS[
            args.container_target
        ]
        struct.pack_into("<H", rebuilt, 4, output_platform)
        if legacy_unknown_target:
            # MTLB 2.3 predates the explicit target-OS header field.  Merely
            # writing macabi into byte 11 leaves iOS Metal rejecting the whole
            # archive as an old tool format before it inspects a function.
            # The tag/section layout above has already been fully parsed and
            # rebuilt, so advertise the modern executable-container revision
            # alongside the now-explicit macabi target.
            struct.pack_into("<HH", rebuilt, 6,
                             *CURRENT_MTLB_FILE_VERSION)
        rebuilt[11] = output_target_os
        struct.pack_into("<H", rebuilt, 12, args.target_major)
        struct.pack_into("<H", rebuilt, 14, args.target_minor)
    struct.pack_into("<Q", rebuilt, 16, len(rebuilt))
    struct.pack_into("<Q", rebuilt, 80, len(new_bitcode))

    for name, content_offset, size in parse_header_extension_tags(rebuilt):
        if name not in OFFSET_SECTION_TAGS:
            continue
        if size != 16:
            raise ValueError(f"{name}: expected offset/size pair")
        offset = u64(rebuilt, content_offset)
        if offset >= bitcode_end:
            struct.pack_into("<Q", rebuilt, content_offset, offset + delta)

    # Reparse the final function list and verify all rebuilt module hashes.
    final_records = parse_function_records(rebuilt)
    for record in final_records:
        tags = record["tags"]
        assert isinstance(tags, dict)
        offset = int(record["bitcode_offset"])
        size = int(record["bitcode_size"])
        module = rebuilt[bitcode_offset + offset : bitcode_offset + offset + size]
        if hashlib.sha256(module).digest() != rebuilt[
            tags["HASH"][0] : tags["HASH"][0] + 32
        ]:
            raise ValueError(f"{record['name']}: output SHA-256 mismatch")
    output_path.write_bytes(rebuilt)
    print(
        f"converted={converted_count}/{len(final_records)} "
        f"target={args.target_triple} "
        f"container_target={'preserved' if args.preserve_container_target else args.container_target} "
        f"bitcode={bitcode_size}->{len(new_bitcode)} bytes "
        f"file={len(original)}->{len(rebuilt)} bytes output={output_path}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output")
    parser.add_argument("--llvm-dis", default="/opt/homebrew/opt/llvm/bin/llvm-dis")
    parser.add_argument("--llvm-as", default="/opt/homebrew/opt/llvm/bin/llvm-as")
    parser.add_argument("--target-triple", default="air64-apple-ios19.0.0-macabi")
    parser.add_argument("--target-major", type=int, default=19)
    parser.add_argument("--target-minor", type=int, default=0)
    parser.add_argument(
        "--in-place-air-target",
        action="store_true",
        help=(
            "for validated legacy 2.3 archives, replace a same-length AIR "
            "target string without re-encoding Apple's bitcode dialect"
        ),
    )
    parser.add_argument(
        "--container-target",
        choices=sorted(OUTPUT_CONTAINER_TARGETS),
        default="macabi",
        help=(
            "target encoded in the rebuilt MTLB header (default: macabi); "
            "the AIR target triple must describe the same target"
        ),
    )
    parser.add_argument(
        "--function",
        action="append",
        help="retarget only this function (repeatable; default: every function)",
    )
    parser.add_argument(
        "--preserve-container-target",
        action="store_true",
        help="leave the MTLB container target unchanged for a selective rebuild",
    )
    parser.add_argument(
        "--rewrite-fract-v3f16-function",
        action="append",
        help=(
            "within this selected function, rewrite the exact unsupported "
            "air.fract.v3f16 call as x - air.floor.v3f16(x)"
        ),
    )
    parser.add_argument(
        "--lower-zero-memset-function",
        action="append",
        help=(
            "within this selected function, lower the exact fixed 24-byte "
            "zero memset to three verified i64 stores"
        ),
    )
    convert(parser.parse_args())


if __name__ == "__main__":
    main()
