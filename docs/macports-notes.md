# MacPorts in the macOS Chroot — Notes & Lessons Learned

MacPorts was chosen as the package manager for the macOS chroot after Homebrew hit a hard wall
(no bottles for macOS 13 arm64, source builds require Xcode CLT which AMFI kills). MacPorts
ships prebuilt binary archives for macOS arm64 and does not require Xcode for most packages.

---

## Environment

| Property | Value |
|---|---|
| Host | Jailbroken iOS (Dopamine rootless, `/var/jb`) |
| macOS rootfs | Bind-mounted at `/var/mnt/rootfs` |
| macOS version | 13.4 arm64 |
| Chroot runner | `launchdchrootexec 0 0 /var/mnt/rootfs /bin/bash "$@"` |
| Non-interactive entry | `echo 'alpine' \| sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh -c "..."` |
| Proxy | SOCKS5h on `127.0.0.1:1082` (iOS side, DNS via proxy) |
| MacPorts install prefix | `/opt/local` |
| MacPorts version | 2.12.3 |

---

## Phase 1 — Installing MacPorts Base

MacPorts provides a source tarball and a `.pkg` installer. The `.pkg` installer cannot be used
inside the chroot (no `PackageKit.framework`). Building from source requires a compiler — also
blocked by AMFI.

**Resolution**: Copy a pre-built MacPorts installation tree from an actual macOS 13.4 machine
(or Docker container) and extract it into the rootfs on the iOS side:

```bash
# On iOS, extract the pre-built MacPorts tree into the rootfs
sudo tar xzf /tmp/macports_opt_local.tar.gz -C /var/mnt/rootfs
```

After extraction, run the postinst.sh signing loop (Phase 4) before attempting to use `port`.

---

## Phase 2 — DNS / Network

Same constraint as Homebrew: no mDNSResponder in the chroot.

**Fix**: Set SOCKS5h proxy environment (the `h` suffix routes DNS through the proxy too):
```bash
export ALL_PROXY=socks5h://127.0.0.1:1082
export HTTPS_PROXY=socks5h://127.0.0.1:1082
export HTTP_PROXY=socks5h://127.0.0.1:1082
```

`port selfupdate` downloads via HTTPS and works with the proxy set. `port sync` uses rsync by
default. Switch to HTTPS sync in `/opt/local/etc/macports/sources.conf`:
```
# Replace rsync line with:
https://distfiles.macports.org/ports.tar.gz [nosync]
```

---

## Phase 3 — `port` Command: Shebang Block

**Critical finding**: `/opt/local/bin/port` is **not** a compiled binary — it is a Tcl script
with `#!/opt/local/libexec/macports/bin/tclsh8.6` as its shebang. AMFI kills it on exec
(exit 126).

The Tcl interpreter `tclsh8.6` itself is a Mach-O binary (not a script), so tclsh runs fine
once trustcached.

**Fix**: Replace `port` with a no-shebang wrapper that calls tclsh explicitly:

```bash
# Inside chroot (run as root, using macOS /bin/cp):
/bin/cp /opt/local/bin/port /opt/local/bin/port.tcl

# Write wrapper (no shebang — bash falls back to direct interpretation):
printf 'exec /opt/local/libexec/macports/bin/tclsh8.6 /opt/local/bin/port.tcl "$@"\n' \
    > /opt/local/bin/port
/bin/chmod +x /opt/local/bin/port
```

**Important**: The `port.tcl` source is the MacPorts-version-specific installed script.
If it is accidentally overwritten (e.g. from running the above twice without making the
backup first), restore it from GitHub:

```bash
# Restore port.tcl for MacPorts 2.12.3 (replace version as needed):
curl -fsSL --proxy socks5h://127.0.0.1:1082 \
  "https://raw.githubusercontent.com/macports/macports-base/v2.12.3/src/port/port.tcl" \
  -o /opt/local/bin/port.tcl
# The @TCLSH@ placeholder in the downloaded file is fine — it's the first line (shebang)
# which is not exec'd; tclsh is invoked directly by the wrapper.
```

**PATH caveat inside chroot**: The iOS shell PATH (`/var/jb/usr/bin`) leaks in. Use absolute
macOS paths for file operations:
- `/bin/cp`, `/bin/chmod`, `/bin/cat`, `/usr/bin/head` — macOS rootfs binaries
- `cp`, `chmod` without full path → resolves to iOS procursus, which crashes (libiosexec sandbox)

---

## Phase 4 — Binary Signing After Every `port install`

