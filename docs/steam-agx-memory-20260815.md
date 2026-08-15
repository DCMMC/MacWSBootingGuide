# Steam native-AGX memory and wakeup repair (2026-08-15)

## Outcome

Steam build `1785799196` now runs its Chromium 126 client shell through the
real iPad AGX stack without the former shader-target failure/GPU restart loop.
The production launch also uses named-semaphore protocol v21: a blocked Steam
Helper sleeps in `kevent` until hostd replies to its retained Unix-stream
request, rather than polling every 500 microseconds.

This is a bounded client-UI result, not a claim that every Steam game is
compatible. It also does not attribute every byte of the historical Jetsam
footprint to one allocator without a heap trace.

## Historical memory-pressure witness

`/var/mobile/Library/Logs/CrashReporter/JetsamEvent-2026-08-15-121442.ips`
reported `vm-compressor-space-shortage`. The old CEF GPU role owned `600180`
resident 16-KiB pages, or 9,833,349,120 bytes (9.16 GiB), while the client had
been launched with the retired software-GPU policy. The surrounding CEF logs
also contained target-incompatible Metal libraries, render pipelines without
a vertex shader, Metal-backend compile failures and GPU-process exits.

Those records prove the pressure event, failed native pipeline creation and
GPU child loss. They do not, by themselves, prove that a single fallback
allocation accounted for all 9.16 GiB; the post-fix memory curve below is the
regression witness.

## Exact Steam ANGLE repair

Steam's shipped CEF identifies itself as Chromium `126.0.6478.183` and embeds
ANGLE revision `5d4df51d1d7d6a290d54111527a4798f10c7ca3c`. Runtime capture from
its real `libGLESv2.dylib` established a 368,459-byte default Metal library
with FNV-1a `d3e757cc4a31c3c0`.

The replacement was rebuilt from that exact revision's official
`mtl_internal_shaders_src_autogen.h` through the real device
`MTLCompilerService`, targeting `air64-apple-ios19.0.0-macabi`:

```text
path   /usr/local/share/macws/angle/angle-default-5d4df51-macabi.metallib
bytes  711592
FNV-1a 49a40eb36303a603
SHA256 4764a117cea2628fd1d524718fa7594af24370fa10bf4fc4737d48488f6542a3
```

`libmachook` substitutes this library only when both the embedded length and
hash match. Chromium 148/VS Code and every unknown ANGLE build keep their own
libraries. Steam Helper source-compile requests are adapted to the macabi
target only for its exact runtime working-directory form. The standalone
asset-builder exception additionally requires the byte-exact source/argument
tuple and `/var/jb/var/mobile/macws_steam_angle_asset_build`; production
preflight removes and rejects that sentinel.

## Native AGX witness

The project's on-device LLDB tool attached to the live production CEF GPU
process and listed these loaded images:

```text
/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU
/System/Library/Extensions/AGXMetal13_3.bundle/Contents/MacOS/AGXMetal13_3
.../Steam Helper.app/.../Libraries/libEGL.dylib
.../Steam Helper.app/.../Libraries/libGLESv2.dylib
```

No `libvk_swiftshader.dylib` image was present. The process command line had
`--disable-gpu-sandbox`, but neither `--disable-gpu` nor a SwiftShader request;
the outer production command used Valve's `-cef-force-gpu`. These are direct
runtime witnesses that this run used Metal/AGX rather than the simulator or
software path.

## Root cause of the remaining high wakeup rate

The earlier production transport kept the correct hostd-owned counter but
rechecked it through a 500-microsecond deadline. The iPad generated:

```text
steam_osx.wakeups_resource-2026-08-15-161632.ips     about 1013 wakeups/s
Steam Helper.wakeups_resource-2026-08-15-161642.ips about  886 wakeups/s
```

LLDB captured the actual Helper thread:

```text
mach_wait_until
MacWSSteamRelativeDelay(microseconds=500)
MacWSSteamSemaphoreConsumeKernelTokenInternal
MacWSSteamSemaphoreConsumeKernelToken
MacWSSteamSemWait
```

This is runtime confirmation that the compatibility layer, rather than a
theoretical Chromium timer, generated the roughly 1-kHz wake path.

## Protocol v21: event-driven FIFO wake

A real-device cross-runtime probe made an iOS-native process write one byte to
an AF_UNIX stream after one second. The chroot macOS peer waited through
`kqueue/EVFILT_READ`:

```text
CLIENT event_filter=-1 event_flags=0x8005 data=1 read=1 reply=0x5a elapsed=1.005181 errno=0
```

Protocol v21 sends a complete operation request before sleeping. For a zero
blocking wait, hostd retains the connected descriptor and request ID in a
FIFO. A post writes one reply to the oldest live descriptor. The client
performs a nonblocking `recv`, then sleeps in level-triggered `EVFILT_READ`;
it re-enters `recv` only after readiness. Counter mutation and
unlink/generation ownership remain serialized on hostd's semaphore queue.

The first v21 package exposed a separate startup race. Five runtime failures
from Helper PID `21574` had the exact host-side form:

