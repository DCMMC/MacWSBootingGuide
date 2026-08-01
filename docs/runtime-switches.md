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
- Submit rings, raw command dumps, lifecycle backtraces, method enumeration,
  PF550 experiments, XPC/RFB/JIT/IOSurface traces, unsafe readbacks and broad
  assert bypasses are off.
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

The deb installs the optional VS Code launch job under
`/var/jb/usr/macOS/gui-launchd`, which is intentionally not auto-scanned by
launchd. `macos_gui.sh production` synchronizes the packaged 60,000-fish
settings and Aquarium extension into the project-owned `targetfix13` profile
before starting WindowServer. It preserves Chromium caches/session state and
never reads or writes the user's normal VS Code profile. VS Code itself is
still loaded explicitly after the GUI is ready; package installation or
re-jailbreak cannot launch Electron prematurely.

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
