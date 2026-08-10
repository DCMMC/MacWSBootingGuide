# WindowServer-owned input routing and cold ViewBridge trust (2026-08-11)

This milestone removes two upstream failures that presented as gray traffic
lights, clicks that worked in some controls but not others, and application
main-thread stalls. It does not special-case Terminal, VSCode, Dock, Finder, or
individual controls.

## ViewBridge cold-start failure

The outer `launchdchrootexec` proxy and the real Ventura XPC target are separate
executables with separate CodeDirectories. Before repair, launchd reported the
ViewBridge job as repeatedly scheduled with an `OS_REASON_EXEC` last exit and
no live process. The installed proxy's arm64e CDHash was trusted, but the real
target's arm64e CDHash was not:

```text
proxy  99ee460c93e5b749e1ff65a059e0c42d3fd1f0d3  trusted
target ed64fdad1a2a4252563fa06bff2da3eb33fb4c33  not trusted
```

The target is:

```text
/System/Library/PrivateFrameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc/Contents/MacOS/ViewBridgeAuxiliary
```

After registering that existing CodeDirectory and hot-kicking only the
ViewBridge job, launchd reported `state = running`, the process executed the
real Ventura target, and its fresh log showed `libmachook` loaded. No binary
was modified and no execution check was bypassed.

`restore_cold_boot_trust()` now includes the real ViewBridge, UIKitSystem,
OpenAndSavePanel and ExtensionKit targets. ExtensionKit independently changed
from `spawn scheduled / OS_REASON_EXEC` to a running real Ventura service after
the same trust restoration, validating that this is the correct cold-start
layer.

## Why global clicks deactivated every application

RE-confirmed against macOS 13.4 SkyLight:
`SLSCopyWindowRoutingRecordsForScreenLocation` returns WindowServer's ordered
routing chain for a Quartz point and `SLSConnectionGetPID` resolves the deepest
destination.

The first SkyLight implementation returned only PID/window identity. Its four
AppKit readiness booleans remained zero, so every click was interpreted as an
inactive target. Runtime diagnostics recorded the broken invariant as:

```text
repair=YES deactivated=10
```

At the same time, each ordinary RFB click broadcast a target probe to every
AppKit main thread and waited up to 150 ms. Busy menu/layout/ViewBridge threads
often produced only 3-8 replies, so a visible WindowServer hit could be lost or
delayed by unrelated applications.

The production path now uses WindowServer routing for both target-probe and
activation records. It obtains the actual session front owner with the public
HIServices `GetFrontProcess`/`GetProcessPID` transaction. A matching owner is
already ready; a different owner receives exactly one activation transaction.
The AppKit broadcast remains only as an API-unavailable compatibility fallback.

Runtime diagnostics for repeated clicks in the selected application now show:

```text
MACWS-INPUT FRONT-OWNER routed=25351 front=25351 ready=YES
MACWS-INPUT ACTIVATE seq=62 kind=activate-target target=25351 window=61 repair=NO menu-preflight=NO deactivated=0 sent=SKIPPED errno=0
```

A Dock click was independently resolved to the real Dock surface:

```text
MACWS-INPUT SLS-ROUTE point=(950.00,800.00) connection=76047 pid=20197 window=8 depth=1/1
```

It activated Terminal and changed the system menubar; no fullscreen transparent
Dock/Finder window intercepted the click. A subsequent native Terminal Window
menu click resolved to Terminal PID 20270/window 13 with
`front=20270 ready=YES` and opened the real AppKit menu. The menu's window items
were disabled because that Terminal process had no live window, an independent
window/session-lifecycle issue rather than an input hit-test failure.

## Acceptance

The Retina VNC InputLab matrix passed left click, drag, right click, scroll,
normal keys, Shift uppercase, Caps Lock uppercase, Control, Command, Tab,
Backspace, Return and Escape. AppKit delivery latency was:

```text
median 4.668 ms
min    0.306 ms
max   43.500 ms
```

After the acceptance run, the runtime diagnostic sentinel was disabled and
only `macwsinputd` plus OSXvnc were hot-restarted. WindowServer, Dock, Finder,
applications and iOS remained running. A production-mode click dismissed the
native Terminal menu and activated System Settings with colored traffic lights.

Both thermal guards remained enabled: 300-second samples, intervention only
for the Critical state, and no iPad free-memory guard.
