# Word default-cache acceptance — 2026-09-20

## Current result: PASS after the production v3 cache transition

After the user confirmed there were no unsaved macOS documents, the normal
macOS GUI stack was stopped. The strict migration verified that no process
still used the chroot, preserved 28 old derived-cache files, installed schema
`macws-macabi-image-filter-v3`, and passed its check. The iPad was not rebooted
or resprung. The ordinary coexistence startup then completed successfully.

Two separate, ordinary Word launches now pass the actual unsaved-document
alert test: native touch on the Dock icon (owned PID `17807`), then native
touch on Word on Launchpad page two (owned PID `18644`). Each created a new
Document1, entered a short acceptance string, and invoked Close. Neither used
an observer, a private cache override, a temporary injected library, nor a
diagnostic flag. Both real iPadOS screenshots show the blue Save background
and complete Don't Save and Cancel buttons; both were visually inspected:

- `/tmp/macws-word-dock-default-alert-20260920.png`
- `/tmp/macws-word-launchpad-default-alert-20260920.png`
- `/tmp/macws-word-dock-default-alert-cg-20260920.png` — independent raw
  260 × 328 macOS window image, owner 17807, window 49; also visually normal.

Live-image inspection of both Word processes confirmed canonical arm64
library UUID `6B46FD91-A12A-37D9-92F5-EBA1F07F55AA`, text SHA-256
`8c2ac164642db290c091c5d7940c0610187f0835629240642c909610c0fb5317`.
Its signed canonical file SHA-256 is
`2cc2fa505a9b543080a1d60bc29bacc7eeaec9faa25e4aadcf596ccfa75b06c5`.
Each owned document was discarded using Don't Save, followed by normal
Command-Q; fresh process checks confirmed both PIDs absent. Terminal 16275
and WindowServer 15997 remained alive. No acceptance document was saved.

The limited Dock finger-touch checks did not reproduce persistent
magnification after finger lift. This is **not** evidence that the reported
intermittent Dock hover/magnification issue is fixed.

The earlier failure below is retained as the pre-migration control, not the
current deployment result.

## Earlier result: FAIL in the ordinary shared-cache configuration

Runtime-confirmed by the actual unsaved-document alert in owned Word PID
`2999`, window `799`. Both the direct macOS window image and the full iPadOS
screen show the Save label without its blue button background:

- `/tmp/macws-word-default-alert-20260920-cg.png` — direct
  `CGWindowListCreateImage`, 260 × 328 pixels, owner PID 2999.
- `/tmp/macws-word-default-alert-20260920-ipad.png` — native iPadOS composite,
  2778 × 1940 pixels.

Both images were copied to the development Mac and visually inspected. This
is not an inference from process uptime, an input acknowledgement, or the
previous diagnostic-cache success.

## Exact test conditions

A single additional owned Word process used the installed canonical
`/usr/local/lib/libmachook_arm64.dylib`, with no additional observer libraries,
no private cache override, no runtime diagnostic environment switches, and no
diagnostic marker files. The ordinary shared Metal cache was neither renamed
nor edited. The existing native launcher supplied the same required chroot
metadata; `-ApplePersistenceIgnoreState YES` prevented restoration of user
documents in this additional test instance.

The signed canonical library SHA-256 was
`273edeca9604272d4305b6c7f9b630d011367ce8c530701ca95ca8084454a141`.
Read-only live-image inspection confirmed:

```text
pid=2999 process=Microsoft Word task-for-pid=0
image=libmachook_arm64.dylib base=0x107628000 cpu=16777228 subtype=0 uuid=5ec31e06f7d038ce998934862e420c21 text-address=0x10762c634 text-bytes=668868 text-sha256=7f9c6e06380acedd01f8bc2758e473d4f92e340dfc40c774185c7f4f005769f1
image-count=767 matched=1 requested=1 no-suspend=yes
```

Normal application input created a new document, typed only
`MacWS ordinary default cache owned test`, and invoked Close. The external CG
capture did not execute a CPU cache-display refresh inside Word.

## Protected processes and cleanup

Before every test input, the helper checked the exact executable path and
process birth time of these protected processes:

| PID | Process | Birth time reported by the device |
| --- | --- | --- |
| 89019 | User Word | Sun Sep 20 02:37:15 2026 |
| 17280 | User Terminal | Sat Sep 19 17:26:13 2026 |
| 16900 | WindowServer | Sat Sep 19 17:25:21 2026 |

Only owned PID 2999 received Don't Save followed by Command-Q. Its native
parent recorded `state=exited, returncode=0`, and a fresh process check
confirmed its absence. All three protected identities remained unchanged.
No service, existing compiler worker, or user application was restarted.
`/tmp/macws_mtlcompiler_diagnostics` was absent before and after this test.

Local and device receipts are
`/tmp/macws-word-default-alert-20260920.{json,ui.json,cleanup.json}`. The fresh
guarded launcher and cleanup script are respectively
`/tmp/macws_word_default_alert_launch_20260920.py` and
`/tmp/macws_word_default_alert_cleanup_20260920.py`.

## Earlier acceptance boundary (superseded by the v3 retest above)

The corrected compiler's earlier fresh private-cache Word test genuinely
passed: owned PID 87884 showed a blue Save button in both raw CG and native
iPadOS pixels. Its actual kind-5 reply contained the corrected MacABI library;
see [the detailed alert investigation](office-unsaved-alert-20260920.md).

That success does **not** establish ordinary production readiness. The default
shared-cache test above still fails. The device's existing v2 cache generation
has not yet been safely migrated to the corrected generation while user Word
is active; no shared-cache mutation was attempted. Attribution of this precise
ordinary run to a particular cached record was not instrumented. Default-cache
visual acceptance remains **pending**, and must be repeated after the safe
production cache transition rather than reported as complete.
