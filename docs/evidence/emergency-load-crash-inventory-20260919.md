# Bounded emergency load / crash inventory

Status: **measured observations, not a heat fix or stability claim**.
After the user reported heat, repeated crashes, and incorrect Shanghai Weather
colors, all agent builds, GPU probes, debugger sessions, and scripted UI tests
were paused. The investigation below used native read-only process counters,
file metadata, existing crash reports, and launchd state. No app or service was
killed, restarted, suspended, resigned, or reconfigured for this inventory.

## Current workload, not an idle benchmark

The two `/bin/ps` cumulative CPU snapshots span 15.062 seconds, Unix timestamps
1789810926.269794 to 1789810941.332041. The raw receipt is
`/tmp/macws-emergency-native-snapshot-20260919.json`. Reported percentages are
CPU-time deltas divided by wall time, expressed as a fraction of **one core**;
they are not the lifetime `%cpu` field.

| Live process | PID | CPU seconds during interval | One-core percentage |
| --- | ---: | ---: | ---: |
| Weather | 17270 | 1.69 | 11.22% |
| WindowServer | 16900 | 0.91 | 6.04% |
| Finder | 17058 | 0.58 | 3.85% |
| ControlCenter | 17064 | 0.56 | 3.72% |
| MacWSHost | 8881 | 0.53 | 3.52% |
| sharedfilelistd | 16855 | 0.33 | 2.19% |
| macwsdisplayd | 17003 | 0.16 | 1.06% |
| macwshostd | 8928 | 0.04 | 0.27% |
| OSXvnc-server | 17142 | 0.04 | 0.27% |

The user/main agent could still be interacting with Weather during this
emergency observation. PowerPoint and Activity Monitor were also live. This
is not an equivalent idle before/after workload, does not measure GPU energy,
and cannot establish or refute the cause of the reported device heat.

Of ten specifically sampled existing output logs, `WindowServer.err` grew
214 bytes and `macwsdisplayd.err` grew 290 bytes; the other eight did not grow.
The new text described one final-composite catch-up request and successful
publication. Thus these particular files were not a high-volume log flood in
this interval. That is not an audit of every possible log or every hot path.

## Confirmed recurring macOS locationd crashes

The process snapshots observed locationd PID 19162 disappear. The subsequent
read-only explicit-domain query is retained at
`/tmp/macws-emergency-locationd-launchd-20260919.log`:

```
user/501/com.macwsguide.macos-locationd = {
    state = spawn scheduled
    program = /var/jb/usr/macOS/PrivateFrameworks/CoreLocation.framework/XPCServices/LocationdProxy.xpc/LocationdProxy
    minimum runtime = 80
    runs = 105
    successive crashes = 98
    last terminating signal = Bus error: 10
```

This is concrete crash-loop evidence, not an inference from a single process
exit. The native iPadOS locationd (PID 357) is a separate process and remained
present. The precise MacWS-owned job was not stopped by this inventory.

The existing report copied to
`/tmp/macws-locationd-emergency-20260919.ips` has capture time
`2026-09-19 16:47:44.6057 +0800`, process `locationd`, PID 12065, macOS platform
1, and injected libmachook UUID `2BE0AD84-7995-373F-84F4-D38FB0583AE1`.
Its file modification time was later, so **mtime must not be used as the crash
time or to blame the later IOSurface candidate**. Its actual exception is:

```
EXC_BAD_ACCESS
SIGBUS
KERN_PROTECTION_FAILURE at 0x000000017017bf00
termination namespace=SIGNAL code=10 indicator="Bus error: 10"
```

The faulting thread repeatedly contains:

```
__CFBasicHashDrain
_CFRelease
_FileCacheReleaseContents(__FileCache*, unsigned char, unsigned char, unsigned char, unsigned char)
_FileCacheFinalize(void const*)
_CFRelease
__CFURLDeallocate
_CFRelease
```

