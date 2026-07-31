cd $(realpath $HOME/../..)/usr/macOS

ENT="/var/jb/usr/macOS/bin/entitlements.plist"

MACHO_PATCHER="/var/jb/usr/macOS/bin/set_macos_version.py"
LIBMACHOOK="/var/jb/usr/macOS/lib/libmachook.dylib"
LIBMACHOOK_ARM64="/var/jb/usr/macOS/lib/libmachook_arm64.dylib"
LIPO="/var/jb/usr/bin/lipo"

# Keep App-driven repair self-contained. Package installation normally fixes
# this first, but running it here also repairs older installs. Do not re-sign
# an already-correct thin library on every repair: this ldid build can change
# its CDHash across passes, which would accumulate obsolete trustcache entries.
split_libmachook=0
if [ -f "$LIBMACHOOK" ] && [ -f "$MACHO_PATCHER" ]; then
    if "$LIPO" -info "$LIBMACHOOK" 2>&1 | grep -q 'Architectures in the fat file'; then
        /var/jb/usr/bin/python3 "$MACHO_PATCHER" "$LIBMACHOOK" || exit 1
        tmp_arm64e="${LIBMACHOOK}.arm64e-new-$$"
        tmp_arm64="${LIBMACHOOK_ARM64}.new-$$"
        "$LIPO" "$LIBMACHOOK" -thin arm64e -output "$tmp_arm64e" || exit 1
        "$LIPO" "$LIBMACHOOK" -thin arm64 -output "$tmp_arm64" || {
            rm -f "$tmp_arm64e"
            exit 1
        }
        chmod 755 "$tmp_arm64e" "$tmp_arm64"
        mv "$tmp_arm64e" "$LIBMACHOOK"
        mv "$tmp_arm64" "$LIBMACHOOK_ARM64"
        split_libmachook=1
        echo '[INFO] split libmachook into thin arm64e + arm64 libraries'
    fi
fi
if [ ! -f "$LIBMACHOOK" ] || [ ! -f "$LIBMACHOOK_ARM64" ]; then
    echo '[ERROR] both thin libmachook slices are required' >&2
    exit 1
fi
for lib in "$LIBMACHOOK" "$LIBMACHOOK_ARM64"; do
    must_sign=$split_libmachook
    if [ -f "$MACHO_PATCHER" ]; then
        patch_output=$(/var/jb/usr/bin/python3 "$MACHO_PATCHER" "$lib") || exit 1
        echo "$patch_output"
        case "$patch_output" in
            *"patched $lib"*) must_sign=1 ;;
        esac
    fi
    if [ "$must_sign" -eq 1 ]; then
        # Two passes are required after lipo -thin; the first pass can leave
        # page hashes describing the pre-growth __LINKEDIT layout.
        /var/jb/usr/bin/ldid -S"$ENT" -M "$lib" || exit 1
        /var/jb/usr/bin/ldid -S"$ENT" -M "$lib" || exit 1
    fi
done

# ─── Trustcache optimization: cache existing hashes ─────────────────────────
# Dump trustcache once at startup to avoid repeated jbctl calls
TRUSTCACHE_FILE="/tmp/postinst_trustcache_$$"
jbctl trustcache info 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$TRUSTCACHE_FILE"
trap "rm -f '$TRUSTCACHE_FILE'" EXIT

is_trusted() {
    local cdhash="$1"
    [ -z "$cdhash" ] && return 1
    grep -qi "$cdhash" "$TRUSTCACHE_FILE" 2>/dev/null
}

trust_cdhash() {
    local cdhash="$1"
    local path="$2"
    local arch="$3"
    if is_trusted "$cdhash"; then
        echo "[SKIP] $path [$arch]: $cdhash (already trusted)"
        return 0
    fi
    echo "[ADD]  $path [$arch]: $cdhash"
    jbctl trustcache add "$cdhash"
    # Add to cache so we don't re-add duplicates within this run
    echo "$cdhash" >> "$TRUSTCACHE_FILE"
}

