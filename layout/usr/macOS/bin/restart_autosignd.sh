# No shebang: AMFI rejects execve of shebang scripts on this device. Invoke
# this file through bash from package/runtime post-installation paths.

AUTOSIGND=/var/jb/usr/macOS/bin/autosignd
AUTOSIGND_SOCKET=/var/mnt/rootfs/tmp/autosignd.sock
AUTOSIGND_LOG=/var/mnt/rootfs/tmp/autosignd.log
KILLALL=/var/jb/usr/bin/killall
LDID=/var/jb/usr/bin/ldid
JBCTL=/var/jb/usr/bin/jbctl

[ -x "$AUTOSIGND" ] || exit 0

# The dynamic trustcache is reboot-volatile and autosignd is itself the first
# image in this signing path, so it must be admitted before it can help any
# chroot child.
for arch in arm64 arm64e; do
    hash=$("$LDID" -arch "$arch" -h "$AUTOSIGND" 2>/dev/null |
        grep CDHash= | cut -c8-)
    [ -n "$hash" ] && "$JBCTL" trustcache add "$hash" 2>/dev/null || true
done

# A package can be configured before the macOS rootfs is mounted. In that
# state there is no socket namespace shared with the future chroot, so defer
# daemon publication to the normal startup repair instead of creating a
# misleading iOS-root socket.
if [ ! -d /var/mnt/rootfs/tmp ]; then
    echo '[INFO] autosignd start deferred until the macOS rootfs is mounted'
    exit 0
fi

# Procursus on the target has no pkill. The former unqualified call leaked one
# daemon per installation, each blocked on an unlinked socket inode. Retire
# exactly autosignd, allow a bounded normal exit, then force only survivors.
if [ -x "$KILLALL" ]; then
    "$KILLALL" autosignd 2>/dev/null || true
    autosignd_wait=0
    while "$KILLALL" -0 autosignd 2>/dev/null &&
          [ "$autosignd_wait" -lt 20 ]; do
        sleep 0.1
        autosignd_wait=$((autosignd_wait + 1))
    done
    if "$KILLALL" -0 autosignd 2>/dev/null; then
        "$KILLALL" -9 autosignd 2>/dev/null || true
    fi
fi

rm -f "$AUTOSIGND_SOCKET"
if [ -x /var/jb/usr/bin/nohup ]; then
    /var/jb/usr/bin/nohup "$AUTOSIGND" >"$AUTOSIGND_LOG" 2>&1 &
else
    nohup "$AUTOSIGND" >"$AUTOSIGND_LOG" 2>&1 &
fi

autosignd_wait=0
while [ ! -S "$AUTOSIGND_SOCKET" ] && [ "$autosignd_wait" -lt 50 ]; do
    sleep 0.1
    autosignd_wait=$((autosignd_wait + 1))
done
if [ ! -S "$AUTOSIGND_SOCKET" ]; then
    echo '[ERROR] autosignd did not publish its socket' >&2
    exit 1
fi

echo '[INFO] started one autosignd instance and verified its socket'
