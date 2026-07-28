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

The native-allocation A/B was not a general performance fix.  A later live
sample still showed WindowServer at 54.5% CPU and 290,352 KiB RSS, and its
trace contained repeated ordinary-texture `AGX_INITARGS FAIL` results.  The
follow-up therefore implemented a lifetime-aware multi-entry compatibility
pool instead of routing every ordinary WindowServer texture through that
failing native initializer.  Runtime recorded five 2388x1668 owned targets
serving at least 39,600 reuse hits, with a bounded live WindowServer sample at
214,240 KiB RSS.  The ownership invariant, exact log lines and limitations are
recorded in `owned-lease-pool/README.md`; this is not yet a long-soak leak
proof.

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

## 7. System input is not complete until its WindowServer frame is published

A later retained-client test corrected an overclaim in the original
changed-region benchmark.  A system event could be accepted while the first
RFB update contained only cursor/window-control feedback.  The actual menu
composite arrived on the following pointer request.  Thus an arbitrary region
digest change was not by itself a semantic menu-success witness.

The boundary was runtime-confirmed in current VS Code.  The original
system-wide path delivered a real secondary-button pair to AppKit:

```text
#### APP-INPUT MOUSE-EVENT pid=67206 serial=2 type=3 window=25 local=(500.00,475.00) pressed=0x2 at=317301.413506
#### APP-INPUT MOUSE-EVENT pid=67206 serial=3 type=4 window=25 local=(500.00,475.00) pressed=0 at=317301.492351
```

For a menu-bar click, the old native-all early return skipped the pointer
capture request.  After closing that gap, the event, two real observation
requests, stable mmap publication and WindowServer acknowledgements were all
visible in one run:

```text
#### OSXVNC NATIVE-ALL event=1 buttons=0x1 rfb=(235.0,20.0) quartz=(117.5,10.0) scale=2
#### OSXVNC POINTER-PROGRESS-CAPTURE serial=1 detail=0x1 generation=1785279999829998000
#### OSXVNC NATIVE-ALL event=2 buttons=0 rfb=(235.0,20.0) quartz=(117.5,10.0) scale=2
#### OSXVNC POINTER-PROGRESS-CAPTURE serial=2 detail=0 generation=1785279999880159000
#### OSXVNC mmap generation #3 sequence=808 changed=YES dirty=147,0 626x1084 rects=17 overflow=NO
#### OSXVNC POINTER-SETTLED-CAPTURE serial=2 detail=0 generation=1785280000030095000
#### VNC-FINAL acknowledged pid=65992 generation=1785279999829998000
#### VNC-FINAL acknowledged pid=65992 generation=1785279999880159000
#### VNC-FINAL acknowledged pid=65992 generation=1785280000030095000
```

The test client now obtains a non-incremental post-Escape baseline and retains
post-action incremental frames for a bounded settle interval.  A real Terminal
menu run completed open, four hover transitions and close, 6/6, with each blue
hover state present in the retained framebuffer:

- `system-input-publish-fix-b/terminal-menu/results.json`
- `system-input-publish-fix-b/terminal-menu/01-menu-open.png`
- `system-input-publish-fix-b/terminal-menu/hover-04.png`

## 8. Secondary-button release serialization

The stricter framebuffer test then exposed an independent right-click race.
In a failed Terminal sample, both `rightMouseDown` and `rightMouseUp` returned
through ordinary `-[NSApplication sendEvent:]`; in successful samples, the
down entered NSMenu's nested tracker and that tracker consumed the up.  The
RFB transport now keeps OSXvnc's original system `CGPostMouseEvent` owner but
delays only the secondary-button release by 120 ms, allowing the down to
establish the real AppKit tracker.  No menu action, selector return value, or
window state is synthesized.

Runtime witness:

```text
#### OSXVNC NATIVE-ALL event=1 buttons=0x4 rfb=(1000.0,700.0) quartz=(500.0,350.0) scale=2
#### OSXVNC RIGHT-UP-SERIALIZE event=1 delay=120ms rfb=(1000.0,700.0)
#### OSXVNC NATIVE-ALL event=2 buttons=0 rfb=(1000.0,700.0) quartz=(500.0,350.0) scale=2
#### APP-INPUT MOUSE-EVENT pid=69267 serial=12 type=3 window=29 local=(419.00,356.00) pressed=0x2 at=318001.959555
```

Five isolated right-click/open/close rounds retained five visibly complete
Terminal contextual menus.  Open latency ranged from 0.290 to 1.021 seconds;
the remaining long tail is a real smoothness problem, so this is a stability
milestone rather than a claim of final responsiveness:

- `system-input-publish-fix-b/right-serialized-1/results.json`
- `system-input-publish-fix-b/right-serialized-1/context-menu.png`
- `system-input-publish-fix-b/right-serialized-2/results.json`
- `system-input-publish-fix-b/right-serialized-3/results.json`
- `system-input-publish-fix-b/right-serialized-4/results.json`
- `system-input-publish-fix-b/right-serialized-5/results.json`
- `system-input-publish-fix-b/right-serialized-5/context-menu.png`

The same installed hook was then tested against a freshly restarted official
VS Code 1.130.0 workbench, rather than a stale full-screen benchmark target.
Its real macOS File menu completed open/hover/close 3/3 with 0.564/0.308/0.251
second first-change latencies.  A secondary click on the editor tab produced
the complete Electron contextual menu in 0.303 seconds and closed in 0.626
seconds.  The screenshots—not merely the changed-region counters—were
inspected for the expected menu contents:

- `system-input-publish-fix-b/vscode-menu-live/results.json`
- `system-input-publish-fix-b/vscode-menu-live/01-menu-open.png`
- `system-input-publish-fix-b/vscode-menu-live/hover-01.png`
- `system-input-publish-fix-b/vscode-context-live/results.json`
- `system-input-publish-fix-b/vscode-context-live/context-menu.png`

After rebuilding and restarting OSXvnc with the final atomic button-state
update, the same VS Code contextual-menu operation remained visually complete
but took 1.037 seconds to open and 1.036 seconds to close.  This repeat is the
current deployed-binary witness and also demonstrates that the long-tail
latency is still unresolved:

- `system-input-publish-fix-b/vscode-context-final/results.json`
- `system-input-publish-fix-b/vscode-context-final/context-menu.png`

This also fixes the terminology boundary: per-process `AppInputBridge` remains
appropriate for the iPad-native host and targeted AppKit content.  VNC menu
bar, contextual-menu and cross-process window input must remain one coherent
system event stream; broadcasting private NSEvents to every process would
duplicate gestures and cannot represent WindowServer-owned UI.
