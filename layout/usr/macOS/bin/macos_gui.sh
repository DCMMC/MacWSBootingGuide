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
#   --runtime-cap=N        optional automation wall-clock cap (minimum 60s)
#
# The iOS-native temperature watchdog is mandatory.  There is deliberately no
# option to disable it: every GUI mode and benchmark stays inside the same
# thermal safety envelope.
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
MACOS_DAEMONS=/var/jb/usr/macOS/LaunchDaemons  # WindowServer + required macOS services
WINDOWSERVER_PLIST="$MACOS_DAEMONS/com.apple.WindowServer.plist"
LAUNCHSERVICESD_PLIST="$MACOS_DAEMONS/com.apple.coreservices.launchservicesd.plist"
SYSTEMSTATUSD_PLIST="$MACOS_DAEMONS/com.apple.systemstatusd.plist"
FONTD_PLIST="$MACOS_DAEMONS/com.macwsguide.xtyped.plist"
VIEWBRIDGE_PLIST="$MACOS_DAEMONS/com.macwsguide.viewbridge.plist"
EXTENSIONKIT_PLIST="$MACOS_DAEMONS/com.macwsguide.extensionkit.plist"
HISERVICES_PLIST="$MACOS_DAEMONS/com.macwsguide.hiservices.plist"
GEOD_PLIST="$MACOS_DAEMONS/com.macwsguide.geod.plist"
CHROOTEXEC=/var/jb/usr/macOS/bin/launchdchrootexec
RUN_BASH=/var/jb/usr/macOS/bin/run_bash.sh
POSTINST=/var/jb/usr/macOS/bin/postinst.sh
THERMAL_HELPER=/var/jb/usr/macOS/bin/macwsthermal
LOGDIR=/var/jb/var/mobile
TEST_LEASE="$LOGDIR/macws_test_lease"

GUI_LAUNCHD_DIR=/var/jb/usr/macOS/gui-launchd   # script-owned; NOT auto-scanned at boot
WATCHDOG_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.watchdog.plist"
VSCODE_ASSET_DIR=/var/jb/usr/macOS/share/vscode
VNC_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.osxvnc.plist"
TERM_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.terminal.plist"
PBOARD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.pboard.plist"
PBS_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.pbs.plist"
LSD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.lsd.plist"
CFPREFSD_DAEMON_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.cfprefsd-daemon.plist"
CFPREFSD_AGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.cfprefsd-agent.plist"
MACOS_LOCATIOND_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.macos-locationd.plist"
CORELOCATIONAGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.corelocationagent.plist"
LOCATIONBRIDGE_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.locationbridge.plist"
ICONSERVICESD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.iconservicesd.plist"
ICONSERVICESAGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.iconservicesagent.plist"
FINDER_DESKTOP_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.finder-desktop.plist"
DOCK_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.dock.plist"
SYSTEMUI_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.systemuiserver.plist"
CONTROL_CENTER_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.controlcenter.plist"
INPUT_PLIST="$MACOS_DAEMONS/com.macwsguide.input.plist"
DISPLAY_PLIST="$MACOS_DAEMONS/com.macwsguide.display.plist"
INTEROP_PLIST="$MACOS_DAEMONS/com.macwsguide.interop.plist"
WINDOWSERVER_LABEL=UIKitApplication:com.macwsguide.windowserver
VNC_LABEL=UIKitApplication:com.macwsguide.osxvnc
TERM_LABEL=UIKitApplication:com.macwsguide.terminal
PBOARD_LABEL=com.macwsguide.pboard
PBS_LABEL=com.macwsguide.pbs
LSD_LABEL=com.macwsguide.lsd
CFPREFSD_DAEMON_LABEL=com.macwsguide.cfprefsd-daemon
CFPREFSD_AGENT_LABEL=com.macwsguide.cfprefsd-agent
MACOS_LOCATIOND_LABEL=com.macwsguide.macos-locationd
CORELOCATIONAGENT_LABEL=com.macwsguide.corelocationagent
LOCATIONBRIDGE_LABEL=com.macwsguide.locationbridge
ICONSERVICESD_LABEL=com.macwsguide.iconservicesd
ICONSERVICESAGENT_LABEL=com.macwsguide.iconservicesagent
FINDER_DESKTOP_LABEL=com.macwsguide.finder-desktop
DOCK_LABEL=com.macwsguide.dock
SYSTEMUI_LABEL=com.macwsguide.systemuiserver
CONTROL_CENTER_LABEL=com.macwsguide.controlcenter
INPUT_LABEL=UIKitApplication:com.macwsguide.input
DISPLAY_LABEL=UIKitApplication:com.macwsguide.display
INTEROP_LABEL=UIKitApplication:com.macwsguide.interop
VIEWBRIDGE_LABEL=com.macwsguide.viewbridge
EXTENSIONKIT_LABEL=com.macwsguide.extensionkit
HISERVICES_LABEL=com.macwsguide.hiservices
GEOD_LABEL=com.macwsguide.geod
WATCHDOG_LABEL=com.macwsguide.watchdog
VSCODE_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.vscode.plist"
VSCODE_LABEL=UIKitApplication:com.macwsguide.vscode
VSCODE_TRUST_SENTINEL="$ROOTFS/Applications/Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
VSCODE_PROFILE_DIR="$ROOTFS/private/tmp/macws-vscode-profile-agx-native-targetfix13"
VSCODE_EXTENSIONS_DIR="$ROOTFS/private/tmp/macws-vscode-extensions"
# Metal's source-library FS cache is keyed by compiler build, not by the
# effective target triple. Before the macabi source adapter existed, VS Code
# populated this exact cache with air64-apple-ios16.3.0 MTLBs. Metal later
# returned those blobs to the macOS AGX device and rejected them as an
# unsupported library format. Keep an explicit project schema beside the
# regenerable library cache so a package/cold start cannot silently reuse
# artifacts produced under the old target policy.
VSCODE_METAL_CACHE_ROOT="$ROOTFS/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/C/com.microsoft.VSCode.helper/com.apple.metal"
VSCODE_METAL_LIBRARY_CACHE="$VSCODE_METAL_CACHE_ROOT/31001"
VSCODE_METAL_CACHE_SCHEMA=macws-macabi-source-v1
VSCODE_METAL_CACHE_MARKER="$VSCODE_METAL_CACHE_ROOT/.macws-source-target-schema"
VSCODE_ANGLE_MACABI_LIBRARY="$ROOTFS/usr/local/share/macws/angle/angle-default-1ba8ec3-macabi.metallib"
CHROME150_PLIST=/var/jb/Library/LaunchDaemons/com.macwsguide.chrome150.plist
CHROME150_LABEL=UIKitApplication:com.macwsguide.chrome150
EXPERIMENTAL_KCMD="$ROOTFS/private/tmp/macws_kcmd_fix"
EXPERIMENTAL_WRAPPED_KCMD="$ROOTFS/private/tmp/macws_kcmd_wrapped_fix"
EXPERIMENTAL_COMMAND_ERROR="$ROOTFS/private/tmp/macws_command_error_diag"
EXPERIMENTAL_COMPLETION="$ROOTFS/private/tmp/macws_cancel_completion"
EXPERIMENTAL_VNC_SHARE="$ROOTFS/private/tmp/macws_vnc_share"
EXPERIMENTAL_OBSERVE_PF550="$ROOTFS/private/tmp/macws_observe_pf550"
EXPERIMENTAL_SUBMIT_RING="$ROOTFS/private/tmp/macws_submit_ring"
EXPERIMENTAL_FAST_SUBMIT_RING="$ROOTFS/private/tmp/macws_submit_fast_ring"
EXPERIMENTAL_RUNTIME_DIAGNOSTICS="$ROOTFS/private/tmp/macws_runtime_diagnostics"
MTLCOMPILER_DIAGNOSTICS="$LOGDIR/macws_mtlcompiler_diagnostics"
MTLCOMPILER_DIAGNOSTICS_NATIVE=/var/mobile/macws_mtlcompiler_diagnostics
CATALYST_LAUNCH_TRACE="$LOGDIR/macws_catalyst_launch.trace"
EXPERIMENTAL_QUEUE_QOS="$ROOTFS/private/tmp/macws_queue_qos_diag"
EXPERIMENTAL_OWNED_SCANOUT="$ROOTFS/private/tmp/macws_owned_scanout"
EXPERIMENTAL_PACE="$ROOTFS/private/tmp/macws_coexist_pace_us"
EXPERIMENTAL_CAPTURE="$ROOTFS/private/tmp/macws_capture_final"
EXPERIMENTAL_CAPTURE_DONE="$ROOTFS/private/tmp/macws_capture_done"
VNC_SHARED_FRAME="$ROOTFS/private/tmp/macws_vnc_fb"
VNC_SHARED_SURFID="$ROOTFS/private/tmp/macws_vnc_surfid"
VNC_ACTIVITY="$ROOTFS/private/tmp/macws_vnc_activity"
INTERACTION_WAKE="$ROOTFS/private/tmp/macws_interaction_wake.sock"
VNC_ACTIVATION_REPLY="$ROOTFS/private/tmp/macws_vnc_activation_reply.sock"
GRAPHICS_READY="$ROOTFS/private/tmp/macws_graphics_ready"
ARMED_CAPTURE_GENERATION=""
CAPTURE_READY_WAIT=60
# A cold native-AGX start may spend more than 45 seconds realizing classes and
# compiling the first compositor pipelines before the first clean producer
# completion.  Keep the real completion/PID witness mandatory, but allow that
# evidence enough time to arrive; runtime sampling on 2026-07-30 saw a healthy
# WindowServer actively render before the old deadline, then publish the exact
# clean-producer witness shortly after the launcher had returned failure.
WINDOWSERVER_READY_WAIT=90
STARTED_WS_PID=""

VNC_BIN=/usr/local/bin/OSXvnc-server                                              # chroot path
TERM_BIN="/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"   # chroot path
PBOARD_BIN=/usr/libexec/pboard
PBS_BIN=/System/Library/CoreServices/pbs
FINDER_BIN=/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
DOCK_BIN=/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
SYSTEMUI_BIN=/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer
CONTROL_CENTER_BIN=/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
ICONSERVICESD_BIN=/System/Library/CoreServices/iconservicesd
ICONSERVICESAGENT_BIN=/System/Library/CoreServices/iconservicesagent
# Never launch Ventura's stock cfprefsd image directly.  iPadOS AMFI rejects
# its Apple CT policy, while the project's broad chroot entitlement profile
# gives it com.apple.security.system-container and makes sandbox_init kill it.
# postinst creates this byte-identical private copy with the dedicated minimal
# cfprefsd entitlement profile that was runtime-validated on iPadOS 16.3.
CFPREFSD_BIN=/usr/local/libexec/macws-cfprefsd
DEFAULTS_BIN=/usr/bin/defaults
LSREGISTER_BIN=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WORKSPACECTL_BIN=/usr/local/bin/macwsworkspacectl
SETTINGS_EXTENSION_REGISTER_LOG="$LOGDIR/settings-extension-register.log"
UICACHE=/var/jb/usr/bin/uicache
SETTINGS_EXTENSION_CARRIER_ID=com.macwsguide.settings-extension-carrier
SETTINGS_EXTENSION_CARRIER_APP=/var/jb/Applications/SettingsExtensionProxy.app
WORKSPACE_WALLPAPER='/System/Library/Desktop Pictures/Solid Colors/Blue Violet.png'
VNC_DESKTOP=macOS-iPad

