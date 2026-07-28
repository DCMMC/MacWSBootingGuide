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
#   --experimental        enable the current command/completion diagnostics
#   --no-terminal         start WindowServer + VNC only, no Terminal
#   --no-vnc              start WindowServer (+ Terminal) but no VNC server
#   --pace-us=N           diagnostic synthetic-completion pace (8333..100000)
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
INPUT_PLIST="$MACOS_DAEMONS/com.macwsguide.input.plist"
VNC_LABEL=com.macwsguide.osxvnc
TERM_LABEL=com.macwsguide.terminal
INPUT_LABEL=com.macwsguide.input
VSCODE_PLIST=/var/jb/Library/LaunchDaemons/com.macwsguide.vscode.plist
VSCODE_LABEL=com.macwsguide.vscode
EXPERIMENTAL_KCMD="$ROOTFS/private/tmp/macws_kcmd_fix"
EXPERIMENTAL_WRAPPED_KCMD="$ROOTFS/private/tmp/macws_kcmd_wrapped_fix"
EXPERIMENTAL_COMMAND_ERROR="$ROOTFS/private/tmp/macws_command_error_diag"
EXPERIMENTAL_COMPLETION="$ROOTFS/private/tmp/macws_cancel_completion"
EXPERIMENTAL_VNC_SHARE="$ROOTFS/private/tmp/macws_vnc_share"
EXPERIMENTAL_OBSERVE_PF550="$ROOTFS/private/tmp/macws_observe_pf550"
EXPERIMENTAL_SUBMIT_RING="$ROOTFS/private/tmp/macws_submit_ring"
EXPERIMENTAL_OWNED_SCANOUT="$ROOTFS/private/tmp/macws_owned_scanout"
EXPERIMENTAL_PACE="$ROOTFS/private/tmp/macws_coexist_pace_us"
EXPERIMENTAL_CAPTURE="$ROOTFS/private/tmp/macws_capture_final"
EXPERIMENTAL_CAPTURE_DONE="$ROOTFS/private/tmp/macws_capture_done"
VNC_SHARED_FRAME="$ROOTFS/private/tmp/macws_vnc_fb"
VNC_SHARED_SURFID="$ROOTFS/private/tmp/macws_vnc_surfid"
VNC_ACTIVITY="$ROOTFS/private/tmp/macws_vnc_activity"
ARMED_CAPTURE_GENERATION=""
CAPTURE_READY_WAIT=60
WINDOWSERVER_READY_WAIT=45
STARTED_WS_PID=""

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
P_GLASSDEMO='/tmp/GlassDemo'
P_FINDER='CoreServices/Finder.app/Contents/MacOS/Finder'
P_INPUTD='/usr/local/bin/macwsinputd'
P_VSCODE='Visual Studio Code.app/Contents/'

# ─── Watchdog (crash-loop safety net) ───────────────────────────────────────
# WindowServer composites window content through the MTLSim Metal bridge, whose
# host (MTLSimDriverHost) can NULL-deref under heavy compositing. When it dies,
# SkyLight asserts on the resulting nil texture and WindowServer aborts; launchd
# relaunches it on-demand, it re-inits, crashes again — a restart storm that
# drives the 1-min load average toward ~44 and risks a kernel panic/reboot.
# The watchdog auto-stops the GUI when it sees that runaway, protecting the device.
WD_LOAD_LIMIT=60     # 1-min load average that triggers a protective stop
                     # (raised from 25: Firefox software WebRender legitimately runs hot
                     #  without crashlooping; the WS-restart counter still catches real
                     #  crashloops)
WD_RESTART_LIMIT=12  # WindowServer restarts within WD_WINDOW that means "crash loop"
                     # (raised from 4: Firefox triggers some SkyLight CAWSBackend asserts
                     #  we haven't byte-patched yet (render_update composite_destination
                     #  nullptr). launchd respawns WS in ~1s; up to ~12 restarts per 45s
                     #  is annoying but not yet runaway — only stop if it's much worse)
WD_WINDOW=45         # seconds — restart-counting window
WD_POLL=5            # seconds between checks
WD_LOAD_GRACE=90      # inherited 1-min load average is stale after userspace restart;
                      # restart-storm protection remains active during this grace period
