# Workspace, menu provider and Maps follow-up (2026-09-12)

Historical record: later Safe Mode checks are in
`switcher-selection-safe-mode-20260912.md`; native menu rendering follow-up is
in `window-native-popup-and-export-cancel-20260912.md`. The unresolved labels
below describe these earlier trials, not a claim that subsequent work stopped.

Scope: the user's new six-item request only. The prior complete code baseline
was committed and pushed to `origin/main` as
`0625ca1f8a148cd7ef1439c37bcda9429b1efd75` before these edits. Generated builds,
screenshots, logs and the empty core artifact were not included.

This is a live acceptance record, not a claim that all six issues are fixed.
WindowServer PID76954 remained unchanged. One intentional SpringBoard restart
installed v54; v55 restarted only Host; v56 restarted only the native location
bridge. **Subsequent failure:** SpringBoard PID35698 crashed at16:17:44 while
adding a Settings Scene (incident79A565D6-CDD3-4708-8F3C-0FABE5EE22CA) and
entered Safe Mode. Thus the earlier visual checks do not establish stability.
See the separate Safe Mode follow-up; remaining feature work is paused.

## Fullscreen: visible acceptance passed

Runtime-confirmed via MacWSWindowing.log, the Scene's old fixed AppKit model
was still applied during its transition to desktop presentation:

```text
1789194093.116 dense-grid-result ... proposed=1389.0x970.0 constrained=898.0x676.0 result=898.0x676.0 ...
1789194093.116 resize-policy springback ... proposed=1389.0x970.0 constrained=898.0x676.0 ... fixed=YESxYES
```

The omitted fields are Scene identifiers; the dimensions and policy are copied
verbatim. v54 detaches only that exact Scene from the AppKit sizing policy
before invoking the real native maximization action. Later valid window-mode
requests restore the normal per-Scene policy. No system-wide constraints or
fullscreen getter were overridden.

The Terminal test began as a1010×678 Stage Manager window. Host.log recorded:

```text
1789194518.225 scene-immersive landed session=638F5A41-8ED9-423A-A0C2-110AAF472B67 is-fullscreen=NO bounds={{0, 0}, {1389, 970}}
```

The independent native iPadOS capture `tmp/v54-terminal-fullscreen.png` was
inspected: the desktop fills the physical display, without Stage Manager
window edges. `is-fullscreen=NO` alone is not a reliable geometry witness on
this OS. Finder workspace restoration also filled1389×970.

## Steam menus and Control Center: displayed and action-tested

Runtime-confirmed via macwsdisplayd.err:

```text
MACWS-DISPLAY menu-provider-fallback visible-owner=36394 visible-window=713 provider=36048 provider-window=709 depth=1 nodes=70
```

The main Steam process owns the menu; Steam Helper owns the visible window.
The existing backend validates their parent relationship and UID. Host now
keeps represented PID/window separately from provider PID/window/generation,
accepting the snapshot for the displayed Scene while sending actions to the
actual provider. It does not activate a hidden provider window on refresh.

Host.log after v55:

```text
1789195445.453 semantic-menu provider=36048/709 represented=36394/713 nodes=70
```

Inspected native captures:

- `tmp/v55-steam-control.png`: real root menu entries; neutral gray controls
  and thicker system material instead of uniformly blue controls.
- `tmp/v55-steam-menu-visible.png`: View menu, real exported entries.
- `tmp/v55-steam-downloads-second.png`: after native HID selected View →
  Downloads, the real Downloads page is visible with an empty queue.

The first Downloads attempt did not establish completion; only the second
capture is acceptance. The first exported root is still called `Apple` by
Steam's menu data; app-menu display-name normalization remains to inspect.
Native AppKit context-menu blur is NOT fixed by this Host styling change.

## Maps: real upstream registration failure; recovery in validation

Runtime-confirmed via catalyst-launcher.log before changes:

```text
[MacWSCatalystLauncher] location provider was not ready after 30 seconds; Maps launch deferred
```

The read-only native probe initially lacked execution/container and effective-
bundle privileges. These are diagnostic-tool failures, not CoreLocation bugs.
Exact oslog evidence:

```text
System Policy: zsh(41506) deny(1) process-exec* /private/var/mobile/Media/macws_location_status_probe-v3
Sandbox: hook..execve() killing com.macwsguide.probe.location-status[pid=41506, uid=0]: (err=1) failed to apply exec policy
#Spi, requires entitlement 'com.apple.locationd.effective_bundle' with bundle identifier 'com.macwsguide.host' or bundle path ''
```

With only the needed diagnostic entitlements, native locationd logged
`#clldu _staticRegistrationResult , missing client`, with an empty `Registered`
and `TimeMissing` for com.macwsguide.host. Merely creating a new effective
CLLocationManager (no authorization setter or location subscription) produced
`a missing client has registered`. The subsequent real getter returned:

