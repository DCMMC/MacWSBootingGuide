# macos_gui.sh — start / stop the chroot macOS GUI stack (WindowServer + VNC +
# Terminal) on the iOS side, with a choice of display mode and full cleanup of
# any previously-running macOS services.
#
# Run as root from the iOS shell (NOT inside the chroot):
#
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production        # one-click production profile
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start coexist     # same production defaults, explicit command
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start exclusive   # macOS takes the physical panel + VNC
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh stop              # tear everything down, return to iOS
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh restart coexist   # stop, then start in the given mode
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh status            # show what is running
#
# Options for start/restart:
#   coexist | exclusive   display mode (default: coexist)
#   --experimental        compatibility alias; native-AGX path is now the default
#   --no-experimental     explicit control run without the native-AGX VNC adapters
#   --diagnostics         also enable high-overhead AGX flight recorders/traces
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
WINDOWSERVER_PLIST="$MACOS_DAEMONS/com.apple.WindowServer.plist"
CHROOTEXEC=/var/jb/usr/macOS/bin/launchdchrootexec
RUN_BASH=/var/jb/usr/macOS/bin/run_bash.sh
POSTINST=/var/jb/usr/macOS/bin/postinst.sh
LOGDIR=/var/jb/var/mobile
TEST_LEASE="$LOGDIR/macws_test_lease"

GUI_LAUNCHD_DIR=/var/jb/usr/macOS/gui-launchd   # script-owned; NOT auto-scanned at boot
VNC_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.osxvnc.plist"
TERM_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.terminal.plist"
PBOARD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.pboard.plist"
PBS_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.pbs.plist"
INPUT_PLIST="$MACOS_DAEMONS/com.macwsguide.input.plist"
VNC_LABEL=com.macwsguide.osxvnc
TERM_LABEL=com.macwsguide.terminal
PBOARD_LABEL=com.macwsguide.pboard
PBS_LABEL=com.macwsguide.pbs
INPUT_LABEL=com.macwsguide.input
VSCODE_PLIST=/var/jb/Library/LaunchDaemons/com.macwsguide.vscode.plist
VSCODE_LABEL=com.macwsguide.vscode
CHROME150_PLIST=/var/jb/Library/LaunchDaemons/com.macwsguide.chrome150.plist
CHROME150_LABEL=com.macwsguide.chrome150
EXPERIMENTAL_KCMD="$ROOTFS/private/tmp/macws_kcmd_fix"
EXPERIMENTAL_WRAPPED_KCMD="$ROOTFS/private/tmp/macws_kcmd_wrapped_fix"
EXPERIMENTAL_COMMAND_ERROR="$ROOTFS/private/tmp/macws_command_error_diag"
EXPERIMENTAL_COMPLETION="$ROOTFS/private/tmp/macws_cancel_completion"
EXPERIMENTAL_VNC_SHARE="$ROOTFS/private/tmp/macws_vnc_share"
EXPERIMENTAL_OBSERVE_PF550="$ROOTFS/private/tmp/macws_observe_pf550"
EXPERIMENTAL_SUBMIT_RING="$ROOTFS/private/tmp/macws_submit_ring"
EXPERIMENTAL_FAST_SUBMIT_RING="$ROOTFS/private/tmp/macws_submit_fast_ring"
EXPERIMENTAL_RUNTIME_DIAGNOSTICS="$ROOTFS/private/tmp/macws_runtime_diagnostics"
EXPERIMENTAL_QUEUE_QOS="$ROOTFS/private/tmp/macws_queue_qos_diag"
EXPERIMENTAL_OWNED_SCANOUT="$ROOTFS/private/tmp/macws_owned_scanout"
EXPERIMENTAL_PACE="$ROOTFS/private/tmp/macws_coexist_pace_us"
EXPERIMENTAL_CAPTURE="$ROOTFS/private/tmp/macws_capture_final"
EXPERIMENTAL_CAPTURE_DONE="$ROOTFS/private/tmp/macws_capture_done"
VNC_SHARED_FRAME="$ROOTFS/private/tmp/macws_vnc_fb"
VNC_SHARED_SURFID="$ROOTFS/private/tmp/macws_vnc_surfid"
VNC_ACTIVITY="$ROOTFS/private/tmp/macws_vnc_activity"
GRAPHICS_READY="$ROOTFS/private/tmp/macws_graphics_ready"
ARMED_CAPTURE_GENERATION=""
CAPTURE_READY_WAIT=60
WINDOWSERVER_READY_WAIT=45
STARTED_WS_PID=""

VNC_BIN=/usr/local/bin/OSXvnc-server                                              # chroot path
TERM_BIN="/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"   # chroot path
PBOARD_BIN=/usr/libexec/pboard
PBS_BIN=/System/Library/CoreServices/pbs
VNC_DESKTOP=macOS-iPad