WD_WS_CPU_LIMIT=70    # sustained one-core WindowServer use is the thermal failure signal
WD_WS_CPU_STRIKES=6   # six 5-second samples = 30 seconds above the limit
WD_DIAG_MAX_RUNTIME=300 # bounded VNC test window; CPU/restart guards remain active
WD_LOG="$LOGDIR/macos_gui_watchdog.log"
WD_TRIP="$LOGDIR/macws_safety_trip"
RECOVERED_WS_PID=""
RECOVERY_EXTRA_RESTARTS=0

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

# Do not connect multiple CGS clients while WindowServer is still realizing
# AGX classes, compiling its first pipelines, and publishing the first display
# command buffer.  Runtime A/B on 2026-07-27 showed 2400/2400 clean producer
# completions when clients were staggered, while the old simultaneous startup
# let the first WindowServer die with SIGSEGV and left VNC attached to a dead
# CGS session.  In experimental mode, a clean producer completion is the
# strongest readiness witness; otherwise require a stable PID for eight
# consecutive samples.
wait_for_initial_ws_ready() {
    local log_start_line="$1" current="" previous="" stable=0 waited=0
    while [ "$waited" -lt "$WINDOWSERVER_READY_WAIT" ]; do
        sleep 1
        waited=$((waited + 1))
        current=$(ws_pid)
        if [ -z "$current" ] || [ "$current" = "-" ]; then
            previous=""
            stable=0
            continue
        fi
        if [ "$current" = "$previous" ]; then
            stable=$((stable + 1))
        else
            previous="$current"
            stable=1
        fi

        if [ "$WANT_EXPERIMENTAL" = 1 ]; then
            if [ "$stable" -ge 2 ] &&
               sed -n "${log_start_line},\$p" "$LOGDIR/WindowServer.err" \
                   2>/dev/null \
                   | grep -qE 'VNC-FLOW poll-result.*status=4.*code=0'; then
                STARTED_WS_PID="$current"
                log "WindowServer graphics ready (pid=$current, clean producer observed)."
                return 0
            fi
        elif [ "$stable" -ge 8 ]; then
            STARTED_WS_PID="$current"
            log "WindowServer ready (pid=$current, stable for ${stable}s)."
            return 0
        fi
    done
    log "ERROR: WindowServer did not reach graphics-ready state after ${WINDOWSERVER_READY_WAIT}s."
    return 1
}

started_ws_unchanged() {
    local stage="$1" current
    current=$(ws_pid)
    if [ -n "$STARTED_WS_PID" ] && [ "$current" = "$STARTED_WS_PID" ]; then
        return 0
    fi
    log "ERROR: WindowServer changed during $stage (ready=$STARTED_WS_PID current=${current:--})."
    log "       Refusing to leave VNC attached to a dead CGS session."
    return 1
}

# 1-minute load average (integer part) from `uptime`.
load1_int() {
    uptime 2>/dev/null | sed -E 's/.*load averages?:[[:space:]]*([0-9]+).*/\1/'
}

# Integer CPU percentage for one exact PID. Unlike load average this catches a
# single WindowServer core spinning at 70-90%, which runtime-confirmed the
# 2026-07-26 thermal incident while the whole-system load average stayed near 1.
ws_cpu_int() {
    local wanted="$1"
    ps -ax -o pid=,%cpu= 2>/dev/null \
        | awk -v wanted="$wanted" '$1 == wanted { printf "%d\n", $2 + 0; exit }'
}

# A GUI client cannot reuse its WindowServer connection after that server dies.
# Runtime evidence from OSXvnc is explicit:
#   "received notification of WindowServer event port death"
#   "port matched the WindowServer port created in BindCGSToRunLoop"
# Keeping that old process alive therefore leaves a valid TCP listener backed by
# a permanently dead CGS session.  Tear down only WS-dependent clients, wait for
# launchd's replacement WS to stay alive for two samples, then reconnect them.
stop_ws_dependents() {
    launchctl unload "$VNC_PLIST"  2>/dev/null
    launchctl unload "$TERM_PLIST" 2>/dev/null
    launchctl remove "$VNC_LABEL"  2>/dev/null
    launchctl remove "$TERM_LABEL" 2>/dev/null
    launchctl unload "$INPUT_PLIST" 2>/dev/null
    launchctl remove "$INPUT_LABEL" 2>/dev/null
    launchctl unload "$VSCODE_PLIST" 2>/dev/null
    launchctl remove "$VSCODE_LABEL" 2>/dev/null

    kill_by_pattern "$P_OSXVNC"
    kill_by_pattern "$P_TERMINAL"
    kill_by_pattern "$P_ACTIVITYMON"
    kill_by_pattern "$P_GLASSDEMO"
    kill_by_pattern "$P_FINDER"
    kill_by_pattern "$P_INPUTD"
    kill_by_pattern "$P_VSCODE"
    rm -f "$ROOTFS"/private/tmp/macws_app_input.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_input_target.sock
}

