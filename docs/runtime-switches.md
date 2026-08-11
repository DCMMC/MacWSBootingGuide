# MacWS production runtime switches

The machine-readable source of truth is
[`runtime-switches.tsv`](runtime-switches.tsv). Run
`python3 misc/audit_runtime_switches.py` after adding a new `getenv()` or
`/tmp/macws_*` `access()` gate; the audit fails if the switch has no recorded
production state.

## One-click production profile

```bash
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production
```

`start` now has the same defaults: coexistence display mode, native AGX and
the required command/completion/VNC compatibility enabled, VNC and Terminal
started, the mandatory health watchdog armed, and diagnostics disabled.
`--experimental` remains
an accepted compatibility alias. Only an intentional control run should use
`--no-experimental`; only an evidence-gathering run should add
`--diagnostics`.

Use this command to inspect the configured launch environments and the actual
state of every runtime flag on the device:

```bash
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh switches
```

The production preflight removes every diagnostic/A-B sentinel and bounded
submit/error dump before launching WindowServer. It rejects launch plists that
contain allocator instrumentation or known trace/flight-recorder environment
variables. `MallocScribble` is explicitly forbidden.

## Production invariants

- `MACWS_AGX_NATIVE=1`: rendering uses the real iOS AGX driver, never MTLSim.
- Cross-image AGX class registration and the current allocation compatibility
  remain enabled because they are functional prerequisites, not diagnostics.
- Direct/wrapped KCMD translation, cancelled-swap completion, owned BGRA
  scanout and the VNC mmap bridge are enabled for the current coexistence
  implementation.
- Validated custom-path and generic Catalyst children receive the scoped
  `MACWS_APP_MOUNT_COMPAT=1` namespace contract. Generic Catalyst children also
  receive `MACWS_CATALYST_DIRECT_DRAWABLE=1`: if SkyLight captures their title
  bar but omits a CAMetalLayer client area, libmachook transfers the completed
  drawable's real IOSurface Mach right to the foreground Host. Host validates
  its typed envelope and geometry, imports it as a native Metal texture, and
  composites it over the black client area without RFB, compression, or CPU
  pixel copies. The broad mount diagnostic is explicitly removed from the
  child environment even if the existing Host was started by a debug shell.
- VS Code and Chrome set `MACWS_CHROMIUM_COMPOSITE_OVERLAYS=1`. For the exact
  UUID-checked Chromium 148 Electron Framework, this marks the root
  `AggregatedRenderPass` with Chromium's real `video_capture_enabled` field
  before its unmodified `CALayerOverlayProcessor` runs. Chromium then rejects
  process-local CALayer promotion with its native
  `kCALayerFailedVideoCaptureEnabled` result and appends the normal primary
  plane, keeping video in the AGX-composited scanout captured by MacWS/VNC.
  The exact adapter writes that real field using a verified two-instruction
  dataflow rewrite; it does not install a per-frame function trampoline.
- Submit rings, raw command dumps, lifecycle backtraces, method enumeration,
  PF550 experiments, XPC/RFB/JIT/IOSurface traces, unsafe readbacks and broad
  assert bypasses are off.
- Finder, Dock, IconServices and LaunchServices use the exact scoped chroot
  mount namespace. CarbonCore's host boot-volume refnum is translated to the
  process-visible root refnum; the RE and runtime witnesses are in
  [`finder-iconservices-root-volume-20260804.md`](finder-iconservices-root-volume-20260804.md).
  FileCache/DesktopServices volume-map probes remain off in production.
- The 100,000-us idle virtual-display interval temporarily changes to
  16,667 us for one second after real VNC input. This is compatibility pacing,
  not a hardware-vblank claim.
- Performance comparisons are valid only when the iOS thermal helper reports
  its startup and five-minute snapshots. Per current policy, only `critical`
  intervenes; `nominal`, `fair`, `serious`, numeric temperatures and missing
  samples are recorded without stopping the run.

## Mandatory health guards

The iPad launcher runs `/var/jb/usr/macOS/bin/macwsthermal` before any GUI
session, then samples once every 300 seconds. Only an explicitly observed
`critical` iPadOS thermal state stops or refuses the GUI. `nominal`, `fair`,
`serious`, numeric temperatures and unreadable samples are log-only.
`--no-watchdog` is rejected; the monitor itself is not a production switch.
`macos_gui.sh status` reads the watchdog's timestamped cached snapshot and does
not perform an extra sensor read.

