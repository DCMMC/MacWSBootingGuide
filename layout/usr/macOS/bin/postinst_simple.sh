#!/bin/bash
# Default post-install for dev builds: jb hook + launcher + chroot insert + libsystem_darwin
# patch + bash trustcache. Skips MacPorts scan, long rootfs lists, dyld_shared_cache hashes, etc.
# For the full signing pass use: sudo bash /var/jb/usr/macOS/bin/postinst.sh
# Usage: sudo bash /var/jb/usr/macOS/bin/postinst_simple.sh

cd "$(realpath "$HOME/../..")/usr/macOS" || exit 1

ENT="/var/jb/usr/macOS/bin/entitlements.plist"

TRUSTCACHE_FILE="/tmp/postinst_trustcache_$$"
jbctl trustcache info 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$TRUSTCACHE_FILE"
trap 'rm -f "$TRUSTCACHE_FILE"' EXIT

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
	echo "$cdhash" >> "$TRUSTCACHE_FILE"
}

add_all_trustcache() {
	local path="$1"
	local cdhash
	[ -f "$path" ] || return
	for arch in arm64 arm64e x86_64; do
		cdhash=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
		[ -n "$cdhash" ] && trust_cdhash "$cdhash" "$path" "$arch"
	done
}

sign_then_trust_all() {
	local path="$1"
	[ -f "$path" ] || return
	ldid -S"$ENT" -M "$path" 2>/dev/null || echo "[WARN] ldid failed: $path" >&2
	add_all_trustcache "$path"
}

echo "==> postinst_simple: jb Mach-O + chroot libmachook + bash"

LSDARWIN="/var/mnt/rootfs/usr/lib/system/libsystem_darwin.dylib"
if [ -f "$LSDARWIN" ] && command -v python3 >/dev/null 2>&1; then
	python3 /var/jb/usr/macOS/bin/patch_libsystem_darwin_os_variant.py "$LSDARWIN" || echo "[WARN] patch_libsystem_darwin failed" >&2
	ldid -S"$ENT" -M "$LSDARWIN" 2>/dev/null || true
	add_all_trustcache "$LSDARWIN"
fi

sign_then_trust_all "/var/jb/usr/macOS/lib/libmachook.dylib"
[ -f "/var/jb/usr/macOS/lib/libmachook-rootfs.dylib" ] && sign_then_trust_all "/var/jb/usr/macOS/lib/libmachook-rootfs.dylib"

sign_then_trust_all "/var/jb/usr/macOS/bin/launchdchrootexec"
[ -f "/var/jb/usr/macOS/bin/launchdchrootexec_debug" ] && sign_then_trust_all "/var/jb/usr/macOS/bin/launchdchrootexec_debug"

LMJB="/var/jb/usr/macOS/lib/libmachook.dylib"
LMROOT="/var/mnt/rootfs/usr/local/lib/libmachook.dylib"
LMROOTSRC="/var/jb/usr/macOS/lib/libmachook-rootfs.dylib"
if [ -f "$LMROOTSRC" ]; then
	cp -vf "$LMROOTSRC" "$LMROOT"
elif [ -f "$LMJB" ]; then
	cp -vf "$LMJB" "$LMROOT"
	if command -v lipo >/dev/null 2>&1; then
		LMTHIN="/tmp/libmachook-rootfs-thin.$$"
		if lipo -thin arm64e "$LMROOT" -output "$LMTHIN" 2>/dev/null && [ -f "$LMTHIN" ]; then
			mv -f "$LMTHIN" "$LMROOT"
		else
			rm -f "$LMTHIN"
			echo "[WARN] lipo -thin arm64e failed for $LMROOT" >&2
		fi
	else
		echo "[WARN] lipo not found" >&2
	fi
else
	echo "[WARN] no libmachook at $LMJB" >&2
fi

if [ -f "$LMROOT" ]; then
	ldid -S"$ENT" -M "$LMROOT" || echo "[WARN] ldid ENT failed for $LMROOT" >&2
	for arch in arm64 arm64e x86_64; do
		h=$(ldid -arch "$arch" -h "$LMROOT" 2>/dev/null | grep CDHash= | cut -c8-)
		[ -n "$h" ] && trust_cdhash "$h" "$LMROOT" "$arch"
	done
fi

add_all_trustcache "/var/mnt/rootfs/bin/bash"

echo "==> postinst_simple done"
