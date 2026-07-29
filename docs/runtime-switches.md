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
started, watchdog enabled, and diagnostics disabled. `--experimental` remains
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
  `nominal` immediately before and after the isolated run.

## Inventory format

Each TSV row records `kind`, exact switch name/path, production state, scope,
and purpose. States mean:

- `on`: required in the normal production profile;
- `off`: forbidden or intentionally absent in production;
- `auto`: launcher-owned infrastructure rather than a user toggle;
- `transient`: bounded runtime state, socket, or one-shot handshake.

Diagnostic files and environment variables can still be enabled deliberately,
but that run must not be reported as a production performance result.
