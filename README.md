# MacWS Booting Guide

Run the real **macOS WindowServer and GUI applications on a jailbroken iPad or
iPhone** — a full macOS desktop rendered live on the iOS display, driven by the
device's own AGX GPU. This is the production release branch.

The project chroots a full macOS 13.4 (Ventura) root filesystem on the iOS
device, `exec`s macOS binaries inside that chroot, and bridges the two worlds:
WindowServer renders through the real iOS AGX kernel driver, the Host app on
the iPad streams the desktop via `IOSurface` (no VNC needed for the primary
path), and a root control daemon orchestrates the whole lifecycle.

> **State of this branch:** production-oriented. Defaults to production mode
> (no diagnostic instrumentation), ships a one-tap debug mode from the Control
> Center, self-heals a crashed debug session on the next production start, and
> is built/verified by GitHub Actions.

---

## What it looks like

- The **MacWSHost** app (iOS UIKit) shows the macOS desktop on the iPad panel
  and acts as the Control Center: start/stop the workspace, launch apps, choose
  touch vs. trackpad, change display density, import/export files, sync the
  clipboard, and view logs.
- Native **Finder, Dock, SystemUIServer, ControlCenter, System Settings, Maps,
  Terminal, GlassDemo, Activity Monitor, VS Code** run inside the chroot as
  real Ventura processes.
- Input is delivered as native AppKit events (touch → clicks, trackpad mode,
  two-finger scroll, pinch-to-zoom, hover, pencil).

---

## Requirements

| Requirement | Value |
|---|---|
| Device | iPad13,6 (and similar arm64e iPads) |
| iPadOS | 16.3 / 16.3.1 |
| Jailbreak | **Dopamine** (rootless, Procursus) |
| macOS rootfs | Full **macOS 13.4** (Ventura) filesystem, extracted to `/var/mnt/rootfs` |
| GPU path | Real iOS **AGX** kernel driver (`MACWS_AGX_NATIVE=1`) |

> Some paths are hardcoded for a rootless jailbreak. With rootful
> jailbreaks you will need to adjust the `/var/jb` prefix and trustcache flow.

---

## Quick start (installed package)

