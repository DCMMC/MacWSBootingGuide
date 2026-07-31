# iPadOS Host window lifecycle and input milestone — 2026-07-31

This milestone moves MacWS Host from a manually selected DisplayStream viewer
toward a real multi-window iPadOS application.  The implementation and the
runtime validation in this document use the AGX-native production GUI stack;
they do not use RFB for Host frame transport and do not use the MTLSim path.

## Result

- A bootstrap Host Scene keeps its semantic macOS menu bar visible and opens
  Terminal automatically.  The first real Terminal window replaces the
  bootstrap Scene instead of leaving a black workspace behind.
- A new eligible level-0 AppKit window is discovered from the validated window
  catalog and requests a new iPadOS Scene.  Existing `(owner PID, logical
  window group)` bindings are reused rather than duplicated.
- Discarding an exact iPadOS Scene sends one typed `CloseWindow` record to the
  owning AppInputBridge, which calls the real AppKit `performClose:`.  The
  binding is persisted by `UISceneSession.persistentIdentifier`, so process
  eviction does not lose the close target.
- AppKit tabs remain one logical iPadOS window: when selection changes the
  visible `CGWindowID`, the Scene follows the replacement that advertises the
  same logical group.
- Temporary panels are not promoted to iPadOS windows.  An AppKit window may
  own a Scene only when AppInputBridge publishes it as visible and level 0;
  menus, sheets and panels continue through the transient-layer compositor.
- Tapping outside the Control Center now lands on a transparent dismissal
  control behind the panel and closes it.
- Two-finger scroll distance is derived from the current viewport, source
  surface and backing scale.  The previous fixed Retina `2x` multiplier has
  been removed.
- Primary and secondary atomic clicks cache the exact source-to-AppKit
  transform before `sendEvent:`.  The direct event-queue route remains active
  for the actual lifetime of AppKit's nested menu loop, and every atomic click
  invalidates the transient catalog so closed menus do not remain composited.
- A windowless Terminal process is retired before relaunch, preserving the
  one-instance invariant without treating process uptime as a usable window.
- VSCode reuse now has two independent witnesses: a visible/resizable AppKit
  workspace and the absence of Electron's own renderer-unresponsive report
  after the exact PID's launch-log boundary.

## Input architecture (not Sidecar HID)

The elastic scroll and working clicks in this milestone are **not** Sidecar
HID.  The source-confirmed route is:

```text
UIKit touch / pointer / keyboard
  -> MacWSInputRecord v4
  -> macwsinputd
  -> /private/tmp/macws_app_input.<pid>.sock
  -> AppInputBridge in the exact AppKit process
  -> real NSEvent / NSApplication sendEvent:
```

Scroll elasticity comes from AppKit wheel phase and momentum-phase records.
Sidecar can provide useful hardware HID semantics, but it cannot by itself fix
the window ownership, coordinate transform, nested menu-loop routing or stale
transient-surface problems above.

## Runtime evidence

### Default Terminal replaces the bootstrap Scene

Runtime-confirmed via `/var/mobile/Library/Logs/MacWSHost.log` and
`MacWSHostd.log`:

```text
1785500547.166 launch-app window-ready id=terminal pid=16438 path=DisplayStream
1785500547.834 launch-auto-window app=terminal pid=16438 window=143 group=143
1785500547.837 scene-reused mode=window window=143 owner=16438 reason=默认终端已经就绪。
```

The resulting HiDPI Scene, persistent semantic menu bar and upper-right
Control Center are visible in
[`default-terminal.png`](evidence/ipados-host-window-lifecycle-input-20260731/default-terminal.png).

### Scene close reaches the exact AppKit owner

Runtime-confirmed via `MacWSHost.log`:

```text
1785500312.083 scene-close source=did-discard id=01D92311-A70F-4998-BB3C-7EA38165FB19 window=137 target=14258 sent=YES errno=0
1785500858.447 scene-close source=control-center id=EB9F6C2A-AE7D-4CD9-9511-75370B784072 window=143 target=16438 sent=YES errno=0
1785500858.602 window-identity-follow owner=16438 group=143 old=143 new=149
```

The last line is the expected tab-group behavior: closing the represented tab
exposes another member of the same native tab group before UIKit finishes
discarding the Scene.

### Dialogs do not become duplicate black Scenes

Runtime-confirmed via `MacWSHost.log` for Terminal's Low Disk Space panel:

```text
1785500548.100 window-auto-scene cancelled identity=16438:g:144 reason=transient
```

