# DetileTest — cross-compile on Mac, deploy over USB iproxy, run in chroot.
#
# Usage (NO shebang on purpose — run via `bash misc/DetileTest/build_and_run.sh`):
#   bash misc/DetileTest/build_and_run.sh            # 2388x1668 (display size)
#   bash misc/DetileTest/build_and_run.sh 512 512    # custom dims
#
# Builds the arm64e slice (the real AGX path). Deploys to the rootfs, signs +
# trustcaches, and runs in the chroot with the AGX-native env so it sees the
# real AGX device (same path WindowServer uses).
set -e

PORT="${PORT:-22222}"
HOST="${HOST:-127.0.0.1}"
PW="${PW:-alpine}"
W="${1:-2388}"
H="${2:-1668}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/main.m"
OUT=/tmp/detile_test
ENT="$HERE/../../entitlements.plist"

echo "=== cross-compiling arm64e (macOS 13.0) ==="
xcrun -sdk macosx clang \
  -arch arm64e -mmacosx-version-min=13.0 \
  -fobjc-arc -fmodules \
  -framework Foundation -framework Metal -framework IOSurface \
  "$SRC" -o "$OUT"
file "$OUT"

echo "=== signing locally (entitlements) ==="
ldid -S"$ENT" "$OUT" 2>/dev/null || codesign -f -s - --entitlements "$ENT" "$OUT" 2>/dev/null || true

echo "=== deploying over iproxy :$PORT ==="
sshpass_or_scp() {
  # No sshpass assumed; rely on key auth (USB host is in authorized_keys).
  scp -P "$PORT" -o ConnectTimeout=10 "$OUT" "root@$HOST:/var/mnt/rootfs/tmp/detile_test"
}
sshpass_or_scp

echo "=== sign + trustcache on device ==="
ssh -p "$PORT" -o ConnectTimeout=10 "root@$HOST" "echo $PW | sudo -S sh -c '
  ENT=/var/jb/usr/macOS/bin/entitlements.plist
  BIN=/var/mnt/rootfs/tmp/detile_test
  chmod 0755 \"\$BIN\"
  ldid -S\"\$ENT\" -M \"\$BIN\"
  for a in arm64 arm64e; do
    h=\$(ldid -arch \$a -h \"\$BIN\" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n \"\$h\" ] && /var/jb/usr/bin/jbctl trustcache add \"\$h\" && echo \"trusted[\$a]=\$h\"
  done
'"

echo "=== running in chroot ==="
ssh -p "$PORT" -o ConnectTimeout=20 "root@$HOST" "echo $PW | sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh -c '
  export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
  export MACWS_AGX_NATIVE=1
  export MACWS_AGX_REGISTER_CLASSES=1
  export MACWS_PIN_FALLBACK=1
  export MACWS_AGX_CRASH_DIAG=1
  /tmp/detile_test $W $H
'" 2>&1
echo "=== exit: $? ==="