Once the `.deb` is installed on the device (see [Installation](#installation)):

```bash
# 1. (one time) mount the macOS rootfs and prepare the chroot — done by the
#    package postinst, or re-run it after reinstalling:
sudo bash /var/jb/usr/macOS/bin/postinst.sh
```

Then open the **MacWSHost** app on the iPad. It auto-starts the macOS
workspace, or tap **启动 macOS 工作区**. The desktop streams to the panel;
touch works immediately.

### Command-line control

```bash
# Enter the chroot shell
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c "echo hi"

# Start / stop the full GUI stack (root, from the iOS shell)
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production    # production start
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh stop          # tear down, return to iOS
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh status        # what is running

# Debug-mode session (rich diagnostics, slower by design)
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start --debug
```

---

## Runtime modes

A session runs in exactly one runtime mode.

### Production (default)

- No diagnostic environment variables or sentinels; `production_preflight`
  asserts a clean environment before WindowServer loads.
- **Self-healing:** if a debug session crashed without stopping cleanly, the
  leftover debug environment is stripped on the next production start, so a cold
  production start always recovers to full functionality.

### Debug mode

- Enabled from the **Control Center** (调试模式 switch, persisted) or the CLI
  (`macos_gui.sh start --debug`).
- Injects getenv-driven libmachook traces (`AGX_CRASH_DIAG`, `ABORT_TRACE`,
  `IOSURF_TRACE`, `XPC_DEBUG`, `MACH_MSG_TRACE`, …) into the WindowServer/VNC/
  Terminal launchd contracts plus the full diagnostic sentinel set.
- Slower and heavier; `stop` restores the production contracts.
- Behavior-changing LAZY/scaffold toggles (`MACWS_KEEP_ASSERT_BYPASS`,
  `MACWS_AGXIOC_FUZZ`, …) are deliberately excluded even from debug mode.

---

## Installation

### Build the `.deb`

**On the device (recommended):**

```bash
ssh -p 2222 root@<device-ip> \
  'THEOS=/var/jb/var/mobile/theos bash /var/jb/var/mobile/MacWSBootingGuide/misc/build_on_ios.sh'
```

**From macOS (cross-compile):** set `DEVICE_IP`/`DEVICE_PORT` at the top of
`misc/build.sh`, then `bash misc/build.sh`.

**From CI:** push a `v*` tag; `.github/workflows/release.yml` builds the `.deb`
on a macOS runner (Theos + `iPhoneOS16.5.sdk` + Xcode macOS SDK + `brew install
dpkg ldid`) and attaches it to a GitHub Release.

### Install on the device

```bash
# Copy the .deb to the device, then:
sudo dpkg -i com.kdt.macosbooter_<version>_iphoneos-arm.deb
sudo bash /var/jb/usr/macOS/bin/postinst.sh     # sign + trustcache everything
```

---

## Device setup (one time, before first package install)

1. Extract a full **macOS 13.4** DMG to `/var/mnt/rootfs` (and the OS cryptex
   to `rootfs/System/Volumes/Preboot/Cryptexes/OS`).
2. Copy-merge `rootfs/System/Library/Templates/Data` into your `rootfs` and
   create the documented symlinks (`System/Volumes/Data → ../..`, `/home`,
   `var/folders/zz`, …).
3. Bind-mount `rootfs/var/jb → /var/jb`
   ([mount-bindfs-dopamine](https://github.com/khanhduytran0/mount-bindfs-dopamine)).
4. Patch `dyld`, `launchservicesd` and `WindowServer` as documented in
   `README`'s "Additional patches" history and in `docs/`; the package's
   `postinst.sh` re-signs every Mach-O with `entitlements.plist` and registers
   CDHashes in the trustcache.
5. Install the `.deb` (above).

---

## Architecture

### Subprojects (root `Makefile`)

**iOS-side (run in the iOS context):**
- `MacWSHost` — the Control Center / display-stream client app.
- `macwshostd` — root control daemon (`com.macwsguide.host.control` XPC); runs
  the GUI lifecycle script, launches apps, reports typed status.
- `macwsallocd` — IOSurface allocator (`com.macwsguide.alloc`).
- `macwsthermal` — iOS-native temperature watchdog helper.
- `autosignd` — on-demand Mach-O re-sign + trustcache for arbitrary chroot
  binaries.
- `launchdchrootexec` — posix_spawns a macOS binary inside the chroot with
  `DYLD_INSERT_LIBRARIES=libmachook.dylib`.
- `MTLCompilerBypassOSCheck`, `MTLSimDriverHost`, `MacWSWindowing`,
  `MacWSCatalystLaunch`, `SettingsExtension*`, `ViewBridge*`, `HIServices*`,
  `Geod*`, `Locationd*`, `FileCoordination*`, `OpenAndSavePanel*`,
  `DockHelper*`, `ExtensionKit*`, `WriteConfig*` proxies.
- `mountdevfs`, `mtl_keepalive`, `misc/PingMTLCompilerService`.

**macOS-side (built for macOS, run inside the chroot):**
- `libmachook` — the injected hook dylib (`DYLD_INSERT_LIBRARIES`), the heart
  of the project: dyld image-load callbacks that patch incompatible system
  calls, AGX/IOGPU/Metal interposers, IOSurface transport, VNC bridge.
- `launchservicesd`, `macwsinputd` (AppKit input), `macwsdisplayd`
  (DisplayStream/IOSurface bridge), `macwsinteropd` (clipboard/files),
  `macwsworkspacectl` (desktop control).

### libmachook module layout

`libmachook/` was split from a single 17,000-line file into focused units:

| File | Responsibility |
|---|---|
| `mac_hooks.m` | infrastructure, JIT, `loadImageCallback` dispatcher |
| `mac_hooks_vnc.m` | diagnostics, VNC/OSXvnc, fsnode/CoreLocation |
| `mac_hooks_iosurface.m` | IOSurface adapters, `IOServiceOpen`, LSD/HIServices |
| `mac_hooks_iogpu.m` | the `#ifdef FORCE_M1_DRIVER` IOGPU/AGX submit subsystem |
| `mac_hooks_internal.h` | shared preamble, types, and cross-part externs |
| `Metal_hooks.x` | Metal/AGX texture + device hooks |
| `AppInputBridge.m` | VNC/AppKit input bridge |
| `exec_hooks.c` | exec-time signing daemon client |

### The startup cascade

`macos_gui.sh start` (orchestrated by `macwshostd` on a Control-Center start):

1. Generates launchd contracts (`gui-launchd/`), retires any previous
   generation.
2. Applies the runtime mode (production = assert clean; debug = inject
   diagnostic env).
3. Arms the mandatory thermal/crash-loop watchdog.
4. Publishes system services (systemstatusd, cfprefsd, lsd, iconservices,
   LaunchServices catalog, Settings proxies), then `launchservicesd` +
   `macwsinputd` + **WindowServer**.
5. Waits for WindowServer graphics readiness, then launches the workspace
   agents (Finder, Dock, SystemUIServer, ControlCenter) and optional VNC/
   Terminal.

`macos_gui.sh stop` (or `misc/cleanup_all.sh` for emergencies) tears everything
down and restores SpringBoard/backboardd.

---

## Troubleshooting

| Symptom | What to check |
|---|---|
| Start fails | The Control Center shows the `macos_gui.sh` output tail (`last_error_detail`). Or: `sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start --debug` |
| App killed by AMFI (`SIGKILL`) | Binary not signed/trustcached. Run `sudo bash /var/jb/usr/macOS/bin/postinst.sh` or use `misc/sign_installed.sh` |
| `chdir: No such file or directory` | Harmless — `run_bash.sh` falls back to `/` |
| No desktop / black frame | Check WindowServer logs via the Control Center log viewer |
| CPU stuck / crash loop | `sudo bash /var/jb/var/mobile/MacWSBootingGuide/misc/cleanup_all.sh` (bounds the loop, restores iOS) |
| Debug session crashed | Next `production` start strips leftover debug env automatically |

### Logs

- `MacWSHostd.log` — root control daemon (`/var/mobile/Library/Logs/`)
- `WindowServer.err` / `WindowServer.out` — WindowServer
- `macos_gui_watchdog.log` — thermal/crash-loop guard
- `macos_gui_start.state` — start phase state machine

### On-demand signing

AMFI evaluates every `exec` in the kernel, so binaries are signed from an
iOS-platform process. `libmachook` interposes `posix_spawn`/`execve` and asks
`autosignd` (via `/tmp/autosignd.sock`) to re-sign + trustcache each binary
before it runs — arbitrary macOS programs work in the chroot without pre-listing
every binary.

---

## Development

- **Docs:** `docs/` — `displaystream-host-architecture.md` (architecture),
  `runtime-switches.tsv` + `.md` (authoritative env/sentinel inventory).
- **CI checks:** `.github/workflows/ci.yml` runs the runtime-switch audit,
  shell syntax, and plist lint on every push/PR; `release.yml` builds the `.deb`.
- **Local syntax check:** `bash misc/compile_check.sh <file.m> …` compiles an
  iOS-side ObjC file against the Xcode SDK to catch typos before shipping.
- **Runtime-switch audit:** `python3 misc/audit_runtime_switches.py` verifies
  every `getenv`/sentinel has a manifest entry.
- **Patch discipline:** see `AGENTS.md`. A symptom-suppressing patch is not a
  fix; every claim about a broken path needs decompiled-code or runtime-log
  evidence.

---

## Credits

- [zhuowei/iOS-run-macOS-executables-tools](https://github.com/zhuowei/iOS-run-macOS-executables-tools)
- [SongXiaoXi/Reductant](https://github.com/SongXiaoXi/Reductant)
- [LiveContainer](https://github.com/LiveContainer/LiveContainer) (launchservicesd → dylib conversion method)
- Theos, Dopamine, Procursus communities
