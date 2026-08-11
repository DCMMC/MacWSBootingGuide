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
OFFICE_LICENSING_PLIST="$MACOS_DAEMONS/com.macwsguide.office-licensing.plist"
CHROOTEXEC=/var/jb/usr/macOS/bin/launchdchrootexec
RUN_BASH=/var/jb/usr/macOS/bin/run_bash.sh
POSTINST=/var/jb/usr/macOS/bin/postinst.sh
QUARTZCORE_COMPAT_PROVISIONER=/var/jb/usr/macOS/bin/ensure_quartzcore_compat.sh
THERMAL_HELPER=/var/jb/usr/macOS/bin/macwsthermal
LOGDIR=/var/jb/var/mobile
TEST_LEASE="$LOGDIR/macws_test_lease"
GUI_TRANSACTION_LOCK="$LOGDIR/.macos_gui.transaction"
GUI_TRANSACTION_PID="$GUI_TRANSACTION_LOCK/pid"
GUI_START_STATE="$LOGDIR/macos_gui_start.state"
GUI_TRANSACTION_HELD=0
GUI_TRANSACTION_STARTED=0

GUI_LAUNCHD_DIR=/var/jb/usr/macOS/gui-launchd   # script-owned; NOT auto-scanned at boot
WATCHDOG_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.watchdog.plist"
VSCODE_ASSET_DIR=/var/jb/usr/macOS/share/vscode
VNC_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.osxvnc.plist"
TERM_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.terminal.plist"
PBOARD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.pboard.plist"
PBS_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.pbs.plist"
LSD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.lsd.plist"
LSD_SYSTEM_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.lsd-system.plist"
CFPREFSD_DAEMON_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.cfprefsd-daemon.plist"
CFPREFSD_AGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.cfprefsd-agent.plist"
MACOS_LOCATIOND_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.macos-locationd.plist"
CORELOCATIONAGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.corelocationagent.plist"
LOCATIONBRIDGE_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.locationbridge.plist"
ICONSERVICESD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.iconservicesd.plist"
ICONSERVICESAGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.iconservicesagent.plist"
CSNAMEDDATAD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.csnameddatad.plist"
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
LSD_SYSTEM_LABEL=com.macwsguide.lsd-system
CFPREFSD_DAEMON_LABEL=com.macwsguide.cfprefsd-daemon
CFPREFSD_AGENT_LABEL=com.macwsguide.cfprefsd-agent
MACOS_LOCATIOND_LABEL=com.macwsguide.macos-locationd
CORELOCATIONAGENT_LABEL=com.macwsguide.corelocationagent
LOCATIONBRIDGE_LABEL=com.macwsguide.locationbridge
ICONSERVICESD_LABEL=com.macwsguide.iconservicesd
ICONSERVICESAGENT_LABEL=com.macwsguide.iconservicesagent
CSNAMEDDATAD_LABEL=com.macwsguide.csnameddatad
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
OFFICE_LICENSING_LABEL=com.macwsguide.office-licensing
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
EXPERIMENTAL_IOGPU_ERROR="$ROOTFS/private/tmp/macws_iogpu_error_diag"
EXPERIMENTAL_PIPELINE_DIAG="$ROOTFS/private/tmp/macws_pipeline_diag"
EXPERIMENTAL_COMPLETION="$ROOTFS/private/tmp/macws_cancel_completion"
EXPERIMENTAL_VNC_SHARE="$ROOTFS/private/tmp/macws_vnc_share"
EXPERIMENTAL_OBSERVE_PF550="$ROOTFS/private/tmp/macws_observe_pf550"
EXPERIMENTAL_SUBMIT_RING="$ROOTFS/private/tmp/macws_submit_ring"
EXPERIMENTAL_FAST_SUBMIT_RING="$ROOTFS/private/tmp/macws_submit_fast_ring"
EXPERIMENTAL_RUNTIME_DIAGNOSTICS="$ROOTFS/private/tmp/macws_runtime_diagnostics"
MTLCOMPILER_DIAGNOSTICS="$LOGDIR/macws_mtlcompiler_diagnostics"
MTLCOMPILER_DIAGNOSTICS_NATIVE=/var/mobile/macws_mtlcompiler_diagnostics
CATALYST_LAUNCH_TRACE="$LOGDIR/macws_catalyst_launch.trace"
MAPS_HOST_CARRIER_MARKER="$LOGDIR/macws-maps-host-carrier.pid"
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
LOCATION_PROVIDER_READY="$ROOTFS/private/tmp/macws_location_provider_ready"
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
OFFICE_LICENSING_BIN=/Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper
ICONSERVICESD_BIN=/System/Library/CoreServices/iconservicesd
ICONSERVICESAGENT_BIN=/System/Library/CoreServices/iconservicesagent
CSNAMEDDATAD_BIN=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/CarbonCore.framework/Versions/A/XPCServices/csnameddatad.xpc/Contents/MacOS/csnameddatad
CSNAMEDDATA_PROXY=/var/jb/usr/macOS/Frameworks/HIServices.framework/Versions/A/XPCServices/HIServicesProxy.xpc/HIServicesProxy
DOCK_HELPER_PROXY=/var/jb/usr/macOS/Frameworks/Dock.framework/Versions/A/XPCServices/DockHelperProxy.xpc/DockHelperProxy
# Never launch Ventura's stock cfprefsd image directly.  iPadOS AMFI rejects
# its Apple CT policy, while the project's broad chroot entitlement profile
# gives it com.apple.security.system-container and makes sandbox_init kill it.
# postinst creates this byte-identical private copy with the dedicated minimal
# cfprefsd entitlement profile that was runtime-validated on iPadOS 16.3.
CFPREFSD_BIN=/usr/local/libexec/macws-cfprefsd
DEFAULTS_BIN=/usr/bin/defaults
LSREGISTER_BIN=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WORKSPACECTL_BIN=/usr/local/bin/macwsworkspacectl
LAUNCHSERVICES_CATALOG_SCHEMA=macws-launchservices-catalog-v2
LAUNCHSERVICES_CATALOG_MARKER="$ROOTFS/var/db/macws/launchservices-catalog.ready"
LSD_SESSION_USER_DIR=/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/0/macws-lsd-session/
LAUNCHSERVICES_VERIFY_LOG="$LOGDIR/launchservices-catalog-verify.log"
SETTINGS_EXTENSION_REGISTER_LOG="$LOGDIR/settings-extension-register.log"
SETTINGS_EXTENSIONS_RUNTIME=/var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh
SETTINGS_EXTENSIONS_RUNTIME_LOG="$LOGDIR/settings-extensions-runtime.log"
WORKSPACE_WALLPAPER='/usr/local/share/macws/wallpapers/macws-forest-lake.png'
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
P_MAPS='/System/Applications/Maps.app/Contents/MacOS/Maps'
P_FINDER='CoreServices/Finder.app/Contents/MacOS/Finder'
P_DOCK='CoreServices/Dock.app/Contents/MacOS/Dock'
P_SYSTEMUI='CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer'
P_CONTROL_CENTER='CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter'
P_OFFICE_LICENSING='PrivilegedHelperTools/com.microsoft.office.licensingV2.helper'
P_ICONSERVICESD='CoreServices/iconservicesd'
P_ICONSERVICESAGENT='CoreServices/iconservicesagent'
P_CSNAMEDDATAD='XPCServices/csnameddatad.xpc/Contents/MacOS/csnameddatad'
P_DOCK_HELPER='XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper'
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
    start|restart|stop|production)
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

