# Existing-window resize removed Stage Manager siblings (v49)

## Status and scope

The incorrect transaction is RE-confirmed in the actual iPadOS 16.3.1 (20D67)
SpringBoard and its use is runtime-confirmed in the v48 logs below. The user
reported that expanding/collapsing Finder Get Info or resizing Terminal sends
other same-stage windows to the background. **The v49 change described here is
not yet visually accepted merely because it compiles or its model agrees.**

This change affects AppKit-to-iPadOS geometry synchronization of an already
shown window. It does not change dense-grid policy, first-appearance sizing,
the explicit full-screen/windowed-role action, or the gesture recognizers.
The v47 per-item/group-limit scope fix and v48 metadata-only queue isolation
remain in place. No device deployment or respring was performed by this audit.

## Actual target binary evidence

Source: the running device's
`/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/`
`dyld_shared_cache_arm64e.21`, SpringBoard image base `0x1c7598000`.
Only bounded function ranges were read; the dyld cache/IPSW was not extracted.
Addresses are unslid VM addresses. Selectors were decoded from the actual
Objective-C message stubs and method metadata.

1. `-[SBSwitcherController _currentMainAppLayout]`, `0x1c79163cc`:

   ```text
   0x1c79163dc bl _currentLayoutState
   0x1c79163e8 bl appLayout
   ```

   This supplies the current whole-stage model, not a per-window leaf.

2. `-[SBAppLayout leafAppLayoutForItem:]` calls
   `_leafAppLayoutForItem:role:` at `0x1c7a365ec`.
   The latter builds **one-item** dictionaries at `0x1c7a36730` and
   `0x1c7a36750` (`mov w4, #1`), then constructs a new AppLayout at
   `0x1c7a36788`. The former resize path prioritized
   `leafAppLayoutForKeyboardFocusedScene`; this is not a valid substitute for
   the complete stage when submitting a replacement workspace layout.

3. `+[SBSwitcherTransitionRequest requestForActivatingAppLayout:]`,
   `0x1c771da20`, allocates/initializes a request and only sets `appLayout`.
   Its initializer clears offset `0x70` at `0x1c771da08`; getter
   `entityInsertionPolicy`, `0x1c771e378`, reads that offset. Thus this request
   has insertion policy **0**, without any explicit append/preserve behavior.

4. `-[SBMainSwitcherControllerCoordinator
   switcherContentController:performTransitionWithRequest:gestureInitiated:]`,
   `0x1c79e67b8`:

   ```text
   0x1c79e67fc cbz w22, 0x1c79e6828       ; gestureInitiated == NO
   0x1c79e6810 bl sceneUpdatesOnly        ; only the gesture branch reads it
   0x1c79e6820 bl handleTransitionRequestForGestureUpdate:
   ... non-gesture branch ...
   0x1c79e684c bl mainWorkspace
   0x1c79e68bc bl requestTransitionWithOptions:displayConfiguration:builder:validator:
   ```

   The old `setSceneUpdatesOnly:YES` did **not** protect siblings on our
   non-gesture route. Changing `gestureInitiated` to YES would misrepresent a
   nonexistent gesture session, not fix the broken transaction input.

5. In `_configureRequest:forSwitcherTransitionRequest:withEventLabel:`,
   environment 1 iterates the supplied AppLayout (`0x1c79e2a9c`), gets the
   request's insertion policy (`0x1c79e2f50`) and calls
   `setEntities:withPolicy:centerEntity:floatingEntity:` (`0x1c79e2f70`).
   Its layout-role enumeration block has this end-of-input behavior:

   ```text
   0x1c796c020 ldr x8, [x19, #0x40]       ; insertion policy
   0x1c796c024 cmp x8, #1
   0x1c796c028 b.eq 0x1c796c084           ; separate preserve-previous path
   0x1c796c02c cbnz x8, 0x1c796c0ec
   0x1c796c034 adrp x8, 0x1db497000
   0x1c796c038 ldr x0, [x8, #0x9e0]
   0x1c796c03c bl entity
   0x1c796c054 bl setEntity:forLayoutRole:
   ```

   The class reference at `0x1db4979e0` resolves to class pointer
   `0x1dd881690`, **SBEmptyWorkspaceEntity**. Consequently, supplying a
   one-item leaf under policy 0 explicitly empties the remaining roles. It is
   not an unexplained Stage Manager eviction heuristic.