SPRINGBOARD=/System/Library/LaunchDaemons/com.apple.SpringBoard.plist
BACKBOARDD=/System/Library/LaunchDaemons/com.apple.backboardd.plist

# Process-match patterns (full paths; unique to the chroot macOS processes so we
# never hit an iOS process by accident — iOS has no WindowServer/launchservicesd).
P_WINDOWSERVER='SkyLight.framework/Resources/WindowServer'
P_LAUNCHSERVICESD='CoreServices/launchservicesd'
P_OSXVNC='OSXvnc-server'
P_TERMINAL='Utilities/Terminal.app/Contents/MacOS/Terminal'
P_PBOARD='/usr/libexec/pboard'
P_PBS='/System/Library/CoreServices/pbs'
P_ACTIVITYMON='Activity Monitor.app/Contents/MacOS/Activity Monitor'
P_GLASSDEMO='/tmp/GlassDemo'
P_FINDER='CoreServices/Finder.app/Contents/MacOS/Finder'
P_INPUTD='/usr/local/bin/macwsinputd'
P_VSCODE='Visual Studio Code.app/Contents/'
P_CHROME150='Google Chrome.app/Contents/'

# Opt-in invocation audit for tracking an unexpected second start/stop without
# leaving permanent command logging in normal use.  The 2026-07-29 controlled
# browser run had its 16,667-us sentinel overwritten to 100,000 us by another
# invocation; process uptime alone could not identify its already-exited
# parent.  Touch $LOGDIR/macws_trace_gui_invocations before a diagnostic run.
if [ -f "$LOGDIR/macws_trace_gui_invocations" ]; then
    {
        printf '%s pid=%s ppid=%s uid=%s args=' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$PPID" "$(id -u)"
        printf '%q ' "$@"
        printf ' parent='
        ps -o command= -p "$PPID" 2>/dev/null || true
        printf '\n'
    } >> "$LOGDIR/macos_gui_invocations.log" 2>&1
fi

# A controlled performance run can hold an explicit lease so a stale SSH
# script cannot silently tear down its WindowServer and replace the pacing or
# client set mid-sample.  Runtime-confirmed 2026-07-29: an unrelated deferred
# `ssh ... bash -s` invoked `start coexist --no-terminal --no-watchdog` during
# a VS Code cold-start regression; the invocation audit captured the exact
# command and parent after it replaced the measured WindowServer PID.  Normal
# interactive use is unchanged because the lease file is absent.  Test owners
# create the file and pass the same token through sudo:
#
#   sudo env MACWS_TEST_LEASE_TOKEN=<token> bash macos_gui.sh start ...
#
# `status` remains read-only and is always allowed.
case "${1:-}" in
    start|restart|stop)
        if [ -f "$TEST_LEASE" ]; then
            expected_lease=$(awk 'NR == 1 { print; exit }' "$TEST_LEASE" 2>/dev/null)
            provided_lease="${MACWS_TEST_LEASE_TOKEN:-}"
            if [ -z "$expected_lease" ] || [ "$provided_lease" != "$expected_lease" ]; then
                log_line="REFUSED: active test lease blocks '$1' (pid=$$ ppid=$PPID)"
                echo "[macos_gui] $log_line" >&2
                echo "$(date '+%Y-%m-%d %H:%M:%S') $log_line" \
                    >> "$LOGDIR/macos_gui_invocations.log" 2>&1
                exit 75
            fi
        fi
        ;;
