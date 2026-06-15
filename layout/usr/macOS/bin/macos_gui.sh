# macos_gui.sh — start / stop the chroot macOS GUI stack (WindowServer + VNC +
# Terminal) on the iOS side, with a choice of display mode and full cleanup of
# any previously-running macOS services.
#
# Run as root from the iOS shell (NOT inside the chroot):
#
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start coexist     # iOS keeps the panel, macOS -> VNC only
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start exclusive   # macOS takes the physical panel + VNC
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh stop              # tear everything down, return to iOS
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh restart coexist   # stop, then start in the given mode
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh status            # show what is running
#
# Options for start/restart:
#   coexist | exclusive   display mode (default: coexist)
#   --no-terminal         start WindowServer + VNC only, no Terminal
#   --no-vnc              start WindowServer (+ Terminal) but no VNC server
#
# Why launchd jobs (and not just `OSXvnc &`):
#   launchdchrootexec posix_spawn()s the target with POSIX_SPAWN_SETEXEC, so it
#   *becomes* the chrooted process — there is no wrapper process to hold the
#   children alive.  A backgrounded OSXvnc/Terminal therefore dies the moment its
#   parent chroot bash (or the SSH session) exits.  launchd is the only parent
#   that survives a disconnect AND, because launchdchrootexec takes its
#   getppid()==1 "system service" path only under launchd, gives the GUI clients
#   the same launch type WindowServer already relies on.  So VNC + Terminal are
#   run as generated launchd jobs (modelled on com.apple.WindowServer.plist).
#
# NO shebang on purpose: this jailbreak's AMFI SIGKILLs execve() of any file with
# a `#!` line (see CLAUDE.md).  Always invoke via `bash <path>`.

set -u

# ─── Paths ──────────────────────────────────────────────────────────────────
ROOTFS=/var/mnt/rootfs
FLAG="$ROOTFS/tmp/ws_headless"                 # coexistence flag (chroot /tmp/ws_headless)
MACOS_DAEMONS=/var/jb/usr/macOS/LaunchDaemons  # WindowServer + launchservicesd
CHROOTEXEC=/var/jb/usr/macOS/bin/launchdchrootexec
RUN_BASH=/var/jb/usr/macOS/bin/run_bash.sh
POSTINST=/var/jb/usr/macOS/bin/postinst.sh
LOGDIR=/var/jb/var/mobile

GUI_LAUNCHD_DIR=/var/jb/usr/macOS/gui-launchd   # script-owned; NOT auto-scanned at boot
VNC_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.osxvnc.plist"
TERM_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.terminal.plist"
VNC_LABEL=com.macwsguide.osxvnc
TERM_LABEL=com.macwsguide.terminal

VNC_BIN=/usr/local/bin/OSXvnc-server                                              # chroot path
TERM_BIN="/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"   # chroot path
VNC_DESKTOP=macOS-iPad

SPRINGBOARD=/System/Library/LaunchDaemons/com.apple.SpringBoard.plist
BACKBOARDD=/System/Library/LaunchDaemons/com.apple.backboardd.plist

# Process-match patterns (full paths; unique to the chroot macOS processes so we
# never hit an iOS process by accident — iOS has no WindowServer/launchservicesd).
P_WINDOWSERVER='SkyLight.framework/Resources/WindowServer'
P_LAUNCHSERVICESD='CoreServices/launchservicesd'
P_OSXVNC='OSXvnc-server'
P_TERMINAL='Utilities/Terminal.app/Contents/MacOS/Terminal'
P_ACTIVITYMON='Activity Monitor.app/Contents/MacOS/Activity Monitor'

# ─── Watchdog (crash-loop safety net) ───────────────────────────────────────
# WindowServer composites window content through the MTLSim Metal bridge, whose
# host (MTLSimDriverHost) can NULL-deref under heavy compositing. When it dies,
# SkyLight asserts on the resulting nil texture and WindowServer aborts; launchd
# relaunches it on-demand, it re-inits, crashes again — a restart storm that
# drives the 1-min load average toward ~44 and risks a kernel panic/reboot.
# The watchdog auto-stops the GUI when it sees that runaway, protecting the device.
WD_LOAD_LIMIT=25     # 1-min load average that triggers a protective stop
WD_RESTART_LIMIT=4   # WindowServer restarts within WD_WINDOW that means "crash loop"
WD_WINDOW=45         # seconds — restart-counting window
WD_POLL=5            # seconds between checks
WD_LOG="$LOGDIR/macos_gui_watchdog.log"

