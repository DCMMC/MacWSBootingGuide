# WindowServer final-composite presentation (2026-08-12)

## Outcome

The fullscreen MacWS Host now presents WindowServer's completed native-AGX
BGRA scanout directly as an IOSurface-backed Metal texture. This fixes three
apparently separate visual regressions at their common source boundary:

- native shadows outside an application's exact window bounds;
- Dock and system-menu backdrop blur/material sampling;
- the warped intermediate frames of the native Genie minimize animation.

Exact-window streams remain authoritative for window identity, geometry and
input hit testing. When a frame carries `MacWSStreamFrameFinalComposite`, Host
does not paint those exact layers a second time over the final pixels.

## Root cause and evidence boundary

The old fullscreen renderer reconstructed the desktop from exact
`SLSHWCaptureStreamCreateWithWindow` surfaces. An exact surface ends at the
window boundary, so it structurally cannot contain an external shadow. A
backdrop material also needs the compositor's already-resolved pixels behind
the layer, and a Genie frame is a compositor-created warped shape rather than
an ordinary rectangular NSWindow backing. Adding more per-window ordering or
Host-side blur would therefore only approximate the missing result.

RE-confirmed via the installed OSXvnc binary: `_rfbGetFramebuffer` reaches
`CGDisplayCreateImage`, and its rectangle variant reaches
`CGDisplayCreateImageForRect`. Runtime-confirmed via VNC captures: the same
desktop already contained the external Terminal shadow, translucent Dock and
Genie warp while the old Host reconstruction did not. Runtime-confirmed via
`libmachook/Metal_hooks.x`: the completed owned linear BGRA scanout is the
surface whose CPU mapping feeds `/tmp/macws_vnc_fb`. The correct upstream fix
is to transfer that completed surface, not recreate its effects downstream.

## Transport and trust boundary

`macws_final_composite_protocol.h` defines a fixed 56-byte `MWFC` v1 record and
the `com.macwsguide.display.final-composite` Mach service. WindowServer sends a
copy-send right for the IOSurface only after its real producer command buffer
reports `MTLCommandBufferStatusCompleted` with no error. Publication uses a
serial one-deep latest-state observer so the Host path is not queued behind
VNC's 15.2-MiB CPU compare/copy.

`macwsdisplayd` checks all of the following before accepting the surface:

- the Mach message shape, complex descriptor count and record ABI;
- audit-trailer PID equality with the record PID;
- `proc_pidpath(senderPID)` matching exactly either the public
  `.../SkyLight.framework/Resources/WindowServer` path or its live Ventura
  `.../SkyLight.framework/Versions/A/Resources/WindowServer` path;
- monotonic sequence per producer PID;
- IOSurface ID, dimensions, row bytes, BGRA fourCC and Metal pixel format.

The accepted surface is republished through the existing bounded XPC lease
protocol as a fullscreen base with `MacWSStreamFrameFinalComposite`. A protocol
v7 Host rejects impossible final/overlay combinations and final frames with a
nonzero application window ID.

The producer currently reuses the same SkyLight-owned display target across
many completed frames. Producer completion is the runtime-proven coherence
boundary. A retain/use-count would not prevent WindowServer from submitting a
later write and must not be presented as synchronization. If a future soak
finds tearing, the root strengthening is an AGX-timeline snapshot ring or a
real cross-process GPU fence, not a reference-count check.

## Runtime evidence on iPad13,6

The production stack ran with WindowServer `67259`, displayd `68105`, Host
`71171`, Dock `67689`, and Terminal `67740`. The first strict identity check
rejected the otherwise valid message and printed the actual versioned path:

```text
final-composite-rejected stage=identity record=valid record-pid=67259 sender-pid=67259 pid-match=YES producer=NO path=/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer sequence=1 surface=34
```

After correcting that exact identity invariant, the receiver recorded:

```text
MACWS-DISPLAY final-composite-received producer=67259 sequence=982 surface=34 size=2388x1668 bpr=9600 subscribers=0
MACWS-DISPLAY workspace-start ... transport=final-composite-iosurface
```

Host then connected its fullscreen stream and advanced the same surface from
base sequence 247 through 4234 during the visual tests. A real Shift-click on
Terminal's yellow traffic light invoked macOS's slow native Genie animation;
the Host capture `/tmp/macws-slow-genie-mid.png` contains its visibly warped
intermediate frame. The final minimized Dock thumbnail and restored Terminal
were captured separately. Host and VNC captures showed the same native shadow
and Dock material before/after the transition. No native effect was
synthesized in UIKit or a Host shader.

