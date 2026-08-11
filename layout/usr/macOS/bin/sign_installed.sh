#!/bin/sh
# sign_installed.sh — Sign and trustcache Mach-O binaries installed by MacPorts / Homebrew.
#
# Run from the iOS shell (NOT inside the chroot) after installing software with `port` or `brew`.
# Trustcache entries are lost on every reboot; this script is safe to re-run at any time.
# Already-trusted CDHashes are detected and skipped without calling jbctl again.
#
# Usage:
#   sudo bash /var/jb/usr/macOS/bin/sign_installed.sh              # sign both MacPorts + Homebrew
#   sudo bash /var/jb/usr/macOS/bin/sign_installed.sh macports     # MacPorts only
#   sudo bash /var/jb/usr/macOS/bin/sign_installed.sh homebrew     # Homebrew only
#   sudo bash /var/jb/usr/macOS/bin/sign_installed.sh /some/path   # arbitrary directory

ENT=/var/jb/usr/macOS/bin/entitlements.plist
LDID=/var/jb/usr/bin/ldid
JBCTL=/var/jb/usr/bin/jbctl
PYTHON=/var/jb/usr/bin/python3
ROOTFS=/var/mnt/rootfs
SIGN_ENT=$ENT
SIGN_PROFILE=system
APP_ENT=""

# ── snapshot current trustcache so we can skip already-trusted entries ────────

TC_CACHE=$(mktemp /tmp/tc_cache.XXXXXX)
# Dopamine's jbctl `list` subcommand silently returns an empty result on the
# target.  `info` is its authoritative read-only inventory.
"$JBCTL" trustcache info 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$TC_CACHE"
printf 'Loaded %d existing trustcache entries.\n' "$(wc -l < "$TC_CACHE")"

# ── counters (written to a tmp file because subshells can't update parent vars) ──

COUNTS=$(mktemp /tmp/tc_counts.XXXXXX)
printf '0 0 0 0\n' > "$COUNTS"   # signed  already_trusted  skipped  no_cdhash

cleanup() {
    rm -f "$TC_CACHE" "$COUNTS"
    [ -n "$APP_ENT" ] && rm -f "$APP_ENT"
}
trap cleanup EXIT

inc_counter() {
    # inc_counter <field 1-4>
    read -r s a k n < "$COUNTS"
    case "$1" in
        1) s=$((s+1)) ;;
        2) a=$((a+1)) ;;
        3) k=$((k+1)) ;;
        4) n=$((n+1)) ;;
    esac
    printf '%d %d %d %d\n' "$s" "$a" "$k" "$n" > "$COUNTS"
}
# ── core sign + trustcache function ──────────────────────────────────────────

