# Fullscreen Settings and Maps production milestone (2026-08-07)

This milestone verifies the production DisplayStream workspace after fixing
System Settings extension discovery and unifying application activation across
Control Center, URL and the real macOS Dock.  The tested package was:

```text
21ee15f9b077ef8da91714380edad84c59001e2cf2d9f1fdb12a40f1030ee83f  com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb
```

No reboot or respring was used.

## System Settings

The target Ventura 13.4 rootfs has no `ExtensionKit` feature-flag domain, but
the provider inherited iPadOS 16's enabled `automatically_sandbox_extensions`
state.  Runtime probing at the real ExtensionFoundation boundary observed
`_EXDefaults.forceSandbox = 1`, query admission failure, and only one admitted
LaunchServices record.  `libmachook` now restores the target OS's absent-domain
semantics at `_os_feature_enabled_impl`; it does not bypass an ExtensionKit
query or extension validation.

Settings extension registration is now a two-phase transaction: register all
candidate URLs first, then validate their exact platform, identifier and path.
The production verifier reported:

```text
settings-extensions-ready candidates=48 records=48
```

`settings-48-appearance.png` shows the complete sidebar and a live Appearance
extension.  A Host-input click selected Displays; `settings-displays-touch.png`
shows its independently launched native right pane, proving the sidebar was not
merely populated with inert labels.

## Maps: Control Center and touch

Maps is spawned once as a direct child of the already-foreground MacWSHost.
The helper replaces itself with `launchdchrootexec` before Maps starts, so the
legacy empty `MacWSCatalystLauncher` scene is never foregrounded.  The control
transaction now returns as soon as the responsible process exists; the
DisplayStream catalog asynchronously stabilizes and activates the exact native
window.

The first production test observed one Maps process, zero Catalyst launcher
processes, map tiles, and an exact fullscreen input target.  A synthetic Host
touch used the same AppInput controller route as UIKit touch and dismissed the
native “What's New in Maps” panel.  See `maps-touch-after-continue.png`.

## Maps: real Dock cold launch

The final test started with Maps absent and clicked the real macOS Dock tile.
There was one existing fullscreen Host scene.  Runtime log evidence:

```text
1786051585.133 state busy=YES phase=启动 macOS 路径… error=
1786051585.133 launch-path accepted requested=/System/Applications/Maps.app executable=/System/Applications/Maps.app/Contents/MacOS/Maps
1786051585.468 launch-app process-ready id=maps pid=60692 uikitsystem=31830 route=existing-MacWSHost catalog=asynchronous
1786051585.469 state busy=NO phase=就绪 error=
1786051587.751 display-stream window-list count=3
1786051587.752 window-auto-scene activated-fullscreen-catalog pid=60692 window=83 group=83 score=3
1786051587.911 fullscreen-input-target pid=60692 window=83 source=frontmost-fallback title=Maps
```

Thus hostd released busy after about 0.34 seconds, the window was activated in
the existing fullscreen scene after about 2.62 seconds, and input targeted Maps
after about 2.78 seconds.  There was no `scene-connected` event after the Dock
request, `MacWSCatalystLauncher` count was zero, and Maps count was one.  The
visible result is `maps-dock-cold-single-scene.png`.

At the end of this test:

```text
thermal-state=nominal raw=0 battery-temp-centic=3669 effective-temp-centic=3669
60692 60665 0.1 608064 /System/Applications/Maps.app/Contents/MacOS/Maps
```

The Settings steady-state extension processes were separately sampled at
0.0% CPU, Maps at 0.4% CPU, WindowServer at 7.4%, and 36.39°C nominal.
