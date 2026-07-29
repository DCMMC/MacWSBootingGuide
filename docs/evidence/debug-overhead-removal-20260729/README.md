# Production debug-overhead boundary — 2026-07-29

This milestone separates the native-AGX/VNC compatibility mechanisms needed
for output from the flight recorders used to reverse-engineer them.  It does
not claim that the remaining WindowServer CPU cost is solved, and it does not
use the short startup sample as a WebGL performance result.

## Build-codegen correction

The on-device build retained symbols with `STRIP=0`.  The installed Theos
`common.mk` makes that an unoptimized build unless `OPTFLAG` is explicit:

```text
207 SHOULD_STRIP := ...
209 ifeq ($(SHOULD_STRIP),$(_THEOS_TRUE))
210 OPTFLAG ?= -Os
212 else
214 OPTFLAG ?= -O0
```

Both `misc/build_on_ios.sh` and `misc/build.sh` now pass `OPTFLAG=-O2` while
retaining the LLDB symbols.  A full package build and subsequent on-device
FAST libmachook builds completed successfully.  This corrects a real
measurement contaminant; `FINALPACKAGE=1` alone did not override `-O0`.

## Production/diagnostic boundary

`macos_gui.sh start ... --experimental` now enables only the command-ABI,
cancelled-swap completion, VNC-sharing, and owned-scanout compatibility that
the current native-AGX path requires.  The following work is armed only by the
additional `--diagnostics` option:

- submit rings and serialized submit dumps;
- command-error/PF550 observers and method traces;
- AGX resource lifecycle hash tables, mutexes, backtraces and allocation
  counters;
- per-event AppInputBridge/macwsinputd traces and timing counters;
- per-frame VNC flow, mmap, damage, map-audit and completion logs.

Runtime option validation requires `--diagnostics` to be paired with
`--experimental`.  Normal startup readiness no longer greps a diagnostic
stderr line: WindowServer writes `/tmp/macws_graphics_ready` once after the
first clean producer completion, and the launcher validates that file's PID.

The VS Code 1.130 / Chrome 150 launch plists no longer request Chromium verbose
stderr logging, Electron logging, JIT mprotect tracing, or Mach tracing.  The
GlassDemo launch plist no longer enables the abort tracer.

## Thermal gate and bounded runtime evidence

`misc/ios_thermal_state_probe.m` reads iOS's `NSProcessInfo.thermalState` and
returns nonzero unless the state is nominal.  The installed device helper is
`/var/jb/usr/local/bin/macws-thermal`.  GUI/debug services were stopped and the
large historical logs truncated before each validation run.

The final functional run started and ended nominal:

```text
thermal-state=nominal raw=0 low-power=no uptime=348857.579
[macos_gui] WindowServer graphics ready (pid=84141, clean producer observed).
[macos_gui] VNC: Retina first frame ready (WindowServer pid=84141, generation=1785340345).
thermal-state=nominal raw=0 low-power=no uptime=348964.578
thermal-state=nominal raw=0 low-power=no uptime=348972.719
```

The production run had no diagnostic sentinel, no serialized submit artifact,
and captured a real Retina frame:

```text
diagnostic_sentinels=0
submit_artifacts=0
RFB name='macOS-iPad' size=2388x1668
nonblack_pixels=1701058/3983184 (42.706%)
PNG sha256=fee379d894c856ece8e432ff2a8ea17fed25b761fc6d91ffe64f1d74b6ee9cf3
```

After about one minute the three principal logs totalled 21,578 bytes.  An
earlier run exposed an incorrectly guarded unchanged-frame message that wrote
415 `VNC-MMAP unchanged skip #0` lines; the condition was corrected and the
final run emitted none.  The final log scan found only two one-shot
`AGX_CLASSREF_DIAG` startup lines and zero hot-path entries from the audited
set.  Those last two lines were then placed behind the same diagnostics gate;
the resulting O2 dylib compiled, signed, trust-cached and deployed at 23:53.

The short post-start process sample still showed WindowServer at 44.2% CPU.
That is an open compositor/VNC cost, not evidence of remaining debug logging
and not a thermally valid steady-state benchmark.  Future WebGL/VNC results
must be rejected unless `macws-thermal` reports nominal immediately before and
after the isolated run.