SPRINGBOARD=/System/Library/LaunchDaemons/com.apple.SpringBoard.plist
BACKBOARDD=/System/Library/LaunchDaemons/com.apple.backboardd.plist

# Process-match patterns (full paths; unique to the chroot macOS processes so we
# never hit an iOS process by accident — iOS has no WindowServer/launchservicesd).
P_WINDOWSERVER='SkyLight.framework/Resources/WindowServer'
P_LAUNCHSERVICESD='CoreServices/launchservicesd'
P_SYSTEMSTATUSD='SystemStatusServer.framework/Support/systemstatusd'
P_FONTD='ATS.framework/Support/fontd'
P_OSXVNC='OSXvnc-server'
P_TERMINAL='Utilities/Terminal.app/Contents/MacOS/Terminal'
P_PBOARD='/usr/libexec/pboard'
P_PBS='/System/Library/CoreServices/pbs'
P_ACTIVITYMON='Activity Monitor.app/Contents/MacOS/Activity Monitor'
P_GLASSDEMO='/tmp/GlassDemo'
P_FINDER='CoreServices/Finder.app/Contents/MacOS/Finder'
P_DOCK='CoreServices/Dock.app/Contents/MacOS/Dock'
P_SYSTEMUI='CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer'
P_CONTROL_CENTER='CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter'
P_ICONSERVICESD='CoreServices/iconservicesd'
P_ICONSERVICESAGENT='CoreServices/iconservicesagent'
P_INPUTD='/usr/local/bin/macwsinputd'
P_DISPLAYD='/usr/local/bin/macwsdisplayd'
P_INTEROPD='/usr/local/libexec/MacWSInteropService.app/Contents/MacOS/macwsinteropd'
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
# The native-AGX workload is distributed across WindowServer, application GPU
# processes and the kernel driver. A single process's CPU percentage therefore
# cannot establish whether the iPad is thermally safe. The primary guard reads
# iPadOS's NSProcessInfo thermal state and AppleSmartBattery temperature through
# an iOS-native helper. Temperature values and non-critical states are evidence
# only; per policy, thermal intervention occurs only at `critical`.
WD_THERMAL_POLL=300  # temperature sensors are sampled every 5 minutes
# Do not gate or stop the GUI on `memory_pressure -Q`. iOS deliberately uses
# otherwise-idle RAM for caches and reclaimable objects, so a free-percentage
# threshold is not a reliable pressure-state boundary. The former 58% policy
# produced a runtime-confirmed false stop during an otherwise healthy launch
# and is retired. XNU/iOS memorystatus remains the authority for reclamation.
WD_RESTART_LIMIT=12  # WindowServer restarts within WD_WINDOW that means "crash loop"
                     # (raised from 4: Firefox triggers some SkyLight CAWSBackend asserts
                     #  we haven't byte-patched yet (render_update composite_destination
                     #  nullptr). launchd respawns WS in ~1s; up to ~12 restarts per 45s
                     #  is annoying but not yet runaway — only stop if it's much worse)
WD_WINDOW=45         # seconds — restart-counting window
WD_POLL=5            # seconds between checks
# Interactive VNC sessions must not disappear at an arbitrary test deadline.
# The old unconditional 300-second limit runtime-confirmed the user's abrupt
# shutdown: the watchdog logged the cap trip while VS Code logged SIGTERM.
# Crash-loop/load/sustained-CPU guards remain armed. Bounded automation can
# opt back into a wall-clock limit with --runtime-cap=SECONDS.
WD_MAX_RUNTIME=0
WD_LOG="$LOGDIR/macos_gui_watchdog.log"
WD_TRIP="$LOGDIR/macws_safety_trip"
WD_PIDFILE="$LOGDIR/macos_gui_watchdog.pid"
WD_READY="$LOGDIR/macos_gui_watchdog.ready"
WD_THERMAL_SNAPSHOT="$LOGDIR/macos_gui_thermal_snapshot"
WD_WS_PIDFILE="$LOGDIR/macos_gui_watchdog.ws-pid"
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
CLEANUP_TERM_PIDS=""
kill_by_pattern() {
    local pat="$1" pids pid
    pids=$(ps aux 2>/dev/null | grep -v grep | grep -F "$pat" | awk '{print $2}')
    for pid in $pids; do
        [ "$pid" = "$$" ] && continue
        kill "$pid" 2>/dev/null
        case " $CLEANUP_TERM_PIDS " in
            *" $pid "*) ;;
            *) CLEANUP_TERM_PIDS="$CLEANUP_TERM_PIDS $pid" ;;
        esac
    done
    return 0
}

# AppKit clients can ignore or remain stuck while handling SIGTERM.  A plain
# process uptime check used to make cleanup look successful even though an old
# Finder survived for 81 minutes at 83% CPU and continuously logged an
# incompatible LaunchServices schema.  Give the complete, exact PID set one
# shared grace period, then KILL only surviving members of that set.  This is a
# lifecycle invariant: no client connected to the previous WindowServer may
# enter the next generation.
finish_pattern_cleanup() {
    local deadline alive="" pid
    [ -z "$CLEANUP_TERM_PIDS" ] && return 0
    deadline=$(( $(date +%s) + 2 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        alive=""
        for pid in $CLEANUP_TERM_PIDS; do
            kill -0 "$pid" 2>/dev/null && alive="$alive $pid"
        done
        [ -z "$alive" ] && break
        sleep 0.1
    done
    for pid in $alive; do
        kill -KILL "$pid" 2>/dev/null
    done
    CLEANUP_TERM_PIDS=""
}

# True if any running process's command line contains the (fixed-string) pattern.
proc_running() {
    ps aux 2>/dev/null | grep -v grep | grep -qF "$1"
}

# launchd's current PID for one exact job (empty / "-" when not running).
launchd_job_pid() {
    launchctl list "$1" 2>/dev/null \
        | awk -F'= ' '/"PID"/{gsub(/[ ";]/,"",$2); print $2}'
}

ws_pid() { launchd_job_pid "$WINDOWSERVER_LABEL"; }

record_ws_pid() {
    local pid="$1" tmp="${WD_WS_PIDFILE}.$$"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$pid" > "$tmp" && mv "$tmp" "$WD_WS_PIDFILE"
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

# Extract one key=value field from the helper's single-line output.  The helper
# uses integer centi-degrees specifically so policy never depends on locale or
# floating-point parsing in the shell.
thermal_field() {
    local line="$1" wanted="$2"
    printf '%s\n' "$line" | awk -v wanted="$wanted" '
        {
            for (i = 1; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == wanted) { print pair[2]; exit }
            }
        }'
}

# Populate THERMAL_* globals from one iOS-native sensor snapshot.  A nonzero
# helper exit status is expected for fair/serious/critical states, so validity
# is determined from its structured output rather than command success alone.
thermal_snapshot() {
    THERMAL_LINE=""
    THERMAL_STATE=""
    THERMAL_TEMP_CENTIC=""
    THERMAL_HELPER_RC=127

    [ -x "$THERMAL_HELPER" ] || return 1
    THERMAL_LINE=$("$THERMAL_HELPER" 2>&1)
    THERMAL_HELPER_RC=$?
    THERMAL_STATE=$(thermal_field "$THERMAL_LINE" thermal-state)
    THERMAL_TEMP_CENTIC=$(thermal_field "$THERMAL_LINE" effective-temp-centic)

    case "$THERMAL_STATE" in
        nominal|fair|serious|critical) ;;
        *) return 1 ;;
    esac
    return 0
}

record_thermal_snapshot() {
    local payload="$1" snapshot_tmp="${WD_THERMAL_SNAPSHOT}.$$"
    printf 'sampled-at=%s %s\n' "$(date +%s)" "$payload" > "$snapshot_tmp"
    mv "$snapshot_tmp" "$WD_THERMAL_SNAPSHOT"
}