wait_for_replacement_ws() {
    local expected="$1" current="" stable=0 tries=0
    RECOVERY_EXTRA_RESTARTS=0
    while [ "$tries" -lt 20 ]; do
        sleep 1
        tries=$((tries + 1))
        current=$(ws_pid)
        if [ -z "$current" ] || [ "$current" = "-" ]; then
            stable=0
            continue
        fi
        if [ "$current" != "$expected" ]; then
            log "watchdog: replacement WindowServer changed again ($expected -> $current)"
            expected="$current"
            stable=1
            RECOVERY_EXTRA_RESTARTS=$((RECOVERY_EXTRA_RESTARTS + 1))
        else
            stable=$((stable + 1))
        fi
        if [ "$stable" -ge 2 ]; then
            RECOVERED_WS_PID="$current"
            return 0
        fi
    done
    RECOVERED_WS_PID=""
    return 1
}

recover_ws_dependents() {
    local old_pid="$1" observed_pid="$2"
    log "watchdog: reconnecting GUI clients to replacement WindowServer $observed_pid"
    stop_ws_dependents
    rm -f "$EXPERIMENTAL_CAPTURE" "$EXPERIMENTAL_CAPTURE_DONE"

    if ! wait_for_replacement_ws "$observed_pid"; then
        log "watchdog: replacement WindowServer did not become stable within 20 seconds"
        return 1
    fi

    if [ -f "$INPUT_PLIST" ]; then
        launchctl load "$INPUT_PLIST" 2>/dev/null
    fi
    if [ "$WANT_VNC" = 1 ]; then
        launchctl load "$VNC_PLIST" 2>/dev/null
    fi
    if [ "$WANT_TERMINAL" = 1 ]; then
        sleep 2
        launchctl load "$TERM_PLIST" 2>/dev/null
    fi
    if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_VNC" = 1 ] &&
       [ "$WANT_TERMINAL" = 1 ]; then
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
    fi
    log "watchdog: GUI clients reconnected after WS $old_pid -> $RECOVERED_WS_PID (vnc=$WANT_VNC terminal=$WANT_TERMINAL)"
    return 0
}

trip_watchdog() {
    local reason="$1"
    echo "$reason" > "$WD_TRIP"
    log "watchdog: SAFETY TRIP: $reason"
    stop_all
}

