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
- The same completed owned BGRA scanout is published to macwsdisplayd through
  the authenticated `com.macwsguide.display.final-composite` Mach service.
  Fullscreen Host imports that IOSurface directly and therefore preserves
  WindowServer-only shadows, backdrop materials and warped animations without
  RFB or the VNC CPU damage scan. This is a production invariant, not a new
  environment/file switch; exact layers remain subscribed for hit testing.
- Production snapshots that final composite through a four-slot same-AGX-queue
  IOSurface ring, with displayd/Host lease use counts preventing producer reuse
  while a consumer owns a frame. `MACWS_FINAL_COMPOSITE_DIRECT=1` is an
  off-by-default diagnostic rollback to the unsafe direct SkyLight surface;
  it must not be used for performance or stability claims.
- WindowServer's native cursor sprite is kept hidden through its verified
  session hide-count contract while its global pointer position continues to
  move. Native menus and Chromium popups therefore retain WindowServer/AppKit
  hover semantics without duplicating Host's circular pointer affordance.
- Validated custom-path apps, generic Catalyst children, and the stock
  UIKitSystem service receive the scoped `MACWS_APP_MOUNT_COMPAT=1` namespace
  contract. UIKitSystem owns the CoreServices repository used while Catalyst
  bundles initialize; without the same logical chroot root its CFURL cache can
  recurse during finalization. Generic Catalyst children also
  receive `MACWS_CATALYST_DIRECT_DRAWABLE=1`: if SkyLight captures their title
  bar but omits a CAMetalLayer client area, libmachook transfers the completed
  drawable's real IOSurface Mach right to the foreground Host. Host validates
  its typed envelope and geometry, imports it as a native Metal texture, and
  composites it over the black client area without RFB, compression, or CPU
  pixel copies. The broad mount diagnostic is explicitly removed from the
  child environment even if the existing Host was started by a debug shell.
- Asphalt additionally enables `MACWS_CATALYST_LOCAL_KEYCHAIN=1`. The stock
  Ventura Security API remains first; only unavailable/MDS results are sent to
  the uid-501 iOS-native `macwskeychaind`, which authenticates Asphalt's exact
  executable and preserves its two original Gameloft Keychain groups. MacWS
  owns no plaintext credential store. At child launch the carrier also probes
  the loopback SOCKS endpoint `127.0.0.1:1082` once: if it is already live,
  Asphalt receives upper/lower-case `ALL_PROXY`, `HTTPS_PROXY` and
  `HTTP_PROXY` values using `socks5h`; otherwise it stays on direct networking.
  This selection does not start a proxy, weaken TLS, or affect another app.
  See
  [`catalyst-keychain-bridge-20260812.md`](catalyst-keychain-bridge-20260812.md).
- VS Code and Chrome set `MACWS_CHROMIUM_COMPOSITE_OVERLAYS=1`. For the exact
  UUID-checked Chromium 148 Electron Framework, this marks the root
  `AggregatedRenderPass` with Chromium's real `video_capture_enabled` field
  before its unmodified `CALayerOverlayProcessor` runs. Chromium then rejects
  process-local CALayer promotion with its native
  `kCALayerFailedVideoCaptureEnabled` result and appends the normal primary
  plane, keeping video in the AGX-composited scanout captured by MacWS/VNC.
  The exact adapter writes that real field using a verified two-instruction
  dataflow rewrite; it does not install a per-frame function trampoline.
- Steam's on-demand job defaults to the download-first CPU UI profile:
  `MACWS_STEAM_CPU_RENDERING=1` and Valve's supported `-cef-disable-gpu`
  switch. At the exact top-level Steam Helper spawn, the process adapter also
  adds Chromium's `--disable-software-rasterizer`,
  `--disable-gpu-rasterization` and `--disable-zero-copy`; games and unrelated
  processes are untouched. This preserves the functionally reliable CPU page
  compositor without allowing the separate SwiftShader/GPU raster path that,
  during an earlier animated download, reached 600,180 resident 16-KiB pages
  before Jetsam reported
  `vm-compressor-space-shortage`. Minidumps then establish that its native
  GPU child was being killed while Crashpad attempted to send the hard-
  immovable task port, after which CEF selected SwiftShader. The exact owner
  of every page in the 9.16-GiB footprint remains unproven. Native AGX remains
  a separately validated opt-in profile, not the default download UI. The iOS kernel
  returns `ENOSYS` for CEF 126's `__sandbox_ms("AMFI", 0x60, ...)` query even
  though task ports are hard-immovable; the exact compatibility result makes
  Chromium use its native no-task-port path. Valve's top-level browser and its
  renderer/network/GPU descendants use atomic `posix_spawn` launch paths, so
  neither the fatal Network/XPC `fork` child nor guarded task-port transfer is
  reached. Steam's `/BSem`, `/Evt` and `/MTX` POSIX names are backed by
  hostd-issued generations and one authoritative hostd counter. Protocol v21
  retains a zero-valued blocking wait's connected AF_UNIX descriptor in FIFO
  order; the client sleeps in `kqueue/EVFILT_READ` until post writes its exact
  reply. Hostd clears inherited `O_NONBLOCK` on every accepted descriptor
  before reading the request; runtime logs proved that leaving it set could
  turn an ordinary pre-data `EAGAIN` into `EPROTO` and break Steam's `/MTX`
  release path. Runtime LLDB captured the event-driven stack, replacing the
  retired 500-us poll which produced roughly 1,000 wakeups/s. `sem_unlink`
  plus same-name
  recreation therefore cannot alias an old Helper handle.
  `MACWS_STEAM_LAUNCH_EPOCH` is generated once by the packaged launch script
  and inherited across the updater/live-client process family; all Steam
  tracing and exit-stop switches remain off.
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