esac

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
# Interactive VNC sessions must not disappear at an arbitrary test deadline.
# The old unconditional 300-second limit runtime-confirmed the user's abrupt
# shutdown: the watchdog logged the cap trip while VS Code logged SIGTERM.
# Crash-loop/load/sustained-CPU guards remain armed. Bounded automation can
# opt back into a wall-clock limit with --runtime-cap=SECONDS.
WD_MAX_RUNTIME=0
WD_LOG="$LOGDIR/macos_gui_watchdog.log"
WD_TRIP="$LOGDIR/macws_safety_trip"
WD_PIDFILE="$LOGDIR/macos_gui_watchdog.pid"
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
# CGS session. In experimental mode, the first clean producer completion writes
# a one-shot PID witness; production readiness must not depend on diagnostic
# stderr traffic. Otherwise require a stable PID for eight consecutive samples.
wait_for_initial_ws_ready() {
    local log_start_line="$1" current="" previous="" stable=0 waited=0 ready_pid=""
    : "$log_start_line"
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

        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_VNC" = 1 ]; then
            ready_pid=$(awk 'NR == 1 { print; exit }' "$GRAPHICS_READY" \
                2>/dev/null)
            if [ "$stable" -ge 2 ] && [ "$ready_pid" = "$current" ]; then
                STARTED_WS_PID="$current"
                log "WindowServer graphics ready (pid=$current, clean producer observed)."
                return 0
            fi
        elif [ "$stable" -ge 8 ]; then
            # A --no-vnc run intentionally has no VNC completion observer, so
            # it cannot emit the VNC-FLOW readiness witness above.  Only call
            # this process readiness; the subsequent CDP/WebGL test supplies
            # the actual graphics witness for headless measurements.
            STARTED_WS_PID="$current"
            log "WindowServer process ready (pid=$current, stable for ${stable}s; graphics not yet witnessed)."
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
    launchctl unload "$CHROME150_PLIST" 2>/dev/null
    launchctl remove "$CHROME150_LABEL" 2>/dev/null
    # A root SSH shell on this jailbreak can still submit `launchctl load`
    # into mobile's user/501 domain.  A system-domain unload then reports
    # success/no-op while the browser job survives and contaminates the next
    # supposedly clean benchmark.  Runtime-confirmed 2026-07-29 via
    # `launchctl print user/501/com.macwsguide.chrome150`.  Remove both
    # disposable browser jobs in that actual domain as well.
    launchctl asuser 501 launchctl unload "$VSCODE_PLIST" 2>/dev/null
    launchctl asuser 501 launchctl remove "$VSCODE_LABEL" 2>/dev/null
    launchctl asuser 501 launchctl unload "$CHROME150_PLIST" 2>/dev/null
    launchctl asuser 501 launchctl remove "$CHROME150_LABEL" 2>/dev/null

    kill_by_pattern "$P_OSXVNC"
    kill_by_pattern "$P_TERMINAL"
    kill_by_pattern "$P_ACTIVITYMON"
    kill_by_pattern "$P_GLASSDEMO"
    kill_by_pattern "$P_FINDER"
    kill_by_pattern "$P_INPUTD"
    kill_by_pattern "$P_VSCODE"
    kill_by_pattern "$P_CHROME150"
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

watchdog_pidfile_cleanup() {
    local owner=""
    [ -f "$WD_PIDFILE" ] || return 0
    owner=$(awk 'NR == 1 { print $1 }' "$WD_PIDFILE" 2>/dev/null)
    [ "$owner" = "$$" ] && rm -f "$WD_PIDFILE"
    return 0
}

# Watchdog loop (runs iOS-side, backgrounded by `start`). Stops the GUI if
# WindowServer crash-loops or the load average runs away.
run_watchdog() {
    local last_pid="" restarts=0 t0 started now pid L load_runaway
    local ws_cpu=0 cpu_strikes=0 missing_samples=0
    local runtime_cap_label="disabled"
    # The parent records $! as soon as it forks us, and the child records $$
    # again here after exec.  The ownership-aware EXIT trap cannot erase a
    # replacement watchdog's pidfile if launch timing overlaps.
    echo "$$" > "$WD_PIDFILE"
    trap watchdog_pidfile_cleanup EXIT
    t0=$(date +%s)
    started=$t0
    [ "$WD_MAX_RUNTIME" -gt 0 ] &&
        runtime_cap_label="${WD_MAX_RUNTIME}s"
    log "watchdog: armed (load>=$WD_LOAD_LIMIT after ${WD_LOAD_GRACE}s grace; WS CPU>=${WD_WS_CPU_LIMIT}% for $((WD_WS_CPU_STRIKES * WD_POLL))s; >=$WD_RESTART_LIMIT restarts/${WD_WINDOW}s; runtime cap=$runtime_cap_label)"
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
        if [ "$WD_MAX_RUNTIME" -gt 0 ] &&
           [ $((now - started)) -ge "$WD_MAX_RUNTIME" ]; then
            trip_watchdog "自动化运行达到 ${WD_MAX_RUNTIME} 秒显式上限，已自动停止"
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
        <!--
          The installed OSXvnc-server defaults rfbDeferUpdateTime to 40 ms.
          RE-confirmed at arm64 clientOutput+0xec: it unlocks the client mutex,
          sleeps defer*1000, then relocks before intersecting damage and
          calling rfbSendFramebufferUpdate. The shared-frame producer and
          generation watcher already coalesce at a bounded frame cadence, so
          this second fixed delay only lengthens menu/drag feedback and holds
          the single clientOutput stream behind later damage.
        -->
        <string>-deferupdate</string>
        <string>0</string>
        <string>-desktop</string>
        <string>${VNC_DESKTOP}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <!--
          System-wide pointer ownership belongs to OSXvnc's native
          CGPostMouseEvent path. Runtime tests cover AppKit's global menu,
          contextual menu, NSWindow modal drag tracker, and application
          content through this one coherent stream. libmachook only fixes the
          Retina RFB-pixel -> Quartz-point scale before calling the original.
          AppInputBridge remains a fallback for non-VNC/native-host input; it
          must not duplicate an active VNC gesture in one target process.
        -->
        <key>MACWS_VNC_NATIVE_ALL</key>
        <string>1</string>
        <!--
          The Retina desktop is 15.2 MiB uncompressed. Runtime timing at the
          actual rfbSendFramebufferUpdate boundary showed a moved-window Zlib
          frame spending 1584 ms in encoding/socket output while mmap copy
          used 1.87 ms. Controlled Tight full-frame requests on this device
          made compression level 1 the lowest-latency measured setting
          (343 ms versus 544 ms at level 6 and 1184 ms at level 9). libmachook
          preserves the client-selected encoding but clamps its compression
          work factor to level 1 before the stream is initialized.
        -->
        <key>MACWS_VNC_LOW_LATENCY_COMPRESSION</key>
        <string>1</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOGDIR}/osxvnc.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGDIR}/osxvnc.log</string>
