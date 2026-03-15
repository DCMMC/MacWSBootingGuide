# MacPorts in the macOS Chroot — Notes & Lessons Learned

MacPorts was chosen as the package manager for the macOS chroot after Homebrew hit a hard wall
(no bottles for macOS 13 arm64, source builds require Xcode CLT which AMFI kills). MacPorts
ships prebuilt `.pkg` archives for macOS arm64 and does not require Xcode for most packages.

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

---

## Phase 1 — Installing MacPorts Base

MacPorts provides a source tarball and a `.pkg` installer. The `.pkg` installer cannot be used
inside the chroot (no `/System/Library/PrivateFrameworks/PackageKit.framework`). The tarball
approach was used instead:

```bash
# Download from iOS side (not inside chroot)
curl -sL --proxy socks5h://127.0.0.1:1082 \
  https://github.com/macports/macports-base/releases/download/v2.9.3/MacPorts-2.9.3.tar.gz \
  -o /tmp/macports-base.tar.gz

tar -xzf /tmp/macports-base.tar.gz -C /tmp
```

**Build issue**: `./configure && make && make install` requires a working compiler inside the
chroot. Clang (from Xcode CLT) is killed by AMFI the same as with Homebrew.

**Resolution**: A pre-built MacPorts base tarball was extracted directly into `/opt/local` by
copying the contents from an actual macOS 13.4 machine (or Docker container), then transferred
to the device rootfs:

```bash
# On iOS, extract the pre-built MacPorts installation tree into the rootfs
cd /var/mnt/rootfs
sudo tar xzf /tmp/macports_opt_local.tar.gz
```

---

## Phase 2 — DNS / Network

Same constraint as Homebrew: no mDNSResponder in the chroot.

**Fix**: Set proxy environment before running `port`:
```bash
export ALL_PROXY=socks5h://127.0.0.1:1082
export HTTPS_PROXY=socks5h://127.0.0.1:1082
export HTTP_PROXY=socks5h://127.0.0.1:1082
# rsync also needs a proxy for port sync:
export RSYNC_PROXY=127.0.0.1:1082
```

`port sync` uses rsync by default. RSYNC_PROXY only works for HTTP proxies; rsync over SOCKS5
doesn't work. **Fix**: Switch MacPorts to use HTTPS for syncing in `/opt/local/etc/macports/sources.conf`:
```
# Replace rsync line with:
https://distfiles.macports.org/ports.tar.gz [nosync]
```

Or disable sync entirely and copy the ports tree from macOS side.

---

## Phase 3 — Shebang Constraint (AMFI kills `#!/...` scripts)

The `port` command itself (`/opt/local/bin/port`) is a compiled binary — no shebang issue.
However, many portfiles and helper scripts use shebangs.

**Key finding**: MacPorts' core `port` binary is a proper Mach-O executable (unlike Homebrew's
`brew` which is a bash script), so the primary interface works. Only portfiles (Tcl scripts
executed internally by `port`) and some shell-script utilities are affected.

**Port build scripts**: MacPorts runs build phases via its internal Tcl interpreter, not
by exec-ing shell scripts with shebangs. Most packages build cleanly.

**Shell scripts with shebangs that needed patching**:
- `/opt/local/share/macports/Tcl/port1.0/portutil.tcl` — No shebang, fine
- Some port distfiles contain configure scripts: `./configure` scripts have `#!/bin/sh` shebangs

**Workaround for configure scripts**: Remove the shebang line from `configure` before running:
```bash
sed -i '' '1{/^#!/d}' configure
bash configure ...
```

Or run via bash explicitly: `bash ./configure ...` (bash will interpret without execve).

**Important**: `/opt/local/bin/tclsh9.0` is a Mach-O binary (fine). All compiled MacPorts
binaries are fine — only shell scripts called via `execve` are affected.

---

## Phase 4 — Binary Signing After Every `port install`

Every Mach-O file installed by MacPorts must be:
1. Re-signed: `ldid -S"$ENT" -M <path>`
2. Trustcached: CDHash extracted and registered via `jbctl trustcache add`

**Automation**: A helper was added to `postinst.sh` to sign all files under `/opt/local/bin`
and `/opt/local/sbin` on each boot (re-adds CDHashes after reboot). For first install, a
one-shot script must also sign dylibs under `/opt/local/lib`.

**Signing all MacPorts Mach-O files** (run after each `port install`):
```bash
ENT=/var/jb/usr/macOS/bin/entitlements.plist
ROOTFS=/var/mnt/rootfs

find "$ROOTFS/opt/local" -type f | while read f; do
    # Only sign Mach-O files (skip text/data)
    if file "$f" 2>/dev/null | grep -q 'Mach-O'; then
        ldid -S"$ENT" -M "$f" 2>/dev/null
        for arch in arm64 arm64e x86_64; do
            h=$(ldid -arch "$arch" -h "$f" 2>/dev/null | grep CDHash= | cut -c8-)
            [ -n "$h" ] && jbctl trustcache add "$h"
        done
    fi
done
```

