# Dock touch hover retention — 2026-09-20

## Current result: PASS for the reproduced short-swipe / outside-tap regression

The Host now closes an existing synthetic scroll-momentum transaction at the
start of a new physical contact, before focus/routing or the new contact is
emitted. The actual device A/B below confirms the old tail ends before the
outside tap, both global cursor APIs remain outside immediately and one second
later, and Dock retires its hover. Ten additional diagnostic-off repetitions
all ended with `myInBar=false`. Independent inspection of both final native
iPadOS screenshots confirms normal Dock icon sizes with no retained Terminal
hover label. This is acceptance of the recorded regression and lifecycle
change, not a universal guarantee about every input interleaving.

Accepted Host: PID 39291, UUID
`A8A8EAED-7936-3AD8-8002-8494C8CBF2B9`, `__text` SHA-256
`68742a505abf1c4ac69a5b84e92661ff3479324ef2fcbc9bbdf9d476173f1f02`.
Only Host was republished/reopened for this A/B; WindowServer, Dock, inputd,
the proxy and user macOS applications were not restarted. Proxy PID 35523
still used the same `E8663F86-D3E2-3B7D-9E24-65FEB7749100` library as the
negative baseline. The detailed acceptance and receipt are recorded at the
end of this document; all earlier negative findings are retained below.

## Negative baseline: prehover alone was not accepted

The final deployed proxy PID 35523 (library UUID prefix `E8663F86`) reproduced
a **new** sticky-hover failure in cycle 2 of the parent's native repetition:
short Dock swipe, then an outside tap. Dock retained `myInBar=1` and pointer
`(620.814,791.825)`. The parent visually inspected
`/tmp/macws-input-final-dock-five-cycles-20260920.png` and confirmed the
retained magnification. Therefore the ten passing sequences on the preceding
generation below were not final acceptance. The actual mouse-move-before-click
contract remains RE-confirmed, but that change alone did not solve all cases.

The initial bounded prehover-only checks passed the six cases below, but later
continuous observations reproduced sticky Dock magnification after outside
input. The unverified second activation-parity addition did not fix Terminal's
first shortcut and has been removed from source and rolled back on device.
The same sticky hover remains on the restored first candidate, so the second
addition is **not** established as its cause. Dock acceptance was not
PASS for either prehover-only generation. Later diagnostic-off Terminal shortcut repetitions
passed the bounded checks documented in
[keyboard-modifier-snapshot-20260920.md](keyboard-modifier-snapshot-20260920.md).
The historical negative keyboard results below remain evidence, not a claim
that their complete cause has been established.

## Original reproduction before the update

This is native Dock icon hover magnification, not a zoomed Host viewport or a
window Genie animation. The two actual iPadOS images were inspected:

- `/tmp/macws-dock-short-swipe-20260920.png`: Terminal and neighboring Dock
  icons remain enlarged, with the Terminal hover label visible.
- `/tmp/macws-dock-outside-tap-after-swipemagnify-20260920.png`: tapping the
  Terminal window outside Dock leaves that same hover presentation in place.

The parent reproduced it through native iPadOS digitizer input, not a direct
MacWS socket injection. For the current boot's verified digitizer sender:

```text
env _MSSafeMode=1 /var/mobile/Media/macws_hid_touch-20260919 --send-drag 0x1000007e6 .05 .507 .05 .520 .20
env _MSSafeMode=1 /var/mobile/Media/macws_hid_touch-20260919 --send-drag 0x1000007e6 .55 .72 .55 .72 .10
```

The short one-finger movement crosses the existing direct-scroll threshold.
The parent's read-only probe PID22550 produced the following original tool
transcript (not redirected to a log file):

```text
pid=22550
state=1 flags=0 keys=59:0,62:0,55:0,54:0,58:0,61:0,56:0,60:0,57:0,48:0,0:0, buttons=0,0,0
state=0 flags=0x20000100 keys=59:0,62:0,55:0,54:0,58:0,61:0,56:0,60:0,57:0,48:0,0:0, buttons=0,0,0
event-flags=0x20000100 type=0
```

This rules out a physically held Control/Command or mouse button in that
snapshot. It does not by itself prove which Dock tracking event is missing.
Earlier stationary 0.45-second touches showed the expected native context
menu; a small subsequent touch closed it. Those passing cases did not cover
this short-swipe-to-hover sequence.

