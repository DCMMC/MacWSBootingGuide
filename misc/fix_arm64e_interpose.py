#!/usr/bin/env python3
"""
fix_arm64e_interpose.py - Fix arm64e __DATA,__interpose section in LC_DYLD_INFO_ONLY binaries

On-device Theos uses LLVM lld which generates arm64e __DATA,__interpose entries as
PAC-encoded chained-fixup-style pointers (auth_rebase / auth_bind) even when the
binary uses LC_DYLD_INFO_ONLY (classic rebase/bind format).  macOS dyld's classic
fixup path does not understand the PAC encoding; it processes the raw 64-bit values
as ordinary pointers, silently producing wrong interpose table entries — so hooks
like sysctlbyname and objc_addExceptionHandler are never applied.

Fix: for each 16-byte interpose entry in the arm64e slice:
  - replacement slot (8 bytes): if it is an auth_rebase (bit63=1, bit62=0), extract
    the plain 32-bit target address and write it back as a zero-extended 64-bit LE
    value — exactly the format LC_DYLD_INFO_ONLY expects to rebase.
  - replacee slot (8 bytes): if it is an auth_bind (bit63=1, bit62=1), zero it —
    LC_DYLD_INFO_ONLY bind opcodes expect a zero slot and fill it with the symbol addr.

Only applied to LC_DYLD_INFO_ONLY arm64e slices; LC_DYLD_CHAINED_FIXUPS slices
(e.g. cross-compiled with Apple ld) are left untouched because the chained-fixup
processor handles PAC entries correctly on its own.

Usage: python3 fix_arm64e_interpose.py <path_to_macho>
"""

import sys
import struct
import os

# Mach-O constants
FAT_MAGIC       = 0xcafebabe
FAT_MAGIC_64    = 0xcafebabf
MH_MAGIC_64     = 0xfeedfacf
MH_CIGAM_64     = 0xcffaedfe

CPU_TYPE_ARM64  = 0x0100000c
CPU_SUBTYPE_ARM64E = 2

LC_SEGMENT_64           = 0x19
LC_DYLD_INFO_ONLY       = 0x80000022
LC_DYLD_CHAINED_FIXUPS  = 0x80000034

# arm64e pointer auth bits (stored in 64-bit value, little-endian)
AUTH_BIT = (1 << 63)
BIND_BIT = (1 << 62)


def is_auth_rebase(val):
    """auth=1 (bit63), bind=0 (bit62)"""
    return (val & AUTH_BIT) and not (val & BIND_BIT)


def is_auth_bind(val):
    """auth=1 (bit63), bind=1 (bit62)"""
    return bool(val & AUTH_BIT) and bool(val & BIND_BIT)


def extract_auth_rebase_target(val):
    """Extract the 32-bit runtime offset from an auth_rebase pointer."""
    return val & 0xFFFFFFFF


def find_section(data, slice_offset, endian, seg_name, sect_name):
    """Return (offset_in_file, size) of a named section, or (None, None)."""
    seg_name  = seg_name.ljust(16, '\x00').encode()
    sect_name = sect_name.ljust(16, '\x00').encode()

    header_fmt = f'{endian}IIIIIIII'
    header_size = struct.calcsize(header_fmt)
    header = struct.unpack_from(header_fmt, data, slice_offset)
    ncmds = header[4]

    cmd_offset = slice_offset + header_size
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(f'{endian}II', data, cmd_offset)
        if cmd == LC_SEGMENT_64:
            # segment_command_64: cmd cmdsize segname[16] vmaddr vmsize fileoff filesize
            # maxprot initprot nsects flags
            seg_fmt = f'{endian}II16sQQQQIIII'
            seg = struct.unpack_from(seg_fmt, data, cmd_offset)
            if seg[2] == seg_name:
                nsects = seg[10]
                sect_off = cmd_offset + struct.calcsize(seg_fmt)
                # section_64: sectname[16] segname[16] addr size offset align ...
                sect_fmt = f'{endian}16s16sQQIIIIII'
                sect_size_each = struct.calcsize(sect_fmt)
                for i in range(nsects):
                    sect = struct.unpack_from(sect_fmt, data, sect_off + i * sect_size_each)
                    if sect[0] == sect_name:
                        return sect[4], sect[3]  # file offset, size
        cmd_offset += cmdsize

    return None, None


