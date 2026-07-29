# Audited one-click native-AGX production profile — 2026-07-30

This milestone makes the validated native-AGX coexistence stack the ordinary
startup path and gives every source-controlled runtime switch an explicit
production state.  It does **not** claim that the remaining WindowServer CPU,
RFB latency, or Chromium presentation pacing is solved.

## Reproducible entry point

The deployed one-click command is:

```text
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production
```

Plain `start` has the same defaults.  Native AGX, the validated command ABI,
cancelled-swap completion, owned Retina scanout, system-wide VNC input and
low-cost RFB compression are on.  `--experimental` remains a compatibility
alias; `--no-experimental` is an explicit control.  Production refuses
`--diagnostics`.

`macos_gui.sh switches` prints the configured launch environments and the
actual state of every file sentinel.  The device-side audit during this run
reported:

```text
profile defaults: AGX-native=ON compatibility=ON diagnostics=OFF mode=coexist
/tmp/macws_kcmd_fix                              actual=ON
/tmp/macws_kcmd_wrapped_fix                      actual=ON
/tmp/macws_cancel_completion                     actual=ON
/tmp/macws_vnc_share                             actual=ON
/tmp/macws_owned_scanout                         actual=ON
/tmp/macws_coexist_pace_us                       actual=ON
```

All 33 diagnostic/A-B sentinel paths printed `expected=OFF actual=OFF`.
The active WindowServer launch environment was exactly:

```text
CA_DISABLE_SWAP_ICC=1
CA_VSYNC_OFF=1
MACWS_AGX_NATIVE=1
MACWS_AGX_REGISTER_CLASSES=1
MACWS_PIN_FALLBACK=1
```

The generated VNC job contained only the two production-specific variables
`MACWS_VNC_LOW_LATENCY_COMPRESSION=1` and `MACWS_VNC_NATIVE_ALL=1`.
`MallocScribble`, implicit Terminal XPC tracing, submit recorders and all
documented trace variables were absent.

## Inventory and static enforcement

[`runtime-switches.tsv`](../../runtime-switches.tsv) is the machine-readable
source of truth.  It currently records 138 environment variables, flag files,
sockets and bounded artifacts, including whether each is on, off, automatic
or transient in production.  The source audit completed with:

```text
runtime-switch audit OK: 79 source/plist env names, 39 source flag files, 138 total recorded entries
```

The audit scans source `getenv()` calls, source `/tmp/macws_*` file gates and
launch-plist environments, and fails when a new switch has no manifest row.
`bash -n`, `plutil`, `git diff --check`, an O2 libmachook build and the full
on-device package/install/postinst flow also completed successfully.

## Runtime smoke evidence

The production preflight and first-frame handshakes were runtime-confirmed:

```text
[macos_gui] PRODUCTION-PREFLIGHT: native AGX required; diagnostics/env traces/dump sentinels OFF.
[macos_gui] WindowServer graphics ready (pid=835, clean producer observed).
[macos_gui] VNC: Retina first frame ready (WindowServer pid=835, generation=1785428502).
diagnostic_flags_on=0
xpc_trace_lines=0
submit_artifacts=0
thermal-state=nominal raw=0 low-power=no
```

The captured RFB desktop was 2388x1668 with 42.880% non-black pixels and SHA-256
`6286cb663d91479083d58f1a2c977b34b4d9f0a7cb2389682756f15c922c4162`.
Terminal and the Retina menu bar were visible.  A live sample still showed
WindowServer at 45–53% CPU while the desktop was otherwise idle.  That is the
next measured bottleneck; it is explicitly not hidden by this milestone.
