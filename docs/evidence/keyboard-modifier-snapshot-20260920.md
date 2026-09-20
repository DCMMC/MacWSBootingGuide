# Keyboard modifier snapshot evidence — 2026-09-20

Latest bounded acceptance: the final proxy35523 generation passes the recorded
fullscreen/window shortcuts, held-Command scene transition, and genuine
Code → Dock Terminal → immediate shortcuts with diagnostics off. Immediate
Tab during creation of a replacement Scene remains a negative case; a
test-only readiness wait succeeds and is not a production fix. The final
section records both outcomes. Earlier intermittent negatives are not erased
or attributed to an unproven candidate.

## Read-only proxy witness

While the user reported a stuck Control/Command state, OSXvnc-server PID 17142
remained the existing process (birth time `Sat Sep 19 17:25:37 2026`). No target
thread was suspended, no event was injected, and no target memory was written.
The exact mapped image was inspected using the existing bounded identity
helper:

```text
pid=17142 process=OSXvnc-server task-for-pid=0
image=libmachook_arm64.dylib base=0x10473c000 cpu=16777228 subtype=0 uuid=60605e6423c8384ba884bc0b20d4ce52 text-address=0x104740000 text-bytes=633912 text-sha256=e896416471393fb6268576170bf35fc5b7df92466fd3a8e55938131e054ac14f
```

The retained matching build `/tmp/libmachook_iosurface_protection_arm64.dylib`
has UUID `60605E64-23C8-384B-A884-BC0B20D4CE52` and file SHA-256
`323506831958b89a8d48b930ef69ccc1f25e1743443bc17a3aeab9ab70bc92f1`.
Its symbol table identifies exactly these two 32-bit globals:

```text
000000000252338c b _macws_vnc_proxy_explicit_modifiers
0000000002523390 b _macws_vnc_proxy_synthetic_modifiers
```

The dedicated reader checked PID/executable path, Mach-O header, exact UUID,
and readable segment bounds before reading just those eight data bytes. A
repeat observation at device-reported UTC `2026-09-19T19:21:47Z` returned:

```text
observed-path=/private/var/mnt/rootfs/usr/local/bin/OSXvnc-server
pid=17142 path=/private/var/mnt/rootfs/usr/local/bin/OSXvnc-server task_for_pid=0
uuid=60605E64-23C8-384B-A884-BC0B20D4CE52 base=0x10473c000 explicit_offset=0x252338c synthetic_offset=0x2523390 explicit=0x0 synthetic=0x0 bytes=8 no_suspend=yes no_target_writes=yes
```

Reader source: `/tmp/macws_vnc_modifier_snapshot_20260920.c`; executed helper:
`/tmp/macws_vnc_modifier_snapshot_v3_20260920`. Two earlier attempts exited 77
at the executable-path guard, before any target state read, because
`proc_pidpath` returned the host's `/private/var/mnt/rootfs` prefix rather than
the chroot path. The final guard allows only those exact validated aliases;
the image UUID and eight-byte bounds were not relaxed.

This proves only that the proxy's two internal masks were zero at the sampled
instants. It does **not** prove that WindowServer's native modifier state was
zero, or that the original missing physical release has been identified.
Reconciliation must not use the internal masks alone as evidence that there
is nothing to release.

## Pure state-machine regression tests

`include/macws_keyboard_state.h` separates the current physical snapshot from
successfully posted modifier sides. It permits an explicit native-state read
at a snapshot boundary; ordinary key processing does not perform native I/O.
Each release/press commits its posted side only after the real poster reports
success. Left/right Shift, Control, Option, and Command are independent.
Software chords restore the physical snapshot instead of unconditionally
releasing a genuinely held modifier.

`python3 -m unittest discover -s misc -p test_keyboard_state.py -v` compiles and
executes the actual C header. It passed the native-held/internal-zero case,
left/right ownership, explicit focus cancellation, post-failure retry,
software-chord restoration, and all 65,536 pairs of eight-side transitions.
These tests establish the translator's local contract, not installed Host
input or Dock visual acceptance.

