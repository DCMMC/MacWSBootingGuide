# Fullscreen native three-finger gestures (2026-08-08)

## Product invariant

Fullscreen workspace gestures must behave like a physical MacBook trackpad.
MacWS Host must transport a continuous gesture; it must not decide the final
Mission Control, App Exposé, or Spaces action, synthesize a keyboard shortcut,
or present an iOS window-picker UI. Dock owns the animation, cancellation,
velocity policy, and final transition.

## Evidence from the target macOS image

The following is RE-confirmed from the arm64e slice of the macOS 13.4 Dock
binary copied from the device. The working files for the investigation were
`/tmp/macws-gesture-re.IXOqrU/Dock.arm64e` and
`/tmp/macws-gesture-re.IXOqrU/Dock.ipsw.objc`.

- `-[DOCKGestures handleEvent:]`, Dock `__TEXT+0x8d1b0`, accepts events whose
  integer field 110 is 23. It interprets field 132 values 1, 2, 4, and 8 as
  begin, change, end, and cancel, then drives handlers through
  `fluidGestureStart:`, `fluidGestureProgress:`, and `fluidGestureEnd:`.
- `-[DOCKGestureEvent initWithEvent:display:gesture:]`, Dock
  `__TEXT+0x47798`, reads signed progress from field 124, velocity from field
  129, direction from field 115, and reversal state from field 136.
- The navigation helper at Dock `__TEXT+0x8d508` reads the axis from field
  123: horizontal is 1 and vertical is 2. It derives left/right/up/down from
  the signed progress. With field 136 set to 1, horizontal progress greater
  than zero selects gesture slot 3 and vertical progress less than or equal
  to zero selects gesture slot 2. These are instructions at
  `__TEXT+0x8d590` and `__TEXT+0x8d5b0`, not inferred UIKit semantics.

This evidence rules out the previous one-shot Control+Arrow and Host-owned
window overview implementations: neither carries phase, progress, or velocity,
so neither can produce an interactive native animation.

## Implemented transport

`MacWSInputKindSystemGesture` carries a stable contact ID and one locked axis.
`pressure` is signed cumulative progress and `altitude` is progress per second.
The existing begin/change/end/cancel flags carry the gesture phase.

MacWS Host resolves Dock from displayd's real `GlobalSystemSurface` descriptor,
not from a process-name guess. `macwsinputd` keeps that explicit endpoint and
does not allow menu, hover, or front-application caches to redirect the record.
Dock's process-local AppInput bridge reconstructs the verified CGEvent fields
and passes the event on Dock's main queue to the real `DOCKGestures` singleton.
Each field is read back after construction; an event is dropped rather than
silently sent if CoreGraphics did not preserve the private value.

The first device probe caught one such alias before it reached Dock. Writing
field 117 after field 115 made `CGEventGetIntegerValueField(event, 115)` return
the field-117 contact value `860243792` instead of direction `1`. Progress,
velocity, axis, phase, and the other integer fields all read back exactly. This
is runtime-confirmed in `/var/jb/var/mobile/dock.log`, PID 97727. The target
Dock disassembly does not consume field 117, so it is no longer written;
contact identity remains a MacWS transport invariant rather than a fabricated
Dock event requirement.

The second device probe found an independent sign bug. UIKit finger-up has a
negative Y translation, but Host negated it and sent positive progress. LLDB
at `-[DOCKGestures _handlerForEvent:]` (`0x102af7688` in Dock PID 8252) showed
that positive vertical progress produced gesture slot 1 and returned `x0=0`.
The real `DOCKGestures` object at `0x11d81d4c0` had no slot-1 handler but had a
live slot-2 handler. The cached Dock preference object at `0x11c733580` had
byte `+0x12 = 1`; Dock `__TEXT+0x22078c` is the getter that reads that exact
byte for `showMissionControlGestureEnabledPref`.

Sending negative vertical progress instead produced slot 2. Stepping out of
`_handlerForEvent:` returned object `0x11d820200`; its stripped isa
`0x102ea1d90` maps in the target image to
`_TtC4Dock22FluidGestureController`. This is runtime confirmation that Dock's
native fluid controller, rather than a MacWS overview, owns the gesture. Host
therefore preserves UIKit's vertical sign while continuing to invert the
horizontal component required by Dock's slot-3 swipe-left convention. The
same pure conversion function is used for progress and velocity and has local
boundary tests.

