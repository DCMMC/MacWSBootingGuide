# iPad launchd performance class and the VS Code 60k workload

## Result

The large iPad/M1 CPU gap was not evidence that V8 was jitless. The exact iOS
launchd binary assigns ordinary daemon jobs to an energy-efficient coalition,
and `POSIXSpawnType=Interactive` alone does not remove that coalition property.
Jobs whose labels start with `UIKitApplication:` enter launchd's application
class instead.

The production GUI labels now use that native application class for
WindowServer, the input bridge, OSXvnc, Terminal, VS Code and Chrome. The
functional environment remains the production native-AGX profile; this change
does not enable MTLSim or diagnostic hooks.

With the new class deployed, the controlled VS Code 1.130 WebGL2 Aquarium run
at 60,000 fish and a 1024x1024 canvas produced 32.302 FPS with a 29.3-ms p50
callback interval and an intact WebGL2 context. The prior controlled production
rounds recorded in the JIT milestone were 11.812 and 11.594 FPS. This is a real
2.7x gain and leaves a much smaller gap to the existing 37.679-FPS M1 result.

The current Mac login session later became locked. A new background-only
control produced 1.010 FPS and is explicitly invalid as a fair M1 baseline; it
is not used in the comparison above.

## Evidence boundary

- `launchd-performance-class-disassembly.txt` is from the actual iPadOS 16.3
  `/sbin/launchd`. It shows `EnergyEfficiencyMode=Efficient` storing one at
  job configuration offset +0x3a8 and the distinct `UIKitApplication:` job
  classification branch.
- `cpu_fp_scalar_probe.c` uses XNU's private `PROC_PIDTHREADCOUNTS=34` ABI to
  separate Efficiency and Performance counters for a fixed arithmetic loop.
- `proc_perf_levels_probe.c` aggregates the same counters across all live
  threads of WindowServer, VNC and Chromium processes.
- `ipad-60k-round3.json` is the post-change WebGL2 workload result.
- `vnc-context-round1` through `round3` visibly complete context-menu
  open/close. The apparent miss in `vnc-title-drag/results.json` is not product
  evidence: the retained frame puts Terminal's title bar around y=464 while
  the old benchmark default dragged from y=185, on the black desktop. The
  benchmark now detects the real light title bar from its normalized frame and
  records the selected coordinates before testing.
- `first-error-diag` records a separate native-AGX `0x103` completion error
  reached only under sustained load. Its root-cause correction is RE-backed
  but pending deployment validation while the iPad is offline.

## Remaining work

This milestone fixes the scheduler-class bottleneck, not the whole target.
Sustained native-AGX command stability, a corrected on-device title-drag run,
production soak time, and a new unlocked/foreground M1 baseline remain open.