sign_one() {
    local f="$1"
    local effective_ent="$SIGN_ENT"
    local current_ent="" merged_ent=""
    local sign_result=0
    [ -f "$f" ] || return 0

    if [ "$SIGN_PROFILE" = third-party-nonplatform ]; then
        current_ent=$(mktemp /tmp/macws_current_entitlements.XXXXXX) || return 1
        merged_ent=$(mktemp /tmp/macws_merged_entitlements.XXXXXX) || {
            rm -f "$current_ent"
            return 1
        }
        : > "$current_ent"
        for entitlement_arch in arm64 arm64e x86_64; do
            if "$LDID" -arch "$entitlement_arch" -e "$f" \
                    > "$current_ent" 2>/dev/null &&
               [ -s "$current_ent" ]; then
                break
            fi
            : > "$current_ent"
        done
        if ! "$PYTHON" - "$SIGN_ENT" "$current_ent" "$merged_ent" <<'PY'
import plistlib, sys

with open(sys.argv[1], "rb") as stream:
    project = plistlib.load(stream)
vendor = {}
try:
    with open(sys.argv[2], "rb") as stream:
        vendor = plistlib.load(stream)
except (EOFError, OSError, plistlib.InvalidFileException):
    pass
vendor.update(project)
vendor.pop("platform-application", None)
with open(sys.argv[3], "wb") as stream:
    plistlib.dump(vendor, stream, fmt=plistlib.FMT_XML, sort_keys=True)
PY
        then
            rm -f "$current_ent" "$merged_ent"
            return 1
        fi
        effective_ent=$merged_ent
    fi

    # `-M` cannot remove an entitlement which polluted an earlier signature.
    # The non-platform profile above is already a complete vendor+project merge,
    # so sign it directly. Other targets retain the historical merge behavior.
    if [ "$SIGN_PROFILE" = third-party-nonplatform ]; then
        "$LDID" -S"$effective_ent" "$f" 2>/dev/null
        sign_result=$?
    else
        "$LDID" -S"$effective_ent" -M "$f" 2>/dev/null
        sign_result=$?
    fi
    rm -f "$current_ent" "$merged_ent"
    if [ "$sign_result" -ne 0 ]; then
        inc_counter 3   # skipped (non-Mach-O)
        return 0
    fi

    local added=0 already=0
    for arch in arm64 arm64e x86_64; do
        local h
        h=$("$LDID" -arch "$arch" -h "$f" 2>/dev/null | grep 'CDHash=' | cut -c8- | tr '[:upper:]' '[:lower:]')
        [ -n "$h" ] || continue

        if grep -qF "$h" "$TC_CACHE" 2>/dev/null; then
            already=$((already+1))
        else
            "$JBCTL" trustcache add "$h" 2>/dev/null
            # Add to in-memory cache so later slices of the same file aren't re-added.
            printf '%s\n' "$h" >> "$TC_CACHE"
            added=$((added+1))
        fi
    done

    if [ "$added" -gt 0 ]; then
        inc_counter 1   # signed + newly trustcached
        printf '  +trust  %s\n' "$(basename "$f")"
    elif [ "$already" -gt 0 ]; then
        inc_counter 2   # already trusted, signing refreshed but no jbctl call needed
        printf '  ok      %s\n' "$(basename "$f")"
    else
        inc_counter 4   # Mach-O but no CDHash (unusual)
        printf '  noarch  %s\n' "$f"
    fi
}

sign_tree() {
    local dir="$1"
    [ -d "$dir" ] || { printf 'skip (not found): %s\n' "$dir"; return 0; }
    printf '\n==> %s\n' "$dir"
    # File mode is not a reliable code predicate in third-party bundles:
    # Office marks thousands of inert resources executable, while Valheim ships
    # its 57 MB PlayFab Mach-O bundle as mode 0644. Probe every regular file's
    # four-byte Mach-O/fat magic in one Python process so ldid only sees code.
    # Office 16.91 Word is the large-tree witness: executable-bit filtering sent
    # 3,640 resources through ldid and still would not catch Valheim's plugin.
    "$PYTHON" -c '
import os, stat, sys

magics = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
for base, _, names in os.walk(sys.argv[1]):
    for name in names:
        path = os.path.join(base, name)
        try:
            mode = os.stat(path, follow_symlinks=False).st_mode
            if not stat.S_ISREG(mode):
                continue
            with open(path, "rb") as stream:
                if stream.read(4) not in magics:
                    continue
            os.write(1, os.fsencode(path) + b"\0")
        except OSError:
            pass
' "$dir" | while IFS= read -r -d '' f; do
        sign_one "$f"
    done
}

# A third-party application is not an iOS platform process.  Giving its main
# executable `platform-application` makes PMAP_CS treat it as a platform main
# binary. Runtime-confirmed with CleanMyMac X 4.15.8: the iPadOS 16.3.1 panic
# named CleanMyMac as the panicked task and reported "attempted associating
# duplicate platform main binary without matching address space layout".
#
# Retain the project's other compatibility permissions and `-M` vendor merge,
# but remove only this incorrect identity bit for /Applications/*.app trees.
prepare_third_party_app_profile() {
    APP_ENT=$(mktemp /tmp/macws_app_entitlements.XXXXXX) || return 1
    "$PYTHON" - "$ENT" "$APP_ENT" <<'PY'
import plistlib, sys

with open(sys.argv[1], "rb") as stream:
    entitlements = plistlib.load(stream)
entitlements.pop("platform-application", None)
with open(sys.argv[2], "wb") as stream:
    plistlib.dump(entitlements, stream, fmt=plistlib.FMT_XML, sort_keys=True)
PY
    SIGN_ENT=$APP_ENT
    SIGN_PROFILE=third-party-nonplatform
}