The previous custom `UIAlertController` overview and Host haptic/status action
are removed from the three-finger path. The older desktop-command protocol is
retained only for wire compatibility and is no longer emitted by this gesture.

## Verification and stability witness

Local protocol boundary tests pass and the complete rootless production package
builds successfully.

A 121-record, 60 Hz, two-second upward probe with progress from `-0.007083` to
`-0.85` produced native Dock begin/end logs. The terminal capture
`/tmp/macws-native3f-after.png` visibly contains macOS's native Mission Control
Spaces strip with `Desktop` and its add-space button. WindowServer PID 8029 and
Dock PID 8252 both remained unchanged. The corresponding runtime log boundary
is:

```text
#### APP-INPUT DOCK-GESTURE pid=8252 axis=2 phase=0x140 progress=-0.007083 velocity=-0.425000 route=DOCKGestures.handleEvent
#### APP-INPUT DOCK-GESTURE pid=8252 axis=2 phase=0x440 progress=-0.850000 velocity=-0.425000 route=DOCKGestures.handleEvent
```

This verified the synthetic transport, Dock's native controller selection, and
the completed native Mission Control state. At that milestone it did **not**
yet verify the full interactive animation requested by the product invariant.

To test that stricter requirement, a clean Dock PID 13910 received a 24-sample
move to `-0.35`, held that changed phase for two seconds, then received cancel.
The held VNC frame changed 17,304 pixels, but its difference bounding box was
only `(0, 0, 1194, 21)`; the window/body pixels did not follow the gesture. The
post-cancel frame was byte-for-byte identical to baseline. Therefore only the
menu-bar portion was visibly interactive in VNC.

LLDB proves this is no longer an input-delivery failure. At Dock's
`FluidGestureController` progress dispatch, gesture and active gesture were
both 2, normalized progress was `d8=0.10000000149`, the native controller state
byte was 2, and the callback pointer stripped to target Dock
`__TEXT+0x2117bc`. That callback reaches Dock `__TEXT+0x211c24`, where the
target disassembly creates and commits an `SLSTransaction` and calls
`WindowManagerRemoteTransition.update(percent:)`. The missing body animation
is now downstream in the WindowManager/SkyLight render path, consistent with
the AGX/MPS errors below; it must not be papered over in Host.

During a bounded pre-install production start, the WindowServer reached graphics
ready, but its log later emitted the following runtime-confirmed failure while
the desktop agents were starting:

```text
Error: command buffer exited with error status. The Metal Performance Shaders operations encoded on it may not have completed. Internal Error (00000103:Internal Error)
```

That warning was investigated rather than hidden by reverting to the custom
overview. It exposed three independent downstream incompatibilities.

## Downstream native-animation repairs

### MPS subtype-3 command ABI

The exact iOS-native reference was captured with
`MPSImageStatisticsMean`. Its command buffer was `0x218` bytes and contained
one subtype-3 segment whose encoded command ended at `0x1d8`, with payload
size `0x1a8`. The matching macOS transition command contained two subtype-3
segments. Both were 16 bytes wider than the iOS ABI; the original translator
recognized only the second one.

The first segment has a separately runtime-confirmed signature: span `0x228`,
mode 2 at `+0x1f4`, a 20-byte zero run at `+0x1cc`, and twelve `0xff` bytes at
`+0x1e0`. The existing structural translator now recognizes that alternate
form, deletes the same macOS-only 16 bytes at `+0x1d0`, and updates all owning
ranges. It does not change a driver result. The successful diagnostic emitted:

```text
#### AGX_SUBMIT_DIAG #5 TEMP-KCMD-SEGMENT-LIST-FIX segment=1/2 subtype=3 range=0x228..0x438->0x428 shrink=0x10 storage=0x428 wrappedTail=NO
#### AGX_SUBMIT_DIAG #5 TEMP-KCMD-SEGMENT-LIST-FIX segment=0/2 subtype=3 range=0..0x228->0x218 shrink=0x10 storage=0x418 wrappedTail=NO
```

