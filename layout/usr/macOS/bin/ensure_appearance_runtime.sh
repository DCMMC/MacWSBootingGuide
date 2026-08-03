# No shebang: iPadOS AMFI rejects execve of shebang scripts in this setup.
# Invoke with: bash /var/jb/usr/macOS/bin/ensure_appearance_runtime.sh

set -e

ROOTFS=/var/mnt/rootfs
APPEARANCE_CONTENTS="$ROOTFS/System/Library/ExtensionKit/Extensions/Appearance.appex/Contents"
APPEARANCE="$APPEARANCE_CONTENTS/MacOS/Appearance"
FRAMEWORKS="$APPEARANCE_CONTENTS/Frameworks"
LIBMACHOOK=/var/jb/usr/macOS/lib/libmachook.dylib
SUBSTRATE=/var/jb/usr/lib/libellekit.dylib
TRAMPOLINES="$ROOTFS/usr/lib/libobjc-trampolines.dylib"
MACHO_PATCHER=/var/jb/usr/macOS/bin/set_macos_version.py
LOAD_PATCHER=/var/jb/usr/macOS/bin/add_macho_load_dylib.py
APPEARANCE_ENT=/var/jb/usr/macOS/bin/appearance-extension-entitlements.plist
LDID=/var/jb/usr/bin/ldid
JBCTL=/var/jb/usr/bin/jbctl
OTOOL=/var/jb/usr/bin/otool

if [ ! -d "$ROOTFS/System/Library" ]; then
    echo '[INFO] Appearance runtime deferred: macOS rootfs is not mounted'
    exit 0
fi
for required in "$APPEARANCE" "$LIBMACHOOK" "$SUBSTRATE" \
                "$TRAMPOLINES" "$MACHO_PATCHER" "$LOAD_PATCHER" \
                "$APPEARANCE_ENT"; do
    if [ ! -f "$required" ]; then
        echo "[ERROR] Appearance runtime prerequisite missing: $required" >&2
        exit 1
    fi
done

trust_macho() {
    local path="$1" arch hash
    for arch in arm64 arm64e x86_64; do
        hash=$($LDID -arch "$arch" -h "$path" 2>/dev/null |
            grep CDHash= | cut -c8-)
        [ -n "$hash" ] && $JBCTL trustcache add "$hash" >/dev/null 2>&1 || true
    done
}

fresh_copy_if_changed() {
    local source="$1" destination="$2" temporary
    if [ -f "$destination" ] && cmp -s "$source" "$destination"; then
        return 0
    fi
    temporary="${destination}.new-$$"
    rm -f "$temporary"
    cp "$source" "$temporary"
    chmod 755 "$temporary"
    chown root:wheel "$temporary" 2>/dev/null || true
    mv -f "$temporary" "$destination"
}

mkdir -p "$FRAMEWORKS/.jbroot/Library/Frameworks/CydiaSubstrate.framework"
chmod 755 "$FRAMEWORKS" "$FRAMEWORKS/.jbroot" \
    "$FRAMEWORKS/.jbroot/Library" \
    "$FRAMEWORKS/.jbroot/Library/Frameworks" \
    "$FRAMEWORKS/.jbroot/Library/Frameworks/CydiaSubstrate.framework"

# Appearance is born inside ExtensionKit's settings-extensions sandbox. A
# global /usr/local/lib injection is denied there, so its compatibility dylib
# and the one CydiaSubstrate image it links are a bundle-local dependency
# closure. Fresh inodes also prevent stale vnode signature caches.
fresh_copy_if_changed "$LIBMACHOOK" "$FRAMEWORKS/libmachook.dylib"
trust_macho "$FRAMEWORKS/libmachook.dylib"

SUBSTRATE_LOCAL="$FRAMEWORKS/.jbroot/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
if [ ! -f "$SUBSTRATE_LOCAL" ] ||
   ! $OTOOL -l "$SUBSTRATE_LOCAL" 2>/dev/null |
       grep -A4 LC_BUILD_VERSION | grep -q 'platform 1'; then
    fresh_copy_if_changed "$SUBSTRATE" "$SUBSTRATE_LOCAL"
    /var/jb/usr/bin/python3 "$MACHO_PATCHER" "$SUBSTRATE_LOCAL"
    # Platform rewriting invalidates the original signature. Two passes settle
    # this ldid build's post-__LINKEDIT page hashes.
    $LDID -S -M "$SUBSTRATE_LOCAL"
    $LDID -S -M "$SUBSTRATE_LOCAL"
fi
trust_macho "$SUBSTRATE_LOCAL"

# RE/runtime-confirmed: the first remote scene asks libobjc to synthesize an
# NSDP accessor with imp_implementationWithBlock. The settings-extension
# sandbox denies the late map of the rootfs vnode as `file-map-executable`.
# Preloading the unchanged Apple-signed trampoline image from the extension's
# own Frameworks directory makes libobjc reuse the admitted image.
fresh_copy_if_changed "$TRAMPOLINES" "$FRAMEWORKS/libobjc-trampolines.dylib"
trust_macho "$FRAMEWORKS/libobjc-trampolines.dylib"

if [ ! -f "$APPEARANCE.macws-preload-backup" ]; then
    cp -p "$APPEARANCE" "$APPEARANCE.macws-preload-backup"
fi

changed=0
for dependency in \
    '@executable_path/../Frameworks/libmachook.dylib' \
    '@executable_path/../Frameworks/libobjc-trampolines.dylib'; do
    output=$(/var/jb/usr/bin/python3 "$LOAD_PATCHER" \
        "$APPEARANCE" "$dependency")
    echo "$output"
    case "$output" in
        *'modified=1'*) changed=1 ;;
    esac
done

entitlements=$($LDID -e "$APPEARANCE" 2>/dev/null || true)
printf '%s\n' "$entitlements" |
    grep -q 'com.apple.macosbooter.lsd.modifydb' || changed=1
$LDID -h "$APPEARANCE" 2>/dev/null |
    grep -q '^Identifier=com.apple.Appearance-Settings.extension$' || changed=1
if [ "$changed" -eq 1 ]; then
    $LDID -Icom.apple.Appearance-Settings.extension \
        -S"$APPEARANCE_ENT" -M "$APPEARANCE"
    $LDID -Icom.apple.Appearance-Settings.extension \
        -S"$APPEARANCE_ENT" -M "$APPEARANCE"
fi
trust_macho "$APPEARANCE"

echo '[INFO] Appearance ExtensionKit runtime is ready'
