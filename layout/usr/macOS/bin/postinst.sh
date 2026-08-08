cd $(realpath $HOME/../..)/usr/macOS

# Invalidate the same-bootsession Settings ExtensionKit verification cache
# before an installation can replace any of its signed runtime dependencies.
rm -f /var/jb/var/mobile/macws-settings-runtime.boot-ready

ENT="/var/jb/usr/macOS/bin/entitlements.plist"
CFPREFSD_ENT="/var/jb/usr/macOS/bin/cfprefsd-entitlements.plist"
EXTENSIONKIT_ENT="/var/jb/usr/macOS/bin/extensionkitservice-entitlements.plist"
APPEARANCE_ENT="/var/jb/usr/macOS/bin/appearance-extension-entitlements.plist"
CORELOCATIONAGENT_NATIVE_ENT="/var/jb/usr/macOS/bin/corelocationagent-native-entitlements.plist"
LOCATIOND_NATIVE_ENT="/var/jb/usr/macOS/bin/locationd-native-entitlements.plist"
GEOD_NATIVE_ENT="/var/jb/usr/macOS/bin/geod-native-entitlements.plist"
INTEROP_LOCATION_ENT="/var/jb/usr/macOS/bin/interop-location-entitlements.plist"
CODE_REQUIREMENT_WRITER="/var/jb/usr/macOS/bin/write_code_requirement.py"

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

# CoreLocationAgent refuses UUID registration unless the client has a real
# designated requirement and that requirement validates against the live
# process. ldid's default ad-hoc requirement contains certificate predicates
# that cannot hold without a signing certificate; generic -S signing can also
# leave no extractable requirement at all. Embed the explicit identifier
# requirement through ldid's raw -Q contract, then trust the resulting hashes.
# Do not re-sign a correct persistent image merely because Dopamine's dynamic
# trustcache was cleared by reboot.
sign_and_trustcache_with_identifier_requirement() {
    local path="$1"
    local identifier="$2"
    [ -f "$path" ] || return 0
    [ -f "$CODE_REQUIREMENT_WRITER" ] || return 1

    local needs_signature=0 current_entitlements="" requirement_file=""
    current_entitlements=$(ldid -e "$path" 2>/dev/null || true)
    printf '%s\n' "$current_entitlements" |
        grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>' ||
        needs_signature=1
    ldid -h "$path" 2>/dev/null |
        grep -Fqx "Identifier=$identifier" || needs_signature=1
    ldid -q "$path" 2>/dev/null | strings |
        grep -Fqx "$identifier" || needs_signature=1

    if [ "$needs_signature" -eq 1 ]; then
        requirement_file="/tmp/macws-code-requirement.$$.bin"
        /var/jb/usr/bin/python3 "$CODE_REQUIREMENT_WRITER" \
            "$identifier" "$requirement_file" || return 1
        ldid -I"$identifier" -Q"$requirement_file" -S"$ENT" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        ldid -I"$identifier" -Q"$requirement_file" -S"$ENT" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        rm -f "$requirement_file"
    fi

    ldid -q "$path" 2>/dev/null | strings |
        grep -Fqx "$identifier" || return 1
    local arch h
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null |
            grep CDHash= | cut -c8-)
        [ -n "$h" ] && trust_cdhash "$h" "$path" "$arch"
    done
}

# ExtensionKit's service is admitted before autosignd can participate and its
# native private entitlements are part of the service contract.  The generic
# MacWS profile drops those rights, while the stock macOS signature is rejected
# by the iPadOS launch-constraint policy.  Preserve the service-specific
# profile and use two ldid passes so the final CodeDirectory describes the
# settled __LINKEDIT layout.
sign_and_trustcache_with_entitlements() {
    local path="$1"
    local entitlements="$2"
    local required_marker="${3:-<key>com.apple.private.extensionkit.host.any-extension</key>}"
    local identifier="${4:-}"
    [ -f "$path" ] || return 0
    [ -f "$entitlements" ] || return 1

    local hashes="" h dominated=1
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && hashes="$hashes $h"
    done
    for h in $hashes; do
        if ! is_trusted "$h"; then
            dominated=0
            break
        fi
    done
    if [ -n "$hashes" ] && [ "$dominated" -eq 1 ] &&
       ldid -e "$path" 2>/dev/null |
           grep -Fq "$required_marker"; then
        if [ -z "$identifier" ] ||
           ldid -h "$path" 2>/dev/null |
               grep -Fqx "Identifier=$identifier"; then
            return 0
        fi
    fi

    if [ -n "$identifier" ]; then
        ldid -I"$identifier" -S"$entitlements" -M "$path" || return 1
        ldid -I"$identifier" -S"$entitlements" -M "$path" || return 1
    else
        ldid -S"$entitlements" -M "$path" || return 1
        ldid -S"$entitlements" -M "$path" || return 1
    fi
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && trust_cdhash "$h" "$path" "$arch"
    done
    # A thin binary legitimately has no hash for the final probed
    # architectures.  Do not let the last false `[ -n "$h" ]` turn an
    # otherwise successful signing/trust operation into a function failure.
    return 0
}

