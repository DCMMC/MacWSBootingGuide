# VNC system-input and menu-compositor milestone — 2026-07-29

This directory records the 2026-07-29 VNC usability work on iPad13,6.  The
production target remains coexistence mode with the native iOS AGX driver.
The milestone is not the final performance/JIT milestone: long-tail input
latency and Chromium's video/mipmapped-IOSurface path remain open.

## 1. System-wide input ownership

`osxvnc-handle-mouse-arm64-disasm.txt` is the arm64 disassembly of the exact
installed OSXvnc binary.  `-[VNCServer handleMouseButtons:atPoint:forClient:]`
stores the point and calls `_CGPostMouseEvent`; this is the system event path,
not an application-private `NSEvent` injection path.

The production hook now forwards every pointer transition through that
original implementation after converting Retina RFB pixels to Quartz points.
It covers hover, left/right down/up, and button-held motion.  Runtime log lines
use the `OSXVNC NATIVE-ALL` prefix and contain both coordinate spaces and the
complete button mask.  `AppInputBridge` remains available for the native iPad
host and as an observational per-AppKit endpoint, but VNC no longer splits
pointer ownership across processes.  This is why WindowServer-owned UI such as
the menu bar and context menus is reachable.

The automated benchmark sends one persistent RFB sequence containing menu
open, eight hover points, menu close, right click/context close, and a
button-held title drag.  The first clean transport run completed 13/13 actions
with p50 0.292 s and max 0.336 s:

- `stable-snapshot-diff/results.json`
- `stable-snapshot-diff/osxvnc-tail.log`

## 2. VNC dirty-region correctness

Runtime logging showed that OSXvnc's mmap watcher compared the previous frame
against a live seqlock mapping while WindowServer could replace that mapping
row-by-row.  A generation change invalidated `previousPixels`, so the next
iteration repeatedly fell back to a full 2388x1668 rectangle.

The watcher now copies one stable generation into private current/previous
buffers and diffs those snapshots.  In the same 13-action raw benchmark, RFB
traffic fell from 166,979,432 bytes to 37,413,840 bytes (77.6% reduction,
approximately 4.46x).  Hextile reduced the raw-equivalent 37.7 MB to 9.39 MB,
but increased local p50 from 0.292 s to 0.447 s, so raw remains the lower
latency choice on the local WLAN:

- `stable-snapshot-hextile/results.json`
- `stable-snapshot-hextile/osxvnc-stat.log`

## 3. Menu tile corruption: disproved theories

The menu's square holes persisted in the stable mmap framebuffer, ruling out
RFB packet loss.  The native tile-pipeline call itself succeeded and returned
`AGXG13GFamilyTileRenderPipeline`; see
`menu-tile-descriptor/windowserver-tile.log`.

Seeding every owned display target with the previous complete frame also did
not change the holes.  It performed roughly 4,200 15.3-MiB copies in the short
test and made latency worse, so it was removed.  A read-only descriptor witness
then runtime-confirmed the real full-display pass uses `loadAction=2` (Clear)
and `storeAction=1` (Store), which explains why pre-seeding could not affect
the result:

- `render-boundary-seed/windowserver-seed.log`
- `render-boundary-seed/windowserver-render-pass-diag.log`
- `render-boundary-seed/results.json`

## 4. RE/runtime-confirmed root cause: equal-shape texture aliasing

The historical plain-texture compatibility allocator cached exactly one
IOSurface and one `MTLTexture` object per `(width,height,pixelFormat)` key.
Its source comment assumed that equal-shaped SkyLight intermediates were used
serially.  Menu/backdrop composition violates that assumption: multiple equal
shapes are live in one frame, so writers alias the same object.

Runtime A/B disabled the compatibility allocator in WindowServer and let the
real AGX device allocate ordinary textures.  WindowServer booted successfully,
and the same menu became spatially continuous after five seconds.  Compare:

- Broken pooled output: `steady-menu-no-seed/after-5s.png`
- Native WindowServer allocation: `native-plain-ab/menu-after-5s.png`
- Clean hover frames: `native-plain-ab/benchmark/hover-04.png` and
  `native-plain-ab/benchmark/hover-08.png`
- Clean context menu: `native-plain-ab/benchmark/context-menu.png`

