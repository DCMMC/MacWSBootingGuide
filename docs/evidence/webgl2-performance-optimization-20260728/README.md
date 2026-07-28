# WebGL2 native-AGX performance optimization evidence (2026-07-28)

This directory records the new performance/stability campaign after the
latest VS Code / Electron / Chromium native-AGX WebGL2 rendering milestone.

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

`macos_gui.sh stop` and `cleanup_all.sh` now also unload the exact VS Code job
and kill only the Visual Studio Code/Code Helper executable paths.  A deployed
test ended with no VS Code, WindowServer, or VNC job/process and removed both
the wrapped-KCMD and command-error sentinels; the verbatim result is in
`vscode-lifecycle-cleanup-proof.txt`.
