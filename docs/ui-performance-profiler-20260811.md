# MacWS UI Performance Profiler and Gesture Replay (2026-08-11)

## Outcome

MacWS now has a production-capable UI profiler rather than relying on process
CPU, screenshots, or subjective statements such as “looks smoother”. It
combines two independent layers:

1. an optional Apple QuartzCore RenderServer HUD, compatible with the mechanism
   used by [CAPerfHUD](https://github.com/khanhduytran0/CAPerfHUD); and
2. a MacWS-specific per-Scene profiler that measures the complete
   DisplayStream/IOSurface/Host-Metal/visible-drawable path and exports
   comparable JSON.

The first complete fixed-floor run is intentionally **FAIL**, not a cosmetic
PASS. Input transport and process stability passed, while visible fluidity and
tail latency did not yet meet the project targets. This gives subsequent work
an exact optimization boundary.

## Why CAPerfHUD alone is insufficient

CAPerfHUD commit `4a40c9253fc11a948fae57ec96d5d2c8dc028481`
(2026-05-01) calls these QuartzCore render-server functions:

```text
CARenderServerGetDebugFlags(0)
CARenderServerGetDebugValue(0, 1)
CARenderServerSetDebugValue(0, 1, level - 1)
CARenderServerSetDebugFlags(0, 0x10000000, flags)
```

That is useful for a system-wide FPS/GPU/glitch overlay, but it cannot identify
whether MacWS time was spent in SkyLight capture, IOSurface transfer, Host
submission, GPU execution, or final presentation. It also has no knowledge of
`MacWSInputRecord`, so it cannot measure input-to-visible latency.

`MacWSHost` therefore gained the same opt-in system HUD access (with
`com.apple.QuartzCore.debug`) plus its own profiler. The Apple HUD defaults to
off and is always forced off by the measured CLI run because it is global and
can perturb the screen being measured.

Apple's supported offline tools remain useful for a deep investigation:

- [Game Performance and Metal Instruments](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/)
- [Metal Performance HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics)
- [Animation Hitches](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)

They are not the daily release gate because MacWS crosses an iOS Host, a
chrooted macOS WindowServer, AppKit processes, and a custom input broker.

## Measured pipeline

`MacWSPerformanceMonitor` writes allocation-free fixed rings (512 samples) on
the frame path. Sorting, percentile calculation, JSON encoding, and label
layout happen only at the explicit export or 2 Hz HUD update boundary.

```text
MacWS input dispatch
        │
        ▼
macOS AppKit/Dock ──► SkyLight CGDisplayStream captureTime
        │                         │
        │                         ▼
        │                Host receiptTime (IOSurface)
        │                         │
        │                         ▼
        │                Host Metal submitTime
        │                         │
        │                         ├──► MTLCommandBuffer GPUStart/GPUEnd
        │                         │
        └─────────────────────────┴──► CAMetalDrawable presented callback
```

The JSON reports:

- source frame interval;
- capture → Host receipt;
- Host receipt → Metal submit;
- submit → command completion;
- GPU execution time;
- capture → visible callback;
- Host input dispatch → first subsequently captured visible frame;
- real drawable frame intervals, hitch count, estimated missed vsyncs, command
  errors, and thermal state.

Two presentation cadences are kept deliberately separate:

- `frame_interval` / `active_average_fps`: drawable callbacks within 250 ms
  of real Host input, with gaps over 150 ms excluded. This is the touch
  fluidity metric.
- `observed_frame_interval`: autonomous producer cadence for workloads such as
  WebGL/video that animate without input.

This distinction prevents a static application's 10 Hz status refresh from
being mislabeled as interactive 10 FPS.

## User interface

MacWS Control Center now has a **Performance Measurement** section:

- Off / Compact / Full MacWS HUD;
- Apple system render HUD toggle;
- Reset measurement;
- Export JSON;
- Run standard touch/gesture regression.

The full HUD shows actual presentation FPS, 1% low, frame p99,
capture-to-visible, input-to-visible, GPU time, hitch/drop/error counts, thermal
state, and sample count. With the HUD off, ordinary production frames take one
atomic-boolean fast path and do not install Metal/drawable callbacks. Reset or
gesture replay starts explicit recording; export stops it. Hiding the HUD
during an explicit recording does not cancel that measurement.

Runtime postcondition on the final build: a cold HUD-off snapshot reported
`instrumentation_active=false` with every counter at zero. Reset plus one tap
reported 53 received / 51 presented frames and one input; after export, a
second tap followed by another snapshot retained exactly those counters and
reported `instrumentation_active=false`. Thus the off state does not quietly
keep Metal completion/presentation instrumentation alive.

Exports are written atomically to:

```text
/var/mobile/Library/Logs/MacWSPerformance/latest.json
/var/mobile/Library/Logs/MacWSPerformance/profile-YYYYMMDD-HHMMSS.json
```

Only the newest 20 archived profiles are retained.

## Gesture replay

The Host-integrated replay uses the same controller boundary as physical UIKit
input, so profiler input timestamps and fullscreen hit routing remain intact.
The suite covers:

- primary tap;
- double tap;
- secondary tap;
- 120 Hz primary-button drag;
- 120 Hz phased scroll;
- 120 Hz phased magnify;
- 120 Hz native Dock vertical up/down gestures;
- 120 Hz native Dock horizontal left/right gestures.

System gestures stop at signed progress `±0.35` and send the native Cancel
phase. They exercise Dock's fluid animation without creating/removing Spaces
or leaving Mission Control active. This is a transport/rendering replay, not a
claim that UIKit recognizer arbitration before `MacWSInputRecord` has been
measured.

## One-command fixed-floor gate

Run from the controlling Mac:

```bash
python3 misc/macws_ui_profile.py \
  --host 192.168.1.6 \
  --output /tmp/macws-ui-profile.json
```

The runner:

1. aborts only at the project's configured `Critical` thermal state;
2. verifies the focused Host target and required process generations;
3. disables both overlays during measurement;
4. resets and exports one independent profile per gesture;
5. runs the InputLab semantic matrix and 60/120 Hz motion gates;
6. verifies process stability and thermal state; and
7. scores against fixed iPad floors, without requiring a MacBook run.

Current fixed floors are 60 FPS target, 55 FPS minimum average, 45 FPS 1% low,
input-to-visible p95 ≤ 50 ms, input bridge p95 ≤ 8 ms, zero Metal command
errors, ≥45 delivered moves/s for a 60 Hz stream, and ≥60 delivered moves/s
for a 120 Hz stress stream.

## First runtime result

Runtime-confirmed on iPad13,6 at nominal 36.5 °C. All ten gesture scenarios
completed, and WindowServer `19905`, Dock `20197`, InputLab `39480`,
UIKitSystem `67107`, displayd `72050`, and the tested Host generation stayed
alive. All Host-side Metal command error counters were zero.

| Scenario | Active avg FPS | 1% low | frame p50 / p95 / p99 ms | input→visible p95 ms | GPU p95 ms |
|---|---:|---:|---:|---:|---:|
| Drag | 52.03 | 23.99 | 16.67 / 41.68 / 41.68 | 49.11 | 2.25 |
| Scroll | 47.98 | 23.99 | 16.67 / 37.52 / 41.68 | 48.89 | 2.41 |
| Magnify | 49.18 | 23.99 | 16.67 / 37.52 / 41.68 | 44.86 | 2.27 |
| Three-finger up | 71.49 | 9.60 | 8.34 / 25.01 / 104.21 | 45.67 | 3.76 |
| Three-finger down | 69.57 | 13.33 | 12.50 / 29.18 / 75.03 | 41.63 | 3.51 |
| Three-finger left | 32.71 | 17.14 | 25.01 / 58.36 / 58.36 | 74.41 | 2.08 |
| Three-finger right | 33.75 | 15.99 | 20.84 / 58.36 / 62.53 | 83.11 | 2.81 |

InputLab remained much faster than the visible boundary:

| Input stream | delivered rate | bridge p95 |
|---|---:|---:|
| requested 60 Hz | 55.00 events/s | 0.765 ms |
| requested 120 Hz | 79.37 events/s | 3.777 ms |

This is runtime evidence that the principal remaining UI problem is not the
AF_UNIX input broker or Host GPU execution. The current tail is dominated by
frame production/presentation cadence, especially horizontal Dock navigation,
with roughly 2–4 ms GPU time but 38–83 ms visible/input tail latency. The next
optimization milestone must improve that boundary rather than add another
event-specific input patch.
