# Startup latency optimization — 2026-09-12

## Scope / current deployment

Device: iPad13,6, iPadOS 16.3.1, root@192.168.1.7:2222.
Only the launcher, single-process trust helper, Settings verifier and Settings
verification script have been activated. The new macwshostd is signed/trusted
and staged at `/var/jb/usr/macOS/bin/macwshostd.next-latency-20260912`, **not
loaded**. User confirmation to save documents/restart the macOS workspace is
pending. No respring, WindowServer restart, trustcache clear, or reboot was
performed in this optimization turn. No commit/push.

Other working-tree changes from the preceding production-defaults audit remain
separate and have NOT been deployed. Do not deploy them incidentally.

## Runtime evidence

Baseline from `/var/mobile/Library/Logs/MacWSStartup.log`:

```text
[macos_gui] Application trust closure ready (bundles=12 Mach-O images=1067).
[macos_gui] Cold-boot trust closure ready (registered=309 existing CodeDirectories).
[macos_gui] TIMING gui-start stage=trust seconds=452 total=469
[macos_gui] TIMING gui-start stage=services seconds=57 total=526
```

New helper, full application roots, no extraction/resource cache, read-only:

```text
BOOT-TRUST {"added": 0, "backend": "dry-run", "cached": 0, "files": 194002, "hashes": 277, "images": 1050, "scan_seconds": 71.71, "total_seconds": 71.71}
```

Cache populated (disk resource index about 43 MiB, SQLite page-cache budget
2 MiB). All 1,050 selected signed native images compared to the device's
`ldid -arch ... -h` in `--verify-ldid` mode; no mismatches, 37.83 s including
the external ldid verification. The old image counter also counts Mach-O files
without an eligible signed arm64/arm64e slice; it is not the native hash count.

Full application scan with cached metadata, plus real registration replay of
all 277 hashes (no trustcache clear):

```text
BOOT-TRUST {"added": 277, "backend": "libjailbreak", "cached": 1050, "files": 194002, "hashes": 277, "images": 1050, "resource_hits": 192952, "scan_seconds": 9.75, "total_seconds": 9.884}
thermal-state=nominal raw=0 low-power=no battery-temp-centic=3719 virtual-temp-centic=3719 effective-temp-centic=3719 uptime=3219.249
```

After integration, the actual installed `macos_gui.sh trust` path (all base
prerequisites, Hydra, QuickLook providers, applications and both shared-cache
hashes, not an applications-only benchmark):

```text
BOOT-TRUST {"added": 0, "backend": "already-trusted", "cached": 1047, "files": 195644, "hashes": 368, "images": 1138, "resource_hits": 192903, "scan_seconds": 9.355, "total_seconds": 9.637}
[macos_gui] Cold-boot trust closure ready (complete dependency closure; live membership verified).
```

These are **same-boot recovery/replay measurements**. They do not establish
post-reboot filesystem-cache performance, 10-second total startup, or a new
end-to-end cold-start total. First use without any index remains slower.

### Application launch

Old timing from `/var/mobile/Library/Logs/MacWSHostd.log`:

```text
1789222903.182 launch-app id=excel pid=21855 executable=/Applications/Microsoft Excel.app/Contents/MacOS/Microsoft Excel
1789222906.233 application-reopen pid=21855 sent=YES errno=0
1789222908.619 application-reopen pid=21855 result=window-ready previous-generation=0 current-generation=1 exit-status=-1
1789223500.984 application-reopen pid=23558 sent=YES errno=0
1789223585.864 launch-app id=sublime pid=23729 executable=/Applications/Sublime Text.app/Contents/MacOS/sublime_text
1789223588.931 application-reopen pid=23729 sent=YES errno=0
```

The one-shot probe compiles the ACTUAL candidate daemon source, opens an
allowed app, and does not register a second broker or replace the live daemon.
New Word launch:

```text
1789224659.916 launch-app id=word pid=26414 executable=/Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word
1789224660.458 launch-app lifecycle-ready pid=26414 route=endpoint-driven-reopen
1789224660.458 application-reopen pid=26414 sent=YES errno=0
1789224663.272 application-reopen pid=26414 result=window-ready previous-generation=0 current-generation=1 exit-status=-1
LAUNCH-PROBE app=word ready=yes pid=26414 seconds=3.377 message=已启动 word，AppKit 窗口已进入 DisplayStream 列表
```

