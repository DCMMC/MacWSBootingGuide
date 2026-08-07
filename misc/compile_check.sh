#!/usr/bin/env bash
# Syntax-check an iOS-side Objective-C file against the local Xcode iOS SDK.
# Used during development to catch typos / missing symbols introduced by edits
# before shipping to the device (the on-device Theos build targets the iOS 16.3
# SDK; this check is a strictness approximation only).
#
# Usage:
#   bash misc/compile_check.sh <file.m> [more .m files ...]
#
# The macOS-side subprojects (macos_gui.sh consumers) are checked with:
#   bash misc/compile_check.sh --macos libmachook/mac_hooks.m   (not logos .x)

set -u

MODE=ios
FILES=()
for a in "$@"; do
    case "$a" in
        --macos) MODE=macos ;;
        --ios) MODE=ios ;;
        *) FILES+=("$a") ;;
    esac
done

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "usage: bash misc/compile_check.sh [--macos|--ios] file.m [...]" >&2
    exit 2
fi

if [ "$MODE" = macos ]; then
    SDK=$(xcrun --sdk macosx --show-sdk-path)
    CC=(xcrun --sdk macosx clang -fsyntax-only -target arm64-apple-macos13.0)
else
    SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    CC=(xcrun --sdk iphoneos clang -fsyntax-only -target arm64-apple-ios14.0)
fi

SHIM=/tmp/macws_cc_shim_$$.h
# Xcode 26's SDK marks some IOKit APIs __API_UNAVAILABLE(ios) that the on-device
# iOS 16.3 SDK accepts; those are pre-existing and out of scope for a syntax
# check.  Neutralize them so the check only surfaces *new* errors.
cat > "$SHIM" <<'EOF'
#pragma once
#include <IOKit/IOKitLib.h>
#ifdef kIOMasterPortDefault
#undef kIOMasterPortDefault
#endif
#define kIOMasterPortDefault MACH_PORT_NULL
EOF

FAIL=0
for f in "${FILES[@]}"; do
    "${CC[@]}" -isysroot "$SDK" \
        -fobjc-arc -fmodules \
        -Wno-unguarded-availability-new \
        -include "$SHIM" \
        -I include \
        "$f" 2>/tmp/macws_cc_$$.log
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $f (rc=$rc)"
        grep -E "error:" /tmp/macws_cc_$$.log | head -20
        FAIL=1
    else
        echo "OK   $f"
    fi
done
rm -f /tmp/macws_cc_$$.log "$SHIM"
exit "$FAIL"