This directs investigation toward actual FileCache lifetime/namespace state;
similarity to the earlier Preview failure is not proof of an identical cause.
Current locationd logs also contain duplicate-class messages and failed
`com.apple.systemadministration.writeconfig` lookups, but those messages alone
do not prove the SIGBUS cause. A current-generation fault witness is still
needed before selecting the repair.

## Separate WLAN watchdog report

`/tmp/macws-wlan-emergency-20260919.ips` is a native DriverKit report at
`2026-09-19 17:26:51.6130 +0800`, PID 402, for
`com.apple.DriverKit-AppleBCMWLAN`. It reports `EXC_CRASH / SIGABRT` with:

```
AppleBCMWLANCore::handleDextWatchdogTimer(IO80211TimerSource*) (.cold.1)
AppleBCMWLANCore::handleDextWatchdogTimer(IO80211TimerSource*)
panic
abort
```

There is no established connection from that report to the GPU adapter, the
Weather color symptom, or a MacWS rendering change. It must not be silently
counted as a newly proven macOS application crash.

## Python observation left unclassified

Before the emergency pause, one requested minimal CLI test ran
`/opt/local/bin/python3 --version` through the ordinary `run_bash.sh` launcher
with an explicit macOS PATH. `/tmp/macws-python-minimal-20260919.log` records:

```
chdir: No such file or directory
[launchdchrootexec] target=/bin/bash arch=arm64e insert=/usr/local/lib/libmachook.dylib
/bin/bash: line 1: 18895 Killed: 9               /opt/local/bin/python3 --version
```

No signing/retry experiment was run afterward. Signal 9 alone does not prove
an AMFI, trust-cache, resource-pressure, or dyld cause. That diagnosis remains
open pending the actual rejection evidence.

## Exact crash-loop containment and namespace route controls

At 17:53 the main agent separately booted out only
`user/foreground/com.macwsguide.macos-locationd`, after observing runs 107,
successive crashes 100, and last signal 10. The job was then absent. Native
iPadOS locationd 357 and user-facing WindowServer/Weather/PowerPoint were
unchanged. This was containment, **not a repair or a permanent disable**.

The macOS crash report explicitly places the fault address in its thread's
`STACK GUARD` region (`170178000-17017c000`), and retains 511 repeated release
frames. This proves recursive cache destruction exhausted that stack; the
old report alone does not identify the original cache-building caller.

Source inspection identified an inconsistent chroot entry contract:
`launchdchrootexec/main.m` supplies the canonical `MACWS_CHROOT_HOST_ROOT`
metadata before chroot, but the shared `ViewBridgeChrootProxy/main.c` did not.
`macws_initialize_chroot_mount_namespace` requires that real root metadata
before installing the filesystem/CoreServices namespace adapters. This is
process namespace data, **not an optional feature/debug flag**.

Three authorized serial controls used one five-second-alarm, non-GUI,
non-Metal process each. They called real `statfs`, CoreFoundation resource
queries, and Objective-C URL resource queries, then normally drained their
own autorelease pools. Raw copied stdout/stderr and exact commands are in
`/tmp/macws-proxy-namespace-controls-20260919.log`. The probe source is
`/tmp/macws_proxy_namespace_probe.m`; the two diagnostic proxy sources and
their reviewable diff are `/tmp/macws_namespace_{original,candidate}_route.c`
and `/tmp/macws-proxy-namespace-diagnostic.diff`.

| Entry route | PID | Host root metadata | `statfs("/").f_mntonname` | C and ObjC root parent |
| --- | ---: | --- | --- | --- |
| Ordinary `launchdchrootexec` | 21152 | `/private/var/mnt/rootfs` | `/` | nil |
| Original shared proxy, only final target replaced by the witness | 21637 | absent | `/private/var` | `/private/var/mnt` |
| Proxy with actual root-FD `F_GETPATH` producer | 21771 | `/private/var/mnt/rootfs` | `/` | nil |

