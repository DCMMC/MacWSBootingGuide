# Stage Manager focus and native Host chrome

Status: implemented and deployed. Application-key notification delivery and
exact native focus are now runtime-confirmed by the v51 chrome-only Terminal
selection and screenshot. See [device acceptance](window-resize-native-lifecycle-v51-20260912.md).
Control Center labels and 125%/150% choices were visually checked. The v53
Terminal→Finder→Terminal chrome-only focus test also passed; see
[v53 acceptance](window-v53-acceptance-20260912.md). Dark appearance and
colorful menu backdrop quality are still release gates.

## Focus evidence

Runtime-confirmed via `/var/mobile/Library/Logs/MacWSHost.log`; these adjacent
lines were copied from the current iPad:

```text
1789158098.318 scene-became-active id=591D8813-A393-414E-8A02-6BDCD2E4A5C0 state=0
1789158098.319 scene-active activates-appkit id=591D8813-A393-414E-8A02-6BDCD2E4A5C0 activated=YES
1789158098.324 scene-became-active id=35053FB5-46CE-4361-BC39-D2CB78B9259F state=0
1789158098.324 scene-active activates-appkit id=35053FB5-46CE-4361-BC39-D2CB78B9259F activated=YES
1789158098.330 scene-became-active id=957377D4-B7D8-41A2-9040-E3AAE5EBE82F state=0
1789158098.330 scene-active activates-appkit id=957377D4-B7D8-41A2-9040-E3AAE5EBE82F activated=YES
```

The old conditional required `self.window.isKeyWindow`, so this establishes
that three different Scenes satisfied that predicate during the same Stage
activation. It does not establish successful input delivery: the old
`activated=YES` merely reported construction of an activation record.

RE-confirmed through bounded reads of the actual UIKitCore 20D67 cache:

```text
0x189170a48 _isApplicationKeyWindow B16@0:8
0x189312d2c _isKeyWindowScene B16@0:8
0x1893ae61c _isTargetOfKeyboardEventDeferringEnvironment B16@0:8
```

The first method obtains `_UIKeyWindowEvaluator.sharedEvaluator`, reads its
selected window at offset 200, then compares that object with its receiver:

```text
0x189170a6c 	mov	x19, x0
0x189170a70 	cbz	x0, #12
0x189170a74 	ldr	x8, [x19, #200]
0x189170a78 	bl	#59160136
0x189170a7c 	cmp	x0, x20
0x189170a80 	cset	w20, eq
```

The same image's 731151-byte `__cstring` section contains:

```text
_UIWindowDidBecomeApplicationKeyNotification
_UISceneDidBecomeTargetOfKeyboardEventDeferringEnvironmentNotification
```

Only the small class metadata, named string section, and individual function
ranges were read; no full IPSW/cache extraction or process attachment was used.
The strings establish the available notification names, not that a particular
user gesture delivered one; the new runtime logs are needed for that witness.

## Implemented focus boundary

- Observe application-key-window and keyboard-deferral-target changes.
- After one UIKit main-queue turn, only the application-wide key UIWindow may
  activate its exact owner PID/window ID through the existing input broker.
- Scene-local `becomeKeyWindow` and `sceneDidBecomeActive` are fallbacks to that
  same checked route, not independent activation authorities.
- Controller-driven first-responder restoration likewise cannot claim keyboard
  ownership for another active-but-unselected Scene.
- Every ActivateTarget now records actual transport success/error, independently
  of broad diagnostics. `scene-focus request` is an issued-request witness,
  not an AppKit acceptance claim; the catalog must confirm its exact Focused ID.
- This path does not activate a UIKit Scene or follow passive macOS focus back
  into Stage Manager.

Background AppKit size updates publish only policy and retain their latest
exact geometry. The geometry is applied once on return to the foreground,
instead of being lost when `_windowPreferredSize` was already updated. A pending
resize completion that finds its Scene backgrounded does not configure AppKit
back to stale hidden UIKit bounds.

## Native chrome and density

The control card and compact semantic menu now use adaptive UIKit SystemThinMaterial
(v52 onward), with clear content/table backgrounds rather than an opaque fill over
the blur. The menu bar uses 14-point text in a 24-point content row. The iPadOS
safe-area strip is retained; initial Scene sizing and subsequent geometry use
the same 24-point chrome constant.

Selectable density is pixel matching, 125%, or 150%. Persisted more-space mode
migrates to pixel matching; the old explicit 110% mode migrates to 125%.
Only logical sizing factors, preference migration, and labels changed. The
corrected drawable algorithm still preserves source-native Retina sampling;
enlargement necessarily enlarges those source pixels and is not advertised as
exact pixel matching.

## Local checks and required acceptance

`MacWSHost` compiles and links for arm64. The C protocol validators, causal ACK
tests, and drawable sampling tests pass, including preference migration and new
125%/150% matching, letterbox, and cropped geometries. No DPI or ConfigureWindow
ACK implementation was replaced for this feature.

Required device checks:

1. Select existing Stage Manager window A then B without clicking macOS content.
   The new application-key notification should emit ActivateTarget for B, and
   the next native catalog must mark B's exact ID Focused.
2. Other co-visible Scenes may log `scene-focus skipped`; they must not emit a
   later activation that restores A. An unrelated iOS app must not be displaced.
3. Open semantic menus and Control Center over colorful content, in light and
   dark appearance; use iPadOS screenshots to judge real blur, contrast, safe
   area, and the compact control affordance.
4. Check the three density choices, reopening/restoration, and source/drawable
   logs. Fixed-axis sizing must include the selected logical factor while the
   source Retina budget stays independent of the previous drawable.
5. Change a background Mac app's own size, return to its Stage, and confirm the
   latest deferred size follows once without raising that Stage prematurely.