# ─── Helpers ────────────────────────────────────────────────────────────────
log() { echo "[macos_gui] $*"; }

require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "macos_gui.sh: must run as root — use:  sudo bash $0 $*" >&2
        exit 1
    fi
}

# Kill chroot macOS processes whose full command line contains a (fixed-string)
# pattern. This device has no pkill/pgrep, so do it with ps + kill. Patterns are
# full chroot paths, unique to the macOS processes, so iOS processes are never hit.
kill_by_pattern() {
    local pat="$1" pids
    pids=$(ps aux 2>/dev/null | grep -v grep | grep -F "$pat" | awk '{print $2}')
    [ -n "$pids" ] && kill $pids 2>/dev/null
    return 0
}

# True if any running process's command line contains the (fixed-string) pattern.
proc_running() {
    ps aux 2>/dev/null | grep -v grep | grep -qF "$1"
}

# launchd's current PID for WindowServer (empty / "-" when not running).
ws_pid() {
    launchctl list com.apple.WindowServer 2>/dev/null \
        | awk -F'= ' '/"PID"/{gsub(/[ ";]/,"",$2); print $2}'
}

# 1-minute load average (integer part) from `uptime`.
load1_int() {
    uptime 2>/dev/null | sed -E 's/.*load averages?:[[:space:]]*([0-9]+).*/\1/'
}

# Watchdog loop (runs iOS-side, backgrounded by `start`). Stops the GUI if
# WindowServer crash-loops or the load average runs away.
run_watchdog() {
    local last_pid="" restarts=0 t0 now pid L
    t0=$(date +%s)
    log "watchdog: armed (load>=$WD_LOAD_LIMIT or >=$WD_RESTART_LIMIT WS restarts / ${WD_WINDOW}s -> auto-stop)"
    while :; do
        sleep "$WD_POLL"
        # If WindowServer is gone for good, there is nothing to guard.
        if ! proc_running "$P_WINDOWSERVER"; then
            log "watchdog: WindowServer not running — exiting."
            return 0
        fi
        pid=$(ws_pid)
        if [ -n "$pid" ] && [ "$pid" != "-" ] && [ -n "$last_pid" ] && [ "$pid" != "$last_pid" ]; then
            restarts=$((restarts + 1))
            log "watchdog: WindowServer restarted ($last_pid -> $pid), count=$restarts in window"
        fi
        [ -n "$pid" ] && [ "$pid" != "-" ] && last_pid="$pid"
        now=$(date +%s)
        if [ $((now - t0)) -ge "$WD_WINDOW" ]; then restarts=0; t0=$now; fi
        L=$(load1_int); [ -z "$L" ] && L=0
        if [ "$L" -ge "$WD_LOAD_LIMIT" ] || [ "$restarts" -ge "$WD_RESTART_LIMIT" ]; then
            log "watchdog: RUNAWAY detected (load=$L, WS restarts=$restarts) -> stopping GUI to protect the device"
            stop_all
            return 0
        fi
    done
}

# True if a macOS binary can actually run in the chroot right now.
chroot_works() {
    case "$(bash "$RUN_BASH" -c 'echo __CHROOT_OK__' 2>/dev/null)" in
        *__CHROOT_OK__*) return 0 ;;
        *)               return 1 ;;
    esac
}

# Self-heal the most common post-reboot failure: the trustcache is volatile
# (code signatures persist across reboots, the trustcache does NOT), so after a
# reboot AMFI SIGKILLs every chroot process (exit 137) until postinst.sh
# re-registers all CDHashes. Detect that and run postinst.sh automatically.
ensure_chroot_works() {
    log "Checking the macOS chroot is runnable..."
    if chroot_works; then
        log "chroot OK."
        return 0
    fi
    log "chroot not runnable (trustcache was likely wiped by a reboot)."
    if [ -f "$POSTINST" ]; then
        log "Re-registering trustcaches via postinst.sh (~1 min)..."
        bash "$POSTINST" > "$LOGDIR/postinst.log" 2>&1
        if chroot_works; then
            log "chroot OK after postinst."
            return 0
        fi
    fi
    log "ERROR: macOS chroot still not runnable after postinst — aborting."
    log "       Inspect: $LOGDIR/postinst.log  and  sudo dmesg | grep AMFI"
    return 1
}

