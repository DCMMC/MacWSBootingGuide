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
# libmachook/Makefile sets ARCHS=arm64 arm64e, TARGET=iphone:clang:latest:14.0,
# and LDFLAGS=-fixup_chains to fix two on-device lld issues:
#   1. On-device lld defaults to LC_DYLD_INFO_ONLY for arm64e.  Without -fixup_chains,
#      ObjC class data pointers (e.g. MTLFakeDevice) are PAC-signed with iOS keys but
#      the classic rebase path cannot re-sign them at load time.  macOS arm64e libobjc
#      then fails autda → EXC_BREAKPOINT (PAC trap DA) in readClass during map_images.
#      -fixup_chains forces LC_DYLD_CHAINED_FIXUPS so macOS dyld re-signs PAC at
#      runtime with the correct macOS keys.
#   2. Without TARGET set, Theos defaults to iOS 9.0, producing old-style
#      LC_VERSION_MIN_IPHONEOS load commands. macOS dyld rejects these.
# Other subprojects keep their own ARCHS (arm64+arm64e is fine since they use
# Substrate hooks, not DYLD_INTERPOSE).
# On-device lld + -Wl,-fixup_chains allows ObjC in the arm64e slice; enable it
# (see Metal_hooks.x — cross-compiles still omit MTLFakeDevice from arm64e).
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 \
	libmachook_CFLAGS+="-DLIBMACHOOK_ON_DEVICE_BUILD=1"

echo "==> Packaging..."
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 \
	libmachook_CFLAGS+="-DLIBMACHOOK_ON_DEVICE_BUILD=1" package

# Find the built .deb
DEB=$(ls -t packages/*.deb 2>/dev/null | head -1)
if [ -z "$DEB" ]; then
    echo "Error: No .deb package found in packages/"
    exit 1
fi

echo "==> Installing $DEB..."
sudo dpkg -i "$DEB"

# Set macOS build version on libmachook.dylib (equivalent to vtool)
# Without this, macOS dyld rejects the library as an iOS binary.
echo "==> Setting macOS build version on libmachook.dylib..."
sudo python3 "$SCRIPT_DIR/set_macos_version.py" /var/jb/usr/macOS/lib/libmachook.dylib

# Re-sign after modifying
echo "==> Re-signing libmachook.dylib..."
sudo ldid -S /var/jb/usr/macOS/lib/libmachook.dylib

echo "==> Running postinst (copy dylib to rootfs, update trustcache)..."
sudo bash /var/jb/usr/macOS/bin/postinst.sh

echo "==> Done! Package installed successfully."
