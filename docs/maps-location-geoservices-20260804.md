# Maps CoreLocation and GeoServices bridge (2026-08-04)

## Scope and current state

This milestone keeps both Ventura protocols intact while moving only the
hardware-facing work to iPadOS:

- iPadOS `CLLocationManager` acquires the real device location.
- Ventura `locationd` remains the authorization, filtering and client-delivery
  authority for Ventura applications.
- Ventura `com.apple.geod` remains the GeoServices endpoint for Ventura Maps;
  it is isolated from iPadOS 16's wire-incompatible service under
  `com.apple.macosbooter.geod`.

The native provider, version-neutral scalar transport, Ventura reconstruction,
GeoServices isolation and MapKit capability adapter are implemented. The
2026-08-05 production-coexistence validation showed populated map tiles and a
live current-location marker in Ventura Maps. Stock Ventura `locationd` sent
each bridged fix to `com.apple.Maps`; no private MapKit result or availability
check is forced.

## Why the stock Ventura provider cannot locate the iPad

Maps authorization was first changed through Ventura's real
`CLLocationInternalServiceProtocol`; the synchronous endpoint reported Maps as
authorized. Pressing Maps' location button then produced the following stock
provider errors:

```text
Apple80211 IOServiceOpen failed (0xe00002bc)
WifiService, interface invalid
This Mac cannot determine your current location because it does not have Wi-Fi.
```

This is runtime evidence that authorization succeeds but Ventura's Wi-Fi
provider cannot attach to the iPadOS Apple80211 user client.

## Maps' additional MapKit preflight

After the scalar provider began delivering valid fixes, Maps still did not
register as a Ventura location client. Its location toolbar action instead
showed the same no-Wi-Fi alert before requesting a location. This is a second,
application-side gate rather than a failure of the provider bridge.

RE of the exact Ventura Maps arm64e image
(`607991F6-FAAE-3B9A-8B44-7526DFD48798`) confirmed the call flow:

```text
-[MacChromeViewController tapLocateMe:]
    setUserTrackingMode:1 animated:1
    _showLocationServicesAlertIfNeeded

-[MacChromeViewController _showLocationServicesAlertIfNeeded]
    [[MKLocationManager sharedLocationManager]
        isLocationServicesPossiblyAvailable:&error]
```

The MapKit implementation preserves authorization and provider checks, then
uses `isWiFiDisabledBlockingLocation`. That method consults
`__MKLocationManagerCanMonitorWiFiStatus` and `_MKWiFiObserver.isWifiEnabled`.
The specific no-Wi-Fi text is selected only when monitoring is enabled but the
observer reports false.

Maps itself enables that Mac-only capability. `RE-confirmed via Maps arm64e
+0x378d80`: `-[MapsAppDelegate _setupSharedLocationManager]` sends
`setCanMonitorWiFiStatus:YES` immediately before creating the shared manager.
A live LLDB breakpoint at
`-[MKLocationManager isLocationServicesPossiblyAvailable:]` then found the
manager's `_wifiObserver` ivar (`+0x148`) was nil. This explains the exact
failure without inferring it from the alert text.

The production adapter therefore acts at the platform declaration, not at the
final availability check. In the Maps process only, `libmachook` preserves the
original MapKit setter but supplies `NO` for Mac CoreWLAN monitoring. The
independent iPad CoreLocation provider remains authoritative; MapKit's real
authorization, restricted/denied, provider-readiness and delivery paths remain
unchanged. No location result or Wi-Fi state is fabricated.

## The first bridge failed at the object ABI boundary

Ventura's real `CLSimulationControllerAdapter` is exposed on
`com.apple.locationd.simulation`. RE of Ventura locationd's Objective-C
metadata confirmed the selectors, entitlement check and allowed classes:

```text
appendSimulatedLocations:
clearSimulatedLocations
setLocationDeliveryBehavior:
setLocationRepeatBehavior:
setLocationInterval:
startLocationSimulation
```