write_plists() {
    mkdir -p "$GUI_LAUNCHD_DIR"

    cat > "$VNC_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${VNC_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${VNC_BIN}</string>
        <string>-rfbnoauth</string>
        <string>-desktop</string>
        <string>${VNC_DESKTOP}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${LOGDIR}/osxvnc.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGDIR}/osxvnc.log</string>
</dict>
</plist>
PLIST

    # Terminal is a GUI app: start it once (RunAtLoad) but do NOT relaunch when
    # the user closes it (KeepAlive false) so launchd does not thrash.
    cat > "$TERM_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${TERM_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${TERM_BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOGDIR}/terminal.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGDIR}/terminal.log</string>
</dict>
</plist>
PLIST
}

# Tear down every macOS GUI service we may have started.  Idempotent: unloading a
# job that is not loaded / killing a process that is gone are harmless no-ops.
cleanup_macos() {
    log "Cleaning up previous macOS GUI services..."

    # 1) our VNC / Terminal launchd jobs (by plist, then by label as a fallback)
    launchctl unload "$VNC_PLIST"  2>/dev/null
    launchctl unload "$TERM_PLIST" 2>/dev/null
    launchctl remove "$VNC_LABEL"  2>/dev/null
    launchctl remove "$TERM_LABEL" 2>/dev/null

    # 2) stray GUI clients (Terminal, VNC, Activity Monitor, ...)
    kill_by_pattern "$P_OSXVNC"
    kill_by_pattern "$P_TERMINAL"
    kill_by_pattern "$P_ACTIVITYMON"

    # 3) the WindowServer + launchservicesd daemons
    launchctl unload "$MACOS_DAEMONS" 2>/dev/null

    # 4) anything still lingering
    kill_by_pattern "$P_WINDOWSERVER"
    kill_by_pattern "$P_LAUNCHSERVICESD"

    sleep 1
    log "Cleanup done."
}

mode_coexist() {
    log "Display mode: COEXISTENCE — iPad panel stays on iOS, macOS renders to VNC only."
    touch "$FLAG"
    # Make sure the iOS UI is up (a previous 'exclusive' run may have unloaded it).
    launchctl load "$BACKBOARDD"  2>/dev/null
    launchctl load "$SPRINGBOARD" 2>/dev/null
}

mode_exclusive() {
    log "Display mode: EXCLUSIVE — macOS takes over the physical panel (and VNC)."
    log "WARNING: exclusive mode drives the panel from WindowServer; on this device"
    log "         that GPU path is the most panic-prone. coexist is the safer choice."
    rm -f "$FLAG"
    # Hand the panel to macOS: stop iOS SpringBoard/backboardd (SpringBoard first).
    launchctl unload "$SPRINGBOARD" 2>/dev/null
    launchctl unload "$BACKBOARDD"  2>/dev/null
}

start_macos() {
    log "Loading macOS WindowServer + launchservicesd..."
    launchctl load "$MACOS_DAEMONS"

    if [ "$WANT_VNC" = 1 ]; then
        log "Starting VNC server (launchd job '$VNC_LABEL', persistent)..."
        rm -f "$LOGDIR/osxvnc.log"
        launchctl load "$VNC_PLIST"
    fi

    if [ "$WANT_TERMINAL" = 1 ]; then
        # Give WindowServer (triggered by the VNC lookup) a moment to check in
        # before Terminal tries to connect to it.
        log "Waiting for WindowServer to come up..."
        sleep 5
        log "Starting Terminal (launchd job '$TERM_LABEL')..."
        rm -f "$LOGDIR/terminal.log"
        launchctl load "$TERM_PLIST"
    fi
}