Every Mach-O file installed by MacPorts must be:
1. Re-signed: `sudo ldid -S"$ENT" -M <path>` (from **iOS shell**, not inside chroot)
2. Trustcached: CDHash extracted and registered via `sudo jbctl trustcache add`

**Trustcache is not persistent across reboots.** `postinst.sh` re-registers all known CDHashes
on every boot. For newly installed packages, run the bulk-sign loop from the iOS shell:

```bash
ENT=/var/jb/usr/macOS/bin/entitlements.plist
LDID=/var/jb/usr/bin/ldid
JBCTL=/var/jb/usr/bin/jbctl

sudo find /var/mnt/rootfs/opt/local -type f | while read f; do
    sudo "$LDID" -S"$ENT" -M "$f" 2>/dev/null || continue
    for arch in arm64 arm64e x86_64; do
        h=$(sudo "$LDID" -arch "$arch" -h "$f" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && sudo "$JBCTL" trustcache add "$h" && echo "[$arch] $(basename $f)"
    done
done
```

**Known libraries confirmed signed and working**:

| Library | Purpose |
|---|---|
| `liblzma.5.dylib` | XZ/LZMA compression |
| `libedit.3.dylib` | Readline-compatible input (tclsh, python) |
| `libffi.8.dylib` | Foreign function interface (ctypes) |
| `libintl.8.dylib` | Internationalization (gettext) |
| `libiconv.2.dylib` | Character encoding conversion |
| `libsqlite3.0.dylib` | SQLite database |
| `libbz2.1.0.dylib` | BZ2 compression |
| `libncurses.6.dylib` | Terminal UI |
| `libmpdec.4.dylib` | Decimal arithmetic (Python decimal module) |

---

## Phase 5 — `uname -m` Returns Device Model String

`uname -m` (and `$tcl_platform(machine)` in Tcl) returns the iOS device model identifier
(e.g. `iPad13,6`) instead of `arm64`. This is because `hw.machine` sysctl is not yet hooked
in `libmachook` to return `arm64`.

**Impact**: MacPorts' architecture detection uses `$tcl_platform(machine)`. `iPad13,6` is
not a recognized arch string.

**Fix**: Set `build_arch arm64` in `/opt/local/etc/macports/macports.conf` (already present
in the installed configuration):
```
build_arch      arm64
```

MacPorts then uses the configured `build_arch` rather than the detected machine string.

**Long-term fix**: Add `hw.machine` → `arm64` spoofing to the `sysctlbyname_new` hook in
`libmachook/mac_hooks.m` alongside the existing `kern.osproductversion` hook.

---

## Phase 6 — DYLD_INSERT_LIBRARIES Preservation

MacPorts' `port` wrapper (shell → tclsh → macports tcl) does **not** use `exec env -i`,
so `DYLD_INSERT_LIBRARIES` is inherited through the call chain naturally.

**Exception**: Some port build phases invoke `xcrun` or `xcode-select` which AMFI kills.
Workaround: stub `/opt/local/bin/xcrun` as a no-shebang shell script:
```bash
printf '/usr/bin/clang "$@"\n' > /opt/local/bin/xcrun
/bin/chmod +x /opt/local/bin/xcrun
```

---

## Phase 7 — Python 3.13 (`port install python313`)

### Install and sign

```bash
# Inside chroot:
export PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/bin
export ALL_PROXY=socks5h://127.0.0.1:1082
port install python313
```

After install, sign all Mach-O files from the iOS shell (see Phase 4 bulk-sign, targeting
`/var/mnt/rootfs/opt/local/Library/Frameworks/Python.framework/Versions/3.13`).

Key Mach-O files to sign:
- `Python.framework/Versions/3.13/Python` — the framework dylib itself
- `Python.framework/Versions/3.13/bin/python3.13` — the executable
- `Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python`
- All `lib/python3.13/lib-dynload/*.cpython-313-darwin.so` (73 extension modules)

### pip bootstrap

pip is not installed by default. Use `ensurepip`:

```bash
python3.13 -m ensurepip --upgrade
```

pip requires `PySocks` to use SOCKS5 proxy. Bootstrap it via curl (no SOCKS needed for curl):

```bash
# iOS shell or inside chroot with curl + proxy:
curl -sL --proxy socks5h://127.0.0.1:1082 --cacert /etc/ssl/cert.pem \
  "https://files.pythonhosted.org/packages/a2/4b/52123768624ae28d84c97515dd96c9958888e8c2d8f122074e31e2be878c/PySocks-1.7.1-py27-none-any.whl" \
  -o /tmp/PySocks-1.7.1-py3-none-any.whl
python3.13 -m pip install --no-deps /tmp/PySocks-1.7.1-py3-none-any.whl
```