</dict>
</plist>
PLIST

    # The chroot has no ordinary macOS loginwindow/LaunchAgent bootstrap, so
    # com.apple.pboard is otherwise absent. Runtime evidence was explicit:
    # OSXvnc logged "Pasteboard Inaccessible" and Electron aborted a drag with
    # "0 items on the pasteboard, but 1 drag images". Register the real macOS
    # pboard binary through the same chroot launcher and expose its original
    # Mach service names in the outer launchd domain.
    cat > "$PBOARD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PBOARD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${PBOARD_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.pasteboard.1</key>
        <true/>
        <key>com.apple.coreservices.uauseractivitypasteboardclient.xpc</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${LOGDIR}/pboard.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGDIR}/pboard.log</string>
</dict>
</plist>
PLIST

    # AppKit does not build the Services submenu in-process. Runtime evidence
    # on 2026-07-29 showed Terminal requesting
    # com.apple.pbs.fetch_services twice while launchctl had no provider; the
    # visible submenu remained at "Building...". The actual macOS 13.4
    # com.apple.pbs LaunchAgent maps that Mach service to
    # /System/Library/CoreServices/pbs. Recreate that service in the outer
    # launchd domain and execute the real binary in the chroot.
    cat > "$PBS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PBS_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${PBS_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.pbs.fetch_services</key>
        <true/>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>NSRunningFromLaunchd</key>
        <string>1</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOGDIR}/pbs.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGDIR}/pbs.log</string>
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
stop_watchdogs() {
    local watchdog_pid="" candidate=""
    if [ -f "$WD_PIDFILE" ]; then
        watchdog_pid=$(awk 'NR == 1 { print $1 }' "$WD_PIDFILE" 2>/dev/null)
        case "$watchdog_pid" in
            ''|*[!0-9]*) ;;
            *)
                [ "$watchdog_pid" = "$$" ] || kill "$watchdog_pid" 2>/dev/null
                ;;
        esac
    fi
    # Migration cleanup for watchdogs started by versions that had no pidfile.
    # Runtime evidence on 2026-07-29 found two simultaneous loops; the older
    # one reloaded VNC/Terminal during a manual restart and launchctl reported
    # both jobs "service already loaded". Match the complete script+subcommand
    # rather than a broad process name.
    for candidate in $(ps -ax -o pid=,command= 2>/dev/null | awk \
        -v needle="bash $0 watchdog " 'index($0, needle) { print $1 }'); do
        [ "$candidate" = "$$" ] || kill "$candidate" 2>/dev/null
    done
    rm -f "$WD_PIDFILE"
}

# Every sentinel below changes code paths, installs tracing, records submit
# payloads, or performs an unsafe A/B readback.  Production startup removes the
# complete list before it creates the small set of required functional flags.
# Keep this list in sync with docs/runtime-switches.tsv; the host-side
# misc/audit_runtime_switches.py check fails when a newly-added source sentinel
# is not recorded there.
diagnostic_flag_paths() {
    printf '%s\n' \
        /private/tmp/macws_agx_dump_methods \
        /private/tmp/macws_agx_trace_reserve \
        /private/tmp/macws_mtl_library_diag \
        /private/tmp/macws_tile_descriptor_diag \
        /tmp/macws_allow_unsafe_pf550_capture \
        /tmp/macws_command_error_diag \
        /tmp/macws_cvdl_trace \
        /tmp/macws_disp_copy \
        /tmp/macws_disp_dump \
        /tmp/macws_disp_fill \
        /tmp/macws_dump_rejected_vnc \
        /tmp/macws_inband_pf550 \
        /tmp/macws_inspect_failed_pf550 \
        /tmp/macws_iogpu_error_diag \
        /tmp/macws_kcmd_field_5e3_diag \
        /tmp/macws_kcmd_field_6bc_diag \
        /tmp/macws_kcmd_field_a4_diag \
        /tmp/macws_observe_pf550 \
        /tmp/macws_owned_no_read \
        /tmp/macws_owned_unlocked_read \
        /tmp/macws_pf550_metadata_diag \
        /tmp/macws_probe_small_pf550 \
        /tmp/macws_queue_qos_diag \
        /tmp/macws_real_swapend \
        /tmp/macws_res_diag \
        /tmp/macws_runtime_diagnostics \
        /tmp/macws_stop_after_clear \
        /tmp/macws_submit_diag \
        /tmp/macws_submit_fast_ring \
        /tmp/macws_submit_ring \
        /tmp/macws_trace_small_pf550_bind \
        /tmp/macws_vnc_native_all \
        /tmp/macws_vnc_test
}