A further native outside-window small scroll, from raw `(.55,.72)` to
`(.55,.734)` in `.20` seconds, **did** clear the magnification:
`/tmp/macws-dock-outside-scroll-clears-20260920.png` (parent visually checked).
Thus ordinary outside Tap and outside Scroll differ in the reproduced state,
matching the source's pre-motion boundary difference. The temporary Host-only
touch diagnostic switch was removed; its bounded log is
`/tmp/macws-dock-touch-before-host-20260920.log`. No global runtime diagnostic
was enabled for this reproduction.

## Narrow change and evidence boundary

For the first update, source-confirmed in `libmachook/mac_hooks.m`: Scroll Began and TouchDown send
an all-buttons-up `CGPostMouseEvent` at the actual new pointer position before
the next transition. Atomic Tap/SecondaryTap previously sent only button down
and button up at that position. The candidate adds the same button-free move
to atomic clicks only when the proxy does not already track a held left
button. The down/up interval remains 2000 microseconds; all positions remain
the real input coordinate, and the original post results remain unchanged.

The existing held-button/contact state, drag paths, scroll translation,
modifier handling, Dock preferences and Host coordinate policy are unchanged.
There is no fake offscreen cursor position, forced Dock reset, added background
timer, per-frame probe or production flag. The separately noted stale
`leftDown`/atomic-click bookkeeping issue is not silently included in this fix.

`include/macws_atomic_pointer_click.h` is the same small transaction called by
the production proxy and the executable fake-poster regression test. The test
checks primary/secondary click order, the unchanged real point, one and only
one pressed event, the exact original pause, existing-drag behavior, and
transparent down/up return values including error values.

The original source hypothesis was that the missing independent button-free
move prevents Dock from retiring its previous hover when a finger taps another
window. The initial device A/B below observed the desired behavior at this
event boundary, but the later counterexample means that this is not a
repeatably accepted repair. It does not claim a reverse-engineered account of
Dock's private internal tracking state. A compiling helper or passing fake
poster alone was not treated as visual acceptance.

### Original acceptance checklist, including possible adverse effect

- Same short-swipe then outside Tap: existing hover must retire with the real
  new point; no fake cursor relocation is permitted.
- Ordinary direct Dock Tap: verify app launch and whether the new pre-motion
  itself starts icon magnification that previously did not appear. Do not
  declare the overall touch UX fixed if this merely shifts the retention to
  every normal Dock click.
- Context click, an existing held drag, subsequent precise-pointer motion,
  and double clicks must retain their established behavior.
- Read-only modifiers/buttons must remain released after these transactions.

Local validation: `python3 -m unittest misc.test_atomic_pointer_click
misc.test_window_popup_composite_contract -v` passed all 10 tests. No device
publication or input was performed by the original candidate implementation
task. The subsequent controlled deployment is documented next.

## New-inode deployment and live implementation identity

Runtime-confirmed via `/tmp/macws-dock-click-deployment-20260920.log` and the
device receipt `/tmp/macws-dock-proxy-stage-20260920/transaction.json`:

- Both signed library slices were copied to new same-directory inodes at the
  four canonical iOS/chroot library paths, then atomically renamed. Mode 0755
  and root:wheel ownership were preserved. No mapped library inode was edited
  or re-signed in place.
- Original inodes remain recoverably hard-linked in
  `.macws-dock-proxy-a0a4eb961509-rollback` under each canonical library
  directory. The receipt records every old/new inode, SHA-256 and cdhash.
- Only `user/501/UIKitApplication:com.macwsguide.osxvnc` was restarted after
  exact loaded program/arguments and singleton process-group validation:
  proxy PID 16260 became 23733. WindowServer 15997, Dock 16238 and Host 19850
  were unchanged. There was no iPad restart, respring, whole-GUI restart, or
  termination of user applications for this update.

The signed arm64 artifact is UUID
`BF8EBB44-48A7-3631-96EB-C2D75FB7FA69`, SHA-256
`061ab644d82690da41899fca5e8df3c9d7db001134c7aeab4fc76d537d0d049c`.
The arm64e artifact is UUID `E3B17053-0657-3B8C-BD36-FA2627CE715D`,
SHA-256 `e45faa5cc0459359311e6a8ac4f9f6a6f26b4652e324be67ae49a6607df7dbfa`.

Crucially, the restarted process was not assumed to use the new implementation
merely because publication succeeded. The no-suspend mapped-image reader
recorded this actual result in `/tmp/macws-dock-click-mapped-20260920.log`:

```text
pid=23733 process=OSXvnc-server task-for-pid=0
image=libmachook_arm64.dylib ... uuid=bf8ebb4448a7363196ebc2d75fb7fa69
text-bytes=648536 text-sha256=3b78b034548a451e5f0d4de60068a89a471c84421f7edd43fe1b8e9aa2beeaf8
image-count=301 matched=1 requested=1 no-suspend=yes
```

