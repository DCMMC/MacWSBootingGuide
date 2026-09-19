# Office unsaved-document alert: observed rendering boundary

Status: the corrected kind-5 compiler adapter is installed. The real Word
87884 unsaved-document alert passes raw-window, button-bitmap and iPad-screen
inspection in a new process with a private diagnostic cache. The earlier
failures below are retained as investigation history, not the current result.
Normal shared-cache re-testing subsequently failed in owned Word 2999;
see [the separate default-cache acceptance](word-default-cache-acceptance-20260920.md).
Safe cache migration and final default-path acceptance remain outstanding;
live user applications and their mapped caches have not been disturbed.

## Real Word reproduction

User Word 71663, Excel 71161, PowerPoint 71345, and Terminal 17280 were
identified by exact executable path and preserved. The test launched a
separate Word 72393 with the installed canonical arm64 library:

```text
/usr/local/lib/libmachook_arm64.dylib
signed SHA256 273edeca9604272d4305b6c7f9b630d011367ce8c530701ca95ca8084454a141
mapped UUID 5EC31E06-F7D0-38CE-9989-34862E420C21
mapped __text SHA256 7f9c6e06380acedd01f8bc2758e473d4f92e340dfc40c774185c7f4f005769f1
```

In this owned instance, Command-N created a blank document; a short owned
test string was typed and Command-W requested closing without saving. The
real alert window 528 was 260 by 328 logical points, grouped with document
526. Its Save button showed white text but no colored background; the
Don't Save and Cancel backgrounds remained visible.

- Actual iPadOS composite:
  `/tmp/macws-word-unsaved-dialog-native-20260920.png`.
- Direct `CGWindowListCreateImage` of window 528:
  `/tmp/macws-word-unsaved-dialog-cg-20260920.png`.

Both images were inspected and show the same missing button background.
Thus the failure is already present before Host's iPadOS composition; it is
not explained solely by a Host window cropping/blending issue. The direct
capture reported owner 72393, bounds `562,228,260,328`, identity transform,
and a nonempty 260-by-328 image. VNC was not used as substitute evidence:
its port refused the connection, and no VNC service was restarted.

The default Word log at `/tmp/macws-word-unsaved-20260919-word.log` contained
font-registry, persistence, and a layout-recursion warning, but no explicit
Metal error. Diagnostics were off in that run, so lack of errors does not
demonstrate a successful GPU path.

## Standard AppKit controls and NSAlert comparison

A separate disposable, 18-second-bounded helper used the same canonical
library. It created an ordinary rounded NSButton, a Return-key default
NSButton, and a standard three-button NSAlert sheet. Only this helper had
process-local runtime/command-error diagnostics. No files or documents
belonged to the helper. No shader or rendering method was overridden.

The helper's actual output included:

```text
control window=535 default=1 primary-enabled=1 ordinary-enabled=1
alert-button index=0 class=_NSAlertButton cell=_NSAlertButtonCell enabled=1 bezel=1 state=0
bitmap name=alert-button-0 class=_NSAlertButton bounds=240.0,40.0 size=480x80 written=1
cg-window name=alert-cg id=546 size=260x312 written=1
```

Inspected CPU bitmap snapshots show the default buttons' blue backgrounds:

- `/tmp/macws-standard-alert-20260920-controls.png`
- `/tmp/macws-standard-alert-v2-20260920-alert.png`
- `/tmp/macws-standard-alert-v2-20260920-alert-button-0.png`

The same standard NSAlert also has its blue default-button background in
the direct raw window capture:
`/tmp/macws-standard-alert-v3-20260920-alert-cg.png`.
The sheet's owning control window is inactive/gray in
`/tmp/macws-standard-alert-v3-20260920-controls-cg.png`, consistent with its
modal state. This distinction avoids mistaking the inactive parent for a
failed default-button renderer.