clear_diagnostic_state() {
    local path
    diagnostic_flag_paths | while IFS= read -r path; do
        rm -f "$ROOTFS$path"
    done

    # Bounded dump directories are historical evidence, not session state.
    # Match only exact MacWS prefixes one directory below the chroot tmp root.
    find "$ROOTFS/private/tmp" -maxdepth 1 -type d \
        \( -name 'macws_fast_submit_error_[0-9]*_[0-9]*' \
        -o -name 'macws_submit_error_[0-9]*_[0-9]*' \) \
        -exec rm -rf {} \; 2>/dev/null
    find "$ROOTFS/private/tmp" -maxdepth 1 -type f \
        \( -name 'macws_submit_*.bin' \
        -o -name 'macws_submit_kcmd_*.bin' \
        -o -name 'macws_submit_segment_*.bin' \
        -o -name 'macws_submit_type1_*.bin' \
        -o -name 'macws_pf550_small_probe.bgra' \
        -o -name 'macws_vnc_rejected.bgra' \
        -o -name 'macws_back115.raw' \
        -o -name 'macws_backdense.raw' \
        -o -name 'macws_agx_runtime_methods.log' \
        -o -name 'macws_disp.log' \) \
        -exec rm -f {} \; 2>/dev/null
}

production_preflight() {
    local path plist key bad=0
    clear_diagnostic_state

    # No production launch job may enable allocator/debug flight recorders via
    # environment.  Functional compatibility variables are documented and
    # intentionally excluded from this deny-list.
    for plist in "$WINDOWSERVER_PLIST" "$VNC_PLIST" "$TERM_PLIST" \
                 "$VSCODE_PLIST" "$CHROME150_PLIST"; do
        [ -f "$plist" ] || continue
        if plutil "$plist" 2>/dev/null | grep -Eq \
            '"?(MallocScribble|MallocStackLogging|MACWS_RUNTIME_DIAGNOSTICS|MACWS_SUBMIT_FAST_RING|MACWS_ABORT_TRACE|MACWS_AGX_CRASH_DIAG|MACWS_IOSURF_TRACE|MACWS_JIT_MPROTECT_TRACE|MACWS_MACH_MSG_TRACE|MACWS_VNC_TRACE_CLIENT_MESSAGES|MACWS_XPC_DEBUG)"?[[:space:]]*='; then
            log "ERROR: production debug environment found in $plist"
            bad=1
        fi
    done
    for key in MACWS_AGX_NATIVE MACWS_AGX_REGISTER_CLASSES MACWS_PIN_FALLBACK; do
        if ! plutil "$WINDOWSERVER_PLIST" 2>/dev/null |
             grep -Eq "\"?$key\"?[[:space:]]*=[[:space:]]*1;"; then
            log "ERROR: required native-AGX environment $key=1 missing from $WINDOWSERVER_PLIST"
            bad=1
        fi
    done
    for path in /tmp/macws_kcmd_fix /tmp/macws_kcmd_wrapped_fix \
                /tmp/macws_cancel_completion; do
        if [ ! -e "$ROOTFS$path" ]; then
            log "ERROR: required native-AGX production flag missing: $path"
            bad=1
        fi
    done
    if [ "$WANT_VNC" = 1 ]; then
        for path in /tmp/macws_vnc_share /tmp/macws_owned_scanout; do
            if [ ! -e "$ROOTFS$path" ]; then
                log "ERROR: required production VNC flag missing: $path"
                bad=1
            fi
        done
        for key in MACWS_VNC_NATIVE_ALL MACWS_VNC_LOW_LATENCY_COMPRESSION; do
            if ! plutil "$VNC_PLIST" 2>/dev/null |
                 grep -Eq "\"?$key\"?[[:space:]]*=[[:space:]]*1;"; then
                log "ERROR: required production VNC environment $key=1 missing from $VNC_PLIST"
                bad=1
            fi
        done
    fi
    diagnostic_flag_paths | while IFS= read -r path; do
        [ ! -e "$ROOTFS$path" ] || echo "$path"
    done > "$ROOTFS/private/tmp/macws_production_preflight.bad"
    if [ -s "$ROOTFS/private/tmp/macws_production_preflight.bad" ]; then
        log "ERROR: diagnostic flag survived production cleanup:"
        sed 's/^/       /' "$ROOTFS/private/tmp/macws_production_preflight.bad"
        bad=1
    fi
    rm -f "$ROOTFS/private/tmp/macws_production_preflight.bad"
    [ "$bad" = 0 ] || return 1
    log "PRODUCTION-PREFLIGHT: native AGX required; diagnostics/env traces/dump sentinels OFF."
    return 0
}