A continuous real-application soak ran momentum scroll, a 120-Hz long drag,
three-finger up and three-finger down. Its exported profile
`profile-20260812-044233.json` recorded:

```text
inputs attempted/sent       661 / 661
content frames received     1622
frames presented            806
final base sequence         6504
visible active average      82.936 FPS
visible p50 / p95 / p99     8.339 / 20.842 / 20.842 ms
visible 1% low              47.980 FPS
hitches / >50 ms stalls     3 / 0
GPU execution p95           0.863 ms
capture-to-Host p95         2.565 ms
Metal command errors        0
thermal state               nominal (37.00 C after soak)
```

An earlier Terminal-only tap/scroll/drag run recorded 503/503 input records,
75.03 visible FPS, 47.98 FPS 1% low, 0 hitches, 0 Metal errors, 0.793 ms GPU
p95 and 0.989 ms capture-to-Host p95. These results demonstrate visible frames
and completed input work; process uptime alone is not used as the witness.

The profiler now exports `presentation_transport.final_composite_active` plus
the base stream, sequence and IOSurface ID. In this mode, visible cadence and
input latency are correlated against the WindowServer-owned final base; the
per-window source is retained only as a diagnostic. A post-fix real Terminal
run reported final surface 34, drag at 79.97 FPS, scroll/momentum/magnify at
72.03–72.94 FPS, 47.98 FPS 1% low, zero hitches, zero >50-ms stalls, zero Metal
errors, passing input-to-visible gates, and nominal 35.79 °C. This avoids the
old false failure where a target exact-window stream was scored even though
its pixels were no longer painted by Host.

Finally, the clean-built production package was installed and its Host binary
matched SHA-256 `7117cc96ad720d025233f707b7bd588bb9e83edeaae0510f3c9a6a1386b8f6fd`
on the Mac and iPad. A package-binary-only rerun passed both scenarios: drag
83.23 FPS and scroll 72.21 FPS, each with about 47.98 FPS 1% low, passing
input-to-visible latency, zero hitches/stalls/Metal errors, and nominal
36.50 °C. WindowServer and the chroot desktop were not restarted for package
installation.

A controlled reload of only the installed display daemon then changed its PID
from `68105` to `91033` while WindowServer remained `67259`. The replacement
receiver immediately accepted surface 34 at producer sequence 25185 and
started the workspace with `transport=final-composite-iosurface`; Host advanced
the replacement base stream to sequence 874 on the same surface. This is the
runtime witness that the one-second bootstrap refresh recovers across a
receive-right replacement without a WindowServer or iOS restart.

## Remaining limits

- Fullscreen now uses the authoritative compositor pixels. Individual
  iPadOS window Scenes still use exact-window surfaces; their outer shadow is
  a Host SDF approximation because unrelated desktop pixels must not leak into
  a single-app Scene.
- The final path removes RFB encode/decode and the VNC CPU scan from Host
  latency, but it does not make a hardware-vblank claim. Idle 100-ms pacing is
  intentionally excluded from active-frame averages.
- Long-duration multi-Space, video and four-Scene pressure remain release
  gates even though this bounded gesture soak had stable PIDs and no command
  errors.
- A Catalyst child carried by MacWSHost is not part of SkyLight's client-area
  capture. Final-composite therefore preserves the native desktop and replaces
  only the focused Catalyst window rectangle with that child's authenticated,
  GPU-completed drawable. This exception is implemented by
  `Rendering/MacWSCatalystDrawableCompositor.*`; VNC still shows SkyLight's
  black client area and cannot validate this Host-only layer.

## 2026-08-13 coherence, cursor and menu follow-up

The producer reuse warning above became a real interactive defect: pointer,
blur and Dock activity let WindowServer begin a later write to the same final
IOSurface while Host still sampled it. Runtime diagnostics showed a fixed
surface before the repair and the sequence `160 -> 34 -> 20 -> 84` after it.
The final publisher now performs an ordered same-command-queue AGX blit into a
four-slot independent IOSurface snapshot ring. `macwsdisplayd` holds a
cross-process IOSurface use count for its current frame and each Host lease, so
the producer never reuses a consumer-owned slot. The explicit diagnostic
rollback is `MACWS_FINAL_COMPOSITE_DIRECT=1`; production leaves it absent and
uses the ring. The user then confirmed that the display flicker was gone.

A post-fix Excel hover profile recorded 70.45 active FPS, 16.67/20.84 ms
p50/p95 frame time, 39.98 FPS 1% low, 2.05% hitches, 41.05 ms
input-to-visible p95, 0.626 ms mean GPU execution and zero Metal command
errors. The evidence file is
`/var/mobile/Library/Logs/MacWSPerformance/profile-20260812-165153.json`.

