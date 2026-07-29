# WebGL2 native-AGX performance optimization evidence (2026-07-28)

This directory records the new performance/stability campaign after the
latest VS Code / Electron / Chromium native-AGX WebGL2 rendering milestone.

The 2026-07-30 shell-environment/resource hardening run is documented in
[`vscode-shell-env-adapter-20260730/README.md`](vscode-shell-env-adapter-20260730/README.md).
It validates one restored Aquarium tab, a working ptyHost, no optional
AgentHost, quiet production JIT bookkeeping, full Retina VNC, 118.949 FPS at
1,000 fish, and a still-open 12.056-vs-37.679 FPS gap at 60,000 fish.

The follow-up production hot-path and cold-start run is documented in
[`production-hotpath-cache-20260730/README.md`](production-hotpath-cache-20260730/README.md).
It removes every sampled diagnostic `access(2)` call from the 60,000-fish GPU
process, confirms that the remaining 12.289 FPS result is still dominated by
ANGLE/AGX command encoding, and makes the strict one-click Retina VNC startup
survive the observed cold native-AGX initialization delay.

The preceding large-command failure and duplicate-webview ownership boundary
are documented separately in
[`vscode-production-error-20260730/README.md`](vscode-production-error-20260730/README.md).
It includes the raw `0x103` completion, decoded `0x174c0` KCMD witness, exact
iOS IOGPU growth-function disassembly, post-fix clean completion, and the
separate five-tab texture-memory case.

## M1 reference workload sweep

The old 1,000-fish result was refresh-rate capped and is not suitable for a
performance ratio.  A five-second warm-up followed by ten one-second samples
per preset gives the first uncapped point at 15,000 fish:

| Fish | Average FPS | Range |
|---:|---:|---:|
| 5,000 | 60.0 | 60-60 |
| 10,000 | 60.1 | 59-61 |
| 15,000 | 47.0 | 45-49 |
| 20,000 | 33.9 | 32-36 |
| 25,000 | 26.6 | 26-28 |
| 30,000 | 21.5 | 16-24 |

Raw samples are in `m1-aquarium-sweep.json`.  The same presets and sampling
method must be used on the iPad before calculating any performance ratio.

## iPad attribution results

The first reduced-diagnostic iPad runs still measured 15.2 FPS at 1,000 fish
and 15.47 FPS at 5,000 fish.  A clean 100-fish control was only 13.0 FPS.
These bounded results establish a load-independent presentation/backpressure
ceiling in the normal Chromium configuration; they do not identify AGX shader
throughput as that ceiling.

Changing the experimental cancelled-swap pace from its 100-ms idle value to a
fixed 16.667 ms did not improve the 1,000-fish result (14.6 FPS).  A dedicated
CoreVideo probe then measured a 119.952-Hz nominal link and 114.74 callbacks/s
over five seconds.  Therefore neither the idle completion knob nor
`CVDisplayLink`'s reported refresh period explains the approximately 15-FPS
normal result.

The exact Chromium 148 framework contains `disable-frame-rate-limit` and
`disable-gpu-vsync`.  A bounded diagnostic using those switches reached 999
rAF callbacks in roughly five seconds at 100 fish (199.13 callback/s; page
average 220 FPS) with no 0x102/0x103 in that run.  This proves that native AGX
and the page are not intrinsically capped at 15 FPS.  The switches are not a
production fix: a separate run without the retained flight recorder produced
repeated real `00000102` command-buffer failures, while a 15,000-fish probe
remained only 12.6 FPS.  The production plist was restored immediately.

The next root-cause target is the Chromium presentation/in-flight-work model
and its interaction with the temporary KCMD/resource-lifetime translators.
The unthrottled switches must remain diagnostic until a long bounded run is
free of command errors, runaway CPU, and resource growth.

## Cold/unlocked 60,000-fish comparison

The repeatable CDP runner in `misc/aquarium_cdp_benchmark.mjs` removes the
Aquarium one-second display counter and refresh-cap ambiguity. It measures rAF
callbacks over elapsed wall time after an eight-second warm-up. At 60,000 fish
and a fixed 1024x1024 canvas, the cold/unlocked iPad produced 8.828 callback/s.
The M1 produced 36.722 callback/s in Chrome 150 and 37.679 callback/s in the
official VS Code 1.130.0 build. The latter is the exact same Electron 42.6.0 /
Chromium 148.0.7778.280 stack used on the iPad, so Chromium version mismatch is
runtime-disproved as the principal 4.27x gap.

Concurrent `powermetrics` samples reported `Current pressure level: Nominal`
throughout. The GPU requested and entered bins through 1278 MHz, but active
residency stayed roughly 15-21%. Heat, screen lock and a fixed 396-MHz request
are therefore runtime-disproved as the primary cause in this controlled run.
They remain stability confounders for future long soaks.

