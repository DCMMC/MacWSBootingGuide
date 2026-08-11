# UI performance regression and native Space cadence (2026-08-12)

## Outcome

The production regression surface now covers thirteen independent gestures,
semantic AppKit delivery, 60/120 Hz sustained input, per-source frame timing,
final drawable presentation, input-to-visible latency, Metal/GPU time, process
generation, and the project's Critical-only thermal gate. The first complete
13 ms baseline intentionally remains FAIL against the 55 FPS / 45 FPS 1%-low
release floors; this is a measured optimization boundary, not a process-uptime
claim.

The measured A/B optimization in this milestone reduces only the active
interaction completion interval from 13,000 us to 8,333 us. Idle completion
remains at 100,000 us, and the independent exact-window capture source remains
bounded at 60 Hz. The 8,333 us production candidate was retained because two
focused repeats and a final full run improved visible cadence at nominal
temperature without changing any semantic input result or service generation.

## Runtime evidence: the input broker is not the limiting stage

The complete run `/tmp/macws-ui-pace13-full-v19.json` retained WindowServer
`16770`, Dock `27704`, InputLab `26651`, displayd `25930`, inputd `25928`, and
Host `16845`. Temperature ended nominal at 29.50 °C and the semantic input
matrix passed. Its sustained motion witnesses were:

```text
60 Hz:  300 moves sent, 299 AppKit drags, 59.7827/s, p95 3.1645 ms
120 Hz: 600 moves sent, 568 AppKit drags, 113.5591/s, p95 2.7700 ms
```

In the same run, hover/drag/long-drag/scroll/momentum/magnify produced
49.72–52.34 source FPS with 24.66–28.45 ms frame p95 and 2.48–2.80 ms GPU p95.
Vertical native Dock animations reached 86.58–88.96 final-presented FPS.
Horizontal native Space animations remained 32.59–33.27 final-presented FPS.
This runtime split places the remaining ordinary-content bottleneck after the
input broker, and the horizontal bottleneck in Space geometry/presentation.

## Runtime evidence: 8,333 us active cadence is a real improvement

The first two focused 8,333 us runs independently produced
53.75/54.15 FPS for long-press drag, 55.12/55.47 FPS for momentum scrolling,
and 55.59/55.75 FPS for magnify. Their corresponding frame p95 ranges were
20.58–23.17 ms, compared with 25.26–27.81 ms in the 13 ms complete baseline.

The final complete run `/tmp/macws-ui-pace8333-full-v24.json` retained Host
`16845`, WindowServer `31251`, inputd `40106`, displayd `40109`, Dock `40340`,
and InputLab `40367`. It ended nominal at 29.59 °C, passed the semantic input
matrix, and reported zero Metal command errors:

| Scenario | Active avg FPS | 1% low | frame p50 / p95 / p99 ms | input→visible p95 ms | GPU p95 ms |
|---|---:|---:|---:|---:|---:|
| Hover | 54.33 | 41.49 | 17.88 / 21.59 / 24.10 | 44.75 | 2.68 |
| Drag | 55.55 | 46.96 | 17.69 / 20.90 / 21.29 | 40.95 | 2.58 |
| Long-press drag | 55.01 | 42.04 | 17.90 / 21.10 / 23.79 | 44.98 | 2.56 |
| Scroll | 54.55 | 35.99 | 17.56 / 21.96 / 27.78 | 44.21 | 2.65 |
| Momentum scroll | 54.55 | 41.97 | 17.66 / 21.57 / 23.83 | 41.03 | 2.62 |
| Magnify | 54.14 | 43.06 | 17.87 / 23.03 / 23.22 | 40.95 | 2.69 |
| Three-finger up | 96.52 | 47.98 | 8.34 / 16.67 / 20.84 | 40.29 | 3.43 |
| Three-finger down | 99.09 | 47.98 | 8.34 / 16.67 / 20.84 | 40.02 | 3.05 |
| Three-finger left | 63.98 | 9.23 | 12.51 / 29.18 / 108.38 | 45.45 | 2.47 |
| Three-finger right | 56.85 | 8.00 | 12.51 / 41.68 / 125.05 | 65.94 | 2.58 |

The matching sustained input witnesses were 59.7727/s at 4.4933 ms p95 for
the 60 Hz stream and 117.9722/s at 4.1079 ms p95 for the 120 Hz stream. A
post-run idle sample still showed nominal 29.59 °C, Host/inputd/displayd/
InputLab at 0.0% CPU and WindowServer at 8.5% CPU. This confirms that the
optimization is bounded to active completion; it does not turn the test
helpers into permanent busy loops.

The release gate still correctly returns FAIL: hover and several ordinary
gestures retain sub-45-FPS 1% lows, horizontal Space animations retain
108–125 ms p99 gaps, and three-finger right retains 65.94 ms input-to-visible
p95. These are the next measured presentation-tail targets. The thresholds
were not relaxed to make the optimization pass.

## Runtime evidence: Dock must bind after the final Space catalog

After a WindowServer recovery, Dock PID `25982` accepted the complete synthetic
gesture input transaction but both horizontal scenarios produced zero geometry
and zero active presentation frames. The workspace controller simultaneously
reported two valid Spaces, IDs `1` and `9`.

A controlled production-only Dock reload (`25982` → `27704`) changed no
gesture bytes, display daemon, Host, or WindowServer. The immediately repeated
right gesture then produced:

```text
geometry_updates=48
source active_average_fps=38.4801
final active_average_fps=38.9571
```

displayd's matching runtime recorder reported:

```text
MACWS-DISPLAY workspace-geometry-burst queries=82 records=470 query-mean-ms=6.840 p50-ms=0.917 p95-ms=26.443 p99-ms=38.829 route=targeted-description-async
```

The startup transaction previously launched Dock, then created the adjacent
Space. `macos_gui.sh` now performs one bounded Dock unload/load after
`ensure-navigation-spaces`, verifies that its exact launchd PID changed, and
only then proceeds to wallpaper/VNC/Terminal. This encodes the measured
dependency rather than requiring a manual post-start restart.

## RE evidence: exact SkyLight transaction ABI

`misc/skylight_geometry_probe.m` dumped the code of the actual Ventura 13.4
SkyLight image on the iPad. Capstone disassembly of
`SLSTransactionSetSpaceTransform` at runtime address `0x1a0d30220` preserves
`x0..x3`, serializes full-width `x1`, 32-bit `w2`, and reads successive doubles
from the transform pointer in `x3`. `SLSTransactionSetWindowTransform` at
`0x1a0d2dff0` preserves `x0..x4`, serializes window `w1`, signed `w2`, placement
`w3`, and reads the transform from `x4`.

This identifies a root event boundary for future work: Dock's exact committed
Space/window transforms can be observed at their transaction setter instead of
reconstructed indefinitely through `CGWindowListCreateDescriptionFromArray`.
No transaction hook or ABI guess is shipped in this milestone; the current
production path remains the verified targeted asynchronous query.

## Profiler determinism fix

Host writes `latest.json` with `NSDataWritingAtomic`. The original runner used
only seconds-resolution mtime and byte length as the new-export marker. A full
thirteen-gesture run completed every Host replay but failed afterward because
the final atomic replacement shared those two values with its predecessor.
The runner now includes the replacement inode in the marker. This is a test
framework correction; it does not relax any performance threshold.
