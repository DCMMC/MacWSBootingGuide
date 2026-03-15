# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MacWSBootingGuide is a WIP jailbreak project that enables running macOS's WindowServer (and macOS GUI applications) on jailbroken iOS/iPadOS devices (arm64, Dopamine rootless jailbreak). It works by chrooting into a bind-mounted macOS filesystem and using dyld interpositioning to patch incompatible system calls and framework behaviors at runtime.

## Build

This project uses [Theos](https://theos.dev). Building is done from macOS:

```bash
# Build, package, and install to device (edit DEVICE_IP in misc/build.sh first)
bash misc/build.sh

# Or build manually
gmake FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless package install \
  THEOS_DEVICE_IP=<device_ip> THEOS_DEVICE_PORT=2222 GO_EASY_ON_ME=1
```

After install, on the device:
```bash
sudo bash /var/jb/usr/macOS/bin/postinst.sh
```

There are no automated tests. Debug with:
```bash
sudo oslog | grep "AMFI\|debugbydcmmc\|launchd\|launchser\|WindowSer\|MTL\|Metal\|Terminal\|iolation"
```

## Architecture

### Subprojects

The root `Makefile` builds six subprojects:

**iOS-side (run in iOS context):**
- `MTLCompilerBypassOSCheck/` — CydiaSubstrate tweak that patches `MTLCompilerService` platform checks so it will compile Metal shaders for a macOS (non-iOS) target.
- `MTLSimDriverHost/` — XPC service that hosts `MTLSimDriver.framework` (from the iOS Simulator runtime). Bridging macOS Metal calls to the iOS GPU driver.
- `launchdchrootexec/` — Small iOS binary that chroots into the macOS rootfs and execs a macOS binary with `DYLD_INSERT_LIBRARIES` pointing to `libmachook.dylib`.

**macOS-side (compiled for macOS target, run inside the chroot):**
- `libmachook/` — The core dylib injected into every macOS process. Contains all runtime interposition hooks.
- `launchservicesd/` — Loader that converts the macOS `launchservicesd` daemon into a dylib so it can run without entitlements that would cause a codesign panic.
- `login/` — Thin wrapper that spawns bash inside the macOS chroot environment.

### libmachook — Core Hook Library

`libmachook/mac_hooks.m` is the primary file. It registers a `dyld_register_func_for_add_image` callback (`loadImageCallback`) that fires for every loaded image and applies binary patches by scanning for specific byte sequences at runtime (hardcoded for iOS 16.5 / macOS 13.4).

Key patches applied:
- **SkyLight** — Removes backboardd coexistence check.
- **IOMobileFramebuffer** — Fixes kernel parameter passing for the iOS framebuffer.
- **Metal** — Bypasses extra MTL reflection deserialization; patches `sysctlbyname` to spoof OS version (reports iOS 16.x as macOS 13.x).
- **libxpc** — Registers `MTLCompilerService` bundle for the XPC lookup.
- **Sandbox** — Disables `sandbox_init_with_parameters` (returns 0).
- **Audit tokens** — Stubs `audit_token_to_asid`, `audit_token_to_auid`, `auditon`, `getaudit_addr` (missing on iOS).
- **Mach ports** — Patches `mach_port_construct` to remove invalid flags.

Additional hook files in `libmachook/`:
- `Metal_hooks.x` — Hooks `MTLSimDevice` and `MTLSimBuffer` to fix storage mode mismatches and `vm_remap`-based XPC memory sharing.
- `QuartzCore_hooks.x` — Skips unsupported tile render pipeline calls.
- `jit.m` — Enables JIT (MAP_JIT) for the process.
- `objc_hooks.c` — ObjC runtime patches.
- `os_log_hooks.m` / `os_variant_hooks.x` — Logging and OS variant spoofing.

### File Syntax

`.x` files use [Logos](https://theos.dev/docs/logos-syntax) (Theos hooking preprocessor). Key directives:
- `%hook ClassName` / `%end` — Hook an Objective-C class.
- `%orig` — Call the original implementation.
- `%ctor` / `%dtor` — Constructor/destructor.

### Hardcoded Offsets

Many patches in `mac_hooks.m` search for hardcoded byte sequences to locate patch sites. These are specific to **iOS 16.5 / macOS 13.4**. When porting to new OS versions, these byte patterns need to be re-derived.

### Entitlements

`entitlements.plist` contains 100+ entitlements required for direct kernel/GPU/hardware access. Every macOS binary run inside the chroot must be re-signed with this plist: `ldid -S./entitlements.plist -M <binary>`.

### Required External Frameworks

Must be sourced from the iOS Simulator runtime (not included in this repo):
- `MTLSimDriver.framework`
- `MTLSimImplementation.framework`
- `MetalSerializer.framework`

### Running Binaries in the macOS Chroot

Before any macOS binary can run on the device, it must be re-signed and its CDHash registered in the trustcache:

```bash
# Re-sign with required entitlements
ldid -S./entitlements.plist -M /var/mnt/rootfs/path/to/binary

# Register CDHash(es) — repeat for each slice you need
cdhash=$(ldid -arch arm64 -h /var/mnt/rootfs/path/to/binary 2>/dev/null | grep CDHash= | cut -c8-)
jbctl trustcache add "$cdhash"
```

Enter the macOS bash environment interactively (CLI only):
```bash
sudo bash /var/jb/usr/macOS/bin/run_bash.sh
```

Run commands or scripts non-interactively (`run_bash.sh` forwards all arguments to bash):
```bash
# Inline command
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c "echo hello"

# Multi-line script piped via stdin (script lives on iOS filesystem)
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -s <<'EOF'
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
echo "running in chroot"
EOF

# Script file that lives on the macOS rootfs, with arguments
sudo bash /var/jb/usr/macOS/bin/run_bash.sh /tmp/script.sh arg1 arg2
```

Notes:
- `chdir: No such file or directory` always appears on stderr — harmless, falls back to `/`.
- PATH is inherited from the iOS shell. Set it explicitly inside scripts if macOS tools are needed.
- `HOME=/Users/root`, `USER=root`, `TMPDIR=/tmp` are fixed by `launchdchrootexec`.
- For script files: place them under `/var/mnt/rootfs/` so they are accessible inside the chroot (e.g. iOS path `/var/mnt/rootfs/tmp/script.sh` → chroot path `/tmp/script.sh`).

Start WindowServer and GUI daemons (unloads SpringBoard/backboardd first):
```bash
sudo launchctl unload /System/Library/LaunchDaemons/com.apple.{SpringBoard,backboardd}.plist
sudo launchctl load /var/jb/usr/macOS/LaunchDaemons
```

Inside the chroot shell, run GUI applications:
```bash
/usr/local/bin/OSXvnc-server -rfbnoauth   # start VNC server first
/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
/System/Applications/Utilities/Activity\ Monitor.app/Contents/MacOS/Activity\ Monitor
```

Return to iOS (respring):
```bash
sudo launchctl unload /var/jb/usr/macOS/LaunchDaemons
sudo launchctl load /System/Library/LaunchDaemons/com.apple.{SpringBoard,backboardd}.plist
```

### Device Setup Summary

1. Mount a full macOS filesystem DMG to `/var/mnt/rootfs` with the symlinks described in the README.
2. Patch `dyld`, `launchservicesd`, and `WindowServer` binaries (some manual, some automated by hooks — see README's "Additional patches" section).
3. Run `postinst.sh` to re-sign binaries and register trustcaches via `jbctl trustcache add`.
4. Use `launchdchrootexec` (via launchctl) to start macOS daemons; WindowServer reads display via `IOMobileFramebuffer`.
5. Connect via VNC (`OSXvnc-server`) or interact via the chroot shell.
