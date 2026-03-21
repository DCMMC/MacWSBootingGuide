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
# Build arm64 only: on-device Theos uses lld (not Apple ld), which generates
# arm64e __DATA,__interpose chained fixup entries in a format that iOS dyld
# cannot process correctly, causing a PAC failure (EXC_BAD_ACCESS code=50) at
# dyld`kdebug_is_enabled when loading the dylib into an arm64e process.
# arm64e processes (macOS bash inside the chroot) fall back to the arm64 slice
# seamlessly, so arm64-only is correct for on-device builds.
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 ARCHS=arm64

echo "==> Packaging..."
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 ARCHS=arm64 package

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
