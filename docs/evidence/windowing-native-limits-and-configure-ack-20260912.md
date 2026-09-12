# Native window limits and resize transaction acknowledgements

Status: implementation/build validated locally; not a device acceptance claim.
The v47 whole-stage/per-item policy isolation remains intact. No deployment or
SpringBoard restart was performed as part of this audit.

## Actual Finder evidence

Read-only copy of the running device's executable:

`/var/mnt/rootfs/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder`

- Fat executable SHA-256: `18f51f37682b3e132166bca92e27237213303f18c8f6b3eaea2e0c72f31cab06`
- Extracted arm64e slice SHA-256: `0f7af3be0d89322d8bb42c4d92a35138ac65dc5f21b03689a885d4d72d84a66b`
- Image base: `0x100000000` (unslid addresses below).
- Objective-C metadata resolves `-[TInfoWindowControllerBase setContentView]`
  to `0x100457548`.

RE-confirmed through that method and the actual selector stubs:

```text
0x1004575a4 bl 0x10073a340    view
0x1004575b0 mov x21, x0      // content view controller's view
0x100457604 mov x2, x20      // content view controller
0x100457608 bl 0x100726120   setContentViewController:
0x10045760c mov x0, x21
0x100457610 bl 0x10073ace0   widthAnchor
0x100457620 adrp x8, 0x100794000
0x100457624 ldr d0, [x8, 0xdb0]
0x100457628 bl 0x100707040   constraintGreaterThanOrEqualToConstant:
0x10045763c mov x0, x21
0x100457640 bl 0x10073ace0   widthAnchor
0x100457650 mov x8, 0x4079000000000000
0x100457654 fmov d0, x8     // IEEE-754 double 400.0
0x100457658 bl 0x1007070a0   constraintLessThanOrEqualToConstant:
0x100457678 mov w3, 2
0x10045767c bl 0x1007008e0   arrayWithObjects:count:
0x1004576b8 bl 0x1006fe260   activateConstraints:
```

Therefore Get Info's width ceiling is an active root-content-view Auto Layout
constraint, not a value that can be inferred from its resizable style bit or
an observed 800-pixel capture. The native constraint is 400 AppKit logical
points; capture backing scale must not be applied twice. No production code
hardcodes this Finder constant or probes sizes by changing the live window.

The previous AppInput implementation returned early for `TInfoWindow`,
advertising an unrestricted horizontal maximum. Its generic path only queried
`maxSize`; it neither queried `contentMaxSize` nor read root content constraints.
It computed maxima for fixed-axis flags/diagnostics but discarded them from
the 20-byte V2 metrics entry and 64-byte V8 catalog descriptor.

## Corrected upstream contract

`MacWSEffectiveMinimumFrameSize` now combines:

1. NSWindow `minSize` and `maxSize`.
2. `contentMinSize` and `contentMaxSize`, converted using the real
   `contentRectForFrameRect:` decoration inset.
3. Active, required (priority 1000), constant Width/Height constraints whose
   first item is the root content view and whose second item is nil.

The third rule reads a narrowly defined native equation. It deliberately does
not guess bounds from arbitrary descendant constraints, soft priorities,
aspect-coupled proposals, or the last frame. Get Info's existing content-driven
fixed-height policy remains independent from its native minimum/maximum width.
The configure setter uses the same computed limits and continues invoking the
real `windowWillResize:toSize:` delegate for proposal-dependent behavior.

The first v48 build narrowed the pre-existing learned-minimum fallback to
compare a result against the normalized `setFrame` proposal and exclude public
aspect/increment axes. That was insufficient: after the root agent deployed
v48, the read-only snapshots below recorded Terminal's published minimum
growing from 230 to 1055 despite that narrower rule. Metadata alone does not
distinguish a native minSize change from the associated-object cache, so the
1055 value must not be attributed to one source without further instrumentation.

The follow-up AppInput change removes the inferred-minimum cache entirely,
including its readers, writers and the inspector's first-observed-width
fallback. A single accepted/rejected frame does not prove a global lower bound,
even after normalization. Only native API/root-constraint values are published;
the exact ACK still returns the application's actual response for this one
request. Opt-in `WINDOW-METRICS` diagnostics now include raw API min/max,
content min/max, required-root constraints and resize increments, so any future
unexpected limit can be attributed to the actual source.

## Transport and compatibility

- Metrics V3 appends maxima and a configure ACK to the unchanged 20-byte V2
  prefix (56-byte total entries). Readers validate both exact V2/20 and V3/56
  layouts and respect the declared stride. Unknown V2 extension fields are zero.