```text
Steam semaphore socket request rejected fd=9 read=0 errno=35 peer=21574
magic=0 version=0 op=0 flags=0 generation=0 waiter=0 request=0
```

The matching client envelope contained the correct reply magic/version but
`error=100 (EPROTO)`, `generation=0` and `requestID=0`. This proved that the
listener's `O_NONBLOCK` state was inherited by an accepted socket: hostd could
run its first fixed-size request read before the client bytes arrived and
mistake the ordinary `EAGAIN` for a malformed request. Hostd now clears
`O_NONBLOCK` on every accepted descriptor before the read; the existing
five-second `SO_RCVTIMEO` still bounds a stalled peer. This repairs the
transport invariant upstream. It does not suppress Steam's resulting mutex
error.

After deployment, LLDB captured the real Browser wait thread as:

```text
kevent
MacWSSteamSemaphoreBrokerSocketValue
MacWSSteamSemaphoreConsumeKernelTokenInternal
MacWSSteamSemaphoreConsumeKernelToken
MacWSSteamSemWait
```

The old `mach_wait_until(500)` frame was absent. This is the root-fix witness,
not merely a reduction in log volume.

## Bounded production regression

Production PID family `67512`/`67602`/`67633` used protocol 21 and all native
AGX switches. Thermal intervention remained `critical`-only.

| Elapsed | Steam-family RSS | Aggregate CPU | GPU RSS / CPU | Result |
|---:|---:|---:|---:|---|
| 1m28s | 1,546.5 MiB | 68.4% | 131.8 MiB / 12.2% | startup/UI population |
| 4m40s | 1,328.4 MiB | 3.8% | 129.5 MiB / 0.0% | idle login client |
| 10m04s | 1,340.6 MiB | 3.8% | 130.0 MiB / 0.0% | bounded soak complete |

During this interval there were zero new Jetsam or wakeups-resource reports,
and zero new occurrences of the four historical shader/GPU-restart strings:

```text
Target OS is incompatible
Render pipeline without vertex shader is invalid
Internal error compiling shader with Metal backend
GPU process exited unexpectedly
```

The family RSS remained 206 MiB below the startup sample after ten minutes
instead of reproducing the old unbounded 9.16-GiB GPU-role growth. The thermal
state briefly logged `serious`, returned to `nominal`, and never reached the
only intervention state, `critical`. Longer game/download workloads remain a
separate regression target.

### Final package regression after the accepted-socket fix

The package-installed production job (diagnostics absent) used PID family
`43273`/`43354` and native-AGX GPU PID `43390`. A fresh LLDB image list again
showed `IOGPU`, `AGXMetal13_3`, Steam `libEGL` and `libGLESv2`, with no
`libvk_swiftshader`. LLDB also captured Browser thread 27 blocked in:

```text
kevent
MacWSSteamReadAll
MacWSSteamSemaphoreBrokerSocketValue(operation=5)
MacWSSteamSemaphoreConsumeKernelTokenInternal
MacWSSteamSemWait
```

The final production memory curve excluded an unrelated 12-hour-old set of
already-exiting (`UE`/`?E`) Helper PIDs; those processes had zero CPU and
could not be reaped even with `SIGKILL`, and the iPad was deliberately not
rebooted.

| Elapsed | Current launch RSS | Aggregate CPU | Result |
|---:|---:|---:|---|
| 1m11s | 1,526.9 MiB | 75.9% | startup/UI population |
| ~2m | 1,519.3 MiB | 49.9% | renderer settling |
| 3m19s | 1,496.2 MiB | 16.2% | bounded |
| ~4m | 1,497.1 MiB | 20.7% | bounded |
| 5m33s | 1,499.5 MiB | 15.1% | bounded soak complete |
| 9m22s | 1,295.7 MiB | 13.7% | post-LLDB idle convergence |

There were zero accepted-socket rejects after the fix, zero `EPROTO` or
`Fatal on Release`/`Wait() failed` messages, zero historical shader/GPU error
strings, and no new Jetsam, crash or wakeups-resource report. The iPad's last
sample during the run was `nominal` at 35.69 C; the critical-only watchdog did
not intervene.

## Production switch state

Enabled for Steam: `MACWS_AGX_NATIVE=1`,
`MACWS_AGX_REGISTER_CLASSES=1`, `MACWS_PIN_FALLBACK=1`,
`MACWS_JIT_MPROTECT_COMPAT=1`, `MACWS_JIT_FAULT_WRITE_COMPAT=1`,
`MACWS_AMFI_IMMOVABLE_TASK_PORT_COMPAT=1`, and
`MACWS_CRASHPAD_IMMOVABLE_TASK_PORT_COMPAT=1`.

Disabled/absent in production: `-cef-disable-gpu`,
`MACWS_STEAM_SEM_DIAGNOSTICS`, compiler diagnostics, the Steam ANGLE asset
builder sentinel, allocator tracing, Mach/XPC tracing, shader dumps and crash
stops.