stop_all() {
    cleanup_macos
    rm -f "$FLAG"
    log "Restoring iOS (SpringBoard / backboardd)..."
    launchctl load "$BACKBOARDD"  2>/dev/null
    launchctl load "$SPRINGBOARD" 2>/dev/null
    log "Stopped. The iPad is back on iOS."
}

status() {
    echo "=== macOS GUI status ==="
    if [ -e "$FLAG" ]; then
        echo "mode flag : present  -> COEXISTENCE (panel = iOS, macOS = VNC)"
    else
        echo "mode flag : absent   -> EXCLUSIVE (macOS owns the panel) / or stopped"
    fi
    echo
    echo "-- processes --"
    ps aux | grep -iE "$P_WINDOWSERVER|$P_OSXVNC|$P_TERMINAL|$P_LAUNCHSERVICESD" \
        | grep -v grep || echo "(none running)"
    echo
    echo "-- launchd jobs --"
    launchctl list 2>/dev/null | grep -iE "WindowServer|launchservices|macwsguide" \
        || echo "(none loaded)"
    echo
    if proc_running "$P_OSXVNC"; then
        echo "VNC: running -> connect with  vnc://<device-ip>:5900   (no password)"
    else
        echo "VNC: not running"
    fi
    echo
    echo "logs: $LOGDIR/osxvnc.log  $LOGDIR/terminal.log  $LOGDIR/WindowServer.err"
}

usage() {
    cat <<USAGE
macos_gui.sh — start/stop the chroot macOS GUI (WindowServer + VNC + Terminal)

Usage (run as root):
  sudo bash $0 start [coexist|exclusive] [--no-terminal] [--no-vnc] [--no-watchdog]
  sudo bash $0 stop
  sudo bash $0 restart [coexist|exclusive] [...]
  sudo bash $0 status

Modes:
  coexist     (default) iPad panel keeps showing iOS; macOS renders to VNC only.
  exclusive   macOS takes over the physical panel as well as VNC.

Safety: `start` also launches a background watchdog that auto-stops the GUI if
WindowServer crash-loops or the load average runs away (panic guard). Disable
with --no-watchdog. Logs to $LOGDIR/macos_gui_watchdog.log.

Connect a VNC viewer to  vnc://<device-ip>:5900  (no password).
USAGE
}

# ─── Argument parsing ───────────────────────────────────────────────────────
CMD="${1:-}"
[ $# -gt 0 ] && shift

MODE=coexist
WANT_VNC=1
WANT_TERMINAL=1
WANT_WATCHDOG=1
for a in "$@"; do
    case "$a" in
        coexist|coexistence|co)  MODE=coexist ;;
        exclusive|full|excl)     MODE=exclusive ;;
        --no-terminal)           WANT_TERMINAL=0 ;;
        --no-vnc)                WANT_VNC=0 ;;
        --no-watchdog)           WANT_WATCHDOG=0 ;;
        *) echo "macos_gui.sh: ignoring unknown option '$a'" >&2 ;;
    esac
done

# Launch the crash-loop watchdog in the background (iOS-side, survives SSH
# disconnect via nohup). Re-invokes this script in `watchdog` mode.
start_watchdog() {
    [ "$WANT_WATCHDOG" = 1 ] || { log "watchdog: disabled (--no-watchdog)"; return 0; }
    rm -f "$WD_LOG"
    nohup bash "$0" watchdog > "$WD_LOG" 2>&1 < /dev/null &
    log "watchdog: started in background (log: $WD_LOG)"
}

case "$CMD" in
    start)
        require_root "$@"
        write_plists
        ensure_chroot_works || exit 1
        cleanup_macos
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        start_macos
        start_watchdog
        echo
        log "Started in $MODE mode."
        status
        ;;
    stop)
        require_root "$@"
        stop_all
        ;;
    restart)
        require_root "$@"
        write_plists
        ensure_chroot_works || exit 1
        stop_all
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        start_macos
        start_watchdog
        echo
        log "Restarted in $MODE mode."
        status
        ;;
    status)
        status
        ;;
    watchdog)
        require_root "$@"
        run_watchdog
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        echo "macos_gui.sh: unknown command '$CMD'" >&2
        usage
        exit 1
        ;;
esac