The black pointer was present in `macwshost://screenshot-base`, proving that it
was already inside WindowServer's authoritative final composite rather than a
Host overlay. RE-confirmed via Ventura 13.4 SkyLight:

- `CGXHideCursor` is at image offset `0x1322b0` and updates the session hide
  count at `cursorState+0x78` before calling the native display cursor-hidden
  transaction;
- its global chain is SkyLight image `+0x53ae8460 -> +0x20 -> +0x108`;
- `CGXShowCursor` decrements the same count and shows the sprite only at the
  transition back to zero.

The first implementation called the correct function from the final-composite
worker and exposed a real thread invariant. Runtime-confirmed by
`WindowServer-2026-08-13-011147.ips` and `...-011209.ips`: both abort on
`com.macwsguide.vnc-completion-observer` at
`CGXHideCursor -> post_notification -> write_datagram`, whose exact assertion
was `pthread_main_np()`. The production implementation performs the complete
SkyLight mutation on WindowServer's main queue, reads the RE-confirmed native
hide count before scheduling and again before calling, and re-arms the check
afterward. It therefore repairs a later application `ShowCursor` transition
without inflating the balanced count every frame. A base screenshot after
Terminal launch, a context-menu hover and menu dismissal contained no native
arrow.

Menu hover keeps the global pointer position even though the sprite is hidden.
Runtime-confirmed on Terminal's native context menu: a Host hover queued to the
application main thread did not highlight Copy because Carbon
`TrackMenuCommon` already owned that thread. AppInputBridge now posts a real
button-free `CGPostMouseEvent` from the process socket thread; WindowServer
performs the native menu-window hit test and AppKit coordinates the selected
background and text appearance. The final base frame showed a blue `Mark`
selection with white text, followed by clean outside-click dismissal, while
WindowServer remained stable and the thermal state stayed nominal at 30.69 C.

## 2026-08-14 no-VNC production and scroll-unit regression

The final-composite producer used to share `/tmp/macws_vnc_share` as its
master enable predicate. `macos_gui.sh --no-vnc` correctly removed that RFB
sentinel, but accidentally disabled the native Host base at the same time and
fell back to per-window composition, losing SkyLight-only material/shadow
pixels. Production now owns two independent contracts:

- `/tmp/macws_final_composite` enables the authenticated WindowServer ->
  displayd -> Host IOSurface transport;
- `/tmp/macws_vnc_share` enables only the legacy RFB mmap/damage consumer.

Owned BGRA scanout and final snapshots remain enabled with or without a VNC
listener. In final-only mode the one-time scanout classifier remains, but the
per-frame CPU RFB comparison/mmap publication is skipped. Runtime after the
repair reported:

```text
MACWS-DISPLAY final-composite-received producer=61324 sequence=1 surface=25 size=2388x1668 bpr=9600 subscribers=1
presentation_transport: base_sequence=321 base_stream=1 base_surface=163 final_composite_active=true
```

A later production snapshot advanced that same authenticated base to sequence
19136 while `/tmp/macws_vnc_share` remained absent. The captured native Dock
context menu contained its translucent material and the desktop/Dock remained
visible through the final composite. No macOS arrow was present: each
successful final publication revalidates the balanced main-thread SkyLight
cursor-hide invariant, so a later application `ShowCursor` cannot leak a
duplicate sprite into Host.

The same regression pass found that one-finger VSCode scrolling had become
four times too fast. Source and runtime evidence identified two distinct APIs:

- the installed OSXvnc disassembly uses a pixel-unit
  `CGEventCreateScrollWheelEvent` followed by `CGEventPost`;
- `CGPostScrollWheelEvent` accepts small integral wheel movements, not pixel
  deltas (also stated by Apple's `CGRemoteOperation.h`).

Electron's process could call pixel `CGEventPost`, but its denied event-post
session silently delivered no Chromium wheel event. Passing every 10-point
UIKit sample to the legacy API did deliver, but a CDP observer measured six
samples as `scrollY 4000 -> 4240`: one remote unit expanded to 40 CSS pixels.
AppInputBridge now chooses by framework capability rather than application ID.
`ElectronNSWindow` uses the process-local precise NSEvent path; windows that
require the WindowServer remote route use a 40-pixel calibrated accumulator
with sub-unit residual. The exact repeat produced six `deltaMode=0,
deltaY=10` Chromium events and `scrollY 4000 -> 4060`, preserving 1:1 finger
travel and the existing native scroll/momentum phases.