# A GUI client cannot reuse its WindowServer connection after that server dies.
# Runtime evidence from OSXvnc is explicit:
#   "received notification of WindowServer event port death"
#   "port matched the WindowServer port created in BindCGSToRunLoop"
# Keeping that old process alive therefore leaves a valid TCP listener backed by
# a permanently dead CGS session.  Tear down only WS-dependent clients, wait for
# launchd's replacement WS to stay alive for two samples, then reconnect them.
stop_ws_dependents() {
    CLEANUP_TERM_PIDS=""
    launchctl unload "$VNC_PLIST"  2>/dev/null
    launchctl unload "$TERM_PLIST" 2>/dev/null
    launchctl remove "$VNC_LABEL"  2>/dev/null
    launchctl remove "$TERM_LABEL" 2>/dev/null
    launchctl unload "$INPUT_PLIST" 2>/dev/null
    launchctl remove "$INPUT_LABEL" 2>/dev/null
    launchctl unload "$DISPLAY_PLIST" 2>/dev/null
    launchctl remove "$DISPLAY_LABEL" 2>/dev/null
    launchctl unload "$INTEROP_PLIST" 2>/dev/null
    launchctl remove "$INTEROP_LABEL" 2>/dev/null
    launchctl unload "$HISERVICES_PLIST" 2>/dev/null
    launchctl unload "$GEOD_PLIST" 2>/dev/null
    launchctl unload "$EXTENSIONKIT_PLIST" 2>/dev/null
    launchctl unload "$VIEWBRIDGE_PLIST" 2>/dev/null
    launchctl remove "$HISERVICES_LABEL" 2>/dev/null
    launchctl remove "$GEOD_LABEL" 2>/dev/null
    launchctl remove "$EXTENSIONKIT_LABEL" 2>/dev/null
    launchctl remove "$VIEWBRIDGE_LABEL" 2>/dev/null
    launchctl unload "$VSCODE_PLIST" 2>/dev/null
    launchctl remove "$VSCODE_LABEL" 2>/dev/null

    # These are on-demand Ventura location services, kept outside the
    # auto-scanned LaunchDaemons directory so they can never race a missing
    # chroot/WindowServer at jailbreak startup.  Unload their exact jobs;
    # never use killall locationd because that would also terminate iPadOS's
    # native system location daemon.
    launchctl unload "$CORELOCATIONAGENT_PLIST" 2>/dev/null
    launchctl remove "$CORELOCATIONAGENT_LABEL" 2>/dev/null
    launchctl unload "$LOCATIONBRIDGE_PLIST" 2>/dev/null
    launchctl remove "$LOCATIONBRIDGE_LABEL" 2>/dev/null
    launchctl unload "$MACOS_LOCATIOND_PLIST" 2>/dev/null
    launchctl remove "$MACOS_LOCATIOND_LABEL" 2>/dev/null
    launchctl unload "$CHROME150_PLIST" 2>/dev/null
    launchctl remove "$CHROME150_LABEL" 2>/dev/null
    launchctl unload "$LSD_PLIST" 2>/dev/null
    launchctl remove "$LSD_LABEL" 2>/dev/null
    launchctl unload "$ICONSERVICESAGENT_PLIST" 2>/dev/null
    launchctl unload "$ICONSERVICESD_PLIST" 2>/dev/null
    launchctl remove "$ICONSERVICESAGENT_LABEL" 2>/dev/null
    launchctl remove "$ICONSERVICESD_LABEL" 2>/dev/null
    for workspace_plist in "$FINDER_DESKTOP_PLIST" "$DOCK_PLIST" \
                           "$SYSTEMUI_PLIST" "$CONTROL_CENTER_PLIST"; do
        launchctl unload "$workspace_plist" 2>/dev/null
    done
    for workspace_label in "$FINDER_DESKTOP_LABEL" "$DOCK_LABEL" \
                           "$SYSTEMUI_LABEL" "$CONTROL_CENTER_LABEL"; do
        launchctl remove "$workspace_label" 2>/dev/null
    done
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
    kill_by_pattern "$P_DOCK"
    kill_by_pattern "$P_SYSTEMUI"
    kill_by_pattern "$P_CONTROL_CENTER"
    kill_by_pattern "$P_ICONSERVICESAGENT"
    kill_by_pattern "$P_ICONSERVICESD"
    kill_by_pattern "$P_INPUTD"
    kill_by_pattern "$P_DISPLAYD"
    kill_by_pattern "$P_INTEROPD"
    kill_by_pattern "$P_VSCODE"
    kill_by_pattern "$P_CHROME150"
    finish_pattern_cleanup
    rm -f "$ROOTFS"/private/tmp/macws_app_input.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_window_metrics.*.bin
    rm -f "$ROOTFS"/private/tmp/macws_menu_client.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_menu_snapshot.*.bin
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

    publish_settings_service_contracts || {
        log "watchdog: private macOS settings service contracts did not recover"
        return 1
    }
    ensure_locationd_dirhelper_tree || {
        log "watchdog: Ventura locationd cache tree did not recover"
        return 1
    }
    [ ! -f "$MACOS_LOCATIOND_PLIST" ] ||
        launchctl load "$MACOS_LOCATIOND_PLIST" 2>/dev/null
    [ ! -f "$CORELOCATIONAGENT_PLIST" ] ||
        launchctl load "$CORELOCATIONAGENT_PLIST" 2>/dev/null
    if [ -f "$INPUT_PLIST" ]; then
        launchctl load "$INPUT_PLIST" 2>/dev/null
    fi
    [ ! -f "$DISPLAY_PLIST" ] || launchctl load "$DISPLAY_PLIST" 2>/dev/null
    [ ! -f "$INTEROP_PLIST" ] || launchctl load "$INTEROP_PLIST" 2>/dev/null
    # The native location producer publishes scalar fixes through interopd.
    # Start it only after that Mach listener exists; an XPC client created
    # before the listener on cold boot can lose its cached first fix.
    [ ! -f "$LOCATIONBRIDGE_PLIST" ] ||
        launchctl load "$LOCATIONBRIDGE_PLIST" 2>/dev/null
    [ ! -f "$LSD_PLIST" ] || launchctl load "$LSD_PLIST" 2>/dev/null
    [ ! -f "$ICONSERVICESD_PLIST" ] || \
        launchctl load "$ICONSERVICESD_PLIST" 2>/dev/null
    [ ! -f "$ICONSERVICESAGENT_PLIST" ] || \
        launchctl load "$ICONSERVICESAGENT_PLIST" 2>/dev/null
    for workspace_plist in "$FINDER_DESKTOP_PLIST" "$DOCK_PLIST" \
                           "$SYSTEMUI_PLIST" "$CONTROL_CENTER_PLIST"; do
        [ ! -f "$workspace_plist" ] || launchctl load "$workspace_plist" 2>/dev/null
    done
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
    [ "$owner" = "$$" ] && rm -f "$WD_PIDFILE" "$WD_READY"
    return 0
}

# Watchdog loop (runs iOS-side, backgrounded by `start`). Thermal intervention
# is critical-only; WindowServer lifecycle and explicit runtime caps are
# independent non-thermal trip paths.
run_watchdog() {
    local last_pid="" restarts=0 t0 started now pid
    local missing_samples=0 next_thermal=0
    local ws_seen=0 startup_wait_logged=0
    local startup_owner="${MACWS_WATCHDOG_STARTUP_OWNER:-}"
    local runtime_cap_label="disabled"
    case "$startup_owner" in
        ''|*[!0-9]*) startup_owner="" ;;
    esac
    # Every launchd generation records its own PID. The ownership-aware EXIT
    # trap cannot erase a replacement watchdog's pidfile if relaunch timing
    # overlaps with the previous process exiting.
    echo "$$" > "$WD_PIDFILE"
    trap watchdog_pidfile_cleanup EXIT
    # launchd restarts this process after an abnormal death. Preserve the last
    # observed WindowServer PID outside the shell process so the replacement
    # can detect a server-generation change that happened while no loop was
    # running. Runtime-confirmed 2026-08-04: the old nohup watchdog vanished
    # with a stale pidfile while macwsdisplayd outlived WindowServer; restarting
    # only macwsdisplayd immediately restored every workspace capture layer.
    last_pid=$(awk 'NR == 1 { print $1 }' "$WD_WS_PIDFILE" 2>/dev/null)
    case "$last_pid" in
        ''|*[!0-9]*) last_pid="" ;;
    esac
    t0=$(date +%s)
    started=$t0
    next_thermal=$((started + WD_THERMAL_POLL))
    [ "$WD_MAX_RUNTIME" -gt 0 ] &&
        runtime_cap_label="${WD_MAX_RUNTIME}s"

    # Handshake proves that the independent watchdog process is alive. Missing
    # telemetry is logged but does not block work: thermal intervention is
    # deliberately limited to an explicitly observed `critical` state.
    if thermal_snapshot; then
        record_thermal_snapshot "$THERMAL_LINE"
        log "watchdog: initial thermal sample: $THERMAL_LINE"
        if [ "$THERMAL_STATE" = critical ]; then
            trip_watchdog "启动时 iPadOS 温度状态为 critical，已拒绝启动 macOS GUI"
            return 0
        fi
    else
        record_thermal_snapshot "unavailable rc=$THERMAL_HELPER_RC output='${THERMAL_LINE:-}'"
        log "watchdog: WARNING: initial thermal telemetry unavailable rc=$THERMAL_HELPER_RC output='${THERMAL_LINE:-}'; continuing because only an observed critical state may intervene"
    fi

    echo "$$" > "$WD_READY"
    log "watchdog: armed (temperature every ${WD_THERMAL_POLL}s, critical-only; memory guard=disabled; restarts>=$WD_RESTART_LIMIT/${WD_WINDOW}s; runtime cap=$runtime_cap_label)"
    while :; do
        sleep "$WD_POLL"
        now=$(date +%s)
        if [ "$now" -ge "$next_thermal" ]; then
            next_thermal=$((now + WD_THERMAL_POLL))
            if thermal_snapshot; then
                record_thermal_snapshot "$THERMAL_LINE"
                log "watchdog: thermal sample: $THERMAL_LINE"
                if [ "$THERMAL_STATE" = critical ]; then
                    trip_watchdog "iPadOS 温度状态达到 critical，已停止 macOS GUI"
                    return 0
                fi
            else
                record_thermal_snapshot "unavailable rc=$THERMAL_HELPER_RC output='${THERMAL_LINE:-}'"
                log "watchdog: WARNING: thermal telemetry unavailable rc=$THERMAL_HELPER_RC output='${THERMAL_LINE:-}'; no intervention without an observed critical state"
            fi
        fi

        # Exit only when the GUI was actually torn down (the WindowServer launchd
        # job is unloaded). A momentarily-absent PROCESS just means launchd is
        # relaunching it after a crash — keep guarding (and count it as a restart).
        if ! launchctl list "$WINDOWSERVER_LABEL" >/dev/null 2>&1; then
            if [ "$ws_seen" = 0 ] && [ -n "$startup_owner" ] &&
               kill -0 "$startup_owner" 2>/dev/null; then
                if [ "$startup_wait_logged" = 0 ]; then
                    log "watchdog: thermal guard active while launcher pid=$startup_owner prepares WindowServer."
                    startup_wait_logged=1
                fi
                continue
            fi
            log "watchdog: WindowServer job unloaded (GUI stopped) — exiting."
            return 0
        fi
        ws_seen=1
        pid=$(ws_pid)
        if [ -z "$pid" ] || [ "$pid" = "-" ]; then
            missing_samples=$((missing_samples + 1))
            if [ "$missing_samples" -eq 1 ] || [ "$missing_samples" -eq 3 ]; then
                log "watchdog: WindowServer job is loaded but has no PID; requesting launchd start (sample=$missing_samples)"
                launchctl start "$WINDOWSERVER_LABEL" 2>/dev/null
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
        if [ -n "$pid" ] && [ "$pid" != "-" ]; then
            last_pid="$pid"
            record_ws_pid "$pid" || \
                log "watchdog: WARNING: could not persist WindowServer pid=$pid"
        fi
        now=$(date +%s)
        if [ $((now - t0)) -ge "$WD_WINDOW" ]; then restarts=0; t0=$now; fi
        if [ "$restarts" -ge "$WD_RESTART_LIMIT" ]; then
            trip_watchdog "WindowServer 在 ${WD_WINDOW} 秒内重启 ${restarts} 次，已自动停止"
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

