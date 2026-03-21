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
# libmachook/Makefile sets ARCHS=arm64 and TARGET=iphone:clang:latest:14.0 to
# prevent two on-device lld bugs:
#   1. lld generates broken arm64e __DATA,__interpose chained fixup entries that
#      corrupt dyld's GOT (PAC failure, EXC_BAD_ACCESS code=50).
#   2. Without TARGET set, Theos defaults to iOS 9.0, producing old-style
#      LC_VERSION_MIN_IPHONEOS load commands and old reloc format. macOS dyld
#      may not process the __interpose section correctly in that format, so the
#      objc_addExceptionHandler stubs in objc_hooks.c don't apply, causing
#      SIGTRAP inside the macOS chroot.
# Other subprojects keep their own ARCHS (arm64+arm64e is fine since they use
# Substrate hooks, not DYLD_INTERPOSE).
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

# Fix arm64e __DATA,__interpose entries.
# On-device lld generates PAC-encoded (auth_rebase/auth_bind) values in the
# interpose slots even though the binary uses LC_DYLD_INFO_ONLY.  macOS dyld's
# classic fixup path doesn't understand the PAC encoding and silently skips the
# hooks (sysctlbyname, objc_addExceptionHandler, etc.), causing a SIGTRAP crash.
# This script strips the PAC bits, leaving plain pointer values for dyld to
# rebase/bind in the normal LC_DYLD_INFO_ONLY way.
echo "==> Fixing arm64e interpose section in libmachook.dylib..."
sudo python3 "$SCRIPT_DIR/fix_arm64e_interpose.py" /var/jb/usr/macOS/lib/libmachook.dylib

# Re-sign after modifying
echo "==> Re-signing libmachook.dylib..."
sudo ldid -S /var/jb/usr/macOS/lib/libmachook.dylib

echo "==> Running postinst (copy dylib to rootfs, update trustcache)..."
sudo bash /var/jb/usr/macOS/bin/postinst.sh

echo "==> Done! Package installed successfully."
