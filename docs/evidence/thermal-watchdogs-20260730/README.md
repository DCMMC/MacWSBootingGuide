# Mandatory iPad and MacBook thermal watchdogs — 2026-07-30

## Incident boundary

The prior iPad benchmark session used `--no-watchdog` while a 60,000-fish
native-AGX workload was active. The user reported that the iPad became very hot
and rebooted it. A WindowServer-only CPU guard could not cover work distributed
across the VS Code renderer/GPU processes and the kernel AGX driver. This
milestone therefore makes whole-device thermal telemetry mandatory and removes
the bypass option.

## iPad implementation status

`macwsthermal/main.m` reads the iOS-native `NSProcessInfo.thermalState` plus
`AppleSmartBattery` `Temperature` and `VirtualTemperature`. Its arm64 build
completed locally with the project Theos toolchain. `macos_gui.sh` now requires
an immediate helper handshake before WindowServer startup and samples the
helper once every 300 seconds. The final user-selected policy intervenes only
for an explicitly observed `critical` state. `nominal`, `fair`, `serious`,
numeric temperatures and unreadable samples are recorded without intervention.
`--no-watchdog` returns exit 64.

After the reboot, the known ED25519 host key reappeared at `192.168.1.6`. The
recovery script removed the complete GUI/browser stack; the subsequent process
check found no WindowServer, OSXvnc, VS Code, Chrome, GlassDemo or macwsinputd.
The first stopped-state IOKit sample was:

```text
"Temperature" = 3469
"VirtualTemperature" = 3469
```

Exactly five minutes later, still without starting or building the macOS GUI,
the second sample was:

```text
"Temperature" = 3559
"VirtualTemperature" = 3559
```

That exceeded the conservative numeric limit in the first watchdog draft, so
build/load testing was paused. The user then explicitly selected a
critical-only intervention policy. The signed helper was installed without
starting the GUI and returned this runtime witness:

```text
thermal-state=nominal raw=0 low-power=no battery-temp-centic=3519 virtual-temp-centic=3519 effective-temp-centic=3519 uptime=1726.175
helper_rc=0
```

The current state was therefore `nominal`; the numeric 35.19 C value is logged
but does not intervene. After installing the launcher, a controlled watchdog
invocation with no WindowServer/VNC/Terminal produced:

```text
[macos_gui] watchdog: initial thermal sample: thermal-state=nominal raw=0 low-power=no battery-temp-centic=3439 virtual-temp-centic=3439 effective-temp-centic=3439 uptime=2086.741
[macos_gui] watchdog: armed (temperature every 300s; only critical intervenes; nominal/fair/serious and numeric temperatures are log-only; restarts>=12/45s; runtime cap=disabled)
[macos_gui] watchdog: WindowServer job unloaded (GUI stopped) — exiting.
watchdog_rc=0 no_watchdog_rc=64
macos_gui.sh: --no-watchdog was removed; thermal safety cannot be disabled
```

No PID/ready files or GUI/browser processes remained. This runtime-confirms
the helper, critical-only policy, requested five-minute interval, clean idle
exit and non-bypassable launcher integration without inducing heat.

## MacBook runtime witnesses

The M1 MacBook Air's raw IOKit snapshot showed that the two battery properties
are not interchangeable on macOS:

```text
"Temperature" = 3133
"VirtualTemperature" = 4009
```

The host helper deliberately records physical `Temperature` as its effective
numeric field and keeps `VirtualTemperature` separately. Only the system state
`critical` controls intervention. The compiled probe and mandatory
preflight produced:

```text
2026-07-30 11:30:44 [macbook-thermal] preflight thermal-state=nominal raw=0 low-power=no battery-temp-centic=3129 virtual-temp-centic=3969 effective-temp-centic=3129 uptime=341009.766
```

The supervisor was also run around a child that slept one second and exited 7;
it armed the 300-second interval, reaped the child, and propagated exit 7:

```text
2026-07-30 11:30:54 [macbook-thermal] preflight thermal-state=nominal raw=0 low-power=no battery-temp-centic=3129 virtual-temp-centic=3969 effective-temp-centic=3129 uptime=341019.524
2026-07-30 11:30:54 [macbook-thermal] armed pid=97665 interval=300s command=bash -c sleep 1; exit 7
2026-07-30 11:30:56 [macbook-thermal] command exited rc=7
wrapper_rc=7
```

After changing the intervention policy to critical-only, the final wrapper
produced:

```text
2026-07-30 11:49:17 [macbook-thermal] preflight thermal-state=nominal raw=0 low-power=no battery-temp-centic=3131 virtual-temp-centic=3989 effective-temp-centic=3131 uptime=342122.203
2026-07-30 11:49:17 [macbook-thermal] state=nominal and temperature=31.31 C are log-only
```

These are runtime witnesses for sensor selection, startup sampling, the requested
five-minute interval, and normal child-status propagation. No heat was induced
to test a real thermal trip.

Numeric temperatures remain evidence, not claimed hardware damage boundaries.
Per the final policy, only the independent system state `critical` intervenes.
