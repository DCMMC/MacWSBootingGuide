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
ROOTFS=/var/mnt/rootfs

# ── snapshot current trustcache so we can skip already-trusted entries ────────

TC_CACHE=$(mktemp /tmp/tc_cache.XXXXXX)
"$JBCTL" trustcache list 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$TC_CACHE"
trap 'rm -f "$TC_CACHE"' EXIT
printf 'Loaded %d existing trustcache entries.\n' "$(wc -l < "$TC_CACHE")"

# ── counters (written to a tmp file because subshells can't update parent vars) ──

COUNTS=$(mktemp /tmp/tc_counts.XXXXXX)
printf '0 0 0 0\n' > "$COUNTS"   # signed  already_trusted  skipped  no_cdhash

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
trap 'rm -f "$TC_CACHE" "$COUNTS"' EXIT

# ── core sign + trustcache function ──────────────────────────────────────────

sign_one() {
    local f="$1"
    [ -f "$f" ] || return 0

    # Sign with entitlements; ldid exits non-zero for non-Mach-O — skip silently.
    if ! "$LDID" -S"$ENT" -M "$f" 2>/dev/null; then
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
    find "$dir" -type f | while read -r f; do
        sign_one "$f"
    done
}

# ── target selection ──────────────────────────────────────────────────────────

TARGET="${1:-both}"

case "$TARGET" in
    macports|mp)   DO_MACPORTS=1; DO_HOMEBREW=0 ;;
    homebrew|brew) DO_MACPORTS=0; DO_HOMEBREW=1 ;;
    both|"")       DO_MACPORTS=1; DO_HOMEBREW=1 ;;
    /*)
        printf '=== Signing custom path: %s ===\n' "$TARGET"
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