```text
native-location-status services-enabled=1 host-authorization=3 query-available=1
```

v56 adds an explicit launch-triggered notification to re-create the real
native location client if the provider witness is absent. It retains the
30-second real-callback gate and exact live-PID/executable validation. Refresh
does not set permissions or fabricate coordinates/readiness. Retired-manager
callbacks are ignored; requests are coalesced over3seconds. Startup's existing
authorization policy is unchanged.

After installing v56, native bridge PID44225 logged:

```text
[macwslocationd] native client refreshed reason=startup authorization=3 services=1
[macwslocationd] delivered native fix #1 type=4 accuracy=48.0m age=402.1s
MACWS-INTEROP Ventura location provider readiness published
MACWS-INTEROP Ventura CLLocationManager output ready
```

The first location was cached by the real provider; its age was not hidden.
Subsequent real locations were delivered. Maps PID44534 launched and
`tmp/maps-v56-first.png` visibly contains native map tiles and What's New.
The same launch notification was then posted while native bridge PID44225
stayed alive. It recorded `native client refreshed reason=maps-launch
authorization=3 services=1`; interop continued submitting real locations
through #33. `tmp/maps-v56-precontinue.png` shows the map at street detail.
The actual TimeMissing failure was not intentionally reintroduced by
unregistering the user's app.

v58 additionally reads the real daemon authorization during registration,
bounded to8half-second retries only for NotDetermined. It does not treat that
transient status as authorization. Old-manager retries are ignored. A denied
or restricted delegate state stops the subscription.

## Native backdrop capture and Settings speed: unresolved

Read-only catalog probe, existing standard capture permission:

```text
capture-permission native-preflight=0 tcc-loaded=1 error=none
capture-permission preflight-symbol=1 service-symbol=1
capture-permission tcc-status=1
```

RE-confirmed actual Ventura SkyLight UUID96676A53-B1E0-3D7E-B98B-B73873CD1880,
18520d030–18520d04c calls TCCAccessPreflight(service,NULL) and accepts status0.
18520d1f8 resolves the dependency. Thus missing symbols are disproved; the
actual TCC policy return still blocks the selective compositor diagnostic.
No permission checks were forced, TCC databases edited, or full-display
capture substituted for an isolated-window stream.

Settings cold launch repeated at about25seconds. Host preflight occupies
about1second, then the actual process takes the remainder to publish a window.
Idle sampling shows the normal AppKit event loop. A stock `/usr/bin/sample`
trial during cold startup coincided with Settings PID45273 dying in dyld's
load-notification path: incident32F6A0E0-6230-4011-A36B-8C1A1820058F,
`EXC_GUARD`, `INVALID_OPTIONS`. No iPad reboot/WindowServer restart occurred.
Do not use that cold sampling method again without fixing its compatibility.

The new bounded Settings-only register probe avoids dyld notification
subscriptions. It completed40samples of a cold start; Settings PID47915
published a window and stayed live. Many samples contain CoreUI/CoreImage
callers with their PC in libGLProgrammability. A separate helper mapped the
same unslid PC0x1e5072b94 into that real library; nearest exported symbol
names are not exact private-function boundaries and must not be overread.

An A/B trial that moved the existing Settings recipe path ahead of the
full-icon fallback did NOT improve cold startup: PID47915 baseline took
21.50seconds and PID53602 trial took21.58seconds (spawn to real window).
The source change was removed and both installed libmachook slices restored
byte-for-byte using fresh inodes. It is NOT a shipped optimization.
The attempted trial screenshot landed on the iPad home screen and cannot
validate icon rendering. No Settings speedup is claimed.

## Installed hashes

```text
v54 Tweak e0b1845b02df7c3c9ca3650a5b15b0d54273bb17593e7dd1aba6f1a33bda70d8
v55 Host 0b33a198b798fe09211d0d4d2d5a91909939bb3fc71162205327e35f96c1b234
v56 location 43c9db35aabb6662fecf6e631136a1fe56db6265991fda5e6bb74c54881164fc
v56 launcher 9074527a715d4fe5491777cb07115f0f17120bd1669358a67f1e4290c9d1d522
v58 location 92453f29954c74de10986ec9e4ce36c05c919fbdea1a41ec8a4b6f3ad877397a
restored arm64e hooks 44b256e549271d56e509e10d8fb7a3d0e2028f7cad1aa5408e464cbacb550898
restored arm64 hooks 88b3552d7a2602e1635368caf448197a9506ade54bbb85ea1fa61dadf247cf5a
```

Every installed image was verified by native `codesign --verify --strict`,
trusted using its final CDHash, and atomically replaced using a fresh inode
with an explicit prior-image backup. Screenshots/logs stay local because some
contain user account or location information.

Final local checks:49window source/unit contracts,4location-refresh contracts,
and3C protocol/configuration/drawable executables pass. Those are regression
guards, not substitutes for the visible acceptance above.