An additional regression covers the asynchronous native-post boundary:
accepted Control-down followed by an immediate native read of zero must still
produce Control-up on the next released physical snapshot. Native observations
therefore add known-down sides; they do not erase locally accepted transitions
merely because the system has not processed them yet.

The parent investigator subsequently reported one narrowly scoped real
Control-keycode-59 release and a new read-only observation (probe PID 10362):
combined-session flags changed from `0x20040100` with `key59:1` to
`0x20000100` with `key59:0`; the HID snapshot remained zero. This was a
temporary recovery of the captured live state, not deployment or acceptance
of the new state-machine fix. No release event was sent by this audit agent.

## Dock boundary remains separate

Source review shows the fullscreen OSXvnc pointer listener posts an atomic
finger tap as down/up at the tap location. A sustained pointer down has an
additional native hover/activation preflight, and physical pointer movement
continues to supply hover records. A missing touch hover-exit or hit-test
preflight remains a **THEORY**, not a proven explanation of the user's stuck
Dock magnification. No Dock setting, magnification check, or pointer geometry
was changed by this audit. The real touch sequence must be rechecked after
the modifier-state correction.

## Coherent deployment and cache-generation retirement

The first keyboard-only library build was **not deployed**: review found that
it omitted the established production C macro
`ADDITIONAL_CFLAGS=-DLIBMACHOOK_ON_DEVICE_BUILD=1`. The replacement combined
keyboard/JSON build retained that macro and the Apple ld64 linker. Its frozen
source/build receipt is `/tmp/macws-keyboard-json-lib-build-receipt-20260920.json`.
The final Host/inputd owner-lifecycle rebuild is in each project's
`.theos/macws-keyboard-owner-20260920/`, not the earlier keyboard directory.
The final complete source test run reported `Ran 444 tests` and
`OK (skipped=12)`; skips remain skips, not device acceptance.

Actual isolated, no-diagnostic CLI processes loaded each final library slice
and completed a real fork/wait round-trip. The retained raw log is
`/tmp/macws-keyboard-cli-smoke-20260920.log`:

```text
CLI-SMOKE main-subtype=00000000 pid=14202
CLI-SMOKE mapped=/private/tmp/macws-keyboard-stage-20260920-UcGdUD/libmachook_arm64.dylib uuid=6B46FD91-A12A-37D9-92F5-EBA1F07F55AA
CLI-SMOKE PASS default-constructor+stdout+fork
CLI-SMOKE main-subtype=80000002 pid=14201
CLI-SMOKE mapped=/private/tmp/macws-keyboard-stage-20260920-UcGdUD/libmachook.dylib uuid=6E014D8F-F233-3820-A51C-1F4466323845
CLI-SMOKE PASS default-constructor+stdout+fork
```

Signed deployment identities (the two library slices and inputd each have
matching iOS-side/chroot canonical copies):

| Artifact | UUID | Signed SHA-256 |
| --- | --- | --- |
| libmachook arm64 | 6B46FD91-A12A-37D9-92F5-EBA1F07F55AA | 2cc2fa505a9b543080a1d60bc29bacc7eeaec9faa25e4aadcf596ccfa75b06c5 |
| libmachook arm64e | 6E014D8F-F233-3820-A51C-1F4466323845 | 232c275bd62d5328a592f0d427c3bf04ac48c70e7c815d9e8eb35bdbbc31f435 |
| MacWSHost | 82A54432-7862-326D-AE49-C3C84E7F7800 | a11a8468661c29e0c6075fac782c1135ace7c4450837a2dc2a5cfb97a6426503 |
| macwsinputd | B1C8AFE2-257E-3D95-BF5C-C8FEFDDF473F | 9c339e920f50adaede0a6628ca52151db0d79518ab103da0f54f305aef74d77b |

After the user confirmed that all macOS applications could close, the exact
native Host path and birth identity were checked before TERM. The normal
`macos_gui.sh stop` returned 0. The strict root-vnode inventory then correctly
blocked publication because four Sublime processes were still alive: the
existing stop script's fixed application-name list does not cover Sublime.
Only the exact verified chroot Sublime main/plugin PIDs were retired with
TERM; its crash handler had already exited. A second root-vnode inventory was
empty. This is a documented stop-list coverage gap, not a reason to weaken
the cache-migration guard.