## Initial bounded touch A/B and regression screenshots (not final acceptance)

All six complete iPadOS screenshots below were independently viewed for this
receipt, not classified solely from filenames or capture success:

| Screenshot under `/tmp/` | Observed result |
|---|---|
| `macws-dock-click-reproduced-hover-after-fix-20260920.png` | The same short movement still produces normal Dock hover: Terminal and adjacent icons are visibly magnified, Terminal label present. The change does not simply disable magnification. |
| `macws-dock-click-outside-tap-pass-20260920.png` | After an ordinary outside tap, icons return to normal size and the hover label disappears. The old-build outside-tap screenshot above retained both. |
| `macws-dock-click-vscode-short-tap-20260920.png` | A normal Code Dock tap brings the existing VS Code window forward, with Code's menu active and no retained magnification. |
| `macws-dock-click-context-menu-20260920.png` | Terminal's real Dock context menu is visible, including New Window, Show All Windows and Quit. |
| `macws-dock-click-dismissed-menu-20260920.png` | The subsequent outside tap dismisses that menu; the existing Code document remains visible. |
| `macws-dock-click-title-drag-20260920.png` | The Terminal title-bar drag moves the window lower while preserving its content and normal Dock icon sizes. |

These were user-type native digitizer touch transactions through the normal
Host/input/proxy path. The reproduced-hover/outside-tap pair is the relevant
negative-to-positive acceptance, rather than a stationary click that never
entered the reported failure state.

The parent's complete regression run reported 446 total tests: 434 passed and
12 skipped, with no failures;
the runtime-switch audit also passed. Neither result is used to overstate
untested gestures or applications. Double-click and precise-pointer cases are
not newly certified by these six screenshots, and the separate Terminal
Command-A/Command-T issue remains open at the time of this receipt.

## Second proxy-only update: atomic-click activation parity

The now-rejected follow-up source change added the existing coordinate-activation
transaction to the atomic click boundary. In that candidate's
`include/macws_atomic_pointer_click.h`, only when no left-button drag was already
held, the order is now:

```text
real-position all-buttons-up motion
existing coordinate-activation callback
original primary/secondary down
original 2000-microsecond pause
original all-buttons-up release
```

The activation callback's failure did not suppress the real click. The
original down/up results were returned unchanged; already-held drags received
neither extra motion nor extra activation. There was no added sleep for focus,
fake coordinate, modifier rewrite, application timer alteration, or success
substitution. This matches the existing TouchDown/RFB activation boundary,
but is not itself proof that every application's first key is ready.

The reviewed prepared manifest is
`/tmp/macws-dock-activation-prepared-transaction-20260920.json`; it intentionally
records the prepublication state and is not alone an installation witness.
Actual publication/restart and mapped-code receipts are
`/tmp/macws-dock-activation-deployment-20260920.log` and
`/tmp/macws-dock-activation-mapped-20260920.log`.

This second transaction used new inodes at the same four canonical library
paths, preserving the preceding generation under
`.macws-dock-activation-c90cc930096e-rollback` in both library directories.
The signed arm64 image is UUID `227D2EDF-AC7B-31D2-915D-9F40BEA0CF41`,
SHA-256 `886bea3ee3200e6c46965e6d5b260481aa6a2f065d3b6306a81f4efb480b0a47`.
The signed arm64e image is UUID `226BF835-46F4-36FA-8681-A8F4C3DF181E`,
SHA-256 `d6ebc991868522415b07ce659ad9ca02198e04f3c4250f5feb25016cae9a67b4`.
Only the exact `user/501/UIKitApplication:com.macwsguide.osxvnc` job changed
lifecycle, from PID 23733 to 27368. Its actual mapped arm64 library was:

```text
pid=27368 process=OSXvnc-server task-for-pid=0
uuid=227d2edfac7b31d2915d9f40bea0cf41 text-bytes=648556
text-sha256=e3e1556ad1047f60c0a9d0737ed2f9ddd6d358165ecaba007a17af1db5ed829a
image-count=301 matched=1 requested=1 no-suspend=yes
```

There was no iPad reboot, respring, or restart of WindowServer, Dock, Host, or
the already-running user applications. Terminal 16275 still uses its preserved
earlier **arm64e** `libmachook.dylib` mapping, UUID
`6E014D8F-F233-3820-A51C-1F4466323845`, 629,748-byte `__text` SHA-256
`87299afb76774491022a42eccd117c65d28f39a9c4c000c763ae19c0215eb5c8`.
The earlier arm64 UUID attribution was incorrect: requesting
`libmachook_arm64.dylib` for this Terminal found zero matching images.
Canonical publication must not be described as replacing bytes in its running
mapping.

