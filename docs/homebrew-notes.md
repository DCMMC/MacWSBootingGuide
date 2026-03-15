# Homebrew in the macOS Chroot — Notes & Lessons Learned

Homebrew 4.x can be partially made to work inside the `launchdchrootexec` chroot on Dopamine
rootless, but hits a hard wall on macOS 13 (Ventura): bottles are no longer officially provided,
forcing source builds which require Xcode CLT. This document records every obstacle and workaround
found during the attempt, as a reference for future work or for anyone trying again.

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

---

## Phase 1 — Prerequisites: Signing & Trustcache

Every macOS Mach-O binary exec'd inside the chroot must be:
1. **Re-signed** with the project entitlements plist: `ldid -S<ENT> -M <path>`
2. **Trustcached**: CDHash extracted and registered via `jbctl trustcache add <cdhash>`

Trustcache is **not persistent across reboots** — `postinst.sh` must re-register all CDHashes
on each boot. Signing is persistent (modifies the binary).

Binaries needed for basic Homebrew operation (all in `/var/mnt/rootfs/`):

```
usr/bin/bash          bin/sh              usr/bin/env
usr/bin/curl          usr/bin/openssl     usr/bin/awk
usr/bin/cut           usr/bin/tar         usr/bin/gzip
usr/bin/bzip2         usr/bin/xz          usr/bin/zstd
usr/bin/lz4           usr/bin/unzip       usr/bin/find
usr/bin/xargs         usr/bin/sed         usr/bin/head
usr/bin/sort          usr/bin/uniq        usr/bin/wc
usr/bin/stat          usr/bin/install     usr/bin/mktemp
usr/bin/tee           usr/bin/tr          usr/bin/readlink
usr/bin/realpath      usr/bin/uname       usr/bin/sw_vers
usr/bin/arch          usr/bin/git         usr/bin/ruby
usr/bin/id            usr/bin/date        usr/bin/file
usr/bin/sudo          bin/ln              bin/ls
bin/mkdir             bin/chmod           bin/mv
usr/sbin/chown
```

---

## Phase 2 — DNS / Network

The chroot has no mDNSResponder. DNS lookups fail.

**Fix**: Use `socks5h://127.0.0.1:1082` (note the `h` — routes DNS through the proxy too).
Plain `socks5://` resolves DNS locally and fails.

Export for curl:
```bash
export ALL_PROXY=socks5h://127.0.0.1:1082
export HTTPS_PROXY=socks5h://127.0.0.1:1082
export HTTP_PROXY=socks5h://127.0.0.1:1082
```

---

## Phase 3 — Homebrew Installer Patches

Downloaded the installer from iOS side (not inside chroot):
```bash
curl -fsSL --proxy socks5h://127.0.0.1:1082 \
  https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
  -o /tmp/brew_install.sh
```

Patches applied to `install.sh` (via Python3 on iOS side):
| Line | Original | Replacement | Reason |
|---|---|---|---|
| ~369 | `abort "Don't run this as root!"` | `return 0` | We run as root |
| ~UNAME_MACHINE | `UNAME_MACHINE="$(/usr/bin/uname -m)"` | `UNAME_MACHINE="arm64"` | `uname -m` returns device model (`iPad13,6`) not CPU arch |

Ultimately, the git-based installer was abandoned (procursus git fails with `libiosexec` in
chroot sandbox). Switched to **tarball install**:
```bash
curl -sL --proxy socks5h://127.0.0.1:1082 \
  https://github.com/Homebrew/brew/tarball/master | \
  tar xz --strip 1 -C /var/mnt/rootfs/opt/homebrew
```

---

## Phase 4 — Shebang Exec Blocked by AMFI

**Core constraint**: AMFI kills `execve()` of any script with a `#!/...` shebang line (exit 126,
`EPERM`). This affects ALL shell scripts, not just brew.

**Workaround**: Remove the shebang from scripts. When bash tries to exec a file and gets
`ENOEXEC` (no shebang), it falls back to interpreting the file directly. This works for any
script invoked from a running bash session.

**Applies to**:
- `/opt/homebrew/bin/brew` (remove `#!/bin/bash`)
- All `Library/Homebrew/shims/` files (17 files)
- All `Library/Homebrew/Library/*.sh` files (~11 files)

Files had shebangs stripped using procursus Python3 on iOS side (GNU sed on iOS corrupts files
due to `\n` handling differences).

---

## Phase 5 — `exec env -i` Strips DYLD_INSERT_LIBRARIES

`brew` wraps everything in `exec /usr/bin/env -i FILTERED_ENV...` which strips all env vars
including `DYLD_INSERT_LIBRARIES=/usr/local/lib/libmachook.dylib`. Without libmachook, the new
bash process crashes (missing iOS→macOS syscall shims).

**Fix**: Patch `bin/brew` to inject the variable before the `exec env -i` call:
```bash
# iOS patch: preserve libmachook injection through exec env -i
FILTERED_ENV+=("DYLD_INSERT_LIBRARIES=/usr/local/lib/libmachook.dylib")
FILTERED_ENV+=("SHELL=/bin/bash")
```

---

## Phase 6 — Process Substitution `< <(...)` Requires `/dev/fd`

`brew.sh` and helpers use `< <(cmd)` process substitution, which requires `/dev/fd/N` nodes.
iOS has no `/dev/fd` (no devfs mounted), so these fail with "No such file or directory".

**Fix**: Replace all occurrences with `<<< "$(cmd)"` or pipes:
```bash
# Before:
IFS=. read -r -a arr < <(printf '%s' "$VAR")
# After:
IFS=. read -r -a arr <<< "$VAR"
```

