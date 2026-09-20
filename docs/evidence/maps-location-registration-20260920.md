# Maps location registration and normal-launch acceptance — 2026-09-20

## Result and scope

**The fresh, normal production Maps generation passed location UI acceptance.**
The app was opened through `macwshost://maps`, the ordinary Host control entry,
not a diagnostic launcher. After dismissing the normal What's New sheet, a
native iPadOS touch on the toolbar location arrow centered the map on its blue
location dot. Roads and map tiles were visibly present. Both authorization
queries after launch and after the location action returned status 3 with no
error. CoreLocationAgent registered this Maps process with `verified:1`.

This test did not enable a feature marker, inject an observer into Maps,
manually set authorization, or restart a location service. It followed the
coordinated normal macOS GUI stop/start that installed a coherent current
runtime; it did not restart iPadOS. The existing production launch-bound
authorization transaction ran normally and is distinguished below from the
read-only diagnostic queries.

This is **not** evidence that an authorization setter is a fix for verification
failure, or that flag migration was the proven cause of the old failure. The
old live Agent's failed verification is preserved; its exact failing Security
operation was not captured before that generation ended.

## Old-generation failure, preserved before stopping macOS

The old processes were Maps 5865, CoreLocationAgent 17030, interop 17017,
native bridge 17020, and Ventura locationd 23153. Native iPadOS locationd was
PID 357. The macOS identities were all UID 0.

Runtime-confirmed in the private pre-restart Agent log:

```text
copy_client_info pid:5865, bundleId:com.apple.Maps, execPath:/System/Applications/Maps.app/Contents/MacOS/Maps, bundlePath:/System/Applications/Maps.app
```

That registration logged `Couldn't get requirement for client` and
`verified:0`. The interop log had earlier reported Maps authorization 3; a
subsequent correctly entitled, read-only query returned:

```text
endpoint=com.apple.macosbooter.locationd.desktop.synchronous bundle=com.apple.Maps path=nil wait=0 status=0 error=none/0
endpoint=com.apple.locationd.desktop.synchronous bundle=com.apple.Maps path=nil wait=0 status=0 error=none/0
endpoint=com.apple.macosbooter.locationd.desktop.synchronous bundle=com.macwsguide.interopd path=nil wait=0 status=3 error=none/0
```

The native location bridge was not simply dead: delivery counters advanced
480 to 540, and interop submissions 776 to 783. These counters alone were not
treated as proof that Maps received locations.

A fresh current-library Security helper could obtain and validate the very
same old Maps process:

```text
pid=5865 requirement-status=0 requirement-nonnull=1
pid=5865 requirement-string-status=0 value=identifier "com.apple.Maps"
pid=5865 validity-status=0
```

The private source artifacts and logs remain under
`/tmp/macws-location-pre-restart-20260920.Lro1NP`, not in the repository.
Coordinates and user map contents are intentionally excluded here.

### Actual rejection path, not a guessed authorization policy

RE-confirmed from the exact Ventura locationd arm64e image, UUID
`DA334E85-02CE-306B-A7B3-7A9DB0966EA1`:

- `CLInternalService`'s authorization getter at image offset `0x47be48`
  resolves the real effective client and calls the actual registration-result
  lookup and authorization-status conversion. Alternate-identity queries
  require the effective-bundle entitlement.
- UUID mapping at `0x112570` retains its verification argument; the branch at
  `0x112a6c` skips clearing when verification is true. The false path references
  `Clearing client authorization due to verification failure during UUID mapping`
  and calls `0x11e668`, which removes the actual client dictionary's
  `Authorized` key.
- This explains why suppressing or repeatedly overriding authorization would
  operate downstream of a real identity failure. It does **not** prove the
  exact old Maps request traversed this branch: that log line was not captured
  at runtime.

The existing CoreLocationAgent requirement-text compiler compatibility and
precise authenticated import binding in `libmachook/mac_hooks.m` date to
`ded7e0b1`. Their installation is not marker-gated. They construct a real
requirement and leave the original code-validity check in place. No new
always-authorized override was added in this investigation.

