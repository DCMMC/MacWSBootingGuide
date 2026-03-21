cd $(realpath $HOME/../..)/usr/macOS

ENT="/var/jb/usr/macOS/bin/entitlements.plist"

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
# Optimized: single ldid call to get all hashes, skip if all trusted.
sign_and_trustcache() {
    local path="$1"
    [ -f "$path" ] || return

    # Get all CDHashes in one ldid call (no -arch = all slices)
    local hashes
    hashes=$(ldid -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -z "$hashes" ] && return  # Not a Mach-O file

    # Check if ALL hashes are already trusted
    local dominated=1
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        if ! is_trusted "$h"; then
            dominated=0
            break
        fi
    done <<< "$hashes"

    if [ "$dominated" -eq 1 ]; then
        return 0  # Silent skip - all trusted
    fi

    # Sign and get new hashes
    ldid -S"$ENT" -M "$path" 2>/dev/null || return
    hashes=$(ldid -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)

    # Add all hashes
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        trust_cdhash "$h" "$path" "all"
    done <<< "$hashes"
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

add_trustcache "/var/jb/usr/macOS/bin/login"
add_trustcache "/var/jb/usr/macOS/bin/TestMetalIOSurface"
add_all_trustcache "/var/jb/usr/macOS/lib/libmachook.dylib"
add_all_trustcache "/var/jb/usr/macOS/bin/launchdchrootexec"
add_all_trustcache "/var/jb/usr/macOS/bin/launchdchrootexec_debug"
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
if [ ! -e "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib" ]; then
	cp -vf /var/jb/usr/macOS/Frameworks/launchservicesd.dylib "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib"
fi
add_all_trustcache "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib"
add_all_trustcache "/var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
add_all_trustcache /var/jb/usr/macOS/bin/HostInjectBootstrap
add_all_trustcache /var/mnt/rootfs/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService
add_all_trustcache /System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService
cp -vf /var/jb/usr/macOS/lib/libmachook.dylib /var/mnt/rootfs/usr/local/lib/libmachook.dylib
add_all_trustcache /var/mnt/rootfs/usr/local/lib/libmachook.dylib
add_all_trustcache '/var/mnt/rootfs/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor'
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
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/ServicePlugins/IOHIDEventServicePlugin.plugin/Contents/MacOS/IOHIDEventServicePlugin
add_all_trustcache "/var/mnt/rootfs/System/Library/CoreServices/Installer Progress.app/Contents/MacOS/Installer Progress"
add_all_trustcache /var/mnt/rootfs/usr/lib/systemhook.dylib
add_all_trustcache /var/jb/usr/lib/libroot.dylib
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset_base
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/AppleSPUHIDStatistics.plugin/Contents/MacOS/AppleSPUHIDStatistics
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/IOHIDEventSystemStatistics.plugin/Contents/MacOS/IOHIDEventSystemStatistics
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/IOHIDNXEventTranslatorSessionFilter.plugin/Contents/MacOS/IOHIDNXEventTranslatorSessionFilter
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/IOHIDDFREventFilter.plugin/Contents/MacOS/IOHIDDFREventFilter
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/SessionFilters/IOHIDRemoteSensorSessionFilter.plugin/Contents/MacOS/IOHIDRemoteSensorSessionFilter
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/SessionFilters/IOAnalytics.plugin/Contents/MacOS/IOAnalytics
# add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/TouchBarEvent.bundle
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/31001/Libraries/libGPUCompiler.dylib
add_all_trustcache /var/mnt/rootfs/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
add_all_trustcache /var/mnt/rootfs/usr/local/lib/.jbroot/usr/lib/libroot.dylib
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
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/ardpackage
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/build_hd_index
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/distnotifyutil
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/sysinfocachegen
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/tccstate
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/Remote\ Desktop\ Message.app/Contents/MacOS/Remote\ Desktop\ Message
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/Remote\ Desktop\ Message.app/Contents/MacOS/Remote\ Desktop\ Message
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/Shared\ Screen\ Viewer.app/Contents/MacOS/Shared\ Screen\ Viewer
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer
add_all_trustcache /var/mnt/rootfs/usr/local/bin/OSXvnc-server
if [ -d /var/mnt/rootfs/var/jb ] && [ ! "$(ls -A /var/mnt/rootfs/var/jb)" ]; then
	/var/jb/usr/local/bin/mount_bindfs /var/jb /var/mnt/rootfs/var/jb
fi

# ─── Homebrew / MacPorts: sign macOS rootfs utilities ─────────────────────────
# These binaries need re-signing because their Apple signatures are not in
# Dopamine's trustcache. sign_and_trustcache re-signs with our entitlements.plist
# and registers CDHashes — run once on first setup, then CDHashes are re-added
# on every reboot automatically.

ROOTFS=/var/mnt/rootfs

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