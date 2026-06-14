#!/usr/bin/env python3
"""set_ios_version.py — REVERSE of set_macos_version.py. Patches LC_BUILD_VERSION
platform from macOS (1) → iOS (2), so the iOS kernel gives the binary normal arm64e
PAC keys (DA/IA/DB). Without this, the kernel zeros DA/IA/DB for "macOS" binaries
running in the chroot. The binary itself remains macOS-compatible (same code, same
libraries); only the platform TAG changes.
"""
import sys, struct

MH_MAGIC_64 = 0xfeedfacf
MH_CIGAM_64 = 0xcffaedfe
LC_BUILD_VERSION = 0x32
PLATFORM_MACOS = 1
PLATFORM_IOS = 2

def patch_slice(data, off):
    end = '<' if struct.unpack_from('<I', data, off)[0] == MH_MAGIC_64 else '>'
    ncmds = struct.unpack_from(f'{end}IIIIIIII', data, off)[4]
    p = off + 32
    flipped = 0
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from(f'{end}II', data, p)
        if cmd == LC_BUILD_VERSION:
            plat = struct.unpack_from(f'{end}I', data, p + 8)[0]
            if plat == PLATFORM_MACOS:
                struct.pack_into(f'{end}I', data, p + 8, PLATFORM_IOS)
                # Also clamp minos/sdk to iOS-valid range (16.3) — macOS 13.4 packed as 0x000d0400
                # is invalid as iOS; iOS 16.3 = 0x00100300. Without this the kernel may reject.
                struct.pack_into(f'{end}I', data, p + 12, (16 << 16) | (3 << 8))  # minos
                struct.pack_into(f'{end}I', data, p + 16, (16 << 16) | (3 << 8))  # sdk
                flipped += 1
                print(f"  patched LC_BUILD_VERSION: macOS → iOS @ off {p:#x}")
        p += sz
    return flipped

def main():
    path = sys.argv[1]
    data = bytearray(open(path, 'rb').read())
    magic = struct.unpack_from('<I', data, 0)[0]
    if magic in (MH_MAGIC_64, MH_CIGAM_64):
        n = patch_slice(data, 0)
    else:
        print(f"unsupported magic {magic:#x}", file=sys.stderr); sys.exit(1)
    if n == 0:
        print("no LC_BUILD_VERSION(macOS) found — nothing to do")
        sys.exit(0)
    open(path, 'wb').write(data)
    print(f"wrote {path} ({n} slice(s) flipped)")

if __name__ == '__main__':
    main()
