# MacWSBootingGuide
Booting macOS's WindowServer on your jailbroken iDevice for real (WIP)

Some paths are currently hardcoded for rootless jailbreak, but you can change them to work with rootful jailbreak. Some tools are hardcoded for Dopamine jailbreak.

You need these from simulator runtime: MTLSimDriver.framework, MTLSimImplementation.framework, MetalSerializer.framework

## Setting up (macOS full installation)
TODO: make a script
- Extract full filesystem dmg to a directory, e.g. `/var/mnt/rootfs`
- ~~Extract App cryptex dmg to `rootfs/System/Volumes/Preboot/Cryptexes/App`~~ (for Safari only, which is not needed)
- Extract OS cryptex dmg to `rootfs/System/Volumes/Preboot/Cryptexes/OS`
- Copy-merge folders from `rootfs/System/Library/Templates/Data` to your `rootfs`
- Symlink `rootfs/System/Volumes/Data` -> `../..`
- Symlink `/home` -> `rootfs/System/Volumes/Data/home` (optional?)
- Symlink `rootfs/var/folders/zz` -> `/var/folders/zz`
- mkdir `rootfs/Users/root`
- Copy `/etc` from macOS installation to `rootfs/etc` (optional?)
- [Bind mount](https://github.com/khanhduytran0/mount-bindfs-dopamine) `rootfs/var/jb` -> `/var/jb`
- Patch `dyld`, `launchservicesd` and `WindowServer` as described below.
- Modify `cpusubtype` in `Installer Progress` and `WindowServer` using `set_to_arm64`
- For every executable you wanna run, sign and merge with `entitlements.plist` in this repo: `ldid -S./entitlements.plist -M binary_name`.
- Load macOS trustcaches using `loadtc /path/to/trustcache`

## Starting up
build in macOS:
```bash
# edit DEVICE_IP/DEVICE_PORT at the top of misc/build.sh to match your iPad/iPhone
bash misc/build.sh
```

run in your iPad/iPhone device:

```bash
sudo bash /var/jb/usr/macOS/bin/postinst.sh
# enter macOS bash environment
sudo bash /var/jb/usr/macOS/bin/run_bash.sh
```

To run any exectuable in (chroot) macOS, run this in iOS shell:

```bash
cd $(realpath $HOME/../..)/usr/macOS

add_trustcache() {
    local path=$1
    local cdhash
    cdhash=$(ldid -arch arm64 -h $path 2>/dev/null | grep CDHash= | cut -c8-)
    if [ -n "$cdhash" ]; then
        echo "Adding $path cdhash: $cdhash"
        jbctl trustcache add "$cdhash"
    fi
}

add_arm64e_trustcache() {
    local path=$1
    local cdhash
    cdhash=$(ldid -arch arm64e -h $path 2>/dev/null | grep CDHash= | cut -c8-)
    if [ -n "$cdhash" ]; then
        echo "Adding $path cdhash: $cdhash"
        jbctl trustcache add "$cdhash"
    fi
}

add_x86_64_trustcache() {
    local path=$1
    local cdhash
    cdhash=$(ldid -arch x86_64 -h $path 2>/dev/null | grep CDHash= | cut -c8-)
    if [ -n "$cdhash" ]; then
        echo "Adding $path cdhash: $cdhash"
        jbctl trustcache add "$cdhash"
    fi
}

add_all_trustcache() {
    add_trustcache $1
    add_arm64e_trustcache $1
    add_x86_64_trustcache $1
}

cp /var/mnt/rootfs/usr/bin/whoami{,.bak}
ldid -S./bin/entitlements.plist -M /var/mnt/rootfs/usr/bin/whoami
add_all_trustcache /var/mnt/rootfs/usr/bin/whoami
```

Debug `kill: 9` when running macOS binary in iOS:
```bash
sudo oslog | grep "AMFI\|debugbydcmmc\|launchd\|launchser\|WindowSer\|MTL\|Metal\|Terminal\|iolation"
```

Open GUI in (chroot) macOS — the easy way (recommended), via `macos_gui.sh`:

```bash
# Cleans up any previous macOS services, sets the display mode, loads WindowServer,
# and starts the VNC server + Terminal as persistent launchd jobs (so they survive
# an SSH disconnect). Run on the iOS side as root:
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start coexist     # iPad keeps iOS on the panel, macOS -> VNC only
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start exclusive   # macOS takes over the physical panel + VNC
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh status            # show what is running
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh stop              # tear everything down, return to iOS
```

Then connect a VNC viewer to `vnc://<device-ip>:5900` (no password). Add
`--no-terminal` / `--no-vnc` to `start` to skip those clients. **coexist** is the
safer default — **exclusive** drives the panel from WindowServer, the most
panic-prone GPU path on this device. `start` also launches a watchdog that
auto-stops the GUI if WindowServer crash-loops or the load runs away (panic guard);
`--no-watchdog` disables it. After a reboot wipes the trustcache, `start` re-runs
`postinst.sh` automatically.

Open GUI in (chroot) macOS — the manual way:

```bash
sudo launchctl unload /System/Library/LaunchDaemons/com.apple.{SpringBoard,backboardd}.plist
sudo launchctl load /var/jb/usr/macOS/LaunchDaemons
```

In (chroot) macOS bash environment, you can run CLI or GUI applications:

- `/usr/local/bin/OSXvnc-server -rfbnoauth` first to open a VNC server
- `/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal`
- `/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor`

Note: launched this way, the VNC server / GUI apps are children of your shell and
die when it (or the SSH session) exits. For coexistence mode (iOS keeps the panel)
set the runtime flag `touch /var/mnt/rootfs/tmp/ws_headless` before starting
WindowServer. `macos_gui.sh` above handles both of these for you.

Respring to iOS:

```bash
sudo launchctl unload /var/jb/usr/macOS/LaunchDaemons
sudo launchctl load /System/Library/LaunchDaemons/com.apple.{SpringBoard,backboardd}.plist
```

## Running Claude Code in the chroot

The Claude Code native CLI (a bun/JSC binary) runs inside the macOS chroot.
Several chroot-specific quirks are involved:

- **AMFI / signing** — every Mach-O must be ad-hoc re-signed + trustcached or AMFI
  `SIGKILL`s it (an Apple signature alone is not enough — its platform-binary /
  library-validation flags get the process killed even when the CDHash is
  trustcached). This is now automatic: the `autosignd` daemon + `libmachook`'s
  exec hooks sign+trustcache each binary on first `exec` (see "On-demand signing"
  below), so `claude` and everything it spawns (`security`, `ps`, `ioreg`, `git`,
  …) just work. `postinst.sh` also signs `claude` and `/usr/bin/security` up front.
- **JSC gigacage** — JavaScriptCore tries to reserve a 64 GiB virtual-address
  "gigacage" at startup, which fails on iOS (`FATAL: Could not allocate gigacage
  memory`). Set `GIGACAGE_ENABLED=0` to disable it.
- **No DNS** — the chroot has network but no working resolver. Route through a
  proxy (the chroot can't resolve hostnames itself). **Important:** Claude Code's
  API client (undici) only honors **`http(s)://` proxies, not `socks5h://`**
  (it does run its own SOCKS server for sandboxed children, but won't use a SOCKS
  proxy for its own API calls). So set `HTTPS_PROXY=http://HOST:PORT` — e.g. point
  it at a mixed http+socks proxy like `pproxy`. `curl`/`git`/`pip` accept the same
  `http://` proxy and resolve DNS through it too.

**1. Install the binary.** The official `install.sh` aborts because the chroot's
`uname -m` reports `iPadN,N` ("Unsupported architecture"), so download the
macOS-arm64 build directly into the chroot at `/usr/local/bin/claude`:

```bash
# inside the chroot (network via your http proxy):
ver=$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)
curl -fsSL -o /usr/local/bin/claude \
  "https://downloads.claude.ai/claude-code-releases/$ver/darwin-arm64/claude"
chmod +x /usr/local/bin/claude
sudo bash /var/jb/usr/macOS/bin/postinst.sh   # sign + trustcache it (from iOS shell)
```

**2. Configure the environment.** The `Claude Code TUI environment` block in
`/var/mnt/rootfs/Users/root/.bashrc` sets `PATH`, `GIGACAGE_ENABLED=0`,
`SSL_CERT_FILE`, and the `http://` proxy vars. Add your auth (env vars work — no
`settings.json` required):

```bash
# Official API key (sent as x-api-key):
export ANTHROPIC_API_KEY=sk-ant-...
# OR a Bearer token for a relay/gateway (sent as Authorization: Bearer) — then
# also set the relay endpoint:
export ANTHROPIC_AUTH_TOKEN=...
export ANTHROPIC_BASE_URL=https://your-relay.example.com/
```

If `ANTHROPIC_BASE_URL` is an **internal** host (e.g. a corp gateway on a `10.x`
IP) it must be reached directly, not via an overseas circumvention proxy — add the
host to the chroot's `/etc/hosts` (chroot has no DNS) and `NO_PROXY` it, or use a
proxy whose egress is on that internal network.

**3. Run it:**

```bash
sudo bash /var/jb/usr/macOS/bin/run_bash.sh   # interactive; sources ~/.bashrc
claude          # TUI; or:  claude -p "hi"
```

### On-demand signing (`autosignd` + `libmachook` exec hooks)

AMFI evaluates every `exec` in the kernel, so a binary can only be signed from an
**iOS-platform** process (the chroot's macOS dyld refuses to load
`libjailbreak.dylib`, so chroot code cannot call `jbclient_*` directly). The flow:

- `libmachook` interposes `posix_spawn[p]` / `execve` / `execv` / `execvp`. Before
  each `exec` it sends the target's chroot path to `autosignd` over the unix socket
  `/tmp/autosignd.sock` and waits for an ack (fail-open; per-process path cache).
- `autosignd` (started by `postinst.sh`, runs in the iOS context) translates the
  path into the rootfs, ad-hoc re-signs it with `ldid -S<entitlements> -M`, and
  registers every slice's CDHash via `jbctl trustcache add`.

Net effect: arbitrary macOS programs run in the chroot without pre-listing every
binary in `postinst.sh`. (`execl*` varargs forms are not interposed — rare, and
they call the array forms internally inside libsystem.)

## Additional patches
> [!NOTE]
> - Some offsets are hardcoded for iOS 16.5/macOS 13.4
> - [x] means it is automated or handled by hooks
> - [ ] means you need to patch it by hand

### macOS side
#### dyld
- [ ] `mach-o file, but is an incompatible architecture (have 'arm64e', need 'arm64')` because `GradedArchs::grade` [disallows](https://github.com/apple-oss-distributions/dyld/blob/dyld-1285.19/common/MachOFile.cpp#L1985-L1989) loading non-system arm64e libraries to arm64 processes. (not really this function but the caller of it I forgot).

#### launchservicesd
- [x] Missing syscalls: `audit_token_to_asid`, `audit_token_to_auid`, `auditon`, `getaudit_addr`
- [ ] This daemon needs to be converted to a dylib using [LiveContainer's method](https://github.com/LiveContainer/LiveContainer/blob/341cc87d40d8eec690d21dc71bd69d74667588da/LiveContainer/LCMachOUtils.m#L71-L88). Please make sure to resign dylib without entitlements to avoid codesign panic ([#2](https://github.com/khanhduytran0/MacWSBootingGuide/issues/2)).

#### loginwindowLite
- [ ] `Error (non-fatal) enumerating <private>: Error Domain=NSCocoaErrorDomain Code=256 "The file “Library” couldn’t be opened." UserInfo={NSURL=Library/ -- file:///System/Library/CoreServices/CoreTypes.bundle/Contents/, NSFilePath=/System/Library/CoreServices/CoreTypes.bundle/Contents/Library, NSUnderlyingError=0x13d5a73b0 {Error Domain=NSPOSIXErrorDomain Code=20 "Not a directory"}}`: because `/System/Volumes/Data/System/Library/CoreServices/CoreTypes.bundle/Contents/Library` might be missing.

#### MTLSimDriver
- [x] `failed assertion _limits.maxColorAttachments > 0 at line 3791 in -[_MTLDevice initLimits]`, can be bypassed using `CFPreferencesSetAppValue(@"EnableSimApple5", @1, @"com.apple.Metal")`
- [x] `-[MTLTextureDescriptorInternal validateWithDevice:], line 1344: error 'Texture Descriptor Validation invalid storageMode (1). Must be one of MTLStorageModeShared(0) MTLStorageModeMemoryless(3) MTLStorageModePrivate(2)`: because macOS defaults to `MTLStorageModeManaged`, while iOS always has unified memory so it doesn't allow that.
- [x] `Attempt to pass a malloc(3)ed region to xpc_shmem_create().`: while regular drivers accept passing `malloc`ed region to `newBufferWithBytesNoCopy:length:options:deallocator:`, doing so to simulator is not allowed since XPC has to share the memory with `MTLSimDriverHost.xpc` process. Workaround is to create a mirrored region using `vm_remap` that can be shared across processes.
- [x] `Unimplemented pixel format of 645346401 used in WSCompositeDestinationCreateWithIOSurface.` due to missing implementation of `-[MTLSimDevice acceleratorPort]`, which mysteriously caused WindowServer to fallback to software rendering in some places, causing said fatal error.
- [x] `-[MTLSimDevice newRenderPipelineStateWithTileDescriptor:options:reflection:error:], line 2124: error 'not supported in the simulator'`. FIXME: this is not implemented at all. However, it is only used by `QuartzCore'CA::OGL::BlurState::tile_downsample(int)` which is skipped by the hook.
- [x] `-[MTLSimTexture initWithDescriptor:decompressedPixelFormat:iosurface:plane:textureRef:heap:device:]:813: failed assertion 'IOSurface backed XR10 textures are not supported in the simulator'`: patch out the check, since it actually works fine.
- [x] `-[MTLSimBuffer newTextureWithDescriptor:offset:bytesPerRow:]`: patch `storageMode == private` check.

#### WindowServer
- [x] It hangs twice when calling `NXClickTime` and `NXGetClickSpace`. Hooked to do nothing instead since both were deprecated.
- [ ] Missing light theme when using macOS recovery. Can be fixed by copying `/System/Library/CoreServices/SystemAppearance.bundle/Contents/Resources` from full macOS installation.

### iOS side
#### MTLCompilerService
- [x] `MTLCompilerObject::readModuleFromBinaryRequest`: patch platform check to allow cross-platform compilation. MTLCompilerBypassOSCheck compares against hardcoded instruction so it might not be reliable across iOS versions.

#### launchd
- [x] `Path not allowed in target domain` is raised when attempting to load XPC bundles not declared in `launchd.plist` (`MTLSimDriverHost.xpc` in this case). This can be bypassed by adding `com.apple.private.domain-extension` entitlement.

#### watchdogd
- [x] Install `WatchDisable` tweak from [this repo](https://nathan4s.lol/repo) which automatically runs @zhuowei's `who_let_the_dogs_out.c` at boot.

## Credits
- [zhuowei/iOS-run-macOS-executables-tools](https://github.com/zhuowei/iOS-run-macOS-executables-tools)
- [SongXiaoXi/Reductant](https://github.com/SongXiaoXi/Reductant)
