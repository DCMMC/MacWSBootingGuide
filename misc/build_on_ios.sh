#!/bin/bash
# Build and install MacWSBootingGuide on-device (iOS shell with Theos)
# Usage: bash misc/build_on_ios.sh
#
# This is the on-device equivalent of misc/build.sh (which builds from macOS).
# All files (scripts, libmachook.dylib) are installed via the .deb package.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Cleaning previous build..."
make clean 2>/dev/null || true

echo "==> Building..."
# Pass LIBMACHOOK_ON_DEVICE_BUILD=1 so libmachook/Makefile adds, for the
# on-device lld only:
#   * -DLIBMACHOOK_ON_DEVICE_BUILD=1  (lets Metal_hooks.x include arm64e ObjC)
#   * -Wl,-fixup_chains               (LC_DYLD_CHAINED_FIXUPS for arm64e)
# Why -fixup_chains is required on-device: on-device lld emits the arm64e
# __interpose tuples (and ObjC class_t) as authenticated pointers under the
# classic LC_DYLD_INFO_ONLY format, which macOS arm64e dyld mis-processes.  The
# DYLD_INTERPOSE of os_variant_has_internal_diagnostics() then never registers,
# so the real implementation runs and traps (brk 1) in libSystem_initializer
# before any hook loads.  -fixup_chains switches to the chained-fixup format
# that macOS dyld re-signs/re-binds correctly at load.  libmachook/Makefile also
# sets TARGET=iphone:clang:latest:14.0 so macOS dyld accepts the load commands
# (Theos would otherwise default to iOS 9.0 / LC_VERSION_MIN_IPHONEOS, rejected
# by macOS dyld).  The macOS cross-compile (misc/build.sh) uses ld64 and must
# NOT get the flag.
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 \
	LIBMACHOOK_ON_DEVICE_BUILD=1

echo "==> Packaging..."
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 \
	LIBMACHOOK_ON_DEVICE_BUILD=1 package

# Find the built .deb
DEB=$(ls -t packages/*.deb 2>/dev/null | head -1)
if [ -z "$DEB" ]; then
    echo "Error: No .deb package found in packages/"
    exit 1
fi

echo "==> Installing $DEB..."
sudo dpkg -i "$DEB"

# Set the macOS build version on the FAT libmachook (both slices; equivalent to
# vtool) — without this macOS dyld rejects the library as an iOS binary.
echo "==> Setting macOS build version on libmachook.dylib (fat)..."
sudo python3 "$SCRIPT_DIR/set_macos_version.py" /var/jb/usr/macOS/lib/libmachook.dylib

# Split the fat libmachook into two THIN dylibs and ship BOTH.
#
# On this device's dyld (iOS 16.x) a *fat* DYLD_INSERT_LIBRARIES dylib fails to
# load into a chrooted macOS process — DYLD_PRINT_SEARCHING reports
#   "fat file, but missing compatible architecture (have 'arm64,arm64e', need '')"
# so the insert is silently dropped and the real
# os_variant_has_internal_diagnostics() traps (brk 1) in libSystem_initializer.
# A *thin* slice matching the process arch loads fine, and dyld silently SKIPS a
# non-matching thin insert.  So we install both slices and launchdchrootexec
# inserts both (libmachook.dylib:libmachook_arm64.dylib): each macOS process
# loads the slice for its own arch — arm64e (bash, Terminal, git, python3) or
# arm64 (WindowServer, claude, MacPorts tools like curl/bzip2).
LIB=/var/jb/usr/macOS/lib/libmachook.dylib
LIB_ARM64=/var/jb/usr/macOS/lib/libmachook_arm64.dylib
echo "==> Splitting fat libmachook into thin arm64e + thin arm64..."
sudo cp "$LIB" "/tmp/libmachook_fat.$$.dylib"
sudo lipo "/tmp/libmachook_fat.$$.dylib" -thin arm64e -output "$LIB"
sudo lipo "/tmp/libmachook_fat.$$.dylib" -thin arm64  -output "$LIB_ARM64"
sudo rm -f "/tmp/libmachook_fat.$$.dylib"

# Re-sign both thin dylibs (signature was invalidated by set_macos_version + split).
#
# CRITICAL: each thin slice must be signed TWICE.  A single `ldid -S` on a slice
# fresh out of `lipo -thin` produces a CodeDirectory whose page hashes do NOT
# match the final on-disk file — ldid hashes the layout before it finishes
# growing __LINKEDIT / LC_CODE_SIGNATURE for the just-split slice.  The cdhash
# looks fine and trustcaches OK (postinst reads it back without complaint), but
# AMFI rejects every mmap of the dylib with "Invalid Page" (SIGKILL CODESIGNING).
# Because launchdchrootexec inserts BOTH slices and dyld validates both, a single
# bad slice SIGKILLs *every* chrooted macOS process (bash, WindowServer, ...).
# Signing a second time settles the layout and yields page hashes that match the
# bytes — verified: 2 signs -> chroot smoke test passes; 1 sign -> Killed: 9.
# (`ldid -S` is not idempotent here, so the cdhash drifts between signs; that is
# harmless because postinst re-reads the final cdhash before trustcaching it.)
echo "==> Re-signing both thin dylibs (twice each: works around ldid+lipo first-sign Invalid-Page bug)..."
sudo ldid -S "$LIB";       sudo ldid -S "$LIB"
sudo ldid -S "$LIB_ARM64"; sudo ldid -S "$LIB_ARM64"

echo "==> Running postinst (copy dylibs to rootfs, update trustcache)..."
sudo bash /var/jb/usr/macOS/bin/postinst.sh

echo "==> Done! Package installed successfully."
