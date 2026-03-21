#!/usr/bin/env python3
"""
Patch libsystem_darwin.dylib so _os_variant_has_internal_diagnostics returns true at entry.
Needed for macOS-in-chroot on iOS: libSystem's initializer calls this before DYLD_INSERT_LIBRARIES
libraries finish loading, so dyld interpose in libmachook never runs in time.

LC_SYMTAB offsets are relative to the start of each thin Mach-O (fat slice base).

Idempotent: skips if the entry already matches the patch.
Pure stdlib — run on iOS (procursus python3).
"""
from __future__ import annotations

import os
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC_64_SWAP = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2

# mov w0, #1 ; ret  (AArch64)
PATCH_BYTES = bytes.fromhex("20008052c0035fd6")
N_TYPE = 0x0E
N_SECT = 0x0E
N_EXT = 0x01


def abs_file_offset(slice_base: int, off: int) -> int:
    """LC_SYMTAB / segment fileoff: relative to slice when off < slice_base."""
    if off >= slice_base:
        return off
    return slice_base + off


def u32_le(d: bytes, o: int) -> int:
    return struct.unpack_from("<I", d, o)[0]


def u32_be(d: bytes, o: int) -> int:
    return struct.unpack_from(">I", d, o)[0]


def u64_le(d: bytes, o: int) -> int:
    return struct.unpack_from("<Q", d, o)[0]


def parse_fat_slices(data: bytes) -> list[tuple[int, int, int, int]] | None:
    m = u32_be(data, 0)
    if m not in (FAT_MAGIC, FAT_CIGAM):
        return None
    swap_be = m == FAT_CIGAM
    nfat = u32_be(data, 4) if not swap_be else int.from_bytes(data[4:8], "little")
    out = []
    off = 8
    for _ in range(nfat):
        if not swap_be:
            cpu, sub, coff, csize, _align = struct.unpack_from(">IIIII", data, off)
        else:
            cpu, sub, coff, csize, _align = struct.unpack_from("<IIIII", data, off)
        out.append((cpu, sub, coff, csize))
        off += 20
    return out


def va_to_fileoff(segments: list[tuple[int, int, int, int]], va: int) -> int | None:
    """segments: (vmaddr, vmsize, fileoff, filesize) — fileoff absolute in file."""
    for vmaddr, vmsize, fileoff, filesize in segments:
        if vmaddr <= va < vmaddr + vmsize:
            delta = va - vmaddr
            if delta < filesize:
                return fileoff + delta
    return None


def parse_macho_slice(
    data: bytes, base: int
) -> tuple[list[tuple[int, int, int, int]], int, int, int] | None:
    """Return (__TEXT segments, symoff_abs, nsyms, stroff_abs) or None."""
    if len(data) < base + 32:
        return None
    magic = u32_le(data, base)
    if magic not in (MH_MAGIC_64, MH_MAGIC_64_SWAP):
        return None
    if magic == MH_MAGIC_64_SWAP:
        return None
    ncmds = u32_le(data, base + 0x10)
    cmd_off = base + 0x20
    segments: list[tuple[int, int, int, int]] = []
    symoff_rel = nsyms = stroff_rel = 0
    for _ in range(ncmds):
        if cmd_off + 8 > len(data):
            break
        cmd = u32_le(data, cmd_off)
        cmdsize = u32_le(data, cmd_off + 4)
        if cmdsize < 8 or cmd_off + cmdsize > len(data):
            break
        if cmd == LC_SEGMENT_64:
            segname = data[cmd_off + 8 : cmd_off + 24].split(b"\x00", 1)[0]
            vmaddr = u64_le(data, cmd_off + 24)
            vmsize = u64_le(data, cmd_off + 32)
            fileoff = u64_le(data, cmd_off + 40)
            filesize = u64_le(data, cmd_off + 48)
            if segname == b"__TEXT":
                fileoff_abs = abs_file_offset(base, fileoff)
                segments.append((vmaddr, vmsize, fileoff_abs, filesize))
        elif cmd == LC_SYMTAB:
            symoff_rel = u32_le(data, cmd_off + 8)
            nsyms = u32_le(data, cmd_off + 12)
            stroff_rel = u32_le(data, cmd_off + 16)
        cmd_off += cmdsize
    if not segments or symoff_rel == 0:
        return None
    symoff_abs = abs_file_offset(base, symoff_rel)
    stroff_abs = abs_file_offset(base, stroff_rel)
    return segments, symoff_abs, nsyms, stroff_abs


