# Finder icon recovery after exact QuickLook generation refresh

## Scope and before state

User-visible missing large icons in `/var/root` affected
`cs336_spring2025_assignment2_systems.pdf` and
`macws-internal-drag-probe.txt`. PNG and folder icons remained visible.
Refreshing **only Finder** from old PID 17058 to normal production PID
76643 did not fix the problem. The inspected before screenshot is
`/tmp/macws-finder-fresh-installed-active-20260920.png`.

The new Finder mapped the installed arm64e library, UUID
`D25AFFEA-E257-3921-A845-785A6012ACBA`, `__text` SHA-256
`008f8532ba2835d78e438927de799231981e59f6bfcea174f952ac19cdabf1ce`.
Its dependent macOS QuickLook jobs were still their pre-upgrade generation:

```text
16636 /System/Library/Frameworks/QuickLookThumbnailing.framework/Support/com.apple.quicklook.ThumbnailsAgent
16645 /System/Library/Frameworks/QuickLook.framework/Versions/A/XPCServices/QuickLookSatellite.xpc/Contents/MacOS/QuickLookSatellite
```

Actual mapped evidence for ThumbnailsAgent 16636:

```text
image=libmachook.dylib cpu=16777228 subtype=2147483650 uuid=a2f517de9c6d3d45afe3458f72e58929 text-bytes=616528 text-sha256=2626650d87e2c0103e216c3badf57beb83e9721aeb4e1000703d5d126b9b1394
```

Both managed launchd jobs were checked for exact PID, PGID=PID, executable
path, `launchdchrootexec` arguments, `/var/mnt/rootfs` root, and matching
production plist under `/var/jb/usr/macOS/gui-launchd/`. The separate
iOS-native ThumbnailsAgent PID 26205 was explicitly excluded.

## Controlled refresh and actual output

Ordinary SIGTERM was first sent to those two verified PIDs. They remained
alive with launchd `runs = 1`; **this did not count as a refresh**. Receipt:
`/tmp/macws-quicklook-refresh-20260920.json`.

With explicit parent authorization, only
`user/foreground/com.macwsguide.quicklook-thumbnails` and
`user/foreground/com.macwsguide.quicklook-satellite` were booted out and
bootstrapped from their unchanged exact production plists. Bootout is
asynchronous: an immediate first thumbnails bootstrap returned 37,
`service already bootstrapped / Operation already in progress`. After
the old job had actually disappeared, bootstrap succeeded. No broad
process matching, service settings change, WS restart, or respring was used.

New managed PIDs were ThumbnailsAgent **81307** and QuickLookSatellite
**82279**. ThumbnailsAgent's actual mapping was verified:

```text
pid=81307 process=com.apple.quicklook.ThumbnailsAgent task-for-pid=0
image=libmachook.dylib cpu=16777228 subtype=2147483650 uuid=d25affeae2573921a845785a6012acba text-bytes=640568 text-sha256=008f8532ba2835d78e438927de799231981e59f6bfcea174f952ac19cdabf1ce
```

The existing mapped-image helper did not allow the QuickLookSatellite
basename and correctly refused PID 82279. Its new job/PID identity is
verified; its mapped UUID was **not** established by that helper.

After navigating Finder to `/var/root`, the real iPad screenshot
`/tmp/macws-finder-fresh-quicklook-20260920.png` showed both formerly absent
icons: a PDF document/type icon and a TXT text-page-shaped icon. These are visible
pixels, not merely a non-nil image object or successful IPC ACK.

The diagnostic Finder was then quit normally. The normal production
launcher created Finder **82644**, window **653**, without any observer or
diagnostic environment. Its mapped UUID/text matched the installed current
library above. The final inspected screenshot
`/tmp/macws-finder-production-freshql-active-20260920.png` again showed the
PDF large icon and TXT text-page-shaped icon. This confirms recovery did not
depend on an observer injection.

This acceptance establishes that the icon positions are no longer blank.
It does **not** establish that the TXT icon contains the actual document's
text; a generic text-document icon is not a content-thumbnail acceptance.

Protected user Word 71663, Excel 71161, PowerPoint 71345, Terminal 17280,
and iOS QuickLook 26205 retained their original PIDs throughout. No user
document was closed, no thumbnail cache was deleted, and no feature flag
was created. UI ownership was released after the final screenshot.

## Diagnostic limitations (do not mistake these for causal traces)

The first Finder observer failed closed on `_dyld_get_image_header(0)`:
MacWS's carrier occupied that slot, although the actual Finder image had
the expected UUID. Its log was `FICON unsupported-main-UUID; no-hooks`.
The revised diagnostic found the unique exact Finder image path and
retained the original UUID, method-type and all seven IMP-offset guards.
It reported `FICON ready` in Finder 81204. Its 60-second observation window
expired before the root directory was opened, so it produced **no target
image metadata events**. No claim about the image producer's internal
return values follows from this unsuccessful observation.

The actual before/after result supports a stale QuickLook generation as
the remaining runtime condition for this reproduction. It does not
identify which individual earlier ABI/shader fix inside the new library
changed the outcome, nor prove every possible Finder thumbnail case.
Safe package upgrade logic should reconcile stateless dependents without
terminating user applications; this session did not change that logic.