# Watchdog loop (runs iOS-side, backgrounded by `start`). Stops the GUI if
# WindowServer crash-loops or the load average runs away.
run_watchdog() {
    local last_pid="" restarts=0 t0 started now pid L load_runaway
    local ws_cpu=0 cpu_strikes=0 diagnostic=0 missing_samples=0
    t0=$(date +%s)
    started=$t0
    [ -e "$EXPERIMENTAL_COMPLETION" ] && diagnostic=1
    log "watchdog: armed (load>=$WD_LOAD_LIMIT after ${WD_LOAD_GRACE}s grace; WS CPU>=${WD_WS_CPU_LIMIT}% for $((WD_WS_CPU_STRIKES * WD_POLL))s; >=$WD_RESTART_LIMIT restarts/${WD_WINDOW}s; diagnostic cap=${WD_DIAG_MAX_RUNTIME}s)"
    while :; do
        sleep "$WD_POLL"
        # Exit only when the GUI was actually torn down (the WindowServer launchd
        # job is unloaded). A momentarily-absent PROCESS just means launchd is
        # relaunching it after a crash — keep guarding (and count it as a restart).
        if ! launchctl list com.apple.WindowServer >/dev/null 2>&1; then
            log "watchdog: WindowServer job unloaded (GUI stopped) — exiting."
            return 0
        fi
        pid=$(ws_pid)
        if [ -z "$pid" ] || [ "$pid" = "-" ]; then
            missing_samples=$((missing_samples + 1))
            if [ "$missing_samples" -eq 1 ] || [ "$missing_samples" -eq 3 ]; then
                log "watchdog: WindowServer job is loaded but has no PID; requesting launchd start (sample=$missing_samples)"
                launchctl start com.apple.WindowServer 2>/dev/null
            fi
            if [ "$missing_samples" -ge 4 ]; then
                trip_watchdog "WindowServer 连续 $((missing_samples * WD_POLL)) 秒没有进程，已自动停止 macOS GUI"
                return 0
            fi
        else
            missing_samples=0
        fi
        if [ -n "$pid" ] && [ "$pid" != "-" ] && [ -n "$last_pid" ] && [ "$pid" != "$last_pid" ]; then
            restarts=$((restarts + 1))
            log "watchdog: WindowServer restarted ($last_pid -> $pid), count=$restarts in window"
            if ! recover_ws_dependents "$last_pid" "$pid"; then
                trip_watchdog "WindowServer 重启后未能建立稳定会话，已自动停止 macOS GUI"
                return 0
            fi
            restarts=$((restarts + RECOVERY_EXTRA_RESTARTS))
            pid="$RECOVERED_WS_PID"
        fi
        [ -n "$pid" ] && [ "$pid" != "-" ] && last_pid="$pid"
        now=$(date +%s)
        if [ $((now - t0)) -ge "$WD_WINDOW" ]; then restarts=0; t0=$now; fi
        L=$(load1_int); [ -z "$L" ] && L=0
        load_runaway=0
        if [ $((now - started)) -ge "$WD_LOAD_GRACE" ] && [ "$L" -ge "$WD_LOAD_LIMIT" ]; then
            load_runaway=1
        fi

        ws_cpu=0
        if [ -n "$pid" ] && [ "$pid" != "-" ]; then
            ws_cpu=$(ws_cpu_int "$pid"); [ -z "$ws_cpu" ] && ws_cpu=0
        fi
        if [ "$ws_cpu" -ge "$WD_WS_CPU_LIMIT" ]; then
            cpu_strikes=$((cpu_strikes + 1))
        elif [ "$cpu_strikes" -gt 0 ]; then
            # One scheduler dip must not erase the preceding 25 seconds of
            # 80-95% CPU. Decay one sample at a time (a small leaky bucket).
            cpu_strikes=$((cpu_strikes - 1))
        fi

        if [ "$load_runaway" -eq 1 ]; then
            trip_watchdog "系统负载达到 $L，已自动停止 macOS GUI"
            return 0
        fi
        if [ "$restarts" -ge "$WD_RESTART_LIMIT" ]; then
            trip_watchdog "WindowServer 在 ${WD_WINDOW} 秒内重启 ${restarts} 次，已自动停止"
            return 0
        fi
        if [ "$cpu_strikes" -ge "$WD_WS_CPU_STRIKES" ]; then
            trip_watchdog "WindowServer 高 CPU 样本累计达到 $((WD_WS_CPU_STRIKES * WD_POLL)) 秒（阈值 ${WD_WS_CPU_LIMIT}%，当前 ${ws_cpu}%），已自动停止以防过热"
            return 0
        fi
        if [ "$diagnostic" -eq 1 ] && [ $((now - started)) -ge "$WD_DIAG_MAX_RUNTIME" ]; then
            trip_watchdog "实验兼容模式达到 ${WD_DIAG_MAX_RUNTIME} 秒安全上限，已自动停止；这仍是诊断脚手架"
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
    <!--
      Terminal is a CoreAnimation client as well as an AppKit application.
      Runtime A/B on 2026-07-28: with the same producer-owned scanout and the
      same paced RFB input, the client advanced through nearly the entire
      command with CA_VSYNC_OFF=1; without it, the completed WindowServer
      surface stopped changing after the first character.  The chroot has no
      working display-vblank handoff, so client commits must not wait for it.
    -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>CA_VSYNC_OFF</key>
        <string>1</string>
        <!--
          Terminal's fast pty output can race its one delayed AppKit redraw in
          this virtual-display session.  This narrowly enables libmachook's
          debounced responder invalidation for Terminal only.  It is a bounded
          usability scaffold, not a substitute for a real display clock. A
          device A/B showed 120ms firing after the text model was complete but
          before TTView's pixels stabilized (VNC stopped at "echo dyna");
          750ms produced the command, output, and new prompt with no later
          input event.
        -->
        <key>MACWS_APP_DISPLAY_SETTLE_MS</key>
        <string>750</string>
    </dict>
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

    # inputd blocks in recv(2), so tear its job down explicitly before the
    # broader directory unload and verify no pre-fix binary remains alive.
    launchctl unload "$INPUT_PLIST" 2>/dev/null
    launchctl remove "$INPUT_LABEL" 2>/dev/null

    # VS Code is launched separately from this script, but it is still a CGS
    # client of this WindowServer.  Runtime-confirmed after the 300-second
    # safety stop: the GUI jobs were gone while Electron and several Code
    # Helper processes retained hundreds of MiB and a dead WS connection.
    # Unload the exact optional job whenever its owning GUI stack is torn down.
    launchctl unload "$VSCODE_PLIST" 2>/dev/null
    launchctl remove "$VSCODE_LABEL" 2>/dev/null

    # 2) stray GUI clients (Terminal, VNC, Activity Monitor, ...)
    kill_by_pattern "$P_OSXVNC"
    kill_by_pattern "$P_TERMINAL"
    kill_by_pattern "$P_ACTIVITYMON"
    kill_by_pattern "$P_GLASSDEMO"
    kill_by_pattern "$P_FINDER"
    kill_by_pattern "$P_INPUTD"
    kill_by_pattern "$P_VSCODE"
    rm -f "$ROOTFS"/private/tmp/macws_app_input.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_input_target.sock

    # 3) the WindowServer + launchservicesd daemons
    launchctl unload "$MACOS_DAEMONS" 2>/dev/null

    # 4) anything still lingering
    kill_by_pattern "$P_WINDOWSERVER"
    kill_by_pattern "$P_LAUNCHSERVICESD"

    # The mmap is a producer-owned WindowServer artifact, not persistent
    # session state.  Keeping it after the producer exits lets a fresh OSXvnc
    # process advertise pixels from an earlier application even when the new
    # WindowServer has not published a frame.  Remove it only after every old
    # producer/client has been stopped so no live mapping is invalidated.
    rm -f "$VNC_SHARED_FRAME" "$VNC_SHARED_SURFID" "$VNC_ACTIVITY" \
        "$EXPERIMENTAL_CAPTURE" "$EXPERIMENTAL_CAPTURE_DONE" \
        "$EXPERIMENTAL_OWNED_SCANOUT"

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
    local ws_log_start_line=1 waited=0
    if [ -f "$LOGDIR/WindowServer.err" ]; then
        ws_log_start_line=$(( $(wc -l < "$LOGDIR/WindowServer.err") + 1 ))
    fi
    log "Loading macOS WindowServer + launchservicesd..."
    launchctl load "$MACOS_DAEMONS"
    log "Waiting for WindowServer graphics initialization before GUI clients..."
    wait_for_initial_ws_ready "$ws_log_start_line" || return 1

    if [ "$WANT_VNC" = 1 ]; then
        log "Starting VNC server (launchd job '$VNC_LABEL', persistent)..."
        rm -f "$LOGDIR/osxvnc.log"
        launchctl load "$VNC_PLIST"
        waited=0
        while ! proc_running "$P_OSXVNC" && [ "$waited" -lt 10 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        proc_running "$P_OSXVNC" || {
            log "ERROR: VNC process did not start."
            return 1
        }
        sleep 2
        started_ws_unchanged "VNC startup" || return 1
    fi

    if [ "$WANT_TERMINAL" = 1 ]; then
        log "Starting Terminal (launchd job '$TERM_LABEL')..."
        rm -f "$LOGDIR/terminal.log"
        launchctl load "$TERM_PLIST"
        sleep 5
        started_ws_unchanged "Terminal startup" || return 1
    fi
}

stop_all() {
    cleanup_macos
    rm -f "$FLAG"
    # A watchdog stop does not pass back through macwshostd, so it must clear
    # the diagnostic sentinels itself.  Otherwise the next ordinary CLI start
    # silently inherits experimental protocol behavior.
    rm -f "$EXPERIMENTAL_KCMD" "$EXPERIMENTAL_COMPLETION" \
        "$EXPERIMENTAL_WRAPPED_KCMD" "$EXPERIMENTAL_COMMAND_ERROR" \
        "$EXPERIMENTAL_VNC_SHARE" "$EXPERIMENTAL_OBSERVE_PF550" \
        "$EXPERIMENTAL_SUBMIT_RING" "$EXPERIMENTAL_OWNED_SCANOUT" \
        "$EXPERIMENTAL_CAPTURE" \
        "$EXPERIMENTAL_CAPTURE_DONE" "$EXPERIMENTAL_PACE"
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
  sudo bash $0 start [coexist|exclusive] [--experimental] [--pace-us=N] [--no-terminal] [--no-vnc] [--no-watchdog]
  sudo bash $0 stop
  sudo bash $0 restart [coexist|exclusive] [...]
  sudo bash $0 status

Modes:
  coexist     (default) iPad panel keeps showing iOS; macOS renders to VNC only.
  exclusive   macOS takes over the physical panel as well as VNC.

Safety: `start` also launches a background watchdog that auto-stops the GUI if
WindowServer crash-loops or the load average runs away (panic guard). Disable
with --no-watchdog. Logs to $LOGDIR/macos_gui_watchdog.log.

The current native VNC path still needs diagnostic command/completion adapters.
Use --experimental explicitly for that path; it is bounded to
${WD_DIAG_MAX_RUNTIME} seconds and remains protected by the high-CPU watchdog.

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
WANT_EXPERIMENTAL=0
COEXIST_PACE_US=""
for a in "$@"; do
    case "$a" in
        coexist|coexistence|co)  MODE=coexist ;;
        exclusive|full|excl)     MODE=exclusive ;;
        --experimental)          WANT_EXPERIMENTAL=1 ;;
        --pace-us=*)             COEXIST_PACE_US="${a#--pace-us=}" ;;
        --no-terminal)           WANT_TERMINAL=0 ;;
        --no-vnc)                WANT_VNC=0 ;;
        --no-watchdog)           WANT_WATCHDOG=0 ;;
        *) echo "macos_gui.sh: ignoring unknown option '$a'" >&2 ;;
    esac