def find_symbol_va(
    data: bytes, symoff_abs: int, nsyms: int, stroff_abs: int, targets: frozenset[str]
) -> int | None:
    if symoff_abs <= 0 or nsyms <= 0 or stroff_abs <= 0:
        return None
    if stroff_abs >= len(data) or symoff_abs >= len(data):
        return None
    strtab = data[stroff_abs : min(len(data), stroff_abs + 0x200000)]
    for i in range(nsyms):
        o = symoff_abs + i * 16
        if o + 16 > len(data):
            break
        n_strx, n_type, n_sect, _n_desc, n_value = struct.unpack_from("<IBBHQ", data, o)
        if n_strx == 0 or n_strx >= len(strtab):
            continue
        end = strtab.find(b"\x00", n_strx)
        if end < 0:
            continue
        name = strtab[n_strx:end].decode("ascii", "replace")
        if name not in targets:
            continue
        if (n_type & N_TYPE) != N_SECT or n_sect == 0:
            continue
        if (n_type & N_EXT) == 0:
            continue
        if n_value != 0:
            return n_value
    for i in range(nsyms):
        o = symoff_abs + i * 16
        if o + 16 > len(data):
            break
        n_strx, n_type, n_sect, _n_desc, n_value = struct.unpack_from("<IBBHQ", data, o)
        if n_strx == 0 or n_strx >= len(strtab):
            continue
        end = strtab.find(b"\x00", n_strx)
        if end < 0:
            continue
        name = strtab[n_strx:end].decode("ascii", "replace")
        if name not in targets:
            continue
        if (n_type & N_TYPE) != N_SECT or n_sect == 0:
            continue
        if n_value != 0:
            return n_value
    return None


def patch_slice(data: bytearray, slice_base: int, label: str) -> bool:
    parsed = parse_macho_slice(bytes(data), slice_base)
    if not parsed:
        print(f"[patch_libsystem_darwin] {label}: parse failed (no __TEXT or symtab?)", file=sys.stderr)
        return False
    segments, symoff_abs, nsyms, stroff_abs = parsed
    targets = frozenset(
        (
            "_os_variant_has_internal_diagnostics",
            "os_variant_has_internal_diagnostics",
        )
    )
    va = find_symbol_va(bytes(data), symoff_abs, nsyms, stroff_abs, targets)
    if va is None:
        print(f"[patch_libsystem_darwin] {label}: symbol not found (stripped? wrong OS?)", file=sys.stderr)
        return False
    fo = va_to_fileoff(segments, va)
    if fo is None:
        print(f"[patch_libsystem_darwin] {label}: va→fileoff failed for 0x{va:x}", file=sys.stderr)
        return False
    if fo + len(PATCH_BYTES) > len(data):
        print(f"[patch_libsystem_darwin] {label}: patch past EOF", file=sys.stderr)
        return False
    if bytes(data[fo : fo + len(PATCH_BYTES)]) == PATCH_BYTES:
        print(f"[patch_libsystem_darwin] {label}: already patched")
        return True
    data[fo : fo + len(PATCH_BYTES)] = PATCH_BYTES
    print(f"[patch_libsystem_darwin] {label}: patched @file 0x{fo:x} va=0x{va:x}")
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_libsystem_darwin_os_variant.py /path/to/libsystem_darwin.dylib", file=sys.stderr)
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path):
        print(f"[patch_libsystem_darwin] not a file: {path}", file=sys.stderr)
        return 1
    with open(path, "rb") as f:
        raw = f.read()
    data = bytearray(raw)
    slices = parse_fat_slices(bytes(data))
    ok_any = False
    if slices is None:
        if patch_slice(data, 0, "thin"):
            ok_any = True
    else:
        for cpu, sub, coff, csize in slices:
            if cpu != CPU_TYPE_ARM64:
                continue
            if coff + csize > len(data):
                continue
            label = f"arm64 slice @{coff:#x} sub={sub}"
            if patch_slice(data, coff, label):
                ok_any = True
    if not ok_any:
        print("[patch_libsystem_darwin] no arm64 slice patched", file=sys.stderr)
        return 1
    os.chmod(path, os.stat(path).st_mode | 0o200)
    with open(path, "wb") as f:
        f.write(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