### Important negative result: first-key recovery is not fixed

The parent repeated the real fast sequence Code → touch Terminal content →
immediate Control-Tab or Command-A. It **still fails**, whereas allowing the
application to settle makes the shortcut work. Thus the second update is
activation-path parity, not an accepted Terminal first-key fix, and the cause
remains under investigation.

The independent fresh InputLab control, PID 28895, did receive its first
Command-M menu action after touch. The actual event receipt
`/tmp/macws-fast-switch-lab-events-20260920.jsonl` includes:

```text
sequence=22 left_down  received_uptime=61794.33059904167
sequence=23 left_up    received_uptime=61794.330713208336
sequence=24 flags_changed modifiers=1048832 key_code=55
sequence=25 menu_action received_uptime=61794.430628083341
sequence=26 flags_changed modifiers=256 key_code=55
```

That menu action arrived about 100 ms after touch-down receipt, followed by
modifier release. This is a useful counterexample to a universal inability to
deliver any first shortcut; it does not invalidate the actual Terminal failure
or establish its root cause. The 446-test suite (434 pass, 12 skip) likewise
does not override this remaining negative UI result.

## Rejection, source cleanup, and guarded runtime rollback

The parent's later continuous screenshots showed Dock magnification persisting
through multiple outside taps and scrolls. Because activation parity had no
accepted first-key benefit, it was not retained merely for source symmetry.
Only that extra activation callback, its record field/adapter, and associated
test expectations were removed. The real-position button-free prehover,
down/2000-microsecond/up sequence, held-drag behavior, and original return
values remain. The executable atomic-click tests plus popup contract tests
passed all 10 cases after this cleanup; no other production path was changed.

The parent then used the guarded transaction rollback, restoring the first
candidate's four exact preserved inodes and restarting only the proxy. The
device receipt `/tmp/macws-dock-activation-stage-20260920/transaction.json`
records `restart.rolled_back=true`. Proxy 31982 actually maps the restored
UUID `BF8EBB44-48A7-3631-96EB-C2D75FB7FA69`, 648,536-byte `__text` SHA-256
`3b78b034548a451e5f0d4de60068a89a471c84421f7edd43fe1b8e9aa2beeaf8`.

Crucially, `/tmp/macws-dock-rollback-first-tap-20260920.png` still shows sticky
Dock magnification after the outside tap on that restored first candidate.
Therefore neither the early isolated passing screenshots nor source parity
establish a completed fix, and this counterexample prevents attributing the
remaining bug solely to the rejected activation addition. Continued root-cause
diagnosis and repeatable acceptance are required. No iPad reboot or respring
was used for this rollback.

## Read-only investigation of the retained state

This section records the state that **survived the proxy rollback**, not a
proven newly generated failure of the restored candidate. Dock itself was not
restarted in either proxy transaction. A later recovery and new-sequence check
are recorded separately below. At that checkpoint acceptance of the subsequent
production generation was still pending; these observations do not establish a universal
success rate or explain when the retained state was originally created.

Runtime-confirmed with the bounded, no-suspend reader
`/tmp/macws_dock_tracking_read_20260920.py`: Dock PID 16238's executable is UUID
`2B02F563-15F3-38D6-96CD-CB6DD77A816C`, matching the inspected Ventura Dock
binary. Its existing `libmachook.dylib` mapping is UUID
`6E014D8F-F233-3820-A51C-1F4466323845`; replacing the proxy library did not
replace this mapping. The reader verified those identities before accessing
the following exact data offsets. It neither attached a debugger nor suspended
or modified any thread.

The retained-state output included:

```json
{"gDockHasKeyFocus": 0, "gDockRetainKeyFocus": 0, "gDockObjFlags": "0x43211", "magnification": true, "fishing": false, "myInBar": true, "fDragging": false}
{"storedPointerFloat": [600.187744140625, 791.8250122070312], "storedCGSPointerDouble": [600.187744140625, 791.8250122070312], "dockTrackingRect": [-95.0, 682.0, 1384.0, 152.0]}
{"trackingActive": 0, "trackingButtons": 0, "synchronousTrackingActive": 0, "mouseLocationActive": 0, "mouseLocation": [0.0, 0.0]}
```

The field names are not guessed from the displayed appearance. RE-confirmed
via that exact Dock binary's own diagnostic formatter:

- `+0x7d99c` and `+0x7d9e4` read `gDockHasKeyFocus` and
  `gDockRetainKeyFocus`, at data offsets `+0x40b889` and `+0x40b888`.
- The formatter at `+0x7dbd0..+0x7dbe8` tests bit `0x10` of
  `+0x40b9dc` and labels it `gDockObj.myInBar`. The same formatter identifies
  magnification, fishing and dragging bits.
- The pointer values are at `+0x40b718` (two floats) and `+0x40b7b0`
  (two doubles); the tracking rectangle is at `+0x40ba30`.

The ordinary mouse-move entry's early-return gate bytes `+0x40b725`,
`+0x40b882` and `+0x40b883` were all zero, and the mode object checked through
`+0x15c4d8` / `+0x15c4f4` was absent. Independently identified
`gCoreDragIsDragging`, `gExposeIsCapturingEvents`,
`gSpringboardIsCapturingEvents`, `gStackIsExpanded` and `DockMenuSuppressed`
were zero. The saved background event mask was `0x360` (which includes the
mouse-move `0x20` bit), its shape was non-null, and its restore guard was zero.
`DOCKMiniView.currentlyShownMiniView` was nil, so the ordinary event loop's
mini-view filter was not active.

The parent also ran the separate, read-only API probe
`/tmp/macws_cursor_dual_location_probe_v2_20260920` as PID 34191. In that
checkpoint its same-process `CGEventGetLocation` and
`CGSCurrentInputPointerPosition` both returned `(563,228)`, well outside the
Dock rectangle above. `CGSInputButtonState(1,0)` and public HID/session
left/right/center button states were all zero. The event flags were
`0x20000100`. This establishes disagreement between the actual global pointer
and Dock's retained inside state; it is not evidence of a pressed-button or
keyboard-focus lock. The CGS signature used by the probe is backed by Dock
`+0x79f58` consuming the returned `d0/d1` point and `+0x3cff4..+0x3d000`
passing exactly `(1,0)` to `CGSInputButtonState`.

The parent inspected both the native iPadOS and independent VNC views; the
retained magnification was present in both, not only a stale Host image.
Relevant private screenshots include
`/tmp/macws-dock-native-vnc-20260920.png` and
`/tmp/macws-dock-current-re-state-20260920.png`.

### Native Dock lifecycle, and an explicitly excluded false lead

RE-confirmed via Dock UUID `2B02F563-15F3-38D6-96CD-CB6DD77A816C`:
`+0x1dc74` drains its actual connection with `CGEventCreateNextEvent` at
`+0x1dca8`. The ordinary path, with neither Expose nor Launchpad capturing,
goes through `+0x1de1c`; with no shown mini-view, it reaches the dispatcher at
`+0x1e180`. Mouse-move type 5 selects `+0x3b304` and subsequently
`+0x3cfd4`. Native mouse-exit type 9 goes through `+0x3ba60` / `+0x3bfe4`
to `+0x78274`, which saves the event's point and queues the real
`DOCKMouseLeaveEvent` through `+0x479bc`. Its processing at `+0x47a38`
contains the normal shrink/label cleanup and clearing of `myInBar`; none of
these methods or data fields was overridden for this investigation.

An initial narrower reading noticed the synthesized type-9 path at
`+0x1e074` and its latch at `+0x401e38`. Completing the upstream control-flow
analysis showed that this belongs to the Expose/Launchpad branch, not the
ordinary Dock path used here. The measured latch was zero. It therefore must
**not** be presented as a stuck ordinary-Dock enter latch or as the cause.

## Actual SkyLight contract: a button transition is not a mouse move

RE-confirmed via the running macOS SkyLight, UUID
`96676A53-B1E0-3D7E-B98B-B73873CD1880`. The two bounded artifacts are:

- `/tmp/macws-cgpostmouse-readonly-dump-20260920.log`: owned probe PID 35131,
  `CGPostMouseEvent` at image offset `+0x50528`, image base `0x1a72a9000`.
  The helper only resolved/read the API; it did not call it.
- `/tmp/macws-cgpostmouse-callee-readonly-20260920.log`: UUID-validated
  no-suspend read of the same image in Dock, limited to 1536 bytes starting at
  its immediate callee `+0x71cf8`.

The public function preserves the point, normalizes Boolean arguments, obtains
the variadic button arguments and calls `+0x71cf8` at `+0x50594`. It does not
itself synthesize a preceding motion. The callee compares the old and requested
button states, with these actual instructions in the second artifact:

```text
0x1a731ae38 cmp w8, w24
0x1a731ae3c cset w9, ne
...
0x1a731ae7c cmp w14, w13
0x1a731ae80 cset w13, ne
0x1a731ae84 orr w9, w13, w9
...
0x1a731ae90 tbz w9, #0, #0x1a731af10
...
0x1a731af04 bl #0x1a737daac
0x1a731af08 mov w20, #0
0x1a731af0c b #0x1a731afe0
```

Any changed button takes that button-transition producer path. It does not
fall through into the no-button-change mouse-move construction. Only the
unchanged-button path compares the new point against its current pointer:

```text
0x1a731af10 ldr x9, [x22]
0x1a731af14 ldr s0, [x9]
0x1a731af18 fcvt d0, s0
0x1a731af1c fcmp d9, d0
0x1a731af20 b.ne #0x1a731af34
0x1a731af24 ldr s0, [x9, #4]
0x1a731af28 fcvt d0, s0
0x1a731af2c fcmp d8, d0
0x1a731af30 b.eq #0x1a731af08
```

Thus an unchanged button state **and unchanged point return success without
posting motion**. For an actually different point with no held button, the
callee writes type 5 at `+0x72084`, then uses the common posting function
`+0x71788` via `+0x71fd8`. This verifies the production invariant addressed
by the real-position prehover: a down/up pair at a new coordinate is not
equivalent to motion followed by a click. It also explains why a successful
same-point hover call is not proof of delivery. These two inspected layers
do not establish any particular downstream coalescing race or justify an
arbitrary additional delay.

## Normal pointer recovery and ten fresh sequences

The parent first sent one genuinely different outside RFB pointer location
`(700,300)`. Both global cursor APIs moved there, but the old Dock state still
contained `(600.1877,791.825)` and `myInBar=1`. In a subsequent single RFB
connection, three button-free pointer events were sent: `(605,790)` inside,
then `(605,640)` outside, then `(700,300)` outside, with 150 ms between
events. Native Dock returned to `myInBar=0`, saved `(605,640)`, and shrank its
rectangle to `(49,755,1096,79)`. The parent visually confirmed the normal
icon size in `/tmp/macws-dock-rfb-reenter-exit-20260920.png`.

This was a diagnostic sequence of ordinary pointer events, not a production
offscreen-cursor workaround, private-state reset, Escape substitution or Dock
restart. No recovery timer or replay of those coordinates was added to code.
It demonstrates that the original Dock event/state machinery remains able to
retire hover.

A further discriminator began with a normal **native finger** stationary
Dock tap rather than RFB entry. It produced the expected inside pointer and
`myInBar=1`; one independently delivered outside RFB move to `(710,310)` then
cleared `myInBar` and shrank Dock. Therefore RFB entry is not intrinsically
required, and native entry alone does not establish a broken state.

After that normal pointer recovery, the parent performed ten new native
sequences on the restored prehover candidate: five stationary Dock-tap →
outside-tap cases and five short-Dock-swipe → outside-tap cases. All ten ended
with `myInBar=0`. These are bounded positive results on freshly exercised
sequences, distinct from the earlier retained-state counterexample. They do
not prove when that older state arose or certify every input interleaving.
The later fresh failure below prevented accepting those ten cases as final.

For completeness, the exact proxy job's existing stdout/stderr file,
`/var/jb/var/mobile/osxvnc.log`, contained startup and RFB connection statistics
but no historical `POINTER-PROXY post ... left=...` diagnostics. Its silence
cannot establish whether a particular old prehover was sent or skipped. No
diagnostic flag was enabled to fill that evidence gap.

## Fresh final-generation counterexample supersedes the ten-case check

Unlike the retained state observed across the earlier proxy rollback, this
counterexample was newly reproduced on final deployed proxy 35523, whose
mapped library UUID prefix is `E8663F86`. The parent used these actual native
digitizer inputs in its repeated test:

```text
short swipe: (.05,.503) -> (.05,.520), duration .20 seconds
outside tap: (.55,.72) -> (.55,.72), duration .10 seconds
```

Cycle 2 left Dock's `myInBar=1`, with cached point `(620.814,791.825)`.
The complete native screenshot
`/tmp/macws-input-final-dock-five-cycles-20260920.png` was viewed by the parent
and shows the failure. This directly refutes treating the previous ten passes
as a completed repair or attributing every later failure to a state inherited
from before publication. The prehover contract and the old-state/recovery
observations remain valid narrower findings; the short-swipe/scroll-to-click
lifecycle required further evidence, provided by the Host-only A/B below.
This negative checkpoint itself did not establish a success rate or PASS.

