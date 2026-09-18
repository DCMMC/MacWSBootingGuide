# System contract recovery — 2026-09-19

This is a release ledger, not a claim that all reported regressions are fixed.
Audio and per-window size constraints were independently accepted by the user.
Do not change those accepted paths while repairing the remaining boundaries.

## Why the preceding acceptance was insufficient

The flag migration combined default selection, launch-job migration, input
changes and deployment changes. A source inventory proves that switches are
classified; it does **not** prove that every newly selected execution path works.
In particular, GUI jobs already explicitly selected native AGX, while no-env
CLI and IconServices processes entered that default for the first time.
Testing only explicitly configured GUI jobs missed that expanded population.
The observed old Terminal itself already had AGX enabled; its shared-runtime
fork failure is not evidence that this particular process first enabled AGX
through the migration.

Installation is also not process replacement. The earlier Windowing failure
was runtime-confirmed to use an old mapped tweak with a new Host. The recovery
therefore distinguishes source revision, built bytes, installed bytes and
mapped image identity. An installed hash is never a witness for mapped code.

## Required boundaries and acceptance

| Boundary | Invariant | Required witness | Current status |
| --- | --- | --- | --- |
| Production policy | Missing debug files cannot disable production adapters | Clean-environment tests and real no-env clients | Inventory passes; newly exposed CoreImage path under repair |
| Input geometry | Activation and mouse-down resolve the same display point | Native drag focus through down/move/up plus iPadOS pixels | Corrected and deployed; two native-path drags pass |
| Process runtime | Loading Metal must not corrupt later fork/exec | Actual GPU pixels then fork; fresh Terminal tabs | Both slices and canonical production Terminal pass |
| Shader compilation | Preserve the request semantics while satisfying both macOS library admission and native iOS AGX execution | Real captured request/reply, both consumer checks, expected GPU pixels | Native CoreImage request/output mismatch captured; scoped dual-platform repair under test |
| Window presentation | App content reaches the authoritative window backing before system transforms | Normal window, occlusion and Mission Control screenshots | Weather thumbnail black report remains open |
| Document rendering | Annotation/icon pixels exist at their producer and reach the viewer | PDF zoom/paint matrix; affected Finder file types | Open; no blanket GPU disable or placeholder icons |
| Power | Compare equivalent workload and thermal state | Bounded cumulative CPU/temperature observations | No controlled before/after baseline yet; not declared fixed |

## Runtime-confirmed fullscreen drag cause and comparison

Source boundary: the Host pointer proxy converted frame pixels to Quartz
points, then passed those logical points to an activation function that labeled
them with RFB pixel dimensions. inputd converted the coordinates a second time.
The RFB caller, by contrast, supplied actual pixel coordinates. History places
this mismatch in `989e856`; attributing its introduction to the flag migration
would be inaccurate even though the user encountered it during this release.

On the actual device, before the repair, the controlled gesture identified:

```text
DRAG source=(1200,280)/2388x1668 native=(600,140) contact=44001
BEFORE 1789765580.704394 1775 [(292, ['visible', 'has_shadow', 'resizable', 'focused'])]
MACWS-INPUT SLS-ROUTE point=(300.00,70.00) connection=208875 pid=9917 window=235 depth=3/3
MACWS-INPUT FRONT-OWNER routed=9917 front=1775 ready=NO
MACWS-INPUT ACTIVATE seq=3 kind=activate-target target=9917 window=235 repair=YES menu-preflight=NO workspace=YES hiservices=0 deactivated=10 sent=YES errno=0
DURING 1789765580.977501 1775 []
DURING 1789765580.977652 9917 [(235, ['visible', 'has_shadow', 'resizable', 'focused'])]
```

The iPadOS capture sequence `/tmp/macws-focus-beforefix-repro` visibly changes
from Terminal to Weather during the drag, independently confirming the focus
sidecar and routing log. The first attempted automated run did not inject input
because this device has no `pgrep`; that attempt is **not** acceptance evidence.
The corrected run used the observed Dock PID 773.

The repair introduces one `MacWSGlobalActivationRecord` contract shared by the
Host proxy and RFB caller: coordinates travel with their original frame extent;
no captured PID/window is inherited into the global hit test. It does not force
focus, suppress deactivation or periodically reactivate a window. Executable C
tests cover 1x, 2x and fractional extents, shifted display origins, boundaries,
invalid inputs and stale target rejection.

Only OSXvnc was restarted to load the new input implementation (PID 13078).
WindowServer 99427 and the user's applications remained running. With all
diagnostic flags absent, `macws_fullscreen_drag_probe.py` then recorded:

```text
first drag:  before/during/during/during/during/after focused=[292]
second drag: before/during/during/during/during/after focused=[292]
```

Full iPadOS sequences `/tmp/macws-focus-afterfix-repro` and
`/tmp/macws-focus-afterfix-second` retained the Terminal foreground and showed
native window movement. These are tests of the native input transport and
WindowServer behavior, not a new physical Magic Keyboard/UITouch recognition
claim. The reusable probe fails if focus changes, always releases its button,
and requires explicit `--perform`.