The trust closure is not limited to the main executable or executable mode
bits. Once per iPad boot, production scans the existing `/Applications/*.app`
nested-code trees by Mach-O magic and restores every already-signed
CodeDirectory to Dopamine's reboot-volatile trustcache. It never re-signs that
nested code. Package installation invalidates the boot marker, so a replaced
framework cannot inherit a stale ready witness. This is the cold-start
invariant that restored Amadine Sparkle, Office Forms/ADAL4 and VSCode helper
frameworks after reboot.

The rootfs devfs mount is independently reboot-volatile. Before reporting the
chroot ready, production invokes the iOS-native `mountdevfs` helper and requires
`/var/mnt/rootfs/dev/ptmx` to be a character device. Runtime before this check
showed Terminal's exact `[forkpty: No such file or directory]`; after the
preflight and a process-only relaunch, Terminal owned a live `/bin/bash -i`
child. A valid shell trustcache witness alone is therefore never treated as a
PTY/readiness witness.

Package configuration has a separate non-GUI utility contract. Ventura's
native `codesign` still runs through `launchdchrootexec` so the normal chroot
and dyld interposes apply, but the caller sets `MACWS_UTILITY_PROCESS=1`.
Only GUI, input, Metal and JIT constructors honor that marker; `codesign`'s
real signature validation and exit status are unchanged. Runtime before this
contract aborted in `EnableJIT` while dpkg was half-configured. The repaired
run completed native ad-hoc signing, strict designated-requirement validation,
all 48 Settings extension checks, and left the package `install ok installed`.

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

Steam's Chromium 126.0.6478.183 embeds ANGLE revision `5d4df51` and a distinct
368,459-byte default Metal library (FNV-1a `d3e757cc4a31c3c0`). The package
installs that exact revision's macabi rebuild separately as
`/usr/local/share/macws/angle/angle-default-5d4df51-macabi.metallib` and
selects it only for that byte-exact source container. The replacement is
711,592 bytes with FNV-1a `49a40eb36303a603`; it is never shared with VS Code's
newer ANGLE function set. See
[`steam-agx-memory-20260815.md`](steam-agx-memory-20260815.md) for the runtime
AGX, memory-curve and event-driven semaphore evidence.

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
## MacWS UI performance controls (2026-08-11)

These production controls are independent of `MACWS_RUNTIME_DIAGNOSTICS`:

`MACWS_INPUTLAB_DIAGNOSTICS` is intentionally absent from the shipped InputLab
job. It enables private AppKit boundary traces only in a temporary diagnostic
job; scored runs keep those synchronous logs off.

| Control | Default | Scope | Meaning |
|---|---|---|---|
| `MacWSPerformanceHUDMode` (`NSUserDefaults`) | `0` | each Host Scene | `0` off, `1` compact, `2` full; off has one atomic fast-path check unless an explicit Reset-to-Export recording is active |
| Apple system performance HUD | off | system-wide QuartzCore RenderServer | Control Center toggle uses CAPerfHUD-compatible Full level 5; `com.apple.QuartzCore.debug` is required |
| `macwshost://performance-reset` | explicit | active Host Scene | clears all fixed rings and starts a new measurement generation |
| `macwshost://performance-snapshot` | explicit | active Host Scene | writes `latest.json` and a timestamped bounded archive |
| `macwshost://performance-hud-{off,compact,full}` | off | active Host Scene | changes only the MacWS overlay |
| `macwshost://system-performance-hud-{on,off}` | off | system-wide | selects Apple Full level 5 or clears flag `0x10000000` |
| `macwshost://performance-gesture-{tap,double-tap,right-tap,hover,drag,long-drag,scroll,scroll-momentum,magnify,three-up,three-down,three-left,three-right}` | explicit | active Host Scene | one bounded replay through the production Host controller input boundary |
| `macwshost://performance-gesture-suite` | explicit | active Host Scene | resets, runs every applicable scenario, and exports JSON |

`misc/macws_ui_profile.py` always switches both visual HUDs off before a scored
run, aborts only at Critical thermal state, and uses the fixed thresholds
documented in `docs/ui-performance-profiler-20260811.md`.