6. The immutable clone is correct: at `0x1c7a376cc` it copies the attributes
   map, changes only the supplied item's entry, then passes the original
   `allItems` (`ldr x2, [x21,#0x68]` at `0x1c7a376f0`) and original layout
   configuration to the constructor at `0x1c7a37714`. The wrong layer was
   the choice of the clone's original AppLayout, not a missing clone field.

7. `appLayoutByBringingItemToFront:inAppLayout:` changes the target item's
   `lastInteractionTime` from `_nextInteractionTime` (`0x1c7748da0`), then
   clones at `0x1c7748dc8`. Native interactive resizing deliberately does this;
   AppKit-driven disclosure-height synchronization must not change focus/z
   ordering merely because content size changed.

Raw decoded ranges are retained under `tmp/window-resize-*-disasm.txt` and
the matching `*-ranges.txt` artifacts for this run. The offsets and copied
instructions above are the durable evidence; temporary artifacts are not a
required build input.

## Runtime use of the broken path

Copied verbatim from `/var/mobile/Library/Logs/MacWSWindowing.log`:

```text
1789158491.762 resize-submitted scene=sceneID:com.macwsguide.host-591D8813-A393-414E-8A02-6BDCD2E4A5C0 requested=265.0x512.0 effective=265.0x512.0 minimum=265.0x512.0 fixed=NOxYES normalized-fullscreen-size=NO bounds={{0, 0}, {1389, 970}} default=1194.0x807.0 supported=0x5 policy=0 windowed-role=NO scene-updates-only=YES source-role=1 source-center=0 target-center=0 target-environment=1 source=0x33 route=SBMainWorkspace
1789158491.853 resize-submitted scene=sceneID:com.macwsguide.host-591D8813-A393-414E-8A02-6BDCD2E4A5C0 requested=265.0x606.0 effective=265.0x606.0 minimum=265.0x606.0 fixed=NOxYES normalized-fullscreen-size=NO bounds={{0, 0}, {1389, 970}} default=1194.0x807.0 supported=0x5 policy=0 windowed-role=NO scene-updates-only=YES source-role=1 source-center=0 target-center=0 target-environment=1 source=0x33 route=SBMainWorkspace
1789158492.281 resize-submitted scene=sceneID:com.macwsguide.host-591D8813-A393-414E-8A02-6BDCD2E4A5C0 requested=265.0x607.0 effective=265.0x607.0 minimum=265.0x607.0 fixed=NOxYES normalized-fullscreen-size=NO bounds={{0, 0}, {1389, 970}} default=1194.0x807.0 supported=0x5 policy=0 windowed-role=NO scene-updates-only=YES source-role=1 source-center=0 target-center=0 target-environment=1 source=0x33 route=SBMainWorkspace
```

These establish that the Get Info height changes used the non-gesture
workspace route and a primary-role/environment-1 model. The old logging did
not include all member IDs; it therefore cannot independently prove the exact
visible group membership before and after that particular transaction.

## Implementation

- Ordinary geometry uses only `_currentMainAppLayout` with an exact scene ID
  member. If the scene is not yet in the current stage, the same geometry
  nonce receives up to 20 readiness rechecks at 100 ms intervals. This covers
  UIKit becoming foreground just before SpringBoard publishes the group,
  without ever activating an old/background group. At the deadline the
  geometry request is consumed as `resize-deferred reason=not-current-stage`,
  retaining metadata. An unavailable current layout uses the same bounded
  readiness retry.
- Only the target's attributed size/sizing policy changes. The clone must
  have exactly the same members and layout roles, and identical non-target
  layout attributes, before submission. No hard-coded insertion flag or
  fabricated gesture is needed: policy 0 now receives the whole correct set.
- Ordinary geometry does not call bring-to-front or claim keyboard action
  source `0x33`. Actual explicit windowed-role conversion retains its existing
  action route; ordinary geometry continues to use a real workspace request.
- Postconditions read only the actual current stage for ordinary geometry.
  They no longer score historical layouts by how well they match the desired
  dimensions. Membership changes make the model check fail, and do not cause
  restoration of a stage the user may have deliberately changed. A scene that
  leaves the current stage is not reactivated by a corrective retry.
- Every postcondition explicitly says `visual-acceptance=UNVERIFIED`.
  Metadata-only policies still exit before geometry/activation/stable-model
  mutation; their independent queue is unchanged.

## Acceptance still required on device

1. Establish Finder + Get Info + Terminal on the same visible stage, with
   distinct usable sizes. Save a full iPadOS compositor screenshot and member
   IDs before changing anything.
2. Expand/collapse Get Info General/More Info repeatedly. The outer iPadOS
   height follows the actual AppKit height; all original siblings remain on
   the stage, with independent sizes. Compare actual screenshots, not just
   model values.