cleanup_macos() {
    log "Cleaning up previous macOS GUI services..."
    stop_watchdogs

    # 1) our VNC / Terminal launchd jobs (by plist, then by label as a fallback)
    launchctl unload "$VNC_PLIST"  2>/dev/null
    launchctl unload "$TERM_PLIST" 2>/dev/null
    launchctl unload "$PBOARD_PLIST" 2>/dev/null
    launchctl unload "$PBS_PLIST" 2>/dev/null
    launchctl remove "$VNC_LABEL"  2>/dev/null
    launchctl remove "$TERM_LABEL" 2>/dev/null
    launchctl remove "$PBOARD_LABEL" 2>/dev/null
    launchctl remove "$PBS_LABEL" 2>/dev/null

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
    kill_by_pattern "$P_PBOARD"
    kill_by_pattern "$P_PBS"
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

    clear_diagnostic_state

    # The mmap is a producer-owned WindowServer artifact, not persistent
    # session state.  Keeping it after the producer exits lets a fresh OSXvnc
    # process advertise pixels from an earlier application even when the new
    # WindowServer has not published a frame.  Remove it only after every old
    # producer/client has been stopped so no live mapping is invalidated.
    rm -f "$VNC_SHARED_FRAME" "$VNC_SHARED_SURFID" "$VNC_ACTIVITY" \
        "$GRAPHICS_READY" \
        "$EXPERIMENTAL_CAPTURE" "$EXPERIMENTAL_CAPTURE_DONE" \
        "$EXPERIMENTAL_KCMD" "$EXPERIMENTAL_WRAPPED_KCMD" \
        "$EXPERIMENTAL_COMMAND_ERROR" "$EXPERIMENTAL_COMPLETION" \
        "$EXPERIMENTAL_VNC_SHARE" "$EXPERIMENTAL_OBSERVE_PF550" \
        "$EXPERIMENTAL_SUBMIT_RING" "$EXPERIMENTAL_FAST_SUBMIT_RING" \
        "$EXPERIMENTAL_OWNED_SCANOUT" "$EXPERIMENTAL_QUEUE_QOS" \
        "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS" "$EXPERIMENTAL_PACE"
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

    log "Starting macOS pasteboard service (launchd job '$PBOARD_LABEL')..."
    rm -f "$LOGDIR/pboard.log"
    launchctl load "$PBOARD_PLIST" || return 1
    waited=0
    while ! proc_running "$P_PBOARD" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_PBOARD" || {
        log "ERROR: macOS pboard process did not start."
        return 1
    }

    log "Starting macOS Services database service (launchd job '$PBS_LABEL')..."
    rm -f "$LOGDIR/pbs.log"
    launchctl load "$PBS_PLIST" || return 1
    waited=0
    while ! proc_running "$P_PBS" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_PBS" || {
        log "ERROR: macOS pbs process did not start."
        return 1
    }

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
        "$EXPERIMENTAL_FAST_SUBMIT_RING" \
        "$EXPERIMENTAL_QUEUE_QOS" "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS" \
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
    ps aux | grep -iE "$P_WINDOWSERVER|$P_OSXVNC|$P_TERMINAL|$P_LAUNCHSERVICESD|$P_PBOARD|$P_PBS" \
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
    echo "logs: $LOGDIR/osxvnc.log  $LOGDIR/terminal.log  $LOGDIR/pboard.log  $LOGDIR/pbs.log  $LOGDIR/WindowServer.err"
}