The production policy is intentionally process-specific.  WindowServer and
ordinary GUI main processes use native AGX texture lifetime.  Chromium/ANGLE
Helper, Renderer, and GPU subprocesses temporarily retain the compatibility
allocator: the global-native control run reached
`AGXTexture init`, rejected a 128x16 R8 texture's cross-image init args, and
then reported `SharedContextState context lost via Skia OOM`; see
`native-plain-ab/vscode-global-native-failure.log`.  Treating the WindowServer
result as globally valid would therefore regress VS Code.  Keeping the main
Electron process on the compatibility allocator was also wrong: its AppKit
menu used concurrent equal-shape textures and showed two isolated blue tiles
instead of a complete hover row.  The final boundary follows actual process
ownership: Electron's main GUI process is native, while `Code Helper` /
`Code Helper (Renderer)` remain on the compatibility allocator.

The final VS Code regression witnesses are under
`gui-native-helper-compat/`:

- `vscode-file-open.png` contains a spatially complete File menu.
- `benchmark2/hover-01.png` contains one complete blue hover row.
- `benchmark2/context-menu.png` contains the complete editor-tab right-click
  menu.
- `benchmark2/title-drag.png` shows the application window in its new position
  after a button-held VNC pointer trajectory.
- `benchmark2-result.json` records 6/6 operations passing, p50 0.504 s and max
  1.169 s.

The exact runtime input witness for that run included left click, hover, right
click and held-button motion in the original Quartz path:

```text
#### OSXVNC NATIVE-ALL event=1 buttons=0x1 rfb=(235.0,20.0) quartz=(117.5,10.0) scale=2
#### OSXVNC NATIVE-ALL event=5 buttons=0 rfb=(260.0,85.0) quartz=(130.0,42.5) scale=2
#### OSXVNC NATIVE-ALL event=6 buttons=0x4 rfb=(1050.0,125.0) quartz=(525.0,62.5) scale=2
#### OSXVNC NATIVE-ALL event=8 buttons=0x1 rfb=(1900.0,75.0) quartz=(950.0,37.5) scale=2
#### OSXVNC NATIVE-ALL event=20 buttons=0x1 rfb=(2050.0,175.0) quartz=(1025.0,87.5) scale=2
#### OSXVNC NATIVE-ALL event=21 buttons=0 rfb=(2050.0,175.0) quartz=(1025.0,87.5) scale=2
```

After two minutes the same Electron main process and its original GPU process
were still alive.  The post-start log interval contained no
`AGX_INITARGS FAIL`, `Skia OOM`, `GPU process exited`, or Metal assertion.

## 5. Stability and remaining latency

Three complete production-policy stress rounds passed 39/39 actions.  Their
p50 values were 0.232 s, 0.390 s, and 0.253 s:

- `native-plain-production-stress/results-1.json`
- `native-plain-production-stress/results-2.json`
- `native-plain-production-stress/results-3.json`

A fourth round missed one menu hover after several 1–2 second tail events.
The event had already entered OSXvnc's original system path in under a
millisecond, so the remaining tail is downstream of socket parsing.  It still
needs to be split between WindowServer frame production and mmap dirty-region
publication before being called fixed.

The native-allocation A/B is not a general performance fix.  A later live
sample still showed WindowServer at 54.5% CPU and 290,352 KiB RSS.  Its trace
also contained repeated ordinary-texture `AGX_INITARGS FAIL` results.  The
clean menus establish the equal-shape-alias diagnosis, but a lifetime-aware
multi-entry compatibility pool is still preferable to routing every ordinary
WindowServer texture through the failing native initializer.  That follow-up
belongs to the remaining smoothness/stability milestone.

VS Code starts and its main window renders with the process-specific policy;
`gui-native-helper-compat/vscode-before-file.png` is the final-policy witness.
The Apple iPad page later triggers a separate, exact Metal validation failure:
an IOSurface-backed texture is created with `mipmapLevelCount=12`, which Metal
forbids.  That video/webview issue is deliberately left after the current
system-input and WebGL/JIT work, matching the requested priority order.

## 6. Service lifecycle fixes included in this milestone

- `pboard` is a real launchd job and the named-profile `sandbox_init` call is
  interposed for the chroot.  This removes the inaccessible-pasteboard state
  that previously caused Electron drag setup to throw.
- The watchdog has one PID-owned instance and no default 300-second kill cap.
- OSXvnc's `MACWS_VNC_NATIVE_ALL=1` setting is emitted by the generated launchd
  plist, so reboot/startup does not depend on a leftover `/tmp` sentinel.
