# cmp_run.sh — build misc/cmp_probe.m for iOS-native + macOS-chroot, run both, print side-by-side.
#
# Usage (from the repo root, on the Mac):
#   bash misc/cmp_run.sh <mode> [side]
#     mode = env | metal | gpu | window | space | all   (default: all)
#     side = both | ios | mac                            (default: both)
#   CMPDEV=<ip> overrides the device IP (default 172.23.154.14, WiFi port 2222).
#
# window/space modes are only meaningful with a running chroot WindowServer —
# start it first (macos_gui.sh start coexist) so the probe can connect as a CGS client.
#
# NB: not exec'd on iOS (shebang/AMFI N/A) — this runs on the Mac and drives SSH.

set -u
MODE="${1:-all}"
SIDE="${2:-both}"
D="${CMPDEV:-172.23.154.14}"
SSH="ssh -p 2222 -o ConnectTimeout=60 -o ServerAliveInterval=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SRC="$(dirname "$0")/cmp_probe.m"
FW="-framework Metal -framework IOSurface -framework Foundation -framework CoreGraphics -framework CoreFoundation"

echo "==> building cmp_probe (iOS + macOS) ..."
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=16.0 -fobjc-arc $FW "$SRC" -o /tmp/cmp_probe_ios || { echo "iOS build failed"; exit 1; }
xcrun --sdk macosx   clang -arch arm64e -mmacosx-version-min=13.0 -fobjc-arc $FW "$SRC" -o /tmp/cmp_probe_mac || { echo "macOS build failed"; exit 1; }

run_ios() {
    $SCP /tmp/cmp_probe_ios "root@$D:/tmp/cmp_probe_ios" >/dev/null 2>&1
    $SSH "root@$D" 'ENT=/var/jb/usr/macOS/bin/entitlements.plist; sudo ldid -S"$ENT" /tmp/cmp_probe_ios 2>/dev/null; chmod +x /tmp/cmp_probe_ios; h=$(ldid -arch arm64e -h /tmp/cmp_probe_ios 2>/dev/null|grep CDHash=|cut -c8-); sudo /var/jb/usr/bin/jbctl trustcache add "$h" >/dev/null 2>&1; sudo /tmp/cmp_probe_ios '"$MODE"' 2>&1'
}
run_mac() {
    $SCP /tmp/cmp_probe_mac "root@$D:/var/mnt/rootfs/tmp/cmp_probe_mac" >/dev/null 2>&1
    $SSH "root@$D" 'ENT=/var/jb/usr/macOS/bin/entitlements.plist; sudo ldid -S"$ENT" /var/mnt/rootfs/tmp/cmp_probe_mac 2>/dev/null; for a in arm64 arm64e; do h=$(ldid -arch $a -h /var/mnt/rootfs/tmp/cmp_probe_mac 2>/dev/null|grep CDHash=|cut -c8-); [ -n "$h" ] && sudo /var/jb/usr/bin/jbctl trustcache add "$h" >/dev/null 2>&1; done; sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c "export PATH=/usr/bin:/bin; export MACWS_AGX_NATIVE=1; export MACWS_AGX_REGISTER_CLASSES=1; export MACWS_PIN_FALLBACK=1; /tmp/cmp_probe_mac '"$MODE"'" 2>&1 | grep -v "^chdir"'
}

if [ "$SIDE" = "ios" ] || [ "$SIDE" = "both" ]; then
    echo; echo "################## iOS-native ##################"; run_ios
fi
if [ "$SIDE" = "mac" ] || [ "$SIDE" = "both" ]; then
    echo; echo "################## chroot-macOS ##################"; run_mac
fi