The first bridge sent an iPadOS 16 `CLLocation` directly over NSXPC. The server
accepted the class and method, but its next decoded object was invalid:

```text
Reveived daemon-side request to append simulated location
next location ... rawLat=0 ... lon=0 ... timestamp=-1 ...
horizontalAccuracy=-1 ... fromSimulationController=false
```

This runtime artifact rules out a missing selector or entitlement. The same
class name crosses NSXPC, but its private keyed archive is not compatible
between iPadOS 16 and Ventura 13.

## Production architecture: scalar transport, native reconstruction

`macwslocationd` now sends only finite, range-checked scalar fields through the
existing `com.macwsguide.interop` Mach service. It does not manufacture a
location. `macwsinteropd`, already running inside the Ventura chroot, validates
the scalars again and creates the `CLLocation` with Ventura's own
`CoreLocation.framework` before invoking the stock simulation protocol.

The transport includes coordinate, altitude, horizontal/vertical accuracy,
course, speed, timestamp, location type, reference frame and raw reference
frame. Floating-point fields use their bit-exact IEEE-754 representation inside
XPC uint64 values so no private Foundation archive is shared across OS
releases. The three private metadata fields are copied only after both sides
validate the exact `CLClientLocation` ABI described below.

Runtime witnesses after deploying the two-stage bridge:

```text
[macwslocationd] native effective client=com.macwsguide.host authorization=3
[macwslocationd] delivered native fix #7 accuracy=52.0m age=0.0s
MACWS-INTEROP submitted Ventura-native location #7 accuracy=52.0m
```

The native helper acts as the installed `com.macwsguide.host` application. A
dedicated uninstalled identifier was rejected verbatim by iPadOS locationd as
an attempt to masquerade as an uninstalled app; borrowing Maps' When-In-Use
identity stopped delivery when Maps left the foreground. The Host identity is
granted `AuthorizedAlways` through the stock entitled CoreLocation API.

## Preserving CoreLocation provider metadata

The public scalar `CLLocation` initializer reconstructs coordinates and
accuracy but resets private provider metadata. Runtime before the final fix
showed Ventura `locationd` accepting every simulated fix and then dropping it:

```text
{"msg":"WARN: location dropped due to referenceFrame", "referenceFrame":"Unknown"}
```

This was not repaired by bypassing that filter. The actual iPadOS provider
metadata is now preserved at the existing private value boundary.

RE-confirmed on the target's iPadOS 16.3 and Ventura 13.4 CoreLocation images:

- `-[CLLocation clientLocation]` returns a 176-byte private value.
- `-[CLLocation initWithClientLocation:]` consumes the same 176-byte value with
  8-byte alignment.
- the location type is at result offset `0x60`;
- `-[CLLocation referenceFrame]` reads internal offset `0x8c`, and the getter
  exports reference frame/raw reference frame at result offsets `0x84`/`0x88`.

The native helper extracts those fields only when the method signature, size,
alignment and public private-accessor witnesses agree. The Ventura helper
patches a Ventura-created `CLClientLocation`, calls Apple's stock private
initializer, then reads the object back and verifies all three fields. Any ABI
drift fails closed instead of submitting a malformed fix.

Final bounded runtime validation after deploying the production binaries:

```text
@ClxSimulated, Fix                                      => 10
Sending location to client ... com.apple.Maps          => 10
location dropped due to referenceFrame                 => 0
referenceFrame ... Unknown                             => 0
```

The same log records the accepted symbolic metadata as `type=WiFi` and
`referenceFrame=WGS84`, while the VNC framebuffer shows the blue current-
location marker. A later `location is simulated, rejecting` message still
appears for another internal path, but it occurs after stock locationd has sent
the same fix to Maps and therefore is not the Maps delivery gate.

Production logs intentionally omit coordinates. The location-sensitive VNC
capture used for the final visual witness is not checked into the repository.