All three exited zero; file-volume URL was `/` in all three. Thus the negative
control **proves the original proxy exposed a host-namespace root parent**,
not that this tiny probe reproduced locationd's full recursive crash. Actual
locationd startup plus completed client protocol replies still must be tested
before claiming the service crash loop fixed.

The candidate shared producer queries the kernel's real canonical root vnode
path while still outside chroot. It rejects open/query/nonterminating failures,
correctly translates Darwin raw syscall carry/errno, closes only a successfully
opened descriptor, replaces inherited stale root metadata, and preserves all
one-shot XPC environment values. Oversized environments now fail explicitly
instead of silently truncating trailing XPC data. The focused tests execute
the actual production environment-building block and check boundary capacity,
stale metadata replacement, original XPC bytes, real arbitrary vnode paths,
and failure cleanup. No statfs string fabrication or feature flag is added.

An additional evidence correction: although the shared proxy source comment
claims no libSystem dependency, `otool -L` on the actual deployed
`LocationdProxy` shows `/usr/lib/libSystem.B.dylib`, matching its current
Makefile's `-lSystem`. This change preserves that deployed link behavior;
it does not claim to repair or experimentally alter the separate one-shot
libxpc initialization contract.

### Actual locationd candidate acceptance

After review, only the exact `LocationdProxy` executable was atomically
replaced. The old inode was retained for rollback; no other proxy, user
application, native location service, WindowServer, or system job was changed.
Receipt: `/tmp/macws-locationd-namespace-install-20260919.json`.

| Artifact | SHA-256 | Inode |
| --- | --- | ---: |
| Old LocationdProxy | `627981e6befae7bfbec3b4a05c5a12c72934fdf90a2e162cad0929f8345ce798` | 1705748 |
| Candidate LocationdProxy | `49fa7f56759dd2131469bc7a08da4726e6bc69eb823fabfd0dcb14ed908822c3` | 1706214 |

The original manifest was bootstrapped normally into `user/foreground`.
It initially reported `runs = 0`, `state = not running`; no empty kickstart
was used to fake readiness. The subsequent real macOS CoreLocation query
used its own five-second deadline and did not request location updates,
change authorization, or log coordinates. It completed normally:

```
macos-location-status pid=23247 begin
macos-location-status services-enabled=1 returned
macos-location-status host-authorization=0 selector=1 returned
macos-location-status normal-return
```

`0` is the returned authorization status, not a manufactured authorization
grant. The actual macOS locationd was PID 23153. Every one of 22 follow-up
samples spanning 22.22 seconds reported:

```
state = running
runs = 1
pid = 23153
last exit code = (never exited)
```

There was no new output in its exact log during that interval. The observer
was prepared to boot out only this job immediately if SIGBUS or a successive
crash appeared; that failure branch did not run. Full probe stderr and raw
launchd observations are in `/tmp/macws-locationd-acceptance-20260919.json`.
This closes the bounded actual-daemon startup/query test in addition to the
namespace API controls. It is not an all-app graphics/heat fix, nor a claim
that an uptime counter alone establishes unlimited long-term stability.
All consumers of the shared proxy source still need the coherent final
package, rather than leaving this single live candidate as the final product.

## Read-only follow-up at 20:31 (same boot)

The later bounded inventory used two native process snapshots, a fresh thermal
query at each sample, an explicit locationd launchd-state query, and top-level
crash-directory metadata only. Raw receipt:
`/tmp/macws-load-crash-followup-20260919.json`. The sample timestamps are
`2026-09-19T12:31:26.631477+00:00` and
`2026-09-19T12:31:36.903432+00:00` (20:31 local), 10.272 seconds apart.
The main agent was performing an **owned PowerPoint rendering acceptance**;
this was not a controlled idle measurement or a heat-fix acceptance test.
There were no service/app restarts, attachments, UI actions, filesystem
cleanup, recursive directory scans, or binary changes by this observer.

Both locationd observations retained the original successful candidate PID:

```text
state = running
runs = 1
pid = 23153
last exit code = (never exited)
```