# Sign a binary with the project entitlements AND register all its CDHashes.
# Optimized: skip re-signing if all per-arch hashes are already trusted.
sign_and_trustcache() {
    local path="$1"
    [ -f "$path" ] || return

    # Collect CDHashes per-arch (ldid -h without -arch does not output CDHash lines)
    local hashes="" h
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && hashes="$hashes $h"
    done
    [ -z "$hashes" ] && return  # Not a Mach-O file

    # Check if ALL hashes are already trusted
    local dominated=1
    for h in $hashes; do
        if ! is_trusted "$h"; then
            dominated=0
            break
        fi
    done

    if [ "$dominated" -eq 1 ]; then
        return 0  # Silent skip - all trusted
    fi

    # Sign and collect new hashes
    ldid -S"$ENT" -M "$path" 2>/dev/null || return
    hashes=""
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && hashes="$hashes $h"
    done

    # Add all hashes
    for h in $hashes; do
        trust_cdhash "$h" "$path" "all"
    done
}

add_trustcache() {
    local path="$1"
    local cdhash
    cdhash=$(ldid -arch arm64 -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$cdhash" ] && trust_cdhash "$cdhash" "$path" "arm64"
}

add_arm64e_trustcache() {
    local path="$1"
    local cdhash
    cdhash=$(ldid -arch arm64e -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$cdhash" ] && trust_cdhash "$cdhash" "$path" "arm64e"
}

add_x86_64_trustcache() {
    local path="$1"
    local cdhash
    cdhash=$(ldid -arch x86_64 -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$cdhash" ] && trust_cdhash "$cdhash" "$path" "x86_64"
}

add_all_trustcache() {
    local path="$1"
    add_trustcache "$path"
    add_arm64e_trustcache "$path"
    add_x86_64_trustcache "$path"
}

# Give a stock macOS image the project code-signing policy once, then restore
# only its persistent CDHashes on subsequent repairs/reboots.  The entitlement
# marker avoids repeatedly changing the file and accumulating obsolete hashes.
ensure_project_signature_and_trustcache() {
    local path="$1"
    [ -f "$path" ] || return 0
    if ! ldid -e "$path" 2>/dev/null |
         grep -q '<key>com.apple.private.graphics-restart-no-kill</key>'; then
        ldid -S"$ENT" -M "$path" || return 1
    fi
    add_all_trustcache "$path"
}

# Re-register every already-signed executable Mach-O in an application bundle.
#
# Dynamic jailbreak trustcaches are lost across a device reboot, while the
# ad-hoc signatures stored in the macOS rootfs persist.  launchdchrootexec can
# repair the process it directly execs, but dyld validates dependent
# frameworks before libmachook/autosignd can run.  Runtime evidence from the
# first VS Code launch after the 2026-07-30 reboot showed exactly that split:
# Contents/MacOS/Code was trusted, then dyld rejected Electron Framework and,
# after that hash was added, Squirrel.framework.  Restoring the 44 signed
# executable files in the bundle made the unchanged VS Code 1.130 build reach
# CDP in four seconds.
#
# Do not call sign_and_trustcache here.  Re-signing a nested framework changes
# its CDHash and can invalidate the bundle's existing nested-code relationship.
# Reading and re-registering the persistent signatures is sufficient and keeps
# the installed application byte-for-byte unchanged.
trust_existing_app_bundle() {
    local bundle="$1"
    local name="$2"
    [ -d "$bundle" ] || return 0

    echo "[INFO] Restoring signed Mach-O trustcache entries for $name..."
    find "$bundle/Contents" -type f -perm -111 -print0 2>/dev/null |
        while IFS= read -r -d '' path; do
            add_all_trustcache "$path"
        done
}

# The iOS-native control daemon is the reboot-safe entry point used by the
# MacWSHost app.  Trust it here, but never unload it from this script: postinst
# may itself be running as a request served by macwshostd.
add_all_trustcache "/var/jb/usr/macOS/bin/macwshostd"

# ─── LaunchDaemons plist ownership/permissions ─────────────────────────────
# launchctl refuses to load any plist under a system LaunchDaemons dir unless
# owner=root:wheel and mode=0644.  The deb install preserves whatever owner
# the build host had (typically mobile:staff), so reset to root:wheel 0644.
# Without this, launchservicesd never starts (chroot Cocoa apps then crash in
# HIServices _RegisterApplication).
if [ -d /var/jb/usr/macOS/LaunchDaemons ]; then
    chown root:wheel /var/jb/usr/macOS/LaunchDaemons/*.plist 2>/dev/null || true
    chmod 644       /var/jb/usr/macOS/LaunchDaemons/*.plist 2>/dev/null || true
fi

# ─── On-demand auto-sign daemon (iOS side) ──────────────────────────────────
# libmachook's exec hooks ask this daemon (over /tmp/autosignd.sock) to
# sign+trustcache a binary on first exec, so arbitrary macOS programs run in the
# chroot without pre-listing every binary here. Trustcache it, then (re)start it.
AUTOSIGND=/var/jb/usr/macOS/bin/autosignd
if [ -x "$AUTOSIGND" ]; then
    add_all_trustcache "$AUTOSIGND"
    pkill -x autosignd 2>/dev/null
    rm -f /var/mnt/rootfs/tmp/autosignd.sock
    nohup "$AUTOSIGND" >/var/mnt/rootfs/tmp/autosignd.log 2>&1 &
    echo "[INFO] started autosignd (on-demand auto-sign daemon)"
fi

# ─── iOS-native IOSurface allocator daemon (for chroot WS CodeHeap) ─────────
# Chroot WS in AGX-native mode can't allocate via sel=0xa heap-creates (kernel
# rejects on the macOS user-client). This daemon runs in iOS-native context
# (sees the real AGX), allocates IOSurfaces of the requested size, returns the
# mach send-right back over XPC. libmachook's CODEHEAP-SHIM connects to it.
ALLOCD=/var/jb/usr/macOS/bin/macwsallocd
ALLOCD_PLIST=/var/jb/Library/LaunchDaemons/com.macwsguide.alloc.plist
if [ -x "$ALLOCD" ]; then
    add_all_trustcache "$ALLOCD"
    if [ -f "$ALLOCD_PLIST" ]; then
        # Unload + load to pick up plist changes.
        launchctl unload "$ALLOCD_PLIST" 2>/dev/null || true
        launchctl load "$ALLOCD_PLIST" 2>&1 | head -3
        echo "[INFO] loaded com.macwsguide.alloc launchd job"
    fi
fi

add_trustcache "/var/jb/usr/macOS/bin/TestMetalIOSurface"
add_trustcache "/var/jb/usr/macOS/bin/PinnedVAProbe"
add_all_trustcache "/var/jb/usr/macOS/lib/libmachook.dylib"
add_all_trustcache "/var/jb/usr/macOS/lib/libmachook_arm64.dylib"
add_all_trustcache "/var/jb/usr/macOS/bin/launchdchrootexec"
add_all_trustcache "/var/jb/usr/macOS/bin/launchdchrootexec_debug"
add_all_trustcache "/var/jb/usr/macOS/bin/macwsinputd"
add_all_trustcache "/var/jb/usr/macOS/bin/macwsdisplayd"
add_all_trustcache "/var/jb/usr/macOS/bin/macwsinteropd"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MetalSerializer.framework/MetalSerializer"
cp -vf /var/jb/usr/macOS/Frameworks/MetalSerializer.framework/MetalSerializer_macos /var/mnt/rootfs/usr/local/Frameworks/MetalSerializer.framework/MetalSerializer
add_all_trustcache /var/mnt/rootfs/usr/local/Frameworks/MetalSerializer.framework/MetalSerializer
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/MTLSimDriver"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimImplementation.framework/MTLSimImplementation"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc/MTLSimDriverHost"
# codesign -vvv -d dyld_shared_cache_arm64e 2>&1 | grep CDHash=
jbctl trustcache add b5da39409492ac85e5a8e8ab618fe77e2d7a2980
# codesign -vvv -d dyld_shared_cache_arm64e.01 2>&1 | grep CDHash=
jbctl trustcache add bbb765988e2677b98d47a549d612fa0d4af25f69
add_all_trustcache "/var/mnt/rootfs/bin/bash"
add_all_trustcache "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd"
SYSTEMSTATUSD="/var/mnt/rootfs/System/Library/PrivateFrameworks/SystemStatusServer.framework/Support/systemstatusd"
if [ -f "$SYSTEMSTATUSD" ] &&
   ! ldid -e "$SYSTEMSTATUSD" 2>/dev/null | grep -q '<key>com.apple.systemstatus.domains</key>'; then
    # A stock macOS systemstatusd only carries com.apple.rootless.critical.
    # macOS executables launched in the iOS chroot must use the same project
    # entitlement set as WindowServer before AMFI will admit the injected
    # libmachook image.  Do this once; repeated ldid passes can change CDHash.
    ldid -S"$ENT" -M "$SYSTEMSTATUSD" || exit 1
fi
add_all_trustcache "$SYSTEMSTATUSD"
if [ ! -e "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib" ]; then
	cp -vf /var/jb/usr/macOS/Frameworks/launchservicesd.dylib "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib"
fi
add_all_trustcache "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib"
add_all_trustcache "/var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
add_all_trustcache /var/jb/usr/macOS/bin/HostInjectBootstrap
add_all_trustcache /var/mnt/rootfs/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService
add_all_trustcache /System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService
# Refresh the chroot copy of libmachook. CRITICAL: rm before cp so the new file
# gets a FRESH INODE. Overwriting in place (cp -f, same inode) leaves the chroot
# kernel's cached code-signature blob for that vnode stale -> it validates the new
# file's pages against the OLD cached hashes -> AMFI "Invalid Page" SIGKILLs every
# arm64e chroot process at dyld insert-map time. A new inode has no cached blob.
# (arm64 escaped this only because WindowServer stayed mapped from one clean load.)
rm -f /var/mnt/rootfs/usr/local/lib/libmachook.dylib
cp -vf /var/jb/usr/macOS/lib/libmachook.dylib /var/mnt/rootfs/usr/local/lib/libmachook.dylib
add_all_trustcache /var/mnt/rootfs/usr/local/lib/libmachook.dylib
# arm64 thin slice (loaded into pure-arm64 chroot processes: WindowServer, claude,
# MacPorts tools). Present only after an on-device build; guard so cross-compile
# installs (single fat libmachook.dylib) don't fail here.
if [ -f /var/jb/usr/macOS/lib/libmachook_arm64.dylib ]; then
	rm -f /var/mnt/rootfs/usr/local/lib/libmachook_arm64.dylib
	cp -vf /var/jb/usr/macOS/lib/libmachook_arm64.dylib /var/mnt/rootfs/usr/local/lib/libmachook_arm64.dylib
	add_all_trustcache /var/mnt/rootfs/usr/local/lib/libmachook_arm64.dylib
fi

# Native-host input bridge.  Keep the installed source and the chroot-visible
# executable on fresh inodes so AMFI does not reuse a stale vnode signature.
if [ -f /var/jb/usr/macOS/bin/macwsinputd ]; then
	rm -f /var/mnt/rootfs/usr/local/bin/macwsinputd
	cp -vf /var/jb/usr/macOS/bin/macwsinputd /var/mnt/rootfs/usr/local/bin/macwsinputd
	chmod 755 /var/mnt/rootfs/usr/local/bin/macwsinputd
	add_all_trustcache /var/mnt/rootfs/usr/local/bin/macwsinputd
fi
for bridge in macwsdisplayd macwsinteropd; do
	if [ -f "/var/jb/usr/macOS/bin/$bridge" ]; then
		rm -f "/var/mnt/rootfs/usr/local/bin/$bridge"
		cp -vf "/var/jb/usr/macOS/bin/$bridge" "/var/mnt/rootfs/usr/local/bin/$bridge"
		chmod 755 "/var/mnt/rootfs/usr/local/bin/$bridge"
		add_all_trustcache "/var/mnt/rootfs/usr/local/bin/$bridge"
	fi
done
# MacWSHost runs as the iOS mobile user while the chroot apps currently run as
# root.  A shared staging directory owned by mobile lets the Host copy
# security-scoped imports into the mounted rootfs; root can then publish the
# same native file URLs through macOS pboard without a second copy.
mkdir -p "/var/mnt/rootfs/Users/Shared/MacWS Imports"
chown mobile:mobile "/var/mnt/rootfs/Users/Shared/MacWS Imports" 2>/dev/null || true
chmod 0770 "/var/mnt/rootfs/Users/Shared/MacWS Imports"
add_all_trustcache '/var/mnt/rootfs/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor'
# Finder keeps its stock macOS Apple signature on a fresh rootfs.  The iOS
# kernel runtime-confirmed that signature is rejected with
# "unsuitable CT policy 0x8 for this platform/device" before Finder reaches
# AppKit.  Sign it once with the same project entitlement profile used by the
# other chroot applications, then only restore the persistent CDHash on later
# postinst/cold-start repairs.  The entitlement probe avoids repeatedly
# changing the signed file and accumulating obsolete trustcache entries.
FINDER_BIN='/var/mnt/rootfs/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder'
ensure_project_signature_and_trustcache "$FINDER_BIN" || exit 1
# Finder's TimelineUI dependency is not present in the iOS dyld shared cache.
# Once Finder itself passed AMFI, dyld runtime-confirmed this exact on-disk
# image was the next rejected arm64e dependency.
ensure_project_signature_and_trustcache \
    '/var/mnt/rootfs/System/Library/PrivateFrameworks/TimelineUI.framework/Versions/A/TimelineUI' || exit 1
add_all_trustcache /var/mnt/rootfs/usr/lib/libobjc-trampolines.dylib
add_all_trustcache /var/mnt/rootfs/usr/lib/dyld
add_all_trustcache /var/mnt/rootfs/bin/ps
add_all_trustcache /var/mnt/rootfs/bin/mv
add_all_trustcache /var/mnt/rootfs/bin/cp
add_all_trustcache /var/mnt/rootfs/usr/bin/log
add_all_trustcache /var/mnt/rootfs/bin/launchctl
add_all_trustcache /var/mnt/rootfs/usr/bin/open
add_all_trustcache /var/jb/usr/macOS/bin/PingMTLCompilerService
add_all_trustcache /var/jb/usr/macOS/bin/launchdchrootexec
add_all_trustcache /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
add_all_trustcache /var/mnt/rootfs/System/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
add_all_trustcache /var/mnt/rootfs/System/Tweaks/TweakLoader.dylib
add_all_trustcache "/var/mnt/rootfs/System/Library/CoreServices/Installer Progress.app/Contents/MacOS/Installer Progress"
add_all_trustcache /var/mnt/rootfs/usr/lib/systemhook.dylib
add_all_trustcache /var/jb/usr/lib/libroot.dylib
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset_base
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/31001/Libraries/libGPUCompiler.dylib
add_all_trustcache /var/mnt/rootfs/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
# GlassDemo is launched directly by macwshostd before libmachook can ask
# autosignd for help. Its persistent signature survives reboot, while
# Dopamine's dynamic trustcache does not.
add_all_trustcache /var/mnt/rootfs/tmp/GlassDemo
add_all_trustcache /var/mnt/rootfs/usr/local/lib/.jbroot/usr/lib/libroot.dylib
# VS Code's main executable is not enough after a reboot: dyld must admit its
# Electron/Squirrel/Mantle/ReactiveObjC frameworks before any injected repair
# code can execute.  Keep this in postinst so macos_gui.sh's existing
# post-reboot self-heal restores the complete benchmark application too.
trust_existing_app_bundle \
    "/var/mnt/rootfs/Applications/Visual Studio Code.app" \
    "Visual Studio Code"
# vnc server
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent
add_all_trustcache /var/mnt/rootfs/bin/launchctl
add_all_trustcache /var/mnt/rootfs/bin/rm
add_all_trustcache /var/mnt/rootfs/bin/ls
add_all_trustcache /var/mnt/rootfs/bin/kill
add_all_trustcache /var/mnt/rootfs/bin/pwd
add_all_trustcache /var/mnt/rootfs/usr/bin/python3
add_all_trustcache /var/mnt/rootfs/usr/bin/defaults
add_all_trustcache /var/mnt/rootfs/usr/bin/perl
add_all_trustcache /var/mnt/rootfs/usr/bin/perl5.30
add_all_trustcache /var/mnt/rootfs/usr/bin/which
add_all_trustcache /var/mnt/rootfs/usr/bin/env
add_all_trustcache /var/mnt/rootfs/usr/bin/grep
add_all_trustcache /var/mnt/rootfs/usr/bin/vim
add_all_trustcache /var/mnt/rootfs/usr/bin/whoami
add_all_trustcache /var/mnt/rootfs/sbin/mount
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer
add_all_trustcache /var/mnt/rootfs/usr/local/bin/OSXvnc-server
sign_and_trustcache /var/mnt/rootfs/usr/libexec/pboard
sign_and_trustcache /var/mnt/rootfs/System/Library/CoreServices/pbs
if [ -d /var/mnt/rootfs/var/jb ] && [ ! "$(ls -A /var/mnt/rootfs/var/jb)" ]; then
	/var/jb/usr/local/bin/mount_bindfs /var/jb /var/mnt/rootfs/var/jb
fi

# Mount a writable devfs into the chroot /dev. Without it the rootfs /dev has no
# /dev/ptmx, so pty programs fail: Terminal.app -> forkpty -> open("/dev/ptmx")
# returns ENOENT ("forkpty: No such file or directory") and no shell spawns.
# mount_bindfs would expose the nodes read-only (ptmx O_RDWR -> EROFS) and the
# macOS mount_devfs is EPERM'd inside the chroot, so use our iOS-native helper.
# It is idempotent (no-op if /var/mnt/rootfs/dev is already a devfs).
if [ -x /var/jb/usr/macOS/bin/mountdevfs ]; then
	add_all_trustcache /var/jb/usr/macOS/bin/mountdevfs
	/var/jb/usr/macOS/bin/mountdevfs /var/mnt/rootfs/dev
fi

# ─── Homebrew / MacPorts: sign macOS rootfs utilities ─────────────────────────
# These binaries need re-signing because their Apple signatures are not in
# Dopamine's trustcache. sign_and_trustcache re-signs with our entitlements.plist
# and registers CDHashes — run once on first setup, then CDHashes are re-added
# on every reboot automatically.

ROOTFS=/var/mnt/rootfs

# Runtime `ps eww` on a fresh Terminal session shows that Terminal launches
# `/bin/bash` without `--login` and strips HOME/USER/SHELL from the child
# environment. This bash build did not consume a user startup file even when
# tested with explicit `--rcfile`; exec_hooks therefore sources the requested
# /Users/root/.bashrc in Terminal's direct shell prelude. Install loaders in
# root's ordinary non-login/login files as a fallback for sessions that do use
# standard bash startup processing after a reboot or a preference change.
TERMINAL_LOGIN_HOME="$ROOTFS/var/root"
TERMINAL_BASHRC_MARKER='# MacWS: load the interactive bash configuration'
mkdir -p "$TERMINAL_LOGIN_HOME"
# 0.3.4 briefly used BASH_ENV for this handoff. The production exec adapter
# now uses a Terminal-parent-scoped explicit prelude, so non-interactive child
# scripts remain untouched; remove only that exact obsolete managed file.
rm -f "$TERMINAL_LOGIN_HOME/.macws-terminal-env"

for TERMINAL_STARTUP_FILE in \
	"$TERMINAL_LOGIN_HOME/.bashrc" \
	"$TERMINAL_LOGIN_HOME/.bash_profile"
do
	if grep -Fq "$TERMINAL_BASHRC_MARKER" "$TERMINAL_STARTUP_FILE" 2>/dev/null; then
		continue
	fi
	if grep -Eq '(^|[[:space:]])(\.|source)[[:space:]]+/Users/root/\.bashrc' \
			"$TERMINAL_STARTUP_FILE" 2>/dev/null; then
		# Respect an existing user-owned integration. Appending our managed
		# block would source .bashrc twice and repeat aliases/PATH edits.
		continue
	fi
	{
		printf '\n%s\n' "$TERMINAL_BASHRC_MARKER"
		printf 'if [ -f /Users/root/.bashrc ]; then\n'
		printf '    . /Users/root/.bashrc\n'
		printf 'fi\n'
	} >> "$TERMINAL_STARTUP_FILE"
done
echo '[INFO] Terminal shells now source /Users/root/.bashrc'

# Core shell / execution helpers
sign_and_trustcache "$ROOTFS/bin/sh"
sign_and_trustcache "$ROOTFS/bin/chmod"
sign_and_trustcache "$ROOTFS/bin/mkdir"
sign_and_trustcache "$ROOTFS/bin/ln"
sign_and_trustcache "$ROOTFS/bin/cat"
sign_and_trustcache "$ROOTFS/bin/echo"

# Text processing
sign_and_trustcache "$ROOTFS/usr/bin/awk"
sign_and_trustcache "$ROOTFS/usr/bin/cut"
sign_and_trustcache "$ROOTFS/usr/bin/sed"
sign_and_trustcache "$ROOTFS/usr/bin/head"
sign_and_trustcache "$ROOTFS/usr/bin/tail"
sign_and_trustcache "$ROOTFS/usr/bin/tr"
sign_and_trustcache "$ROOTFS/usr/bin/sort"
sign_and_trustcache "$ROOTFS/usr/bin/uniq"
sign_and_trustcache "$ROOTFS/usr/bin/wc"
sign_and_trustcache "$ROOTFS/usr/bin/tee"
sign_and_trustcache "$ROOTFS/usr/bin/xargs"
sign_and_trustcache "$ROOTFS/usr/bin/grep"

# File / path utilities
sign_and_trustcache "$ROOTFS/usr/bin/find"
sign_and_trustcache "$ROOTFS/usr/bin/stat"
sign_and_trustcache "$ROOTFS/usr/bin/file"
sign_and_trustcache "$ROOTFS/usr/bin/readlink"
sign_and_trustcache "$ROOTFS/usr/bin/realpath"
sign_and_trustcache "$ROOTFS/usr/bin/install"
sign_and_trustcache "$ROOTFS/usr/bin/mktemp"
sign_and_trustcache "$ROOTFS/usr/bin/xcode-select"

# System info / privilege
sign_and_trustcache "$ROOTFS/usr/bin/uname"
sign_and_trustcache "$ROOTFS/usr/bin/sw_vers"
sign_and_trustcache "$ROOTFS/usr/bin/arch"
sign_and_trustcache "$ROOTFS/usr/bin/id"
sign_and_trustcache "$ROOTFS/usr/bin/date"
sign_and_trustcache "$ROOTFS/usr/bin/sudo"
sign_and_trustcache "$ROOTFS/usr/sbin/chown"

# Archive / compression
sign_and_trustcache "$ROOTFS/usr/bin/tar"
sign_and_trustcache "$ROOTFS/usr/bin/gzip"
sign_and_trustcache "$ROOTFS/usr/bin/bzip2"
sign_and_trustcache "$ROOTFS/usr/bin/xz"
sign_and_trustcache "$ROOTFS/usr/bin/zstd"
sign_and_trustcache "$ROOTFS/usr/bin/lz4"
sign_and_trustcache "$ROOTFS/usr/bin/unzip"

# Network
sign_and_trustcache "$ROOTFS/usr/bin/curl"
sign_and_trustcache "$ROOTFS/usr/bin/openssl"
sign_and_trustcache "$ROOTFS/usr/bin/rsync"

# Scripting runtimes
sign_and_trustcache "$ROOTFS/usr/bin/ruby"
sign_and_trustcache "$ROOTFS/usr/bin/git"

# Claude Code (native bun/JSC binary installed to /usr/local/bin/claude) and the
# macOS Keychain CLI it spawns for credential storage. See README "Running
# Claude Code in the chroot". Run with GIGACAGE_ENABLED=0 (see ~/.bashrc).
sign_and_trustcache "$ROOTFS/usr/local/bin/claude"
sign_and_trustcache "$ROOTFS/usr/bin/security"

# Portable Ruby (Homebrew's vendored Ruby 4.0.1)
PRUBY="$ROOTFS/opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.1"
sign_and_trustcache "$PRUBY/bin/ruby"
for bundle in \
    "lib/ruby/gems/4.0.0/extensions/arm64-darwin-20/4.0.0-static/fiddle-1.1.8/fiddle.bundle" \
    "lib/ruby/gems/4.0.0/extensions/arm64-darwin-20/4.0.0-static/debug-1.11.1/debug/debug.bundle" \
    "lib/ruby/gems/4.0.0/extensions/arm64-darwin-20/4.0.0-static/bootsnap-1.21.1/bootsnap/bootsnap.bundle" \
    "lib/ruby/gems/4.0.0/extensions/arm64-darwin-20/4.0.0-static/msgpack-1.8.0/msgpack/msgpack.bundle"
do
    sign_and_trustcache "$PRUBY/$bundle"
done

# MacPorts binaries and libraries (installed at /opt/local)
# Re-adds CDHashes on every reboot (signing is persistent, trustcache is not).
# On first install, run the bulk-sign loop in CLAUDE.md "Skills" to sign all Mach-O files.
if [ -d "$ROOTFS/opt/local" ]; then
    # Tcl interpreter (MacPorts uses tclsh internally; port binary is a wrapper script)
    sign_and_trustcache "$ROOTFS/opt/local/libexec/macports/bin/tclsh8.6"
    sign_and_trustcache "$ROOTFS/opt/local/bin/tclsh"
    sign_and_trustcache "$ROOTFS/opt/local/bin/tclsh9.0"

    # Confirmed-installed dependency libraries
    for lib in liblzma liblzma.5 libedit libedit.3 libffi libffi.8 \
                libintl libintl.8 libiconv libiconv.2 \
                libsqlite3 libsqlite3.0 libbz2 libbz2.1.0 libbz2.1 \
                libncurses libncurses.6 libncursesw libncursesw.6 \
                libmpdec libmpdec.4 libmpdec++ libmpdec++.4; do
        sign_and_trustcache "$ROOTFS/opt/local/lib/${lib}.dylib"
    done

    # Python 3.13 (confirmed working; installed via port install python313)
    PY313="$ROOTFS/opt/local/Library/Frameworks/Python.framework/Versions/3.13"
    sign_and_trustcache "$ROOTFS/opt/local/bin/python3.13"
    sign_and_trustcache "$PY313/bin/python3.13"
    sign_and_trustcache "$PY313/Resources/Python.app/Contents/MacOS/Python"
    sign_and_trustcache "$PY313/Python"

    # Python 3.13 extension modules and site-packages .so files
    # (also picks up any new .so files installed by pip)
    find "$PY313/lib" -type f \( -name "*.so" -o -name "*.dylib" \) 2>/dev/null \
        | while read f; do sign_and_trustcache "$f"; done

    # Re-register CDHashes for MacPorts Mach-O binaries/dylibs.
    # Only process files with Mach-O extensions to skip scripts/text files.
    echo "[INFO] Scanning MacPorts for Mach-O files..."
    MACHO_COUNT=0
    for dir in "$ROOTFS/opt/local/bin" "$ROOTFS/opt/local/sbin"; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*; do
            [ -f "$f" ] || continue
            # Skip shell scripts (check for #! or text files)
            head -c2 "$f" 2>/dev/null | grep -q '^#!' && continue
            sign_and_trustcache "$f"
            MACHO_COUNT=$((MACHO_COUNT + 1))
        done
    done
    # Process only .dylib, .so, .bundle in lib directories
    find "$ROOTFS/opt/local/lib" "$ROOTFS/opt/local/libexec" \
         -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.bundle" -o -name "*.a" \) \
         2>/dev/null | while read f; do
        sign_and_trustcache "$f"
        MACHO_COUNT=$((MACHO_COUNT + 1))
    done
    echo "[INFO] Processed $MACHO_COUNT MacPorts files"
fi
