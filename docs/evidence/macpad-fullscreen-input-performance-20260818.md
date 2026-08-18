# macPad crash, fullscreen, and input-performance witness (2026-08-18)

## Scope

This milestone repairs the macPad Host crash that occurred when the first
display frame arrived, validates the installed production package in the
native iPadOS fullscreen workspace, and removes a coarse scroll bottleneck
without changing native gesture semantics.  The validation used the iPad at
`192.168.1.6`; it did not reboot or respring the device.

## Host crash: root cause and production invariant

The device crash report
`/private/var/mobile/Library/Logs/CrashReporter/MacWSHost-2026-08-18-130507.ips`
records an Objective-C forwarding failure on the main queue:

```text
"exception" : {"type":"EXC_CRASH","signal":"SIGABRT"}
"asi" : {"libsystem_c.dylib":["abort() called"]}
-[UIResponder doesNotRecognizeSelector:]
-[MacWSViewController applyStatus:] main.m:3582
```

RE-confirmed from the pre-rebuild Host binary: the `applyStatus:` call site
sent `hasFinalCompositeFrame`, while that binary's Objective-C method table did
not contain `-[MacWSMetalView hasFinalCompositeFrame]`.  The source did contain
the implementation.  Theos had resumed from stale on-device Host objects after
source synchronization preserved older mtimes, producing a mixed
translation-unit Objective-C ABI.  This was not a display-service crash and
was not fixed by suppressing the unrecognized selector.

`misc/build_on_ios.sh` now refreshes every macPad source/header mtime for a
normal production package build and refuses to package unless `nm` finds all
four cross-translation-unit selectors:

```text
-[MacWSMetalView hasDirectSurfaceFrame]
-[MacWSMetalView hasFinalCompositeFrame]
-[MacWSMetalView configureStreamMode:windowID:]
-[MacWSViewController applyStatus:]
```

The clean production build emitted:

```text
==> Host ABI invariant: refreshed all macPad source/header mtimes
==> Host ABI invariant: packaged selector contract verified
```

The installed binary contains all four methods.  After installation macPad
remained alive for more than five minutes at 0.0% sampled CPU and no crash newer
than 13:05 appeared.  No restart or respring was used.

## Fullscreen production witness

The installed Host produced these runtime lines after entering the workspace:

```text
immersive-postcondition expected=YES status-request=YES status-hidden=YES home-indicator-auto-hide=YES deferred-edges=15 bounds={{0, 0}, {1389, 970}} screen={{0, 0}, {1389, 970}} safe-insets={0, 0, 20, 0}
runtime-confirmed native Metal present scene=90c4c2be457e90de frame=2388x1668 backing=2.000 drawable=2388x1668 content=(0.00,0.00 1389.00x970.00) density=1.16 source=IOSurface status=4 error=nil
```

This runtime-confirms all of the following for the production binary:

- the scene bounds equal the full 1389x970 iPad screen;
- the iOS status bar is hidden and Home Indicator auto-hide is requested;
- native Metal presents the complete 2388x1668 Retina IOSurface without a
  content crop or scale offset.

The corresponding Host-composited and base-frame captures were 2778x1940 and
2388x1668.  Their SHA-256 hashes are:

```text
7c3466e2c7c33684211dd3fd867104ccd2d6fac653feec4cda80b2fe09a2269a  MacWSHost-ui.png
d3b113083f98c4316fc7b1598e855926798a4a7eaa5bc0060d9c8f36f64c2897  MacWSHost-base.png
```

## Precise scrolling at the correct framework boundary

Runtime InputLab evidence showed that the previous system route accumulated
pixel deltas and divided by 40 before calling `CGPostScrollWheelEvent`.  Small
touch deltas were therefore accepted by the bridge but truncated before the
target responder could see them.  A blanket local `NSWindow sendEvent:` route
fixed AppKit/Electron, but System Settings' SwiftUI hosting boundary received
those events without producing new content frames.

The production route is now selected from the actual target window's view
class ancestry, cached per real `NSWindow`:

```text
APP-INPUT SCROLL-CAPABILITY ... route=NSWindow.sendEvent matched-class=none views-scanned=18
APP-INPUT SCROLL-CAPABILITY ... window-class=NSKVONotifying_SwiftUI.AppKitWindow route=CGPostScrollWheelEvent matched-class=_TtGC7SwiftUI13NSHostingView... matched-image=/System/Library/Frameworks/SwiftUI.framework/...
```