The former `memory_pressure -Q <= 58%` launcher guard is disabled. iOS uses
otherwise-idle RAM for caches and reclaimable allocations, and the returned
free percentage is not an Apple pressure-state boundary. Runtime on 2026-08-01
showed the threshold stopping an otherwise-running production launch, so startup and the
watchdog no longer sample, refuse, or stop on that value. XNU/iOS memorystatus
retains authority over cache reclamation and process pressure handling. The
historical reset evidence remains in
[`memory-reset-20260801/`](evidence/memory-reset-20260801/README.md), but no
project memory threshold is active.

At startup, production mode validates two independent trustcache witnesses:
the base chroot shell and VS Code's early-loaded Electron Framework. If either
is missing after a reboot, it runs `postinst.sh` once and requires both checks
to pass before WindowServer starts. `postinst.sh` re-registers the persistent
per-architecture signatures of executable files inside the existing VS Code
bundle; it deliberately does not re-sign nested frameworks.

Cold-start control state is intentionally small and explicit.  The atomic
`/var/jb/var/mobile/.macos_gui.transaction` directory prevents overlapping
start/stop/restart mutations, while `macos_gui_start.state` is an atomically
replaced phase journal for the Host UI.  The rootfs catalog marker records the
LaunchServices schema plus an application/extension source fingerprint; it is
accepted only after a live read-only record verification.  A matching but
inactive catalog is reactivated through stock `lsregister` calls, not trusted
from the marker alone.  The Settings boot-ready witness is tied to the current
bootsession and dependency hashes; its persistent hash manifest contains only
verified executable CDHashes used to restore the reboot-volatile trustcache.

The deb installs the optional VS Code launch job under
`/var/jb/usr/macOS/gui-launchd`, which is intentionally not auto-scanned by
launchd. `macos_gui.sh production` synchronizes the packaged 60,000-fish
settings and Aquarium extension into the project-owned `targetfix13` profile
before starting WindowServer. It preserves Chromium caches/session state and
never reads or writes the user's normal VS Code profile. VS Code itself is
still loaded explicitly after the GUI is ready; package installation or
re-jailbreak cannot launch Electron prematurely.

The VS Code Helper Metal source-library cache has a separate persistent schema
marker, `macws-macabi-source-v1`. Runtime capture on 2026-08-01 proved that an
old `31001/libraries.data` returned `air64-apple-ios16.3.0` MTLBs to the macOS
AGX device, while a clean cache produced only
`air64-apple-ios19.0.0-macabi` and the same ANGLE sources compiled
successfully. On a missing or mismatched marker, `postinst.sh` (or the next
production start after all VS Code helpers are stopped) removes only
`31001/libraries.list` and `31001/libraries.data`; Chromium profile, session,
function, and media caches remain intact.

Chromium 148.0.7778.280 embeds ANGLE revision `1ba8ec3`'s default Metal
library as `air64-apple-macosx10.14.0`. The container itself loads on the
chroot AGX device, but the iOS compiler service rejects function-constant
specialization as a target-OS mismatch. The package therefore installs a
second library generated from that exact ANGLE source by the real device
compiler through the macabi adapter. `libmachook` substitutes it only when the
embedded source library matches both the runtime-confirmed 361,943-byte length
and FNV-1a hash `4a17e801057d2e72`; other Electron/ANGLE versions retain their
own library. The installed replacement is independently checked as a
714,152-byte MTLB with FNV-1a `2b19e550c422772a` before use.

MacBook reference measurements use the matching guarded entry point:

```bash
bash misc/run_aquarium_benchmark_safe.sh \
  --host 127.0.0.1 --port 9222 --fish 60000 --seconds 15
```

`misc/macbook_thermal_watchdog.sh` performs the same immediate snapshot and
300-second sampling around any supplied command, with intervention restricted
to `critical`. On macOS it uses
`AppleSmartBattery.Temperature` as the physical battery-temperature field and
records `VirtualTemperature` separately; the two are not interchangeable on
the M1 reference machine. The watchdog log defaults to
`${TMPDIR}/macws_macbook_thermal_watchdog.log`.

## Inventory format

Each TSV row records `kind`, exact switch name/path, production state, scope,
and purpose. States mean:

- `on`: required in the normal production profile;
- `off`: forbidden or intentionally absent in production;
- `auto`: launcher-owned infrastructure rather than a user toggle;
- `transient`: bounded runtime state, socket, or one-shot handshake.

Diagnostic files and environment variables can still be enabled deliberately,
but that run must not be reported as a production performance result.
