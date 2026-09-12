# v53: final geometry and focus acceptance, remaining animation failures

Status: **partial**, not an all-issues-fixed report. This supersedes the pending
v52 status in [v51 evidence](window-resize-native-lifecycle-v51-20260912.md).
Tests used real iPadOS HID contacts and full 2778×1940 native screenshots,
not the Host's own reconstructed screenshot or process uptime.

## Installed scope

- Host v53 SHA-256: `36b51b380455cec484972ff83337bf012ef00286cdb61322147d9364b4d8162d`.
- Host PID4149, SpringBoard PID158, WindowServer PID76954.
- v52 and v53 each reloaded **Host only**, not SpringBoard or WindowServer.
  The preceding v51 native gesture hook required one SpringBoard reload.
- v51 Windowing and v50 AppInput remain installed. Host v52 is recoverable at
  `/var/mobile/Media/macws-v53-animation-settlement/backups/MacWSHost`.
- Current test windows: Finder PID98948, browser318, About316, Info317;
  Terminal PID97632/window304. Native and iOS window identities are separate.

## Actual failure that drove v53

v52's actual-UIKit-bounds comparison fixed a false completion witness, but
`tmp/v52-getinfo-expand-general/frame-011.png` still showed “窗口太小” at 150%.
Runtime-confirmed via Host logs: the first in-flight AppKit animation size was
466 points, later policies carried 552 then555, while the completed UIKit
Scene remained879 points tall. Native555 at density1.5 plus48 chrome requires
880.5, not879. Publishing a newer policy without retaining a geometry successor
lost the terminal size. Rounding a minimum downward also cannot satisfy it.

v53 therefore:

1. Ceils minimum Scene extents and fixed axes, and never rounds a preferred
   extent below that minimum. It does **not** disable the too-small check.
2. Retains one latest AppKit animation geometry, with exact owner/window
   identity, while its predecessor Scene transaction is in flight. Replays it
   after completion only if a newer native gesture/configure does not own the
   geometry. No observed response is cached as a permanent minimum.
3. Preserves an active, deadline-bounded Scene-follow transaction through a
   subscription reconfiguration **only** for the same PID/window. Suspension,
   target replacement and expired transactions still cancel it.

The third change compiled and passed source-contract tests. The v53 restoration
test did not require a size correction, so it is **not** a runtime acceptance
of restoration under stale geometry. Host restoration grouping remains open.

## Visually checked results

| Case | Result and artifact |
|---|---|
| Get Info collapse, 150%, two Scenes | Final399×684 correct; About retained. `tmp/v53-general-collapse-1/frame-011.png`. Frame003 still has transient black bands: animation gate FAIL. |
| Get Info expansion, 150%, two Scenes | Final399×881, no too-small warning. `tmp/v53-general-expand-1/frame-011.png`. |
| Same collapse/expansion with four Scenes | All four retained in `tmp/v53-general-collapse-four/frame-011.png` and `tmp/v53-general-expand-four/frame-011.png`; final geometry correct. Collapse frame003 still fails transient-band gate. |
| Finder native corner drag with same-contact400ms pause | Resumed movement continued to new Configure ACKs. Native constraint returned445-point width; UIKit settled668×446 at150%. Four Scenes retained in `tmp/v53-finder-shrink-four/frame-011.png`. |
| Terminal→Finder→Terminal through Host/iOS chrome only | Exact native Focused flags switched304→318→304. `tmp/v53-finder-shrink-four/frame-011.png` shows active Finder, `tmp/v53-focus-terminal-confirmed.png` active Terminal; no macOS-content activation click. |
| 125%/150% choices | Real Control Center selection: Terminal48×17 at125% vs40×14 at150%. `tmp/v53-density125-terminal.png`, `tmp/v53-focus-terminal-confirmed.png`. Source-native drawable sampling retained. |
| Control Center | `tmp/v53-controls-terminal.png`: three density choices, compact menu affordance, adaptive ThinMaterial card. Colorful-backdrop and dark-appearance quality still require acceptance. |

Verbatim runtime witnesses from `tmp/window-v53-host.log`:

```text
1789183913.666 window-size appkit-animation deferred window=317 pid=98948 latest=266.0x555.0
1789183913.877 window-size follows-appkit window=317 pid=98948 reason=appkit-animation-latest logical=266.0x555.0 density=1.500 chrome=0.0x48.0 scene=399.0x881.0 fixed=NOxYES requested=YES
1789183913.988 window-configuration scene-follow reached window=317 pid=98948 logical=266.0x555.3 after-deadline=NO
1789183914.245 scene-native-size result id=C80D7F41-1DB8-4364-8FD3-639A7208C5D9 fbs=sceneID:com.macwsguide.host-C80D7F41-1DB8-4364-8FD3-639A7208C5D9 requested=399.0x881.0 windowed-role=NO fills-screen=NO bounds=399.0x881.0 landed=YES stage=request-completed-early
1789183640.700 native-resize-gesture scene=sceneID:com.macwsguide.host-1B52C85E-4E43-40C9-9672-176DC78951DD window=318 active=YES
1789183641.906 native-resize-gesture scene=sceneID:com.macwsguide.host-1B52C85E-4E43-40C9-9672-176DC78951DD window=318 active=NO
1789183642.010 window-configuration ack window=318 pid=98948 sequence=16 request-time=88254.314025 requested=317.3x265.0 applied=445.0x265.0 queued=317.3x265.0 result=constrained
1789183607.132 scene-focus request reason=_UIWindowDidBecomeApplicationKeyNotification scene=1B52C85E-4E43-40C9-9672-176DC78951DD window=318 pid=98948 application-key=YES issued=YES
1789183704.838 scene-focus request reason=_UIWindowDidBecomeApplicationKeyNotification scene=D2500D4E-4773-48E8-B95D-1ED4489123B2 window=304 pid=97632 application-key=YES issued=YES
1789183778.544 host-drawable-policy window=304 bounds=673.00x565.00 previous=1080x920 source=1076x904 drawable=1077x904 display-scale=2.000 backing=2.000 density=1.250 policy=source-native-auto fullscreen-canvas=NO
```

