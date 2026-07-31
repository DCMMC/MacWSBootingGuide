# Native Host multi-layer, Carbon input, and instance reuse — 2026-07-31

Target: `iPad13,6`, iPadOS 16.3.1, chroot macOS 13.4. Device address
during this validation was `192.168.1.6`. No iPad or WindowServer reboot was
performed. The final thermal sample was:

```text
thermal-state=nominal raw=0 low-power=no battery-temp-centic=3639 virtual-temp-centic=3639 effective-temp-centic=3639 uptime=57088.449
```

The production diagnostics sentinel was absent after validation:

```text
diagnostic-sentinel=absent
```

## Why a context menu could open but not accept the next click

Runtime-confirmed via an LLDB attachment to the actual macOS 13.4 Terminal:
the right-click enters this synchronous nested event tracker on the main
thread:

```text
rightMouseDown:
  -> NSCarbonMenuImpl _popUpContextMenu
  -> SLMPerformPopUpCarbonMenu
  -> TrackMenuCommon
  -> _NSHLTBMenuEventProc
```

This invalidated the earlier assumption that the ordinary AppInput main
CFRunLoop drain could construct the later click. That drain cannot run while
the same main thread is held in the Carbon tracker. The fix caches the exact
real `NSApplication`, `NSWindow`, and coordinate transform before the
secondary event enters the tracker. While that tracker is active, the socket
thread creates ordinary mouse events and inserts them into the application's
real event queue in chronological order. HIToolbox/AppKit still owns hit
testing, enabled-state validation, and action dispatch. No menu item, selector,
or screen coordinate is hardcoded.

Runtime validation opened Terminal's real context menu on base window 26:

```text
MACWS-DISPLAY layer-start stream=17 base=26 layer=32 level=101 destination=(726,566 282x328)
```

Selecting Copy removed the exact transient layer:

```text
MACWS-DISPLAY layer-remove base=26 layer=32
```

The before/after Host screenshots visibly showed the native menu appear and
then disappear. Terminal remained alive and returned to approximately 0.1%
CPU. This is the stability witness; process uptime alone was not used.

## Why the menu is a layer instead of an RFB crop

Runtime window-catalog evidence shows menus, popovers, and sheets as separate
nonzero-level SkyLight windows. Protocol v3 therefore keeps the selected
application window as an exact base stream and transports each bounded,
same-owner transient as another exact `SLSHWCaptureStreamCreateWithWindow`
IOSurface. The frame descriptor carries the layer window ID, level, content
rect, and destination rect. MacWS Host retains one lease per layer and draws
the textures in level order with Metal. `layer_removed` explicitly retires a
closed transient.

This path contains no RFB encoder, zlib/hextile/tight compression, TCP 5900,
full-desktop crop, or CPU pixel copy. Base and transient producers have
independent three-frame lease bounds, so a static menu cannot consume the
base window's complete queue.

## Scroll pressure witness

A diagnostics-only Terminal instance published exact window 54. One scroll
change produced:

```text
APP-INPUT SCROLL-DISPATCH pid=1972 target-window=54 event-window=0 local=(500.00,324.87) delta=(0.00,420.00) route=NSWindow.sendEvent
```

The captured Host image visibly moved to older Terminal output. A subsequent
120-change stream took 2.003 seconds to send. The last corresponding frame
reported:

```text
display-perf stream=45 sequence=120 capture-to-receipt-ms=1.615 receipt-to-submit-ms=5.755 submit-to-complete-ms=2.633 status=4 error=nil
MACWS-DISPLAY throughput stream=45 window=54 layer=54 frames=120 elapsed=105.707 fps=1.13 outstanding=1 dropped=0
```

The `fps=1.13` field is a lifetime average from stream creation, including a
long static interval; it is not the 2.003-second stress rate. The valid
bounded-path witness is the approximately 10.003 ms final frame and zero
drops. A physical-gesture input-to-visible p95 remains an open acceptance
test.

Diagnostics were then disabled and Terminal was restarted into the production
profile. The resulting production process set was:

```text
1328  macwshostd
1342  MacWSHost
2487  /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
95371 macwsinputd
95615 macwsdisplayd
```

## Exact application instance reuse

Launching `macwshost://terminal` while Terminal was already running used to
spawn a second process. The first implementation compared the expected host
path `/var/mnt/rootfs/...` and missed the kernel's canonical
`/private/var/mnt/rootfs/...` path. Runtime `proc_pidpath` output exposed that
exact mismatch.

The production fix resolves the host path with `realpath` and compares the
complete executable path, not `p_comm`, display name, or bundle title. If the
matching process has valid PID-scoped window metrics it is reused; if it has
not published a capturable window, hostd explicitly refuses to create a
duplicate. The successful run recorded:

```text
1785496107.952 launch-app reuse id=terminal pid=99577 executable=/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal identity=proc_pidpath
1785496108.034 launch-auto-window app=terminal pid=99577 window=15 group=15
```

There was one matching Terminal process before and after that launch. Host
Scene identity is separately keyed by `owner PID + logical tab group` (or
exact window ID when no group exists), so requesting an already presented
window activates its existing Scene and duplicate connected Scenes are pruned
without closing the underlying macOS window.

## Keyboard layout contract

The iPad floating software keyboard is intentionally free to overlap and be
moved by the user. MacWS Host does not bind the Metal view to
`keyboardLayoutGuide` and does not resize the macOS window for keyboard frame
changes.

The Host-owned `Ctrl / Option / Command / Shift / Esc / Tab / arrows` row is a
different object. When the keyboard proxy becomes first responder, this row's
height changes from 0 to 52 points and the Metal view's bottom is constrained
to its top. Thus only this row reserves content space. It is not an
`inputAccessoryView`, so it cannot overlay the macOS pixels. While the proxy
is active, touching Metal does not steal first responder and immediately
dismiss the floating keyboard.

## Remaining acceptance work

- Physical long-press, two-finger scroll, Magic Keyboard click/right-click,
  Shift/Caps, and shortcut-row regression across Terminal and VSCode.
- Replace the semantic menu's UIKit alert-style expansion with a macOS-faithful
  adaptive light/dark panel, then qualify hover and keyboard navigation.
- Drag through every dense Stage Manager size while correlating Scene bounds,
  Metal drawable, AppKit frame, and exact input mapping.
- Four simultaneous foreground Scenes, app close propagation, transient-layer
  ownership, and 30-minute memory/thermal stability.