All seven canonical targets were published by same-directory atomic rename,
with each original inode retained by hard link outside autoload locations.
Mode/owner/group and final signed hashes were checked. Host Info.plist decoded
content, AppIcon bytes, and original entitlements matched the replacement.
The publication helper's temporary-filesystem tests also exercised a failure
on the fourth rename and recovery of all original inodes. Device receipt:
`/tmp/macws-keyboard-20260920-UcGdUD-publish.json`; backup paths are recorded
per target there. No live mapped library inode was rewritten.

Strict cache migration (without `--defer-if-running`) returned:

```text
METAL-CACHE {"retired_files": 28, "state": "migrated"}
{"schema": "macws-macabi-image-filter-v3"}
```

The separate `--check` exited 0. All 28 derived cache files remain recoverable
under `Library/Caches/MacWS/metal-library-target/retired/`; migration journal
`macws-macabi-image-filter-v3.json` records their original metadata. No user
document or preference was removed. The subsequent production start uses
`coexist --no-vnc`, with diagnostics off and no persistent RFB pixel-copy
overhead. During stop/publication, SpringBoard PID315 and backboardd PID350
both retained their exact original `Sat Sep 19 12:27:33 2026` birth identities.
No iPad reboot or respring was performed. Real keyboard and default-cache
Word visible-output acceptance remain separate from these deployment checks.

The normal production startup completed successfully in 63 seconds
(`/tmp/macws-keyboard-start-20260920.log`). Fresh identities were verified with
bounded, non-suspending task reads: inputd15987 has executable UUID
`B1C8AFE2-257E-3D95-BF5C-C8FEFDDF473F`; it, WindowServer15997 and OSXvnc16260
all mapped the new arm64 library UUID `6B46FD91-A12A-37D9-92F5-EBA1F07F55AA`
with actual 648460-byte `__text` SHA-256
`8c2ac164642db290c091c5d7940c0610187f0835629240642c909610c0fb5317`.
Fresh native Host16375 mapped UUID `82A54432-7862-326D-AE49-C3C84E7F7800`
with actual `__text` SHA-256
`e7ca7dcff6a432a84a7a8dd774cbee847c03b4fde312bfdd60167c95bcb0ca86`.
These match the frozen artifacts, not merely their on-disk filenames.
Terminal16275 was visibly rendered behind the normal Host control center in
the inspected full-iPad screenshot
`/tmp/macws-keyboard-host-ready-20260920.png`. CoreLocationAgent16158 and
interop16142 belong to the same fresh GUI generation. Keyboard interaction
testing was then handed to the parent; no Word UI was injected concurrently.

## Native iPadOS input acceptance after publication

Runtime-confirmed via `/tmp/macws-keyboard-inputlab-native-events-20260920.jsonl`
and the native iPad screenshots below. The explicit, bounded
`misc/ios_hid_key_chord_probe.c` sends keyboard-page HID events through iPadOS;
it does not write MacWS input datagrams. Every release event is allocated
before the first down, but receives its timestamp immediately before dispatch.
The diagnostic is not installed as a service or called in production.

Input Lab PID17211 ran against the canonical library without debug switches.
The native digitizer metadata identified the current boot's built-in SPI
service as `0x1000007e6`. A center tap through that sender produced real
AppKit `left_down`/`left_up` events; dispatch return alone was not accepted as
proof. Do not reuse a previous boot's sender ID without checking it again.

After the initial individual checks, five consecutive repetitions of
Ctrl+B, right-Ctrl+C, Cmd+M, and right-Cmd+M (20 chords total) delivered
the expected control characters and menu actions. The saved log has 136
events: 14 ordinary key-down/up pairs, 13 menu actions, 85 modifier changes,
and four left-down/up pairs. Representative actual events:

```text
sequence=12 event=key_down key_code=11 modifiers=262400 characters="\u0002"
sequence=14 event=flags_changed key_code=59 modifiers=256
sequence=17 event=key_down key_code=8 modifiers=262400 characters="\u0003"
sequence=21 event=flags_changed key_code=62 modifiers=256
sequence=27 event=menu_action modifiers=1048832
sequence=30 event=flags_changed key_code=54 modifiers=256
sequence=135 event=left_down button=0 modifiers=256 pressed_buttons=1
sequence=136 event=left_up button=0 modifiers=256 pressed_buttons=0
```

These are field-for-field transcriptions of the JSON events, not fabricated
success counters. Read-only native-state probe PID17443 after those chords:

```text
state=1 flags=0 keys=59:0,62:0,55:0,54:0,58:0,61:0,56:0,60:0,57:0,48:0,0:0, buttons=0,0,0
state=0 flags=0x20000100 keys=59:0,62:0,55:0,54:0,58:0,61:0,56:0,60:0,57:0,48:0,0:0, buttons=0,0,0
```

Terminal16275 was then exercised with native HID, not a shell command sent
over SSH. Cmd+T created a second real tab. Unexecuted marker text `first`
and `second` distinguished the two tabs. Ctrl+Tab visibly changed from
`second` to `first`, and Cmd+A visibly selected the terminal contents blue.
Right-Ctrl+Tab also switched tabs. The same Ctrl+Tab and Cmd+A operations
worked after leaving the fullscreen workspace for window mode. The parent
personally inspected these full iPadOS captures:

- `/tmp/macws-keyboard-terminal-second-20260920.png`
- `/tmp/macws-keyboard-terminal-ctrl-tab-20260920.png`
- `/tmp/macws-keyboard-terminal-command-a-20260920.png`
- `/tmp/macws-keyboard-terminal-windowed-20260920.png`

Both marker lines were cleared with Ctrl+U without execution. Input Lab
exited normally through its real Cmd+Q menu equivalent. The original short
Input Lab run was inconclusive for ordinary keys because Ctrl+Tab transferred
its first responder to a native button; the screenshot confirmed that focus
change. It was not counted as a lost-key failure or as a passing key test.

Scope: this verifies real iPadOS-to-AppKit input, left/right modifier releases,
subsequent ordinary clicks, and the reported Terminal shortcuts in both modes.
It is not a claim of exhaustive physical Magic Keyboard testing or reliable
delivery under deliberately injected UNIX-datagram loss. The pure-C state
tests separately cover producer-side ambiguity, scene handoff, failed event
posting, and delayed native key-state observation.

### Post-acceptance route audit

The review found two additional boundary inconsistencies in the candidate,
before final submission. Neither is presented as an observed user failure:

- The broker's new early KeyUp route was broader than its KeyDown route for
  plain software-keyboard ASCII. Both now use the same production
  `IsNativeKeyboardProxyRecord` predicate. An executable test extracts that
  real C predicate and checks all source/modifier/keysym combinations in both
  directions. Ordinary/Shift software text retains AppInput; hardware and
  software command/special keys retain the session proxy.
- The controller formerly rejected every press when input was unavailable,
  despite the view permitting KeyUp. It now blocks new downs only. The pure-C
  producer's `MacWSKeyboardSourceApplyOwned` permits an existing owner to
  release keys while disabled, without claiming ownership or adding a new
  held modifier. Its actual C implementation is exercised for pre-edge right
  Control release, aggregate-only release, rejected new downs, and rejection
  of disabled non-owners.

The updated complete suite passed 444 tests, 12 skipped, in 54.604 seconds:
`/tmp/macws-keyboard-release-all-tests-20260920.log`. Only the Host and inputd
need replacement for these final boundary changes; the already verified
library and WindowServer generation do not change.

After the final Host/inputd replacement, a further native-HID test held
right Control for 2500 ms while requesting `exit-workspace`, then held right
Command for 2500 ms while requesting `enter-workspace`. The native helper
reported the held interval before each mode change and released afterward.
This exercises release across an actual presentation/Scene handoff rather
than an empty-state mode toggle. The read-only probes after the respective
releases (PIDs20027 and 20060) both reported:

