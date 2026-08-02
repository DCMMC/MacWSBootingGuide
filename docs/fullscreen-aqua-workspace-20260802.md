# Fullscreen Aqua workspace milestone

Date: 2026-08-02
Target: iPad13,6, iPadOS 16.3.1, macOS 13.4 chroot, AGX-native production profile

This milestone makes the fullscreen MacWS Host Scene present the real macOS
desktop instead of a UIKit imitation. Finder owns the desktop, Dock owns Dock
and Launchpad, and SystemUIServer/ControlCenter own the right-side menu extras.
The frame still reaches the iPad through DisplayStream IOSurface → native Metal;
RFB is not used by MacWS Host.

## 1. Cold production start

`macos_gui.sh start coexist` now starts the private LaunchServices service,
registers the real system/local/user application catalog, then starts
WindowServer, Finder, Dock, SystemUIServer, ControlCenter, DisplayStream and
Terminal in dependency order. The cold-start witness was:

```text
[macos_gui] LaunchServices application catalog ready.
[macos_gui] WindowServer graphics ready (pid=98036, clean producer observed).
[macos_gui] Finder workspace agent ready.
[macos_gui] Dock workspace agent ready.
[macos_gui] SystemUIServer workspace agent ready.
[macos_gui] ControlCenter workspace agent ready.
[macos_gui] Native macOS desktop wallpaper ready.
[macos_gui] VNC: Retina first frame ready (WindowServer pid=98036, generation=1785676667).
```

`lsregister -dump` contained 438 bundle records after this cold start. The
production desktop is captured in
[`cold-production-desktop.png`](evidence/fullscreen-workspace-20260802/cold-production-desktop.png):
2388×1668 pixels with the real Finder desktop, purple macOS desktop image,
Dock, menu bar and right-side status extras.

## 2. LaunchServices root-volume repair

The real `lsregister -f` initially returned `-50`. This was not fixed by
forcing registration success.

Runtime LLDB on the target LaunchServices image showed
`-[FSNode isVolume]` at `0x19e38637c`: it calls `isDirectory`, reads
`NSURLIsVolumeKey`, and falls back to `isMountTrigger`.
`_LSIsNodeTranslocatedMountPoint` at `0x19e3a4e2c` then created
`NSOSStatusErrorDomain -50` with `_LSFunction=_LSIsNodeTranslocatedMountPoint`
and `_LSLine=117` when the chroot root was not classified as a volume. The
runtime object itself was:

```text
<FSNode ...> { isDir = y, path = '/' }
```

`libmachook` now calls the original `isVolume` first. Only when it returns
false does it compare that FSNode URL with the exact process root by URL or by
`stat(2)` device/inode and report the root as a volume. Non-root nodes and all
native success/error paths remain unchanged. `postinst.sh` also creates the
kernel-visible namespace alias `/rootfs -> /` only when the path is absent and
refuses to overwrite a conflicting path. After both sides used the new
library, the real command returned `REGISTER_RC=0`; the full application scan
completed in 4.809 seconds.

This is an upstream namespace/volume-invariant repair, not an `lsregister`
return-value bypass.

## 3. Real wallpaper, Dock, Launchpad and status menu

`macwsworkspacectl` is a macOS arm64 AppKit tool installed in the chroot:

- `set-wallpaper [path]` calls
  `-[NSWorkspace setDesktopImageURL:forScreen:options:error:]` for every real
  `NSScreen`. The production default is macOS's built-in
  `/System/Library/Desktop Pictures/Solid Colors/Blue Violet.png`.
- `show-launchpad` spawns the stock
  `/System/Applications/Launchpad.app/Contents/MacOS/Launchpad` launcher and
  waits for its real Dock transaction.

The built-in `Motion Blue.heic` call returned success but still produced a
black desktop on this chroot, so production deliberately uses the built-in PNG
whose visible result is runtime-confirmed. No wallpaper is drawn in UIKit.

The one-click Launchpad route is:

```sh
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh launchpad
```

