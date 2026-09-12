# Window-mode menus and two-finger export (2026-09-12)

Scope: native Finder/Terminal context and toolbar menus; two-finger Finder
export must not commit an internal icon move. The earlier fullscreen, menu
provider, Maps and Safe Mode work remains documented separately. This is not
an assertion that every third-party popover or unrelated historical issue
has been verified.

## Native menu pixels

Runtime-confirmed via native iPadOS captures and WindowServer screenshots:
`tmp/v60-finder-toolbar-before.png` has the isolated, flat menu backing;
`tmp/v60-finder-toolbar-native.png` has compositor material and shadow. The
existing exact-window HW capture does not carry the surrounding compositor
result. Selective capture was separately blocked by the real TCC preflight;
that policy is **not** bypassed here.

The base window keeps its isolated Retina stream. Only a same-owner, actual
level-101 popup with validated on-screen geometry uses the existing trusted,
completed AGX FinalComposite IOSurface. Its descriptor retains exact popup
input geometry separately from texture crop coordinates. Host samples only
the popup and a bounded 20-point native-shadow region, clipped to the base
and texture. No CPU image copy, invented blur, double SDF shadow, forced
permission result, or global base-window screen crop was introduced.

Occlusion checks stop at the popup, not the base. The actual ordered catalog
contained a transparent full-display Dock window21 at level20 below the menu;
the first prototype incorrectly treated that as an occluder. Same-owner
attached submenus preserve the parent's native material. A tall context menu
may extend beyond the base; only its visible paint region is relevant. Actual
offscreen/occluded/unsupported layers retain their independent capture.

Freshness and ownership remain mandatory: completed frame time must be newer
than observed popup geometry; geometry changes revoke the crop; every native
surface lease owns a use count until Host's GPU retirement. The existing
three-outstanding-frames-per-layer bound remains. Fullscreen is unchanged.

Runtime-confirmed via `macwsdisplayd.err`, copied verbatim:

```text
MACWS-DISPLAY native-popup-composite base=855 layer=882 owner=73105 source=2024,140 352x460 destination=1072,90 352x460 completed=2815888099436 required=2815887836951 route=completed-AGX-region no-copy=YES
MACWS-DISPLAY native-popup-composite base=855 layer=883 owner=73105 source=1738,404 296x504 destination=786,354 296x504 completed=2823045353964 required=2823045329304 route=completed-AGX-region no-copy=YES
MACWS-DISPLAY native-popup-composite base=855 layer=884 owner=73105 source=1584,452 652x756 destination=632,402 652x756 completed=2838601573493 required=2838601550573 route=completed-AGX-region no-copy=YES
MACWS-DISPLAY native-popup-composite base=905 layer=910 owner=79913 source=1270,292 402x592 destination=662,242 402x592 completed=2875522812902 required=2875522498112 route=completed-AGX-region no-copy=YES
```

Inspected native iPadOS captures:

- `tmp/v63-start.png`: Finder Action menu, real border/shadow.
- `tmp/v63-submenu.png`: Sort By submenu, visible blue-folder backdrop tint,
  native shadow and coherent selection highlight in both menus.
- `tmp/v64-context.png`: tall file context menu, visible blue backdrop tint
  and native shadow; existing base clipping remains, not claimed fixed here.
- `tmp/v64-final-layout.png`: Terminal context menu, native border/shadow.
  The earlier `v64-terminal-context.png` landed before menu presentation and
  is not an acceptance image.

## Export probe cancellation

The two-finger hold generates a deliberately tagged, short native source drag
to populate NSDragPboard. Its cancel record formerly became only mouse-up,
which is a drop. Before-fix real two-finger HID captures
`v60-icon-before.png` / `v60-icon-hold-before-fix.png` showed approximately
21 displayed pixels of horizontal movement, matching the 16-view-point probe.

Only an already-owned exact-window/contact **InteropDragProbe TouchCancel**
now posts native Escape down/up before releasing the mouse button. The
ordinary one-finger tracker, two-finger recognizer failure dependency, short
secondary tap and keyboard input paths are unchanged. Mouse release still
runs if key posting fails; no stuck button is hidden.

Runtime-confirmed via Finder.host.log:

```text
#### APP-INPUT CONTENT-DRAG-ROUTE pid=73105 gesture=1146242828 window=855 local=(640.05,295.21) content=(640.05,295.21) route=native-system-interop-probe
#### APP-INPUT INTEROP-CANCEL pid=73105 window=855 contact=1146242828 escape=0/0 before-mouse-up=YES
#### APP-INPUT SYSTEM-POINTER pid=73105 window=855 kind=4 buttons=0/0 appkit=(1132.04,602.21) quartz=(1132.04,231.79) exact-start=NO exact-continuation=YES result=0/0
```

Host confirmed the actual named plain-text provider:

