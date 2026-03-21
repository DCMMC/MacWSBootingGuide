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
# libmachook uses TARGET=iphone:clang:latest:14.0 so load commands are not legacy
# LC_VERSION_MIN_IPHONEOS (macOS dyld rejects those).  MTLFakeDevice is registered
# at runtime (objc_allocateClassPair) so arm64e does not need static ObjC metadata
# workarounds like -Wl,-fixup_chains.
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1

echo "==> Packaging..."
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 package

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