Samples of the same VS Code GPU process show identical Chromium/ANGLE
`libGLESv2` offsets on both machines. The downstream driver differs: macOS
13.4 uses `AGX::ArgumentTable`, while macOS 26.3.1 uses
`AGX::G13::CommandEncoding` and `FixedLayoutUserArgumentTable`. This is a
runtime-confirmed version-path difference, not yet proof that the newer
encoding path causes the performance delta.

Runtime artifacts:

- `ipad-aquarium-results.json` — all bounded iPad samples and context witnesses.
- `cvdisplaylink-probe.txt` — nominal and actual CoreVideo callback evidence.
- `ipad-vscode-gpu-process-15000.sample.txt` — eight-second GPU-process sample.
- `unthrottled-102-runtime-excerpt.txt` — verbatim ANGLE error lines from the
  unstable unthrottled run.
- `aquarium-cdp-60000-comparison.json` — same-workload iPad, Chrome 150 M1,
  and same-version VS Code M1 results.
- `ipad-60000-thermal-and-agx-runtime-excerpt.txt` — verbatim thermal/DVFS
  samples and the observed old/new AGX argument-encoding symbols.
- `ios16-agx-priority-re-excerpt.txt` — actual iOS 16.3 AGXG13G priority
  propagation disassembly excerpts.
- `cpu-singlethread-probe.txt` — identical optimized integer-loop outputs from
  the M1 MacBook Air and iPad, including matching checksums.
- `fast-submit-error-20260728-2245/` — first-error fixed-ring manifests,
  complete KCMD/segment snapshots, and bounded referenced-resource captures
  for the WindowServer and Chromium `0x102` witnesses.

Device cleanup removed 188 generated `macws_submit_*` diagnostic files and all
files under CrashReporter after their relevant evidence had already been
curated.  The stable VS Code launch arguments and stopped iOS state were
restored at the end of the run.

## Complex Metal worker path and exact completion-pace control (2026-07-29)

Chromium 148's complex WebGL2 fragment shader exposed a third real
`MTLCompilerService` build call. RE of UUID
`6D2CFE56-8D88-39AA-BC25-7FFE5058ED4E` found `_compileRequestMain` loading the
same six-argument service-vtable +0x18 ABI and calling it at `__TEXT+0x20e8`
through `blraaz x9`. The older two-site adapter missed that worker path, so its
reply retained `air64-apple-ios16.3.0` and macOS Metal rejected the library.

The UUID-locked installer now validates and redirects all three call sites
(`+0x20e8`, `+0x25f0`, `+0x2628`) into the existing target adapter while still
calling the real compiler and loader. A standalone source probe returned a
real `_MTLLibrary` and `_MTLFunctionInternal`; the exact VS Code 1.130.0 /
Chromium 148 complex shader produced a 9,184-byte accepted reply containing
`air64-apple-ios19.0.0-macabi`. This removes the complex-source library-format
failure without bypassing validation.

A separately rotated, unlocked, Thermal-Nominal headless run proved both the
on-device sentinel and WindowServer completion logs stayed at exactly 16,667
us. The 512x512 fill control nevertheless measured 16.756 rAF callbacks/s,
with a 62.012-ms average rAF interval, while CPU issue time was only 0.0417 ms
per draw. Thus the earlier approximately 15-FPS result was not contamination
from the 100-ms idle default. That controlled run still exposed repeated
`newEvent` / AGX selector `0x18` failures (`0xe00002c2`). Subsequent
binary/runtime comparison found the actual iOS 16.3 initializer uses selector
`0x14` with the same input/output ABI. Translating `0x18->0x14` now returns a
real `_IOGPUMetalMTLEvent`; a bounded VS Code run completed all 64 explicit GPU
timer queries with zero pending queries and a 0.377-ms GPU-time median. The rAF
median nevertheless remained 39.8 ms, moving the active target from event
construction to presentation scheduling.

The exact disassembly, compiler logs, target strings, pacing lines, benchmark
values, and limitation are in
`metal-target-worker-and-controlled-pace-20260729.txt` and
`private-metal-event-selector-20260729.txt`.

## Native-AGX throughput is near M1; rAF/presentation is not (2026-07-29)

The corrected event path made GPU timer queries usable as a real boundary.
The exact same official VS Code 1.130.0 / Chromium 148 build then ran 1,000
draws per batch on both systems with either requestAnimationFrame or
setTimeout(0) driving the next batch. In the timeout control, the iPad reached
191,788.885 draws/s versus the M1's 202,055.133 draws/s: 94.919% of M1. All
391 iPad and 409 M1 GPU queries completed, with zero pending. CPU issue
throughput reached 91.063% of M1, and iPad GPU-time p50 was 0.322 ms versus
0.375 ms on M1.