This is not title matching.  The catalog is sourced from all CG windows but
accepts only AppInput metrics entries whose real AppKit window is visible and
level 0; the 250 ms stability boundary catches the short ordering transition.

### Terminal click and native menu path

Runtime-confirmed input records:

```text
1785500595.296 input-v4 synthetic kind=tap routed-through-controller scene=8f80000000 target=16438 point=(1120.00,60.00) frame=1140x798
1785500685.880 input-v4 synthetic kind=secondary routed-through-controller scene=8f80000000 target=16438 point=(500.00,300.00) frame=1770x1106
1785500706.095 input-v4 synthetic kind=tap routed-through-controller scene=8f80000000 target=16438 point=(1500.00,800.00) frame=1770x1106
```

The visible results are:

- [`terminal-two-tabs.png`](evidence/ipados-host-window-lifecycle-input-20260731/terminal-two-tabs.png)
- [`terminal-native-context-menu.png`](evidence/ipados-host-window-lifecycle-input-20260731/terminal-native-context-menu.png)
- [`terminal-context-menu-dismissed.png`](evidence/ipados-host-window-lifecycle-input-20260731/terminal-context-menu-dismissed.png)

The context menu is the native AppKit menu, not a Host recreation.  The final
image shows that an ordinary outside primary click removed its transient
surface.

### VSCode lifecycle and renderer-health boundary

The old process produced this exact application-owned witness:

```text
[main 2026-07-31T12:09:55.019Z] CodeWindow: detected unresponsive
[main 2026-07-31T12:10:10.024Z] [uncaught exception in main]: UnresponsiveSampleError: UnresponsiveSampleError: from window with ID 2 belonging to process with pid 13108
```

Its base NSWindow remained visible and resizable under the recovery sheet, so
geometry flags alone were disproved as a renderer-health test.  `macwshostd`
now stores `(PID, vscode.log byte offset)` in
`/var/jb/var/mobile/vscode-health-marker` and scans only the exact launch's
suffix.  A later normal request reused PID 18614 without spawning a duplicate:

```text
1785501676.270 launch-app window-ready id=vscode pid=18614 path=DisplayStream
1785501676.435 launch-auto-window app=vscode pid=18614 window=159 group=159
1785501676.436 scene-activation reusing id=18EB6FE1-C17F-43FD-86D2-3FF7C9651A36 owner=18614 group=159 window=159
```

The restored native AGX VSCode window rendering the Apple page is captured in
[`vscode-apple-page.png`](evidence/ipados-host-window-lifecycle-input-20260731/vscode-apple-page.png).

## Persistent state and switches

This milestone adds no environment-variable or flag-file feature switch.  The
behavior is the production default.

- `MacWSPersistedSceneWindowBindings` — an iOS `NSUserDefaults` dictionary
  keyed by the persistent UIKit Scene identifier.  Values contain stream mode,
  window ID, owner PID, logical group, minimum size, resizability and title.
- `/var/jb/var/mobile/vscode-health-marker` — root-owned `PID byteOffset`
  record used to isolate Electron health diagnostics to one production launch.

## Validation boundary / remaining work

- Runtime validation proves Terminal tab creation, native secondary menu and
  menu dismissal through the same controller/input transport boundary used by
  UIKit.  Hardware touch, long-press, two-finger scroll, drag, Shift/Caps Lock
  and Magic Keyboard still require an end-to-end hands-on acceptance pass.
- An automated VSCode Activity Bar coordinate probe did not visibly select
  Search after the Scene had resized, so this milestone does **not** claim that
  every VSCode button is fixed.  The next input milestone must derive its probe
  coordinate from the exact current content rectangle, then validate clicks,
  right-click, drag and keyboard events against stable observable UI state.
- One `screencapture` request returned an all-black PNG while WindowServer,
  VSCode and DisplayStream counters continued advancing; a subsequent capture
  restored the complete image.  This is recorded as a capture-path transient,
  not counted as application stability.
- Static/partly animated producer cadence observed during the Apple page was
  only several frames per second and VSCode logged AGX command-buffer internal
  errors.  No fluidity or WebGL-performance conclusion is made in this
  lifecycle milestone.

## Build verification

The complete rootless production package built successfully with:

```text
gmake -j8 FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 package
dm.pl: building package `com.kdt.macosbooter:iphoneos-arm64' in `./packages/com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb'
```

The device deployment updated MacWS Host, `macwsdisplayd`, `macwshostd` and
`libmachook` without rebooting the iPad or WindowServer.