```text
state=1 flags=0 keys=59:0,62:0,55:0,54:0,58:0,61:0,56:0,60:0,57:0,48:0,0:0, buttons=0,0,0
state=0 flags=0x20000100 keys=59:0,62:0,55:0,54:0,58:0,61:0,56:0,60:0,57:0,48:0,0:0, buttons=0,0,0
```

Subsequent native Ctrl+Tab selected the second Terminal tab, and Cmd+A
visibly selected its contents. Inspected full-iPad screenshot:
`/tmp/macws-keyboard-final-held-scene-release-20260920.png`. The self-created
second tab was then closed normally with Cmd+W. A genuine primary touch in
the remaining original terminal cleared selection without opening a context
menu; screenshot `/tmp/macws-keyboard-final-primary-click-20260920.png` and
probe20117 again confirmed all modifier keys and mouse buttons released.
No synthetic test marker was executed as a shell command or saved to a user
document. No diagnostic switch was enabled for these final tests.

### Final Host/inputd-only publication

The frozen `7462b83` Host and paired-route broker were signed and admitted
under their canonical basenames, then installed using three new inodes.
Host entitlements and decoded Info.plist were checked against the installed
application before publication. The old inodes remain recoverable outside
autoload directories:

- `/var/jb/usr/macOS/rollback/final-frontend-20260920/`
- `/var/mnt/rootfs/usr/local/lib/.macws-rollback-final-frontend-20260920/`

Only native Host16375 and inputd15987 were stopped. The input job's process
group was checked to contain no other process before its normal
`launchctl bootout`/`bootstrap` lifecycle. The first helper invocation stopped
Host, then failed because `/bin/launchctl` does not exist on this device; no
canonical file had changed. The receipt records this interruption and the
guarded continuation using the verified `/var/jb/usr/bin/launchctl` path.

The final signed files and actual non-pausing mapped identities agree:

| Component | New PID | Mapped UUID | Signed file SHA-256 |
| --- | --- | --- | --- |
| Host | 19850 | `5C169C83-7C4A-31DB-A0E4-EC2BDA0732BF` | `4a37b3f4fc47d14ae0e56531346bad1f6f3293c46d87054dd4878dd6744d38b5` |
| inputd, both canonical copies | 19848 | `2E83E844-F080-309F-990B-91DD28748968` | `551389ea81cf21e43de257278c27aff93228216499c066f4f64834371ccd0f74` |

Mapped Host text is 405492 bytes, SHA-256
`192dd3954f172f1d324c60892f18b579e448e964de9f4773b151a179cdd42b20`;
broker text is 19324 bytes, SHA-256
`6b64abf6116ebe99747efe33b9842f436e80215547900803402c1fc95ca1edda`.
The broker still maps the verified `6B46FD91` arm64 library. WindowServer15997,
Terminal16275, session proxy16260, SpringBoard315 and backboardd350 retain
exact executable, birth time, parent and process-group identities. No library,
Metal cache, WindowServer or iPadOS session was restarted in this final refresh.

Local receipts are `/tmp/macws-keyboard-final-frontend-manifest-20260920.json`,
`/tmp/macws-keyboard-final-frontend-refresh-20260920.json`, and
`/tmp/macws-keyboard-final-frontend-mapped-20260920.log`. Device transaction
receipts are under `/tmp/macws-keyboard-final-frontend-20260920/`.

## Later Terminal witness and diagnostic-off fast-switch acceptance

Terminal PID16275 is the existing **arm64e** process, not an arm64 consumer.
Its actual `libmachook.dylib` UUID is
`6E014D8F-F233-3820-A51C-1F4466323845`, with 629,748-byte `__text` SHA-256
`87299afb76774491022a42eccd117c65d28f39a9c4c000c763ae19c0215eb5c8`.
The additional atomic-click activation candidate was withdrawn; at this stage
proxy31982 was the restored prehover-only arm64 image
`BF8EBB44-48A7-3631-96EB-C2D75FB7FA69`. No claim is made that the old Terminal
mapping was replaced by either proxy-only deployment.

