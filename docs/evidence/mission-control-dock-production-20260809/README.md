# Native Mission Control, Dock, and three-finger presentation pacing

This milestone keeps the gesture path native: UIKit sends one continuous
three-finger transaction, `macwsinputd` forwards it to the live Dock process,
and Dock drives Ventura's own Mission Control animation. No replacement task
switcher UI, forced-success predicate, or SkyLight Space mutation is used.

## Root-cause evidence

The input bridge was already delivering the bounded synthetic gesture at
120 Hz (181 records in 1.5 seconds). The remaining regression was in the iOS
presentation path: `MacWSStreamClient` drained display frames on a 60-Hz
`CADisplayLink`, then handed them to an independently scheduled 60-Hz
`MTKView`. That two-stage cadence produced a runtime-confirmed effective
Mission Control layer rate of only 30.82 fps:

```text
MACWS-DISPLAY layer-retire-begin layer=67 reason=workspace-catalog-removed grace-ms=5000 frames=68 elapsed=2.174 fps=30.82 outstanding=1 dropped=30
```

The frame-delivery display link now requests the panel's 120-Hz cadence while
keeping the producer capped at 60 fps and retaining the existing per-layer
pending-frame coalescing. It pauses as soon as the pending frames are drained,
so this does not create a permanent 120-Hz idle wakeup. A safe direct
predecessor IOSurface-texture reuse also avoids recreating a Metal texture
when the producer republishes the same surface. A larger texture cache was
tested and removed because rotating IOSurface IDs produced no material reuse.

The same 181-record/1.5-second replay after the presentation fix produced:

```text
MACWS-DISPLAY layer-retire-begin layer=27 reason=workspace-catalog-removed grace-ms=5000 frames=106 elapsed=2.145 fps=48.96 outstanding=1 dropped=4
```

This is a 58.9% effective-frame-rate increase and an 86.7% reduction in
dropped frames for the measured animation (`30 -> 4`). Repeated runs measured
49-50 fps with 3-6 dropped frames. These figures are runtime-confirmed from
`/var/jb/var/mobile/macwsdisplayd.err`; they are not inferred from process
uptime or VNC packet rate.

## Native modal input and Dock validation

Mission Control exposed a separate input invariant: a full-screen Dock-owned
modal surface has no ordinary application window ID. `macwsinputd` now retains
the live WindowServer-resolved target, while the injected bridge observes
Dock's real `ECModalEventController` state and calls its original modal event
router. The observer accepts only real CG mouse event types; private gesture
type 29 is never copied as a pointer-event template. Modal witness installation
also occurs once at Gesture Begin rather than on every 120-Hz Changed record.

A Host-format global system tap selected the real Mission Control surface and
dismissed it. WindowServer, Dock, `macwsinputd`, and `macwsdisplayd` retained
their PIDs and no new WindowServer crash report appeared. The startup topology
contained exactly two native Spaces. The native Dock magnification preference
was also verified at `magnification=1`, `largesize=128`.

Evidence:

- [`mission-control-before-first-tap.png`](mission-control-before-first-tap.png)
  shows Ventura Mission Control before the first Host-format modal tap.
- [`mission-control-space-created.png`](mission-control-space-created.png)
  shows the new real Space created by that tap. The test-created extra Space
  was subsequently removed through the native UI.
- [`dock-native-magnification.png`](dock-native-magnification.png) and
  [`dock-native-magnification.json`](dock-native-magnification.json) record the
  stock Dock's maximum hover magnification and the bounded VNC observation.

## Production artifact and safety state

The complete package was rebuilt, installed, and followed by a clean GUI-stack
stop/start (no reboot and no respring):

```text
package sha256: 475f31726319dd1e3f5a2a56d279e4d047c9aa9caf7437578fd8bb169d420686
MacWSHost CDHash: 21157b8d3b9af4f43f0cf46fd03cad102cdcd30c
thermal-state=nominal battery-temp-centic=3259
```

The production preflight kept native AGX mandatory, diagnostics disabled, the
memory guard disabled, and the temperature watchdog at a five-minute interval
with intervention restricted to the Critical state.