## Fresh generation: before Maps launch

After the normal coordinated macOS restart:

```text
WindowServer=15997
macwsinteropd=16142
macwslocationd=16145
CoreLocationAgent=16158
Ventura locationd=16159
native iPadOS locationd=357
```

The native bridge reported real effective-client authorization 3 and delivered
a location. The fresh Agent registered interop 16142 with `verified:1`.
Before Maps existed, the entitled read-only authorization helper returned Maps
bundle-ID status 3 and interop status 3.

**Query-identity distinction:** a bundle-path-only query returned 0 both
before and after the successful Maps acceptance. It is not interchangeable
with the Maps bundle-ID authorization lookup and was not counted as a failure.
Without the appropriate query entitlement, the helper receives a real
`com.apple.locationd.internalservice.errorDomain` error; that case is also not
misreported as a successful status-0 lookup.

## Normal Maps launch and actual location UI

Runtime-confirmed after `uiopen macwshost://maps`:

```text
Maps PID=20280
2026-09-19 13:46:15.291 CoreLocationAgent[16158:786479] copy_client_info pid:20280, bundleId:com.apple.Maps, execPath:/System/Applications/Maps.app/Contents/MacOS/Maps, bundlePath:/System/Applications/Maps.app
2026-09-19 13:46:15.294 CoreLocationAgent[16158:786479] Sending registration to locationd - pid:20280, uuid:77151375-7025-415D-8C19-62E243FADCEE, bundleId:com.apple.Maps, bundlePath:/System/Applications/Maps.app, execPath:/System/Applications/Maps.app/Contents/MacOS/Maps, isPlugin:0, verified:1, requirement:identifier "com.apple.Maps"
```

The macOS log clock is spoofed/offset; the operation took place on the native
2026-09-20 session. These textual macOS timestamps must not be directly
compared to native timestamps.

The normal production interop launch handler, without a diagnostic setter:

```text
MACWS-INTEROP refreshing Maps authorization for application pid=20280
MACWS-INTEROP Ventura location witness and Maps authorization verified witness=3 maps=3
MACWS-INTEROP submitted Ventura-native location #40 accuracy=47.5m
MACWS-INTEROP Ventura CLLocationManager witness restarted after authorization verification
MACWS-INTEROP submitted Ventura-native location #41 accuracy=47.5m
MACWS-INTEROP submitted Ventura-native location #42 accuracy=47.5m
```

Independent read-only Security checks for Maps 20280 and interop 16142 each
returned guest lookup 0, designated-requirement lookup 0, and validity 0.
After the location-button action, the private and ordinary desktop service
names both returned Maps bundle-ID authorization 3, `error=none/0`.

The UI input used the previously verified native digitizer sender and screen
coordinate transform. Native full-iPad captures were manually viewed:

- `/tmp/macws-maps-normal-start-20260920.png`: Maps and normal What's New sheet.
- `/tmp/macws-maps-after-continue-20260920.png`: real blue location dot, tiles
  still loading at the initial scale.
- `/tmp/macws-maps-location-button-20260920.png`: selected toolbar location
  arrow, map centered on the blue dot, visible local roads and map tiles.

These images contain location information and are private local evidence,
not repository assets. UI ownership was returned immediately after acceptance;
Maps was left running and no other application was closed.

## Tests and remaining attribution boundary

`python3 -m unittest misc.test_maps_location_refresh_contract -v`: **4 passed**.
These are source-contract tests, not substitutes for the above UI and API
witnesses.

The new generation no longer reproduces the old failed registration or
authorization clearing. A coherent runtime restart resolved the observed
case, but distinguishing an old mapped-library generation from a transient
old registration/readiness failure requires evidence from that failed
generation which is no longer available. No claim is made that all future
permission-denied cases should be overridden or that this test authorizes
ignoring the user's native location permission.