The initial native reopen is now endpoint-driven (0.542 s in this sample), not
withheld by the old 3-second grace. This is not a claim that all launches save
3 seconds: app initialization overlaps the old wait. Document delivery remains
on its separate endpoint-ready route. A real visible window wins before a
reopen is sent; failure still requires a fresh generation/real visible metrics.

### Settings extension preparation

The initial probe exercised the old preparation script and took 38.332 s:

```text
1789224696.634 system-settings runningboard-bridge result=verified pid=387
1789224696.636 spawned pid=26469 executable=/var/jb/usr/bin/bash wait=YES
1789224697.083 spawned pid=26507 executable=/var/jb/usr/bin/bash wait=YES
1789224725.486 spawned pid=28406 executable=/var/jb/usr/bin/bash wait=YES
1789224725.655 system-settings runtime result=verified action=dependency-reconcile initial_verify=1 repair=0
1789224726.009 launch-app id=system-settings pid=28431 executable=/System/Applications/System Settings.app/Contents/MacOS/System Settings
1789224734.965 launch-app window-ready id=system-settings pid=28431 path=DisplayStream
```

This confirms ~28.4 s in dependency reconciliation, but the truncated/overwritten
old verifier log does NOT prove exactly which dependency forced that repair.
Do not claim the new verifier eliminates necessary dependency-copy work after
a real library update.

New complete verification, after that repair:

```text
SETTINGS-VERIFY {"added": 2, "backend": "libjailbreak", "cached": 0, "files": 243, "images": 243, "panes": 48, "resource_hits": 0, "total_seconds": 0.394}
SETTINGS-VERIFY {"added": 0, "backend": "already-trusted", "cached": 243, "files": 243, "images": 243, "panes": 48, "resource_hits": 0, "total_seconds": 0.146}
```

This checks all pane identities, unique executable fallback, setuid carriers,
iOS registration, exact actual dependency signatures and live trust, not only
the old aggregate boot marker. Missing/stale dependencies still fail into the
existing repair path. The separate typed LaunchServices verifier is unchanged.

Actual Host `macwshost://system-settings` reopening succeeded. The inspected
native screenshot `tmp/launch-optimization-settings-visible-20260912.png`
shows real Settings Appearance controls, with Word's template window behind.
The earlier `...settings-20260912.png` shows the iOS home screen and is NOT a
macOS rendering acceptance witness. Screenshots contain user app context and
are deliberately not added to Git.

## Implementation and safety

- `macws_boot_trust.py`: seek/read CodeDirectory hashing, 64 KiB hash chunks,
  fat/thin and arm64/arm64e handling; never maps/loads entire executables.
  Format reference: [Apple XNU cs_blobs.h](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h).
- Disk caches validate device, inode, size, nanosecond mtime AND ctime on every
  scan. Resource-to-code replacement invalidates a negative entry. Cache files
  are private, atomic/transactional and not witnesses of live trust. iOS still
  performs normal code-page validation. No re-signing by the restore helper.
- Exact native registration ABI RE-confirmed via the device's
  `libjailbreak.dylib` at `0xaefc`: x0/x1 feed `_xpc_dictionary_set_data` at
  `0xaf30`; reply `result` read at `0xaf68`, integer returned at `0xaf90`.
  Matches existing `misc/loadtc`. Other versions lacking the symbol fall back
  to checked `jbctl trustcache add`, followed by live membership verification.
- Complete application closure retained; no cost transfer to the first Office
  launch. Thermal admission and ten-second scan checkpoints retained.
- New app admission tests compile the actual loop with deterministic witness
  functions; they cover visible-window win, immediate endpoint admission,
  process exit and timeout, with at most one reopen.

## Validation / pending work

Local test discovery: 123 tests; signature/parser/cache and Settings corruption
cases plus compiled app admission tests. macwshostd arm64 build passes. Shell
syntax and runtime-switch audit pass. Production audit changes remain separate.

Pending: activate candidate macwshostd only after user has saved current macOS
documents; then controlled app samples (fresh, reuse, document open), and one
full workspace start with startup timing + visible/input acceptance. True
device-reboot acceptance remains separate; do not clear trustcache or claim a
workspace restart simulates all aspects of a reboot.

Rollback launcher:
`/var/jb/usr/macOS/bin/macos_gui.sh.before-latency-20260912`.
Rollback Settings script:
`/var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh.before-latency-20260912`.
Resource/hash caches are regenerable and contain no user document content.
