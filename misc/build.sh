#!/bin/bash
# Build and install MacWSBootingGuide from macOS (cross-compile)
# Usage: bash misc/build.sh
#
# All scripts and binaries are installed via the .deb package.
# Only libmachook.dylib needs post-processing with vtool (macOS build version).

set -e

DEVICE_IP="192.168.5.8"
DEVICE_PORT=2222
# Default: postinst_simple.sh (fast). Override: POSTINST_SCRIPT=/var/jb/usr/macOS/bin/postinst.sh bash misc/build.sh
POSTINST_SCRIPT="${POSTINST_SCRIPT:-/var/jb/usr/macOS/bin/postinst_simple.sh}"

# Setup SSH key (default password: alpine)
ssh-copy-id -p $DEVICE_PORT root@$DEVICE_IP 2>/dev/null || true

# Build, package, and install
gmake FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless package install \
  THEOS_DEVICE_IP=$DEVICE_IP THEOS_DEVICE_PORT=$DEVICE_PORT GO_EASY_ON_ME=1

# Post-process libmachook.dylib with macOS build version
cp .theos/obj/libmachook.dylib .
python3 misc/set_macos_version.py libmachook.dylib
ldid -S libmachook.dylib
codesign -f -s - libmachook.dylib

# arm64e-only dylib for chroot (macOS dyld SIGKILL on fat DYLD_INSERT_LIBRARIES)
lipo -thin arm64e libmachook.dylib -output libmachook-rootfs.dylib
ldid -S libmachook-rootfs.dylib
codesign -f -s - libmachook-rootfs.dylib

# Replace the package-installed version with the post-processed one
scp -P $DEVICE_PORT libmachook.dylib root@$DEVICE_IP:/var/jb/usr/macOS/lib/libmachook.dylib
scp -P $DEVICE_PORT libmachook-rootfs.dylib root@$DEVICE_IP:/var/jb/usr/macOS/lib/libmachook-rootfs.dylib
rm -f libmachook.dylib libmachook-rootfs.dylib

echo "==> Running postinst ($POSTINST_SCRIPT)..."
ssh -p $DEVICE_PORT root@$DEVICE_IP "echo alpine | sudo -S bash $POSTINST_SCRIPT"

echo "==> Done!"