done

# The stable interactive A/B uses a 100 ms idle completion interval and lets
# VNC activity temporarily select 16.667 ms for one second.  Make that tested
# pair the experimental default so the one-click command does not silently
# fall back to the hot, fixed 60 Hz scaffold. An explicit --pace-us still
# selects a different idle value.
if [ "$WANT_EXPERIMENTAL" = 1 ] && [ -z "$COEXIST_PACE_US" ]; then
    COEXIST_PACE_US=100000
fi

if [ -n "$COEXIST_PACE_US" ]; then
    if [ "$WANT_EXPERIMENTAL" != 1 ]; then
        echo "macos_gui.sh: --pace-us requires --experimental" >&2
        exit 1
    fi
    case "$COEXIST_PACE_US" in
        *[!0-9]*|'')
            echo "macos_gui.sh: --pace-us must be an integer from 8333 to 100000" >&2
            exit 1
            ;;
    esac
    if [ "$COEXIST_PACE_US" -lt 8333 ] || [ "$COEXIST_PACE_US" -gt 100000 ]; then
        echo "macos_gui.sh: --pace-us must be from 8333 to 100000" >&2
        exit 1
    fi
fi

enable_experimental_if_requested() {
    [ "$WANT_EXPERIMENTAL" = 1 ] || return 0
    touch "$EXPERIMENTAL_KCMD" "$EXPERIMENTAL_COMPLETION" \
        "$EXPERIMENTAL_VNC_SHARE" "$EXPERIMENTAL_OBSERVE_PF550" \
        "$EXPERIMENTAL_SUBMIT_RING" "$EXPERIMENTAL_OWNED_SCANOUT"
    rm -f "$EXPERIMENTAL_PACE"
    if [ -n "$COEXIST_PACE_US" ]; then
        echo "$COEXIST_PACE_US" > "$EXPERIMENTAL_PACE"
    fi
    log "DIAGNOSTIC-SCAFFOLD: command ABI + cancelled-swap completion + read-only PF550 completion observer + bounded submit flight recorder + owned BGRA scanout + stable VNC mmap enabled."
    if [ -n "$COEXIST_PACE_US" ]; then
        log "DIAGNOSTIC-SCAFFOLD: synthetic completion pace=${COEXIST_PACE_US} us (not a refresh-rate implementation)."
    fi
}