- `macwshostd` reads only each validated entry's declared bytes, preserving
  launcher readiness for both versions.
- The existing stream V8 descriptor and all IOSurface/frame traffic remain
  unchanged. An optional `window_limits` windows-event companion contains
  44-byte records keyed by both owner PID and window ID.
- Old Hosts ignore this key; new Hosts handle its absence. V2 AppKit producers
  do not advertise ACK capability merely because displayd is updated.
- The Host catalog fingerprint includes limits/ACKs, so a constraint response
  that does not change the surface dimensions is still delivered.

After `setFrame:display:animate:` and any anchor correction have completed,
AppInput records the original input timestamp and sample sequence, requested
dimensions, and the actual accepted dimensions on that exact NSWindow. It
publishes these fields with metrics. An unrelated catalog/frame change cannot
be used as an acknowledgement for a newer pending request. Absence of an ACK
remains absence, not an inferred rejection.

## SpringBoard policy scope

`maximum_width` / `maximum_height` extend the existing per-scene policy; zero
is an absent bound. The selected item's actual resize response and grid proposal
are bounded, and its candidate array includes the exact native maximum. All
temporary candidate arrays are restored. Whole-stage calculations still clear
per-item policies as in v47, and non-MacPad applications retain stock grids.

`policy_only:YES` updates a validated scene's metadata without creating a
layout transition, changing its stable size, or activating/reordering it.
The file scanner consumes these requests before selecting geometry winners:
metadata cannot replace the geometry nonce, delete its pending file, or cancel
its postcondition observer. Policy publication has its own issued-at ordering;
an older geometry retry uses newer bounds without republishing obsolete limits.
`initial-size-protocol=1` is a stable capability marker separate from the
diagnostic implementation-path string.

## Local checks and required device acceptance

- C protocol test: mixed V2/V3 decoding, two-window legacy stride, zero-filled
  unknown extension, ACK identity fields, NaN/truncation rejection.
- `test_window_policy_queue_contract.py`: source-contract guards for metadata
  consumption before geometry coalescing, separate nonce ownership, and
  monotonic policy publication. This is not a GUI acceptance test.
- Built AppInput/libmachook for arm64 and arm64e, displayd and hostd for arm64,
  and the SpringBoard tweak for arm64/arm64e.
- Required next: observe new Get Info metrics showing the actual 400 logical
  point maximum; inspect true iPadOS composite screenshots after attempting
  expansion past that boundary and after disclosure-height changes.
- Required next: rapid Terminal resize must settle to the latest requested
  size with matching timestamp/sequence ACK, not a surface from an older request.
- Required next: keep a large Finder plus fixed About and Get Info in one
  Stage Manager group; verify independent dimensions and no stage ejection.

Passing compilation or metadata validation does not satisfy those visual and
interaction acceptance checks.

## Read-only observations after the root agent deployed v48

`misc/macws_window_metrics_dump.py` reads only a bounded regular file (at most
14,360 bytes) and distinguishes V2 ACK-unavailable, V3 no-ACK-yet and an actual
identified ACK. It deliberately reports `current_frame_included: false`:
metrics do not contain the current render frame, and an ACK is historical.

Runtime-confirmed via `tmp/window-metrics-finder-v3-native-max400-v48.json`:

- PID 43902, generation 57, window 213 (Get Info), flags 2125.
- `minimum_logical_size: {width: 265.0, height: 528.0}`.
- `maximum_logical_size: {width: 400.0, height: 528.0}`.
- ACK timestamp `62436.78896916668`, sequence 39, requested/applied 265×528.
- The main Finder window 200 independently reports maximum 16384×16384;
  About window 211 independently reports min=max301×326.
- Generation 60 (`tmp/window-metrics-finder-v3-at-terminal-regression-v48.json`)
  changes Get Info's min/max height to 555 while preserving maximum width400.

Runtime-confirmed via the two Terminal snapshots:

- `tmp/window-metrics-terminal-v3-initial-v48.json`: PID43918/window206,
  generation14, min230×176; ACK timestamp62398.33937600001, sequence345,
  requested862×514, applied857×498.
- `tmp/window-metrics-terminal-v3-min-regression-v48.json`: same PID/window,
  generation67, min1055×176; ACK timestamp62414.07424945835, sequence412,
  requested/applied1055×590.

These prove the new maximum/ACK fields reach the producer sidecar, and that
the first v48 build still had a Terminal minimum regression. They do not prove
the final iPadOS frame, nor the exact source of Terminal's inflated minimum.
The no-inferred-minimum follow-up needs a fresh process and its own acceptance.