# ── target selection ──────────────────────────────────────────────────────────

TARGET="${1:-both}"

case "$TARGET" in
    macports|mp)   DO_MACPORTS=1; DO_HOMEBREW=0 ;;
    homebrew|brew) DO_MACPORTS=0; DO_HOMEBREW=1 ;;
    both|"")       DO_MACPORTS=1; DO_HOMEBREW=1 ;;
    /*)
        case "$TARGET" in
            "$ROOTFS"/Applications/*.app|"$ROOTFS"/Applications/*.app/*)
                prepare_third_party_app_profile || exit 1
                ;;
        esac
        printf '=== Signing custom path: %s (profile=%s) ===\n' \
               "$TARGET" "$SIGN_PROFILE"
        sign_tree "$TARGET"
        read -r s a k n < "$COUNTS"
        printf '\nDone. newly-trusted=%d  already-trusted=%d  skipped(non-Mach-O)=%d  no-cdhash=%d\n' \
               "$s" "$a" "$k" "$n"
        exit 0 ;;
    *)
        printf 'Usage: %s [macports|homebrew|/absolute/path]\n' "$0" >&2
        exit 1 ;;
esac

printf '=== sign_installed.sh  rootfs=%s ===\n' "$ROOTFS"

# ── MacPorts (/opt/local) ─────────────────────────────────────────────────────

if [ "$DO_MACPORTS" -eq 1 ]; then
    printf '\n--- MacPorts ---\n'

    sign_tree "$ROOTFS/opt/local/libexec/macports/bin"
    sign_tree "$ROOTFS/opt/local/bin"
    sign_tree "$ROOTFS/opt/local/sbin"
    sign_tree "$ROOTFS/opt/local/lib"
    sign_tree "$ROOTFS/opt/local/libexec"

    # Python framework — all versions installed via MacPorts
    for pyver in "$ROOTFS/opt/local/Library/Frameworks/Python.framework/Versions"/*/; do
        [ -d "$pyver" ] || continue
        printf '\n--- Python framework: %s ---\n' "$(basename "$pyver")"
        sign_tree "$pyver"
    done
fi

# ── Homebrew (/opt/homebrew) ──────────────────────────────────────────────────

if [ "$DO_HOMEBREW" -eq 1 ]; then
    printf '\n--- Homebrew ---\n'

    sign_tree "$ROOTFS/opt/homebrew/bin"
    sign_tree "$ROOTFS/opt/homebrew/sbin"
    sign_tree "$ROOTFS/opt/homebrew/lib"
    sign_tree "$ROOTFS/opt/homebrew/libexec"
    sign_tree "$ROOTFS/opt/homebrew/Cellar"

    # Homebrew vendor Ruby (used by the brew CLI itself)
    PRUBY="$ROOTFS/opt/homebrew/Library/Homebrew/vendor/portable-ruby"
    if [ -d "$PRUBY" ]; then
        printf '\n--- Homebrew portable Ruby ---\n'
        sign_tree "$PRUBY"
    fi
fi

# ── summary ───────────────────────────────────────────────────────────────────

read -r s a k n < "$COUNTS"
printf '\n=== Done ===\n'
printf 'newly-trusted=%d  already-trusted(skipped jbctl)=%d  non-Mach-O=%d  no-cdhash=%d\n' \
       "$s" "$a" "$k" "$n"
printf '\nTrustcache entries added for this session.\n'
printf 'Run postinst.sh on next reboot to re-register (trustcache is not persistent).\n'