The same iPad reached only 41.686% of M1 under rAF, with a 49.3-ms median
interval versus 16.7 ms. Switching only the producer from rAF to timeout made
the iPad 9.43x faster while preserving the WebGL commands, flushes and timer
queries. This runtime-isolates the remaining large gap to visible-frame /
presentation scheduling rather than shader execution or AGX command
throughput. Exact values, histograms, integrity counters and limitations are
in `presentation-scheduler-split-20260729.txt`.

`macos_gui.sh stop` and `cleanup_all.sh` now also unload the exact VS Code job
and kill only the Visual Studio Code/Code Helper executable paths.  A deployed
test ended with no VS Code, WindowServer, or VNC job/process and removed both
the wrapped-KCMD and command-error sentinels; the verbatim result is in
`vscode-lifecycle-cleanup-proof.txt`.

## VS Code generation 3 and WindowServer leading-wrapper fix (2026-07-29)

A clean VS Code cold start exposed a third trailing-wrapper generation.  The
old translator incorrectly required the literal generation 2 even though the
outer and trailing records advanced together to 3.  Validating equality over
the observed 2/3 range restored the latest VS Code run: 1,539/1,539 WebGL2 GPU
queries completed at 191,456.011 draws/s with zero command errors.

The same run separated a WindowServer-only problem.  Its nested subtype-1
record was normalized, but the macOS type-9/list wrappers were retained and
produced repeatable IOGPU ProtectionViolation errors.  The project LLDB
captured the equivalent iOS-native PF550 command as a direct 0x820-byte KCMD
plus direct 0x130-byte list.  Translating the exact wrapped form to that native
layout changed a bounded A/B from 68 early protection observations to zero,
then delivered 6,600/6,600 clean VNC-copy completions, a full Retina Terminal
frame, and 16/16 visible keyboard acknowledgements.

This also narrows the heat report: the erroring WindowServer consumed roughly
75-88% of one CPU, so it was a heat source, not evidence that heat caused the
protocol error.  WindowServer still used 43.4% at the end of the clean bounded
run; presentation/compositor CPU work remains.  The prior unlocked,
Thermal-Nominal rAF result still had a 49.3-ms median, so screen lock cannot be
the entire performance gap.  Exact records, hashes, log excerpts, temperature,
and the pending locked/unlocked A/B are in
`windowserver-wrapper-generation3-20260729.txt`.

## Coexistence / VNC / exclusive attribution (2026-07-29)

The official VS Code 1.130.0 build (Electron 42.6.0, Chromium
148.0.7778.280) was run on both the iPad and M1 MacBook Air with the exact
same 60,000-fish Aquarium URL, 1024x1024 canvas, eight-second warm-up, and
15-second wall-clock rAF measurement. All runs reported WebGL2, the requested
60,000 model fish, and no context loss.

| iPad mode | VNC | Page FPS | p50 frame interval |
|---|---:|---:|---:|
| coexist | on | 12.368 | 81.2 ms |
| coexist | off | 12.625 | 79.3 ms |
| exclusive, repeat 1 | off | 12.092 | 83.0 ms |
| exclusive, repeat 2 | off | 12.238 | 82.0 ms |
| M1 macOS control | n/a | 36.615 | 27.1 ms |

Disabling VNC improved the coexist run by only 2.08%. More importantly,
unloading SpringBoard and backboardd and switching to exclusive mode did not
improve the result: its two-run mean was 12.165 FPS, 3.64% below the controlled
coexist/no-VNC run. The exclusive run had no SpringBoard/backboardd launchd
jobs, while the active GPU process used about 106% CPU, the renderer 86%, and
WindowServer 67%. This runtime-disproves iOS foreground UI work and VNC as
the principal explanation for the remaining 2.90x gap to the M1. The current
target remains per-frame Chromium/ANGLE command encoding and WindowServer
composition/submission CPU work.

Chromium also logs that `TASK_CATEGORY_POLICY` foreground promotion returns
`KERN_INVALID_ARGUMENT`. A native iOS probe tested every SDK task role 0
through 8 in fresh child processes; all were rejected and the read-back role
stayed zero. A bounded compatibility experiment translated the exact failed
self/foreground request into user-interactive pthread QoS and runtime-confirmed
the calling thread changed from QoS 21 to 33. It nevertheless measured only
12.230 FPS. Renicing the renderer to -20 measured 12.320 FPS. Both were below
the 12.625-FPS control, so the compatibility hook was removed rather than
shipped as a symptom-level patch. `misc/task_category_policy_probe.c` is kept
as the reproducible kernel witness.