# The executable signature persists across a reboot, but Dopamine's dynamic
# trustcache does not.  Checking only /bin/bash is insufficient for a GUI app:
# runtime-confirmed after the 2026-07-30 reboot, bash and VS Code's main
# executable ran while dyld rejected Electron Framework before libmachook or
# autosignd could execute.  Use that early dependency as a second sentinel.
vscode_bundle_trusted() {
    local hash=""

    # VS Code is optional.  Its absence must not block the generic GUI stack.
    [ -e "$VSCODE_TRUST_SENTINEL" ] || return 0
    hash=$(/var/jb/usr/bin/ldid -arch arm64 -h "$VSCODE_TRUST_SENTINEL" 2>/dev/null |
        /var/jb/usr/bin/grep 'CDHash=' | /var/jb/usr/bin/cut -c8-)
    [ -n "$hash" ] || return 1
    /var/jb/usr/bin/jbctl trustcache info 2>/dev/null |
        /var/jb/usr/bin/grep -Fqi "$hash"
}

# cfprefsd is now a direct outer-launchd target, so autosignd cannot repair it:
# AMFI evaluates the executable before libmachook can connect to autosignd.
# Runtime-confirmed on iPadOS 16.3: the stock Ventura signature is killed with
# "unsuitable CT policy 0x8 for this platform/device" and launchd records exit
# status 9.  Require both the persistent project entitlement marker and the
# current-boot arm64e trustcache entry before any CFPreferences client starts.
macos_cfprefsd_trusted() {
    local binary="$ROOTFS$CFPREFSD_BIN" hash=""
    [ -f "$binary" ] || return 1
    /var/jb/usr/bin/ldid -e "$binary" 2>/dev/null |
        /var/jb/usr/bin/grep -q \
            '<key>com.apple.private.graphics-restart-no-kill</key>' || return 1
    hash=$(/var/jb/usr/bin/ldid -arch arm64e -h "$binary" 2>/dev/null |
        /var/jb/usr/bin/grep 'CDHash=' | /var/jb/usr/bin/cut -c8-)
    [ -n "$hash" ] || return 1
    /var/jb/usr/bin/jbctl trustcache info 2>/dev/null |
        /var/jb/usr/bin/grep -Fqi "$hash"
}

# Repair the same-volume temporary directory contract that Ventura
# CoreFoundation's cfprefsd requires for atomic plist replacement.  The
# mounted macOS /private/var is a distinct filesystem root in this chroot, so
# iPadOS _dirhelper_relative resolves it beneath /private/var/.TemporaryItems.
# LLDB runtime-confirmed all three components and their required modes.  Keep
# this in the production start path as well as postinst so cold starts repair
# an incomplete/restored rootfs before the first preferences client connects.
ensure_cfprefsd_dirhelper_tree() {
    local temporary_root="$ROOTFS/private/var/.TemporaryItems"
    local temporary_user="$temporary_root/folders.0"
    local temporary_leaf="$temporary_user/TemporaryItems"

    mkdir -p "$temporary_leaf" || return 1
    chown root:wheel "$temporary_root" "$temporary_user" "$temporary_leaf" \
        2>/dev/null || true
    chmod 1311 "$temporary_root" || return 1
    chmod 0700 "$temporary_user" "$temporary_leaf" || return 1
}

# Ventura's _locationd account is uid/gid 205 and Darwin dirhelper resolves
# its per-user cache root to this deterministic hash.  Runtime on the target
# reached `CLLocationController` only after the complete 0/C/T hierarchy
# existed; without it locationd exits with "could not create persistent store
# directory" and errno EIO.  Repair only this exact service-owned tree.
ensure_locationd_dirhelper_tree() {
    local location_root="$ROOTFS/var/folders/zz/zyxvpxvq6csfxvn_n00000sm00006d"
    mkdir -p "$location_root/0" "$location_root/C" "$location_root/T" ||
        return 1
    chown -R 205:205 "$location_root" 2>/dev/null || true
    chmod 0700 "$location_root" "$location_root/0" \
        "$location_root/C" "$location_root/T" || return 1
}

# Self-heal both post-reboot failure classes before starting WindowServer.
# One postinst pass restores the base chroot plus every persistent executable
# signature in VS Code's nested frameworks; both witnesses must pass afterward.
ensure_chroot_works() {
    local chroot_ok=0 vscode_ok=0 cfprefs_ok=0

    log "Checking the macOS chroot is runnable..."
    chroot_works && chroot_ok=1
    vscode_bundle_trusted && vscode_ok=1
    macos_cfprefsd_trusted && cfprefs_ok=1
    if [ "$chroot_ok" -eq 1 ] && [ "$vscode_ok" -eq 1 ] &&
       [ "$cfprefs_ok" -eq 1 ]; then
        log "chroot, VS Code, and macOS cfprefsd trust sentinels OK."
        return 0
    fi
    [ "$chroot_ok" -eq 1 ] ||
        log "chroot not runnable (base trustcache is incomplete)."
    [ "$vscode_ok" -eq 1 ] ||
        log "VS Code Electron Framework is not trusted (application trustcache is incomplete)."
    [ "$cfprefs_ok" -eq 1 ] ||
        log "macOS cfprefsd lacks the project signature or current-boot trustcache entry."
    if [ -f "$POSTINST" ]; then
        log "Re-registering trustcaches via postinst.sh (~1 min)..."
        bash "$POSTINST" > "$LOGDIR/postinst.log" 2>&1
        if chroot_works && vscode_bundle_trusted && macos_cfprefsd_trusted; then
            log "chroot, VS Code, and macOS cfprefsd trust sentinels OK after postinst."
            return 0
        fi
    fi
    log "ERROR: chroot or VS Code trust sentinel still fails after postinst — aborting."
    log "       Inspect: $LOGDIR/postinst.log  and  sudo dmesg | grep AMFI"
    return 1
}