switch_status() {
    local path actual
    echo "=== MacWS production switch audit ==="
    echo "profile defaults: AGX-native=ON compatibility=ON diagnostics=OFF mode=coexist"
    echo
    echo "-- required functional flags --"
    for path in /tmp/macws_kcmd_fix /tmp/macws_kcmd_wrapped_fix \
                /tmp/macws_cancel_completion /tmp/macws_vnc_share \
                /tmp/macws_owned_scanout /tmp/macws_coexist_pace_us; do
        if [ -e "$ROOTFS$path" ]; then actual=ON; else actual=OFF; fi
        printf '%-48s actual=%s\n' "$path" "$actual"
    done
    echo
    echo "-- diagnostic/A-B flags (production expected OFF) --"
    diagnostic_flag_paths | while IFS= read -r path; do
        if [ -e "$ROOTFS$path" ]; then actual=ON; else actual=OFF; fi
        printf '%-48s expected=OFF actual=%s\n' "$path" "$actual"
    done
    echo
    echo "-- configured launch environments --"
    for path in "$WINDOWSERVER_PLIST" "$VNC_PLIST" "$TERM_PLIST" \
                "$VSCODE_PLIST" "$CHROME150_PLIST"; do
        [ -f "$path" ] || continue
        echo "[$path]"
        plutil "$path" 2>/dev/null | sed -n '/EnvironmentVariables =/,/^    };/p'
    done
    echo
    echo "authoritative inventory: docs/runtime-switches.tsv"
}

usage() {
    cat <<USAGE
macos_gui.sh — start/stop the chroot macOS GUI (WindowServer + VNC + Terminal)

Usage (run as root):
  sudo bash $0 production
  sudo bash $0 start [coexist|exclusive] [--no-experimental] [--diagnostics] [--pace-us=N] [--runtime-cap=SECONDS] [--no-terminal] [--no-vnc] [--no-watchdog]
  sudo bash $0 switches
  sudo bash $0 stop
  sudo bash $0 restart [coexist|exclusive] [...]
  sudo bash $0 status

Modes:
  coexist     (default) iPad panel keeps showing iOS; macOS renders to VNC only.
  exclusive   macOS takes over the physical panel as well as VNC.

Safety: start also launches a background watchdog that auto-stops the GUI if
WindowServer crash-loops or the load average runs away (panic guard). Disable
with --no-watchdog. Logs to $LOGDIR/macos_gui_watchdog.log.

The production profile enables native AGX and its required command/completion
compatibility adapters by default. High-overhead flight recorders and read-only
method tracing remain off unless --diagnostics is explicitly present. Use
--no-experimental only for an intentional control experiment. Interactive
sessions have no arbitrary wall-clock timeout, while
crash-loop/load/high-CPU protection stays armed. Automated runs may add
--runtime-cap=300 (minimum 60 seconds).

Connect a VNC viewer to  vnc://<device-ip>:5900  (no password).
USAGE
}

# ─── Argument parsing ───────────────────────────────────────────────────────
CMD="${1:-}"
[ $# -gt 0 ] && shift

FORCE_PRODUCTION=0
if [ "$CMD" = production ]; then
    CMD=start
    FORCE_PRODUCTION=1
fi

MODE=coexist
WANT_VNC=1
WANT_TERMINAL=1
WANT_WATCHDOG=1
WANT_EXPERIMENTAL=1
WANT_DIAGNOSTICS=0
COEXIST_PACE_US=""
for a in "$@"; do
    case "$a" in
        coexist|coexistence|co)  MODE=coexist ;;
        exclusive|full|excl)     MODE=exclusive ;;
        --experimental)          WANT_EXPERIMENTAL=1 ;;
        --no-experimental)       WANT_EXPERIMENTAL=0 ;;
        --diagnostics)           WANT_DIAGNOSTICS=1 ;;
        --pace-us=*)             COEXIST_PACE_US="${a#--pace-us=}" ;;
        --runtime-cap=*)         WD_MAX_RUNTIME="${a#--runtime-cap=}" ;;
        --no-terminal)           WANT_TERMINAL=0 ;;
        --no-vnc)                WANT_VNC=0 ;;
        --no-watchdog)           WANT_WATCHDOG=0 ;;
        *) echo "macos_gui.sh: ignoring unknown option '$a'" >&2 ;;
    esac
done

if [ "$FORCE_PRODUCTION" = 1 ] &&
   { [ "$WANT_EXPERIMENTAL" != 1 ] || [ "$WANT_DIAGNOSTICS" = 1 ]; }; then
    echo "macos_gui.sh: production requires native compatibility ON and diagnostics OFF" >&2
    exit 1
fi

if [ "$WANT_DIAGNOSTICS" = 1 ] && [ "$WANT_EXPERIMENTAL" != 1 ]; then
    echo "macos_gui.sh: --diagnostics requires --experimental" >&2
    exit 1
fi

case "$WD_MAX_RUNTIME" in
    *[!0-9]*|'')
        echo "macos_gui.sh: --runtime-cap must be an integer (0 or at least 60 seconds)" >&2
        exit 1
        ;;
esac
if [ "$WD_MAX_RUNTIME" -ne 0 ] &&
   [ "$WD_MAX_RUNTIME" -lt 60 ]; then
    echo "macos_gui.sh: --runtime-cap must be 0 or at least 60 seconds" >&2
    exit 1