## Short-swipe / outside-tap boundary: actual competing momentum stream

The parent's bounded witness
`/tmp/macws-dock-current-witness-20260920.log` adds evidence from the freshly
failed generation, rather than inferring delivery from a screenshot:

```text
uuid=E8663F86-D3E2-3B7D-9E24-65FEB7749100
#### OSXVNC POINTER-PROXY post kind=6 contact=1262642960 pixel=(1718.6,750.2)/2388x1668 quartz=(859.3,375.1) left=NO result=0/0
pid=38010 CGEventGetLocation=(620.814,791.825) CGSCurrentInputPointerPosition=(620.814,791.825) flags=0x20000100
CGSInputButtonState(1,0)=0 public HID left=0 right=0 center=0 session left=0 right=0 center=0
```

Probe 38014 subsequently returned the same inside location and zero buttons.
The input helper completed the actual outside tap; the proxy accepted it at
the correct outside point, with its local `leftDown` false and both original
post results zero. The following Host timestamps establish that the previous
Dock momentum transaction overlapped the new contact:

| Host event | Timestamp |
| --- | ---: |
| Short swipe's physical scroll ended | 1789861457.547 |
| Old-location momentum began | 1789861457.549 |
| New outside contact began | 1789861457.588 |
| Outside contact ended as a tap | 1789861457.738 |
| Old-location momentum ended | 1789861458.471 |

The actual global cursor returning inside makes this more than a stale Host
render or only a disagreement with Dock's cached position. This witness does
**not** by itself identify which later post moved the global cursor back; the
overlapping stream is a concrete candidate that requires transaction-level
verification or an isolated lifecycle A/B.

### Source-confirmed baseline lifecycle gap, and route caution

In the failed Host's `MacWSMetalView.m`, ordinary `touchesBegan:` entered
`beginDirectTouchCandidate:` without stopping `_scrollMomentumDisplayLink`.
The stationary candidate's Tap path also did not stop it. A newly classified
scroll, indirect-scroll begin, multi-finger gesture or scene lifecycle did
stop momentum. `scrollMomentumTick:` kept the old `_scrollMomentumFramePoint`
for its entire remaining stream. Consequently that producer permitted an old
synthetic scroll tail and a new independent direct contact to coexist. This
is a source observation, not a claim that every such overlap causes Dock's
failure.

The proxy's Scroll branch calls button-free `CGPostMouseEvent` for Began,
including momentum Began; every phase then creates a precise CG scroll event,
sets its location to the record's point, and posts it to the session. A theory
that the **first** momentum Began happened after this outside tap is refuted
by the timestamps above: it occurred 39 ms before the new contact began.

The Host's diagnostic line naming Dock window 20 is logged before
`routeFullscreenInputRecord:` finishes. Its later Dock/global-surface Scroll
normalization clears the encoded window to zero, which selects inputd's proxy
route. That earlier log alone cannot prove a window-20 AppInput delivery.
Conversely, the current AppInput exact-global-surface path and
`MacWSPostDockSystemInput` do not implement Scroll; their pointer-only helper
rejects it. Any claim that the measured momentum went through those methods
needs a post-normalization wire/consumer witness.

### Exact native scroll counterevidence

RE-confirmed via the actual Dock UUID
`2B02F563-15F3-38D6-96CD-CB6DD77A816C`: dispatcher jump-table entry for type
22 selects `+0x3b564`. It executes:

```text
+0x3b564 mov x0, x19
+0x3b568 mov w1, #0x7b
+0x3b56c bl  +0x2f7be0  ; CGEventGetIntegerValueField
+0x3b570 cbnz x0, +0x3cbf4
```

Field 123 is the momentum phase set by the producer. A nonzero phase returns
before the ordinary Dock wheel handler. Therefore the evidence does not
support saying that Dock's ordinary wheel handler itself processes the
momentum tail and rewrites `myInBar`. Global event-posting effects remain a
different boundary to validate.

### Other candidates explicitly not proven by this failure

The proxy's atomic-click helper ends with all buttons up, but the surrounding
listener does not clear its `leftDown` / `activeContact` bookkeeping. If an
atomic click overlaps a previously held contact, a later click can omit
prehover and Scroll can be dropped. That source inconsistency warrants its
own state-machine coverage, but the actual failed outside Tap above had
`left=NO`; it does not establish this as the cause of this reproduction.