Before the final no-diagnostic checks, a bounded 30-second diagnostic observed
the existing Terminal event route. Only the exact validated four-byte cached
AppInput diagnostic state was temporarily changed `0 -> 1 -> 0`; both the
controller and independent watchdog verified restoration. No diagnostic flag
file, application restart, iPad reboot, or respring was needed. This was
temporary diagnostic state, not a production feature-enablement dependency.

Runtime-confirmed verbatim excerpts from
`/tmp/macws-terminal-input-witness-20260920.log`:

```text
[launchdchrootexec] target=/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal arch=arm64e insert=/usr/local/lib/libmachook.dylib
#### APP-INPUT MOUSE-EVENT pid=16275 serial=2 type=1 window=93 clicks=1 local=(18.00,310.00) pressed=0x1 at=66125.310540
#### APP-INPUT SYSTEM-ACTIVATE pid=16275 window=93 active-before=NO active-after=NO
#### APP-INPUT SYSTEM-ACTIVATE-EVENT pid=16275 window=93 data1=47 data2=0 retained=YES
#### APP-INPUT KEY-EVENT pid=16275 serial=1 type=10 keycode=48 chars=\t active=YES window=93 responder=NSKVONotifying_TTView at=66125.463309
#### APP-INPUT KEY-RETURN pid=16275 serial=1 elapsed=15.591ms active=YES responder=NSKVONotifying_TTView has-string=YES length=207
#### APP-INPUT KEY-EVENT pid=16275 serial=2 type=11 keycode=48 chars=\t active=YES window=25 responder=NSKVONotifying_TTView at=66125.524413
#### APP-INPUT KEY-EVENT pid=16275 serial=3 type=10 keycode=0 chars=a active=YES window=25 responder=NSKVONotifying_TTView at=66142.775185
#### APP-INPUT KEY-RETURN pid=16275 serial=3 elapsed=3.407ms active=YES responder=NSKVONotifying_TTView has-string=YES length=1526
```

These samples establish real AppKit delivery and show the Tab down in window93
followed by its up in window25. The immediate `active-after=NO` mouse witness
is not by itself a failed activation: the later key event reports `active=YES`.
They do not prove every earlier intermittent first-key failure has the same
cause; enabling diagnostics can also affect timing. Final acceptance therefore
used the restored production diagnostic-off state, not this trace alone.

### Repeat checks after diagnostics were off

The parent sent native HID through iPadOS for each Code → touch Terminal →
immediate shortcut cycle. No MacWS input datagram or shell command substituted
for the real key. The following full-iPad screenshots were inspected by the
parent and independently reviewed for this evidence update:

| Native-HID sequence | Visible result and retained screenshots |
|---|---|
| Three immediate Control-Tab cycles, covering left and right Control | Two existing tabs alternate, confirmed by both selected-tab appearance and different visible content. `/tmp/macws-key-nodiag-cycle-1-20260920.png`, `-cycle-2-20260920.png`, `-cycle-3-20260920.png`. |
| Three Command-A cycles, covering left and right Command | Each screenshot shows Terminal contents fully selected blue. `/tmp/macws-key-nodiag-cmda-1-20260920.png`, `-cmda-2-20260920.png`, `-cmda-3-20260920.png`. |
| Window mode: Command-T, Control-Tab, Command-A | A new test tab exists, the original tab is selected, and its content is blue-selected. `/tmp/macws-key-final-window-shortcuts-20260920.png`. |

The parent additionally inspected window-mode right-Control-Tab switching to
the owned test tab, right-Command-A selecting that tab blue, and a native
screen tap at `(.60,.30)` clearing selection without opening a context menu:
`/tmp/macws-key-final-window-rightctrl-20260920.png`,
`/tmp/macws-key-final-window-rightcmd-20260920.png`, and
`/tmp/macws-key-final-window-primary-20260920.png`.
The immediately subsequent read-only native-state probe PID33400 reported all
eight modifier keys, Tab/A, and mouse buttons released; combined flags were
`0x20000100`. The self-owned second tab was then closed normally with Command-W,
leaving the original Terminal tab intact.

These observations support bounded acceptance of the reported shortcuts in
both modes with diagnostics off. They are not a 100% reliability claim,
exhaustive hardware-keyboard coverage, proof of the earlier intermittent
failure's complete cause, or acceptance of the separately unresolved sticky
Dock magnification. In particular, no keyboard success is credited to the
withdrawn extra atomic-click activation callback.