# `start`, `restart`, and `stop` mutate the same outer-launchd contracts. A
# second control-centre tap used to enter cleanup while the first invocation
# was still publishing services, leaving a plausible-looking half stack whose
# WindowServer or lsd belonged to the wrong generation. `mkdir` is the one
# atomic primitive available in the device shell. Keep the lock recoverable by
# recording the exact owner PID and reclaiming it only after that PID is gone.
release_gui_transaction() {
    local owner=""
    [ "$GUI_TRANSACTION_HELD" -eq 1 ] || return 0
    owner=$(sed -n '1p' "$GUI_TRANSACTION_PID" 2>/dev/null)
    if [ "$owner" = "$$" ]; then
        rm -f "$GUI_TRANSACTION_PID"
        rmdir "$GUI_TRANSACTION_LOCK" 2>/dev/null || true
    fi
    GUI_TRANSACTION_HELD=0
}

acquire_gui_transaction() {
    local operation="$1" owner="" owner_command="" attempt=0
    while [ "$attempt" -lt 2 ]; do
        if mkdir "$GUI_TRANSACTION_LOCK" 2>/dev/null; then
            printf '%s\n' "$$" > "$GUI_TRANSACTION_PID" || {
                rmdir "$GUI_TRANSACTION_LOCK" 2>/dev/null || true
                return 1
            }
            GUI_TRANSACTION_HELD=1
            GUI_TRANSACTION_STARTED=$(date +%s)
            trap release_gui_transaction EXIT
            return 0
        fi
        owner=$(sed -n '1p' "$GUI_TRANSACTION_PID" 2>/dev/null)
        case "$owner" in
            ''|*[!0-9]*) owner="" ;;
        esac
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            owner_command=$(ps -p "$owner" -o command= 2>/dev/null)
            log "ERROR: GUI transition '$operation' refused; pid=$owner is already changing the MacWS stack (${owner_command:-unknown command})."
            return 75
        fi
        # A killed shell cannot run its EXIT trap. Remove only the two exact
        # script-owned lock objects, then retry the atomic mkdir once.
        rm -f "$GUI_TRANSACTION_PID"
        rmdir "$GUI_TRANSACTION_LOCK" 2>/dev/null || return 75
        log "Recovered stale GUI transition lock (previous owner=${owner:-unknown})."
        attempt=$((attempt + 1))
    done
    return 75
}

write_gui_start_state() {
    local phase="$1" detail="${2:-}" temporary="${GUI_START_STATE}.new.$$"
    {
        printf 'schema=macws-gui-start-v1\n'
        printf 'pid=%s\n' "$$"
        printf 'operation=%s\n' "$CMD"
        printf 'mode=%s\n' "$MODE"
        printf 'phase=%s\n' "$phase"
        printf 'started_at=%s\n' "$GUI_TRANSACTION_STARTED"
        printf 'updated_at=%s\n' "$(date +%s)"
        printf 'detail=%s\n' "$detail"
    } > "$temporary" || return 1
    chmod 0644 "$temporary" || return 1
    mv -f "$temporary" "$GUI_START_STATE"
}

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
RESTORE_MAPS_AFTER_WS=0
pattern_is_running() {
    ps aux 2>/dev/null | grep -v grep | grep -Fq "$1"
}

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
    RESTORE_MAPS_AFTER_WS=0
    # Maps was previously omitted from the dependent set. Runtime evidence
    # showed its old process still alive with 0 windows and ~956 MiB footprint
    # after "WindowServer event port death"; it did not publish another window
    # in that generation. Remember that it was open, retire the stale generation
    # below, and let the foreground Host's existing Catalyst carrier recreate
    # exactly one fresh generation.
    pattern_is_running "$P_MAPS" && RESTORE_MAPS_AFTER_WS=1
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
    # This file is an output witness from the current interopd generation, not
    # persistent configuration. Never let a replacement process inherit an
    # apparently-ready provider from a dead generation.
    rm -f "$LOCATION_PROVIDER_READY"
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
    launchctl unload "$LSD_SYSTEM_PLIST" 2>/dev/null
    launchctl remove "$LSD_SYSTEM_LABEL" 2>/dev/null
    launchctl unload "$ICONSERVICESAGENT_PLIST" 2>/dev/null
    launchctl unload "$ICONSERVICESD_PLIST" 2>/dev/null
    launchctl remove "$ICONSERVICESAGENT_LABEL" 2>/dev/null
    launchctl remove "$ICONSERVICESD_LABEL" 2>/dev/null
    launchctl unload "$CSNAMEDDATAD_PLIST" 2>/dev/null
    launchctl remove "$CSNAMEDDATAD_LABEL" 2>/dev/null
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
    kill_by_pattern "$P_MAPS"
    rm -f "$MAPS_HOST_CARRIER_MARKER"
    kill_by_pattern "$P_FINDER"
    kill_by_pattern "$P_DOCK"
    kill_by_pattern "$P_DOCK_HELPER"
    kill_by_pattern "$P_SYSTEMUI"
    kill_by_pattern "$P_CONTROL_CENTER"
    kill_by_pattern "$P_ICONSERVICESAGENT"
    kill_by_pattern "$P_ICONSERVICESD"
    kill_by_pattern "$P_CSNAMEDDATAD"
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