### SSL certificate fix

Python's ssl module tries to use the macOS Security framework (Keychain) for CA validation,
which doesn't work in the chroot (no system services). Use the system cert bundle instead:

```bash
export SSL_CERT_FILE=/etc/ssl/cert.pem   # macOS ships this at 333KB
```

After setting this, `ssl.create_default_context()` and `requests` both work.

### Required environment for Python sessions

```bash
export PATH=/opt/local/Library/Frameworks/Python.framework/Versions/3.13/bin:/opt/local/bin:/usr/bin:/bin
export ALL_PROXY=socks5h://127.0.0.1:1082
export HTTPS_PROXY=socks5h://127.0.0.1:1082
export SSL_CERT_FILE=/etc/ssl/cert.pem
```

### After `pip install` — sign new .so files

Compiled pip packages (e.g. `charset_normalizer`) install `.so` extension modules that must
be signed. From iOS shell after each `pip install`:

```bash
ENT=/var/jb/usr/macOS/bin/entitlements.plist
SITE=/var/mnt/rootfs/opt/local/Library/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages
find "$SITE" -name "*.so" -o -name "*.dylib" | while read f; do
    sudo /var/jb/usr/bin/ldid -S"$ENT" -M "$f" 2>/dev/null
    h=$(ldid -arch arm64 -h "$f" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$h" ] && sudo /var/jb/usr/bin/jbctl trustcache add "$h" && echo "signed: $(basename $f)"
done
```

---

## Phase 8 — Confirmed Working

| Package/Component | Version | Notes |
|---|---|---|
| `port` (MacPorts CLI) | 2.12.3 | Wrapper fix required (Phase 3) |
| `port selfupdate` | — | Works with HTTPS proxy |
| `python313` | 3.13.12 | Full stdlib, ctypes, ssl, multiprocessing |
| `pip` | 25.3 | Via ensurepip; needs PySocks for SOCKS5 proxy |
| `requests` | 2.32.5 | pip install; needs SSL_CERT_FILE |
| `charset_normalizer` | 3.4.5 | C extension; must sign after pip install |
| `liblzma`, `libedit`, `libffi` | various | Dependency libs for python313 |

---

## Phase 9 — Remaining Issues / Limitations

1. **`uname -m` / `hw.machine`**: Returns `iPad13,6` instead of `arm64`. Mitigated by
   `build_arch arm64` in `macports.conf` for MacPorts. Python itself is unaffected since it
   uses compile-time arch (`arm64`), not runtime sysctl. Long-term fix: hook `hw.machine`
   in `libmachook`.

2. **`port install` for new packages**: Every new package needs the bulk-sign loop run after
   install. The `postinst.sh` loop handles reboots but not first-time installs.

3. **Packages requiring a C compiler**: Any port that doesn't have a prebuilt binary for
   macOS 13 arm64 will try to compile — clang is killed by AMFI. Check variant availability
   with `port info <pkg>` before installing.

4. **Signed `.so` count grows with pip installs**: `postinst.sh` must be updated or the
   per-`pip install` signing loop run manually each time.

---

## Summary: MacPorts vs Homebrew

| | MacPorts | Homebrew |
|---|---|---|
| Binary packages for macOS 13 arm64 | Yes | No (Tier 3 deprecated) |
| `port` CLI is executable directly | No (Tcl script, needs wrapper) | No (bash script, needs shebang strip) |
| `DYLD_INSERT_LIBRARIES` preserved | Yes | No (patch `FILTERED_ENV` needed) |
| Requires Xcode CLT | Rarely | Always (source-only on macOS 13) |
| DNS/network | SOCKS5h proxy | SOCKS5h proxy |
| Outcome | **Working** | Hard wall at package install |

---

## Files Modified for MacPorts

| File (under `/var/mnt/rootfs/`) | Change |
|---|---|
| `opt/local/bin/port` | Replaced with no-shebang tclsh wrapper |
| `opt/local/bin/port.tcl` | Restored from MacPorts 2.12.3 GitHub source |
| `opt/local/etc/macports/sources.conf` | Changed rsync source to HTTPS |
| `opt/local/etc/macports/macports.conf` | `build_arch arm64` already set |
| All Mach-O files under `opt/local/` | Re-signed with `entitlements.plist` and trustcached |
