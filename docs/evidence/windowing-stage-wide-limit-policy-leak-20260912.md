# Fixed-window policy leaked into Stage Manager's whole-stage size limit

Status: root cause established from the running device's exact dyld cache;
the correction has not yet been visually accepted. Earlier v46 success claims
based on model values and process uptime were invalid.

## Exact binary and bounded read method

Device: `root@192.168.1.7:2222`, iPadOS 16.3.1 / 20D67.

SpringBoard is the cache image at unslid base `0x1c7598000`:
`/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard`.
Text is in
`/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e.21`,
mapping base `0x1c3230000`, file offset zero. Reads were small bounded ranges
through `misc/disasm_remote_dyld_range.sh`; no full cache extraction, IPSW
decompilation, LLDB attachment, or SpringBoard restart was used for this audit.

The exact Objective-C method metadata, decoded read-only from that cache:

```text
0x1c78b3bac frameForLayoutRole:inAppLayout:containerOrientation:windowScene: {CGRect={CGPoint=dd}{CGSize=dd}}48@0:8q16@24q32@40
0x1c78b3e30 _frameForLayoutRole:inAppLayout:containerBounds:containerOrientation:chamoisLayoutAttributes:floatingDockHeight:screenScale:isChamoisWindowingUIEnabled:prefersStripHidden:prefersDockHidden:skipAutoLayout: {CGRect={CGPoint=dd}{CGSize=dd}}112@0:8q16@24{CGRect={CGPoint=dd}{CGSize=dd}}32q64@72d80d88B96B100B104B108
0x1c78b50d0 _appLayoutByPerformingAutoLayoutIfNeededInAppLayout:containerOrientation:chamoisLayoutAttributes:floatingDockHeight:screenScale:draggingItem:overlappingModelBeforeDragging:bounds:prefersStripHidden:prefersDockHidden: @112@0:8@16q24@32d40d48@56@64{CGRect={CGPoint=dd}{CGSize=dd}}72B104B108
```

## RE-confirmed mechanism

The upper convenience frame method enters the lower frame method. The lower
method calls whole-layout auto-layout before computing the requested item's
frame (`0x1c78b3ef8`). Auto-layout first calculates a **whole-stage maximum**
size using `maximumWindowWidthForOverlapping` and the container height. It calls
the same `nearestGridSize...` method that MacWSWindowing hooks for item sizing:

```text
0x1c78b51f8 stub 0x1c802e6e0 ref 0x1d7d50f78 _chamoisLayoutGridCache
0x1c78b5208 stub 0x1c8099ec0 ref 0x1d7d70340 maximumWindowWidthForOverlapping
0x1c78b527c stub 0x1c809bce0 ref 0x1d7d70ce0 nearestGridSizeForProposedSize:countOnStage:inBounds:contentOrientation:layoutRestrictionInfo:screenScale:chamoisLayoutAttributes:
```

The returned limit is stored before iteration:

```text
0x1c78b527c bl #8284772
0x1c78b5280 str d0, [sp, #208]
0x1c78b5284 str d1, [sp, #192]
```

It then enumerates all items (`allItems` at `0x1c78b52d8`), resolves their
individual roles (`layoutRoleForItem:` at `0x1c78b5354`), and invokes the lower
frame calculator with `skipAutoLayout=YES` at `0x1c78b5408`. This invocation
does **not** reenter the convenience method that v46 uses as its scope boundary.

Auto-layout stores the computed item frame in its pre-overlap user size, then
can clamp that item's ordinary size to the stage-wide maximum:

```text
0x1c78b5488 stub 0x1c80636e0 ref 0x1d7d60030 attributesByModifyingAttributedUserSizeBeforeOverlapping:
0x1c78b54b8 ldr d0, [sp, #208]
0x1c78b54bc fcmp d0, d9
0x1c78b54c0 fcsel d9, d0, d9, mi
0x1c78b54c4 ldr d0, [sp, #192]
0x1c78b54c8 fcmp d0, d8
0x1c78b54d8 fcsel d8, d0, d8, mi
0x1c78b5544 stub 0x1c80636c0 ref 0x1d7d60028 attributesByModifyingAttributedSize:
0x1c78b556c stub 0x1c8060c40 ref 0x1d7d5f3e8 appLayoutByModifyingLayoutAttributes:forItem:
```

v46 keeps `MacWSActiveDenseGridPolicy` set to About Finder throughout this
entire sequence. Its grid hook replaces a proposal with the active fixed
width/height without knowing whether the proposal belongs to an item or the
stage. Therefore the stage-wide limit becomes the About window's size.
Per-Scene model repairs can restore stored attribute numbers afterward, but
cannot make this earlier calculation correct or constitute visible acceptance.

## Runtime-confirmed matching witness

Copied verbatim from `/var/mobile/Library/Logs/MacWSWindowing.log`:

```text
1789153119.139 initial-size entering route=layout-attributes-calculator scene=sceneID:com.macwsguide.host-180C5342-11F1-448B-AD38-703A01B88CBD nonce=B35AB3EC-E037-4A1B-AF17-23BADA31A924 role=1 target=301.0x378.0 minimum=301.0x378.0 fixed=YESxYES window-scene-class=SBWindowScene
1789153119.140 dense-grid-result grid=0x28243a590 proposed=1004.0x970.0 constrained=301.0x378.0 result=301.0x378.0 candidates=128x83 stock=8x4 policy=sceneID:com.macwsguide.host-180C5342-11F1-448B-AD38-703A01B88CBD
```

The `1004x970` input is the whole-stage maximum proposal, not About's own
`301x378` attributed size. The underlying item-loop ownership and clamp are
established by the disassembly above; final iPad composition must additionally
be checked with an actual iPadOS screenshot.

## Correct scope and acceptance requirements

- The whole-layout auto-layout method must execute with no active fixed-item
  policy. Its maximum-width/height calculation must retain system semantics.
- The lower per-item frame method has the exact role and immutable AppLayout,
  including the internal `skipAutoLayout=YES` calls. That is the identity
  boundary needed for each item's dense candidates and fixed-axis constraints.
- A stock item encountered inside a Host-initiated transaction must clear the
  outer Host scope while it runs, not inherit a fixed Host policy.
- Adding another stable-size repair or overriding the final frame does not fix
  the contaminated stage-wide input.
- Acceptance must capture the iPadOS composition before and after About opens,
  correlate both Scenes' actual geometry, and verify the original Finder stays
  large beside the small panel. Model values or VNC macOS output alone do not
  establish that outcome.

## Implemented candidate and local checks

The v47 source removes the v43–46 immutable model-repair hooks and the upper
calculator workaround. The group auto-layout hook clears the inherited item
policy, and the lower per-item hook sets/restores its exact Scene policy for
each recursive item calculation. Gesture provenance is saved separately so a
sibling's policy-free scope does not lose the actual selected resize item.
Initial activation policy remains in the Scene-keyed map after its request
file is consumed, so recursive initial-item calculations use the same target.

Both arm64 and arm64e compile and link. The final candidate's SHA-256 is
`37b5c44136600812fbddd42a2422944238653efd4b82d57af19221a50565b691`.
`dyld_info -arch arm64e -fixups` reports `cfstring auth-bind=153 plain-bind=0`.
`nm` confirms the two exact method selector hooks and absence of the obsolete
upper/model-ingress hooks. `git diff --check` passed. The copied build output is
`tmp/macws-windowing-v47-build.log`.

The normal system stage maximum may still cause a large window to reflow
slightly (for example 1045 points toward a 1004-point overlapping limit). The
candidate preserves that native validation; the actual resulting iPadOS
composition and fixed-panel first frame still require visual verification.
