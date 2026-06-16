# Re-sign VSCode with the JIT-enabled entitlements plist.
# Runs from the iOS shell (NOT inside chroot).
ENT=/var/jb/usr/macOS/bin/vscode_entitlements.plist
APP="/var/mnt/rootfs/Applications/Visual Studio Code.app"
LDID=/var/jb/usr/bin/ldid
JBCTL=/var/jb/usr/bin/jbctl

set -u
echo "=== entitlements: $ENT ==="
ls -la "$ENT"
echo
echo "=== walking app, signing every Mach-O ==="

SIGNED=0
TRUSTED=0
SKIPPED=0
ERR=0

while IFS= read -r f; do
    # Try ldid sign first. Non-Mach-O exits non-zero quietly.
    if ! "$LDID" -S"$ENT" -M "$f" 2>/dev/null; then
        SKIPPED=$((SKIPPED+1))
        continue
    fi
    SIGNED=$((SIGNED+1))
    for arch in arm64 arm64e; do
        h=$("$LDID" -arch "$arch" -h "$f" 2>/dev/null | grep CDHash= | cut -c8- | tr 'A-F' 'a-f')
        if [ -n "$h" ]; then
            if "$JBCTL" trustcache add "$h" 2>/dev/null; then
                TRUSTED=$((TRUSTED+1))
            fi
        fi
    done
done < <(find "$APP" -type f)

echo
echo "summary: signed=$SIGNED trustcache_add=$TRUSTED skipped(non-Mach-O)=$SKIPPED err=$ERR"