3. Rapidly resize Terminal on both axes and release. Characters must settle
   correctly without a black band; no other stage member is removed.
4. Switch to another stage while an AppKit update is pending: the old group
   must not be activated. Returning to its scene permits foreground geometry
   reconciliation; metadata remains up to date.
5. Recheck About Finder first-frame size and min/max/fixed-axis limits. Dense
   sizes must remain MacPad-only. No fixed About size may leak into siblings.

`misc/test_window_resize_stage_contract.py` and
`misc/test_window_policy_queue_contract.py` guard source contracts only;
neither is a substitute for these visible results.

## Local build and checks

- `python3 misc/test_window_resize_stage_contract.py`: 9 passed, including
  group-scope policy clearing and nested per-item identity rebinding.
- `python3 misc/test_window_policy_queue_contract.py`: 5 passed.
- `git diff --check`: clean.
- Native macOS cross-link completed for arm64 and arm64e; log:
  `tmp/MacWSWindowing-current-stage-v49-build.log`.
- `MacWSWindowing/.theos/obj/MacWSWindowing.dylib` SHA-256:
  `334ed1f380ce3c5d879cbec7c8d13d0f57aca6c9f29e7fd53ac9a40ab9b7cb29`.
- `dyld_info -arch arm64e -fixups`: `__cfstring` has 168 authenticated binds,
  0 plain binds. These are ABI/build checks, not evidence of visible success.

## First readonly v49 runtime observations (partial, not full acceptance)

The deployment coordinator restarted SpringBoard once, then relaunched Host.
The witness identifies **v49 / SpringBoard PID 59384**. The first Host launch
still rejected geometry as `windowing-bridge-not-loaded`: changing the
diagnostic `resize=` label had not been accompanied by updating the Host's
capability-prefix match. Host was amended to accept both the legacy and v49
labels, then relaunched without another SpringBoard restart. Requests before
that client correction were **not tests of the v49 resize transaction**.

After the corrected Host launched, the following actual transactions arrived:

```text
1789160538.356 resize-postcondition scene=sceneID:com.macwsguide.host-A782ECD5-7957-4518-B6BB-81495FF4A46B landed=YES role-landed=YES size-landed=YES role=2 center=0 environment=1 expected-windowed=NO expected=331.0x742.0 actual=331.0x742.0 size-api=YES samples=1 transaction-attempt=1 stage-members-preserved=YES current-items=sceneID:com.macwsguide.host-D1D8C086-8C6E-400C-87B9-EA9789E78D07,sceneID:com.macwsguide.host-A782ECD5-7957-4518-B6BB-81495FF4A46B visual-acceptance=UNVERIFIED
1789160538.493 resize-postcondition scene=sceneID:com.macwsguide.host-D1D8C086-8C6E-400C-87B9-EA9789E78D07 landed=YES role-landed=YES size-landed=YES role=1 center=0 environment=1 expected-windowed=NO expected=376.0x456.0 actual=376.0x456.0 size-api=YES samples=1 transaction-attempt=1 stage-members-preserved=YES current-items=sceneID:com.macwsguide.host-D1D8C086-8C6E-400C-87B9-EA9789E78D07,sceneID:com.macwsguide.host-A782ECD5-7957-4518-B6BB-81495FF4A46B visual-acceptance=UNVERIFIED
```

These current-stage observations confirm that resizing Get Info and then
About preserved the **two-member input group**, with different sizes. They
do not establish that the original three-window startup group survived:
before the first geometry submission at `1789160538.252`, layout calculations
already showed About/Get Info together and the main Finder scene separately.
Attribution of that earlier grouping change requires independent screenshots
and the startup/user-action timeline, not guessing from these postconditions.

Artifacts:

- `tmp/window-resize-v49-first-runtime-stage.txt`: complete bounded log tail,
  including the multi-line `stage-items` arrays preceding each postcondition.
- `tmp/window-resize-v49-first-finder-metrics.json`: Finder PID 43902 generation
  458, still the **old running Finder process**, not a no-learned-minimum test.
  Its Get Info window 282 reports native min `265 x 555`, max `400 x 555`;
  density 1.25 and 48-point chrome correspond to scene policy `331 x 742`
  and max width 500. The main Finder's cached minimum in that old process
  must not be attributed to the newly installed but not yet loaded library.

No UI action, process restart, or deployment was initiated by this readonly
monitor. Controlled disclosure/Terminal gesture tests and visual acceptance
remain separate from these initial observations.