fi

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
    touch "$EXPERIMENTAL_KCMD" "$EXPERIMENTAL_WRAPPED_KCMD" \
        "$EXPERIMENTAL_COMPLETION"
    if [ "$WANT_VNC" = 1 ]; then
        touch "$EXPERIMENTAL_VNC_SHARE" "$EXPERIMENTAL_OWNED_SCANOUT"
    else
        # A headless/CDP performance run must not allocate and publish a
        # 15.2-MiB VNC scanout every WindowServer frame.  Keeping these
        # producer hooks enabled without an RFB consumer perturbs the very
        # presentation cadence the run is intended to measure.
        rm -f "$EXPERIMENTAL_VNC_SHARE" "$EXPERIMENTAL_OBSERVE_PF550" \
            "$EXPERIMENTAL_OWNED_SCANOUT"
    fi
    # Keep the old heap-allocating, mutex-protected deep recorder off the hot
    # path.  A VS Code GPU-process sample caught it in submission, and it can
    # perturb the timing-sensitive 0x102 failure.  The fixed-memory recorder
    # remains available only under the explicit diagnostic mode below.
    rm -f "$EXPERIMENTAL_SUBMIT_RING"
    rm -f "$EXPERIMENTAL_COMMAND_ERROR" "$EXPERIMENTAL_FAST_SUBMIT_RING" \
        "$EXPERIMENTAL_OBSERVE_PF550" "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS"
    if [ "$WANT_DIAGNOSTICS" = 1 ]; then
        touch "$EXPERIMENTAL_COMMAND_ERROR" \
            "$EXPERIMENTAL_FAST_SUBMIT_RING" \
            "$EXPERIMENTAL_OBSERVE_PF550" \
            "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS"
    fi
    rm -f "$EXPERIMENTAL_PACE"
    if [ -n "$COEXIST_PACE_US" ]; then
        echo "$COEXIST_PACE_US" > "$EXPERIMENTAL_PACE"
    fi
    if [ "$WANT_VNC" = 1 ]; then
        log "NATIVE-AGX-SCAFFOLD: command ABI (direct + validated wrapper forms) + cancelled-swap completion + owned BGRA scanout + stable VNC mmap enabled."
    else
        log "NATIVE-AGX-SCAFFOLD: command ABI (direct + validated wrapper forms) + cancelled-swap completion enabled; VNC scanout bridge disabled for headless measurement."
    fi
    if [ "$WANT_DIAGNOSTICS" = 1 ]; then
        log "DIAGNOSTICS: AGX fast submit recorder, lifecycle witnesses, PF550 observer, and command-error hooks enabled."
    fi
    if [ -n "$COEXIST_PACE_US" ]; then
        log "VIRTUAL-DISPLAY-COMPAT: completion pace=${COEXIST_PACE_US} us (not a hardware refresh signal)."
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
    stop_watchdogs
    rm -f "$WD_LOG"
    rm -f "$WD_TRIP"
    # Re-exec with the exact session intent.  The recovery path needs these
    # flags so a WS restart does not unexpectedly launch a VNC/Terminal job the
    # user disabled, and so it knows whether to request a fresh shared frame.
    set -- watchdog "$MODE"
    [ "$WANT_VNC" = 1 ] || set -- "$@" --no-vnc
    [ "$WANT_TERMINAL" = 1 ] || set -- "$@" --no-terminal
    [ "$WANT_EXPERIMENTAL" = 1 ] && set -- "$@" --experimental
    [ "$WANT_DIAGNOSTICS" = 1 ] && set -- "$@" --diagnostics
    [ -n "$COEXIST_PACE_US" ] && set -- "$@" "--pace-us=$COEXIST_PACE_US"
    [ "$WD_MAX_RUNTIME" -gt 0 ] &&
        set -- "$@" "--runtime-cap=$WD_MAX_RUNTIME"
    nohup bash "$0" "$@" > "$WD_LOG" 2>&1 < /dev/null &
    echo "$!" > "$WD_PIDFILE"
    log "watchdog: started in background (log: $WD_LOG; vnc=$WANT_VNC terminal=$WANT_TERMINAL experimental=$WANT_EXPERIMENTAL diagnostics=$WANT_DIAGNOSTICS)"
}

case "$CMD" in
    start)
        require_root "$@"
        write_plists
        ensure_chroot_works || exit 1
        cleanup_macos
        enable_experimental_if_requested
        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_DIAGNOSTICS" != 1 ]; then
            production_preflight || { stop_all; exit 1; }
        fi
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
        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_DIAGNOSTICS" != 1 ]; then
            production_preflight || { stop_all; exit 1; }
        fi
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
    switches)
        switch_status
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
