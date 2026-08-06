# Cold-start workspace-controller package skew — 2026-08-07

## Failure

After the iPad rebooted, MacWS repeatedly remained at
`检查并修复启动环境…`.  The rootfs and the three existing trust sentinels were
already healthy; the failure happened later in the same synchronous launcher
transaction.

Runtime evidence from `/var/mobile/Library/Logs/MacWSHostd.log`:

```text
[macos_gui] Checking the macOS chroot is runnable...
[macos_gui] chroot, VS Code, and macOS cfprefsd trust sentinels OK.
[macos_gui] Registering the real macOS system/local/user application catalog...
[macos_gui] ERROR: System Settings extension registration failed.
[launchdchrootexec] target=/usr/local/bin/macwsworkspacectl arch=arm64 insert=/usr/local/lib/libmachook_arm64.dylib
usage: macwsworkspacectl set-wallpaper [path] | show-launchpad | register-settings-extension | open-application /absolute/App.app | session-status | activate-process PID | list-windows PID | reopen-process PID | inspect-appkit-reopen | inspect-uikitmac
```

The installed storage and chroot copies were byte-identical and stale:

```text
c05373ed9013fcba19893be37db28059184a31b809176e7242b9647d514a3bd0  /var/jb/usr/macOS/bin/macwsworkspacectl
c05373ed9013fcba19893be37db28059184a31b809176e7242b9647d514a3bd0  /var/mnt/rootfs/usr/local/bin/macwsworkspacectl
```

This is runtime-confirmed package skew: `macos_gui.sh` from commit `85f8714`
requires the plural `register-settings-extensions` operation, while both
installed binaries exposed only the older singular operation.  Each failure
then performed cleanup, and the Host retried the complete startup transaction,
which made the single UI phase look like a permanent hang.

## Repair

The current `macwsworkspacectl` build was installed atomically at both paths,
signed with the project entitlement profile, and its arm64 CDHash
`981e30cf940b374e051e98d5175e3e696c30e79d` was added to the current boot's
trustcache.  The previous binaries remain as `.pre-all-settings` recovery
copies on the device.

Two source guardrails prevent the same split runtime from being published:

1. `misc/build_on_ios.sh --fast` now treats every aggregate non-libmachook
   subproject, including `macwsworkspacectl`, as package-owned.  A newer source
   forces a full build instead of silently shipping only libmachook.
2. Both package and repair postinst paths verify that the packaged controller
   exposes the all-settings startup contract before copying it into the
   chroot.

## Runtime verification

The already-running automatic retry consumed the repaired binary and validated
all 48 Ventura Settings extension records:

```text
settings-extensions-ready candidates=48 registered=48
[macos_gui] LaunchServices application catalog ready.
[macos_gui] All System Settings extension runtimes and carriers are ready.
[macos_gui] Private macOS ViewBridge, ExtensionKit, HIServices and GeoServices contracts ready.
[macos_gui] Loading legacy macOS launchservicesd, input bridge, and WindowServer...
1786033781.078 state busy=YES phase=等待 WindowServer、触控与窗口流… error=
1786033781.202 state busy=NO phase=就绪 error=
```

The Host then launched Terminal and obtained its real DisplayStream window:

```text
1786033781.396 launch-app id=terminal pid=61927 executable=/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
1786033784.884 launch-app window-ready id=terminal pid=61927 path=DisplayStream
```

No reboot or respring was used during repair.  The thermal watchdog remained
armed at its production 300-second interval and reported `thermal-state=nominal`
with an effective battery temperature of 32.19 °C.

## Full-package alignment

A follow-up timestamp audit found that the installed `macwshostd`,
`macwsinputd`, `macwsdisplayd`, and arm64 `libmachook` images also predated the
current `e457662` production source commit.  A clean detached worktree at
`18b9f6c` was therefore rebuilt as a complete package instead of copying more
individual artifacts.  The package witness was:

```text
525c3f50c654530391df15436d0a8fad1a09147a546e9aedd77959ecfb4fc577  com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb
Status: install ok installed
Version: 0.3.4
```

The post-package equivalent cold start again passed the trust sentinels,
registered the application catalog and all Settings extensions, and returned
success.  No reboot or respring was used.

This repair does **not** claim to solve the separate native-AGX WindowServer
stability issue.  After launcher success, runtime logs still showed periodic
WindowServer exit status 6 following Metal command-buffer `Internal Error
00000103`; the watchdog rebuilt input/display services for each replacement
generation.  That failure is downstream of the repaired package-version
contract and needs its own AGX evidence/root-cause cycle.