The `TEMP` prefix is intentional: this is a byte-exact compatibility
translator backed by native/macOS command captures, but the private ABI still
needs broader command-family coverage before it should be called a general
AGX fix.

### QuartzCore Mission Control shaders

After the MPS repair, the native transition reached its real copy and blur
passes. AGX rejected two exact pairs from Ventura QuartzCore with
`MTLLibraryErrorDomain/AGXMetal13_3 code 3`, `Target OS is incompatible`:

- `std_vert1_lph` + `inplace_copy_lph`;
- `downsample_blur_vert_lph` + `downsample_8_frag_lph`.

`postinst.sh` now builds a byte-validated secondary QuartzCore library in
which only nine runtime-confirmed functions have a macabi AIR triple. The
original system library remains the process-wide default, and the real
function constants and descriptors are forwarded to the compatible copy.
The installed artifact is 1,047,040 bytes with SHA-256
`0cc979fb9a44ca2b7675bb73fcae02bbfa472f7498aa51bd543229927392f8e2`.
The same formerly failing pipeline then returned a real native object:

```text
vertex=downsample_blur_vert_lph fragment=downsample_8_frag_lph ... result=0x12f8ce000 class=AGXG13GFamilyRenderPipeline errorDomain=(not-requested-or-nil)
```

### SkyLight UberComposite specialization

With a real Terminal window present, a deeper transition still crashed at
`MetalShader::CopyPipelineState+0x140`, fault address `0x28`. The crash
registers had `x19=0`; target disassembly shows `x19` is the `MetalShader *`
`this` argument and the faulting instruction is `ldr x8, [x19,#0x28]`.
The caller disassembly at `MetalBacking::RenderToDestination+0x28c` showed
that this nil came directly from `ShaderComposer::UberComposite`.

Logging at the upstream specialization boundary then produced the actual
cause, not a theory:

```text
#### SKYLIGHT-UBER-SPECIALIZE ... name=UberCompositeVertex ... function=0x1258c3c60 errorDomain=(nil)
#### SKYLIGHT-UBER-SPECIALIZE ... name=UberCompositeFragment ... function=0x0 errorDomain=MTLLibraryErrorDomain errorCode=3 description=Target OS is incompatible.
```

The SkyLight compatibility library therefore adds only that
runtime-confirmed `UberCompositeFragment` module to the existing two Simple*
modules. It is 707,456 bytes with SHA-256
`990803db710c494ff98155983cc9d3134c131e1ddbf3ce9e4468a3013134ffd6`.
No nil guard was added to `CopyPipelineState`, and no failure result is
replaced. Repeating the same constants produced real UberComposite pipeline
objects and kept WindowServer alive.

## Final production witness

The final run used ordinary `start coexist --runtime-cap=180`; its production
preflight confirmed native AGX on and all diagnostic sentinels/environment
traces off. A real Terminal window was visible while a 34-record, 60 Hz
vertical gesture moved continuously to `-0.42`, held for two seconds, and
cancelled.

- WindowServer PID `79678`, Dock PID `79945`, Terminal PID `80022`, and VNC
  PID `79999` were identical before and after the gesture.
- The held frame visibly contains macOS's real Spaces strip and selected
  `Desktop` thumbnail. It is not a Host/UIKit view.
- `production-baseline-final.png` and
  `production-after-cancel-final.png` are byte-for-byte identical, both
  SHA-256 `bdeea7a10624fda1312392ac8d145981ade3dd95ea6e5f32f949e996d5880e03`.
  The held native-animation frame is different, SHA-256
  `198652adb3f8178d5db39d8d47b672fbf73f54e6a5c4b6818c5b53129f7a42be`.
- Thermal state stayed `nominal`; the final sample was 31.19 °C.

This is runtime evidence for continuous native Dock animation and exact
cancel restoration through the production AGX/VNC path. A physical-touch
witness still requires closing and reopening the already-running Host app so
its UIKit process loads the newly installed executable; a pre-install process
cannot acquire new code in place.

## 2026-08-08 four-direction completion and presentation pacing

The remaining direction failures were two independent stock-macOS
preconditions, not missing Host gesture recognizers.

