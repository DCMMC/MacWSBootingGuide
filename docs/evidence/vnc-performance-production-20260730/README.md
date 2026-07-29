# Production VNC latency and context-menu evidence (2026-07-30)

This evidence set measures the Retina `2388x1668` VNC path after moving
high-frequency AppInputBridge and RFB observation logs behind the audited
runtime-diagnostics switch.  The benchmark masks cursor-only changes and
requires at least 1024 changed pixels before an operation can pass.

## Production hot-path logging

Runtime-confirmed: a production start produced a 33-line, 2930-byte VNC log.
The high-frequency diagnostic-pattern count was zero before the benchmark and
remained zero after the complete menu, hover, context-click, and drag sequence.
The combined production logs grew from 68 to 85 lines during the sequence, but
none matched the audited AppInput/RFB hot-path diagnostic patterns.  Errors and
event drops remain logged.

## Quiet production result

Source: [`quiet-production-round1/results.json`](quiet-production-round1/results.json).

| Operation | Result | First valid visible update |
|---|---:|---:|
| menu open | pass | 318 ms |
| menu hover 1 | pass | 164 ms |
| menu hover 2 | pass | 153 ms |
| menu hover 3 | pass | 183 ms |
| menu close | pass | 212 ms |
| context menu | **miss** | only 852 changed pixels |
| context close | **miss** | only 852 changed pixels |
| title drag | pass | 315 ms |

Six of eight operations passed.  The passing-operation median was 183 ms and
the maximum was 318 ms.  This older run returned after the first digest change
and applied the 1024-pixel validity threshold only after a fixed settle window;
it is retained as regression evidence but is superseded for latency by the
threshold-aware measurements below.

The diagnostics-enabled control run in
[`diagnostic-route/results.json`](diagnostic-route/results.json) passed seven
of eight operations: menu open 322 ms, hover 180/146/172 ms, close 215 ms,
context menu miss, context close 151 ms, and title drag 308 ms.  Its median was
180 ms.  A single round is insufficient to attribute the small difference to
logging, so no performance causality is claimed from this comparison.

## Context-menu failure

Runtime-confirmed via the Terminal/AppInput log: the secondary click reached
the expected window and local coordinate; `rightMouseDown:` then remained
blocked until the benchmark sent Escape approximately 1.9 seconds later.

```text
APP-INPUT MOUSE-EVENT pid=8598 serial=2 type=3 window=7 local=(27.00,232.00) pressed=0x2
APP-INPUT SECONDARY-HOVER-AB pid=8598 serial=2 window=7 delay=80ms
APP-INPUT LIVE-POST pid=8598 serial=2 kind=10 window=7 source=active-window
APP-INPUT KEY-MENU-CANCEL pid=8598 serial=3 source=secondary-tracker route=hitoolbox-active-tracker
APP-INPUT MOUSE-RETURN pid=8598 serial=2 type=3 window=7 elapsed=1900.005ms
```

The benchmark's incremental framebuffer capture requests were acknowledged,
but no contextual-menu pixels appeared before its timeout.

An iOS-local LLDB capture subsequently resolved the blocked main thread as
`rightMouseDown:` -> `_showMenuForEvent:` ->
`NSCarbonMenuImpl _popUpContextMenu` -> `SLMPerformPopUpCarbonMenu` ->
`TrackMenuCommon` -> `_NSHLTBMenuEventProc`.  See
[`context-menu-lldb-stack.txt`](context-menu-lldb-stack.txt).  A full RFB
capture taken while that exact stack was stopped,
[`context-menu-lldb-active.png`](context-menu-lldb-active.png), visibly
contains Terminal's native contextual menu.  This runtime-confirms that the
menu is created and composited eventually; the remaining failure is delayed
publication and/or missing incremental damage before the benchmark timeout.

The `context-delayed-hover-ab` run tested an 80 ms same-position `mouseMoved`
event after the secondary click.  The log above runtime-confirms delivery, but
[`context-delayed-hover-ab/results.json`](context-delayed-hover-ab/results.json)
still recorded a context-menu miss with only 676 changed pixels.  That A/B
patch was therefore rejected and removed from production.

Earlier benchmark folders that labelled context-clicks as passes are not valid
context-menu evidence: their saved screenshots contain no menu, and the older
acceptance rule allowed cursor/focus changes.  The hardened 1024-pixel rule
correctly rejects the 544-852-pixel false positives in the current runs.

## Threshold-aware timing correction

The first hardened implementation still compared every pixel in a large ROI
in Python before requesting the next RFB update.  A synthetic 1200x1100 test
measured approximately 1.2 seconds of local comparison work, which was being
charged to the iPad.  `vnc_usability_benchmark.py` now skips equal row spans in
C and stops as soon as the validity threshold is reached.  The same synthetic
threshold check now takes approximately 0.8 ms; an exact final count takes
approximately 45 ms and runs outside the measured first-valid-frame path.

Runtime-confirmed by
[`context-fast-threshold/results.json`](context-fast-threshold/results.json):
with the corrected timer, the native context menu appeared after 324 ms and
closed after 156 ms.  AppInput diagnostics placed Terminal's `rightMouseDown:`
34 ms after OSXvnc entered the secondary-button handler, while RFB decoding
took 15 ms.  The remaining latency is predominantly between AppKit menu entry
and publication of a valid composed frame, not input transport, encoding, or
the benchmark's pixel loop.

The secondary-menu observation pair was moved from 180/360 ms to 120/240 ms
without changing any event or accepting a fabricated frame.  Six production
runs recorded menu-open latencies of 712, 330, 268, 129, 95, and 377 ms.  The
large range means this A/B is not yet a complete latency fix; its conventional
median is 299 ms versus the one corrected 324-ms old-cadence run.

The complete threshold-aware production run in
[`full-threshold-aware-production/results.json`](full-threshold-aware-production/results.json)
validated seven of eight operations: menu open 383 ms, hover 207/250/181 ms,
menu close 157 ms, context open 351 ms, and context close 256 ms.  The title
drag used a stale coordinate outside the current title bar and is not a drag
regression witness.  A separate coordinate attempt changed only 6330 pixels
and screenshots showed the window had not moved, so it is also not claimed as
a pass.  Title-drag targeting remains open.

## Current conclusion

- Runtime-confirmed: production diagnostics are quiet on the measured input
  and RFB hot paths.
- Runtime-confirmed: menu interaction renders at roughly 157-383 ms response
  latency in the corrected full run; title dragging still needs a valid
  current-frame target before it can be re-qualified.
- Runtime-confirmed: right-click reaches Terminal, enters AppKit's native
  Carbon menu tracker, and the menu is visible in a later full RFB capture.
- THEORY: the observed interactive failure is now in the VNC publication or
  incremental-damage path.  A clean full-vs-incremental timing run is the next
  discriminator; no event-delay workaround is retained.