def has_chained_fixups(data, slice_offset, endian):
    """Return True if the slice uses LC_DYLD_CHAINED_FIXUPS."""
    header_fmt = f'{endian}IIIIIIII'
    header_size = struct.calcsize(header_fmt)
    header = struct.unpack_from(header_fmt, data, slice_offset)
    ncmds = header[4]

    cmd_offset = slice_offset + header_size
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(f'{endian}II', data, cmd_offset)
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            return True
        cmd_offset += cmdsize
    return False


def fix_interpose_slice(data, slice_offset):
    """Fix the arm64e __DATA,__interpose section in place. Returns True if modified."""
    magic = struct.unpack_from('<I', data, slice_offset)[0]
    if magic == MH_MAGIC_64:
        endian = '<'
    elif magic == MH_CIGAM_64:
        endian = '>'
    else:
        return False

    # Only arm64e slices need fixing
    header_fmt = f'{endian}IIIIIIII'
    header = struct.unpack_from(header_fmt, data, slice_offset)
    cputype    = header[1]
    cpusubtype = header[2] & 0xFF  # mask off caps byte
    if cputype != CPU_TYPE_ARM64 or cpusubtype != CPU_SUBTYPE_ARM64E:
        return False

    # Skip if binary already uses LC_DYLD_CHAINED_FIXUPS (handled correctly by dyld)
    if has_chained_fixups(data, slice_offset, endian):
        print("  [arm64e] Uses LC_DYLD_CHAINED_FIXUPS — skipping (no fix needed)")
        return False

    # Find __DATA,__interpose
    sect_file_off, sect_size = find_section(data, slice_offset, endian, '__DATA', '__interpose')
    if sect_file_off is None:
        print("  [arm64e] No __DATA,__interpose section found")
        return False

    entry_size = 16  # two 8-byte pointers per entry
    n_entries  = sect_size // entry_size
    if n_entries == 0:
        print("  [arm64e] __DATA,__interpose is empty")
        return False

    modified = False
    for i in range(n_entries):
        off = sect_file_off + i * entry_size

        replacement, replacee = struct.unpack_from('<QQ', data, off)

        new_replacement = replacement
        new_replacee    = replacee

        if is_auth_rebase(replacement):
            # Extract the plain 32-bit target; zero upper 32 bits
            target = extract_auth_rebase_target(replacement)
            new_replacement = target  # plain LE 64-bit
            modified = True

        if is_auth_bind(replacee):
            # Zero out; LC_DYLD_INFO_ONLY bind opcodes will fill this in
            new_replacee = 0
            modified = True

        if new_replacement != replacement or new_replacee != replacee:
            struct.pack_into('<QQ', data, off, new_replacement, new_replacee)
            print(f"  [arm64e] entry {i}: replacement 0x{replacement:016x} -> 0x{new_replacement:016x}  "
                  f"replacee 0x{replacee:016x} -> 0x{new_replacee:016x}")

    return modified


def process_file(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    magic = struct.unpack('>I', data[:4])[0]
    modified = False

    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        is_64     = (magic == FAT_MAGIC_64)
        nfat_arch = struct.unpack('>I', data[4:8])[0]
        arch_fmt  = '>IIQQII' if is_64 else '>IIIII'
        arch_size = struct.calcsize(arch_fmt)

        print(f"Fat binary with {nfat_arch} architectures")
        arch_off = 8
        for i in range(nfat_arch):
            if is_64:
                cputype, cpusubtype, offset, size, align, _reserved = struct.unpack_from('>IIQQII', data, arch_off)
            else:
                cputype, cpusubtype, offset, size, align = struct.unpack_from('>IIIII', data, arch_off)

            arch_names = {
                (CPU_TYPE_ARM64, 0): 'arm64',
                (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E): 'arm64e',
                (0x01000007, 3): 'x86_64',
            }
            arch_name = arch_names.get((cputype, cpusubtype & 0xFF), f'cpu{cputype:#010x}')
            print(f"  Slice {i}: {arch_name} at offset 0x{offset:x}")

            if fix_interpose_slice(data, offset):
                modified = True

            arch_off += arch_size
    else:
        print("Thin binary")
        if fix_interpose_slice(data, 0):
            modified = True

    if modified:
        with open(path, 'wb') as f:
            f.write(data)
        print(f"Fixed: {path}")
        return True
    else:
        print(f"No changes: {path}")
        return False


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <macho_file> [macho_file2 ...]")
        sys.exit(1)
    for path in sys.argv[1:]:
        if not os.path.isfile(path):
            print(f"Error: {path} not found")
            continue
        print(f"\nProcessing: {path}")
        process_file(path)


if __name__ == '__main__':
    main()