Target Dock `-[DOCKGestures _handlerForEvent:]` was disassembled through both
branches. Horizontal positive/negative progress selects handler slots 3/4;
vertical positive/negative selects slots 1/2. Runtime LLDB and event readback
confirmed that the bridge delivered those exact signs. A cold preferences
database, however, did not contain Dock's real
`showAppExposeGestureEnabled` preference, so the slot-1 handler was nil.
Production startup now writes and reads back both
`showMissionControlGestureEnabled` and `showAppExposeGestureEnabled` before
Dock launches. Startup fails instead of silently exposing a half-configured
gesture controller if either value cannot be persisted.

The initial managed-space catalog contained exactly one real Space. That makes
both horizontal edge gestures stock Dock no-ops. The new read-only
`macwsworkspacectl list-spaces` command uses the target-exported
`SLS/CGSMainConnectionID` and `SLS/CGSCopyManagedDisplaySpaces` APIs to make
this topology visible. `CGSSpaceCreate` was RE-confirmed from Ventura call
sites as `(connection, type, options) -> uint64_t`, then runtime-confirmed on
the device: a created Space appeared in the same authoritative catalog and a
positive two-second gesture changed Current Space `1 -> 2`; the negative
gesture changed it back `2 -> 1`, with the same WindowServer and Dock PIDs.

Production now invokes the idempotent
`ensure-navigation-spaces` command after WindowServer is ready but before
Dock starts. A one-Space cold session gets exactly one adjacent native Desktop;
an existing two-or-more-Space user topology is preserved. The validated cold
start printed:

```text
Native macOS desktop navigation topology ready: navigation-spaces ready before=1 after=2 created=2
```

This ordering matters. A diagnostic that created a Space and then unloaded a
live Dock caused WindowServer to restart while displayd was retiring Dock's
full-Retina streams. That run was rejected as evidence and the full GUI stack
was stopped. Production never reloads Dock for this feature.

### Why the animation had looked much slower than the input

AppInput diagnostics on Dock PID 99804 received 119 Changed records at 120 Hz,
delivered 115 to the real `DOCKGestures.handleEvent:`, and coalesced only 4.
This runtime result rules out the HID broker and Dock main-queue coalescer as
the remaining frame-rate bottleneck.

Dock's fluid controllers update SkyLight compositor geometry without passing
through the AppKit NSWindow sidecar. displayd previously discovered those
positions only through its one-second recovery catalog scan. The native
handler now sends one lightweight `a` invalidation after it consumes a sample;
displayd temporarily samples authoritative CGWindow geometry at display
cadence and republishes each retained IOSurface at its new destination. It
does not create an animation or choose a transition.

The first implementation still waited a full 16 ms *after* each Retina
catalog scan. Its period was therefore `scan time + 16 ms`, and a moving Dock
desktop layer retired at only 19.85 fps. The production loop now subtracts
the completed scan time from the 60-Hz period and runs the next pass
immediately when a scan has already consumed the budget. This high-rate mode
is bounded to 250 ms after the last native gesture sample. The Dock notifier
also reuses one nonblocking Unix datagram socket instead of creating and
closing a socket on every main-thread sample.

The installed production A/B showed:

- before animation sampling, a two-second Space transition caused only 46
  Host texture imports over 5.066 seconds;
- the first event-driven version caused 476 imports over 5.123 seconds
  (10.3 times the aggregate presentation work);
- after period compensation, a 1.5-second App Exposé gesture increased Host
  imports `2864 -> 3261` over 3.051 seconds and its primary Dock layer reached
  sequence 98 while still updating;
- the cold-start two-Space build completed horizontal Current Space `1 -> 2`
  and `2 -> 1`, and vertical positive/negative gestures entered and left the
  native Dock views;
- no new crash report appeared during the accepted four-direction run. The
  final device sample was thermal `nominal`, 34.09 °C. The mandatory watchdog
  remains 300-second, Critical-only, with its memory guard disabled.

The final rootless production package is
`com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb`, SHA-256
`c2f09a57e4b1d7c9db14413de1aa20cf9b31baa65d981c58eb817e764a4f60d5`.

This closes the four-direction functional gap and removes the artificial
post-scan delay. It is not a claim that every complex Mission Control scene is
now identical to a MacBook at 60 fps: CGWindow catalog work and the number of
simultaneous Retina layers remain measurable costs.