Local follow-up executed the actual pure keyboard state, wire, and producer
tests using `python3 -m unittest misc.test_keyboard_state
misc.test_keyboard_snapshot_wire misc.test_keyboard_source -v`: all three
tests passed (1.509 seconds). This documentation update performed no device
writes, UI injection, or process lifecycle changes.

## Final input-lifecycle generation and asynchronous handoff boundary

The final state-model change records the last successfully submitted UP for
each modifier side in `acceptedUpSides`. A native state read can still report
the old DOWN while that UP is queued. If the new scene owner still holds the
same side, the translator must submit a new ordered DOWN after the pending UP;
the stale native DOWN must not suppress it. Submission history is cleared by
an accepted DOWN, not merely by observing native zero. Failed posting retains
the existing retry contract. This is a correction demonstrated in the
executable asynchronous model, not proof that it caused every earlier device
input failure. No timer, sleep, native acknowledgement, or feature flag was
added.

`misc/test_keyboard_state.py` compiles the actual C header with UBSan and now
also exhausts all 256 × 256 old/new owner-side combinations. It queues the old
owner's releases without draining them, applies the new snapshot while native
state still reports the old owner, then drains the queue and verifies exact
native/posted/physical agreement and final release. Its required output is:

```text
keyboard-state PASS: native divergence, side ownership, failure retry, software restore, 65536 transitions, 65536 async owner handoffs
```

The state, wire, and producer tests were rerun together for this update:
all three passed in 2.059 seconds. These pure tests do not substitute for
scene readiness or real Host delivery.

The complete final suite subsequently passed: 446 tests in 57.012 seconds,
`OK (skipped=12)` (434 executed passes). Retained log:
`/tmp/macws-input-final-all-tests-20260920.log`. This does not override the
remaining real-device negative cases below.

### Published and actually mapped artifacts

`/tmp/macws-input-final-deployment-20260920.json` records signed, trusted new
inodes atomically published at the four exact canonical library paths. Each
old inode was hardlinked into the adjacent
`.macws-input-final-25b4ccace3cf-rollback/` directory before replacement, so
already running consumers were not modified in place. Both architectures
passed the default-constructor/stdout/fork CLI smoke before publication;
receipt: `/tmp/macws-input-final-cli-smoke-20260920.log`.

| Slice | Final UUID | Signed SHA-256 |
|---|---|---|
| arm64 | `E8663F86-D3E2-3B7D-9E24-65FEB7749100` | `9efcfdf3169ba4a6003aab77113e9057e426592ac21215cb0738169a4dbd4011` |
| arm64e | `F63D073E-02FD-3AB5-9B74-3FFB8181551D` | `a63af96c529ff6c34fb28105db9983d30d022bfa5b85718ace1d99934588fa34` |

Only `user/501/UIKitApplication:com.macwsguide.osxvnc` was restarted,
proxy31982 → 35523. The read-only non-suspending mapped witness in
`/tmp/macws-input-final-mapped-20260920.log` confirms:

```text
pid=35523 process=OSXvnc-server task-for-pid=0
image=libmachook_arm64.dylib base=0x104fe8000 cpu=16777228 subtype=0 uuid=e8663f86d3e23b7d9e2465feb7749100 text-address=0x104fec000 text-bytes=648572 text-sha256=b2dbf355f7572ac14bb2f57623892065dcfd2c8b9b220263853295f1e1e0cedc
image-count=301 matched=1 requested=1 no-suspend=yes
```

Host19850, inputd19848, WindowServer15997, and existing applications were not
restarted by this publication. In particular Terminal16275 remains the
**arm64e** `6E014D8F-F233-3820-A51C-1F4466323845` mapping documented above;
the final arm64e CLI smoke is not evidence that Terminal loaded that new
slice. No iPad reboot or respring occurred.

### Real native-HID acceptance and explicit remaining negative

The parent inspected these final-generation full-iPad screenshots, with
diagnostics off:

| Sequence | Actual result / retained screenshot |
|---|---|
| Fullscreen Control-Tab, then Command-A | Original tab selected and its contents blue. `/tmp/macws-input-final-full-basic-20260920.png`. |
| Window mode right-Control-Tab, then right-Command-A | Second tab selected and blue. `/tmp/macws-input-final-window-basic-20260920.png`. |
| Hold right Command across window → fullscreen, then A | Contents selected; subsequent native probe35751 reports all keys/buttons released. `/tmp/macws-input-final-held-command-scene-20260920.png`. |
| Genuine Code foreground → native Dock Terminal tap → immediate Command-T and Control-Tab | A second tab is created and selection returns to the original. `/tmp/macws-input-final-code-before-key-20260920.png` and `/tmp/macws-input-final-dock-terminal-shortcuts-20260920.png`; the latter was also independently inspected for this update. |

One boundary **remains unaccepted**: during `exit-workspace`, which creates a
replacement Scene, two immediate Tab presses did not switch tabs. Evidence:
`/tmp/macws-input-final-held-control-scene-20260920.png` and
`/tmp/macws-input-final-held-control-scene-probed-20260920.png`. Native
probe35855 reports Control keycode59 held (`59:1`), but that is not evidence
that Tab reached a ready Host/scene, nor proof of where it was lost.

In a separate control the **test script**, not production code, waited 0.8
seconds after the fullscreen → window transition before Tab. It then
switched from the second tab to the first blue-selected tab:
`/tmp/macws-input-final-held-control-ready-20260920.png`. Production readiness
logic was not changed and no sleep was added. The scene-creation negative is
not credited as fixed by `acceptedUpSides`, nor attributed to that model
without a delivery witness. The successful bounded cases are not a claim of
100% keyboard reliability or acceptance of the separate Dock-hover issue.

## Final Host contact/momentum update: keyboard regression check

The subsequent six-line Host contact change cancels existing synthesized
momentum when a new contact begins; it does not change keyboard translation or
scene-readiness handling. Only Host19850 was replaced by Host39291. Receipt
`/tmp/macws-host-contact-momentum-publish-20260920.json` records the old
executable inode1709300 preserved by hardlink, new inode1709414 published
atomically, unchanged Info.plist/entitlements, and the single Host lifecycle.
Proxy35523 and inputd19848 remained unchanged, as did WindowServer15997,
Dock16238, Terminal16275, SpringBoard315 and backboardd350. No iPad reboot or
respring was performed.

The published Host's signed SHA-256 is
`0d4c9eff2233d6c8b551e169696ee802802a009b0c1cc5a995df1e1b960bf4a0`.
The parent verified actual Host39291 mapping UUID
`A8A8EAED-7936-3AD8-8002-8494C8CBF2B9`, with 405,516-byte `__text` SHA-256
`68742a505abf1c4ac69a5b84e92661ff3479324ef2fcbc9bbdf9d476173f1f02`.
This is a Host-only update; it does not imply that the older Terminal or
other consumer library mappings changed.

The parent inspected both final native-HID keyboard regressions:

- Fullscreen Control-Tab then Command-A selected the right/second tab and
  highlighted its contents blue:
  `/tmp/macws-contact-final-keyboard-full-20260920.png`.
- Window-mode right-Control-Tab then right-Command-A selected the left/first
  tab and highlighted its contents blue:
  `/tmp/macws-contact-final-keyboard-window-20260920.png`.

Native probes39622 and39691 reported all left/right modifiers and mouse
buttons released. The owned second tab was then selected with Control-Tab and
closed normally using Command-W. Final screenshot
`/tmp/macws-contact-final-keyboard-clean-20260920.png`, also independently
inspected for this update, shows only the original Terminal tab remaining.

The immediate-Tab replacement-Scene negative above was **not retested or
accepted** on this Host. Its readiness source is unchanged; the contact fix
and these basic keyboard passes must not be cited as resolving that boundary.

The complete updated suite passed 447 tests in 56.391 seconds,
`OK (skipped=12)` (435 executed passes), as recorded in
`/tmp/macws-input-contact-final-tests-20260920.log`.