A second, separate race is possible in the native consumer. RE-confirmed via
the same Dock: normal type-5 processing reaches `+0x3c8d8` calling
`+0x3cfd4`. At `+0x3cff4..+0x3cffc` it queries **current**
`CGSInputButtonState(1,0)`, not the moved event's own button snapshot. If
nonzero and `gCoreDragIsDragging` is zero, `+0x3d014` returns without the
normal point/enter-leave update. An immediately following down could in
principle race consumption of a queued prehover. No observed failing
consumer return has proved that interleaving here, and it cannot alone
explain the newer witness's global cursor returning inside. It is not a
justification for adding an arbitrary pre-click delay or bypassing Dock's
native button check.

The discriminating acceptance therefore needed to verify that a new real
contact ends the old momentum transaction before the new pointer action,
then check the actual global pointer, Dock state and native screenshot across
repeated short-swipe/outside-tap sequences. The following actual Host-only A/B
performs that check; neither fake-poster tests nor the earlier ten passes were
substituted for it.

## Accepted Host-only lifecycle repair and repeated native validation

The production change consists of six added lines at the start of
`MacWSMetalView`'s `touchesBegan:withEvent:`: a nonempty new contact calls the
existing `stopScrollMomentumWithTerminalPhase:YES` before focus/routing and
before any finger, pointer or Pencil contact is emitted. This closes the old
semantic stream through its normal terminal event and invalidates its display
link. It does not disable inertia, reset Dock's internal state, invent an
offscreen pointer, change native event validation or add a delay. The later
gesture retains its usual ability to begin its own momentum.

The recoverable Host-only publish receipt is
`/tmp/macws-host-contact-momentum-publish-20260920.json`. It records old Host
19850, reopened Host 39291, the new UUID above and the preserved old inode.
The signed installed file SHA-256 is
`0d4c9eff2233d6c8b551e169696ee802802a009b0c1cc5a995df1e1b960bf4a0`.
The publication receipt's immediate state says functional acceptance was
still needed; the subsequent artifacts below, not that publication alone,
provide acceptance.

Runtime-confirmed via
`/tmp/macws-dock-contact-fixed-witness-20260920.log`, using the same native
short swipe and outside tap as the failing experiment:

| Host event | Timestamp |
| --- | ---: |
| Short swipe's physical scroll ended | 1789862339.087 |
| Old-location momentum began | 1789862339.089 |
| Old-location momentum ended | 1789862339.129 |
| New outside contact began, after the terminal record | 1789862339.129 |
| Outside contact ended as a tap | 1789862339.279 |

The ordered raw log places the complete terminal route before the new
`direct-touch lifecycle=began` line, even though both round to the same
millisecond. There is no old tail continuing after the new tap. The proxy
remained PID 35523 and accepted the same outside coordinate:

```text
#### OSXVNC POINTER-PROXY post kind=6 contact=2895135872 pixel=(1718.6,750.2)/2388x1668 quartz=(859.3,375.1) left=NO result=0/0
pid=39386 CGEventGetLocation=(859.000,375.000) CGSCurrentInputPointerPosition=(859.000,375.000) flags=0x20000100
CGSInputButtonState(1,0)=0 public HID left=0 right=0 center=0 session left=0 right=0 center=0
pid=39390 CGEventGetLocation=(859.000,375.000) CGSCurrentInputPointerPosition=(859.000,375.000) flags=0x20000100
```

Those are the immediate and one-second-later pointer checks. Dock's
`myInBar` was false. The parent and the independent reviewer inspected
`/tmp/macws-contact-momentum-dock-fixed-20260920.png`: Dock is back to its
normal icon sizes and the sticky Terminal tooltip is absent. In contrast,
the preserved failing screenshot has visibly enlarged Terminal/neighboring
icons and the retained Terminal label.

After the bounded diagnostic witness, its watchdog and controller both
verified diagnostic state zero; the watchdog exited normally. Ten more
identical short-swipe → outside-tap cycles ran with diagnostics off. The raw
`/tmp/macws-dock-contact-ten-cycles-20260920.json` contains all ten individual
reader results, not only an aggregate success count. Independent parsing
confirmed every cycle 1 through 10 has:

```text
pass=true
myInBar=false
storedPointerFloat=(859.3070068359375,375.07501220703125)
dockTrackingRect=(49,755,1096,79)
```

The final native image
`/tmp/macws-contact-momentum-ten-cycles-20260920.png` was independently
viewed and likewise shows normal Dock sizes with no retained label. Dock's
UUID, PID and old library mapping remained unchanged throughout. This
isolates the accepted change at the upstream contact/momentum ownership
boundary rather than attributing recovery to a Dock or WindowServer restart.
