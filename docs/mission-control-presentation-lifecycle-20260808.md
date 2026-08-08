# Mission Control presentation lifecycle — 2026-08-08

## Result

Fullscreen DisplayStream delivery now coalesces the newest base/layer frames
at an iPad display boundary, and short-lived Mission Control capture streams
are retired one display interval apart.  The fix preserves native Dock gesture
input and the real macOS animation; it does not replace Mission Control with a
Host animation, raise the producer queue depth, or suppress AGX failures.

The production package was rebuilt and installed on the iPad.  One 241-record
120 Hz gesture and four repeated Mission Control/create-desktop-area cycles
kept the same processes alive:

```text
BASE_WS=91440
BASE_DOCK=91568
AFTER_WS=91440
AFTER_DOCK=91568
```

No `Internal Error 00000103`, assertion, abort, or new crash report appeared
during that bounded run.  The final thermal sample was `nominal`, 35.09 °C.
The GUI stack was stopped explicitly after validation; the device was not
rebooted or resprung.

## Evidence and failure boundary

Mission Control is not one captured bitmap.  Runtime DisplayStream logs show
three short-lived Dock windows for one transition: one 356x60 layer and two
2388x1668 Retina layers.  They arrive independently:

```text
MACWS-DISPLAY layer-start stream=14 base=0 layer=21 ... destination=(1016,804 356x60)
MACWS-DISPLAY layer-start stream=15 base=0 layer=22 ... destination=(0,0 2388x1668)
MACWS-DISPLAY layer-start stream=16 base=0 layer=20 ... destination=(0,0 2388x1668)
```

Before this change, every XPC callback immediately scheduled its own UIKit
delivery.  The Host could therefore import several related IOSurfaces and ask
MTKView to present repeatedly within one panel refresh.  Runtime logs also
showed the producer's real queue-depth boundary being reached:

```text
MACWS-DISPLAY backpressure ... outstanding=3 dropped=1
```

This is a visible-output witness, not an inference from process uptime.  The
existing fullscreen disconnect path already contains an independent runtime
witness for the other lifecycle edge: stopping every Retina stream in one
stack frame was followed by `Internal Error 00000103` and a new WindowServer
PID.  Mission Control's three removal timers shared the same five-second
deadline and previously recreated that teardown burst on one serial queue
turn.

The user's create-Space crash itself was intermittent.  A production-only
abort trace was temporarily armed after preflight, but four bounded attempts
did not reproduce an abort and the trace was removed before the final build.
Accordingly this milestone does not claim a captured create-Space stack.  It
repairs the runtime-confirmed upstream capture/presentation lifetime invariant
that the action stresses.

## Implementation

- `MacWSStreamClient` keeps only the newest frame per layer and arms a paused
  `CADisplayLink`.  At the next native display boundary it drains one sorted
  batch, so sibling Dock surfaces are applied coherently and replaced pending
  leases are returned immediately.
- `MacWSMetalView` records the exact submitted lease token for the base and
  each overlay.  A superseded frame is retained until GPU completion only if
  that exact IOSurface was encoded; imported-but-never-submitted frames return
  their producer lease immediately.
- `macwsdisplayd` keeps the existing five-second same-window reuse grace, then
  validates and drains expired transient stops at 16 ms intervals.  Every stop
  rechecks layer identity and retirement generation before touching the real
  `CGDisplayStream`.

The post-fix runtime sequence was:

```text
MACWS-DISPLAY layer-retire-stop-queued depth=1 interval-ms=16
MACWS-DISPLAY layer-retire-stop-queued depth=2 interval-ms=16
MACWS-DISPLAY layer-retire-stop-queued depth=3 interval-ms=16
MACWS-DISPLAY layer-retire-complete layer=21 reason=workspace-catalog-removed
MACWS-DISPLAY layer-retire-complete layer=22 reason=workspace-catalog-removed
MACWS-DISPLAY layer-retire-complete layer=20 reason=workspace-catalog-removed
```

Four rapid cycles created and retired another twelve transient layers with the
same ordered sequence while WindowServer and Dock PIDs remained unchanged.

## Production configuration and remaining work

The installed WindowServer plist was checked after package installation:
`MACWS_ABORT_TRACE` was absent, all diagnostic sentinel files reported OFF,
and `MACWS_AGX_NATIVE=1` remained enabled.  The test used
`start coexist --no-vnc --no-terminal --runtime-cap=300`.

This milestone materially improves coherence and removes the reproduced
teardown burst, but it does not claim MacBook-level smoothness yet.  The
four-cycle stress still recorded a one-frame producer drop on the first
Mission Control burst for several streams.  That residual is the next
performance boundary: fullscreen mode composites multiple independent Retina
layers, while an ordinary pinch commonly updates only one application layer.
Further work must measure and reduce Host composition/GPU-completion latency;
increasing queue depth would only retain more full-size IOSurfaces and is not
treated as a fix.

The cold production start also had one separate transient failure: the first
IconServices agent attempt exited before its endpoint-ready check without a
crash report; a clean retry succeeded.  That startup issue remains distinct
from the Mission Control presentation fix.
