# Fullscreen input and document Scene foreground — 2026-09-07

## Fullscreen input regression boundary

The running `macwsinputd` had already been replaced with the input ABI-6
build, while the long-lived Dock process still mapped the preceding ABI-5
`libmachook`.  LLDB disassembly of `MacWSInputRecordIsValid` in that live Dock
process showed the exact rejection gate:

```text
ldrh w8, [x8, #0x4]
cmp w8, #0x5
b.ne
```

Fullscreen pointer events always use Dock as the WindowServer-connected event
poster.  An ABI-6 Host/broker record therefore reached the PID-specific Dock
socket but was rejected before Dock posted it.  Window-mode input could still
work because it used a different, already refreshed AppKit endpoint.

ABI 6 added only `OpenDocuments`; the packed input record remains 84 bytes.
The repaired wire contract is consequently:

- kinds 1–23 are emitted as ABI 5 and accepted as ABI 5 or 6;
- kind 24 (`OpenDocuments`) is emitted and accepted only as ABI 6;
- package installation reloads a loaded `macwsinputd` and Dock after replacing
  their mapped binaries.

This keeps document sidecar handling fail-closed while allowing a rolling
upgrade to preserve all pre-existing pointer, keyboard and gesture kinds.

The installed package printed the receiver refresh witnesses:

```text
Reloaded live input job UIKitApplication:com.macwsguide.input.
Reloaded live input job com.macwsguide.dock.
```

The replacement broker then reported the compatible ABI range:

```text
MACWS-INPUT READY socket=/private/tmp/macws_host_input.sock abi=5-6 record=84 display=1 bounds=(0,0 1194x834) pixels=1194x834 postAccess=NO targetSocket=READY
```

## Fullscreen end-to-end witness

After entering fullscreen, UIKit reported that the Scene filled the real
screen:

```text
scene-maximization UIKit-observation session=E1FA027A-DEC7-400F-95B7-939FF2160873 expected-fullscreen=YES is-fullscreen=NO fills-screen=YES bounds={{0, 0}, {1389, 970}} screen={{0, 0}, {1389, 970}} authoritative-postcondition=UIKit-scene-screen-geometry
```

A diagnostic tap on the Finder Dock tile used the same controller and broker
boundary as a physical touch.  The Host emitted ABI 5, the broker routed it to
the newly loaded Dock PID 37304, and the visible fullscreen target changed
from Terminal PID 33580 to Finder PID 28329:

```text
input synthetic kind=tap wire=5 routed-through-controller scene=eaf879d1502b54ff target=0 point=(120.00,1610.00) frame=2388x1668
MACWS-INPUT RX seq=123 scene=d02b54ff kind=tap target=37304 frame=(120.00,1610.00)/2388x1668 quartz=(60.00,805.00) event=1 created=NO post=issued route_errno=0 cursor=unavailable(-1.00,-1.00) samples=0 capture=0
MACWS-INPUT ROUTE seq=123 route=appkit-socket pid=37304 window=212
presentation-target-change previous=33580 next=28329 direct-heartbeat=0/0 fullscreen-canvas=0/0 mode=1
fullscreen-input-target pid=28329 window=34 source=frontmost-presented-layer title=root
```

This is a rendered-state witness, not process-uptime evidence: the same tap
changed WindowServer's frontmost application and the Host's presented pixels.

## Finder document window foreground postcondition

The document-open transaction and the iPadOS Scene activation are separate.
The target AppKit application can accept the document while FrontBoard leaves
an existing or newly connected Scene behind another Stage Manager window.
`MacWSHost` now verifies the real `UIScene.activationState` after every
document/window activation and retries the same public
`requestSceneSessionActivation` transaction at most twice when it is not
`ForegroundActive`.  The check covers both a new connection and reuse of an
already connected Scene.

Opening the PNG produced an exact Preview window in the live CoreGraphics
catalog:

```text
window=52 pid=28952 owner=Preview name=IMG_0120.png layer=0 alpha=1.0 onscreen=true bounds=(4,29 933x703)
```

The matching iPadOS Scene was then connected and reached the foreground
postcondition immediately:

```text
scene-activation requested supportsMultiple=YES connected=2 open=2 origin=892EC4B5-EB5A-429C-802A-329533068CD5 window=52
scene-connected id=F57169A8-F89F-4D6F-969A-3DF0E858D081 role=UIWindowSceneSessionRoleApplication mode=2 window=52
scene-became-active id=F57169A8-F89F-4D6F-969A-3DF0E858D081 state=0
scene-foreground-postcondition id=F57169A8-F89F-4D6F-969A-3DF0E858D081 attempt=0 state=0
```

Reactivating the already connected Preview Scene exercised the reuse path
without reconnecting it:

```text
scene-activation requested supportsMultiple=YES connected=2 open=5 origin=F57169A8-F89F-4D6F-969A-3DF0E858D081 window=52
scene-activation reusing id=F57169A8-F89F-4D6F-969A-3DF0E858D081 owner=28952 group=0 window=52
scene-foreground-postcondition id=F57169A8-F89F-4D6F-969A-3DF0E858D081 attempt=0 state=0
```