[`cold-production-launchpad.png`](evidence/fullscreen-workspace-20260802/cold-production-launchpad.png)
shows the real Launchpad search field, folder and Dock. The later production
IconServices repair now keeps both `iconservicesd` and `iconservicesagent`
alive: runtime tracing proved `qtn_proc_init_with_self` returned
`-2/ENOPOLICY`, while a diagnostic-state probe inside the wrapper clobbered
the deliberately translated `ENOATTR` back to `ENOENT`. The wrapper now
evaluates diagnostics before restoring errno, so the stock agent reaches its
listener in production. Dock icons are mostly restored. Four `?` placeholders
and an empty Launchpad “Other” folder remain because Launchpad's application
import stage has not populated its persistent database (`apps=0`); this is no
longer attributed to IconServices process startup.

[`fullscreen-status-menu-touch.png`](evidence/fullscreen-workspace-20260802/fullscreen-status-menu-touch.png)
shows a fullscreen Host click opening the real macOS Control Center. The menu
contains Wi-Fi, Bluetooth, AirDrop, Focus, Screen Mirroring, Display, Sound and
Music controls and is rendered by the macOS ControlCenter process.

## 4. iPadOS fullscreen postconditions

MacWS uses SpringBoard's real focused-Scene fullscreen action rather than
writing a `UIWindow` frame or scaling a layer. RE-confirmed on iPadOS 16.3.1:
`-[SpringBoard _handleEnterFullScreenKeyShortcut:]` at `0x1c7669808` asks the
active display scene for its switcher controller and performs action `0x11`
(decimal 17). The tweak validates that the focused app layout contains the
exact requested MacWS FBS Scene ID before performing this system transaction.

Fullscreen Host returns:

```text
prefersStatusBarHidden = YES
prefersHomeIndicatorAutoHidden = YES
preferredScreenEdgesDeferringSystemGestures = UIRectEdgeAll
```

Cold Scene restoration now reasserts this policy after the real `UIWindow` is
key and visible; it no longer depends on having traversed the interactive
fullscreen button path. The target runtime recorded the following at 0, 250
and 1250 ms:

```text
immersive-postcondition expected=YES status-request=YES status-hidden=YES home-indicator-auto-hide=YES deferred-edges=15 bounds={{0, 0}, {1389, 970}} screen={{0, 0}, {1389, 970}} safe-insets={0, 0, 20, 0}
```

`status-hidden=YES` is the live `UIStatusBarManager` state; equal Scene/screen
bounds witness the real system fullscreen geometry. The Home Indicator is an
auto-hide policy rather than a public visible-state property, so the companion
pixel witness is
[`fullscreen-production-desktop-final.png`](evidence/fullscreen-workspace-20260802/fullscreen-production-desktop-final.png):
neither iOS status content nor the Home Indicator is present, while the
translucent MacWS control button remains at the upper-right edge.

## 5. Fullscreen system input root cause and repair

The first fullscreen build enabled input only when the display catalog
contained a normal focused AppKit window with a live per-process socket. That
made Dock, Launchpad and desktop state report “touch unavailable.” Keeping the
last Terminal PID was also invalid once a system overlay became frontmost.

Runtime `macwsinputd` diagnostics for a Launchpad tile at Quartz `(160,105)`
showed the actual front-to-back windows:

```text
pid=98036 owner=Window Server layer=2147483630 window=3 contains=YES
pid=99793 owner=Dock          layer=27         window=25 contains=YES
```

The old `WindowTargetAtPoint` accepted only layer zero, so it rejected Dock and
fell back to `CGEventPost(kCGHIDEventTap)`. On this chroot that fallback changed
the cursor but did not deliver the click. A controlled record explicitly sent
to Dock pid 99793 opened Launchpad's real “Other” folder, proving that the
per-process CoreGraphics route was valid.

The central broker now uses `CGWindowListCopyWindowInfo`'s authoritative
front-to-back order, accepts the first containing nonnegative-layer window,
and excludes owner `Window Server`. This naturally covers ordinary windows,
AppKit popup/menu layers, Dock/Launchpad and SystemUIServer/ControlCenter
extras; there is no application-name or coordinate hardcode. Fullscreen Host
sends pointer/scroll records with `targetPID=0` so the broker performs that
per-point selection. Keyboard records retain a genuinely focused catalog PID;
when none exists they remain zero and use the broker's cached/probed target.

After the repair, the same zero-target click logged:

```text
MACWS-INPUT ROUTE seq=1 route=target-pid pid=99793 window=25
```

and visibly changed Launchpad from the open folder back to its folder grid.
The subsequent full-screen status-extra click opened the native Control Center
shown above. Production was then restored with all runtime/AppInput diagnostic
sentinels absent. The final no-diagnostic visual pair is
[`fullscreen-launchpad-grid.png`](evidence/fullscreen-workspace-20260802/fullscreen-launchpad-grid.png)
→
[`fullscreen-launchpad-folder-touch.png`](evidence/fullscreen-workspace-20260802/fullscreen-launchpad-folder-touch.png):
one zero-target Host click opens the real Dock-owned folder.

## 6. Current evidence boundary

Runtime-confirmed in this milestone:

- real SpringBoard fullscreen geometry;
- hidden iOS status bar and auto-hidden Home Indicator policy, with a pixel
  witness showing no iOS chrome;
- DisplayStream/native-Metal full desktop at 2388×1668;
- real macOS wallpaper, menu bar, Dock, Launchpad and right-side status items;
- full-desktop point routing into Dock/Launchpad and ControlCenter;
- production cold start with diagnostics off and memory guard disabled.

Still open:

- repair Launchpad's native application-source import stage so its persistent
  database populates application rows and the remaining Dock placeholders;
- physical-finger subjective latency and all gesture combinations still need
  a user-on-device regression even though the exact controller → broker →
  native system-UI event path has visible runtime witnesses here.

## 7. Atomic window → fullscreen stream handoff (2026-08-03)

The enlarged partial desktop and disabled touch seen during an interactive
window → fullscreen transition had one shared producer failure, not two
unrelated view/input bugs.

Runtime-confirmed via `MacWSHost.log`: the exact-window generation ended at
`2162×1414`; after the fullscreen request there was no replacement base frame
for about 40 seconds. During that interval Host retained the last Metal
drawable while iPadOS maximized the Scene, so the old window-sized image was
scaled up. Input correctly remained gated because the replacement frame
generation did not exist. The first healthy replacement was:

```text
display-stream first-frame revalidate-input mode=1 target=0 status=DisplayStream IOSurface 首帧已就绪
display-stream first-frame revalidate-input mode=1 target=0 status=2388×1668  ·  DisplayStream  ·  IOSurface 直传
```

Runtime-confirmed via `macwsdisplayd.err`: a stale fullscreen Scene still owned
`stream 10` and its full desktop layer set while the current window owned an
exact stream. Entering fullscreen created workspace `55` plus a second set of
Retina layer streams. WindowServer then emitted AGX command-buffer
`Internal Error (00000103)` and restarted. The first attempted ownership fix
still stopped the old graph and immediately created another; the integration
probe changed WindowServer PID `75537 → 78356` and recorded
`layer-start failed ... error=-308`, so that implementation was rejected.

Production now treats the complete macOS desktop capture graph as a unique
physical resource. A newer foreground fullscreen subscriber receives the
already-running graph: layer callbacks are rebound to the new XPC client and
each layer's retained latest IOSurface is republished. No SkyLight capture
stream is stopped or recreated during the transfer. The packaged build passed
the two-client probe with stable PIDs:

```text
78356 WindowServer  (before and after)
79399 macwsdisplayd (before and after)
MACWS-DISPLAY workspace-handoff stream=1 layers=11 new-client=... transport=live-graph-transfer
```

Host also submits an explicit black Metal clear for the short interval between
stream generations. `MTKView` therefore cannot retain and magnify an exact
window drawable while the fullscreen base IOSurface is pending. Viewport zoom
is reset to `1.0`, center `(0.5,0.5)` before both transition directions, and
the first direct IOSurface causes the controller to re-evaluate the complete
input-ready invariant.

The reproducible integration source is
[`macws_display_handoff_probe.m`](../misc/macws_display_handoff_probe.m); the
verbatim accepted/rejected evidence is
[`display-handoff-production.txt`](evidence/fullscreen-workspace-20260802/display-handoff-production.txt).

The device was locked after package installation, so the final physical UIKit
button/finger pass for this exact build remains an explicit evidence boundary.
The display-service ownership race itself is exercised without UIKit and has
passed twice, including once against the installed production `.deb`.
