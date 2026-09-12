# SpringBoard Safe Mode: selected layout lifetime

## Captured failure

Runtime-confirmed via `SpringBoard-2026-09-12-161745.ips`, incident
`79A565D6-CDD3-4708-8F3C-0FABE5EE22CA`, PID35698, SIGABRT. Local original:
`tmp/springboard-v54-161745.ips`. Relevant exception frames, verbatim symbols:

```text
-[NSArray subarrayWithRange:] + 572
-[SBSwitcherModifier(SharedModifierUtilities) appLayoutsToCacheSnapshotsWithVisibleRange:numberOfSnapshotsToCache:biasForward:] + 284
-[SBHomeGestureToSwitcherSwitcherModifier appLayoutsToCacheSnapshots] + 172
-[SBFluidSwitcherViewController _updateSnapshotCache] + 72
-[SBFluidSwitcherViewController _rebuildCachedAdjustedAppLayouts] + 992
-[SBMainSwitcherControllerCoordinator _addAppLayoutToFront:removeAppLayout:] + 480
-[SBSceneManagerCoordinator _createSceneForApplication:withOptions:completion:] + 364
```

Host log immediately before the crash:

```text
1789201064.138 scene-activation requested supportsMultiple=YES connected=3 open=5 origin=1E7C21F0-1FBE-416D-ABF0-C515AB251BF5 window=784
1789201064.140 scene-activation options window=784 public-preserve=YES window-preserve=YES origin-state=0
1789201064.190 scene-activation failed: Error Domain=BSServiceConnectionErrorDomain Code=3 "XPC error received on message reply handler" UserInfo={BSErrorCodeDescription=OperationFailed, NSLocalizedFailureReason=XPC error received on message reply handler}
```

This was a new Settings window. The requester was ForegroundActive (0);
therefore a Host foreground-state check alone is not an established fix.
The report does not contain the exception's range values or the selected
layout's membership. Do not invent those runtime values.

## Actual-binary evidence

RE-confirmed against the device's iPadOS16.3.1(20D67) SpringBoard framework,
UUID`13B37E5E-5290-3E2E-91B9-4378BD2E8312`. Unslid image base
`0x1c7598000`; crash-time base`0x2037e4000`, shared-cache slide`0x3c24c000`.
All reads used `misc/macws_dyld_range_query.py`, bounded to32KiB/read and
12seconds, without extracting/mapping a full cache or IPSW.

- Initializer`0x1c7c60b4c` retains the `selectedAppLayout:` argument at
  `0x1c7c60bf8`. Actual class metadata identifies `_appLayout`, offset0x88,
  type`@"SBAppLayout"`; `_multitaskingModifier` is the different0x90 ivar.
- `appLayoutsToCacheSnapshots`,0x1c7c61758: nonempty layouts with a nonnil
  selection call `indexOfObject:` at0x1c7c617a8. That result is passed
  unchanged as the range location, length1, at0x1c7c61800.
- Shared cache helper0x1c7963300 passes the original location/length to
  `subarrayWithRange:` at0x1c7963418. This is exactly the failing call:
  the crash records its return address0x1c796341c (+284).
- `appLayoutsToCacheFullsizeSnapshots`,0x1c7c61838, also computes from the
  same `_appLayout` and its `indexOfObject:` result. Fixing only the first
  failing array read would leave another invalid consumer.
- `adjustedAppLayoutsForAppLayouts:`,0x1c7c610a4, produces the adjusted
  model consumed by the cache rebuild; it does not rebind `_appLayout`.

RE establishes a stale-selection invariant violation. THEORY pending a live
rebind witness: adding/replacing a Host Stage Manager group leaves the gesture
modifier selecting the old immutable group although the exact Scenes survive
in a replacement. The retained model must follow Scene identity, not an old
group object or a guessed array index.

## v59 candidate correction

At the adjusted-model publication boundary, retain the unique replacement
group containing **all** old Scene identities, only if the old selection has
disappeared and contains a Host item. Keep both bundle and exact Scene ID in
the match. Existing selections, stock-only groups, ambiguous candidates,
partial/split membership and missing identities remain untouched.

No `NSArray` hook, exception catcher, cache suppression, forced index, fake
layout or assertion bypass. Apple's array and ordering are returned unchanged.
The real retained selection is updated before snapshot consumers run.

Installed SHA256:
`d6b3a34777caa8c3ce371efbb14754f465f2a5010010f3c9b0c8ad6b2b2f9781`.
Apple codesign strict verification passed; arm64e constant strings have
178authenticated DA binds,0plain binds. Both final CDHashes trusted. A fresh
inode replaced the dylib atomically; original backup remains in
`/var/mobile/Media/macws-v59-selection/backups/MacWSWindowing.dylib`.

## Validation and remaining limit

- 12compiled Foundation selection tests passed (`misc/test_switcher_selection.m`).
- 49existing window-contract Python tests passed; `git diff --check` passed.
- User exited Safe Mode, producing SB57800 at16:41:51. One intentional
  installation restart loaded v59 in SB58898 at16:48:17. WindowServer76954
  and Host38654 were not restarted by this fix.
- About Finder window798 connected at377x456. Host log:
  `1789203041.334 scene-initial-size postcondition id=BAC6FCBF-4542-40A3-9210-CE178E084392 landed=YES expected=377.0x456.0 actual=377.0x456.0 action=keep-initial-layout`.
  Screenshot`tmp/safemode-v59-about-landed.png` inspected: real About content,
  Finder and other windows coexist.
- Screenshot`tmp/safemode-v59-system-switcher.png` inspected: native iPadOS
  app switcher with a rendered multi-window macPad group. Earlier synthetic
  edge swipes did **not** enter the switcher and are not acceptance passes.
- As of17:12, no subsequent SpringBoard crash; PID58898 and v59 marker match.
  This is **not** proof the failure path has been exercised: no
  `switcher-selection rebound` witness has been captured yet. Exact timed
  reproduction remains outstanding. Do not mark this as fully verified.

### Follow-up with the user temporarily hands-off

At17:27 a real Finder `New Finder Window` menu action created window827 while
the native app switcher had been visually verified (`tmp/v59-switcher-before-new.png`).
The new Scene connected and rendered at1077x801 with a real1436x1004 IOSurface.
After entering the switcher again, an exact-target `Close Window` action closed
only this test window827. Host independently confirmed its retirement:

```text
1789205384.725 runtime-confirmed mac-window-removed id=CBE94BDF-A682-4449-846C-2A655919648B owner=34735 window=827 group=827 catalog-count=2 owner-missing=NO refreshed-catalog=YES recovery=retire-scene mac-window=preserved
1789205386.830 scene-discard duplicate-only id=CBE94BDF-A682-4449-846C-2A655919648B mac-window=preserved
```

`tmp/v59-returned-after-test.png` inspected at17:32: the remaining Documents
window826 and About798 render correctly; metrics list no827. Window826 was
initially created in the earlier trial, but the user subsequently navigated it
to Documents and closed the original698, so826 was preserved. No files were
changed by these tests. No held contacts or background input generators remain.
The installed SHA matches v59; Safe Mode marker absent, SB58898 and WS76954
unchanged, no new SpringBoard crash. The dangerous missing-selection branch
still did not log a rebind, so the outstanding validation limit above remains.