arm_initial_vnc_capture_if_requested() {
    [ "$WANT_EXPERIMENTAL" = 1 ] || return 0
    [ "$WANT_VNC" = 1 ] || return 0
    # A WindowServer-only diagnostic start deliberately has no app content to
    # capture.  Besides being misleading, arming here consumes the one-shot on
    # an empty desktop before a debugger can launch the test application.
    [ "$WANT_TERMINAL" = 1 ] || return 0
    # The initial completed PF80 surface is runtime-confirmed to contain only
    # alpha on some starts.  Request a bounded PF550 read after Terminal has
    # launched so a newly connected VNC client receives a real first frame
    # without needing a blind pointer movement.  WindowServer consumes this
    # generation once and writes macws_capture_done only after a validated,
    # spatially non-uniform frame has been published.
    sleep 1
    rm -f "$EXPERIMENTAL_CAPTURE_DONE"
    ARMED_CAPTURE_GENERATION=$(date +%s)
    echo "$ARMED_CAPTURE_GENERATION" > "$EXPERIMENTAL_CAPTURE"
    log "VNC: requested post-Terminal shared frame generation $ARMED_CAPTURE_GENERATION."
}

wait_for_initial_vnc_capture_if_requested() {
    [ -n "$ARMED_CAPTURE_GENERATION" ] || return 0

    # OSXvnc allocates its cached framebuffer before Terminal has necessarily
    # produced the first usable scanout. Runtime evidence on 2026-07-26 showed
    # an early client receiving a 2388x1668 all-zero update while WindowServer
    # acknowledged the validated, non-uniform mmap a few seconds later. Do not
    # advertise the session as ready until that exact generation is published.
    # A newly connecting client then asks OSXvnc for a full rectangle and the
    # existing mmap hook copies the completed frame into its ordinary buffer.
    local waited=0 ack_generation="" ack_pid=""
    log "VNC: waiting up to ${CAPTURE_READY_WAIT}s for a validated Retina first frame..."
    while [ "$waited" -lt "$CAPTURE_READY_WAIT" ]; do
        if [ -f "$EXPERIMENTAL_CAPTURE_DONE" ]; then
            ack_pid=$(awk 'NR == 1 { print $1 }' "$EXPERIMENTAL_CAPTURE_DONE" 2>/dev/null)
            ack_generation=$(awk 'NR == 1 { print $2 }' "$EXPERIMENTAL_CAPTURE_DONE" 2>/dev/null)
            if [ "$ack_generation" = "$ARMED_CAPTURE_GENERATION" ]; then
                log "VNC: Retina first frame ready (WindowServer pid=$ack_pid, generation=$ack_generation)."
                ARMED_CAPTURE_GENERATION=""
                return 0
            fi
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log "WARNING: no validated VNC first frame after ${CAPTURE_READY_WAIT}s; VNC remains available for diagnostics."
    log "         Inspect $LOGDIR/WindowServer.err for 'VNC-FINAL generation=$ARMED_CAPTURE_GENERATION'."
    ARMED_CAPTURE_GENERATION=""
    return 0
}