Its elapsed time advanced from `02:10:23` to `02:10:33`. Combined with the
earlier completed CoreLocation query, this is evidence that the **previously
observed recurring locationd crash loop had not recurred in this generation**
by this check. It is not a substitute for all protocol, app, or GPU tests.

CPU-time deltas below are divided by the measured wall interval and expressed
as a percentage of one CPU core, not `ps`'s lifetime `%cpu` column:

| Process | PID | CPU seconds | One-core percentage |
| --- | ---: | ---: | ---: |
| ControlCenter | 17064 | 0.50 | 4.87% |
| Finder | 17058 | 0.45 | 4.38% |
| sharedfilelistd | 16855 | 0.24 | 2.34% |
| WindowServer | 16900 | 0.24 | 2.34% |
| Weather | 27054 | 0.19 | 1.85% |
| Activity Monitor | 18846 | 0.15 | 1.46% |
| macOS locationd | 23153 | 0.05 | 0.49% |
| macwshostd | 8928 | 0.04 | 0.39% |
| OSXvnc-server | 17142 | 0.04 | 0.39% |
| User PowerPoint (untouched) | 19000 | 0.03 | 0.29% |
| Owned test PowerPoint | 36001 | 0.03 | 0.29% |
| macwsdisplayd | 17003 | 0.03 | 0.29% |
| MacWSHost | 8881 | 0.01 | 0.10% |

All listed PIDs and executable paths matched between samples. In particular,
WindowServer 16900, Host 8881, Weather 27054, and user PowerPoint 19000 were
not replaced during this interval. Short-lived native `livefileproviderd`,
`sleep`, and the observer's `ps` PIDs changed; disappearance alone is not
classified as a crash. Many native system processes report zero
CPU counters through this `ps` interface, so these data are not a total-device
CPU or energy measurement.

The fresh, independently executed thermal queries returned:

```text
thermal-state=nominal raw=0 low-power=no battery-temp-centic=3079 virtual-temp-centic=3079 effective-temp-centic=3079 uptime=26833.303
thermal-state=nominal raw=0 low-power=no battery-temp-centic=3089 virtual-temp-centic=3089 effective-temp-centic=3089 uptime=26843.590
```

That is nominal state and 30.79→30.89 °C in this brief interval, not a GPU
power measurement or evidence that every cause of the user's heat concern
has been resolved.

Crash inventory scope and results:

- `/var/mobile/Library/Logs/CrashReporter`: 1740 direct regular files; directory
  mtime and the latest 12 filename/mtime/size entries were identical in both
  samples. The latest remained `locationd-2026-09-19-164746.ips`, mtime
  `2026-09-19T09:45:52.268996+00:00`, 70185 bytes, followed by the already
  documented WLAN report. As established above, that locationd mtime is not
  its capture time and does not indicate a new crash at 20:31.
- `/var/mnt/rootfs/Library/Logs/DiagnosticReports`: zero direct regular files,
  directory mtime unchanged.
- `/var/root/Library/Logs/CrashReporter` and
  `/var/mnt/rootfs/var/root/Library/Logs/DiagnosticReports`: absent in both
  samples, explicitly recorded as missing rather than treated as inspected.

No subdirectories or alternative crash stores were traversed. Thus the result
is **no new report metadata within this bounded scope**, not a claim that an
application cannot fail without generating a report.

## 21:28 follow-up during owned Office testing

`/tmp/macws-office-crash-followup-late-20260919.json` contains two more
read-only samples, 13:28:27.513 and 13:28:37.780 UTC. Locationd remained PID23153,
`runs = 1`, `last exit code = (never exited)`. The same bounded crash-directory
inventory still had 1740 reports, identical latest metadata and no new report;
the previously absent directories were still explicitly reported absent.
Both thermal observations were `thermal-state=nominal` with the returned
battery/virtual/effective temperature 3439 centi-degrees (34.39 C). Testing was
ongoing, not idle; these data do not establish GPU energy use or eliminate
all possible heat causes. No crash loop was observed within this scope.