# Materialize only the project-owned benchmark profile. The user's normal VS
# Code profile is never read, removed or rewritten. These small authoritative
# files are copied on each GUI start so package upgrades cannot leave an old
# plist, workload URL or extension behind; Chromium caches and session storage
# remain intact for normal warm starts.
prepare_vscode_production_assets() {
    local extension_source="$VSCODE_ASSET_DIR/macwsguide.macws-aquarium-runner-0.0.1"
    local extension_target="$VSCODE_EXTENSIONS_DIR/macwsguide.macws-aquarium-runner-0.0.1"
    local installed_schema="" marker_tmp=""

    [ -d "$ROOTFS/Applications/Visual Studio Code.app" ] || return 0
    if [ ! -f "$VSCODE_PLIST" ] ||
       [ ! -f "$VSCODE_ASSET_DIR/settings.json" ] ||
       [ ! -f "$VSCODE_ASSET_DIR/extensions.json" ] ||
       [ ! -d "$extension_source" ]; then
        log "ERROR: packaged VS Code production assets are incomplete."
        return 1
    fi

    if ! mkdir -p "$VSCODE_PROFILE_DIR/User" "$extension_target" ||
       ! cp "$VSCODE_ASSET_DIR/settings.json" "$VSCODE_PROFILE_DIR/User/settings.json" ||
       ! cp "$VSCODE_ASSET_DIR/extensions.json" "$VSCODE_EXTENSIONS_DIR/extensions.json" ||
       ! cp "$extension_source/package.json" "$extension_target/package.json" ||
       ! cp "$extension_source/extension.js" "$extension_target/extension.js" ||
       ! cp "$extension_source/README.md" "$extension_target/README.md"; then
        log "ERROR: failed to materialize the VS Code production profile."
        return 1
    fi

    # Runtime-confirmed on 2026-08-01: the legacy libraries.data contained
    # air64-apple-ios16.3.0 while a freshly generated cache contained only
    # air64-apple-ios19.0.0-macabi and made every previously failing ANGLE
    # source request return a real _MTLLibrary. cleanup_macos has already
    # stopped every VS Code helper, so invalidating these two exact,
    # regenerable files cannot race an active Metal cache writer.
    [ ! -f "$VSCODE_METAL_CACHE_MARKER" ] ||
        installed_schema=$(sed -n '1p' "$VSCODE_METAL_CACHE_MARKER" 2>/dev/null)
    if [ "$installed_schema" != "$VSCODE_METAL_CACHE_SCHEMA" ]; then
        if ! mkdir -p "$VSCODE_METAL_CACHE_ROOT" ||
           ! rm -f "$VSCODE_METAL_LIBRARY_CACHE/libraries.list" \
                   "$VSCODE_METAL_LIBRARY_CACHE/libraries.data"; then
            log "ERROR: failed to invalidate the incompatible VS Code Metal library cache."
            return 1
        fi
        marker_tmp="$VSCODE_METAL_CACHE_MARKER.$$"
        if ! printf '%s\n' "$VSCODE_METAL_CACHE_SCHEMA" > "$marker_tmp" ||
           ! mv -f "$marker_tmp" "$VSCODE_METAL_CACHE_MARKER"; then
            rm -f "$marker_tmp"
            log "ERROR: failed to commit the VS Code Metal cache schema marker."
            return 1
        fi
        log "VS Code Metal source cache migrated to $VSCODE_METAL_CACHE_SCHEMA."
    fi
    log "VS Code production assets ready (isolated profile=targetfix13)."
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
    <key>POSIXSpawnType</key>
    <string>Interactive</string>
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

    # A normal macOS login bootstrap publishes both CFPreferences services
    # before Dock/Finder start.  Runtime-confirmed on the target: without the
    # macOS agent, Dock creates a LaunchPadDBName and immediately reports that
    # its ByHost domain is non-persistent, so no Launchpad database is created.
    # iPadOS publishes identically named but platform-incompatible endpoints;
    # libmachook maps these private listeners and every chroot client together.
    cat > "$CFPREFSD_DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CFPREFSD_DAEMON_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${CFPREFSD_BIN}</string>
        <string>daemon</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.cfprefsd.daemon</key><true/></dict>
    <key>EnableTransactions</key><true/>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>${LOGDIR}/cfprefsd-daemon.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/cfprefsd-daemon.log</string>
</dict>
</plist>
PLIST

    cat > "$CFPREFSD_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CFPREFSD_AGENT_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${CFPREFSD_BIN}</string>
        <string>agent</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.cfprefsd.agent</key><true/></dict>
    <key>EnableTransactions</key><true/>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>${LOGDIR}/cfprefsd-agent.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/cfprefsd-agent.log</string>
</dict>
</plist>
PLIST

    # Ventura applications use /usr/libexec/lsd, not the legacy
    # launchservicesd endpoint alone.  iPadOS publishes the same com.apple.lsd
    # names in user/501; without isolation the chroot's lsregister runtime-
    # confirmed that it opened iOS's container database (Bundle table = 0).
    # Publish the stock macOS LaunchAgent contract under names that
    # libmachook maps on both the listener and client sides.
    cat > "$LSD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LSD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>/usr/libexec/lsd</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.macosbooter.lsd.advertisingidentifiers</key><true/>
        <key>com.apple.macosbooter.lsd.diagnostics</key><true/>
        <key>com.apple.macosbooter.lsd.dissemination</key><true/>
        <key>com.apple.macosbooter.lsd.encryption</key><true/>
        <key>com.apple.macosbooter.lsd.extensions</key><true/>
        <key>com.apple.macosbooter.lsd.mapdb</key><true/>
        <key>com.apple.macosbooter.lsd.modifydb</key><true/>
        <key>com.apple.macosbooter.lsd.open</key><true/>
        <key>com.apple.macosbooter.lsd.openurl</key><true/>
        <key>com.apple.macosbooter.lsd.personaobserver</key><true/>
        <key>com.apple.macosbooter.lsd.plugin</key><true/>
        <key>com.apple.macosbooter.lsd.trustedsignatures</key><true/>
        <key>com.apple.macosbooter.security.translocation</key><true/>
    </dict>
    <key>EnableTransactions</key><true/>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>${LOGDIR}/lsd.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/lsd.log</string>
</dict>
</plist>
PLIST

    # IconServices is normally split between a system store daemon and a
    # per-login agent.  The chroot has neither launchd domain, while iPadOS
    # publishes incompatible services under the same bootstrap names.  Run
    # the two stock Ventura executables with their stock UID split and publish
    # collision-free names; libmachook maps both listeners and clients.
    cat > "$ICONSERVICESD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${ICONSERVICESD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>240</string><string>240</string>
        <string>${ROOTFS}</string><string>${ICONSERVICESD_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.iconservices.store</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/iconservicesd.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/iconservicesd.log</string>
</dict>
</plist>
PLIST

    cat > "$ICONSERVICESAGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${ICONSERVICESAGENT_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${ICONSERVICESAGENT_BIN}</string>
        <string>runAsRoot</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.iconservices</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/iconservicesagent.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/iconservicesagent.log</string>
</dict>
</plist>
PLIST

    # A macOS Aqua login session normally launches Finder, Dock,
    # SystemUIServer and ControlCenter as per-user LaunchAgents.  The chroot
    # deliberately has no loginwindow domain, so map the stock Ventura agents'
    # executable and Mach-service contracts into the outer launchd domain.
    # These are the real desktop owners: Finder publishes desktop items, Dock
    # owns desktop pictures/Spaces/Launchpad, and the latter two publish the
    # right side of the global menu bar.  Host captures their SkyLight windows;
    # it does not draw substitutes.
    cat > "$FINDER_DESKTOP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${FINDER_DESKTOP_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${FINDER_BIN}</string>
        <string>-ApplePersistenceIgnoreState</string><string>YES</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>EnvironmentVariables</key>
    <dict><key>CA_VSYNC_OFF</key><string>1</string></dict>
    <key>StandardOutPath</key><string>${LOGDIR}/finder-desktop.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/finder-desktop.log</string>
</dict>
</plist>
PLIST

    cat > "$DOCK_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${DOCK_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${DOCK_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.desktoppicture.cache-delete</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.appstore</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.controlcenter</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.downloads</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.fullscreen</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.launchpad</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.notificationcenter</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.ppt</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.remotedesktoppicture</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.server</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.sidecar</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.spaces</key><dict><key>HideUntilCheckIn</key><true/></dict>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict><key>CA_VSYNC_OFF</key><string>1</string></dict>
    <key>StandardOutPath</key><string>${LOGDIR}/dock.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/dock.log</string>
</dict>
</plist>
PLIST

    cat > "$SYSTEMUI_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${SYSTEMUI_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${SYSTEMUI_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.SUISMessaging</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dockextra.server</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dockling.server</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.ipodserver</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.systemuiserver.ServiceProvider</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.systemuiserver.screencapture</key><dict><key>HideUntilCheckIn</key><true/></dict>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict><key>CA_VSYNC_OFF</key><string>1</string></dict>
    <key>StandardOutPath</key><string>${LOGDIR}/systemuiserver.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/systemuiserver.log</string>
</dict>
</plist>
PLIST

    cat > "$CONTROL_CENTER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CONTROL_CENTER_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${CONTROL_CENTER_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.controlcenter</key><true/>
        <key>com.apple.controlcenter.show.toggles</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.usernotifications.delegate.com.apple.controlcenter.notifications.airplay</key><true/>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict><key>CA_VSYNC_OFF</key><string>1</string></dict>
    <key>StandardOutPath</key><string>${LOGDIR}/controlcenter.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/controlcenter.log</string>
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
    <key>POSIXSpawnType</key>
    <string>Interactive</string>
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
    local watchdog_pid="" candidate="" stopped="" deadline="" alive=""
    # A watchdog that trips must finish stop_all() before it exits. Unloading
    # its own launchd job here would terminate it halfway through restoration;
    # SuccessfulExit=false leaves the loaded job dormant after the clean exit.
    # Ordinary start/stop callers unload the job first so no replacement can
    # race their cleanup transaction.
    if [ "$CMD" != watchdog ]; then
        launchctl unload "$WATCHDOG_PLIST" 2>/dev/null
        launchctl remove "$WATCHDOG_LABEL" 2>/dev/null
    fi
    if [ -f "$WD_PIDFILE" ]; then
        watchdog_pid=$(awk 'NR == 1 { print $1 }' "$WD_PIDFILE" 2>/dev/null)
        case "$watchdog_pid" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$watchdog_pid" != "$$" ]; then
                    kill "$watchdog_pid" 2>/dev/null
                    stopped="$stopped $watchdog_pid"
                fi
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
        if [ "$candidate" != "$$" ]; then
            kill "$candidate" 2>/dev/null
            case " $stopped " in
                *" $candidate "*) ;;
                *) stopped="$stopped $candidate" ;;
            esac
        fi
    done

    # TERM is asynchronous. Runtime-confirmed on 2026-08-01: a previous
    # watchdog could still be inside its recovery/cleanup transaction after a
    # new `start` had created the production flags, then remove those new flags
    # and make preflight fail. Wait for the exact PIDs selected above before
    # starting another generation; use a bounded KILL only for those same
    # stale watchdogs, never a broad process-name kill.
    deadline=$(( $(date +%s) + 5 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        alive=""
        for candidate in $stopped; do
            kill -0 "$candidate" 2>/dev/null && alive="$alive $candidate"
        done
        [ -z "$alive" ] && break
        sleep 0.1
    done
    for candidate in $alive; do
        kill -KILL "$candidate" 2>/dev/null
    done
    if [ -n "$alive" ]; then
        deadline=$(( $(date +%s) + 2 ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            stopped=""
            for candidate in $alive; do
                kill -0 "$candidate" 2>/dev/null && stopped="$stopped $candidate"
            done
            [ -z "$stopped" ] && break
            sleep 0.1
        done
    fi
    rm -f "$WD_PIDFILE" "$WD_READY"
    [ "$CMD" = watchdog ] || rm -f "$WD_WS_PIDFILE"
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
        /tmp/macws_app_input_diagnostics \
        /tmp/macws_file_panel_diag \
        /private/tmp/macws_mtl_data_diag \
        /private/tmp/macws_mtl_library_diag \
        /private/tmp/macws_tile_descriptor_diag \
        /tmp/macws_pipeline_diag \
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
        /tmp/macws_video_diag \
        /tmp/macws_vnc_test \
        /private/tmp/macws_xpc_proxy_trace
}

clear_diagnostic_state() {
    local path
    diagnostic_flag_paths | while IFS= read -r path; do
        rm -f "$ROOTFS$path"
    done
    rm -f "$MTLCOMPILER_DIAGNOSTICS" "$MTLCOMPILER_DIAGNOSTICS_NATIVE" \
        "$CATALYST_LAUNCH_TRACE"
    # Request/reply captures are created only by the compiler diagnostic
    # sentinel.  Remove these exact project-owned directories before an
    # ordinary session so neither stale evidence nor bounded binary dumps add
    # filesystem work to production shader compilation.
    rm -rf "$LOGDIR/mtlcompiler_requests" "$LOGDIR/mtlcompiler_replies"

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
        -o -name 'macws_mtl_source_failure_*.metal' \
        -o -name 'macws_mtl_data_*.bin' \
        -o -name 'macws_cached_library_*.bin' \
        -o -name 'macws_compiled_library_*.bin' \
        -o -name 'macws_video_nv12_*.meta' \
        -o -name 'macws_video_nv12_*_p[01].raw' \
        -o -name 'macws_video_texture_*_p[01].raw' \
        -o -name 'macws_video_gpu_sample_*.rgba' \
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
            '"?(MallocScribble|MallocStackLogging|MACWS_RUNTIME_DIAGNOSTICS|MACWS_APP_INPUT_DIAGNOSTICS|MACWS_FILE_PANEL_DIAG|MACWS_SUBMIT_FAST_RING|MACWS_ABORT_TRACE|MACWS_AGX_CRASH_DIAG|MACWS_IOSURF_TRACE|MACWS_JIT_MPROTECT_TRACE|MACWS_MACH_MSG_TRACE|MACWS_VNC_TRACE_CLIENT_MESSAGES|MACWS_XPC_DEBUG)"?[[:space:]]*='; then
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
    if [ -d "$ROOTFS/Applications/Visual Studio Code.app" ]; then
        if [ ! -f "$VSCODE_ANGLE_MACABI_LIBRARY" ] ||
           [ "$(wc -c < "$VSCODE_ANGLE_MACABI_LIBRARY" 2>/dev/null)" != 714152 ]; then
            log "ERROR: exact ANGLE 1ba8ec3 macabi default library is missing or invalid: $VSCODE_ANGLE_MACABI_LIBRARY"
            bad=1
        fi
        for key in MACWS_AGX_NATIVE MACWS_AGX_REGISTER_CLASSES \
                   MACWS_PIN_FALLBACK MACWS_JIT_MPROTECT_COMPAT \
                   MACWS_JIT_FAULT_WRITE_COMPAT \
                   MACWS_AMFI_IMMOVABLE_TASK_PORT_COMPAT \
                   MACWS_MACOS_SYSTEM_POLICY_COMPAT \
                   MACWS_CHROMIUM_COMPOSITE_OVERLAYS; do
            if ! plutil "$VSCODE_PLIST" 2>/dev/null |
                 grep -Eq "\"?$key\"?[[:space:]]*=[[:space:]]*1;"; then
                log "ERROR: required VS Code production environment $key=1 missing from $VSCODE_PLIST"
                bad=1
            fi
        done
        for path in \
            '--user-data-dir=/tmp/macws-vscode-profile-agx-native-targetfix13' \
            '--extensions-dir=/tmp/macws-vscode-extensions' \
            '--use-angle=metal' '--ignore-gpu-blocklist' \
            '--disable-features=SkiaGraphite'; do
            if ! plutil "$VSCODE_PLIST" 2>/dev/null | grep -Fq -- "$path"; then
                log "ERROR: required VS Code production argument missing: $path"
                bad=1
            fi
        done
    fi
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
    for path in "$MTLCOMPILER_DIAGNOSTICS" \
                "$MTLCOMPILER_DIAGNOSTICS_NATIVE"; do
        if [ -e "$path" ]; then
            log "ERROR: iOS MTLCompilerService diagnostic flag survived production cleanup: $path"
            bad=1
        fi
    done
    [ "$bad" = 0 ] || return 1
    log "PRODUCTION-PREFLIGHT: native AGX required; diagnostics/env traces/dump sentinels OFF."
    return 0
}

cleanup_macos() {
    log "Cleaning up previous macOS GUI services..."
    stop_watchdogs
    CLEANUP_TERM_PIDS=""

    # 1) our VNC / Terminal launchd jobs (by plist, then by label as a fallback)
    launchctl unload "$VNC_PLIST"  2>/dev/null
    launchctl unload "$TERM_PLIST" 2>/dev/null
    launchctl unload "$PBOARD_PLIST" 2>/dev/null
    launchctl unload "$PBS_PLIST" 2>/dev/null
    launchctl remove "$VNC_LABEL"  2>/dev/null
    launchctl remove "$TERM_LABEL" 2>/dev/null
    launchctl remove "$PBOARD_LABEL" 2>/dev/null
    launchctl remove "$PBS_LABEL" 2>/dev/null
    launchctl unload "$LSD_PLIST" 2>/dev/null
    launchctl remove "$LSD_LABEL" 2>/dev/null
    launchctl unload "$CFPREFSD_AGENT_PLIST" 2>/dev/null
    launchctl unload "$CFPREFSD_DAEMON_PLIST" 2>/dev/null
    launchctl remove "$CFPREFSD_AGENT_LABEL" 2>/dev/null
    launchctl remove "$CFPREFSD_DAEMON_LABEL" 2>/dev/null
    launchctl unload "$ICONSERVICESAGENT_PLIST" 2>/dev/null
    launchctl unload "$ICONSERVICESD_PLIST" 2>/dev/null
    launchctl remove "$ICONSERVICESAGENT_LABEL" 2>/dev/null
    launchctl remove "$ICONSERVICESD_LABEL" 2>/dev/null
    for workspace_plist in "$FINDER_DESKTOP_PLIST" "$DOCK_PLIST" \
                           "$SYSTEMUI_PLIST" "$CONTROL_CENTER_PLIST"; do
        launchctl unload "$workspace_plist" 2>/dev/null
    done
    for workspace_label in "$FINDER_DESKTOP_LABEL" "$DOCK_LABEL" \
                           "$SYSTEMUI_LABEL" "$CONTROL_CENTER_LABEL"; do
        launchctl remove "$workspace_label" 2>/dev/null
    done

    # inputd blocks in recv(2), so tear its job down explicitly before the
    # broader directory unload and verify no pre-fix binary remains alive.
    launchctl unload "$INPUT_PLIST" 2>/dev/null
    launchctl remove "$INPUT_LABEL" 2>/dev/null
    launchctl unload "$DISPLAY_PLIST" 2>/dev/null
    launchctl remove "$DISPLAY_LABEL" 2>/dev/null
    launchctl unload "$INTEROP_PLIST" 2>/dev/null
    launchctl remove "$INTEROP_LABEL" 2>/dev/null

    # VS Code is launched separately from this script, but it is still a CGS
    # client of this WindowServer.  Runtime-confirmed after the 300-second
    # safety stop: the GUI jobs were gone while Electron and several Code
    # Helper processes retained hundreds of MiB and a dead WS connection.
    # Unload the exact optional job whenever its owning GUI stack is torn down.
    launchctl unload "$VSCODE_PLIST" 2>/dev/null
    launchctl remove "$VSCODE_LABEL" 2>/dev/null

    # These are on-demand Ventura services outside the auto-scanned daemon
    # directory. Unload exact jobs; killing `locationd` by process name would
    # also terminate iPadOS's native location daemon.
    launchctl unload "$CORELOCATIONAGENT_PLIST" 2>/dev/null
    launchctl remove "$CORELOCATIONAGENT_LABEL" 2>/dev/null
    launchctl unload "$LOCATIONBRIDGE_PLIST" 2>/dev/null
    launchctl remove "$LOCATIONBRIDGE_LABEL" 2>/dev/null
    launchctl unload "$MACOS_LOCATIOND_PLIST" 2>/dev/null
    launchctl remove "$MACOS_LOCATIOND_LABEL" 2>/dev/null

    # 2) stray GUI clients (Terminal, VNC, Activity Monitor, ...)
    kill_by_pattern "$P_OSXVNC"
    kill_by_pattern "$P_TERMINAL"
    kill_by_pattern "$P_PBOARD"
    kill_by_pattern "$P_PBS"
    kill_by_pattern "$P_ACTIVITYMON"
    kill_by_pattern "$P_GLASSDEMO"
    kill_by_pattern "$P_FINDER"
    kill_by_pattern "$P_DOCK"
    kill_by_pattern "$P_SYSTEMUI"
    kill_by_pattern "$P_CONTROL_CENTER"
    kill_by_pattern "$P_ICONSERVICESAGENT"
    kill_by_pattern "$P_ICONSERVICESD"
    kill_by_pattern "$P_INPUTD"
    kill_by_pattern "$P_DISPLAYD"
    kill_by_pattern "$P_INTEROPD"
    kill_by_pattern "$P_VSCODE"
    rm -f "$ROOTFS"/private/tmp/macws_app_input.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_window_metrics.*.bin
    rm -f "$ROOTFS"/private/tmp/macws_menu_client.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_menu_snapshot.*.bin
    rm -f "$ROOTFS"/private/tmp/macws_input_target.sock

    # 3) WindowServer and the macOS service daemons loaded with it
    launchctl unload "$MACOS_DAEMONS" 2>/dev/null

    # 4) anything still lingering
    kill_by_pattern "$P_WINDOWSERVER"
    kill_by_pattern "$P_LAUNCHSERVICESD"
    kill_by_pattern "$P_SYSTEMSTATUSD"
    kill_by_pattern "$P_FONTD"
    finish_pattern_cleanup

    clear_diagnostic_state

    # The mmap is a producer-owned WindowServer artifact, not persistent
    # session state.  Keeping it after the producer exits lets a fresh OSXvnc
    # process advertise pixels from an earlier application even when the new
    # WindowServer has not published a frame.  Remove it only after every old
    # producer/client has been stopped so no live mapping is invalidated.
    rm -f "$VNC_SHARED_FRAME" "$VNC_SHARED_SURFID" "$VNC_ACTIVITY" \
        "$INTERACTION_WAKE" "$VNC_ACTIVATION_REPLY" \
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

seed_launchservices_database() {
    if [ ! -x "$ROOTFS$LSREGISTER_BIN" ]; then
        log "ERROR: stock macOS lsregister is missing at $LSREGISTER_BIN"
        return 1
    fi
    rm -f "$LOGDIR/lsregister.log"
    log "Registering the real macOS system/local/user application catalog..."
    if ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$LSREGISTER_BIN" \
            -f -apps system,local,user > "$LOGDIR/lsregister.log" 2>&1; then
        log "ERROR: LaunchServices application scan failed."
        tail -n 20 "$LOGDIR/lsregister.log" 2>/dev/null || true
        return 1
    fi
    # Appearance.appex is system-level ExtensionKit content, not embedded in
    # System Settings.app.  The normal application scan can therefore leave
    # its old PlugInKit record at Container state -1 after a cold database
    # rebuild.  Use Ventura LaunchServices' own plug-in registrar and require
    # an exact platform-1 record before publishing the settings services.
    rm -f "$SETTINGS_EXTENSION_REGISTER_LOG"
    if ! MACWS_CATALOG_REGISTRATION=1 \
            "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
            register-settings-extension \
            > "$SETTINGS_EXTENSION_REGISTER_LOG" 2>&1; then
        log "ERROR: System Settings extension registration failed."
        tail -n 20 "$SETTINGS_EXTENSION_REGISTER_LOG" 2>/dev/null || true
        return 1
    fi
    log "LaunchServices application catalog ready."
}

prepare_settings_service_proxies() {
    local proxy=""
    # These freestanding iOS first images chroot before libSystem consumes
    # launchd's one-shot context.  Package postinst establishes this invariant,
    # but an incremental developer copy can replace a file and silently clear
    # its setuid bit.  Reassert the exact owner/mode before publishing any
    # service so cold production starts cannot regress to Connection Invalid.
    for proxy in \
        /var/jb/usr/macOS/Frameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc/ViewBridgeAuxiliary \
        /var/jb/usr/macOS/Frameworks/HIServices.framework/Versions/A/XPCServices/HIServicesProxy.xpc/HIServicesProxy \
        /var/jb/usr/macOS/Frameworks/AppKit.framework/Versions/C/XPCServices/OpenAndSavePanelProxy.xpc/OpenAndSavePanelProxy \
        /var/jb/usr/macOS/Frameworks/ExtensionFoundation.framework/Versions/A/XPCServices/ExtensionKitProxy.xpc/ExtensionKitProxy \
        /var/jb/usr/macOS/PrivateFrameworks/GeoServices.framework/Versions/A/XPCServices/GeodProxy.xpc/GeodProxy \
        /var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy; do
        if [ ! -x "$proxy" ]; then
            log "ERROR: required macOS service proxy is missing: $proxy"
            return 1
        fi
        chown root:wheel "$proxy" || return 1
        chmod 4755 "$proxy" || return 1
    done

    # ExtensionKit resolves the Ventura Appearance.appex through the iOS
    # RunningBoard carrier.  A valid macOS PlugInKit record alone is not
    # sufficient: runtime on 2026-08-04 reproduced an ordered-in but empty
    # System Settings shell while this carrier was absent from iOS
    # LaunchServices.  Make the carrier registration a startup invariant, not
    # a best-effort postinst side effect.
    if [ ! -x "$UICACHE" ]; then
        log "ERROR: uicache is missing; cannot verify the Settings extension carrier."
        return 1
    fi
    if ! "$UICACHE" -l 2>/dev/null | grep -Fq \
            "$SETTINGS_EXTENSION_CARRIER_ID : "; then
        log "Registering the iOS System Settings extension carrier..."
        "$UICACHE" -p "$SETTINGS_EXTENSION_CARRIER_APP" \
            >/dev/null 2>&1 || return 1
    fi
    if ! "$UICACHE" -l 2>/dev/null | grep -Fq \
            "$SETTINGS_EXTENSION_CARRIER_ID : "; then
        log "ERROR: System Settings extension carrier is not registered in iOS LaunchServices."
        return 1
    fi
    log "System Settings extension carrier registration ready."
}

publish_settings_service_contracts() {
    local plist="" label=""
    prepare_settings_service_proxies || return 1
    for plist in "$VIEWBRIDGE_PLIST" "$EXTENSIONKIT_PLIST" \
                 "$HISERVICES_PLIST" "$GEOD_PLIST"; do
        if [ ! -f "$plist" ]; then
            log "ERROR: required macOS service job is missing: $plist"
            return 1
        fi
        launchctl load "$plist" || return 1
    done
    for label in "$VIEWBRIDGE_LABEL" "$EXTENSIONKIT_LABEL" \
                 "$HISERVICES_LABEL" "$GEOD_LABEL"; do
        launchctl list "$label" >/dev/null 2>&1 || {
            log "ERROR: private macOS service contract was not registered: $label"
            return 1
        }
    done
    log "Private macOS ViewBridge, ExtensionKit, HIServices and GeoServices contracts ready."
}

verify_preferences_persistence() {
    local value=""
    rm -f "$LOGDIR/cfprefsd-probe.log"
    if ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" write \
            com.macwsguide.bootstrap PersistentPreferencesReady -bool true \
            > "$LOGDIR/cfprefsd-probe.log" 2>&1; then
        log "ERROR: private macOS CFPreferences write failed."
        tail -n 20 "$LOGDIR/cfprefsd-probe.log" 2>/dev/null || true
        return 1
    fi
    value=$("$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" read \
        com.macwsguide.bootstrap PersistentPreferencesReady 2>> \
        "$LOGDIR/cfprefsd-probe.log") || value=""
    if [ "$value" != 1 ]; then
        log "ERROR: private macOS CFPreferences domain is not persistent (read='$value')."
        tail -n 20 "$LOGDIR/cfprefsd-probe.log" 2>/dev/null || true
        return 1
    fi
    log "Private macOS CFPreferences database ready."
}

apply_workspace_wallpaper() {
    if [ ! -x "$ROOTFS$WORKSPACECTL_BIN" ]; then
        log "ERROR: native workspace controller is missing at $WORKSPACECTL_BIN"
        return 1
    fi
    rm -f "$LOGDIR/workspace-controller.log"
    if ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
            set-wallpaper "$WORKSPACE_WALLPAPER" \
            > "$LOGDIR/workspace-controller.log" 2>&1; then
        log "ERROR: the real macOS desktop wallpaper could not be applied."
        tail -n 20 "$LOGDIR/workspace-controller.log" 2>/dev/null || true
        return 1
    fi
    log "Native macOS desktop wallpaper ready."
}

toggle_native_launchpad() {
    [ -x "$ROOTFS$WORKSPACECTL_BIN" ] || {
        log "ERROR: native workspace controller is missing at $WORKSPACECTL_BIN"
        return 1
    }
    proc_running "$P_WINDOWSERVER" && proc_running "$P_DOCK" || {
        log "ERROR: Launchpad requires a running WindowServer and Dock."
        return 1
    }
    "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" show-launchpad
}

start_macos() {
    local ws_log_start_line=1 waited=0
    if [ -f "$LOGDIR/WindowServer.err" ]; then
        ws_log_start_line=$(( $(wc -l < "$LOGDIR/WindowServer.err") + 1 ))
    fi
    # SystemStatus clients immediately enumerate and register every subscribed
    # domain. Runtime sampling showed that starting WindowServer before
    # the private macOS SystemStatus endpoints exist leaves several NSXPC
    # queues serializing registrations to a disconnected endpoint. Register
    # and prove the stock macOS daemon under its collision-free private names
    # first; this is dependency ordering, not a client bypass.
    log "Starting macOS systemstatusd before WindowServer clients..."
    rm -f "$LOGDIR/systemstatusd.out" "$LOGDIR/systemstatusd.err"
    launchctl load "$SYSTEMSTATUSD_PLIST" || return 1
    waited=0
    while ! proc_running "$P_SYSTEMSTATUSD" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_SYSTEMSTATUSD" || {
        log "ERROR: macOS systemstatusd did not start. See $LOGDIR/systemstatusd.err"
        return 1
    }

    # AppKit normally obtains its shared XType registry from the per-login
    # com.apple.fonts service. The chroot has no loginwindow/LaunchAgent
    # bootstrap, so every cold GUI application falls back to rebuilding a
    # static registry in-process. Runtime timestamps on the target showed
    # Terminal spending 2.685 seconds between that fallback message and its
    # first NSWindow. Start the stock macOS fontd under the chroot launcher and
    # publish its original Mach services before any GUI application starts.
    log "Starting macOS shared font registry service..."
    rm -f "$LOGDIR/fontd.log"
    launchctl load "$FONTD_PLIST" || return 1
    waited=0
    while ! proc_running "$P_FONTD" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_FONTD" || {
        log "ERROR: macOS fontd did not start. See $LOGDIR/fontd.log"
        return 1
    }

    log "Publishing private macOS CFPreferences daemon and login agent..."
    ensure_cfprefsd_dirhelper_tree || {
        log "ERROR: could not prepare the CFPreferences atomic-write hierarchy."
        return 1
    }
    rm -f "$LOGDIR/cfprefsd-daemon.log" "$LOGDIR/cfprefsd-agent.log"
    launchctl load "$CFPREFSD_DAEMON_PLIST" || return 1
    launchctl load "$CFPREFSD_AGENT_PLIST" || return 1
    launchctl list "$CFPREFSD_DAEMON_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private macOS cfprefsd daemon contract was not registered."
        return 1
    }
    launchctl list "$CFPREFSD_AGENT_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private macOS cfprefsd agent contract was not registered."
        return 1
    }
    verify_preferences_persistence || return 1

    log "Publishing the private macOS LaunchServices database services..."
    rm -f "$LOGDIR/lsd.log"
    launchctl load "$LSD_PLIST" || return 1
    launchctl list "$LSD_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private macOS lsd MachService contract was not registered."
        return 1
    }

    # Register the stock IconServices store and root-session agent before
    # lsregister asks LaunchServices to resolve application resources.  Merely
    # leaving these services to the iOS bootstrap namespace produced an empty
    # Launchpad and transparent Dock tiles; clients were speaking to the wrong
    # platform contract.  Both processes must remain alive, not merely have a
    # launchd label, before the application catalog scan begins.
    log "Starting private macOS IconServices store and session agent..."
    rm -f "$LOGDIR/iconservicesd.log" "$LOGDIR/iconservicesagent.log"
    launchctl load "$ICONSERVICESD_PLIST" || return 1
    launchctl load "$ICONSERVICESAGENT_PLIST" || return 1
    waited=0
    while [ "$waited" -lt 10 ]; do
        proc_running "$P_ICONSERVICESD" &&
            proc_running "$P_ICONSERVICESAGENT" && break
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_ICONSERVICESD" || {
        log "ERROR: macOS iconservicesd did not stay alive. See $LOGDIR/iconservicesd.log"
        return 1
    }
    proc_running "$P_ICONSERVICESAGENT" || {
        log "ERROR: macOS iconservicesagent did not stay alive. See $LOGDIR/iconservicesagent.log"
        return 1
    }
    # The former quarantine failure happened after the process was briefly
    # visible, so a single ps sample falsely declared readiness.  Require the
    # same two endpoints to survive beyond that startup window.
    sleep 2
    proc_running "$P_ICONSERVICESD" && proc_running "$P_ICONSERVICESAGENT" || {
        log "ERROR: a macOS IconServices endpoint exited during startup."
        tail -n 20 "$LOGDIR/iconservicesagent.log" 2>/dev/null || true
        return 1
    }
    log "Private macOS IconServices endpoints ready."

    seed_launchservices_database || return 1

    # System Settings' first visible pane is a stock ExtensionKit scene.  Its
    # host synchronously resolves ViewBridgeAuxiliary and HIServices before
    # Appearance is launched, so all three collision-free service contracts
    # must exist before any GUI application can enter that dependency chain.
    log "Publishing macOS ViewBridge, ExtensionKit and HIServices services..."
    publish_settings_service_contracts || return 1

    log "Loading legacy macOS launchservicesd, input bridge, and WindowServer..."
    launchctl load "$LAUNCHSERVICESD_PLIST" || return 1
    launchctl load "$INPUT_PLIST" || return 1
    launchctl load "$WINDOWSERVER_PLIST" || return 1
    log "Waiting for WindowServer graphics initialization before GUI clients..."
    wait_for_initial_ws_ready "$ws_log_start_line" || return 1

    # Maps uses Ventura CoreLocationAgent and the four Ventura desktop
    # locationd protocols.  iPadOS publishes colliding but wire-incompatible
    # services; libmachook maps the stock macOS peers together under private
    # names.  Publish the on-demand jobs only after both LaunchServices and
    # WindowServer are ready because CoreLocationAgent is an AppKit process.
    log "Publishing private Ventura CoreLocation services..."
    ensure_locationd_dirhelper_tree || {
        log "ERROR: could not prepare Ventura locationd's uid-205 cache tree."
        return 1
    }
    [ -f "$MACOS_LOCATIOND_PLIST" ] &&
        [ -f "$CORELOCATIONAGENT_PLIST" ] &&
        [ -f "$LOCATIONBRIDGE_PLIST" ] || {
        log "ERROR: packaged Ventura CoreLocation launch contracts are missing."
        return 1
    }
    rm -f "$LOGDIR/macos-locationd.log" "$LOGDIR/corelocationagent.log" \
          "$LOGDIR/macwslocationd.log"
    launchctl load "$MACOS_LOCATIOND_PLIST" || return 1
    launchctl load "$CORELOCATIONAGENT_PLIST" || return 1
    launchctl list "$MACOS_LOCATIOND_LABEL" >/dev/null 2>&1 || {
        log "ERROR: Ventura locationd contract was not registered."
        return 1
    }
    launchctl list "$CORELOCATIONAGENT_LABEL" >/dev/null 2>&1 || {
        log "ERROR: CoreLocationAgent contract was not registered."
        return 1
    }
    log "Private Ventura CoreLocation contracts ready."

    log "Starting DisplayStream IOSurface bridge..."
    launchctl load "$DISPLAY_PLIST" || return 1

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

    log "Starting iOS/macOS clipboard and file bridge..."
    launchctl load "$INTEROP_PLIST" || return 1

    # CLLocation's private keyed archive differs between iPadOS 16 and
    # Ventura 13.  The native producer therefore sends validated scalar fields
    # to macwsinteropd, which reconstructs the object with Ventura CoreLocation.
    # Publish the native producer only after interopd owns its Mach service.
    log "Starting native-to-Ventura location provider bridge..."
    launchctl load "$LOCATIONBRIDGE_PLIST" || return 1
    launchctl list "$LOCATIONBRIDGE_LABEL" >/dev/null 2>&1 || {
        log "ERROR: native-to-Ventura location bridge did not start."
        return 1
    }
    log "Native-to-Ventura location provider bridge ready."

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

    log "Starting the real macOS Aqua workspace agents (Finder, Dock, SystemUIServer, ControlCenter)..."
    for workspace_log in finder-desktop dock systemuiserver controlcenter; do
        rm -f "$LOGDIR/$workspace_log.log"
    done
    if ! proc_running "$P_FINDER"; then
        launchctl load "$FINDER_DESKTOP_PLIST" || return 1
    else
        log "Finder desktop owner is already running; preserving the single instance."
    fi
    launchctl load "$DOCK_PLIST" || return 1
    launchctl load "$SYSTEMUI_PLIST" || return 1
    launchctl load "$CONTROL_CENTER_PLIST" || return 1
    waited=0
    while [ "$waited" -lt 15 ]; do
        proc_running "$P_FINDER" && proc_running "$P_DOCK" &&
            proc_running "$P_SYSTEMUI" && proc_running "$P_CONTROL_CENTER" && break
        sleep 1
        waited=$((waited + 1))
    done
    for workspace_spec in \
        "Finder:$P_FINDER:finder-desktop.log" \
        "Dock:$P_DOCK:dock.log" \
        "SystemUIServer:$P_SYSTEMUI:systemuiserver.log" \
        "ControlCenter:$P_CONTROL_CENTER:controlcenter.log"; do
        workspace_name=${workspace_spec%%:*}
        workspace_rest=${workspace_spec#*:}
        workspace_pattern=${workspace_rest%%:*}
        workspace_log=${workspace_rest#*:}
        if proc_running "$workspace_pattern"; then
            log "$workspace_name workspace agent ready."
        else
            log "ERROR: $workspace_name did not reach a live process. See $LOGDIR/$workspace_log"
            return 1
        fi
    done
    apply_workspace_wallpaper || return 1

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
    if [ -f "$WD_THERMAL_SNAPSHOT" ]; then
        echo "thermal   : $(awk 'NR == 1 { print; exit }' "$WD_THERMAL_SNAPSHOT" 2>/dev/null)"
    else
        echo "thermal   : not sampled (watchdog is stopped or has not armed yet)"
    fi
    echo "memory    : guard disabled (managed by iOS/XNU memorystatus)"
    if [ -e "$FLAG" ]; then
        echo "mode flag : present  -> COEXISTENCE (panel = iOS, macOS = VNC)"
    else
        echo "mode flag : absent   -> EXCLUSIVE (macOS owns the panel) / or stopped"
    fi
    echo
    echo "-- processes --"
    ps aux | grep -iE "$P_WINDOWSERVER|$P_OSXVNC|$P_TERMINAL|$P_LAUNCHSERVICESD|$P_SYSTEMSTATUSD|$P_FONTD|$P_PBOARD|$P_PBS|$P_FINDER|$P_DOCK|$P_SYSTEMUI|$P_CONTROL_CENTER" \
        | grep -v grep || echo "(none running)"
    echo
    echo "-- launchd jobs --"
    launchctl list 2>/dev/null | grep -iE "WindowServer|launchservices|systemstatus|macwsguide" \
        || echo "(none loaded)"
    echo
    if proc_running "$P_OSXVNC"; then
        echo "VNC: running -> connect with  vnc://<device-ip>:5900   (no password)"
    else
        echo "VNC: not running"
    fi
    echo
    echo "logs: $LOGDIR/osxvnc.log  $LOGDIR/terminal.log  $LOGDIR/lsd.log  $LOGDIR/dock.log  $LOGDIR/systemuiserver.log  $LOGDIR/controlcenter.log  $LOGDIR/WindowServer.err"
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
  sudo bash $0 start [coexist|exclusive] [--no-experimental] [--diagnostics] [--pace-us=N] [--runtime-cap=SECONDS] [--no-terminal] [--no-vnc]
  sudo bash $0 switches
  sudo bash $0 guard [coexist|exclusive] [...]  # re-arm only; no GUI restart
  sudo bash $0 launchpad
  sudo bash $0 stop
  sudo bash $0 restart [coexist|exclusive] [...]
  sudo bash $0 status

Modes:
  coexist     (default) iPad panel keeps showing iOS; macOS renders to VNC only.
  exclusive   macOS takes over the physical panel as well as VNC.

Safety: start launches a mandatory launchd-backed iOS-native health watchdog
before the GUI. If the guard is killed abnormally, launchd restarts it and its
persisted WindowServer generation reconnects stale GUI bridges.
It records a startup snapshot, samples temperature every five minutes, and
stops for thermal reasons only when iPadOS explicitly reports critical.
Nominal/fair/serious states, numeric temperatures, and unreadable samples are
logged without intervention. The former free-memory percentage guard is
disabled; iOS/XNU memorystatus owns cache reclamation and memory pressure.
Crash-loop and explicit runtime-cap guards remain separate. The watchdog
cannot be disabled. Logs to
$LOGDIR/macos_gui_watchdog.log.

The production profile enables native AGX and its required command/completion
compatibility adapters by default. High-overhead flight recorders and read-only
method tracing remain off unless --diagnostics is explicitly present. Use
--no-experimental only for an intentional control experiment. Interactive
sessions have no arbitrary wall-clock timeout, while
thermal/crash-loop protection stays armed. Automated runs may add
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
        --no-watchdog)
            echo "macos_gui.sh: --no-watchdog was removed; thermal safety cannot be disabled" >&2
            exit 64
            ;;
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
        "$EXPERIMENTAL_OBSERVE_PF550" "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS" \
        "$MTLCOMPILER_DIAGNOSTICS"
    if [ "$WANT_DIAGNOSTICS" = 1 ]; then
        touch "$EXPERIMENTAL_COMMAND_ERROR" \
            "$EXPERIMENTAL_FAST_SUBMIT_RING" \
            "$EXPERIMENTAL_OBSERVE_PF550" \
            "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS" \
            "$MTLCOMPILER_DIAGNOSTICS"
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

# Write the exact launch intent into a script-owned launchd job. The job is not
# installed in an auto-scanned daemon directory, so it exists only for an
# explicitly started MacWS session. `SuccessfulExit=false` restarts it after a
# signal/jetsam death, while a deliberate clean exit remains stopped.
write_watchdog_plist() {
    local startup_owner="$1"
    shift
    {
        cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${WATCHDOG_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/var/jb/usr/bin/bash</string>
        <string>$0</string>
PLIST
        for watchdog_arg in "$@"; do
            # All values reaching this helper are constrained enum/numeric
            # command-line options, so none can contain XML metacharacters.
            printf '        <string>%s</string>\n' "$watchdog_arg"
        done
        cat <<PLIST
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MACWS_WATCHDOG_STARTUP_OWNER</key>
        <string>${startup_owner}</string>
        <!-- launchd does not supply the interactive rootless Procursus PATH. -->
        <key>PATH</key>
        <string>/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Background</string>
    <key>ThrottleInterval</key><integer>2</integer>
    <key>StandardOutPath</key><string>${WD_LOG}</string>
    <key>StandardErrorPath</key><string>${WD_LOG}</string>
</dict>
</plist>
PLIST
    } > "$WATCHDOG_PLIST"
}

# Launch the mandatory thermal/crash-loop watchdog as an iOS-side launchd job
# and wait for its independent temperature-sensor handshake before returning.
start_watchdog() {
    local child="" ready_owner="" waited=0
    stop_watchdogs
    rm -f "$WD_LOG" "$WD_TRIP" "$WD_READY" "$WD_THERMAL_SNAPSHOT" \
        "$WD_WS_PIDFILE" "$LOGDIR/macos_gui_memory_snapshot"
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
    write_watchdog_plist "$$" "$@" || return 1
    if ! launchctl load "$WATCHDOG_PLIST"; then
        log "ERROR: mandatory health watchdog launchd job failed to load."
        return 1
    fi
    while [ "$waited" -lt 10 ]; do
        child=$(launchd_job_pid "$WATCHDOG_LABEL")
        ready_owner=$(awk 'NR == 1 { print $1 }' "$WD_READY" 2>/dev/null)
        if [ -n "$child" ] && [ "$child" != "-" ] &&
           [ "$ready_owner" = "$child" ]; then
            log "watchdog: launchd-backed health guard ready (pid=$child; temperature=${WD_THERMAL_POLL}s critical-only; memory guard=disabled; log=$WD_LOG)."
            return 0
        fi
        if [ -f "$WD_TRIP" ]; then
            log "ERROR: mandatory health watchdog failed to arm."
            [ -f "$WD_TRIP" ] && sed 's/^/[macos_gui]        /' "$WD_TRIP"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log "ERROR: mandatory health watchdog did not acknowledge within 10 seconds."
    return 1
}

case "$CMD" in
    start)
        require_root "$@"
        write_plists || { log "ERROR: failed to write GUI launch plists."; exit 1; }
        cleanup_macos
        prepare_vscode_production_assets || { stop_all; exit 1; }
        enable_experimental_if_requested
        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_DIAGNOSTICS" != 1 ]; then
            production_preflight || { stop_all; exit 1; }
        fi
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        start_watchdog || { stop_all; exit 1; }
        ensure_chroot_works || { stop_all; exit 1; }
        start_macos || { stop_all; exit 1; }
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
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
        write_plists || { log "ERROR: failed to write GUI launch plists."; exit 1; }
        stop_all
        prepare_vscode_production_assets || { stop_all; exit 1; }
        enable_experimental_if_requested
        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_DIAGNOSTICS" != 1 ]; then
            production_preflight || { stop_all; exit 1; }
        fi
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        start_watchdog || { stop_all; exit 1; }
        ensure_chroot_works || { stop_all; exit 1; }
        start_macos || { stop_all; exit 1; }
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
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
    guard)
        # Low-impact recovery/testing entry point: arm the mandatory guard for
        # an already-running GUI session without restarting WindowServer or
        # any client. Ordinary users get the same path automatically via start.
        require_root "$@"
        mkdir -p "$GUI_LAUNCHD_DIR"
        start_watchdog
        ;;
    launchpad)
        require_root "$@"
        toggle_native_launchpad
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
