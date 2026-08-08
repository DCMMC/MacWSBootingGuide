# Maps cold location and native Desktop creation (2026-08-09)

## Scope

This milestone addresses two cold paths that were still independently
reproducible after the native three-finger gesture work:

1. Maps could load tiles after a fresh GUI generation but never acquire the
   device location.
2. Mission Control's real `+` button terminated WindowServer while creating a
   new Desktop.

Neither path is replaced with Host UI. Maps still consumes Ventura
CoreLocation, and Desktop creation still belongs to Dock, SkyLight, and
CoreAnimation.

## Maps: readiness must mean an actual provider update

LLDB on the exact Ventura binaries established the capability chain:

```text
-[MKLocationManager isLocationServicesPossiblyAvailable:]
  -> GEOIsDeviceLocationServicesCapable
  -> +[CLLocationManager locationServicesCapable]
```

On the iPad, the last call returned false before Maps registered its normal
location consumer even though the separate, unmodified Ventura
`CLLocationManager` in `macwsinteropd` subsequently received real provider
updates. The old launch ordering treated a live bridge process as sufficient;
on a cold generation Maps could perform and cache its capability decision
before the first update arrived.

The repair makes the real callback the invariant:

- `macwsinteropd` writes `/private/tmp/macws_location_provider_ready` only
  from `locationManager:didUpdateLocations:` and stores its own PID.
- The Maps-only capability adapter first calls Apple's original
  `+locationServicesCapable`. It upgrades a false result only if the marker PID
  is live and `proc_pidpath` identifies the exact interop executable.
- `MacWSCatalystLauncher` verifies the same process-bound witness before it
  starts Maps. The foreground-Host helper waits for at most 30 seconds; the
  UIKit carrier retries asynchronously without blocking its main run loop.
- Both ordinary teardown and WindowServer-dependent recovery delete the
  readiness marker. Maps and its carrier PID are also retired with the old CGS
  generation, so neither a stale file nor a live process with a dead CGS port
  can satisfy a later cold launch.
- Maps receives its real Ventura container Data directory through
  `CFFIXED_USER_HOME`, eliminating the non-persistent CFPreferences domain
  inherited from the UIKit carrier.

The runtime witness produced by the repaired interop generation is:

```text
MACWS-INTEROP Ventura location provider readiness published
MACWS-INTEROP Ventura CLLocationManager output ready
```

No coordinate is stored in the readiness file or committed as evidence.

## Desktop creation: a tenth QuartzCore target mismatch

The input route was first separated from the SkyLight mutation. Calling
`CGSSpaceCreate` through the bounded `macwsworkspacectl create-space`
diagnostic created a real third managed Space while the existing WindowServer
and Dock PIDs remained alive. Selecting an existing Desktop through the same
global input path also changed the current Space. These witnesses ruled out a
generic CGS-create failure and a coordinate-routing failure.

The exact physical-UI-equivalent reproduction was then:

1. send Dock's native continuous three-finger-up gesture;
2. move the global pointer to the expanded Spaces strip;
3. click the native `+` button.

The read-only render-pipeline observer captured the last failing descriptor:

```text
label=com.apple.coreanimation.draw.Pw40aXm_Tsb3A2Xhf_Isrc
vertex=downsample_blur_vert_lph
fragment=single_pass_blur_3_lph
result=0x0
errorDomain=AGXMetal13_3
errorCode=3
description=Target OS is incompatible.
```

WindowServer then exited with launchd's recorded reason
`OS_REASON_COREANIMATION`. This is runtime confirmation that the crash was not
caused by the gesture bridge or Dock's Desktop model: creation reached a new
Ventura QuartzCore shader that the iOS-native AGX compiler rejected.

The existing compatibility architecture was extended at the upstream shader
boundary. `postinst.sh` now retargets only
`single_pass_blur_3_lph`, in addition to the nine previously confirmed
functions, into the secondary macabi library. The system QuartzCore library
remains the process-wide default; the original function name and real function
constants are forwarded to the secondary copy, and the real AGX compiler and
pipeline validators remain enabled.

The ten-function artifact is deterministic:

```text
bytes=1047456
sha256=4a1fceb931d8b0f2a67ae13a9c9f17e928cccc04af67e86bfbff2564dbf63e08
fnv1a64=cd2dd4b299540c07
```

Provisioning is handled by the focused
`ensure_quartzcore_compat.sh` helper. Both the complete rootfs repair and
dpkg's package post-install path call it. A matching hash exits immediately;
an old nine-function artifact is rebuilt and atomically replaced before the
first GUI start. This matters on upgrades where every executable trust
sentinel remains valid and would otherwise give startup no reason to run the
large general repair script. Production cold-start preflight performs the same
cheap 1-MiB hash check, covering a restored rootfs snapshot independently of
package state.

`macwsworkspacectl create-space` remains an explicit diagnostic/repair
primitive only. Production three-finger gestures and the `+` button continue
to use Dock's native implementation.
