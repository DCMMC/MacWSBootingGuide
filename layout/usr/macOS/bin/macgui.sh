# macgui.sh — one-shot manager for the macOS GUI coexistence stack on jailbroken iOS.
#
# Brings up (or tears down) macOS WindowServer + launchservicesd + OSXvnc-server + Terminal
# so macOS renders into VNC (:5900) while iOS keeps the physical iPad panel — no flicker
# (libmachook auto-detects a running backboardd and suppresses WindowServer's panel scanout).
#
# Usage (from the iOS shell, needs root — like run_bash.sh):
#   sudo bash /var/jb/usr/macOS/bin/macgui.sh [start|stop|status]
#     start   (default) kill stale procs, then start the whole stack
#     stop    kill the whole macOS GUI stack (the iOS UI keeps running)
#     status  show what is currently running
#
# Notes:
#  - After a device REBOOT the Dopamine trustcache is lost and the chroot is AMFI-killed;
#    `start` detects that and re-runs postinst.sh automatically (slow, ~1 min).
#  - pkill -f is unreliable in this environment, so processes are killed by explicit pid.
#  - There is NO shebang on purpose (AMFI blocks execve of shebang files); always invoke
#    it via `bash .../macgui.sh`.

JB=/var/jb
WS_PLIST="$JB/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist"
LSD_PLIST="$JB/usr/macOS/LaunchDaemons/com.apple.coreservices.launchservicesd.plist"
RUN_BASH="$JB/usr/macOS/bin/run_bash.sh"
CHROOT_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
MODE="${1:-start}"

log() { echo "[macgui] $*"; }

if [ "$(id -u)" != "0" ]; then echo "[macgui] ERROR: run as root (sudo)."; exit 1; fi

# pids of processes whose full command contains $1 (excluding the grep itself)
pids_for() { ps -axo pid,command 2>/dev/null | grep -F "$1" | grep -v grep | awk '{print $1}'; }

kill_stack() {
    log "stopping macOS GUI stack (kill by pid; pkill -f is unreliable here)..."
    launchctl bootout system/com.apple.WindowServer 2>/dev/null
    # NOTE: do NOT bootout launchservicesd — it's a shared on-demand service; tearing it down
    # then racing a reload leaves it un-runnable and .app launches (Terminal) then fail.
    for pat in "Resources/WindowServer" "MTLSimDriverHost" "OSXvnc-server" "MacOS/Terminal"; do
        for p in $(pids_for "$pat"); do kill -9 "$p" 2>/dev/null && log "  killed $p ($pat)"; done
    done
    sleep 2
}

show_status() {
    log "processes:"
    ps -axo pid,comm 2>/dev/null \
      | grep -iE "Resources/WindowServer|MTLSimDriverHost|MacOS/Terminal|OSXvnc|launchservicesd|SpringBoard\$|backboardd" \
      | grep -v grep | sed 's/^/  /'
    uptime 2>/dev/null | sed 's/.*平均负载/  load/;s/.*load average/  load/'
}

case "$MODE" in
  stop)   kill_stack; log "stopped (iOS UI still running)."; exit 0 ;;
  status) show_status; exit 0 ;;
  start)  ;;
  *) echo "usage: bash $0 [start|stop|status]"; exit 1 ;;
esac

# ---- start ----
kill_stack

# Chroot runnable? After a reboot the trustcache is gone -> AMFI Killed:9 -> re-trustcache.
# (run_bash exits 0 even when the inner exec is killed, so check stdout, not the exit code.)
if [ "$(bash "$RUN_BASH" -c 'echo READY' 2>/dev/null)" != "READY" ]; then
    log "chroot not runnable (trustcache lost after reboot?) — running postinst.sh (slow ~1min)..."
    bash "$JB/usr/macOS/bin/postinst.sh" >/tmp/macgui_postinst.log 2>&1
    log "  postinst done (log: /tmp/macgui_postinst.log)"
fi

# launchd rejects plists not owned root:wheel (dpkg installs them as the build user).
chown root:wheel "$JB"/usr/macOS/LaunchDaemons/*.plist 2>/dev/null
chmod 644 "$JB"/usr/macOS/LaunchDaemons/*.plist 2>/dev/null

log "starting WindowServer..."
launchctl load "$WS_PLIST" 2>/dev/null
# plain kickstart (NOT -k): kill_stack already killed it, and `-k` misbehaves when the
# target isn't currently running.
launchctl kickstart system/com.apple.WindowServer 2>/dev/null
WS=""
for i in $(seq 1 20); do
    WS=$(pids_for "Resources/WindowServer" | head -1)
    [ -n "$WS" ] && break
    sleep 0.5
done
if [ -n "$WS" ]; then log "  WindowServer pid=$WS"; else
    log "  ERROR: WindowServer did not start (see /var/jb/var/mobile/WindowServer.err)"; fi

log "ensuring launchservicesd is up (needed for .app launches)..."
launchctl load "$LSD_PLIST" 2>/dev/null            # idempotent ("already bootstrapped" is fine)
launchctl kickstart system/com.apple.coreservices.launchservicesd 2>/dev/null
LSD=""
for i in $(seq 1 16); do
    LSD=$(pids_for "launchservicesd" | head -1)
    [ -n "$LSD" ] && break
    sleep 0.5
done
if [ -n "$LSD" ]; then log "  launchservicesd pid=$LSD"; else
    log "  WARNING: launchservicesd not up — Terminal may fail to launch"; fi

log "starting OSXvnc-server on :5900..."
bash "$RUN_BASH" -c "export PATH=$CHROOT_PATH; /usr/local/bin/OSXvnc-server -rfbnoauth -rfbport 5900 >/tmp/vnc.out 2>&1 &" >/dev/null 2>&1
sleep 2

log "starting Terminal.app..."
bash "$RUN_BASH" -c "export PATH=$CHROOT_PATH; /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal >/tmp/term.out 2>&1 &" >/dev/null 2>&1
sleep 3

show_status
IP=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null)
if [ -n "$IP" ]; then
    log "done — connect VNC to $IP:5900 (macOS in VNC, iOS on the panel, no flicker)."
else
    log "done — connect your VNC viewer to this device on port 5900 (macOS in VNC, iOS on the panel, no flicker)."
fi