## Ventura locationd process compatibility

Two independent crashes were fixed at their upstream ownership boundaries:

- `runtime-confirmed via locationd-2026-08-05-115107.ips`: retaining parsed
  CoreTypes property-list strings in a cross-image `CFSet` faulted in
  `CFHash -> CFSetAddValue`. The allow-list now converts declarations to owned
  UTF-8 strings while the property list is alive and uses exact byte equality;
  it does not invent a type or return a constant object.
- `runtime-confirmed via locationd-2026-08-05-115330.ips`:
  `CLInternalServiceSilo` recursively finalized CoreServices `FileCache`/CFURL
  objects after `statfs` escaped the chroot mount namespace. Ventura locationd
  now opts into the same logical-root filesystem metadata adapter already used
  by Finder and LaunchServices. iPadOS's native locationd never loads the
  adapter.

After both repairs the same Ventura locationd process remained alive throughout
the final Maps validation and its provider/client counters continued advancing.

## Ventura locationd lifecycle adaptation

Ventura locationd is an on-demand daemon, but its transaction lifecycle does
not map cleanly onto the shared iPadOS launchd namespace. Runtime logs show it
starting with location services off, becoming idle, and performing an orderly
shutdown before a later stationary iPad fix arrives:

```text
#Warning,Location Services state changed,clearing local cache
@ClxEvent, ToggleOff, 0, delta, -1.0
locationd shutting down, force=0
```

`macwsinteropd` therefore uses the RE-confirmed synchronous protocol before
submitting a fix: it enables location services and restores Maps authorization,
then calls the simulation controller. On an interruption it retains the last
real fix and retries once after the launch job's 10-second throttle window. It
does not poll or create a high-frequency keepalive.

The native producer is started only after `macwsinteropd` owns the interop Mach
service. This ordering is applied both to cold GUI start and WindowServer
dependent recovery.

## GeoServices isolation

iPadOS and Ventura both publish `com.apple.geod`, but their request resource
formats differ. The old unisolated route produced:

```text
GEOErrorDomain Code=-10 "No resources in request"
```

`libmachook` now rewrites Ventura clients and the Ventura listener to
`com.apple.macosbooter.geod`. `GeodProxy` enters the Ventura chroot and execs
the stock Ventura `com.apple.geod`; its executable is signed with the stock
Ventura geod entitlement set and published as an on-demand launchd Mach
service. No GeoServices request or response payload is translated.

## Production acceptance (2026-08-05)

All checks below were captured from one native-AGX production coexistence
session:

1. Ventura simulation accepted the reconstructed fixes with native `WiFi` type
   and `WGS84` reference frame.
2. Ventura locationd delivered ten consecutive fixes to `com.apple.Maps`; the
   old reference-frame drop and MapKit Wi-Fi alert were absent.
3. Ventura geod served populated map resources without `GEOErrorDomain -10`.
4. A 2388x1668 VNC capture visibly showed populated tiles and the blue current-
   location marker; the toolbar current-location action remained interactive.
5. No Maps, Ventura locationd, `macwsinteropd` or `macwslocationd` crash report
   appeared during the final validation interval.
6. iPadOS native locationd was never restarted. The 5-minute watchdog reported
   `thermal-state=nominal` and approximately 35.2 C at the final sample; its
   intervention policy remained Critical-only with the memory guard disabled.

The matching complete rootless production package built successfully on the
Mac host with SHA-256
`81abac7f11d4d6408921575f809ad878ff7f56a7109b608ba341a4d707c74b5e`.
Archive inspection confirmed the native producer, Ventura interop app bundle,
all three CoreLocation launch contracts, GeoServices contract, entitlement
profiles and requirement writer are present. Both binaries contain the new
`reference_frame`/`raw_reference_frame` protocol keys, and the package contains
no Python bytecode cache or diagnostic capture artifact.