Files patched: `brew.sh`, `utils/helpers.sh`, `utils/ruby.sh`, `shims/utils.sh`

---

## Phase 7 — `shasum` is a Perl Script

`vendor-install.sh` uses `/usr/bin/shasum` to verify download checksums. `shasum` is a Perl
script. After shebang removal, bash tries to interpret Perl POD documentation as shell — syntax
error.

**Fix**: Replace `shasum` usage in `vendor-install.sh` with `openssl dgst`:
```bash
# Before:
sha="$(/usr/bin/shasum -a 256 "${CACHED_LOCATION}" | cut -d' ' -f1)"
# After:
sha="$(/usr/bin/openssl dgst -sha256 "${CACHED_LOCATION}" | awk '{print $NF}')"
```

---

## Phase 8 — Portable Ruby 4.0.1

Homebrew needs its own Ruby (≥4.0) since macOS ships 2.6. It downloads
`portable-ruby-4.0.1.arm64_big_sur.bottle.tar.gz` from GitHub.

**Signing issue**: After extraction, `vendor-install.sh` tests ruby by running it. The binary
is killed (SIGKILL/AMFI) because it was just extracted and isn't in trustcache.

**Fix sequence**:
1. Let `brew vendor-install ruby` download and extract (it will fail the test and clean up)
2. Or: manually extract the cached tarball from iOS side:
   ```bash
   cd /var/mnt/rootfs/opt/homebrew/Library/Homebrew/vendor
   sudo tar xzf /var/mnt/rootfs/Users/root/Library/Caches/Homebrew/portable-ruby-4.0.1.arm64_big_sur.bottle.tar.gz
   ```
3. Sign all Mach-O files under `portable-ruby/4.0.1/`:
   - `bin/ruby`
   - `lib/ruby/gems/.../fiddle.bundle`
   - `lib/ruby/gems/.../debug.bundle`
   - `lib/ruby/gems/.../bootsnap.bundle`
   - `lib/ruby/gems/.../msgpack.bundle`
4. Create symlink: `ln -sfn 4.0.1 portable-ruby/current`

After this, `brew --version` works.

---

## Phase 9 — Curl Shim via `/usr/bin/env`

Homebrew invokes the curl shim as `/usr/bin/env /path/to/shims/shared/curl`. When env tries to
exec a script with no shebang, macOS `execvp` fallback tries `/bin/sh script` — which gets
killed by AMFI (the sh-invoked shim process isn't directly trustcached).

**Fix**: Replace the curl shim script with a symlink to the actual curl binary:
```bash
cp shims/shared/curl shims/shared/curl.bak
rm shims/shared/curl
ln -s /usr/bin/curl shims/shared/curl
```
Now `env shims/shared/curl args` → `env /usr/bin/curl args` (symlink transparent to execve) →
works.

Also patch `utils/curl.rb` to hardcode `/usr/bin/curl` as curl_path (bypasses
`--homebrew=print-path` shim invocation):
```ruby
def curl_path
  @curl_path ||= T.let("/usr/bin/curl", T.nilable(String))
  @curl_path
end
```

---

## Phase 10 — macOS 13 / Bottle Unavailability

After all the above fixes, `brew --version` works and `brew install jq` proceeds to the
download phase. But jq (and its dependencies) have **no prebuilt bottles** for macOS 13
arm64 in current Homebrew:

```
Error: The following formula cannot be installed from bottle and must be
built from source.
  jq
Install the Command Line Tools:
  xcode-select --install
```

macOS 13 (Ventura) is Tier 3 in Homebrew 4.x — officially deprecated. Newer formula versions
no longer publish bottles for it. Building from source requires Xcode CLT which cannot run
inside the chroot (clang is killed by AMFI).

**Conclusion**: Homebrew is not viable for installing packages in this environment without
bottle archives. **Use MacPorts instead** (see `docs/macports-notes.md`).

---

## Files Modified for Homebrew

| File (under `/var/mnt/rootfs/`) | Change |
|---|---|
| `opt/homebrew/bin/brew` | Remove shebang; add `DYLD_INSERT_LIBRARIES` to `FILTERED_ENV`; hardcode `UNAME_MACHINE=arm64`; `return 0` in root check |
| `opt/homebrew/Library/Homebrew/brew.sh` | Replace `< <(...)` with `<<< ...`; create `/.dockerenv` for root bypass |
| `opt/homebrew/Library/Homebrew/utils/helpers.sh` | Replace `< <(stty size)` with `<<< "$(stty size)"` |
| `opt/homebrew/Library/Homebrew/utils/ruby.sh` | Replace process substitutions with pipes |
| `opt/homebrew/Library/Homebrew/shims/utils.sh` | Replace `< <(type -aP ...)` with `<<< "$(type -aP ...)"` |
| `opt/homebrew/Library/Homebrew/cmd/vendor-install.sh` | Replace `shasum` with `openssl dgst -sha256` |
| `opt/homebrew/Library/Homebrew/utils/curl.rb` | Hardcode `curl_path` to `/usr/bin/curl` |
| `opt/homebrew/Library/Homebrew/shims/shared/curl` | Replace script with symlink to `/usr/bin/curl` |
| `opt/homebrew/Library/Homebrew/shims/*` (17 files) | Remove shebangs |
| `opt/homebrew/Library/Homebrew/*.sh` (~11 files) | Remove shebangs |
| `/.dockerenv` | Created (empty) to bypass Homebrew's root check |
| `usr/bin/shasum` | Shebang removed (problematic — Perl POD interpreted as bash) |