The original helper attempted to nest `runModal` inside a main-queue GCD
callback and did not execute its subsequently queued sampling callbacks.
That run produced only the normal-button bitmap comparison and is **not**
an NSAlert acceptance result. It was corrected to the standard nonblocking
`beginSheetModalForWindow:completionHandler:` API; the v2 and v3 helpers
returned zero. Their screen snapshots did not show the helper in front of
Word, so those full-screen images are not counted as alert-screen evidence.
The helper's self-targeted `CGWindowListCreateImage` is the actual raw-window
comparison. No Target OS/CoreImage failure was found in the bounded helper
logs, which alone is not comprehensive error coverage.

## First process-local Word observation attempt

A new owned Word 75111 loaded the same canonical UUID plus the explicit
test-only `/private/tmp/macws_alert_observer_20260920.dylib`. Its source was
reviewed: it preserves the original NSAlert methods and schedules one
modal-compatible timer, capturing raw CG pixels before and after each
button's `cacheDisplay`. Runtime/command-error diagnostics applied only to
this owned process.

The observer installed, but Word's real alert did not traverse the two
observed public NSAlert entry points. Actual log:

```text
ALERT-OBS installed pid=75111
```

No `ALERT-OBS` captures followed. The production window-metrics diagnostic
identified the real window 554 as `NSKVONotifying__NSAlertPanel`, grouped
with owned document 552. The real failure still appeared in
`/tmp/macws-word-alert-observed-screen-20260920.png`. Therefore this attempt
does not supply Word-internal CPU bitmap evidence and must not be described
as an observed shader failure or a zero-error result. Raw log:
`/tmp/macws-word-alert-observed-20260920.log`.

Both owned Word instances were closed normally using Don't Save for their
own test document followed by Command-Q. Post-operation process inventories
confirmed they had exited and all four protected user applications remained.
The current Dock input endpoint was re-resolved to PID 70850 after an older
17120 endpoint proved no longer live; no input through that stale endpoint
was counted as a successful action.

## Actual Word button pipeline failure and fresh-cache control

