# Run explicitly with bash; keeping this file shebang-free also makes a synced
# copy safe under the jailbreak's AMFI shebang restriction.
# Usage: bash misc/deploy_macwswindowing.sh [device-ip]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEVICE_IP="${1:-192.168.1.6}"
DEVICE_USER="${MACWS_DEVICE_USER:-mobile}"
DEVICE_SSH="${DEVICE_USER}@${DEVICE_IP}"
BUILD_DIR="$PROJECT_DIR/MacWSWindowing"
BUILT="$BUILD_DIR/.theos/obj/MacWSWindowing.dylib"
REMOTE_DIR=/var/jb/var/mobile/macws-cross-build
REMOTE_NEW="$REMOTE_DIR/MacWSWindowing.dylib.new"
REMOTE_BINARY="$REMOTE_DIR/MacWSWindowing.dylib"
REMOTE_SHA="$REMOTE_DIR/MacWSWindowing.sha256"
INSTALLED=/var/jb/usr/lib/TweakInject/MacWSWindowing.dylib

gmake -C "$BUILD_DIR" clean all \
    FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1

[ -s "$BUILT" ] || {
    echo "Error: MacWSWindowing build product not found: $BUILT" >&2
    exit 1
}

FIXUPS=$(mktemp)
trap 'rm -f "$FIXUPS"' EXIT
dyld_info -arch arm64e -fixups "$BUILT" > "$FIXUPS"
cf_count=$(awk '$2 == "__cfstring" && $4 == "auth-bind" && /key=DA/ { count++ } END { print count+0 }' "$FIXUPS")
plain_cf_count=$(awk '$2 == "__cfstring" && $4 == "bind" { count++ } END { print count+0 }' "$FIXUPS")
if [ "$cf_count" -lt 1 ] || [ "$plain_cf_count" -ne 0 ]; then
    echo "Error: Apple-ld64 auth-fixup invariant failed (auth=$cf_count plain=$plain_cf_count)." >&2
    exit 1
fi
echo "==> Verified arm64e __cfstring fixups: auth-bind/key=DA count=$cf_count, plain-bind count=0"

ssh "$DEVICE_SSH" "mkdir -p '$REMOTE_DIR'"
scp "$BUILT" "$DEVICE_SSH:$REMOTE_NEW"

# sudo is intentionally interactive unless the caller has configured a sudo
# credential helper. No password is stored in this repository.
ssh -t "$DEVICE_SSH" "sudo sh -c '
set -e
ldid -h \"$REMOTE_NEW\" >/dev/null
mv \"$REMOTE_NEW\" \"$REMOTE_BINARY\"
chown root:wheel \"$REMOTE_BINARY\"
chmod 0755 \"$REMOTE_BINARY\"
sha256sum \"$REMOTE_BINARY\" > \"$REMOTE_SHA\"
tmp=\"${INSTALLED}.apple-ld64-new\"
cp \"$REMOTE_BINARY\" \"\$tmp\"
chown root:wheel \"\$tmp\"
chmod 0755 \"\$tmp\"
mv \"\$tmp\" \"$INSTALLED\"
rm -f /var/mobile/.eksafemode
rm -f /var/mobile/Library/Preferences/com.macwsguide.dense-grid.loaded
killall SpringBoard
'"

echo "==> Installed validated MacWSWindowing; SpringBoard is restarting"