## Terminal and shared-runtime integrity

Runtime-confirmed via `Terminal-2026-09-19-043206.ips` and
`Terminal-2026-09-19-043240.ips`: Terminal's fork child dies in
`xpc_atfork_child -> libSystem_atfork_child -> fork -> forkpty` before exec.
The faulting `objc_msgSend` page is read-only in the child. A historical patch
had changed `objc_msgSendSuper2` on that same shared-runtime page from
`AUTDA x16,x17` (`0xdac11a30`) to `XPACD x16` (`0xdac147f0`). Runtime reads
show the actual AGX superclass metadata already carries PAC signatures.

The fix removes that obsolete **global** libobjc text mutation while preserving
the scoped driver stub repair, real class registration, IOGPU loading and
NSBundle/compiler resource initialization. It does not bypass authentication,
fork safety or error handling. On both arm64 and arm64e, an actual Apple M1
4x4 GPU render reads BGRA `191,128,64,255` at every pixel, stock AUTDA stays
unchanged, and the fork child exits 0. Before removal the corresponding probe
rendered correctly but its child died with SIGBUS 10.

An isolated actual Terminal PID 10549 passed new-tab creation: new bash 11446
survived and the complete iPadOS screenshot showed its prompt. That test process
was closed through its real Quit menu; the user's old Terminal was untouched.
The final signed canonical libraries were then installed as new inodes with
verified hashes and an exact rollback receipt. After verifying the old Terminal
1775 had no child jobs, its real Quit menu exited normally. The production
launcher started Terminal 13515; two real New Tab actions retained bash children
13526, 13685 and 13743. `/tmp/macws-terminal-production-verified.png` shows three
tabs, the actual `echo macwsterminalok` result and a restored prompt. Read-only
dyld inspection found exactly one canonical libmachook in both Terminal and its
new shell, UUID `D270F170-4ED4-3D03-8E29-4535AE2077D9`; native AGX loaded with
stock superclass authentication intact. The functioning Terminal was left open.
Other applications still mapping old libraries are tracked as such rather than
claimed to be refreshed. No user documents or desktop services were closed.

## Shipping discipline

Each further production change needs a failing witness, a specific contract
repair, an executable regression where possible, and post-install verification
of the actual consumer. Do not broaden Metal target rewriting, replace missing
icons with dummy pixels, paint a fixed-position Weather overlay over Mission
Control, or disable GPU rendering to make a screenshot superficially pass.

Final release remains pending the open rows above; the earlier audio/window
acceptance alone must not be labeled whole-system production readiness.

## Acceptance tooling is part of the repair

The previous `macws_release_regression.py` could emit top-level `PASS` while
its own visible-output gate said `MANUAL_REQUIRED`. A failed installed-plist
read also looked like omitted, default-on AGX keys. Neither is valid release
evidence. The harness now separates automated success from release acceptance,
rejects unreadable/invalid installed policy, and samples current native thermal
telemetry instead of accepting the last historical watchdog line. Unknown
telemetry blocks acceptance, not the user's applications. No new process kill,
suspend, restart or throttle behavior was added.

Eleven executable harness tests cover the failing evidence cases. A successful
automated run now returns `RELEASE_ACCEPTANCE_REQUIRED` (exit 3), never release
`PASS`; actual installed/mapped identities and visible behavior remain separate
required witnesses.

The installed-profile audit also found four historical, unloaded experiment
jobs in `/var/jb/usr/macOS/gui-launchd`: `glassdemo`, `iconservicesagent.diag`,
`inputlab`, and `maps`. Their exact labels, chroot executable/arguments and
diagnostic keys were validated, and both system and user/501 launchd domains
reported no such service (113). Their original bytes and metadata were retained
by no-clobber hard-link archival under
`/var/jb/usr/macOS/retired-launch-jobs/*.plist.<sha256>.disabled` before removing
only the old launch-directory names. Current generated production jobs and
application data were not changed. These files were not evidence of active
tracing or the cause of the user's heat report.

### Observation must not change application behavior

Runtime-confirmed via `/tmp/macws-preview-mount-ab-20260919.log`: an isolated
Preview test with diagnostics enabled aborted with
`-[NSPopoverFrame resizeIncrements]: unrecognized selector sent to instance`,
from `MacWSPublishWindowMetrics +2112`. The production constraint calculation
already checked selector availability, but the additional diagnostic query did
not. Optional diagnostic size queries now honor actual object capabilities;
missing values are reported as NaN, not used to invent size limits. Three
executable tests cover partial objects, exact returned sizes, and zero native
constraint witness allocations/associated-object accesses with diagnostics off.
The real native constraint queries and resize calculations remain unchanged.
This diagnostic-only crash is distinct from Preview's default-mode FileCache
recursion and is not evidence that the latter is fixed.

The test tools also rejected a dead application whose old, change-driven
metrics file still said "focused". Menu actions now require a live target;
fullscreen drag checks stop and release if the owner dies or focus changes.
This liveness check is not an atomic responder or PID-generation guarantee.
Four focus-gate tests cover stale metrics and unobservable/system PIDs. These
tool checks do not change the user's production input routing.