**Known libraries that needed signing** (checked via `ls /var/mnt/rootfs/opt/local/lib/`):
- `liblzma.dylib` / `liblzma.5.dylib` — xz/lzma decompression
- `libedit.dylib` / `libedit.3.dylib` — command-line editing (used by python3, tclsh)
- `libffi.dylib` / `libffi.8.dylib` — foreign function interface

All three are dependencies pulled in transitively by most packages.

---

## Phase 5 — DYLD_INSERT_LIBRARIES Stripping

MacPorts' `port` binary does **not** use `exec env -i` (unlike Homebrew's `brew`), so
`DYLD_INSERT_LIBRARIES` is naturally inherited by child processes in most cases.

**Exception**: Some ports run their build phases via `xcrun` or `xcode-select` which AMFI
kills outright. Workaround: stub `xcrun`:
```bash
echo '/usr/bin/clang "$@"' > /opt/local/bin/xcrun
# No shebang — bash interprets directly
chmod +x /opt/local/bin/xcrun
ldid -S"$ENT" -M /opt/local/bin/xcrun
```

**`env` invocations**: When a script uses `/usr/bin/env programname`, env must be trustcached
and `programname` must be in PATH and trustcached. `usr/bin/env` is already signed and
trustcached by `postinst.sh`.

---

## Phase 6 — Python3 and JIT

MacPorts Python (`port install python312`) creates `/opt/local/bin/python3.12`. Python requires
JIT memory allocation (`MAP_JIT`) for its bytecode compiler.

**Fix**: The `jit.m` hook in `libmachook` already enables `MAP_JIT` for all processes, so
Python works once trustcached.

A helper script was created at `/tmp/sign_python3_jit.sh` during debugging:
```bash
#!/bin/bash
ENT=/var/jb/usr/macOS/bin/entitlements.plist
ldid -S"$ENT" -M /var/mnt/rootfs/opt/local/bin/python3.12
h=$(ldid -arch arm64 -h /var/mnt/rootfs/opt/local/bin/python3.12 2>/dev/null | grep CDHash= | cut -c8-)
jbctl trustcache add "$h"
```

---

## Phase 7 — `port` Sync and Portfile Index

`port selfupdate` and `port sync` try to update the ports tree. Both use rsync or git which
have network/SOCKS issues.

**Workaround**: Manually copy the ports tree from macOS side:
```bash
# On macOS (host), compress MacPorts ports tree:
tar czf /tmp/macports_ports.tar.gz -C /opt/local/var/macports/sources/rsync.macports.org \
  macports/release/tarballs/ports.tar
# Transfer to device and extract into rootfs
```

Or use `port -d sync` with HTTP source as described in Phase 2.

---

## Phase 8 — Confirmed Working Packages

After all the above fixes, the following packages were confirmed to install and run:

| Package | Notes |
|---|---|
| `python312` | Works; JIT enabled via `jit.m` hook |
| `liblzma` (`xz`) | Library works; `xz` binary works |
| `libffi` | Library works |
| `libedit` | Library works |

---

## Phase 9 — Remaining Limitations

1. **Packages requiring Xcode CLT**: Any package that invokes `xcode-select` or `xcrun` directly
   for compiler detection will fail unless `xcrun` is stubbed as above.
2. **No persistent trustcache**: CDHashes are lost on reboot. `postinst.sh` re-registers them.
3. **Signed binaries count**: Every new `port install` adds new Mach-O files that need signing.
   Run the full signing loop in Phase 4 after each install.
4. **`port` interactive mode**: `port -i` uses readline/libedit; works once libedit is signed.

---

## Summary: MacPorts vs Homebrew

| | MacPorts | Homebrew |
|---|---|---|
| Binary packages for macOS 13 arm64 | Yes (`.pkg`, extracted) | No (Tier 3, deprecated) |
| Core CLI is Mach-O binary | Yes (`port`) | No (bash script → shebang blocked) |
| `DYLD_INSERT_LIBRARIES` preservation | Yes (no `exec env -i`) | No (must patch `FILTERED_ENV`) |
| Requires Xcode CLT for packages | Rarely (pre-built binaries) | Always (source-only on macOS 13) |
| Outcome | Usable | Hard wall at package install |

---

## Files Modified for MacPorts

| File (under `/var/mnt/rootfs/`) | Change |
|---|---|
| `opt/local/etc/macports/sources.conf` | Changed rsync source to HTTPS |
| `opt/local/bin/xcrun` (stub) | Created stub script forwarding to `/usr/bin/clang` |
| All Mach-O files under `opt/local/` | Re-signed with `entitlements.plist` and trustcached |
