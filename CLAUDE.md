# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MacWSBootingGuide is a WIP jailbreak project that enables running macOS's WindowServer (and macOS GUI applications) on jailbroken iOS/iPadOS devices (arm64, Dopamine rootless jailbreak). It works by chrooting into a bind-mounted macOS filesystem and using dyld interpositioning to patch incompatible system calls and framework behaviors at runtime.

## Build

This project uses [Theos](https://theos.dev).

### Build on iOS (on-device)

If you have Theos installed on the jailbroken device:

```bash
# Build, package, and install (from project directory)
bash misc/build_on_ios.sh

# Or manually:
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 package
sudo dpkg -i packages/*.deb
sudo bash /var/jb/usr/macOS/bin/postinst.sh
```

### Build on macOS (cross-compile)

```bash
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
ldid -S/var/jb/usr/macOS/bin/entitlements.plist -M /var/mnt/rootfs/path/to/binary

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
# Always set the full environment at the top of every script:
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -s <<'EOF'
# --- standard chroot environment ---
export PATH=/opt/local/bin:/opt/local/sbin:\
/opt/local/Library/Frameworks/Python.framework/Versions/3.13/bin:\
/opt/homebrew/bin:/opt/homebrew/sbin:\
/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/Users/root
export USER=root
export TMPDIR=/tmp
export SHELL=/bin/bash
# Network (DNS routed through SOCKS5h proxy):
export ALL_PROXY=socks5h://127.0.0.1:1082
export HTTPS_PROXY=socks5h://127.0.0.1:1082
export HTTP_PROXY=socks5h://127.0.0.1:1082
# SSL: Security framework is unreachable in chroot; use the system cert bundle:
export SSL_CERT_FILE=/etc/ssl/cert.pem
# --- end environment ---

echo "running in chroot"
port version
python3.13 --version
EOF

# Script file that lives on the macOS rootfs, with arguments
sudo bash /var/jb/usr/macOS/bin/run_bash.sh /tmp/script.sh arg1 arg2
```

Notes:
- `chdir: No such file or directory` always appears on stderr — harmless, falls back to `/`.
- PATH is inherited from the iOS shell; **always override it** in scripts or tools will resolve to iOS procursus binaries which crash inside the chroot (libiosexec sandbox).
- `HOME=/Users/root`, `USER=root`, `TMPDIR=/tmp` are pre-set by `launchdchrootexec` but PATH is not.
- `SSL_CERT_FILE=/etc/ssl/cert.pem` is required for any Python/curl SSL to work — the macOS Security framework (Keychain) is unreachable in the chroot.
- For script files: place them under `/var/mnt/rootfs/` so they are accessible inside the chroot (e.g. iOS path `/var/mnt/rootfs/tmp/script.sh` → chroot path `/tmp/script.sh`).
- After installing software via `port` or `brew`, run `misc/sign_installed.sh` from the iOS shell to sign and trustcache all new Mach-O files (see below).

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

---

## Practical Knowledge: iOS Shell Operations

### Commands That Require `sudo`

Run these from the iOS shell (SSH or terminal). Almost all privileged operations need `sudo`:

```bash
# Always need sudo:
sudo bash /var/jb/usr/macOS/bin/run_bash.sh          # enter chroot
sudo bash /var/jb/usr/macOS/bin/postinst.sh          # re-sign & trustcache
sudo ldid -S<entitlements> -M <binary>               # re-sign a binary (writes signature)
sudo jbctl trustcache add <cdhash>                   # register CDHash (modifies trustcache)
sudo /var/jb/usr/local/bin/mount_bindfs <src> <dst>  # bind mount
sudo launchctl load/unload <plist>                   # manage daemons
sudo dmesg                                           # kernel log

# Do NOT need sudo (read-only or user-space):
ldid -h <binary>                  # inspect CDHash (read-only)
ldid -arch arm64 -h <bin> 2>/dev/null | grep CDHash= | cut -c8-  # extract cdhash
jbctl trustcache info             # dump trustcache contents (read-only)
ls, cat, grep, file, strings      # read-only inspection
oslog                             # log streaming (may need sudo for kernel logs)
python3                           # iOS procursus python3
```

**jbctl trustcache commands**:
- `jbctl trustcache add <hash>` — requires sudo (modifies trustcache)
- `jbctl trustcache info` — no sudo needed (read-only, dumps all CDHashes)
- `jbctl trustcache list` — **broken**, always returns empty; use `info` instead

**Non-interactive sudo pattern** (for scripting from macOS via SSH):
```bash
echo 'alpine' | sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh -c "command"
```

### Extracting and Registering CDHashes

```bash
# Sign and register a single binary (all architectures):
ENT=/var/jb/usr/macOS/bin/entitlements.plist
sudo ldid -S"$ENT" -M /var/mnt/rootfs/path/to/binary
for arch in arm64 arm64e x86_64; do
    h=$(ldid -arch "$arch" -h /var/mnt/rootfs/path/to/binary 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$h" ] && sudo /var/jb/usr/bin/jbctl trustcache add "$h"
done
```

---

## Critical Constraint: AMFI Shebang Block

**AMFI kills `execve()` of any file with a `#!/...` shebang line** (exits 126, `EPERM`).
This applies to ALL scripts, not just shell scripts.

**Symptoms**: Command exits immediately with no output; `dmesg` shows `AMFI: ... deny`.

**Workaround — remove shebangs**: When bash tries to exec a file and gets `ENOEXEC` (no
recognized binary/shebang format), it falls back to interpreting it as a shell script directly.
This works for any script executed within a running bash session.

```bash
# Strip the first line if it's a shebang (iOS-side, using python3 — NOT GNU sed):
python3 -c "
import sys
with open(sys.argv[1], 'r+') as f:
    lines = f.readlines()
    if lines and lines[0].startswith('#!'):
        f.seek(0); f.writelines(lines[1:]); f.truncate()
" /var/mnt/rootfs/path/to/script
```

**Do NOT use GNU sed** (`/var/jb/usr/bin/sed`) to strip shebangs — it corrupts files due to
`\n`/`\r\n` line-ending differences. Use procursus `python3` on the iOS side instead.

**Applies to**: Any shell script, Python script, Ruby script, Perl script, Tcl script — any
text file with a `#!` first line that is exec'd via `execve`.

**Exception**: Scripts invoked by `bash script.sh` or `python3 script.py` (not exec'd directly)
are not affected since bash/python handle them without calling `execve` on the script file.

---

## Environment Variables for `run_bash.sh` Sessions

`launchdchrootexec` sets a minimal environment. Always export the following at the start of
any chroot session or script:

```bash
# Minimal working environment for the macOS chroot:
export PATH=/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/Users/root
export USER=root
export TMPDIR=/tmp
export SHELL=/bin/bash

# If you need network access (DNS goes through the SOCKS5 proxy):
export ALL_PROXY=socks5h://127.0.0.1:1082
export HTTPS_PROXY=socks5h://127.0.0.1:1082
export HTTP_PROXY=socks5h://127.0.0.1:1082
# Note: use socks5h:// (NOT socks5://) so DNS is resolved through the proxy too

# DYLD_INSERT_LIBRARIES is set automatically by launchdchrootexec; do not override it.
# If a subprocess strips it (e.g. via exec env -i), re-inject:
export DYLD_INSERT_LIBRARIES=/usr/local/lib/libmachook.dylib
```

**`launchdchrootexec` pre-sets**: `HOME=/Users/root`, `USER=root`, `TMPDIR=/tmp`,
`DYLD_INSERT_LIBRARIES=/usr/local/lib/libmachook.dylib`.

**PATH is inherited from the iOS shell** — always set it explicitly inside scripts.

---

## Skills: Common Operations

### Skill: Sign and Trustcache a Single Binary

```bash
# On iOS shell (run_bash NOT needed — this is iOS-side ldid):
ENT=/var/jb/usr/macOS/bin/entitlements.plist
BIN=/var/mnt/rootfs/path/to/binary
sudo ldid -S"$ENT" -M "$BIN"
for arch in arm64 arm64e x86_64; do
    h=$(ldid -arch "$arch" -h "$BIN" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$h" ] && sudo /var/jb/usr/bin/jbctl trustcache add "$h" && echo "Trusted [$arch]: $h"
done
```

### Skill: Sign All Mach-O Files in a Directory Tree

Use `misc/sign_installed.sh` (deployed to `/var/jb/usr/macOS/bin/sign_installed.sh`).
This is the standard tool for signing after any `port install`, `brew install`, or `pip install`.

```bash
# Sign everything MacPorts installed (most common case after port install):
echo 'alpine' | sudo -S bash /var/jb/usr/macOS/bin/sign_installed.sh macports

# Sign everything Homebrew installed:
echo 'alpine' | sudo -S bash /var/jb/usr/macOS/bin/sign_installed.sh homebrew

# Sign both (default):
echo 'alpine' | sudo -S bash /var/jb/usr/macOS/bin/sign_installed.sh

# Sign an arbitrary directory (e.g. after extracting a tarball):
echo 'alpine' | sudo -S bash /var/jb/usr/macOS/bin/sign_installed.sh /var/mnt/rootfs/usr/local/myapp

# After pip install — sign new .so files in Python site-packages:
echo 'alpine' | sudo -S bash /var/jb/usr/macOS/bin/sign_installed.sh \
  /var/mnt/rootfs/opt/local/Library/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages
```

The script is idempotent and safe to re-run at any time. It skips non-Mach-O files silently.

### Skill: Run a Multi-Line Script in the Chroot (Non-Interactive)

Place the script in the rootfs so it is accessible inside the chroot:
```bash
# Write script to rootfs (accessible inside chroot as /tmp/myscript.sh)
cat > /var/mnt/rootfs/tmp/myscript.sh << 'EOF'
export PATH=/opt/local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export ALL_PROXY=socks5h://127.0.0.1:1082
# ... script body ...
EOF

# Run it (no shebang needed — bash -s reads from stdin or bash <path> executes directly):
echo 'alpine' | sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh /tmp/myscript.sh
```

Or pipe inline via stdin (script stays on iOS filesystem):
```bash
echo 'alpine' | sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh -s << 'EOF'
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
echo "hello from chroot"
EOF
```

### Skill: Strip Shebangs from a Directory of Scripts (iOS Side)

```bash
python3 << 'EOF'
import os, sys

target_dir = "/var/mnt/rootfs/opt/homebrew/Library/Homebrew/shims"
for root, dirs, files in os.walk(target_dir):
    for fname in files:
        fpath = os.path.join(root, fname)
        try:
            with open(fpath, 'r+', encoding='utf-8', errors='ignore') as f:
                content = f.read()
                if content.startswith('#!'):
                    newline_pos = content.find('\n')
                    if newline_pos != -1:
                        f.seek(0)
                        f.write(content[newline_pos+1:])
                        f.truncate()
                        print(f"Stripped shebang: {fpath}")
        except (IsADirectoryError, PermissionError):
            pass
EOF
```

### Skill: Check If a CDHash Is in the Trustcache

```bash
cdhash=$(ldid -arch arm64 -h /var/mnt/rootfs/path/to/binary 2>/dev/null | grep CDHash= | cut -c8-)
echo "CDHash: $cdhash"
jbctl trustcache info | grep -i "$cdhash" && echo "IN trustcache" || echo "NOT in trustcache"
```

**Note**: Use `jbctl trustcache info` to dump the trustcache contents. `jbctl trustcache list`
always returns empty output and does not work for checking trustcache membership.

### Skill: Debug Why a Binary Is Being Killed

```bash
# Watch AMFI/kernel logs while running the binary in another session:
sudo dmesg | grep -E 'AMFI|deny|kill|sigkill' | tail -20
# Or:
sudo oslog | grep "AMFI\|violation\|kill"
```

### Skill: Install MacPorts Package (After Base is Set Up)

```bash
# Inside chroot, with proxy set:
export ALL_PROXY=socks5h://127.0.0.1:1082
export PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin
port install <package>

# After install, sign all new Mach-O files (run from iOS shell, NOT inside chroot):
# (use the bulk-sign skill above, targeting /var/mnt/rootfs/opt/local)
```

---

## Package Manager Notes

- **MacPorts** (`/opt/local`): Works. Has prebuilt binaries for macOS 13 arm64. `port` binary
  is a Mach-O (no shebang issue). After each `port install`, re-sign all new Mach-O files.
  See `docs/macports-notes.md` for full details.

- **Homebrew** (`/opt/homebrew`): Does NOT work for package installation on macOS 13 arm64 —
  no bottles available, source builds require Xcode CLT (AMFI-killed). `brew --version` can
  be made to work but `brew install` fails. See `docs/homebrew-notes.md` for full details.

---

## Python 3.13 (MacPorts)

Installed as `port install python313`. Confirmed working as of 2026-03-15 (version 3.13.12).

### Required: sign all Mach-O files after install

Run `/tmp/sign_python313.sh` (iOS side) or the bulk-sign skill from CLAUDE.md targeting
`/opt/local/Library/Frameworks/Python.framework/Versions/3.13` and `/opt/local/lib`.

### pip setup

```bash
# Install pip (bundled with Python 3.13):
python3.13 -m ensurepip --upgrade

# pip needs PySocks to use a SOCKS5 proxy. Bootstrap it via curl:
curl -sL --proxy socks5h://127.0.0.1:1082 --cacert /etc/ssl/cert.pem \
  "https://files.pythonhosted.org/packages/a2/4b/52123768624ae28d84c97515dd96c9958888e8c2d8f122074e31e2be878c/PySocks-1.7.1-py27-none-any.whl" \
  -o /tmp/PySocks-1.7.1-py3-none-any.whl
python3.13 -m pip install --no-deps /tmp/PySocks-1.7.1-py3-none-any.whl
```

### Required environment variables for Python sessions

```bash
export SSL_CERT_FILE=/etc/ssl/cert.pem           # macOS cert bundle (Security fw unreachable in chroot)
export ALL_PROXY=socks5h://127.0.0.1:1082        # DNS-aware SOCKS5 proxy
export HTTPS_PROXY=socks5h://127.0.0.1:1082
# Include the Python framework bin for pip3/pip3.13 commands:
export PATH=/opt/local/Library/Frameworks/Python.framework/Versions/3.13/bin:$PATH
```

### After every `pip install` — sign new .so files (from iOS shell)

```bash
ENT=/var/jb/usr/macOS/bin/entitlements.plist
SITE=/var/mnt/rootfs/opt/local/Library/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages
find "$SITE" -type f \( -name "*.so" -o -name "*.dylib" \) | while read f; do
    sudo ldid -S"$ENT" -M "$f" 2>/dev/null
    h=$(ldid -arch arm64 -h "$f" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$h" ] && sudo /var/jb/usr/bin/jbctl trustcache add "$h" && echo "signed: $(basename $f)"
done
```

### Confirmed working modules

`sys`, `os`, `json`, `re`, `math`, `hashlib`, `sqlite3`, `ssl`, `zlib`, `lzma`, `bz2`, `csv`,
`ctypes`, `decimal`, `readline`, `multiprocessing`, `concurrent.futures`,
`requests` (pip), `charset_normalizer` (pip), `certifi` (pip), `urllib3` (pip)
