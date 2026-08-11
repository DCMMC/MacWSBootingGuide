# Control Center application, input, and presentation regression — 2026-08-11

## Release verdict

The production native-AGX session passed the complete 12-application launch
matrix and the AppKit input semantics/latency gate. It did **not** yet pass the
MacBook-class visible-animation gate: the accurately segmented native Mission
Control producer averaged 55.08 fps, but its 1% low was 29.16 fps against the
fixed 45 fps target. This document therefore separates `AUTOMATED PASS` from
`VISIBLE PERFORMANCE OPEN`; process uptime is never used as a substitute for
pixels or event delivery.

The daily target is fixed and no longer requires a MacBook run every time:

| Metric | Release target |
|---|---:|
| Active interaction | 60 fps |
| Active interaction 1% low | at least 45 fps |
| MacWS input bridge p95 | at most 8 ms |
| Physical input to visible response p95 | at most 50 ms |
| 60 Hz synthetic drag delivery | at least 45 events/s |
| 120 Hz synthetic drag delivery | at least 60 events/s |

A MacBook Air measurement is calibration-only. It should be repeated after a
major input/display architecture change, not as part of every iPad build.

## Control Center application matrix

The automated runner used the same `macwshost://<id>` action as every Control
Center button and required four independent witnesses: live process, valid
version-2 AppKit window catalog, process-local input socket, and Host
DisplayStream Scene/focus transition. It retained one screenshot and JSON
record per application. All 12 passed; median launch-to-witness time was
8.885 seconds, mean 10.324 seconds, and the slowest was Excel at 23.520
seconds.

| Application | Launch (s) | Functional visible witness |
|---|---:|---|
| GlassDemo | 5.380 | Native right-click menu opened; vibrancy/blur remained visible |
| Terminal | 5.081 | Typed `echo macwsinputok`; create/switch tab worked |
| Activity Monitor | 8.575 | CPU → Memory tab click changed the visible pane |
| Finder | 9.194 | Double-clicking Documents opened the folder |
| VS Code | 5.589 | `…` menu opened, an item could be selected, outside tap dismissed it |
| System Settings | 7.416 | Displays pane loaded and accepted selection |
| Maps | 11.502 | Map tiles and location marker rendered; drag and magnify changed the map |
| Amadine | 8.468 | Tutorial card selection changed visibly |
| Word | 14.657 | Document accepted typed text |
| Excel | 23.520 | Cell A1 accepted typed text |
| PowerPoint | 14.225 | Slide text accepted typed text |
| Asphalt | 10.282 | Native Catalyst age screen rendered and accepted a tap |

Asphalt then reached its own online connection-error page. The process stayed
alive for more than three minutes with a valid drawable, but this run does not
claim an online race was entered. It was explicitly closed after the bounded
test.

The full machine-readable matrix is
[`app-launch-summary.json`](evidence/control-center-input-performance-20260811/app-launch-summary.json).

## Input semantics and latency

InputLab received 44 version-4 transport records as 47 real AppKit events. The
matrix covered:

- left click, drag, and right click;
- phased scroll (`began → changed → ended`);
- phased magnify with exact `0, +0.125, -0.0625, 0` values;
- lowercase, Shift uppercase, Caps Lock uppercase, Control, Command, Tab,
  Backspace, Return, and Escape.

The bounded five-second motion probes produced:

| Requested rate | Moves sent | AppKit drags | Delivery rate | p50 | p95 | max |
|---:|---:|---:|---:|---:|---:|---:|
| 60 Hz | 300 | 283 | 56.58 Hz | 0.493 ms | 1.002 ms | 18.127 ms |
| 120 Hz | 600 | 400 | 79.97 Hz | 0.386 ms | 2.597 ms | 20.099 ms |

Both hot-path p95 measurements are well inside the 8 ms gate. The semantic
matrix's 94.5 ms maximum is not used as its motion score because it includes
deliberate synchronous native control/menu tracking between heterogeneous
operations. Exact records are in
[`input-matrix.json`](evidence/control-center-input-performance-20260811/input-matrix.json),
[`input-motion-60.json`](evidence/control-center-input-performance-20260811/input-motion-60.json),
and
[`input-motion-120.json`](evidence/control-center-input-performance-20260811/input-motion-120.json).

## Two- and three-finger visible regression

The two-finger scroll and magnify paths passed both the phased AppKit event
matrix and visible Maps movement/zoom. The native three-finger path was tested
in every requested direction without replacing Dock's UI:

- upward entered Ventura Mission Control;
- a global modal tap selected InputLab and returned to the desktop;
- downward entered native App Exposé;
- horizontal positive switched to the adjacent Space;
- horizontal negative returned to the original Space.