# Launch the crash-loop watchdog in the background (iOS-side, survives SSH
# disconnect via nohup). Re-invokes this script in `watchdog` mode.
start_watchdog() {
    [ "$WANT_WATCHDOG" = 1 ] || { log "watchdog: disabled (--no-watchdog)"; return 0; }
    rm -f "$WD_LOG"
    rm -f "$WD_TRIP"
    # Re-exec with the exact session intent.  The recovery path needs these
    # flags so a WS restart does not unexpectedly launch a VNC/Terminal job the
    # user disabled, and so it knows whether to request a fresh shared frame.
    set -- watchdog "$MODE"
    [ "$WANT_VNC" = 1 ] || set -- "$@" --no-vnc
    [ "$WANT_TERMINAL" = 1 ] || set -- "$@" --no-terminal
    [ "$WANT_EXPERIMENTAL" = 1 ] && set -- "$@" --experimental
    [ -n "$COEXIST_PACE_US" ] && set -- "$@" "--pace-us=$COEXIST_PACE_US"
    nohup bash "$0" "$@" > "$WD_LOG" 2>&1 < /dev/null &
    log "watchdog: started in background (log: $WD_LOG; vnc=$WANT_VNC terminal=$WANT_TERMINAL experimental=$WANT_EXPERIMENTAL)"
}

case "$CMD" in
    start)
        require_root "$@"
        write_plists
        ensure_chroot_works || exit 1
        cleanup_macos
        enable_experimental_if_requested
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        start_macos || { stop_all; exit 1; }
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
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
        enable_experimental_if_requested
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        start_macos || { stop_all; exit 1; }
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
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