ensure_navigation_spaces() {
    local rc=0

    # CGSSpaceCreate needs Dock's per-session Space controller to be live.
    # Runtime-confirmed on the 2026-08-09 cold boot: invoking the controller
    # after WindowServer but before Dock blocked indefinitely inside
    # `ensure-navigation-spaces`.  Require the upstream owner and bound the
    # IPC transaction so a broken Space service can never wedge GUI startup.
    proc_running "$P_DOCK" || {
        log "ERROR: Dock must be ready before establishing native macOS desktops."
        return 1
    }
    rm -f "$LOGDIR/navigation-spaces.log"
    /var/jb/usr/bin/timeout -k 2 20 \
        "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
        ensure-navigation-spaces > "$LOGDIR/navigation-spaces.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "ERROR: could not establish adjacent native macOS desktops."
        [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] ||
            log "ERROR: native desktop IPC exceeded the 20-second startup bound."
        tail -n 20 "$LOGDIR/navigation-spaces.log" 2>/dev/null || true
        return 1
    fi
    log "Native macOS desktop navigation topology ready: $(tail -n 1 "$LOGDIR/navigation-spaces.log")"
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
    [ ! -f "$LSD_SYSTEM_PLIST" ] || \
        launchctl load "$LSD_SYSTEM_PLIST" 2>/dev/null
    [ ! -f "$LSD_PLIST" ] || launchctl load "$LSD_PLIST" 2>/dev/null
    [ ! -f "$ICONSERVICESD_PLIST" ] || \
        launchctl load "$ICONSERVICESD_PLIST" 2>/dev/null
    [ ! -f "$ICONSERVICESAGENT_PLIST" ] || \
        launchctl load "$ICONSERVICESAGENT_PLIST" 2>/dev/null
    [ ! -f "$CSNAMEDDATAD_PLIST" ] || \
        launchctl load "$CSNAMEDDATAD_PLIST" 2>/dev/null
    for workspace_plist in "$FINDER_DESKTOP_PLIST" "$DOCK_PLIST" \
                           "$SYSTEMUI_PLIST" "$CONTROL_CENTER_PLIST"; do
        [ ! -f "$workspace_plist" ] || launchctl load "$workspace_plist" 2>/dev/null
    done
    # A replacement WindowServer owns a new session/Space catalog. Wait for
    # Dock's replacement controller before rebuilding the adjacent native
    # desktop topology; the bounded helper prevents recovery itself wedging.
    local workspace_waited=0
    while ! proc_running "$P_DOCK" && [ "$workspace_waited" -lt 15 ]; do
        sleep 1
        workspace_waited=$((workspace_waited + 1))
    done
    ensure_navigation_spaces || return 1
    apply_workspace_wallpaper || return 1
    if [ "$WANT_VNC" = 1 ]; then
        launchctl load "$VNC_PLIST" 2>/dev/null
    fi
    if [ "$WANT_TERMINAL" = 1 ]; then
        sleep 2
        launchctl load "$TERM_PLIST" 2>/dev/null
    fi
    if [ "$RESTORE_MAPS_AFTER_WS" = 1 ] &&
       [ -x /var/jb/usr/bin/uiopen ]; then
        # macwshost://maps is the sole production Catalyst launch route. It
        # brings the existing Host Scene forward, then the foreground Host
        # performs the responsible-process spawn required by UIKitSystem.
        /var/jb/usr/bin/uiopen 'macwshost://maps' >/dev/null 2>&1 ||
            log "watchdog: WARNING: Maps restoration request was rejected"
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

# Restore only existing signatures required before autosignd and the macOS
# session can start. Dopamine's dynamic trustcache is reboot-volatile, while
# all CodeDirectories below persist on disk. Runtime LLDB on the 2026-08-09
# cold boot proved that omitting launchservicesd.dylib makes its loader call a
# NULL dlopen result; WindowServer then blocks in LS setup before publishing
# the SkyLight session port, leaving Dock and every AppKit client hung in
# get_session_port. This bounded restore changes no binary or signature.
BOOT_TRUSTCACHE_INFO=""
BOOT_TRUSTCACHE_ADDED=0

boot_trust_hash() {
    local hash="$1"
    [ -n "$hash" ] || return 0
    if printf '%s\n' "$BOOT_TRUSTCACHE_INFO" |
            /var/jb/usr/bin/grep -Fqi "$hash"; then
        return 0
    fi
    /var/jb/usr/bin/jbctl trustcache add "$hash" >/dev/null 2>&1 || return 1
    BOOT_TRUSTCACHE_INFO="${BOOT_TRUSTCACHE_INFO}
$hash"
    BOOT_TRUSTCACHE_ADDED=$((BOOT_TRUSTCACHE_ADDED + 1))
}

boot_trust_macho() {
    local path="$1" arch="" hash=""
    [ -f "$path" ] || return 0
    for arch in arm64 arm64e; do
        hash=$(/var/jb/usr/bin/ldid -arch "$arch" -h "$path" 2>/dev/null |
            /var/jb/usr/bin/grep 'CDHash=' | /var/jb/usr/bin/cut -c8-)
        [ -z "$hash" ] || boot_trust_hash "$hash" || return 1
    done
}

restore_cold_boot_trust() {
    local path="" vscode_bundle="$ROOTFS/Applications/Visual Studio Code.app"
    BOOT_TRUSTCACHE_INFO=$(/var/jb/usr/bin/jbctl trustcache info 2>/dev/null || true)
    BOOT_TRUSTCACHE_ADDED=0

    # Exact Ventura 13.4 arm64e shared-cache CodeDirectories. dyld reports
    # "code signature registration for shared cache failed" without them.
    boot_trust_hash b5da39409492ac85e5a8e8ab618fe77e2d7a2980 || return 1
    boot_trust_hash bbb765988e2677b98d47a549d612fa0d4af25f69 || return 1

    for path in \
        /var/jb/usr/macOS/bin/launchdchrootexec \
        /var/jb/usr/macOS/lib/libmachook.dylib \
        /var/jb/usr/macOS/lib/libmachook_arm64.dylib \
        /var/jb/Applications/MacWSCatalystLauncher.app/MacWSCatalystLauncher \
        "$ROOTFS/usr/local/lib/libmachook.dylib" \
        "$ROOTFS/usr/local/lib/libmachook_arm64.dylib" \
        "$ROOTFS/usr/lib/dyld" \
        "$ROOTFS/System/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" \
        /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate \
        "$ROOTFS/bin/bash" \
        "$ROOTFS/System/Library/CoreServices/launchservicesd" \
        "$ROOTFS/System/Library/CoreServices/launchservicesd.dylib" \
        "$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer" \
        "$ROOTFS/System/Library/PrivateFrameworks/SystemStatusServer.framework/Support/systemstatusd" \
        "$ROOTFS/usr/local/libexec/macws-cfprefsd" \
        "$ROOTFS/usr/libexec/lsd" \
        "$ROOTFS/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder" \
        "$ROOTFS/System/Library/PrivateFrameworks/TimelineUI.framework/Versions/A/TimelineUI" \
        "$ROOTFS/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" \
        "$ROOTFS/System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper" \
        "$ROOTFS/System/Library/PrivateFrameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc/Contents/MacOS/ViewBridgeAuxiliary" \
        "$ROOTFS/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/XPCServices/com.apple.hiservices-xpcservice.xpc/Contents/MacOS/com.apple.hiservices-xpcservice" \
        "$ROOTFS/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService" \
        "$ROOTFS/System/Library/Frameworks/ExtensionFoundation.framework/Versions/A/XPCServices/extensionkitservice.xpc/Contents/MacOS/extensionkitservice" \
        "$ROOTFS/System/Library/CoreServices/UIKitSystem.app/Contents/MacOS/UIKitSystem" \
        "$ROOTFS/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer" \
        "$ROOTFS/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter" \
        "$ROOTFS/System/Library/CoreServices/iconservicesd" \
        "$ROOTFS/System/Library/CoreServices/iconservicesagent" \
        "$ROOTFS/usr/libexec/pboard" \
        "$ROOTFS/System/Library/CoreServices/pbs" \
        "$ROOTFS$OFFICE_LICENSING_BIN" \
        "$ROOTFS/System/Applications/System Settings.app/Contents/MacOS/System Settings" \
        "$ROOTFS/System/Applications/Maps.app/Contents/MacOS/Maps" \
        "$ROOTFS/System/Library/CoreServices/CoreLocationAgent.app/Contents/MacOS/CoreLocationAgent" \
        "$ROOTFS/usr/libexec/locationd" \
        "$ROOTFS/System/Library/PrivateFrameworks/GeoServices.framework/Versions/A/XPCServices/com.apple.geod.xpc/Contents/MacOS/com.apple.geod" \
        "$ROOTFS/usr/local/bin/macwsinputd" \
        "$ROOTFS/usr/local/bin/macwsdisplayd" \
        "$ROOTFS/usr/local/bin/macwsinteropd" \
        "$ROOTFS/usr/local/bin/macwsworkspacectl"; do
        boot_trust_macho "$path" || return 1
    done

    # Electron's nested executable signatures persist, but dyld validates them
    # before libmachook/autosignd can service the process. Restore the unchanged
    # bundle exactly as the former full postinst path did.
    if [ -d "$vscode_bundle/Contents" ]; then
        while IFS= read -r -d '' path; do
            boot_trust_macho "$path" || return 1
        done < <(find "$vscode_bundle/Contents" -type f -perm -111 -print0 2>/dev/null)
    fi
    log "Cold-boot trust closure ready (registered=$BOOT_TRUSTCACHE_ADDED existing CodeDirectories)."
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

ensure_launchservices_session_user_dir() {
    local directory="$ROOTFS$LSD_SESSION_USER_DIR"
    mkdir -p "$directory" || return 1
    chown root:wheel "$directory" 2>/dev/null || true
    chmod 0700 "$directory" || return 1
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
    restore_cold_boot_trust || {
        log "ERROR: reboot-volatile macOS trust closure could not be restored."
        return 1
    }
    # A restored/rootfs snapshot can regress only the data-only shader artifact
    # while every executable trust sentinel remains valid. Hash-check the
    # focused provisioner on every cold start; its matching path is one 1-MiB
    # read and performs no compiler or signing work.
    if [ ! -f "$QUARTZCORE_COMPAT_PROVISIONER" ] ||
       ! bash "$QUARTZCORE_COMPAT_PROVISIONER" \
            > "$LOGDIR/quartzcore-compat.log" 2>&1; then
        log "ERROR: exact QuartzCore native-AGX compatibility library is unavailable."
        tail -n 20 "$LOGDIR/quartzcore-compat.log" 2>/dev/null || true
        return 1
    fi
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

    # Remove the pre-xpcproxy scaffold on upgrade.  A normal launchd Mach job
    # cannot provide an Application-type XPC service's AppKit main-thread
    # lifecycle; keeping it registered races the real bundle activation and
    # leaves Dock's MenuGroup waiting forever for a reply.
    launchctl unload "$GUI_LAUNCHD_DIR/com.macwsguide.dockhelper.plist" 2>/dev/null
    launchctl remove com.macwsguide.dockhelper 2>/dev/null
    rm -f "$GUI_LAUNCHD_DIR/com.macwsguide.dockhelper.plist"

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
          OSXvnc maps RFB button 4 to the third CGPostMouseEvent slot unless
          this option is enabled. Runtime tracing in Dock then receives
          CGEvent type 0x19 (OtherMouseDown), while the swapped mapping
          delivers the correct type 3 (RightMouseDown). Keep RFB's
          conventional bit-4 right button and translate it with the server's
          documented compatibility switch. Dock still applies its own later
          tracking-state gate; correct event type alone does not bypass it.
        -->
        <string>-swapButtons</string>
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
    # macOS runs two copies of lsd in different launchd domains.  The system
    # daemon opens the durable csstore (`runAsRoot` is its stock role switch),
    # while the Background-session agent exposes the application catalog to
    # AppKit clients and obtains generations from the daemon's dissemination
    # endpoint.  A single iPadOS bootstrap domain cannot publish the same
    # service names twice, so libmachook maps the unmodified protocols onto a
    # private system family and private session family.
    cat > "$LSD_SYSTEM_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LSD_SYSTEM_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>/usr/libexec/lsd</string>
        <string>runAsRoot</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>MACWS_LSD_ROLE</key><string>system</string></dict>
    <key>MachServices</key>
    <dict>
        <key>com.apple.macosbooter.lsd.system.advertisingidentifiers</key><true/>
        <key>com.apple.macosbooter.lsd.system.diagnostics</key><true/>
        <key>com.apple.macosbooter.lsd.system.dissemination</key><true/>
        <key>com.apple.macosbooter.lsd.system.encryption</key><true/>
        <key>com.apple.macosbooter.lsd.system.extensions</key><true/>
        <key>com.apple.macosbooter.lsd.system.mapdb</key><true/>
        <key>com.apple.macosbooter.lsd.system.modifydb</key><true/>
        <key>com.apple.macosbooter.lsd.system.open</key><true/>
        <key>com.apple.macosbooter.lsd.system.openurl</key><true/>
        <key>com.apple.macosbooter.lsd.system.personaobserver</key><true/>
        <key>com.apple.macosbooter.lsd.system.plugin</key><true/>
        <key>com.apple.macosbooter.lsd.system.trustedsignatures</key><true/>
        <key>com.apple.macosbooter.lsd.system.security.translocation</key><true/>
    </dict>
    <key>EnableTransactions</key><true/>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>${LOGDIR}/lsd-system.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/lsd-system.log</string>
</dict>
</plist>
PLIST

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
    <key>EnvironmentVariables</key>
    <dict>
        <key>MACWS_LSD_ROLE</key><string>session</string>
        <key>MACWS_LSD_SESSION_USER_DIR</key><string>${LSD_SESSION_USER_DIR}</string>
    </dict>
    <key>MachServices</key>
    <dict>
        <key>com.apple.macosbooter.lsd.advertisingidentifiers</key><true/>
        <key>com.apple.macosbooter.lsd.diagnostics</key><true/>
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
    <key>StandardOutPath</key><string>${LOGDIR}/lsd-session.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/lsd-session.log</string>
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

    # CarbonCore normally asks launchd's XPC bundle resolver to instantiate
    # csnameddatad for a login session. The chroot has no XPC bundle domain.
    # Runtime-confirmed on 2026-08-06: a Dock secondary click reached the real
    # DOCKFileTile showMenu:options: path, then logged lookup error 3 for this
    # exact endpoint and produced no menu window. Publish the stock Ventura
    # XPC executable under a collision-free service name; libmachook maps both
    # the listener and every chroot client without replacing its protocol.
    cat > "$CSNAMEDDATAD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CSNAMEDDATAD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array><string>${CSNAMEDDATA_PROXY}</string></array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.carboncore.csnameddata</key><true/></dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>XPC_SERVICE_NAME</key><string>${CSNAMEDDATAD_LABEL}</string>
        <key>MACWS_XPC_TARGET</key><string>${CSNAMEDDATAD_BIN}</string>
        <key>CA_VSYNC_OFF</key><string>1</string>
        <key>MACWS_AGX_NATIVE</key><string>1</string>
        <key>MACWS_AGX_REGISTER_CLASSES</key><string>1</string>
        <key>MACWS_PIN_FALLBACK</key><string>1</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/csnameddatad.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/csnameddatad.log</string>
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
        <!--
          A cold start must create a usable shell window, not restore whichever
          auxiliary panel happened to survive the previous GUI generation.
          Runtime evidence on 2026-08-07 captured a Terminal process whose
          only on-screen layer-3 window was "Inspector"; the corresponding
          /var/root Saved Application State windows.plist contained that same
          sole persistent window.  Use AppKit's native persistence opt-out for
          this launch, while leaving Terminal preferences and profiles intact.
        -->
        <string>-ApplePersistenceIgnoreState</string>
        <string>YES</string>
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
    launchctl unload "$OFFICE_LICENSING_PLIST" 2>/dev/null
    launchctl remove "$VNC_LABEL"  2>/dev/null
    launchctl remove "$TERM_LABEL" 2>/dev/null
    launchctl remove "$PBOARD_LABEL" 2>/dev/null
    launchctl remove "$PBS_LABEL" 2>/dev/null
    launchctl remove "$OFFICE_LICENSING_LABEL" 2>/dev/null
    launchctl unload "$LSD_PLIST" 2>/dev/null
    launchctl remove "$LSD_LABEL" 2>/dev/null
    launchctl unload "$LSD_SYSTEM_PLIST" 2>/dev/null
    launchctl remove "$LSD_SYSTEM_LABEL" 2>/dev/null
    launchctl unload "$CFPREFSD_AGENT_PLIST" 2>/dev/null
    launchctl unload "$CFPREFSD_DAEMON_PLIST" 2>/dev/null
    launchctl remove "$CFPREFSD_AGENT_LABEL" 2>/dev/null
    launchctl remove "$CFPREFSD_DAEMON_LABEL" 2>/dev/null
    launchctl unload "$ICONSERVICESAGENT_PLIST" 2>/dev/null
    launchctl unload "$ICONSERVICESD_PLIST" 2>/dev/null
    launchctl remove "$ICONSERVICESAGENT_LABEL" 2>/dev/null
    launchctl remove "$ICONSERVICESD_LABEL" 2>/dev/null
    launchctl unload "$CSNAMEDDATAD_PLIST" 2>/dev/null
    launchctl remove "$CSNAMEDDATAD_LABEL" 2>/dev/null
    # Upgrade cleanup for the obsolete direct-DockHelper launchd scaffold.
    launchctl unload "$GUI_LAUNCHD_DIR/com.macwsguide.dockhelper.plist" 2>/dev/null
    launchctl remove com.macwsguide.dockhelper 2>/dev/null
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
    rm -f "$LOCATION_PROVIDER_READY"

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
    kill_by_pattern "$P_OFFICE_LICENSING"
    kill_by_pattern "$P_ACTIVITYMON"
    kill_by_pattern "$P_GLASSDEMO"
    # Maps cannot survive a WindowServer generation change: its CGS port is
    # permanently bound to the retired server even if the Catalyst carrier
    # process remains live.  The old omission made the next launch falsely
    # reuse that live PID and publish no AppKit window.
    kill_by_pattern "$P_MAPS"
    rm -f "$MAPS_HOST_CARRIER_MARKER"
    kill_by_pattern "$P_FINDER"
    kill_by_pattern "$P_DOCK"
    kill_by_pattern "$P_DOCK_HELPER"
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

launchservices_source_fingerprint() {
    local manifest="$ROOTFS/private/tmp/macws-launchservices-source.$$"
    local root="" bundle="" info="" checksum=""
    {
        printf '%s\n' "$LAUNCHSERVICES_CATALOG_SCHEMA"
        for root in \
            "$ROOTFS/System/Applications" \
            "$ROOTFS/Applications" \
            "$ROOTFS/Users/root/Applications" \
            "$ROOTFS/System/Library/CoreServices"; do
            [ -d "$root" ] || continue
            find "$root" -type d -name '*.app' -prune -print 2>/dev/null
        done | sort | while IFS= read -r bundle; do
            info="$bundle/Contents/Info.plist"
            printf '%s|' "${bundle#$ROOTFS}"
            if [ -f "$info" ]; then
                checksum=$(cksum "$info" 2>/dev/null) || checksum=unreadable
                printf '%s\n' "$checksum"
            else
                printf '%s\n' missing-info
            fi
        done
        root="$ROOTFS/System/Library/ExtensionKit/Extensions"
        if [ -d "$root" ]; then
            find "$root" -type d -name '*.appex' -prune -print 2>/dev/null |
                sort | while IFS= read -r bundle; do
                    info="$bundle/Contents/Info.plist"
                    printf '%s|' "${bundle#$ROOTFS}"
                    if [ -f "$info" ]; then
                        checksum=$(cksum "$info" 2>/dev/null) ||
                            checksum=unreadable
                        printf '%s\n' "$checksum"
                    else
                        printf '%s\n' missing-info
                    fi
                done
        fi
        info="$ROOTFS/System/Library/CoreServices/SystemVersion.plist"
        [ ! -f "$info" ] || cksum "$info" 2>/dev/null
    } > "$manifest" || {
        rm -f "$manifest"
        return 1
    }
    checksum=$(cksum "$manifest" 2>/dev/null | awk '{print $1 ":" $2}')
    rm -f "$manifest"
    [ -n "$checksum" ] || return 1
    printf '%s' "$checksum"
}

seed_launchservices_database() {
    local fingerprint="" marker_value="" marker_tmp="" catalog_current=0
    local root="" bundle=""
    local -a application_paths=()
    if [ ! -x "$ROOTFS$LSREGISTER_BIN" ]; then
        log "ERROR: stock macOS lsregister is missing at $LSREGISTER_BIN"
        return 1
    fi
    if [ ! -x "$ROOTFS$WORKSPACECTL_BIN" ]; then
        log "ERROR: native workspace controller is missing at $WORKSPACECTL_BIN"
        return 1
    fi
    fingerprint=$(launchservices_source_fingerprint) || {
        log "ERROR: LaunchServices source fingerprint could not be computed."
        return 1
    }
    marker_value="$LAUNCHSERVICES_CATALOG_SCHEMA|$fingerprint"
    rm -f "$LOGDIR/lsregister.log"
    if [ -f "$LAUNCHSERVICES_CATALOG_MARKER" ] &&
       [ "$(sed -n '1p' "$LAUNCHSERVICES_CATALOG_MARKER" 2>/dev/null)" = \
         "$marker_value" ]; then
        catalog_current=1
        rm -f "$LAUNCHSERVICES_VERIFY_LOG"
        if "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
                verify-launchservices-catalog \
                > "$LAUNCHSERVICES_VERIFY_LOG" 2>&1; then
            log "LaunchServices catalog reused after platform-1 record verification."
            return 0
        fi

        # Runtime A/B on 2026-08-07 established the actual reboot invariant:
        # the same healthy, seeded csstore reports Terminal as `mounted`
        # immediately after registration and `not mounted` after only the
        # session lsd is reloaded.  _LSCopyLocalDatabase still returns the
        # non-null database with no error; NSWorkspace filters those inactive
        # records and returns nil.  A normal macOS login receives a root-volume
        # mount notification that reactivates them, while the bind-mounted
        # chroot does not.  Re-register each already-known application path and
        # the Settings extensions through stock LaunchServices.  An on-device
        # A/B over all 184 application bundles took 3 seconds and left the
        # csstore byte size unchanged, while restoring arbitrary Spotlight-
        # style launches instead of only the five startup witnesses.
        log "Reactivating persisted LaunchServices records for the mounted chroot..."
        for root in \
            "$ROOTFS/System/Applications" \
            "$ROOTFS/Applications" \
            "$ROOTFS/Users/root/Applications" \
            "$ROOTFS/System/Library/CoreServices"; do
            [ -d "$root" ] || continue
            while IFS= read -r bundle; do
                application_paths+=("${bundle#$ROOTFS}")
            done < <(find "$root" -type d -name '*.app' -prune -print \
                2>/dev/null | sort)
        done
        if [ "${#application_paths[@]}" -gt 0 ] &&
           "$CHROOTEXEC" 0 0 "$ROOTFS" "$LSREGISTER_BIN" -f \
                "${application_paths[@]}" \
                > "$LOGDIR/lsregister-reactivate.log" 2>&1 &&
           MACWS_CATALOG_REGISTRATION=1 \
                "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
                register-settings-extensions \
                > "$SETTINGS_EXTENSION_REGISTER_LOG" 2>&1 &&
           "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
                verify-launchservices-catalog \
                >> "$SETTINGS_EXTENSION_REGISTER_LOG" 2>&1; then
            log "LaunchServices catalog reactivated and verified."
            return 0
        fi
        log "Targeted LaunchServices reactivation failed; rebuilding the clean catalog."
        tail -n 8 "$LAUNCHSERVICES_VERIFY_LOG" 2>/dev/null || true
    fi

    # A changed rootfs/catalog schema needs one authoritative rebuild.  The
    # previous `-f -apps system,local,user` path repeatedly appended records:
    # runtime evidence found a 148,717,568-byte store and a 50-60 second
    # `_LSDatabaseClean` on every lsd launch.  Ventura's stock `-kill -seed`
    # transaction produced a clean 6-10 MB store in 6 seconds on this device
    # and immediately passed every application/ExtensionKit witness.
    if [ "$catalog_current" -eq 1 ]; then
        log "Rebuilding the real macOS application catalog after failed reactivation..."
    else
        log "Building the real macOS application catalog for this rootfs generation..."
    fi
    if ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$LSREGISTER_BIN" \
            -kill -seed > "$LOGDIR/lsregister.log" 2>&1; then
        log "ERROR: LaunchServices clean seed failed."
        tail -n 20 "$LOGDIR/lsregister.log" 2>/dev/null || true
        return 1
    fi
    # Ventura's Settings panes are system-level ExtensionKit content, not
    # embedded in System Settings.app.  A normal application-only scan leaves
    # these plug-ins absent (or with stale Container state -1 records) after a
    # cold database rebuild.  Register every pane through LaunchServices' own
    # plug-in registrar and require exact platform-1 records before publishing
    # the settings services.
    rm -f "$SETTINGS_EXTENSION_REGISTER_LOG"
    if ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
            verify-launchservices-catalog \
            > "$SETTINGS_EXTENSION_REGISTER_LOG" 2>&1; then
        log "Clean seed needs explicit System Settings extension activation..."
        if ! MACWS_CATALOG_REGISTRATION=1 \
                "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
                register-settings-extensions \
                >> "$SETTINGS_EXTENSION_REGISTER_LOG" 2>&1 ||
           ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
                verify-launchservices-catalog \
                >> "$SETTINGS_EXTENSION_REGISTER_LOG" 2>&1; then
            log "ERROR: rebuilt LaunchServices catalog failed record verification."
            tail -n 20 "$SETTINGS_EXTENSION_REGISTER_LOG" 2>/dev/null || true
            return 1
        fi
    fi
    mkdir -p "$(dirname "$LAUNCHSERVICES_CATALOG_MARKER")" || return 1
    marker_tmp="$LAUNCHSERVICES_CATALOG_MARKER.new.$$"
    printf '%s\n' "$marker_value" > "$marker_tmp" || return 1
    chmod 0644 "$marker_tmp" || return 1
    mv -f "$marker_tmp" "$LAUNCHSERVICES_CATALOG_MARKER" || return 1
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
    for proxy in \
        /var/jb/Applications/MacWSSettingsExtension-com.apple.*.app/SettingsExtensionProxy; do
        [ -x "$proxy" ] || continue
        chown root:wheel "$proxy" || return 1
        chmod 4755 "$proxy" || return 1
    done

    # Every Ventura Settings pane is a distinct ExtensionKit executable and
    # therefore needs a distinct registered iOS first-image carrier.  Runtime
    # on 2026-08-05 proved that sharing one path makes RunningBoard reject the
    # second pane with unequal identities, while preparing only Appearance
    # leaves Wi-Fi/Bluetooth/etc. at OSLaunchdErrorDomain/2.  Reconcile the
    # complete metadata-selected set at production start so restored
    # trustcaches and iOS LaunchServices state cannot silently regress after a
    # cold jailbreak bootstrap.
    if [ ! -f "$SETTINGS_EXTENSIONS_RUNTIME" ]; then
        log "ERROR: Settings ExtensionKit runtime helper is missing."
        return 1
    fi
    rm -f "$SETTINGS_EXTENSIONS_RUNTIME_LOG"
    if ! bash "$SETTINGS_EXTENSIONS_RUNTIME" --verify \
            > "$SETTINGS_EXTENSIONS_RUNTIME_LOG" 2>&1; then
        log "Repairing System Settings extension runtimes after verification failure..."
        if ! bash "$SETTINGS_EXTENSIONS_RUNTIME" \
                >> "$SETTINGS_EXTENSIONS_RUNTIME_LOG" 2>&1 ||
           ! bash "$SETTINGS_EXTENSIONS_RUNTIME" --verify \
                >> "$SETTINGS_EXTENSIONS_RUNTIME_LOG" 2>&1; then
            log "ERROR: System Settings extension runtimes could not be prepared."
            tail -n 20 "$SETTINGS_EXTENSIONS_RUNTIME_LOG" 2>/dev/null || true
            return 1
        fi
    fi
    log "All System Settings extension runtimes and carriers are ready."
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
    local value="" mission_control="" app_expose=""
    local dock_magnification="" dock_large_size=""
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
    # Dock registers its native fluid-gesture controllers while starting.  A
    # cold rootfs may not have created either preference yet; in that state
    # Ventura's real DOCKGestures object has no App Expose handler in slot 1,
    # so a correctly delivered three-finger-down stream is intentionally
    # ignored.  Persist the stock Dock preferences before Dock is launched and
    # verify the values through cfprefsd instead of installing another handler.
    rm -f "$LOGDIR/dock-gesture-preferences.log"
    if ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" write \
            com.apple.dock showMissionControlGestureEnabled -bool true \
            > "$LOGDIR/dock-gesture-preferences.log" 2>&1 ||
       ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" write \
            com.apple.dock showAppExposeGestureEnabled -bool true \
            >> "$LOGDIR/dock-gesture-preferences.log" 2>&1 ||
       ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" write \
            com.apple.dock magnification -bool true \
            >> "$LOGDIR/dock-gesture-preferences.log" 2>&1 ||
       ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" write \
            com.apple.dock largesize -int 128 \
            >> "$LOGDIR/dock-gesture-preferences.log" 2>&1; then
        log "ERROR: native Dock gesture/magnification preferences could not be persisted."
        tail -n 20 "$LOGDIR/dock-gesture-preferences.log" 2>/dev/null || true
        return 1
    fi
    mission_control=$("$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" read \
        com.apple.dock showMissionControlGestureEnabled 2>> \
        "$LOGDIR/dock-gesture-preferences.log") || mission_control=""
    app_expose=$("$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" read \
        com.apple.dock showAppExposeGestureEnabled 2>> \
        "$LOGDIR/dock-gesture-preferences.log") || app_expose=""
    dock_magnification=$("$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" read \
        com.apple.dock magnification 2>> \
        "$LOGDIR/dock-gesture-preferences.log") || dock_magnification=""
    dock_large_size=$("$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" read \
        com.apple.dock largesize 2>> \
        "$LOGDIR/dock-gesture-preferences.log") || dock_large_size=""
    if [ "$mission_control" != 1 ] || [ "$app_expose" != 1 ] ||
       [ "$dock_magnification" != 1 ] || [ "$dock_large_size" != 128 ]; then
        log "ERROR: native Dock preferences failed verification (Mission Control='$mission_control', App Expose='$app_expose', magnification='$dock_magnification', largesize='$dock_large_size')."
        tail -n 20 "$LOGDIR/dock-gesture-preferences.log" 2>/dev/null || true
        return 1
    fi
    log "Private macOS CFPreferences database ready; native gestures and maximum Dock hover magnification enabled."
}

apply_workspace_wallpaper() {
    local rc=0

    if [ ! -x "$ROOTFS$WORKSPACECTL_BIN" ]; then
        log "ERROR: native workspace controller is missing at $WORKSPACECTL_BIN"
        return 1
    fi
    rm -f "$LOGDIR/workspace-controller.log"
    /var/jb/usr/bin/timeout -k 2 20 \
        "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
        set-wallpaper "$WORKSPACE_WALLPAPER" \
        > "$LOGDIR/workspace-controller.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "ERROR: the real macOS desktop wallpaper could not be applied."
        [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] ||
            log "ERROR: native wallpaper IPC exceeded the 20-second startup bound."
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

    # The stock fontd is not healthy in this chroot merely because its PID is
    # present: a runtime sample on 2026-08-06 found no original service main
    # thread, only CydiaSubstrate exception/signal workers, while clients
    # repeatedly logged "failed to get common fonts".  A controlled cold
    # Terminal A/B measured first-window latency at 8.463 s with that endpoint
    # present versus 3.361 s after unloading it.  Leave the stale job unloaded
    # so AppKit immediately selects its working per-process static registry.
    # This is dependency selection backed by a visible-window witness, not a
    # check bypass; the plist remains packaged for future root-cause work.
    launchctl unload "$FONTD_PLIST" >/dev/null 2>&1 || true
    log "Using AppKit's per-process static font registry (shared fontd disabled)."

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

    # Office's serializer and applications do not write the volume-license
    # plist in-process. They synchronously call the stock privileged helper's
    # Mach service. A normal macOS boot publishes that service from the
    # helper's LaunchDaemon, but the chroot has no independent launchd domain.
    # Publish the unmodified protocol in the outer bootstrap and execute the
    # real helper through launchdchrootexec. This is optional when Office is
    # not installed and must never make the base desktop unavailable.
    if [ -x "$ROOTFS$OFFICE_LICENSING_BIN" ]; then
        if [ ! -f "$OFFICE_LICENSING_PLIST" ]; then
            log "WARNING: Office licensing helper is installed but its launch contract is missing."
        else
            log "Publishing Microsoft Office volume-licensing service..."
            rm -f "$LOGDIR/office-licensing.log"
            if launchctl load "$OFFICE_LICENSING_PLIST"; then
                # MachServices registration is the readiness contract.  The
                # stock helper is allowed to exit after an idle request and
                # launchd will reactivate it for the next Office client, so
                # waiting for a persistent PID would add ten seconds to every
                # desktop start and misreport a healthy on-demand service.
                log "Microsoft Office volume-licensing service registered (on demand)."
            else
                log "WARNING: Office licensing service could not be registered."
                tail -n 20 "$LOGDIR/office-licensing.log" 2>/dev/null || true
            fi
        fi
    fi

    log "Publishing the private macOS LaunchServices system store and session catalog..."
    ensure_launchservices_session_user_dir || {
        log "ERROR: could not prepare the isolated LaunchServices session store."
        return 1
    }
    rm -f "$LOGDIR/lsd-system.log" "$LOGDIR/lsd-session.log"
    launchctl load "$LSD_SYSTEM_PLIST" || return 1
    launchctl list "$LSD_SYSTEM_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private macOS system lsd contract was not registered."
        return 1
    }
    launchctl load "$LSD_PLIST" || return 1
    launchctl list "$LSD_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private macOS session lsd contract was not registered."
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

    log "Publishing CarbonCore named-data service for Dock menus..."
    rm -f "$LOGDIR/csnameddatad.log"
    launchctl load "$CSNAMEDDATAD_PLIST" || return 1
    launchctl list "$CSNAMEDDATAD_LABEL" >/dev/null 2>&1 || {
        log "ERROR: CarbonCore named-data MachService contract was not registered."
        return 1
    }

    seed_launchservices_database || return 1

    # System Settings' first visible pane is a stock ExtensionKit scene.  Its
    # host synchronously resolves ViewBridgeAuxiliary and HIServices before
    # Appearance is launched, so all three collision-free service contracts
    # must exist before any GUI application can enter that dependency chain.
    log "Publishing macOS ViewBridge, ExtensionKit and HIServices services..."
    publish_settings_service_contracts || return 1

    log "Loading legacy macOS launchservicesd..."
    launchctl load "$LAUNCHSERVICESD_PLIST" || return 1
    # The launchd contract can be registered even when the loader's dylib is
    # absent from Dopamine's reboot-volatile trustcache. Runtime LLDB on the
    # 2026-08-09 cold boot showed WindowServer then blocking synchronously in
    # LSClientToServerConnection before it published the SkyLight session
    # port. Require the real payload process to survive first; a merely loaded
    # launchd label is not a readiness witness.
    waited=0
    while ! proc_running "$P_LAUNCHSERVICESD" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_LAUNCHSERVICESD" || {
        log "ERROR: legacy macOS launchservicesd did not reach a live process."
        tail -n 30 "$LOGDIR/launchservicesd.err" 2>/dev/null ||
            tail -n 30 /var/jb/var/mobile/launchservicesd.err 2>/dev/null || true
        return 1
    }
    sleep 2
    proc_running "$P_LAUNCHSERVICESD" || {
        log "ERROR: legacy macOS launchservicesd exited during its readiness window."
        tail -n 30 /var/jb/var/mobile/launchservicesd.err 2>/dev/null || true
        return 1
    }
    log "Legacy macOS LaunchServices endpoint ready."

    log "Loading input bridge and WindowServer..."
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

    # DockHelper is an Application-type XPC service and must remain on-demand.
    # libmachook registers this proxy bundle in Dock; xpcproxy gives the stock
    # helper the NSApplication main-thread lifecycle required by TrackMenuCommon.
    # A permanently running launchd job is not an equivalent readiness witness.
    [ -x "$DOCK_HELPER_PROXY" ] || {
        log "ERROR: DockHelper XPC activation proxy is missing: $DOCK_HELPER_PROXY"
        return 1
    }
    log "Dock menu presentation helper registered for on-demand XPC activation."

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
    # These IPCs used to run before Dock and could wedge indefinitely in
    # get_session_port. They are now bounded and run only after LaunchServices,
    # WindowServer, and all real Aqua session owners have explicit readiness
    # witnesses. Establish two adjacent native Spaces for continuous three-
    # finger navigation, then apply the persisted high-resolution wallpaper.
    ensure_navigation_spaces || return 1
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
    echo "logs: $LOGDIR/osxvnc.log  $LOGDIR/terminal.log  $LOGDIR/lsd-system.log  $LOGDIR/lsd-session.log  $LOGDIR/dock.log  $LOGDIR/systemuiserver.log  $LOGDIR/controlcenter.log  $LOGDIR/WindowServer.err"
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
    rm -f "$EXPERIMENTAL_COMMAND_ERROR" "$EXPERIMENTAL_IOGPU_ERROR" \
        "$EXPERIMENTAL_PIPELINE_DIAG" "$EXPERIMENTAL_FAST_SUBMIT_RING" \
        "$EXPERIMENTAL_OBSERVE_PF550" "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS" \
        "$MTLCOMPILER_DIAGNOSTICS"
    if [ "$WANT_DIAGNOSTICS" = 1 ]; then
        touch "$EXPERIMENTAL_COMMAND_ERROR" "$EXPERIMENTAL_IOGPU_ERROR" \
            "$EXPERIMENTAL_PIPELINE_DIAG" \
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
    <!-- The old job was runtime-confirmed to exit with
         JETSAM_REASON_MEMORY_IDLE_EXIT after arming.  This launchd lifecycle
         flag keeps the mandatory five-minute thermal sampler resident; it
         neither restores the retired free-memory guard nor overrides an iOS
         memorystatus limit. -->
    <key>EnablePressuredExit</key><false/>
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
        acquire_gui_transaction start || exit $?
        write_gui_start_state preparing "generating launchd contracts"
        write_plists || { log "ERROR: failed to write GUI launch plists."; exit 1; }
        write_gui_start_state cleaning "retiring the previous service generation"
        cleanup_macos
        write_gui_start_state assets "preparing the production application profile"
        prepare_vscode_production_assets || { stop_all; exit 1; }
        enable_experimental_if_requested
        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_DIAGNOSTICS" != 1 ]; then
            write_gui_start_state preflight "validating native AGX production switches"
            production_preflight || { stop_all; exit 1; }
        fi
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        write_gui_start_state safety "arming the critical-only thermal watchdog"
        start_watchdog || { stop_all; exit 1; }
        write_gui_start_state trust "restoring executable trust for this boot"
        ensure_chroot_works || { stop_all; exit 1; }
        write_gui_start_state services "starting catalogs, WindowServer, bridges, and applications"
        start_macos || { stop_all; exit 1; }
        write_gui_start_state first-frame "waiting for the optional initial VNC capture"
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
        write_gui_start_state ready "WindowServer and requested clients are ready"
        echo
        log "Started in $MODE mode."
        status
        ;;
    stop)
        require_root "$@"
        acquire_gui_transaction stop || exit $?
        write_gui_start_state stopping "retiring the active GUI service generation"
        stop_all
        write_gui_start_state stopped "iOS display services restored"
        ;;
    restart)
        require_root "$@"
        acquire_gui_transaction restart || exit $?
        write_gui_start_state preparing "generating launchd contracts"
        write_plists || { log "ERROR: failed to write GUI launch plists."; exit 1; }
        write_gui_start_state cleaning "retiring the active GUI service generation"
        stop_all
        write_gui_start_state assets "preparing the production application profile"
        prepare_vscode_production_assets || { stop_all; exit 1; }
        enable_experimental_if_requested
        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_DIAGNOSTICS" != 1 ]; then
            write_gui_start_state preflight "validating native AGX production switches"
            production_preflight || { stop_all; exit 1; }
        fi
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        write_gui_start_state safety "arming the critical-only thermal watchdog"
        start_watchdog || { stop_all; exit 1; }
        write_gui_start_state trust "restoring executable trust for this boot"
        ensure_chroot_works || { stop_all; exit 1; }
        write_gui_start_state services "starting catalogs, WindowServer, bridges, and applications"
        start_macos || { stop_all; exit 1; }
        write_gui_start_state first-frame "waiting for the optional initial VNC capture"
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
        write_gui_start_state ready "WindowServer and requested clients are ready"
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