WindowServer PID 19905, Dock PID 20197, Host PID 38539, and InputLab PID 39480
survived the full sequence. The adjacent Space contained an already-black VS
Code window; switching back restored the original desktop, so that content is
recorded as an application/window state rather than mislabeled as a gesture
transport failure.

Visible evidence:

- [Mission Control](evidence/control-center-input-performance-20260811/mission-control.png)
- [App Exposé](evidence/control-center-input-performance-20260811/app-expose.png)
- [Adjacent Space](evidence/control-center-input-performance-20260811/space-switched.png)
- [Original Space restored](evidence/control-center-input-performance-20260811/space-restored.png)
- [InputLab after modal selection](evidence/control-center-input-performance-20260811/post-mission-inputlab.png)

## Honest presentation-performance boundary

The previous `frames / (last timestamp - first timestamp)` statistic counted
the tester's static inspection pause between Mission Control enter and exit.
It could report 28 fps even when active frames were near 60 fps. `macwsdisplayd`
now keeps a fixed allocation-free 512-interval ring per captured layer, splits
at a real producer gap longer than 150 ms, and emits average, p50, p99, and 1%
low for each active burst. It does not add a per-frame log or enable a debug
sentinel.

At a runtime-confirmed `nominal` 37.69 °C thermal state, the main Dock layer
reported:

```text
MACWS-DISPLAY active-frame-burst layer=484 owner=Dock reason=producer-gap intervals=113 average-fps=55.08 p50-ms=17.644 p99-ms=34.290 one-percent-low-fps=29.16
MACWS-DISPLAY layer-retire-begin layer=484 reason=workspace-catalog-removed grace-ms=5000 frames=124 elapsed=4.305 fps=28.57 outstanding=1 dropped=4
```

Representative application layers averaged 52.56–52.57 fps with p99 near 49
ms. The Host's sequence-120 end-to-end stage witness was healthy but not free:

```text
display-perf stream=16 sequence=120 capture-to-receipt-ms=1.001 receipt-to-submit-ms=7.589 submit-to-complete-ms=3.342 status=4 error=nil
```

The input path is therefore ruled out as the dominant source of the visible
jank for this run. Runtime logs place the remaining boundary in the
multi-layer fullscreen capture/presentation path: the Dock layer reached the
three-lease backpressure limit and dropped four frames, while several Retina
application/system layers updated in the same animation burst. The evidence
does not yet distinguish how much of that jitter originates in SkyLight's
many exact-window capture producers versus Host lease feedback; that narrower
attribution remains open and must be measured before changing queue depth or
stopping streams.

## Repeatable workflow

The daily automated gate is one command:

```bash
python3 misc/macws_release_regression.py \
  --host 192.168.1.6 \
  --run-apps \
  --output /tmp/macws-release-regression.json
```

It checks production native-AGX switches and the main runtime-diagnostics
sentinel (the production launcher remains the exhaustive debug-state
preflight), reads the five-minute thermal watchdog, aborts dynamic work only at
`critical`, runs the 12-app matrix, then executes semantic and 60/120 Hz
InputLab probes. A
subset rerun no longer overwrites the full matrix; merge retained per-app
results with:

```bash
python3 misc/control_center_app_regression.py \
  --host 192.168.1.6 \
  --output /tmp/macws-control-center-regression \
  --summary-only
```

The final physical phase remains necessary because synthetic transport cannot
measure touch sampling or photon output. On the iPad, perform one 10-second
cycle each of single tap, long-press window drag, one-finger touch scroll,
two-finger trackpad scroll, pinch, three-finger up/down/left/right, and hardware
Shift/Caps Lock typing. Fail the visible gate for any dead control, stuck modal
menu, window/input PID restart, touch-to-visible p95 above roughly 50 ms, active
animation below 60 fps, or 1% low below 45 fps. Do not reinterpret a failed
visible gate as PASS because the process stayed alive.

After an active Mission Control run, score the segmented producer samples
without accepting the legacy static-lifetime statistic:

```bash
ssh mobile@192.168.1.6 \
  'tail -n 500 /var/jb/var/mobile/macwsdisplayd.err' | \
  python3 misc/display_active_frame_report.py --owner Dock
```

The command exits nonzero when average fps or 1% low misses the fixed target;
the 2026-08-11 run correctly returned `FAIL` rather than rounding 55.08 fps up
to “close enough.”

The combined automated witness is
[`release-regression.json`](evidence/control-center-input-performance-20260811/release-regression.json).
