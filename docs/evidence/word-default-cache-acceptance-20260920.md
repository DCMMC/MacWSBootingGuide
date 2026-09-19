# Word default-cache acceptance — 2026-09-20

## Result: FAIL in the ordinary shared-cache configuration

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

## Acceptance boundary

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