# A stock service can need both its native private protocol rights and the
# MacWS admission/injection profile.  `ldid -M` merges the second profile into
# the current signature; signing with either profile alone drops the other
# half and reproduces an early sandbox or launch-constraint kill.  Validate
# both markers and the identifier before treating a persistent signature as a
# cold-start witness.  Callers that are themselves verified by a stock macOS
# agent can request an explicit identifier-only designated requirement; ldid's
# synthesized ad-hoc default contains certificate predicates that can never
# validate for our unsigned image.
sign_and_trustcache_merging_native_entitlements() {
    local path="$1"
    local native_entitlements="$2"
    local native_marker="$3"
    local identifier="$4"
    local explicit_requirement="${5:-0}"
    [ -f "$path" ] || return 0
    [ -f "$native_entitlements" ] || return 1

    local hashes="" h dominated=1 current_entitlements="" requirement_valid=1
    current_entitlements=$(ldid -e "$path" 2>/dev/null || true)
    if [ "$explicit_requirement" -eq 1 ]; then
        ldid -q "$path" 2>/dev/null | strings |
            grep -Fqx "$identifier" || requirement_valid=0
        if ldid -q "$path" 2>/dev/null | strings |
            grep -Fq 'subject.CN'; then
            requirement_valid=0
        fi
    fi
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && hashes="$hashes $h"
    done
    for h in $hashes; do
        if ! is_trusted "$h"; then
            dominated=0
            break
        fi
    done
    if [ -n "$hashes" ] && [ "$dominated" -eq 1 ] &&
       [ "$requirement_valid" -eq 1 ] &&
       printf '%s\n' "$current_entitlements" |
           grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>' &&
       printf '%s\n' "$current_entitlements" | grep -Fq "$native_marker" &&
       ldid -h "$path" 2>/dev/null |
           grep -Fqx "Identifier=$identifier"; then
        return 0
    fi

    if [ "$explicit_requirement" -eq 1 ]; then
        local requirement_file="/tmp/macws-code-requirement.$$.bin"
        /var/jb/usr/bin/python3 "$CODE_REQUIREMENT_WRITER" \
            "$identifier" "$requirement_file" || return 1
        ldid -I"$identifier" -Q"$requirement_file" -S"$ENT" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        ldid -I"$identifier" -Q"$requirement_file" \
            -S"$native_entitlements" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        ldid -I"$identifier" -Q"$requirement_file" \
            -S"$native_entitlements" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        rm -f "$requirement_file"
    else
        ldid -I"$identifier" -S"$ENT" -M "$path" || return 1
        ldid -I"$identifier" -S"$native_entitlements" -M "$path" || return 1
        ldid -I"$identifier" -S"$native_entitlements" -M "$path" || return 1
    fi
    current_entitlements=$(ldid -e "$path" 2>/dev/null || true)
    printf '%s\n' "$current_entitlements" |
        grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>' || return 1
    printf '%s\n' "$current_entitlements" | grep -Fq "$native_marker" || return 1
    ldid -h "$path" 2>/dev/null |
        grep -Fqx "Identifier=$identifier" || return 1
    if [ "$explicit_requirement" -eq 1 ]; then
        ldid -q "$path" 2>/dev/null | strings |
            grep -Fqx "$identifier" || return 1
        ! ldid -q "$path" 2>/dev/null | strings |
            grep -Fq 'subject.CN' || return 1
    fi
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && trust_cdhash "$h" "$path" "$arch"
    done
    return 0
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

# Keep cfprefsd out of the generic project entitlement profile.  Runtime
# evidence on iPadOS 16.3 established both failure boundaries: the stock Apple
# image is rejected by AMFI CT policy 0x8, and adding the generic profile's
# com.apple.security.system-container makes sandbox_init kill the process.
# A private fresh-inode copy signed with this dedicated profile runs normally
# and can map the injected libmachook image.  Re-sign only if the persistent
# copy is absent or has the wrong identity/profile, avoiding obsolete CDHashes.
ensure_private_cfprefsd_and_trustcache() {
    local source_path='/var/mnt/rootfs/usr/sbin/cfprefsd'
    local target_path='/var/mnt/rootfs/usr/local/libexec/macws-cfprefsd'
    local temporary_root='/var/mnt/rootfs/private/var/.TemporaryItems'
    local temporary_user="$temporary_root/folders.0"
    local temporary_leaf="$temporary_user/TemporaryItems"
    local target_dir temporary needs_refresh=0 entitlements=''

    [ -f "$source_path" ] || return 1
    [ -f "$CFPREFSD_ENT" ] || return 1
    target_dir=${target_path%/*}
    mkdir -p "$target_dir" || return 1

    # RE-confirmed against Ventura CoreFoundation and the iPadOS 16.3
    # libsystem_coreservices implementation.  CFPDSource's atomic plist writer
    # calls _dirhelper_relative for the Preferences mount.  On this chroot's
    # mount topology it resolves to this exact three-level hierarchy and
    # rejects/misses it unless the modes are 01311, 0700, 0700 respectively.
    # Without it _CFPrefsTemporaryFDToWriteTo returns -1/ENOENT after the
    # target plist itself has already opened successfully.
    mkdir -p "$temporary_leaf" || return 1
    chown root:wheel "$temporary_root" "$temporary_user" "$temporary_leaf" \
        2>/dev/null || true
    chmod 1311 "$temporary_root" || return 1
    chmod 0700 "$temporary_user" "$temporary_leaf" || return 1

    if [ ! -f "$target_path" ]; then
        needs_refresh=1
    else
        entitlements=$(ldid -e "$target_path" 2>/dev/null || true)
        ldid -h "$target_path" 2>/dev/null |
            grep -q 'Identifier=com.macwsguide.cfprefsd' || needs_refresh=1
        printf '%s\n' "$entitlements" |
            grep -q '<key>com.apple.private.graphics-restart-no-kill</key>' || needs_refresh=1
        if printf '%s\n' "$entitlements" |
             grep -q '<key>com.apple.security.system-container</key>'; then
            needs_refresh=1
        fi
    fi

    if [ "$needs_refresh" -eq 1 ]; then
        temporary="${target_path}.new-$$"
        rm -f "$temporary"
        cp "$source_path" "$temporary" || return 1
        chmod 755 "$temporary" || return 1
        chown root:wheel "$temporary" 2>/dev/null || true
        ldid -Icom.macwsguide.cfprefsd -S"$CFPREFSD_ENT" "$temporary" || {
            rm -f "$temporary"
            return 1
        }
        mv -f "$temporary" "$target_path" || return 1
        echo "[INFO] installed dedicated private macOS cfprefsd"
    fi
    add_all_trustcache "$target_path"
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
        # Rootless package extraction can preserve the build account's uid.
        # launchd rejects a system-domain plist before the allocator ever gets
        # a chance to check in, so normalize and verify the real load result.
        chown root:wheel "$ALLOCD_PLIST" || exit 1
        chmod 0644 "$ALLOCD_PLIST" || exit 1
        launchctl unload "$ALLOCD_PLIST" 2>/dev/null || true
        if ! launchctl load "$ALLOCD_PLIST"; then
            echo "[ERROR] failed to load com.macwsguide.alloc launchd job" >&2
            exit 1
        fi
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
sign_and_trustcache_merging_native_entitlements \
    "/var/jb/usr/macOS/libexec/MacWSInteropService.app/Contents/MacOS/macwsinteropd" \
    "$INTEROP_LOCATION_ENT" \
    '<key>com.apple.locationd.simulation</key>' \
    'com.macwsguide.interopd' \
    1 || exit 1
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MetalSerializer.framework/MetalSerializer"
cp -vf /var/jb/usr/macOS/Frameworks/MetalSerializer.framework/MetalSerializer_macos /var/mnt/rootfs/usr/local/Frameworks/MetalSerializer.framework/MetalSerializer
add_all_trustcache /var/mnt/rootfs/usr/local/Frameworks/MetalSerializer.framework/MetalSerializer
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/MTLSimDriver"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimImplementation.framework/MTLSimImplementation"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc/MTLSimDriverHost"
# Theos rootless XPC bundles use a flat bundle layout.  Builds installed before
# the proxy was converted from a copied macOS bundle can leave a second
# `Contents/Info.plist` behind.  CoreFoundation then resolves that stale nested
# metadata instead of the new flat Info.plist, so xpc_add_bundle never sees the
# proxy's MachServices declaration.  Remove only that obsolete nested layout;
# the authoritative executable and Info.plist are at the bundle root.
VIEWBRIDGE_PROXY=/var/jb/usr/macOS/Frameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc
if [ -f "$VIEWBRIDGE_PROXY/Info.plist" ] &&
   [ -d "$VIEWBRIDGE_PROXY/Contents" ]; then
    rm -rf "$VIEWBRIDGE_PROXY/Contents"
    echo "[INFO] removed stale nested ViewBridge proxy bundle layout"
fi
VIEWBRIDGE_PROXY_EXEC="$VIEWBRIDGE_PROXY/ViewBridgeAuxiliary"
HISERVICES_PROXY_EXEC="/var/jb/usr/macOS/Frameworks/HIServices.framework/Versions/A/XPCServices/HIServicesProxy.xpc/HIServicesProxy"
OPEN_SAVE_PANEL_PROXY_EXEC="/var/jb/usr/macOS/Frameworks/AppKit.framework/Versions/C/XPCServices/OpenAndSavePanelProxy.xpc/OpenAndSavePanelProxy"
DOCK_HELPER_PROXY_EXEC="/var/jb/usr/macOS/Frameworks/Dock.framework/Versions/A/XPCServices/DockHelperProxy.xpc/DockHelperProxy"
GEOD_PROXY_EXEC="/var/jb/usr/macOS/PrivateFrameworks/GeoServices.framework/Versions/A/XPCServices/GeodProxy.xpc/GeodProxy"
WRITE_CONFIG_PROXY_EXEC="/var/jb/usr/macOS/PrivateFrameworks/SystemAdministration.framework/XPCServices/WriteConfigProxy.xpc/WriteConfigProxy"
LOCATIOND_PROXY_EXEC="/var/jb/usr/macOS/PrivateFrameworks/CoreLocation.framework/XPCServices/LocationdProxy.xpc/LocationdProxy"
add_all_trustcache "$VIEWBRIDGE_PROXY_EXEC"
add_all_trustcache "$HISERVICES_PROXY_EXEC"
add_all_trustcache "$OPEN_SAVE_PANEL_PROXY_EXEC"
add_all_trustcache "$DOCK_HELPER_PROXY_EXEC"
add_all_trustcache "$GEOD_PROXY_EXEC"
add_all_trustcache "$WRITE_CONFIG_PROXY_EXEC"
add_all_trustcache "$LOCATIOND_PROXY_EXEC"
add_all_trustcache "/var/jb/usr/macOS/bin/macwslocationd"
EXTENSIONKIT_PROXY="/var/jb/usr/macOS/Frameworks/ExtensionFoundation.framework/Versions/A/XPCServices/ExtensionKitProxy.xpc/ExtensionKitProxy"
add_all_trustcache "$EXTENSIONKIT_PROXY"
# These four services are launched as mobile-owned per-process XPC jobs, but
# share a freestanding first image that must chroot before libSystem/libxpc
# consumes launchd's one-shot context.  Runtime witness (2026-08-04): both
# ViewBridgeAuxiliary and ExtensionKitProxy in mode 0755 exited with the
# source-defined chroot-failure status 111; mode 4755 let the same images
# reach their real macOS targets.  Keep the privilege on these minimal launch
# stubs only and enforce the invariant for every consumer of main.c.
for proxy in \
    "$VIEWBRIDGE_PROXY_EXEC" \
    "$HISERVICES_PROXY_EXEC" \
    "$OPEN_SAVE_PANEL_PROXY_EXEC" \
    "$DOCK_HELPER_PROXY_EXEC" \
    "$EXTENSIONKIT_PROXY" \
    "$GEOD_PROXY_EXEC" \
    "$WRITE_CONFIG_PROXY_EXEC" \
    "$LOCATIOND_PROXY_EXEC"; do
    if [ -x "$proxy" ]; then
        chown root:wheel "$proxy"
        chmod 4755 "$proxy"
    fi
done
add_all_trustcache "/var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy"
if [ -x /var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy ]; then
    chown root:wheel /var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy
    chmod 4755 /var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy
    uicache -p /var/jb/Applications/SettingsExtensionProxy.app >/dev/null 2>&1 || true
fi
add_all_trustcache "/var/jb/usr/macOS/Frameworks/FileCoordination.framework/Versions/A/XPCServices/FileCoordinationProxy.xpc/FileCoordinationProxy"
# The flat iOS proxy bundles above are only the launch images visible to the
# iOS XPC service manager.  Their SETEXEC targets live inside the macOS rootfs
# and are admitted by iOS AMFI before libmachook/autosignd can run.  Runtime
# evidence on 2026-08-02: each proxy reached its chroot boundary, then the real
# target died before its first userspace log and the client received
# `Connection invalid`; none of the three real target CDHashes was present in
# the dynamic trustcache.  Persistently sign those upstream executables and
# restore their CDHashes on every postinst/re-jailbreak, exactly like the other
# initial process images below.
sign_and_trustcache "/var/mnt/rootfs/System/Library/PrivateFrameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc/Contents/MacOS/ViewBridgeAuxiliary"
sign_and_trustcache "/var/mnt/rootfs/System/Library/CoreServices/UIKitSystem.app/Contents/MacOS/UIKitSystem"
sign_and_trustcache "/var/mnt/rootfs/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/XPCServices/com.apple.hiservices-xpcservice.xpc/Contents/MacOS/com.apple.hiservices-xpcservice"
sign_and_trustcache "/var/mnt/rootfs/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService"
sign_and_trustcache_with_entitlements \
    "/var/mnt/rootfs/System/Library/Frameworks/ExtensionFoundation.framework/Versions/A/XPCServices/extensionkitservice.xpc/Contents/MacOS/extensionkitservice" \
    "$EXTENSIONKIT_ENT"
sign_and_trustcache_with_entitlements \
    "/var/mnt/rootfs/System/Library/ExtensionKit/Extensions/Appearance.appex/Contents/MacOS/Appearance" \
    "$APPEARANCE_ENT" \
    '<key>com.apple.security.exception.files.absolute-path.read-write</key>' \
    'com.apple.Appearance-Settings.extension'
sign_and_trustcache_merging_native_entitlements \
    "/var/mnt/rootfs/System/Library/CoreServices/CoreLocationAgent.app/Contents/MacOS/CoreLocationAgent" \
    "$CORELOCATIONAGENT_NATIVE_ENT" \
    '<key>com.apple.locationd.authorizeapplications</key>' \
    'com.apple.CoreLocationAgent' || exit 1
sign_and_trustcache_merging_native_entitlements \
    "/var/mnt/rootfs/usr/libexec/locationd" \
    "$LOCATIOND_NATIVE_ENT" \
    '<key>com.apple.private.security.storage.locationd</key>' \
    'com.apple.locationd' || exit 1
sign_and_trustcache_merging_native_entitlements \
    "/var/mnt/rootfs/System/Library/PrivateFrameworks/GeoServices.framework/Versions/A/XPCServices/com.apple.geod.xpc/Contents/MacOS/com.apple.geod" \
    "$GEOD_NATIVE_ENT" \
    '<key>com.apple.private.network.socket-delegate</key>' \
    'com.apple.geod' || exit 1
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

# Establish the complete arm64e loader closure before the first chroot exec
# below.  The signatures persist across a reboot, but Dopamine's dynamic
# trustcache does not.  Runtime-confirmed on 2026-08-05: invoking /bin/bash
# before these two hashes were restored produced, in order,
#
#   AMFI: '/usr/lib/dyld' has no CMS blob
#   Library not loaded: @rpath/CydiaSubstrate.framework/CydiaSubstrate
#
# and SIGKILL/abort before the later legacy registration block could run.
# Registering the existing dyld and chroot CydiaSubstrate CodeDirectories made
# the unchanged bash process complete normally.  Keep this upstream of the
# Ventura codesign calls rather than weakening their result checks.
add_all_trustcache /var/mnt/rootfs/usr/lib/dyld
add_all_trustcache \
	/var/mnt/rootfs/System/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate

# System Settings panes are real Ventura ExtensionKit executables launched
# through unique iOS first-image carriers. Keep every pane's native
# entitlements, bundle-local dependency closure, load commands, common service
# exceptions, runtime fingerprint and reboot-volatile trustcache in one
# idempotent helper shared with the package postinst.
bash /var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh || exit 1
# Package installation already paid the one-time signing/copying cost.  Deeply
# verify the completed closure now so the first GUI launch can reuse the exact
# bootsession/dependency witness instead of re-reading all 48 panes on its
# latency-sensitive path.  The verifier also writes the persistent trust-hash
# manifest used to restore the reboot-volatile dynamic trustcache.
bash /var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh --verify || exit 1

# Native-host input bridge.  Keep the installed source and the chroot-visible
# executable on fresh inodes so AMFI does not reuse a stale vnode signature.
if [ -f /var/jb/usr/macOS/bin/macwsinputd ]; then
	rm -f /var/mnt/rootfs/usr/local/bin/macwsinputd
	cp -vf /var/jb/usr/macOS/bin/macwsinputd /var/mnt/rootfs/usr/local/bin/macwsinputd
	chmod 755 /var/mnt/rootfs/usr/local/bin/macwsinputd
	add_all_trustcache /var/mnt/rootfs/usr/local/bin/macwsinputd
fi
# Keep the repair path subject to the same package/runtime compatibility
# invariant as DEBIAN/postinst.  Copying a stale single-pane controller over a
# newer chroot binary would make a reboot self-heal deterministically regress
# into the long `register-settings-extensions` failure loop.
if ! /var/jb/usr/bin/grep -aFq 'register-settings-extensions' \
		/var/jb/usr/macOS/bin/macwsworkspacectl 2>/dev/null; then
	echo 'ERROR: installed macwsworkspacectl lacks the all-settings startup contract.' >&2
	exit 1
fi
for bridge in macwsdisplayd macwsinteropd macwsworkspacectl; do
	if [ -f "/var/jb/usr/macOS/bin/$bridge" ]; then
		rm -f "/var/mnt/rootfs/usr/local/bin/$bridge"
		cp -vf "/var/jb/usr/macOS/bin/$bridge" "/var/mnt/rootfs/usr/local/bin/$bridge"
		chmod 755 "/var/mnt/rootfs/usr/local/bin/$bridge"
		add_all_trustcache "/var/mnt/rootfs/usr/local/bin/$bridge"
	fi
done
# Keep the CoreLocation client at a real bundle path.  CoreLocationAgent's
# copy_client_info routine skips designated-requirement extraction when both
# bundle identifier and bundle path are absent; the old /usr/local/bin daemon
# therefore remained permanently unverified even with a valid CodeDirectory.
INTEROP_BUNDLE_SOURCE=/var/jb/usr/macOS/libexec/MacWSInteropService.app/Contents
INTEROP_BUNDLE_TARGET=/var/mnt/rootfs/usr/local/libexec/MacWSInteropService.app/Contents
if [ -f "$INTEROP_BUNDLE_SOURCE/MacOS/macwsinteropd" ]; then
	mkdir -p "$INTEROP_BUNDLE_TARGET/MacOS"
	cp -f "$INTEROP_BUNDLE_SOURCE/Info.plist" \
		"$INTEROP_BUNDLE_TARGET/Info.plist"
	rm -f "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd"
	cp -f "$INTEROP_BUNDLE_SOURCE/MacOS/macwsinteropd" \
		"$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd"
	chmod 644 "$INTEROP_BUNDLE_TARGET/Info.plist"
	chmod 755 "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd"
	# CoreLocationAgent validates the live client through macOS Security.
	# ldid's embedded signature is sufficient for AMFI but Ventura Security
	# reports it as an unsupported live Code object.  Re-seal the complete
	# chroot bundle with Ventura's own ad-hoc signer so Info.plist, resources,
	# entitlements, identifier and the explicit identifier-only requirement are
	# represented in the native macOS CodeDirectory.  Runtime-confirmed on the
	# target: strict verification passes, flags=0x2(adhoc), and repeated signing
	# produces the same CDHash.
	/var/jb/usr/macOS/bin/launchdchrootexec 0 0 /var/mnt/rootfs \
		/usr/bin/codesign --force --sign - --timestamp=none \
		--preserve-metadata=identifier,entitlements,requirements \
		/usr/local/libexec/MacWSInteropService.app || exit 1
	/var/jb/usr/macOS/bin/launchdchrootexec 0 0 /var/mnt/rootfs \
		/usr/bin/codesign --verify --strict --verbose=2 \
		/usr/local/libexec/MacWSInteropService.app || exit 1
	ldid -e "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd" 2>/dev/null |
		grep -Fq '<key>com.apple.locationd.simulation</key>' || exit 1
	ldid -h "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd" 2>/dev/null |
		grep -Fqx 'Identifier=com.macwsguide.interopd' || exit 1
	add_all_trustcache "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd"
fi
# LaunchServices' FSNode layer receives the kernel mount name for the macOS
# filesystem even after launchdchrootexec has changed the process root.  On the
# target device its real database therefore records bundle paths below
# `/rootfs` (for example `/rootfs/System/Applications/Launchpad.app`).  The
# matching runtime dump reports "Bundle node not found on disk" unless that
# kernel-visible mount name also resolves inside the chroot.  Keep a single,
# exact namespace alias to the logical process root; do not overwrite any real
# path a user may already have created.
if [ ! -e /var/mnt/rootfs/rootfs ] && [ ! -L /var/mnt/rootfs/rootfs ]; then
	ln -s / /var/mnt/rootfs/rootfs
elif [ -L /var/mnt/rootfs/rootfs ] &&
     [ "$(readlink /var/mnt/rootfs/rootfs 2>/dev/null)" != / ]; then
	echo '[ERROR] /var/mnt/rootfs/rootfs exists but does not target /' >&2
	exit 1
fi
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
# The chroot has no loginwindow trust/bootstrap handoff. These are direct
# outer-launchd targets, so each top-level executable must already satisfy the
# same project signing policy before libmachook/autosignd can run. Their stock
# code and service contracts remain intact; this only makes the launch targets
# admissible on the iOS kernel and restores dynamic trust after a reboot.
for workspace_binary in \
    '/var/mnt/rootfs/usr/libexec/lsd' \
    '/var/mnt/rootfs/System/Library/CoreServices/iconservicesd' \
    '/var/mnt/rootfs/System/Library/CoreServices/iconservicesagent' \
    '/var/mnt/rootfs/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock' \
    '/var/mnt/rootfs/System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper' \
    '/var/mnt/rootfs/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/CarbonCore.framework/Versions/A/XPCServices/csnameddatad.xpc/Contents/MacOS/csnameddatad' \
    '/var/mnt/rootfs/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer' \
    '/var/mnt/rootfs/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter' \
    '/var/mnt/rootfs/System/Applications/Launchpad.app/Contents/MacOS/Launchpad'; do
    ensure_project_signature_and_trustcache "$workspace_binary" || exit 1
done
ensure_private_cfprefsd_and_trustcache || exit 1
# Finder's TimelineUI dependency is not present in the iOS dyld shared cache.
# Once Finder itself passed AMFI, dyld runtime-confirmed this exact on-disk
# image was the next rejected arm64e dependency.
ensure_project_signature_and_trustcache \
    '/var/mnt/rootfs/System/Library/PrivateFrameworks/TimelineUI.framework/Versions/A/TimelineUI' || exit 1
# The chroot has no loginwindow LaunchAgent domain, so macos_gui.sh publishes
# the stock fontd's original com.apple.fonts services through an outer launchd
# job. Like Finder, this top-level launch target must already pass AMFI before
# libmachook can run. Preserve its project signature and restore its CDHash on
# every post-reboot repair.
ensure_project_signature_and_trustcache \
    '/var/mnt/rootfs/System/Library/Frameworks/ApplicationServices.framework/Frameworks/ATS.framework/Support/fontd' || exit 1
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
sign_and_trustcache '/var/mnt/rootfs/System/Applications/System Settings.app/Contents/MacOS/System Settings'
sign_and_trustcache_with_identifier_requirement \
    '/var/mnt/rootfs/System/Applications/Maps.app/Contents/MacOS/Maps' \
    'com.apple.Maps' || exit 1
# GlassDemo is launched directly by macwshostd before libmachook can ask
# autosignd for help. Its persistent signature survives reboot, while
# Dopamine's dynamic trustcache does not.
add_all_trustcache /var/mnt/rootfs/tmp/GlassDemo
add_all_trustcache /var/mnt/rootfs/usr/local/lib/.jbroot/usr/lib/libroot.dylib
# A user application's main executable is not enough after a reboot: dyld must
# admit its nested frameworks before libmachook/autosignd has a chance to run.
# VS Code first exposed this with Electron/Squirrel/Mantle/ReactiveObjC, but the
# invariant applies equally to newly installed AppKit and Electron bundles.
# Restore every *already-signed* executable in /Applications so launch-by-path
# remains cold-boot safe without growing a hard-coded application list.
for application_bundle in /var/mnt/rootfs/Applications/*.app; do
    [ -d "$application_bundle" ] || continue
    trust_existing_app_bundle \
        "$application_bundle" \
        "$(basename "$application_bundle" .app)"
done
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

# Ventura QuartzCore's real desktop-window-effects shaders are compiled for a
# macOS AIR target, while this project intentionally executes them on the iOS
# native AGX driver. Preserve the original system library as the process-wide
# default and build a secondary library in which only the nine
# runtime-confirmed failing functions carry a macabi AIR triple. libmachook
# forwards the original function constants when present and redirects the four
# zero-constant base functions unchanged; it does not bypass compilation or
# pipeline validation.
QC_DEFAULT="$ROOTFS/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"
QC_ORIGINAL="$QC_DEFAULT.macws-macos13.4-original"
QC_EXPECTED_SHA256=ac8014164c7784395f86ac2926c62b67c96faa2a3c789f231b4b22b64024bfba
QC_COMPAT_DIR="$ROOTFS/usr/local/share/macws/quartzcore"
QC_COMPAT_TARGET="$QC_COMPAT_DIR/default-desktop-effects-macabi.metallib"
QC_COMPAT_EXPECTED_SHA256=0cc979fb9a44ca2b7675bb73fcae02bbfa472f7498aa51bd543229927392f8e2
QC_REPACKER=/var/jb/usr/macOS/bin/repack_metallib_macabi.py
QC_LLVM_DIS=/var/jb/usr/lib/llvm-16/bin/llvm-dis
QC_LLVM_AS=/var/jb/usr/lib/llvm-16/bin/llvm-as

qc_sha256() {
	sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

if [ "$(qc_sha256 "$QC_ORIGINAL")" != "$QC_EXPECTED_SHA256" ]; then
	if [ "$(qc_sha256 "$QC_DEFAULT")" != "$QC_EXPECTED_SHA256" ]; then
		echo "[ERROR] QuartzCore default.metallib is not the supported macOS 13.4 library." >&2
		exit 1
	fi
	cp "$QC_DEFAULT" "$QC_ORIGINAL.new.$$" || exit 1
	chmod 0644 "$QC_ORIGINAL.new.$$" || exit 1
	mv -f "$QC_ORIGINAL.new.$$" "$QC_ORIGINAL" || exit 1
fi

# Undo an interrupted diagnostic replacement before any GUI process can see it.
if [ "$(qc_sha256 "$QC_DEFAULT")" != "$QC_EXPECTED_SHA256" ]; then
	cp "$QC_ORIGINAL" "$QC_DEFAULT.new.$$" || exit 1
	chmod 0644 "$QC_DEFAULT.new.$$" || exit 1
	mv -f "$QC_DEFAULT.new.$$" "$QC_DEFAULT" || exit 1
fi

if [ ! -f "$QC_REPACKER" ] || [ ! -x "$QC_LLVM_DIS" ] ||
   [ ! -x "$QC_LLVM_AS" ]; then
	echo "[ERROR] QuartzCore macabi repacker or device LLVM 16 is unavailable." >&2
	exit 1
fi
mkdir -p "$QC_COMPAT_DIR" || exit 1
QC_COMPAT_TMP="$QC_COMPAT_TARGET.new.$$"
python3 "$QC_REPACKER" "$QC_ORIGINAL" "$QC_COMPAT_TMP" \
	--llvm-dis "$QC_LLVM_DIS" --llvm-as "$QC_LLVM_AS" \
	--function fixed_vert_lph_spc \
	--function fixed_vert_lph_gen \
	--function fixed_frag_lph_cpf \
	--function path_blit_vert_lph \
	--function attachment_clear_frag_lph \
	--function std_vert1_lph \
	--function inplace_copy_lph \
	--function downsample_blur_vert_lph \
	--function downsample_8_frag_lph \
	--rewrite-fract-v3f16-function fixed_frag_lph_cpf \
	--preserve-container-target || exit 1
if [ "$(qc_sha256 "$QC_COMPAT_TMP")" != "$QC_COMPAT_EXPECTED_SHA256" ]; then
	echo "[ERROR] Generated QuartzCore desktop-effects library failed exact validation." >&2
	exit 1
fi
chmod 0644 "$QC_COMPAT_TMP" || exit 1
mv -f "$QC_COMPAT_TMP" "$QC_COMPAT_TARGET" || exit 1
echo '[INFO] installed exact QuartzCore desktop-effects macabi shader library'

# SkyLight's desktop backing-window path has a second, independently
# Runtime-confirmed target mismatches exist for the ordinary
# SimpleVertex/SimpleTextureFragment pair and for the UberCompositeFragment
# specialization reached when Mission Control snapshots a real application
# window. Generate a separate three-function compatibility library from the
# exact Ventura 13.4 source; never replace SkyLight's process-wide library.
SKY_DEFAULT="$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib"
SKY_EXPECTED_SHA256=378174fcbf7fc639aa737cad7a765690b2d76fa3a66c7a8e71018441f3ac3184
SKY_COMPAT_DIR="$ROOTFS/usr/local/share/macws/skylight"
SKY_COMPAT_TARGET="$SKY_COMPAT_DIR/SkyLightShaders-desktop-effects-macabi.metallib"
SKY_COMPAT_EXPECTED_SHA256=990803db710c494ff98155983cc9d3134c131e1ddbf3ce9e4468a3013134ffd6
if [ "$(qc_sha256 "$SKY_DEFAULT")" != "$SKY_EXPECTED_SHA256" ]; then
	echo "[ERROR] SkyLightShaders.air64.metallib is not the supported macOS 13.4 library." >&2
	exit 1
fi
mkdir -p "$SKY_COMPAT_DIR" || exit 1
SKY_COMPAT_TMP="$SKY_COMPAT_TARGET.new.$$"
python3 "$QC_REPACKER" "$SKY_DEFAULT" "$SKY_COMPAT_TMP" \
	--llvm-dis "$QC_LLVM_DIS" --llvm-as "$QC_LLVM_AS" \
	--function SimpleVertex \
	--function SimpleTextureFragment \
	--function UberCompositeFragment \
	--preserve-container-target || exit 1
if [ "$(qc_sha256 "$SKY_COMPAT_TMP")" != "$SKY_COMPAT_EXPECTED_SHA256" ]; then
	echo "[ERROR] Generated SkyLight desktop-effects library failed exact validation." >&2
	exit 1
fi
chmod 0644 "$SKY_COMPAT_TMP" || exit 1
mv -f "$SKY_COMPAT_TMP" "$SKY_COMPAT_TARGET" || exit 1
echo '[INFO] installed exact SkyLight desktop-effects macabi shader library'

# MPSImage supplies the real desktop-effects reduction kernel reached after
# SkyLight's desktop surface pipelines are available. The exact runtime
# failures are sum_rgba_columns and sum_rgba_rows with a macOS AIR target;
# both report no function constants against the exact Ventura library, so
# libmachook redirects only base-function creation to this byte-validated
# selective macabi library.
MPSIMAGE_DEFAULT="$ROOTFS/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSImage.framework/Versions/A/Resources/default.metallib"
MPSIMAGE_EXPECTED_SHA256=376ded7ee154429f6950656eb668b26af27fc6149b734b11dd48a33d68fe4285
MPSIMAGE_COMPAT_DIR="$ROOTFS/usr/local/share/macws/mpsimage"
MPSIMAGE_COMPAT_TARGET="$MPSIMAGE_COMPAT_DIR/default-desktop-effects-macabi.metallib"
MPSIMAGE_COMPAT_EXPECTED_SHA256=0187b2e6f58659e9974680c1b82d15d393d99f5feb3be85451043c33861b1496
if [ "$(qc_sha256 "$MPSIMAGE_DEFAULT")" != "$MPSIMAGE_EXPECTED_SHA256" ]; then
	echo "[ERROR] MPSImage default.metallib is not the supported macOS 13.4 library." >&2
	exit 1
fi
mkdir -p "$MPSIMAGE_COMPAT_DIR" || exit 1
MPSIMAGE_COMPAT_TMP="$MPSIMAGE_COMPAT_TARGET.new.$$"
python3 "$QC_REPACKER" "$MPSIMAGE_DEFAULT" "$MPSIMAGE_COMPAT_TMP" \
	--llvm-dis "$QC_LLVM_DIS" --llvm-as "$QC_LLVM_AS" \
	--function sum_rgba_columns \
	--function sum_rgba_rows \
	--preserve-container-target || exit 1
if [ "$(qc_sha256 "$MPSIMAGE_COMPAT_TMP")" != "$MPSIMAGE_COMPAT_EXPECTED_SHA256" ]; then
	echo "[ERROR] Generated MPSImage desktop-effects library failed exact validation." >&2
	exit 1
fi
chmod 0644 "$MPSIMAGE_COMPAT_TMP" || exit 1
mv -f "$MPSIMAGE_COMPAT_TMP" "$MPSIMAGE_COMPAT_TARGET" || exit 1
echo '[INFO] installed exact MPSImage desktop-effects macabi shader library'

# Chromium 148 / Electron 42 ships ANGLE's default Metal library for macOS.
# Its container loads in the chroot, but iOS MTLCompilerService rejects
# function-constant specialization with "Target OS is incompatible". Install
# the byte-validated replacement built from the exact ANGLE 1ba8ec3 generated
# source through the project's real macabi compiler adapter. libmachook selects
# it only when the original embedded library's length+FNV hash match.
ANGLE_MACABI_SOURCE=/var/jb/usr/macOS/share/angle/angle-default-1ba8ec3-macabi.metallib
ANGLE_MACABI_DIR="$ROOTFS/usr/local/share/macws/angle"
ANGLE_MACABI_TARGET="$ANGLE_MACABI_DIR/angle-default-1ba8ec3-macabi.metallib"
if [ ! -f "$ANGLE_MACABI_SOURCE" ] ||
   [ "$(wc -c < "$ANGLE_MACABI_SOURCE" 2>/dev/null)" != 714152 ]; then
	echo "[ERROR] Packaged ANGLE macabi default library is missing or invalid." >&2
	exit 1
fi
mkdir -p "$ANGLE_MACABI_DIR" || exit 1
ANGLE_MACABI_TMP="$ANGLE_MACABI_TARGET.new.$$"
cp "$ANGLE_MACABI_SOURCE" "$ANGLE_MACABI_TMP" || exit 1
chmod 0644 "$ANGLE_MACABI_TMP" || exit 1
mv -f "$ANGLE_MACABI_TMP" "$ANGLE_MACABI_TARGET" || exit 1
echo '[INFO] installed ANGLE 1ba8ec3 macabi default Metal library'

# Metal's on-disk source-library cache key omits the effective target triple.
# Caches created before the MacWS macabi source adapter therefore contain
# valid MTLBs for iOS that the macOS AGX device rejects. Version this narrow,
# regenerable cache independently from Chromium's profile/session caches.
VSCODE_METAL_CACHE_ROOT="$ROOTFS/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/C/com.microsoft.VSCode.helper/com.apple.metal"
VSCODE_METAL_LIBRARY_CACHE="$VSCODE_METAL_CACHE_ROOT/31001"
VSCODE_METAL_CACHE_SCHEMA=macws-macabi-source-v1
VSCODE_METAL_CACHE_MARKER="$VSCODE_METAL_CACHE_ROOT/.macws-source-target-schema"

invalidate_vscode_metal_source_cache() {
	local installed_schema="" marker_tmp=""
	[ -d "$ROOTFS/Applications/Visual Studio Code.app" ] || return 0
	[ ! -f "$VSCODE_METAL_CACHE_MARKER" ] ||
		installed_schema=$(sed -n '1p' "$VSCODE_METAL_CACHE_MARKER" 2>/dev/null)
	[ "$installed_schema" != "$VSCODE_METAL_CACHE_SCHEMA" ] || return 0

	# postinst can be invoked manually. Do not unlink an active helper's
	# mmap-backed cache: leave the marker absent and macos_gui.sh will perform
	# the same migration after its normal exact-process cleanup.
	if ps ax -o command= 2>/dev/null |
	   grep -E '[V]isual Studio Code\.app|[C]ode Helper' >/dev/null; then
		rm -f "$VSCODE_METAL_CACHE_MARKER"
		echo "[INFO] VS Code is running; deferred Metal source-cache migration to the next GUI start."
		return 0
	fi

	mkdir -p "$VSCODE_METAL_CACHE_ROOT" || return 1
	rm -f "$VSCODE_METAL_LIBRARY_CACHE/libraries.list" \
	      "$VSCODE_METAL_LIBRARY_CACHE/libraries.data" || return 1
	marker_tmp="$VSCODE_METAL_CACHE_MARKER.$$"
	printf '%s\n' "$VSCODE_METAL_CACHE_SCHEMA" > "$marker_tmp" || return 1
	mv -f "$marker_tmp" "$VSCODE_METAL_CACHE_MARKER" || return 1
	echo "[INFO] VS Code Metal source cache migrated to $VSCODE_METAL_CACHE_SCHEMA."
}

invalidate_vscode_metal_source_cache || {
	echo "[ERROR] Failed to migrate the VS Code Metal source cache." >&2
	exit 1
}

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