```text
1789211489.486 interop-provider-output name=macws-internal-drag-probe.txt types=public.plain-text,public.content conforms=item:YES data:YES file-url:NO content:YES directory:NO
1789211489.489 interop-drag-prepare completed window=855 pid=73105 serial=2 source=two-finger-hold began=YES providers=1 urls=1 types=public.plain-text,public.content
```

`v62-export-after.png` visibly contains the export handle. After dismissing
the handle/selection, comparison of the original icon region in
`v62-export-before.png` and `v62-export-dismissed.png` returned:

```text
image=2778x1940 region=1890,760 140x125 best=(MAE, dx): [(0.0, 0), (4.684571428571428, -1), (4.684571428571428, 1), (6.226285714285714, -2), (6.226285714285714, 2)]
```

Thus that trial has zero pixel difference and zero displacement. Real short
two-finger HID generated the context menu without an export handle. An
attempted final one-finger regression trial used stale coordinates after the
Finder window changed from718 to858points wide: it is **not** a passing drag
test. No new claim of end-to-end iOS file delivery is made from provider
creation alone. The temporary AppInput diagnostic marker was removed and the
diagnostic Finder process73105 restarted without it (replacement81969).

## Validation incident: packed metrics corruption

The first test display service crashed: report
`macwsdisplayd-2026-09-12-181939.ips`, PID69700, SIGSEGV in objc_release+8,
`SendWindowList+2536` (binary offset0x14158). x0 was
`0x2301e38000000003`, not an Objective-C object. The restart loop was stopped;
SpringBoard/WindowServer were not restarted.

Runtime-confirmed on the actual device by
`misc/macws_metrics_storage_test.m`:

```text
metrics-storage wire=56 objc-encoded=64 alignment=8 encoding={?=IIIffff{?=dIffff}}
metrics-storage byte-exact roundtrip and canaries: PASS
```

Objective-C type encodings omit `packed`. NSValue copied64bytes into/from
a56-byte wire struct and corrupted an adjacent ARC owner. All metric storage
and read sites now use NSData with explicit sizeof lengths. The protocol's
56-byte v3 ABI is unchanged. No release/assert bypass was added. Real window
lists, resize ACKs, base and popup frames subsequently completed successfully.

## Validation incident: diagnostic disk writes

Report `macwsdisplayd.diskwrites_resource-2026-09-12-195526.ips`, incident
C8090A4D-3011-4581-B452-2E5C461EDCCB, explicitly says `Action taken: none`.
This is a resource warning, not another crash:

```text
Writes:           1073.75 MB of file backed memory dirtied over 5257 seconds (204.27 KB per second average), exceeding limit of 12.43 KB per second over 86400 seconds
```

Symbolicating its exact deployed image maps macwsdisplayd offsets0x1edb8,
0x1f560,0x3bc0,0x3ca8,0x3674 to the receiver, DeliverFinalComposite and
WriteFinalCompositeState. Every completed frame atomically rewrote a status
sidecar. That diagnostic heartbeat is now coalesced to5seconds for unchanged
state/producer/reason. State transitions remain immediate and every real
frame still traverses the unchanged XPC validation/presentation path.

## Build and regression coverage

- Host, displayd, both libmachook slices compile and pass native strict
  codesign verification. Final CDHashes trusted; deployments use fresh inodes,
  atomic replacement and explicit backups.
- 56window source contracts,4location contracts,12compiled switcher identity
  cases, compiled protocol validators and packed-metrics canary test pass.
  Source contracts do not substitute for the captures above.
- SpringBoard58898 and WindowServer76954 remained unchanged during this
  follow-up. The prior Safe Mode rebind-path validation limitation remains in
  its own evidence document; process uptime alone is not stability evidence.
- Raw screenshots and personal logs remain local, not in Git.

Deployed SHA256 (final diagnostic-write check recorded separately below):

```text
Host v63 a8680e5228a9f7ec700d3a09f0198c69e7a29aa75181ea97752a46d9eaf7f728
displayd v65 93c5091ccac71168803f382f12001e1dec7397ff84a3f646edf5dd2ffb087711
hooks arm64e v60 1937a6a0a36dafb567915814855adec41033ea72971830d802ccc2e4ddc8bdc6
hooks arm64 v60 d06971fd5dc9c4d5a6d3c84d36e4ba5b23043f1c2a3cc75d0dd09bc000f6372c
```

Final v65 runtime check: the installed hash matches above. Consecutive
one-second reads kept the same sidecar inode between updates; mtime/sequence
advanced as1789216765/1141096,1789216770/1141146,
1789216775/1141196. This verifies5-second diagnostic writes while completed
frame sequences advance. `tmp/v65-final.png` was inspected: live Finder911
and Terminal905 coexist. Displayd84113 publishes actual1626x1166 and1916x1460
base frames at backing2.0. SB58898/WS76954 unchanged; diagnostic marker absent.
This short cadence check is not a new24-hour disk-write benchmark.