This is a framework-capability check, not an app-name allowlist.  Ordinary
AppKit/Electron windows preserve precise pixel deltas plus native scroll and
momentum phases.  SwiftUI windows retain the CGS-connected system route that
runtime evidence proves they require.

System Settings' targeted scroll profile passed with 70.99 visible FPS,
47.98 one-percent-low FPS, and no frame stall over 50 ms.

## Real-app gesture performance

The full regression used the production `MacWSInputRecord-v4` path (no RFB)
against a real chroot application.  Its semantic matrix passed left/right
click, drag, phased scroll `[1, 4 x 8, 8]`, momentum, magnify, and keyboard
modifiers.  Delivery results were:

| Input stream | Records | Delivered | Effective rate | p95 bridge latency |
|---|---:|---:|---:|---:|
| 60 Hz drag | 300 | 299 | 59.76 Hz | 1.99 ms |
| 120 Hz drag | 600 | 540 | 107.96 Hz | 4.52 ms |

Visible final-composite cadence:

| Scenario | Average FPS | 1% low FPS | Result |
|---|---:|---:|---|
| Hover | 87.01 | 47.98 | PASS |
| Drag | 85.91 | 47.98 | PASS |
| Long-press drag | 88.49 | 47.98 | PASS |
| Scroll | 90.37 | 47.98 | PASS |
| Momentum scroll | 90.90 | 47.98 | PASS |
| Magnify | 87.31 | 47.98 | PASS |
| Three-finger up | 105.63 | 47.98 | PASS |
| Three-finger down | 103.47 | 47.98 | PASS |
| Three-finger left | 93.60 | 39.98 | FAIL (isolated long frame) |
| Three-finger right | 89.05 | 47.97 | PASS |
| Mission Control selection | 98.14 | 29.99 | FAIL (isolated long frame) |

The suite remains honestly `FAIL`: tap main-thread dispatch p95 was 18.5 ms
against the 16.7 ms target, and the two native Dock/Mission Control animations
still contain isolated long frames.  GPU execution p95 was approximately 1 ms,
so those outliers are not evidence of an AGX execution bottleneck.  The
follow-up Mission Control run did successfully select the native window and
passed the selection-latency gate, but still recorded one 58.36 ms compositor
stall.  Thresholds were not relaxed.

Raw JSON witness hashes:

```text
4dddc3debb8285d74d049fe7d487e4f7bf4ce7866196aee941ae0992e5cef60f  macpad-ui-profile-optimized-20260818.json
6ff10a9f1b5672a84e76dfa9e723e3d637bea236040c2f56e27275652e0a83ba  macpad-ui-profile-targeted-20260818.json
02665885ed730e1b0517e876ecb65076f910c084edc7f0473473dd46bd4bb3e6  settings-capability-scroll-20260818.json
```

## Stray optimization boundary

The accepted native-AGX gameplay baseline remains the separately documented
1194x834 run at 11.01 active FPS.  Three bounded graphics-setting experiments
were rejected rather than promoted as improvements:

- MetalFX at 50% reached
  `GPUANERegionOps.mm:419: failed assertion 'ANE compilation failed!'` and
  generated `Stray-Mac-Shipping-2026-08-18-150507.ips`;
- built-in scaling at 50% produced an exact Stray window with black content;
- built-in 100% with low effects/shadows also produced black content.

The original user configuration was restored byte-for-byte and Stray was
stopped.  `misc/stray_first_run_pipeline.py` now activates the exact catalogued
PID/window through macPad's existing scene URL before taking evidence.  In a
fullscreen workspace this selects the game in place and prevents VNC from
silently measuring a previously focused Terminal window.

The requested MacGamerHQ reference describes Stray as native Apple Silicon,
MetalFX-capable, and requiring macOS 12, Apple M1, and 8.2 GB storage:
<https://www.macgamerhq.com/games/stray-mac/>.  That page does not publish an
exact M1 MacBook Air FPS row, so it is used as a compatibility/configuration
reference, not as an invented numerical target.  The measured 11.01 FPS above
is therefore retained as the only valid device-side game baseline.

The installed production artifacts are bound by:

```text
e9d21fde392a2595a177574faac412d55954424d584aad9bd36301997ccc4d8e  MacWSHost
9508efbd73b1b7ec38865a826958336deec688b17852f5a650a7d971d57feb15  libmachook.dylib
6860434501750b51b8d865b4e4fd180094f66936538b4a00cf2b930000393e16  com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb
```

The five-minute device watchdog's latest sample after testing was nominal at
35.69 C.  Its policy remains unchanged: sample every five minutes and
intervene only at `Critical`.