Read-only native metrics independently reported Finder generation85/window318
flags77 (`visible`, `has_shadow`, `resizable`, `focused`), mtime1789183607.2337768;
Terminal generation55/window304 flags77, mtime1789183704.924379. These are
native focus witnesses, not mere successful ActivateTarget sends. A first
screenshot immediately after injection can precede activation; the later
confirmed images above were inspected as well.

`tmp/window-v53-windowing.log` independently retained all exact Scene identities:

```text
1789183914.089 resize-postcondition scene=sceneID:com.macwsguide.host-C80D7F41-1DB8-4364-8FD3-639A7208C5D9 landed=YES role-landed=YES size-landed=YES role=5 center=0 environment=1 expected-windowed=NO expected=399.0x881.0 actual=399.0x881.0 size-api=YES samples=1 transaction-attempt=1 stage-members-preserved=YES current-items=sceneID:com.macwsguide.host-D2500D4E-4773-48E8-B95D-1ED4489123B2,sceneID:com.macwsguide.host-1B52C85E-4E43-40C9-9672-176DC78951DD,sceneID:com.macwsguide.host-C80D7F41-1DB8-4364-8FD3-639A7208C5D9,sceneID:com.macwsguide.host-6E6F2BAC-5022-471A-AE35-4641FBD4BC1D visual-acceptance=UNVERIFIED
```

## Test harness correction

The old menu probe passed window317 with Close Window, but the then-active
browser310 closed. The native catalog at1789183119.499227 still contained317
and316, not310. This was a failed diagnostic, **not** proof of an Info close.
The browser was reopened via a guarded New Finder Window action as318.

`MacWSMenuActionOnMainThread` deliberately leaves ordering to the Host's
explicit ActivateTarget and executes the native responder action. A window ID
binds the cached menu snapshot, not that responder's focus. The probe now
requires exact native focus before snapshot and again before dispatch, and
prints `action-accepted ... completion=UNVERIFIED`. It never activates by itself.
This guard is point-in-time, not an atomic completion guarantee.

Runtime negative test (Info317 focused, requested About316):

```text
RuntimeError: refusing menu action: requested pid=98948 window=316, native focused windows=[317]; activate the exact window first
```

## Selective compositor diagnostic: still blocked, not a fix

The bounded selective capture helper still refuses to create a stream without
native capture permission. An explicit standard
[CGRequestScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess())
attempt returned false immediately, without obtaining permission. An isolated
helper signed/trusted with `com.apple.private.tcc.allow =
[kTCCServiceScreenCapture]` also returned false. No shared signing profile or
TCC database was modified; no check was hooked or forced.

Verbatim second diagnostic output (helper SHA-256
`27a85634bf0b5a3858bfb564db9da5725177df6b35d5e710271b5475bf095498`):

```text
{"capture_started":false,"wall_time":1789184125.908313,"event":"consent-before","monotonic":90754.381769,"granted":false}
{"capture_started":false,"monotonic":90754.382077999995,"wall_time":1789184125.908597,"request_returned":false,"event":"consent-after","granted":false}
```

Actual-binary RE, installed Ventura SkyLight, bounded reads only:

- CGPreflightScreenCaptureAccess1851df928 branches to18520d678.
- CGRequestScreenCaptureAccess1851df92c reaches18520d3b8 via singleton18520d6c8.
- 18520cfb0 selects preflight/request pointers;18520d1f8 opens
  `/System/Library/PrivateFrameworks/TCC.framework/TCC` and resolves
  `TCCAccessPreflight` (string1854b5423). A missing pointer has its own
  false-return path18520d150.

This establishes the dependency, **not** which rejection path ran. THEORY:
chroot TCC routing/availability may differ; confirming it requires actual
symbol-resolution and TCC reply evidence. Do not label another entitlement or
a forced preflight return a rendering fix. Window-mode final composition,
QuickLook animation and Weather graphics remain unresolved.

## Remaining gates and local checks

- Fast resize/transient black bands: FAIL, despite correct final sizes.
- Redundant SpringBoard model retry: still observed after Finder shrink;
  UIKit had already settled while a model lookup retained476×445.5. Do not
  weaken the model postcondition just to suppress the retry.
- Host restoration without regrouping/secondary geometry changes: pending.
- Non-macPad stock grids: scoped code/logs retain stock path; no broad visual
  stock-app resizing acceptance in this segment.
- Pixel Match is retained, but this segment visually compared125% and150%,
  not a fresh Pixel Match round trip. Active Terminal ends at125%; other
  existing Scenes retain their own current density.
- 42 Python contract/unit tests pass; causal ACK/Scene-bounds and drawable
  sampling C tests pass. Host v53 and both diagnostics compile; Host and
  diagnostic code signatures were strictly verified. `git diff --check` passes.

No claim of all requested issues solved; no Git commit/push in this segment.