The corrected alert-window observer (v2) reached owned Word 75724's real
`NSKVONotifying__NSAlertPanel`. It captured raw CG pixels before and after
the three actual buttons' `cacheDisplay`. Both CG images lacked the blue
Save background. Buttons 0/1 (Cancel/Don't Save) rasterized normally;
button 2 was white text over transparency. These are application-generated
pixels, not a Host-only compositing symptom. Files are
`/tmp/macws-alert-owned-75724-{cg-before,button-0,button-1,button-2,cg-after}.png`.

Owned Word 77878 added a process-local compute-pipeline observer, with
broad runtime diagnostics **off**. All three observed public interfaces
reported installation. Its real Save-button bitmap operation emitted:

```text
ALERT-OBS button=2 class=_NSAlertButton cell=_NSAlertButtonCell enabled=1 state=0 bezel=1 bounds=0.0,0.0,240.0,40.0 layer=_NSViewBackingLayer
CI-PIPELINE-OBS pid=77878 selector=newComputePipelineStateWithDescriptor:options:reflection:error: function=ciKernelMain error=Error Domain=AGXMetal13_3 Code=3 "Target OS is incompatible." UserInfo={NSLocalizedDescription=Target OS is incompatible.}
2   CoreImage 0x00000001ac5743b4 CreateComputePipelineState + 248
3   CoreImage 0x00000001ac573390 CIMetalComputePipelineStateCreateFromDAG + 52
4   CoreImage 0x00000001ac573258 _ZN2CI8MetalDAG7compileEj + 304
```

Raw log: `/tmp/macws-word-alert-pipeline-20260920.log`. The same failure
preceded the bitmap request during actual alert drawing. This links the
missing Save background to an actual rejected CoreImage pipeline, rather
than inferring GPU failure from a stale cache file alone.

An additional owned Word 79289 used the stock Metal cache-path API before
creating its first device. This **diagnostic-only** isolated directory was
created with `mkdtemp`; the real getter verified it:

```text
METAL-CACHE-SCOPE READY pid=79289 requested=/private/tmp/macws-metal-cache-scope-79289-bypn0Q actual=/private/tmp/macws-metal-cache-scope-79289-bypn0Q inode=53537806 no-gpu=yes no-shared-cache-mutation=yes
```

The installed canonical library's mapped UUID was
`5EC31E06-F7D0-38CE-9989-34862E420C21`, actual arm64;
`__text` SHA-256 was
`7f9c6e06380acedd01f8bc2758e473d4f92e340dfc40c774185c7f4f005769f1`.
All four public/private observed compute interfaces installed. The real
alert **still failed**, with the same `ciKernelMain` Code 3 failure,
including during button 2's bitmap operation. Inspected raw CG image:
`/tmp/macws-alert-owned-79289-cg-before.png`; complete screen:
`/tmp/macws-word-fresh-cache-alert-20260920.png`; log:
`/tmp/macws-word-alert-fresh-cache-20260920.log`.

The newly created private `31001/libraries.data` was 163840 bytes, SHA-256
`a851d2f66308757a1b475bdbafdeae9a52f5f105ecdb1f106d7900f9da8c4bf1`.
Six complete MTLB records had MacABI header `0x86`. At offset 22816 a
10672-byte native-macOS `0x81` / macOS 13.4 `ciKernelMain` record was
newly present, containing the `CUIShapeEffectFilters.metal` source name.
Its SHA-256 was
`90768d63ae44acadd3c3ab4b1f175f513dee0bc63119df4b9ccba38966043241`,
identical to the previously identified incompatible shared-Word record.
Copies: `/tmp/macws-word-fresh-cache-79289-libraries.{data,list}`.

Thus merely deleting/migrating Word's old shared cache is **not sufficient**:
the current fresh-cache path reproduces the incompatible output. This
does not by itself locate the faulty producer; compiler request/reply or
actual CoreUI input provenance is still needed. No shared cache, user
document, production library, or global diagnostic flag was modified.
Each owned Word above was normally closed using Don't Save only on its own
test document, then Command-Q; PID absence was checked independently of
the launch observer's 300-second wait limit. All four protected user
applications remained alive.

## Compiler request correction and real Word fresh-cache acceptance

The independent 16×16 `CUIHueSaturationFilterLocal` reproducer traversed
compiler request kind **5**, not the ordinary CoreImage kind-14 DAG path.
The first compiler candidate made that small fixture render all 256 pixels,
but this was **not sufficient Word acceptance**. It returned
`visible=256 changed-bytes=226 varied-bytes=672`, while the real Word Save
button in owned PID 86703 remained broken. Candidate 1 was preserved with
this limitation explicitly recorded rather than claiming the UI was fixed.

One bounded real-Word capture (owned PID 87091) established the difference:

```text
[2026-09-20 02:18:53 pid=87122] target adapter entry #1 a0=0x2826cc0e0 a1=0xffffffff a2=0x5 request=0x10023c000 total=139288 a5=0x16fd3e4b8 head=09000000-b4000000-02000000-68020000
```

The Word request was **139288** bytes, versus **139840** in the small
fixture. It did not enter candidate 1's module-target adaptation. Its
10776-byte reply contained at +104 the identical incompatible 10672-byte
MTLB, SHA-256 `90768d63...643241`. The full runtime request/reply, not a
guessed app whitelist, supplied the next parser regression fixture:

- `/tmp/raw-87122-001-5-139288-7abde80b00408403.bin`
- `/tmp/reply-87122-001-10776-11647568e5cb115d.bin`
- `/tmp/macws-word-alert-kind5-capture-fresh-20260920.compiler.log`

The parser was corrected against the actual producer's 8-byte module
alignment contract. The second, source-frozen compiler artifact was built
with both architectures, then signed/admitted and published by one atomic
new-inode replacement of the actual TweakInject file. No existing compiler
worker, application, or WindowServer was restarted. Publication receipt:
`/tmp/macws-compiler-kind5-word-publish-20260920.json`.

Candidate 2 identities:

- Pre-device-signing artifact SHA-256:
  `3b9777e280f524be56c0980583c496d005a59832a5a00ba5ced6baa7e60a8ab0`.
- Installed signed SHA-256:
  `164652ab63384b51c30d094cabe95b912aad877b6992a369057f001d4aaf8cc9`;
  inode **1708236**.
- Artifact arm64 UUID: `E4A381C8-A561-3DC9-BD1C-686184850535`;
  arm64e UUID: `FA946B15-9537-366B-A01A-0D2231C25585`.
- Source `Tweak.x` SHA-256:
  `ff3b64035a9bc2583ddf613a701f0b00de28fe10ac5f1e3b26941e3eb8aaca03`;
  image-filter request header SHA-256:
  `f7a1e0fcc35923a5fd679ffb11aff6a53744c7daef8d4d8f10708a709fc2d991`.

A fresh-cache owned Word **87884** replayed normal New → type our test text
→ Close, producing its real unsaved-document alert. The new worker **87918**
now executed:

```text
[2026-09-20 02:26:48 pid=87918] Image-filter target context installed=1 restore-rx=0
[2026-09-20 02:26:48 pid=87918] MacWS image-filter module-target count=2 adapted=1
```

Its **same 139288-byte input** returned a MacABI `0x86` MTLB, length 10672,
SHA-256 `0dc34c377ac98c576623be53d78b6c01fc3c25e17153e84d6ffee8c02a226102`.
Actual reply: `/tmp/reply-87918-001-10776-4f35b8d7bf390918.bin`.

The Save button's real blue gradient/white text was inspected in all three
independent outputs:

- Raw app window before CPU bitmap capture:
  `/tmp/macws-alert-owned-87884-cg-before.png`.
- Actual button's `cacheDisplay` bitmap:
  `/tmp/macws-alert-owned-87884-button-2.png`.
- Full native iPad screenshot:
  `/tmp/macws-word-kind5-word-fixed-alert-20260920.png`.

All four compute-observer interfaces reported installation; no observed
pipeline failure was logged in this bounded run. That is scoped coverage,
not a claim about every possible GPU operation. Diagnostic compiler capture
lasted approximately 6.6 seconds and its `/tmp` marker was removed in
`finally`. The owned document was discarded normally and owned Word quit;
protected user applications and WS retained their original PIDs/start times.

This is a **real UI pass with a private diagnostic cache**, not yet an
acceptance of a regular Word launch using the pre-existing shared cache.
That final no-observer/default-cache acceptance remains separate; user
documents and mapped caches must not be disrupted to obtain it.

### Runtime identity and rollback boundaries

Fresh worker task ports refused the mapped-image probe (`task_for_pid=5`),
even with an owned test held alive three seconds. The artifact UUIDs above
are therefore **not claimed as remotely verified mapped UUIDs**. Runtime
loaded-code evidence is the exact signed-inode publication, a newly born
worker executing the candidate-only target-adapter log/entry, its captured
request/reply, and real computed/visible pixels. No repeated task-port
attempts or debugger attachment was used to bypass the refusal.

The original production inode is preserved outside autoload at
`/var/jb/usr/macOS/rollback/compiler-kind5-20260920/MTLCompilerBypassOSCheck.dylib.disabled`
(SHA-256 `cc964e73f1fd5ce1e8aefe4147f72019230a89f04d72d635d6823b34e4df1081`).
Candidate 1 is separately preserved at
`/var/jb/usr/macOS/rollback/compiler-kind5-word-20260920/candidate1-MTLCompilerBypassOSCheck.dylib.disabled`
(SHA-256 `7af7bb37d018f247e7a5182c8d3bcb17d8502c085a740210ba243c45b9923479`).
Neither directory is a tweak autoload directory. The two backup generations
must not be confused. No `make install`, respring, or compiler `killall`
was invoked.

## Historical next discriminator (superseded by the observations above)

The present evidence narrows the problem to Office's in-process rendering
path or its resources/cache: generic AppKit/NSAlert CPU and raw-window output
work, while fresh Word with the same library does not. It does not yet
identify which exact shader/resource causes the missing button background.
The next useful observation is the actual Word alert's raw CG image and
button CPU bitmap, captured through the real alert-window boundary rather
than assuming the public NSAlert entry points were invoked. Shader-cache
content and target incompatibility evidence collected independently should
be correlated with that active drawing path before any cache or production
change is called a fix.
