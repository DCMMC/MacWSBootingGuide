# macPad window interaction regression witness (2026-09-08)

Device: iPad13,6, iPadOS 16.3.1, macOS 13.4 userland. No IPSW was
downloaded, extracted, or scanned during this work.

## Native AppKit scroll crash and causal boundary

The device crash report
`/var/mobile/Library/Logs/CrashReporter/Finder-2026-09-08-113319.ips`
records an application-triggered abort from the Host-produced phased wheel
event, not an out-of-memory kill:

```text
EXC_CRASH SIGABRT Application Triggered Fault
__abort_with_payload
_os_crash_msg
__NSScrollingConcurrentVBLMonitorGetWorkIntervalHandle_block_invoke +248
_dispatch_once
-[_NSScrollingConcurrentVBLMonitor resume] +1656
-[NSScrollingBehaviorConcurrentVBL _startGestureScrollWithVBLFilter:] +524
-[NSScrollingBehaviorConcurrentVBL _scrollView:trackGestureScrollWithEvent:] +896
-[NSScrollingBehaviorConcurrentVBL scrollView:scrollWheelWithEvent:] +512
-[NSCollectionView scrollWheel:]
-[NSWindow _reallySendEvent:isDelayedEvent:]
-[NSWindow sendEvent:]
MacWSPostInputOnMainThread AppInputBridge.m:7611
```

This runtime-confirms that a process-local wheel event carrying trackpad
gesture phases selects AppKit's concurrent-VBL monitor, whose work-interval
setup aborts in this chroot. The repair is upstream routing, not an abort or
assert bypass:

- native AppKit/SwiftUI content uses the CGS-connected
  `CGPostScrollWheelEvent` path when WindowServer's independent hit test
  identifies the exact requested window;
- Catalyst and Electron retain their process-local pixel/phase path;
- a covered native AppKit window retains pixel deltas but clears only the
  unavailable gesture/momentum phase fields in its process-local fallback.
  The Host remains the producer of the complete finger and momentum delta
  stream.

The foreground Finder probe hit its real icon view and selected the native
system route:

```text
APP-INPUT SCROLL-CAPABILITY pid=64878 window=430 window-class=NSKVONotifying_TBrowserWindow hit-class=NSKVONotifying_TIconCollectionView route=CGPostScrollWheelEvent matched-class=none matched-image=none boundary=AppKit ancestry-scanned=14
APP-INPUT SYSTEM-SCROLL pid=64878 window=430 pixel=(0.000,-8.000) wheel=(0,-1) residual=(0.000,-6.000) phase=0x200 unit-pixels=10.0 boundary=AppKit result=0 route=CGPostScrollWheelEvent
```

The same Finder window was then deliberately covered by Activity Monitor.
WindowServer no longer matched the requested Finder surface, so the bounded
local fallback was exercised:

```text
APP-INPUT SCROLL-DISPATCH pid=60587 target-window=390 event-window=390 local=(500.00,289.00) delta=(0.00,-8.00) route=NSWindow.sendEvent-discrete-fallback
```

Finder remained alive in both cases and no Finder report newer than
11:33 appeared. Fresh RFB captures visibly showed the Applications/root icon
rows move. The retained capture hashes are:

```text
5536fd35ae217b45358c8f625680788823fd7cf47437674a5a1234093d1d4bce  finder-after-app-click.png
8ba2a305f37e59287cb05a1db9cb8fc765420d82a85ad40c8e2926843f4ea159  finder-applications-after-host-scroll.png
c349a430b058ec274548623c0e8f83189373dff13f5314d4e6dab276eb8b15d3  finder-after-covered-scroll.png
de5ec0cb542668cebe8b907f08a8d4067d41ac0a688082a3b56a8890c56eb2ec  finder-root-after-final-scroll.png
```

The Finder A/B also measured the receiving AppKit wheel unit at roughly
7-10 visible pixels. Native AppKit therefore uses a 10-pixel accumulator;
SwiftUI retains its separately runtime-measured 40-pixel unit. This avoids the
previous five-sample startup delay without making System Settings jump several
rows per sample.

## Modal, Quick Look, popup bounds, and Preview witnesses

The Activity Monitor terminate confirmation and Sublime unsaved-document
confirmation were each dismissed through the production Host input socket,
addressed to the presenting base window. `AppInputBridge` resolved their real
AppKit `sheetParent`/`parentWindow` chain and routed the click to the transient
window; neither test used RFB for the confirming click.

Finder received Space through the Host key protocol while `IMG_0120.png` was
selected. The native Quick Look card appeared with the real image and metadata,
and its complete frame stayed within the presenting Finder frame. The same
Space route closed it. This validates both the QuickLookUI service carrier and
the transient-window constraint policy.

Preview displayed both `IMG_0120.png` and a readable CS336 PDF with real image
and page pixels. The ImageKit fix preserves `IOSurfaceCreate`'s dictionary
contract and converts only finite, positive, integral floating dimensions to
the SInt64 representation required by iPadOS IOSurface; it does not fabricate a
surface or skip validation.

A 50-page PDF can still spend substantial transient CPU time in the stock
software OpenGL ImageKit renderer while producing thumbnails. Sampling showed
the hot stack in `-[IKImageContentView updateContentForLayer:] -> [CIContext
render:toIOSurface:] -> CI::GLContext::render_root_node -> glDrawArrays`.
After the current PDF settled, Preview returned to 0.0% sampled CPU. This is a
remaining performance characteristic, not reported as fixed merely because
the process stayed alive.

## Fullscreen Mission Control

The fullscreen path was tested end-to-end through the production protocols:
the Host's three-finger gesture opened Mission Control, then the root-only
localhost OSXvnc pointer proxy supplied the hardware-style long-press/drag.
Finder visibly moved from desktop 1 to desktop 2. The fallback is unavailable
unless the exact local proxy socket exists; no semantic “move window” command
is substituted for the native Mission Control interaction.
