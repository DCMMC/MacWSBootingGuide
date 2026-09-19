# Keyboard modifier snapshot evidence — 2026-09-20

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
